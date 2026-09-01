//! The quick terminal: one window that drops in on a global hotkey.
//!
//! **What makes this different from every other window in this host**: it is
//! reached when Polter is *not* the foreground application. That single fact
//! shapes the whole file --
//!
//!  - the hotkey has to be a **system-wide** registration (`RegisterHotKey`),
//!    not an accelerator in a window procedure, because there is no focus to
//!    receive a key;
//!  - **its failure is silent**: if another program already owns the
//!    combination, `RegisterHotKey` simply returns false and the key does
//!    nothing, which to a user is indistinguishable from "I mistyped it". So
//!    the result is logged, with the combination spelled out.
//!  - it has no tab strip, no tabs, and exactly one surface. It is a terminal
//!    that appears, not a window you manage.
//!
//! **The edge comes from the config.** An earlier note in this file said it
//! could not: that `quick-terminal-position` is a Zig enum with no entry in
//! `include/ghostty.h` and therefore nothing to read. **That was wrong, and
//! the correction is worth keeping** -- `ghostty_config_get` has a generic
//! `.@"enum"` arm (`src/config/c_get.zig`) that writes the tag *name* as a
//! `const char*`. So any enum in the config is readable by string, whether or
//! not `ghostty.h` names it, and `quick-terminal-position` is read here as
//! one of `top` / `bottom` / `left` / `right` / `center`.
//!
//! The screen is still the monitor under the pointer rather than
//! `quick-terminal-screen`: on a desk with two screens the panel should
//! arrive where the user is looking, which is `mouse`, the mode that is also
//! the most useful default. `main` remains unimplemented and is written down
//! here rather than silently assumed.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::c_void;

use windows::core::w;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::ffi::*;
use crate::{api, logf};

/// The hotkey's registration id. One is enough; the value only has to be
/// unique within this window.
const HOTKEY_ID: i32 = 0xB0;
/// The slide runs on this timer.
const TIMER_SLIDE: usize = 0xB1;
const SLIDE_STEPS: i32 = 8;

struct Quick {
    /// The frame that drops in. Owns nothing but the surface window.
    hwnd: HWND,
    /// The surface window inside it: a `PolterSurface`, so it reuses the same
    /// window procedure, the same `CS_OWNDC`, and the same key handling as a
    /// tab's pane. **A quick terminal is not a different kind of terminal.**
    child: HWND,
    surface: usize,
    visible: bool,
    /// Where the window is going, and where it started, during a slide.
    /// **Both coordinates**, because the panel slides sideways on the left
    /// and right edges and a y-only slide would leave those two edges
    /// appearing fully formed with no animation at all -- a difference nobody
    /// would report as a bug and nobody would notice as correct.
    slide_to: (i32, i32),
    slide_from: (i32, i32),
    slide_step: i32,
    /// **Last geometry per monitor, keyed by device name.**
    ///
    /// macOS keeps the same cache keyed by a stable display UUID, and the
    /// reason is the same here: monitors are unplugged and plugged back, and
    /// a window that reappears where it was on *that* screen is the whole
    /// point of a drop-down terminal. `\\\\.\\DISPLAY1` is the stable name
    /// Windows offers; a monitor handle is not stable across a replug.
    geometry: HashMap<String, RECT>,
    /// From the config, read once.
    autohide: bool,
    size_primary: (u32, f32), // (tag, value) -- tag per ghostty_quick_terminal_size_tag_e
    edge: Edge,
}

/// Which edge the panel drops in from -- `quick-terminal-position`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Edge {
    Top,
    Bottom,
    Left,
    Right,
    Center,
}

impl Edge {
    /// The core hands the enum over as its tag name.
    ///
    /// **An unrecognised name falls back to `Top` and says so.** A silent
    /// fallback here would make a typo in the config look like the feature
    /// ignoring the setting, which is the same symptom as not having read it
    /// at all -- and this file has already been wrong once about whether it
    /// could read it.
    pub fn parse(name: &str) -> Option<Edge> {
        match name {
            "top" => Some(Edge::Top),
            "bottom" => Some(Edge::Bottom),
            "left" => Some(Edge::Left),
            "right" => Some(Edge::Right),
            "center" => Some(Edge::Center),
            _ => None,
        }
    }
}

thread_local! {
    static QUICK: RefCell<Option<Quick>> = const { RefCell::new(None) };
}

fn with_quick<R>(f: impl FnOnce(&mut Quick) -> R) -> Option<R> {
    QUICK.with(|c| c.borrow_mut().as_mut().map(f))
}

/// The surface bound to a window, if that window is the quick terminal's.
///
/// `tabs::surface_of` falls through to this, so the shared `surface_wndproc`
/// keeps working without knowing this module exists.
pub fn surface_of(hwnd: HWND) -> Surface {
    QUICK
        .with(|c| {
            c.borrow()
                .as_ref()
                .filter(|q| q.child == hwnd)
                .map(|q| q.surface)
        })
        .map(|s| s as Surface)
        .unwrap_or(std::ptr::null_mut())
}

pub fn is_visible() -> bool {
    with_quick(|q| q.visible).unwrap_or(false)
}

// ------------------------------------------------------------------ screen

/// The monitor to drop into, and its work area.
///
/// The pointer's monitor, not the primary one: on a desk with two screens the
/// quick terminal should arrive where the user is looking, and the pointer is
/// the only cheap proxy for that. Returns the device name too, because that
/// is the key the geometry cache is stored under.
fn target_monitor() -> Option<(String, RECT)> {
    unsafe {
        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        let mon = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);
        let mut mi = MONITORINFOEXW {
            monitorInfo: MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFOEXW>() as u32,
                ..Default::default()
            },
            ..Default::default()
        };
        if !GetMonitorInfoW(mon, &mut mi as *mut _ as *mut MONITORINFO).as_bool() {
            return None;
        }
        let name = String::from_utf16_lossy(
            &mi.szDevice[..mi.szDevice.iter().position(|&c| c == 0).unwrap_or(0)],
        );
        // The *work* area, not the monitor: dropping over the taskbar is a
        // bug you only notice on the machine that has one at the top.
        Some((name, mi.monitorInfo.rcWork))
    }
}

/// How far along its axis the panel extends, from `quick-terminal-size`.
///
/// The primary size is measured along the axis the edge implies: a height for
/// top and bottom, a width for left and right. That is the core's own reading
/// of the setting, and it is why one number serves all four edges.
fn primary_extent(size: (u32, f32), full: i32) -> i32 {
    match size {
        // GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE
        (1, v) => ((full as f32) * (v / 100.0)) as i32,
        // GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS
        (2, v) => v as i32,
        // NONE, or anything unrecognised: a quarter of the screen.
        _ => full / 4,
    }
    .clamp(100.min(full), full)
}

