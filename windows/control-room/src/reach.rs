//! What can still be done with the control room's tab in front, where there
//! is no terminal to do it on (`dev-docs/windows/control-room.md`, 2.5).
//!
//! On Windows a key reaches the window that has the keyboard, and a binding
//! is performed by the core on the terminal that window is. The control
//! room's panel is not a terminal. Left at that, every key bound in the
//! configuration is dead while it is in front, and so is every menu row and
//! palette entry, because those are performed on "the terminal in front" too.
//!
//! This says, for an action by its name, which of three things it is:
//!
//!  * **the host's own** -- going to a tab, opening one, closing this one,
//!    the command palette, the control room itself. The host has an entry
//!    for each and needs no terminal. This is a closed list, [`Host`];
//!  * **the application's** -- the core scopes it to the app, so any
//!    terminal there is can be asked to perform it, and which one makes no
//!    difference;
//!  * **a terminal's** -- copy, paste, split, search and the rest. With the
//!    control room in front there is nothing for these to act on: a menu
//!    greys them and a key does nothing.
//!
//! And it says which of the host's own a key press is, by the bindings the
//! configuration holds: the same question the macOS host's
//! `ControlRoomRules.tabIndex` answers for "go to tab N", for the whole of
//! the closed list.
//!
//! **Why a key is matched here and not by the core.** The core matches a key
//! to a binding only on a surface (`ghostty_surface_key`), and performing it
//! there would also *type* an unbound key into that terminal. Its app-level
//! entry (`ghostty_app_key`) performs app-scoped bindings only. So for the
//! tab actions the host asks the configuration what each is bound to and
//! compares. The comparison is the first three steps of the core's
//! `Binding.Set.getEvent`: the physical key with the binding modifiers, then
//! the unshifted character with them. **Not matched: `catch_all`, key
//! sequences, key tables, and a binding marked `performable`** (the reverse
//! lookup the host uses for an action with an argument leaves those out).

use std::sync::OnceLock;

/// What the host does itself, with no terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Host {
    /// The tab at this place, counting from 1; past the last is the last.
    GotoTab(u32),
    LastTab,
    NextTab,
    PreviousTab,
    NewTab,
    /// The tab in front, which is the control room's own.
    CloseTab,
    CloseWindow,
    NewWindow,
    CommandPalette,
    /// Go to the control room: with it in front already, nothing to do.
    ControlRoom,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Needs {
    /// The host performs it.
    Nothing(Host),
    /// Any terminal's surface performs it; which one makes no difference.
    AnyTerminal,
    /// It acts on the terminal in front, and there has to be one.
    Terminal,
}

/// The core's app-scoped actions (`Binding.Action.scope` in
/// `src/input/Binding.zig`), less the ones the host performs itself. A test
/// reads that function and fails when this is not the same set.
pub const APP_SCOPED: &[&str] = &[
    "ignore",
    "unbind",
    "open_config",
    "reload_config",
    "close_all_windows",
    "quit",
    "toggle_quick_terminal",
    "toggle_visibility",
    "check_for_updates",
    "show_gtk_inspector",
    "screenshot",
    "undo",
    "redo",
];

/// The app-scoped actions the host performs itself rather than passing to a
/// terminal: together with [`APP_SCOPED`] they are everything the core
/// scopes to the app.
pub const APP_SCOPED_HOSTED: &[&str] = &["new_window", "poltergeist_toggle_control_room"];

