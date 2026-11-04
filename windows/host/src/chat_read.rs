//! The Windows host's one door onto a group's chat (task 2802, W1).
//!
//! **Read only.** There is no send, no draft and no `chat_send` here; this
//! module carries the requests mac already sends through the same app-level
//! ABI (`ghostty_app_chat_read`, `include/ghostty.h`), and the strict
//! replies back. The W1 contract is
//! `polter-artifacts/2793/2802-W1-READ-TRANSPORT.md`; the UI that will use
//! it is a later slice, and nothing in this file starts, schedules or
//! retries anything.
//!
//! **One export, one call.** `group_read` and the three bounded history
//! calls are dispatched by the core behind that one symbol. A reply is
//! asked for once, into a buffer of `BODY_LIMIT + 1` bytes (`cap` is the
//! whole allocation; the last byte is the core's NUL). The call is never
//! made twice: a `0` answer is "nothing yet", and asking again to learn a
//! size would be a second chance for a poll's state to move between them.
//!
//! **Transport is not the core's answer.** `TransportError` is about the
//! call itself (the export is missing, the reply did not fit, its bytes are
//! not UTF-8). The core's own refusals and pending/ready states are parsed
//! as JSON and kept as such -- an error is read before a state, and a
//! reply that says both is malformed, not a success.

use std::ffi::c_void;

use serde_json::{Map, Value};

use crate::ffi::Api;

/// The largest reply body this host accepts, not counting the NUL the core
/// may write after it.
pub const BODY_LIMIT: usize = 96 * 1024;

/// The ABI as the host calls it. Kept a named type so a test can hand in
/// the same shape without a loaded `Api`.
pub type ReadFn = unsafe extern "C" fn(
    app: *mut c_void,
    req: *const u8,
    len: usize,
    buf: *mut u8,
    cap: usize,
) -> usize;

/// What one call to the door came to, before any JSON is read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Transport {
    /// The core has no reading yet: the ABI answered 0 bytes.
    NotReady,
    /// The reply body, already checked as UTF-8.
    Body(String),
}

/// Why there is no body at all. Never a decode of the core's answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportError {
    /// This core has no `ghostty_app_chat_read`: a core from before task
    /// 2802. Not a socket fallback and not a surface door.
    Unsupported,
    /// The reply is longer than the buffer this host allocated. The buffer
    /// is not read and the call is not made again.
    TooLarge,
    /// The reply's bytes are not UTF-8. Never replaced with U+FFFD.
    MalformedUtf8,
}

/// One call, one buffer. `call` is handed the request's bytes and the
/// output buffer, and answers how many bytes of body it wrote.
pub fn read_once(
    request: &str,
    call: impl FnOnce(&[u8], &mut [u8]) -> usize,
) -> Result<Transport, TransportError> {
    let mut out = vec![0u8; BODY_LIMIT + 1];
    let n = call(request.as_bytes(), &mut out);
    if n == 0 {
        return Ok(Transport::NotReady);
    }
    if n > BODY_LIMIT {
        return Err(TransportError::TooLarge);
    }
    match std::str::from_utf8(&out[..n]) {
        Ok(text) => Ok(Transport::Body(text.to_owned())),
        Err(_) => Err(TransportError::MalformedUtf8),
    }
}

/// The production adapter, with the loaded export.
///
/// **App thread only.** The `App` is used for the duration of the call and
/// is not stored; nothing here is `Send`/`Sync`.
pub fn ask(api: &Api, app: *mut c_void, request: &str) -> Result<Transport, TransportError> {
    ask_with(api.app_chat_read, app, request)
}

/// The same, with the export passed in: the one place the missing-export
/// rule lives, and what a test can drive without a loaded `Api`.
pub fn ask_with(
    read: Option<ReadFn>,
    app: *mut c_void,
    request: &str,
) -> Result<Transport, TransportError> {
    let Some(read) = read else {
        return Err(TransportError::Unsupported);
    };
    read_once(request, |req, out| unsafe {
        read(app, req.as_ptr(), req.len(), out.as_mut_ptr(), out.len())
    })
}

