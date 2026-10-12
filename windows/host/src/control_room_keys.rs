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
//!  * A binding in a key sequence or a key table, and `catch_all`.
//!  * A `performable` binding of an action that takes an argument -- except
//!    `goto_tab`, whose tab is read off the digit on the key
//!    (`reach::goto_tab_of`; the default `alt+1` … `alt+8` are exactly this
//!    off macOS, and were dead on the panel until task 1439).
//!  * Anything while an input method is composing: the panel takes no text
//!    and hands the input method's document back, so there is none.

use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::{GetAncestor, GA_ROOT};

use polter_control_room::reach::{self, Key, Listed, Pressed, Trigger};

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
///
/// **Which of the two the configuration is asked, and how they are put
/// together, is `reach::bindings`** -- it is where Alt+2 was lost (task
/// 1439), so it is where the tests are. This hands it the forward listing
/// and the reverse lookup and decides nothing.
fn bindings() -> Vec<(String, Trigger)> {
    // Every key of every action, by the action's tag: the forward table.
    let listed: Vec<Listed> = crate::keybinds::rows()
        .iter()
        .map(|r| Listed {
            action: r.action.to_string(),
            sequence: r.sequence,
            triggers: r.triggers.iter().filter_map(|t| trigger(*t)).collect(),
        })
        .collect();
    // One key for a whole name (`goto_tab:3`), and never a performable one.
    let reverse = |action: &str| match keys::trigger_lookup(action) {
        Lookup::Bound(t) => trigger(t),
        Lookup::Unbound => None,
        Lookup::NoConfig => None,
        Lookup::NoLookup => None,
    };
    reach::bindings(&listed, &reverse)
}

thread_local! {
    /// The window whose control room is handing a key to the core right
    /// now, and what the host's action callback did with what came back.
    /// Set for the length of the `ghostty_app_key` call and no longer.
    static ASKING: std::cell::Cell<Option<Asking>> = const { std::cell::Cell::new(None) };
}

#[derive(Clone, Copy)]
struct Asking {
    frame: isize,
    /// How many actions the core sent back while the key was with it.
    actions: u32,
    /// How many of them the host could not carry out.
    refused: u32,
}

/// The window an app-scoped action is for, when the core sent it because of
/// a key pressed on that window's control room.
///
/// **Why the action cannot say so itself.** The core performs an app-scoped
/// binding on the app: its action arrives with no surface, and a host that
/// places windows by the surface that asked has nothing to go on. In a
/// terminal that never shows, because the key goes to the surface and the
/// action comes back naming it. From the panel there is no surface -- so
/// Ctrl+Shift+N arrived as "new_window, for nobody", was not queued, and
/// the panel's log said the core had performed it (task 1439).
///
/// None outside a key the panel is handing over, which is every other time.
pub fn asking() -> Option<HWND> {
    ASKING.with(|a| a.get()).map(|a| HWND(a.frame as *mut std::ffi::c_void))
}

/// The action callback's account of one action that came back during the
/// key: whether the host carried it out.
pub fn answered(carried_out: bool) {
    ASKING.with(|a| {
        if let Some(mut now) = a.get() {
            now.actions += 1;
            if !carried_out {
                now.refused += 1;
            }
            a.set(Some(now));
        }
    });
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
            ASKING.with(|a| a.set(Some(Asking { frame: frame.0 as isize, actions: 0, refused: 0 })));
            let taken = unsafe { (api.app_key)(app, ev) };
            let told = ASKING.with(|a| a.take());
            if taken {
                // **What the core says and what happened are two things**,
                // and this line used to report the first as the second:
                // "the core performed it", over a new window nobody made.
                // `app_key` is true when the key is an app-scoped binding
                // and the core has taken it; whether the host then did the
                // thing is what the action callback counted.
                let (actions, refused) = told.map(|t| (t.actions, t.refused)).unwrap_or((0, 0));
                let outcome = reach::app_key_outcome(actions, refused);
                wlogf!(
                    frame,
                    "[control-room] key vk=0x{:02x} mods=0x{:x} -> app_key=true (an app-scoped binding, taken by the core): {} ({} action(s) came back, {} not carried out)",
                    vk,
                    mods,
                    outcome.sentence(),
                    actions,
                    refused
                );
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