/// What an action needs, by its name as a binding spells it (`new_tab`,
/// `goto_tab:3`, `close_tab:this`).
pub fn needs(action: &str) -> Needs {
    let (name, arg) = match action.split_once(':') {
        Some((name, arg)) => (name, Some(arg)),
        None => (action, None),
    };
    let host = match (name, arg) {
        ("goto_tab", Some(n)) => n.parse::<u32>().ok().filter(|n| *n >= 1).map(Host::GotoTab),
        ("last_tab", None) => Some(Host::LastTab),
        ("next_tab", None) => Some(Host::NextTab),
        ("previous_tab", None) => Some(Host::PreviousTab),
        ("new_tab", None) => Some(Host::NewTab),
        // Closing the other tabs, or the ones to the right, asks about the
        // terminals in them and is left to a terminal tab.
        ("close_tab", None) | ("close_tab", Some("this")) => Some(Host::CloseTab),
        ("close_window", None) => Some(Host::CloseWindow),
        ("new_window", None) => Some(Host::NewWindow),
        ("toggle_command_palette", None) => Some(Host::CommandPalette),
        ("poltergeist_toggle_control_room", None) => Some(Host::ControlRoom),
        _ => None,
    };
    match host {
        Some(h) => Needs::Nothing(h),
        None if APP_SCOPED.contains(&name) => Needs::AnyTerminal,
        None => Needs::Terminal,
    }
}

/// Whether a menu row for `action` can be chosen with the control room in
/// front. `any_terminal` is whether the application has a terminal at all.
pub fn offered(action: &str, any_terminal: bool) -> bool {
    match needs(action) {
        Needs::Nothing(_) => true,
        Needs::AnyTerminal => any_terminal,
        Needs::Terminal => false,
    }
}

// ---------------------------------------------------------------- the keys

/// The actions whose bindings the panel asks the configuration for, each
/// spelled as a binding spells it. **Closed, and short on purpose**: these
/// are what the tab strip is for, and each has a host entry that needs no
/// terminal.
///
/// Not here, and why:
///  * `new_window`, `poltergeist_toggle_control_room` and the other
///    app-scoped actions: `ghostty_app_key` performs those, by the core's
///    own matching, before this list is consulted;
///  * `close_tab:other` / `:right`, `move_tab`, `move_tab_to_new_window`,
///    `toggle_tab_overview`: left for later -- each has a rule of its own
///    (asking, the place of a tab with no terminal) that is not written yet;
///  * anything about a terminal: there is none.
pub const KEYED: &[&str] = &[
    "goto_tab:1",
    "goto_tab:2",
    "goto_tab:3",
    "goto_tab:4",
    "goto_tab:5",
    "goto_tab:6",
    "goto_tab:7",
    "goto_tab:8",
    "last_tab",
    "next_tab",
    "previous_tab",
    "new_tab",
    "close_tab:this",
    "close_window",
    "toggle_command_palette",
];

/// The modifiers a binding is matched on: the core's `Mods.binding()`.
pub mod mods {
    pub const SHIFT: u8 = 1 << 0;
    pub const CTRL: u8 = 1 << 1;
    pub const ALT: u8 = 1 << 2;
    pub const SUPER: u8 = 1 << 3;
    pub const ALL: u8 = SHIFT | CTRL | ALT | SUPER;
}

/// A key as the host saw it go down.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pressed {
    /// The native key code: the scan code, with `0xE000` on an extended key.
    /// What the core's key table is keyed by on Windows.
    pub native: u32,
    /// What the key types with nothing held, 0 for none.
    pub unshifted: u32,
    /// Of `mods`, the ones that are down.
    pub mods: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Key {
    /// A physical key, by its name in `ghostty.h` without the prefix
    /// (`DIGIT_1`, `TAB`, `T`).
    Physical(String),
    /// A character.
    Unicode(u32),
}

/// What an action is bound to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Trigger {
    pub key: Key,
    pub mods: u8,
}

/// Whether a key press is this trigger.
pub fn matches(pressed: &Pressed, trigger: &Trigger) -> bool {
    if pressed.mods & mods::ALL != trigger.mods & mods::ALL {
        return false;
    }
    match &trigger.key {
        Key::Physical(name) => native_code(name) == Some(pressed.native),
        Key::Unicode(cp) => pressed.unshifted != 0 && pressed.unshifted == *cp,
    }
}

