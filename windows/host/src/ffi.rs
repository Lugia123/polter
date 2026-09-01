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
pub const ACTION_COPY_TITLE_TO_CLIPBOARD: u32 = 68;

// `ghostty_action_goto_tab_e`. Anything >= 0 is a 1-based tab index.
pub const GOTO_TAB_PREVIOUS: i32 = -1;
pub const GOTO_TAB_NEXT: i32 = -2;
pub const GOTO_TAB_LAST: i32 = -3;

// `ghostty_action_close_tab_mode_e`.
pub const CLOSE_TAB_THIS: i32 = 0;
pub const CLOSE_TAB_OTHER: i32 = 1;
pub const CLOSE_TAB_RIGHT: i32 = 2;

pub const PLATFORM_WIN32: u32 = 3;

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

    /// `ghostty_action_size_limit_s { u32 min_w, min_h, max_w, max_h; }`.
    /// A zero max means "no maximum", which is what the core sends today.
    pub fn as_size_limit(&self) -> (u32, u32, u32, u32) {
        let g = |i: usize| u32::from_ne_bytes(self.payload[i..i + 4].try_into().unwrap());
        (g(0), g(4), g(8), g(12))
    }
}

pub type WakeupCb = extern "C" fn(*mut c_void);
pub type ActionCb = extern "C" fn(App, Target, Action) -> bool;
pub type ReadClipboardCb = extern "C" fn(*mut c_void, u32, *mut c_void) -> bool;
pub type ConfirmReadClipboardCb = extern "C" fn(*mut c_void, *const c_char, *mut c_void, u32);
pub type WriteClipboardCb = extern "C" fn(*mut c_void, u32, *const c_void, usize, bool);
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
    assert!(std::mem::size_of::<KeyEvent>() == 32);
    assert!(std::mem::align_of::<KeyEvent>() == 8);
};

/// Resolved entry points. We load at runtime rather than link, because the
/// build installs no import library for ghostty-internal.dll, and because
/// the width table lives in a *different* DLL than the surface API.
/// `ghostty_diagnostic_s`. **One field: there is no line number.** A criterion
/// that promises to show where in the file the error is cannot be met from
/// this API; the message is the whole of what the core reports.
#[repr(C)]
pub struct Diagnostic {
    pub message: *const c_char,
}

pub struct Api {
    pub init: unsafe extern "C" fn(usize, *const *const c_char) -> i32,
    pub config_new: unsafe extern "C" fn() -> Config,
    pub config_diagnostics_count: unsafe extern "C" fn(Config) -> u32,
    pub config_get_diagnostic: unsafe extern "C" fn(Config, u32) -> Diagnostic,
    pub config_load_default_files: unsafe extern "C" fn(Config),
    pub config_finalize: unsafe extern "C" fn(Config),
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

    // from ghostty-vt.dll -- proves both DLLs are loaded and callable
    pub codepoint_width: unsafe extern "C" fn(u32) -> u8,
    /// Cluster-aware width, in cells. Consumes one grapheme per call and
    /// returns how many codepoints it took. This is the terminal's own table:
    /// using anything else makes the candidate window drift on exactly the
    /// characters an IME produces.
    pub grapheme_width: unsafe extern "C" fn(*const u32, usize, *mut u8) -> usize,
}
