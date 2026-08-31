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
use crate::{api, logf};
use windows::Win32::Foundation::{HWND, LRESULT, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::*;

/// Host-level accelerators, tried **only for what the core did not take**.
///
/// The core owns keybinds; this table exists because the core's Windows
/// defaults are not yet exercised on a real machine, and a host with no way
/// to open a tab is not testable. Every entry here goes through
/// `ghostty_surface_binding_action` -- the same entry point a macOS menu item
/// uses -- so the action path being tested is the production one. When the
/// core's own binds cover these, this table stops firing on its own: it is
/// reached only after `ghostty_surface_key` returned false.
fn accelerator(vk: VIRTUAL_KEY, ctrl: bool, shift: bool) -> Option<&'static str> {
    match (ctrl, shift, vk) {
        (true, true, VK_T) => Some("new_tab"),
        (true, true, VK_W) => Some("close_tab:this"),
        (true, true, VK_C) => Some("copy_title_to_clipboard"),
        (true, true, VK_M) => Some("toggle_maximize"),
        (true, true, VK_RIGHT) => Some("move_tab:1"),
        (true, true, VK_LEFT) => Some("move_tab:-1"),
        (true, false, VK_TAB) => Some("next_tab"),
        // Splits. The names are the core's own binding syntax, so these go
        // through exactly the path a user's keybind would.
        (true, true, VK_D) => Some("new_split:right"),
        (true, true, VK_E) => Some("new_split:down"),
        (true, true, VK_Z) => Some("toggle_split_zoom"),
        (true, true, VK_OEM_PLUS) => Some("equalize_splits"),
        (true, true, VK_UP) => Some("goto_split:up"),
        (true, true, VK_DOWN) => Some("goto_split:down"),
        // The palette's only other way in is a keybind, which reaches the core
        // through surface_key -- the path that goes dead whenever the scan code
        // is zero. This entry does not, so the panel stays reachable.
        (true, true, VK_P) => Some("toggle_command_palette"),
        (_, _, VK_F11) => Some("toggle_fullscreen"),
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
            composing: false,
        };
        let vk = wp.0 as u16;
        // Read out what the log needs before the event is handed over: the
        // C struct is passed by value and moves.
        let (ev_keycode, ev_mods) = (ev.keycode, ev.mods);
        let consumed_by_core = (api().surface_key)(surface, ev);
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
            if let Some(name) = accelerator(VIRTUAL_KEY(vk), ctrl, shift) {
                let ok = crate::binding(name);
                logf!("[key] host accelerator {:?} -> binding_action = {}", name, ok);
                consumed = ok;
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
