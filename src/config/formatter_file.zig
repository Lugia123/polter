const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const Key = @import("key.zig").Key;
const help_strings = @import("help_strings");
const formatter = @import("formatter.zig");

// IMPORTANT: This is in a separate file from formatter.zig because it
// puts a build-time dependency on Config.zig which brings in too much
// into libghostty-vt tests which reference some formattable types.

/// FileFormatter is a formatter implementation that outputs the
/// config in a file-like format. This uses more generous whitespace,
/// can include comments, etc.
pub const FileFormatter = struct {
    alloc: Allocator,
    config: *const Config,

    /// Include comments for documentation of each key
    docs: bool = false,

    /// Only include changed values from the default.
    changed: bool = false,

    /// Implements std.fmt so it can be used directly with std.fmt.
    pub fn format(
        self: FileFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        @setEvalBranchQuota(10_000);

        // If we're change-tracking then we need the default config to
        // compare against.
        var default: ?Config = if (self.changed)
            Config.default(self.alloc) catch return error.WriteFailed
        else
            null;
        defer if (default) |*v| v.deinit();

        // By pointer, not by value. The old `if (default) |d|` inside the
        // loop captured `Config` **by value**, so every one of the 219
        // unrolled rounds carried its own 3,256-byte copy.
        const default_ptr: ?*const Config = if (default) |*d| d else null;

        inline for (@typeInfo(Config).@"struct".fields) |field| {
            if (field.name[0] == '_') continue;
            try emitField(self, field.name, field.type, writer, default_ptr);
        }
    }

    /// Emit one config field. **`noinline` is load-bearing, not a hint.**
    ///
    /// This body used to live directly inside the `inline for` above, which
    /// unrolls once per emitted field — 219 of them. `format` then had a
    /// single stack frame of 2,201,712 bytes, **larger than the whole 2 MB
    /// default stack on Windows**: one call, one overflow, before it read a
    /// single field.
    ///
    /// Measured on x86_64-windows-gnu Debug, by taking each function's
    /// stack-pointer decrement out of `ghostty-internal-static.lib`:
    ///
    ///     as written here (default_ptr + noinline)     17,184 bytes
    ///     default_ptr only, loop body still inline     65,248
    ///     neither                                   2,201,712
    ///
    /// **Nearly all of it was the capture, not the unrolling.** `if (default)
    /// |d|` binds `Config` *by value*, and a Debug build materialises about
    /// three copies of it per round: (2,201,712 - 65,248) / 219 rounds is
    /// 9,755 bytes, and `@sizeOf(Config)` is 3,256. That is what `default_ptr`
    /// above is for, and it is the change that matters.
    ///
    /// `noinline` is the remainder, and worth keeping for a different reason:
    /// with the body inline, `format` still grows ~219 bytes per config field,
    /// so its frame is O(fields) — and fields keep getting added to this
    /// struct. Pulling the body out makes the 219 instantiations take turns:
    /// each is 176..1,392 bytes and only one is live at a time, so `format`
    /// is O(1) in the field count.
    ///
    /// Do **not** "fix" this by moving `default` to the heap instead. That was
    /// the other candidate and it was measured: `@sizeOf(?Config)` is 3,264
    /// bytes, 0.148% of the old frame.
    noinline fn emitField(
        self: FileFormatter,
        comptime name: []const u8,
        comptime T: type,
        writer: *std.Io.Writer,
        default: ?*const Config,
    ) std.Io.Writer.Error!void {
        const value = @field(self.config, name);
        const do_format = if (default) |d| format: {
            const key = @field(Key, name);
            break :format d.changed(self.config, key);
        } else true;
        if (!do_format) return;

        const do_docs = self.docs and @hasDecl(help_strings.Config, name);
        if (do_docs) {
            const help = @field(help_strings.Config, name);
            var lines = std.mem.splitScalar(u8, help, '\n');
            while (lines.next()) |line| {
                try writer.print("# {s}\n", .{line});
            }
        }

        formatter.formatEntry(
            T,
            name,
            value,
            writer,
        ) catch return error.WriteFailed;

        if (do_docs) try writer.print("\n", .{});
    }
};

test "format default config" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    // We just make sure this works without errors. We aren't asserting output.
    const fmt: FileFormatter = .{
        .alloc = alloc,
        .config = &cfg,
    };
    try fmt.format(&buf.writer);

    //std.log.warn("{s}", .{buf.written()});
}

test "format default config changed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"font-size" = 42;

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    // We just make sure this works without errors. We aren't asserting output.
    const fmt: FileFormatter = .{
        .alloc = alloc,
        .config = &cfg,
        .changed = true,
    };
    try fmt.format(&buf.writer);

    //std.log.warn("{s}", .{buf.written()});
}
