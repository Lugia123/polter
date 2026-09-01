//! The pending-key indicator: what the terminal is waiting for.
//!
//! **Why this is a feature and not decoration.** A key sequence bind
//! (`ctrl+a>ctrl+b>n=new_window`) puts the terminal into a state where the
//! next keystroke means something different. Without a visible sign, a user
//! who pressed the first half has **no way to tell** whether the terminal is
//! waiting, whether the chord already failed, or whether the key did nothing
//! at all -- and the recovery (press Escape) is only obvious if you know
//! which of the three you are in.
//!
//! **The core drives it entirely.** `key_sequence { active, trigger }`
//! arrives with `active = true` once per key consumed by a sequence, and with
//! `active = false` when the sequence ends (completed or abandoned).
//! `key_table` pushes/pops the name of an active key table. The host only
//! accumulates and draws.
//!
//! **Note there is no default key sequence in the shipped config** -- the
//! `ctrl+z>1=` style bindings in `Config.zig` are inside its tests. So this
//! indicator is only reachable once a user configures a sequence, which is
//! also why its acceptance criterion says to configure one first.
//!
//! **Naming a key without a 176-entry table.** The core publishes no
//! key-to-name function, so the host has to render `ghostty_input_key_e`
//! itself. But three ranges of that enum are contiguous -- letters at 20..=45,
//! digits at 6..=15, F1..F12 at 121..=132 -- so the common cases are
//! arithmetic, and only a dozen named keys need a table. A trigger tagged
//! `UNICODE` carries the codepoint and needs no mapping at all.

use std::cell::RefCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::Mutex;

use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::logf;

const WM_KEYSEQ_SYNC: u32 = WM_APP + 6;

const HEIGHT: i32 = 30;
const PAD: i32 = 10;
const COL_BG: u32 = 0x00403f3d;
const COL_TEXT: u32 = 0x00ffffff;
const COL_DIM: u32 = 0x00a0a0a0;

static HWND_KEYSEQ: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// `ghostty_input_key_e`, **read from the header rather than copied out of
/// it**.
///
/// The ordinals used to be a dozen hand-counted constants and everything else
/// fell through to a `key#N` string. That was defensible while this file only
/// drew the pending-key indicator, where showing *that* a key was consumed is
/// the whole job. **It stopped being defensible the moment menus started
/// rendering their shortcut halves through here**: `Ctrl+key#72` is not a
/// degraded label, it is a wrong one, and it went in front of users.
///
/// 72 is `INSERT`. `Ctrl+Insert` and `Shift+Insert` are the oldest
/// copy/paste keys on Windows, so the binding was not just valid, it was the
/// most Windows-appropriate binding in the menu -- and this file printed it
/// as a number.
///
/// Embedding the header (the same trick `menu.rs` uses on `Binding.zig`)
/// means the table **cannot drift from the enum it names**, and that adding a
/// key to the core cannot silently produce another `key#N`.
const GHOSTTY_H: &str = include_str!("../../../include/ghostty.h");

/// Enum member names in ordinal order, e.g. `["UNIDENTIFIED", "BACKQUOTE",
/// ...]` with the `GHOSTTY_KEY_` prefix removed.
fn key_names() -> &'static [String] {
    static NAMES: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    NAMES.get_or_init(|| {
        let mut out = Vec::new();
        let mut inside = false;
        for line in GHOSTTY_H.lines() {
            let t = line.trim();
            if !inside {
                // The enum is anonymous, so it is found by its typedef name
                // on the closing line; the opening one is just `typedef enum
                // {`. Tracking from the first member instead: the block that
                // ends `} ghostty_input_key_e;` is the one we want, and
                // members are recognised by their prefix, which no other enum
                // in this header shares.
                if t.starts_with("GHOSTTY_KEY_") {
                    inside = true;
                } else {
                    continue;
                }
            }
            if t.starts_with('}') {
                break;
            }
            if let Some(name) = t.strip_prefix("GHOSTTY_KEY_") {
                let name = name.trim_end_matches(',').trim();
                if !name.is_empty() {
                    out.push(name.to_string());
                }
            }
        }
        out
    })
}

/// `ghostty_input_trigger_tag_e`
const TRIGGER_PHYSICAL: i32 = 0;
const TRIGGER_UNICODE: i32 = 1;

