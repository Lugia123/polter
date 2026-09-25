//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const global = @import("../../global.zig");
const Renderer = @import("../generic.zig").Renderer(OpenGL);
const OpenGL = @import("../OpenGL.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;
const build_config = @import("../../build_config.zig");

const log = std.log.scoped(.opengl);

/// Options for beginning a frame.
pub const Options = struct {};

renderer: *Renderer,
target: *Target,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    _ = opts;

    return .{
        .renderer = renderer,
        .target = target,
    };
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    _ = self;
    return RenderPass.begin(.{ .attachments = attachments });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
///
/// NOTE: For OpenGL, `sync` is ignored. What happens to the finished target
/// depends on who presents it:
///
///   - **Exported frames (GTK).** We never block; the frame is exported and
///     pushed to the latest-frame slot, and the apprt pulls it from there.
///   - **The WGL path (Windows, `ExportedFrame == void`).** Nobody pulls:
///     the renderer thread owns the window's context, so it blits and swaps
///     buffers itself, here. There is nothing to export and no apprt redraw
///     to ask for.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;

    const health: Health = if (comptime OpenGL.ExportedFrame == void) wgl: {
        // `gl.finish` blocks until the GPU has drained; `r` here is the
        // `generic.Renderer`, the same address `[rsz]` prints.
        if (comptime build_config.log_render_phase) log.info(
            "[rphase] r={x} at=finish",
            .{@intFromPtr(self.renderer)},
        );
        gl.finish();

        // If there are any GL errors, consider the frame unhealthy.
        const health: Health = if (gl.errors.getError()) .healthy else |_| .unhealthy;

        // If the frame is healthy, present it: blit to the window's back
        // buffer and swap.
        if (health == .healthy) {
            self.renderer.api.present(self.target.*) catch |err| {
                log.err("Failed to present render target: err={}", .{err});
            };
        }

        break :wgl health;
    } else exported: {
        // If there are any GL errors, consider the frame unhealthy.
        const health: Health = if (gl.errors.getError()) .healthy else |_| .unhealthy;

        // If the frame is healthy, draw it to an ExportedFrame
        // Then sync before exporting and pushing to the present queue.
        // The apprt pulls from this queue in its snapshot handler.
        const presented_frame: ?OpenGL.ExportedFrame = if (health == .healthy) frame: {
            const frame = self.renderer.api.present(self.target.*) catch |err| {
                log.warn("failed to present render target: err={}", .{err});
                break :frame null;
            };
            break :frame frame;
        } else null;

        // Sync after frame draw AND frame present GL calls.
        gl.finish();

        // At this point the ExportedFrame is finished and can be shared
        if (presented_frame) |frame| {
            self.renderer.pushFrame(frame);

            // Notify the surface that it should redraw.
            //
            // ⚠️ **Upstream's `.forever` send into the app mailbox, kept
            // verbatim and not audited: the same shape as #483.** A full app
            // mailbox parks the renderer thread here, holding the draw mutex.
            // Only the GTK export path reaches it; no platform this fork ships
            // compiles it. Whoever brings GTK back owns bounding it.
            _ = self.renderer.surface_mailbox.push(.redraw, .{ .forever = {} });
        }

        break :exported health;
    };

    // Report the health to the renderer.
    self.renderer.frameCompleted(health);
}
