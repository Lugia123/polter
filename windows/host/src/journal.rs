//! A pane's scrollback, kept on disk as it runs: the host's half of
//! `ghostty_surface_set_scrollback_journal`.
//!
//! The core writes a project pane's scrollback to its snapshot file every
//! `project-scrollback-autosave-interval` and once more when the pane closes
//! (`src/termio/scrollback_journal.zig`). That is what survives a killed
//! process, a power cut or a crash -- the cases where the capture a save
//! makes is already stale. **The function is useless unless a host calls
//! it**, and a call a later change drops leaves everything looking right:
//! the project file still names the snapshot, and nothing is ever written
//! to it after the save.
//!
//! So a pane's slot (`tabs::Pane::scrollback`) is a `Journaled`, not a bare
//! `project::Slot`, and the only way to make one is `start`, which is where
//! the core is asked. Giving a pane a snapshot name without that request is
//! a compile error (`slot` is private to this module), not a silence.
//!
//! The same shape on macOS is `ProjectScrollback.Journaled`.

use crate::logf;
use crate::project::Slot;

/// A pane's snapshot in a project, **as one whose scrollback the core has
/// been asked to journal there.** Made only by `start`.
#[derive(Debug, PartialEq, Eq)]
pub struct Journaled {
    slot: Slot,
}

impl Journaled {
    pub fn slot(&self) -> &Slot {
        &self.slot
    }
}

/// Keep `surface`'s scrollback journaled at `slot`, and hand the slot back
/// as one that is. `pane` is the pane's `PaneId`, for the log: a surface
/// pointer is reused once freed, a pane id never is.
///
/// ⚠️ A `true` from the core only means the request was queued. The core
/// logs "scrollback journal active path=..." when the journal is first
/// really written; nothing before that line is evidence it works.
///
/// **The slot is kept whatever happens here** -- the name is the pane's for
/// life (`project::Allocator`), and a pane that could not be journaled still
/// has to save into the same file next time. What a refusal costs is logged.
///
/// Asking again for the path already being journaled does nothing in the
/// core; asking for another path moves the journal there and leaves the old
/// file for the project that names it. A pane just made from a project has
/// no journal until this is called, and its first write rewrites the file
/// from the restored state.
///
/// ⚠️ **Not with the window lock held**: this calls into the core, and the
/// core calls back into this host (`project_ui::tab_tree` has
/// the deadlock that cost once).
pub fn start(pane: u64, surface: usize, slot: Slot) -> Journaled {
    let path = slot.dir.join(&slot.name);
    if surface == 0 {
        // absence: means it was not reached -- every pane given a slot had a
        // surface. Both callers skip surface 0 today, so this is a guard.
        logf!("[journal] pane {}: no surface, nothing to journal to {:?}", pane, path);
        return Journaled { slot };
    }
    let Some(c) = path.to_str().and_then(|s| std::ffi::CString::new(s).ok()) else {
        logf!("[journal] pane {}: {:?} is not a UTF-8 path the core can take; its scrollback is not being journaled", pane, path);
        return Journaled { slot };
    };
    if request(surface, &c) {
        logf!("[journal] pane {} (surface 0x{:x}) asked to journal to {:?}", pane, surface, path);
    } else {
        logf!("[journal] pane {} (surface 0x{:x}): the core refused to journal to {:?}; its scrollback is not being saved as it runs", pane, surface, path);
    }
    Journaled { slot }
}

/// A pane's snapshot that its scrollback was restored from, **held back:
/// nothing is written to it yet** (task 1609). Made by `hold` when a pane
/// is made from a project; `begin` turns it into a `Journaled` once the
/// page the pane is on has been built whole.
///
/// **Why the wait.** A page is built pane by pane, and it can still be
/// refused after some of them exist (`project_ui::open_page_in_new_tab`
/// takes it back). Journaled from the moment they were made, those panes
/// had already rewritten their snapshots by then: on a real machine (#1605
/// S2) a failed open turned a saved 0.snap of 1510 bytes into 1873, and in
/// a project never opened before left a new one behind (S1). Held, a pane
/// that is taken back has written nothing, and the files are as they were.
#[derive(Debug, PartialEq, Eq)]
pub struct Held {
    pane: u64,
    surface: usize,
    slot: Slot,
}

