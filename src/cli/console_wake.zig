//! Waking a thread that is waiting on the console's input (task 2059).
//!
//! The conversations view reads its keys on a thread of its own (vaxis'
//! `Loop`), and on Windows that thread sits in `ReadConsoleInputW` until
//! something arrives. Leaving, the view asks the loop to stop and waits for
//! the thread -- and vaxis' way of getting it out of the read, writing a
//! cursor-position request so that the reply arrives as input, does not
//! reach it there. So `q` set the flag, the view stopped drawing, and the
//! process went on until the next key: measured on Windows, round six, as
//! "q and Ctrl+Q quit only on the key after".
//!
//! What gets it out is an input record of our own, put into the console's
//! input buffer: the read returns, the loop sees its flag and ends. A
//! released Shift is the record, because it is one vaxis turns into an
//! event -- a record it drops would leave the read waiting again -- and one
//! nothing in the view does anything with.
//!
//! The records are declared here rather than borrowed from vaxis, whose
//! console types only exist in a non-test Windows build: this file can be
//! compiled for Windows on its own, which is how it is checked.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const KEY_EVENT: windows.WORD = 0x0001;
const VK_SHIFT: windows.WORD = 0x10;

const KeyEventRecord = extern struct {
    bKeyDown: windows.BOOL,
    wRepeatCount: windows.WORD,
    wVirtualKeyCode: windows.WORD,
    wVirtualScanCode: windows.WORD,
    uChar: windows.WCHAR,
    dwControlKeyState: windows.DWORD,
};

/// `INPUT_RECORD`: a `WORD` and a union the size of its largest member, a
/// mouse event's 16 bytes, at offset 4.
const InputRecord = extern struct {
    EventType: windows.WORD,
    Event: extern union {
        KeyEvent: KeyEventRecord,
        bytes: [16]u8,
    },
};

extern "kernel32" fn WriteConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: [*]const InputRecord,
    nLength: windows.DWORD,
    lpNumberOfEventsWritten: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// Put a released Shift into the input of the console `stdin` reads; true
/// when it went in.
pub fn wake(stdin: windows.HANDLE) bool {
    var record: InputRecord = .{ .EventType = KEY_EVENT, .Event = .{ .bytes = @splat(0) } };
    record.Event.KeyEvent = .{
        .bKeyDown = .FALSE,
        .wRepeatCount = 1,
        .wVirtualKeyCode = VK_SHIFT,
        .wVirtualScanCode = 0,
        .uChar = 0,
        .dwControlKeyState = 0,
    };
    var written: windows.DWORD = 0;
    return WriteConsoleInputW(stdin, @ptrCast(&record), 1, &written) != .FALSE and written == 1;
}

// `wake` itself, compiled: only for Windows, where kernel32 is there to
// link against. Checked with `zig test -target x86_64-windows-gnu
// --test-no-exec` on this file.
test {
    if (comptime builtin.os.tag == .windows) _ = &wake;
}

test "2059: an input record is the size Windows reads" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(InputRecord));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(InputRecord, "Event"));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(KeyEventRecord));
}
