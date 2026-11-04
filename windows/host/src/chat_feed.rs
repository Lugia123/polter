//! One group's read-only chat, as the Windows host will drive it (task
//! 2802, W2a).
//!
//! **The data owner and nothing else.** This is the state machine the
//! native page will use: one feed per group, a bounded window of rows with
//! stable identities, one history job at a time, and named actions the
//! host carries out. It holds no `App`, no window handle, no raw pointer,
//! no thread, no timer and no global. The group page's visibility, the
//! clock and a fresh request id are handed in by the host; replies come
//! back through `accept_*`, which checks the generation, the group and the
//! kind before anything is applied.
//!
//! **W2a is not wired to the UI.** Nothing here replaces the old
//! `polter +chat` page, and neither `chat_page`, `control_room` nor `tabs`
//! mention it. The Win32 lifecycle is a later contract; this module only
//! produces the actions that lifecycle will run.
//!
//! The history contract is mac's (`NATIVE-HISTORY-CONTRACT`,
//! `2800-C2A-FIRST-SCREEN.md`): a begin is a snapshot, a poll's pending is
//! not empty, a ready page goes in front of the body, and `live_next` is
//! the group's in-memory `seq` -- never the log's `head`, never a history
//! token.

use std::collections::HashMap;

use crate::chat_read::{
    self, BeginOutcome, Failure, Message, Request, Stop, Transport, TransportError,
};

/// The most rows one feed keeps. Older rows go first.
pub const WINDOW_LIMIT: usize = 500;
/// The text and identity budget those rows may use, in bytes.
pub const WINDOW_BYTES: usize = 4 * 1024 * 1024;

/// How often a visible feed reads live, and how soon it catches up while
/// the core says there is more.
pub const LIVE_PERIOD_MS: u64 = 2_000;
pub const CATCH_UP_MS: u64 = 200;
/// How soon a pending history scan is asked again.
pub const HISTORY_POLL_MS: u64 = 200;

/// The page size a bootstrap asks for.
pub const BEGIN_LIMIT: u16 = 50;

/// What the first screen shows. **`Loading` is not `Empty`**: a pending
/// page has not answered yet, and drawing "no messages" then would be
/// taken back a moment later.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Load {
    Loading,
    Ready,
    Empty,
}

/// What a tick or a call owes the host. The host encodes nothing: these
/// are W1 requests already built by the one encoder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Begin {
        request: String,
    },
    Live {
        request: String,
    },
    Poll {
        request: String,
    },
    /// Best effort, at most once per known job.
    Cancel {
        request: String,
    },
}

/// A fresh request id, or `None` when this host cannot make one. The
/// production source is the W2b host's; W2a only requires that it can be
/// injected and counted.
pub type NextRequestId = fn() -> Option<String>;

/// Which read an accept answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Begin,
    Live,
    Poll,
    Cancel,
}

/// Who asked, so a late answer can be recognised before it is applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Envelope {
    pub kind: Kind,
    pub generation: u64,
    pub group: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Job {
    id: String,
    group: String,
    generation: u64,
}

/// One row: **`id` is the first core anchor this message was seen under**
/// and never changes. The message it carries may be replaced by a later
/// answer that proves the identity canonical.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub id: String,
    pub message: Message,
}

/// The bounded body and its alias indexes. **One owner per row**: the
/// indexes map a core identity to the row's display id, and a row removed
/// from the front takes every alias that pointed at it.
#[derive(Debug, Default)]
struct Body {
    rows: Vec<Row>,
    /// Canonical `anchor` -> display id.
    anchors: HashMap<String, String>,
    /// `live_anchor` -> display id.
    live_anchors: HashMap<String, String>,
    bytes: usize,
}

impl Body {
    fn clear(&mut self) {
        self.rows.clear();
        self.anchors.clear();
        self.live_anchors.clear();
        self.bytes = 0;
    }

    fn row_of(&self, id: &str) -> Option<usize> {
        self.rows.iter().position(|row| row.id == id)
    }

    /// The text and identity a row costs, per the contract's boundary.
    fn cost(message: &Message) -> usize {
        let mentions: usize = message.mentions.as_ref().map_or(0, |list| {
            list.iter()
                .map(|m| m.id.len() + m.title.as_ref().map_or(0, |t| t.len()))
                .sum()
        });
        message.text.len()
            + message.anchor.len()
            + message.live_anchor.as_ref().map_or(0, |a| a.len())
            + message.author.len()
            + message.role.as_ref().map_or(0, |r| r.len())
            + mentions
    }

    fn unindex(&mut self, id: &str) {
        self.anchors.retain(|_, owner| owner != id);
        self.live_anchors.retain(|_, owner| owner != id);
    }

    fn drop_oldest(&mut self) {
        if self.rows.is_empty() {
            return;
        }
        let row = self.rows.remove(0);
        self.bytes = self.bytes.saturating_sub(Self::cost(&row.message));
        let id = row.id;
        self.unindex(&id);
    }

    fn trim(&mut self) {
        while self.rows.len() > WINDOW_LIMIT || self.bytes > WINDOW_BYTES {
            if self.rows.is_empty() {
                break;
            }
            self.drop_oldest();
        }
    }

