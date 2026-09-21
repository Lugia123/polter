//! The terminal inspector's own window (task 648, C).
//!
//! **Why its own `HWND` and not a repaint of the pane it is inspecting.**
//! `tabs.rs`'s opening comment states the fact this follows: a libghostty
//! surface is bound to one `HWND` for its whole life
//! (`ghostty_surface_config_s.platform.win32.hwnd`), and `wgl.zig` takes a
//! `CS_OWNDC` device context for that window and keeps it until the GL
//! context is destroyed. A tab is a second `HWND` for exactly that reason;
//! the inspector is a third one, for the same reason a second window cannot
//! share the first window's device context.
//!
//! **Why its own WGL context, never the renderer thread's.** `main.rs`'s
//! `DRAW_ON_PAINT` doc comment says the renderer thread owns the surface's
//! WGL context, so a main-thread draw would have no context current. The
//! inspector runs on the main thread (its `HWND`'s messages arrive there),
//! so it needs a context of its own -- created, made current, and destroyed
//! entirely by this module, never touching `wgl.zig`'s.
//!
//! `ghostty_inspector_opengl_render` does not clear the framebuffer itself
//! (see `src/apprt/embedded.zig`'s `renderOpenGL`, which leaves that to the
//! caller). This module is the caller, and `paint` below does it.

use std::ffi::c_void;
use std::sync::Mutex;

use windows::core::w;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{GetDC, InvalidateRect, ReleaseDC, ValidateRect, HDC};
use windows::Win32::Graphics::OpenGL::{
    wglCreateContext, wglDeleteContext, wglGetProcAddress, wglMakeCurrent, ChoosePixelFormat,
    SetPixelFormat, SwapBuffers, HGLRC, PFD_DOUBLEBUFFER, PFD_DRAW_TO_WINDOW, PFD_MAIN_PLANE,
    PFD_SUPPORT_OPENGL, PFD_TYPE_RGBA, PIXELFORMATDESCRIPTOR,
};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SetFocus, VIRTUAL_KEY, VK_BACK, VK_CONTROL, VK_DELETE, VK_DOWN, VK_END, VK_ESCAPE, VK_HOME,
    VK_LCONTROL, VK_LEFT, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_MENU, VK_NEXT, VK_PRIOR, VK_RCONTROL,
    VK_RETURN, VK_RIGHT, VK_RMENU, VK_RSHIFT, VK_RWIN, VK_SHIFT, VK_SPACE, VK_TAB, VK_UP,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::ffi::*;
use crate::{api, hlogf};

/// Posted to a frame when the inspector op queue has something in it.
/// Private to the `PolterInspector` class's owner, same as every other
/// `WM_APP + N` in this host (see `mouse.rs`'s doc comment on why reuse
/// across classes is not a collision).
pub const WM_POLTER_INSPECTOR_OP: u32 = WM_APP + 30;

struct Win {
    hwnd: HWND,
    hdc: HDC,
    hglrc: HGLRC,
    /// `ghostty_surface_t`, as a `usize` because raw pointers aren't `Send`
    /// and this lives behind a `Mutex`. Not dereferenced except by handing
    /// it straight back to the C API on the thread that owns the window.
    surface: usize,
    inspector: usize,
    gl_ready: bool,
}

// SAFETY: every field is either an opaque OS/FFI handle (valid from any
// thread by Win32/WGL contract, so long as WGL calls stay on the thread that
// holds it current -- which is this window's own thread, enforced by the
// fact that only its own `wndproc` and `apply` ever touch `hglrc`) or a
// `usize` copy of a pointer this module never dereferences off that thread.
unsafe impl Send for Win {}

static WINS: Mutex<Vec<Win>> = Mutex::new(Vec::new());

enum Op {
    SetMode { owner: HWND, surface: usize, mode: i32 },
}

// SAFETY: `HWND` is an opaque handle, valid to read from any thread; `apply`
// (the only thing that reads `owner` out of the queue) always runs on the
// window-owning thread regardless of which thread pushed it, the same
// argument `tabs::post_op`'s queue relies on.
unsafe impl Send for Op {}

