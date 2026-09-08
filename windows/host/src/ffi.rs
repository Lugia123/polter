//! Hand-written libghostty FFI.
//!
//! Every layout here was measured against `include/ghostty.h` with a native
//! C program (offsetof/sizeof), not guessed:
//!   action_s          size 32  align 8  (tag @0, union @8, union size 24)
//!   target_s          size 16  align 8
//!   surface_config_s  size 96  align 8
//!   runtime_config_s  size 64
//! If any of those change, this file is wrong and the symptom will be
//! garbage payloads rather than a link error.

// The tags and mode values here are the ABI written down; a couple are not
// referenced yet (new_window is the next batch) but belong with the rest.
#![allow(dead_code)]

use std::ffi::c_void;
use std::os::raw::c_char;

pub type App = *mut c_void;
pub type Config = *mut c_void;
pub type Surface = *mut c_void;

// --- action tags we care about (values generated from ghostty.h) ---
pub const ACTION_QUIT: u32 = 0;
pub const ACTION_CLOSE_TAB: u32 = 3;
pub const ACTION_PRESENT_TERMINAL: u32 = 22;
pub const ACTION_INITIAL_SIZE: u32 = 25;
pub const ACTION_CELL_SIZE: u32 = 26;
pub const ACTION_RENDER: u32 = 28;
pub const ACTION_SET_TITLE: u32 = 34;
pub const ACTION_MOUSE_SHAPE: u32 = 39;
pub const ACTION_MOUSE_VISIBILITY: u32 = 40;
pub const ACTION_RENDERER_HEALTH: u32 = 42;
pub const ACTION_RELOAD_CONFIG: u32 = 50;
pub const ACTION_CONFIG_CHANGE: u32 = 51;
pub const ACTION_CLOSE_WINDOW: u32 = 52;
pub const ACTION_RING_BELL: u32 = 53;
pub const ACTION_SHOW_CHILD_EXITED: u32 = 59;

// --- M6-a batch: the "capability parity" actions this host now implements.
//
// Values derived from `src/apprt/action.zig`'s `Action.Key` declaration
// order (the C enum is generated from it, so position *is* the ABI value).
// Cross-checked against the constants above, which #57 measured
// independently: close_tab=3, present_terminal=22, initial_size=25,
// cell_size=26, render=28, set_title=34 all agree.
pub const ACTION_NEW_WINDOW: u32 = 1;
pub const ACTION_NEW_TAB: u32 = 2;
pub const ACTION_NEW_SPLIT: u32 = 4;
pub const ACTION_TOGGLE_QUICK_TERMINAL: u32 = 10;
pub const ACTION_GOTO_SPLIT: u32 = 17;
pub const ACTION_RESIZE_SPLIT: u32 = 19;
pub const ACTION_EQUALIZE_SPLITS: u32 = 20;
pub const ACTION_TOGGLE_SPLIT_ZOOM: u32 = 21;
pub const ACTION_TOGGLE_MAXIMIZE: u32 = 6;
/// `Action.Key.toggle_command_palette`, the 12th member of that enum.
/// Verified against `src/apprt/action.zig` the same way the rest of this
/// table was: parse the 72 members in order and take the index.
pub const ACTION_TOGGLE_COMMAND_PALETTE: u32 = 11;
// Search and the pending-key indicator. Ordinals derived the same way as the
// rest of this table: parse the 72 members of `Action.Key` in
// `src/apprt/action.zig` in order and take the index.
pub const ACTION_OPEN_CONFIG: u32 = 43;
pub const ACTION_KEY_SEQUENCE: u32 = 47;
pub const ACTION_READONLY: u32 = 67;
pub const ACTION_KEY_TABLE: u32 = 48;
pub const ACTION_START_SEARCH: u32 = 63;
pub const ACTION_END_SEARCH: u32 = 64;
pub const ACTION_SEARCH_TOTAL: u32 = 65;
pub const ACTION_SEARCH_SELECTED: u32 = 66;
pub const ACTION_TOGGLE_FULLSCREEN: u32 = 7;
pub const ACTION_MOVE_TAB: u32 = 15;
pub const ACTION_GOTO_TAB: u32 = 16;
pub const ACTION_SIZE_LIMIT: u32 = 23;
pub const ACTION_RESET_WINDOW_SIZE: u32 = 24;
pub const ACTION_SET_TAB_TITLE: u32 = 35;
pub const ACTION_PWD: u32 = 38;
pub const ACTION_COPY_TITLE_TO_CLIPBOARD: u32 = 68;
/// The five below are the tags `cb_action` used to fall through to `_ => false`
/// on. **A falling-through tag is not a silent no-op**: `binding_action`
/// returns false and the menu row does nothing, which reads as a broken menu.
/// Counted the same way as the rest -- the whole `ghostty_action_tag_e` was
/// parsed and checked against the six constants already here before these were
/// taken from it.
pub const ACTION_TOGGLE_POLTERGEIST_CHAT: u32 = 12;
/// `toggle_visibility`, the member straight after `toggle_poltergeist_chat`.
///
/// **This number is machine-checked**, along with every other one in this
/// file, by `test "the Windows host's action tags"` in `src/apprt/action.zig`,
/// which names the action a wrong number would dispatch instead. A second
/// checker reading `ghostty_action_tag_e` was written for this task and then
/// deleted: that test's own comment argues against it by name, because the
/// header is already pinned to the enum, and one fact with two readers is the
/// shape this repository has opened tasks about.
pub const ACTION_TOGGLE_VISIBILITY: u32 = 13;
pub const ACTION_INSPECTOR: u32 = 29;
pub const ACTION_PROMPT_TITLE: u32 = 37;
pub const ACTION_FLOAT_WINDOW: u32 = 45;
/// The three tags after `copy_title_to_clipboard`, counted off
/// `ghostty_action_tag_e` in `include/ghostty.h`. **The count was checked
/// against a tag that was already here**: `copy_title_to_clipboard` comes out
/// at 68 by the same counting, which is what says the counting is right.
pub const ACTION_MOVE_TAB_TO_NEW_WINDOW: u32 = 69;
pub const ACTION_POLTERGEIST_MARK: u32 = 70;
pub const ACTION_POLTERGEIST_CLOSE: u32 = 71;

