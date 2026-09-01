//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const gl = @import("opengl");
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");
const wgl = @import("opengl/wgl.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// Because OpenGL's frame completion is always
/// sync, we have no need for multi-buffering.
pub const swap_chain_count = 1;

const log = std.log.scoped(.opengl);

/// Whether this build drives its own WGL context on a host-provided `HWND`.
///
/// This is the `embedded` apprt on Windows: there is no app runtime to hand
/// us a context the way GTK does, only a window handle from the external
/// host. `embedded` on Darwin still has no OpenGL path (it uses Metal), so
/// it keeps the old no-op behavior.
const wgl_enabled =
    apprt.runtime == apprt.embedded and
    builtin.os.tag == .windows;

/// Threading model for the WGL path.
///
/// **The renderer thread owns the context for the whole session.** This is
/// deliberately *not* what the GTK path does, so the reasoning is written
/// down here rather than inferred from the code.
///
/// GTK loads glad on the main thread and does the real drawing there, because
/// `GtkGLArea`'s context belongs to the main loop. WGL has no such rule: a
/// context may be current on any thread, just not on two at once. So we give
/// it to the renderer thread, which matters on Windows specifically because
/// dragging or resizing a window enters a *nested modal message loop* that
/// blocks the host's thread. Drawing on the main thread the way GTK does
/// would freeze the terminal for as long as the user holds the title bar.
///
/// Two constraints fix the handoff sequence:
///
///   1. `glad.context` is `threadlocal` (`pkg/opengl/glad.zig`), so every
///      thread that issues GL calls must run `glad.load` itself.
///   2. `generic.zig`'s `Renderer.init` builds GPU resources (`SwapChain`,
///      atlas textures) immediately after `OpenGL.init`, on the *main*
///      thread. So the context has to be current there first.
///
/// Which gives:
///
/// | hook                    | thread   | what it does                     |
/// | ----------------------- | -------- | -------------------------------- |
/// | `init`                  | main     | create context, current, load glad |
/// | (`SwapChain.init`)      | main     | builds GPU resources             |
/// | `finalizeSurfaceInit`   | main     | release, so the thread can claim it |
/// | `threadEnter`           | renderer | claim, load glad again (TLS)     |
/// | `present`               | renderer | blit, then `SwapBuffers`         |
/// | `threadExit`            | renderer | release                          |
/// | `threadEnter` (again)   | main     | reclaim for teardown             |
/// | `deinit`                | main     | destroy                          |
///
/// The last two are `Surface.deinit`, which joins the renderer thread and
/// then calls `threadEnter` again to free GPU resources from the main
/// thread. GL objects live in the context, not the thread, so objects built
/// on one thread stay valid on the other.
const Threading = void;

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The most recently presented target, in case we need to present it again.
last_target: ?Target = null,

/// Our WGL context, when we own one. See `Threading` above.
context: if (wgl_enabled) wgl else void,

/// NOTE: The error set is inferred rather than declared. On the GTK path
///       this infers to `error{}`, matching the old signature; the WGL path
///       genuinely can fail, since it creates the context here.
pub fn init(alloc: Allocator, opts: rendererpkg.Options) !OpenGL {
    const context = if (comptime wgl_enabled) context: {
        // Build our context on the window the host gave us. This leaves it
        // current on this (the main) thread, which is what the caller needs:
        // `Renderer.init` creates GPU resources right after we return.
        const hwnd = switch (opts.rt_surface.platform) {
            .win32 => |v| v.hwnd,

            // On Windows targets `Platform.MacOS` and `Platform.IOS` are
            // `void` and `Platform.init` rejects those tags outright, so we
            // can never actually hold one here.
            .macos, .ios => return error.UnsupportedPlatform,
        };

        const ctx = try wgl.init(@ptrCast(hwnd));
        errdefer {
            var c = ctx;
            c.deinit();
        }

        // Load glad for *this* thread. `threadEnter` does it again for the
        // renderer thread, because glad's context is threadlocal.
        try prepareContext(null);

        break :context ctx;
    } else {};

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .context = context,
    };
}

pub fn deinit(self: *OpenGL) void {
    if (comptime wgl_enabled) self.context.deinit();
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".calling_convention;

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = try gl.glad.load(getProcAddress);
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer gl.glad.unload();
    log.info("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Enable debug output for the context.
    try gl.enable(gl.c.GL_DEBUG_OUTPUT);

    // Register our debug message callback with the OpenGL context.
    gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
}

/// This is called early right after surface creation.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        // GTK uses global OpenGL context so we load from null.
        apprt.gtk,
        => try prepareContext(null),

        apprt.embedded => {
            // Nothing to do here. This hook is static (no renderer instance
            // exists yet) so there is nowhere to store a context; we create
            // ours in `init`, where we have both `rt_surface` and a `self`
            // to keep it in. See `Threading`.
            //
            // On non-Windows embedded targets there is still no OpenGL
            // path at all -- those builds use Metal.
        },
    }

    // These are very noisy so this is commented, but easy to uncomment
    // whenever we need to check the OpenGL extension list
    // if (builtin.mode == .Debug) {
    //     var ext_iter = try gl.ext.iterator();
    //     while (try ext_iter.next()) |ext| {
    //         log.debug("OpenGL extension available name={s}", .{ext});
    //     }
    // }
}