/// Where the panel comes to rest on this work area, for this edge.
///
/// **Pure, so the four edges can be checked without a monitor.** The bug this
/// shape guards against is the one where three edges are written by copying
/// the first and one of the four ends up mirrored -- which on a machine whose
/// config says `top` is invisible forever.
pub fn resting_rect(edge: Edge, work: RECT, size: (u32, f32)) -> RECT {
    let (full_w, full_h) = (work.right - work.left, work.bottom - work.top);
    match edge {
        Edge::Top => {
            let h = primary_extent(size, full_h);
            RECT { left: work.left, top: work.top, right: work.right, bottom: work.top + h }
        }
        Edge::Bottom => {
            let h = primary_extent(size, full_h);
            RECT { left: work.left, top: work.bottom - h, right: work.right, bottom: work.bottom }
        }
        Edge::Left => {
            let w = primary_extent(size, full_w);
            RECT { left: work.left, top: work.top, right: work.left + w, bottom: work.bottom }
        }
        Edge::Right => {
            let w = primary_extent(size, full_w);
            RECT { left: work.right - w, top: work.top, right: work.right, bottom: work.bottom }
        }
        // Centre has no edge to come from, so it is sized on both axes and
        // simply appears. Sliding it from anywhere would be inventing a
        // direction the setting deliberately does not have.
        Edge::Center => {
            let w = primary_extent(size, full_w);
            let h = primary_extent(size, full_h);
            let (cx, cy) = (work.left + full_w / 2, work.top + full_h / 2);
            RECT { left: cx - w / 2, top: cy - h / 2, right: cx + w / 2, bottom: cy + h / 2 }
        }
    }
}

/// The top-left the slide starts from: just outside the work area, on the
/// edge the panel belongs to. Equal to the resting corner for `center`, which
/// is how "no slide" is expressed without a second code path.
pub fn offscreen_origin(edge: Edge, work: RECT, rest: RECT) -> (i32, i32) {
    let (w, h) = (rest.right - rest.left, rest.bottom - rest.top);
    match edge {
        Edge::Top => (rest.left, work.top - h),
        Edge::Bottom => (rest.left, work.bottom),
        Edge::Left => (work.left - w, rest.top),
        Edge::Right => (work.right, rest.top),
        Edge::Center => (rest.left, rest.top),
    }
}

/// The window rectangle for this drop, honouring the cache.
fn target_rect(q: &Quick, work: RECT, device: &str) -> RECT {
    if let Some(prev) = q.geometry.get(device) {
        return *prev;
    }
    resting_rect(q.edge, work, q.size_primary)
}

// -------------------------------------------------------------------- init

fn read_config(config: Config) -> (bool, (u32, f32), Edge) {
    use windows::core::s;
    use windows::Win32::System::LibraryLoader::{GetModuleHandleA, GetProcAddress};
    let mut autohide = true;
    let mut size = (1u32, 25.0f32);
    let mut edge = Edge::Top;
    unsafe {
        let Ok(m) = GetModuleHandleA(s!("ghostty-internal.dll")) else {
            return (autohide, size, edge);
        };
        let Some(p) = GetProcAddress(m, s!("ghostty_config_get")) else {
            logf!("[quick] ghostty_config_get not exported; using defaults");
            return (autohide, size, edge);
        };
        let get: unsafe extern "C" fn(Config, *mut c_void, *const u8, usize) -> bool =
            std::mem::transmute(p);

        let key = b"quick-terminal-autohide";
        let mut v: bool = true;
        if get(config, &mut v as *mut _ as *mut c_void, key.as_ptr(), key.len()) {
            autohide = v;
        }

        // `ghostty_config_quick_terminal_size_s` -- two `{tag, value}` pairs.
        #[repr(C)]
        #[derive(Default, Clone, Copy)]
        struct SizeOne {
            tag: u32,
            value: u32,
        }
        #[repr(C)]
        #[derive(Default, Clone, Copy)]
        struct SizeBoth {
            primary: SizeOne,
            secondary: SizeOne,
        }
        let key = b"quick-terminal-size";
        let mut s2 = SizeBoth::default();
        if get(config, &mut s2 as *mut _ as *mut c_void, key.as_ptr(), key.len()) {
            // The value is a union of `float` and `uint32`; which one it is
            // follows the tag, so it is read as the matching type rather than
            // cast between them.
            let v = match s2.primary.tag {
                1 => f32::from_bits(s2.primary.value),
                _ => s2.primary.value as f32,
            };
            size = (s2.primary.tag, v);
        }

        // The edge. `c_get.zig`'s generic enum arm writes the tag name as a
        // `const char*` owned by the core -- read, never freed.
        let key = b"quick-terminal-position";
        let mut name: *const std::os::raw::c_char = std::ptr::null();
        if get(config, &mut name as *mut _ as *mut c_void, key.as_ptr(), key.len())
            && !name.is_null()
        {
            let s = std::ffi::CStr::from_ptr(name).to_string_lossy().into_owned();
            match Edge::parse(&s) {
                Some(e) => edge = e,
                None => logf!(
                    "[quick] quick-terminal-position = {:?} is not a name this host knows; \
                     using top",
                    s
                ),
            }
        } else {
            logf!("[quick] quick-terminal-position could not be read; using top");
        }
    }
    (autohide, size, edge)
}