    /// Put one message where its identity says it belongs. Returns false
    /// when the message would not fit on its own (the contract's
    /// `TooLarge`, not a truncation).
    fn absorb(&mut self, message: Message) -> bool {
        let cost = Self::cost(&message);
        if cost > WINDOW_BYTES {
            return false;
        }

        // First by the canonical anchor, then by the live alias: the same
        // message comes back from history with `p:<log_seq>` after the
        // live read first saw it as `l:<session>:<seq>`.
        let by_anchor = self.anchors.get(&message.anchor).cloned();
        let by_live = message
            .live_anchor
            .as_ref()
            .and_then(|alias| {
                // A later record's `live_anchor` is the identity an earlier
                // live row was first seen under, which may itself be that
                // row's canonical anchor.
                self.live_anchors
                    .get(alias)
                    .or_else(|| self.anchors.get(alias))
            })
            .cloned();

        let id = match (by_anchor, by_live) {
            (Some(a), Some(b)) if a != b => {
                // Two rows the core has now proved to be one: fold the
                // later one into the earlier display id.
                let b_at = match self.row_of(&b) {
                    Some(at) => at,
                    None => return true,
                };
                let b_row = self.rows.remove(b_at);
                self.bytes = self.bytes.saturating_sub(Self::cost(&b_row.message));
                self.unindex(&b);
                // Every alias that pointed at the removed row now points
                // at the surviving one.
                for owner in self.anchors.values_mut() {
                    if owner == &b {
                        *owner = a.clone();
                    }
                }
                for owner in self.live_anchors.values_mut() {
                    if owner == &b {
                        *owner = a.clone();
                    }
                }
                a
            }
            (Some(a), _) => a,
            (None, Some(b)) => b,
            (None, None) => message.anchor.clone(),
        };

        if let Some(at) = self.row_of(&id) {
            let old = Self::cost(&self.rows[at].message);
            self.bytes = self.bytes.saturating_sub(old);
            self.rows[at].message = message;
            self.bytes += cost;
        } else {
            self.bytes += cost;
            self.rows.push(Row {
                id: id.clone(),
                message,
            });
        }

        let (anchor, alias) = match self.rows.iter().find(|row| row.id == id) {
            Some(row) => (row.message.anchor.clone(), row.message.live_anchor.clone()),
            None => return true,
        };
        self.anchors.insert(anchor, id.clone());
        if let Some(alias) = alias {
            self.live_anchors.insert(alias, id);
        }
        self.trim();
        true
    }

    /// One history page, in the core's order, in front of what is already
    /// there. Overlaps update their row rather than duplicating it.
    fn absorb_front(&mut self, messages: Vec<Message>) {
        // The row ids that were already here; a message that matches one
        // of them keeps its row (and its display id) but moves to the
        // front.
        let mut front: Vec<Row> = Vec::with_capacity(messages.len());
        for message in messages {
            let by_anchor = self.anchors.get(&message.anchor).cloned();
            let by_live = message
                .live_anchor
                .as_ref()
                .and_then(|alias| {
                    // Same fallback as `absorb`: an earlier live row's
                    // canonical anchor is this record's live alias.
                    self.live_anchors
                        .get(alias)
                        .or_else(|| self.anchors.get(alias))
                })
                .cloned();
            let id = match (by_anchor, by_live) {
                (Some(a), _) => a,
                (None, Some(b)) => b,
                (None, None) => message.anchor.clone(),
            };
            if let Some(at) = self.row_of(&id) {
                let row = self.rows.remove(at);
                self.bytes = self.bytes.saturating_sub(Self::cost(&row.message));
                front.push(Row { id, message });
            } else {
                front.push(Row { id, message });
            }
        }
        // Absorbing them one by one keeps the alias rules in one place;
        // the front list was built already de-duplicated.
        let mut merged = Vec::with_capacity(front.len() + self.rows.len());
        merged.extend(front);
        merged.append(&mut self.rows);
        self.rows = merged;
        for row in &self.rows {
            self.bytes += Self::cost(&row.message);
            self.anchors
                .insert(row.message.anchor.clone(), row.id.clone());
            if let Some(alias) = row.message.live_anchor.clone() {
                self.live_anchors.insert(alias, row.id.clone());
            }
        }
        self.trim();
    }
}

/// What the last history page said about what comes after it. The stop
/// reason and the resume point are kept together: an end has no token, a
/// full or budget page must name one, and a gap may have either.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tail {
    pub stop: Stop,
    pub next_token: Option<String>,
    pub restarted: bool,
    pub gap: bool,
}

/// One group's chat.
pub struct Feed {
    next_id: NextRequestId,
    group: Option<String>,
    generation: u64,
    active: bool,
    session: Option<String>,
    live_next: u64,
    job: Option<Job>,
    /// The request id of the current begin. **Bound to that begin's full
    /// parameters**: a Busy/NotReady retry reuses it, and nothing else
    /// does.
    begin_id: Option<String>,
    load: Load,
    /// The log's persisted head as the begin named it. **Not `live_next`**:
    /// the two water marks are different numbers and are never compared.
    history_upper: u64,
    /// The history tail, kept apart from `load`: `Empty` does not mean
    /// there is no more history. `None` is "no page has answered yet",
    /// which is not the same as "the page ended".
    tail: Option<Tail>,
    live_due: Option<u64>,
    history_due: Option<u64>,
    /// One automated rebootstrap after `Expired`/`NoSuchJob`; reset only
    /// when a ready page is delivered.
    rebootstrap_used: bool,
    /// When the begin may be called again (first ask, or a Busy/NotReady
    /// retry with the same id and parameters).
    begin_due: Option<u64>,
    /// Which due clock went last, so two due reads alternate instead of
    /// history starving live.
    history_first: bool,
    /// A live catch-up that stopped advancing (contract: Stalled), and the
    /// token a TooLarge page left for an explicit later recovery.
    stalled: bool,
    history_token: Option<String>,
    trouble: Option<String>,
    live_error: Option<String>,
    history_error: Option<String>,
    /// At most one cancel the host still owes us, for a job this feed
    /// dropped while changing group. One slot: no growing set of ids.
    cleanup: Option<Action>,
    body: Body,
}

