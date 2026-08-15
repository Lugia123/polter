//! Poltergeist: the capability layer that lets one "supervisor" terminal
//! watch over several AI agent terminals.
//!
//! Ghostty's side of Poltergeist is deliberately small. It is a sensor and a
//! pipe: it measures how long a terminal's visible screen has gone unchanged
//! and reports that, and it carries messages. Every semantic judgement --
//! is the agent thinking, stuck, or done; should it be nudged or left alone
//! -- belongs to the supervisor AI, not to this code.
//!
//! See `docs/poltergeist/README.md` for the design, and
//! `docs/poltergeist/sensing.md` for why the sensing layer is this thin.

pub const Bus = @import("Bus.zig");
pub const Fingerprint = @import("Fingerprint.zig");
pub const rpc = @import("rpc.zig");
pub const Sampler = @import("Sampler.zig");
pub const Watcher = @import("Watcher.zig");
pub const screen = @import("screen.zig");

test {
    _ = Bus;
    _ = Fingerprint;
    _ = rpc;
    _ = Sampler;
    _ = Watcher;
    _ = screen;
}
