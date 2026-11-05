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
/// A new method's `group`, in UTF-8 bytes (root contract v1). The legacy
/// `group_read` keeps its old, unchecked shape.
pub const GROUP_LIMIT: usize = 256;
/// An anchor's bound, in UTF-8 bytes. Opaque: never parsed here.
pub const ANCHOR_LIMIT: usize = 512;
/// A whole request body's bound, in UTF-8 bytes.
pub const REQUEST_LIMIT: usize = 16 * 1024;
/// A file reference's raw Markdown text, in UTF-8 bytes.
pub const REFERENCE_LIMIT: usize = 4096;
/// The most members `chat_metadata` may list, per the frozen contract.
pub const MEMBERS_LIMIT: usize = 200;
/// A search query, after trimming, in UTF-8 bytes.
pub const QUERY_LIMIT: usize = 256;
/// A hit's snippet, in UTF-8 bytes, and its ranges.
pub const SNIPPET_LIMIT: usize = 512;
pub const RANGES_LIMIT: usize = 32;
/// An around request's neighbours on each side.
pub const AROUND_LIMIT: u8 = 99;

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
    /// The group's brief and members, in memory, no writes and no seen.
    Metadata {
        group: String,
    },
    Begin {
        group: String,
        request_id: String,
        limit: u16,
        resume_token: Option<String>,
    },
    /// `mode:"context"`: the next page of one direction of an `around`
    /// result. **The token is the whole question**; no anchor, query or
    /// direction is sent beside it.
    ///
    /// **Not the ordinary history continuation.** A history page's
    /// `next_token` is asked for with `Request::Begin` and its
    /// `resume_token`, the shape every core already serves.
    ContextBegin {
        group: String,
        request_id: String,
        resume_token: String,
        limit: u16,
    },
    /// `mode:"around"`: a target and its immediate visible neighbours.
    AroundBegin {
        group: String,
        request_id: String,
        anchor: String,
        /// The target message's own core hint, passed through unchanged.
        /// Around may carry it; history/context may not.
        location: Option<String>,
        before: u8,
        after: u8,
    },
    /// `mode:"reference"`: the source message and the exact reference text
    /// a file click was made from.
    ReferenceBegin {
        group: String,
        request_id: String,
        anchor: String,
        /// The source message's core hint, passed through unchanged.
        location: Option<String>,
        original_reference: String,
    },
    /// A literal substring search over the stored raw Markdown.
    SearchBegin {
        group: String,
        request_id: String,
        query: String,
        limit: u16,
        resume_token: Option<String>,
    },
    Poll {
        job_id: String,
    },
    Cancel {
        job_id: String,
    },
    SearchPoll {
        job_id: String,
    },
    SearchCancel {
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
    BadGroup,
    BadAnchor,
    BadQuery,
    BadReference,
    BadAround,
    TooLong,
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
            Request::Metadata { group } => {
                check_new_group(group)?;
                params.insert("group".into(), Value::String(group.clone()));
                "chat_metadata"
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
            Request::ContextBegin {
                group,
                request_id,
                resume_token,
                limit,
            } => {
                check_new_group(group)?;
                check_request_id(request_id)?;
                if *limit < LIMIT_RANGE.0 || *limit > LIMIT_RANGE.1 {
                    return Err(RequestError::BadLimit);
                }
                if !is_opaque_id(resume_token) {
                    return Err(RequestError::BadResumeToken);
                }
                params.insert("mode".into(), Value::String("context".into()));
                params.insert("group".into(), Value::String(group.clone()));
                params.insert("request_id".into(), Value::String(request_id.clone()));
                params.insert("resume_token".into(), Value::String(resume_token.clone()));
                params.insert("limit".into(), Value::from(*limit));
                "chat_history_begin"
            }
            Request::AroundBegin {
                group,
                request_id,
                anchor,
                location,
                before,
                after,
            } => {
                check_new_group(group)?;
                check_request_id(request_id)?;
                check_anchor(anchor)?;
                if *before > AROUND_LIMIT || *after > AROUND_LIMIT {
                    return Err(RequestError::BadAround);
                }
                params.insert("mode".into(), Value::String("around".into()));
                params.insert("group".into(), Value::String(group.clone()));
                params.insert("request_id".into(), Value::String(request_id.clone()));
                params.insert("anchor".into(), Value::String(anchor.clone()));
                if let Some(location) = location {
                    check_anchor(location)?;
                    params.insert("location".into(), Value::String(location.clone()));
                }
                params.insert("before".into(), Value::from(*before));
                params.insert("after".into(), Value::from(*after));
                "chat_history_begin"
            }
            Request::ReferenceBegin {
                group,
                request_id,
                anchor,
                location,
                original_reference,
            } => {
                check_new_group(group)?;
                check_request_id(request_id)?;
                check_anchor(anchor)?;
                if original_reference.is_empty() || original_reference.len() > REFERENCE_LIMIT {
                    return Err(RequestError::BadReference);
                }
                params.insert("mode".into(), Value::String("reference".into()));
                params.insert("group".into(), Value::String(group.clone()));
                params.insert("request_id".into(), Value::String(request_id.clone()));
                params.insert("anchor".into(), Value::String(anchor.clone()));
                if let Some(location) = location {
                    check_anchor(location)?;
                    params.insert("location".into(), Value::String(location.clone()));
                }
                params.insert(
                    "original_reference".into(),
                    Value::String(original_reference.clone()),
                );
                "chat_history_begin"
            }
            Request::SearchBegin {
                group,
                request_id,
                query,
                limit,
                resume_token,
            } => {
                check_new_group(group)?;
                check_request_id(request_id)?;
                if *limit < LIMIT_RANGE.0 || *limit > LIMIT_RANGE.1 {
                    return Err(RequestError::BadLimit);
                }
                let query = trim_query(query);
                if query.is_empty() || query.len() > QUERY_LIMIT {
                    return Err(RequestError::BadQuery);
                }
                if let Some(token) = resume_token {
                    if !is_opaque_id(token) {
                        return Err(RequestError::BadResumeToken);
                    }
                }
                params.insert("group".into(), Value::String(group.clone()));
                params.insert("request_id".into(), Value::String(request_id.clone()));
                params.insert("query".into(), Value::String(query.to_owned()));
                params.insert("limit".into(), Value::from(*limit));
                if let Some(token) = resume_token {
                    params.insert("resume_token".into(), Value::String(token.clone()));
                }
                "chat_search_begin"
            }
            Request::Poll { job_id } => {
                if !is_opaque_id(job_id) {
                    return Err(RequestError::BadJobId);
                }
                params.insert("job_id".into(), Value::String(job_id.clone()));
                "chat_history_poll"
            }
            Request::SearchPoll { job_id } => {
                if !is_opaque_id(job_id) {
                    return Err(RequestError::BadJobId);
                }
                params.insert("job_id".into(), Value::String(job_id.clone()));
                "chat_search_poll"
            }
            Request::SearchCancel { job_id } => {
                if !is_opaque_id(job_id) {
                    return Err(RequestError::BadJobId);
                }
                params.insert("job_id".into(), Value::String(job_id.clone()));
                "chat_search_cancel"
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
        let encoded =
            serde_json::to_string(&Value::Object(body)).map_err(|_| RequestError::Encode)?;
        if encoded.len() > REQUEST_LIMIT {
            return Err(RequestError::TooLong);
        }
        Ok(encoded)
    }
}

/// A new method's group: 1..=256 UTF-8 bytes. The legacy live read is not
/// put through this -- its accepted shape stays exactly what it was.
fn check_new_group(group: &str) -> Result<(), RequestError> {
    if group.is_empty() || group.len() > GROUP_LIMIT {
        return Err(RequestError::BadGroup);
    }
    Ok(())
}

fn check_request_id(request_id: &str) -> Result<(), RequestError> {
    if request_id.is_empty() {
        return Err(RequestError::EmptyRequestId);
    }
    if request_id.len() > REQUEST_ID_LIMIT {
        return Err(RequestError::RequestIdTooLong);
    }
    Ok(())
}

/// The search query's ASCII whitespace trim, exactly the frozen rule:
/// HT, LF, VT, FF, CR and SPACE at either end. **Not** Unicode whitespace.
pub fn trim_query(query: &str) -> &str {
    query.trim_matches(|c| matches!(c, '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' '))
}

/// An anchor is opaque: the only thing this host may know is its bound.
pub fn check_anchor(anchor: &str) -> Result<(), RequestError> {
    if anchor.is_empty() || anchor.len() > ANCHOR_LIMIT {
        return Err(RequestError::BadAnchor);
    }
    Ok(())
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
    /// The core's opaque locator hint (`Root location supplement`). Kept
    /// **verbatim**: this host never parses it, derives it or puts a token
    /// of its own in its place. `None` means "this record carried none".
    pub location: Option<String>,
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

/// Which way a `context` page went. The core names it; this host never
/// infers it from the rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Older,
    Newer,
}

/// One `mode:"context"` page: the ordered records in the direction the
/// resume token named, and the token that continues that same direction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextPage {
    pub job_id: String,
    pub group: String,
    pub session: String,
    pub direction: Direction,
    pub messages: Vec<Message>,
    /// **Both directions travel with every page**; the response names the
    /// page's own two edges, not a generic `next_token`.
    pub older_token: Option<String>,
    pub newer_token: Option<String>,
    pub older_at_end: bool,
    pub newer_at_end: bool,
    pub stop: Stop,
    pub restarted: bool,
    pub gap: bool,
}

/// One member as `chat_metadata` names it. `role` is absent for a member
/// the core did not describe; an empty role is a different fact.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Member {
    pub id: String,
    pub title: String,
    pub role: Option<String>,
}

/// A group's brief and members. **A bounded list**: `member_count` is the
/// true number even when `members_truncated` says the list was cut.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Metadata {
    pub group: String,
    pub brief: String,
    pub members: Vec<Member>,
    pub member_count: u32,
    pub members_truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MetadataOutcome {
    Data(Metadata),
    Failed(Failure),
}

/// One `mode:"around"` page: the target's index in `messages` (the core's
/// actual index, never assumed) and the two direction cursors.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AroundPage {
    pub job_id: String,
    pub group: String,
    pub session: String,
    pub messages: Vec<Message>,
    pub target_index: usize,
    pub older_token: Option<String>,
    pub newer_token: Option<String>,
    pub older_at_end: bool,
    pub newer_at_end: bool,
    /// A gap/restart in the around range; a direction at an end with one
    /// of these is not complete.
    pub gap: bool,
    pub restarted: bool,
}