static QUEUE: Mutex<Vec<Op>> = Mutex::new(Vec::new());

/// Queue `ACTION_INSPECTOR`'s request and wake the owning frame's message
/// loop. Queued rather than done inline for the same reason `tabs::post_op`
/// is: `cb_action` may be called from whichever thread the core is on, and
/// creating or destroying a window off the thread that owns it is undefined
/// in Win32.
pub fn request(owner: HWND, surface: Surface, mode: i32) {
    QUEUE.lock().unwrap().push(Op::SetMode { owner, surface: surface as usize, mode });
    unsafe {
        let _ = PostMessageW(Some(owner), WM_POLTER_INSPECTOR_OP, WPARAM(0), LPARAM(0));
    }
}

/// Drain the queue and apply every op. Called from the frame's `wndproc` on
/// `WM_POLTER_INSPECTOR_OP`, so this always runs on the thread that owns the
/// windows it creates and destroys.
pub fn run_ops(hinst: windows::Win32::Foundation::HINSTANCE) {
    let ops: Vec<Op> = std::mem::take(&mut *QUEUE.lock().unwrap());
    for op in ops {
        match op {
            Op::SetMode { owner, surface, mode } => apply(owner, hinst, surface, mode),
        }
    }
}

fn apply(owner: HWND, hinst: windows::Win32::Foundation::HINSTANCE, surface: usize, mode: i32) {
    let existing = WINS.lock().unwrap().iter().any(|w| w.surface == surface);
    let show = match mode {
        INSPECTOR_SHOW => true,
        INSPECTOR_HIDE => false,
        // INSPECTOR_TOGGLE and anything else: flip what is there now.
        _ => !existing,
    };
    if show {
        if existing {
            if let Some(hwnd) = hwnd_of(surface) {
                unsafe {
                    let _ = ShowWindow(hwnd, SW_SHOW);
                    let _ = SetForegroundWindow(hwnd);
                }
            }
        } else {
            create(owner, hinst, surface);
        }
    } else if existing {
        destroy(surface);
    }
}

fn hwnd_of(surface: usize) -> Option<HWND> {
    WINS.lock().unwrap().iter().find(|w| w.surface == surface).map(|w| w.hwnd)
}

/// `ACTION_RENDER_INSPECTOR`: the core has new frames for an inspector that
/// (by construction -- see `queueInspectorRender` in `embedded.zig`) can only
/// have raised this because an input callback just ran on this window's own
/// thread. Returns whether there was a window to invalidate, so the caller
/// can tell "rendered" from "nothing here to render" rather than claiming
/// both alike.
pub fn request_render(surface: Surface) -> bool {
    match hwnd_of(surface as usize) {
        Some(hwnd) => {
            unsafe {
                let _ = InvalidateRect(Some(hwnd), None, false);
            }
            true
        }
        None => false,
    }
}