/// The host's own action a key press is, from what the configuration binds
/// each of `KEYED` to. `bindings` is `(action, trigger)`, an action once for
/// each key it has.
///
/// The physical key is tried before the character for every binding, as the
/// core does: a key that is one action by position and another by what it
/// types is the first.
pub fn pressed_action(pressed: &Pressed, bindings: &[(String, Trigger)]) -> Option<Host> {
    let hosted = |action: &str| match needs(action) {
        Needs::Nothing(h) => Some(h),
        Needs::AnyTerminal | Needs::Terminal => None,
    };
    let find = |physical: bool| {
        bindings.iter().find_map(|(action, trigger)| {
            let is_physical = match &trigger.key {
                Key::Physical(_) => true,
                Key::Unicode(_) => false,
            };
            (is_physical == physical && matches(pressed, trigger)).then(|| hosted(action)).flatten()
        })
    };
    find(true).or_else(|| find(false))
}

// The core's own key table, read rather than copied: which native code is
// which key is one fact, and it lives in `src/input/keycodes.zig`.
const KEYCODES: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/input/keycodes.zig"));

/// `(name as ghostty.h has it, the native code on Windows)` for every key
/// the core's table gives a Windows code.
fn table() -> &'static [(String, u32)] {
    static TABLE: OnceLock<Vec<(String, u32)>> = OnceLock::new();
    TABLE.get_or_init(|| parse_keycodes(KEYCODES))
}

/// Read the two tables of `keycodes.zig`: W3C code to key (`.{ "KeyA",
/// .key_a },`) and the raw entries (`.{ usb, evdev, xkb, win, mac, "KeyA"
/// },`), joined on the code.
fn parse_keycodes(src: &str) -> Vec<(String, u32)> {
    let mut code_to_key: Vec<(String, String)> = Vec::new();
    let mut out: Vec<(String, u32)> = Vec::new();
    for line in src.lines() {
        let t = line.trim();
        let Some(inner) = t.strip_prefix(".{").and_then(|r| r.trim_end_matches(',').strip_suffix('}')) else {
            continue;
        };
        let parts: Vec<&str> = inner.split(',').map(str::trim).collect();
        match parts.as_slice() {
            // `"KeyA", .key_a`
            [code, key] if code.starts_with('"') && key.starts_with('.') => {
                code_to_key.push((code.trim_matches('"').to_string(), header_name(&key[1..])));
            }
            // `0x070004, 0x001e, 0x0026, 0x001e, 0x0000, "KeyA"`
            [_usb, _evdev, _xkb, win, _mac, code] if code.starts_with('"') => {
                let code = code.trim_matches('"');
                let Some(win) = win.strip_prefix("0x").and_then(|h| u32::from_str_radix(h, 16).ok()) else {
                    continue;
                };
                // 0 is "this key has no code on this platform".
                if win == 0 {
                    continue;
                }
                if let Some((_, name)) = code_to_key.iter().find(|(c, _)| c == code) {
                    out.push((name.clone(), win));
                }
            }
            _ => {}
        }
    }
    out
}

/// A member of the core's `Key` enum as `ghostty.h` names it: `key_a` is
/// `A`, everything else is upper-cased.
fn header_name(zig: &str) -> String {
    match zig.strip_prefix("key_") {
        Some(letter) if letter.len() == 1 => letter.to_ascii_uppercase(),
        _ => zig.to_ascii_uppercase(),
    }
}

/// The native code of a physical key on Windows, by its `ghostty.h` name.
pub fn native_code(name: &str) -> Option<u32> {
    table().iter().find(|(n, _)| n == name).map(|(_, code)| *code)
}

#[cfg(test)]
mod tests {
    use super::*;

    const BINDING_ZIG: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/input/Binding.zig"));
    const HEADER: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../include/ghostty.h"));

    fn physical(name: &str, mods: u8) -> Trigger {
        Trigger { key: Key::Physical(name.into()), mods }
    }

    fn unicode(c: char, mods: u8) -> Trigger {
        Trigger { key: Key::Unicode(c as u32), mods }
    }

