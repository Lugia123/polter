const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
pub const resourcesDir = internal_os.resourcesDir;

/// ⚠️ **What is *not* done here is a contract, and nothing writes it down.**
///
/// The types in this file are deliberately almost empty, and code elsewhere
/// depends on that emptiness without ever saying so. Adding a line to one of
/// these functions can therefore break callers while changing no control
/// flow, producing no compile error, and showing up only at runtime -- which
/// has already happened once: `wakeup` did nothing, so callers passed it an
/// `undefined` pointer quite safely; the moment it counted a call it
/// followed that pointer, and `undefined` became a segfault at
/// 0xaaaaaaaaaaaaaaaa in tests that happened to reach the send.
///
/// So before adding anything here, work out what each caller relies on this
/// *not* doing. As of this writing:
///
///   - `wakeup`: relied on not to follow `self`. It does now, so every
///     caller must pass a real object.
///   - `performIpc`: takes no `self` at all, so nothing can be relied on
///     there.
///   - `Surface`: has no fields and nothing in the tree constructs one, so
///     there is nothing to rely on **today**. ⚠️ That is a fact about the
///     current tree, not a property of the type -- give it a field and this
///     exercise has to be done again from scratch.
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
    /// How many times `wakeup` has been called.
    ///
    /// ⚠️ **This is here for tests, and this is the right place for it.**
    /// `none` produces no executable at all (see `apprt/runtime.zig`), so
    /// this counter cannot reach any shipped artifact -- unlike a counter on
    /// a real runtime, which would be dead weight in the product to serve a
    /// test. It records and nothing else: `wakeup` still does exactly what
    /// it did, and still returns to the same place.
    ///
    /// ⚠️ **Do not delete this as leftover debugging.** Without it, "the
    /// consumer was never woken" and "the test never observed the wake"
    /// produce identical readings, and the tests that assert a send wakes
    /// the app loop would pass whether or not the wiring was there.
    wakeups: usize = 0,

    /// Takes `*App` rather than `*const App`: the core reaches this through
    /// a mutable pointer anyway (`App.tick` takes `rt_app: *apprt.App`), and
    /// the GTK runtime already declares it this way, so nothing about the
    /// signature was fixed. Writing through a `*const` would have needed a
    /// cast, and a cast that writes through a const pointer is undefined
    /// behaviour whenever the thing really is const -- a shape worth not
    /// leaving around to be copied.
    pub fn wakeup(self: *App) void {
        self.wakeups += 1;
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

test "the wakeup counter counts wakeups, and only wakeups" {
    // ⚠️ **This runs before anything relies on the counter, on purpose.**
    // Tests further up assert that sending into the app mailbox wakes the
    // app loop, and they read that off this number. If the number never
    // moved -- a counter that was never wired up -- those tests would pass
    // for a tree in which nothing wakes anything, and "the consumer was not
    // woken" and "the instrument is not connected" would be the same
    // reading. So: it does not move on its own, and it moves when called.
    var app: App = .{};
    try std.testing.expectEqual(@as(usize, 0), app.wakeups);

    app.wakeup();
    try std.testing.expectEqual(@as(usize, 1), app.wakeups);

    app.wakeup();
    app.wakeup();
    try std.testing.expectEqual(@as(usize, 3), app.wakeups);
}