/// Create the inspector window, its own WGL context, and the core's
/// inspector object, in that order -- each step needs the one before it.
fn create(owner: HWND, hinst: windows::Win32::Foundation::HINSTANCE, surface: usize) {
    let s = surface as Surface;
    let insp = unsafe { (api().surface_inspector)(s) };
    if insp.is_null() {
        hlogf!(owner, "[inspector] ghostty_surface_inspector returned null; not opening");
        return;
    }

    // An owned top-level window, not a child: it floats over `owner` (hidden
    // and restored with it) but is not clipped to its client area the way a
    // `WS_CHILD` pane is. `CS_OWNDC` because this window keeps its own DC
    // for the life of its GL context, the same reason `PolterSurface` has it.
    let hwnd = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterInspector"),
            w!("Ghostty Inspector"),
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            900,
            700,
            Some(owner),
            None,
            Some(hinst),
            None,
        )
    };
    let hwnd = match hwnd {
        Ok(h) => h,
        Err(e) => {
            hlogf!(owner, "[inspector] CreateWindowExW failed: {:?}", e);
            return;
        }
    };

    let hdc = unsafe { GetDC(Some(hwnd)) };
    if hdc.is_invalid() {
        hlogf!(owner, "[inspector] GetDC failed");
        unsafe {
            let _ = DestroyWindow(hwnd);
        }
        return;
    }

    let hglrc = match create_context(owner, hdc) {
        Some(c) => c,
        None => {
            hlogf!(owner, "[inspector] WGL context creation failed; see the lines above");
            unsafe {
                ReleaseDC(Some(hwnd), hdc);
                let _ = DestroyWindow(hwnd);
            }
            return;
        }
    };

    if unsafe { wglMakeCurrent(hdc, hglrc) }.is_err() {
        hlogf!(owner, "[inspector] wglMakeCurrent failed for the new context");
        unsafe {
            let _ = wglDeleteContext(hglrc);
            ReleaseDC(Some(hwnd), hdc);
            let _ = DestroyWindow(hwnd);
        }
        return;
    }

    let gl_ready = unsafe { (api().inspector_opengl_init)(insp) };
    if !gl_ready {
        hlogf!(owner, "[inspector] ghostty_inspector_opengl_init returned false");
        // Not fatal to the window: leave it open with `gl_ready = false` so
        // `paint` below can say so on screen rather than the window simply
        // not existing, which would look like the open request did nothing.
    }

    let scale = unsafe { GetDpiForWindow(hwnd) }.max(96) as f64 / 96.0;
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut rc) };
    let (w, h) = ((rc.right - rc.left).max(1) as u32, (rc.bottom - rc.top).max(1) as u32);

    unsafe {
        (api().inspector_set_content_scale)(insp, scale, scale);
        (api().inspector_set_size)(insp, w, h);
        (api().inspector_set_focus)(insp, true);
    }

    WINS.lock().unwrap().push(Win { hwnd, hdc, hglrc, surface, inspector: insp as usize, gl_ready });

    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = SetForegroundWindow(hwnd);
        let _ = SetFocus(Some(hwnd));
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
    hlogf!(
        owner,
        "[inspector] opened for surface {:?}: hwnd={:?} {}x{} scale={} gl_ready={}",
        s, hwnd.0, w, h, scale, gl_ready
    );
}