// ------------------------------------------------------------------ requests

/// How long a `request_id` may be, in UTF-8 bytes.
pub const REQUEST_ID_LIMIT: usize = 128;
/// The range the core accepts for `limit`.
pub const LIMIT_RANGE: (u16, u16) = (1, 200);

/// A request this host can make. **A fixed set, not a method string**: a
/// caller cannot name an arbitrary method or carry a reader/from/scope of
/// its own.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    /// The live read. `since` is the group's in-memory `seq`, never a
    /// `log_seq` and never a history token.
    Live {
        group: String,
        since: u64,
    },
    Begin {
        group: String,
        request_id: String,
        limit: u16,
        resume_token: Option<String>,
    },
    Poll {
        job_id: String,
    },
    Cancel {
        job_id: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestError {
    EmptyRequestId,
    RequestIdTooLong,
    BadLimit,
    BadJobId,
    BadResumeToken,
    Encode,
}

/// A job id or resume token: exactly 32 lowercase hex characters, the
/// core's own form. Upper case is a different token and is refused.
pub fn is_opaque_id(text: &str) -> bool {
    text.len() == 32 && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

impl Request {
    /// Encode this as the one JSON object the door takes. Built with
    /// `serde_json`, never by pasting a group or a token into a string.
    pub fn encode(&self) -> Result<String, RequestError> {
        let mut params = Map::new();
        let method = match self {
            Request::Live { group, since } => {
                params.insert("group".into(), Value::String(group.clone()));
                params.insert("since".into(), Value::from(*since));
                "group_read"
            }
            Request::Begin {
                group,
                request_id,
                limit,
                resume_token,
            } => {
                if request_id.is_empty() {
                    return Err(RequestError::EmptyRequestId);
                }
                if request_id.len() > REQUEST_ID_LIMIT {
                    return Err(RequestError::RequestIdTooLong);
                }
                if *limit < LIMIT_RANGE.0 || *limit > LIMIT_RANGE.1 {
                    return Err(RequestError::BadLimit);
                }
                if let Some(token) = resume_token {
                    if !is_opaque_id(token) {
                        return Err(RequestError::BadResumeToken);
                    }
                }
                params.insert("group".into(), Value::String(group.clone()));
                params.insert("request_id".into(), Value::String(request_id.clone()));
                params.insert("limit".into(), Value::from(*limit));
                if let Some(token) = resume_token {
                    params.insert("resume_token".into(), Value::String(token.clone()));
                }
                "chat_history_begin"
            }
            Request::Poll { job_id } => {
                if !is_opaque_id(job_id) {
                    return Err(RequestError::BadJobId);
                }
                params.insert("job_id".into(), Value::String(job_id.clone()));
                "chat_history_poll"
            }
            Request::Cancel { job_id } => {
                if !is_opaque_id(job_id) {
                    return Err(RequestError::BadJobId);
                }
                params.insert("job_id".into(), Value::String(job_id.clone()));
                "chat_history_cancel"
            }
        };
        let mut body = Map::new();
        body.insert("method".into(), Value::String(method.into()));
        body.insert("params".into(), Value::Object(params));
        serde_json::to_string(&Value::Object(body)).map_err(|_| RequestError::Encode)
    }
}

// ------------------------------------------------------------------ replies

/// Why a ready page stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stop {
    AtEnd,
    Full,
    Budget,
    Gap,
}

/// One terminal a message named. `title` is absent when it was empty, the
/// same distinction the line carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mention {
    pub id: String,
    pub title: Option<String>,
}