// --- The terminal-semantics and appearance batch (task 273, second group).
//
// **Every ordinal below was counted twice, from two files that are generated
// from each other, and both counts were anchored on a constant that was
// already in this table.** The two readings are `Action.Key`'s declaration
// order in `src/apprt/action.zig` (72 members) and `ghostty_action_tag_e`'s
// member order in `include/ghostty.h`; the anchors are
// `copy_title_to_clipboard` = 68 and `move_tab_to_new_window` = 69, which
// come out right in both. That is the whole of what says these numbers are
// right -- **a wrong ordinal here compiles, links, and silently dispatches
// one action into another action's arm.**
pub const ACTION_TOGGLE_BACKGROUND_OPACITY: u32 = 14;
pub const ACTION_SCROLLBAR: u32 = 27;
pub const ACTION_DESKTOP_NOTIFICATION: u32 = 33;
pub const ACTION_MOUSE_OVER_LINK: u32 = 41;
pub const ACTION_QUIT_TIMER: u32 = 44;
pub const ACTION_COLOR_CHANGE: u32 = 49;
pub const ACTION_SELECTION_CHANGED: u32 = 54;
pub const ACTION_OPEN_URL: u32 = 58;
pub const ACTION_PROGRESS_REPORT: u32 = 60;
pub const ACTION_COMMAND_FINISHED: u32 = 62;

// `ghostty_action_open_url_kind_e`. **`OSC8` is the one that matters**: it is
// the only kind whose URL was chosen by whatever is running in the terminal
// rather than by the person at the keyboard, so it is the only one this host
// refuses to hand to the shell unconditionally. See `links.rs`.
pub const OPEN_URL_KIND_UNKNOWN: i32 = 0;
pub const OPEN_URL_KIND_TEXT: i32 = 1;
pub const OPEN_URL_KIND_HTML: i32 = 2;
pub const OPEN_URL_KIND_OSC8: i32 = 3;

// `ghostty_action_progress_report_state_e`.
pub const PROGRESS_STATE_REMOVE: i32 = 0;
pub const PROGRESS_STATE_SET: i32 = 1;
pub const PROGRESS_STATE_ERROR: i32 = 2;
pub const PROGRESS_STATE_INDETERMINATE: i32 = 3;
pub const PROGRESS_STATE_PAUSE: i32 = 4;

// `ghostty_action_color_kind_e`. Anything >= 0 is a palette index; the three
// named colours are negative.
pub const COLOR_KIND_FOREGROUND: i32 = -1;
pub const COLOR_KIND_BACKGROUND: i32 = -2;
pub const COLOR_KIND_CURSOR: i32 = -3;

// `ghostty_action_quit_timer_e`.
pub const QUIT_TIMER_START: i32 = 0;
pub const QUIT_TIMER_STOP: i32 = 1;

/// The window/tab/edit batch (task 272). Counted off `ghostty_action_tag_e`
/// in `include/ghostty.h` the same way every number above it was.
///
/// **These five are checked rather than trusted, and by something that runs.**
/// `src/apprt/action.zig`'s test `the Windows host's action tags` reads this
/// file and compares every `ACTION_*` here against `Action.Key`, naming the
/// action a wrong number would dispatch instead. It is not a comment about a
/// check that ought to exist: `zig build test -Dtest-filter="the Windows host's
/// action tags"` runs 86 tests where an unmatched filter runs 85, so the
/// difference is this one executing.
pub const ACTION_CLOSE_ALL_WINDOWS: u32 = 5;
pub const ACTION_GOTO_WINDOW: u32 = 18;
pub const ACTION_SET_WINDOW_TITLE: u32 = 36;
pub const ACTION_UNDO: u32 = 55;
pub const ACTION_REDO: u32 = 56;

// --- Actions this host answers with a **refusal**, not an implementation.
//
// **These six are a ledger, not a capability list, and the difference has to
// be kept in the arithmetic.** Counting the `ACTION_*` that appear in
// `cb_action` used to answer "how many of the core's actions does this host
// do"; with these six declared it answers something else, because each of
// them exists so that pressing the thing produces a *named refusal* instead
// of `[action] tag=30 is not implemented by this host` -- a bare number, in a
// log the person cannot see, from a row that looked like every row that
// works. So the number to publish is three numbers: implemented, refused by
// name, and still owed.
//
// **Why a refusal is worth an arm at all.** `_ => false` already returns
// false; what it cannot do is say *why*, and "this platform has no such
// thing" and "nobody has built it yet" are different sentences that a person
// filing a bug needs told apart. `ACTION_INSPECTOR` (29) has answered that
// way since the port had an inspector question at all, and these follow it.
//
// Ordinals counted off `ghostty_action_tag_e` like every constant above, and
// checked by `the Windows host's action tags` in `src/apprt/action.zig` --
// which names the action a wrong number would dispatch instead.
pub const ACTION_TOGGLE_TAB_OVERVIEW: u32 = 8;
pub const ACTION_TOGGLE_WINDOW_DECORATIONS: u32 = 9;
pub const ACTION_SHOW_GTK_INSPECTOR: u32 = 30;
pub const ACTION_RENDER_INSPECTOR: u32 = 31;
pub const ACTION_EXPORT_TERMINAL_IO: u32 = 32;
pub const ACTION_CHECK_FOR_UPDATES: u32 = 57;

/// `secure_input`. **Not in the ledger above**: this one is implemented.
///
/// Ordinal counted off `ghostty_action_tag_e` and checked by
/// `the Windows host's action tags` in `src/apprt/action.zig`.
pub const ACTION_SECURE_INPUT: u32 = 46;

// --- Actions this host **owes**: it does not perform them, and the arm says
// so by name with the task that carries the work.
//
// **A third state, not a spelling of refusal.** The ledger above is "this
// platform has no such thing"; these four are "not built here yet", and
// writing them with the same marker would register work-not-done as
// work-not-wanted. Two of them were looked at and deferred with a reason
// (285, 286) and two are simply owed (302, 303) -- the arm's sentence says
// which, because in six months a deferred decision that reads like an
// oversight gets picked up again and its reasoning thrown away.
//
// Ordinals counted off `ghostty_action_tag_e` and checked by
// `the Windows host's action tags` in `src/apprt/action.zig`.
// `ACTION_TOGGLE_BACKGROUND_OPACITY` (14) and `ACTION_QUIT_TIMER` (44) are
// **not repeated here**: they are already declared in the block above, which
// W3 added when it counted that batch. Two constants for one tag is a Rust
// compile error (`E0428`), which is the one duplication in this file that
// cannot be made silently -- so the arms below simply use those.
// `ACTION_TOGGLE_VISIBILITY` (13) is **not repeated here** either: task 302
// implemented it and declared it in the block above, and the two changes met
// in the merge.
pub const ACTION_SHOW_ON_SCREEN_KEYBOARD: u32 = 61;