/// Bootstrap-then-attribs, the same two-step `wgl.zig`'s `Context.init` uses
/// (a legacy context exists only to resolve `wglCreateContextAttribsARB`,
/// which is itself an extension and unreachable before some context is
/// current). Falls back to the bootstrap context itself if the driver has no
/// `WGL_ARB_create_context` -- unlike the terminal renderer, dcimgui's
/// OpenGL3 backend does not require a core profile, so an old-style context
/// is a degraded-but-working answer here rather than a refusal.
fn create_context(owner: HWND, hdc: HDC) -> Option<HGLRC> {
    let pfd = PIXELFORMATDESCRIPTOR {
        nSize: std::mem::size_of::<PIXELFORMATDESCRIPTOR>() as u16,
        nVersion: 1,
        dwFlags: PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
        iPixelType: PFD_TYPE_RGBA,
        cColorBits: 32,
        cAlphaBits: 8,
        iLayerType: PFD_MAIN_PLANE.0 as u8,
        ..Default::default()
    };
    let format = unsafe { ChoosePixelFormat(hdc, &pfd) };
    // not-gated: `format == 0` is the failure itself, not a suppressor --
    // the line reports exactly the event its condition names, the same way
    // a window class that would not register does.
    if format == 0 {
        hlogf!(owner, "[inspector] ChoosePixelFormat found no suitable format");
        return None;
    }
    if unsafe { SetPixelFormat(hdc, format, &pfd) }.is_err() {
        hlogf!(owner, "[inspector] SetPixelFormat failed, format={}", format);
        return None;
    }

    let bootstrap = match unsafe { wglCreateContext(hdc) } {
        Ok(c) => c,
        Err(e) => {
            hlogf!(owner, "[inspector] wglCreateContext (bootstrap) failed: {:?}", e);
            return None;
        }
    };
    if unsafe { wglMakeCurrent(hdc, bootstrap) }.is_err() {
        hlogf!(owner, "[inspector] wglMakeCurrent (bootstrap) failed");
        unsafe {
            let _ = wglDeleteContext(bootstrap);
        }
        return None;
    }

    const WGL_CONTEXT_MAJOR_VERSION_ARB: i32 = 0x2091;
    const WGL_CONTEXT_MINOR_VERSION_ARB: i32 = 0x2092;
    const WGL_CONTEXT_PROFILE_MASK_ARB: i32 = 0x9126;
    const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: i32 = 0x00000001;
    // `HGLRC`, not `Option<HGLRC>`: this is the raw WGL extension signature
    // (a null handle on failure, the same convention `wglCreateContext`
    // above uses before the `windows` crate wraps it in a `Result`), and an
    // `Option<HGLRC>` in an `extern "system" fn` type has no FFI-safe layout.
    type CreateContextAttribsArb = unsafe extern "system" fn(HDC, HGLRC, *const i32) -> HGLRC;

    let create_attribs: Option<CreateContextAttribsArb> = unsafe {
        wglGetProcAddress(windows::core::PCSTR(c"wglCreateContextAttribsARB".as_ptr() as _))
            .map(|p| std::mem::transmute(p))
    };

    let result = match create_attribs {
        None => {
            // Degraded, not fatal: leave the bootstrap context current and
            // use it as-is. `ImGui_ImplOpenGL3_Init(null)` picks its GLSL
            // version from `glGetString(GL_VERSION)` at init time, so a
            // pre-3.2 compatibility context still renders, just not core.
            hlogf!(owner, "[inspector] driver has no WGL_ARB_create_context; using the bootstrap context");
            Some(bootstrap)
        }
        Some(create_fn) => {
            let attribs = [
                WGL_CONTEXT_MAJOR_VERSION_ARB, 3,
                WGL_CONTEXT_MINOR_VERSION_ARB, 3,
                WGL_CONTEXT_PROFILE_MASK_ARB, WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
                0,
            ];
            let core = unsafe { create_fn(hdc, HGLRC::default(), attribs.as_ptr()) };
            let core = if core.0.is_null() { None } else { Some(core) };
            unsafe {
                let _ = wglMakeCurrent(HDC::default(), HGLRC::default());
                let _ = wglDeleteContext(bootstrap);
            }
            match core {
                Some(c) => {
                    if unsafe { wglMakeCurrent(hdc, c) }.is_err() {
                        hlogf!(owner, "[inspector] wglMakeCurrent (core 3.3) failed");
                        unsafe {
                            let _ = wglDeleteContext(c);
                        }
                        None
                    } else {
                        Some(c)
                    }
                }
                None => {
                    hlogf!(owner, "[inspector] driver refused an OpenGL 3.3 core profile context");
                    None
                }
            }
        }
    };
    result
}

/// Tear down one inspector window: shut down the OpenGL backend, delete the
/// GL context, deactivate and free the core's inspector object (`shutdown`
/// and `free` are how the screenshot criterion "closed -> the overlay is
/// gone and does not linger" gets satisfied, not just `ShowWindow(SW_HIDE)`),
/// then destroy the window.
fn destroy(surface: usize) {
    let win = {
        let mut wins = WINS.lock().unwrap();
        let Some(idx) = wins.iter().position(|w| w.surface == surface) else { return };
        wins.remove(idx)
    };
    unsafe {
        if win.gl_ready {
            let _ = wglMakeCurrent(win.hdc, win.hglrc);
            (api().inspector_opengl_shutdown)(win.inspector as Inspector);
        }
        let _ = wglMakeCurrent(HDC::default(), HGLRC::default());
        let _ = wglDeleteContext(win.hglrc);
        ReleaseDC(Some(win.hwnd), win.hdc);
        (api().inspector_free)(surface as Surface);
        let _ = DestroyWindow(win.hwnd);
    }
    hlogf!(win.hwnd, "[inspector] closed for surface {:?}", surface as *const c_void);
}

