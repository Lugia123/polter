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
///
/// **The whole session, not one screenful**: the reading window keeps what
/// the person has loaded (5000 rows) and evicts a block at a time, so a
/// page that was just read is not trimmed away one row at a time.
pub const WINDOW_LIMIT: usize = 5_000;
/// The text and identity budget those rows may use, in bytes. Raised with
/// the row limit: 5000 rows at a few kilobytes each would otherwise hit
/// the byte budget long before the row limit and silently keep far fewer.
pub const WINDOW_BYTES: usize = 32 * 1024 * 1024;
/// Rows dropped at once when the window is over its limit. **A block, not
/// one row**: evicting one row per tick would make every scroll past the
/// limit re-lay out the page.
pub const EVICT_ROWS: usize = 100;

/// How often a visible feed reads live, and how soon it catches up while
/// the core says there is more.
pub const LIVE_PERIOD_MS: u64 = 2_000;
pub const CATCH_UP_MS: u64 = 200;
/// How soon a pending history scan is asked again.
pub const HISTORY_POLL_MS: u64 = 200;
/// **How long a failed or empty block is not asked for again.** Without
/// this, every wheel notch at the top would re-ask the page that just
/// failed; the host still shows the failure, but once.
pub const AUX_RETRY_MS: u64 = 2_000;

// **Four doors, four sizes.** They are separate constants even where two
// values happen to agree today: the first screen, an older block, a page
// of search results and a context window's direction are different
// questions, and one number used in four places makes changing any of
// them change all of them.
/// The first screen: 100 rows.
pub const FIRST_CHUNK: u16 = 100;
/// One older block: 50 rows each time the reader comes near the top.
pub const OLDER_CHUNK: u16 = 50;
/// One page of search results: its own value, unchanged from before.
pub const SEARCH_CHUNK: u16 = 50;
/// One page in a context window's direction: its own value.
pub const CONTEXT_CHUNK: u16 = 50;
/// Empty budget pages stepped past in one ask. Each step is a different
/// physical range; the cap only stops a runaway scan from spinning here.
pub const AUTO_ADVANCE_LIMIT: u8 = 8;
/// New messages kept while the reader is in the history, apart from the
/// reading window. **Ten eviction blocks**, so the waiting tail is always
/// smaller than the window it rejoins and a return to the latest cannot
/// drop more than it keeps.
pub const TAIL_LIMIT: usize = EVICT_ROWS * 10;
/// Hits kept for the right-hand panel. The core pages; the host's list is
/// bounded like the body.
pub const SEARCH_RESULTS_LIMIT: usize = 500;
/// The text/identity budget the kept results may use.
pub const SEARCH_BYTES_LIMIT: usize = 4 * 1024 * 1024;

/// What the first screen shows. **`Loading` is not `Empty`**: a pending
/// page has not answered yet, and drawing "no messages" then would be
/// taken back a moment later.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Load {
    Loading,
    Ready,
    Empty,
    /// The core cancelled the scan before answering about the history.
    /// **Not Empty**: that would say the group has no records.
    Cancelled,
    /// Nothing could be read cleanly: a gap or a restart means an empty
    /// page is not an empty group.
    Gap,
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
    /// The group's brief and members.
    Metadata {
        request: String,
    },
    /// One page of a literal search.
    SearchBegin {
        request: String,
    },
    SearchPoll {
        request: String,
    },
    /// `mode:"context"` for the next page in one direction.
    AuxBegin {
        request: String,
    },
    /// The shared `chat_history_poll`, for whichever auxiliary job is
    /// running (context today; around/reference reuse this pair).
    AuxPoll {
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
    Metadata,
    AuxBegin,
    AuxPoll,
    SearchBegin,
    SearchPoll,
    Cancel,
}

