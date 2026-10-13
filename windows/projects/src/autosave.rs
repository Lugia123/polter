//! How soon a change to an open project is written.
//!
//! The macOS host's `ProjectAutosaveChange` and `ProjectAutosaveDebouncer`,
//! with the same numbers. There the debouncer owns a timer; here it only
//! says when, and the host sets one -- so the whole rule runs without a
//! message loop.

/// What changed in an open project, which says how long its write may be
/// put off while other changes keep arriving.
///
/// **Why a write has a latest moment at all.** Every change restarts a short
/// wait, so that a burst is one write. But a pane with an agent in it
/// changes its title several times a second for as long as the agent works,
/// and a wait that every change restarts then never ends: a split made
/// while agents were running was written when they all fell silent, or
/// never. So a write has a latest moment as well, counted from the first
/// change it is for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Change {
    /// A tab's tree: a pane added or closed, a divider moved.
    Layout,
    /// A page added to the project, taken out, closed, or moved among the
    /// tabs.
    Pages,
    /// Which tab of a window is showing.
    Front,
    /// A window moved or resized. Dragging one is many of these.
    WindowFrame,
    /// A pane's title or directory. Follows the person around all day and
    /// is worth much less a second after it happened.
    PaneDetail,
}

impl Change {
    pub const ALL: [Change; 5] = [Change::Layout, Change::Pages, Change::Front, Change::WindowFrame, Change::PaneDetail];

    /// The longest a write is put off after a change of this kind, however
    /// many changes follow it, in seconds.
    pub fn no_later_than(self) -> f64 {
        match self {
            Change::Layout | Change::Pages | Change::Front => 3.0,
            Change::WindowFrame => 10.0,
            Change::PaneDetail => 30.0,
        }
    }
}

/// How long after the last change of a burst the write happens, in seconds.
pub const QUIET: f64 = 1.0;

/// When the write for a burst of changes is due: `QUIET` after the last of
/// them, and never later than the change that allows the least waiting said
/// it could be put off.
///
/// Times are seconds on any clock that only goes forward; the caller says
/// what time it is.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Debounce {
    /// When the pending write is to happen; none when nothing is pending.
    due: Option<f64>,
    /// The latest it may happen.
    deadline: Option<f64>,
}

impl Debounce {
    pub fn new() -> Debounce {
        Debounce::default()
    }

    pub fn is_pending(&self) -> bool {
        self.due.is_some()
    }

    /// When the pending write is due; none when nothing is pending. What
    /// the host sets its timer by.
    pub fn due_at(&self) -> Option<f64> {
        self.due
    }

    /// Something changed at `now`: (re)start the wait, without moving the
    /// latest moment any later than an earlier change of this burst put it.
    /// Answers when the write is now due. **What changed has no default**: a
    /// caller that did not have to say would be the next one whose write
    /// never comes.
    pub fn poke(&mut self, change: Change, now: f64) -> f64 {
        let latest = self.deadline.unwrap_or(f64::INFINITY).min(now + change.no_later_than());
        self.deadline = Some(latest);
        let due = now + QUIET.min(latest - now).max(0.0);
        self.due = Some(due);
        due
    }

    /// Whether the pending write is to happen at `now`. When it is, nothing
    /// is pending any more: the caller writes.
    pub fn take_if_due(&mut self, now: f64) -> bool {
        match self.due {
            Some(due) if now >= due => {
                *self = Debounce::default();
                true
            }
            _ => false,
        }
    }

    /// Take a pending write now instead of later -- for when what is being
    /// saved is about to stop existing. False when none was pending.
    pub fn flush(&mut self) -> bool {
        let was = self.due.is_some();
        *self = Debounce::default();
        was
    }

    /// Drop a pending write without making it.
    pub fn cancel(&mut self) {
        *self = Debounce::default();
    }
}
