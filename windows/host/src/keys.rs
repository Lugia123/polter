//! Windows key events -> `ghostty_surface_key`.
//!
//! **There is no mapping table here, and that is the point.**
//!
//! `ghostty_input_key_s.keycode` is not one of the `GHOSTTY_KEY_*` values --
//! the core looks it up in `src/input/keycodes.zig`, matching against that
//! table's *native* column, which on a Windows build is column 3. Those values
//! are IBM PC scan codes (set 1) with `0xE0` for the extended keys: `KeyC` is
//! `0x2E`, `Escape` is `0x01`, `ArrowLeft` is `0xE04B`.
//!
//! Windows already hands us exactly that, in `WM_KEYDOWN`'s lParam: bits 16-23
//! are the scan code and bit 24 is the extended flag. So the whole conversion
//! is six lines, and the 673-line table the core already carries does the rest.
//!
//! Writing a VK-to-key table instead would have been a second table to keep in
//! agreement with that one, and the disagreements would have been silent --
//! one key that does nothing, on one layout.

use windows::Win32::Foundation::LPARAM;
use windows::Win32::UI::Input::KeyboardAndMouse::*;

// ghostty_input_mods_e
pub const MODS_NONE: i32 = 0;
pub const MODS_SHIFT: i32 = 1 << 0;
pub const MODS_CTRL: i32 = 1 << 1;
pub const MODS_ALT: i32 = 1 << 2;
pub const MODS_SUPER: i32 = 1 << 3;
pub const MODS_CAPS: i32 = 1 << 4;
pub const MODS_NUM: i32 = 1 << 5;
pub const MODS_SHIFT_RIGHT: i32 = 1 << 6;
pub const MODS_CTRL_RIGHT: i32 = 1 << 7;
pub const MODS_ALT_RIGHT: i32 = 1 << 8;
pub const MODS_SUPER_RIGHT: i32 = 1 << 9;

// ghostty_input_action_e
pub const ACTION_RELEASE: u32 = 0;
pub const ACTION_PRESS: u32 = 1;
pub const ACTION_REPEAT: u32 = 2;

/// The value the core's keycode table is keyed by.
pub fn keycode(lp: LPARAM) -> u32 {
    let sc = ((lp.0 >> 16) & 0xFF) as u32;
    let extended = (lp.0 >> 24) & 1 != 0;
    if extended { 0xE000 | sc } else { sc }
}

/// Bit 30 of lParam is set when the key was already down, which is a repeat.
pub fn is_repeat(lp: LPARAM) -> bool {
    (lp.0 >> 30) & 1 != 0
}

fn down(vk: VIRTUAL_KEY) -> bool {
    (unsafe { GetKeyState(vk.0 as i32) } as u16 & 0x8000) != 0
}
fn toggled(vk: VIRTUAL_KEY) -> bool {
    (unsafe { GetKeyState(vk.0 as i32) } as u16 & 0x0001) != 0
}

/// Which modifiers are held, including which side.
///
/// The base bit says the modifier is down at all; the `_RIGHT` bit says the
/// right-hand one is. Both are set when only the right key is held, which is
/// what the core expects -- the sided bit refines the plain one, it does not
/// replace it.
pub fn mods() -> i32 {
    let mut m = MODS_NONE;
    let (ls, rs) = (down(VK_LSHIFT), down(VK_RSHIFT));
    let (lc, rc) = (down(VK_LCONTROL), down(VK_RCONTROL));
    let (la, ra) = (down(VK_LMENU), down(VK_RMENU));
    let (lw, rw) = (down(VK_LWIN), down(VK_RWIN));
    if ls || rs { m |= MODS_SHIFT; }
    if rs { m |= MODS_SHIFT_RIGHT; }
    if lc || rc { m |= MODS_CTRL; }
    if rc { m |= MODS_CTRL_RIGHT; }
    if la || ra { m |= MODS_ALT; }
    if ra { m |= MODS_ALT_RIGHT; }
    if lw || rw { m |= MODS_SUPER; }
    if rw { m |= MODS_SUPER_RIGHT; }
    if toggled(VK_CAPITAL) { m |= MODS_CAPS; }
    if toggled(VK_NUMLOCK) { m |= MODS_NUM; }
    m
}

/// What the key would type with nothing held down.
///
/// Used for matching keybinds written against characters rather than physical
/// keys. `MapVirtualKeyW` answers for the current layout without disturbing
/// dead-key state, which `ToUnicode` would.
pub fn unshifted_codepoint(vk: u32) -> u32 {
    let c = unsafe { MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR) };
    // The top bit marks a dead key; the character is still in the low bits,
    // but it is not something typed on its own.
    let c = c & 0x7FFF_FFFF;
    match char::from_u32(c) {
        // Layouts report letters uppercase. Unshifted means lower.
        Some(ch) if ch.is_ascii_uppercase() => (ch as u32) + 32,
        Some(_) => c,
        None => 0,
    }
}

// --------------------------------------------------------------- dispatch