/// Who asked, so a late answer can be recognised before it is applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Envelope {
    pub kind: Kind,
    pub generation: u64,
    pub group: String,
    /// The request id this reply answers, when the host knows it (it sent
    /// the request). **A reply whose id is not the feed's current one is
    /// stale even when group and generation still match**, and a job it
    /// started is cancelled unless it is the job this feed already holds.
    pub request_id: Option<String>,
    /// The polled job this reply answers, when the host knows it.
    pub job_id: Option<String>,
    /// The navigation epoch at send time; `0` means the host did not say.
    pub nav: u64,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TrimEnd {
    Oldest,
    Newest,
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

    /// Drop the newest row instead. **What the reading window does**: a
    /// person reading older rows must not have the page they just loaded
    /// trimmed away by the window's oldest-first rule.
    fn drop_newest(&mut self) {
        let Some(row) = self.rows.pop() else {
            return;
        };
        self.bytes = self.bytes.saturating_sub(Self::cost(&row.message));
        let id = row.id;
        self.unindex(&id);
    }

    fn trim(&mut self) {
        let _ = self.trim_keeping(TrimEnd::Oldest);
    }

    /// Drop the newest end and say whether anything was lost. A `true` is
    /// a **discontinuity**: the reading window's newest retained row no
    /// longer touches whatever comes after it.
    fn trim_keeping_oldest(&mut self) -> bool {
        self.trim_keeping(TrimEnd::Newest)
    }

    /// **Evict a block, not a row.** The window is bounded at 5000 rows (or
    /// 32 MiB); when it goes over, one whole block of `EVICT_ROWS` leaves
    /// the chosen end. Dropping a single row would make every new message
    /// past the limit renumber and re-lay out the whole page; a block makes
    /// the discontinuity rare and explicit, and the bool returned is what
    /// says it happened.
    fn trim_keeping(&mut self, end: TrimEnd) -> bool {
        let mut dropped = false;
        while self.rows.len() > WINDOW_LIMIT || self.bytes > WINDOW_BYTES {
            if self.rows.is_empty() {
                break;
            }
            let block = EVICT_ROWS.min(self.rows.len());
            for _ in 0..block {
                match end {
                    TrimEnd::Oldest => self.drop_oldest(),
                    TrimEnd::Newest => self.drop_newest(),
                }
            }
            dropped = true;
        }
        dropped
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
    fn absorb_front(&mut self, messages: Vec<Message>, keep_oldest: bool) -> bool {
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
        // **Recount from the rows that are actually here**: the removed
        // overlaps were subtracted above, so adding to the old total would
        // count every surviving row a second time and shrink the window.
        self.bytes = 0;
        for row in &self.rows {
            self.bytes += Self::cost(&row.message);
            self.anchors
                .insert(row.message.anchor.clone(), row.id.clone());
            if let Some(alias) = row.message.live_anchor.clone() {
                self.live_anchors.insert(alias, row.id.clone());
            }
        }
        if keep_oldest {
            self.trim_keeping_oldest()
        } else {
            self.trim();
            false
        }
    }
}

impl Body {
    /// Append one row **without trimming the reading anchor**. Refuses
    /// when the window would overflow: a context page must say it hit the
    /// budget rather than silently drop the newest rows it just added.
    fn try_absorb_back(&mut self, message: Message) -> bool {
        let cost = Self::cost(&message);
        if self.bytes.saturating_add(cost) > WINDOW_BYTES || self.rows.len() >= WINDOW_LIMIT {
            return false;
        }
        // Aliases are kept in one place by `absorb`; here the rows are
        // already de-duplicated by the caller against this body.
        self.bytes += cost;
        let id = message.anchor.clone();
        self.anchors.insert(message.anchor.clone(), id.clone());
        if let Some(alias) = message.live_anchor.clone() {
            self.live_anchors.insert(alias, id.clone());
        }
        self.rows.push(Row { id, message });
        true
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
    /// **This history range has seen a gap or a restart on any page so
    /// far.** A later clean page cannot wash it out; only a new range or an
    /// explicit reload starts again.
    pub dirty: bool,
}

/// What the person can see about older pages. **Cancelled, incomplete and
/// the beginning are three different facts**, and a page that stopped on
/// its byte budget with nothing in it is none of them: it is still
/// progress.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OlderState {
    /// No older request has been made for this page.
    Idle,
    /// A scan is running, or an empty budget page is being stepped past.
    Loading,
    /// Rows arrived and the tail can still be continued.
    Incomplete,
    /// The core said this is the beginning of the captured range, and the
    /// range was complete (`at_end` with no gap and no restart).
    End,
    /// The beginning was reached, but records in it could not be read or
    /// the log restarted. **Not `End`**: the page cannot claim completeness.
    Gap,
    /// The core cancelled the scan; it did not answer about the history.
    Cancelled,
    /// A named failure. `TooLarge` keeps its token for an explicit retry.
    Failed(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AuxKind {
    /// The next history page, asked for with `resume_token` and no `mode`.
    Older,
    /// A target and its neighbours, `mode:"around"`.
    Around,
    /// A file reference's source, `mode:"reference"`.
    Reference,
    /// One direction of an around window, `mode:"context"`.
    Context,
}

/// The one auxiliary history job: an older page, an around window, or a
/// reference source. All three reuse the history poll/cancel pair.
struct Aux {
    kind: AuxKind,
    request_id: String,
    /// The older page's continuation token (the history page's own
    /// `next_token`).
    token: Option<String>,
    /// The around/reference target message.
    anchor: Option<String>,
    /// That message's own core hint, stored and sent back unchanged.
    location: Option<String>,
    /// The reference's exact raw Markdown text.
    reference: Option<String>,
    before: u8,
    after: u8,
    /// The navigation this aux belongs to. A reply for an older navigation
    /// never changes the window.
    nav: u64,
    job: Option<String>,
    begin_due: Option<u64>,
    poll_due: Option<u64>,
}

impl Aux {
    fn older(request_id: String, token: String, now: u64) -> Aux {
        Aux {
            kind: AuxKind::Older,
            request_id,
            token: Some(token),
            anchor: None,
            location: None,
            reference: None,
            before: 0,
            after: 0,
            nav: 0,
            job: None,
            begin_due: Some(now),
            poll_due: None,
        }
    }

    fn around(
        request_id: String,
        anchor: String,
        location: Option<String>,
        before: u8,
        after: u8,
        now: u64,
    ) -> Aux {
        Aux {
            kind: AuxKind::Around,
            request_id,
            token: None,
            anchor: Some(anchor),
            location,
            reference: None,
            before,
            after,
            nav: 0,
            job: None,
            begin_due: Some(now),
            poll_due: None,
        }
    }

    fn context(request_id: String, token: String, now: u64) -> Aux {
        Aux {
            kind: AuxKind::Context,
            request_id,
            token: Some(token),
            anchor: None,
            location: None,
            reference: None,
            before: 0,
            after: 0,
            nav: 0,
            job: None,
            begin_due: Some(now),
            poll_due: None,
        }
    }

    fn reference(
        request_id: String,
        anchor: String,
        location: Option<String>,
        reference: String,
        now: u64,
    ) -> Aux {
        Aux {
            kind: AuxKind::Reference,
            request_id,
            token: None,
            anchor: Some(anchor),
            location,
            reference: Some(reference),
            before: 0,
            after: 0,
            nav: 0,
            job: None,
            begin_due: Some(now),
            poll_due: None,
        }
    }
}

/// What a search is doing, as the right-hand panel shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchState {
    /// No query has been asked for this page.
    Idle,
    Loading,
    /// Hits arrived and the scan can be continued.
    Incomplete,
    /// A clean, gap-free end of the captured range.
    End,
    /// The end was reached but the range was incomplete.
    Gap,
    Cancelled,
    Failed(String),
}

struct SearchJob {
    request_id: String,
    query: String,
    /// The scan cursor the next page is asked from, if any.
    token: Option<String>,
    job: Option<String>,
    begin_due: Option<u64>,
    poll_due: Option<u64>,
}

impl SearchJob {
    fn new(request_id: String, query: String, now: u64) -> SearchJob {
        SearchJob {
            request_id,
            query,
            token: None,
            job: None,
            begin_due: Some(now),
            poll_due: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchTail {
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
    /// A live catch-up that stopped advancing (contract: Stalled), and the
    /// token a TooLarge page left for an explicit later recovery.
    stalled: bool,
    history_token: Option<String>,
    trouble: Option<String>,
    live_error: Option<String>,
    history_error: Option<String>,
    /// See `Tail::dirty`: accumulated across pages of one history range.
    history_dirty: bool,
    /// Cancels the host still owes for jobs this feed dropped. **Fixed
    /// slots, one per kind of job this feed can hold** (bootstrap,
    /// auxiliary, search); a session change can drop several at once, and
    /// a single slot would overwrite a cancel and leave a scan running.
    cleanup: [Option<Action>; 3],
    /// The group's brief and members, once `chat_metadata` has answered.
    metadata: Option<chat_read::Metadata>,
    metadata_error: Option<String>,
    metadata_due: Option<u64>,
    /// The search job and what it has answered. **Separate from history**:
    /// it uses `chat_search_*`, not the history poll/cancel pair.
    search: Option<SearchJob>,
    search_state: SearchState,
    search_query: Option<String>,
    search_results: Vec<chat_read::Hit>,
    search_tail: Option<SearchTail>,
    search_dirty: bool,
    /// Empty budget pages stepped past for the current query.
    search_auto: u8,
    /// Hits beyond the bounded result list, kept in memory rather than
    /// consumed and dropped. While this is non-empty no further page is
    /// requested.
    search_remainder: Vec<chat_read::Hit>,
    /// The result list is at its bound.
    search_full: bool,
    /// A newer page/remainder is being accepted after releasing older
    /// results from the front; the page decides how much room it needs.
    search_release_next: bool,
    /// The window has released newer hits at least once for this query.
    search_released: bool,
    /// What the kept hits cost.
    search_bytes: usize,
    /// The token of the page a failure/cancel interrupted. A retry asks
    /// **this** page again, never the first one.
    search_resume: Option<String>,
    /// The next page in one direction, when one is asked for.
    aux: Option<Aux>,
    /// Which navigation the person asked for last (an around target, a
    /// reference, a return to the latest). **A reply for an older one never
    /// moves the window.**
    nav_epoch: u64,
    /// The answers around and reference keep. One auxiliary job at a
    /// time; these hold what it last produced.
    around: Option<chat_read::AroundPage>,
    reference: Option<chat_read::ReferencePage>,
    /// Reference answers that arrived for a navigation/owner that is no
    /// longer current, or that were dropped before anyone consumed them.
    /// **Each ticket is minted once and nobody adopted it**; the host
    /// closes them through the preview ledger. A list, not one slot: two
    /// late answers must not overwrite each other's capability.
    orphan_reference: Vec<String>,
    /// The two direction cursors of the context window.
    context_older: Option<String>,
    context_newer: Option<String>,
    context_older_at_end: bool,
    context_newer_at_end: bool,
    /// A gap or restart seen on that direction's pages.
    context_older_dirty: bool,
    context_newer_dirty: bool,
    /// The retained boundary on that side. When the opposite side trimmed
    /// this edge, its old cursor is invalid and walking it re-anchors here
    /// with an `around` request instead of paging across a gap.
    context_older_reanchor: Option<String>,
    context_newer_reanchor: Option<String>,
    /// A newer page the window could not take whole. **Never advance the
    /// cursor past rows nobody kept**: these are drained before the next
    /// request.
    context_remainder: Vec<Message>,
    aux_error: Option<String>,
    older: OlderState,
    /// When the current older ask was made, and the earliest moment a new
    /// one may be made after a failure or an empty block. **Both ends use
    /// their own clock**: a context window and the history chain are
    /// different doors and one must not cool the other.
    older_asked_ms: u64,
    older_retry_at: u64,
    context_asked_ms: u64,
    context_retry_at: u64,
    /// Empty budget pages stepped past for the current ask. Bounded so a
    /// long run of them cannot spin the scan for ever.
    auto_advances: u8,
    /// The reader is looking at older rows: **the reading window keeps its
    /// oldest end**, and live messages arriving meanwhile wait in
    /// `tail_rows` rather than growing or trimming what is being read.
    reading_history: bool,
    /// An explicit non-latest window (an around/context answer). **Live
    /// rows wait in the tail and returning to the latest must reload**,
    /// never splice.
    context_mode: bool,
    tail_rows: Vec<Message>,
    /// The reading window dropped its newest rows, or the waiting tail
    /// dropped its oldest: **the two are then not adjacent**. Returning to
    /// the latest end must reload rather than splice a false neighbour.
    history_gap: bool,
    tail_gap: bool,
    /// Which due clock goes next when live, the bootstrap scan and the
    /// auxiliary scan are due together.
    poll_turn: u8,
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
            stalled: false,
            history_token: None,
            trouble: None,
            live_error: None,
            history_error: None,
            history_dirty: false,
            cleanup: [None, None, None],
            metadata: None,
            metadata_error: None,
            metadata_due: None,
            search: None,
            search_state: SearchState::Idle,
            search_query: None,
            search_results: Vec::new(),
            search_tail: None,
            search_dirty: false,
            search_auto: 0,
            search_remainder: Vec::new(),
            search_full: false,
            search_release_next: false,
            search_released: false,
            search_bytes: 0,
            search_resume: None,
            aux: None,
            nav_epoch: 0,
            around: None,
            reference: None,
            orphan_reference: Vec::new(),
            context_older: None,
            context_newer: None,
            context_older_at_end: true,
            context_newer_at_end: true,
            context_older_dirty: false,
            context_newer_dirty: false,
            context_older_reanchor: None,
            context_newer_reanchor: None,
            context_remainder: Vec::new(),
            aux_error: None,
            older: OlderState::Idle,
            older_asked_ms: 0,
            older_retry_at: 0,
            context_asked_ms: 0,
            context_retry_at: 0,
            auto_advances: 0,
            reading_history: false,
            context_mode: false,
            tail_rows: Vec::new(),
            history_gap: false,
            tail_gap: false,
            poll_turn: 0,
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

    /// The group's brief and members, once the metadata call answered.
    /// `None` is "not read yet", never "the group has neither".
    pub fn metadata(&self) -> Option<&chat_read::Metadata> {
        self.metadata.as_ref()
    }

    pub fn metadata_error(&self) -> Option<&str> {
        self.metadata_error.as_deref()
    }

    /// What the older direction is doing. `Incomplete` is not `End`: rows
    /// arrived and the tail still names a continuation.
    pub fn older(&self) -> &OlderState {
        &self.older
    }

    /// Whether asking for older rows would start a scan now.
    pub fn can_load_older(&self) -> bool {
        self.active
            && self.aux.is_none()
            && !matches!(self.older, OlderState::Loading)
            && self
                .tail
                .as_ref()
                .and_then(|t| t.next_token.as_deref())
                .is_some()
    }

    /// Ask for the page the tail's token points at. **The token is the
    /// whole question**: this host sends no anchor or direction beside it.
    /// Returns false when there is nothing to ask, so a scroll edge cannot
    /// start a second scan.
    pub fn load_older(&mut self, request_id: String, now_ms: u64) -> bool {
        // **A failed or empty block is not asked for again on every wheel
        // notch.** The state still says what happened; the clock is what
        // stops a scroll edge from becoming a retry storm.
        if now_ms < self.older_retry_at {
            return false;
        }
        if !self.can_load_older() || !valid_request_id(&request_id) {
            return false;
        }
        let Some(token) = self.tail.as_ref().and_then(|t| t.next_token.clone()) else {
            return false;
        };
        self.older_asked_ms = now_ms;
        self.older = OlderState::Loading;
        self.auto_advances = 0;
        self.reading_history = true;
        self.aux = Some(Aux::older(request_id, token, now_ms));
        true
    }

    pub fn around(&self) -> Option<&chat_read::AroundPage> {
        self.around.as_ref()
    }

    pub fn reference(&self) -> Option<&chat_read::ReferencePage> {
        self.reference.as_ref()
    }

    /// Every ticket a reference answer minted and nobody adopted. The host
    /// closes them through its owner-checked ledger.
    pub fn take_orphan_references(&mut self) -> Vec<String> {
        std::mem::take(&mut self.orphan_reference)
    }

    /// **Ownership moves before a stored answer is dropped.** A ready page
    /// in `reference` has a minted ticket; clearing the field without
    /// parking it drops the one capability that answer carried.
    fn discard_reference(&mut self) {
        if let Some(page) = self.reference.take() {
            self.park_reference_page(&page);
        }
    }

    fn park_reference_page(&mut self, page: &chat_read::ReferencePage) {
        // **The same 32-lower-hex rule the conservative reader uses**: a
        // decoded page is not a licence to treat any string as a ticket.
        if let Some(token) = chat_read::ticket_of(page) {
            self.orphan_reference.push(token);
        }
    }

    /// The conservative cleanup path for a page the full decoder refused.
    /// **The minted ticket is independent of source-field validation**: if
    /// the JSON still says `mode:"reference"` and carries a ticket-shaped
    /// token, it is returned even though the page cannot be used.
    fn park_reference_text(&mut self, text: &str) {
        if let Some(token) = chat_read::reference_ticket(text) {
            self.orphan_reference.push(token);
        }
    }

    /// A rejected/uncalled-for answer may still carry a ticket minted by
    /// that final poll. **Every exit a `ReadyReference` can leave by goes
    /// through here**, including the identity guards at the top of a poll,
    /// a bootstrap answer of the wrong mode, and a page the decoder refused.
    fn park_reference_answer(&mut self, transport: &Result<Transport, TransportError>) {
        if let Ok(Transport::Body(text)) = transport {
            if let Ok(chat_read::PollOutcome::ReadyReference(page)) = chat_read::decode_poll(text) {
                self.park_reference_page(&page);
            } else {
                self.park_reference_text(text);
            }
        }
    }

    /// Take the reference answer once, so a repaint cannot remount a
    /// ticket the page already consumed.
    pub fn take_reference(&mut self) -> Option<chat_read::ReferencePage> {
        self.reference.take()
    }

    pub fn aux_error(&self) -> Option<&str> {
        self.aux_error.as_deref()
    }

    /// An around/reference/context job is in flight.
    pub fn aux_busy(&self) -> bool {
        self.aux.is_some()
    }

    /// A new navigation replaces the one in flight. Its job is cancelled
    /// through a cleanup slot, and the epoch bump makes any late reply
    /// stale.
    fn supersede_aux(&mut self) {
        if let Some(aux) = self.aux.take() {
            if let Some(job_id) = aux.job {
                if let Ok(request) = (Request::Cancel { job_id }).encode() {
                    self.queue_cleanup(request);
                }
            }
        }
        self.aux_error = None;
        self.nav_epoch += 1;
    }

    /// Ask for a target and its neighbours (`mode:"around"`). The search
    /// result click uses this when the row it names is not in the body.
    pub fn load_around(
        &mut self,
        anchor: &str,
        location: Option<&str>,
        before: u8,
        after: u8,
        request_id: String,
        now_ms: u64,
    ) -> bool {
        if !self.active
            || !valid_request_id(&request_id)
            || chat_read::check_anchor(anchor).is_err()
        {
            return false;
        }
        self.supersede_aux();
        self.around = None;
        let nav = self.nav_epoch;
        let mut aux = Aux::around(
            request_id,
            anchor.to_owned(),
            location.map(str::to_owned),
            before,
            after,
            now_ms,
        );
        aux.nav = nav;
        self.aux = Some(aux);
        true
    }

    /// Ask for a message's exact file-reference source
    /// (`mode:"reference"`). The answer carries the existing `files_open`
    /// object unchanged; this host never builds one.
    pub fn load_reference(
        &mut self,
        anchor: &str,
        location: Option<&str>,
        original_reference: &str,
        request_id: String,
        now_ms: u64,
    ) -> bool {
        if !self.active
            || !valid_request_id(&request_id)
            || chat_read::check_anchor(anchor).is_err()
            || original_reference.is_empty()
            || original_reference.len() > chat_read::REFERENCE_LIMIT
        {
            return false;
        }
        self.supersede_aux();
        // **A ready answer A is replaced by B**: its ticket was minted and
        // never adopted, so it goes back rather than being dropped here.
        self.discard_reference();
        let nav = self.nav_epoch;
        let mut aux = Aux::reference(
            request_id,
            anchor.to_owned(),
            location.map(str::to_owned),
            original_reference.to_owned(),
            now_ms,
        );
        aux.nav = nav;
        self.aux = Some(aux);
        true
    }

    /// The context window's cursors: `(older token, older at end, newer
    /// token, newer at end)`.
    pub fn context_tokens(&self) -> (Option<&str>, bool, Option<&str>, bool) {
        (
            self.context_older.as_deref(),
            self.context_older_at_end,
            self.context_newer.as_deref(),
            self.context_newer_at_end,
        )
    }

    /// Whether one direction of the context window has another page to
    /// ask for now.
    pub fn context_can(&self, older: bool) -> bool {
        if !self.context_mode || self.aux.is_some() {
            return false;
        }
        if older {
            self.context_older_reanchor.is_some()
                || (self.context_older.is_some() && !self.context_older_at_end)
        } else {
            self.context_newer_reanchor.is_some()
                || !self.context_remainder.is_empty()
                || (self.context_newer.is_some() && !self.context_newer_at_end)
        }
    }

    /// One more page of the context window, in the direction its own token
    /// names (`mode:"context"`). **Never the history or search door.**
    pub fn load_context(&mut self, older: bool, request_id: String, now_ms: u64) -> bool {
        if !self.active || !self.context_mode || !valid_request_id(&request_id) {
            return false;
        }
        // **The context door has its own retry clock**: a gap or a failed
        // page in a located window must not be asked for on every wheel
        // notch either.
        if now_ms < self.context_retry_at {
            return false;
        }
        self.context_asked_ms = now_ms;
        // **A trimmed edge is recovered by re-anchoring, not by paging
        // across the gap**: ask for an around window ending at the message
        // still on screen, which restores a real four-way cursor set.
        let reanchor = if older {
            self.context_older_reanchor.clone()
        } else {
            self.context_newer_reanchor.clone()
        };
        if let Some(anchor) = reanchor {
            let location = self
                .body
                .rows
                .iter()
                .find(|row| {
                    row.message.anchor == anchor
                        || row.id == anchor
                        || row.message.live_anchor.as_deref() == Some(anchor.as_str())
                })
                .map(|row| row.message.location.clone())
                .unwrap_or(None);
            let (before, after) = if older { (49, 0) } else { (0, 49) };
            return self.load_around(
                &anchor,
                location.as_deref(),
                before,
                after,
                request_id,
                now_ms,
            );
        }
        if !older && !self.context_remainder.is_empty() {
            let pending = std::mem::take(&mut self.context_remainder);
            let mut left = Vec::new();
            for message in pending {
                let keep = message.clone();
                if !self.body.try_absorb_back(message) {
                    left.push(keep);
                }
            }
            self.context_remainder = left;
            if !self.context_remainder.is_empty() {
                self.aux_error = Some("ContextBudget".to_owned());
                return false;
            }
            self.aux_error = None;
            if self.context_newer.is_none() || self.context_newer_at_end {
                return true;
            }
        }
        let (token, at_end) = if older {
            (self.context_older.clone(), self.context_older_at_end)
        } else {
            (self.context_newer.clone(), self.context_newer_at_end)
        };
        let Some(token) = token else { return false };
        if at_end {
            return false;
        }
        self.supersede_aux();
        let nav = self.nav_epoch;
        let mut aux = Aux::context(request_id, token, now_ms);
        aux.nav = nav;
        self.aux = Some(aux);
        self.aux_error = None;
        true
    }

    /// The reader asked for the newest end again: the messages that waited
    /// while they read history join the body, the history window trims from
    /// its oldest end as usual, and live rows go into the body again.
    pub fn return_to_latest(&mut self, now_ms: u64) {
        // **Returning to the latest cancels whatever navigation was in
        // flight**, and bumps the navigation epoch so a late around or
        // reference completion is refused rather than moving the window.
        self.nav_epoch += 1;
        if let Some(aux) = self.aux.take() {
            if let Some(job_id) = aux.job {
                if let Ok(request) = (Request::Cancel { job_id }).encode() {
                    self.queue_cleanup(request);
                }
            }
        }
        self.around = None;
        self.discard_reference();
        self.context_older = None;
        self.context_newer = None;
        self.context_older_at_end = true;
        self.context_newer_at_end = true;
        self.context_older_dirty = false;
        self.context_newer_dirty = false;
        self.context_older_reanchor = None;
        self.context_newer_reanchor = None;
        self.context_remainder.clear();
        self.aux_error = None;
        // **A window that dropped rows, or an explicit context window, is
        // not adjacent to what comes after it.** Splicing the waiting tail
        // onto it would invent neighbours; the honest move is an explicit
        // switch: clear both and read the newest page again.
        if self.context_mode || self.history_gap || self.tail_gap {
            if let Some(job) = self.job.take() {
                if let Ok(request) = (Request::Cancel { job_id: job.id }).encode() {
                    self.queue_cleanup(request);
                }
            }
            self.body.clear();
            self.tail_rows.clear();
            self.history_gap = false;
            self.tail_gap = false;
            self.history_dirty = false;
            self.reading_history = false;
            self.context_mode = false;
            self.older = OlderState::Idle;
            self.tail = None;
            self.load = Load::Loading;
            self.restart_bootstrap(now_ms);
            return;
        }
        let waiting = std::mem::take(&mut self.tail_rows);
        for message in waiting {
            if !self.body.absorb(message) {
                break;
            }
        }
        self.reading_history = false;
    }

    /// Whether the reading window is on the history rather than the latest
    /// end. **Not the same as "older rows exist"**: the older scan's state
    /// is `older()`.
    pub fn reading_history(&self) -> bool {
        self.reading_history
    }

    /// The view is an explicit non-latest context window (around/context),
    /// not the latest end with older pages loaded.
    pub fn context_window(&self) -> bool {
        self.context_mode
    }

    /// Whether that direction's range has a gap or restart behind it.
    pub fn context_dirty(&self, older: bool) -> bool {
        if older {
            self.context_older_dirty
        } else {
            self.context_newer_dirty
        }
    }

    pub fn nav_epoch(&self) -> u64 {
        self.nav_epoch
    }

    /// The person moved off the bottom: live rows now wait aside, and a
    /// hidden/re-shown page keeps this window instead of bootstrapping
    /// over it.
    pub fn enter_reading(&mut self) {
        if self.active && !self.context_mode {
            self.reading_history = true;
        }
    }

    /// A located row, loaded or not, is a navigation: the aux in flight is
    /// superseded and its late reply cannot move the window.
    pub fn cancel_navigation(&mut self) {
        self.supersede_aux();
    }

    /// Messages that arrived while the reader was in the history. They are
    /// not in `rows()` and the reading window's bound never trims them.
    pub fn new_messages(&self) -> usize {
        self.tail_rows.len()
    }

    pub fn search_state(&self) -> &SearchState {
        &self.search_state
    }

    pub fn search_query(&self) -> Option<&str> {
        self.search_query.as_deref()
    }

    pub fn search_results(&self) -> &[chat_read::Hit] {
        &self.search_results
    }

    pub fn search_tail(&self) -> Option<&SearchTail> {
        self.search_tail.as_ref()
    }

    /// Whether another search page can be asked for now.
    pub fn search_can_more(&self) -> bool {
        // **Both a partial page and a gap with a cursor can continue**;
        // the list's own limit does not count as "no more".
        matches!(
            self.search_state,
            SearchState::Incomplete | SearchState::Gap
        ) && self.search.is_none()
            && (!self.search_remainder.is_empty()
                || self
                    .search_tail
                    .as_ref()
                    .and_then(|tail| tail.next_token.as_deref())
                    .is_some())
    }

    /// The result list reached its bound; the rest is held, not lost.
    pub fn search_full(&self) -> bool {
        self.search_full
    }

    /// Newer hits were released to make room for older ones in this query.
    pub fn search_released(&self) -> bool {
        self.search_released
    }

    fn hit_cost(hit: &chat_read::Hit) -> usize {
        hit.message.text.len()
            + hit.message.anchor.len()
            + hit.message.author.len()
            + hit.snippet.len()
            + hit.ranges.len() * 8
    }

    /// Accept a whole bounded page (or what is left of one), **releasing
    /// newer hits from the front only when the page needs the room**.
    fn absorb_search_page(&mut self, hits: Vec<chat_read::Hit>) {
        let mut fresh: Vec<chat_read::Hit> = Vec::new();
        for hit in hits {
            if self
                .search_results
                .iter()
                .chain(self.search_remainder.iter())
                .any(|seen| seen.message.anchor == hit.message.anchor)
                || fresh
                    .iter()
                    .any(|seen| seen.message.anchor == hit.message.anchor)
            {
                continue;
            }
            fresh.push(hit);
        }
        let page_bytes: usize = fresh.iter().map(Self::hit_cost).sum();
        let release = self.search_release_next
            || self.search_results.len() + fresh.len() > SEARCH_RESULTS_LIMIT
            || self.search_bytes + page_bytes > SEARCH_BYTES_LIMIT;
        self.search_release_next = false;
        if release {
            let mut dropped = false;
            while !self.search_results.is_empty()
                && (self.search_results.len() + fresh.len() > SEARCH_RESULTS_LIMIT
                    || self.search_bytes + page_bytes > SEARCH_BYTES_LIMIT)
            {
                self.search_bytes = self
                    .search_bytes
                    .saturating_sub(Self::hit_cost(&self.search_results[0]));
                self.search_results.remove(0);
                dropped = true;
            }
            self.search_released |= dropped;
        }
        let mut left: Vec<chat_read::Hit> = Vec::new();
        for hit in fresh {
            let cost = Self::hit_cost(&hit);
            if self.search_results.len() < SEARCH_RESULTS_LIMIT
                && self.search_bytes + cost <= SEARCH_BYTES_LIMIT
            {
                self.search_bytes += cost;
                self.search_results.push(hit);
            } else {
                left.push(hit);
            }
        }
        self.search_remainder = left;
        self.search_full = !self.search_remainder.is_empty()
            || self.search_results.len() >= SEARCH_RESULTS_LIMIT
            || self.search_bytes >= SEARCH_BYTES_LIMIT;
    }

    /// The panel's "Load older results": drain what is already held, or
    /// ask for the next page **with the intent to make room for it**.
    pub fn search_load_older(&mut self, request_id: String, now_ms: u64) -> bool {
        if self.search.is_some()
            || !matches!(
                self.search_state,
                SearchState::Incomplete | SearchState::Gap
            )
        {
            return false;
        }
        if !self.search_remainder.is_empty() {
            let held = std::mem::take(&mut self.search_remainder);
            // The next page is known whole; give it room without asking
            // the core for anything.
            self.search_release_next = true;
            self.absorb_search_page(held);
            self.search_state = if self.search_full {
                SearchState::Incomplete
            } else {
                match self.search_tail.as_ref().map(|tail| tail.stop) {
                    Some(Stop::AtEnd) if !self.search_dirty => SearchState::End,
                    Some(Stop::AtEnd) | Some(Stop::Gap) => SearchState::Gap,
                    _ => SearchState::Incomplete,
                }
            };
            return true;
        }
        let Some(token) = self
            .search_tail
            .as_ref()
            .and_then(|tail| tail.next_token.clone())
        else {
            return false;
        };
        if !valid_request_id(&request_id) {
            return false;
        }
        self.search_resume = Some(token.clone());
        self.search = Some(SearchJob {
            request_id,
            query: self.search_query.clone().unwrap_or_default(),
            token: Some(token),
            job: None,
            begin_due: Some(now_ms),
            poll_due: None,
        });
        self.search_release_next = true;
        self.search_state = SearchState::Loading;
        true
    }

    /// Retry the page a failure/cancel interrupted. **Same query, same
    /// scan cursor, existing hits kept**; only when there is no cursor does
    /// it restart the query.
    pub fn retry_search(&mut self, request_id: String, now_ms: u64) -> bool {
        if !valid_request_id(&request_id) {
            return false;
        }
        let Some(query) = self.search_query.clone() else {
            return false;
        };
        if let Some(token) = self.search_resume.clone() {
            self.search = Some(SearchJob {
                request_id,
                query,
                token: Some(token),
                job: None,
                begin_due: Some(now_ms),
                poll_due: None,
            });
            self.search_state = SearchState::Loading;
            true
        } else {
            self.start_search(&query, request_id, now_ms)
        }
    }

    /// Ask a literal query of this group. The query is trimmed by the
    /// frozen ASCII rule before it is sent; an empty one asks nothing.
    pub fn start_search(&mut self, query: &str, request_id: String, now_ms: u64) -> bool {
        if !self.active || !valid_request_id(&request_id) {
            return false;
        }
        let query = chat_read::trim_query(query);
        if query.is_empty() || query.len() > chat_read::QUERY_LIMIT {
            return false;
        }
        if let Some(job) = self.search.take() {
            if let Some(job_id) = job.job {
                if let Ok(request) = (Request::SearchCancel { job_id }).encode() {
                    self.queue_cleanup(request);
                }
            }
        }
        self.search_results.clear();
        self.search_tail = None;
        self.search_dirty = false;
        self.search_auto = 0;
        self.search_remainder.clear();
        self.search_full = false;
        self.search_release_next = false;
        self.search_released = false;
        self.search_bytes = 0;
        self.search_resume = None;
        self.search_query = Some(query.to_owned());
        self.search_state = SearchState::Loading;
        self.search = Some(SearchJob::new(request_id, query.to_owned(), now_ms));
        true
    }

    /// Continue the same query from the scan cursor. The query cannot
    /// change between pages; the cursor alone is the question.
    pub fn search_more(&mut self, request_id: String, now_ms: u64) -> bool {
        if self.search.is_some() || !valid_request_id(&request_id) {
            return false;
        }
        let Some(token) = self
            .search_tail
            .as_ref()
            .and_then(|tail| tail.next_token.clone())
        else {
            return false;
        };
        let Some(query) = self.search_query.clone() else {
            return false;
        };
        self.search_resume = Some(token.clone());
        self.search = Some(SearchJob {
            request_id,
            query,
            token: Some(token),
            job: None,
            begin_due: Some(now_ms),
            poll_due: None,
        });
        self.search_state = SearchState::Loading;
        true
    }

    /// Empty query or a closed panel: stop the scan and forget the
    /// question. Hits already shown are dropped with it -- they answer a
    /// query nobody is asking any more.
    pub fn clear_search(&mut self) -> Option<Action> {
        let cancel = self.cancel_search();
        self.search_state = SearchState::Idle;
        self.search_query = None;
        self.search_results.clear();
        self.search_tail = None;
        self.search_dirty = false;
        self.search_auto = 0;
        self.search_remainder.clear();
        self.search_full = false;
        self.search_release_next = false;
        self.search_released = false;
        self.search_bytes = 0;
        self.search_resume = None;
        cancel
    }

    /// Stop the scan. The core answers about the job, not about the query.
    pub fn cancel_search(&mut self) -> Option<Action> {
        self.search_state = SearchState::Cancelled;
        let job = self.search.take()?;
        if let Some(token) = job.token.clone() {
            self.search_resume = Some(token);
        }
        job.job.and_then(|job_id| {
            Request::SearchCancel { job_id }
                .encode()
                .ok()
                .map(|request| Action::Cancel { request })
        })
    }

    fn push_tail(&mut self, message: Message) {
        // One answer per live read, but a re-read after a session change
        // can name the same anchor again; the tail keeps one row per
        // identity like the body does.
        if self.tail_rows.iter().any(|m| m.anchor == message.anchor) {
            return;
        }
        self.tail_rows.push(message);
        while self.tail_rows.len() > TAIL_LIMIT {
            self.tail_rows.remove(0);
            self.tail_gap = true;
        }
    }

    /// Stop the auxiliary scan without answering about the history. What
    /// the body already holds stays.
    pub fn cancel_older(&mut self) -> Option<Action> {
        self.older = OlderState::Cancelled;
        let aux = self.aux.take()?;
        aux.job.and_then(|job_id| {
            Request::Cancel { job_id }
                .encode()
                .ok()
                .map(|request| Action::Cancel { request })
        })
    }

    /// Put a cancel in the first free slot. Both slots full would mean
    /// three jobs, which this feed cannot have; the caller is not allowed
    /// to grow the set, so the extra is dropped rather than invented.
    fn queue_cleanup(&mut self, request: String) {
        for slot in &mut self.cleanup {
            if slot.is_none() {
                *slot = Some(Action::Cancel { request });
                return;
            }
        }
    }

    /// Drain a cancel this feed still owes. **A hidden page has no tick to
    /// ask**, so its caller takes these out and sends them itself.
    pub fn pending_cleanup(&mut self) -> Option<Action> {
        self.take_cleanup()
    }

    fn take_cleanup(&mut self) -> Option<Action> {
        for slot in &mut self.cleanup {
            if slot.is_some() {
                return slot.take();
            }
        }
        None
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
        self.older = OlderState::Idle;
        self.aux_error = None;
        self.auto_advances = 0;
        // **A page hidden mid-read comes back where it was.** The rows, the
        // reading mode and the live messages waiting aside are kept; only
        // a group change or an explicit refresh resets them.
        if !self.body.rows.is_empty()
            && self.session.is_some()
            && (self.reading_history || self.context_mode)
        {
            self.begin_id = None;
            self.begin_due = None;
            self.history_due = None;
            self.live_due = Some(now_ms);
            self.load = Load::Ready;
            return;
        }
        self.begin_due = Some(now_ms);
        self.live_due = None;
        self.history_due = None;
        if self.metadata.is_none() {
            self.metadata_due = Some(now_ms);
        }
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
        // The auxiliary scan goes into a cleanup slot; the bootstrap
        // job's cancel is what this call returns. A page hidden for a
        // moment keeps its rows and its tail, so `start` can show them
        // again and continue older from the same token.
        if let Some(aux) = self.aux.take() {
            if let Some(job_id) = aux.job {
                if let Ok(request) = (Request::Cancel { job_id }).encode() {
                    self.queue_cleanup(request);
                }
            }
        }
        self.older = OlderState::Idle;
        self.auto_advances = 0;
        // **A hidden page keeps its reading window, its tail and its
        // discontinuity**: coming back does not silently re-join them.
        if let Some(search) = self.search.take() {
            if let Some(job_id) = search.job {
                if let Ok(request) = (Request::SearchCancel { job_id }).encode() {
                    self.queue_cleanup(request);
                }
            }
            self.search_state = SearchState::Cancelled;
        }
        // **A ready reference answer nobody consumed yet is still the
        // host's to close.** `stop` may return early through the `?` below;
        // this must happen before it.
        self.discard_reference();
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
            limit: FIRST_CHUNK,
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
        let id_ok = envelope
            .request_id
            .as_deref()
            .map_or(true, |id| self.begin_id.as_deref() == Some(id));
        let current = envelope.kind == Kind::Begin
            && envelope.generation == self.generation
            && self.group.as_deref() == Some(envelope.group.as_str())
            && self.active
            && id_ok;
        if !current {
            // A begin that arrived too late: its job, if it named one and
            // is not a job this feed already holds, is cancelled once. The
            // old generation is not restored.
            return self.cancel_started(&transport);
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
                    // identities. **A bootstrap while reading history or a
                    // context window is an explicit refresh to the latest
                    // end**: the old window is replaced whole, never merged
                    // with the newest page in an invented order.
                    let session_changed = self
                        .session
                        .as_ref()
                        .is_some_and(|session| session != &page.session);
                    if session_changed || self.reading_history || self.context_mode {
                        self.body.clear();
                        self.tail_rows.clear();
                        self.reading_history = false;
                        self.context_mode = false;
                        self.around = None;
                        self.discard_reference();
                        self.context_older = None;
                        self.context_newer = None;
                        self.context_older_at_end = true;
                        self.context_newer_at_end = true;
                        self.context_older_dirty = false;
                        self.context_newer_dirty = false;
                        self.context_older_reanchor = None;
                        self.context_newer_reanchor = None;
                        self.context_remainder.clear();
                        self.history_gap = false;
                        self.tail_gap = false;
                        self.history_dirty = false;
                        self.tail = None;
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

    /// The answer to `chat_metadata`. A failure names itself; it never
    /// clears a brief that is already on screen.
    pub fn accept_metadata(
        &mut self,
        envelope: &Envelope,
        transport: Result<Transport, TransportError>,
        now_ms: u64,
    ) -> Option<Action> {
        if !self.active
            || envelope.kind != Kind::Metadata
            || envelope.generation != self.generation
            || self.group.as_deref() != Some(envelope.group.as_str())
        {
            return None;
        }
        match transport {
            Ok(Transport::NotReady) => {
                self.metadata_due = Some(now_ms + LIVE_PERIOD_MS);
                None
            }
            Err(err) => {
                self.metadata_error = Some(transport_word(err).to_owned());
                None
            }
            Ok(Transport::Body(text)) => match chat_read::decode_metadata(&text) {
                Err(_) => {
                    self.metadata_error = Some("Malformed".to_owned());
                    None
                }
                Ok(chat_read::MetadataOutcome::Failed(failure)) => {
                    self.metadata_error = Some(failure.error);
                    None
                }
                Ok(chat_read::MetadataOutcome::Data(meta)) => {
                    if meta.group == envelope.group {
                        self.metadata = Some(meta);
                        self.metadata_error = None;
                    }
                    None
                }
            },
        }
    }

    /// The answer to `chat_search_begin`. The query cannot change between
    /// pages; a reply that names another one is not this job's.
    pub fn accept_search_begin(
        &mut self,
        envelope: &Envelope,
        transport: Result<Transport, TransportError>,
        now_ms: u64,
    ) -> Option<Action> {
        let id_ok = envelope.request_id.as_deref().map_or(true, |id| {
            self.search.as_ref().is_some_and(|job| job.request_id == id)
        });
        let current = self.active
            && envelope.kind == Kind::SearchBegin
            && envelope.generation == self.generation
            && self.group.as_deref() == Some(envelope.group.as_str())
            && id_ok;
        if !current || self.search.is_none() {
            // A search begin that arrived too late; its job is cancelled
            // unless the feed already holds it.
            let Ok(Transport::Body(text)) = &transport else {
                return None;
            };
            let Ok(chat_read::SearchBeginOutcome::Started(start)) =
                chat_read::decode_search_begin(text)
            else {
                return None;
            };
            let held = self
                .search
                .as_ref()
                .and_then(|job| job.job.as_ref())
                .is_some_and(|job| *job == start.job_id);
            if held {
                return None;
            }
            return Request::SearchCancel {
                job_id: start.job_id,
            }
            .encode()
            .ok()
            .map(|request| Action::Cancel { request });
        }
        match transport {
            Ok(Transport::NotReady) => {
                if let Some(job) = self.search.as_mut() {
                    job.begin_due = Some(now_ms + LIVE_PERIOD_MS);
                }
                None
            }
            Err(err) => {
                self.fail_search(transport_word(err));
                None
            }
            Ok(Transport::Body(text)) => match chat_read::decode_search_begin(&text) {
                Err(_) => {
                    self.fail_search("Malformed");
                    None
                }
                Ok(chat_read::SearchBeginOutcome::Failed(failure)) => {
                    if failure.error == "Busy" {
                        if let Some(job) = self.search.as_mut() {
                            job.begin_due = Some(now_ms + HISTORY_POLL_MS);
                        }
                    } else {
                        self.fail_search(&failure.error);
                    }
                    None
                }
                Ok(chat_read::SearchBeginOutcome::Started(start)) => {
                    let matches = self
                        .search
                        .as_ref()
                        .is_some_and(|job| job.query == start.query);
                    if start.group != envelope.group
                        || self.session.as_deref() != Some(start.session.as_str())
                        || !matches
                    {
                        let cancel = Request::SearchCancel {
                            job_id: start.job_id,
                        }
                        .encode()
                        .ok()
                        .map(|request| Action::Cancel { request });
                        self.fail_search("CursorMismatch");
                        return cancel;
                    }
                    self.search_query = Some(start.query);
                    if let Some(job) = self.search.as_mut() {
                        job.job = Some(start.job_id);
                        job.begin_due = None;
                        job.poll_due = Some(now_ms + HISTORY_POLL_MS);
                    }
                    None
                }
            },
        }
    }

    /// The answer to `chat_search_poll`. Hits accumulate; a page that
    /// stopped on its budget with no hit is progress, not "no results".
    pub fn accept_search_poll(
        &mut self,
        envelope: &Envelope,
        transport: Result<Transport, TransportError>,
        now_ms: u64,
    ) -> Option<Action> {
        if !self.active
            || envelope.kind != Kind::SearchPoll
            || envelope.generation != self.generation
            || self.group.as_deref() != Some(envelope.group.as_str())
            || self.search.is_none()
        {
            return None;
        }
        if let Some(job_id) = envelope.job_id.as_deref() {
            if self.search.as_ref().and_then(|job| job.job.as_deref()) != Some(job_id) {
                return None;
            }
        }
        match transport {
            Ok(Transport::NotReady) => {
                if let Some(job) = self.search.as_mut() {
                    job.poll_due = Some(now_ms + HISTORY_POLL_MS);
                }
                None
            }
            Err(err) => {
                self.fail_search(transport_word(err));
                None
            }
            Ok(Transport::Body(text)) => match chat_read::decode_search_poll(&text) {
                Err(_) => {
                    self.fail_search("Malformed");
                    None
                }
                Ok(chat_read::SearchPollOutcome::Failed(failure)) => {
                    match failure.error.as_str() {
                        "Busy" => {
                            if let Some(job) = self.search.as_mut() {
                                job.poll_due = Some(now_ms + HISTORY_POLL_MS);
                            }
                        }
                        "TooLarge" => {
                            if let Some(job) = self.search.as_mut() {
                                if let Some(token) = failure.next_token.clone() {
                                    job.token = Some(token);
                                }
                            }
                            self.fail_search("TooLarge");
                        }
                        other => self.fail_search(other),
                    }
                    None
                }
                Ok(chat_read::SearchPollOutcome::Pending(status)) => {
                    let changed = self
                        .search
                        .as_ref()
                        .is_some_and(|job| job.query != status.query);
                    if changed {
                        self.fail_search("CursorMismatch");
                    } else if let Some(job) = self.search.as_mut() {
                        job.poll_due = Some(now_ms + HISTORY_POLL_MS);
                    }
                    None
                }
                Ok(chat_read::SearchPollOutcome::Cancelled(_)) => {
                    if let Some(token) = self.search.as_ref().and_then(|job| job.token.clone()) {
                        self.search_resume = Some(token);
                    }
                    self.search = None;
                    self.search_state = SearchState::Cancelled;
                    None
                }
                Ok(chat_read::SearchPollOutcome::Ready(page)) => {
                    let expected = self.search.as_ref().and_then(|job| job.job.clone());
                    if expected.as_deref() != Some(page.job_id.as_str())
                        || page.group != envelope.group
                        || self.session.as_deref() != Some(page.session.as_str())
                        || self
                            .search
                            .as_ref()
                            .is_some_and(|job| job.query != page.query)
                    {
                        return None;
                    }
                    let results_empty = page.results.is_empty();
                    let next_token = page.next_token.clone();
                    // **One bounded page at a time**: if it needs room, the
                    // newest kept hits are released and the whole page is
                    // taken, so no result is consumed then dropped.
                    self.absorb_search_page(page.results);
                    self.search_dirty |= page.gap || page.restarted;
                    self.search_tail = Some(SearchTail {
                        stop: page.stop,
                        next_token: page.next_token,
                        restarted: page.restarted,
                        gap: page.gap,
                    });
                    self.search = None;
                    if !self.search_full {
                        self.search_resume = next_token.clone();
                    }
                    if !results_empty {
                        self.search_auto = 0;
                    }
                    self.search_state = match page.stop {
                        Stop::AtEnd if !self.search_dirty => SearchState::End,
                        Stop::AtEnd => SearchState::Gap,
                        Stop::Gap => SearchState::Gap,
                        _ => SearchState::Incomplete,
                    };
                    // **An empty budget page is progress**: follow its
                    // continuation on this query, up to the same bounded
                    // count the history scan uses. A person can continue
                    // from the panel when the cap is reached.
                    if results_empty
                        && matches!(page.stop, Stop::Budget | Stop::Full)
                        && next_token.is_some()
                    {
                        if self.search_auto < AUTO_ADVANCE_LIMIT {
                            self.search_auto += 1;
                            self.search = Some(SearchJob {
                                request_id: (self.next_id)().unwrap_or_default(),
                                query: page.query.clone(),
                                token: next_token,
                                job: None,
                                begin_due: Some(now_ms),
                                poll_due: None,
                            });
                            if self
                                .search
                                .as_ref()
                                .is_some_and(|job| valid_request_id(&job.request_id))
                            {
                                self.search_state = SearchState::Loading;
                            } else {
                                self.search = None;
                                self.search_state = SearchState::Incomplete;
                            }
                        }
                    }
                    None
                }
            },
        }
    }

    fn fail_search(&mut self, code: &str) {
        // **The interrupted page is remembered**, so a retry continues
        // from it instead of clearing the shown results and starting over.
        if let Some(token) = self.search.as_ref().and_then(|job| job.token.clone()) {
            self.search_resume = Some(token);
        }
        self.search = None;
        self.search_state = SearchState::Failed(code.to_owned());
    }

    /// The answer to an older page's begin. It is the ordinary history
    /// begin shape (with its snapshot and water marks); only the job's
    /// identity is taken, because the live end belongs to the bootstrap
    /// that is already running.
    pub fn accept_aux_begin(
        &mut self,
        envelope: &Envelope,
        transport: Result<Transport, TransportError>,
        now_ms: u64,
    ) -> Option<Action> {
        let id_ok = envelope.request_id.as_deref().map_or(true, |id| {
            self.aux.as_ref().is_some_and(|aux| aux.request_id == id)
        });
        let current = self.active
            && envelope.kind == Kind::AuxBegin
            && envelope.generation == self.generation
            && self.group.as_deref() == Some(envelope.group.as_str())
            && id_ok;
        if !current || self.aux.is_none() {
            // A begin that arrived after this feed stopped wanting it: its
            // job is cancelled, and nothing is applied.
            return self.cancel_started(&transport);
        }
        match transport {
            Ok(Transport::NotReady) => {
                if let Some(aux) = self.aux.as_mut() {
                    aux.begin_due = Some(now_ms + LIVE_PERIOD_MS);
                }
                None
            }
            Err(err) => {
                self.fail_aux(transport_word(err));
                None
            }
            Ok(Transport::Body(text)) => {
                let older = self
                    .aux
                    .as_ref()
                    .is_some_and(|aux| aux.kind == AuxKind::Older);
                if older {
                    match chat_read::decode_begin(&text) {
                        Err(_) => {
                            self.fail_aux("Malformed");
                            None
                        }
                        Ok(BeginOutcome::Failed(failure)) => {
                            self.aux_begin_failure(now_ms, &failure);
                            None
                        }
                        Ok(BeginOutcome::Started(page)) => self.aux_started(
                            page.job_id,
                            &page.group,
                            &page.session,
                            envelope,
                            now_ms,
                        ),
                    }
                } else {
                    match chat_read::decode_aux_begin(&text) {
                        Err(_) => {
                            self.fail_aux("Malformed");
                            None
                        }
                        Ok(chat_read::AuxBeginOutcome::Failed(failure)) => {
                            self.aux_begin_failure(now_ms, &failure);
                            None
                        }
                        Ok(chat_read::AuxBeginOutcome::Started(start)) => self.aux_started(
                            start.job_id,
                            &start.group,
                            &start.session,
                            envelope,
                            now_ms,
                        ),
                    }
                }
            }
        }
    }

    fn aux_started(
        &mut self,
        job_id: String,
        group: &str,
        session: &str,
        envelope: &Envelope,
        now_ms: u64,
    ) -> Option<Action> {
        if group != envelope.group {
            return cancel_job(&job_id);
        }
        // An anchor, a token or a reference belongs to the session that
        // issued it. A page from another run cannot be spliced in.
        if self.session.as_deref() != Some(session) {
            let cancel = cancel_job(&job_id);
            self.fail_aux("CursorStale");
            return cancel;
        }
        if let Some(aux) = self.aux.as_mut() {
            aux.job = Some(job_id);
            aux.begin_due = None;
            aux.poll_due = Some(now_ms + HISTORY_POLL_MS);
        }
        None
    }

    fn aux_begin_failure(&mut self, now_ms: u64, failure: &Failure) {
        match failure.error.as_str() {
            "Busy" => {
                if let Some(aux) = self.aux.as_mut() {
                    aux.begin_due = Some(now_ms + HISTORY_POLL_MS);
                }
            }
            "TooLarge" => {
                // Keep the token an explicit retry can use; never skip it.
                if let Some(token) = failure.next_token.clone() {
                    if let Some(aux) = self.aux.as_mut() {
                        aux.token = Some(token);
                    }
                }
                self.fail_aux("TooLarge");
            }
            other => self.fail_aux(other),
        }
    }

    fn fail_aux(&mut self, code: &str) {
        match self.aux.as_ref().map(|aux| aux.kind) {
            Some(AuxKind::Around) | Some(AuxKind::Reference) => {
                self.aux_error = Some(code.to_owned())
            }
            Some(AuxKind::Context) => {
                self.aux_error = Some(code.to_owned());
                self.older = OlderState::Failed(code.to_owned());
                self.context_retry_at = self.context_asked_ms.saturating_add(AUX_RETRY_MS);
            }
            _ => {
                self.older = OlderState::Failed(code.to_owned());
                self.older_retry_at = self.older_asked_ms.saturating_add(AUX_RETRY_MS);
            }
        }
        self.aux = None;
    }

    /// A begin reply this feed no longer wants. **Its job is cancelled even
    /// when there is nothing to show**, unless the id is one of the jobs
    /// this feed still holds -- a duplicate reply must not cancel the scan
    /// it belongs to.
    fn cancel_started(&self, transport: &Result<Transport, TransportError>) -> Option<Action> {
        let Ok(Transport::Body(text)) = transport else {
            return None;
        };
        let job_id = match chat_read::decode_begin(text) {
            Ok(BeginOutcome::Started(page)) => Some(page.job_id),
            _ => match chat_read::decode_aux_begin(text) {
                Ok(chat_read::AuxBeginOutcome::Started(start)) => Some(start.job_id),
                _ => None,
            },
        }?;
        let held_by_bootstrap = self.job.as_ref().is_some_and(|job| job.id == job_id);
        let held_by_aux = self
            .aux
            .as_ref()
            .and_then(|aux| aux.job.as_ref())
            .is_some_and(|job| *job == job_id);
        if held_by_bootstrap || held_by_aux {
            return None;
        }
        cancel_job(&job_id)
    }

    /// The answer to an older page's poll. **The page is the ordinary
    /// history page**: a `budget` page with no rows is progress, not the
    /// beginning of the group.
    pub fn accept_aux_poll(
        &mut self,
        envelope: &Envelope,
        transport: Result<Transport, TransportError>,
        now_ms: u64,
    ) -> Option<Action> {
        if !self.active
            || envelope.kind != Kind::AuxPoll
            || envelope.generation != self.generation
            || self.group.as_deref() != Some(envelope.group.as_str())
        {
            // **The guard is before every state mutation and after the
            // answer was minted**: a late/stale reference ticket is still
            // the host's to close, even when none of the feed's properties
            // will ever hold it.
            if envelope.kind == Kind::AuxPoll {
                self.park_reference_answer(&transport);
            }
            return None;
        }
        if self.aux.is_none() {
            // The navigation was cancelled/closed: its ready page may still
            // carry a ticket nobody adopted.
            self.park_reference_answer(&transport);
            return None;
        }
        // **A reply for another job or another navigation is dropped
        // before any state is touched**; it must not fail the task that is
        // current now. A reference ticket already minted is handed back.
        let mut stale = false;
        if let Some(job_id) = envelope.job_id.as_deref() {
            if self.aux.as_ref().and_then(|aux| aux.job.as_deref()) != Some(job_id) {
                stale = true;
            }
        }
        if envelope.nav != 0 && envelope.nav != self.nav_epoch {
            stale = true;
        }
        if stale {
            self.park_reference_answer(&transport);
            return None;
        }
        match transport {
            Ok(Transport::NotReady) => {
                if let Some(aux) = self.aux.as_mut() {
                    aux.poll_due = Some(now_ms + HISTORY_POLL_MS);
                }
                None
            }
            Err(err) => {
                self.fail_aux(transport_word(err));
                None
            }
            Ok(Transport::Body(text)) => {
                let kind = self.aux.as_ref().map(|aux| aux.kind);
                match chat_read::decode_poll(&text) {
                    Err(_) => {
                        // **A page that fails the strict source check can
                        // still name a minted ticket.** Validation and
                        // cleanup are separate responsibilities.
                        self.park_reference_text(&text);
                        self.fail_aux("Malformed");
                        None
                    }
                    Ok(chat_read::PollOutcome::Failed(failure)) => {
                        self.aux_poll_failure(now_ms, &failure);
                        None
                    }
                    Ok(chat_read::PollOutcome::Pending(_)) => {
                        if let Some(aux) = self.aux.as_mut() {
                            aux.poll_due = Some(now_ms + HISTORY_POLL_MS);
                        }
                        None
                    }
                    Ok(chat_read::PollOutcome::Cancelled(_)) => {
                        // The core cancelled the scan; that is not the end
                        // of the history and not an empty body.
                        self.aux = None;
                        match kind {
                            Some(AuxKind::Older) => self.older = OlderState::Cancelled,
                            _ => self.aux_error = Some("Cancelled".to_owned()),
                        }
                        None
                    }
                    Ok(chat_read::PollOutcome::Ready(page)) if kind == Some(AuxKind::Older) => {
                        let expected = self.aux.as_ref().and_then(|a| a.job.clone());
                        if expected.as_deref() != Some(page.job_id.as_str()) {
                            return None;
                        }
                        if page.group != envelope.group {
                            return None;
                        }
                        if self.session.as_deref() != Some(page.session.as_str()) {
                            self.fail_aux("CursorStale");
                            return None;
                        }
                        self.aux = None;
                        let empty = page.messages.is_empty();
                        let token = page.next_token.clone();
                        let trimmed = self.body.absorb_front(page.messages, true);
                        self.history_gap |= trimmed;
                        self.history_dirty |= page.gap || page.restarted;
                        self.tail = Some(Tail {
                            stop: page.stop,
                            next_token: page.next_token,
                            restarted: page.restarted,
                            gap: page.gap,
                            dirty: self.history_dirty,
                        });
                        self.history_error = None;
                        // **`at_end` is only the beginning when the page is
                        // complete**: a gap or a restarted log says
                        // records are missing from the range.
                        let complete_end = page.stop == Stop::AtEnd && !self.history_dirty;
                        match page.stop {
                            Stop::AtEnd if complete_end => {
                                self.auto_advances = 0;
                                self.older = OlderState::End;
                            }
                            Stop::AtEnd => {
                                self.auto_advances = 0;
                                self.older = OlderState::Gap;
                            }
                            Stop::Gap if token.is_none() => {
                                self.auto_advances = 0;
                                self.older = OlderState::Gap;
                            }
                            Stop::Budget | Stop::Full if empty => {
                                // **A budget page with no rows is progress.**
                                match token {
                                    Some(next) if self.auto_advances < AUTO_ADVANCE_LIMIT => {
                                        self.auto_advances += 1;
                                        self.start_older_with_token(next, now_ms);
                                    }
                                    Some(_) => {
                                        // Eight empty pages in a row: stop
                                        // stepping, but **not as "beginning
                                        // of the group"** -- the core has not
                                        // said there is nothing older, only
                                        // that these pages held nothing.
                                        self.auto_advances = 0;
                                        self.older = OlderState::Incomplete;
                                        self.older_retry_at =
                                            now_ms.saturating_add(AUX_RETRY_MS);
                                    }
                                    None => {
                                        // An empty page with no continuation:
                                        // this really is the beginning.
                                        self.auto_advances = 0;
                                        self.older = OlderState::End;
                                    }
                                }
                            }
                            _ => {
                                self.auto_advances = 0;
                                self.older = OlderState::Incomplete;
                                self.older_retry_at = now_ms.saturating_add(AUX_RETRY_MS);
                            }
                        }
                        self.load = if self.body.rows.is_empty() {
                            match self.older {
                                OlderState::End => Load::Empty,
                                _ => Load::Loading,
                            }
                        } else {
                            Load::Ready
                        };
                        None
                    }
                    Ok(chat_read::PollOutcome::ReadyContext(page))
                        if kind == Some(AuxKind::Context) =>
                    {
                        let expected = self.aux.as_ref().and_then(|a| a.job.clone());
                        let nav_ok = self.aux.as_ref().map(|a| a.nav) == Some(self.nav_epoch);
                        if expected.as_deref() != Some(page.job_id.as_str())
                            || page.group != envelope.group
                            || self.session.as_deref() != Some(page.session.as_str())
                            || !nav_ok
                        {
                            self.fail_aux("ContextStale");
                            return None;
                        }
                        self.aux = None;
                        match page.direction {
                            chat_read::Direction::Older => {
                                let trimmed = self.body.absorb_front(page.messages, true);
                                self.history_gap |= trimmed;
                                self.context_older_dirty |= page.gap || page.restarted;
                                self.context_newer_dirty |= page.gap || page.restarted;
                                // **Only this direction's outer edge moved**;
                                // the other cursor still names the retained
                                // edge of that side.
                                self.context_older = page.older_token.clone();
                                self.context_older_at_end =
                                    page.older_at_end && !self.context_older_dirty;
                                if trimmed {
                                    // **The newest edge moved**, so the old
                                    // newer cursor names rows no longer in
                                    // the window. The retained edge is kept
                                    // for a re-anchoring `around`.
                                    let edge =
                                        self.body.rows.last().map(|row| row.message.anchor.clone());
                                    self.context_newer = None;
                                    self.context_newer_at_end = false;
                                    self.context_newer_reanchor = edge;
                                    self.context_remainder.clear();
                                }
                            }
                            chat_read::Direction::Newer => {
                                // **Take the whole page**: the opposite
                                // (older) edge gives way, and its cursor is
                                // replaced by a re-anchor point on the row
                                // that stayed.
                                let before =
                                    self.body.rows.first().map(|row| row.message.anchor.clone());
                                for message in page.messages {
                                    let _ = self.body.absorb(message);
                                }
                                let after =
                                    self.body.rows.first().map(|row| row.message.anchor.clone());
                                self.context_newer_dirty |= page.gap || page.restarted;
                                self.context_older_dirty |= page.gap || page.restarted;
                                self.context_newer = page.newer_token.clone();
                                self.context_newer_at_end =
                                    page.newer_at_end && !self.context_newer_dirty;
                                if before != after {
                                    self.context_older = None;
                                    self.context_older_at_end = false;
                                    self.context_older_reanchor = after;
                                    self.context_remainder.clear();
                                }
                            }
                        }
                        // **A gap or restart in a located window cools its
                        // own door**: the missing range is not asked for
                        // again on every wheel notch.
                        if page.gap || page.restarted {
                            self.context_retry_at = now_ms.saturating_add(AUX_RETRY_MS);
                        }
                        self.load = if self.body.rows.is_empty() {
                            Load::Empty
                        } else {
                            Load::Ready
                        };
                        None
                    }
                    Ok(chat_read::PollOutcome::ReadyAround(page))
                        if kind == Some(AuxKind::Around) =>
                    {
                        let expected = self.aux.as_ref().and_then(|a| a.job.clone());
                        let anchor = self.aux.as_ref().and_then(|a| a.anchor.clone());
                        if expected.as_deref() != Some(page.job_id.as_str())
                            || page.group != envelope.group
                            || self.session.as_deref() != Some(page.session.as_str())
                            || self.aux.as_ref().map(|a| a.nav) != Some(self.nav_epoch)
                            || !page.messages.get(page.target_index).is_some_and(|m| {
                                // A live row promoted to its persisted
                                // identity keeps the live anchor as the
                                // alias the question named.
                                Some(m.anchor.as_str()) == anchor.as_deref()
                                    || m.live_anchor.as_deref() == anchor.as_deref()
                            })
                        {
                            self.fail_aux("AnchorMismatch");
                            return None;
                        }
                        self.aux = None;
                        self.aux_error = None;
                        self.context_older = page.older_token.clone();
                        self.context_newer = page.newer_token.clone();
                        self.context_older_dirty = page.gap || page.restarted;
                        self.context_newer_dirty = page.gap || page.restarted;
                        self.context_older_at_end = page.older_at_end && !self.context_older_dirty;
                        self.context_newer_at_end = page.newer_at_end && !self.context_newer_dirty;
                        self.context_older_reanchor = None;
                        self.context_newer_reanchor = None;
                        self.context_remainder.clear();
                        // **An explicit context view**: the left side now
                        // shows this target and its immediate neighbours,
                        // not a window spliced onto the previous rows.
                        self.body.clear();
                        for message in &page.messages {
                            let _ = self.body.absorb(message.clone());
                        }
                        self.reading_history = true;
                        self.context_mode = true;
                        self.history_gap = false;
                        self.tail = None;
                        self.load = if self.body.rows.is_empty() {
                            Load::Empty
                        } else {
                            Load::Ready
                        };
                        self.around = Some(page);
                        None
                    }
                    Ok(chat_read::PollOutcome::ReadyReference(page))
                        if kind == Some(AuxKind::Reference) =>
                    {
                        let expected = self.aux.as_ref().and_then(|a| a.job.clone());
                        let want_anchor = self.aux.as_ref().and_then(|a| a.anchor.clone());
                        let want_ref = self.aux.as_ref().and_then(|a| a.reference.clone());
                        if expected.as_deref() != Some(page.job_id.as_str())
                            || page.group != envelope.group
                            || self.session.as_deref() != Some(page.session.as_str())
                            || self.aux.as_ref().map(|a| a.nav) != Some(self.nav_epoch)
                            || !(want_anchor.as_deref() == Some(page.source_anchor.as_str())
                                || want_anchor.as_deref() == page.source_live_anchor.as_deref())
                            || want_ref.as_deref() != Some(page.original_reference.as_str())
                        {
                            self.park_reference_page(&page);
                            self.fail_aux("ReferenceMismatch");
                            return None;
                        }
                        self.aux = None;
                        self.aux_error = None;
                        self.reference = Some(page);
                        None
                    }
                    Ok(chat_read::PollOutcome::ReadyReference(page)) => {
                        // **A well-formed reference answer on an Older /
                        // Context / Around job is still a minted ticket**:
                        // it is not this job's answer, but it is the host's
                        // to close.
                        self.park_reference_page(&page);
                        self.fail_aux("Malformed");
                        None
                    }
                    Ok(_) => {
                        // A page of another mode on this job is not this
                        // feed's answer.
                        self.fail_aux("Malformed");
                        None
                    }
                }
            }
        }
    }

    fn aux_poll_failure(&mut self, now_ms: u64, failure: &Failure) {
        match failure.error.as_str() {
            "Busy" => {
                if let Some(aux) = self.aux.as_mut() {
                    aux.poll_due = Some(now_ms + HISTORY_POLL_MS);
                }
            }
            "TooLarge" => {
                if let Some(token) = failure.next_token.clone() {
                    if let Some(aux) = self.aux.as_mut() {
                        aux.token = Some(token);
                    }
                }
                self.fail_aux("TooLarge");
            }
            other => self.fail_aux(other),
        }
    }

    fn start_older_with_token(&mut self, token: String, now_ms: u64) {
        let Some(request_id) = (self.next_id)() else {
            self.fail_aux("BadRequestId");
            return;
        };
        if !valid_request_id(&request_id) {
            self.fail_aux("BadRequestId");
            return;
        }
        self.older = OlderState::Loading;
        // A backwards scan is a history read even when nobody scrolled:
        // new live rows wait aside instead of trimming the page in front.
        self.reading_history = true;
        self.aux = Some(Aux::older(request_id, token, now_ms));
    }

    /// At most one ordinary read per tick. A due begin first, then the two
    /// clocks in turn when both are due -- history cannot starve live.
    /// Nothing is produced while the page is not visible.
    pub fn next_action(&mut self, now_ms: u64) -> Option<Action> {
        // A cancel this feed owes for a job it dropped goes first -- even
        // when the page is no longer visible, because a dropped job must
        // not keep scanning -- and it leaves the slot as it is taken: at
        // most once.
        if let Some(action) = self.take_cleanup() {
            return Some(action);
        }
        if !self.active {
            return None;
        }
        // The header's brief and members are one in-memory read; it goes
        // before the first page so a group with no history still has them.
        if self.metadata_due.map_or(false, |at| now_ms >= at) {
            self.metadata_due = None;
            return self.metadata_action();
        }
        if self.begin_id.is_some() && self.begin_due.map_or(false, |at| now_ms >= at) {
            self.begin_due = None;
            return self.begin_action();
        }
        // The auxiliary scan's own begin goes before any poll, so an older
        // page is actually asked for on this tick.
        if self
            .aux
            .as_ref()
            .and_then(|aux| aux.begin_due)
            .map_or(false, |at| now_ms >= at)
        {
            if let Some(aux) = self.aux.as_mut() {
                aux.begin_due = None;
            }
            return self.aux_begin_action();
        }
        if let Some(job) = self.search.as_ref() {
            if job.begin_due.map_or(false, |at| now_ms >= at) {
                if let Some(job) = self.search.as_mut() {
                    job.begin_due = None;
                }
                return self.search_begin_action();
            }
        }
        let live = self.live_due.map_or(false, |at| now_ms >= at);
        let history = self
            .job
            .as_ref()
            .is_some_and(|_| self.history_due.map_or(false, |at| now_ms >= at));
        let aux = self
            .aux
            .as_ref()
            .is_some_and(|aux| aux.job.is_some() && aux.poll_due.map_or(false, |at| now_ms >= at));
        let search = self
            .search
            .as_ref()
            .is_some_and(|job| job.job.is_some() && job.poll_due.map_or(false, |at| now_ms >= at));
        // Four clocks, one read a tick: round-robin so no scan is starved
        // by another.
        let due = [live, history, aux, search];
        if !due.iter().any(|d| *d) {
            return None;
        }
        let start = self.poll_turn as usize % due.len();
        let pick = (0..due.len())
            .map(|k| (start + k) % due.len())
            .find(|i| due[*i])?;
        self.poll_turn = ((pick + 1) % due.len()) as u8;
        match pick {
            0 => self.live_now(),
            1 => self.poll_now(),
            2 => self.aux_poll_now(),
            _ => self.search_poll_now(),
        }
    }

    fn search_begin_action(&self) -> Option<Action> {
        let job = self.search.as_ref()?;
        let group = self.group.as_deref()?;
        let request = Request::SearchBegin {
            group: group.to_owned(),
            request_id: job.request_id.clone(),
            query: job.query.clone(),
            limit: SEARCH_CHUNK,
            resume_token: job.token.clone(),
        }
        .encode()
        .ok()?;
        Some(Action::SearchBegin { request })
    }

    fn search_poll_now(&mut self) -> Option<Action> {
        let job = self.search.as_mut()?;
        job.poll_due = None;
        let id = job.job.as_ref()?;
        Request::SearchPoll { job_id: id.clone() }
            .encode()
            .ok()
            .map(|request| Action::SearchPoll { request })
    }

    fn metadata_action(&self) -> Option<Action> {
        let group = self.group.as_deref()?;
        let request = Request::Metadata {
            group: group.to_owned(),
        }
        .encode()
        .ok()?;
        Some(Action::Metadata { request })
    }

    fn aux_begin_action(&self) -> Option<Action> {
        let aux = self.aux.as_ref()?;
        let group = self.group.as_deref()?;
        // **An ordinary history continuation is not `mode:"context"`.** The
        // token a history page hands back is asked for with the legacy
        // `chat_history_begin` shape, which every core already serves.
        // `mode:"context"` belongs to the around page's two directions.
        let request = match aux.kind {
            AuxKind::Older => Request::Begin {
                group: group.to_owned(),
                request_id: aux.request_id.clone(),
                // One older block, not a first screen: 50.
                limit: OLDER_CHUNK,
                resume_token: aux.token.clone(),
            },
            AuxKind::Around => Request::AroundBegin {
                group: group.to_owned(),
                request_id: aux.request_id.clone(),
                anchor: aux.anchor.clone()?,
                location: aux.location.clone(),
                before: aux.before,
                after: aux.after,
            },
            AuxKind::Reference => Request::ReferenceBegin {
                group: group.to_owned(),
                request_id: aux.request_id.clone(),
                anchor: aux.anchor.clone()?,
                location: aux.location.clone(),
                original_reference: aux.reference.clone()?,
            },
            AuxKind::Context => Request::ContextBegin {
                group: group.to_owned(),
                request_id: aux.request_id.clone(),
                resume_token: aux.token.clone()?,
                // The around window's own continuation keeps its own size.
                limit: CONTEXT_CHUNK,
            },
        }
        .encode()
        .ok()?;
        Some(Action::AuxBegin { request })
    }

    fn aux_poll_now(&mut self) -> Option<Action> {
        let aux = self.aux.as_mut()?;
        aux.poll_due = None;
        let job = aux.job.as_ref()?;
        poll_action(job).map(|action| match action {
            Action::Poll { request } => Action::AuxPoll { request },
            other => other,
        })
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
                        // **Both jobs are dropped here, and both are
                        // cancelled**: the auxiliary scan goes into its own
                        // cleanup slot, not over the bootstrap job's.
                        if let Some(aux) = self.aux.take() {
                            if let Some(job_id) = aux.job {
                                if let Ok(request) = (Request::Cancel { job_id }).encode() {
                                    self.queue_cleanup(request);
                                }
                            }
                        }
                        self.older = OlderState::Idle;
                        self.auto_advances = 0;
                        self.reading_history = false;
                        self.context_mode = false;
                        self.tail_rows.clear();
                        self.history_gap = false;
                        self.tail_gap = false;
                        if let Some(search) = self.search.take() {
                            if let Some(job_id) = search.job {
                                if let Ok(request) = (Request::SearchCancel { job_id }).encode() {
                                    self.queue_cleanup(request);
                                }
                            }
                        }
                        self.search_state = SearchState::Idle;
                        self.search_query = None;
                        self.search_results.clear();
                        self.search_tail = None;
                        self.around = None;
                        self.discard_reference();
                        self.context_older = None;
                        self.context_newer = None;
                        self.context_older_at_end = true;
                        self.context_newer_at_end = true;
                        self.context_older_dirty = false;
                        self.context_newer_dirty = false;
                        self.context_older_reanchor = None;
                        self.context_newer_reanchor = None;
                        self.context_remainder.clear();
                        self.aux_error = None;
                        // **A new core run is a new identity space.** The
                        // old session's live rows cannot be merged with a
                        // new bootstrap: drop them and bump the generation
                        // so every reply from the old run is refused.
                        self.body.clear();
                        self.tail = None;
                        self.history_dirty = false;
                        self.session = None;
                        self.live_next = 0;
                        self.generation += 1;
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
                        if self.reading_history {
                            // **The reading window keeps what is being
                            // read.** New messages wait in their own
                            // bounded tail until the person returns to the
                            // latest end.
                            self.push_tail(message);
                        } else if !self.body.absorb(message) {
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
            // A reference answer on this door still carries a minted
            // ticket; the owner-checked ledger gets it even though the
            // page is refused before any state is touched.
            if envelope.kind == Kind::Poll {
                self.park_reference_answer(&transport);
            }
            return None;
        }
        if let Some(job_id) = envelope.job_id.as_deref() {
            if self.job.as_ref().map(|job| job.id.as_str()) != Some(job_id) {
                self.park_reference_answer(&transport);
                return None;
            }
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
                    // **The current bootstrap door needs the same cleanup
                    // as every other refusal**: a reference page whose
                    // strict source check failed can still name a minted
                    // ticket, and this branch is reached with a matching
                    // group/generation/job.
                    self.park_reference_text(&text);
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
                        Load::Cancelled
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
                    // A bootstrap answers about the newest end, so any
                    // messages that waited while the person read history
                    // join the body now.
                    let waiting = std::mem::take(&mut self.tail_rows);
                    for message in waiting {
                        self.body.absorb(message);
                    }
                    self.reading_history = false;
                    self.history_gap = false;
                    self.tail_gap = false;
                    self.history_dirty |= page.gap || page.restarted;
                    let empty = page.messages.is_empty();
                    let token = page.next_token.clone();
                    let _ = self.body.absorb_front(page.messages, false);
                    self.tail = Some(Tail {
                        stop: page.stop,
                        next_token: page.next_token,
                        restarted: page.restarted,
                        gap: page.gap,
                        dirty: self.history_dirty,
                    });
                    self.job = None;
                    self.history_due = None;
                    self.history_error = None;
                    self.rebootstrap_used = false;
                    if empty && matches!(page.stop, Stop::Budget | Stop::Full) {
                        if let Some(next) = token {
                            // The newest page consumed the whole budget
                            // without a record: step to its continuation
                            // instead of showing an empty group.
                            if self.auto_advances < AUTO_ADVANCE_LIMIT {
                                self.auto_advances += 1;
                                self.start_older_with_token(next, now_ms);
                            }
                        }
                    }
                    let dirty = self.history_dirty;
                    self.load = if self.body.rows.is_empty() {
                        if dirty {
                            Load::Gap
                        } else {
                            match self.older {
                                OlderState::End => Load::Empty,
                                OlderState::Gap => Load::Gap,
                                OlderState::Idle => {
                                    if self
                                        .tail
                                        .as_ref()
                                        .and_then(|t| t.next_token.as_deref())
                                        .is_some()
                                    {
                                        Load::Loading
                                    } else {
                                        Load::Empty
                                    }
                                }
                                _ => Load::Loading,
                            }
                        }
                    } else {
                        Load::Ready
                    };
                    if self.aux.is_some() {
                        self.older = OlderState::Loading;
                    }
                    None
                }
                Ok(chat_read::PollOutcome::ReadyContext(_))
                | Ok(chat_read::PollOutcome::ReadyAround(_)) => {
                    // The bootstrap asked for the newest history page, not
                    // a direction cursor or an around window: either here
                    // is not this job's answer.
                    self.history_error = Some("Malformed".to_owned());
                    self.job = None;
                    self.history_due = None;
                    None
                }
                Ok(chat_read::PollOutcome::ReadyReference(page)) => {
                    // **A reference answer of the wrong mode still minted
                    // its ticket.** Park it before refusing the page.
                    self.park_reference_page(&page);
                    self.history_error = Some("Malformed".to_owned());
                    self.job = None;
                    self.history_due = None;
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
        // a cleanup slot is what it is picked up from.
        if let Some(job) = self.job.take() {
            if let Ok(request) = (Request::Cancel { job_id: job.id }).encode() {
                self.queue_cleanup(request);
            }
        }
        if let Some(aux) = self.aux.take() {
            if let Some(job_id) = aux.job {
                if let Ok(request) = (Request::Cancel { job_id }).encode() {
                    self.queue_cleanup(request);
                }
            }
        }
        self.older = OlderState::Idle;
        self.auto_advances = 0;
        self.poll_turn = 0;
        self.reading_history = false;
        self.context_mode = false;
        self.tail_rows.clear();
        self.history_gap = false;
        self.tail_gap = false;
        self.history_dirty = false;
        self.search = None;
        self.search_state = SearchState::Idle;
        self.search_query = None;
        self.search_results.clear();
        self.search_tail = None;
        self.around = None;
        self.discard_reference();
        self.context_older = None;
        self.context_newer = None;
        self.context_older_at_end = true;
        self.context_newer_at_end = true;
        self.context_older_dirty = false;
        self.context_newer_dirty = false;
        self.context_older_reanchor = None;
        self.context_newer_reanchor = None;
        self.context_remainder.clear();
        self.aux_error = None;
        self.metadata = None;
        self.metadata_error = None;
        self.metadata_due = None;
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

fn cancel_job(job_id: &str) -> Option<Action> {
    Request::Cancel {
        job_id: job_id.to_owned(),
    }
    .encode()
    .ok()
    .map(|request| Action::Cancel { request })
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

    /// The request id the feed itself put in a begin. A continued scan
    /// mints a new id (idempotence binds the id to its token), so a test
    /// must use what the feed emitted, not the id of the previous request.
    fn begin_request_id(request: &str) -> String {
        let value: Value = serde_json::from_str(request).unwrap();
        value["params"]["request_id"].as_str().unwrap().to_owned()
    }

    fn envelope(kind: Kind, generation: u64, group: &str) -> Envelope {
        Envelope {
            kind,
            generation,
            group: group.to_owned(),
            request_id: None,
            job_id: None,
            nav: 0,
        }
    }

    fn envelope_id(kind: Kind, generation: u64, group: &str, id: &str) -> Envelope {
        Envelope {
            kind,
            generation,
            group: group.to_owned(),
            request_id: Some(id.to_owned()),
            job_id: None,
            nav: 0,
        }
    }

    fn msg(anchor: &str) -> Message {
        Message {
            seq: 0,
            log_seq: 0,
            from: "0x1".to_owned(),
            from_self: false,
            author: "worker".to_owned(),
            at_ms: 1_700_000_000_000,
            summary: false,
            channel: 0,
            text: "hi".to_owned(),
            anchor: anchor.to_owned(),
            live_anchor: None,
            location: None,
            content_version: 0,
            mentions: None,
            role: None,
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

    /// Answer the header read that a start schedules before the begin.
    fn settle_metadata(feed: &mut Feed, group: &str, now: u64) {
        if feed.metadata().is_none() {
            if let Some(Action::Metadata { .. }) = feed.next_action(now) {
                let answer = json!({
                    "ok": true, "group": group, "brief": "",
                    "members": [], "member_count": 0, "members_truncated": false
                })
                .to_string();
                feed.accept_metadata(
                    &envelope(Kind::Metadata, feed.generation(), group),
                    body(answer),
                    now,
                );
            }
        }
    }

    /// Start a feed on `g` and carry its first begin through to a session
    /// with a known job. Returns the feed and the job id.
    fn started(group: &str) -> (Feed, String) {
        let job = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned();
        let mut feed = Feed::new(next_id);
        feed.start(group, "r1".to_owned(), 0);
        settle_metadata(&mut feed, group, 0);
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
            Action::Metadata { .. } => "metadata",
            Action::SearchBegin { .. } => "search-begin",
            Action::SearchPoll { .. } => "search-poll",
            Action::AuxBegin { .. } => "aux-begin",
            Action::AuxPoll { .. } => "aux-poll",
            Action::Cancel { .. } => "cancel",
        }
    }

    #[test]
    fn a_failed_older_block_cools_before_it_is_asked_again() {
        let (mut feed, job) = started("g");
        let token = "cccccccccccccccccccccccccccccccc";
        let first = ready("g", &job, "s1", &[], "budget", Some(token));
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(first),
            10,
        );
        assert!(feed.load_older("r-older".to_owned(), 20));
        // The block fails (an unreadable answer is a failure, not a page).
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(String::new()),
            30,
        );
        assert!(matches!(feed.older(), OlderState::Failed(_)));
        // **Not on every wheel notch**: the same block is refused by the
        // clock, not asked again, and the person still sees the failure
        // once (the page's notice reads the state).
        assert!(!feed.load_older("r-again".to_owned(), 31));
        // After the cooling period the block may be asked for again.
        assert!(feed.load_older(
            "r-later".to_owned(),
            20 + AUX_RETRY_MS
        ));
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
    fn metadata_is_read_once_before_the_page_and_a_failure_keeps_it() {
        let mut feed = Feed::new(next_id);
        feed.start("g", "r1".to_owned(), 0);
        let Some(Action::Metadata { request }) = feed.next_action(0) else {
            panic!("metadata first");
        };
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["method"], "chat_metadata");
        assert_eq!(value["params"]["group"], "g");
        // The begin waits behind it.
        assert!(matches!(feed.next_action(0), Some(Action::Begin { .. })));

        let answer = json!({
            "ok": true, "group": "g", "brief": "what for",
            "members": [{"id": "0x1", "title": "a", "role": null}],
            "member_count": 1, "members_truncated": false
        })
        .to_string();
        feed.accept_metadata(
            &envelope(Kind::Metadata, feed.generation(), "g"),
            body(answer),
            0,
        );
        let meta = feed.metadata().expect("the brief and members");
        assert_eq!(meta.brief, "what for");
        assert_eq!(meta.member_count, 1);
        assert_eq!(feed.metadata_error(), None);

        // A later failure names itself and does not erase what is shown.
        let refused = json!({ "ok": false, "error": "NoSuchGroup" }).to_string();
        feed.accept_metadata(
            &envelope(Kind::Metadata, feed.generation(), "g"),
            body(refused),
            10,
        );
        assert_eq!(feed.metadata_error(), Some("NoSuchGroup"));
        assert_eq!(feed.metadata().map(|m| m.brief.as_str()), Some("what for"));
    }

    #[test]
    fn an_empty_budget_page_is_progress_and_steps_to_its_continuation() {
        let (mut feed, job) = started("g");
        let token = "cccccccccccccccccccccccccccccccc";
        let reply = ready("g", &job, "s1", &[], "budget", Some(token));
        let action = feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(reply),
            10,
        );
        assert!(action.is_none());
        // **Not "no messages yet"**: the scan is still progressing.
        assert_eq!(feed.load(), Load::Loading);
        assert_eq!(feed.older(), &OlderState::Loading);
        let tail = feed.tail().expect("a page answered");
        assert_eq!(tail.stop, Stop::Budget);
        assert_eq!(tail.next_token.as_deref(), Some(token));

        // The continuation is the ordinary history begin shape -- no
        // `mode` -- so a core that only knows the legacy methods serves it.
        let Some(Action::AuxBegin { request }) = feed.next_action(10) else {
            panic!("the budget page's continuation is asked for");
        };
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["method"], "chat_history_begin");
        assert_eq!(value["params"]["resume_token"], token);
        assert!(value["params"].get("mode").is_none());
    }

    #[test]
    fn older_pages_prepend_keep_the_reading_anchor_and_end_explicitly() {
        let (mut feed, job) = started("g");
        let first = vec![message(0, 10, "p:10", None), message(0, 11, "p:11", None)];
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(ready(
                "g",
                &job,
                "s1",
                &first,
                "full",
                Some("cccccccccccccccccccccccccccccccc"),
            )),
            10,
        );
        assert_eq!(feed.older(), &OlderState::Idle);
        assert!(feed.can_load_older());

        assert!(feed.load_older("r-older".to_owned(), 20));
        assert!(feed.reading_history());
        let Some(Action::AuxBegin { request }) = feed.next_action(20) else {
            panic!("one older begin");
        };
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["method"], "chat_history_begin");
        assert!(value["params"].get("mode").is_none());

        let older_job = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        let begin_reply = begin("g", older_job, "s1", 5, &[]);
        feed.accept_aux_begin(
            &envelope(Kind::AuxBegin, feed.generation(), "g"),
            body(begin_reply),
            20,
        );
        let older = vec![message(0, 8, "p:8", None), message(0, 9, "p:9", None)];
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(ready("g", older_job, "s1", &older, "at_end", None)),
            30,
        );
        let ids: Vec<&str> = feed.rows().iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, ["p:8", "p:9", "p:10", "p:11"]);
        assert_eq!(feed.older(), &OlderState::End);
        assert!(!feed.can_load_older());
    }

    #[test]
    fn new_messages_wait_aside_while_the_reading_window_keeps_its_page() {
        let (mut feed, job) = started("g");
        let first = vec![message(0, 10, "p:10", None)];
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(ready(
                "g",
                &job,
                "s1",
                &first,
                "full",
                Some("cccccccccccccccccccccccccccccccc"),
            )),
            10,
        );
        assert!(feed.load_older("r-older".to_owned(), 20));
        // A live message arrives while the person reads older rows: it is
        // not appended to the reading window.
        let live_row = message(12, 0, "l:s1:12", None);
        feed.accept_live(
            &envelope(Kind::Live, feed.generation(), "g"),
            body(live("g", "s1", 5, 12, false, &[live_row])),
            30,
        );
        assert_eq!(feed.rows().len(), 1);
        assert_eq!(feed.new_messages(), 1);
        feed.return_to_latest(0);
        assert_eq!(feed.rows().len(), 2);
        assert_eq!(feed.rows()[1].id, "l:s1:12");
        assert_eq!(feed.new_messages(), 0);
        assert!(!feed.reading_history());
    }

    #[test]
    fn an_older_page_survives_the_window_limit_while_reading_history() {
        let mut body = Body::default();
        for i in 0..WINDOW_LIMIT {
            assert!(body.absorb(msg(&format!("p:{i}"))));
        }
        // A page older than everything in the window: the ordinary trim
        // (oldest first) would delete exactly this page.
        let older: Vec<Message> = (0..20).map(|i| msg(&format!("old:{i}"))).collect();
        body.absorb_front(older, true);
        // **A block leaves the far end, not one row**: 5000 + 20 rows is
        // over the limit by 20, and the oldest-first rule would delete the
        // page just loaded, so one whole block (100) goes from the newest
        // end instead.
        assert_eq!(body.rows.len(), WINDOW_LIMIT - EVICT_ROWS + 20);
        // The page just loaded is still there, at the front.
        assert_eq!(body.rows[0].id, "old:0");
        assert_eq!(body.rows[19].id, "old:19");
        // What was trimmed is the newest end, not the reading end.
        assert_eq!(body.rows.last().map(|r| r.id.as_str()), Some("p:4899"));
    }

    #[test]
    fn a_session_change_cancels_both_jobs_not_only_the_one_it_returns() {
        let (mut feed, boot_job) = started("g");
        // An auxiliary job started by an older ask.
        let first = vec![message(0, 10, "p:10", None)];
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(ready(
                "g",
                &boot_job,
                "s1",
                &first,
                "full",
                Some("cccccccccccccccccccccccccccccccc"),
            )),
            10,
        );
        assert!(feed.load_older("r-older".to_owned(), 20));
        let _ = feed.next_action(20);
        let older_job = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        feed.accept_aux_begin(
            &envelope(Kind::AuxBegin, feed.generation(), "g"),
            body(begin("g", older_job, "s1", 5, &[])),
            20,
        );
        // A second bootstrap scan alive at the same moment is what a
        // rebootstrap after `Expired` looks like; both jobs are dropped by
        // the session change below.
        let boot = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        feed.job = Some(Job {
            id: boot.to_owned(),
            group: "g".to_owned(),
            generation: feed.generation(),
        });

        // A live reply from another core session drops both.
        let cancel = feed.accept_live(
            &envelope(Kind::Live, feed.generation(), "g"),
            body(live("g", "s2", 5, 6, false, &[])),
            40,
        );
        let mut cancelled: Vec<String> = Vec::new();
        if let Some(Action::Cancel { request }) = cancel {
            cancelled.push(request);
        }
        while let Some(Action::Cancel { request }) = feed.next_action(40) {
            cancelled.push(request);
        }
        let joined = cancelled.join(" ");
        assert!(
            joined.contains(older_job),
            "the auxiliary job is cancelled too"
        );
        assert!(
            joined.contains(boot),
            "the bootstrap job's cancel is not overwritten"
        );
    }

    fn search_begin(group: &str, job: &str, session: &str, query: &str) -> String {
        json!({
            "ok": true, "state": "pending",
            "job_id": job, "group": group, "session": session, "query": query
        })
        .to_string()
    }

    fn search_ready(
        group: &str,
        job: &str,
        session: &str,
        query: &str,
        hits: &[Value],
        stop: &str,
        token: Option<&str>,
        gap: bool,
    ) -> String {
        json!({
            "ok": true, "state": "ready", "job_id": job, "group": group,
            "session": session, "query": query, "results": hits,
            "stop": stop, "next_token": token,
            "restarted": false, "gap": gap
        })
        .to_string()
    }

    fn hit(anchor: &str) -> Value {
        json!({
            "message": message(0, 9, anchor, None),
            "snippet": "hi", "snippet_start": 0,
            "ranges": [{"start": 0, "end": 2}]
        })
    }

    #[test]
    fn search_is_its_own_door_pages_by_its_cursor_and_does_not_reuse_history() {
        let (mut feed, _job) = started("g");
        assert!(feed.start_search(" \t批量 \n", "r-search".to_owned(), 10));
        let Some(Action::SearchBegin { request }) = feed.next_action(10) else {
            panic!("one search begin");
        };
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["method"], "chat_search_begin");
        assert_eq!(value["params"]["query"], "批量");
        assert!(value["params"].get("resume_token").is_none());

        let job = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
        feed.accept_search_begin(
            &envelope_id(Kind::SearchBegin, feed.generation(), "g", "r-search"),
            body(search_begin("g", job, "s1", "批量")),
            10,
        );
        let token = "ffffffffffffffffffffffffffffffff";
        feed.accept_search_poll(
            &envelope(Kind::SearchPoll, feed.generation(), "g"),
            body(search_ready(
                "g",
                job,
                "s1",
                "批量",
                &[hit("p:9")],
                "budget",
                Some(token),
                false,
            )),
            20,
        );
        assert_eq!(feed.search_state(), &SearchState::Incomplete);
        assert_eq!(feed.search_results().len(), 1);

        // The continuation is the same query plus the scan cursor.
        assert!(feed.search_more("r-search-2".to_owned(), 30));
        let Some(Action::SearchBegin { request }) = feed.next_action(30) else {
            panic!("one search continuation");
        };
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["method"], "chat_search_begin");
        assert_eq!(value["params"]["query"], "批量");
        assert_eq!(value["params"]["resume_token"], token);
    }

    #[test]
    fn a_search_that_reaches_an_incomplete_end_is_a_gap_and_a_retry_does_not_duplicate_a_hit() {
        let (mut feed, _job) = started("g");
        assert!(feed.start_search("批量", "r-search".to_owned(), 10));
        let _ = feed.next_action(10);
        let job = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
        feed.accept_search_begin(
            &envelope_id(Kind::SearchBegin, feed.generation(), "g", "r-search"),
            body(search_begin("g", job, "s1", "批量")),
            10,
        );
        // The same hit twice (a retried page) is kept once.
        feed.accept_search_poll(
            &envelope(Kind::SearchPoll, feed.generation(), "g"),
            body(search_ready(
                "g",
                job,
                "s1",
                "批量",
                &[hit("p:9"), hit("p:9")],
                "at_end",
                None,
                true,
            )),
            20,
        );
        assert_eq!(feed.search_results().len(), 1);
        assert_eq!(feed.search_state(), &SearchState::Gap);
    }

    #[test]
    fn around_uses_the_messages_hint_and_replaces_the_window_as_a_context_view() {
        let (mut feed, _job) = started("g");
        assert!(feed.load_around("p:9", Some("hint/keep"), 1, 1, "r-around".to_owned(), 10));
        let Some(Action::AuxBegin { request }) = feed.next_action(10) else {
            panic!("one around begin");
        };
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["method"], "chat_history_begin");
        assert_eq!(value["params"]["mode"], "around");
        assert_eq!(value["params"]["anchor"], "p:9");
        assert_eq!(value["params"]["location"], "hint/keep");
        assert_eq!(value["params"]["before"], 1);
        assert_eq!(value["params"]["after"], 1);
        assert!(value["params"].get("resume_token").is_none());

        let job = "abababababababababababababababab";
        let pending = json!({
            "ok": true, "state": "pending", "job_id": job,
            "group": "g", "session": "s1"
        })
        .to_string();
        feed.accept_aux_begin(
            &envelope_id(Kind::AuxBegin, feed.generation(), "g", "r-around"),
            body(pending),
            10,
        );
        let ready = json!({
            "ok": true, "state": "ready", "mode": "around", "job_id": job,
            "group": "g", "session": "s1",
            "messages": [
                message(0, 8, "p:8", None),
                message(0, 9, "p:9", None),
                message(0, 10, "p:10", None)
            ],
            "target_index": 1,
            "older_token": "cccccccccccccccccccccccccccccccc",
            "newer_token": null,
            "older_at_end": false, "newer_at_end": true
        })
        .to_string();
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(ready),
            20,
        );
        let ids: Vec<&str> = feed.rows().iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, ["p:8", "p:9", "p:10"]);
        assert_eq!(feed.around().map(|p| p.target_index), Some(1));
        assert!(feed.reading_history());

        // A reference keeps the core's `file_open` object whole and sends
        // the source message's own hint unchanged.
        assert!(feed.load_reference(
            "p:9",
            Some("hint/keep"),
            "README.md",
            "r-ref".to_owned(),
            30
        ));
        let Some(Action::AuxBegin { request }) = feed.next_action(30) else {
            panic!("one reference begin");
        };
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["params"]["mode"], "reference");
        assert_eq!(value["params"]["location"], "hint/keep");
        assert_eq!(value["params"]["original_reference"], "README.md");
        let ref_job = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
        feed.accept_aux_begin(
            &envelope_id(Kind::AuxBegin, feed.generation(), "g", "r-ref"),
            body(
                json!({
                    "ok": true, "state": "pending", "job_id": ref_job,
                    "group": "g", "session": "s1"
                })
                .to_string(),
            ),
            30,
        );
        let ready = json!({
            "ok": true, "state": "ready", "mode": "reference", "job_id": ref_job,
            "group": "g", "session": "s1",
            "source": {"anchor": "p:9", "live_anchor": null, "location": null,
                       "original_reference": "README.md"},
            "file_open": {"token": "t0", "info": {"path": "README.md"},
                          "plugin": {"key": "edit-text"}}
        })
        .to_string();
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(ready),
            40,
        );
        let page = feed.reference().expect("the reference answer");
        assert_eq!(page.source_anchor, "p:9");
        assert_eq!(page.file_open["plugin"]["key"], "edit-text");
    }

    /// One ready reference answer, as the core spells it: the two
    /// hyphen-null source fields are present even when they have no value.
    fn reference_ready(job: &str, token: &str) -> String {
        json!({
            "ok": true, "state": "ready", "mode": "reference", "job_id": job,
            "group": "g", "session": "s1",
            "source": {"anchor": "p:9", "live_anchor": null, "location": null,
                       "original_reference": "README.md"},
            "file_open": {"token": token, "info": {"path": "README.md"},
                          "plugin": {"key": "edit-text"}}
        })
        .to_string()
    }

    /// Get the feed into the state the host sees when a reference answer
    /// is waiting to be consumed.
    fn ready_reference_token(feed: &mut Feed, token: &str) {
        assert!(feed.load_reference("p:9", None, "README.md", "r-ref".to_owned(), 30));
        let Some(Action::AuxBegin { .. }) = feed.next_action(30) else {
            panic!("one reference begin");
        };
        let job = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
        feed.accept_aux_begin(
            &envelope_id(Kind::AuxBegin, feed.generation(), "g", "r-ref"),
            body(
                json!({
                    "ok": true, "state": "pending", "job_id": job,
                    "group": "g", "session": "s1"
                })
                .to_string(),
            ),
            30,
        );
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(reference_ready(job, token)),
            40,
        );
        assert_eq!(
            feed.reference().map(|p| p.file_open["token"].as_str()),
            Some(Some(token))
        );
    }

    #[test]
    fn a_reference_replaced_before_adoption_hands_its_ticket_back() {
        let (mut feed, _job) = started("g");
        ready_reference_token(&mut feed, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        // The person clicked another source before this answer was
        // consumed: A's ticket was minted and must not be dropped.
        assert!(feed.load_reference("p:10", None, "b.md", "r-ref2".to_owned(), 60));
        assert_eq!(feed.take_orphan_references(), vec!["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]);
        assert!(feed.reference().is_none());
    }

    #[test]
    fn a_token_that_is_not_a_ticket_is_not_queued_for_close() {
        // A structurally complete page whose `file_open.token` is not the
        // 32-lower-hex shape the core mints carries no capability: the
        // decoded path applies the same rule as the conservative one.
        for token in ["short", "9F2C0A1B4D5E6F708192A3B4C5D6E7F8"] {
            let (mut feed, _job) = started("g");
            ready_reference_token(&mut feed, token);
            assert!(feed.load_reference("p:10", None, "b.md", "r-ref2".to_owned(), 60));
            assert!(feed.take_orphan_references().is_empty(), "{token}");
        }
    }

    #[test]
    fn stopping_the_page_parks_a_ready_reference_for_the_close_path() {
        let (mut feed, _job) = started("g");
        ready_reference_token(&mut feed, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        let _ = feed.stop(70);
        assert_eq!(feed.take_orphan_references(), vec!["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]);
    }

    #[test]
    fn late_reference_polls_accumulate_instead_of_overwriting() {
        let (mut feed, _job) = started("g");
        // No navigation is waiting; two late answers must both be closed,
        // not one overwriting the other.
        feed.cancel_navigation();
        let generation = feed.generation();
        for (job, token) in [
            ("abababababababababababababababab", "11111111111111111111111111111111"),
            ("cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", "22222222222222222222222222222222"),
        ] {
            feed.accept_aux_poll(
                &envelope(Kind::AuxPoll, generation, "g"),
                body(reference_ready(job, token)),
                20,
            );
        }
        assert_eq!(
            feed.take_orphan_references(),
            vec!["11111111111111111111111111111111", "22222222222222222222222222222222"]
        );
    }

    #[test]
    fn a_reference_for_another_generation_or_group_is_still_returned() {
        let (mut feed, _job) = started("g");
        let stale = feed.generation() + 1;
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, stale, "g"),
            body(reference_ready("abababababababababababababababab", "33333333333333333333333333333333")),
            20,
        );
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "other"),
            body(reference_ready("cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", "44444444444444444444444444444444")),
            20,
        );
        assert_eq!(
            feed.take_orphan_references(),
            vec!["33333333333333333333333333333333", "44444444444444444444444444444444"]
        );
    }

    #[test]
    fn a_reference_answer_on_an_around_job_returns_its_ticket() {
        let (mut feed, _job) = started("g");
        assert!(feed.load_around("p:9", None, 1, 1, "r-around".to_owned(), 10));
        let Some(Action::AuxBegin { .. }) = feed.next_action(10) else {
            panic!("one around begin");
        };
        let job = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
        feed.accept_aux_begin(
            &envelope_id(Kind::AuxBegin, feed.generation(), "g", "r-around"),
            body(
                json!({
                    "ok": true, "state": "pending", "job_id": job,
                    "group": "g", "session": "s1"
                })
                .to_string(),
            ),
            10,
        );
        // Structurally a valid reference answer, but this job asked for an
        // around window. It is refused and its ticket returned.
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(reference_ready(job, "55555555555555555555555555555555")),
            20,
        );
        assert_eq!(feed.take_orphan_references(), vec!["55555555555555555555555555555555"]);
    }

    #[test]
    fn a_reference_page_that_fails_the_source_check_still_returns_its_ticket() {
        let (mut feed, _job) = started("g");
        assert!(feed.load_reference("p:9", None, "README.md", "r-ref".to_owned(), 30));
        let Some(Action::AuxBegin { .. }) = feed.next_action(30) else {
            panic!("one reference begin");
        };
        let job = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
        feed.accept_aux_begin(
            &envelope_id(Kind::AuxBegin, feed.generation(), "g", "r-ref"),
            body(
                json!({
                    "ok": true, "state": "pending", "job_id": job,
                    "group": "g", "session": "s1"
                })
                .to_string(),
            ),
            30,
        );
        // The strict source check refuses this page (`location` missing,
        // `live_anchor` the wrong type), but the ticket it minted is still
        // the host's to close.
        let broken = json!({
            "ok": true, "state": "ready", "mode": "reference", "job_id": job,
            "group": "g", "session": "s1",
            "source": {"anchor": "p:9", "live_anchor": 7, "original_reference": "README.md"},
            "file_open": {"token": "0123456789abcdef0123456789abcdef",
                          "plugin": {"key": "edit-text"}}
        })
        .to_string();
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(broken),
            40,
        );
        assert!(feed.reference().is_none());
        assert_eq!(
            feed.take_orphan_references(),
            vec!["0123456789abcdef0123456789abcdef"]
        );
    }

    #[test]
    fn a_broken_reference_page_on_the_bootstrap_door_still_returns_its_ticket() {
        // The current bootstrap door, with matching group/generation/job:
        // the strict source check fails (missing `location`, wrong-typed
        // `live_anchor`), but the ticket it minted is still queued.
        let (mut feed, _job) = started("g");
        let broken = json!({
            "ok": true, "state": "ready", "mode": "reference",
            "job_id": "abababababababababababababababab",
            "group": "g", "session": "s1",
            "source": {"anchor": "p:9", "live_anchor": 7, "original_reference": "README.md"},
            "file_open": {"token": "0123456789abcdef0123456789abcdef",
                          "plugin": {"key": "edit-text"}}
        })
        .to_string();
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(broken),
            20,
        );
        assert_eq!(feed.history_error(), Some("Malformed"));
        assert_eq!(
            feed.take_orphan_references(),
            vec!["0123456789abcdef0123456789abcdef"]
        );
    }

    #[test]
    fn a_reference_answer_on_the_bootstrap_door_returns_its_ticket() {
        let (mut feed, _job) = started("g");
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(reference_ready(
                "abababababababababababababababab",
                "66666666666666666666666666666666",
            )),
            20,
        );
        assert_eq!(feed.take_orphan_references(), vec!["66666666666666666666666666666666"]);
    }

    #[test]
    fn an_overlapping_page_recounts_bytes_once() {
        let mut body = Body::default();
        for i in 0..10 {
            assert!(body.absorb(msg(&format!("p:{i}"))));
        }
        fn bytes_of(body: &Body) -> usize {
            body.rows.iter().map(|row| Body::cost(&row.message)).sum()
        }
        assert_eq!(body.bytes, bytes_of(&body));
        // One new older row and one overlap with the existing window.
        let _ = body.absorb_front(vec![msg("old:1"), msg("p:0")], true);
        assert_eq!(body.rows.len(), 11);
        assert_eq!(body.bytes, bytes_of(&body));
        // An empty page changes nothing, and repeating the same page does
        // not grow the charge.
        let (rows, bytes) = (body.rows.len(), body.bytes);
        let _ = body.absorb_front(Vec::new(), true);
        assert_eq!((body.rows.len(), body.bytes), (rows, bytes));
        let _ = body.absorb_front(vec![msg("old:1"), msg("p:0")], true);
        assert_eq!((body.rows.len(), body.bytes), (rows, bytes));
    }

    #[test]
    fn a_gap_on_an_earlier_page_keeps_a_later_clean_end_from_claiming_the_beginning() {
        let (mut feed, job) = started("g");
        let first = vec![message(0, 10, "p:10", None)];
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(ready(
                "g",
                &job,
                "s1",
                &first,
                "full",
                Some("cccccccccccccccccccccccccccccccc"),
            )),
            10,
        );
        // Older page one: a gap, and a token to continue.
        assert!(feed.load_older("r-older".to_owned(), 20));
        let Some(Action::AuxBegin { request }) = feed.next_action(20) else {
            panic!("one older begin");
        };
        let job1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        feed.accept_aux_begin(
            &envelope_id(
                Kind::AuxBegin,
                feed.generation(),
                "g",
                &begin_request_id(&request),
            ),
            body(begin("g", job1, "s1", 5, &[])),
            20,
        );
        let gap_page = ready(
            "g",
            job1,
            "s1",
            &[],
            "budget",
            Some("dddddddddddddddddddddddddddddddd"),
        )
        .replace(r#""gap":false"#, r#""gap":true"#);
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(gap_page),
            30,
        );
        // The empty budget page steps to the token it named. **The
        // auto-advance mints its own request id**; accepting its begin
        // under the old id would be refused, which is what this test
        // caught.
        let Some(Action::AuxBegin { request }) = feed.next_action(30) else {
            panic!("the continued older begin");
        };
        let job2 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
        feed.accept_aux_begin(
            &envelope_id(
                Kind::AuxBegin,
                feed.generation(),
                "g",
                &begin_request_id(&request),
            ),
            body(begin("g", job2, "s1", 5, &[])),
            30,
        );
        // The next page is clean and says at_end; the range is still dirty.
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(ready("g", job2, "s1", &[], "at_end", None)),
            40,
        );
        assert_eq!(feed.older(), &OlderState::Gap);
        assert!(feed.tail().is_some_and(|t| t.dirty));
    }

    #[test]
    fn context_pages_merge_by_direction_and_keep_the_reading_anchor() {
        let (mut feed, _job) = started("g");
        assert!(feed.load_around("p:9", None, 1, 1, "r-around".to_owned(), 10));
        let _ = feed.next_action(10);
        let job = "abababababababababababababababab";
        feed.accept_aux_begin(
            &envelope_id(Kind::AuxBegin, feed.generation(), "g", "r-around"),
            body(json!({"ok": true, "state": "pending", "job_id": job, "group": "g", "session": "s1"}).to_string()),
            10,
        );
        let (older_tok, newer_tok) = (
            "cccccccccccccccccccccccccccccccc",
            "dddddddddddddddddddddddddddddddd",
        );
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(
                json!({
                    "ok": true, "state": "ready", "mode": "around", "job_id": job,
                    "group": "g", "session": "s1",
                    "messages": [message(0,9,"p:9",None), message(0,10,"p:10",None)],
                    "target_index": 0,
                    "older_token": older_tok, "newer_token": newer_tok,
                    "older_at_end": false, "newer_at_end": false
                })
                .to_string(),
            ),
            20,
        );
        assert!(feed.context_window());

        // Older direction prepends, keeping the anchor that was at the top.
        assert!(feed.load_context(true, "r-ctx-old".to_owned(), 30));
        let _ = feed.next_action(30);
        let ctx_job = "f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0";
        feed.accept_aux_begin(
            &envelope_id(Kind::AuxBegin, feed.generation(), "g", "r-ctx-old"),
            body(json!({"ok": true, "state": "pending", "job_id": ctx_job, "group": "g", "session": "s1"}).to_string()),
            30,
        );
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(
                json!({
                    "ok": true, "state": "ready", "mode": "context", "job_id": ctx_job,
                    "group": "g", "session": "s1", "direction": "older",
                    "messages": [message(0,7,"p:7",None), message(0,8,"p:8",None)],
                    "older_token": null, "newer_token": "dddddddddddddddddddddddddddddddd",
                    "older_at_end": true, "newer_at_end": false,
                    "stop": "at_end",
                    "restarted": false, "gap": false
                })
                .to_string(),
            ),
            40,
        );
        let ids: Vec<&str> = feed.rows().iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, ["p:7", "p:8", "p:9", "p:10"]);

        // Newer direction appends; the top anchor is still p:7.
        assert!(feed.load_context(false, "r-ctx-new".to_owned(), 50));
        let _ = feed.next_action(50);
        let ctx_job2 = "f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1";
        feed.accept_aux_begin(
            &envelope_id(Kind::AuxBegin, feed.generation(), "g", "r-ctx-new"),
            body(json!({"ok": true, "state": "pending", "job_id": ctx_job2, "group": "g", "session": "s1"}).to_string()),
            50,
        );
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(
                json!({
                    "ok": true, "state": "ready", "mode": "context", "job_id": ctx_job2,
                    "group": "g", "session": "s1", "direction": "newer",
                    "messages": [message(0,11,"p:11",None)],
                    "older_token": null, "newer_token": null,
                    "older_at_end": true, "newer_at_end": true,
                    "stop": "at_end",
                    "restarted": false, "gap": false
                })
                .to_string(),
            ),
            60,
        );
        let ids: Vec<&str> = feed.rows().iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, ["p:7", "p:8", "p:9", "p:10", "p:11"]);
    }

    #[test]
    fn a_context_remainder_is_not_skipped_by_the_cursor() {
        let (mut feed, _job) = started("g");
        for i in 0..WINDOW_LIMIT {
            assert!(feed.body.absorb(msg(&format!("p:{i}"))));
        }
        feed.context_mode = true;
        feed.reading_history = true;
        feed.context_newer = Some("dddddddddddddddddddddddddddddddd".to_owned());
        feed.context_remainder = vec![msg("new:1"), msg("new:2")];
        assert!(feed.context_can(false));
        // The window is full: the remainder cannot be taken yet, and no
        // request is made past rows nobody kept.
        assert!(!feed.load_context(false, "r-more".to_owned(), 10));
        assert!(feed.aux.is_none());
        assert_eq!(feed.context_remainder.len(), 2);
        assert_eq!(feed.aux_error(), Some("ContextBudget"));
    }

    #[test]
    fn returning_to_latest_from_a_context_window_cancels_aux_and_reloads() {
        let (mut feed, _job) = started("g");
        assert!(feed.load_around("p:9", None, 1, 1, "r-around".to_owned(), 10));
        let _ = feed.next_action(10);
        let aux_job = "abababababababababababababababab";
        feed.accept_aux_begin(
            &envelope_id(Kind::AuxBegin, feed.generation(), "g", "r-around"),
            body(json!({"ok": true, "state": "pending", "job_id": aux_job, "group": "g", "session": "s1"}).to_string()),
            10,
        );
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(
                json!({
                    "ok": true, "state": "ready", "mode": "around", "job_id": aux_job,
                    "group": "g", "session": "s1",
                    "messages": [message(0,9,"p:9",None)],
                    "target_index": 0,
                    "older_token": "cccccccccccccccccccccccccccccccc",
                    "newer_token": null,
                    "older_at_end": false, "newer_at_end": true
                })
                .to_string(),
            ),
            20,
        );
        assert!(feed.context_window());
        feed.return_to_latest(30);
        assert!(!feed.context_window());
        assert!(feed.rows().is_empty());
        // The old scan's cancel is drained before the fresh begin.
        let mut saw_cancel = false;
        let mut saw_begin = false;
        while let Some(action) = feed.next_action(30) {
            match action {
                Action::Cancel { request } => {
                    saw_cancel |= request.contains(aux_job);
                }
                Action::Begin { request } => {
                    saw_begin |= request.contains("chat_history_begin");
                }
                _ => break,
            }
        }
        assert!(saw_cancel || saw_begin);
        assert!(saw_begin);
    }

    #[test]
    fn an_empty_budget_search_page_advances_on_the_same_query() {
        let (mut feed, _job) = started("g");
        assert!(feed.start_search("批量", "r-search".to_owned(), 10));
        let _ = feed.next_action(10);
        let job = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
        feed.accept_search_begin(
            &envelope_id(Kind::SearchBegin, feed.generation(), "g", "r-search"),
            body(search_begin("g", job, "s1", "批量")),
            10,
        );
        let token = "ffffffffffffffffffffffffffffffff";
        feed.accept_search_poll(
            &envelope(Kind::SearchPoll, feed.generation(), "g"),
            body(search_ready(
                "g",
                job,
                "s1",
                "批量",
                &[],
                "budget",
                Some(token),
                false,
            )),
            20,
        );
        assert_eq!(feed.search_state(), &SearchState::Loading);
        let Some(Action::SearchBegin { request }) = feed.next_action(20) else {
            panic!("the empty page's continuation");
        };
        let value: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(value["params"]["query"], "批量");
        assert_eq!(value["params"]["resume_token"], token);
    }

    #[test]
    fn at_end_with_a_gap_is_not_the_beginning_and_an_empty_page_is_not_an_empty_group() {
        // The first page says "beginning" but also that records are
        // missing: that is not an empty group and not a clean end.
        let (mut feed, job) = started("g");
        let dirty =
            ready("g", &job, "s1", &[], "at_end", None).replace(r#""gap":false"#, r#""gap":true"#);
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(dirty),
            10,
        );
        assert_eq!(feed.load(), Load::Gap);

        // The same combination from an older page is `Gap`, not `End`.
        let (mut feed, job) = started("g");
        let first = vec![message(0, 10, "p:10", None)];
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(ready(
                "g",
                &job,
                "s1",
                &first,
                "full",
                Some("cccccccccccccccccccccccccccccccc"),
            )),
            10,
        );
        assert!(feed.load_older("r-older".to_owned(), 20));
        let _ = feed.next_action(20);
        let older_job = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        feed.accept_aux_begin(
            &envelope_id(Kind::AuxBegin, feed.generation(), "g", "r-older"),
            body(begin("g", older_job, "s1", 5, &[])),
            20,
        );
        let restarted = ready("g", older_job, "s1", &[], "at_end", None)
            .replace(r#""restarted":false"#, r#""restarted":true"#);
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(restarted),
            30,
        );
        assert_eq!(feed.older(), &OlderState::Gap);
    }

    #[test]
    fn returning_to_latest_across_a_trimmed_window_reloads_and_does_not_splice() {
        let (mut feed, job) = started("g");
        for i in 0..WINDOW_LIMIT {
            assert!(feed.body.absorb(msg(&format!("p:{i}"))));
        }
        feed.reading_history = true;
        feed.history_gap = true;
        feed.push_tail(msg("l:s1:1"));
        feed.return_to_latest(10);

        // Both sides are dropped: the waiting tail is not placed next to
        // the reading window's last kept row.
        assert!(feed.rows().is_empty());
        assert_eq!(feed.new_messages(), 0);
        assert!(!feed.reading_history());
        assert_eq!(feed.load(), Load::Loading);
        // **The old scan is cancelled before the fresh page is asked for**
        // (the one cleanup slot is drained first), so the switch has two
        // actions, in that order -- and neither is a splice.
        let Some(Action::Cancel { request }) = feed.next_action(10) else {
            panic!("the old scan is cancelled before the fresh page");
        };
        assert!(request.contains(&job));
        let Some(Action::Begin { request }) = feed.next_action(10) else {
            panic!("a fresh newest page after the explicit switch");
        };
        assert!(request.contains("chat_history_begin"));
    }

    #[test]
    fn a_late_or_duplicate_begin_never_cancels_the_job_this_feed_holds() {
        let (mut feed, job) = started("g");
        // A stale generation whose reply names the job the feed still
        // holds: nothing is cancelled.
        let duplicate = begin("g", &job, "s1", 5, &[]);
        let action = feed.accept_begin(
            &envelope(Kind::Begin, feed.generation() + 7, "g"),
            body(duplicate),
            10,
        );
        assert!(action.is_none());
        assert_eq!(feed.job.as_ref().map(|j| j.id.as_str()), Some(job.as_str()));

        // A reply for a *different* job on a stale generation is cancelled.
        let stale = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        let action = feed.accept_begin(
            &envelope(Kind::Begin, feed.generation() + 7, "g"),
            body(begin("g", stale, "s1", 5, &[])),
            20,
        );
        let Some(Action::Cancel { request }) = action else {
            panic!("the foreign job is cancelled");
        };
        assert!(request.contains(stale));

        // A wrong request id is refused even when group and generation
        // still match; the reply's own job is cancelled.
        let other = "dddddddddddddddddddddddddddddddd";
        let action = feed.accept_begin(
            &envelope_id(Kind::Begin, feed.generation(), "g", "not-r1"),
            body(begin("g", other, "s1", 5, &[])),
            30,
        );
        let Some(Action::Cancel { request }) = action else {
            panic!("a wrong request id is stale");
        };
        assert!(request.contains(other));
        assert_eq!(feed.job.as_ref().map(|j| j.id.as_str()), Some(job.as_str()));
    }

    #[test]
    fn around_accepts_a_live_anchor_promoted_to_its_persisted_identity() {
        let (mut feed, _job) = started("g");
        // The person located a live row by its live identity.
        assert!(feed.load_around("l:s1:6", None, 1, 1, "r-around".to_owned(), 10));
        let _ = feed.next_action(10);
        let job = "abababababababababababababababab";
        feed.accept_aux_begin(
            &envelope_id(Kind::AuxBegin, feed.generation(), "g", "r-around"),
            body(json!({"ok": true, "state": "pending", "job_id": job, "group": "g", "session": "s1"}).to_string()),
            10,
        );
        let promoted = message(0, 9, "p:9", Some("l:s1:6"));
        feed.accept_aux_poll(
            &envelope(Kind::AuxPoll, feed.generation(), "g"),
            body(
                json!({
                    "ok": true, "state": "ready", "mode": "around", "job_id": job,
                    "group": "g", "session": "s1",
                    "messages": [promoted],
                    "target_index": 0,
                    "older_token": null, "newer_token": null,
                    "older_at_end": true, "newer_at_end": true
                })
                .to_string(),
            ),
            20,
        );
        assert!(feed.around().is_some());
        assert_eq!(
            feed.rows().first().map(|r| r.message.anchor.as_str()),
            Some("p:9")
        );
    }

    #[test]
    fn the_first_dirty_bootstrap_page_reports_dirty_in_its_tail() {
        let (mut feed, job) = started("g");
        let dirty = ready(
            "g",
            &job,
            "s1",
            &[],
            "budget",
            Some("cccccccccccccccccccccccccccccccc"),
        )
        .replace(r#""gap":false"#, r#""gap":true"#);
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(dirty),
            10,
        );
        assert!(feed.tail().is_some_and(|tail| tail.dirty));
    }

    #[test]
    fn a_late_aux_begin_is_cancelled_and_never_polled() {
        let (mut feed, job) = started("g");
        let first = vec![message(0, 10, "p:10", None)];
        feed.accept_poll(
            &envelope(Kind::Poll, feed.generation(), "g"),
            body(ready(
                "g",
                &job,
                "s1",
                &first,
                "full",
                Some("cccccccccccccccccccccccccccccccc"),
            )),
            10,
        );
        assert!(feed.load_older("r-older".to_owned(), 20));
        let generation = feed.generation();
        feed.stop(20);
        let late = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        let action = feed.accept_aux_begin(
            &envelope(Kind::AuxBegin, generation, "g"),
            body(begin("g", late, "s1", 5, &[])),
            30,
        );
        let Some(Action::Cancel { request }) = action else {
            panic!("the late begin's job is cancelled");
        };
        assert!(request.contains(late));
    }

    #[test]
    fn a_busy_begin_retries_the_same_id() {
        let mut feed = Feed::new(next_id);
        feed.start("g", "r1".to_owned(), 0);
        settle_metadata(&mut feed, "g", 0);
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
        // the job it drops is picked up from a cleanup slot first.
        feed.start("h", "r2".to_owned(), 100);
        let Some(Action::Cancel { request }) = feed.next_action(100) else {
            panic!("the dropped job's cancel comes first");
        };
        assert!(request.contains(&job));
        // The new group's header is read before its first page.
        settle_metadata(&mut feed, "h", 100);
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