impl Feed {
    /// A feed with no group. `next_id` is the host's factory for the ids
    /// this module has to make itself (a session change or the one
    /// allowed recovery).
    pub fn new(next_id: NextRequestId) -> Feed {
        Feed {
            next_id,
            group: None,
            generation: 0,
            active: false,
            session: None,
            live_next: 0,
            job: None,
            begin_id: None,
            load: Load::Loading,
            history_upper: 0,
            tail: None,
            live_due: None,
            history_due: None,
            rebootstrap_used: false,
            begin_due: None,
            history_first: false,
            stalled: false,
            history_token: None,
            trouble: None,
            live_error: None,
            history_error: None,
            cleanup: None,
            body: Body::default(),
        }
    }

    pub fn group(&self) -> Option<&str> {
        self.group.as_deref()
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn load(&self) -> Load {
        self.load
    }

    /// The first problem worth naming: a live failure is not a history
    /// failure, but a page that shows one of them must not clear the other
    /// path's content.
    pub fn trouble(&self) -> Option<&str> {
        self.trouble
            .as_deref()
            .or(self.live_error.as_deref())
            .or(self.history_error.as_deref())
    }

    pub fn live_error(&self) -> Option<&str> {
        self.live_error.as_deref()
    }

    pub fn history_error(&self) -> Option<&str> {
        self.history_error.as_deref()
    }

    pub fn stalled(&self) -> bool {
        self.stalled
    }

    /// The history tail, kept apart from `load`: a body with no rows does
    /// not mean there is no more history. `None` until a page answers.
    pub fn tail(&self) -> Option<&Tail> {
        self.tail.as_ref()
    }

    /// The log's persisted head as the begin named it.
    pub fn history_upper(&self) -> u64 {
        self.history_upper
    }

    /// The token a `TooLarge` page named, for an explicit recovery later.
    /// Nothing in W2a follows it by itself.
    pub fn history_token(&self) -> Option<&str> {
        self.history_token.as_deref()
    }

    pub fn rows(&self) -> &[Row] {
        &self.body.rows
    }

    /// The group's page is visible. **The id is the host's** and is bound
    /// to this begin's full parameters; the same group already running is
    /// a no-op that keeps its body, its job and its id.
    pub fn start(&mut self, group: &str, request_id: String, now_ms: u64) {
        if self.active && self.group.as_deref() == Some(group) {
            return;
        }
        if self.group.as_deref() != Some(group) {
            self.leave_group();
            self.group = Some(group.to_owned());
        }
        if !valid_request_id(&request_id) {
            // No legal id: this bootstrap cannot start. What is already on
            // screen stays, and the old id is not reused.
            self.trouble = Some("BadRequestId".to_owned());
            self.load = Load::Loading;
            self.active = true;
            return;
        }
        self.active = true;
        self.generation += 1;
        self.begin_id = Some(request_id);
        self.load = Load::Loading;
        self.trouble = None;
        self.begin_due = Some(now_ms);
        self.live_due = None;
        self.history_due = None;
    }

    /// The page is gone. **Unconditional**: scheduling stops, the
    /// generation moves so every answer in flight is stale, and a known
    /// job is cancelled once. What the body has stays on screen.
    pub fn stop(&mut self, _now_ms: u64) -> Option<Action> {
        self.active = false;
        self.generation += 1;
        self.begin_due = None;
        self.live_due = None;
        self.history_due = None;
        let job = self.job.take()?;
        Request::Cancel { job_id: job.id }
            .encode()
            .ok()
            .map(|request| Action::Cancel { request })
    }

    /// The first request of a bootstrap. The begin's id and parameters
    /// stay fixed until it succeeds, fails, or the page stops.
    pub fn begin_action(&self) -> Option<Action> {
        if !self.active {
            return None;
        }
        let group = self.group.as_deref()?;
        let request_id = self.begin_id.as_deref()?;
        let request = Request::Begin {
            group: group.to_owned(),
            request_id: request_id.to_owned(),
            limit: BEGIN_LIMIT,
            resume_token: None,
        }
        .encode()
        .ok()?;
        Some(Action::Begin { request })
    }

    /// An answer to the begin this feed is waiting for. A begin for an old
    /// generation or another group is not applied; one that carries a job
    /// is cancelled best-effort, and it never starts a poll or a live read.
    pub fn accept_begin(
        &mut self,
        envelope: &Envelope,
        transport: Result<Transport, TransportError>,
        now_ms: u64,
    ) -> Option<Action> {
        let current = envelope.kind == Kind::Begin
            && envelope.generation == self.generation
            && self.group.as_deref() == Some(envelope.group.as_str())
            && self.active;
        if !current {
            // A begin that arrived too late: its job, if it named one, is
            // cancelled once. The old generation is not restored.
            if let Ok(Transport::Body(text)) = &transport {
                if let Ok(BeginOutcome::Started(page)) = chat_read::decode_begin(text) {
                    return Request::Cancel {
                        job_id: page.job_id,
                    }
                    .encode()
                    .ok()
                    .map(|request| Action::Cancel { request });
                }
            }
            return None;
        }

        match transport {
            Ok(Transport::NotReady) => {
                // Same id, next visible period.
                self.begin_due = Some(now_ms + LIVE_PERIOD_MS);
                None
            }
            Err(TransportError::Unsupported) => {
                self.trouble = Some("Unsupported".to_owned());
                self.load = Load::Loading;
                None
            }
            Err(TransportError::TooLarge) => {
                self.trouble = Some("TooLargeTransport".to_owned());
                None
            }
            Err(TransportError::MalformedUtf8) => {
                self.trouble = Some("MalformedUtf8".to_owned());
                None
            }
            Ok(Transport::Body(text)) => match chat_read::decode_begin(&text) {
                Err(_) => {
                    self.trouble = Some("Malformed".to_owned());
                    None
                }
                Ok(BeginOutcome::Failed(failure)) => {
                    self.failed_begin(now_ms, &failure);
                    None
                }
                Ok(BeginOutcome::Started(page)) => {
                    if page.group != envelope.group {
                        return None;
                    }
                    // A new session replaces the body only once this
                    // snapshot is applied; earlier rows are another run's
                    // identities.
                    if let Some(session) = &self.session {
                        if session != &page.session {
                            self.body.clear();
                        }
                    }
                    self.session = Some(page.session);
                    self.live_next = page.live_since;
                    self.history_upper = page.history_upper;
                    self.job = Some(Job {
                        id: page.job_id,
                        group: page.group,
                        generation: self.generation,
                    });
                    // **The recovery budget is not restored here.** Only a
                    // ready page restores it (contract §3); a begin that
                    // merely started would let a scan that keeps expiring
                    // bootstrap for ever.
                    self.trouble = None;
                    for message in page.live_snapshot {
                        if !self.body.absorb(message) {
                            self.trouble = Some("TooLarge".to_owned());
                            break;
                        }
                    }
                    self.load = Load::Loading;
                    self.begin_due = None;
                    self.live_due = Some(now_ms + LIVE_PERIOD_MS);
                    self.history_due = Some(now_ms + HISTORY_POLL_MS);
                    None
                }
            },
        }
    }

    fn failed_begin(&mut self, now_ms: u64, failure: &Failure) {
        match failure.error.as_str() {
            // Same id, next tick: a second id would be a second scan.
            "Busy" => self.begin_due = Some(now_ms + HISTORY_POLL_MS),
            // Nothing was started, so there is no job to poll; keep what
            // is on screen and stop this bootstrap.
            "LogsClosed" | "NoSuchGroup" | "NotAMember" => {
                self.trouble = Some(failure.error.clone());
                self.begin_id = None;
            }
            "Expired" | "NoSuchJob" => {
                if self.rebootstrap_used {
                    self.trouble = Some(failure.error.clone());
                    self.begin_id = None;
                } else {
                    self.rebootstrap_used = true;
                    self.restart_bootstrap(now_ms);
                }
            }
            "TooLarge" => {
                self.trouble = Some(failure.error.clone());
                self.begin_id = None;
            }
            _ => {
                self.trouble = Some(failure.error.clone());
                self.begin_id = None;
            }
        }
    }

    /// At most one ordinary read per tick. A due begin first, then the two
    /// clocks in turn when both are due -- history cannot starve live.
    /// Nothing is produced while the page is not visible.
    pub fn next_action(&mut self, now_ms: u64) -> Option<Action> {
        // A cancel this feed owes for a job it dropped goes first -- even
        // when the page is no longer visible, because a dropped job must
        // not keep scanning -- and it leaves the slot as it is taken: at
        // most once.
        if let Some(action) = self.cleanup.take() {
            return Some(action);
        }
        if !self.active {
            return None;
        }
        if self.begin_id.is_some() && self.begin_due.map_or(false, |at| now_ms >= at) {
            self.begin_due = None;
            return self.begin_action();
        }
        let live = self.live_due.map_or(false, |at| now_ms >= at);
        let history = self.history_due.map_or(false, |at| now_ms >= at);
        let pick_history = match (live, history) {
            (true, true) => {
                let first = self.history_first;
                self.history_first = !first;
                first
            }
            (false, true) => true,
            (true, false) => false,
            (false, false) => return None,
        };
        if pick_history {
            self.poll_now()
        } else {
            self.live_now()
        }
    }

    fn live_now(&mut self) -> Option<Action> {
        self.live_due = None;
        let group = self.group.as_deref()?;
        if self.session.is_none() {
            return None;
        }
        live_action(group, self.live_next)
    }

    fn poll_now(&mut self) -> Option<Action> {
        self.history_due = None;
        let job = self.job.as_ref()?;
        poll_action(&job.id)
    }

    /// An answer to a live read. Same generation, group and kind only; a
    /// changed core session starts one new bootstrap and keeps the body.
    pub fn accept_live(
        &mut self,
        envelope: &Envelope,
        transport: Result<Transport, TransportError>,
        now_ms: u64,
    ) -> Option<Action> {
        if !self.active
            || envelope.kind != Kind::Live
            || envelope.generation != self.generation
            || self.group.as_deref() != Some(envelope.group.as_str())
        {
            return None;
        }
        match transport {
            Ok(Transport::NotReady) => {
                // Keep the body; ask again next visible period.
                self.live_due = Some(now_ms + LIVE_PERIOD_MS);
                None
            }
            Err(err) => {
                self.live_error = Some(transport_word(err).to_owned());
                self.live_due = None;
                None
            }
            Ok(Transport::Body(text)) => match chat_read::decode_live(&text) {
                Err(_) | Ok(chat_read::LiveOutcome::Failed(_)) => {
                    self.live_error = Some(failure_word(&text).unwrap_or("Malformed").to_owned());
                    self.live_due = None;
                    None
                }
                Ok(chat_read::LiveOutcome::Batch(batch)) => {
                    if batch.group != envelope.group {
                        return None;
                    }
                    if self.session.as_deref() != Some(batch.session.as_str()) {
                        // This core run is not the one the feed knew:
                        // cancel the old job, drop the water mark, start
                        // one new bootstrap. The body stays until that
                        // begin answers.
                        let cancel = self.job.take().and_then(|job| {
                            Request::Cancel { job_id: job.id }
                                .encode()
                                .ok()
                                .map(|request| Action::Cancel { request })
                        });
                        self.session = None;
                        self.live_next = 0;
                        self.live_due = None;
                        self.history_due = None;
                        match (self.next_id)() {
                            Some(id) if valid_request_id(&id) => {
                                self.begin_id = Some(id);
                                self.begin_due = Some(now_ms);
                            }
                            _ => {
                                self.begin_id = None;
                                self.trouble = Some("BadRequestId".to_owned());
                            }
                        }
                        return cancel;
                    }
                    let old_next = self.live_next;
                    for message in batch.messages {
                        if !self.body.absorb(message) {
                            self.live_error = Some("TooLarge".to_owned());
                            break;
                        }
                    }
                    self.live_next = batch.next;
                    if batch.more {
                        // `more` that does not move is a loop, not a
                        // backlog: stop catching up and keep the body.
                        if batch.next <= old_next {
                            self.stalled = true;
                            self.live_due = None;
                        } else {
                            self.stalled = false;
                            self.live_due = Some(now_ms + CATCH_UP_MS);
                        }
                    } else {
                        self.stalled = false;
                        self.live_due = Some(now_ms + LIVE_PERIOD_MS);
                    }
                    None
                }
            },
        }
    }

    /// An answer to a poll. The page's job, group, session and generation
    /// are all checked before a row moves.
    pub fn accept_poll(
        &mut self,
        envelope: &Envelope,
        transport: Result<Transport, TransportError>,
        now_ms: u64,
    ) -> Option<Action> {
        if !self.active
            || envelope.kind != Kind::Poll
            || envelope.generation != self.generation
            || self.group.as_deref() != Some(envelope.group.as_str())
        {
            return None;
        }
        match transport {
            Ok(Transport::NotReady) => {
                self.history_due = Some(now_ms + HISTORY_POLL_MS);
                None
            }
            Err(err) => {
                self.history_error = Some(transport_word(err).to_owned());
                self.history_due = None;
                self.job = None;
                None
            }
            Ok(Transport::Body(text)) => match chat_read::decode_poll(&text) {
                Err(_) => {
                    self.history_error = Some("Malformed".to_owned());
                    self.history_due = None;
                    self.job = None;
                    None
                }
                Ok(chat_read::PollOutcome::Failed(failure)) => {
                    self.failed_poll(now_ms, &failure);
                    None
                }
                Ok(chat_read::PollOutcome::Pending(_)) => {
                    self.history_due = Some(now_ms + HISTORY_POLL_MS);
                    None
                }
                Ok(chat_read::PollOutcome::Cancelled(_)) => {
                    // A cancelled scan is not a page and not an answer
                    // about the history: it must not leave the page
                    // saying it is still loading for ever.
                    self.job = None;
                    self.history_due = None;
                    self.load = if self.body.rows.is_empty() {
                        Load::Empty
                    } else {
                        Load::Ready
                    };
                    None
                }
                Ok(chat_read::PollOutcome::Ready(page)) => {
                    match self.job.as_ref() {
                        Some(job) if job.id == page.job_id => {}
                        _ => return None,
                    }
                    if page.group != envelope.group {
                        return None;
                    }
                    if let Some(session) = &self.session {
                        if session != &page.session {
                            return None;
                        }
                    }
                    self.body.absorb_front(page.messages);
                    self.tail = Some(Tail {
                        stop: page.stop,
                        next_token: page.next_token,
                        restarted: page.restarted,
                        gap: page.gap,
                    });
                    self.job = None;
                    self.history_due = None;
                    self.history_error = None;
                    self.rebootstrap_used = false;
                    self.load = if self.body.rows.is_empty() {
                        Load::Empty
                    } else {
                        Load::Ready
                    };
                    None
                }
            },
        }
    }

    fn failed_poll(&mut self, now_ms: u64, failure: &Failure) {
        match failure.error.as_str() {
            "Busy" => self.history_due = Some(now_ms + HISTORY_POLL_MS),
            "Expired" | "NoSuchJob" => {
                if self.rebootstrap_used {
                    self.history_error = Some(failure.error.clone());
                    self.history_due = None;
                    self.job = None;
                } else {
                    self.rebootstrap_used = true;
                    self.restart_bootstrap(now_ms);
                }
            }
            "TooLarge" => {
                // Keep the token for an explicit recovery; never skip a
                // record or follow it here.
                self.history_token = failure.next_token.clone();
                self.history_error = Some(failure.error.clone());
                self.history_due = None;
                self.job = None;
            }
            _ => {
                self.history_error = Some(failure.error.clone());
                self.history_due = None;
                self.job = None;
            }
        }
    }

    /// A new begin after the core said the scan is gone. The id comes
    /// from the factory: when it has none, this bootstrap stops rather
    /// than reusing the old id.
    fn restart_bootstrap(&mut self, now_ms: u64) {
        match (self.next_id)() {
            Some(id) if valid_request_id(&id) => {
                self.begin_id = Some(id);
                self.job = None;
                self.begin_due = Some(now_ms);
                self.live_due = None;
                self.history_due = None;
                self.load = Load::Loading;
            }
            _ => {
                self.begin_id = None;
                self.trouble = Some("BadRequestId".to_owned());
            }
        }
    }

    fn leave_group(&mut self) {
        // A job this feed knew is cancelled even when the caller is a
        // `start` that changes group (its return value cannot carry one):
        // the one cleanup slot is what it is picked up from.
        if let Some(job) = self.job.take() {
            if let Ok(request) = (Request::Cancel { job_id: job.id }).encode() {
                self.cleanup = Some(Action::Cancel { request });
            }
        }
        self.active = false;
        self.generation += 1;
        self.session = None;
        self.live_next = 0;
        self.begin_id = None;
        self.load = Load::Loading;
        self.history_upper = 0;
        self.tail = None;
        self.begin_due = None;
        self.live_due = None;
        self.history_due = None;
        self.rebootstrap_used = false;
        self.history_first = false;
        self.stalled = false;
        self.history_token = None;
        self.trouble = None;
        self.live_error = None;
        self.history_error = None;
        self.body.clear();
    }
}

fn transport_word(err: TransportError) -> &'static str {
    match err {
        TransportError::Unsupported => "Unsupported",
        TransportError::TooLarge => "TooLargeTransport",
        TransportError::MalformedUtf8 => "MalformedUtf8",
    }
}

