//! The size an embedded surface starts at, before the apprt's first
//! `ghostty_surface_set_size`.
//!
//! **It matters because the terminal is built at this size, and a pane
//! reopened from a project is restored into it** (`Termio.init`, before the
//! shell is spawned). When this was always a placeholder, the apprt's real
//! size arrived afterwards and the restored screen was resized a second time
//! -- with the pane's own prompt handling on, which erased the restored
//! prompt line and let the console's first clear take the last screenful
//! with it (issue #35; #826 is the chain it belongs to).
//!
//! So an apprt that knows the size when it creates the surface passes it in
//! `ghostty_surface_config_s.width`/`height`, and then its first `set_size`
//! with the same numbers changes nothing (`Surface.sizeCallback` returns
//! early on an equal size). One that does not know passes 0 and gets the
//! placeholder, which is what every apprt got before.
//!
//! In its own file rather than in `embedded.zig` because that file's tests
//! are never compiled into the test binary; a rule tested there is a rule
//! nobody checks.

const std = @import("std");
const SurfaceSize = @import("structs.zig").SurfaceSize;

/// What a surface starts at when the apprt did not say. The value every
/// embedded surface used before the apprt could pass one.
pub const placeholder: SurfaceSize = .{ .width = 800, .height = 600 };

/// The size to build the surface at, given what the apprt passed. A zero
/// in either dimension means "not known yet", not a size.
pub fn fromApprt(width: u32, height: u32) SurfaceSize {
    if (width == 0 or height == 0) return placeholder;
    return .{ .width = width, .height = height };
}

test "a size the apprt passes is the size the surface starts at" {
    const s = fromApprt(1000, 655);
    try std.testing.expectEqual(@as(u32, 1000), s.width);
    try std.testing.expectEqual(@as(u32, 655), s.height);
}

test "an apprt that does not know the size gets the placeholder, not a zero-sized terminal" {
    try std.testing.expect(fromApprt(0, 0).eql(&placeholder));
    // Half known is not known: a grid with a real width and zero rows is not
    // a terminal anything can be restored into.
    try std.testing.expect(fromApprt(1000, 0).eql(&placeholder));
    try std.testing.expect(fromApprt(0, 655).eql(&placeholder));
}
