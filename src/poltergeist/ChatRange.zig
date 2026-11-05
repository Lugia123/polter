//! Bounded, query-owned proofs of a captured physical chat range.
//! Capture and verification run on a worker. A scanner consumes the verified
//! bytes themselves; it never verifies a path and then reopens it for parsing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Tree = @import("daylog.zig").GroupTree;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const block_bytes: usize = 128 * 1024;
pub const work_slice_bytes: usize = 2 * 1024 * 1024;
pub const max_files: usize = 4096;
pub const max_blocks: usize = 131072; // 4 MiB of hashes, at most 16 GiB captured data.
pub const Error = Allocator.Error || error{ CursorStale, Cancelled, TooLarge };

pub const Location = struct { seq: u64, ordinal: u64, day: u32, part: u32, inode: u64, start: u64, end: u64, check: u64 };
pub const Observer = struct {
    ctx: *anyopaque,
    visit: *const fn (*anyopaque, File, u64, []const u8) Allocator.Error!void,
};
pub const Work = struct {
    observer: ?Observer = null,
    cancel: ?*const std.atomic.Value(bool),
    physical: usize = 0,
    pub fn check(self: *Work) error{Cancelled}!void {
        if (self.cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
    }
    fn charged(self: *Work, bytes: usize) error{Cancelled}!void {
        self.physical += bytes;
        if (self.physical >= work_slice_bytes) {
            self.physical = 0;
            std.Thread.yield() catch {};
        }
        try self.check();
    }
};

pub const File = struct {
    day: u32,
    part: u32,
    inode: u64,
    end: u64,
    blocks: []const [32]u8,
};

/// Shared immutably by a job and its tokens; lifetime is the manager's bounded
/// snapshot lifetime, never a process-global or permanent per-query index.
pub const Capture = struct {
    alloc: Allocator,
    files: []const File,
    locations: []const Location = &.{},

    pub fn create(alloc: Allocator, io: std.Io, tree: *const Tree, group: []const u8, work: *Work) Error!*Capture {
        try work.check();
        var all_days = try tree.days(alloc, group);
        defer all_days.deinit(alloc);
        if (all_days.items.len > max_files) return error.TooLarge;
        const self = try alloc.create(Capture);
        errdefer alloc.destroy(self);
        const files = try alloc.alloc(File, all_days.items.len);
        var count: usize = 0;
        errdefer {
            for (files[0..count]) |file| alloc.free(file.blocks);
            alloc.free(files);
        }
        const scratch = try alloc.alloc(u8, block_bytes);
        defer alloc.free(scratch);
        var blocks_left: usize = max_blocks;
        // Freeze every file bound before doing cold proof I/O. No new file or
        // append can expand this range while the initial proof is being built.
        for (all_days.items, files) |day, *file| {
            try work.check();
            const path = try tree.partPath(alloc, group, day.day, day.part);
            defer alloc.free(path);
            const handle = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return error.CursorStale;
            defer handle.close(io);
            const stat = handle.stat(io) catch return error.CursorStale;
            if (stat.inode == 0) return error.CursorStale;
            const needed64 = std.math.divCeil(u64, stat.size, block_bytes) catch return error.TooLarge;
            if (needed64 > blocks_left) return error.TooLarge;
            const needed: usize = @intCast(needed64);
            blocks_left -= needed;
            file.* = .{ .day = day.day, .part = day.part, .inode = @intCast(stat.inode), .end = stat.size, .blocks = try alloc.alloc([32]u8, needed) };
            count += 1;
        }
        var file_index = files.len;
        while (file_index > 0) {
            file_index -= 1;
            const file = files[file_index];
            try work.check();
            const path = try tree.partPath(alloc, group, file.day, file.part);
            defer alloc.free(path);
            const handle = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return error.CursorStale;
            defer handle.close(io);
            try checkFile(io, handle, file);
            const hashes: [][32]u8 = @constCast(file.blocks);
            for (hashes, 0..) |*digest, index| {
                try work.check();
                const offset: u64 = @as(u64, @intCast(index)) * block_bytes;
                const n: usize = @intCast(@min(block_bytes, file.end - offset));
                const got = handle.readPositionalAll(io, scratch[0..n], offset) catch return error.CursorStale;
                if (got != n) return error.CursorStale;
                Sha256.hash(scratch[0..n], digest, .{});
                if (work.observer) |observer| try observer.visit(observer.ctx, file, offset, scratch[0..n]);
                try work.charged(got);
            }
            try checkFile(io, handle, file);
        }
        self.* = .{ .alloc = alloc, .files = files };
        return self;
    }
    pub fn destroy(self: *Capture) void {
        if (self.locations.len > 0) self.alloc.free(self.locations);
        for (self.files) |file| self.alloc.free(file.blocks);
        self.alloc.free(self.files);
        self.alloc.destroy(self);
    }
    pub fn locate(self: *const Capture, seq: u64) error{CursorStale}!?Location {
        var result: ?Location = null;
        for (self.locations) |location| if (location.seq == seq) {
            if (result != null) return error.CursorStale;
            result = location;
        };
        return result;
    }
    pub fn find(self: *const Capture, day: u32, part: u32) ?File {
        for (self.files) |file| if (file.day == day and file.part == part) return file;
        return null;
    }
    pub fn days(self: *const Capture, alloc: Allocator) Allocator.Error!Tree.Days {
        var result: Tree.Days = .empty;
        errdefer result.deinit(alloc);
        for (self.files) |file| try result.append(alloc, .{ .day = file.day, .part = file.part });
        return result;
    }
};

fn checkFile(io: std.Io, handle: std.Io.File, file: File) error{CursorStale}!void {
    const stat = handle.stat(io) catch return error.CursorStale;
    if (file.inode == 0 or stat.inode != file.inode or stat.size < file.end) return error.CursorStale;
}

/// A worker-local two-block cache. Its buffers are the only bytes a verified
/// scan parses. Each later job checks touched blocks against the original
/// immutable digests; normal append beyond captured end is irrelevant.
pub const Verifier = struct {
    capture: *const Capture,
    alloc: Allocator,
    io: std.Io,
    work: Work,
    storage: []u8,
    slots: [2]Slot = .{ .{}, .{} },
    replace: usize = 0,
    const Slot = struct { day: u32 = 0, part: u32 = 0, index: u64 = 0, valid: bool = false, len: usize = 0 };

    pub fn init(alloc: Allocator, io: std.Io, capture: *const Capture, cancel: ?*const std.atomic.Value(bool)) Allocator.Error!Verifier {
        return .{ .capture = capture, .alloc = alloc, .io = io, .work = .{ .cancel = cancel }, .storage = try alloc.alloc(u8, 2 * block_bytes) };
    }
    pub fn deinit(self: *Verifier) void {
        self.alloc.free(self.storage);
    }

    pub fn read(self: *Verifier, handle: std.Io.File, day: u32, part: u32, target: []u8, offset: u64) error{ CursorStale, Cancelled }!usize {
        try self.work.check();
        const file = self.capture.find(day, part) orelse return error.CursorStale;
        try checkFile(self.io, handle, file);
        if (offset > file.end or target.len > file.end - offset) return error.CursorStale;
        var copied: usize = 0;
        while (copied < target.len) {
            try self.work.check();
            const at = offset + copied;
            const index = at / block_bytes;
            var selected: ?usize = null;
            for (self.slots, 0..) |slot, i| if (slot.valid and slot.day == day and slot.part == part and slot.index == index) {
                selected = i;
                break;
            };
            const slot_index = selected orelse blk: {
                const i = self.replace;
                self.replace = (i + 1) % 2;
                self.slots[i].valid = false;
                const start = index * block_bytes;
                const n: usize = @intCast(@min(block_bytes, file.end - start));
                const buffer = self.storage[i * block_bytes ..][0..n];
                const got = handle.readPositionalAll(self.io, buffer, start) catch return error.CursorStale;
                if (got != n or index >= file.blocks.len) return error.CursorStale;
                var digest: [32]u8 = undefined;
                Sha256.hash(buffer, &digest, .{});
                if (!std.mem.eql(u8, &digest, &file.blocks[@intCast(index)])) return error.CursorStale;
                try self.work.charged(got);
                self.slots[i] = .{ .day = day, .part = part, .index = index, .valid = true, .len = n };
                break :blk i;
            };
            const within: usize = @intCast(at % block_bytes);
            const count = @min(target.len - copied, self.slots[slot_index].len - within);
            @memcpy(target[copied..][0..count], self.storage[slot_index * block_bytes + within ..][0..count]);
            copied += count;
        }
        return copied;
    }
};