/// The core's own error word from a reply that decoded to no live batch.
fn failure_word(text: &str) -> Option<&'static str> {
    match chat_read::decode_live(text) {
        Ok(chat_read::LiveOutcome::Failed(failure)) => Some(match failure.error.as_str() {
            "TooLarge" => "TooLarge",
            _ => "Failed",
        }),
        _ => None,
    }
}

/// The core's own bound on a request id, in UTF-8 bytes.
pub fn valid_request_id(text: &str) -> bool {
    !text.is_empty() && text.len() <= chat_read::REQUEST_ID_LIMIT
}

/// The live read for the feed's current water mark.
#[allow(dead_code)]
pub fn live_action(group: &str, since: u64) -> Option<Action> {
    Request::Live {
        group: group.to_owned(),
        since,
    }
    .encode()
    .ok()
    .map(|request| Action::Live { request })
}

/// One poll of the known job.
#[allow(dead_code)]
pub fn poll_action(job: &str) -> Option<Action> {
    Request::Poll {
        job_id: job.to_owned(),
    }
    .encode()
    .ok()
    .map(|request| Action::Poll { request })
}

// `live_action` and `poll_action` are the named actions the tick will hand
// out in the next step of this slice.

// ------------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    fn next_id() -> Option<String> {
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        Some(format!("{n:032x}"))
    }

    fn group_of(request: &str) -> String {
        let value: Value = serde_json::from_str(request).unwrap();
        match value["method"].as_str().unwrap() {
            "group_read" | "chat_history_begin" => {
                value["params"]["group"].as_str().unwrap().to_owned()
            }
            _ => String::new(),
        }
    }

    fn envelope(kind: Kind, generation: u64, group: &str) -> Envelope {
        Envelope {
            kind,
            generation,
            group: group.to_owned(),
        }
    }

    fn message(seq: u64, log_seq: u64, anchor: &str, live: Option<&str>) -> Value {
        json!({
            "seq": seq,
            "log_seq": log_seq,
            "from": "0x1",
            "from_self": false,
            "author": "worker",
            "at_ms": 1_700_000_000_000i64,
            "summary": false,
            "channel": 0,
            "text": "hi",
            "anchor": anchor,
            "live_anchor": live,
            "content_version": 0,
            "mentions": [],
            "role": ""
        })
    }

    fn begin(group: &str, job: &str, session: &str, live_since: u64, snapshot: &[Value]) -> String {
        json!({
            "ok": true,
            "state": "pending",
            "job_id": job,
            "group": group,
            "session": session,
            "live_since": live_since,
            "history_upper": 9,
            "live_snapshot": snapshot
        })
        .to_string()
    }

    fn ready(
        group: &str,
        job: &str,
        session: &str,
        messages: &[Value],
        stop: &str,
        token: Option<&str>,
    ) -> String {
        json!({
            "ok": true,
            "state": "ready",
            "job_id": job,
            "group": group,
            "session": session,
            "messages": messages,
            "stop": stop,
            "next_token": token,
            "restarted": false,
            "gap": false
        })
        .to_string()
    }

    fn live(
        group: &str,
        session: &str,
        since: u64,
        next: u64,
        more: bool,
        messages: &[Value],
    ) -> String {
        json!({
            "ok": true,
            "group": group,
            "session": session,
            "cursor": since,
            "since": since,
            "next": next,
            "more": more,
            "messages": messages
        })
        .to_string()
    }

    fn body(text: String) -> Result<Transport, TransportError> {
        Ok(Transport::Body(text))
    }

    /// Start a feed on `g` and carry its first begin through to a session
    /// with a known job. Returns the feed and the job id.
    fn started(group: &str) -> (Feed, String) {
        let job = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned();
        let mut feed = Feed::new(next_id);
        feed.start(group, "r1".to_owned(), 0);
        let action = feed.next_action(0).expect("a begin");
        let Action::Begin { request } = action else {
            panic!("expected begin");
        };
        assert_eq!(group_of(&request), group);
        let generation = feed.generation();
        let answer = begin(group, &job, "s1", 5, &[]);
        let cancel = feed.accept_begin(&envelope(Kind::Begin, generation, group), body(answer), 0);
        assert!(cancel.is_none());
        (feed, job)
    }

    #[test]
    fn a_persisted_page_shows_with_no_live_rows_and_live_then_appends() {
        let (mut feed, job) = started("g");
        // Empty live snapshot: still loading, not empty.
        assert_eq!(feed.load(), Load::Loading);

        let generation = feed.generation();
        let page = vec![message(0, 1, "p:1", None), message(0, 2, "p:2", None)];
        let reply = ready("g", &job, "s1", &page, "at_end", None);
        feed.accept_poll(&envelope(Kind::Poll, generation, "g"), body(reply), 10);
        assert_eq!(feed.load(), Load::Ready);
        assert_eq!(feed.rows().len(), 2);
        let tail = feed.tail().expect("a page answered");
        assert_eq!(tail.stop, Stop::AtEnd);
        assert_eq!(tail.next_token, None);

        // Live appends after the page, and updates live_next.
        let reply = live("g", "s1", 5, 6, false, &[message(6, 0, "l:s1:6", None)]);
        feed.accept_live(
            &envelope(Kind::Live, feed.generation(), "g"),
            body(reply),
            20,
        );
        assert_eq!(feed.rows().len(), 3);
        assert_eq!(feed.rows()[2].id, "l:s1:6");
    }

    #[test]
    fn an_overlapping_page_updates_its_row_and_never_duplicates_it() {
        let (mut feed, job) = started("g");
        let generation = feed.generation();
        let live_row = message(6, 0, "l:s1:6", None);
        feed.accept_live(
            &envelope(Kind::Live, generation, "g"),
            body(live("g", "s1", 5, 6, false, &[live_row])),
            10,
        );
        assert_eq!(feed.rows().len(), 1);

        // The same message comes back from history with its persisted
        // identity and the live identity as the alias it had.
        let persisted = message(0, 9, "p:9", Some("l:s1:6"));
        let reply = ready("g", &job, "s1", &[persisted], "at_end", None);
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(reply),
            20,
        );
        assert_eq!(feed.rows().len(), 1);
        assert_eq!(feed.rows()[0].id, "l:s1:6");
        assert_eq!(feed.rows()[0].message.anchor, "p:9");
    }

    #[test]
    fn the_same_group_started_twice_makes_no_second_job() {
        let (mut feed, job) = started("g");
        let generation = feed.generation();
        feed.start("g", "r2".to_owned(), 30);
        assert_eq!(feed.generation(), generation);
        assert!(feed.next_action(30).is_none());
        assert_eq!(job.len(), 32);
    }

    #[test]
    fn a_late_begin_is_cancelled_once_and_never_starts_a_read() {
        let (mut feed, _) = started("g");
        let old_generation = feed.generation();
        feed.stop(40);
        let new_generation = feed.generation();
        assert_ne!(old_generation, new_generation);

        // A begin for the generation that is gone names a job: one
        // cancel, and nothing else.
        let stamp = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        let answer = begin("g", stamp, "s1", 5, &[]);
        let action = feed.accept_begin(
            &envelope(Kind::Begin, old_generation, "g"),
            body(answer),
            50,
        );
        let Some(Action::Cancel { request }) = action else {
            panic!("expected one cancel");
        };
        assert!(request.contains(stamp));
        assert!(feed.next_action(50).is_none());
    }

    #[test]
    fn stop_cancels_a_known_job_once() {
        let (mut feed, job) = started("g");
        let action = feed.stop(40).expect("one cancel");
        let Action::Cancel { request } = action else {
            panic!("expected cancel");
        };
        assert!(request.contains(&job));
        assert!(feed.stop(41).is_none());
    }

    #[test]
    fn pending_polls_and_live_take_turns_and_do_not_starve_each_other() {
        let (mut feed, _job) = started("g");
        let generation = feed.generation();
        // Poll pending: the scan is still running.
        let pending = json!({
            "ok": true, "state": "pending",
            "job_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "group": "g", "session": "s1"
        })
        .to_string();
        feed.accept_poll(&envelope(Kind::Poll, generation, "g"), body(pending), 10);
        // Live not ready: the body stays and it is asked again later.
        feed.accept_live(
            &envelope(Kind::Live, generation, "g"),
            Ok(Transport::NotReady),
            10,
        );

        // At 2100 both are due; the tick gives one, then the other.
        let first = feed.next_action(2_100).expect("one read");
        let second = feed.next_action(2_100).expect("the other read");
        assert_ne!(kind_name(&first), kind_name(&second));
        assert!(feed.next_action(2_100).is_none());
    }

    fn kind_name(action: &Action) -> &'static str {
        match action {
            Action::Begin { .. } => "begin",
            Action::Live { .. } => "live",
            Action::Poll { .. } => "poll",
            Action::Cancel { .. } => "cancel",
        }
    }

    #[test]
    fn more_that_does_not_advance_stops_the_catch_up_and_keeps_the_body() {
        let (mut feed, _job) = started("g");
        let reply = live("g", "s1", 5, 5, true, &[message(5, 0, "l:s1:5", None)]);
        feed.accept_live(
            &envelope(Kind::Live, feed.generation(), "g"),
            body(reply),
            10,
        );
        assert!(feed.stalled());
        assert_eq!(feed.rows().len(), 1);
        // Catch-up stops: no live read is offered; the history clock is
        // free to run.
        assert!(!matches!(
            feed.next_action(1_000),
            Some(Action::Live { .. })
        ));
    }

    #[test]
    fn a_gap_and_a_budget_page_are_not_an_empty_chat() {
        let (mut feed, job) = started("g");
        let reply = ready(
            "g",
            &job,
            "s1",
            &[],
            "budget",
            Some("cccccccccccccccccccccccccccccccc"),
        );
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(reply),
            10,
        );
        // A budget page with no rows is not "the history ended".
        assert_eq!(feed.load(), Load::Empty);
        let tail = feed.tail().expect("a page answered");
        assert_eq!(tail.stop, Stop::Budget);
        assert_eq!(
            tail.next_token.as_deref(),
            Some("cccccccccccccccccccccccccccccccc")
        );
    }

    #[test]
    fn a_busy_begin_retries_the_same_id() {
        let mut feed = Feed::new(next_id);
        feed.start("g", "r1".to_owned(), 0);
        let Action::Begin { request } = feed.next_action(0).expect("a begin") else {
            panic!("expected begin");
        };
        assert!(request.contains("r1"));
        let busy = json!({ "ok": false, "error": "Busy" }).to_string();
        feed.accept_begin(
            &envelope(Kind::Begin, feed.generation(), "g"),
            body(busy),
            0,
        );
        let again = feed.begin_action().expect("the same id");
        let Action::Begin { request } = again else {
            panic!("expected begin");
        };
        assert!(request.contains("r1"));
    }

    #[test]
    fn the_recovery_budget_is_spent_until_a_ready_page_restores_it() {
        let expired = json!({ "ok": false, "error": "Expired" }).to_string();
        let job2 = "dddddddddddddddddddddddddddddddd";

        // One Expired buys one automated bootstrap.
        let (mut feed, _job) = started("g");
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(expired.clone()),
            10,
        );
        let Some(Action::Begin { .. }) = feed.next_action(20) else {
            panic!("the one allowed rebootstrap");
        };
        // The new begin starts -- and does not restore the budget.
        let started_again = begin("g", job2, "s1", 5, &[]);
        feed.accept_begin(
            &envelope(Kind::Begin, feed.generation(), "g"),
            body(started_again),
            20,
        );
        // A second Expired stops with the core's word, and no new begin
        // is offered however many ticks follow.
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(expired.clone()),
            30,
        );
        assert_eq!(feed.history_error(), Some("Expired"));
        assert!(!matches!(feed.next_action(40), Some(Action::Begin { .. })));
        assert!(!matches!(
            feed.next_action(5_000),
            Some(Action::Begin { .. })
        ));

        // A ready page is what restores it: after one, the next Expired
        // buys another bootstrap.
        let (mut feed, job) = started("g");
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            Ok(Transport::NotReady),
            10,
        );
        let reply = ready("g", &job, "s1", &[], "at_end", None);
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(reply),
            20,
        );
        assert!(feed.tail().is_some());
        assert_eq!(feed.history_error(), None);
        // A new page lifecycle (stop then same-group start) has its own
        // generation and a begin; Expired now buys one more bootstrap.
        feed.stop(30);
        feed.start("g", "r2".to_owned(), 40);
        let begin_reply = begin("g", job2, "s1", 5, &[]);
        feed.accept_begin(
            &envelope(Kind::Begin, feed.generation(), "g"),
            body(begin_reply),
            40,
        );
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(expired),
            50,
        );
        assert_eq!(feed.history_error(), None);
        assert!(matches!(feed.next_action(60), Some(Action::Begin { .. })));
    }

    #[test]
    fn a_begin_for_a_generation_that_is_gone_changes_nothing() {
        let (mut feed, _job) = started("g");
        let old = feed.generation();
        feed.stop(10);
        // Same group again: a new generation, and the old answers are
        // stale even though the group still matches.
        feed.start("g", "r2".to_owned(), 20);
        assert_ne!(feed.generation(), old);

        let stale = begin(
            "g",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "s1",
            5,
            &[message(5, 0, "l:s1:5", None)],
        );
        let action = feed.accept_begin(&envelope(Kind::Begin, old, "g"), body(stale), 30);
        // The stale begin's job is cancelled, and none of it is applied.
        assert!(matches!(action, Some(Action::Cancel { .. })));
        assert_eq!(feed.rows().len(), 0);
        assert_eq!(feed.load(), Load::Loading);
    }

    #[test]
    fn changing_group_queues_the_old_jobs_cancel_before_the_new_begin() {
        let (mut feed, job) = started("g");
        // A start on another group cannot return an action: the cancel of
        // the job it drops is picked up from the one cleanup slot first.
        feed.start("h", "r2".to_owned(), 100);
        let Some(Action::Cancel { request }) = feed.next_action(100) else {
            panic!("the dropped job's cancel comes first");
        };
        assert!(request.contains(&job));
        let Some(Action::Begin { request }) = feed.next_action(100) else {
            panic!("then the new begin");
        };
        assert!(request.contains("r2"));
        // Once taken, it is not produced again.
        assert!(!matches!(
            feed.next_action(101),
            Some(Action::Cancel { .. })
        ));
    }
}