/// One message, in the core's own fields. A history record has `seq = 0`,
/// and that is legal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    pub seq: u64,
    pub log_seq: u64,
    pub from: String,
    pub from_self: bool,
    pub author: String,
    pub at_ms: i64,
    pub summary: bool,
    pub channel: u64,
    pub text: String,
    pub anchor: String,
    pub live_anchor: Option<String>,
    pub content_version: u64,
    /// `None` is "the line did not record them"; `Some(vec![])` is "it
    /// named nobody". The two are not folded together.
    pub mentions: Option<Vec<Mention>>,
    /// `None` on the same terms as `mentions`; `Some("")` is a terminal in
    /// no role.
    pub role: Option<String>,
}

/// The live read's batch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveBatch {
    pub group: String,
    pub session: String,
    pub cursor: u64,
    pub since: u64,
    pub next: u64,
    pub more: bool,
    pub messages: Vec<Message>,
}

/// A failure the core named. Gate-level refusals carry only `error`;
/// post-begin ones also carry the job's identity, and `TooLarge` carries
/// the token to resume at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    pub error: String,
    pub job_id: Option<String>,
    pub group: Option<String>,
    pub session: Option<String>,
    pub next_token: Option<String>,
}

/// The identity a pending, cancelled or begin reply carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub job_id: String,
    pub group: String,
    pub session: String,
}

/// A scan that has started, with the live snapshot taken when it began.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BeginPage {
    pub job_id: String,
    pub group: String,
    pub session: String,
    pub live_since: u64,
    pub history_upper: u64,
    pub live_snapshot: Vec<Message>,
}

/// One finished page. `next_token` is a **required key** even when null.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadyPage {
    pub job_id: String,
    pub group: String,
    pub session: String,
    pub messages: Vec<Message>,
    pub stop: Stop,
    pub next_token: Option<String>,
    pub restarted: bool,
    pub gap: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveOutcome {
    Batch(LiveBatch),
    Failed(Failure),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BeginOutcome {
    Started(BeginPage),
    Failed(Failure),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PollOutcome {
    Pending(Status),
    Cancelled(Status),
    Ready(ReadyPage),
    Failed(Failure),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CancelOutcome {
    Cancelled(Status),
    Failed(Failure),
}

/// A reply this host could not read. **Not an empty page and not a
/// pending**: the core said something this build cannot act on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Malformed;

// ---------------------------------------------------------------- decoding

fn object(value: &Value) -> Result<&Map<String, Value>, Malformed> {
    match value {
        Value::Object(o) => Ok(o),
        _ => Err(Malformed),
    }
}

fn required_string(o: &Map<String, Value>, key: &str) -> Result<String, Malformed> {
    match o.get(key) {
        Some(Value::String(s)) => Ok(s.clone()),
        _ => Err(Malformed),
    }
}

/// Missing and null are one fact (as the mac model reads them); an explicit
/// empty string or empty array is not.
fn optional_string(o: &Map<String, Value>, key: &str) -> Result<Option<String>, Malformed> {
    match o.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        _ => Err(Malformed),
    }
}

fn required_u64(o: &Map<String, Value>, key: &str) -> Result<u64, Malformed> {
    match o.get(key) {
        // `as_u64` refuses floats, so a number cannot be routed through f64.
        Some(Value::Number(n)) => n.as_u64().ok_or(Malformed),
        _ => Err(Malformed),
    }
}

fn required_i64(o: &Map<String, Value>, key: &str) -> Result<i64, Malformed> {
    match o.get(key) {
        Some(Value::Number(n)) => n.as_i64().ok_or(Malformed),
        _ => Err(Malformed),
    }
}

fn required_bool(o: &Map<String, Value>, key: &str) -> Result<bool, Malformed> {
    match o.get(key) {
        Some(Value::Bool(b)) => Ok(*b),
        _ => Err(Malformed),
    }
}

fn opaque_required(o: &Map<String, Value>, key: &str) -> Result<String, Malformed> {
    let text = required_string(o, key)?;
    if !is_opaque_id(&text) {
        return Err(Malformed);
    }
    Ok(text)
}

fn opaque_optional(o: &Map<String, Value>, key: &str) -> Result<Option<String>, Malformed> {
    match optional_string(o, key)? {
        None => Ok(None),
        Some(text) if is_opaque_id(&text) => Ok(Some(text)),
        Some(_) => Err(Malformed),
    }
}

fn mention(value: &Value) -> Result<Mention, Malformed> {
    let o = object(value)?;
    Ok(Mention {
        id: required_string(o, "id")?,
        title: optional_string(o, "title")?,
    })
}

fn message(value: &Value) -> Result<Message, Malformed> {
    let o = object(value)?;
    let mentions = match o.get("mentions") {
        None | Some(Value::Null) => None,
        Some(Value::Array(items)) => {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                out.push(mention(item)?);
            }
            Some(out)
        }
        _ => return Err(Malformed),
    };
    Ok(Message {
        seq: required_u64(o, "seq")?,
        log_seq: required_u64(o, "log_seq")?,
        from: required_string(o, "from")?,
        from_self: required_bool(o, "from_self")?,
        author: required_string(o, "author")?,
        at_ms: required_i64(o, "at_ms")?,
        summary: required_bool(o, "summary")?,
        channel: required_u64(o, "channel")?,
        text: required_string(o, "text")?,
        anchor: required_string(o, "anchor")?,
        live_anchor: optional_string(o, "live_anchor")?,
        content_version: required_u64(o, "content_version")?,
        mentions,
        role: optional_string(o, "role")?,
    })
}

fn messages(o: &Map<String, Value>, key: &str) -> Result<Vec<Message>, Malformed> {
    let items = match o.get(key) {
        Some(Value::Array(items)) => items,
        _ => return Err(Malformed),
    };
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        out.push(message(item)?);
    }
    Ok(out)
}

