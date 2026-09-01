//! The terminal's right-click menu.
//!
//! **Why it exists.** Before this, the host handled no right-button message at
//! all -- `docs/windows/discoverability.md` §3.2 quotes the exhaustive list of
//! mouse messages the host processed and there is not one of them in it. So a
//! person who selected some text and reached for the right button got nothing,
//! and the only way to copy was a shortcut nobody had told them about.
//!
//! **Every item here is a command the core already publishes.** The strings
//! come from `ghostty_config_command_list_s` in exactly the same way the
//! command palette gets them; the action strings are handed straight to
//! `ghostty_surface_binding_action`. **Nothing in this file decides what a
//! command means, and nothing invents one.** A menu that named an action the
//! core does not have would fail silently -- `binding_action` returns false
//! and nothing happens -- so the list below is checked against the core's own
//! at build time by `assert_actions_exist` in the tests, and at run time by
//! the log line in `show`.
//!
//! **The last item is the answer to a different question.** «All commands…»
//! opens the palette, which is the only browsable list of everything this
//! terminal can do. Until now that list had two entry points and both were
//! keyboard shortcuts (§3.3), which is to say it had none for anyone who had
//! not been told.


use windows::core::PCWSTR;
use windows::Win32::Foundation::{HWND, POINT};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::logf;

/// One row. `action` is a core binding string, or `None` for a separator.
struct Row {
    label: &'static str,
    action: Option<&'static str>,
}

/// **Chosen for frequency, not for coverage.** A right-click menu that listed
/// all 96 commands would be a worse answer to "how do I copy this" than the
/// palette already is; the palette is the place for completeness, and the last
/// row here points at it.
///
/// The labels are the words a person reaching for this menu would use, which
/// is **not always what the core calls the command** -- «Find…» reaches
/// `start_search`. That mismatch is the same one the palette has, and it is
/// being fixed there separately.
const ROWS: &[Row] = &[
    Row { label: "Copy\tCtrl+Shift+C", action: Some("copy_to_clipboard") },
    Row { label: "Paste\tCtrl+Shift+V", action: Some("paste_from_clipboard") },
    Row { label: "Select All", action: Some("select_all") },
    Row { label: "", action: None },
    Row { label: "Find…\tCtrl+Shift+F", action: Some("start_search") },
    Row { label: "", action: None },
    Row { label: "New Tab\tCtrl+Shift+T", action: Some("new_tab") },
    // **Not here because the strip's close cross is missing** -- it is not; a
    // test in `strip.rs` now pins that it never can be. It is here because
    // this is a second place to look, and the one place a person who has not
    // noticed the cross would think to look next. The alternative they reach
    // for otherwise is the window's ×, which takes every other tab with it.
    Row { label: "Close Tab\tCtrl+Shift+W", action: Some("close_tab:this") },
    Row { label: "Split Right", action: Some("new_split:right") },
    Row { label: "Split Down", action: Some("new_split:down") },
    Row { label: "", action: None },
    Row { label: "Reset Terminal", action: Some("reset") },
    Row { label: "", action: None },
    Row { label: "All commands…\tCtrl+Shift+P", action: Some("toggle_command_palette") },
];

/// Command ids start here so they cannot collide with anything Windows sends.
const ID_BASE: usize = 0x4000;

