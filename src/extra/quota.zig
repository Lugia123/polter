//! Comptime branch quotas for the generators in this directory.
//!
//! bash, fish, vim and zsh each build their output at comptime by walking
//! the config options (and, for the shell completions, the CLI actions and
//! their options). Every one of those costs backward branches, so a fixed
//! `@setEvalBranchQuota` is a limit the next added option eventually runs
//! into. They all used to be 50000, and `project-scrollback-limit-bytes`
//! took fish past it with under 200 to spare.
//!
//! So the quota is computed from what is walked. On 2026-09-27 the walk was
//! 666 items (`items`), and each generator's real need was measured by
//! bisecting `@setEvalBranchQuota` until the build failed
//! (`zig build -Dtarget=x86_64-windows-gnu`, which builds the generated
//! resources):
//!
//!   generator  needed           bound here  margin
//!   bash       16,991 - 17,187  85,248      5.0x
//!   zsh        15,625 - 16,406  85,248      5.2x
//!   vim        21,875 - 22,656  85,248      3.8x
//!   fish       50,000 - 50,195  433,776     8.6x  (+ 174,264 bytes of help text)
//!
//! vim, the hungriest per item, used about 34 branches per item for both
//! passes together; the bound allows 128 (2 x `per_item`), so every item
//! added grows the bound faster than it grows the need. Too high a bound
//! costs nothing: the quota only decides how long a comptime loop that never
//! ends runs before the compiler reports it.
//!
//! sublime is not here: its walk is a `for` over the field list joined with
//! `++`, and it builds with a quota of 1 -- it does not grow with the config.

const Config = @import("../config/Config.zig");
const Action = @import("../cli.zig").ghostty.Action;

/// Charged for every config option, enum or flag member, CLI action and CLI
/// option the generators walk.
pub const per_item = 64;

/// The quota for a generator that walks the config and the CLI actions,
/// twice (once to measure the output, once to write it).
pub fn configWalk() comptime_int {
    return 2 * per_item * items();
}

/// How many things `configWalk` charges for.
pub fn items() comptime_int {
    comptime {
        const config_fields = @typeInfo(Config).@"struct".fields;
        const actions = @typeInfo(Action).@"enum".fields;
        // **No `@setEvalBranchQuota` here.** A quota can only be raised, and a
        // raise made here would stay in force for the caller -- which then
        // runs under this number instead of the one computed from it. Walking
        // the field lists costs almost nothing, as sublime's quota of 1 shows.

        var total: comptime_int = 0;
        for (config_fields) |field| total += 1 + memberCount(field.type);
        for (actions) |action| {
            total += 1;
            const options = @field(Action, action.name).options();
            for (@typeInfo(options).@"struct".fields) |opt| {
                total += 1 + memberCount(opt.type);
            }
        }
        return total;
    }
}

/// The names a generator may list for a value of type `T`.
fn memberCount(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .@"enum" => |info| info.fields.len,
        .@"struct" => |info| info.fields.len,
        .optional => |info| memberCount(info.child),
        else => 0,
    };
}
