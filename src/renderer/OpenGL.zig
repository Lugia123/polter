//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const gl = @import("opengl");
const egl = gl.egl;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const build_config = @import("../build_config.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);
const Dmabuf = @import("Dmabuf.zig");

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

/// Triple-buffering gives the GPU room to pipeline renders without
/// having to wait on the apprt consuming previous frames.
///
/// The WGL path keeps the single buffer it always had: it presents
/// synchronously (`gl.finish`, then blit and swap, all on the renderer
/// thread; see `Frame.complete`), so there is no consumer to pipeline
/// against and two more targets would only be two more targets' memory.
pub const swap_chain_count = if (wgl_enabled) 1 else 3;

const log = std.log.scoped(.opengl);

/// Whether this build drives its own WGL context on a host-provided `HWND`.
///
/// This is the `embedded` apprt on Windows: there is no app runtime to hand
/// us a context the way GTK does, only a window handle from the external
/// host. Everything else -- GTK, and anything that ever builds OpenGL on a
/// Unix -- takes upstream's surfaceless EGL path and exports its frames.
/// `embedded` on Darwin has no OpenGL path at all (it uses Metal).
const wgl_enabled =
    apprt.runtime == apprt.embedded and
    builtin.os.tag == .windows;

/// Threading model for the WGL path.
///
/// **The renderer thread owns the context for the whole session.** A WGL
/// context may be current on any thread, just not on two at once, so we give
/// it to the renderer thread. That matters on Windows specifically because
/// dragging or resizing a window enters a *nested modal message loop* that
/// blocks the host's thread; drawing there would freeze the terminal for as
/// long as the user holds the title bar.
///
/// `glad.context` is `threadlocal` (`pkg/opengl/glad.zig`), so every thread
/// that issues GL calls must run `glad.load` itself. Which gives:
///
/// | hook          | thread   | what it does                                  |
/// | ------------- | -------- | --------------------------------------------- |
/// | `init`        | main     | create context, load glad (version check), release |
/// | `threadEnter` | renderer | claim, load glad again (TLS)                  |
/// | (`drawFrame`) | renderer | builds GPU resources lazily                   |
/// | `present`     | renderer | blit, then `SwapBuffers`                      |
/// | (`generic.threadExit`) | renderer | frees GPU resources           |
/// | `threadExit`  | renderer | release                                       |
/// | `deinit`      | main     | destroy                                       |
///
/// ⚠️ **This changed with upstream's 2f0b65346.** It used to be that
/// `Renderer.init` built the swap chain and shaders on the *main* thread
/// right after `init`, so the context had to stay current there until a
/// `finalizeSurfaceInit` hook released it, and `Surface.deinit` re-claimed it
/// on the main thread to free GPU resources. Upstream now creates GPU
/// resources lazily in `drawFrame` and frees them in `threadExit`, both on
/// the renderer thread, and deleted both hooks -- so `init` releases the
/// context itself before returning (as the EGL path does), and nothing
/// touches GL on the main thread after that.
const Threading = void;

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

egl_display: if (wgl_enabled) void else *gl.egl.Display,
egl_context: if (wgl_enabled) void else *gl.egl.Context,

/// Our WGL context, when we own one. See `Threading` above.
context: if (wgl_enabled) wgl else void,

/// This renderer's own share of the `[blit]` instrumentation budget. Per
/// instance on purpose: a process-wide budget is spent entirely by the first
/// surface that draws, and every pane opened after that is silent from birth.
/// See `renderer/log_budget.zig`.
present_log: rendererpkg.LogBudget = .{ .max = present_log_max },

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !OpenGL {
    if (comptime wgl_enabled) return initWgl(alloc, opts);

    try egl.load();

    const display: *egl.Display = try .initPlatform(
        egl.c.EGL_PLATFORM_SURFACELESS_MESA,
        egl.c.EGL_DEFAULT_DISPLAY,
        null,
    );

    log.info("EGL vendor={s}", .{display.queryString(.vendor) orelse "(unknown)"});
    log.info("EGL extensions={s}", .{display.queryString(.extensions) orelse "(unknown)"});

    try egl.bindApi(egl.c.EGL_OPENGL_API);

    // Choose a config. We need a config that is renderable with
    // OpenGL and a RGBA8 color buffer.
    const config = egl.Config.choose(display, &.{
        // EGL_SURFACE_TYPE defaults to EGL_WINDOW_BIT even though
        // we are rendering exclusively through surfaceless mode.
        // This is no problem on Mesa but we need to specify this
        // explicitly for proprietary Nvidia drivers.
        egl.c.EGL_SURFACE_TYPE,    0,
        egl.c.EGL_RENDERABLE_TYPE, egl.c.EGL_OPENGL_BIT,
        egl.c.EGL_RED_SIZE,        8,
        egl.c.EGL_GREEN_SIZE,      8,
        egl.c.EGL_BLUE_SIZE,       8,
        egl.c.EGL_ALPHA_SIZE,      8,
    }) catch |err| {
        log.warn("failed to choose config err={}", .{err});
        return err;
    };

    // Create our context.
    const context = egl.Context.create(display, config, null, &.{
        egl.c.EGL_CONTEXT_MAJOR_VERSION,       MIN_VERSION_MAJOR,
        egl.c.EGL_CONTEXT_MINOR_VERSION,       MIN_VERSION_MINOR,
        egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
    }) catch |err| {
        log.warn("failed to create EGL context err={}", .{err});
        return err;
    };
    errdefer context.destroy(display) catch {};

    display.makeCurrent(null, null, context) catch |err| {
        log.warn("failed to make EGL context current err={}", .{err});
        return err;
    };

    // Release current so that the main thread
    // doesn't hold onto the GL context forever.
    defer display.releaseCurrent();

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .egl_display = display,
        .egl_context = context,
        .context = {},
    };
}