/// `ghostty_input_mods_e` bits that are worth showing. Sided and lock bits are
/// deliberately dropped: "Ctrl+Shift+A" is what the user typed into their
/// config, and showing "RCtrl+CapsLock+Ctrl+Shift+A" would be accurate and
/// useless.
pub(crate) fn mods_label(mods: i32) -> String {
    let mut s = String::new();
    if mods & (1 << 1) != 0 {
        s.push_str("Ctrl+");
    }
    if mods & (1 << 2) != 0 {
        s.push_str("Alt+");
    }
    if mods & (1 << 0) != 0 {
        s.push_str("Shift+");
    }
    if mods & (1 << 3) != 0 {
        s.push_str("Win+");
    }
    s
}

pub(crate) fn key_label(tag: i32, key: u32) -> String {
    if tag == TRIGGER_UNICODE {
        return char::from_u32(key)
            .map(|c| c.to_uppercase().to_string())
            .unwrap_or_else(|| "?".into());
    }
    if tag != TRIGGER_PHYSICAL {
        return "\u{2026}".into();
    }
    let Some(name) = key_names().get(key as usize) else {
        // **No longer silent.** What comes out of this function is shown to a
        // user, so a key with no name is a defect to report, not a string to
        // print. Reaching here now means an ordinal outside the enum the
        // header declares -- a core newer than the header this was built
        // against.
        logf!("[keys] no label for physical key #{key}; the header has {} entries", key_names().len());
        return format!("key#{key}");
    };
    label_for_name(name)
}

/// One enum member name as a person would see it on a keycap.
///
/// Split out so the whole enum can be walked in a test without a window.
fn label_for_name(name: &str) -> String {
    // Symbols are drawn as the symbol, not as the word: `Ctrl+;` reads, and
    // `Ctrl+Semicolon` does not.
    match name {
        "BACKQUOTE" => return "`".into(),
        "BACKSLASH" => return "\\".into(),
        "BRACKET_LEFT" => return "[".into(),
        "BRACKET_RIGHT" => return "]".into(),
        "COMMA" => return ",".into(),
        "EQUAL" => return "=".into(),
        "MINUS" => return "-".into(),
        "PERIOD" => return ".".into(),
        "QUOTE" => return "'".into(),
        "SEMICOLON" => return ";".into(),
        "SLASH" => return "/".into(),
        "ARROW_LEFT" => return "\u{2190}".into(),
        "ARROW_UP" => return "\u{2191}".into(),
        "ARROW_RIGHT" => return "\u{2192}".into(),
        "ARROW_DOWN" => return "\u{2193}".into(),
        "ESCAPE" => return "Esc".into(),
        "SPACE" => return "Space".into(),
        _ => {}
    }
    // `A`..`Z` and `F1`..`F25` are already what a keycap says.
    if name.len() == 1 || (name.starts_with('F') && name[1..].chars().all(|c| c.is_ascii_digit())) {
        return name.to_string();
    }
    // `DIGIT_7` is the 7 key.
    if let Some(d) = name.strip_prefix("DIGIT_") {
        return d.to_string();
    }
    // `NUMPAD_ADD` -> `NumAdd`, keeping numpad keys distinguishable from the
    // main-row keys that share their names. Without this, `NUMPAD_5` and `5`
    // would render identically and a menu could not tell them apart.
    if let Some(rest) = name.strip_prefix("NUMPAD_") {
        return format!("Num{}", camel(rest));
    }
    camel(name)
}

/// `PAGE_DOWN` -> `PageDown`.
fn camel(name: &str) -> String {
    name.split('_')
        .map(|w| {
            let mut c = w.chars();
            match c.next() {
                Some(f) => f.to_uppercase().collect::<String>() + &c.as_str().to_lowercase(),
                None => String::new(),
            }
        })
        .collect()
}

#[derive(Default)]
struct Inbox {
    /// Appended triggers, already rendered to text.
    push: Vec<String>,
    /// True when the core said the sequence ended.
    clear: bool,
    /// Key table pushes; `None` entries mean "pop one".
    tables: Vec<Option<String>>,
    tables_clear: bool,
}

static INBOX: Mutex<Inbox> = Mutex::new(Inbox {
    push: Vec::new(),
    clear: false,
    tables: Vec::new(),
    tables_clear: false,
});