/// One `mode:"reference"` page. `file_open` is the exact existing
/// `files_open` ticket/preview-descriptor object, kept whole so the host
/// never rebuilds it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReferencePage {
    pub job_id: String,
    pub group: String,
    pub session: String,
    pub source_anchor: String,
    /// The live identity the core verified for that source, if any. **A
    /// request anchor may equal this after a promotion**; the host never
    /// builds one itself.
    pub source_live_anchor: Option<String>,
    pub source_location: Option<String>,
    pub original_reference: String,
    pub file_open: Value,
}

/// Whether `token` has the ticket shape the core mints: 32 lower-case hex
/// (`polter_preview_route::is_token`, the same rule the preview route
/// applies). **One rule for every `file_open.token` the host handles**,
/// whether the page decoded completely or only conservatively.
pub fn is_ticket(token: &str) -> bool {
    polter_preview_route::is_token(token)
}

/// The ticket a decoded reference page carries, if it has the shape the
/// core mints. A token that cannot be one is not treated as a capability.
pub fn ticket_of(page: &ReferencePage) -> Option<String> {
    let token = page.file_open.get("token")?.as_str()?;
    is_ticket(token).then(|| token.to_owned())
}

/// The ticket a ready reference page minted, read **conservatively** from
/// the JSON even when the full page fails validation (a missing
/// `live_anchor`/`location`, a wrong field type). A minted ticket is a
/// capability the host must hand back, and its cleanup must not depend on
/// the rest of the page being well-formed.
///
/// **It never guesses one**: `mode` must say `reference`, `file_open` must be
/// an object and its `token` must have the ticket's exact shape. The same
/// check applies when the page decodes completely (`ticket_of`); a decoder
/// that trusts any string would be the bypass this closes.
pub fn reference_ticket(text: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(text).ok()?;
    if value.get("mode").and_then(|m| m.as_str()) != Some("reference") {
        return None;
    }
    let token = value.get("file_open")?.get("token")?.as_str()?;
    is_ticket(token).then(|| token.to_owned())
}