fn failure(o: &Map<String, Value>) -> Result<Failure, Malformed> {
    Ok(Failure {
        error: required_string(o, "error")?,
        job_id: opaque_optional(o, "job_id")?,
        group: optional_string(o, "group")?,
        session: optional_string(o, "session")?,
        next_token: opaque_optional(o, "next_token")?,
    })
}

fn status(o: &Map<String, Value>) -> Result<Status, Malformed> {
    Ok(Status {
        job_id: opaque_required(o, "job_id")?,
        group: required_string(o, "group")?,
        session: required_string(o, "session")?,
    })
}

/// What every reply starts with: a failure, or `ok=true` and the state it
/// named. A reply carrying both an error and `ok=true` is malformed.
enum Head<'a> {
    Failure(Failure),
    Ok(&'a Map<String, Value>),
}

fn head(o: &Map<String, Value>) -> Result<Head<'_>, Malformed> {
    if o.contains_key("error") {
        if required_bool(o, "ok").ok() == Some(true) {
            return Err(Malformed);
        }
        return Ok(Head::Failure(failure(o)?));
    }
    if required_bool(o, "ok")? != true {
        return Err(Malformed);
    }
    Ok(Head::Ok(o))
}

fn state<'a>(o: &'a Map<String, Value>) -> Result<&'a str, Malformed> {
    match o.get("state") {
        Some(Value::String(s)) => Ok(s),
        _ => Err(Malformed),
    }
}

fn stop(text: &str) -> Option<Stop> {
    match text {
        "at_end" => Some(Stop::AtEnd),
        "full" => Some(Stop::Full),
        "budget" => Some(Stop::Budget),
        "gap" => Some(Stop::Gap),
        _ => None,
    }
}

/// The stop reason and the resume point must not disagree: an end has no
/// token, a full or budget page must name one, and a gap may have either.
fn resumable(page: &ReadyPage) -> bool {
    match page.stop {
        Stop::AtEnd => page.next_token.is_none(),
        Stop::Full | Stop::Budget => page.next_token.as_deref().map_or(false, |t| !t.is_empty()),
        Stop::Gap => page.next_token.as_deref().map_or(true, |t| !t.is_empty()),
    }
}