impl Held {
    pub fn pane(&self) -> u64 {
        self.pane
    }
}

/// Hold `slot` for the pane `pane` (`surface`) made from it. **Asks the
/// core nothing.**
pub fn hold(pane: u64, surface: usize, slot: Slot) -> Held {
    logf!("[journal] pane {}: restored from {:?}; not journaled until its page is built", pane, slot.dir.join(&slot.name));
    Held { pane, surface, slot }
}

/// The page is built: keep the pane's scrollback journaled at the slot it
/// was restored from, from now on (`start`).
pub fn begin(held: Held) -> Journaled {
    start(held.pane, held.surface, held.slot)
}

#[cfg(not(test))]
fn request(surface: usize, path: &std::ffi::CStr) -> bool {
    unsafe { (crate::api().surface_set_scrollback_journal)(surface as crate::ffi::Surface, path.as_ptr()) }
}

// What the core was asked, per thread, in place of the core.
#[cfg(test)]
thread_local! {
    static ASKED: std::cell::RefCell<Vec<(usize, String)>> = const { std::cell::RefCell::new(Vec::new()) };
    static ANSWER: std::cell::Cell<bool> = const { std::cell::Cell::new(true) };
}

#[cfg(test)]
fn request(surface: usize, path: &std::ffi::CStr) -> bool {
    ASKED.with(|a| a.borrow_mut().push((surface, path.to_str().unwrap().to_string())));
    ANSWER.with(|a| a.get())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn asked() -> Vec<(usize, String)> {
        ASKED.with(|a| std::mem::take(&mut *a.borrow_mut()))
    }

    fn slot() -> Slot {
        Slot { dir: PathBuf::from(r"C:\p\x.scrollback"), name: "3.snap".to_string() }
    }

    #[test]
    fn start_asks_the_core_to_journal_at_the_panes_file() {
        asked();
        let j = start(7, 0x1234, slot());
        let calls = asked();
        assert_eq!(calls.len(), 1, "one request per start, got {:?}", calls);
        assert_eq!(calls[0].0, 0x1234, "the request went to another surface");
        assert_eq!(
            PathBuf::from(&calls[0].1),
            PathBuf::from(r"C:\p\x.scrollback").join("3.snap"),
            "the journal was asked for somewhere other than the pane's snapshot file"
        );
        assert_eq!(j.slot(), &slot());
    }

    #[test]
    fn a_refused_request_still_leaves_the_pane_its_name() {
        asked();
        ANSWER.with(|a| a.set(false));
        let j = start(7, 0x1234, slot());
        ANSWER.with(|a| a.set(true));
        assert_eq!(asked().len(), 1);
        assert_eq!(j.slot(), &slot(), "a refusal must not cost the pane its number");
    }

    /// Task 1609: a pane made from a saved snapshot asks the core nothing
    /// while its page is being built; only `begin`, once the page stands,
    /// starts the journal -- at the slot it was restored from.
    #[test]
    fn a_held_snapshot_is_not_written_until_its_page_is_built() {
        asked();
        let held = hold(7, 0x1234, slot());
        assert!(asked().is_empty(), "a pane being built asked the core to write its snapshot");
        assert_eq!(held.slot, slot());
        // Taken back: dropped, and still nothing asked.
        drop(held);
        assert!(asked().is_empty());
        let j = begin(hold(8, 0x5678, slot()));
        let calls = asked();
        assert_eq!(calls.len(), 1, "a built page journals each pane once, got {:?}", calls);
        assert_eq!(calls[0].0, 0x5678);
        assert_eq!(PathBuf::from(&calls[0].1), PathBuf::from(r"C:\p\x.scrollback").join("3.snap"));
        assert_eq!(j.slot(), &slot());
    }

    #[test]
    fn no_surface_no_request() {
        asked();
        let j = start(7, 0, slot());
        assert!(asked().is_empty(), "a pane with no surface has nothing to journal");
        assert_eq!(j.slot(), &slot());
    }
}
