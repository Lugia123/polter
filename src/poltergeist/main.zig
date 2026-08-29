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

pub const Archive = @import("Archive.zig");
pub const Bus = @import("Bus.zig");
pub const Chat = @import("Chat.zig");
pub const actions = @import("actions.zig");
pub const ChatLog = @import("ChatLog.zig");
pub const Feed = @import("Feed.zig");
pub const daylog = @import("daylog.zig");
pub const Fingerprint = @import("Fingerprint.zig");
pub const provision = @import("provision.zig");
pub const rpc = @import("rpc.zig");
pub const Sampler = @import("Sampler.zig");
pub const Server = @import("Server.zig");
pub const Plugin = @import("Plugin.zig");
pub const notify = @import("notify.zig");
pub const reap = @import("reap.zig");
pub const report = @import("report.zig");
pub const secret = @import("secret.zig");
pub const Session = @import("Session.zig");
pub const skill = @import("skill.zig");
pub const Transcript = @import("Transcript.zig");
pub const Watcher = @import("Watcher.zig");
pub const wire = @import("wire.zig");
pub const screen = @import("screen.zig");

// Every module in this package, and the list is exhaustive on purpose.
//
// Zig only analyses what is referenced, so a module named above but absent
// here has tests that are never compiled -- they do not fail, they do not
// run, and nothing says so. Five of them sat like that (`ChatLog`,
// `Plugin`, `notify`, `secret`, `Session`), which is how a bug in the
// restore path lived behind a file full of passing-looking tests.
//
// Adding an import above means adding a line here.
test {
    _ = @import("server_test.zig");
    _ = actions;
    _ = Archive;
    _ = Bus;
    _ = Chat;
    _ = ChatLog;
    _ = Feed;
    _ = daylog;
    _ = Fingerprint;
    _ = notify;
    _ = Plugin;
    _ = reap;
    _ = report;
    _ = provision;
    _ = rpc;
    _ = Sampler;
    _ = secret;
    _ = Server;
    _ = Session;
    _ = skill;
    _ = Transcript;
    _ = Watcher;
    _ = wire;
    _ = screen;
}