fn parse(text: &str) -> Result<Value, Malformed> {
    serde_json::from_str::<Value>(text).map_err(|_| Malformed)
}

/// The live read (`group_read`).
pub fn decode_live(text: &str) -> Result<LiveOutcome, Malformed> {
    let value = parse(text)?;
    let o = object(&value)?;
    let o = match head(o)? {
        Head::Failure(f) => return Ok(LiveOutcome::Failed(f)),
        Head::Ok(o) => o,
    };
    Ok(LiveOutcome::Batch(LiveBatch {
        group: required_string(o, "group")?,
        session: required_string(o, "session")?,
        cursor: required_u64(o, "cursor")?,
        since: required_u64(o, "since")?,
        next: required_u64(o, "next")?,
        more: required_bool(o, "more")?,
        messages: messages(o, "messages")?,
    }))
}

/// A begin is a snapshot, never a page: `state` must be `pending`.
pub fn decode_begin(text: &str) -> Result<BeginOutcome, Malformed> {
    let value = parse(text)?;
    let o = object(&value)?;
    let o = match head(o)? {
        Head::Failure(f) => return Ok(BeginOutcome::Failed(f)),
        Head::Ok(o) => o,
    };
    if state(o)? != "pending" {
        return Err(Malformed);
    }
    Ok(BeginOutcome::Started(BeginPage {
        job_id: opaque_required(o, "job_id")?,
        group: required_string(o, "group")?,
        session: required_string(o, "session")?,
        live_since: required_u64(o, "live_since")?,
        history_upper: required_u64(o, "history_upper")?,
        live_snapshot: messages(o, "live_snapshot")?,
    }))
}

/// One poll: pending, cancelled, a finished page, or a failure. An unknown
/// success state is malformed, not a page.
pub fn decode_poll(text: &str) -> Result<PollOutcome, Malformed> {
    let value = parse(text)?;
    let o = object(&value)?;
    let o = match head(o)? {
        Head::Failure(f) => return Ok(PollOutcome::Failed(f)),
        Head::Ok(o) => o,
    };
    match state(o)? {
        "pending" => Ok(PollOutcome::Pending(status(o)?)),
        "cancelled" => Ok(PollOutcome::Cancelled(status(o)?)),
        "ready" => {
            let stop = stop(required_string(o, "stop")?.as_str()).ok_or(Malformed)?;
            // The key must be there even when its value is null; a page
            // that never said whether it can be resumed is not a page that
            // ended.
            let next_token = match o.get("next_token") {
                None => return Err(Malformed),
                Some(Value::Null) => None,
                Some(Value::String(s)) => Some(s.clone()),
                Some(_) => return Err(Malformed),
            };
            if let Some(token) = next_token.as_deref() {
                if !is_opaque_id(token) {
                    return Err(Malformed);
                }
            }
            let page = ReadyPage {
                job_id: opaque_required(o, "job_id")?,
                group: required_string(o, "group")?,
                session: required_string(o, "session")?,
                messages: messages(o, "messages")?,
                stop,
                next_token,
                restarted: required_bool(o, "restarted")?,
                gap: required_bool(o, "gap")?,
            };
            if !resumable(&page) {
                return Err(Malformed);
            }
            Ok(PollOutcome::Ready(page))
        }
        _ => Err(Malformed),
    }
}

/// A cancel answers `cancelled` or a failure and nothing else.
pub fn decode_cancel(text: &str) -> Result<CancelOutcome, Malformed> {
    let value = parse(text)?;
    let o = object(&value)?;
    let o = match head(o)? {
        Head::Failure(f) => return Ok(CancelOutcome::Failed(f)),
        Head::Ok(o) => o,
    };
    if state(o)? != "cancelled" {
        return Err(Malformed);
    }
    Ok(CancelOutcome::Cancelled(status(o)?))
}