fn find(hwnd: HWND) -> Option<usize> {
    WINS.lock().unwrap().iter().position(|w| w.hwnd == hwnd)
}

fn with_win<R>(hwnd: HWND, f: impl FnOnce(&Win) -> R) -> Option<R> {
    let wins = WINS.lock().unwrap();
    wins.iter().find(|w| w.hwnd == hwnd).map(f)
}

fn paint(hwnd: HWND) {
    let Some((hdc, hglrc, insp, gl_ready)) =
        with_win(hwnd, |w| (w.hdc, w.hglrc, w.inspector, w.gl_ready))
    else {
        return;
    };
    if !gl_ready {
        return;
    }
    unsafe {
        if wglMakeCurrent(hdc, hglrc).is_err() {
            return;
        }
        // The host clears; `ghostty_inspector_opengl_render` does not (see
        // this module's doc comment). Matches the colour
        // `src/apprt/gtk/class/imgui_widget.zig`'s `glAreaRender` clears to.
        gl_clear_color(0x28 as f32 / 255.0, 0x2C as f32 / 255.0, 0x34 as f32 / 255.0, 1.0);
        gl_clear();
        (api().inspector_opengl_render)(insp as Inspector);
        let _ = SwapBuffers(hdc);
    }
}

// A handful of raw GL entry points dcimgui's own backend already links
// against (via `opengl32.dll`), so no new dependency is added by calling
// them here too -- just declared, the same way `wgl.zig`'s `c` struct
// hand-declares the Win32/WGL functions the `windows` crate doesn't cover.
unsafe extern "system" {
    fn glClearColor(r: f32, g: f32, b: f32, a: f32);
    fn glClear(mask: u32);
    fn glViewport(x: i32, y: i32, w: i32, h: i32);
}
const GL_COLOR_BUFFER_BIT: u32 = 0x4000;
fn gl_clear_color(r: f32, g: f32, b: f32, a: f32) {
    unsafe { glClearColor(r, g, b, a) };
}
fn gl_clear() {
    unsafe { glClear(GL_COLOR_BUFFER_BIT) };
}

/// `ghostty_input_key_e` for a Win32 virtual key, or `None` for a key this
/// host does not forward to the inspector. `vk_from_physical` in `quick.rs`
/// is this function's mirror image (key ordinal -> VK); the three contiguous
/// runs (`KEY_A..+26`, `KEY_DIGIT_0..+10`, `KEY_F1..+12`) are the same
/// arithmetic run the other way, so a wrong anchor in `ffi.rs` would show up
/// as both functions disagreeing rather than as one silently-wrong table.
fn key_of(vk: VIRTUAL_KEY) -> Option<i32> {
    let v = vk.0;
    if (0x41..=0x5A).contains(&v) {
        return Some(KEY_A + (v as i32 - 0x41)); // VK_A..VK_Z
    }
    if (0x30..=0x39).contains(&v) {
        return Some(KEY_DIGIT_0 + (v as i32 - 0x30)); // VK_0..VK_9
    }
    if (0x70..=0x7B).contains(&v) {
        return Some(KEY_F1 + (v as i32 - 0x70)); // VK_F1..VK_F12
    }
    Some(match VIRTUAL_KEY(v) {
        VK_LEFT => KEY_ARROW_LEFT,
        VK_RIGHT => KEY_ARROW_RIGHT,
        VK_UP => KEY_ARROW_UP,
        VK_DOWN => KEY_ARROW_DOWN,
        VK_TAB => KEY_TAB,
        VK_RETURN => KEY_ENTER,
        VK_ESCAPE => KEY_ESCAPE,
        VK_BACK => KEY_BACKSPACE,
        VK_DELETE => KEY_DELETE,
        VK_SPACE => KEY_SPACE,
        VK_HOME => KEY_HOME,
        VK_END => KEY_END,
        VK_PRIOR => KEY_PAGE_UP,
        VK_NEXT => KEY_PAGE_DOWN,
        VK_LSHIFT => KEY_SHIFT_LEFT,
        VK_RSHIFT => KEY_SHIFT_RIGHT,
        VK_LCONTROL => KEY_CONTROL_LEFT,
        VK_RCONTROL => KEY_CONTROL_RIGHT,
        VK_LMENU => KEY_ALT_LEFT,
        VK_RMENU => KEY_ALT_RIGHT,
        VK_LWIN => KEY_META_LEFT,
        VK_RWIN => KEY_META_RIGHT,
        // `VK_SHIFT`/`VK_CONTROL`/`VK_MENU` arrive on some layouts instead of
        // the left/right-specific codes; without a side to report, left is
        // the same guess `keys::mods()` makes for the generic bit.
        VK_SHIFT => KEY_SHIFT_LEFT,
        VK_CONTROL => KEY_CONTROL_LEFT,
        VK_MENU => KEY_ALT_LEFT,
        _ => return None,
    })
}