/// How many key messages have reached `handle_key_message`. **A key that never
/// increments this never got past the message pump** -- which is where TSF is
/// offered the keystroke first.
static KEYS_LOGGED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

use crate::ffi::{self, Surface};
use crate::{api, hlogf, logf, plogf};
use windows::Win32::Foundation::{HWND, LRESULT, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::*;

/// Host-level accelerators, tried **only for what the core did not take**.
///
/// **The premise this table was written on is false, and that is why it is
/// now five rows instead of sixteen.** It said the core's Windows defaults
/// were not yet exercised, so the host had to cover them. The core does have
/// Windows defaults, and had them all along: eleven of the sixteen rows named
/// a chord the core already binds, so they never ran.
///
/// **Dead was not the dangerous half.** A row the core covers is not
/// unreachable -- it is reached whenever the core *declines*, and
/// `performable` bindings decline as a matter of course. `copy_to_clipboard`
/// is bound to `ctrl+shift+c` with `performable = true`, and
/// `Config.zig:1996` says what that means: "If there is no selection, Ghostty
/// behaves as if the keybind was not set." So every `ctrl+shift+c` with no
/// selection fell through to this table, which sent
/// `copy_title_to_clipboard`: the window title, onto the clipboard, silently.
/// The person had selected text, copied, pasted the title, and had every
/// reason to doubt their own selection. That row is gone.
///
/// **The rule, and it does not care whether the actions agree.** A row whose
/// chord the core also binds is deleted, even when both name the same action.
/// "The same action" is today's coincidence: the core changes one default and
/// a harmless dead row becomes a `ctrl+shift+c`, with nothing anywhere
/// reporting the change. Four rows were already in the second state --
/// `ctrl+shift+←/→` sent `move_tab` where the core sends `previous_tab` /
/// `next_tab`, and those two are `performable`, so with a single tab open the
/// core declined and the host moved a tab instead of switching one.
///
/// What is left is the chords the core does not bind on Windows, where this
/// table is the only way to reach the action at all. Each of them logs when it
/// fires -- they are supposed to fire, so the line is a signal rather than
/// noise, and when the core grows a default the line will stop appearing,
/// which is the reading that says a row can retire.
/// The modifiers that must **not** be held for a host accelerator to fire,
/// named rather than counted.
///
/// **The table below is matched on `Ctrl` and `Shift` alone, so without this
/// every row also answered to any number of extra modifiers**:
/// `Ctrl+Shift+Alt+M` maximised the window, and so did `Ctrl+Shift+Win+M`.
/// Those are chords other software and input methods own -- pressing one and
/// having a window maximise is the kind of thing nobody traces back to a
/// terminal.
///
/// **It returns the name, not a bool, because the rejection has to be
/// legible.** A tightened condition that merely does nothing turns "this key
/// does not work" into silence, and silence is indistinguishable from the key
/// never having arrived -- which is a live, unresolved problem in this host
/// (see `docs/windows/keys.md` §2.3). So the caller logs *which* modifier
/// stopped it.
fn blocking_mods(alt: bool, win: bool) -> Option<&'static str> {
    match (alt, win) {
        (true, true) => Some("Alt and Win"),
        (true, false) => Some("Alt"),
        (false, true) => Some("Win"),
        (false, false) => None,
    }
}

fn accelerator(vk: VIRTUAL_KEY, ctrl: bool, shift: bool) -> Option<&'static str> {
    match (ctrl, shift, vk) {
        // **`ctrl+shift+,` was here, and the argument for keeping it was
        // right about the action and wrong about the chord.** The plugin page
        // does have no core action -- the core knows nothing about a settings
        // window -- so this row could never be superseded *by an action*. But
        // the chord was already taken: `Config.zig:6733` binds
        // `ctrlOrSuper(.{ .shift = true })` with `','`, which on Windows is
        // `ctrl+shift+,`, to `reload_config`. That binding is not
        // `performable`, so the core consumes the key every time and this row
        // has never once run. Pressing it reloads the config; the settings
        // page does not open, and did not before this deletion either.
        //
        // **So the settings page currently has no keyboard route at all.**
        // That is a gap to fill with a chord the core does not bind, not a
        // reason to keep a row that cannot fire.
        (true, true, VK_M) => Some("toggle_maximize"),
        // The core's split-right default is `ctrl+shift+o`, not `d`.
        (true, true, VK_D) => Some("new_split:right"),
        (true, true, VK_Z) => Some("toggle_split_zoom"),
        // The core binds `equalize_splits` to `super+ctrl+=`, which is the
        // macOS branch; there is no Windows default.
        (true, true, VK_OEM_PLUS) => Some("equalize_splits"),

        // **`ctrl+tab` was here, and it should not have been.** The first
        // pass called it "not verified" and asked for a keypress on a real
        // machine to settle whether the key is encoded into the pty. It never
        // needed one: `Config.zig:6896` binds `.{ .physical = .tab }` with
        // `.ctrl` to `next_tab`, on every platform, which is the same action
        // this row named. The reason it looked open is that the pass which
        // enumerated the core's defaults missed that line -- so the question
        // "does this key reach the table" was asked of a machine when the
        // answer was in the source, and the row would have survived on the
        // strength of an incomplete search rather than a fact.

        _ => None,
    }
}