/// `ghostty_action_secure_input_e`, whose members are `on, off, toggle` in
/// that order (`src/apprt/action.zig`'s `SecureInput`, pinned to the header by
/// `checkGhosttyHEnum`).
///
/// **`toggle` is a real third value and not a spelling of the other two.** The
/// core sends `on`/`off` from `setPasswordInput`; `toggle` arrives from the
/// keybinding, and a host that folded it into "on" would leave the person
/// unable to switch the thing off from the keyboard.
pub const SECURE_INPUT_ON: i32 = 0;
pub const SECURE_INPUT_OFF: i32 = 1;
pub const SECURE_INPUT_TOGGLE: i32 = 2;

/// `ghostty_action_poltergeist_mark_s`. The prefix is the core's rendered
/// glyphs; `role`, `shielded` and `held` are the meaning, which is what a menu
/// item needs -- **a tick cannot be derived from a string**, which is the
/// reason the core sends both.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PoltergeistMark {
    pub prefix: *const c_char,
    /// `ghostty_action_poltergeist_role_e`: 0 none, 1 supervisor, 2 watched.
    pub role: i32,
    pub shielded: bool,
    /// The user is holding this terminal to its work.
    ///
    /// **Its own field and not a glyph inside `prefix`**, since task 276. A
    /// terminal with no role carries no prefix at all, held or not, so the
    /// hold was invisible out here in exactly the case that is normal.
    pub held: bool,
}

/// `ghostty_action_poltergeist_close_scope_e`.
pub const POLTERGEIST_CLOSE_THIS_TAB: i32 = 0;
pub const POLTERGEIST_CLOSE_OTHER_TABS: i32 = 1;
pub const POLTERGEIST_CLOSE_TABS_TO_THE_RIGHT: i32 = 2;
pub const POLTERGEIST_CLOSE_WINDOW: i32 = 3;

/// `ghostty_action_poltergeist_close_result_e`.
///
/// **Zero is `UNSUPPORTED` on purpose**, and the header says why: the core
/// initialises the cell to it, so an apprt that quietly does nothing -- or
/// writes nothing -- is reported as having done nothing rather than
/// inheriting `CLOSED` by accident. A host that closes the tab and forgets
/// to write here leaves the agent believing the action was ignored, which is
/// the *worse* of the two failures because the screen looks right.
pub const POLTERGEIST_CLOSE_RESULT_UNSUPPORTED: i32 = 0;
pub const POLTERGEIST_CLOSE_RESULT_CLOSED: i32 = 1;
pub const POLTERGEIST_CLOSE_RESULT_AWAITING_CONFIRMATION: i32 = 2;

// `ghostty_action_goto_tab_e`. Anything >= 0 is a 1-based tab index.
pub const GOTO_TAB_PREVIOUS: i32 = -1;
pub const GOTO_TAB_NEXT: i32 = -2;
pub const GOTO_TAB_LAST: i32 = -3;

// `ghostty_action_close_tab_mode_e`.
pub const CLOSE_TAB_THIS: i32 = 0;
pub const CLOSE_TAB_OTHER: i32 = 1;
pub const CLOSE_TAB_RIGHT: i32 = 2;

// `ghostty_input_mouse_state_e`.
pub const MOUSE_RELEASE: i32 = 0;
pub const MOUSE_PRESS: i32 = 1;

// `ghostty_input_mouse_button_e`. Only the three this host forwards are
// named; the enum runs to eleven and the rest have no Win32 message here.
pub const MOUSE_UNKNOWN: i32 = 0;
pub const MOUSE_LEFT: i32 = 1;
pub const MOUSE_RIGHT: i32 = 2;
pub const MOUSE_MIDDLE: i32 = 3;

pub const PLATFORM_WIN32: u32 = 3;

// `ghostty_clipboard_e`.
pub const CLIPBOARD_STANDARD: u32 = 0;
pub const CLIPBOARD_SELECTION: u32 = 1;

// `ghostty_clipboard_request_e`.
pub const CLIPBOARD_REQUEST_PASTE: u32 = 0;
pub const CLIPBOARD_REQUEST_OSC_52_READ: u32 = 1;
pub const CLIPBOARD_REQUEST_OSC_52_WRITE: u32 = 2;

/// `ghostty_clipboard_content_s`.
///
/// **The write callback is handed an array of these, not a string.** Both
/// fields are `const char*`, so a host that reads the payload as one C string
/// gets the *mime type* -- `text/plain` copied to the clipboard, every time,
/// with no error anywhere. The pair is the reason this struct exists rather
/// than a `*const c_char`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ClipboardContent {
    pub mime: *const c_char,
    pub data: *const c_char,
}

// `ghostty_target_tag_e`. **The union only has a surface in it**, so when
// the tag says `APP` the `surface` field is not a surface -- reading it is
// how a per-surface fact gets recorded against a pointer that names nothing.
pub const TARGET_APP: u32 = 0;
pub const TARGET_SURFACE: u32 = 1;

#[repr(C)]
pub struct Target {
    pub tag: u32,
    pub _pad: u32,
    pub surface: Surface,
}

#[repr(C)]
pub struct Action {
    pub tag: u32,
    pub _pad: u32,
    pub payload: [u8; 24],
}

