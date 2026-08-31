//! WGL context management for rendering into a host-provided `HWND`.
//!
//! This is the piece that was missing for the `embedded` apprt on Windows.
//! With GTK, the app runtime owns the GL context and hands us one that is
//! already current; with `embedded` there is no app runtime at all, only an
//! `HWND` that an external host (the Rust shell) created for us. So we have
//! to build the context ourselves and decide who owns it.
//!
//! ## Threading
//!
//! A WGL context may be made current on any thread, but on **at most one
//! thread at a time**. We hand it to the renderer thread for the whole
//! session; see the `Threading` doc comment in `renderer/OpenGL.zig` for why
//! and for the exact handoff sequence.
//!
//! Every thread that issues GL calls must also run `glad.load` itself,
//! because `glad.context` is `threadlocal` (see `pkg/opengl/glad.zig`).
//! This type only manages *which thread the context is current on*; loading
//! glad is the caller's job, right after `makeCurrent`.

const Context = @This();

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HDC = windows.HDC;
const HGLRC = windows.HGLRC;
const HWND = windows.HWND;
const LONG = windows.LONG;
const PROC = windows.PROC;
const WORD = windows.WORD;

const log = std.log.scoped(.wgl);

/// The host-owned window we render into. We never destroy this; the host
/// created it and the host outlives us.
hwnd: HWND,

/// Device context for `hwnd`, from `GetDC`. Released in `deinit`.
hdc: HDC,

/// The OpenGL rendering context. This owns every GL object we create,
/// independent of which thread happens to have it current.
hglrc: HGLRC,

pub const Error = error{
    /// `GetDC` failed for the host's window.
    NoDeviceContext,
    /// No pixel format matching our requirements exists for this device.
    NoPixelFormat,
    /// `SetPixelFormat` failed. Most likely the host already set a
    /// different, incompatible pixel format on this window: a pixel
    /// format can only be set once per window.
    PixelFormatFailed,
    /// Creating the legacy bootstrap context failed. The window probably
    /// has no OpenGL-capable driver behind it.
    ContextFailed,
    /// The driver does not expose `WGL_ARB_create_context`, so we cannot
    /// ask for the 4.3 core profile that Ghostty's shaders require.
    NoCreateContextARB,
    /// The driver refused a 4.3 core profile context.
    VersionUnsupported,
    /// `wglMakeCurrent` failed.
    MakeCurrentFailed,
};