/// `WM_KEYDOWN` / `WM_SYSKEYDOWN` / `WM_KEYUP` / `WM_SYSKEYUP` on a surface
/// window.
///
/// Order is load-bearing and none of it fails loudly:
///
///  1. TSF already had this message (the pump offers `ITfKeystrokeMgr` first
///     and never dispatches what it eats), so anything arriving here is a key
///     the IME did not want.
///  2. The core gets the key. `TranslateMessage` has already run, so the
///     character this key produces is sitting in the queue; we look without
///     removing, hand it over as the event's text, and take it out only if
///     the core says it used the event -- otherwise the `WM_CHAR` fallback
///     would type it a second time.
///  3. Only then the host accelerators above.
///  4. Whatever nobody wanted goes back to `DefWindowProcW` if it is a
///     `WM_SYSKEY*`. Swallowing those takes Alt+F4 and the system menu with
///     them, and then the only way out of the window is the task manager.
pub fn handle_key_message(
    hwnd: HWND,
    msg: u32,
    wp: WPARAM,
    lp: LPARAM,
    surface: Surface,
) -> LRESULT {
    unsafe {
        let is_down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;

        let mut pending = MSG::default();
        let mut text_buf = [0u8; 8];
        let mut text_ptr: *const std::os::raw::c_char = std::ptr::null();
        let mut have_pending = false;
        if is_down
            && PeekMessageW(&mut pending, Some(hwnd), WM_CHAR, WM_CHAR, PM_NOREMOVE).as_bool()
        {
            have_pending = true;
            let c = pending.wParam.0 as u16;
            // Control characters are the key's business, not text.
            if c >= 0x20 {
                if let Some(ch) = char::from_u32(c as u32) {
                    let n = ch.encode_utf8(&mut text_buf).len();
                    text_buf[n] = 0;
                    text_ptr = text_buf.as_ptr() as *const _;
                }
            }
        }

        let ev = ffi::KeyEvent {
            action: if !is_down {
                ACTION_RELEASE
            } else if is_repeat(lp) {
                ACTION_REPEAT
            } else {
                ACTION_PRESS
            },
            mods: mods(),
            consumed_mods: 0,
            keycode: keycode(lp),
            text: text_ptr,
            unshifted_codepoint: unshifted_codepoint(wp.0 as u32),
            // **This is hard-coded, and the core therefore never learns that
            // the host is composing.** `tsf.rs` knows -- `Ime::composing` is
            // set and cleared by `OnStartComposition` / `OnEndComposition` --
            // and that answer is simply not passed on here.
            //
            // **Read this before leaving it as it is.** It is harmless today
            // only because nothing in the core reads the field, and that is a
            // fact about somebody else's code on some other day. The moment
            // the core decides anything by it -- "while composing, do not
            // treat a key as a binding" is the obvious one -- a constant
            // `false` sends that decision down the wrong branch **every single
            // time**, and nothing raises so much as a warning: the key is
            // handled, just as though no input method were running. The
            // symptom would be an IME user losing composition to a keybind,
            // which reads as a keybind bug rather than as this line.
            composing: false,
        };
        let vk = wp.0 as u16;
        // Read out what the log needs before the event is handed over: the
        // C struct is passed by value and moves.
        let (ev_keycode, ev_mods) = (ev.keycode, ev.mods);
        crate::trace_intercept("before surface_key");
        let consumed_by_core = (api().surface_key)(surface, ev);
        crate::trace_intercept("after surface_key");
        let mut consumed = consumed_by_core;

        // **Log every key with a modifier, and the first few of everything.**
        //
        // Typing working proves nothing about this path: a printable key that
        // `surface_key` declines still reaches the terminal through the
        // `WM_CHAR` fallback, and IME output arrives via `surface_text`
        // entirely separately. So "letters appear on screen" is consistent
        // with `surface_key` never having worked at all. A control key has no
        // such second path -- Ctrl-C either goes through here or does not
        // happen -- which is exactly why this is the line that has to exist.
        let n = KEYS_LOGGED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
        let modded = ev_mods & (MODS_CTRL | MODS_ALT | MODS_SUPER) != 0;
        if n <= 20 || modded {
            logf!(
                "[key] msg=0x{:x} vk=0x{:02x} keycode=0x{:x} mods=0x{:x} text={} -> surface_key={}",
                msg,
                vk,
                ev_keycode,
                ev_mods,
                if text_ptr.is_null() { "none" } else { "yes" },
                consumed_by_core
            );
        }

        if !consumed && is_down {
            let ctrl = down(VK_CONTROL);
            let shift = down(VK_SHIFT);
            // **Checked here rather than inside the table**, so the table
            // stays a plain list of chords and the policy has one home --
            // next to the log line that has to explain it.
            let extra = blocking_mods(
                down(VK_MENU),
                down(VK_LWIN) || down(VK_RWIN),
            );
            // **Refused, and refused *without consuming the key*.**
            //
            // An early return here would be a second defect wearing the
            // first one's clothes: `Alt` makes this a `WM_SYSKEYDOWN`, and
            // the tail of this function hands those to `DefWindowProcW` on
            // purpose -- swallowing them takes `Alt+F4` and the system menu
            // with them. So this arm only writes a line; `consumed` stays
            // false and the message goes on to its normal ending.
            match (accelerator(VIRTUAL_KEY(vk), ctrl, shift), extra) {
                (Some(name), Some(held)) => {
                    // **Said out loud, not silently dropped.** Somebody
                    // pressing this combination and getting nothing needs to
                    // be able to tell "the host refused it" from "the key
                    // never arrived"; those two look the same from a chair,
                    // and this host has an open question about exactly that
                    // (`docs/windows/keys.md` §2.3).
                    // `hlogf!`, not `logf!`: this is about one window, and
                    // the handle is a surface, so it is walked up to its frame
                    // (or the line says it is about no window at all).
                    hlogf!(
                        hwnd,
                        "[key] host accelerator {:?} NOT fired: {} also held \
                         (this table matches Ctrl+Shift exactly)",
                        name,
                        held
                    );
                }
                (Some(name), None) => {
                // Two kinds of entry live in that table. Most are core action
                // names and go to `ghostty_surface_binding_action`. A `__polter_`
                // one names something the core has never heard of -- sending it
                // there would just return false, and the accelerator would look
                // like it did not fire.
                let ok = match name {
                    "__polter_plugin_page" => {
                        crate::settings_ui::request_toggle();
                        true
                    }
                    _ => crate::binding(name),
                };
                // **Logged because these are supposed to fire.** Every row
                // left in that table names a chord the core does not bind on
                // Windows, so this line appearing is the table doing its job.
                // The day the core grows a default for one of them, the core
                // consumes the key first and this line stops appearing for it
                // -- which is how a row earns its retirement, rather than
                // being noticed by someone reading the source years later.
                logf!(
                    "[key] host accelerator {:?} -> binding_action = {} (the core has no Windows bind for this chord)",
                    name,
                    ok
                );
                consumed = ok;
                }
                (None, _) => {}
            }
        }

        // Taken by somebody: drop the character so the WM_CHAR fallback does
        // not type it as well.
        if consumed && have_pending {
            let _ = PeekMessageW(&mut pending, Some(hwnd), WM_CHAR, WM_CHAR, PM_REMOVE);
        }

        if !consumed && (msg == WM_SYSKEYDOWN || msg == WM_SYSKEYUP) {
            // Default processing for a *system* key belongs to the top-level
            // window: Alt+F4 becomes WM_SYSCOMMAND/SC_CLOSE, and a surface is
            // a child window, so handing it to the child would ask the wrong
            // window to close. GA_ROOT is the frame.
            let root = GetAncestor(hwnd, GA_ROOT);
            let target = if root.0.is_null() { hwnd } else { root };
            return DefWindowProcW(target, msg, wp, lp);
        }
        LRESULT(0)
    }
}

