const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// Nothing to wake: this runtime has no app loop. The core calls this
    /// after putting a message in the app mailbox, to make the loop come
    /// round and drain it; with no loop the message simply waits in the
    /// queue for whoever is driving.
    ///
    /// ⚠️ Without this, `App.Mailbox.push` cannot be instantiated under this
    /// runtime -- and since this is the runtime the default test build uses,
    /// that meant **no test could reach the app mailbox at all**. Zig only
    /// analyses functions that are called, so nothing complained; the path
    /// was simply never compiled. This file exists to make tests compile
    /// (see its first commit) and this is the same thing again.
    pub fn wakeup(self: *const App) void {
        _ = self;
    }

    /// Always return false as there is no apprt to communicate with.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }
};
pub const Surface = struct {};