impl Action {
    /// Both initial_size and cell_size are `{ u32 width; u32 height; }`.
    pub fn as_size(&self) -> (u32, u32) {
        let w = u32::from_ne_bytes(self.payload[0..4].try_into().unwrap());
        let h = u32::from_ne_bytes(self.payload[4..8].try_into().unwrap());
        (w, h)
    }
    /// set_title carries a `const char*`.
    pub fn as_cstr(&self) -> Option<&'static std::ffi::CStr> {
        let p = usize::from_ne_bytes(self.payload[0..8].try_into().unwrap()) as *const c_char;
        if p.is_null() { return None; }
        Some(unsafe { std::ffi::CStr::from_ptr(p) })
    }

    /// `ghostty_action_poltergeist_mark_s { const char* prefix; int role;
    /// bool shielded; bool held; }`. The pointer is 8-aligned, so `role` is at
    /// offset 8 and `shielded` at 12 -- **not** packed after the pointer at 8
    /// and 12 by luck: the same 4-alignment rule that put `resize_split`'s
    /// enum at 4 rather than 2 applies here, and getting it wrong reads a byte
    /// of padding as the tick.
    ///
    /// `held` is a second `bool` immediately after `shielded`, at 13. **Added
    /// at the end on purpose**: every offset above it is unchanged, so the
    /// struct grew without moving anything an older reading depended on.
    pub fn as_poltergeist_mark(&self) -> (i32, bool, bool) {
        let role = i32::from_ne_bytes(self.payload[8..12].try_into().unwrap());
        (role, self.payload[12] != 0, self.payload[13] != 0)
    }

    /// `ghostty_action_poltergeist_close_s { scope; bool confirm; result*; }`.
    ///
    /// The enum is int-sized at 0 and `confirm` is one byte at 4, but the
    /// **out pointer is 8-aligned**, so it lands at 8 and not at 5. Reading
    /// it at 5 would hand the core three bytes of padding and five bytes of
    /// pointer to write an enum through, which is a wild write rather than a
    /// wrong answer.
    pub fn as_poltergeist_close(&self) -> (i32, bool, *mut i32) {
        let scope = i32::from_ne_bytes(self.payload[0..4].try_into().unwrap());
        let confirm = self.payload[4] != 0;
        let result = usize::from_ne_bytes(self.payload[8..16].try_into().unwrap()) as *mut i32;
        (scope, confirm, result)
    }

    /// `ghostty_action_reload_config_s { bool soft; }`.
    ///
    /// **`soft` is the difference between two different jobs.** True means
    /// "hand the core back the config you already have" -- the core's own
    /// conditional state (light/dark, say) changed and it wants the values
    /// recomputed against it. False means "go and read the file again",
    /// which is what «重载配置» and ctrl+shift+, mean. Treating soft as hard
    /// throws away whatever the user typed into the settings window; treating
    /// hard as soft is the bug this port had, and it looks like nothing
    /// happening.
    pub fn as_reload_soft(&self) -> bool {
        self.payload[0] != 0
    }

    /// A bare `c_int` payload: goto_tab, close_tab mode, fullscreen mode.
    pub fn as_i32(&self) -> i32 {
        i32::from_ne_bytes(self.payload[0..4].try_into().unwrap())
    }

    /// `ghostty_action_move_tab_s { ssize_t amount; }`.
    pub fn as_isize(&self) -> i64 {
        i64::from_ne_bytes(self.payload[0..8].try_into().unwrap())
    }

    /// `ghostty_action_resize_split_s { u16 amount; enum direction; }`.
    /// The enum is int-sized and 4-aligned, so it lands at offset 4, not 2.
    pub fn as_resize_split(&self) -> (u16, i32) {
        let amount = u16::from_ne_bytes(self.payload[0..2].try_into().unwrap());
        let dir = i32::from_ne_bytes(self.payload[4..8].try_into().unwrap());
        (amount, dir)
    }

    /// `ghostty_action_key_sequence_s { bool active; ghostty_input_trigger_s trigger; }`
    /// where the trigger is `{ int tag; union { int; u32 } key; int mods; }`.
    /// The bool is 1 byte but the trigger is 4-aligned, so the trigger starts
    /// at offset 4, not 1.
    pub fn as_key_sequence(&self) -> (bool, i32, u32, i32) {
        let g = |i: usize| i32::from_ne_bytes(self.payload[i..i + 4].try_into().unwrap());
        (self.payload[0] != 0, g(4), g(8) as u32, g(12))
    }

    /// `ghostty_action_key_table_s { tag; union { struct { const char* name; size_t len; } } }`.
    /// Returns the tag and, for `activate`, the name.
    pub fn as_key_table(&self) -> (i32, Option<String>) {
        let tag = i32::from_ne_bytes(self.payload[0..4].try_into().unwrap());
        if tag != 0 {
            return (tag, None);
        }
        let p = usize::from_ne_bytes(self.payload[8..16].try_into().unwrap()) as *const u8;
        let len = usize::from_ne_bytes(self.payload[16..24].try_into().unwrap());
        if p.is_null() || len == 0 || len > 256 {
            return (tag, None);
        }
        let bytes = unsafe { std::slice::from_raw_parts(p, len) };
        (tag, Some(String::from_utf8_lossy(bytes).into_owned()))
    }

    /// A NUL-terminated `const char*` at `off`, as an owned `String`.
    ///
    /// **Owned, not borrowed, and that is the point.** `as_cstr` hands back a
    /// `&'static CStr` over memory the core owns for the duration of the
    /// callback only; every arm below hands its text to another thread or to
    /// a window procedure that runs later. A borrow that outlives the call is
    /// the shape `borrow-across-dispatch.py` exists to catch.
    fn string_at(&self, off: usize) -> Option<String> {
        let p = usize::from_ne_bytes(self.payload[off..off + 8].try_into().unwrap())
            as *const c_char;
        if p.is_null() {
            return None;
        }
        Some(unsafe { std::ffi::CStr::from_ptr(p) }.to_string_lossy().into_owned())
    }

    /// A `(ptr, len)` pair at `off`, as an owned `String`. Not NUL-terminated
    /// on the core's side, so the length is the only thing that ends it.
    ///
    /// `None` for a null pointer **and for a zero length**: the core sends
    /// `len == 0` to mean "the mouse left the link", and a zero-length string
    /// and no string at all are the same fact with two spellings.
    fn sized_string_at(&self, off: usize) -> Option<String> {
        let p = usize::from_ne_bytes(self.payload[off..off + 8].try_into().unwrap()) as *const u8;
        let len = usize::from_ne_bytes(self.payload[off + 8..off + 16].try_into().unwrap());
        if p.is_null() || len == 0 {
            return None;
        }
        // A URL longer than this is not a URL anybody typed or clicked; the
        // ceiling is here so a corrupt length cannot make us read a gigabyte.
        if len > 64 * 1024 {
            return None;
        }
        let bytes = unsafe { std::slice::from_raw_parts(p, len) };
        Some(String::from_utf8_lossy(bytes).into_owned())
    }

    /// `ghostty_action_open_url_s { kind; const char* url; uintptr_t len; }`.
    /// The enum is int-sized and the pointer is 8-aligned, so `url` is at 8
    /// and `len` at 16 -- **not** packed at 4 and 12.
    pub fn as_open_url(&self) -> (i32, Option<String>) {
        (self.as_i32(), self.sized_string_at(8))
    }

    /// `ghostty_action_mouse_over_link_s { const char* url; size_t len; }`.
    /// `None` means the pointer has left the link.
    pub fn as_mouse_over_link(&self) -> Option<String> {
        self.sized_string_at(0)
    }

    /// `ghostty_action_desktop_notification_s { const char* title, *body; }`.
    /// Both are NUL-terminated.
    pub fn as_desktop_notification(&self) -> (Option<String>, Option<String>) {
        (self.string_at(0), self.string_at(8))
    }

    /// `ghostty_action_progress_report_s { state; int8_t progress; }`, where
    /// `progress` is **-1 for "no percentage was reported"** and 0..=100
    /// otherwise. Returned as `Option<u8>` so the sentinel cannot be painted
    /// as a bar length by accident.
    pub fn as_progress_report(&self) -> (i32, Option<u8>) {
        let raw = self.payload[4] as i8;
        (self.as_i32(), if (0..=100).contains(&raw) { Some(raw as u8) } else { None })
    }

    /// `ghostty_action_color_change_s { kind; uint8_t r, g, b; }`. The enum is
    /// int-sized, so the three bytes start at offset 4.
    pub fn as_color_change(&self) -> (i32, u8, u8, u8) {
        (self.as_i32(), self.payload[4], self.payload[5], self.payload[6])
    }

    /// `ghostty_action_command_finished_s { int16_t exit_code; uint64_t
    /// duration; }`. The `u64` is 8-aligned, so it is at offset 8 and not 2.
    ///
    /// `exit_code` is **-1 for "no exit code was reported"**, which is why it
    /// comes back as an `Option` rather than as a number a caller could
    /// compare against zero and call a success.
    pub fn as_command_finished(&self) -> (Option<i16>, u64) {
        let code = i16::from_ne_bytes(self.payload[0..2].try_into().unwrap());
        let duration = u64::from_ne_bytes(self.payload[8..16].try_into().unwrap());
        (if code < 0 { None } else { Some(code) }, duration)
    }

    /// `ghostty_action_scrollbar_s { uint64_t total, offset, len; }` --
    /// rows of scrollback in total, the top row on screen, and how many rows
    /// are visible.
    pub fn as_scrollbar(&self) -> (u64, u64, u64) {
        let g = |i: usize| u64::from_ne_bytes(self.payload[i..i + 8].try_into().unwrap());
        (g(0), g(8), g(16))
    }

    /// `ghostty_action_size_limit_s { u32 min_w, min_h, max_w, max_h; }`.
    /// A zero max means "no maximum", which is what the core sends today.
    pub fn as_size_limit(&self) -> (u32, u32, u32, u32) {
        let g = |i: usize| u32::from_ne_bytes(self.payload[i..i + 4].try_into().unwrap());
        (g(0), g(4), g(8), g(12))
    }
}

