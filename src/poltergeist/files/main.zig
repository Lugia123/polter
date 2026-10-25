//! Files in a group's working directories: which directories there are, what
//! may be read of them and written to them (task 2145,
//! `polter-artifacts/2145/PLAN.md` §1). Pure and tested off the hosts; the
//! app gathers (`App.controlPage`) and the hosts draw.

pub const Workdirs = @import("Workdirs.zig");
pub const Access = @import("Access.zig");
pub const Text = @import("Text.zig");

test {
    _ = Workdirs;
    _ = Access;
    _ = Text;
}