/// One hit: the full message (identity and metadata) plus the display
/// snippet and the **UTF-8 byte ranges relative to the snippet**.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HitRange {
    pub start: u32,
    pub end: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hit {
    pub message: Message,
    pub snippet: String,
    pub snippet_start: u32,
    pub ranges: Vec<HitRange>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchStatus {
    pub job_id: String,
    pub group: String,
    pub session: String,
    /// The canonical query the core echoed, not the text typed.
    pub query: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchPage {
    pub job_id: String,
    pub group: String,
    pub session: String,
    pub query: String,
    pub results: Vec<Hit>,
    pub stop: Stop,
    pub next_token: Option<String>,
    pub restarted: bool,
    pub gap: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchBeginOutcome {
    Started(SearchStatus),
    Failed(Failure),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchPollOutcome {
    Pending(SearchStatus),
    Cancelled(Status),
    Ready(SearchPage),
    Failed(Failure),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchCancelOutcome {
    Cancelled(Status),
    Failed(Failure),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveOutcome {
    Batch(LiveBatch),
    Failed(Failure),
}

/// The identity a non-history begin (`context`, `around`, `reference`)
/// answers with. These modes carry no live snapshot or water marks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuxStart {
    pub job_id: String,
    pub group: String,
    pub session: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BeginOutcome {
    Started(BeginPage),
    Failed(Failure),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuxBeginOutcome {
    Started(AuxStart),
    Failed(Failure),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PollOutcome {
    Pending(Status),
    Cancelled(Status),
    Ready(ReadyPage),
    ReadyContext(ContextPage),
    ReadyAround(AroundPage),
    ReadyReference(ReferencePage),
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

/// The key must be there and its value is a string or `null`. **`null` is
/// the core's answer "none"; a missing key is a page that never answered**,
/// and the two are different facts -- the frozen reference source always
/// spells `live_anchor` and `location`, even when it has neither.
fn nullable_string(o: &Map<String, Value>, key: &str) -> Result<Option<String>, Malformed> {
    match o.get(key) {
        Some(Value::Null) => Ok(None),
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

fn optional_bool(o: &Map<String, Value>, key: &str) -> Result<bool, Malformed> {
    match o.get(key) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(b)) => Ok(*b),
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

/// The key must be there; its value is a cursor or `null`. **Both
/// directional cursors are part of the frozen around/context shape**, so a
/// page that omits one never answered that shape -- missing is not "no
/// cursor" the way an explicit `null` is.
fn nullable_opaque(o: &Map<String, Value>, key: &str) -> Result<Option<String>, Malformed> {
    match o.get(key) {
        Some(Value::Null) => Ok(None),
        Some(Value::String(text)) if is_opaque_id(text) => Ok(Some(text.clone())),
        _ => Err(Malformed),
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
        location: optional_string(o, "location")?,
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
    stop_agrees_with(page.stop, page.next_token.as_deref())
}

fn stop_agrees_with(stop: Stop, next_token: Option<&str>) -> bool {
    match stop {
        Stop::AtEnd => next_token.is_none(),
        Stop::Full | Stop::Budget => next_token.map_or(false, |t| !t.is_empty()),
        Stop::Gap => next_token.map_or(true, |t| !t.is_empty()),
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

/// `chat_metadata`: the brief and the bounded member list.
pub fn decode_metadata(text: &str) -> Result<MetadataOutcome, Malformed> {
    let value = parse(text)?;
    let o = object(&value)?;
    let o = match head(o)? {
        Head::Failure(f) => return Ok(MetadataOutcome::Failed(f)),
        Head::Ok(o) => o,
    };
    let items = match o.get("members") {
        Some(Value::Array(items)) => items,
        _ => return Err(Malformed),
    };
    if items.len() > MEMBERS_LIMIT {
        return Err(Malformed);
    }
    let mut members = Vec::with_capacity(items.len());
    for item in items {
        let m = object(item)?;
        members.push(Member {
            id: required_string(m, "id")?,
            title: required_string(m, "title")?,
            role: optional_string(m, "role")?,
        });
    }
    let count = required_u64(o, "member_count")?;
    let member_count = u32::try_from(count).map_err(|_| Malformed)?;
    Ok(MetadataOutcome::Data(Metadata {
        group: required_string(o, "group")?,
        brief: required_string(o, "brief")?,
        members,
        member_count,
        members_truncated: required_bool(o, "members_truncated")?,
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

/// A `context`/`around`/`reference` begin: `state:"pending"` and the job's
/// identity, no snapshot and no water marks.
pub fn decode_aux_begin(text: &str) -> Result<AuxBeginOutcome, Malformed> {
    let value = parse(text)?;
    let o = object(&value)?;
    let o = match head(o)? {
        Head::Failure(f) => return Ok(AuxBeginOutcome::Failed(f)),
        Head::Ok(o) => o,
    };
    if state(o)? != "pending" {
        return Err(Malformed);
    }
    Ok(AuxBeginOutcome::Started(AuxStart {
        job_id: opaque_required(o, "job_id")?,
        group: required_string(o, "group")?,
        session: required_string(o, "session")?,
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
            // A legacy history page omits `mode`; that means history. The
            // new modes name themselves, and an unknown one is not a page.
            let mode = match o.get("mode") {
                None => "history",
                Some(Value::String(s)) => s.as_str(),
                Some(_) => return Err(Malformed),
            };
            let job_id = opaque_required(o, "job_id")?;
            let group = required_string(o, "group")?;
            let session = required_string(o, "session")?;
            match mode {
                "around" => {
                    let messages = messages(o, "messages")?;
                    let target = required_u64(o, "target_index")?;
                    let target_index = usize::try_from(target).map_err(|_| Malformed)?;
                    if target_index >= messages.len() {
                        return Err(Malformed);
                    }
                    Ok(PollOutcome::ReadyAround(AroundPage {
                        job_id,
                        group,
                        session,
                        messages,
                        target_index,
                        older_token: nullable_opaque(o, "older_token")?,
                        newer_token: nullable_opaque(o, "newer_token")?,
                        older_at_end: required_bool(o, "older_at_end")?,
                        newer_at_end: required_bool(o, "newer_at_end")?,
                        gap: optional_bool(o, "gap")?,
                        restarted: optional_bool(o, "restarted")?,
                    }))
                }
                "reference" => {
                    let source = match o.get("source") {
                        Some(value) => object(value)?,
                        _ => return Err(Malformed),
                    };
                    let file_open = match o.get("file_open") {
                        Some(value @ Value::Object(_)) => value.clone(),
                        _ => return Err(Malformed),
                    };
                    Ok(PollOutcome::ReadyReference(ReferencePage {
                        job_id,
                        group,
                        session,
                        source_anchor: required_string(source, "anchor")?,
                        source_live_anchor: nullable_string(source, "live_anchor")?,
                        source_location: nullable_string(source, "location")?,
                        original_reference: required_string(source, "original_reference")?,
                        file_open,
                    }))
                }
                "history" | "context" => {
                    let stop = stop(required_string(o, "stop")?.as_str()).ok_or(Malformed)?;
                    let messages = messages(o, "messages")?;
                    let restarted = required_bool(o, "restarted")?;
                    let gap = required_bool(o, "gap")?;
                    if mode == "history" {
                        // The key must be there even when its value is
                        // null; a page that never said whether it can be
                        // resumed is not a page that ended.
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
                            job_id,
                            group,
                            session,
                            messages,
                            stop,
                            next_token,
                            restarted,
                            gap,
                        };
                        if !resumable(&page) {
                            return Err(Malformed);
                        }
                        Ok(PollOutcome::Ready(page))
                    } else {
                        let direction = match required_string(o, "direction")?.as_str() {
                            "older" => Direction::Older,
                            "newer" => Direction::Newer,
                            _ => return Err(Malformed),
                        };
                        // **No generic `next_token` here**: the page names
                        // both of its own edges.
                        Ok(PollOutcome::ReadyContext(ContextPage {
                            job_id,
                            group,
                            session,
                            direction,
                            messages,
                            older_token: nullable_opaque(o, "older_token")?,
                            newer_token: nullable_opaque(o, "newer_token")?,
                            older_at_end: required_bool(o, "older_at_end")?,
                            newer_at_end: required_bool(o, "newer_at_end")?,
                            stop,
                            restarted,
                            gap,
                        }))
                    }
                }
                _ => Err(Malformed),
            }
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

/// `chat_search_begin`: pending, with the canonical query echoed.
pub fn decode_search_begin(text: &str) -> Result<SearchBeginOutcome, Malformed> {
    let value = parse(text)?;
    let o = object(&value)?;
    let o = match head(o)? {
        Head::Failure(f) => return Ok(SearchBeginOutcome::Failed(f)),
        Head::Ok(o) => o,
    };
    if state(o)? != "pending" {
        return Err(Malformed);
    }
    Ok(SearchBeginOutcome::Started(SearchStatus {
        job_id: opaque_required(o, "job_id")?,
        group: required_string(o, "group")?,
        session: required_string(o, "session")?,
        query: required_string(o, "query")?,
    }))
}

fn hit_range(value: &Value) -> Result<HitRange, Malformed> {
    let o = object(value)?;
    let start = u32::try_from(required_u64(o, "start")?).map_err(|_| Malformed)?;
    let end = u32::try_from(required_u64(o, "end")?).map_err(|_| Malformed)?;
    Ok(HitRange { start, end })
}

fn hit(value: &Value) -> Result<Hit, Malformed> {
    let o = object(value)?;
    let message_value = o.get("message").ok_or(Malformed)?;
    let message = message(message_value)?;
    let snippet = required_string(o, "snippet")?;
    if snippet.len() > SNIPPET_LIMIT {
        return Err(Malformed);
    }
    let snippet_start = u32::try_from(required_u64(o, "snippet_start")?).map_err(|_| Malformed)?;
    // **The snippet is an exact substring of the stored text**, at UTF-8
    // byte offsets: a snippet that does not match says the core and this
    // host disagree about the source, which is not a hit.
    let start = snippet_start as usize;
    let end = start.checked_add(snippet.len()).ok_or(Malformed)?;
    if end > message.text.len()
        || !message.text.is_char_boundary(start)
        || !message.text.is_char_boundary(end)
        || message.text.get(start..end) != Some(snippet.as_str())
    {
        return Err(Malformed);
    }
    let items = match o.get("ranges") {
        Some(Value::Array(items)) => items,
        _ => return Err(Malformed),
    };
    if items.len() > RANGES_LIMIT {
        return Err(Malformed);
    }
    let mut ranges = Vec::with_capacity(items.len());
    let mut previous_end = 0u32;
    for item in items {
        let range = hit_range(item)?;
        if range.start > range.end
            || range.end as usize > snippet.len()
            || range.start < previous_end
            || !snippet.is_char_boundary(range.start as usize)
            || !snippet.is_char_boundary(range.end as usize)
        {
            return Err(Malformed);
        }
        previous_end = range.end;
        ranges.push(range);
    }
    Ok(Hit {
        message,
        snippet,
        snippet_start,
        ranges,
    })
}

/// `chat_search_poll`: pending (with the query), cancelled, or a page.
pub fn decode_search_poll(text: &str) -> Result<SearchPollOutcome, Malformed> {
    let value = parse(text)?;
    let o = object(&value)?;
    let o = match head(o)? {
        Head::Failure(f) => return Ok(SearchPollOutcome::Failed(f)),
        Head::Ok(o) => o,
    };
    match state(o)? {
        "pending" => Ok(SearchPollOutcome::Pending(SearchStatus {
            job_id: opaque_required(o, "job_id")?,
            group: required_string(o, "group")?,
            session: required_string(o, "session")?,
            query: required_string(o, "query")?,
        })),
        "cancelled" => Ok(SearchPollOutcome::Cancelled(status(o)?)),
        "ready" => {
            let stop = stop(required_string(o, "stop")?.as_str()).ok_or(Malformed)?;
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
            let page = SearchPage {
                job_id: opaque_required(o, "job_id")?,
                group: required_string(o, "group")?,
                session: required_string(o, "session")?,
                query: required_string(o, "query")?,
                results: match o.get("results") {
                    Some(Value::Array(items)) => {
                        let mut out = Vec::with_capacity(items.len());
                        for item in items {
                            out.push(hit(item)?);
                        }
                        out
                    }
                    _ => return Err(Malformed),
                },
                stop,
                next_token,
                restarted: required_bool(o, "restarted")?,
                gap: required_bool(o, "gap")?,
            };
            if !stop_agrees_with(page.stop, page.next_token.as_deref()) {
                return Err(Malformed);
            }
            Ok(SearchPollOutcome::Ready(page))
        }
        _ => Err(Malformed),
    }
}

pub fn decode_search_cancel(text: &str) -> Result<SearchCancelOutcome, Malformed> {
    let value = parse(text)?;
    let o = object(&value)?;
    let o = match head(o)? {
        Head::Failure(f) => return Ok(SearchCancelOutcome::Failed(f)),
        Head::Ok(o) => o,
    };
    if state(o)? != "cancelled" {
        return Err(Malformed);
    }
    Ok(SearchCancelOutcome::Cancelled(status(o)?))
}

// ------------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

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
    fn metadata_is_its_own_named_call_and_keeps_member_count_truthful() {
        let request = Request::Metadata {
            group: "群".to_owned(),
        }
        .encode()
        .unwrap();
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["method"], "chat_metadata");
        assert_eq!(value["params"]["group"], "群");

        let text = r#"{"ok":true,"group":"g","brief":"what for","members":[{"id":"0x1","title":"a","role":null},{"id":"0x2","title":"b","role":"worker"}],"member_count":7,"members_truncated":true}"#;
        let MetadataOutcome::Data(meta) = decode_metadata(&text).unwrap() else {
            panic!("expected metadata");
        };
        assert_eq!(meta.member_count, 7);
        assert!(meta.members_truncated);
        assert_eq!(meta.members.len(), 2);
        assert_eq!(meta.members[0].role, None);
        assert_eq!(meta.members[1].role.as_deref(), Some("worker"));

        // A negative or fractional count is not a count.
        assert_eq!(
            decode_metadata(&text.replace(r#""member_count":7"#, r#""member_count":-1"#)),
            Err(Malformed)
        );
    }

    #[test]
    fn a_context_begin_sends_only_its_token_and_mode() {
        let request = Request::ContextBegin {
            group: "g".to_owned(),
            request_id: "r".to_owned(),
            resume_token: good(),
            limit: 50,
        }
        .encode()
        .unwrap();
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["method"], "chat_history_begin");
        assert_eq!(value["params"]["mode"], "context");
        assert_eq!(value["params"]["resume_token"], good());
        assert_eq!(value["params"]["limit"], 50);
        // The token is the question: no anchor, query or direction.
        assert!(value["params"].get("anchor").is_none());
        assert!(value["params"].get("query").is_none());
        assert!(value["params"].get("before").is_none());

        let bad = Request::ContextBegin {
            group: "g".to_owned(),
            request_id: "r".to_owned(),
            resume_token: "not-a-token".to_owned(),
            limit: 50,
        };
        assert_eq!(bad.encode().unwrap_err(), RequestError::BadResumeToken);
        let empty_group = Request::ContextBegin {
            group: String::new(),
            request_id: "r".to_owned(),
            resume_token: good(),
            limit: 50,
        };
        assert_eq!(empty_group.encode().unwrap_err(), RequestError::BadGroup);
    }

    #[test]
    fn a_context_ready_is_not_a_history_page_and_keeps_its_direction() {
        let text = format!(
            r#"{{"ok":true,"state":"ready","mode":"context","job_id":"{id}","group":"g","session":"s","direction":"older","messages":[],"stop":"budget","older_token":"{token}","newer_token":null,"older_at_end":false,"newer_at_end":true,"restarted":false,"gap":false}}"#,
            id = id(),
            token = good()
        );
        let PollOutcome::ReadyContext(page) = decode_poll(&text).unwrap() else {
            panic!("expected a context page");
        };
        assert_eq!(page.direction, Direction::Older);
        assert_eq!(page.stop, Stop::Budget);
        assert_eq!(page.older_token.as_deref(), Some(good().as_str()));
        assert_eq!(page.newer_token, None);
        assert!(page.newer_at_end);

        // A direction this build does not know is malformed, not newer.
        let sideways = text.replace(r#""direction":"older""#, r#""direction":"sideways""#);
        assert_eq!(decode_poll(&sideways), Err(Malformed));
        // A context page with no direction cursor is still readable; the
        // at_end flags, not a generic token, say each edge.
        let ended = text
            .replace(r#""stop":"budget""#, r#""stop":"at_end""#)
            .replace(
                &format!(r#""older_token":"{}""#, good()),
                r#""older_token":null"#,
            )
            .replace(r#""older_at_end":false"#, r#""older_at_end":true"#);
        let PollOutcome::ReadyContext(page) = decode_poll(&ended).unwrap() else {
            panic!("expected a context page");
        };
        assert_eq!(page.stop, Stop::AtEnd);
        assert_eq!(page.older_token, None);
        assert!(page.older_at_end);

        // **Both cursors are keys of the frozen shape, not optional
        // extras**: missing one is malformed, while an explicit null is a
        // real answer. Same for the around shape.
        for key in ["older_token", "newer_token"] {
            let mut omitted: Value = serde_json::from_str(&text).unwrap();
            omitted.as_object_mut().unwrap().remove(key);
            assert_eq!(decode_poll(&omitted.to_string()), Err(Malformed), "{key} omitted");
            let mut wrong: Value = serde_json::from_str(&text).unwrap();
            wrong[key] = Value::Bool(true);
            assert_eq!(decode_poll(&wrong.to_string()), Err(Malformed), "{key} not string|null");
        }

        // A newer-direction page keeps that edge's own cursor and does not
        // borrow the older one.
        let newer = text.replace(r#""direction":"older""#, r#""direction":"newer""#);
        let PollOutcome::ReadyContext(page) = decode_poll(&newer).unwrap() else {
            panic!("expected a context page");
        };
        assert_eq!(page.direction, Direction::Newer);
        assert_eq!(page.older_token.as_deref(), Some(good().as_str()));
        assert_eq!(page.newer_token, None);
    }

    #[test]
    fn a_location_hint_is_verbatim_and_only_around_and_reference_may_send_it() {
        let with = message_json().replace(
            r#""live_anchor":null"#,
            r#""live_anchor":null,"location":"core hint / keep as is""#,
        );
        let text = format!(
            r#"{{"ok":true,"group":"g","session":"s","cursor":0,"since":0,"next":0,"more":false,"messages":[{}]}}"#,
            with
        );
        let LiveOutcome::Batch(batch) = decode_live(&text).unwrap() else {
            panic!("expected a batch");
        };
        assert_eq!(
            batch.messages[0].location.as_deref(),
            Some("core hint / keep as is")
        );
        // Missing is not an empty hint.
        let text = format!(
            r#"{{"ok":true,"group":"g","session":"s","cursor":0,"since":0,"next":0,"more":false,"messages":[{}]}}"#,
            message_json()
        );
        let LiveOutcome::Batch(batch) = decode_live(&text).unwrap() else {
            panic!("expected a batch");
        };
        assert_eq!(batch.messages[0].location, None);

        let around = Request::AroundBegin {
            group: "g".to_owned(),
            request_id: "r".to_owned(),
            anchor: "p:9".to_owned(),
            location: Some("hint".to_owned()),
            before: 2,
            after: 3,
        }
        .encode()
        .unwrap();
        let value: Value = serde_json::from_str(&around).unwrap();
        assert_eq!(value["params"]["mode"], "around");
        assert_eq!(value["params"]["location"], "hint");

        let reference = Request::ReferenceBegin {
            group: "g".to_owned(),
            request_id: "r".to_owned(),
            anchor: "p:9".to_owned(),
            location: Some("hint".to_owned()),
            original_reference: "README.md".to_owned(),
        }
        .encode()
        .unwrap();
        let value: Value = serde_json::from_str(&reference).unwrap();
        assert_eq!(value["params"]["location"], "hint");

        // A context page has no location at all: its token is the whole
        // question.
        let context = Request::ContextBegin {
            group: "g".to_owned(),
            request_id: "r".to_owned(),
            resume_token: good(),
            limit: 50,
        }
        .encode()
        .unwrap();
        let value: Value = serde_json::from_str(&context).unwrap();
        assert!(value["params"].get("location").is_none());
    }

    #[test]
    fn search_begin_trims_only_the_frozen_whitespace_and_echoes_one_query() {
        let request = Request::SearchBegin {
            group: "g".to_owned(),
            request_id: "r".to_owned(),
            query: " \t批量\n ".to_owned(),
            limit: 50,
            resume_token: None,
        }
        .encode()
        .unwrap();
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["method"], "chat_search_begin");
        assert_eq!(value["params"]["query"], "批量");
        assert!(value["params"].get("resume_token").is_none());

        let untrimmed = Request::SearchBegin {
            group: "g".to_owned(),
            request_id: "r".to_owned(),
            query: "   ".to_owned(),
            limit: 50,
            resume_token: None,
        };
        assert_eq!(untrimmed.encode().unwrap_err(), RequestError::BadQuery);
    }

    #[test]
    fn a_search_hit_is_an_exact_substring_and_its_ranges_stay_inside_it() {
        let text = json!({
            "ok": true, "state": "ready", "job_id": id(), "group": "g",
            "session": "s", "query": "hi", "results": [{
                "message": serde_json::from_str::<Value>(message_json()).unwrap(),
                "snippet": "hi", "snippet_start": 0,
                "ranges": [{"start": 0, "end": 2}]
            }],
            "stop": "at_end", "next_token": null,
            "restarted": false, "gap": false
        })
        .to_string();
        let SearchPollOutcome::Ready(page) = decode_search_poll(&text).unwrap() else {
            panic!("expected a search page");
        };
        assert_eq!(page.results.len(), 1);
        assert_eq!(page.results[0].snippet, "hi");
        assert_eq!(page.results[0].ranges[0], HitRange { start: 0, end: 2 });

        // A snippet that is not the text at that offset is not a hit, and
        // a range that runs past the snippet is malformed.
        let wrong = text.replace(r#""snippet":"hi""#, r#""snippet":"ho""#);
        assert_eq!(decode_search_poll(&wrong), Err(Malformed));
        let past = text.replace(r#""end":2"#, r#""end":9"#);
        assert_eq!(decode_search_poll(&past), Err(Malformed));
    }

    #[test]
    fn an_around_page_names_its_target_and_both_directions() {
        let text = json!({
            "ok": true, "state": "ready", "mode": "around", "job_id": id(),
            "group": "g", "session": "s",
            "messages": [serde_json::from_str::<Value>(message_json()).unwrap()],
            "target_index": 0,
            "older_token": good(), "newer_token": null,
            "older_at_end": false, "newer_at_end": true
        })
        .to_string();
        let PollOutcome::ReadyAround(page) = decode_poll(&text).unwrap() else {
            panic!("expected an around page");
        };
        assert_eq!(page.target_index, 0);
        assert_eq!(page.older_token.as_deref(), Some(good().as_str()));
        assert!(page.newer_at_end);
        // An index past the returned messages is not a target.
        let bad = text.replace(r#""target_index":0"#, r#""target_index":1"#);
        assert_eq!(decode_poll(&bad), Err(Malformed));
        // The around shape carries both directional cursors by name.
        for key in ["older_token", "newer_token"] {
            let mut omitted: Value = serde_json::from_str(&text).unwrap();
            omitted.as_object_mut().unwrap().remove(key);
            assert_eq!(decode_poll(&omitted.to_string()), Err(Malformed), "{key} omitted");
        }
    }

    #[test]
    fn a_reference_page_keeps_the_existing_file_open_object_whole() {
        let text = json!({
            "ok": true, "state": "ready", "mode": "reference", "job_id": id(),
            "group": "g", "session": "s",
            "source": {
                "anchor": "p:9", "live_anchor": "l:s:4", "location": "line 3",
                "original_reference": "README.md"
            },
            "file_open": {"ok": true, "ticket": "t", "descriptor": {"kind": "text"}}
        })
        .to_string();
        let PollOutcome::ReadyReference(page) = decode_poll(&text).unwrap() else {
            panic!("expected a reference page");
        };
        assert_eq!(page.source_anchor, "p:9");
        assert_eq!(page.source_live_anchor.as_deref(), Some("l:s:4"));
        assert_eq!(page.source_location.as_deref(), Some("line 3"));
        assert_eq!(page.original_reference, "README.md");
        assert_eq!(page.file_open["descriptor"]["kind"], "text");
        // The two hyphen-null fields are optional in value, **not in key**:
        // a page that omits either never answered the frozen shape.
        for key in ["live_anchor", "location"] {
            let mut omitted: Value = serde_json::from_str(&text).unwrap();
            omitted["source"].as_object_mut().unwrap().remove(key);
            assert_eq!(decode_poll(&omitted.to_string()), Err(Malformed), "{key} omitted");
            let mut wrong: Value = serde_json::from_str(&text).unwrap();
            wrong["source"][key] = Value::Bool(true);
            assert_eq!(decode_poll(&wrong.to_string()), Err(Malformed), "{key} not string|null");
        }
        // Without the ticket object this is not a reference answer.
        let mut missing: Value = serde_json::from_str(&text).unwrap();
        missing["file_open"] = Value::Null;
        assert_eq!(decode_poll(&missing.to_string()), Err(Malformed));
    }

    /// The conservative cleanup reads a ticket only from something that
    /// still says `mode:"reference"` and carries the ticket's exact shape;
    /// it never fishes a `token` out of another page.
    #[test]
    fn a_ticket_is_read_conservatively_only_from_a_reference_page() {
        let ok = json!({
            "mode": "reference",
            "file_open": {"token": "0123456789abcdef0123456789abcdef"}
        })
        .to_string();
        assert_eq!(
            reference_ticket(&ok).as_deref(),
            Some("0123456789abcdef0123456789abcdef")
        );
        for text in [
            json!({"file_open": {"token": "0123456789abcdef0123456789abcdef"}}).to_string(),
            json!({"mode": "history", "file_open": {"token": "0123456789abcdef0123456789abcdef"}}).to_string(),
            json!({"mode": "reference", "file_open": {"token": "short"}}).to_string(),
            json!({"mode": "reference", "file_open": {"token": 7}}).to_string(),
            json!({"mode": "reference", "file_open": {"token": "9F2C0A1B4D5E6F708192A3B4C5D6E7F8"}}).to_string(),
        ] {
            assert_eq!(reference_ticket(&text), None, "{text}");
        }
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