// ------------------------------------------------- shortcuts, from the core

// **What a menu shows after the tab must come from the core.**
//
// `docs/windows/s4.md` §3.4 point 1: a hand-written `"Ctrl+Shift+C"` in a menu
// label is wrong the moment a user rebinds the action, **and nothing reports
// it**. There is no assertion that can fire, no action that fails, no log line
// that goes red -- the menu simply tells the user to press a key that does
// something else now. So the shortcut half of every label is asked of the
// same table the keyboard itself is driven by.
//
// The core answers through `ghostty_config_trigger(config, action, len)`,
// which is the identical call the macOS menus make
// (`Ghostty.Config.keyboardShortcut(for:)`). Unbound actions come back as the
// default trigger -- `physical`/`unidentified`, mods zero -- which is the
// probe for "this action has no key", **not** an error.

use std::sync::atomic::AtomicUsize;

/// `ghostty_input_trigger_s { int tag; union { int; u32 } key; int mods; }`.
///
/// Twelve bytes, so on the Win64 ABI it comes back through a hidden pointer;
/// declaring it `repr(C)` and returning it by value is what makes Rust apply
/// the same rule the C compiler did.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
pub struct TriggerC {
    pub tag: i32,
    pub key: u32,
    pub mods: i32,
}

/// `ghostty_input_trigger_tag_e`.
pub const TRIGGER_PHYSICAL: i32 = 0;
pub const TRIGGER_UNICODE: i32 = 1;
pub const TRIGGER_CATCH_ALL: i32 = 2;

/// `GHOSTTY_KEY_UNIDENTIFIED` is ordinal 0 and is what an unbound action's
/// trigger carries, because `Trigger{}`'s default key is `.unidentified`.
const KEY_UNIDENTIFIED: u32 = 0;

type ConfigTriggerFn = unsafe extern "C" fn(crate::ffi::Config, *const u8, usize) -> TriggerC;

