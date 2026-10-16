//! Poltergeist: the capability layer that lets one "supervisor" terminal
//! watch over several AI agent terminals.
//!
//! Ghostty's side of Poltergeist is deliberately small. It is a sensor and a
//! pipe: it measures how long a terminal's visible screen has gone unchanged
//! and reports that, and it carries messages. Every semantic judgement --
//! is the agent thinking, stuck, or done; should it be nudged or left alone
//! -- belongs to the supervisor AI, not to this code.
//!
//! See `dev-docs/poltergeist/README.md` for the design, and
//! `dev-docs/poltergeist/sensing.md` for why the sensing layer is this thin.

pub const Resident = @import("Resident.zig");
pub const Bus = @import("Bus.zig");
pub const Chat = @import("Chat.zig");
pub const ControlAct = @import("ControlAct.zig");
pub const ControlAsk = @import("ControlAsk.zig");
pub const ControlFix = @import("ControlFix.zig");
pub const ControlNotify = @import("ControlNotify.zig");
pub const ControlRoom = @import("ControlRoom.zig");
pub const ControlWake = @import("ControlWake.zig");
pub const ShellSteps = @import("ShellSteps.zig");
pub const Attention = @import("Attention.zig");
pub const actions = @import("actions.zig");
pub const arrange = @import("arrange.zig");
pub const keys = @import("keys.zig");
pub const draft = @import("draft.zig");
pub const prompts = @import("prompts.zig");
pub const login_path = @import("login_path.zig");
pub const workdir = @import("workdir.zig");
pub const ChatLog = @import("ChatLog.zig");
pub const MentionRetry = @import("MentionRetry.zig");
pub const fresh_assign = @import("fresh_assign.zig");
pub const process_info = @import("process_info.zig");
pub const Feed = @import("Feed.zig");
pub const GroupLog = @import("GroupLog.zig");
pub const GroupRename = @import("GroupRename.zig");
pub const group_stores = @import("group_stores.zig");
pub const daylog = @import("daylog.zig");
pub const Fingerprint = @import("Fingerprint.zig");
pub const inventory = @import("inventory.zig");
pub const provision = @import("provision.zig");
pub const quota = @import("quota.zig");
pub const QuotaWatch = @import("QuotaWatch.zig");
pub const rpc = @import("rpc.zig");
pub const Sampler = @import("Sampler.zig");
pub const Server = @import("Server.zig");
pub const Plugin = @import("Plugin.zig");
pub const agent_cli = @import("agent_cli.zig");
pub const Identities = @import("Identities.zig");
pub const TakeOver = @import("TakeOver.zig");
pub const agent_event = @import("agent_event.zig");
pub const PluginLog = @import("PluginLog.zig");
pub const notes = @import("notes.zig");
pub const notify = @import("notify.zig");
pub const persona = @import("persona.zig");
pub const official = @import("official.zig");
pub const PersonaStore = @import("PersonaStore.zig");
pub const PersonaWaits = @import("PersonaWaits.zig");
pub const screenshot = @import("screenshot.zig");
pub const reap = @import("reap.zig");
pub const report = @import("report.zig");
pub const scrub = @import("scrub.zig");
pub const secret = @import("secret.zig");
pub const Session = @import("Session.zig");
pub const Projects = @import("Projects.zig");
pub const Tasks = @import("Tasks.zig");
pub const TaskLog = @import("TaskLog.zig");
pub const StatsLog = @import("StatsLog.zig");
pub const Retention = @import("Retention.zig");
pub const SessionLog = @import("SessionLog.zig");
pub const TerminalMeta = @import("TerminalMeta.zig");
pub const Records = @import("Records.zig");
pub const Sweeper = @import("Sweeper.zig");
pub const RecordTools = @import("RecordTools.zig");
pub const Storage = @import("Storage.zig");
pub const skill = @import("skill.zig");
pub const skill_store = @import("skill_store.zig");
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
    _ = Attention;
    _ = actions;
    _ = arrange;
    _ = keys;
    _ = draft;
    _ = prompts;
    _ = login_path;
    _ = workdir;
    _ = Resident;
    _ = Bus;
    _ = agent_event;
    _ = Chat;
    _ = ControlAct;
    _ = @import("HostProjectActs.zig");
    _ = ControlAsk;
    _ = ControlFix;
    _ = ControlNotify;
    _ = ControlRoom;
    _ = ControlWake;
    _ = ShellSteps;
    _ = ChatLog;
    _ = MentionRetry;
    _ = fresh_assign;
    _ = process_info;
    _ = Feed;
    _ = GroupLog;
    _ = GroupRename;
    _ = group_stores;
    _ = daylog;
    _ = Fingerprint;
    _ = inventory;
    _ = notes;
    _ = StatsLog;
    _ = Retention;
    _ = SessionLog;
    _ = TerminalMeta;
    _ = Records;
    _ = Sweeper;
    _ = RecordTools;
    _ = Storage;
    _ = notify;
    _ = quota;
    _ = QuotaWatch;
    _ = persona;
    _ = PersonaStore;
    _ = PersonaWaits;
    _ = Plugin;
    _ = agent_cli;
    _ = Identities;
    _ = TakeOver;
    _ = PluginLog;
    _ = reap;
    _ = report;
    _ = provision;
    _ = rpc;
    _ = Sampler;
    _ = scrub;
    _ = secret;
    _ = Server;
    _ = Session;
    _ = Tasks;
    _ = TaskLog;
    _ = skill;
    _ = skill_store;
    _ = official;
    _ = Transcript;
    _ = Watcher;
    _ = wire;
    _ = screen;
    _ = screenshot;
}