pub extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_ERASEBKGND => LRESULT(1),

            WM_PAINT => {
                paint(hwnd);
                let _ = ValidateRect(Some(hwnd), None);
                LRESULT(0)
            }

            WM_SIZE => {
                let w = (lp.0 & 0xFFFF) as u32;
                let h = ((lp.0 >> 16) & 0xFFFF) as u32;
                if let Some(insp) = with_win(hwnd, |win| win.inspector) {
                    if w > 0 && h > 0 {
                        (api().inspector_set_size)(insp as Inspector, w, h);
                        gl_viewport_if_current(hwnd, w, h);
                        let _ = InvalidateRect(Some(hwnd), None, false);
                    }
                }
                LRESULT(0)
            }

            WM_DPICHANGED => {
                let dpi = (wp.0 & 0xFFFF) as f64;
                let scale = dpi / 96.0;
                if let Some(insp) = with_win(hwnd, |win| win.inspector) {
                    (api().inspector_set_content_scale)(insp as Inspector, scale, scale);
                }
                LRESULT(0)
            }

            WM_SETFOCUS => {
                if let Some(insp) = with_win(hwnd, |win| win.inspector) {
                    (api().inspector_set_focus)(insp as Inspector, true);
                }
                LRESULT(0)
            }
            WM_KILLFOCUS => {
                if let Some(insp) = with_win(hwnd, |win| win.inspector) {
                    (api().inspector_set_focus)(insp as Inspector, false);
                }
                LRESULT(0)
            }

            WM_MOUSEMOVE => {
                mouse_pos(hwnd, lo_i16(lp) as f64, hi_i16(lp) as f64);
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                mouse_button(hwnd, MOUSE_PRESS, MOUSE_LEFT);
                LRESULT(0)
            }
            WM_LBUTTONUP => {
                mouse_button(hwnd, MOUSE_RELEASE, MOUSE_LEFT);
                LRESULT(0)
            }
            WM_RBUTTONDOWN => {
                mouse_button(hwnd, MOUSE_PRESS, MOUSE_RIGHT);
                LRESULT(0)
            }
            WM_RBUTTONUP => {
                mouse_button(hwnd, MOUSE_RELEASE, MOUSE_RIGHT);
                LRESULT(0)
            }
            WM_MBUTTONDOWN => {
                mouse_button(hwnd, MOUSE_PRESS, MOUSE_MIDDLE);
                LRESULT(0)
            }
            WM_MBUTTONUP => {
                mouse_button(hwnd, MOUSE_RELEASE, MOUSE_MIDDLE);
                LRESULT(0)
            }
            WM_MOUSEWHEEL => {
                let delta = hi_i16(LPARAM(wp.0 as isize)) as f64;
                if let Some(insp) = with_win(hwnd, |win| win.inspector) {
                    (api().inspector_mouse_scroll)(insp as Inspector, 0.0, delta / 120.0 * 3.0, 0);
                }
                LRESULT(0)
            }

            WM_KEYDOWN | WM_SYSKEYDOWN | WM_KEYUP | WM_SYSKEYUP => {
                let pressed = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
                let vk = VIRTUAL_KEY((wp.0 & 0xFFFF) as u16);
                if let Some(k) = key_of(vk) {
                    if let Some(insp) = with_win(hwnd, |win| win.inspector) {
                        let action = if pressed { KEY_PRESS } else { KEY_RELEASE };
                        (api().inspector_key)(insp as Inspector, action, k, crate::keys::mods());
                    }
                }
                LRESULT(0)
            }

            WM_CHAR => {
                let c = wp.0 as u16;
                if c >= 0x20 || c == 0x08 || c == 0x0D || c == 0x09 {
                    if let Some(insp) = with_win(hwnd, |win| win.inspector) {
                        let mut buf = [0u8; 8];
                        if let Some(ch) = char::from_u32(c as u32) {
                            let txt = ch.encode_utf8(&mut buf);
                            let mut cbuf: Vec<u8> = txt.as_bytes().to_vec();
                            cbuf.push(0);
                            (api().inspector_text)(insp as Inspector, cbuf.as_ptr() as *const _);
                        }
                    }
                }
                LRESULT(0)
            }

            // The X button and Alt+F4 both arrive here. Hiding, not
            // destroying: closing is `destroy`'s job (called from `apply`
            // on `INSPECTOR_HIDE`/`INSPECTOR_TOGGLE`), so the window and the
            // surface's inspector both go through the one teardown path
            // regardless of which of the two ways a person used to ask.
            WM_CLOSE => {
                if let Some(idx) = find(hwnd) {
                    let surface = WINS.lock().unwrap()[idx].surface;
                    destroy(surface);
                }
                LRESULT(0)
            }

            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