/// Resolved once. `0` means "looked and it was not there", which is different
/// from "not looked yet" and is why this is not an `Option` re-resolved on
/// every call: a missing export would otherwise be logged once per menu item.
static CONFIG_TRIGGER: AtomicUsize = AtomicUsize::new(usize::MAX);

fn config_trigger_fn() -> Option<ConfigTriggerFn> {
    use std::sync::atomic::Ordering;
    use windows::core::s;
    use windows::Win32::System::LibraryLoader::{GetModuleHandleA, GetProcAddress};

    let cached = CONFIG_TRIGGER.load(Ordering::Acquire);
    if cached != usize::MAX {
        return if cached == 0 {
            None
        } else {
            Some(unsafe { std::mem::transmute::<usize, ConfigTriggerFn>(cached) })
        };
    }

    // Resolved by name rather than added to `ffi::Api`, because the whole of
    // this lookup is one call used by menus; `Api` is the set of entry points
    // the terminal cannot run without, and a missing `config_trigger` costs a
    // menu its shortcut text, not the terminal its startup.
    let addr = unsafe {
        GetModuleHandleA(s!("ghostty-internal.dll"))
            .ok()
            .and_then(|m| GetProcAddress(m, s!("ghostty_config_trigger")))
            .map(|p| p as usize)
            .unwrap_or(0)
    };
    CONFIG_TRIGGER.store(addr, Ordering::Release);
    if addr == 0 {
        logf!("[keys] ghostty_config_trigger not exported; menus will show no shortcuts");
        return None;
    }
    Some(unsafe { std::mem::transmute::<usize, ConfigTriggerFn>(addr) })
}

/// Render a trigger the way a menu shows it, or `None` when the action has no
/// key bound to it.
///
/// **Pure, and separated from the lookup on purpose**: it is the half that
/// can be tested without a core to ask, and it is the half where "the label
/// followed the config" is decided.
///
/// The naming comes from `keyseq.rs`, which already had to solve it for the
/// pending-key indicator. **Deliberately not a second implementation** -- two
/// renderings of the same trigger that disagree would disagree quietly, and
/// the disagreement would be between a menu and the indicator that appears
/// when you use it.
pub fn format_trigger(t: TriggerC) -> Option<String> {
    // `catch_all` has no key payload at all -- the core says reading it is an
    // error for a C consumer -- so there is nothing to draw.
    if t.tag == TRIGGER_CATCH_ALL {
        return None;
    }
    if t.tag == TRIGGER_PHYSICAL && t.key == KEY_UNIDENTIFIED {
        return None;
    }
    let s = format!(
        "{}{}",
        crate::keyseq::mods_label(t.mods),
        crate::keyseq::key_label(t.tag, t.key)
    );
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// The prefix on an action name the **host** performs, not the core.
///
/// `__polter_minimize`, `__polter_plugin_page` and their kind name things the
/// core has never heard of: a settings window, a Win32 `ShowWindow` call. They
/// travel through the same tables as core action names because the menus and
/// the accelerator table are one list each, and they are separated by this
/// prefix at the point where the core would otherwise be asked.
///
/// **Defined here and nowhere else.** `menu.rs` had its own copy, and its own
/// comment pointed at this file as the precedent -- two definitions of one
/// concept, which is the shape that has gone wrong repeatedly in this port.
/// The direction is the one the modules already run in: `menu.rs` calls into
/// `keys.rs` for its accelerators, so the constant lives at the end that is
/// already depended upon.
pub const HOST_ACTION_PREFIX: &str = "__polter_";

/// Whether an action name belongs to the host rather than to the core.
pub fn is_host_action(name: &str) -> bool {
    name.starts_with(HOST_ACTION_PREFIX)
}

/// Names already reported by `shortcut_for`, so a host action reaching it
/// produces one line rather than one per menu build.
static REPORTED: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// Why a lookup did not produce a usable trigger, or the trigger it did.
///
/// **Four outcomes, not one `None`.** They are four different faults with one
/// symptom -- "the hotkey is the built-in one" -- and collapsing them into a
/// single `Option` is what made the last one take three round trips on the
/// test machine to tell apart from the first. Each gets its own log line at
/// the call site.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lookup {
    /// `ghostty_config_trigger` is not exported by the core that loaded.
    NoLookup,
    /// The host has no config handle yet.
    NoConfig,
    /// The config was read and this action simply has no key bound to it.
    Unbound,
    Bound(TriggerC),
}

/// The raw trigger bound to a core action, with the reason when there is none.
pub fn trigger_lookup(action: &str) -> Lookup {
    let Some(f) = config_trigger_fn() else {
        return Lookup::NoLookup;
    };
    let cfg = crate::config_handle();
    if cfg.is_null() {
        return Lookup::NoConfig;
    }
    let t = unsafe { f(cfg, action.as_ptr(), action.len()) };
    // Same "no binding" probe as `format_trigger`, so the two cannot disagree
    // about whether an action is bound.
    if t.tag == TRIGGER_CATCH_ALL || (t.tag == TRIGGER_PHYSICAL && t.key == KEY_UNIDENTIFIED) {
        return Lookup::Unbound;
    }
    Lookup::Bound(t)
}