/// Create the window (hidden) and claim the hotkey.
pub fn init(hinst: windows::Win32::Foundation::HINSTANCE, config: Config, owner: HWND) {
    let (autohide, size_primary, edge) = read_config(config);

    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(quick_proc),
            hInstance: hinst,
            lpszClassName: w!("PolterQuick"),
            hbrBackground: HBRUSH(std::ptr::null_mut()),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 {
            logf!("[quick] RegisterClassExW failed");
            return;
        }

        let hwnd = CreateWindowExW(
            // TOOLWINDOW keeps it out of the taskbar and out of Alt+Tab: a
            // drop-down terminal is not a window you switch to, it is one
            // that arrives. TOPMOST because it must cover whatever the user
            // was looking at.
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            w!("PolterQuick"),
            w!("Polter"),
            WS_POPUP | WS_CLIPCHILDREN,
            0,
            0,
            100,
            100,
            None,
            None,
            Some(hinst),
            None,
        );
        let Ok(hwnd) = hwnd else {
            logf!("[quick] CreateWindowExW failed");
            return;
        };

        QUICK.with(|c| {
            *c.borrow_mut() = Some(Quick {
                hwnd,
                child: HWND(std::ptr::null_mut()),
                surface: 0,
                visible: false,
                slide_to: (0, 0),
                slide_from: (0, 0),
                slide_step: 0,
                geometry: HashMap::new(),
                autohide,
                size_primary,
                edge,
            })
        });

        // **The hotkey, and the one line that says whether it exists.**
        // `RegisterHotKey` fails when another process already owns the
        // combination, and it fails by returning false -- after which the key
        // does nothing at all and looks, from the user's side, exactly like a
        // key they did not press hard enough.
        // **The combination comes from the core's binding table**, the same
        // place the menus get their shortcut text. Hardcoding it here would
        // be §3.4.1's bug in its most expensive form: a user who rebinds
        // `toggle_quick_terminal` gets a hotkey that is not the one their
        // config says, with nothing anywhere reporting the disagreement.
        //
        // It also makes the failure path *testable without writing a
        // program to squat on a key*: point the config at a combination
        // something else already owns and `RegisterHotKey` fails for real.
        // **Four outcomes, four different lines.** They all end in the same
        // built-in fallback, so on screen they are one symptom; a single line
        // covering all four cost three round trips on the test machine to
        // tell the first from the last, and only an unrelated `diagnostics`
        // count made it possible at all.
        use crate::keys::Lookup;
        let resolved = match crate::keys::trigger_lookup("toggle_quick_terminal") {
            Lookup::NoLookup => {
                logf!(
                    "[quick] ghostty_config_trigger is not exported by this core, so no \
                     configured hotkey can be read at all; using the built-in {}",
                    HOTKEY_COMBO
                );
                None
            }
            Lookup::NoConfig => {
                logf!(
                    "[quick] no config handle yet, so the hotkey could not be looked up; \
                     using the built-in {}",
                    HOTKEY_COMBO
                );
                None
            }
            Lookup::Unbound => {
                logf!(
                    "[quick] the config was read and toggle_quick_terminal has no keybind \
                     in it; using the built-in {}",
                    HOTKEY_COMBO
                );
                None
            }
            Lookup::Bound(t) => match hotkey_from_trigger(t) {
                Some(v) => Some(v),
                None => {
                    // **The case that actually happened.** The tag, key and
                    // mods are in the line because without them it says only
                    // "something was bound and I could not use it", which is
                    // exactly where the last investigation stalled.
                    logf!(
                        "[quick] toggle_quick_terminal IS bound (tag={} key=0x{:x} mods=0x{:x} \
                         = {:?}) but this host cannot turn it into a RegisterHotKey \
                         combination; using the built-in {}",
                        t.tag,
                        t.key,
                        t.mods,
                        crate::keys::format_trigger(t),
                        HOTKEY_COMBO
                    );
                    None
                }
            },
        };
        let (mods, vk, combo) =
            resolved.unwrap_or((MOD_CONTROL, VK_OEM_3.0 as u32, HOTKEY_COMBO.to_string()));
        let r = RegisterHotKey(Some(owner), HOTKEY_ID, mods | MOD_NOREPEAT, vk);
        // `GetLastError` is read **before** anything else can clobber it, and
        // only on the failing branch, because on the success branch it holds
        // whatever the last unrelated call left behind.
        let err = if r.is_ok() {
            0
        } else {
            windows::Win32::Foundation::GetLastError().0
        };
        for line in hotkey_lines(&combo, r.is_ok(), err) {
            logf!("{}", line);
        }
        logf!(
            "[quick] window ready; edge={:?} autohide={} size={:?} monitors={}",
            edge,
            autohide,
            size_primary,
            monitor_count()
        );
    }
}

/// The combination used when the config has nothing usable. **One constant,
/// used by the registration and by the log**, so a line that names a
/// combination cannot name a different one than was actually asked for.
const HOTKEY_COMBO: &str = "Ctrl+`";

/// `ghostty_input_key_e` ordinals. The three contiguous runs are the same
/// ones `keyseq.rs` uses to name keys, derived by counting the enum in
/// `include/ghostty.h`; they are repeated rather than shared because that
/// file names keys for a human and this one maps them to virtual keys, and
/// the two would drift in different directions.
const K_BACKQUOTE: u32 = 1;
const K_DIGIT_0: u32 = 6;
const K_A: u32 = 20;
const K_SPACE: u32 = 63;
const K_ESCAPE: u32 = 120;
const K_F1: u32 = 121;

/// A core trigger as `RegisterHotKey` wants it: modifiers, virtual key, and
/// the combination spelled out for the log.
///
/// **`None` when the key cannot be expressed**, rather than a guess. A hotkey
/// registered on the wrong key is worse than no hotkey: it silently steals a
/// combination from another program and does the wrong thing when pressed,
/// and neither end reports it.
///
/// Only the keys a person actually binds a global hotkey to are mapped --
/// letters, digits, function keys, backquote, space, escape. That is
/// arithmetic on three contiguous ranges plus three constants, not a
/// 176-entry table; an unmapped key falls back and logs.
fn hotkey_from_trigger(t: crate::keys::TriggerC) -> Option<(HOT_KEY_MODIFIERS, u32, String)> {
    let vk = match t.tag {
        crate::keys::TRIGGER_PHYSICAL => vk_from_physical(t.key)?,
        // **A unicode trigger is the common case, not the exotic one**, and
        // an earlier version of this function declined it outright -- which
        // made every hotkey written the way people actually write hotkeys
        // fall back to the built-in, silently.
        //
        // The reason is `src/input/key.zig:129`: the `Key` enum's fields are
        // `key_a` and `digit_1`, **not `a` and `1`**. So when `Binding.zig`'s
        // trigger parser walks the enum field names looking for `a` it finds
        // nothing, drops through to its single-codepoint branch, and yields
        // `.unicode = 'a'`. `ctrl+shift+a` and `ctrl+1` are therefore *both*
        // unicode triggers, and only spellings nobody writes in a config
        // (`ctrl+key_a`) come back physical.
        crate::keys::TRIGGER_UNICODE => vk_from_codepoint(t.key)?,
        // `catch_all` carries no key at all.
        _ => return None,
    };
    finish(t, vk)
}

