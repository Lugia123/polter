//! "Load Project…": the list of saved projects, and opening the one picked.
//!
//! **Why this exists (task 839).** Windows could save a project and had no
//! way at all to open one: `project::list` and
//! `project_ui::load_project_into_new_tab` had no caller, and neither the menu
//! nor the palette had a project row. Everything about restoring a project --
//! the split tree, each pane's directory, its command history, and now its
//! scrollback -- was therefore only ever exercised by unit tests on this
//! platform.
//!
//! **A popup list rather than a window.** macOS opens a picker window
//! (`ProjectPicker.swift`) from the `Project` menu; this host has no list
//! window of its own, and the native popup menu is what the language picker
//! already uses for "choose one of these" (`language.rs`). Same entry point
//! as macOS -- a `Project` group with `Save as Project…` and `Load Project…`
//! -- and the list itself is the platform's own control.
//!
//! **Opened from the message loop, not from inside the menu call**, for the
//! reason `language::request_picker` gives: `--menu-selftest` performs every
//! row through the same call a click makes, and a `TrackPopupMenu` entered
//! there would hold the self-test in its modal loop.

use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::Mutex;

use windows::core::PCWSTR;
use windows::Win32::Foundation::{HWND, POINT};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::{n_, tr};
use crate::project;
use crate::wlogf;

static PENDING_FRAME: AtomicPtr<core::ffi::c_void> = AtomicPtr::new(std::ptr::null_mut());
static PENDING_AT: Mutex<POINT> = Mutex::new(POINT { x: 0, y: 0 });

/// Menu ids for the rows. Small and local: `TPM_RETURNCMD` hands the id back
/// to this call and nowhere else.
const ID_BASE: usize = 1;

/// Open the list for `frame`. **Returns at once**; the list opens from the
/// thread's own message loop. See the module comment.
pub fn request_load(frame: HWND) -> bool {
    let mut at = POINT::default();
    let _ = unsafe { GetCursorPos(&mut at) };
    *PENDING_AT.lock().unwrap() = at;
    PENDING_FRAME.store(frame.0, Ordering::Release);
    let id = unsafe { SetTimer(None, 0, 0, Some(load_timer)) };
    // not-gated: the condition is the event -- the timer was refused, and
    // without this line a click that opened nothing would leave no trace.
    if id == 0 {
        wlogf!(frame, "[project] SetTimer failed; the project list was not opened");
        return false;
    }
    true
}

unsafe extern "system" fn load_timer(_: HWND, _: u32, id: usize, _: u32) {
    let _ = KillTimer(None, id);
    let frame = HWND(PENDING_FRAME.swap(std::ptr::null_mut(), Ordering::AcqRel));
    if frame.0.is_null() {
        return;
    }
    let at = *PENDING_AT.lock().unwrap();
    show(frame, at);
}

fn show(frame: HWND, at: POINT) {
    let Some(dir) = project::resolve_state_dir().map(|s| project::default_dir(&s)) else {
        wlogf!(frame, "[project] no state directory (neither XDG_STATE_HOME nor LOCALAPPDATA); nothing to list");
        tell(frame, &tr(n_("No Saved Projects")));
        return;
    };
    let mut listing = project::list(&dir);
    // **Every project left out is named.** `list` skips what it cannot read
    // -- on purpose, and the same on every platform -- so the one thing this
    // entry point owes the person is that a missing row has a line to find.
    for (path, why) in &listing.skipped {
        wlogf!(frame, "[project] list left out {:?}: {}", path, why);
    }
    // Newest first, as `ProjectStore.list` orders it on macOS.
    listing.entries.sort_by(|a, b| b.saved_at.cmp(&a.saved_at));
    wlogf!(
        frame,
        "[project] load list: {} project(s), {} left out, in {:?}",
        listing.entries.len(),
        listing.skipped.len(),
        dir
    );

    let chosen = unsafe {
        let menu = match CreatePopupMenu() {
            Ok(m) => m,
            Err(e) => {
                wlogf!(frame, "[project] CreatePopupMenu failed: {e:?}");
                return;
            }
        };
        if listing.entries.is_empty() {
            // **Greyed, not absent**: an empty popup and one that never
            // opened look the same.
            let wide: Vec<u16> = tr(n_("No Saved Projects")).encode_utf16().chain(Some(0)).collect();
            let _ = AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, PCWSTR(wide.as_ptr()));
        }
        for (i, e) in listing.entries.iter().enumerate() {
            // `&` is a mnemonic marker in a menu label; a project named
            // "a & b" would otherwise lose its ampersand and underline the
            // space after it.
            let wide: Vec<u16> = e.name.replace('&', "&&").encode_utf16().chain(Some(0)).collect();
            let _ = AppendMenuW(menu, MF_STRING, ID_BASE + i, PCWSTR(wide.as_ptr()));
        }
        let c = TrackPopupMenu(menu, TPM_RETURNCMD, at.x, at.y, None, frame, None);
        let _ = DestroyMenu(menu);
        c
    };

    let Some(entry) = (chosen.0 as usize).checked_sub(ID_BASE).and_then(|i| listing.entries.get(i)) else {
        wlogf!(frame, "[project] load list dismissed without a choice");
        return;
    };
    wlogf!(frame, "[project] load {:?} (saved_at={}) -> load_project_into_new_tab …", entry.name, entry.saved_at);
    let hinst = unsafe { windows::Win32::System::LibraryLoader::GetModuleHandleW(None) }
        .map(Into::into)
        .unwrap_or_default();
    match crate::project_ui::load_project_into_new_tab(frame, crate::app_handle(), hinst, &entry.path) {
        Ok(()) => wlogf!(frame, "[project] loaded {:?}", entry.name),
        Err(e) => {
            // **Said on screen as well as in the log.** The row was picked;
            // a failure that only a log records is, to the person, a click
            // that did nothing.
            wlogf!(frame, "[project] load {:?} failed: {}", entry.name, e);
            tell(frame, &format!("{}\n\n{}", tr(n_("The project could not be opened.")), e));
        }
    }
}

fn tell(frame: HWND, text: &str) {
    let title: Vec<u16> = tr(n_("Load Project")).encode_utf16().chain(Some(0)).collect();
    let body: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
    unsafe {
        MessageBoxW(Some(frame), PCWSTR(body.as_ptr()), PCWSTR(title.as_ptr()), MB_OK | MB_ICONINFORMATION);
    }
}