unsafe fn gl_viewport_if_current(hwnd: HWND, w: u32, h: u32) {
    if let Some((hdc, hglrc)) = with_win(hwnd, |win| (win.hdc, win.hglrc)) {
        if wglMakeCurrent(hdc, hglrc).is_ok() {
            glViewport(0, 0, w as i32, h as i32);
        }
    }
}

fn mouse_pos(hwnd: HWND, x: f64, y: f64) {
    let Some((insp, scale)) = with_win(hwnd, |w| w.inspector).map(|insp| {
        let scale = unsafe { GetDpiForWindow(hwnd) }.max(96) as f64 / 96.0;
        (insp, scale)
    }) else {
        return;
    };
    unsafe { (api().inspector_mouse_pos)(insp as Inspector, x / scale, y / scale) };
}

fn mouse_button(hwnd: HWND, state: i32, button: i32) {
    if let Some(insp) = with_win(hwnd, |w| w.inspector) {
        unsafe { (api().inspector_mouse_button)(insp as Inspector, state, button, crate::keys::mods()) };
    }
}

fn lo_i16(lp: LPARAM) -> i32 {
    (lp.0 & 0xFFFF) as u16 as i16 as i32
}
fn hi_i16(lp: LPARAM) -> i32 {
    ((lp.0 >> 16) & 0xFFFF) as u16 as i16 as i32
}

/// Register the `PolterInspector` window class. Called once at startup next
/// to `PolterHost`/`PolterSurface`.
pub fn register_class(hinst: windows::Win32::Foundation::HINSTANCE) -> bool {
    let wc = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        // CS_OWNDC: this window keeps its own DC for its GL context's life,
        // the same reason `PolterSurface` has it.
        style: CS_OWNDC | CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(wndproc),
        hInstance: hinst,
        lpszClassName: w!("PolterInspector"),
        hbrBackground: windows::Win32::Graphics::Gdi::HBRUSH(std::ptr::null_mut()),
        hCursor: unsafe { LoadCursorW(None, IDC_ARROW).unwrap_or_default() },
        ..Default::default()
    };
    unsafe { RegisterClassExW(&wc) != 0 }
}