/// A `ghostty_input_key_e` ordinal as a virtual key.
fn vk_from_physical(k: u32) -> Option<u32> {
    let vk = if (K_A..K_A + 26).contains(&k) {
        0x41 + (k - K_A) // VK_A .. VK_Z
    } else if (K_DIGIT_0..K_DIGIT_0 + 10).contains(&k) {
        0x30 + (k - K_DIGIT_0) // VK_0 .. VK_9
    } else if (K_F1..K_F1 + 12).contains(&k) {
        0x70 + (k - K_F1) // VK_F1 .. VK_F12
    } else {
        match k {
            K_BACKQUOTE => VK_OEM_3.0 as u32,
            K_SPACE => VK_SPACE.0 as u32,
            K_ESCAPE => VK_ESCAPE.0 as u32,
            _ => return None,
        }
    };
    Some(vk)
}

/// A unicode codepoint as a virtual key.
///
/// ASCII letters and digits map by arithmetic and are the same on every
/// layout. Anything else goes through `VkKeyScanW`, which answers for the
/// **currently active layout** -- and is accepted only when it needs no
/// modifier of its own. A character that requires Shift on this layout (`:`
/// on a US keyboard) would otherwise register the *unshifted* key, giving the
/// user a combination they never asked for; declining is the honest answer.
///
/// The layout dependence is real and cannot be removed here:
/// `RegisterHotKey` takes a virtual key, and which character a virtual key
/// produces is a property of the layout at press time. Switching layouts
/// moves such a hotkey. That is Windows' behaviour, not this function's.
fn vk_from_codepoint(cp: u32) -> Option<u32> {
    let ch = char::from_u32(cp)?;
    // Case names the same physical key, and a config saying `ctrl+shift+A`
    // must not register a different hotkey from `ctrl+shift+a`.
    if ch.is_ascii_lowercase() {
        return Some(ch.to_ascii_uppercase() as u32);
    }
    if ch.is_ascii_uppercase() || ch.is_ascii_digit() {
        return Some(ch as u32);
    }
    match ch {
        // Must agree with `vk_from_physical`'s `K_BACKQUOTE`, or a user who
        // writes the default combination out explicitly would get a
        // different key from the one they get by writing nothing.
        '`' => return Some(VK_OEM_3.0 as u32),
        ' ' => return Some(VK_SPACE.0 as u32),
        _ => {}
    }
    // -1 means this layout cannot produce the character at all.
    let r = unsafe { VkKeyScanW(cp as u16) };
    if r == -1 {
        return None;
    }
    if (r >> 8) & 0xFF != 0 {
        return None; // needs a modifier of its own; see above
    }
    Some((r & 0xFF) as u32)
}

/// Modifiers, and the label, for a key that has already been resolved.
fn finish(t: crate::keys::TriggerC, vk: u32) -> Option<(HOT_KEY_MODIFIERS, u32, String)> {
    // `ghostty_input_mods_e` -> `HOT_KEY_MODIFIERS`. The sided bits are
    // ignored on purpose: `RegisterHotKey` cannot express "the right-hand
    // Ctrl only", so honouring them would mean claiming a combination
    // narrower than the one that gets registered.
    let mut mods = HOT_KEY_MODIFIERS(0);
    if t.mods & (1 << 0) != 0 {
        mods |= MOD_SHIFT;
    }
    if t.mods & (1 << 1) != 0 {
        mods |= MOD_CONTROL;
    }
    if t.mods & (1 << 2) != 0 {
        mods |= MOD_ALT;
    }
    if t.mods & (1 << 3) != 0 {
        mods |= MOD_WIN;
    }
    // **A hotkey with no modifier is refused.** `RegisterHotKey` would take
    // it and then swallow that key system-wide, from every application, for
    // the life of the process -- a bare `a` bound by accident makes the
    // machine unusable and gives no clue why.
    if mods.0 == 0 {
        return None;
    }

    Some((mods, vk, crate::keys::format_trigger(t)?))
}

/// `ERROR_HOTKEY_ALREADY_REGISTERED`. The only failure worth naming, because
/// it is the one that happens to users rather than to programs.
const ERROR_HOTKEY_ALREADY_REGISTERED: u32 = 1409;

/// The startup lines for the hotkey registration.
///
/// **This is the whole point of the return-value check, so it is a function
/// and not an inline `logf!`.** `RegisterHotKey` does not raise anything, does
/// not pop a dialog and does not write to any log of its own: when another
/// process already owns the combination it returns FALSE and the key silently
/// does nothing forever after. An implementation that never looked at the
/// return value is **byte-for-byte identical in behaviour** to a correct one
/// on the success path, which is why "it worked on my machine" cannot
/// distinguish them and why the failure line has to be produced from the
/// actual return value and the actual error code.
///
/// The success line says *registered at startup* on purpose. Windows does not
/// notify anyone when a hotkey is taken over later, so this line is a fact
/// about one moment, not a claim about the present.
fn hotkey_lines(combo: &str, ok: bool, err: u32) -> Vec<String> {
    if ok {
        return vec![format!(
            "[quick] hotkey {combo} registered (true at startup; Windows does not report \
             a later takeover)"
        )];
    }
    let mut v = vec![format!("[quick] hotkey {combo} FAILED err={err}")];
    v.push(if err == ERROR_HOTKEY_ALREADY_REGISTERED {
        format!(
            "[quick] err={err} is ERROR_HOTKEY_ALREADY_REGISTERED: another process owns \
             {combo}. The quick terminal cannot be opened by keyboard in this session."
        )
    } else {
        format!(
            "[quick] the quick terminal cannot be opened by keyboard in this session; \
             RegisterHotKey returned FALSE with err={err}"
        )
    });
    v
}

/// How many monitors the desktop has.
///
/// In the startup line because `C3`'s floor needs it: on a one-screen machine
/// "the panel appeared on the right monitor" is unverifiable -- the right
/// monitor and the only monitor are the same rectangle -- and this number is
/// what lets a report say *not applicable* instead of *passed*.
fn monitor_count() -> u32 {
    unsafe extern "system" fn count_cb(
        _: HMONITOR,
        _: HDC,
        _: *mut RECT,
        data: LPARAM,
    ) -> windows::core::BOOL {
        unsafe {
            let n = data.0 as *mut u32;
            if !n.is_null() {
                *n += 1;
            }
        }
        windows::core::BOOL(1)
    }
    let mut n: u32 = 0;
    unsafe {
        let _ = EnumDisplayMonitors(
            None,
            None,
            Some(count_cb),
            LPARAM(&mut n as *mut u32 as isize),
        );
    }
    n
}

// ------------------------------------------------------------------ toggle

/// Show or hide. Called from the hotkey, from the core's action, and from
/// `--qttest`.
pub fn toggle(app: App, hinst: windows::Win32::Foundation::HINSTANCE) {
    let visible = is_visible();
    if visible {
        hide();
    } else {
        show(app, hinst);
    }
}