fn initWgl(alloc: Allocator, opts: rendererpkg.Options) !OpenGL {
    // Build our context on the window the host gave us.
    const hwnd = switch (opts.rt_surface.platform) {
        .win32 => |v| v.hwnd,

        // On Windows targets `Platform.MacOS` and `Platform.IOS` are
        // `void` and `Platform.init` rejects those tags outright, so we
        // can never actually hold one here.
        .macos, .ios => return error.UnsupportedPlatform,
    };

    var ctx = try wgl.init(@ptrCast(hwnd));
    errdefer ctx.deinit();

    // Load glad on this thread too, even though no GL work happens here any
    // more: it is where the version check lives, and failing it here fails
    // surface creation, which is where a machine without OpenGL 4.3 should
    // be told so. `threadEnter` loads it again for the renderer thread.
    try prepareContext(null);

    // Let go of the context so the renderer thread can claim it in
    // `threadEnter`: a WGL context can only be current on one thread at a
    // time. This used to be `finalizeSurfaceInit`'s job; see `Threading`.
    ctx.clearCurrent();

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .egl_display = {},
        .egl_context = {},
        .context = ctx,
    };
}

pub fn deinit(self: *OpenGL) void {
    if (comptime wgl_enabled) {
        self.context.deinit();
        self.* = undefined;
        return;
    }

    self.egl_display.releaseCurrent();
    self.egl_context.destroy(self.egl_display) catch {};

    // Do not destroy the EGL display here as
    // it is shared across the entire process.
    // It will get automatically torn down by the OS.
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

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread. The EGL context was created at `init` time on the main thread;
/// here we (re)bind it to this thread and load the thread-local glad
/// function pointers so all subsequent GL work on this thread is valid.
pub fn threadEnter(self: *OpenGL, surface: *apprt.Surface) !void {
    _ = surface;

    if (comptime wgl_enabled) {
        // Take ownership of the context on this thread. `init` released it.
        try self.context.makeCurrent();

        // glad's context is threadlocal, so having loaded it on the main
        // thread in `init` does nothing for us here. This only re-resolves
        // the function pointers; the context is the same one.
        try prepareContext(null);
        return;
    }

    try self.egl_display.makeCurrent(null, null, self.egl_context);
    // Load our function pointers for this thread's threadlocal.
    try prepareContext(&gl.egl.getProcAddress);
}

/// Callback called by renderer.Thread when it exits. Called on the render
/// thread; unbinds the context from this thread so it can be destroyed on
/// the main thread.
pub fn threadExit(self: *OpenGL) void {
    if (comptime wgl_enabled) {
        // Release the context so `deinit` can destroy it from the main
        // thread. `generic.threadExit` has already freed every GPU resource
        // on this thread before calling us.
        self.context.clearCurrent();

        // ⚠️ No `glad.unload` here, unlike the EGL path. glad's loader keeps
        // one process-wide library handle, and this path has never been run
        // with a pane's exit closing it under the others. Not adding that
        // untested on the way through a merge.
        return;
    }

    self.egl_display.releaseCurrent();
    gl.glad.unload();
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    // On the WGL path we ask the window, not GL. `GL_VIEWPORT` is the surface
    // size elsewhere only because `setViewport` below keeps it so; the
    // renderer also sets its own viewport per render target, so reading it
    // back here would report the last target's size instead of the window's.
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

/// Set the GL viewport to cover the given size in device pixels.
///
/// This used to be automatically called by the GtkGLArea upon resizing,
/// but now we need to do this manually.
pub fn setViewport(self: *const OpenGL, width: u32, height: u32) void {
    _ = self;
    gl.viewport(0, 0, @intCast(width), @intCast(height)) catch |err| {
        log.warn("failed to set OpenGL viewport err={}", .{err});
    };
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

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    _ = self;
    return Target.init(.{
        .width = width,
        .height = height,
    });
}

const present_log_max: usize = 40;

/// Present the provided target. On the WGL path this blits the target into
/// the window's back buffer and swaps; on every other path it exports the
/// target for the apprt to composite, and the caller takes ownership of the
/// returned frame.
///
/// This runs on the render thread.
pub fn present(self: *OpenGL, target: Target) !ExportedFrame {
    if (comptime !wgl_enabled) return self.exportTarget(target);

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
    // absence: proves nothing -- a fixed budget with no escape. Once the
    // first `present_log_max` presents of this renderer are spent the line
    // never appears again, whatever happens, so a search that comes back
    // empty separates nothing: not drawing and drawing look identical here.
    if (self.present_log.take()) {
        const fb = blk: {
            var v: gl.c.GLint = undefined;
            gl.glad.context.GetIntegerv.?(gl.c.GL_DRAW_FRAMEBUFFER_BINDING, &v);
            break :blk v;
        };
        var vp: [4]gl.c.GLint = undefined;
        gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &vp);
        const err = gl.glad.context.GetError.?();
        {
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
        }
    }

    // ⚠️ `r` here is the *graphics API* address, not the renderer's --
    // `present` cannot reach the `generic.Renderer` that owns it (that
    // dependency only runs the other way). It is the same address `[blit]`
    // above prints, and differs from the `r` in `[rsz]` and every other
    // `[rphase]` line by a fixed offset. Do not join them on `r`.
    if (comptime build_config.log_render_phase) log.info(
        "[rphase] r={x} at=swap",
        .{@intFromPtr(self)},
    );

    // On the WGL path nothing else is going to present for us. The export
    // path hands its frame to the apprt to composite; our host only owns the
    // window, so the swap is ours to do, here, right after the blit that
    // filled the back buffer.
    self.context.swapBuffers();
}

/// Export a rendered target. Caller takes ownership
/// of the frame and is responsible for freeing it.
///
/// This runs on the render thread.
fn exportTarget(self: *OpenGL, target: Target) !ExportedFrame {
    if (target.exportDmabuf(self.egl_display, self.egl_context)) |dmabuf| {
        return .{ .dmabuf = dmabuf };
    } else |_| {
        // If DMABUFs fail, then use CPU buffers
        return .{ .memory = .{
            .width = @intCast(target.width),
            .height = @intCast(target.height),
            .pixels = try target.readPixelsAlloc(self.alloc),
            .alloc = self.alloc,
        } };
    }
}

/// A finished frame exported for presentation by the apprt.
///
/// `void` on the WGL path, which presents for itself and exports nothing;
/// `generic.LatestFrame` and `Frame.complete` both key off that.
pub const ExportedFrame = if (wgl_enabled) void else ExportedFrameUnion;

const ExportedFrameUnion = union(enum) {
    dmabuf: Dmabuf,
    memory: Memory,

    /// RGBA8 pixel data with premultiplied alpha, tightly packed
    /// (`width * 4` bytes per row), in CPU memory.
    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
        }
    };

    pub fn deinit(self: ExportedFrameUnion) void {
        switch (self) {
            .dmabuf => |v| v.deinit(),
            .memory => |v| v.deinit(),
        }
    }
};

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
        .target = .@"2d",
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
        .target = .@"2d",
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
            .target = .rectangle,
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
