//! Files in a group's working directories: which directories there are, what
//! may be read of them and written to them (task 2145,
//! `polter-artifacts/2145/PLAN.md` §1). Pure and tested off the hosts; the
//! app gathers (`App.controlPage`) and the hosts draw.

pub const Workdirs = @import("Workdirs.zig");
pub const Access = @import("Access.zig");
pub const Text = @import("Text.zig");
pub const Diff = @import("Diff.zig");
pub const Merge = @import("Merge.zig");
pub const Write = @import("Write.zig");
pub const Locks = @import("Locks.zig");
pub const Recent = @import("Recent.zig");
pub const Watch = @import("Watch.zig");
pub const Tickets = @import("Tickets.zig");

test {
    _ = Workdirs;
    _ = Access;
    _ = Text;
    _ = Diff;
    _ = Merge;
    _ = Write;
    _ = Locks;
    _ = Recent;
    _ = Watch;
    _ = Tickets;
}