/// This is called just prior to spinning up the renderer
/// thread for final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = surface;

    if (comptime wgl_enabled) {
        // This is the last main-thread hook before the renderer thread is
        // spawned. Our context is still current here from `init`, and a WGL
        // context can only be current on one thread at a time, so we have to
        // let go of it now or `threadEnter` would fail to claim it.
        self.context.clearCurrent();
    }
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = surface;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // GTK doesn't support threaded OpenGL operations as far as I can
            // tell, so we use the renderer thread to setup all the state
            // but then do the actual draws and texture syncs and all that
            // on the main thread. As such, we don't do anything here.
        },

        apprt.embedded => {
            if (comptime wgl_enabled) {
                // Take ownership of the context on this thread. Whoever had
                // it last released it: `finalizeSurfaceInit` on the way in,
                // `threadExit` on the way out.
                try self.context.makeCurrent();

                // glad's context is threadlocal, so having loaded it on the
                // main thread in `init` does nothing for us here. The GL
                // objects themselves belong to the context and are already
                // there; this only re-resolves the function pointers.
                try prepareContext(null);
            }
        },
    }
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const OpenGL) void {
    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // We don't need to do any unloading for GTK because we may
            // be sharing the global bindings with other windows.
        },

        apprt.embedded => {
            if (comptime wgl_enabled) {
                // Release the context so another thread can claim it.
                // `Surface.deinit` joins this thread and then calls
                // `threadEnter` again from the main thread to tear down GPU
                // resources, which would fail if we still held it.
                self.context.clearCurrent();
            }
        },
    }
}

pub fn displayRealized(self: *const OpenGL) void {
    _ = self;

    switch (apprt.runtime) {
        apprt.gtk => prepareContext(null) catch |err| {
            log.warn(
                "Error preparing GL context in displayRealized, err={}",
                .{err},
            );
        },

        else => @compileError("only GTK should be calling displayRealized"),
    }
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameEnd(self: *OpenGL) void {
    _ = self;
}

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    // On the WGL path we ask the window, not GL. `GL_VIEWPORT` only happens
    // to be the surface size under GTK because `GtkGLArea` sets it before
    // each draw; nothing does that for a bare `HWND`, and the renderer sets
    // its own viewport per render target, so reading it back here would
    // report the last target's size instead of the window's.
    if (comptime wgl_enabled) {
        const size = self.context.clientSize();
        return .{ .width = size.width, .height = size.height };
    }

    var viewport: [4]gl.c.GLint = undefined;
    gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    return .{
        .width = @intCast(viewport[2]),
        .height = @intCast(viewport[3]),
    };
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    return Target.init(.{
        .internal_format = if (self.blending.isLinear()) .srgba else .rgba,
        .width = width,
        .height = height,
    });
}

var present_log_count: usize = 0;
const present_log_max: usize = 40;

/// Present the provided target.
pub fn present(self: *OpenGL, target: Target) !void {
    // In order to present a target we blit it to the default framebuffer.

    // We disable GL_FRAMEBUFFER_SRGB while doing this blit, otherwise the
    // values may be linearized as they're copied, but even though the draw
    // framebuffer has a linear internal format, the values in it should be
    // sRGB, not linear!
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
    };

    // Bind the target for reading.
    const fbobind = try target.framebuffer.bind(.read);
    defer fbobind.unbind();

    // Blit
    gl.glad.context.BlitFramebuffer.?(
        0,
        0,
        @intCast(target.width),
        @intCast(target.height),
        0,
        0,
        @intCast(target.width),
        @intCast(target.height),
        gl.c.GL_COLOR_BUFFER_BIT,
        gl.c.GL_NEAREST,
    );

    // **What this prints, and why these quantities.** A resize was measured
    // end to end -- surface, screen, target and the cell grid all follow the
    // window -- and the newly exposed region stayed black, with the boundary
    // exactly at the *old* width. The blit above is built from `target` on
    // both sides, so its rectangle cannot be the wrong size; what it cannot
    // tell us is how big the thing it blits *into* is. That is the one
    // quantity nobody has read yet, so it is the one this prints, next to
    // the numbers it has to be compared against.
    //
    // `err` is here because a blit that fails is currently silent, and a
    // silent failure and a stale drawable produce the same black pixels.
    if (present_log_count < present_log_max) {
        present_log_count += 1;
        const fb = blk: {
            var v: gl.c.GLint = undefined;
            gl.glad.context.GetIntegerv.?(gl.c.GL_DRAW_FRAMEBUFFER_BINDING, &v);
            break :blk v;
        };
        var vp: [4]gl.c.GLint = undefined;
        gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &vp);
        const err = gl.glad.context.GetError.?();
        if (comptime wgl_enabled) {
            const client = self.context.clientSize();
            log.info(
                "[blit] r={x} target={d}x{d} dst={d}x{d} drawable={d}x{d} viewport=({d},{d},{d},{d}) fb={d} err=0x{x}",
                .{
                    @intFromPtr(self),   target.width, target.height,
                    target.width,        target.height,
                    client.width,        client.height,
                    vp[0], vp[1], vp[2], vp[3],
                    fb,                  err,
                },
            );
        } else {
            // Rule 5: a criterion that does not apply says so, out loud. The
            // drawable size is asked of the window, and only the WGL path has
            // a window to ask.
            log.info(
                "[blit] r={x} target={d}x{d} dst={d}x{d} drawable=n/a (not the WGL path) viewport=({d},{d},{d},{d}) fb={d} err=0x{x}",
                .{
                    @intFromPtr(self), target.width, target.height,
                    target.width,      target.height,
                    vp[0], vp[1], vp[2], vp[3],
                    fb,                err,
                },
            );
        }
    }

    // On the WGL path nothing else is going to present for us. GTK swaps
    // buffers itself as part of its draw cycle; our host only owns the
    // window, so the swap is ours to do, here, right after the blit that
    // filled the back buffer.
    if (comptime wgl_enabled) self.context.swapBuffers();

    // Keep track of this target in case we need to repeat it.
    self.last_target = target;
}

/// Present the last presented target again.
pub fn presentLastTarget(self: *OpenGL) !void {
    if (self.last_target) |target| try self.present(target);
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2D",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2D",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .Rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}