#[derive(Default)]
struct State {
    pending: Vec<String>,
    tables: Vec<String>,
    font: HFONT,
    visible: bool,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

fn post() {
    let h = HWND_KEYSEQ.load(Ordering::Acquire);
    if h.is_null() {
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), WM_KEYSEQ_SYNC, WPARAM(0), LPARAM(0)) };
}

// ------------------------------------------------------- from `action_cb`

/// `GHOSTTY_ACTION_KEY_SEQUENCE`. **Safe from any thread.**
pub fn on_key_sequence(active: bool, tag: i32, key: u32, mods: i32) {
    if let Ok(mut inbox) = INBOX.lock() {
        if active {
            inbox.push.push(format!("{}{}", mods_label(mods), key_label(tag, key)));
        } else {
            inbox.clear = true;
            inbox.push.clear();
        }
    }
    post();
}

/// `GHOSTTY_ACTION_KEY_TABLE`. **Safe from any thread.**
/// `tag`: 0 activate, 1 deactivate, 2 deactivate all.
pub fn on_key_table(tag: i32, name: Option<&str>) {
    if let Ok(mut inbox) = INBOX.lock() {
        match tag {
            0 => inbox.tables.push(Some(name.unwrap_or("?").to_string())),
            1 => inbox.tables.push(None),
            _ => {
                inbox.tables_clear = true;
                inbox.tables.clear();
            }
        }
    }
    post();
}

// ------------------------------------------------------------------ setup

pub fn init(hinst: windows::Win32::Foundation::HINSTANCE) {
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_DROPSHADOW,
            lpfnWndProc: Some(keyseq_proc),
            hInstance: hinst,
            hbrBackground: HBRUSH(std::ptr::null_mut()),
            lpszClassName: w!("PolterKeySeq"),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 {
            logf!("[keyseq] RegisterClassExW failed");
            return;
        }
        // `WS_EX_NOACTIVATE`: this thing must never take focus. It is a sign,
        // not a control, and stealing focus mid-chord would break the very
        // sequence it is reporting.
        let hwnd = match CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            w!("PolterKeySeq"),
            w!("Polter"),
            WS_POPUP,
            0,
            0,
            200,
            HEIGHT,
            None,
            None,
            Some(hinst),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                logf!("[keyseq] CreateWindowExW failed: {e:?}");
                return;
            }
        };
        let dpi = GetDpiForWindow(hwnd).max(96) as i32;
        let font = CreateFontW(
            -(14 * dpi / 96),
            0,
            0,
            0,
            FW_SEMIBOLD.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            w!("Segoe UI"),
        );
        STATE.with(|c| c.borrow_mut().font = font);
        HWND_KEYSEQ.store(hwnd.0, Ordering::Release);
        logf!("[keyseq] ready");
    }
}

fn label() -> String {
    STATE.with(|c| {
        let st = c.borrow();
        let mut s = String::new();
        for t in &st.tables {
            s.push('[');
            s.push_str(t);
            s.push_str("] ");
        }
        s.push_str(&st.pending.join(" "));
        if !st.pending.is_empty() {
            s.push_str(" …");
        }
        s.trim().to_string()
    })
}

fn sync() {
    // Drain the inbox, then drop the lock before touching any window.
    let (push, clear, tables, tables_clear) = {
        let Ok(mut inbox) = INBOX.lock() else { return };
        (
            std::mem::take(&mut inbox.push),
            std::mem::replace(&mut inbox.clear, false),
            std::mem::take(&mut inbox.tables),
            std::mem::replace(&mut inbox.tables_clear, false),
        )
    };

    STATE.with(|c| {
        let mut st = c.borrow_mut();
        if clear {
            st.pending.clear();
        }
        st.pending.extend(push);
        if tables_clear {
            st.tables.clear();
        }
        for t in tables {
            match t {
                Some(name) => st.tables.push(name),
                None => {
                    st.tables.pop();
                }
            }
        }
    });

    let text = label();
    let me = HWND(HWND_KEYSEQ.load(Ordering::Acquire));
    if me.0.is_null() {
        return;
    }

    let want = !text.is_empty();
    let was = STATE.with(|c| c.borrow().visible);
    STATE.with(|c| c.borrow_mut().visible = want);

    unsafe {
        if !want {
            if was {
                let _ = ShowWindow(me, SW_HIDE);
                logf!("[keyseq] cleared");
            }
            return;
        }

        let frame = crate::tabs::frame_hwnd();
        let mut fr = RECT::default();
        if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
            return;
        }
        let dpi = GetDpiForWindow(me).max(96) as i32;
        let sc = |v: i32| v * dpi / 96;

        // Width follows the text: a fixed box would either clip a long chord
        // or float mostly empty.
        let w = sc(PAD * 2) + (text.chars().count() as i32 + 1) * sc(9);
        let h = sc(HEIGHT);
        let x = fr.right - w - sc(16);
        let y = fr.bottom - h - sc(16);

        // `SWP_NOACTIVATE` for the same reason as `WS_EX_NOACTIVATE`.
        let _ = SetWindowPos(
            me,
            Some(HWND_TOPMOST),
            x,
            y,
            w,
            h,
            SWP_SHOWWINDOW | SWP_NOACTIVATE,
        );
        let _ = InvalidateRect(Some(me), None, true);
        logf!("[keyseq] pending {:?}", text);
    }
}