/// Create a WGL context for the given host window.
///
/// On success the context is **current on the calling thread**, because the
/// caller needs to load glad and build GPU resources immediately afterwards.
/// Call `clearCurrent` before handing it to another thread.
pub fn init(hwnd: HWND) Error!Context {
    const hdc = c.GetDC(hwnd) orelse {
        log.err("GetDC failed for host window", .{});
        return error.NoDeviceContext;
    };
    errdefer _ = c.ReleaseDC(hwnd, hdc);

    // Pick and set a pixel format. This can only be done once per window,
    // so if the host has already done it with something incompatible we
    // fail here rather than rendering to a format we didn't ask for.
    var pfd: c.PIXELFORMATDESCRIPTOR = .{
        .nSize = @sizeOf(c.PIXELFORMATDESCRIPTOR),
        .nVersion = 1,
        .dwFlags = c.PFD_DRAW_TO_WINDOW | c.PFD_SUPPORT_OPENGL | c.PFD_DOUBLEBUFFER,
        .iPixelType = c.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cAlphaBits = 8,
        .cDepthBits = 0,
        .cStencilBits = 0,
        .iLayerType = c.PFD_MAIN_PLANE,
    };

    const format = c.ChoosePixelFormat(hdc, &pfd);
    if (format == 0) {
        log.err("ChoosePixelFormat found no suitable format", .{});
        return error.NoPixelFormat;
    }
    if (c.SetPixelFormat(hdc, format, &pfd) == .FALSE) {
        log.err(
            "SetPixelFormat failed, format={d}; the host may have already " ++
                "set an incompatible pixel format on this window",
            .{format},
        );
        return error.PixelFormatFailed;
    }

    // WGL bootstrap: `wglCreateContextAttribsARB` is itself an extension,
    // so it can only be resolved through `wglGetProcAddress`, which in turn
    // only works while some context is current. So we make a legacy context
    // first purely to look the function up, then throw it away.
    const bootstrap = c.wglCreateContext(hdc) orelse {
        log.err("wglCreateContext failed for the bootstrap context", .{});
        return error.ContextFailed;
    };

    if (c.wglMakeCurrent(hdc, bootstrap) == .FALSE) {
        _ = c.wglDeleteContext(bootstrap);
        log.err("wglMakeCurrent failed for the bootstrap context", .{});
        return error.MakeCurrentFailed;
    }

    const createContextAttribs: ?c.PFNWGLCREATECONTEXTATTRIBSARBPROC =
        @ptrCast(c.wglGetProcAddress("wglCreateContextAttribsARB"));

    // Tear the bootstrap context down regardless of what we found. We must
    // clear it as current first, or we'd be deleting a context in use.
    defer {
        _ = c.wglDeleteContext(bootstrap);
    }

    const createFn = createContextAttribs orelse {
        _ = c.wglMakeCurrent(null, null);
        log.err(
            "driver does not support WGL_ARB_create_context, so a " ++
                "{d}.{d} core profile cannot be requested",
            .{ required_major, required_minor },
        );
        return error.NoCreateContextARB;
    };

    // Ask for a core profile at the minimum version Ghostty's shaders need.
    // For 3.2 and up the driver is required to return a context of at least
    // the requested version, so this is a floor, not an exact match.
    const attribs = [_]c_int{
        c.WGL_CONTEXT_MAJOR_VERSION_ARB, required_major,
        c.WGL_CONTEXT_MINOR_VERSION_ARB, required_minor,
        c.WGL_CONTEXT_PROFILE_MASK_ARB,  c.WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
        c.WGL_CONTEXT_FLAGS_ARB,
        if (builtin.mode == .Debug)
            c.WGL_CONTEXT_DEBUG_BIT_ARB
        else
            0,
        0,
    };

    const hglrc = createFn(hdc, null, &attribs) orelse {
        _ = c.wglMakeCurrent(null, null);
        log.err(
            "driver refused an OpenGL {d}.{d} core profile context",
            .{ required_major, required_minor },
        );
        return error.VersionUnsupported;
    };
    errdefer _ = c.wglDeleteContext(hglrc);

    // Switch off the bootstrap context and onto the real one. This also
    // releases the bootstrap context so the deferred delete above is safe.
    if (c.wglMakeCurrent(hdc, hglrc) == .FALSE) {
        _ = c.wglMakeCurrent(null, null);
        log.err("wglMakeCurrent failed for the core profile context", .{});
        return error.MakeCurrentFailed;
    }

    log.info("created WGL context hwnd={*} pixel_format={d}", .{ hwnd, format });

    return .{ .hwnd = hwnd, .hdc = hdc, .hglrc = hglrc };
}

/// Destroy the context. The context must not be current on any thread;
/// callers reach this state via `clearCurrent`.
pub fn deinit(self: *Context) void {
    // Deleting a context that is still current on this thread is legal but
    // defers the destruction, so clear it first to keep teardown ordered.
    //
    // Only clear it if it's *ours*, though: with several surfaces open the
    // calling thread may have some other surface's context current, and
    // tearing that one down here would be a bug in a hard place to find.
    if (c.wglGetCurrentContext() == self.hglrc) {
        _ = c.wglMakeCurrent(null, null);
    }
    _ = c.wglDeleteContext(self.hglrc);
    _ = c.ReleaseDC(self.hwnd, self.hdc);
    self.* = undefined;
}

/// Make this context current on the calling thread. The caller must load
/// glad afterwards, since glad's context is threadlocal.
pub fn makeCurrent(self: *const Context) Error!void {
    if (c.wglMakeCurrent(self.hdc, self.hglrc) == .FALSE) {
        log.err("wglMakeCurrent failed", .{});
        return error.MakeCurrentFailed;
    }
}

/// Release the context from the calling thread, so that another thread may
/// claim it. A WGL context can only be current on one thread at a time, so
/// every handoff has to pass through here.
pub fn clearCurrent(self: *const Context) void {
    _ = self;
    if (c.wglMakeCurrent(null, null) == .FALSE) {
        log.warn("wglMakeCurrent(null, null) failed while releasing context", .{});
    }
}

/// Present the back buffer.
pub fn swapBuffers(self: *const Context) void {
    if (c.SwapBuffers(self.hdc) == .FALSE) {
        log.warn("SwapBuffers failed", .{});
    }
}

/// The size of the window's client area, in physical pixels.
///
/// We ask the window rather than reading `GL_VIEWPORT` the way the GTK path
/// does. Under GTK, `GtkGLArea` sets the viewport to the widget size before
/// each draw, so the viewport happens to be the surface size. Nothing does
/// that for a bare `HWND`, and the renderer sets its own viewport per target,
/// so `GL_VIEWPORT` here would report the last render target's size instead
/// of the window's.
pub fn clientSize(self: *const Context) struct { width: u32, height: u32 } {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &rect) == .FALSE) {
        log.warn("GetClientRect failed", .{});
        return .{ .width = 0, .height = 0 };
    }

    // A minimized or collapsed window can report a zero or inverted rect.
    // The renderer treats a zero size as "don't draw", which is what we want.
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    return .{
        .width = if (width > 0) @intCast(width) else 0,
        .height = if (height > 0) @intCast(height) else 0,
    };
}