    /// The Windows defaults for the keyed actions, as `Config.zig` binds them.
    fn defaults() -> Vec<(String, Trigger)> {
        let mut b = Vec::new();
        for n in 1..=8u32 {
            b.push((format!("goto_tab:{n}"), physical(&format!("DIGIT_{n}"), mods::ALT)));
        }
        b.push(("last_tab".into(), physical("DIGIT_9", mods::ALT)));
        b.push(("next_tab".into(), physical("TAB", mods::CTRL)));
        b.push(("next_tab".into(), physical("PAGE_DOWN", mods::CTRL)));
        b.push(("previous_tab".into(), physical("TAB", mods::CTRL | mods::SHIFT)));
        b.push(("previous_tab".into(), physical("PAGE_UP", mods::CTRL)));
        b.push(("new_tab".into(), unicode('t', mods::CTRL | mods::SHIFT)));
        b.push(("close_tab:this".into(), unicode('w', mods::CTRL | mods::SHIFT)));
        b.push(("toggle_command_palette".into(), unicode('p', mods::CTRL | mods::SHIFT)));
        b
    }

    fn press(native: u32, unshifted: char, mods: u8) -> Pressed {
        Pressed { native, unshifted: unshifted as u32, mods }
    }

    // -- which of the three an action is ---------------------------------------

    #[test]
    fn the_tab_actions_are_the_hosts_own() {
        assert_eq!(needs("goto_tab:3"), Needs::Nothing(Host::GotoTab(3)));
        assert_eq!(needs("last_tab"), Needs::Nothing(Host::LastTab));
        assert_eq!(needs("next_tab"), Needs::Nothing(Host::NextTab));
        assert_eq!(needs("previous_tab"), Needs::Nothing(Host::PreviousTab));
        assert_eq!(needs("new_tab"), Needs::Nothing(Host::NewTab));
        assert_eq!(needs("close_tab"), Needs::Nothing(Host::CloseTab));
        assert_eq!(needs("close_tab:this"), Needs::Nothing(Host::CloseTab));
        assert_eq!(needs("close_window"), Needs::Nothing(Host::CloseWindow));
        assert_eq!(needs("new_window"), Needs::Nothing(Host::NewWindow));
        assert_eq!(needs("toggle_command_palette"), Needs::Nothing(Host::CommandPalette));
        assert_eq!(needs("poltergeist_toggle_control_room"), Needs::Nothing(Host::ControlRoom));
    }

    #[test]
    fn what_acts_on_a_terminal_needs_one() {
        for action in [
            "copy_to_clipboard",
            "paste_from_clipboard",
            "new_split:right",
            "toggle_split_zoom",
            "start_search",
            "clear_screen",
            "increase_font_size:1",
            "poltergeist_supervisor",
            // Closing other tabs asks about the terminals in them.
            "close_tab:other",
            "close_tab:right",
            "move_tab:1",
            // A tab number that is not one.
            "goto_tab:0",
            "goto_tab:x",
            "goto_tab",
            // Not an action at all.
            "",
            "new_tab:3",
        ] {
            assert_eq!(needs(action), Needs::Terminal, "{action}");
            assert!(!offered(action, true), "{action}");
        }
    }

    #[test]
    fn an_app_action_needs_some_terminal_and_none_in_particular() {
        for action in ["quit", "open_config", "reload_config", "check_for_updates", "close_all_windows"] {
            assert_eq!(needs(action), Needs::AnyTerminal, "{action}");
            assert!(offered(action, true), "{action}");
            assert!(!offered(action, false), "{action}");
        }
        // The host's own are offered with no terminal anywhere.
        assert!(offered("new_tab", false));
        assert!(offered("new_window", false));
    }

