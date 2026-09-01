//! The terminal's right-click menu.
//!
//! **Why it exists.** Before this, the host handled no right-button message at
//! all -- `docs/windows/discoverability.md` §3.2 quotes the exhaustive list of
//! mouse messages the host processed and there is not one of them in it. So a
//! person who selected some text and reached for the right button got nothing,
//! and the only way to copy was a shortcut nobody had told them about.
//!
//! **Every item here is a command the core already publishes.** The action
//! strings are handed straight to `ghostty_surface_binding_action`, and every
//! one of them was checked against the `Action` union in
//! `src/input/Binding.zig` rather than against any document -- `s4.md` §3.2
//! shipped four action names the core does not have, and a menu that names an
//! action the core does not have **fails silently**: `binding_action` returns
//! false and nothing happens. That is why the log line in `show` prints the
//! action string and the result, and why the tests below pin the shape.
//!
//! **The shortcut half of every label comes from the core's binding table.**
//! It used to be a string constant compiled into the label (`"Copy\tCtrl+
//! Shift+C"`). `docs/windows/s4.md` §3.4 point 1 is about exactly that: a
//! constant is wrong the moment the user rebinds the action, and **nothing
//! anywhere reports it** -- there is no failing action, no red log line, just
//! a menu quietly instructing the user to press the wrong key. The labels
//! below now carry no tab and no key; `keys::shortcut_for` asks
//! `ghostty_config_trigger` at the moment the menu is built.
//!
//! **The list is the macOS one.** `SurfaceView_AppKit.swift`'s `menu(for:)`
//! is the reference; the rows here follow it in order, plus the four this
//! host had already and macOS reaches elsewhere (Select All, Find…, New Tab,
//! Close Tab, and the palette row at the bottom).
//!
//! **The last item is the answer to a different question.** «All commands…»
//! opens the palette, which is the only browsable list of everything this
//! terminal can do. Until now that list had two entry points and both were
//! keyboard shortcuts (§3.3), which is to say it had none for anyone who had
//! not been told.

use std::sync::atomic::{AtomicBool, Ordering};

use windows::core::PCWSTR;
use windows::Win32::Foundation::{HWND, POINT};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::ffi::Surface;
use crate::logf;

/// Which state bit ticks a row.
///
/// **A row that offers to change something has to say whether it already
/// happened.** The reason is copied verbatim from the macOS side, which wrote
/// it down first: an item that has been used reads exactly like one that has
/// not, and the only way to find out whether the last click landed is to
/// click it again -- which undoes it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tick {
    Readonly,
    PgSupervisor,
    PgWatched,
    PgShielded,
}

/// One row. `action` is a core binding string, or `None` for a separator.
struct Row {
    label: &'static str,
    action: Option<&'static str>,
    tick: Option<Tick>,
}

const fn item(label: &'static str, action: &'static str) -> Row {
    Row { label, action: Some(action), tick: None }
}
const fn checkable(label: &'static str, action: &'static str, tick: Tick) -> Row {
    Row { label, action: Some(action), tick: Some(tick) }
}
const SEP: Row = Row { label: "", action: None, tick: None };

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
    item("复制", "copy_to_clipboard"),
    item("粘贴", "paste_from_clipboard"),
    item("全选", "select_all"),
    SEP,
    item("查找…", "start_search"),
    SEP,
    item("新建标签", "new_tab"),
    // **Not here because the strip's close cross is missing** -- it is not; a
    // test in `strip.rs` now pins that it never can be. It is here because
    // this is a second place to look, and the one place a person who has not
    // noticed the cross would think to look next. The alternative they reach
    // for otherwise is the window's ×, which takes every other tab with it.
    item("关闭标签", "close_tab:this"),
    SEP,
    // All four directions, because macOS has all four. Two of them were
    // missing here, and a split menu that offers right and down but not left
    // and up reads as "this terminal cannot split left", not as "this menu is
    // short".
    item("向右分屏", "new_split:right"),
    item("向左分屏", "new_split:left"),
    item("向下分屏", "new_split:down"),
    item("向上分屏", "new_split:up"),
    SEP,
    item("重置终端", "reset"),
    item("终端检查器", "inspector:toggle"),
    checkable("只读", "toggle_readonly", Tick::Readonly),
    SEP,
    // Two different titles, and they are genuinely different: the tab title
    // sticks to the tab and survives focus moving inside it, the surface
    // title is this pane's. The core has a separate action for each.
    item("改标签标题…", "prompt_tab_title"),
    item("改终端标题…", "prompt_surface_title"),
    SEP,
    checkable(
        "设为总管",
        "poltergeist_supervisor",
        Tick::PgSupervisor,
    ),
    checkable(
        "监督此终端",
        "poltergeist_toggle_watch",
        Tick::PgWatched,
    ),
    checkable(
        "禁止 agent 进入",
        "poltergeist_toggle_shielded",
        Tick::PgShielded,
    ),
    SEP,
    item("命令面板", "toggle_command_palette"),
];

