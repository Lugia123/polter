//! The keyboard while the control room's panel has it.
//!
//! A key reaches the window that holds the keyboard, and a binding is
//! performed by the core on the terminal that window is. The panel is not a
//! terminal, so left alone every bound key is dead while it is in front.
//! This is the way out, in two steps, after the panel's own keys (up, down,
//! Enter) have had theirs:
//!
//!  1. **`ghostty_app_key`**: the core matches the key against the
//!     configuration itself and performs the binding when it is app-scoped
//!     -- the control room's own toggle, a new window, quit, the
//!     configuration. Nothing here knows what those keys are.
//!  2. **The closed list** (`polter_control_room::reach::KEYED`): go to a
//!     tab, open one, close this one, close the window, the command palette.
//!     The configuration is asked what each is bound to *now*, the press is
//!     compared (`reach::pressed_action`), and the host performs it
//!     (`tabs::perform_hosted`).
//!
//! Anything else is not handled: the caller hands it to `DefWindowProcW`.
//!
//! **This file compares nothing itself.** Which action a key is, which
//! actions are on the list and why, and the key table are all `reach`, which
//! is tested where it is written. What is here is the asking and the
//! passing on. `dev-docs/windows/control-room.md` 2.5 has the list and what
//! is deliberately not on it; `keys.rs`'s accelerator table is untouched --
//! it runs only for a terminal.
//!
//! # Not matched
//!
//!  * A binding in a key sequence or a key table, `catch_all`, and a
//!    `performable` binding of an action that takes an argument.
//!  * Anything while an input method is composing: the panel takes no text
//!    and hands the input method's document back, so there is none.

use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::{GetAncestor, GA_ROOT};

use polter_control_room::reach::{self, Key, Pressed, Trigger};

use crate::ffi;
use crate::keys::{self, Lookup, TriggerC, ACTION_PRESS, ACTION_REPEAT, TRIGGER_PHYSICAL, TRIGGER_UNICODE};
use crate::wlogf;

/// A core trigger as `reach` compares it; none for one it cannot compare
/// (`catch_all`, or a physical key the header has no name for).
fn trigger(t: TriggerC) -> Option<Trigger> {
    let key = if t.tag == TRIGGER_PHYSICAL {
        Key::Physical(crate::keyseq::key_name(t.key)?.to_string())
    } else if t.tag == TRIGGER_UNICODE {
        Key::Unicode(t.key)
    } else {
        return None;
    };
    Some(Trigger { key, mods: (t.mods as u8) & reach::mods::ALL })
}

/// What the configuration binds each action of the closed list to, right
/// now. **Asked on every key and never kept**: `reload_config` replaces the
/// bindings, and there is no signal to drop a cache on (`keys::shortcut_for`
/// has the same note).
fn bindings() -> Vec<(String, Trigger)> {
    let mut out = Vec::new();
    // Every key of every action, by the action's tag: the forward table.
    let rows = crate::keybinds::rows();
    for action in reach::KEYED {
        let whole = rows.iter().find(|r| r.action == *action && !r.sequence);
        match whole {
            // An action with no argument: its tag is its whole name, and the
            // forward table has every key it is bound to.
            Some(row) => {
                for t in &row.triggers {
                    if let Some(t) = trigger(*t) {
                        out.push((action.to_string(), t));
                    }
                }
            }
            // An action with an argument (`goto_tab:3`): the forward table
            // carries the tag only and cannot tell 3 from 7, so the one key
            // the reverse lookup gives for the whole name. Also where an
            // action whose keys include a sequence ends up.
            None => match keys::trigger_lookup(action) {
                Lookup::Bound(t) => {
                    if let Some(t) = trigger(t) {
                        out.push((action.to_string(), t));
                    }
                }
                Lookup::Unbound => {}
                Lookup::NoConfig => {}
                Lookup::NoLookup => {}
            },
        }
    }
    out
}

/// A key went down on the panel and the panel had no use of its own for it.
/// True when it was a binding and has been performed.
pub fn handle(hwnd: HWND, wp: WPARAM, lp: LPARAM) -> bool {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let vk = wp.0 as u32;
    let mods = keys::mods();
    let native = keys::keycode(lp);
    let unshifted = keys::unshifted_codepoint(vk);

    // Step 1: the core's own matching, for what it scopes to the app.
    if let Some(api) = crate::api_opt() {
        let app = crate::app_opt();
        if !app.is_null() {
            let ev = ffi::KeyEvent {
                action: if keys::is_repeat(lp) { ACTION_REPEAT } else { ACTION_PRESS },
                mods,
                consumed_mods: 0,
                keycode: native,
                text: std::ptr::null(),
                unshifted_codepoint: unshifted,
                composing: false,
            };
            if unsafe { (api.app_key)(app, ev) } {
                wlogf!(frame, "[control-room] key vk=0x{:02x} mods=0x{:x} -> app_key=true (an app-scoped binding; the core performed it)", vk, mods);
                return true;
            }
        }
    }

    // Step 2: the closed list.
    let pressed = Pressed { native, unshifted, mods: (mods as u8) & reach::mods::ALL };
    match reach::pressed_action(&pressed, &bindings()) {
        Some(host) => {
            wlogf!(frame, "[control-room] key vk=0x{:02x} mods=0x{:x} -> {:?}", vk, mods, host);
            crate::tabs::perform_hosted(frame, host, "a key on the control room");
            true
        }
        None => {
            // absence: depends -- only a key with a modifier held is worth a
            // line; a bare key that is nothing is every stray press.
            if pressed.mods != 0 {
                wlogf!(frame, "[control-room] key vk=0x{:02x} mods=0x{:x} -> not a binding the control room answers", vk, mods);
            }
            false
        }
    }
}