    /// The names in the `.app` arms of `Action.scope`.
    fn core_app_scoped() -> Vec<String> {
        let start = BINDING_ZIG.find("pub fn scope(self: Action) Scope {").expect("Action.scope is in Binding.zig");
        let body = &BINDING_ZIG[start..];
        let end = body.find("\n    }\n").expect("Action.scope ends");
        let mut out = Vec::new();
        let mut names: Vec<String> = Vec::new();
        for line in body[..end].lines() {
            let t = line.trim();
            if let Some(name) = t.strip_prefix('.').and_then(|r| r.strip_suffix(',')) {
                names.push(name.to_string());
            } else if t.starts_with("=> .app") {
                out.append(&mut names);
            } else if t.starts_with("=> .") {
                names.clear();
            }
        }
        out
    }

    #[test]
    fn the_app_scoped_actions_are_the_ones_the_core_scopes_to_the_app() {
        let mut core = core_app_scoped();
        // The parse has a floor: the function has a dozen `.app` names, and a
        // reader that stopped matching would compare two empty lists.
        assert!(core.len() >= 12, "only {} app-scoped names were read", core.len());
        let mut here: Vec<String> = APP_SCOPED.iter().chain(APP_SCOPED_HOSTED).map(|s| s.to_string()).collect();
        core.sort();
        here.sort();
        assert_eq!(here, core);
        for action in APP_SCOPED_HOSTED {
            assert!(matches!(needs(action), Needs::Nothing(_)), "{action}");
        }
    }

    #[test]
    fn every_keyed_action_is_the_hosts_own_and_is_one_the_core_has() {
        for action in KEYED {
            assert!(matches!(needs(action), Needs::Nothing(_)), "{action}");
            let name = action.split(':').next().unwrap();
            assert!(BINDING_ZIG.contains(&format!("\n    {name}")), "{name} is not an action in Binding.zig");
        }
        // The app-scoped ones are the core's to match, not this list's.
        for action in APP_SCOPED.iter().chain(APP_SCOPED_HOSTED) {
            assert!(!KEYED.contains(action), "{action}");
        }
    }

    // -- the key table -----------------------------------------------------------

    #[test]
    fn the_native_codes_are_the_cores_own_table() {
        // Read from `keycodes.zig`, so these are spot checks that the right
        // column is read (`win`, the fourth), not a second copy of it.
        assert_eq!(native_code("DIGIT_1"), Some(0x0002));
        assert_eq!(native_code("DIGIT_9"), Some(0x000a));
        assert_eq!(native_code("TAB"), Some(0x000f));
        assert_eq!(native_code("T"), Some(0x0014));
        assert_eq!(native_code("W"), Some(0x0011));
        assert_eq!(native_code("PAGE_DOWN"), Some(0xe051));
        assert_eq!(native_code("PAGE_UP"), Some(0xe049));
        assert_eq!(native_code("NOT_A_KEY"), None);
        assert!(table().len() > 100, "{}", table().len());
    }

    #[test]
    fn every_name_in_the_table_is_a_key_in_the_header() {
        for (name, _) in table() {
            assert!(HEADER.contains(&format!("GHOSTTY_KEY_{name},")), "{name} is not in ghostty.h");
        }
    }

    // -- matching ----------------------------------------------------------------

    #[test]
    fn the_default_keys_reach_their_tab_actions() {
        let b = defaults();
        assert_eq!(pressed_action(&press(0x02, '1', mods::ALT), &b), Some(Host::GotoTab(1)));
        assert_eq!(pressed_action(&press(0x09, '8', mods::ALT), &b), Some(Host::GotoTab(8)));
        assert_eq!(pressed_action(&press(0x0a, '9', mods::ALT), &b), Some(Host::LastTab));
        assert_eq!(pressed_action(&press(0x0f, '\t', mods::CTRL), &b), Some(Host::NextTab));
        assert_eq!(pressed_action(&press(0x0f, '\t', mods::CTRL | mods::SHIFT), &b), Some(Host::PreviousTab));
        assert_eq!(pressed_action(&press(0xe051, '\0', mods::CTRL), &b), Some(Host::NextTab));
        assert_eq!(pressed_action(&press(0xe049, '\0', mods::CTRL), &b), Some(Host::PreviousTab));
        assert_eq!(pressed_action(&press(0x14, 't', mods::CTRL | mods::SHIFT), &b), Some(Host::NewTab));
        assert_eq!(pressed_action(&press(0x11, 'w', mods::CTRL | mods::SHIFT), &b), Some(Host::CloseTab));
        assert_eq!(pressed_action(&press(0x19, 'p', mods::CTRL | mods::SHIFT), &b), Some(Host::CommandPalette));
    }