/// The key combination bound to a core action right now, e.g.
/// `shortcut_for("copy_to_clipboard")` -> `Some("Ctrl+Shift+C")`.
///
/// `None` means the action exists but has no binding, **or** that the config
/// could not be asked. Both render the same way -- a menu row with no
/// shortcut half -- which is correct: showing a key that is not bound is the
/// failure this function exists to prevent, and showing none is merely quiet.
///
/// # This does not cache, and must not start
///
/// **The trigger is asked of the core on every call, once per menu row, every
/// time a menu is built.** That looks wasteful and is the first thing a
/// reader will want to fix. It is deliberate:
///
///  - `reload_config` replaces the binding set. A cache would keep showing
///    the **previous** key, and the whole point of this function is that a
///    menu never shows a key that is not the current one. A stale cache is
///    the original hand-written-constant bug with extra steps.
///  - The case that catches it is deletion, not change: unbind
///    `copy_to_clipboard` entirely and the row must go **blank**. A cache
///    that only refreshes on lookup-miss keeps the old value forever,
///    because the old value is never a miss.
///  - There is nothing to invalidate against. The core does not hand the host
///    a generation number for the keybind set, so a correct cache would need
///    a signal that does not exist.
///
/// The cost is a `stringToEnum` and a hash lookup per row, on the click that
/// opens a menu. If that ever needs fixing, the fix is a cache **cleared on
/// `GHOSTTY_ACTION_CONFIG_CHANGE`**, not a cache with no invalidation.
///
/// (The *function pointer* is resolved once -- that one genuinely cannot
/// change while the process lives.)
pub fn shortcut_for(action: &str) -> Option<String> {
    // **A host action is never asked of the core**, and saying so by name is
    // the point of this branch.
    //
    // `ghostty_config_trigger` parses whatever it is handed; a name the core
    // does not have comes back as the default trigger, which is
    // indistinguishable from a real action that nobody has bound. So without
    // this the failure is a menu row with no shortcut and **no line anywhere
    // naming the action** -- which is exactly how the last round of these
    // took as long as it did to find.
    //
    // `menu.rs` gates these before they get here. This is the second door:
    // anything else that calls this function directly gets the same answer
    // and the same log line.
    //
    // **What this does not check** is whether a non-prefixed name is a real
    // core action. That question is answered by `menu.rs`'s `unresolved`
    // count, which parses `Binding.zig`; duplicating that parser here would
    // be a second definition of "is this a core action", which is the thing
    // this constant was just moved to avoid.
    if is_host_action(action) {
        if let Ok(mut seen) = REPORTED.lock() {
            if !seen.iter().any(|n| n == action) {
                seen.push(action.to_string());
                logf!(
                    "[keys] {:?} is a host action, not a core one; no keybind was looked up \
                     (this is expected for {}* names and is reported once each)",
                    action,
                    HOST_ACTION_PREFIX
                );
            }
        }
        return None;
    }

    let f = config_trigger_fn()?;
    let cfg = crate::config_handle();
    if cfg.is_null() {
        return None;
    }
    let t = unsafe { f(cfg, action.as_ptr(), action.len()) };
    format_trigger(t)
}

#[cfg(test)]
mod shortcut_tests {
    use super::*;

    /// The concept lives in one place. **`menu.rs` used to carry its own copy
    /// of this prefix**, with a comment pointing at this file as the
    /// precedent -- two definitions of one fact, which is how they drift.
    #[test]
    fn host_actions_are_recognised_by_their_prefix() {
        assert!(is_host_action("__polter_minimize"));
        assert!(is_host_action("__polter_plugin_page"));
        assert!(!is_host_action("new_tab"));
        assert!(!is_host_action("close_tab:this"));
        // A core action that merely starts with an underscore is not ours.
        assert!(!is_host_action("_sdk"));
    }

    /// **A host action must never reach the core's binding table.**
    ///
    /// Asking `ghostty_config_trigger` about a name the core does not have
    /// returns the default trigger, which reads exactly like a real action
    /// nobody has bound: a menu row with no shortcut and **no line anywhere
    /// naming the action**. This returns `None` before that can happen.
    ///
    /// The assertion is about the branch, not the lookup: with no core loaded
    /// in a test binary every lookup returns `None` anyway, so the value
    /// alone proves nothing. What is pinned here is that the host-action
    /// branch is reached first -- `is_host_action` is the same predicate the
    /// function uses.
    #[test]
    fn a_host_action_is_never_asked_of_the_core() {
        for a in ["__polter_minimize", "__polter_plugin_page", "__polter_about"] {
            assert!(is_host_action(a), "{a} must be gated");
            assert_eq!(shortcut_for(a), None);
        }
    }

    /// An action nobody bound draws no shortcut. This is the case that has to
    /// be right first: the default trigger is not a sentinel value chosen by
    /// this host, it is whatever `Trigger{}` happens to be, and reading it as
    /// a real key would print `Ctrl+key#0` next to half the menu.
    #[test]
    fn an_unbound_action_has_no_shortcut() {
        assert_eq!(format_trigger(TriggerC::default()), None);
        assert_eq!(
            format_trigger(TriggerC { tag: TRIGGER_PHYSICAL, key: 0, mods: 0 }),
            None
        );
    }

