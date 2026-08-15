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
pub const Chat = @import("Chat.zig");
pub const ChatLog = @import("ChatLog.zig");
pub const Fingerprint = @import("Fingerprint.zig");
pub const rpc = @import("rpc.zig");
pub const Sampler = @import("Sampler.zig");
pub const Server = @import("Server.zig");
pub const skill = @import("skill.zig");
pub const Watcher = @import("Watcher.zig");
pub const wire = @import("wire.zig");
pub const screen = @import("screen.zig");

test {
    _ = @import("server_test.zig");
    _ = Bus;
    _ = Chat;
    _ = Fingerprint;
    _ = rpc;
    _ = Sampler;
    _ = Server;
    _ = skill;
    _ = Watcher;
    _ = wire;
    _ = screen;
}
