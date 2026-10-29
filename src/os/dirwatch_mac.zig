//! FSEvents half of `dirwatch.zig`. Per-file events, merged over 0.3 s; the
//! stream delivers on a private serial dispatch queue. **`stop` waits for
//! the callbacks already queued** (`dispatch_sync_f` on that queue), so the
//! owner can free what the callback uses once it returns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dirwatch = @import("dirwatch.zig");

const Stream = *anyopaque;

const Context = extern struct {
    version: isize = 0,
    info: ?*anyopaque = null,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copy_description: ?*const anyopaque = null,
};

const EventCallback = *const fn (
    stream: Stream,
    info: ?*anyopaque,
    count: usize,
    paths: [*]const [*:0]const u8,
    flags: [*]const u32,
    ids: [*]const u64,
) callconv(.c) void;

extern "c" fn FSEventStreamCreate(
    allocator: ?*anyopaque,
    callback: EventCallback,
    context: *const Context,
    paths: *anyopaque,
    since: u64,
    latency: f64,
    flags: u32,
) ?Stream;
extern "c" fn FSEventStreamSetDispatchQueue(stream: Stream, queue: *anyopaque) void;
extern "c" fn FSEventStreamStart(stream: Stream) bool;
extern "c" fn FSEventStreamStop(stream: Stream) void;
extern "c" fn FSEventStreamInvalidate(stream: Stream) void;
extern "c" fn FSEventStreamRelease(stream: Stream) void;
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_release(obj: *anyopaque) void;
extern "c" fn dispatch_sync_f(queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, len: isize, encoding: u32, is_external: bool) ?*anyopaque;
extern "c" fn CFArrayCreate(alloc: ?*anyopaque, values: [*]const ?*anyopaque, count: isize, callbacks: *const anyopaque) ?*anyopaque;
extern "c" fn CFRelease(obj: *anyopaque) void;
extern "c" var kCFTypeArrayCallBacks: u8;

const k_utf8: u32 = 0x08000100;
const k_since_now: u64 = std.math.maxInt(u64);
const k_file_events: u32 = 0x00000010;
/// Without it no RootChanged event is ever sent.
const k_watch_root: u32 = 0x00000004;
const latency_s: f64 = 0.3;

const Mac = @This();

alloc: Allocator,
stream: Stream,
queue: *anyopaque,
cb: dirwatch.Callback,
ctx: ?*anyopaque,

fn onEvents(
    _: Stream,
    info: ?*anyopaque,
    count: usize,
    paths: [*]const [*:0]const u8,
    flags: [*]const u32,
    _: [*]const u64,
) callconv(.c) void {
    const self: *Mac = @ptrCast(@alignCast(info.?));
    for (0..count) |i| {
        if (dirwatch.fseventsOverflow(flags[i])) self.cb(self.ctx, .overflow);
        self.cb(self.ctx, .{ .path = std.mem.span(paths[i]) });
    }
}

fn noop(_: ?*anyopaque) callconv(.c) void {}

pub fn start(alloc: Allocator, root: []const u8, cb: dirwatch.Callback, ctx: ?*anyopaque) dirwatch.Error!*Mac {
    const self = try alloc.create(Mac);
    errdefer alloc.destroy(self);

    const s = CFStringCreateWithBytes(null, root.ptr, @intCast(root.len), k_utf8, false) orelse return error.WatchFailed;
    defer CFRelease(s);
    const vals = [_]?*anyopaque{s};
    const arr = CFArrayCreate(null, &vals, 1, &kCFTypeArrayCallBacks) orelse return error.WatchFailed;
    defer CFRelease(arr);

    const queue = dispatch_queue_create("polter.dirwatch", null) orelse return error.WatchFailed;
    errdefer dispatch_release(queue);

    self.* = .{ .alloc = alloc, .stream = undefined, .queue = queue, .cb = cb, .ctx = ctx };
    const context: Context = .{ .info = self };
    const stream = FSEventStreamCreate(null, onEvents, &context, arr, k_since_now, latency_s, k_file_events | k_watch_root) orelse
        return error.WatchFailed;
    FSEventStreamSetDispatchQueue(stream, queue);
    if (!FSEventStreamStart(stream)) {
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease(stream);
        return error.WatchFailed;
    }
    self.stream = stream;
    return self;
}

pub fn stop(self: *Mac) void {
    FSEventStreamStop(self.stream);
    FSEventStreamInvalidate(self.stream);
    // Neither call above waits for a callback that is running or queued. The
    // queue is serial and `stop` is never called on it, so a block run on it
    // returns only after everything queued before has finished.
    dispatch_sync_f(self.queue, null, noop);
    FSEventStreamRelease(self.stream);
    dispatch_release(self.queue);
    self.alloc.destroy(self);
}