    /// `catch_all` carries no key; the union is undefined for a C reader.
    #[test]
    fn catch_all_has_no_shortcut_even_with_mods() {
        assert_eq!(
            format_trigger(TriggerC { tag: TRIGGER_CATCH_ALL, key: 0x1234, mods: 1 << 1 }),
            None
        );
    }

    /// ordinal 20 is `GHOSTTY_KEY_A`, ordinal 22 is `C`; mods bit 1 is ctrl,
    /// bit 0 is shift.
    #[test]
    fn a_bound_action_renders_mods_then_key() {
        let t = TriggerC { tag: TRIGGER_PHYSICAL, key: 22, mods: (1 << 1) | (1 << 0) };
        assert_eq!(format_trigger(t).as_deref(), Some("Ctrl+Shift+C"));
    }

    /// **The floor for the test above.** If `format_trigger` ignored its
    /// argument and returned a constant -- which is exactly what the
    /// hand-written labels this replaces did -- the previous test would still
    /// pass. Two different triggers must render differently.
    #[test]
    fn a_different_binding_renders_differently() {
        let a = TriggerC { tag: TRIGGER_PHYSICAL, key: 22, mods: (1 << 1) | (1 << 0) };
        let b = TriggerC { tag: TRIGGER_PHYSICAL, key: 44, mods: 1 << 2 };
        let (sa, sb) = (format_trigger(a), format_trigger(b));
        assert_eq!(sb.as_deref(), Some("Alt+Y"));
        assert_ne!(sa, sb, "two bindings must not render to the same label");
    }
}

#[cfg(test)]
mod accelerator_mod_tests {
    use super::blocking_mods;

    /// **The table matches `Ctrl+Shift` and nothing else**, so anything else
    /// held has to stop it. Before this, `Ctrl+Shift+Alt+M` maximised the
    /// window and so did `Ctrl+Shift+Win+M` -- chords that belong to other
    /// software and to input methods.
    #[test]
    fn an_extra_modifier_blocks_the_chord() {
        assert!(blocking_mods(true, false).is_some(), "Alt must block");
        assert!(blocking_mods(false, true).is_some(), "Win must block");
        assert!(blocking_mods(true, true).is_some(), "both must block");
    }

    /// **The floor for the test above.** A `blocking_mods` that returned
    /// `Some` unconditionally would pass it while stopping every accelerator
    /// in the table -- and the symptom of that is "the shortcut stopped
    /// working", reported by somebody who will not connect it to this change.
    #[test]
    fn the_plain_chord_is_not_blocked() {
        assert!(blocking_mods(false, false).is_none());
    }

    /// **It has to say *which* one.** The rejection is written into the log so
    /// that "the host refused this" can be told apart from "the key never
    /// arrived" -- and a line that says only "refused" leaves the reader with
    /// the same question they started with.
    #[test]
    fn it_names_the_modifier_that_stopped_it() {
        assert_eq!(blocking_mods(true, false), Some("Alt"));
        assert_eq!(blocking_mods(false, true), Some("Win"));
        assert_eq!(blocking_mods(true, true), Some("Alt and Win"));
        // Three different situations, three different strings: a reader who
        // sees one knows which key to let go of.
        let all = [
            blocking_mods(true, false),
            blocking_mods(false, true),
            blocking_mods(true, true),
        ];
        let mut seen = all.to_vec();
        seen.sort();
        seen.dedup();
        assert_eq!(seen.len(), 3, "each case must be distinguishable in the log");
    }
}

// ---------------------------------------- would the core have wanted this?

/// `ghostty_surface_key_is_binding`, resolved lazily.
///
/// **Not in `ffi::Api`, and that is the difference between a diagnostic and a
/// dependency.** `Api` is loaded with `sym!`, which aborts startup when a
/// symbol is missing -- correct for the entry points the terminal cannot run
/// without, wrong for this one. A `ghostty-internal.dll` older than this
/// question should still start; it just cannot answer it. Same shape, and the
/// same reason, as `config_trigger_fn` above.
static KEY_IS_BINDING: AtomicUsize = AtomicUsize::new(usize::MAX);

type KeyIsBindingFn =
    unsafe extern "C" fn(Surface, ffi::KeyEvent, *mut std::os::raw::c_int) -> bool;

/// `ghostty_binding_flags_e`: `include/ghostty.h` gives `PERFORMABLE = 1 << 3`.
const BINDING_FLAG_PERFORMABLE: std::os::raw::c_int = 1 << 3;

