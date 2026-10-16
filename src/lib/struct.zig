const std = @import("std");
const testing = std.testing;
const Target = @import("target.zig").Target;

/// Create a struct type that is C ABI compatible from a Zig struct type.
///
/// When the target is `.zig`, the original struct type is returned as-is.
/// When the target is `.c`, the struct is recreated with an `extern` layout,
/// ensuring a stable, C-compatible memory layout.
///
/// This handles packed structs by resolving zero alignments to the natural
/// alignment of each field's type, since extern structs require explicit
/// alignment. This means packed struct fields like `bool` will take up
/// their full size (1 byte) rather than being bit-packed.
pub fn Struct(
    comptime target: Target,
    comptime Zig: type,
) type {
    return switch (target) {
        .zig => Zig,
        .c => c: {
            const info = @typeInfo(Zig).@"struct";
            var names: [info.fields.len][]const u8 = undefined;
            var types: [info.fields.len]type = undefined;
            var attrs: [info.fields.len]std.builtin.Type.StructField.Attributes = undefined;

            for (info.fields, &names, &types, &attrs) |field, *name, *ty, *attr| {
                name.* = field.name;
                ty.* = field.type;
                attr.* = .{
                    .@"align" = field.alignment,
                    .@"comptime" = field.is_comptime,
                    .default_value_ptr = field.default_value_ptr,
                };
            }

            break :c @Struct(.@"extern", null, &names, &types, &attrs);
        },
    };
}

/// Returns true if a struct of type `T` with size `size` can set
/// field `field` (if it fits within the size). This is used for ABI
/// compatibility for structs that have an explicit size field.
pub fn sizedFieldFits(
    comptime T: type,
    size: usize,
    comptime field: []const u8,
) bool {
    const offset = @offsetOf(T, field);
    const field_size = @sizeOf(@FieldType(T, field));
    return size >= offset + field_size;
}

test "sizedFieldFits boundary checks" {
    const Sized = extern struct {
        size: usize,
        a: u8,
        b: u32,
    };

    const size_required = @offsetOf(Sized, "size") + @sizeOf(@FieldType(Sized, "size"));
    const a_required = @offsetOf(Sized, "a") + @sizeOf(@FieldType(Sized, "a"));
    const b_required = @offsetOf(Sized, "b") + @sizeOf(@FieldType(Sized, "b"));

    try testing.expect(sizedFieldFits(Sized, size_required, "size"));
    try testing.expect(!sizedFieldFits(Sized, size_required - 1, "size"));

    try testing.expect(sizedFieldFits(Sized, a_required, "a"));
    try testing.expect(!sizedFieldFits(Sized, a_required - 1, "a"));

    try testing.expect(sizedFieldFits(Sized, b_required, "b"));
    try testing.expect(!sizedFieldFits(Sized, b_required - 1, "b"));
}

test "sizedFieldFits respects alignment padding" {
    const Sized = extern struct {
        size: usize,
        a: u8,
        b: u32,
    };

    const up_to_padding = @offsetOf(Sized, "b");
    try testing.expect(sizedFieldFits(Sized, up_to_padding, "a"));
    try testing.expect(!sizedFieldFits(Sized, up_to_padding, "b"));
}

test "packed struct converts to extern with full-size bools" {
    const Packed = packed struct {
        flag1: bool,
        flag2: bool,
        value: u8,
    };

    const C = Struct(.c, Packed);
    const info = @typeInfo(C).@"struct";

    try testing.expectEqual(.@"extern", info.layout);
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "flag1")));
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "flag2")));
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "value")));
    try testing.expectEqual(@as(usize, 3), @sizeOf(C));
}

/// Verify that the extern struct (or extern union) `Zig` has the same
/// layout as the C type `c_name` in `ghostty.h`: the same fields, each at
/// the same offset with the same size, and the same size and alignment
/// overall. They are one piece of memory written from two sides -- the host
/// fills it by the header, the core reads it by the Zig declaration -- and
/// neither compiler can see the other's, so a reordered, missing or
/// resized field compiles on both sides and is read from the wrong bytes.
///
/// Fields are matched by name, not by position, so two adjacent fields of
/// the same type that are swapped on one side are still caught. Where the
/// two sides name a field differently, `renames` maps the Zig name to the C
/// name, e.g. `.{ .coord_tag = "coord" }`.
///
/// Every mismatch is logged before failing, so one run names all of them.
/// Like `checkGhosttyHEnum`, this should only ever be called inside a
/// `test` because the `ghostty.h` module is only available then.
pub fn checkGhosttyHStruct(
    comptime Zig: type,
    comptime c_name: []const u8,
    comptime renames: anytype,
) !void {
    const c = @import("ghostty.h");
    const C = @field(c, c_name);
    const is_union = @typeInfo(Zig) == .@"union";
    const z_fields = std.meta.fields(Zig);
    const c_fields = std.meta.fields(C);
    var ok = true;

    inline for (z_fields) |f| {
        const cn: []const u8 = comptime if (@hasField(@TypeOf(renames), f.name))
            @field(renames, f.name)
        else
            f.name;
        if (comptime !@hasField(C, cn)) {
            std.log.err("{s}.{s}: " ++ c_name ++ " has no field {s}", .{ @typeName(Zig), f.name, cn });
            ok = false;
        } else {
            const z_size = @sizeOf(f.type);
            const c_size = @sizeOf(@FieldType(C, cn));
            if (z_size != c_size) {
                std.log.err("{s}.{s} is {d} bytes but " ++ c_name ++ ".{s} is {d}", .{ @typeName(Zig), f.name, z_size, cn, c_size });
                ok = false;
            }
            if (!is_union) {
                const z_off = @offsetOf(Zig, f.name);
                const c_off = @offsetOf(C, cn);
                if (z_off != c_off) {
                    std.log.err("{s}.{s} is at offset {d} but " ++ c_name ++ ".{s} is at {d}", .{ @typeName(Zig), f.name, z_off, cn, c_off });
                    ok = false;
                }
            }
        }
    }

    // A field the header has and the Zig side does not: the core never
    // reads it, and every Zig field after it is read from the wrong place.
    inline for (c_fields) |cf| {
        const known = comptime known: {
            for (z_fields) |f| {
                const cn: []const u8 = if (@hasField(@TypeOf(renames), f.name))
                    @field(renames, f.name)
                else
                    f.name;
                if (std.mem.eql(u8, cn, cf.name)) break :known true;
            }
            break :known false;
        };
        if (!known) {
            std.log.err(c_name ++ ".{s} has no counterpart in {s}", .{ cf.name, @typeName(Zig) });
            ok = false;
        }
    }

    if (@sizeOf(Zig) != @sizeOf(C)) {
        std.log.err("{s} is {d} bytes but " ++ c_name ++ " is {d}", .{ @typeName(Zig), @sizeOf(Zig), @sizeOf(C) });
        ok = false;
    }
    if (@alignOf(Zig) != @alignOf(C)) {
        std.log.err("{s} aligns to {d} but " ++ c_name ++ " to {d}", .{ @typeName(Zig), @alignOf(Zig), @alignOf(C) });
        ok = false;
    }

    try testing.expect(ok);
}