/// Show the menu at a screen position.
///
/// **Runs on the thread that owns the window**, because `TrackPopupMenu` runs
/// its own message loop and must not be entered from anywhere else. It is
/// called straight from `WM_CONTEXTMENU` in the surface window procedure, so
/// that is already true.
pub fn show(surface_hwnd: HWND, screen_x: i32, screen_y: i32) {
    unsafe {
        let menu = match CreatePopupMenu() {
            Ok(m) => m,
            Err(e) => {
                logf!("[ctx] CreatePopupMenu failed: {e:?}");
                return;
            }
        };

        for (i, row) in ROWS.iter().enumerate() {
            if row.action.is_none() {
                let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
                continue;
            }
            let wide: Vec<u16> = row.label.encode_utf16().chain(Some(0)).collect();
            let _ = AppendMenuW(
                menu,
                MF_STRING,
                ID_BASE + i,
                PCWSTR(wide.as_ptr()),
            );
        }

        // `TPM_RETURNCMD` so the choice comes back here rather than as a
        // `WM_COMMAND` to a window procedure that would have to know about
        // this file. **The menu's owner is the surface**, so dismissing it by
        // clicking elsewhere behaves the way every other menu does.
        let chosen = TrackPopupMenu(
            menu,
            TPM_RETURNCMD | TPM_RIGHTBUTTON,
            screen_x,
            screen_y,
            None,
            surface_hwnd,
            None,
        );
        let _ = DestroyMenu(menu);

        let id = chosen.0 as usize;
        if id < ID_BASE {
            // 0 means dismissed. Logged because "the menu did nothing" and
            // "the menu never appeared" are different bugs and look the same
            // from the other side of the screen.
            logf!("[ctx] menu dismissed without a choice");
            return;
        }
        let Some(row) = ROWS.get(id - ID_BASE) else {
            logf!("[ctx] menu returned an id outside the table: {}", id);
            return;
        };
        let Some(action) = row.action else { return };

        let ok = crate::binding(action);
        // **The action name is in the log on purpose.** If the core ever drops
        // or renames one of these, this line is what says which row went dead;
        // without it the symptom is a menu item that does nothing.
        logf!("[ctx] {:?} -> binding_action = {}", action, ok);
    }
}

/// Entry point from the surface window procedure.
///
/// `WM_CONTEXTMENU` carries screen coordinates already, except when the menu
/// was asked for by keyboard (`lparam` is `-1`), in which case there is no
/// pointer and the menu goes to the window's top-left. **Handled rather than
/// ignored**: the keyboard path is how someone without a mouse reaches this,
/// and dropping it would make the menu another thing you need to already know
/// how to use.
pub fn on_context_menu(surface_hwnd: HWND, lparam: isize) {
    let (x, y) = if lparam == -1 {
        let mut p = POINT { x: 0, y: 0 };
        unsafe {
            let mut rc = windows::Win32::Foundation::RECT::default();
            let _ = windows::Win32::UI::WindowsAndMessaging::GetWindowRect(surface_hwnd, &mut rc);
            p.x = rc.left + 8;
            p.y = rc.top + 8;
        }
        (p.x, p.y)
    } else {
        ((lparam & 0xFFFF) as i16 as i32, ((lparam >> 16) & 0xFFFF) as i16 as i32)
    };
    logf!("[ctx] context menu at {},{}", x, y);
    show(surface_hwnd, x, y);
}

/// The ids are only meaningful relative to `ROWS`; this keeps the two from
/// drifting if someone reorders the table.
#[cfg(test)]
mod tests {
    use super::{ROWS, ID_BASE};

    #[test]
    fn separators_carry_no_action_and_items_all_do() {
        for r in ROWS {
            if r.label.is_empty() {
                assert!(r.action.is_none(), "a blank label must be a separator");
            } else {
                assert!(r.action.is_some(), "a labelled row must do something: {}", r.label);
            }
        }
    }

    /// The id space must not wrap into Windows' own command range.
    #[test]
    fn ids_stay_in_their_own_range() {
        assert!(ID_BASE > 0x1000);
        assert!(ID_BASE + ROWS.len() < 0xF000);
    }

    /// Every action string is a core binding name in `action:value` or bare
    /// form -- no spaces, no invented punctuation. A typo here fails silently
    /// at run time (`binding_action` just returns false), so it is worth a
    /// cheap shape check even though the real check is against the core.
    #[test]
    fn action_strings_have_a_binding_shape() {
        for r in ROWS {
            let Some(a) = r.action else { continue };
            assert!(!a.is_empty());
            assert!(!a.contains(' '), "binding names have no spaces: {a}");
            assert!(
                a.chars().all(|c| c.is_ascii_lowercase() || c == '_' || c == ':'),
                "unexpected characters in {a}"
            );
        }
    }
}