fn key_is_binding_fn() -> Option<KeyIsBindingFn> {
    use std::sync::atomic::Ordering;
    use windows::core::s;
    use windows::Win32::System::LibraryLoader::{GetModuleHandleA, GetProcAddress};

    let cached = KEY_IS_BINDING.load(Ordering::Acquire);
    if cached != usize::MAX {
        return if cached == 0 {
            None
        } else {
            Some(unsafe { std::mem::transmute::<usize, KeyIsBindingFn>(cached) })
        };
    }
    let addr = unsafe {
        GetModuleHandleA(s!("ghostty-internal.dll"))
            .ok()
            .and_then(|m| GetProcAddress(m, s!("ghostty_surface_key_is_binding")))
            .map(|p| p as usize)
            .unwrap_or(0)
    };
    KEY_IS_BINDING.store(addr, Ordering::Release);
    if addr == 0 {
        // process-wide: a symbol is present or absent in the loaded DLL, which
        // is a fact about this process and not about any one window
        plogf!(
            "[key] ghostty_surface_key_is_binding not exported; \
             cannot say whether an intercepted key was one of ours"
        );
        return None;
    }
    Some(unsafe { std::mem::transmute::<usize, KeyIsBindingFn>(addr) })
}

/// **Would this key have run one of our bindings, had it reached the core?**
///
/// # Why this exists, and why it only writes a line
///
/// While an input method is composing, TSF claims keys before the core is
/// ever offered them -- **including chords that are ours**. A real machine
/// showed `ctrl`, `shift` and `c` all taken with `composing=Some(true)`, so
/// `ctrl+shift+c` did nothing while a candidate window was open. Every
/// application shortcut is unavailable in that state.
///
/// The fix would be to keep such chords away from TSF. **This is not that
/// fix**: it asks the question and writes the answer down, because the number
/// that decides whether the fix is worth its risk -- *how many of the keys
/// taken during composition were ours* -- is not known, and guessing it is
/// what the risk is made of.
///
/// # The trap this call sits next to
///
/// `keyEventIsBinding` answers "would this trigger a binding", and its own
/// documentation says it **does not check `performable`**. So `ctrl+shift+c`
/// with no selection answers *yes* here, while the core would decline it if
/// actually sent. **An interception built on the bare boolean would take such
/// a key away from the input method, have the core refuse it, have the host
/// accelerator table refuse it too, and the key would simply vanish** -- worse
/// than today, where at least the IME uses it. That is why the flags are read
/// and reported separately: the number worth acting on is
/// `binding=yes performable=no`, not `binding=yes`.
/// What the core says about a key, in the three shapes that matter here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BindingAnswer {
    /// A binding, and its answer does not depend on terminal state.
    /// **The only kind that may be taken away from the input method.**
    Ours,
    /// A binding, but `performable`: the core will decline it when the
    /// conditions are not met. Taking it from the input method would mean
    /// nobody handles it at all.
    Performable,
    /// Not one of ours; the input method is welcome to it.
    NotOurs,
    /// The question could not be asked. **Its own answer, never folded into
    /// `NotOurs`** -- "we did not ask" and "we asked and it said no" lead to
    /// opposite conclusions about whether the numbers below are complete.
    Unknown(&'static str),
}

impl BindingAnswer {
    /// For the log line. One string per case, so a reader can tell all four
    /// apart without knowing the enum.
    pub fn label(self) -> &'static str {
        match self {
            BindingAnswer::Ours => "binding=yes performable=no",
            BindingAnswer::Performable => {
                "binding=yes performable=yes (intercepting this one would lose the key)"
            }
            BindingAnswer::NotOurs => "binding=no",
            BindingAnswer::Unknown(why) => why,
        }
    }

    /// **May this key be kept away from TSF?** Only the first case.
    pub fn may_intercept(self) -> bool {
        matches!(self, BindingAnswer::Ours)
    }
}

/// Ask the core what it would do with this key, without sending it.
pub fn ask_binding(msg: u32, wp: WPARAM, lp: LPARAM) -> BindingAnswer {
    if msg != WM_KEYDOWN && msg != WM_SYSKEYDOWN {
        return BindingAnswer::Unknown("n/a (not a keydown)");
    }
    let Some(f) = key_is_binding_fn() else {
        return BindingAnswer::Unknown("unknown (symbol missing)");
    };
    let surface = crate::tabs::active_surface(crate::tabs::overlay_frame());
    if surface.is_null() {
        return BindingAnswer::Unknown("unknown (no focused surface)");
    }
    let ev = ffi::KeyEvent {
        action: if is_repeat(lp) { ACTION_REPEAT } else { ACTION_PRESS },
        mods: mods(),
        consumed_mods: 0,
        keycode: keycode(lp),
        text: std::ptr::null(),
        unshifted_codepoint: unshifted_codepoint(wp.0 as u32),
        composing: false,
    };
    let mut flags: std::os::raw::c_int = 0;
    if !unsafe { f(surface, ev, &mut flags) } {
        return BindingAnswer::NotOurs;
    }
    if flags & BINDING_FLAG_PERFORMABLE != 0 {
        BindingAnswer::Performable
    } else {
        BindingAnswer::Ours
    }
}

/// The same question, formatted for a log line.
pub fn binding_probe(msg: u32, wp: WPARAM, lp: LPARAM) -> &'static str {
    ask_binding(msg, wp, lp).label()
}