pub type WakeupCb = extern "C" fn(*mut c_void);
pub type ActionCb = extern "C" fn(App, Target, Action) -> bool;
/// `(surface userdata, ghostty_clipboard_e, request state) -> started`.
///
/// **The return value carries an ownership contract**, and it is the one
/// thing in this file that leaks if it is got wrong. `embedded.zig`
/// (`clipboardRequest`) allocates the request state before calling this:
///
///  * return `false` and the core destroys that state -- the safe answer, and
///    the right one for *every* failure path here;
///  * return `true` and the host has promised to call
///    `ghostty_surface_complete_clipboard_request` with that same pointer.
///    Returning `true` and then bailing out leaks the request, silently.
pub type ReadClipboardCb = extern "C" fn(*mut c_void, u32, *mut c_void) -> bool;
pub type ConfirmReadClipboardCb = extern "C" fn(*mut c_void, *const c_char, *mut c_void, u32);
/// `(surface userdata, ghostty_clipboard_e, contents, count, confirm)`.
///
/// The first argument is **the surface's** userdata -- our pane id -- not the
/// runtime's. `embedded.zig` passes `self.userdata` from the `Surface`, and
/// `RuntimeConfig.userdata` (which is null) never reaches here.
pub type WriteClipboardCb =
    extern "C" fn(*mut c_void, u32, *const ClipboardContent, usize, bool);
pub type CloseSurfaceCb = extern "C" fn(*mut c_void, bool);

/// `ghostty_input_key_s`.
///
/// `keycode` is **not** a `GHOSTTY_KEY_*` value. The core resolves it through
/// `src/input/keycodes.zig` against that table's native column, which for a
/// Windows build holds PC scan codes. See `keys.rs`.
#[repr(C)]
pub struct KeyEvent {
    pub action: u32,
    pub mods: i32,
    pub consumed_mods: i32,
    pub keycode: u32,
    /// UTF-8, NUL-terminated, or null for a key that types nothing.
    pub text: *const c_char,
    pub unshifted_codepoint: u32,
    pub composing: bool,
}

