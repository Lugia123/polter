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
//! **Position and screen come from defaults, not from the config.** The core
//! exposes `quick-terminal-size`, `-autohide` and `-animation-duration`
//! through `ghostty_config_get` because those have C representations;
//! `quick-terminal-position` and `-screen` are Zig enums with no entry in
//! `include/ghostty.h`, so there is nothing to read. Top edge and the monitor
//! under the pointer are what this does until that changes -- written down
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
    /// Where the window is going, and where it is now, during a slide.
    slide_to: i32,
    slide_from: i32,
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

/// The window rectangle for this drop, honouring the cache.
fn target_rect(q: &Quick, work: RECT, device: &str) -> RECT {
    if let Some(prev) = q.geometry.get(device) {
        return *prev;
    }
    let w = work.right - work.left;
    let full_h = work.bottom - work.top;
    let h = match q.size_primary {
        // GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE
        (1, v) => ((full_h as f32) * (v / 100.0)) as i32,
        // GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS
        (2, v) => v as i32,
        // NONE, or anything unrecognised: a quarter of the screen.
        _ => full_h / 4,
    }
    .clamp(100, full_h);
    RECT {
        left: work.left,
        top: work.top,
        right: work.left + w,
        bottom: work.top + h,
    }
}

// -------------------------------------------------------------------- init

fn read_config(config: Config) -> (bool, (u32, f32)) {
    use windows::core::s;
    use windows::Win32::System::LibraryLoader::{GetModuleHandleA, GetProcAddress};
    let mut autohide = true;
    let mut size = (1u32, 25.0f32);
    unsafe {
        let Ok(m) = GetModuleHandleA(s!("ghostty-internal.dll")) else {
            return (autohide, size);
        };
        let Some(p) = GetProcAddress(m, s!("ghostty_config_get")) else {
            logf!("[quick] ghostty_config_get not exported; using defaults");
            return (autohide, size);
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
    }
    (autohide, size)
}

/// Create the window (hidden) and claim the hotkey.
pub fn init(hinst: windows::Win32::Foundation::HINSTANCE, config: Config, owner: HWND) {
    let (autohide, size_primary) = read_config(config);

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
                slide_to: 0,
                slide_from: 0,
                slide_step: 0,
                geometry: HashMap::new(),
                autohide,
                size_primary,
            })
        });

        // **The hotkey, and the one line that says whether it exists.**
        // `RegisterHotKey` fails when another process already owns the
        // combination, and it fails by returning false -- after which the key
        // does nothing at all and looks, from the user's side, exactly like a
        // key they did not press hard enough.
        let ok = RegisterHotKey(
            Some(owner),
            HOTKEY_ID,
            MOD_CONTROL | MOD_NOREPEAT,
            VK_OEM_3.0 as u32,
        )
        .is_ok();
        logf!(
            "[quick] window ready; hotkey Ctrl+` registered={} autohide={} size={:?}",
            ok,
            autohide,
            size_primary
        );
        if !ok {
            logf!("[quick] the hotkey is owned by another process; it will do nothing");
        }
    }
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

    let rect = with_quick(|q| target_rect(q, work, &device)).unwrap_or(work);
    let (w, h) = (rect.right - rect.left, rect.bottom - rect.top);

    unsafe {
        // Placed above the work area and slid down, so the first frame is
        // already the right size: a window that resizes while it animates
        // makes the terminal reflow on every step.
        let _ = SetWindowPos(
            hwnd,
            Some(HWND_TOPMOST),
            rect.left,
            work.top - h,
            w,
            h,
            SWP_NOACTIVATE,
        );
    }

    if need_child {
        create_surface(hwnd, app, hinst, w, h);
    }

    with_quick(|q| {
        q.visible = true;
        q.slide_from = work.top - h;
        q.slide_to = rect.top;
        q.slide_step = 0;
        q.geometry.insert(device.clone(), rect);
    });

    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        let _ = SetForegroundWindow(hwnd);
        SetTimer(Some(hwnd), TIMER_SLIDE, 16, None);
    }
    log_state("show");
}

fn hide() {
    let Some(hwnd) = QUICK.with(|c| c.borrow().as_ref().map(|q| q.hwnd)) else {
        return;
    };
    with_quick(|q| q.visible = false);
    unsafe {
        let _ = KillTimer(Some(hwnd), TIMER_SLIDE);
        let _ = ShowWindow(hwnd, SW_HIDE);
    }
    log_state("hide");
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
    with_quick(|q| {
        q.child = child;
        q.surface = s as usize;
    });
    logf!("[quick] surface = {:?} on {:?} {}x{}", s, child.0, w, h);
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
                    let y = q.slide_from + ((q.slide_to - q.slide_from) as f32 * eased) as i32;
                    let _ = SetWindowPos(
                        q.hwnd,
                        None,
                        0,
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