// ------------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;

    fn id() -> String {
        "0123456789abcdef0123456789abcdef".to_owned()
    }

    fn good() -> String {
        "0123456789abcdef0123456789abcdef".to_owned()
    }

    fn message_json() -> &'static str {
        r#"{"seq":3,"log_seq":9,"from":"0x1","from_self":false,"author":"worker","at_ms":1700000000000,"summary":false,"channel":0,"text":"hi","anchor":"p:9","live_anchor":null,"content_version":0,"mentions":[],"role":""}"#
    }

    #[test]
    fn transport_reads_exactly_the_bytes_it_was_told_and_zero_is_not_ready() {
        let t = read_once("{}", |_req, out| {
            out[..2].copy_from_slice(b"{}");
            2
        })
        .unwrap();
        assert_eq!(t, Transport::Body("{}".to_owned()));

        let empty = read_once("{}", |_, _| 0).unwrap();
        assert_eq!(empty, Transport::NotReady);
    }

    #[test]
    fn transport_caps_at_96k_whole_and_refuses_more_without_reading() {
        let body = vec![b'{'; BODY_LIMIT];
        let t = read_once("{}", |_, out| {
            out[..BODY_LIMIT].copy_from_slice(&body);
            BODY_LIMIT
        })
        .unwrap();
        match t {
            Transport::Body(text) => assert_eq!(text.len(), BODY_LIMIT),
            other => panic!("expected the whole body, got {other:?}"),
        }

        let too_large = read_once("{}", |_, _| BODY_LIMIT + 1).unwrap_err();
        assert_eq!(too_large, TransportError::TooLarge);
    }

    #[test]
    fn transport_refuses_bytes_that_are_not_utf8() {
        let err = read_once("{}", |_, out| {
            out[0] = 0xff;
            1
        })
        .unwrap_err();
        assert_eq!(err, TransportError::MalformedUtf8);
    }

    #[test]
    fn a_missing_export_is_unsupported_and_calls_nothing() {
        let err = ask_with(None, std::ptr::null_mut(), "{}").unwrap_err();
        assert_eq!(err, TransportError::Unsupported);
    }

    #[test]
    fn requests_are_named_shapes_and_never_hand_built_json() {
        let live = Request::Live {
            group: "a\"b\\c\n群".to_owned(),
            since: 9_007_199_254_740_993, // > 2^53
        }
        .encode()
        .unwrap();
        let value: Value = serde_json::from_str(&live).unwrap();
        assert_eq!(value["method"], "group_read");
        assert_eq!(value["params"]["group"], "a\"b\\c\n群");
        assert_eq!(
            value["params"]["since"].as_u64(),
            Some(9_007_199_254_740_993)
        );

        let begin = Request::Begin {
            group: "g".to_owned(),
            request_id: "r".to_owned(),
            limit: 50,
            resume_token: None,
        }
        .encode()
        .unwrap();
        let value: Value = serde_json::from_str(&begin).unwrap();
        assert_eq!(value["method"], "chat_history_begin");
        assert!(value["params"].get("resume_token").is_none());

        let poll = Request::Poll { job_id: id() }.encode().unwrap();
        let value: Value = serde_json::from_str(&poll).unwrap();
        assert_eq!(value["method"], "chat_history_poll");
        assert_eq!(value["params"]["job_id"], id());

        let cancel = Request::Cancel { job_id: id() }.encode().unwrap();
        let value: Value = serde_json::from_str(&cancel).unwrap();
        assert_eq!(value["method"], "chat_history_cancel");
    }

    #[test]
    fn request_bounds_are_enforced_before_anything_is_sent() {
        let long = "r".repeat(REQUEST_ID_LIMIT + 1);
        assert_eq!(
            Request::Begin {
                group: "g".to_owned(),
                request_id: long,
                limit: 1,
                resume_token: None
            }
            .encode()
            .unwrap_err(),
            RequestError::RequestIdTooLong
        );
        assert_eq!(
            Request::Begin {
                group: "g".to_owned(),
                request_id: String::new(),
                limit: 1,
                resume_token: None
            }
            .encode()
            .unwrap_err(),
            RequestError::EmptyRequestId
        );
        assert_eq!(
            Request::Begin {
                group: "g".to_owned(),
                request_id: "r".to_owned(),
                limit: 0,
                resume_token: None
            }
            .encode()
            .unwrap_err(),
            RequestError::BadLimit
        );
        assert_eq!(
            Request::Poll {
                job_id: "ABC".to_owned()
            }
            .encode()
            .unwrap_err(),
            RequestError::BadJobId
        );
        assert_eq!(
            Request::Begin {
                group: "g".to_owned(),
                request_id: "r".to_owned(),
                limit: 1,
                resume_token: Some("XYZ".to_owned())
            }
            .encode()
            .unwrap_err(),
            RequestError::BadResumeToken
        );
    }

    #[test]
    fn live_keeps_u64_beyond_two_to_the_53() {
        let text = format!(
            r#"{{"ok":true,"group":"g","session":"s","cursor":9007199254740993,"since":9007199254740993,"next":9007199254740995,"more":false,"messages":[{}]}}"#,
            message_json()
        );
        let LiveOutcome::Batch(batch) = decode_live(&text).unwrap() else {
            panic!("expected a batch");
        };
        assert_eq!(batch.cursor, 9_007_199_254_740_993);
        assert_eq!(batch.next, 9_007_199_254_740_995);
        assert_eq!(batch.messages.len(), 1);
        assert_eq!(batch.messages[0].anchor, "p:9");
    }

    #[test]
    fn mentions_missing_and_explicitly_empty_are_not_folded() {
        let base = message_json();
        let missing = base.replace(r#""mentions":[],"role":"""#, r#""role":"""#);
        let text = format!(
            r#"{{"ok":true,"group":"g","session":"s","cursor":0,"since":0,"next":0,"more":false,"messages":[{missing}]}}"#
        );
        let LiveOutcome::Batch(batch) = decode_live(&text).unwrap() else {
            panic!("expected a batch");
        };
        assert_eq!(batch.messages[0].mentions, None);

        let empty = format!(
            r#"{{"ok":true,"group":"g","session":"s","cursor":0,"since":0,"next":0,"more":false,"messages":[{}]}}"#,
            message_json()
        );
        let LiveOutcome::Batch(batch) = decode_live(&empty).unwrap() else {
            panic!("expected a batch");
        };
        assert_eq!(batch.messages[0].mentions, Some(vec![]));
        assert_eq!(batch.messages[0].role.as_deref(), Some(""));
    }

    #[test]
    fn a_begin_is_not_a_poll_pending_and_a_poll_pending_is_not_a_begin() {
        let begin = format!(
            r#"{{"ok":true,"state":"pending","job_id":"{id}","group":"g","session":"s","live_since":1,"history_upper":2,"live_snapshot":[]}}"#,
            id = id()
        );
        assert!(matches!(
            decode_begin(&begin).unwrap(),
            BeginOutcome::Started(_)
        ));

        // A poll's pending reply is not a begin: no snapshot, no water
        // marks.
        let pending = format!(
            r#"{{"ok":true,"state":"pending","job_id":"{id}","group":"g","session":"s"}}"#,
            id = id()
        );
        assert!(matches!(
            decode_poll(&pending).unwrap(),
            PollOutcome::Pending(_)
        ));
        assert_eq!(decode_begin(&pending), Err(Malformed));
    }

    fn ready(stop: &str, token: Option<&str>) -> String {
        let token = match token {
            None => "null".to_owned(),
            Some(t) => format!("\"{t}\""),
        };
        format!(
            r#"{{"ok":true,"state":"ready","job_id":"{id}","group":"g","session":"s","messages":[],"stop":"{stop}","next_token":{token},"restarted":false,"gap":false}}"#,
            id = id()
        )
    }

    #[test]
    fn ready_pages_require_a_resume_point_that_agrees_with_the_stop() {
        for (stop, token) in [
            ("at_end", None),
            ("full", Some(good())),
            ("budget", Some(good())),
            ("gap", None),
            ("gap", Some(good())),
        ] {
            let text = ready(stop, token.as_deref());
            assert!(
                matches!(decode_poll(&text).unwrap(), PollOutcome::Ready(_)),
                "stop={stop} token={token:?} should be a page"
            );
        }
        // Disagreements, and a missing key, are malformed.
        assert_eq!(
            decode_poll(&ready("at_end", Some(good().as_str()))),
            Err(Malformed)
        );
        assert_eq!(decode_poll(&ready("full", None)), Err(Malformed));
        assert_eq!(decode_poll(&ready("budget", None)), Err(Malformed));
        let missing = ready("at_end", None).replace(r#""next_token":null"#, r#""unused":null"#);
        assert_eq!(decode_poll(&missing), Err(Malformed));
        assert_eq!(decode_poll(&ready("sideways", None)), Err(Malformed));
    }

    #[test]
    fn cancel_accepts_cancelled_or_a_failure_and_never_a_page() {
        let cancelled = format!(
            r#"{{"ok":true,"state":"cancelled","job_id":"{id}","group":"g","session":"s"}}"#,
            id = id()
        );
        assert!(matches!(
            decode_cancel(&cancelled).unwrap(),
            CancelOutcome::Cancelled(_)
        ));
        assert_eq!(decode_cancel(&ready("at_end", None)), Err(Malformed));

        let refused = r#"{"error":"NoSuchJob"}"#;
        let CancelOutcome::Failed(failure) = decode_cancel(refused).unwrap() else {
            panic!("expected a refusal");
        };
        assert_eq!(failure.error, "NoSuchJob");
        assert_eq!(failure.job_id, None);
    }

    #[test]
    fn errors_are_read_before_states_and_keep_unknown_codes() {
        let too_large = format!(
            r#"{{"ok":false,"error":"TooLarge","job_id":"{id}","group":"g","session":"s","next_token":"{token}"}}"#,
            id = id(),
            token = good()
        );
        let PollOutcome::Failed(failure) = decode_poll(&too_large).unwrap() else {
            panic!("expected a failure");
        };
        assert_eq!(failure.error, "TooLarge");
        assert_eq!(failure.next_token.as_deref(), Some(good().as_str()));

        let odd = r#"{"ok":false,"error":"SomethingNew"}"#;
        let BeginOutcome::Failed(failure) = decode_begin(odd).unwrap() else {
            panic!("expected a failure");
        };
        assert_eq!(failure.error, "SomethingNew");

        // An error and a success in one reply is not a success.
        let both = format!(
            r#"{{"ok":true,"error":"Busy","state":"pending","job_id":"{id}","group":"g","session":"s"}}"#,
            id = id()
        );
        assert_eq!(decode_poll(&both), Err(Malformed));
    }

    #[test]
    fn malformed_fields_are_not_an_empty_chat() {
        // A float where a u64 belongs.
        let float = r#"{"ok":true,"group":"g","session":"s","cursor":1.5,"since":0,"next":0,"more":false,"messages":[]}"#;
        assert_eq!(decode_live(float), Err(Malformed));
        // A missing required message field.
        let missing = r#"{"ok":true,"group":"g","session":"s","cursor":0,"since":0,"next":0,"more":false,"messages":[{"seq":0}]}"#;
        assert_eq!(decode_live(missing), Err(Malformed));
        // An unknown success state.
        let unknown = format!(
            r#"{{"ok":true,"state":"later","job_id":"{id}","group":"g","session":"s"}}"#,
            id = id()
        );
        assert_eq!(decode_poll(&unknown), Err(Malformed));
    }
}