#[repr(C)]
pub struct RuntimeConfig {
    pub userdata: *mut c_void,
    pub supports_selection_clipboard: bool,
    pub wakeup_cb: WakeupCb,
    pub action_cb: ActionCb,
    pub read_clipboard_cb: ReadClipboardCb,
    pub confirm_read_clipboard_cb: ConfirmReadClipboardCb,
    pub write_clipboard_cb: WriteClipboardCb,
    pub close_surface_cb: CloseSurfaceCb,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SurfaceConfig {
    pub platform_tag: u32,
    pub _pad0: u32,
    pub platform_hwnd: *mut c_void, // union { nsview | uiview | hwnd }
    pub userdata: *mut c_void,
    pub scale_factor: f64,
    pub font_size: f32,
    pub _pad1: u32,
    pub working_directory: *const c_char,
    pub command: *const c_char,
    pub env_vars: *mut c_void,
    pub env_var_count: usize,
    pub initial_input: *const c_char,
    pub wait_after_command: bool,
    pub context: u32,
    pub poltergeist_chat: bool,
    pub _pad2: [u8; 7],
}

const _: () = {
    assert!(std::mem::size_of::<Action>() == 32);
    assert!(std::mem::size_of::<Target>() == 16);
    assert!(std::mem::size_of::<SurfaceConfig>() == 96);
    assert!(std::mem::size_of::<RuntimeConfig>() == 64);
    // action u32 + mods i32 + consumed i32 + keycode u32 then an 8-aligned
    // pointer, u32, bool, tail padding.
    assert!(std::mem::size_of::<GString>() == 24);
    assert!(std::mem::size_of::<Info>() == 24);
    assert!(std::mem::size_of::<Diagnostic>() == 8);
    assert!(std::mem::size_of::<KeyEvent>() == 32);
    assert!(std::mem::align_of::<KeyEvent>() == 8);
    // Measured the same way the rest of this file was, against
    // `include/ghostty.h`: two doubles, two u32s, then an 8-aligned pointer
    // and a usize.
    assert!(std::mem::size_of::<Text>() == 40);
    assert!(std::mem::size_of::<Point>() == 16);
    assert!(std::mem::size_of::<Selection>() == 36);
};

/// Resolved entry points. We load at runtime rather than link, because the
/// build installs no import library for ghostty-internal.dll, and because
/// the width table lives in a *different* DLL than the surface API.
/// `ghostty_string_s { const char* ptr; uintptr_t len; bool sentinel; }`.
/// Owned by the core; hand it back to `ghostty_string_free`.
///
/// **The third field is easy to miss and expensive to miss**: `string_free`
/// takes this *by value*, so a two-field version would compile, link, and
/// hand the callee a short structure. The size assertion below is what makes
/// that a build failure instead of a corrupted stack on the test machine.
#[repr(C)]
pub struct GString {
    pub ptr: *const c_char,
    pub len: usize,
    pub sentinel: bool,
}

/// `ghostty_info_s { ghostty_build_mode_e build_mode; const char* version; size_t version_len; }`.
/// The enum is int-sized, so the pointer lands at offset 8, not 4.
#[repr(C)]
pub struct Info {
    pub build_mode: i32,
    pub version: *const c_char,
    pub version_len: usize,
}

/// `ghostty_diagnostic_s`. **One field: there is no line number.** A criterion
/// that promises to show where in the file the error is cannot be met from
/// this API; the message is the whole of what the core reports.
#[repr(C)]
pub struct Diagnostic {
    pub message: *const c_char,
}

/// `ghostty_input_trigger_s { int tag; union { int physical; u32 unicode; } key; int mods; }`.
///
/// The same shape `ffi.rs` already describes inline for
/// `ghostty_action_key_sequence_s`; it is spelled out as a type here because
/// the keybind listing hands back whole structs rather than one field.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Trigger {
    pub tag: i32,
    pub key: u32,
    pub mods: i32,
}

/// `ghostty_trigger_tag_e`.
pub const TRIGGER_PHYSICAL: i32 = 0;
pub const TRIGGER_UNICODE: i32 = 1;
pub const TRIGGER_CATCH_ALL: i32 = 2;

/// `ghostty_binding_flags_e`. **`PERFORMABLE` is the one this host cares
/// about**: a binding carrying it is absent from the core's reverse map, which
/// is why the menu cannot print its shortcut even though the key works.
pub const BINDING_CONSUMED: u8 = 1 << 0;
pub const BINDING_ALL: u8 = 1 << 1;
pub const BINDING_GLOBAL: u8 = 1 << 2;
pub const BINDING_PERFORMABLE: u8 = 1 << 3;

/// `ghostty_keybind_s`: one row of the keybind listing.
///
/// **Not `config_trigger`.** That call reads the core's reverse map, which
/// deliberately drops `performable` bindings so a GUI does not register them
/// as menu accelerators -- so a page built on it is blind in exactly the
/// places the menu is. This comes from the forward table.
///
/// `action` is static storage owned by the core: **do not free it**, and it
/// stays valid for the life of the process.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Keybind {
    pub action: *const u8,
    pub action_len: usize,
    /// `false` means "this action exists and has no key today". That is the
    /// only way an action with no default binding -- `toggle_secure_input`,
    /// say -- can appear in a listing at all.
    pub bound: bool,
    pub trigger: Trigger,
    pub flags: u8,
    /// The binding is reached through a leader-key sequence and `trigger` is
    /// only its first step. ⚠️ **No real data stands behind this today**: the
    /// core's default configuration has no sequenced bindings.
    pub sequence: bool,
}

impl Keybind {
    /// The action's tag, or `None` for the row an out-of-range index returns.
    ///
    /// **Borrowed from the core, not copied**: the pointer is a compile-time
    /// constant on the other side of the ABI.
    pub fn action(&self) -> Option<&'static str> {
        if self.action.is_null() || self.action_len == 0 {
            return None;
        }
        // SAFETY: the core documents this as static, NUL-free, UTF-8 storage
        // whose length it reports; `action_len` is not a guess.
        let bytes = unsafe { std::slice::from_raw_parts(self.action, self.action_len) };
        std::str::from_utf8(bytes).ok()
    }

    /// Whether the core's reverse map -- and therefore the menu -- can see
    /// this binding.
    pub fn hidden_from_menu(&self) -> bool {
        self.bound && (self.flags & BINDING_PERFORMABLE) != 0
    }
}

// --- reading the screen, for the UIA provider (`uia.rs`) ---

/// `ghostty_point_tag_e`.
pub const POINT_ACTIVE: i32 = 0;
pub const POINT_VIEWPORT: i32 = 1;
pub const POINT_SCREEN: i32 = 2;
pub const POINT_SURFACE: i32 = 3;

/// `ghostty_point_coord_e`.
pub const COORD_EXACT: i32 = 0;
pub const COORD_TOP_LEFT: i32 = 1;
pub const COORD_BOTTOM_RIGHT: i32 = 2;

/// `ghostty_point_s`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Point {
    pub tag: i32,
    pub coord: i32,
    pub x: u32,
    pub y: u32,
}

/// `ghostty_selection_s`.
///
/// **`rectangle` is a `bool` after two 16-byte points, so the struct is 36
/// bytes and not 40.** Both fields being 4-aligned is what keeps the tail
/// from rounding up to 8; the assertion below is what makes a wrong guess a
/// build failure rather than a selection the core reads past the end of.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Selection {
    pub tl: Point,
    pub br: Point,
    pub rectangle: bool,
}