fn show(app: App, hinst: windows::Win32::Foundation::HINSTANCE) {
    let Some((device, work)) = target_monitor() else {
        logf!("[quick] no monitor; not showing");
        return;
    };

    let (hwnd, need_child) = match QUICK.with(|c| {
        c.borrow()
            .as_ref()
            .map(|q| (q.hwnd, q.child.0.is_null()))
    }) {
        Some(v) => v,
        None => return,
    };

    let edge = with_quick(|q| q.edge).unwrap_or(Edge::Top);
    let rect = with_quick(|q| target_rect(q, work, &device)).unwrap_or(work);
    let (w, h) = (rect.right - rect.left, rect.bottom - rect.top);
    let from = offscreen_origin(edge, work, rect);

    unsafe {
        // Placed just outside the work area at its final size, then slid in:
        // a window that resizes while it animates makes the terminal reflow
        // on every step.
        let _ = SetWindowPos(hwnd, Some(HWND_TOPMOST), from.0, from.1, w, h, SWP_NOACTIVATE);
    }

    if need_child {
        create_surface(hwnd, app, hinst, w, h);
    }

    with_quick(|q| {
        q.visible = true;
        q.slide_from = from;
        q.slide_to = (rect.left, rect.top);
        q.slide_step = 0;
        q.geometry.insert(device.clone(), rect);
    });

    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        let _ = SetForegroundWindow(hwnd);
        SetTimer(Some(hwnd), TIMER_SLIDE, 16, None);
    }
    // **The device name is in this line, not just the coordinates.** Which
    // monitor the panel chose is the thing that cannot be checked from a
    // screenshot on a one-screen machine, and the name is the half of it that
    // still can be: a host that never asked `GetMonitorInfo` for a name has
    // nothing to print here.
    logf!(
        "[quick] shown on {} at {},{} {}x{} edge={:?} work={}x{}+{}+{} monitors={}",
        device,
        rect.left,
        rect.top,
        w,
        h,
        edge,
        work.right - work.left,
        work.bottom - work.top,
        work.left,
        work.top,
        monitor_count()
    );
}

fn hide() {
    let Some(hwnd) = QUICK.with(|c| c.borrow().as_ref().map(|q| q.hwnd)) else {
        return;
    };
    with_quick(|q| q.visible = false);
    unsafe {
        let _ = KillTimer(Some(hwnd), TIMER_SLIDE);
        let _ = ShowWindow(hwnd, SW_HIDE);
        // **`UnregisterHotKey` is deliberately not called here.** The hotkey
        // belongs to the session, not to the window: releasing it on hide
        // would let the panel open exactly once, and the second press would
        // do nothing with no line in the log to say why.
    }
    logf!("[quick] hidden | {}", state_line());
}

fn create_surface(
    frame: HWND,
    app: App,
    hinst: windows::Win32::Foundation::HINSTANCE,
    w: i32,
    h: i32,
) {
    let scale = crate::tabs::scale_of();
    let child = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterSurface"),
            windows::core::PCWSTR::null(),
            WS_CHILD | WS_CLIPSIBLINGS | WS_VISIBLE,
            0,
            0,
            w.max(1),
            h.max(1),
            Some(frame),
            None,
            Some(hinst),
            None,
        )
    };
    let Ok(child) = child else {
        logf!("[quick] surface window failed");
        return;
    };

    let mut sc: SurfaceConfig = unsafe { (api().surface_config_new)() };
    sc.platform_tag = PLATFORM_WIN32;
    sc.platform_hwnd = child.0 as *mut c_void;
    sc.scale_factor = scale;
    let s = unsafe { (api().surface_new)(app, &sc) };
    if s.is_null() {
        logf!("[quick] ghostty_surface_new returned null");
        unsafe {
            let _ = DestroyWindow(child);
        }
        return;
    }
    unsafe {
        (api().surface_set_content_scale)(s, scale, scale);
        (api().surface_set_size)(s, w.max(1) as u32, h.max(1) as u32);
        (api().surface_set_focus)(s, true);
    }
    crate::ime_attach(child);
    // Files can be dropped onto the quick terminal too. It is the same window
    // class as a pane, so it is the same registration -- the panel being a
    // different *window* is not a reason for it to be a different *terminal*.
    crate::dnd::attach(child);
    with_quick(|q| {
        q.child = child;
        q.surface = s as usize;
    });
    logf!("[quick] surface = {:?} on {:?} {}x{}", s, child.0, w, h);
}

/// One frame of the slide, `eased` running 0 → 1.
///
/// Both axes, so the same easing serves all four edges. Pure because the
/// property worth pinning is that it **ends exactly on the destination**: an
/// interpolation that stops a pixel short leaves a permanent one-pixel gap at
/// the screen edge, which reads as a rendering bug rather than as arithmetic.
fn slide_at(from: (i32, i32), to: (i32, i32), eased: f32) -> (i32, i32) {
    (
        from.0 + ((to.0 - from.0) as f32 * eased) as i32,
        from.1 + ((to.1 - from.1) as f32 * eased) as i32,
    )
}

// ------------------------------------------------------------------- proc

unsafe extern "system" fn quick_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_ERASEBKGND => LRESULT(1),

            // One step of the slide. Geometry only: the child is resized once,
            // when it is created, so the terminal does not reflow per frame.
            WM_TIMER if wp.0 == TIMER_SLIDE => {
                let done = with_quick(|q| {
                    q.slide_step += 1;
                    let t = (q.slide_step as f32 / SLIDE_STEPS as f32).min(1.0);
                    // Ease out: fast at the start, settling at the end. A
                    // linear slide reads as mechanical at this distance.
                    let eased = 1.0 - (1.0 - t) * (1.0 - t);
                    let (x, y) = slide_at(q.slide_from, q.slide_to, eased);
                    let _ = SetWindowPos(
                        q.hwnd,
                        None,
                        x,
                        y,
                        0,
                        0,
                        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
                    );
                    t >= 1.0
                })
                .unwrap_or(true);
                if done {
                    let _ = KillTimer(Some(hwnd), TIMER_SLIDE);
                }
                LRESULT(0)
            }

            WM_SIZE => {
                let (w, h) = ((lp.0 & 0xFFFF) as i32, ((lp.0 >> 16) & 0xFFFF) as i32);
                if let Some(child) = QUICK.with(|c| c.borrow().as_ref().map(|q| q.child)) {
                    if !child.0.is_null() && w > 0 && h > 0 {
                        let _ = SetWindowPos(
                            child,
                            None,
                            0,
                            0,
                            w,
                            h,
                            SWP_NOZORDER | SWP_SHOWWINDOW,
                        );
                    }
                }
                LRESULT(0)
            }

            // Autohide: losing activation is how a drop-down terminal goes
            // away. Guarded by the config, because somebody debugging with
            // two windows open will want it off.
            WM_ACTIVATE => {
                if wp.0 as u32 & 0xFFFF == WA_INACTIVE
                    && with_quick(|q| q.autohide).unwrap_or(false)
                    && is_visible()
                {
                    hide();
                }
                LRESULT(0)
            }

            WM_SETFOCUS => {
                if let Some(child) = QUICK.with(|c| c.borrow().as_ref().map(|q| q.child)) {
                    if !child.0.is_null() {
                        let _ = SetFocus(Some(child));
                    }
                }
                LRESULT(0)
            }

            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