/// Command ids start here so they cannot collide with anything Windows sends.
const ID_BASE: usize = 0x4000;

// ------------------------------------------------------ poltergeist marking

/// `ghostty_action_poltergeist_role_e`.
const ROLE_SUPERVISOR: u8 = 1;
const ROLE_WATCHED: u8 = 2;

/// `GHOSTTY_ACTION_POLTERGEIST_MARK` arrived. **Safe from any thread.**
///
/// **This deliberately stores nothing.** The mark lives in exactly one place,
/// `tabs.rs`, against the surface it was sent for, and this menu reads it back
/// out of `tabs::mark_for_surface` every time it is built. An earlier draft of
/// this file kept its own copy of `(role, shielded)`; that copy would have
/// been a second place for one fact to be right, which is the shape that has
/// gone wrong repeatedly here -- the menu's target, the close batch, the
/// mark's landing tab -- every time by two stores drifting apart with nothing
/// to report it.
///
/// So all this does is say the notification happened, which is worth a line:
/// a mark that never reaches the host and a mark that reaches it and changes
/// nothing are different bugs.
pub fn on_poltergeist_mark(role: i32, shielded: bool) {
    logf!("[ctx] poltergeist mark notified: role={} shielded={}", role, shielded);
}

static PG_NEVER_TOLD_LOGGED: AtomicBool = AtomicBool::new(false);

/// The three agent bits for the surface this menu belongs to, or `None` when
/// there is no answer for it.
///
/// `None` is a **third state**, not a synonym for "all off": it means this
/// surface is not in any tab the host knows about, or no mark has ever
/// arrived. Both draw unticked, and an unticked row is indistinguishable on
/// screen from one whose state was never learned -- which is exactly the
/// confusion §3.3 says these ticks exist to prevent. So the difference is
/// stated in the log instead of left to be guessed at.
fn mark_of(surface: Surface) -> Option<(u8, bool)> {
    if surface.is_null() {
        return None;
    }
    crate::tabs::mark_for_surface(surface)
}

/// Run a core action **on one named surface**.
///
/// The `tabs::binding_on_tab` of panes. `crate::binding` exists for the
/// keyboard, where "the focused surface" is the right answer by definition;
/// a menu opened with the right button has a different right answer, and the
/// two are different operations that happen to share a name.
fn binding_on(surface: Surface, name: &str) -> bool {
    if surface.is_null() {
        // **Not a fall back to the focused surface.** Silently retargeting is
        // the bug this function exists to remove, and it would come back
        // wearing a `null` check. A menu on a window with no surface should
        // do nothing and say so.
        logf!("[ctx] no surface for this window; {:?} not sent", name);
        return false;
    }
    unsafe { (crate::api().surface_binding_action)(surface, name.as_ptr(), name.len()) }
}

/// Whether a tick is on, for **this** surface.
///
/// Every one of the four reads is scoped to the surface the menu was opened
/// on. Nothing here asks what is focused, and that is the whole point: with a
/// split open, the pane under the pointer and the pane with focus are two
/// different terminals that look the same on screen, so a tick sourced from
/// "current" is wrong in exactly the cases nobody sets up to test.
///
/// This is the third member of one family, all now reading the same
/// `surface` variable: **which surface the action runs on** (fixed earlier),
/// **which surface the mark belongs to** (`tabs::mark_for_surface`), and
/// **which surface the state is about** (`hud::is_readonly_for`).
/// `hud::is_readonly()` exists and resolves the focused surface -- its own
/// doc comment says a menu must not use it.
fn tick_state(surface: Surface, mark: Option<(u8, bool)>, t: Tick) -> bool {
    match t {
        Tick::Readonly => crate::hud::is_readonly_for(surface as usize),
        // **Three bits, read three times.** Sharing one getter between the
        // three is the most natural way to write this and would tick all
        // three together, which no test that only looks at one row can see.
        Tick::PgSupervisor => matches!(mark, Some((r, _)) if r == ROLE_SUPERVISOR),
        Tick::PgWatched => matches!(mark, Some((r, _)) if r == ROLE_WATCHED),
        Tick::PgShielded => matches!(mark, Some((_, s)) if s),
    }
}