impl Selection {
    /// The whole of what is on screen right now, scrollback excluded.
    ///
    /// The `x`/`y` are ignored for the `TOP_LEFT`/`BOTTOM_RIGHT` coords --
    /// they name the corner, they do not carry it. This is the same pair
    /// macOS builds for `cachedVisibleContents`.
    pub fn viewport() -> Selection {
        Selection {
            tl: Point { tag: POINT_VIEWPORT, coord: COORD_TOP_LEFT, x: 0, y: 0 },
            br: Point { tag: POINT_VIEWPORT, coord: COORD_BOTTOM_RIGHT, x: 0, y: 0 },
            rectangle: false,
        }
    }
}

/// `ghostty_text_s`. **The core owns `text`**; it comes back from
/// `surface_read_text` and goes back through `surface_free_text`. Nothing
/// here may outlive that pair -- see the lock rule at the top of `uia.rs`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Text {
    pub tl_px_x: f64,
    pub tl_px_y: f64,
    pub offset_start: u32,
    pub offset_len: u32,
    pub text: *const c_char,
    pub text_len: usize,
}

impl Default for Text {
    fn default() -> Text {
        Text {
            tl_px_x: 0.0,
            tl_px_y: 0.0,
            offset_start: 0,
            offset_len: 0,
            text: std::ptr::null(),
            text_len: 0,
        }
    }
}

pub struct Api {
    pub init: unsafe extern "C" fn(usize, *const *const c_char) -> i32,
    pub config_new: unsafe extern "C" fn() -> Config,
    /// Version and build mode, for the about box. **The core owns this string**;
    /// a version the host composes itself is a second one to keep in step.
    pub info: unsafe extern "C" fn() -> Info,
    pub config_open_path: unsafe extern "C" fn() -> GString,
    pub string_free: unsafe extern "C" fn(GString),
    pub config_diagnostics_count: unsafe extern "C" fn(Config) -> u32,
    pub config_get_diagnostic: unsafe extern "C" fn(Config, u32) -> Diagnostic,
    /// The keybind listing: every binding, then every action that has none.
    ///
    /// **This is the data source for a "what are the shortcuts" page, and
    /// `config_trigger` is not.** See `Keybind`.
    pub config_keybind_count: unsafe extern "C" fn(Config) -> u32,
    pub config_keybind: unsafe extern "C" fn(Config, u32) -> Keybind,
    /// Read one config value by key. **The return value is the answer to "did
    /// the user set this"**, not just an error code: `c_get.zig`'s optional
    /// arm returns false for a field that is null, so
    /// `window-position-x` (`?i16`) reports false exactly when the user left
    /// it alone. That is the signal the geometry restore needs.
    pub config_get: unsafe extern "C" fn(Config, *mut c_void, *const u8, usize) -> bool,
    pub config_load_default_files: unsafe extern "C" fn(Config),
    pub config_finalize: unsafe extern "C" fn(Config),
    /// Hand the core a config and let it propagate to every surface.
    ///
    /// **The seven things `App.updateConfig` sets have no other way in**, and
    /// `App.zig` says in so many words that neither apprt calls it at launch:
    /// the agent socket, the notice interval, the stand-down rule, three
    /// Poltergeist timers and the compaction threshold sit at their struct
    /// defaults until something calls this. Four of those defaults are `0`,
    /// which means *off*, so "the feature does nothing" is what a Windows
    /// user saw and there was nothing in any log to say why.
    ///
    /// **The caller keeps the config.** `embedded.zig` clones what it needs
    /// before returning, so the handle may be freed the moment this returns
    /// -- and must not be freed while anything else still holds it, which on
    /// this host means `CONFIG`.
    ///
    /// It performs `.config_change` back at the apprt before it returns, on
    /// this same thread. An arm that re-reads the config on *that* tag calls
    /// this again, and the recursion has nothing to stop it.
    pub app_update_config: unsafe extern "C" fn(App, Config),
    /// The same, for one surface only. This is what a *soft* reload of a
    /// surface target is: the core's conditional state moved and the values
    /// want recomputing, with no file read anywhere.
    pub surface_update_config: unsafe extern "C" fn(Surface, Config),
    /// Release a config handle. The twin of `config_new`; without it every
    /// reload leaks a whole `Config`, and a reload is a key people hold down
    /// while they edit a theme.
    pub config_free: unsafe extern "C" fn(Config),
    pub app_new: unsafe extern "C" fn(*const RuntimeConfig, Config) -> App,
    pub app_tick: unsafe extern "C" fn(App),
    pub surface_config_new: unsafe extern "C" fn() -> SurfaceConfig,
    pub surface_new: unsafe extern "C" fn(App, *const SurfaceConfig) -> Surface,
    pub surface_draw: unsafe extern "C" fn(Surface),
    pub surface_set_size: unsafe extern "C" fn(Surface, u32, u32),
    pub surface_set_content_scale: unsafe extern "C" fn(Surface, f64, f64),
    pub surface_set_focus: unsafe extern "C" fn(Surface, bool),
    pub surface_free: unsafe extern "C" fn(Surface),
    /// Drive a keybind action by name, e.g. "new_tab" or "goto_tab:2".
    ///
    /// This is how a menu item works on macOS: the core parses the string,
    /// performs the binding, and emits the resulting action back through
    /// `action_cb` -- the same path a real key press takes through
    /// `surface_key` below. The host accelerators in `keys.rs` and the
    /// `--selftest` script both go through here, which is why a green
    /// self-test is evidence about the *action* path and says nothing about
    /// the keyboard.
    pub surface_binding_action: unsafe extern "C" fn(Surface, *const u8, usize) -> bool,
    /// The second half of a paste. `read_clipboard_cb` only says a request
    /// **started**; the text arrives back through here, against the same
    /// `state` pointer the callback was handed.
    ///
    /// **Its absence from this struct is the whole of "paste does nothing".**
    /// Without the symbol there is no way to finish a request, which makes
    /// `cb_read_clipboard`'s hard-coded `false` the only self-consistent thing
    /// it could have been.
    pub surface_complete_clipboard_request:
        unsafe extern "C" fn(Surface, *const c_char, *mut c_void, bool),

    // --- keyboard ---
    /// The real input entry point. `surface_text` only ever meant "these
    /// bytes were typed"; this is what carries a *key*, which is what
    /// Ctrl-C is.
    pub surface_key: unsafe extern "C" fn(Surface, KeyEvent) -> bool,