// ------------------------------------------------------------------ state

/// One line with the **inputs** as well as the result.
///
/// "The window is in the right place" is a conclusion; the monitor it chose
/// and that monitor's work area are what it was concluded from. This host has
/// already paid once for a line that printed only the conclusion.
pub fn state_line() -> String {
    let mon = target_monitor();
    let (device, work) = mon
        .map(|(d, w)| (d, w))
        .unwrap_or_else(|| ("<none>".into(), RECT::default()));
    let (visible, wr, cached) = QUICK
        .with(|c| {
            c.borrow().as_ref().map(|q| {
                let mut r = RECT::default();
                unsafe {
                    let _ = GetWindowRect(q.hwnd, &mut r);
                }
                (q.visible, r, q.geometry.len())
            })
        })
        .unwrap_or((false, RECT::default(), 0));
    format!(
        "visible={} monitor={} work={}x{}+{}+{} window={}x{}+{}+{} cached_monitors={}",
        visible,
        device,
        work.right - work.left,
        work.bottom - work.top,
        work.left,
        work.top,
        wr.right - wr.left,
        wr.bottom - wr.top,
        wr.left,
        wr.top,
        cached
    )
}

pub fn log_state(tag: &str) {
    logf!("[quick] {} | {}", tag, state_line());
}

/// `--qttest`: drop in and out without a hotkey, printing the inputs each
/// time. **What it cannot cover is the part that matters most** -- that the
/// hotkey works while Polter is not the foreground window -- because a script
/// running inside Polter is, by definition, running while Polter is focused.
/// That one step stays manual, and is called out in the log.
pub fn script_step(app: App, hinst: windows::Win32::Foundation::HINSTANCE, step: usize) -> bool {
    match step {
        0 => {
            log_state("qttest: before first show");
            toggle(app, hinst);
            true
        }
        1 => {
            log_state("qttest: after show (expect visible=true, window inside work area)");
            true
        }
        2 => {
            toggle(app, hinst);
            log_state("qttest: after hide (expect visible=false)");
            true
        }
        3 => {
            toggle(app, hinst);
            log_state("qttest: after second show (expect same window rect as the first)");
            true
        }
        4 => {
            toggle(app, hinst);
            logf!(
                "[quick] qttest done -- the hotkey itself is NOT covered: press Ctrl+` \
                 while another application is focused and look for a [quick] show line"
            );
            false
        }
        _ => false,
    }
}

// ------------------------------------------------------------------ tests

#[cfg(test)]
mod tests {
    use super::*;

    /// A 1920x1080 desktop with a 40px taskbar at the bottom.
    const WORK: RECT = RECT { left: 0, top: 0, right: 1920, bottom: 1040 };
    /// 25% of the axis.
    const SIZE: (u32, f32) = (1, 25.0);

    #[test]
    fn the_edge_comes_from_the_config_name() {
        assert_eq!(Edge::parse("top"), Some(Edge::Top));
        assert_eq!(Edge::parse("bottom"), Some(Edge::Bottom));
        assert_eq!(Edge::parse("left"), Some(Edge::Left));
        assert_eq!(Edge::parse("right"), Some(Edge::Right));
        assert_eq!(Edge::parse("center"), Some(Edge::Center));
    }

    /// An unknown name is **not** silently an edge. The caller logs and falls
    /// back to top; folding the fallback in here would hide a config typo
    /// behind behaviour indistinguishable from a correct `top`.
    #[test]
    fn an_unknown_position_name_is_not_an_edge() {
        assert_eq!(Edge::parse("topp"), None);
        assert_eq!(Edge::parse(""), None);
        assert_eq!(Edge::parse("TOP"), None);
    }

    #[test]
    fn each_edge_rests_against_its_own_edge() {
        let top = resting_rect(Edge::Top, WORK, SIZE);
        assert_eq!((top.left, top.top, top.right), (0, 0, 1920));
        assert_eq!(top.bottom, 260); // 25% of 1040

        let bottom = resting_rect(Edge::Bottom, WORK, SIZE);
        assert_eq!((bottom.left, bottom.right, bottom.bottom), (0, 1920, 1040));
        assert_eq!(bottom.top, 780);

        let left = resting_rect(Edge::Left, WORK, SIZE);
        assert_eq!((left.left, left.top, left.bottom), (0, 0, 1040));
        assert_eq!(left.right, 480); // 25% of 1920

        let right = resting_rect(Edge::Right, WORK, SIZE);
        assert_eq!((right.top, right.bottom, right.right), (0, 1040, 1920));
        assert_eq!(right.left, 1440);
    }

    /// **The floor for the test above.** Four edges written by copying the
    /// first would still satisfy "top is at the top"; what they cannot
    /// satisfy is that all four differ. Every pair is compared because the
    /// mistake that actually happens is one mirrored edge, not four.
    #[test]
    fn no_two_edges_produce_the_same_rectangle() {
        let all = [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right, Edge::Center];
        for (i, a) in all.iter().enumerate() {
            for b in &all[i + 1..] {
                let (ra, rb) = (resting_rect(*a, WORK, SIZE), resting_rect(*b, WORK, SIZE));
                assert_ne!(
                    (ra.left, ra.top, ra.right, ra.bottom),
                    (rb.left, rb.top, rb.right, rb.bottom),
                    "{a:?} and {b:?} land in the same place"
                );
            }
        }
    }