// ------------------------------------------------------------------- build

/// One rendered row, ready to hand to `AppendMenuW`.
#[derive(Debug, PartialEq, Eq)]
pub struct Item {
    /// Index into `ROWS`; the menu id is `ID_BASE + index`.
    pub index: usize,
    /// The full label including the `\t` and the shortcut, when there is one.
    pub text: String,
    pub separator: bool,
    pub checked: bool,
}

/// Render the whole menu.
///
/// **The two lookups are arguments so that this is testable without a core.**
/// The thing worth testing is not that a shortcut appears, it is that the
/// shortcut *follows the config*: the bug being fixed here is a label that
/// stays the same when the binding changes, and the only way to see that is
/// to build the same menu twice against two different binding tables.
fn build(
    shortcut: &dyn Fn(&str) -> Option<String>,
    tick: &dyn Fn(Tick) -> bool,
) -> Vec<Item> {
    ROWS.iter()
        .enumerate()
        .map(|(index, row)| {
            let Some(action) = row.action else {
                return Item {
                    index,
                    text: String::new(),
                    separator: true,
                    checked: false,
                };
            };
            // The tab and everything after it is the shortcut half. A row
            // with no binding gets no tab either -- a trailing tab renders as
            // a column of empty space next to every unbound item.
            let text = match shortcut(action) {
                Some(k) if !k.is_empty() => format!("{}\t{}", row.label, k),
                _ => row.label.to_string(),
            };
            Item {
                index,
                text,
                separator: false,
                checked: row.tick.map(&*tick).unwrap_or(false),
            }
        })
        .collect()
}