/// The OpenGL version we request. This mirrors `OpenGL.MIN_VERSION_*`;
/// `prepareContext` re-checks the version it actually got.
const required_major = 4;
const required_minor = 3;

/// Win32 and WGL declarations we need.
///
/// These live here rather than in `src/os/windows.zig` because they are only
/// meaningful to the renderer, and follow that file's style: reuse the types
/// `std.os.windows` provides, hand-declare what it does not.
const c = struct {
    pub const RECT = extern struct {
        left: LONG,
        top: LONG,
        right: LONG,
        bottom: LONG,
    };

    pub const PIXELFORMATDESCRIPTOR = extern struct {
        nSize: WORD,
        nVersion: WORD,
        dwFlags: DWORD,
        iPixelType: u8,
        cColorBits: u8,
        cRedBits: u8 = 0,
        cRedShift: u8 = 0,
        cGreenBits: u8 = 0,
        cGreenShift: u8 = 0,
        cBlueBits: u8 = 0,
        cBlueShift: u8 = 0,
        cAlphaBits: u8 = 0,
        cAlphaShift: u8 = 0,
        cAccumBits: u8 = 0,
        cAccumRedBits: u8 = 0,
        cAccumGreenBits: u8 = 0,
        cAccumBlueBits: u8 = 0,
        cAccumAlphaBits: u8 = 0,
        cDepthBits: u8 = 0,
        cStencilBits: u8 = 0,
        cAuxBuffers: u8 = 0,
        iLayerType: u8 = 0,
        bReserved: u8 = 0,
        dwLayerMask: DWORD = 0,
        dwVisibleMask: DWORD = 0,
        dwDamageMask: DWORD = 0,
    };

    pub const PFD_TYPE_RGBA: u8 = 0;
    pub const PFD_MAIN_PLANE: u8 = 0;
    pub const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
    pub const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
    pub const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;

    pub const WGL_CONTEXT_MAJOR_VERSION_ARB: c_int = 0x2091;
    pub const WGL_CONTEXT_MINOR_VERSION_ARB: c_int = 0x2092;
    pub const WGL_CONTEXT_FLAGS_ARB: c_int = 0x2094;
    pub const WGL_CONTEXT_PROFILE_MASK_ARB: c_int = 0x9126;
    pub const WGL_CONTEXT_DEBUG_BIT_ARB: c_int = 0x00000001;
    pub const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: c_int = 0x00000001;

    pub const PFNWGLCREATECONTEXTATTRIBSARBPROC = *const fn (
        hdc: HDC,
        share: ?HGLRC,
        attribs: [*]const c_int,
    ) callconv(.winapi) ?HGLRC;

    pub extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
    pub extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) c_int;
    pub extern "user32" fn GetClientRect(
        hWnd: HWND,
        lpRect: *RECT,
    ) callconv(.winapi) BOOL;

    pub extern "gdi32" fn ChoosePixelFormat(
        hdc: HDC,
        ppfd: *const PIXELFORMATDESCRIPTOR,
    ) callconv(.winapi) c_int;
    pub extern "gdi32" fn SetPixelFormat(
        hdc: HDC,
        format: c_int,
        ppfd: *const PIXELFORMATDESCRIPTOR,
    ) callconv(.winapi) BOOL;
    pub extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;

    pub extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
    pub extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
    pub extern "opengl32" fn wglMakeCurrent(
        hdc: ?HDC,
        hglrc: ?HGLRC,
    ) callconv(.winapi) BOOL;
    pub extern "opengl32" fn wglGetCurrentContext() callconv(.winapi) ?HGLRC;
    pub extern "opengl32" fn wglGetProcAddress(
        name: [*:0]const u8,
    ) callconv(.winapi) ?PROC;
};

test "PIXELFORMATDESCRIPTOR matches the Win32 layout" {
    // The Win32 struct is 40 bytes with 1-byte alignment on the u8 fields;
    // getting this wrong makes ChoosePixelFormat silently misbehave.
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(c.PIXELFORMATDESCRIPTOR));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(c.PIXELFORMATDESCRIPTOR, "nSize"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(c.PIXELFORMATDESCRIPTOR, "dwFlags"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(c.PIXELFORMATDESCRIPTOR, "iPixelType"));
    try std.testing.expectEqual(@as(usize, 9), @offsetOf(c.PIXELFORMATDESCRIPTOR, "cColorBits"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(c.PIXELFORMATDESCRIPTOR, "dwLayerMask"));
}