extern "system" fn keyseq_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_KEYSEQ_SYNC => {
                sync();
                LRESULT(0)
            }
            // Never take focus, even if something tries to give it.
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(hwnd, &mut ps);
                if !hdc.is_invalid() {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(hwnd, &mut rc);
                    let bg = CreateSolidBrush(COLORREF(COL_BG));
                    FillRect(hdc, &rc, bg);
                    let _ = DeleteObject(bg.into());
                    SetBkMode(hdc, TRANSPARENT);
                    let text = label();
                    STATE.with(|c| {
                        let st = c.borrow();
                        let old = SelectObject(hdc, st.font.into());
                        SetTextColor(
                            hdc,
                            COLORREF(if st.pending.is_empty() { COL_DIM } else { COL_TEXT }),
                        );
                        let mut wide: Vec<u16> = text.encode_utf16().collect();
                        DrawTextW(hdc, &mut wide, &mut rc, DT_CENTER | DT_SINGLELINE | DT_VCENTER);
                        SelectObject(hdc, old);
                    });
                    let _ = EndPaint(hwnd, &ps);
                }
                LRESULT(0)
            }
            WM_DESTROY => {
                STATE.with(|c| {
                    let f = c.borrow().font;
                    if !f.0.is_null() {
                        let _ = DeleteObject(f.into());
                    }
                });
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The ordinal of an enum member, looked up by name.
    ///
    /// **Not a hand-copied constant.** The constants this replaces were the
    /// reason the table could disagree with the header at all; a test that
    /// used them to check the header would have been checking one copy
    /// against itself.
    fn ord(name: &str) -> u32 {
        key_names()
            .iter()
            .position(|n| n == name)
            .unwrap_or_else(|| panic!("{name} is not in ghostty_input_key_e")) as u32
    }

    #[test]
    fn letters_digits_and_function_keys_read_as_keycaps() {
        assert_eq!(key_label(TRIGGER_PHYSICAL, ord("A")), "A");
        assert_eq!(key_label(TRIGGER_PHYSICAL, ord("Z")), "Z");
        assert_eq!(key_label(TRIGGER_PHYSICAL, ord("DIGIT_0")), "0");
        assert_eq!(key_label(TRIGGER_PHYSICAL, ord("DIGIT_9")), "9");
        assert_eq!(key_label(TRIGGER_PHYSICAL, ord("F1")), "F1");
        assert_eq!(key_label(TRIGGER_PHYSICAL, ord("F12")), "F12");
    }

    #[test]
    fn named_keys_come_from_the_table() {
        assert_eq!(key_label(TRIGGER_PHYSICAL, ord("ESCAPE")), "Esc");
        assert_eq!(key_label(TRIGGER_PHYSICAL, ord("SPACE")), "Space");
    }

    /// **The two the user was shown as numbers**, end to end through the same
    /// entry point the menu uses. `Ctrl+Insert` and `Shift+Insert` are the
    /// oldest copy/paste keys on Windows, so this was not an obscure binding
    /// being mangled -- it was the most appropriate one in the menu.
    #[test]
    fn insert_renders_as_insert_not_as_key_72() {
        let s = key_label(TRIGGER_PHYSICAL, ord("INSERT"));
        assert_eq!(s, "Insert");
        assert_eq!(format!("{}{}", mods_label(1 << 1), s), "Ctrl+Insert");
        assert_eq!(format!("{}{}", mods_label(1 << 0), s), "Shift+Insert");
    }

    /// An unmapped key must still say *something*: the indicator's job is to
    /// show that a key was consumed, and a blank label would look like the
    /// chord ended.
    /// An ordinal the header does not declare. **175 used to be the probe
    /// here and is not usable any more** -- it is `PASTE`, a real key with a
    /// real name now. Using an in-range ordinal as the "unmapped" probe is
    /// exactly how this function kept its blind spot: every value anyone
    /// tested with was one the fallback was expected to catch.
    #[test]
    fn an_ordinal_outside_the_enum_still_renders_and_is_identifiable() {
        let n = key_names().len() as u32 + 10;
        let s = key_label(TRIGGER_PHYSICAL, n);
        assert!(!s.is_empty());
        assert!(s.contains(&n.to_string()), "should name the ordinal, got {s}");
    }

    /// **Every key the core can report has a name.**
    ///
    /// This is the test that would have caught `Ctrl+key#72` before a user
    /// did. It walks the whole enum rather than the handful of ordinals
    /// somebody thought to list, because the defect was precisely in the ones
    /// nobody thought to list.
    #[test]
    fn no_key_in_the_enum_renders_as_a_number() {
        let names = key_names();
        assert_eq!(names.len(), 176, "the header's key enum changed size");
        for (i, name) in names.iter().enumerate() {
            let s = key_label(TRIGGER_PHYSICAL, i as u32);
            assert!(
                !s.contains("key#"),
                "ordinal {i} ({name}) has no label: {s}"
            );
            assert!(!s.is_empty(), "ordinal {i} ({name}) rendered empty");
        }
    }

    /// The three the user actually saw, by name rather than by ordinal, so
    /// this keeps meaning the same thing if the enum is renumbered.
    #[test]
    fn the_keys_that_were_printed_as_numbers_now_have_names() {
        assert_eq!(label_for_name("INSERT"), "Insert");
        assert_eq!(label_for_name("DELETE"), "Delete");
        assert_eq!(label_for_name("HOME"), "Home");
        assert_eq!(label_for_name("END"), "End");
        assert_eq!(label_for_name("PAGE_UP"), "PageUp");
        assert_eq!(label_for_name("PAGE_DOWN"), "PageDown");
        // The one that broke `quick.rs`'s fallback test.
        assert_eq!(label_for_name("BACKQUOTE"), "`");
    }

    /// Numpad keys must not collapse onto the main row: a menu that showed
    /// `Ctrl+5` for both could not say which one it meant.
    #[test]
    fn numpad_keys_are_distinguishable_from_the_main_row() {
        assert_ne!(label_for_name("NUMPAD_5"), label_for_name("DIGIT_5"));
        assert_eq!(label_for_name("DIGIT_5"), "5");
        assert_eq!(label_for_name("NUMPAD_5"), "Num5");
    }

    #[test]
    fn unicode_triggers_need_no_table() {
        assert_eq!(key_label(TRIGGER_UNICODE, 'c' as u32), "C");
    }

    #[test]
    fn mods_are_ordered_and_drop_sided_and_lock_bits() {
        // ctrl | shift, plus the right-hand ctrl bit and caps lock.
        let m = (1 << 1) | (1 << 0) | (1 << 7) | (1 << 4);
        assert_eq!(mods_label(m), "Ctrl+Shift+");
    }

    /// Isolates *which bit* each modifier is read from. The test above sets
    /// the base bit and its sided companion together, so reading the wrong one
    /// produced the same string and a mutation that swapped them passed.
    /// Added after that mutation run.
    #[test]
    fn each_modifier_comes_from_its_own_bit() {
        // The core always sets the base bit alongside a sided one (see
        // `keys.rs::mods`), so a sided bit on its own never occurs in
        // practice -- which is exactly why it is the probe: only a host
        // reading the wrong bit would turn it into a label.
        assert_eq!(mods_label(1 << 7), "", "ctrl_right alone is not Ctrl");
        assert_eq!(mods_label(1 << 6), "", "shift_right alone is not Shift");
        assert_eq!(mods_label(1 << 1), "Ctrl+");
        assert_eq!(mods_label(1 << 0), "Shift+");
        assert_eq!(mods_label(1 << 2), "Alt+");
        assert_eq!(mods_label(1 << 3), "Win+");
    }

    #[test]
    fn no_mods_is_empty_not_a_stray_plus() {
        assert_eq!(mods_label(0), "");
    }
}