/// Show the menu at a screen position.
///
/// **Runs on the thread that owns the window**, because `TrackPopupMenu` runs
/// its own message loop and must not be entered from anywhere else. It is
/// called straight from `WM_CONTEXTMENU` in the surface window procedure, so
/// that is already true.
pub fn show(surface_hwnd: HWND, screen_x: i32, screen_y: i32) {
    // **The surface this menu is for**, not the focused one. They are the
    // same today because a right-click focuses the pane first, but the whole
    // §3.3 trap is a menu that acts on "current" instead of on what was
    // clicked, and this is the same question one window down.
    let surface = crate::tabs::surface_of(surface_hwnd);
    let mark = mark_of(surface);
    let items = build(&|a| crate::keys::shortcut_for(a), &|t| tick_state(surface, mark, t));

    unsafe {
        let menu = match CreatePopupMenu() {
            Ok(m) => m,
            Err(e) => {
                logf!("[ctx] CreatePopupMenu failed: {e:?}");
                return;
            }
        };

        let mut with_shortcut = 0usize;
        let mut shown = 0usize;
        for it in &items {
            if it.separator {
                let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
                continue;
            }
            shown += 1;
            if it.text.contains('\t') {
                with_shortcut += 1;
            }
            let mut flags = MF_STRING;
            if it.checked {
                flags |= MF_CHECKED;
            }
            let wide: Vec<u16> = it.text.encode_utf16().chain(Some(0)).collect();
            let _ = AppendMenuW(menu, flags, ID_BASE + it.index, PCWSTR(wide.as_ptr()));
        }

        // **Self-sufficient**, in the shape `[palette]` uses: the counts are
        // the inputs, not just the conclusion. `shortcuts=0` on a build where
        // the user has bindings is the symptom of `ghostty_config_trigger`
        // not being reachable, and without this number that symptom is
        // invisible -- the menu looks fine, it is just silently back to
        // having no shortcut text at all.
        logf!(
            "[ctx] built {} items, {} with shortcuts, {} separators",
            shown,
            with_shortcut,
            items.len() - shown
        );
        if mark.is_none() && !PG_NEVER_TOLD_LOGGED.swap(true, Ordering::AcqRel) {
            logf!(
                "[ctx] no GHOSTTY_ACTION_POLTERGEIST_MARK has reached this host; \
                 the three agent rows are drawn unticked because their state is \
                 unknown, not because it is off"
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

        // **Straight at the surface this menu was opened on.**
        //
        // `crate::binding` would send it to `tabs::active_surface()`, and a
        // right-click does not move focus -- `tabs.rs` calls `focus_pane_at`
        // from `WM_LBUTTONDOWN` only. So with splits open, right-clicking an
        // unfocused pane and picking «Copy» copied the *other* pane's
        // selection. **Invisible without splits**, and with them it looks
        // exactly like the user having failed to select anything.
        //
        // This is the same trap as §3.3's menu target, one window further
        // down: the identity was already resolved at the top of this
        // function and then thrown away at the point of use.
        let ok = binding_on(surface, action);
        // **The action name and the surface are both in the log on purpose.**
        // The action name says which row went dead if the core ever renames
        // one. The surface pointer is the only external evidence that this
        // fix took: with a single pane the surface a menu acts on and the
        // focused surface are always the same value, so a build that still
        // went through `active_surface()` would look identical everywhere
        // except a split -- which is not a state a log reader can assume was
        // set up. It is printed from the variable the call actually used, not
        // from a copy taken earlier.
        logf!(
            "[ctx] pick {:?} on surface {:?} -> {:?} binding_action = {}",
            row.label,
            surface,
            action,
            ok
        );
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
    use super::*;

    fn no_shortcuts(_: &str) -> Option<String> {
        None
    }
    fn no_ticks(_: Tick) -> bool {
        false
    }

    /// The tick tests below probe the three poltergeist bits, which come from
    /// the `mark` argument and never touch the surface. A null one keeps them
    /// honest about that: if one of them ever started reading the surface,
    /// it would have to say so.
    const NO_SURFACE: Surface = std::ptr::null_mut();

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

    /// Every row macOS's `menu(for:)` offers is offered here too.
    ///
    /// Spelled as action names rather than labels because the labels are
    /// wording and the actions are the contract. **Copy and Paste aside, the
    /// four splits and the two title prompts were the ones missing**, which is
    /// what task 103 is.
    #[test]
    fn the_macos_menu_is_covered() {
        let have: Vec<&str> = ROWS.iter().filter_map(|r| r.action).collect();
        for a in [
            "copy_to_clipboard",
            "paste_from_clipboard",
            "new_split:right",
            "new_split:left",
            "new_split:down",
            "new_split:up",
            "reset",
            "inspector:toggle",
            "toggle_readonly",
            "prompt_tab_title",
            "prompt_surface_title",
            "poltergeist_supervisor",
            "poltergeist_toggle_watch",
            "poltergeist_toggle_shielded",
        ] {
            assert!(have.contains(&a), "the macOS menu has {a} and this one does not");
        }
    }

    // ------------------------------------------------- shortcuts follow config

    /// **The point of task 103's second item.** The same menu, built against
    /// two different binding tables, must produce two different labels.
    ///
    /// The hand-written constants this replaces would pass any test that only
    /// looked at one config: `"Copy\tCtrl+Shift+C"` is a correct label right
    /// up until the user rebinds copy, and then it is a wrong one that
    /// nothing reports. So the assertion is not "the label says Ctrl+Shift+C",
    /// it is "the label changed when the binding did".
    #[test]
    fn the_shortcut_half_follows_the_binding_table() {
        let default_cfg = |a: &str| match a {
            "copy_to_clipboard" => Some("Ctrl+Shift+C".to_string()),
            _ => None,
        };
        let rebound_cfg = |a: &str| match a {
            "copy_to_clipboard" => Some("Alt+Y".to_string()),
            _ => None,
        };

        let label_of = |items: &[Item]| {
            items
                .iter()
                .find(|i| ROWS[i.index].action == Some("copy_to_clipboard"))
                .map(|i| i.text.clone())
                .expect("copy row exists")
        };

        let a = label_of(&build(&default_cfg, &no_ticks));
        let b = label_of(&build(&rebound_cfg, &no_ticks));

        assert_eq!(a, "复制\tCtrl+Shift+C");
        assert_eq!(b, "复制\tAlt+Y");
        assert_ne!(
            a, b,
            "the label must follow the config; a constant would make these equal"
        );
    }

    /// **The floor for the test above, from the other side.** A row whose
    /// action has no binding must carry no tab at all. Without this, an
    /// implementation that appended `"\t"` unconditionally -- or one that fell
    /// back to a built-in constant when the lookup came back empty -- would
    /// still pass the test above.
    #[test]
    fn an_unbound_row_carries_no_tab() {
        let items = build(&no_shortcuts, &no_ticks);
        for it in items.iter().filter(|i| !i.separator) {
            assert!(
                !it.text.contains('\t'),
                "no binding was offered, so {:?} must have no shortcut half",
                it.text
            );
            assert_eq!(it.text, ROWS[it.index].label);
        }
    }

    /// **The action string reaches the binding table whole**, `:value` and
    /// all. `ghostty_config_trigger` parses the entire string, so passing
    /// `new_split` where `new_split:right` was meant still returns *a*
    /// trigger -- a wrong one, silently. Truncation at the colon is therefore
    /// the failure that looks most like success.
    #[test]
    fn the_action_reaches_the_lookup_with_its_value_attached() {
        use std::cell::RefCell;
        let seen: RefCell<Vec<String>> = RefCell::new(Vec::new());
        let _ = build(
            &|a| {
                seen.borrow_mut().push(a.to_string());
                None
            },
            &no_ticks,
        );
        let seen = seen.into_inner();
        for a in ["new_split:right", "new_split:left", "new_split:down", "new_split:up", "close_tab:this", "inspector:toggle"] {
            assert!(seen.iter().any(|s| s == a), "{a} never reached the lookup");
        }
        assert!(
            !seen.iter().any(|s| s == "new_split"),
            "an action was truncated at the colon before the lookup"
        );
    }

    /// **The four splits must not collapse to one shortcut.** If the value
    /// were dropped on the way to the binding table, all four would come back
    /// with the same trigger and the menu would show one key four times --
    /// which reads as a config mistake, not as a host bug.
    #[test]
    fn four_splits_with_four_bindings_render_four_labels() {
        let cfg = |a: &str| match a {
            "new_split:right" => Some("Ctrl+Shift+D".to_string()),
            "new_split:left" => Some("Ctrl+Shift+A".to_string()),
            "new_split:down" => Some("Ctrl+Shift+E".to_string()),
            "new_split:up" => Some("Ctrl+Shift+W".to_string()),
            _ => None,
        };
        let items = build(&cfg, &no_ticks);
        let mut labels: Vec<&str> = items
            .iter()
            .filter(|i| {
                ROWS[i.index]
                    .action
                    .is_some_and(|a| a.starts_with("new_split:"))
            })
            .map(|i| i.text.as_str())
            .collect();
        assert_eq!(labels.len(), 4);
        labels.sort_unstable();
        labels.dedup();
        assert_eq!(labels.len(), 4, "the four splits share a label");
    }

    /// **No binding is not the same as not available** (`s4.md` §3.4.3 is the
    /// stronger form of this). With an empty binding table every row must
    /// still be present and still be a real, pickable command.
    #[test]
    fn an_empty_binding_table_removes_no_rows() {
        let full = build(&|_| Some("Ctrl+X".to_string()), &no_ticks);
        let empty = build(&no_shortcuts, &no_ticks);
        assert_eq!(full.len(), empty.len());
        assert_eq!(full.len(), ROWS.len());
        for (a, b) in full.iter().zip(empty.iter()) {
            assert_eq!(a.index, b.index);
            assert_eq!(a.separator, b.separator);
            // Same action behind both, so the row is as clickable as before.
            assert_eq!(ROWS[a.index].action, ROWS[b.index].action);
        }
    }

    /// A label must never carry a key of its own. This is the regression
    /// guard: the file used to hold `"Copy\tCtrl+Shift+C"` as a literal, and
    /// the way that comes back is somebody adding one new row in the old
    /// style, which no other test would notice.
    #[test]
    fn no_row_has_a_hand_written_shortcut() {
        for r in ROWS {
            assert!(
                !r.label.contains('\t'),
                "the shortcut comes from the core, not from the label: {:?}",
                r.label
            );
        }
    }

    /// A window with no surface sends nothing, and **does not fall back to
    /// the focused surface**.
    ///
    /// The fallback is the tempting fix for the null case and it is the
    /// original bug wearing a null check: it would make «Copy» on a
    /// surface-less window copy from whichever pane happened to have focus.
    /// The only safe answer is to do nothing, loudly.
    #[test]
    fn a_null_surface_sends_no_action() {
        assert!(!binding_on(std::ptr::null_mut(), "copy_to_clipboard"));
    }

    // ------------------------------------------------------------- ticks

    /// Each checkable row reads its **own** state bit.
    ///
    /// Tested one bit at a time rather than all-on/all-off: three rows that
    /// all read the same getter would pass an all-on test and an all-off test
    /// alike, and copying a getter and forgetting to change it is the most
    /// natural way to write this wrong.
    #[test]
    fn each_checkable_row_reads_its_own_bit() {
        for probe in [Tick::Readonly, Tick::PgSupervisor, Tick::PgWatched, Tick::PgShielded] {
            let items = build(&no_shortcuts, &|t| t == probe);
            let ticked: Vec<&str> = items
                .iter()
                .filter(|i| i.checked)
                .map(|i| ROWS[i.index].label)
                .collect();
            assert_eq!(
                ticked.len(),
                1,
                "exactly one row ticks for {probe:?}, got {ticked:?}"
            );
            assert_eq!(ROWS[items.iter().find(|i| i.checked).unwrap().index].tick, Some(probe));
        }
    }

    /// Nothing ticks when nothing is on -- the other half of the pair above.
    #[test]
    fn nothing_ticks_when_no_state_is_set() {
        let items = build(&no_shortcuts, &no_ticks);
        assert!(items.iter().all(|i| !i.checked));
    }

    /// A plain row can never tick, whatever the state says. The probe is a
    /// tick function that returns true for everything: only rows that carry a
    /// `Tick` may come back checked.
    #[test]
    fn rows_without_a_tick_never_check() {
        let items = build(&no_shortcuts, &|_| true);
        for it in items.iter().filter(|i| !i.separator) {
            assert_eq!(
                it.checked,
                ROWS[it.index].tick.is_some(),
                "{:?} checked without a state to check from",
                ROWS[it.index].label
            );
        }
    }

    /// `supervisor` and `watched` are two values of one enum, so they can
    /// never both be on. The mapping from role to row is where that gets
    /// dropped -- e.g. by testing `!= none` for both.
    #[test]
    fn supervisor_and_watched_are_mutually_exclusive() {
        assert!(tick_state(NO_SURFACE, Some((ROLE_SUPERVISOR, false)), Tick::PgSupervisor));
        assert!(!tick_state(NO_SURFACE, Some((ROLE_SUPERVISOR, false)), Tick::PgWatched));

        assert!(!tick_state(NO_SURFACE, Some((ROLE_WATCHED, false)), Tick::PgSupervisor));
        assert!(tick_state(NO_SURFACE, Some((ROLE_WATCHED, false)), Tick::PgWatched));
    }

    /// The shield is independent of the role: a shielded terminal that is
    /// neither supervisor nor watched must tick exactly one row.
    #[test]
    fn the_shield_is_its_own_bit() {
        assert!(tick_state(NO_SURFACE, Some((0, true)), Tick::PgShielded));
        assert!(!tick_state(NO_SURFACE, Some((0, true)), Tick::PgSupervisor));
        assert!(!tick_state(NO_SURFACE, Some((0, true)), Tick::PgWatched));
        assert!(!tick_state(NO_SURFACE, Some((ROLE_WATCHED, false)), Tick::PgShielded));
    }

    /// **Never told is not "all off".** Both draw unticked; only the log line
    /// in `show` separates them, which is why `None` has to reach the tick
    /// function rather than being flattened to `(0, false)` on the way in.
    #[test]
    fn an_unknown_mark_ticks_nothing_and_is_not_role_none() {
        for t in [Tick::PgSupervisor, Tick::PgWatched, Tick::PgShielded] {
            assert!(!tick_state(NO_SURFACE, None, t), "{t:?} ticked with no mark at all");
        }
        // The distinction this test exists to protect: the two cases are
        // different values, so a caller can tell them apart.
        let none_mark: Option<(u8, bool)> = None;
        let role_none: Option<(u8, bool)> = Some((0, false));
        assert_ne!(none_mark, role_none);
    }
}
