//! ReadDirectoryChangesW half of `dirwatch.zig`. One thread issues an
//! **overlapped** read and waits (`WaitForMultipleObjects`) for it **or** the
//! stop event; `stop` sets the event and joins. A synchronous read cannot be
//! stopped reliably: a `CancelIoEx` that lands before the call is made
//! cancels nothing, and the thread then blocks until the next change.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dirwatch = @import("dirwatch.zig");

const HANDLE = *anyopaque;
const DWORD = u32;
const BOOL = i32;

extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: DWORD,
    share: DWORD,
    security: ?*anyopaque,
    disposition: DWORD,
    flags: DWORD,
    template: ?HANDLE,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn ReadDirectoryChangesW(
    dir: HANDLE,
    buffer: [*]align(4) u8,
    len: DWORD,
    subtree: BOOL,
    filter: DWORD,
    returned: ?*DWORD,
    overlapped: ?*Overlapped,
    completion: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(h: HANDLE, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ResetEvent(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForMultipleObjects(count: DWORD, handles: [*]const HANDLE, wait_all: BOOL, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetOverlappedResult(h: HANDLE, overlapped: *Overlapped, transferred: *DWORD, wait: BOOL) callconv(.winapi) BOOL;

const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: DWORD = 0,
    offset_high: DWORD = 0,
    event: ?HANDLE = null,
};

const list_directory: DWORD = 0x0001;
const share_all: DWORD = 0x7; // read | write | delete
const open_existing: DWORD = 3;
const backup_semantics: DWORD = 0x02000000;
const flag_overlapped: DWORD = 0x40000000;
const infinite: DWORD = 0xFFFFFFFF;
const notify_filter: DWORD = 0x1 | 0x2 | 0x8 | 0x10 | 0x40; // names, size, last write, creation

const Info = extern struct {
    next: DWORD,
    action: DWORD,
    name_len: DWORD, // bytes
    // name: [name_len / 2]u16 follows
};

const Win = @This();

alloc: Allocator,
root: []u8,
dir: HANDLE,
io_event: HANDLE,
stop_event: HANDLE,
cb: dirwatch.Callback,
ctx: ?*anyopaque,
stopping: std.atomic.Value(bool) = .init(false),
thread: ?std.Thread = null,

pub fn start(alloc: Allocator, root: []const u8, cb: dirwatch.Callback, ctx: ?*anyopaque) dirwatch.Error!*Win {
    const self = try alloc.create(Win);
    errdefer alloc.destroy(self);
    const root_copy = try alloc.dupe(u8, root);
    errdefer alloc.free(root_copy);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, root) catch return error.WatchFailed;
    defer alloc.free(wide);
    const h = CreateFileW(wide.ptr, list_directory, share_all, null, open_existing, backup_semantics | flag_overlapped, null) orelse
        return error.WatchFailed;
    if (@intFromPtr(h) == std.math.maxInt(usize)) return error.WatchFailed;
    errdefer _ = CloseHandle(h);
    // Auto-reset would lose a set that nobody was waiting on yet; both are
    // manual-reset, and the I/O one is reset by the loop before each read.
    const io_event = CreateEventW(null, 1, 0, null) orelse return error.WatchFailed;
    errdefer _ = CloseHandle(io_event);
    const stop_event = CreateEventW(null, 1, 0, null) orelse return error.WatchFailed;
    errdefer _ = CloseHandle(stop_event);
    self.* = .{ .alloc = alloc, .root = root_copy, .dir = h, .io_event = io_event, .stop_event = stop_event, .cb = cb, .ctx = ctx };
    self.thread = std.Thread.spawn(.{}, run, .{self}) catch return error.WatchFailed;
    return self;
}

fn run(self: *Win) void {
    var buf: [64 * 1024]u8 align(4) = undefined;
    var path_buf: [4096]u8 = undefined;
    const handles = [2]HANDLE{ self.io_event, self.stop_event };
    while (!self.stopping.load(.acquire)) {
        _ = ResetEvent(self.io_event);
        var ov: Overlapped = .{ .event = self.io_event };
        // The read could not even be issued (the directory went away, or
        // access changed): the watch is over, and the reader must look again.
        if (ReadDirectoryChangesW(self.dir, &buf, buf.len, 1, notify_filter, null, &ov, null) == 0) {
            self.cb(self.ctx, .overflow);
            return;
        }
        switch (dirwatch.windowsWait(WaitForMultipleObjects(2, &handles, 0, infinite))) {
            .io => {},
            .stop, .failed => {
                // The read is still pending and `buf`/`ov` are on this
                // stack: cancel it and wait until the system is done with
                // them before they go.
                _ = CancelIoEx(self.dir, &ov);
                var n: DWORD = 0;
                _ = GetOverlappedResult(self.dir, &ov, &n, 1);
                return;
            },
        }
        var got: DWORD = 0;
        if (GetOverlappedResult(self.dir, &ov, &got, 0) == 0) {
            self.cb(self.ctx, .overflow);
            return;
        }
        if (dirwatch.windowsOverflow(got)) {
            self.cb(self.ctx, .overflow); // the buffer overflowed: nothing to name
            continue;
        }
        var off: usize = 0;
        while (off + @sizeOf(Info) <= got) {
            const info: *const Info = @ptrCast(@alignCast(&buf[off]));
            const name_bytes = buf[off + @sizeOf(Info) ..][0..info.name_len];
            const name16: []const u16 = std.mem.bytesAsSlice(u16, @as([]align(2) u8, @alignCast(name_bytes)));
            const n = self.root.len + 1;
            // A name too long for the buffer (3 bytes a unit at worst) is
            // skipped, not cut.
            if (n + name16.len * 3 <= path_buf.len) {
                @memcpy(path_buf[0..self.root.len], self.root);
                path_buf[self.root.len] = '\\';
                const w = std.unicode.wtf16LeToWtf8(path_buf[n..], name16);
                if (!self.stopping.load(.acquire)) self.cb(self.ctx, .{ .path = path_buf[0 .. n + w] });
            }
            if (info.next == 0) break;
            off += info.next;
        }
    }
}

pub fn stop(self: *Win) void {
    self.stopping.store(true, .release);
    _ = SetEvent(self.stop_event);
    if (self.thread) |t| t.join();
    _ = CloseHandle(self.dir);
    _ = CloseHandle(self.io_event);
    _ = CloseHandle(self.stop_event);
    self.alloc.free(self.root);
    self.alloc.destroy(self);
}