    #[test]
    fn the_modifiers_have_to_be_exactly_the_bindings() {
        let b = defaults();
        // One more held, one fewer, a different one.
        assert_eq!(pressed_action(&press(0x02, '1', mods::ALT | mods::SHIFT), &b), None);
        assert_eq!(pressed_action(&press(0x02, '1', 0), &b), None);
        assert_eq!(pressed_action(&press(0x02, '1', mods::CTRL), &b), None);
        assert_eq!(pressed_action(&press(0x14, 't', mods::CTRL), &b), None);
        assert_eq!(pressed_action(&press(0x14, 't', mods::CTRL | mods::SHIFT | mods::ALT), &b), None);
    }

    #[test]
    fn a_character_binding_follows_the_layout_and_a_physical_one_the_position() {
        let b = defaults();
        // On a layout where the key in T's place types `y`: `ctrl+shift+t`
        // is wherever `t` is, and Alt+1 is still the key in 1's place even
        // where it types `&`.
        assert_eq!(pressed_action(&press(0x14, 'y', mods::CTRL | mods::SHIFT), &b), None);
        assert_eq!(pressed_action(&press(0x15, 't', mods::CTRL | mods::SHIFT), &b), Some(Host::NewTab));
        assert_eq!(pressed_action(&press(0x02, '&', mods::ALT), &b), Some(Host::GotoTab(1)));
    }

    #[test]
    fn a_key_bound_to_something_about_a_terminal_is_not_the_hosts() {
        let mut b = defaults();
        b.push(("copy_to_clipboard".into(), unicode('c', mods::CTRL | mods::SHIFT)));
        b.push(("quit".into(), unicode('q', mods::CTRL | mods::SHIFT)));
        assert_eq!(pressed_action(&press(0x2e, 'c', mods::CTRL | mods::SHIFT), &b), None);
        // An app action is the core's to match and perform.
        assert_eq!(pressed_action(&press(0x10, 'q', mods::CTRL | mods::SHIFT), &b), None);
        // A key with no binding at all.
        assert_eq!(pressed_action(&press(0x1e, 'a', 0), &b), None);
        assert_eq!(pressed_action(&press(0x1e, 'a', 0), &[]), None);
    }

    #[test]
    fn a_rebound_key_is_followed_and_the_old_one_is_let_go() {
        let b = vec![("new_tab".to_string(), unicode('n', mods::CTRL))];
        assert_eq!(pressed_action(&press(0x31, 'n', mods::CTRL), &b), Some(Host::NewTab));
        assert_eq!(pressed_action(&press(0x14, 't', mods::CTRL | mods::SHIFT), &b), None);
    }

    #[test]
    fn the_position_wins_over_the_character_as_in_the_core() {
        // One key, bound by position to one action and by character to
        // another: the physical binding is tried first.
        let b = vec![
            ("new_tab".to_string(), unicode('1', mods::ALT)),
            ("goto_tab:1".to_string(), physical("DIGIT_1", mods::ALT)),
        ];
        assert_eq!(pressed_action(&press(0x02, '1', mods::ALT), &b), Some(Host::GotoTab(1)));
    }

    #[test]
    fn a_key_that_types_nothing_matches_no_character() {
        let b = vec![("new_tab".to_string(), Trigger { key: Key::Unicode(0), mods: 0 })];
        assert_eq!(pressed_action(&Pressed { native: 0x3b, unshifted: 0, mods: 0 }, &b), None);
    }
}