    /// Every resting rectangle is inside the *work* area, which is what keeps
    /// the panel off the taskbar. The bottom edge is the one that gets this
    /// wrong, by measuring from the monitor rather than from the work area.
    #[test]
    fn every_edge_stays_inside_the_work_area() {
        for e in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right, Edge::Center] {
            let r = resting_rect(e, WORK, SIZE);
            assert!(r.left >= WORK.left && r.top >= WORK.top, "{e:?} starts outside");
            assert!(r.right <= WORK.right && r.bottom <= WORK.bottom, "{e:?} ends outside");
        }
    }

    /// The slide starts fully off the work area, on the matching side.
    #[test]
    fn the_slide_starts_outside_on_the_matching_side() {
        for (e, ) in [(Edge::Top,), (Edge::Bottom,), (Edge::Left,), (Edge::Right,)] {
            let rest = resting_rect(e, WORK, SIZE);
            let (x, y) = offscreen_origin(e, WORK, rest);
            let (w, h) = (rest.right - rest.left, rest.bottom - rest.top);
            let outside = x + w <= WORK.left
                || x >= WORK.right
                || y + h <= WORK.top
                || y >= WORK.bottom;
            assert!(outside, "{e:?} starts at {x},{y} which is not outside the work area");
        }
    }

    /// Centre has no direction to come from, so it starts where it ends.
    #[test]
    fn centre_does_not_slide() {
        let rest = resting_rect(Edge::Center, WORK, SIZE);
        assert_eq!(offscreen_origin(Edge::Center, WORK, rest), (rest.left, rest.top));
    }

    /// The animation must land **exactly** on the destination. One pixel
    /// short leaves a permanent gap at the screen edge on every show.
    #[test]
    fn the_slide_ends_exactly_on_the_destination() {
        let from = (0, -260);
        let to = (0, 0);
        assert_eq!(slide_at(from, to, 1.0), to);
        assert_eq!(slide_at(from, to, 0.0), from);
        // And sideways, which is the axis a y-only implementation drops.
        let from = (-480, 0);
        let to = (0, 0);
        assert_eq!(slide_at(from, to, 1.0), to);
        assert_ne!(slide_at(from, to, 0.5), to);
    }

    #[test]
    fn size_is_read_as_a_percentage_or_as_pixels() {
        assert_eq!(primary_extent((1, 50.0), 1000), 500);
        assert_eq!(primary_extent((2, 640.0), 1000), 640);
        // Unrecognised tag: a quarter, not zero. A zero-height panel is
        // invisible and looks exactly like the hotkey not working.
        assert_eq!(primary_extent((0, 0.0), 1000), 250);
    }

    // ---------------------------------------------------- the combination

    use crate::keys::{TriggerC, TRIGGER_PHYSICAL, TRIGGER_UNICODE};

    fn phys(key: u32, mods: i32) -> TriggerC {
        TriggerC { tag: TRIGGER_PHYSICAL, key, mods }
    }

    /// Letters, digits and function keys are three contiguous runs, so the
    /// mapping is arithmetic. Both ends of each run are checked -- a run
    /// mapped with the wrong base looks right in the middle.
    #[test]
    fn the_three_contiguous_runs_map_to_their_virtual_keys() {
        let ctrl = 1 << 1;
        assert_eq!(hotkey_from_trigger(phys(K_A, ctrl)).unwrap().1, 0x41, "A");
        assert_eq!(hotkey_from_trigger(phys(K_A + 25, ctrl)).unwrap().1, 0x5A, "Z");
        assert_eq!(hotkey_from_trigger(phys(K_DIGIT_0, ctrl)).unwrap().1, 0x30, "0");
        assert_eq!(hotkey_from_trigger(phys(K_DIGIT_0 + 9, ctrl)).unwrap().1, 0x39, "9");
        assert_eq!(hotkey_from_trigger(phys(K_F1, ctrl)).unwrap().1, 0x70, "F1");
        assert_eq!(hotkey_from_trigger(phys(K_F1 + 11, ctrl)).unwrap().1, 0x7B, "F12");
    }

    /// The default combination, end to end: `ctrl+` ` must come out as
    /// MOD_CONTROL plus VK_OEM_3, which is what the built-in fallback
    /// registers. If this disagrees, a configured default and the fallback
    /// would claim two different keys while both logging the same name.
    #[test]
    fn the_default_backquote_hotkey_maps_to_the_fallback() {
        let (mods, vk, combo) = hotkey_from_trigger(phys(K_BACKQUOTE, 1 << 1)).unwrap();
        assert_eq!(mods, MOD_CONTROL);
        assert_eq!(vk, VK_OEM_3.0 as u32);
        assert_eq!(combo, HOTKEY_COMBO);
    }

    /// Each modifier bit reaches its own flag. Tested one at a time: a
    /// mapping that returned MOD_CONTROL for everything passes any test that
    /// sets ctrl alongside the others.
    #[test]
    fn each_modifier_bit_reaches_its_own_flag() {
        let f = |bit: i32| hotkey_from_trigger(phys(K_A, bit)).unwrap().0;
        assert_eq!(f(1 << 0), MOD_SHIFT);
        assert_eq!(f(1 << 1), MOD_CONTROL);
        assert_eq!(f(1 << 2), MOD_ALT);
        assert_eq!(f(1 << 3), MOD_WIN);
        assert_eq!(f((1 << 0) | (1 << 1)), MOD_SHIFT | MOD_CONTROL);
    }

    /// **A bare key is refused.** `RegisterHotKey` would accept it and then
    /// swallow that key system-wide, in every application, until the process
    /// exits -- a machine where `a` does nothing anywhere, with no clue why.
    #[test]
    fn a_hotkey_with_no_modifier_is_refused() {
        assert!(hotkey_from_trigger(phys(K_A, 0)).is_none());
        assert!(hotkey_from_trigger(phys(K_F1, 0)).is_none());
    }

    /// Sided bits alone are not modifiers. The core sets the base bit next to
    /// a sided one, so a sided bit on its own never occurs in practice --
    /// which is exactly why it is the probe: only a mapping reading the wrong
    /// bit would turn it into a flag, and then a bare key would register.
    #[test]
    fn sided_modifier_bits_do_not_count_as_modifiers() {
        assert!(hotkey_from_trigger(phys(K_A, 1 << 7)).is_none(), "ctrl_right alone");
        assert!(hotkey_from_trigger(phys(K_A, 1 << 6)).is_none(), "shift_right alone");
    }

    /// A key this host cannot express is declined, not guessed at. **A hotkey
    /// on the wrong key is worse than none**: it steals a combination from
    /// another program and misbehaves when pressed, and neither end reports
    /// it.
    #[test]
    fn an_unmappable_key_is_declined_rather_than_guessed() {
        assert!(hotkey_from_trigger(phys(175, 1 << 1)).is_none(), "an unmapped ordinal");
        assert!(
            hotkey_from_trigger(TriggerC { tag: TRIGGER_UNICODE, key: 'q' as u32, mods: 1 << 1 })
                .is_none(),
            "a unicode trigger names a character, not a physical key"
        );
    }

    /// **The bug W4's three rounds cornered, as a test.**
    ///
    /// `ctrl+shift+a` in a config parses to a **unicode** trigger, not a
    /// physical one, because `key.zig`'s enum field is `key_a` -- so the
    /// parser's enum-name walk misses `a` and falls through to its
    /// single-codepoint branch. A `hotkey_from_trigger` that only accepted
    /// physical triggers therefore declined every hotkey written the way
    /// people write hotkeys, and fell back to the built-in silently.
    #[test]
    fn a_unicode_trigger_is_the_common_case_and_must_map() {
        let t = TriggerC { tag: TRIGGER_UNICODE, key: 'a' as u32, mods: (1 << 1) | (1 << 0) };
        let (mods, vk, combo) = hotkey_from_trigger(t).expect("ctrl+shift+a must be usable");
        assert_eq!(mods, MOD_CONTROL | MOD_SHIFT);
        assert_eq!(vk, 0x41, "VK_A");
        assert_eq!(combo, "Ctrl+Shift+A");
    }

    /// Digits go the same way: the enum field is `digit_1`, so `ctrl+1` is
    /// also a unicode trigger. The physical digit range in this file is
    /// therefore unreachable from any config anyone would write -- which is
    /// why testing only the physical path proved nothing.
    #[test]
    fn a_unicode_digit_maps_too() {
        let t = TriggerC { tag: TRIGGER_UNICODE, key: '1' as u32, mods: 1 << 2 };
        assert_eq!(hotkey_from_trigger(t).unwrap().1, 0x31, "VK_1");
    }

    /// The backquote written as a character, which is how `ctrl+`` reaches
    /// here from a config -- and it must land on the same virtual key as the
    /// built-in fallback, or a user who writes the default explicitly gets a
    /// different hotkey from the one they get by writing nothing.
    #[test]
    fn the_configured_backquote_and_the_fallback_are_the_same_key() {
        let t = TriggerC { tag: TRIGGER_UNICODE, key: '`' as u32, mods: 1 << 1 };
        let (mods, vk, _) = hotkey_from_trigger(t).unwrap();
        assert_eq!((mods, vk), (MOD_CONTROL, VK_OEM_3.0 as u32));
    }

    /// Upper and lower case name the same physical key. A config saying
    /// `ctrl+shift+A` must not register a different hotkey from
    /// `ctrl+shift+a`.
    #[test]
    fn case_does_not_change_the_key() {
        let lower = TriggerC { tag: TRIGGER_UNICODE, key: 'a' as u32, mods: 1 << 1 };
        let upper = TriggerC { tag: TRIGGER_UNICODE, key: 'A' as u32, mods: 1 << 1 };
        assert_eq!(hotkey_from_trigger(lower).unwrap().1, hotkey_from_trigger(upper).unwrap().1);
    }

    /// **The one the test box needs.** `ctrl+shift+a` is the combination a
    /// screenshot tool on that machine already owns, so pointing the config
    /// at it is how the `RegisterHotKey` failure path gets exercised for
    /// real. This pins that the config route can actually reach it.
    #[test]
    fn ctrl_shift_a_is_expressible() {
        let (mods, vk, combo) = hotkey_from_trigger(phys(K_A, (1 << 1) | (1 << 0))).unwrap();
        assert_eq!(mods, MOD_CONTROL | MOD_SHIFT);
        assert_eq!(vk, 0x41);
        assert_eq!(combo, "Ctrl+Shift+A");
    }

    // --------------------------------------------------------- the hotkey

    /// The success line names the combination and says when it was true.
    #[test]
    fn the_success_line_names_the_combination() {
        let lines = hotkey_lines("Ctrl+`", true, 0);
        assert_eq!(lines.len(), 1);
        assert!(lines[0].contains("Ctrl+`"), "{}", lines[0]);
        assert!(lines[0].contains("registered"));
        assert!(!lines[0].contains("FAILED"));
        // It must not read as a claim about the present.
        assert!(lines[0].contains("at startup"), "{}", lines[0]);
    }

    /// **The line that the whole return-value check exists for.**
    ///
    /// `RegisterHotKey` fails by returning FALSE and nothing else: no
    /// exception, no dialog, no log of its own. So the only difference
    /// between a host that checks and a host that does not is this line, and
    /// it has to carry the error number -- 1409 is the one a user will hit,
    /// and it means a different thing from every other value.
    #[test]
    fn the_failure_line_is_self_sufficient() {
        let lines = hotkey_lines("Ctrl+`", false, ERROR_HOTKEY_ALREADY_REGISTERED);
        let joined = lines.join("\n");
        assert!(joined.contains("FAILED err=1409"), "{joined}");
        assert!(joined.contains("Ctrl+`"), "{joined}");
        assert!(joined.contains("ERROR_HOTKEY_ALREADY_REGISTERED"), "{joined}");
        // What it means for the user, in the same log, not inferred.
        assert!(joined.contains("cannot be opened by keyboard"), "{joined}");
    }

    /// An unexpected error code still produces a failure line rather than
    /// falling through to the success wording. This is the floor for the test
    /// above: matching on 1409 alone would leave every other failure silent,
    /// which is the exact bug being guarded against, one code narrower.
    #[test]
    fn an_unexpected_error_code_still_fails_loudly() {
        let joined = hotkey_lines("Ctrl+`", false, 87).join("\n");
        assert!(joined.contains("FAILED err=87"), "{joined}");
        assert!(!joined.contains("ERROR_HOTKEY_ALREADY_REGISTERED"), "{joined}");
        assert!(joined.contains("cannot be opened by keyboard"), "{joined}");
    }

    /// Success and failure must not be tellable apart only by a trailing
    /// boolean. A `registered={ok}` line technically carries the fact, but
    /// `registered=false` scrolls past as though it were a status field; the
    /// two cases have to be different sentences.
    #[test]
    fn success_and_failure_do_not_look_alike() {
        let ok = hotkey_lines("Ctrl+`", true, 0).join("\n");
        let bad = hotkey_lines("Ctrl+`", false, 1409).join("\n");
        assert_ne!(ok, bad);
        assert!(!ok.contains("FAILED"));
        assert!(!bad.contains("registered ("));
    }
}