    // --- IME ---
    /// Committed text, as if typed. UTF-8, length in bytes.
    pub surface_text: unsafe extern "C" fn(Surface, *const c_char, usize),
    /// The in-flight composition, rendered inline by the core.
    pub surface_preedit: unsafe extern "C" fn(Surface, *const c_char, usize),
    /// Where the cursor is, for placing the candidate window.
    ///
    /// Out params are `x, y, width, height`. Read `src/Surface.zig:2277`
    /// before using them, because they are not the rectangle they look like:
    /// **x is the horizontal midpoint of the cursor cell, not its left edge**,
    /// **y is the cell's bottom, not its top**, and x/y/height are divided by
    /// the content scale while **width deliberately is not** (there is a
    /// comment there saying so, and saying why is unknown). At scale 1.0 the
    /// difference does not show.
    pub surface_ime_point: unsafe extern "C" fn(Surface, *mut f64, *mut f64, *mut f64, *mut f64),

    // --- mouse ---
    /// `(surface, state, button, mods) -> consumed`.
    ///
    /// **The core owns the selection**, the same way it owns the search: this
    /// host reports what the pointer did and never decides what a drag means.
    /// Nothing here had ever been called, so the core had never been told this
    /// terminal has a mouse at all -- which is why a drag produced no
    /// highlight and `copy_to_clipboard` declined for want of a selection.
    pub surface_mouse_button: unsafe extern "C" fn(Surface, i32, i32, i32) -> bool,
    /// `(surface, x, y, mods)`.
    ///
    /// **The coordinates are unscaled**, which is the one thing about this
    /// call that is easy to get wrong and invisible when wrong: the core
    /// multiplies them by the content scale itself
    /// (`embedded.zig`'s `cursorPosToPixels`). A Win32 client coordinate in a
    /// per-monitor-aware process is already in physical pixels, so it has to
    /// be **divided** by the same scale this host passed to
    /// `surface_set_content_scale` before it is handed over. Send physical
    /// pixels and the selection lands somewhere else on a high-DPI display
    /// while looking perfect at 100%.
    pub surface_mouse_pos: unsafe extern "C" fn(Surface, f64, f64, i32),
    /// `(surface, xoff, yoff, scroll_mods)`.
    ///
    /// **`yoff` is wheel *ticks*, not lines and not pixels** -- unless
    /// `scroll_mods` says the event is high precision, in which case it is
    /// pixels. `Surface.zig`'s `scrollCallback` says so directly, and it
    /// multiplies by the cell height and the user's
    /// `mouse-scroll-multiplier` **itself**. So a host that pre-multiplies by
    /// either of those is applying it twice, and the symptom is a wheel that
    /// feels wrong in a way nobody can attribute.
    ///
    /// Fractional ticks are expected and handled: high-resolution wheels
    /// report less than one notch at a time.
    ///
    /// **Signs pass straight through.** Win32 says a positive `wDelta` is the
    /// wheel rotated away from the user; the core says positive is up. Same
    /// direction, no negation -- and getting that wrong is invisible to any
    /// criterion that only asks whether the view moved.
    ///
    /// `scroll_mods` is `ghostty_input_scroll_mods_t`, a bitmask: bit 0 is
    /// `precision`, bits 1-3 are the momentum phase. Zero is "an ordinary
    /// notched wheel", which is all Win32 gives us.
    pub surface_mouse_scroll: unsafe extern "C" fn(Surface, f64, f64, i32),

    // --- reading the screen ---
    /// Copy some of the terminal's text out. **The core takes its own
    /// `renderer_state.mutex` and hands back a copy** (`embedded.zig`'s
    /// `readTextLocked` -> `dumpTextLocked`), so what arrives is a snapshot
    /// and not a view onto a buffer the terminal thread is still writing.
    ///
    /// The core's own comment on it: *"This is an expensive operation so it
    /// shouldn't be called too often. We recommend that callers cache the
    /// result and throttle calls to this function."* `uia.rs` does.
    pub surface_read_text: unsafe extern "C" fn(Surface, Selection, *mut Text) -> bool,
    /// Whether this surface has a selection right now.
    ///
    /// **The half that keeps an empty answer honest.** `read_selection`
    /// answers `false` both when there is no selection and when it could not
    /// read one, and a UIA client reads an empty selection array as "nothing
    /// is selected" -- so without this, "nothing selected" and "could not
    /// tell" would be the same reply.
    pub surface_has_selection: unsafe extern "C" fn(Surface) -> bool,
    /// The current selection's text, with the same `Text` payload
    /// `read_text` fills in -- including `tl_px_*`, whose **`-1` means the
    /// range is not in the viewport** (`embedded.zig` substitutes it when
    /// `text.viewport` is null). That is a value-shaped absence, and anything
    /// that computes with it produces a rectangle pointing at a place the
    /// text is not.
    pub surface_read_selection: unsafe extern "C" fn(Surface, *mut Text) -> bool,
    /// The other half of `surface_read_text`. **Not optional**: the text is
    /// the core's allocation, and skipping this leaks it once per read --
    /// which, at a screen reader's polling rate, is a leak with a slope.
    pub surface_free_text: unsafe extern "C" fn(Surface, *mut Text),

    // --- CLI actions ---
    /// Run a `+action` from this process's command line, if there is one.
    ///
    /// **It does not return when there is one**: it runs the action and
    /// exits. That is the whole contract, and it is the same one
    /// `macos/Sources/App/main.swift` relies on at line 51.
    ///
    /// It was inert on Windows until `global.zig` was taught to read
    /// `GetCommandLineW()`: the C API handed that target an empty command
    /// line, so `global.action()` was always null and this returned at once.
    pub cli_try_action: unsafe extern "C" fn(),
    /// `ghostty_translate(msgid) -> translated`, or the same pointer when the
    /// catalogue has no entry. The core's own catalogues (`po/`) are already
    /// loaded by `i18n.init` during `ghostty_init`; this is the only thing
    /// the host needed in order to use them. See `i18n.rs`.
    pub translate: unsafe extern "C" fn(*const c_char) -> *const c_char,

    // from ghostty-vt.dll -- proves both DLLs are loaded and callable
    pub codepoint_width: unsafe extern "C" fn(u32) -> u8,
    /// Cluster-aware width, in cells. Consumes one grapheme per call and
    /// returns how many codepoints it took. This is the terminal's own table:
    /// using anything else makes the candidate window drift on exactly the
    /// characters an IME produces.
    pub grapheme_width: unsafe extern "C" fn(*const u32, usize, *mut u8) -> usize,
}
