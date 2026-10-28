//! App is the primary GUI application for ghostty. This builds the window,
//! sets up the renderer, etc. The primary run loop is started by calling
//! the "run" function.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const apprt = @import("apprt.zig");
const Surface = @import("Surface.zig");
const input = @import("input.zig");
const configpkg = @import("config.zig");
const Config = configpkg.Config;
const BlockingQueue = @import("datastruct/main.zig").BlockingQueue;
const renderer = @import("renderer.zig");
const font = @import("font/main.zig");
const build_config = @import("build_config.zig");
const global = @import("global.zig");

const log = std.log.scoped(.app);

const poltergeistpkg = @import("poltergeist/main.zig");
const scrollback = @import("termio/scrollback.zig");

/// Least time between telling one terminal it has messages. Agents talking
/// to each other can produce a burst; being told once about all of it is
/// what a person would want too.
const chat_notice_gap_ms = 30 * std.time.ms_per_s;

/// A little past the end of the gap, so the sweep that comes back for a
/// message does not arrive a millisecond early and wait again.
const chat_notice_retry_margin_ms = 250;
const terminal = @import("terminal/main.zig");
const internal_os = @import("os/main.zig");

const SurfaceList = std.ArrayListUnmanaged(*apprt.Surface);

/// General purpose allocator
alloc: Allocator,

/// The list of surfaces that are currently active.
surfaces: SurfaceList,

/// Who is supervising whom. Lives on the app because supervision spans
/// surfaces; a surface only ever reports into it.
poltergeist: poltergeistpkg.Bus,

/// The personas the user has written, and what each terminal is wearing.
///
/// On the app rather than on a surface because the file is one file: every
/// terminal reads the same declarations, and only the wearing is per
/// terminal. Loaded lazily the first time anything asks, the same shape as
/// `ensurePoltergeistConfigText` -- a user with no `personas.json` should
/// not pay for a file read at startup.
personas: poltergeistpkg.PersonaStore,

/// Whether `personas` has been asked to read the file yet.
///
/// ⚠️ **Separate from `personas.loaded`**, which says whether the read
/// succeeded. This one says whether we have tried. The interface needs the
/// first to know it is still waiting and the second to know the answer, and
/// a single flag would make "not yet" and "nothing there" the same state --
/// the distinction the whole `stale` field exists for.
personas_attempted: bool = false,

/// The squad templates (`squads.json`, task 2449), read the first time
/// anything asks, for the reason `personas` is.
squads: poltergeistpkg.SquadStore,
squads_attempted: bool = false,

/// What each agent CLI on this machine has installed, as its adapter plugin
/// reports it. Filled on a thread of its own; see `agent_cli.Cache`.
poltergeist_agent_clis: poltergeistpkg.agent_cli.Cache,

/// How many turns of the app loop have gone by. `ownClis` reads
/// launchers.json once per round and keeps the answer in an arena, because
/// what it hands out points into it (`poltergeist_own_round`).
own_round: u64 = 0,

/// Who a hand-started agent is, by its adapter's word (task 1635); asked on
/// a thread, and `identity_changed` is raised when an answer is kept.
identities: poltergeistpkg.Identities,
identity_changed: std.atomic.Value(bool) = .init(false),

/// The terminals that have written down their last screenful and
/// scrollback as the application quits (task 2086,
/// `writeDownBeforeQuit`). Here and not on that function's stack: an IO
/// thread later than the wait still counts on it, after the wait has given
/// up and returned, and the app is never freed as it quits.
quit_written: std.atomic.Value(u32) = .init(0),

/// "Let the control room take over?" under way (task 1635,
/// `takeOverStep`), and the last one that stopped without taking over.
take_over: ?TakeOverRun = null,
take_over_failed: ?TakeOverFailed = null,

/// What the terminals have said to each other. Separate from the bus
/// because talking is not steering, and mixing them would blur that.
chat: poltergeistpkg.Chat,

/// What the host has said about projects, and nothing about any group:
/// which group has which project is `chat`'s.
projects: poltergeistpkg.Projects,

/// The launch a start is holding for the supervisor's pane of a project
/// the host has been ordered to open. One at a time, like the one waiting
/// for a tab; a second start replaces it.
project_launch: ?ProjectLaunch = null,

/// The tab a start opened for a group's supervisor because its project was
/// open and marked no pane as the supervisor's (task 1794), until the host
/// says that tab is the project's and its pane the marked one -- or the
/// terminal is gone. `Projects.seatFor` orders it seated meanwhile.
project_seating: ?poltergeistpkg.Projects.Seating = null,

/// Who is doing which piece of work, per group.
///
/// Beside the chat rather than inside it: a task is not a message, and the
/// two have different lifetimes -- a group's messages are trimmed as they
/// grow and its tasks are not. Both are pure models the app holds and
/// drives; see `poltergeist/Tasks.zig` for what it deliberately does not
/// store.
tasks: poltergeistpkg.Tasks,

/// The panel on disk, so the morning has one. Null when there is no state
/// directory, which is the same condition that leaves `chat_log` null.
task_log: ?poltergeistpkg.TaskLog = null,

/// The hourly snapshot of what each group looked like. Written by the
/// program, read by nobody until somebody goes looking; see `StatsLog`.
stats_log: ?poltergeistpkg.StatsLog = null,

/// Who was in which group, when, and what agent session they ran: what ties
/// a terminal's transcript to a group (task 1511). See `SessionLog`.
session_log: ?poltergeistpkg.SessionLog = null,

/// What each terminal was beside its transcript: agent session, project
/// tab, role (task 1511). See `TerminalMeta`.
terminal_meta: ?poltergeistpkg.TerminalMeta = null,

/// Who each terminal of an earlier run was, by the agent session it ran
/// last, so that one back as the same session takes up its tasks and its
/// groups (task 1978). Built once per process, the first time the state
/// is opened, out of what earlier runs wrote: opened again later it would
/// hand out what has already been taken up.
reclaim: ?poltergeistpkg.Reclaim = null,

/// What goes round -- logs, transcripts, screenshots -- kept to its limits
/// on a thread of its own: at start and every hour (task 1511). Started by
/// the first terminal, whether or not the chat log is on.
sweeper: ?poltergeistpkg.Sweeper = null,

/// The sweeper's limits, as the configuration last said them.
sweep_limits: SweepLimits = .{},

/// The state directory the sweeper works in. Owned.
sweep_state_dir: ?[]const u8 = null,

/// The limits last handed to the sweeper, to tell a change from a repeat.
sweep_limits_seen: SweepLimits = .{},

/// Where the host puts screenshots, as it said at the last configure.
/// Owned. Log Management counts and clears screenshots there.
sweep_shots_dir: ?[]const u8 = null,

/// Working out who was in the groups from before the session record --
/// reading the whole chat record, tens of megabytes on a used machine -- on
/// a thread of its own, so that the first start after an upgrade does not
/// hold the window still. What it found is written here, on this thread,
/// at the next tick (`storageTick`).
backfill_thread: ?std.Thread = null,
backfill_mutex: std.Io.Mutex = .init,
/// Set by the backfill thread under `backfill_mutex`, taken by `storageTick`.
backfill_found: ?poltergeistpkg.SessionLog.Inference = null,
/// App thread only: a backfill has started and its lines are not written.
/// The sweeper is held until they are, so that its first sweep knows which
/// old transcripts belong to a group.
backfill_pending: bool = false,

/// Something on a storage thread wants the app thread: a backfill is done,
/// or the sweeper has something to say. Read in `tick`.
storage_due: std.atomic.Value(bool) = .init(false),

/// The group shells on disk, so the list has last night's groups in it.
///
/// The same state directory and the same condition as `chat_log`, because
/// it is the same directory: a group's shell is written beside the record
/// it already has. What comes back is the name and the note, never the
/// members -- see `poltergeist/GroupLog.zig` for why that is where the
/// line falls rather than a compromise.
group_log: ?poltergeistpkg.GroupLog = null,

/// The control room's snapshot and what says when it changed
/// (`dev-docs/poltergeist/control-room.md`, 5.4).
control_room: poltergeistpkg.ControlRoom,

/// The cards the person has pressed "Fix" on, and as of which moment
/// (`ControlFix.Sent`). Not written down: a terminal's id does not outlive
/// the run, and a failure is the run's.
control_fix_sent: poltergeistpkg.ControlFix.Sent = .{},
/// How the control room's last ask of each group's supervisor went, for
/// the line under its row (task 1671).
control_asks: poltergeistpkg.ControlAsk = .{},

/// Something happened that the snapshot may not show yet. Read and cleared
/// by `tick`, which is the one place it is worked out.
control_dirty: bool = false,

/// The wake thread saying its moment has come. Set off the app thread.
control_due: std.atomic.Value(bool) = .init(false),

/// Started the first time there is a moment to wait for, so a session that
/// never has one never has the thread.
control_wake: ?poltergeistpkg.ControlWake = null,

/// What the control room's notifications have already dealt with
/// (`ControlNotify`, section 9 of the design).
control_notify: poltergeistpkg.ControlNotify = .empty,

/// What the host last said about its control room: in front or not, and
/// which cards are on screen (`ghostty_app_control_presence`).
control_sight: poltergeistpkg.ControlNotify.Sight = .none,

/// When a refused notice is to be offered again, on the bus's clock; null
/// when none is waiting. See `noticeRetryIn`.
notice_retry_ms: ?u64 = null,

/// The retry thread saying its moment has come. Set off the app thread.
notice_due: std.atomic.Value(bool) = .init(false),

/// An agent's connection closed (`Server.Submit.agent_gone`): look at who is
/// connected on the next tick, rather than at the next screen report,
/// which may never come (task 1668).
links_due: std.atomic.Value(bool) = .init(false),

/// Started the first time a notice is refused, so a session in which none
/// ever is never has the thread.
notice_wake: ?poltergeistpkg.ControlWake = null,

/// The supervisors' alarms (task 2148), read from `alarms.json` the first
/// time they are wanted.
alarms: ?poltergeistpkg.Alarms = null,
/// What wakes the app for an alarm or a silence reminder: one moment, the
/// earliest of either (`considerSupervisorClocks`).
alarm_wake: ?poltergeistpkg.ControlWake = null,
alarm_due: std.atomic.Value(bool) = .init(false),
/// Something that decides when the next alarm or reminder is due has
/// changed -- a request arrived, so a group, a supervisor or a task may be
/// new (`poltergeistRequest`, `controlAct`). Read and cleared by `tick`,
/// which is where the clock is worked out again.
///
/// ⚠️ **Why this exists at all**: `arm` used to be reached from three
/// places only -- the first tick, an alarm set or cancelled, and an alarm
/// ringing. A group whose tasks appear after that first tick, with an alarm
/// nobody has set, therefore had nothing to arm its first reminder, and the
/// only thing that ever armed one was an alarm operation or a restart
/// (measured 2026-10-24: first reminders 2 m 31 s and 5 m 27 s late on a
/// one-minute setting, with no upper bound at all).
alarm_dirty: bool = false,
/// A warning about the alarm wake thread has already been written. It fails
/// to start once and stays failed (`alarm_wake` stays null), and `tick`
/// asks again every time it runs -- without this the log would carry one
/// `alarms: no wake thread` line per tick for the life of the process,
/// which is how a real warning stops being read.
alarm_wake_warned: bool = false,

/// The thread reading every pane's process tree (task 1993, #1985), and
/// what it last read: memory and process count by terminal. Started on the
/// first tick, like the stall watch, and judged against each pane's lines
/// (`judgeResources`).
resource_sampler: ?poltergeistpkg.ResourceSampler = null,
/// The sampler saying a reading is ready. Set off the app thread.
resources_due: std.atomic.Value(bool) = .init(false),
resource_usage: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, poltergeistpkg.ledger.Usage) = .empty,
/// Each pane's last five minutes, for its card on the performance page
/// (task 2015, `ResourceRecent`): kept while it is read, dropped with it.
resource_recent: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, poltergeistpkg.ResourceRecent) = .empty,
/// The readings' count, each point's `seq`: a page asks for what came
/// after the last it has.
resource_seq: u64 = 0,
/// Each pane's last stop, for its card and its group's dot (task 2015).
resource_killed: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, poltergeistpkg.ResourcePage.Killed) = .empty,
/// Each pane's level at the last reading: a change of one is a change of
/// the control room's snapshot (`ControlRoom.Input.resource_levels`).
resource_tones: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, poltergeistpkg.ResourcePage.Tone) = .empty,
/// What each pane in the history is called, and in which group
/// (`ResourceNames`, `<state>/resources/names.json`).
resource_names: poltergeistpkg.ResourceNames = .{},
/// Which terminal ids ran the same agent session (task 2234): one row on
/// the performance page per session, not one per id. Filled when an agent
/// says its session (`noteSession`), and once at startup from what earlier
/// runs wrote down.
resource_sessions: poltergeistpkg.ResourcePage.SessionTable = .{},
/// The last answer `controlPage` gave and the request it was for, held for
/// a host's second call when the first could not take it.
page_req: std.ArrayListUnmanaged(u8) = .empty,
page_out: std.ArrayListUnmanaged(u8) = .empty,
page_held: bool = false,
/// When the readings were last written to the log (`resources_log_every_ms`).
resources_logged_ms: ?u64 = null,
/// Each judged pane's judge, and the lines it was judging by: lines that
/// changed start it again (`judge.State.fresh`).
resource_judges: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, ResourceJudge) = .empty,
/// The machine's memory pressure, told to the person only (#1985 §3.4).
resource_pressure: poltergeistpkg.judge.PressureState = .fresh,
/// Panes being stopped: what their note will say once `Stopper` is done.
resource_kills: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, ResourceKill) = .empty,
/// What Polter itself costs and whether the machine is running out (task
/// 2149). One allocation, taken when the sampler starts and never grown --
/// see `Overall`'s own note, and the test that reads the byte counter.
resource_overall: ?*poltergeistpkg.Overall = null,
/// A wall clock for the test that asks the two doors onto the overall
/// answer -- the page's and `resource_overview`'s -- for one answer and
/// compares them byte for byte (task 2149). Two reads of the real clock are
/// a millisecond apart often enough, and the answer carries the moment it
/// was made, so without this the test would be about the clock. Null in the
/// app, which reads the real one.
overall_wall_ms_for_test: ?i64 = null,
/// The panes the last reading was split by, with the chat surfaces among
/// them: what `resource_overview` needs to say which terminal a sidecar
/// belongs to (task 2149 §1).
resource_all_panes: []poltergeistpkg.ledger.Pane = &.{},
/// Seven days of each pane's levels, by half hour (task 1993, #1985 §9):
/// the slots in memory, and the day file they go into.
resource_history: poltergeistpkg.ResourceHistory = .{},
resource_history_file: ?poltergeistpkg.ResourceHistory.File = null,
/// Stops that finished, handed over from the stopper's thread.
resource_stopped_mutex: std.Io.Mutex = .init,
resource_stopped: std.ArrayListUnmanaged(ResourceStopped) = .empty,
resource_stops_running: std.atomic.Value(u32) = .init(0),
resource_stopped_due: std.atomic.Value(bool) = .init(false),

/// The thread that reads each account's allowance off disk, and the flag it
/// raises when what it read is new (`poltergeist/QuotaWatch.zig`). Null
/// until the control room first works anything out.
quota_watch: ?poltergeistpkg.QuotaWatch = null,
quota_changed: std.atomic.Value(bool) = .init(false),

/// T1 for the control room: `poltergeist-quiescence-after`.
control_still_ms: u64 = (poltergeistpkg.Sampler.Config{}).quiescence_ms,

/// The person's home directory, once it has been asked for. Owned unless
/// empty. See `controlHome`.
control_home: ?[]const u8 = null,

/// When it is acceptable to disturb the user. Null means any hour.
///
/// Only scheduling questions respect it; an authorisation prompt goes out
/// whatever the hour, because holding one back protects nobody's sleep --
/// it just leaves a terminal stopped until morning.
poltergeist_notify_window: ?poltergeistpkg.notify.Window = null,

/// When the group notes were last worked out. See `considerGroupNotes`.
poltergeist_notes_ms: ?u64 = null,

/// `poltergeist-task-idle-after` and `poltergeist-group-quiet-after`, in
/// milliseconds. Zero for either means that half says nothing.
poltergeist_task_idle_ms: u64 = 0,
poltergeist_group_quiet_ms: u64 = 0,

/// `poltergeist-silence-remind-after`, in milliseconds; zero switches it off
/// (task 2148).
poltergeist_silence_remind_ms: u64 = 15 * std.time.ms_per_min,

/// `poltergeist-worker-nudge-after`, in milliseconds. Zero switches it off.
poltergeist_worker_nudge_ms: u64 = 0,

/// `poltergeist-compact-after`, in bytes. Zero switches it off.
poltergeist_compact_after: usize = 0,

/// Tasks whose owner has already been reminded to report on them.
///
/// **Once per task.** A reminder that arrives every quarter of an hour is
/// one that gets ignored, and worse, one that competes with what the
/// supervisor is typing into the same box. Cleared when the task is handed
/// out afresh, because that is a new piece of work rather than the same one
/// going quiet again -- see `logTask`.
///
/// In memory only: a restart forgets, and one extra reminder after a
/// restart is a better failure than a reminder that never comes.
poltergeist_nudged: std.AutoHashMapUnmanaged(u64, void) = .empty,

/// The whole configuration, rendered the way `+show-config` renders it, so
/// that an agent can be told what it is working under.
///
/// A snapshot rather than a pointer to the live config. The apprt owns that
/// config and replaces it on reload; holding the pointer across one would be
/// a dangling read at the worst moment, and copying the struct means owning
/// every string inside it. Text costs a few tens of kilobytes once per
/// reload and cannot dangle.
poltergeist_config_text: []const u8 = "",

/// When the last plugin test went out, on `poltergeistElapsedMs`'s clock.
///
/// Optional rather than a zero sentinel: that clock starts at zero, so a
/// test in the app's first millisecond would stamp a 0 that reads back as
/// "never tested", and the limit would not apply to the very first call.
poltergeist_plugin_tested_ms: ?u64 = null,

/// The notification plugins the config asked for, loaded once at startup.
///
/// Everything they own lives in `plugin_arena`, which is why they are a
/// pair: manifests are strings all the way down and are read once.
poltergeist_plugins: []const poltergeistpkg.Plugin.Manifest = &.{},
/// Every agent CLI a plugin manages and whether it can be started; in
/// `poltergeist_plugin_arena`, read with `poltergeist_plugins`.
poltergeist_cli_standings: []const poltergeistpkg.ControlRoom.CliStanding = &.{},
poltergeist_plugin_arena: ?std.heap.ArenaAllocator = null,
/// The Agent CLIs of the person's own as the control room offers them (task
/// 2156 v3, `ownClis`): keys, names, bases and roles -- never a command or
/// a variable. In `poltergeist_own_arena`.
///
/// **Read once per round and cached by the file's size and time**
/// (`ownClis`). What is handed out points into `poltergeist_own_arena`, so
/// **nothing may replace it while a round is using what it read**: a second
/// read inside one round would have to free the arena the first read's
/// slices live in. `poltergeist_own_round` is which round the cache belongs
/// to, and a read re-stats the file only when the round has moved on.
poltergeist_own_clis: []const poltergeistpkg.ControlRoom.OwnCli = &.{},
poltergeist_own_arena: ?std.heap.ArenaAllocator = null,
/// The round `poltergeist_own_clis` was read in, and the file's size and
/// time as it was then. A later read within the same round answers with the
/// cache without touching the file at all.
poltergeist_own_round: u64 = std.math.maxInt(u64),
poltergeist_own_seen: ?struct { size: u64, mtime: i96 } = null,

/// Every installed plugin that declares what its CLI's title says
/// (`Plugin.TitleSays`, task 1656) -- **switched on or not**. Reading a
/// title starts nothing and writes nothing, and the CLI is in use whether
/// or not its provisioning plugin is: Codex's is off until somebody turns
/// it on. In `plugin_arena`, with the rest.
poltergeist_says: []const poltergeistpkg.Plugin.Manifest = &.{},

/// Whether the plugin directories a release did not ship (task 1683,
/// `Plugin.Shipped`) have been said in the log. Once per process, at the
/// first `ensurePlugins`: the leftover is a fact about the install, and a
/// line on every reload or listing would only repeat it.
poltergeist_strays_said: bool = false,

/// Where last night's arrangement is written down. Null until the state
/// directory is known. Owned.
poltergeist_session_path: ?[]const u8 = null,

/// The state directory the logs were opened under, for `group_rename`,
/// which rewrites the records in it. Null while no log is open. Owned.
poltergeist_state_dir: ?[]const u8 = null,

/// Why the logs are not open, when something went wrong opening them.
/// Owned. Null when they are open, and when they were never asked for.
///
/// **This exists so that a short list is not mistaken for a true one.** With
/// the logs closed the groups that are on disk are not loaded, and the list
/// that comes back is empty -- which reads, to the supervisor asking, as "you
/// have no groups". It is told this instead (`group_list`'s `warning`), and
/// the person is told once where they will see it.
poltergeist_log_problem: ?[]const u8 = null,

/// Whether a start has already waited for another process's rename. Once
/// is enough: `ensureChatLog` runs again for every window, and a window
/// opened later should not freeze for as long again.
poltergeist_waited_for_rename: bool = false,

/// The one-shot thread that says the records are closed a second time, a few
/// seconds after the first window opens (`noteLogProblem`), and the flag that
/// tells it to give up when the app is going away. Joined in `deinit`.
poltergeist_late_alert: ?std.Thread = null,
poltergeist_stopping: std.atomic.Value(bool) = .init(false),

/// Whether the MCP registration has been checked this run. Once is enough:
/// it cannot go stale while we are the thing it points at.
poltergeist_registered: bool = false,

/// Things the user has to be told, waiting for a terminal to say them in.
///
/// Provisioning runs while the very first surface is being built, which is
/// before there is any surface to write on -- and the failure it can report
/// is *the agent has no tools*, so the one party that must not be the only
/// recipient is the agent. So they queue here and the first terminal that
/// finishes starting up prints them. Queued rather than dropped: no surface
/// means no user either, and a message thrown away for want of a window is
/// the same silence this replaced.
///
/// Drained on first delivery, not repeated per terminal -- one report, in
/// the window the user is looking at. Each line is owned.
poltergeist_alerts: std.ArrayListUnmanaged([]const u8) = .empty,

/// `<state>/polter/plugins`, where every plugin's log file goes. Owned.
///
/// **Worked out once and kept**, rather than passed down to whoever starts a
/// resident: there are two callers that start one -- everything at launch,
/// and one plugin at a time when an agent switches it on -- and a directory
/// computed separately by each of them is two answers to "where do the logs
/// live". Null means it has not been asked for yet; an empty string means it
/// was asked for and there is nowhere, which is what makes a plugin fall
/// back to inheriting standard error.
///
/// Empty is a literal rather than an allocation, which `deinit` may free
/// without knowing the difference: freeing a zero-length slice is defined to
/// do nothing.
poltergeist_log_dir: ?[]const u8 = null,

/// What the previous run left behind. See `Session.Recall`, which reads
/// the file as it is constructed so that this run cannot overwrite the
/// material before anybody asks for it.
poltergeist_recall: poltergeistpkg.Session.Recall = .{},

/// The same conversation, written down. Null when logging is off.
///
/// The chat in memory is a working set: it trims as it grows and the
/// supervisor compacts it on purpose. This is the record, and nothing
/// removes anything from it -- otherwise the morning after an unattended
/// night has nothing to read, which is the case the whole feature is for.
chat_log: ?poltergeistpkg.ChatLog = null,

/// What happened, handed to plugins as it happens.
///
/// Deliberately not the chat log. The log is a core feature -- it is
/// complete on its own and nothing about it changes because a plugin
/// exists or does not -- and it is never a plugin's data source. A plugin
/// subscribes here and keeps an extra copy of what it is handed. See
/// `poltergeist/Feed.zig`.
poltergeist_feed: poltergeistpkg.Feed,

/// The resident plugins, one thread each. Empty unless one is installed and
/// switched on, which is the ordinary case.
///
/// **Every plugin that subscribes to something lands here**, not only the
/// ones somebody calls an archive; see `startResident`.
poltergeist_residents: std.ArrayListUnmanaged(*poltergeistpkg.Resident) = .empty,

/// The worker terminals each supervisor has split off, oldest first, by
/// `Surface.id`.
///
/// **Identities, not a count and not a position.** The second and third
/// workers are placed by splitting the previous one downwards, so the last
/// entry has to name a surface. It names it by id because that can be looked
/// up: when the person has closed that pane, `findSurfaceByID` fails and the
/// placement says so. An ordinal would still be a number after the pane it
/// counted was gone, and the wrong placement it produced would look exactly
/// like the right one.
///
/// **The whole list, not only the last one, because the column is counted
/// from it** (task 900). The tab's pane count includes terminals the person
/// opened themselves, and those are neither in the column nor in the way of
/// it: "three workers, the column is full" has to count ours and nothing
/// else. A closed worker stays in the list and is not counted -- only a
/// surface that can still be found in the supervisor's tab is.
poltergeist_workers: std.AutoHashMapUnmanaged(
    poltergeistpkg.Bus.Id,
    std.ArrayListUnmanaged(poltergeistpkg.Bus.Id),
) = .empty,

/// A split that has been asked for and whose terminal has not appeared yet.
///
/// ⚠️ **Why this exists: the id cannot always be read when the split is
/// requested.** The Windows host pushes the op onto its window thread's queue
/// and returns, so when `performAction(.new_split, …)` comes back, the
/// surface does not exist. (macOS is the other way round: its notification is
/// delivered synchronously and the surface is already there. That case is
/// attributed at once and never becomes pending; see
/// `PendingWorker.afterSplit`, task 877.) The first version recorded the new worker by
/// looking for a surface that had appeared by then, which is never, so
/// nothing was ever recorded and every worker after the first was placed as
/// if the tab held somebody else's panes. Measured on the real machine as
/// "the cap is one, not three".
///
/// So the attribution is settled on the **next** call instead, when the
/// surface is certainly there. `before` is the set of surfaces that existed
/// when the split was asked for; whatever is in `surfaces` and not in it is
/// the worker.
poltergeist_pending_worker: ?PendingWorker = null,

/// Worker requests parked until the worker their supervisor asked for just
/// before has appeared (task 1797, Q3): the next one is stacked onto it,
/// and on the Windows host it is not there yet. Each is looked at again
/// every `worker_wait_look_ms`, and placed without it once
/// `worker_wait_ms` has passed. App thread only.
poltergeist_worker_waits: std.ArrayListUnmanaged(WorkerWait) = .empty,

/// `persona_wait` requests that are being held rather than answered.
///
/// A slot process asks "tell me when this terminal's persona might want me
/// differently" and we do not answer until something moves. The machinery
/// for that already exists -- `Server.Pending` is built for the app
/// answering later -- so holding one is a matter of keeping the pointer and
/// remembering to complete it.
///
/// ⚠️ **Shutdown answers these without us**: `Server.stop` settles every
/// request it is still tracking, so a parked wait cannot wedge a connection
/// thread at `pending.done`.
poltergeist_persona_waits: poltergeistpkg.PersonaWaits = undefined,

/// Mentions refused for a reason that clears by itself, waiting to be typed
/// again (#60). Woken by the same retry as refused notices (`noticeRetryIn`).
mention_retries: poltergeistpkg.MentionRetry = undefined,

/// Standing lines (`tellSurface`) refused for a reason that clears, typed
/// once it has (task 1682). Woken by the same retry as refused notices.
owed_tells: poltergeistpkg.OwedTells = undefined,

/// The second message a supervisor started from the control room is owed,
/// in a CLI whose first turn has none of Polter's tools
/// (`Plugin.StartupSays.tools_from_second_turn`, task 1746): typed once,
/// after that first turn is over (`startLineTry`).
start_lines: poltergeistpkg.OwedTells = undefined,

/// Terminals whose CLI was started without its first prompt because the
/// folder was not trusted yet (`agent_cli.HooksHeard.first_prompt`, task
/// 1746): Polter types the role's instructions once the person has answered
/// the trust box and the CLI's input box shows (`payFirstPrompts`).
first_prompts: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, void) = .empty,

/// The agents in a project's supervisor's pane that have been taken as the
/// group's supervisor, or refused and said so (task 1795): once per agent,
/// not at every request it makes -- and a new agent in that pane again
/// (`Projects.SeatJudged`). Forgotten with the agent or the terminal.
seat_judged: poltergeistpkg.Projects.SeatJudged = .{},

/// The group each `+launch --group=` said its agent is for, by terminal,
/// until that agent is heard and the launch is judged (`launchJoin`, task
/// 1844). Names owned here. Forgotten with the terminal.
launch_groups: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, []const u8) = .empty,

/// Terminals a role's launch line was typed into whose agent has not been
/// heard yet (task 1974). While one is here its pane is not free for
/// another launch, whatever its screen says -- see `FreeWorker.Launching`.
/// Gone when its agent is heard, its launch fails, it closes, the person
/// types into it, or `launch_agent_wait_ms` passes with none of that.
launching: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, FreeWorker.Launching) = .empty,

/// When each owed second message was first owed, and for which group
/// (task 1787): how long it has waited for its agent to connect, and what
/// to say if it never does.
start_owed: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, StartOwed) = .empty,

/// Second messages typed and not yet seen to have reached their CLI
/// (`checkStartLines`, task 1746 round two): the line, when it was typed,
/// and how many times.
start_checks: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, StartCheck) = .empty,

/// `task_assign` with `fresh`, held between the /clear and the CLI saying
/// it has cleared (#64). Each holds a reference to its request.
fresh_assigns: poltergeistpkg.fresh_assign.Waits(*poltergeistpkg.Server.Pending) = .{},

/// Screenshot requests the apprt answered `pending` to, held until it calls
/// `ghostty_app_poltergeist_screenshot_complete` or their time runs out.
/// Each holds a reference to its request, taken when it was parked.
poltergeist_screenshot_waits: poltergeistpkg.screenshot.Waits(*poltergeistpkg.Server.Pending) = .{},

/// The request being dispatched right now, so that a host function called
/// from inside `dispatch` can park it. Null outside `poltergeistRequest`.
poltergeist_dispatching: ?*poltergeistpkg.Server.Pending = null,

/// Set by a host function that parked `poltergeist_dispatching`: the
/// response `dispatch` returned is then not an answer and is not sent.
poltergeist_parked: bool = false,

/// `screenshot-agent-access`.
poltergeist_screenshot_allowed: bool = true,

/// What the app thread has in hand, for the thread that says when it has
/// had it too long (task 1729). Written by the app thread, read by
/// `stall_watch_thread`; see `poltergeist/StallWatch.zig`.
stall_watch: poltergeistpkg.StallWatch = .{},
stall_watch_stop: std.atomic.Value(bool) = .init(false),
stall_watch_thread: ?std.Thread = null,

/// The worktrees Polter made, kept in `<state>/worktrees.json` (task 1702).
/// Null until the state directory is known or a request needs it.
poltergeist_worktrees: ?poltergeistpkg.worktree.Ledger = null,

/// `poltergeist-worktree-location`.
poltergeist_worktree_location: poltergeistpkg.worktree.Location = .beside,

/// Trees being made on a thread of their own, each with the request it
/// parked (`poltergeistWorktreePrepare`). App thread only.
poltergeist_worktree_jobs: std.ArrayListUnmanaged(WorktreeWait) = .empty,

/// Who holds each task tree's build lease. In memory, and for the app thread
/// only: `Leases` has no lock. Nothing takes a lease yet (there is no
/// `worktree_lease` tool), so this only ever answers "nobody"; a close or a
/// cancel reads it and a cancel lets it go.
worktree_leases: ?poltergeistpkg.worktree.Leases = null,

/// Whether the resident plugins have been looked for. Testing the list
/// instead would not do: with none installed it stays empty for ever,
/// and every config reload would re-read every plugin's settings file to
/// find that out again.
poltergeist_residents_started: bool = false,

/// Baseline for the monotonic clock the bus is given. Taken on the first
/// report rather than at startup so it costs nothing when unused.
poltergeist_epoch: ?std.Io.Timestamp = null,

/// The socket agents reach Poltergeist through. Null unless
/// `poltergeist-mcp` is on, so the default build opens nothing.
poltergeist_server: ?poltergeistpkg.Server = null,

/// Surfaces this app opened to run the chat interface.
///
/// A request arriving from one of these counts as coming from the person
/// at the keyboard (`Chat.user_id`) rather than from the terminal it
/// happens to be running in. That terminal is usually in no group at all,
/// and the user is a member of every one.
///
/// Kept as a list of ids the host itself put there, so identity still
/// comes from the host rather than from anything a client says about
/// itself. A watched agent's surface is not on it, so an agent cannot
/// reach user identity by any route.
chat_surfaces: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty,

/// A terminal the tool surface asked for that the runtime has not made yet
/// (every split, every Windows tab): the next terminal to finish starting
/// before `deadline_ms` is the one, and is marked as opened by an agent
/// (`claimAgentOpened`, #989). The same shape, and the same accepted risk, as
/// `PersonaStore.pending_launch`: a terminal the person opens in that same
/// moment could be taken for it.
///
/// `by` is the agent that asked, kept because what the new terminal is
/// granted depends on who that was (`Bus.markOpenedByAgent`).
poltergeist_agent_open: ?struct { deadline_ms: u64, by: poltergeistpkg.Bus.Id } = null,

/// The apprt, kept so that a connection thread can wake the app loop after
/// putting a request in the mailbox.
///
/// Set before the socket is opened and never changed after, so the
/// connection threads that read it cannot race the write: they do not exist
/// until `start` has been called, which happens later in the same function.
poltergeist_rt_app: ?*apprt.App = null,

/// This is true if the app that Ghostty is in is focused. This may
/// mean that no surfaces (terminals) are focused but the app is still
/// focused, i.e. may an about window. On macOS, this concept is known
/// as the "active" app while focused windows are known as the
/// "main" window.
///
/// This is used to determine if keyboard shortcuts that are non-global
/// should be processed. If the app is not focused, then we don't want
/// to process keyboard shortcuts that are not global.
///
/// This defaults to true since we assume that the app is focused when
/// Ghostty is initialized but a well behaved apprt should call
/// focusEvent to set this to the correct value right away.
focused: bool = true,

/// The last focused surface. This surface may not be valid;
/// you must always call hasSurface to validate it.
focused_surface: ?*Surface = null,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: Mailbox.Queue,

/// Agents' requests, waiting for the app thread (task 1730): **a queue of
/// their own, not slots in `mailbox`.** In the mailbox a role change's burst
/// -- every sidecar's notifier asking again at once, then every agent
/// listing its tools -- took every slot, and a terminal setting its title
/// then had its IO thread stopped until the app came back for it
/// (`MailboxBurst`). Here a push never waits: see `PoltergeistRequests`.
poltergeist_requests: PoltergeistRequests,

/// The set of font GroupCache instances shared by surfaces with the
/// same font configuration.
font_grid_set: font.SharedGridSet,

// Used to rate limit desktop notifications. Some platforms (notably macOS) will
// run out of resources if desktop notifications are sent too fast and the OS
// will kill Ghostty.
last_notification_time: ?std.Io.Timestamp = null,
last_notification_digest: u64 = 0,

/// The conditional state of the configuration. See the equivalent field
/// in the Surface struct for more information. In this case, this applies
/// to the app-level config and as a default for new surfaces.
config_conditional_state: configpkg.ConditionalState,

/// Set to false once we've created at least one surface. This
/// never goes true again. This can be used by surfaces to determine
/// if they are the first surface.
first: bool = true,

pub const CreateError = Allocator.Error || font.SharedGridSet.InitError;

/// Create a new app instance. This returns a stable pointer to the app
/// instance which is required for callbacks.
pub fn create(alloc: Allocator) CreateError!*App {
    var app = try alloc.create(App);
    errdefer alloc.destroy(app);
    try app.init(alloc);

    // If font discovery supports warmup, then we call it. Some font
    // mechanisms (e.g. CoreText) have a multi-millisecond one-time cost
    // on startup.
    if (comptime @hasDecl(font.Discover, "warmup")) {
        if (std.Thread.spawn(
            .{},
            font.Discover.warmup,
            .{},
        )) |thr| thr.detach() else |err| {
            log.warn("font warmup thread spawn failed err={}", .{err});
        }
    }

    // Same for the renderer's graphics API (e.g. Metal), which pays
    // one-time framework initialization costs on first use.
    if (comptime @hasDecl(renderer.Renderer.API, "warmup")) {
        if (std.Thread.spawn(
            .{},
            renderer.Renderer.API.warmup,
            .{},
        )) |thr| thr.detach() else |err| {
            log.warn("renderer warmup thread spawn failed err={}", .{err});
        }
    }

    return app;
}

/// Initialize the main app instance. This creates the main window, sets
/// up the renderer state, compiles the shaders, etc. This is the primary
/// "startup" logic.
///
/// After calling this function, well behaved apprts should then call
/// `focusEvent` to set the initial focus state of the app.
pub fn init(
    self: *App,
    alloc: Allocator,
) CreateError!void {
    var font_grid_set = try font.SharedGridSet.init(alloc);
    errdefer font_grid_set.deinit();

    self.* = .{
        .alloc = alloc,
        .surfaces = .empty,
        .mailbox = .{},
        .poltergeist_requests = .{},
        .font_grid_set = font_grid_set,
        .config_conditional_state = .{},
        .poltergeist = .init(alloc, .{}),
        .personas = .{ .alloc = alloc },
        .squads = .{ .alloc = alloc },
        .poltergeist_agent_clis = .init(alloc),
        .identities = .init(alloc),
        .poltergeist_persona_waits = .{ .alloc = alloc, .io = global.io() },
        .mention_retries = .{ .alloc = alloc },
        .owed_tells = .{ .alloc = alloc },
        .start_lines = .{ .alloc = alloc },
        .poltergeist_feed = .init(alloc, global.io()),
        .chat = .init(alloc, .{}),
        .projects = .init(alloc),
        .tasks = .init(alloc, .{}),
        .control_room = .init(alloc),
    };
    self.identities.changed = identitiesChanged;
    self.identities.ctx = self;
}

pub fn deinit(self: *App) void {
    // First: the late-alert thread posts into our mailbox, and must be gone
    // before anything it could touch is.
    self.poltergeist_stopping.store(true, .release);
    if (self.poltergeist_late_alert) |t| t.join();
    // The identify threads raise a flag on this App; gone before it is.
    self.identities.deinit(global.io());
    if (self.take_over) |*t| t.deinit(self.alloc);
    if (self.take_over_failed) |*f| self.alloc.free(f.group);

    // The storage threads read and write the state directory: gone before
    // the logs they would race are closed.
    if (self.backfill_thread) |t| t.join();
    self.backfill_thread = null;
    if (self.backfill_found) |*f| f.deinit();
    self.backfill_found = null;
    if (self.sweeper) |*w| w.stop();

    // The same for the control room's wake thread, which calls the apprt's
    // `wakeup`: gone before the surfaces, so it cannot fire into a close.
    if (self.control_wake) |*w| w.stop();
    self.control_wake = null;
    if (self.notice_wake) |*w| w.stop();
    self.notice_wake = null;
    if (self.alarm_wake) |*w| w.stop();
    self.alarm_wake = null;
    if (self.alarms) |*al| al.deinit();
    self.alarms = null;
    if (self.quota_watch) |*w| w.stop();
    self.quota_watch = null;
    if (self.resource_sampler) |*w| w.stop();
    self.resource_sampler = null;
    if (self.resource_overall) |o| o.destroy();
    self.resource_overall = null;
    self.alloc.free(self.resource_all_panes);
    self.resource_all_panes = &.{};
    self.resource_usage.deinit(self.alloc);
    self.resource_recent.deinit(self.alloc);
    self.resource_killed.deinit(self.alloc);
    self.resource_tones.deinit(self.alloc);
    self.resource_names.deinit(self.alloc);
    self.resource_sessions.deinit(self.alloc);
    self.page_req.deinit(self.alloc);
    self.page_out.deinit(self.alloc);
    // A stop still waiting out its grace calls back into this App: wait
    // for it rather than have it write into freed memory.
    {
        var waited: u64 = 0;
        while (self.resource_stops_running.load(.acquire) > 0 and waited <= poltergeistpkg.Stopper.grace_ms + 1_000) : (waited += 50)
            global.io().sleep(.fromMilliseconds(50), .awake) catch break;
    }
    // The half hours still open go down as they stand.
    {
        var ids: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
        defer ids.deinit(self.alloc);
        var it = self.resource_history.slots.keyIterator();
        while (it.next()) |id| ids.append(self.alloc, id.*) catch break;
        for (ids.items) |id| if (self.resource_history.take(id)) |c| self.writeHistorySlot(c);
        self.keepHistoryOpen();
    }
    self.resource_history.deinit(self.alloc);
    if (self.resource_history_file) |*f| f.deinit(self.alloc);
    self.resource_history_file = null;
    self.resource_judges.deinit(self.alloc);
    self.resource_kills.deinit(self.alloc);
    self.resource_stopped.deinit(self.alloc);

    // Clean up all our surfaces
    for (self.surfaces.items) |surface| surface.deinit();
    self.surfaces.deinit(self.alloc);

    if (self.poltergeist_server) |*srv| srv.deinit();

    // First, and joined before anything else is freed. Strictly each of
    // these borrows nothing from the app -- it copied what it needed and
    // opened its own handle on the log -- but the order says plainly who
    // has to have stopped before the rest of this runs.
    for (self.poltergeist_residents.items) |archive| archive.destroy();
    self.poltergeist_residents.deinit(self.alloc);
    {
        var it = self.poltergeist_workers.valueIterator();
        while (it.next()) |list| list.deinit(self.alloc);
        self.poltergeist_workers.deinit(self.alloc);
    }
    if (self.poltergeist_pending_worker) |*p| p.deinit(self.alloc);
    for (self.poltergeist_worker_waits.items) |w| w.held.release();
    self.poltergeist_worker_waits.deinit(self.alloc);

    // After them, and that order is the whole of it: each archive gives
    // its subscription back as it is destroyed.
    self.poltergeist_feed.deinit();

    if (self.poltergeist_config_text.len > 0) self.alloc.free(self.poltergeist_config_text);
    if (self.chat_log) |*l| l.deinit();
    if (self.task_log) |*l| l.deinit();
    if (self.stats_log) |*l| l.deinit();
    if (self.session_log) |*l| l.deinit();
    if (self.terminal_meta) |*m| m.deinit();
    if (self.reclaim) |*r| r.deinit();
    if (self.sweeper) |*w| w.deinit();
    if (self.sweep_state_dir) |d| self.alloc.free(d);
    if (self.sweep_shots_dir) |d| self.alloc.free(d);
    self.poltergeist_nudged.deinit(self.alloc);
    if (self.group_log) |*l| l.deinit();
    if (self.poltergeist_session_path) |p| self.alloc.free(p);
    if (self.poltergeist_state_dir) |p| self.alloc.free(p);
    for (self.poltergeist_worktree_jobs.items) |w| {
        // Waits for git, at quit, rather than free what its thread reads.
        w.job.destroy();
        w.held.release();
        self.alloc.free(w.preface);
    }
    if (self.worktree_leases) |*l| l.deinit();
    self.poltergeist_worktree_jobs.deinit(self.alloc);
    if (self.poltergeist_worktrees) |*w| w.deinit();
    if (self.poltergeist_log_problem) |p| self.alloc.free(p);
    self.poltergeist_recall.deinit(self.alloc);
    if (self.poltergeist_plugin_arena) |*a| a.deinit();
    if (self.poltergeist_own_arena) |*a| a.deinit();
    for (self.poltergeist_alerts.items) |line| self.alloc.free(line);
    self.poltergeist_alerts.deinit(self.alloc);
    if (self.poltergeist_log_dir) |d| self.alloc.free(d);
    self.chat_surfaces.deinit(self.alloc);
    self.control_room.deinit();
    self.control_fix_sent.deinit(self.alloc);
    self.control_asks.deinit(self.alloc);
    self.control_notify.deinit(self.alloc);
    self.control_sight.deinit(self.alloc);
    if (self.control_home) |h| if (h.len > 0) self.alloc.free(h);
    self.chat.deinit();
    self.projects.deinit();
    if (self.project_launch) |*l| l.arena.deinit();
    if (self.project_seating) |*s| self.alloc.free(s.group);
    self.tasks.deinit();
    self.poltergeist.deinit();
    self.personas.deinit();
    self.squads.deinit();
    self.poltergeist_agent_clis.deinit(global.io());
    self.poltergeist_persona_waits.deinit();
    self.mention_retries.deinit();
    self.owed_tells.deinit();
    self.start_lines.deinit();
    self.first_prompts.deinit(self.alloc);
    self.seat_judged.deinit(self.alloc);
    {
        var it = self.launch_groups.valueIterator();
        while (it.next()) |name| self.alloc.free(name.*);
        self.launch_groups.deinit(self.alloc);
    }
    self.launching.deinit(self.alloc);
    {
        var it = self.start_owed.valueIterator();
        while (it.next()) |o| self.alloc.free(o.group);
        self.start_owed.deinit(self.alloc);
    }
    {
        var it = self.start_checks.valueIterator();
        while (it.next()) |c| self.alloc.free(c.line);
        self.start_checks.deinit(self.alloc);
    }
    // Answered by the server shutting down, like the waits around it.
    for (self.fresh_assigns.entries.items) |e| e.held.release();
    self.fresh_assigns.deinit(self.alloc);
    // The requests themselves are answered by the server shutting down;
    // what is dropped here is this side's reference to each.
    for (self.poltergeist_screenshot_waits.entries.items) |e| e.held.release();
    self.poltergeist_screenshot_waits.deinit(self.alloc);

    self.stall_watch_stop.store(true, .release);
    if (self.stall_watch_thread) |t| t.join();
    self.stall_watch_thread = null;

    // Clean up our font group cache
    // We should have zero items in the grid set at this point because
    // destroy only gets called when the app is shutting down and this
    // should gracefully close all surfaces.
    assert(self.font_grid_set.count() == 0);
    self.font_grid_set.deinit();
}

/// How long quitting waits for the terminals to write down their last
/// screenful and scrollback, all of them together. A terminal is a file
/// write or two; one that has not answered in this long is stuck, and
/// quitting must not be.
pub const quit_write_wait_ms: u64 = 1000;

/// The application is quitting, and neither host frees it as it does
/// (task 2086, `polter-artifacts/2020/app-deinit-at-quit.md`): so
/// `deinit`'s per-terminal close never comes, and with it went each
/// terminal's last screenful of transcript and up to five seconds of its
/// scrollback journal. Each terminal's IO thread writes them now; this
/// waits for all of them, `quit_write_wait_ms` at most. The hosts call it
/// as they quit (`ghostty_app_quitting`), and nothing else is torn down.
pub fn writeDownBeforeQuit(self: *App) void {
    self.quit_written.store(0, .release);
    var asked: u32 = 0;
    for (self.surfaces.items) |rt| {
        rt.core().writeDownBeforeQuit(&self.quit_written);
        asked += 1;
    }
    const io = global.io();
    const all = waitCounted(&self.quit_written, asked, quit_write_wait_ms, io);
    log.info("quitting: {d} of {d} terminal(s) wrote down their last screenful and scrollback{s}", .{
        self.quit_written.load(.acquire),
        asked,
        if (all) "" else "; the rest were not waited for",
    });
}

/// Whether `counter` reaches `want` within `budget_ms`.
fn waitCounted(counter: *const std.atomic.Value(u32), want: u32, budget_ms: u64, io: std.Io) bool {
    const step_ms = 5;
    var waited: u64 = 0;
    while (counter.load(.acquire) < want) : (waited += step_ms) {
        if (waited >= budget_ms) return false;
        io.sleep(.fromMilliseconds(step_ms), .awake) catch return false;
    }
    return true;
}

test "2086: quitting waits until every terminal has counted, and no longer than its budget" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Nobody asked; everybody answered.
    var counter: std.atomic.Value(u32) = .init(0);
    try std.testing.expect(waitCounted(&counter, 0, 0, io));
    counter.store(2, .release);
    try std.testing.expect(waitCounted(&counter, 2, 0, io));

    // One short: given up at the budget, not waited on for ever.
    counter.store(1, .release);
    try std.testing.expect(!waitCounted(&counter, 2, 20, io));

    // The last one counted from another thread while this one waits.
    counter.store(1, .release);
    const Late = struct {
        fn run(c: *std.atomic.Value(u32), lio: std.Io) void {
            lio.sleep(.fromMilliseconds(30), .awake) catch {};
            _ = c.fetchAdd(1, .release);
        }
    };
    const t = try std.Thread.spawn(.{}, Late.run, .{ &counter, io });
    defer t.join();
    try std.testing.expect(waitCounted(&counter, 2, 2_000, io));
}

pub fn destroy(self: *App) void {
    // Deinitialize the app
    self.deinit();

    // Free the app memory
    self.alloc.destroy(self);
}

/// Tick ticks the app loop. This will drain our mailbox and process those
/// events. This should be called by the application runtime on every loop
/// tick.
pub fn tick(self: *App, rt_app: *apprt.App) !void {
    // **A new round** (task 2156 v3): everything this turn asks about the
    // person's own Agent CLIs gets one answer, and that answer is not freed
    // under anybody while the turn is using it (`ownClis`).
    self.ownClisRound();

    // Started here, on the first tick, because `self` has its address by
    // now and keeps it until `deinit` stops the thread.
    if (self.stall_watch_thread == null) {
        self.stall_watch_thread = std.Thread.spawn(.{}, poltergeistpkg.StallWatch.run, .{
            &self.stall_watch,
            global.io(),
            &self.stall_watch_stop,
            stall_watch_every_ms,
            poltergeistpkg.StallWatch.logSink,
            @as(?*anyopaque, null),
        }) catch |err| thread: {
            log.warn("app thread: no watch on it; its thread could not start err={}", .{err});
            break :thread null;
        };
    }

    // The resource sampler (task 1993): started once, like the stall watch.
    if (self.resource_sampler == null and !self.poltergeist_stopping.load(.acquire)) {
        self.resource_sampler = .{ .io = global.io(), .alloc = std.heap.smp_allocator, .fire = resourcesDue, .ctx = self };
        self.resource_sampler.?.start() catch |err| {
            log.warn("resources: no sampler; its thread could not start err={}", .{err});
            self.resource_sampler = null;
        };
        // The overall reading (task 2149): one allocation, here, and never
        // another -- which is what makes "the monitor does not grow" a
        // thing that can be read off `monitorBytes`.
        if (self.resource_overall == null) {
            self.resource_overall = poltergeistpkg.Overall.create(self.alloc) catch |err| b: {
                log.warn("resources: no overall reading err={}", .{err});
                break :b null;
            };
        }
    }
    if (self.resources_due.swap(false, .acq_rel)) self.takeResourceReading();
    if (self.resource_stopped_due.swap(false, .acq_rel)) self.finishResourceStops();

    // Drain our mailbox
    try self.drainMailbox(rt_app);
    // Then the agents' requests (task 1730): after the terminals' messages,
    // which keep terminals moving, and woken the same way
    // (`submitPoltergeistRequest`).
    self.drainPoltergeistRequests();

    // The rest of the tick is one item of its own: whatever it does after
    // the mailbox, a stall in it is named `tick`.
    self.stall_watch.begin(poltergeistpkg.StallWatch.nowNs(global.io()), .{ .kind = "tick" });
    defer self.stall_watch.end(poltergeistpkg.StallWatch.nowNs(global.io()));

    // A notice that was refused in its supervisor's terminal, come back
    // for. Before the snapshot, like everything else that can move it.
    // A connection closed: note it now, and come back once its grace has
    // passed to see whether its program still runs (`Bus.considerLinks`).
    if (self.links_due.swap(false, .acq_rel)) {
        if (!self.poltergeist_stopping.load(.acquire)) {
            self.notePoltergeistAgentsHere();
            self.noticeRetryIn(poltergeistpkg.Bus.link_grace_ms + chat_notice_retry_margin_ms);
        }
    }

    // An alarm's moment, or a supervisor's quiet, has come (task 2148).
    // Also the first tick, so that alarms a restart left behind are armed,
    // and after any request or control-room act, which is where a group, a
    // supervisor or a task comes from.
    if (self.alarm_due.swap(false, .acq_rel) or
        self.alarm_dirty or
        self.alarm_wake == null)
    {
        if (!self.poltergeist_stopping.load(.acquire)) self.considerSupervisorClocks();
    }

    if (self.notice_due.swap(false, .acq_rel)) {
        self.notice_retry_ms = null;
        if (!self.poltergeist_stopping.load(.acquire)) {
            // Connections first: a loss whose grace has run out goes into
            // the box this delivery takes from (task 1668).
            self.notePoltergeistAgentsHere();
            self.deliverPoltergeistNotices(self.poltergeistElapsedMs());
            // Mentions refused a moment ago, before the sweep below: one
            // typed now is marked as told, so the sweep does not add a
            // notice behind it.
            self.retryMentions(self.poltergeistElapsedMs());
            // Standing lines refused a moment ago (task 1682).
            self.payOwedTells();
            // A started supervisor's second message (task 1746).
            self.payStartLines();
            // A question a starting CLI asks the person, come up or gone
            // (task 1746): looked at again while a launch waits.
            if (self.holdStartupQuestions(self.poltergeistElapsedMs())) self.controlRoomTouch();
            // And the first prompt of a CLI that waited on the person.
            self.payFirstPrompts();
            // A fresh assignment whose clear was never confirmed.
            self.sweepFreshAssigns();
            // A worker waiting on the one asked for before it (task 1797).
            self.sweepWorkerWaits();
            // A worker asked for whose terminal the apprt makes later (task
            // 1848): recorded as soon as it is there.
            self.settlePendingWorkerOnTime();
            // And the groups: a message that arrived while its reader had
            // just been told about another, or whose notice was refused.
            self.tellTerminalsAboutMessages();
        }
    }

    if (self.storage_due.swap(false, .acq_rel)) self.storageTick();

    // After it, so that everything this tick changed is in one snapshot.
    self.controlRoomTick(rt_app);
}

/// What the storage threads left for this one: the backfill's lines to
/// write, and then the sweeper let go.
fn storageTick(self: *App) void {
    if (self.poltergeist_stopping.load(.acquire)) return;
    const io = global.io();
    self.backfill_mutex.lockUncancelable(io);
    const found = self.backfill_found;
    self.backfill_found = null;
    self.backfill_mutex.unlock(io);

    if (found) |f| {
        var owned = f;
        defer owned.deinit();
        if (self.session_log) |*l| l.writeInferred(owned, self.poltergeistWallMs());
        self.backfill_pending = false;
        if (self.sweeper) |*w| w.release();
    }
    self.control_dirty = true;
}

/// On the sweeper's thread: the first sweep has started or stopped waiting
/// for the person. The control room says so at the next tick.
fn sweeperWaitingChanged(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.poltergeist_stopping.load(.acquire)) return;
    self.storage_due.store(true, .release);
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// Settings > General > Log Management: how much each kind takes, how it
/// is kept, and whether the first sweep is waiting (`Storage.writeUsage`).
/// Caller owns the JSON. Errors when there is no state directory yet.
pub fn storageUsageJson(self: *App, alloc: Allocator) ![]u8 {
    const state_dir = self.sweep_state_dir orelse return error.NoStateDirectory;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const io = global.io();
    const today = poltergeistpkg.daylog.dayOf(self.poltergeistWallMs());
    const usages = try poltergeistpkg.Storage.usage(arena.allocator(), io, state_dir, self.sweep_shots_dir, today, poltergeistpkg.daylog.dayOf);
    var buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();
    try poltergeistpkg.Storage.writeUsage(&buf.writer, state_dir, usages, if (self.sweeper) |*w| w.waitingBytes() else null);
    return buf.toOwnedSlice();
}

/// "Clear…" on one row of Log Management, after the person confirmed.
/// Tasks are compacted from the panel in memory; shell history keeps every
/// file a saved project or an open pane names, and is not touched at all
/// when a project file will not read.
pub fn storageClear(self: *App, kind: poltergeistpkg.Storage.Kind) !poltergeistpkg.Sweeper.Report {
    const state_dir = self.sweep_state_dir orelse return error.NoStateDirectory;
    const now = self.poltergeistWallMs();
    if (kind == .tasks) {
        const l = if (self.task_log) |*v| v else return error.LogsClosed;
        const got = l.compact(&self.tasks, now);
        return .{ .files = got.files, .bytes = got.bytes };
    }
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = global.io();
    var keep: std.ArrayListUnmanaged([]const u8) = .empty;
    if (kind == .history) {
        const named = (try poltergeistpkg.Storage.historyNamedByProjects(a, io, state_dir)) orelse
            return error.ProjectUnreadable;
        try keep.appendSlice(a, named);
        for (self.surfaces.items) |rt| {
            const f = rt.core().history_filename;
            if (f.len > 0) try keep.append(a, f);
        }
    }
    const r = try poltergeistpkg.Storage.clear(a, io, state_dir, self.sweep_shots_dir, kind, keep.items, poltergeistpkg.daylog.dayOf(now), poltergeistpkg.daylog.dayOf);
    log.info("poltergeist: cleared {t}: files={d} bytes={d} dirs={d}", .{ kind, r.files, r.bytes, r.dirs });
    return r;
}

/// The backfill thread: read, hand over, wake the app thread.
fn backfillMain(self: *App, state_dir: []const u8) void {
    defer std.heap.page_allocator.free(state_dir);
    const io = global.io();
    const started = poltergeistpkg.daylog.nowMs(io);
    const found = poltergeistpkg.SessionLog.infer(std.heap.page_allocator, io, state_dir, poltergeistpkg.Chat.user_id) catch |err| {
        log.warn("poltergeist: could not work out the older groups' members err={}", .{err});
        return;
    };
    log.info("poltergeist: older groups read in {d}ms: {d} groups, {d} members", .{
        poltergeistpkg.daylog.nowMs(io) - started, found.groups.len, found.members.len,
    });
    self.backfill_mutex.lockUncancelable(io);
    self.backfill_found = found;
    self.backfill_mutex.unlock(io);
    self.storage_due.store(true, .release);
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// Come back in `delay_ms` and offer the supervisors their boxes again: a
/// notice was refused in one of their terminals (`Surface.typePoltergeistNotice`)
/// and nothing else is certain to drive a delivery when the refusal lifts.
///
/// One wake for all of them, at the earliest moment anybody asked for. A
/// retry that is refused again asks again, so a person who keeps typing
/// pushes it back ten seconds at a time and nothing is typed under them.
/// There is no upper bound and none is wanted: each retry costs one refused
/// attempt, and the notice is about somebody who is still waiting.
pub fn noticeRetryIn(self: *App, delay_ms: u64) void {
    const now_ms = self.poltergeistElapsedMs();
    self.notice_retry_ms = earlierRetry(self.notice_retry_ms, now_ms, now_ms +| delay_ms);

    if (self.notice_wake == null) {
        self.notice_wake = .{ .io = global.io(), .fire = noticeRetryDue, .ctx = self };
        self.notice_wake.?.start() catch |err| {
            log.warn("poltergeist: no retry thread; a refused notice waits for the next report err={}", .{err});
            self.notice_wake = null;
            return;
        };
    }
    self.notice_wake.?.arm(self.notice_retry_ms, now_ms);
}

/// The retry that stands after another is asked for: the earlier of the
/// two, unless the one standing is already in the past (it fired, or is
/// about to) and so is no longer a moment to wait for.
fn earlierRetry(standing: ?u64, now_ms: u64, asked: u64) u64 {
    const at = standing orelse return asked;
    if (at <= now_ms) return asked;
    return @min(at, asked);
}

test "notice delivery: several refusals share one wake, at the earliest moment asked for" {
    try std.testing.expectEqual(@as(u64, 8_000), earlierRetry(null, 1_000, 8_000));
    // A later ask does not push an earlier one back...
    try std.testing.expectEqual(@as(u64, 8_000), earlierRetry(8_000, 2_000, 12_000));
    // ...an earlier one pulls it forward...
    try std.testing.expectEqual(@as(u64, 5_000), earlierRetry(8_000, 2_000, 5_000));
    // ...and one that has passed is not a moment to keep.
    try std.testing.expectEqual(@as(u64, 19_000), earlierRetry(8_000, 9_000, 19_000));
}

/// The retry thread's whole job: raise the flag and get `tick` called.
/// From a connection thread: an agent's connection has closed. Only says so;
/// the app thread looks.
fn poltergeistAgentGone(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.poltergeist_stopping.load(.acquire)) return;
    self.links_due.store(true, .release);
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

fn noticeRetryDue(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.poltergeist_stopping.load(.acquire)) return;
    self.notice_due.store(true, .release);
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// Say that the control room's snapshot may be out of date. Cheap, and
/// safe from anywhere on the app thread: the working-out waits for `tick`.
pub fn controlRoomTouch(self: *App) void {
    if (self.control_dirty) return;
    self.control_dirty = true;
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// An identify thread's whole job on this side: say there is an answer and
/// get `tick` called.
fn identitiesChanged(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.poltergeist_stopping.load(.acquire)) return;
    self.identity_changed.store(true, .release);
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// The wake thread's whole job: raise the flag and get `tick` called.
/// The resource sampler has a reading (task 1993). Off the app thread.
fn resourcesDue(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.poltergeist_stopping.load(.acquire)) return;
    self.resources_due.store(true, .release);
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// How often the readings go to the log, as one line of the largest panes.
const resources_log_every_ms: u64 = 60 * std.time.ms_per_s;

/// Keep the sampler's reading, and tell it which panes to read next: the
/// panes change between readings, so each reading is split by the panes
/// as they were when the one before it was taken.
fn takeResourceReading(self: *App) void {
    const sampler = &(self.resource_sampler orelse return);
    if (sampler.take()) |got| {
        defer sampler.alloc.free(got.usage);
        defer sampler.alloc.free(got.procs);
        // The whole reading, both halves of it: the per-terminal totals,
        // and the process table they came from, which the overall reading
        // (task 2149) is worked out of. One scan, so the two pages cannot
        // disagree about a machine that moved between them.
        self.useOverallReading(got.procs);
        // Windows: no process table to split; each pane's job is read here,
        // on the app thread, as `shellBusy` reads its shell (task 1993 P6).
        if (comptime builtin.os.tag == .windows) self.takeJobReadings() else self.useResourceReading(got.usage);
    }

    // The panes for the next reading: the chat surfaces among them, so the
    // overall reading can tell a group's chat from a worker's terminal.
    // The per-terminal page leaves the chats out, and that split is made
    // where the page is built, not here.
    var panes: std.ArrayListUnmanaged(poltergeistpkg.ledger.Pane) = .empty;
    defer panes.deinit(self.alloc);
    for (self.surfaces.items) |v| {
        const surface = v.core();
        const pane = surface.resourcePane() orelse continue;
        panes.append(self.alloc, pane) catch return;
    }
    const kept = self.alloc.dupe(poltergeistpkg.ledger.Pane, panes.items) catch return;
    self.alloc.free(self.resource_all_panes);
    self.resource_all_panes = kept;
    var readable: std.ArrayListUnmanaged(poltergeistpkg.ledger.Pane) = .empty;
    defer readable.deinit(self.alloc);
    for (panes.items) |p| {
        if (self.isChatSurface(p.id)) continue;
        readable.append(self.alloc, p) catch return;
    }
    sampler.setPanes(readable.items) catch |err| log.warn("resources: could not hand the sampler its panes err={}", .{err});
}

/// Fold one reading's process table into the overall reading (task 2149):
/// which of Polter's processes is a chat, which a sidecar, and what the
/// machine is spending.
fn useOverallReading(self: *App, procs: []const poltergeistpkg.procscan.Proc) void {
    const overall = self.resource_overall orelse return;
    const wall = self.poltergeistWallMs();
    const read = poltergeistpkg.OverallRead.build(self.alloc, procs, self.resource_all_panes, procargsClassify, null) catch |err| {
        log.warn("resources: could not read Polter's own processes err={}", .{err});
        return;
    };
    defer self.alloc.free(read);

    // The main process is this one, and it is not any pane's: its row is
    // what the whole program holds, sidecars and chats excluded, because
    // those are their own rows -- a sidecar's parent is the agent CLI, not
    // Polter. Which pid this is, on this platform, is `procscan.selfPid`.
    const me: u32 = poltergeistpkg.procscan.selfPid();
    var main: poltergeistpkg.Overall.PaneReading = .{
        .id = 0,
        .root_pid = me,
        .mem = 0,
        .procs = 1,
    };
    for (procs) |p| if (p.pid == me) {
        main.mem = p.footprint;
        main.cpu_ns = p.cpu_ns;
        // When this process started, so a Polter restarted under the same
        // pid is another process (handoff §4 rule 7).
        main.start_ms = p.start_ms;
    };

    overall.sample(.{
        .now_ms = wall,
        .start_ms = wall - @as(i64, @intCast(self.poltergeistElapsedMs())),
        .machine = .{
            .mem_total = poltergeistpkg.procscan.physicalMemory(),
            .mem_used = poltergeistpkg.procscan.machineUsed(),
            .swap_used = poltergeistpkg.procscan.swapUsed(),
            .swap_total = poltergeistpkg.procscan.swapTotal(),
            .disk_free = poltergeistpkg.procscan.diskFree(),
        },
        .main = main,
        .panes = read,
    });
}

/// Which of Polter's own a process is, from its arguments (`procargs.zig`).
/// A process of another user cannot be read, which is `other`.
fn procargsClassify(_: ?*anyopaque, pid: u32, _: []const u8) poltergeistpkg.procargs.Seen {
    return poltergeistpkg.procargs.classify(pid);
}

const ResourceJudge = struct {
    state: poltergeistpkg.judge.State,
    limits: poltergeistpkg.limits.Limits,
};

const ResourceKill = struct {
    event: poltergeistpkg.judge.Event,
    for_ms: u32,
    top: [16]u8,
    top_len: u8,
    top_count: u32,
};

const ResourceStopped = struct { id: poltergeistpkg.Bus.Id, out: poltergeistpkg.Stopper.Outcome };

/// Every reading against every pane's lines (task 1993, #1985 §3):
/// `judge.step`, then what its events say to do. Only a pane its supervisor
/// drew lines on is judged, and `Bus.killGuard` is asked again here -- the
/// second guard -- with a chat surface never stopped either.
fn judgeResources(self: *App, usage: []const poltergeistpkg.ledger.Usage) void {
    const judge = poltergeistpkg.judge;
    const now: i64 = @intCast(self.poltergeistElapsedMs());
    const phys = poltergeistpkg.procscan.physicalMemory() orelse 0;

    // Judges of panes that no longer have lines, or are gone, go.
    {
        var it = self.resource_judges.iterator();
        var stale: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
        defer stale.deinit(self.alloc);
        while (it.next()) |kv| if (self.poltergeist.limitsOf(kv.key_ptr.*).isEmpty() or !self.resource_usage.contains(kv.key_ptr.*)) {
            stale.append(self.alloc, kv.key_ptr.*) catch break;
        };
        for (stale.items) |id| _ = self.resource_judges.remove(id);
    }

    self.recordResourceHistory(usage);

    for (usage) |u| {
        const lim = self.poltergeist.limitsOf(u.id);
        if (lim.isEmpty()) continue;
        const guard = if (self.isChatSurface(u.id)) .never else self.poltergeist.killGuard(u.id);
        if (guard == .never) continue;
        const surface = self.findSurfaceByID(u.id) orelse continue;
        const slot = self.resource_judges.getOrPut(self.alloc, u.id) catch continue;
        if (!slot.found_existing or !std.meta.eql(slot.value_ptr.limits, lim)) slot.value_ptr.* = .{ .state = .fresh, .limits = lim };
        const v = judge.step(&slot.value_ptr.state, &lim, .{ .mem = u.mem, .procs = u.procs }, now, phys, .{
            .protected = guard == .protected,
            .typing = surface.personTyping(),
        });
        for (v.all()) |e| switch (e.what) {
            .warn, .withheld => self.resourceWarned(u, lim, e),
            .kill => {},
        };
        if (v.kill()) |e| self.resourceKill(surface, u, lim, e);
    }

    // The machine as a whole: the person, never a pane.
    if (poltergeistpkg.procscan.pressureLevel()) |level| {
        if (judge.pressureStep(&self.resource_pressure, judge.Pressure.fromKernel(level), now)) |p| self.resourcePressure(usage, p);
    }
}

/// Every pane read, into its half hour: the level its judge is at (ok for
/// a pane with no lines), and the most it held. A pane no longer read has
/// its half hour written as it stood.
fn recordResourceHistory(self: *App, usage: []const poltergeistpkg.ledger.Usage) void {
    const History = poltergeistpkg.ResourceHistory;
    const wall = self.poltergeistWallMs();
    const offset = poltergeistpkg.daylog.localOffsetMs(wall);
    {
        var gone: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
        defer gone.deinit(self.alloc);
        var it = self.resource_history.slots.keyIterator();
        while (it.next()) |id| if (!self.resource_usage.contains(id.*)) gone.append(self.alloc, id.*) catch break;
        for (gone.items) |id| if (self.resource_history.take(id)) |c| self.writeHistorySlot(c);
    }
    {
        var read: std.ArrayListUnmanaged(u64) = .empty;
        defer read.deinit(self.alloc);
        for (usage) |u| read.append(self.alloc, u.id) catch break;
        self.resource_history.settle(read.items);
    }
    for (usage) |u| {
        const level: History.Level = if (self.resource_judges.getPtr(u.id)) |j| History.levelOf(&j.state) else .ok;
        const closed = self.resource_history.note(self.alloc, u.id, wall, offset, level, u.mem, u.procs) catch continue;
        if (closed) |c| self.writeHistorySlot(c);
    }
    self.keepHistoryOpen();
}

/// The half hours still open, onto the disk as they stand: rewritten only
/// when one's level or peak moved (`File.keepOpen`).
fn keepHistoryOpen(self: *App) void {
    const f = &(self.resource_history_file orelse return);
    var out: std.Io.Writer.Allocating = .init(self.alloc);
    defer out.deinit();
    var it = self.resource_history.slots.iterator();
    while (it.next()) |kv| poltergeistpkg.ResourceHistory.writeSlot(&out.writer, .{ .pane = kv.key_ptr.*, .slot = kv.value_ptr.* }) catch return;
    f.keepOpen(self.alloc, out.written());
}

/// A pane closed: its half hour written now, not when the sampler next
/// misses it.
fn historyPaneGone(self: *App, id: poltergeistpkg.Bus.Id) void {
    const c = self.resource_history.close(self.alloc, id) orelse return;
    self.writeHistorySlot(c);
    self.keepHistoryOpen();
    log.info("resources: 0x{x} closed, its half hour written", .{id});
}

fn writeHistorySlot(self: *App, c: poltergeistpkg.ResourceHistory.Closed) void {
    const f = &(self.resource_history_file orelse return);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    poltergeistpkg.ResourceHistory.writeSlot(&w, c) catch return;
    f.write(c.slot.start_ms, w.buffered());
}

/// A line that counted, into the history at this moment, and its pane's
/// half hour raised to it.
fn writeHistoryEvent(self: *App, u: poltergeistpkg.ledger.Usage, e: poltergeistpkg.judge.Event, for_ms: u32, told: poltergeistpkg.ResourceHistory.Told) void {
    const History = poltergeistpkg.ResourceHistory;
    switch (e.what) {
        .kill => self.resource_history.raise(u.id, .killed),
        .withheld => self.resource_history.raise(u.id, .withheld),
        .warn => {},
    }
    const f = &(self.resource_history_file orelse return);
    const wall = self.poltergeistWallMs();
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    History.writeEvent(&w, u.id, wall, e, for_ms, u.topName(), u.top_count, told) catch return;
    f.write(wall, w.buffered());
}

fn resourceWarned(self: *App, u: poltergeistpkg.ledger.Usage, lim: poltergeistpkg.limits.Limits, e: poltergeistpkg.judge.Event) void {
    const judge = poltergeistpkg.judge;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const body = judge.warnText(arena.allocator(), resourceTr, e, u.topName(), u.top_count) catch return;
    {
        const en = judge.warnText(arena.allocator(), judge.english, e, u.topName(), u.top_count) catch "";
        log.warn("resources: 0x{x} {s}", .{ u.id, en });
    }
    // A warning is a question of hours, as `notify_user` scheduling is:
    // outside the hours the person allows, not raised. A kill is told at
    // any hour (`finishResourceStop`).
    const told_person = e.tell_person and self.resourceWarningAllowed();
    if (told_person) _ = self.raiseSystemNotification(u.id, resourceTr(judge.words.warn_title), body);
    const boss_told = lim.warn_tells_supervisor and self.resourceSupervisor(u.id) != null;
    self.writeHistoryEvent(u, e, switch (e.metric) {
        .memory => lim.memory.for_ms,
        .processes => lim.processes.for_ms,
    }, .{ .person = told_person, .supervisor = boss_told });
    if (lim.warn_tells_supervisor) if (self.resourceSupervisor(u.id)) |boss| {
        var line: [254]u8 = undefined;
        var a2: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        // `tellSurface` takes under 255 bytes: in a supervisor's words, short.
        const text = switch (e.metric) {
            .memory => std.fmt.bufPrint(&line, "Polter: 0x{x} holds {s}, over a line of {s} you drew.", .{ u.id, judge.bytesText(&a2, e.value), judge.bytesText(&b2, e.at) }),
            .processes => std.fmt.bufPrint(&line, "Polter: 0x{x} runs {d} processes, over a line of {d} you drew.", .{ u.id, e.value, e.at }),
        } catch return;
        self.tellSurface(boss, text);
    };
}

/// Whether a warning may be raised now: `notify.decide` with the hours the
/// person set (`poltergeist_notify_window`), as a scheduling question --
/// one nobody has to be woken for. The count is 1: the system's own
/// notification is somewhere to send it, with or without a plugin.
fn resourceWarningAllowed(self: *App) bool {
    const event: poltergeistpkg.notify.Event = .{ .reason = .scheduling, .title = "", .body = "", .at_ms = self.poltergeistWallMs() };
    return poltergeistpkg.notify.decide(event, self.poltergeist_notify_window, localMinuteNow(), 1) == .tell;
}

/// The person's language, as every other word the core writes (`controlFixTr`).
fn resourceTr(msgid: [:0]const u8) []const u8 {
    return std.mem.span(internal_os.i18n._(msgid.ptr));
}

/// Who is told of a pane's kill: the supervisor it was opened for, or the
/// one whose agent opened it.
fn resourceSupervisor(self: *App, id: poltergeistpkg.Bus.Id) ?poltergeistpkg.Bus.Id {
    return self.poltergeist.workerOf(id) orelse self.poltergeist.openedBy(id);
}

/// Stop `u`'s agent: everything in the pane but its child and that child's
/// children (`ledger.stoppable`), `SIGTERM` then `SIGKILL` on a thread of its
/// own (`Stopper`). The rest is `finishResourceStops`.
fn resourceKill(self: *App, surface: *Surface, u: poltergeistpkg.ledger.Usage, lim: poltergeistpkg.limits.Limits, e: poltergeistpkg.judge.Event) void {
    if (self.resource_kills.contains(u.id)) return;
    // Windows: the pane's job, everything in it but the shell and the
    // console host, stopped at once -- there is no `SIGTERM` to wait out.
    // The rest is the same as below, from `resourceStopped` on.
    if (comptime builtin.os.tag == .windows) {
        const note: ResourceKill = .{
            .event = e,
            .for_ms = switch (e.metric) {
                .memory => lim.memory.for_ms,
                .processes => lim.processes.for_ms,
            },
            .top = u.top,
            .top_len = u.top_len,
            .top_count = u.top_count,
        };
        self.resource_kills.put(self.alloc, u.id, note) catch return;
        self.writeHistoryEvent(u, e, note.for_ms, .{ .person = true, .supervisor = self.resourceSupervisor(u.id) != null });
        const stopped = surface.io.stopAgent(self.alloc) orelse 0;
        log.warn("resources: stopped {d} processes in 0x{x}'s job, {s} {d} over {d}{s}", .{
            stopped, u.id, @tagName(e.metric), e.value, e.at, if (e.isFast()) " (fast)" else "",
        });
        _ = self.resource_stops_running.fetchAdd(1, .acq_rel);
        resourceStopped(self, u.id, .{ .termed = 0, .killed = stopped });
        return;
    }
    const pane = surface.resourcePane() orelse return;
    const procs = poltergeistpkg.procscan.scan(self.alloc) catch return;
    defer self.alloc.free(procs);
    const pids = poltergeistpkg.ledger.stoppable(std.heap.smp_allocator, procs, pane) catch return;
    if (pids.len == 0) {
        std.heap.smp_allocator.free(pids);
        log.warn("resources: 0x{x} is over its kill line and has nothing to stop under its shell", .{u.id});
        return;
    }
    const note: ResourceKill = .{
        .event = e,
        .for_ms = switch (e.metric) {
            .memory => lim.memory.for_ms,
            .processes => lim.processes.for_ms,
        },
        .top = u.top,
        .top_len = u.top_len,
        .top_count = u.top_count,
    };
    self.resource_kills.put(self.alloc, u.id, note) catch {
        std.heap.smp_allocator.free(pids);
        return;
    };
    log.warn("resources: stopping 0x{x}: {d} processes, {s} {d} over {d}{s}", .{
        u.id, pids.len, @tagName(e.metric), e.value, e.at, if (e.isFast()) " (fast)" else "",
    });
    _ = self.resource_stops_running.fetchAdd(1, .acq_rel);
    // Into the history now, at the moment the line counted: the person is
    // always told, the supervisor when there is one.
    self.writeHistoryEvent(u, e, note.for_ms, .{ .person = true, .supervisor = self.resourceSupervisor(u.id) != null });
    poltergeistpkg.Stopper.start(.{
        .io = global.io(),
        .alloc = std.heap.smp_allocator,
        .pids = pids,
        .id = u.id,
        .fire = resourceStopped,
        .ctx = self,
    }) catch |err| {
        log.warn("resources: could not start stopping 0x{x} err={}", .{ u.id, err });
        _ = self.resource_stops_running.fetchSub(1, .acq_rel);
        std.heap.smp_allocator.free(pids);
        _ = self.resource_kills.remove(u.id);
    };
}

/// On the stopper's thread: hand the outcome over and wake the app.
fn resourceStopped(ctx: *anyopaque, id: u64, out: poltergeistpkg.Stopper.Outcome) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    {
        self.resource_stopped_mutex.lockUncancelable(global.io());
        defer self.resource_stopped_mutex.unlock(global.io());
        self.resource_stopped.append(self.alloc, .{ .id = id, .out = out }) catch {};
    }
    self.resource_stopped_due.store(true, .release);
    _ = self.resource_stops_running.fetchSub(1, .acq_rel);
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// The agent is gone: the pane's modes put back and its line written, then
/// the person, the supervisor and the group told, and the pane's open
/// tasks blocked (#1985 §3.2). Never resumed here: the supervisor is given
/// the command.
fn finishResourceStops(self: *App) void {
    var done: std.ArrayListUnmanaged(ResourceStopped) = .empty;
    defer done.deinit(self.alloc);
    {
        self.resource_stopped_mutex.lockUncancelable(global.io());
        defer self.resource_stopped_mutex.unlock(global.io());
        std.mem.swap(std.ArrayListUnmanaged(ResourceStopped), &done, &self.resource_stopped);
    }
    for (done.items) |d| {
        const kv = self.resource_kills.fetchRemove(d.id) orelse continue;
        self.finishResourceStop(d.id, kv.value, d.out);
    }
}

fn finishResourceStop(self: *App, id: poltergeistpkg.Bus.Id, k: ResourceKill, out: poltergeistpkg.Stopper.Outcome) void {
    const judge = poltergeistpkg.judge;
    // For its card and its group's dot, ten minutes (task 2015).
    self.resource_killed.put(self.alloc, id, .{
        .at_ms = self.poltergeistWallMs(),
        .metric = k.event.metric,
        .value = k.event.value,
        .at = k.event.at,
    }) catch {};
    self.noteResourceTones();
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const top = k.top[0..k.top_len];
    const said = judge.killText(aa, resourceTr, k.event, k.for_ms, top, k.top_count) catch "";
    const english = judge.killText(aa, judge.english, k.event, k.for_ms, top, k.top_count) catch "";
    // Windows has no gentle stop to wait out: `stopAgent` used
    // `TerminateProcess` on each at once.
    if (comptime builtin.os.tag == .windows) {
        log.warn("resources: stopped 0x{x}: {s}; {d} ended with TerminateProcess", .{ id, english, out.killed });
    } else {
        log.warn("resources: stopped 0x{x}: {s}; {d} sent SIGTERM, {d} still there after {d} ms and sent SIGKILL", .{
            id, english, out.termed, out.killed, poltergeistpkg.Stopper.grace_ms,
        });
    }
    // A new round for the pane: what its lines do next is news.
    if (self.resource_judges.getPtr(id)) |j| judge.afterKill(&j.state);
    if (self.findSurfaceByID(id)) |surface| {
        const note = std.fmt.allocPrint(aa, "\u{2500}\u{2500} {s} \u{2500}\u{2500}", .{said}) catch "";
        surface.noteKilled(note);
    }

    // The person: always, at any hour.
    _ = self.raiseSystemNotification(id, resourceTr(judge.words.kill_title), said);

    // The supervisor: what happened and how to go on, typed in -- the
    // notice box has no line of its own for one terminal's text.
    if (self.resourceSupervisor(id)) |boss| {
        const agent = self.poltergeist.agentOf(id);
        const launch = self.personas.launchOf(id);
        const role: []const u8 = if (launch) |l| l.role else self.personas.stateOf(id).key orelse "";
        const cli: []const u8 = agent.cli.get() orelse if (launch) |l| l.choice.cli else "";
        var line: std.Io.Writer.Allocating = .init(aa);
        var a: [32]u8 = undefined;
        var b: [32]u8 = undefined;
        // An agent only when Polter knows which CLI it was; otherwise it
        // was some program, as a `node` typed at the prompt is.
        const what: []const u8 = if (cli.len > 0) "the agent" else "what was running";
        line.writer.print("Polter stopped {s} in 0x{x}: ", .{ what, id }) catch {};
        switch (k.event.metric) {
            .memory => line.writer.print("memory {s} over its kill line {s}", .{ judge.bytesText(&a, k.event.value), judge.bytesText(&b, k.event.at) }) catch {},
            .processes => line.writer.print("{d} processes over its kill line {d}", .{ k.event.value, k.event.at }) catch {},
        }
        line.writer.writeAll(if (k.event.isFast()) ", 1.5x: at once." else ".") catch {};
        if (role.len > 0 and cli.len > 0) {
            line.writer.writeAll(" Resume it there with: polter") catch {};
            poltergeistpkg.agent_cli.writeLaunchWords(&line.writer, role, cli, .{ .group = null, .session = agent.session_id.get() }) catch {};
        }
        // `tellSurface` takes under 255 bytes and drops the rest unsaid.
        const short = std.fmt.allocPrint(aa, "Polter stopped {s} in 0x{x} at its kill line; its tasks are blocked.", .{ what, id }) catch "";
        self.tellSurface(boss, if (line.written().len < 255) line.written() else short);
    }

    // Its open tasks, in every group it is in, are blocked. No line in the
    // groups: Polter has no name of its own there yet, and a line posted as
    // the person would put words in their mouth in a record that is taken
    // at its word.
    const live = self.liveTerminals(aa) catch &.{};
    const groups = self.chat.groupsFor(aa, id, live) catch &.{};
    for (groups) |group| {
        const mine = self.tasks.forWorker(self.alloc, group, id) catch continue;
        defer self.alloc.free(mine);
        for (mine) |t| {
            self.tasks.setProgress(t.id, id, .blocked) catch continue;
            self.logTask(.progressed, t.id);
        }
    }
}

/// The machine's pressure held for 10 s: the person, with the three panes
/// holding the most. Nothing is stopped for it.
fn resourcePressure(self: *App, usage: []const poltergeistpkg.ledger.Usage, p: poltergeistpkg.judge.Pressure) void {
    const judge = poltergeistpkg.judge;
    var top: [3]?poltergeistpkg.ledger.Usage = .{ null, null, null };
    for (usage) |u| {
        var i: usize = 0;
        while (i < top.len) : (i += 1) {
            if (top[i] == null or u.mem > top[i].?.mem) {
                var k = top.len - 1;
                while (k > i) : (k -= 1) top[k] = top[k - 1];
                top[i] = u;
                break;
            }
        }
    }
    var buf: [400]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var a: [32]u8 = undefined;
    var nm: [16]u8 = undefined;
    for (top, 0..) |t, n| if (t) |u| {
        w.print("{s}0x{x} {s} ({s})", .{ if (n > 0) ", " else "", u.id, judge.bytesText(&a, u.mem), judge.safeName(&nm, u.topName()) }) catch break;
    };
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const msgid = switch (p) {
        .critical => judge.words.pressure_critical,
        else => judge.words.pressure_warn,
    };
    const fill = poltergeistpkg.ControlRoom.Say.fill;
    log.warn("resources: {s}", .{fill(arena.allocator(), msgid, &.{w.buffered()}) catch ""});
    const body = fill(arena.allocator(), resourceTr(msgid), &.{w.buffered()}) catch return;
    const from = (top[0] orelse return).id;
    // A warning about the machine, held to the person's hours like a pane's.
    if (!self.resourceWarningAllowed()) return;
    _ = self.raiseSystemNotification(from, resourceTr(judge.words.pressure_title), body);
}

fn useResourceReading(self: *App, usage: []const poltergeistpkg.ledger.Usage) void {
    self.resource_usage.clearRetainingCapacity();
    for (usage) |u| self.resource_usage.put(self.alloc, u.id, u) catch break;
    self.keepRecent(usage);
    self.logResources(usage);
    self.judgeResources(usage);
    self.noteResourceTones();
}

/// The reading into each pane's last five minutes; a pane it does not
/// name is gone, and its minutes with it.
fn keepRecent(self: *App, usage: []const poltergeistpkg.ledger.Usage) void {
    self.resource_seq += 1;
    const wall = self.poltergeistWallMs();
    {
        var gone: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
        defer gone.deinit(self.alloc);
        var it = self.resource_recent.keyIterator();
        while (it.next()) |id| if (!self.resource_usage.contains(id.*)) gone.append(self.alloc, id.*) catch break;
        for (gone.items) |id| _ = self.resource_recent.remove(id);
    }
    for (usage) |u| {
        const r = self.resource_recent.getOrPut(self.alloc, u.id) catch continue;
        if (!r.found_existing) r.value_ptr.* = .{};
        r.value_ptr.push(.{ .seq = self.resource_seq, .at_ms = wall, .mem = u.mem }, u.cpu_ns, u.started_ms);
    }
    self.keepResourceNames(wall);
}

/// Each read pane's name and group, for the history's rows once it has
/// closed; written only when one changed.
fn keepResourceNames(self: *App, wall: i64) void {
    for (self.control_room.route_rows) |row| {
        for (row.members, row.titles) |id, title| {
            if (!self.resource_usage.contains(id)) continue;
            self.resource_names.note(self.alloc, id, title, row.group, wall) catch continue;
        }
    }
    self.resource_names.prune(self.alloc, wall);
    // The same terminals, gone from the session table too (task 2234): an
    // id `ResourceNames` has forgotten can never name a row again, and
    // without this its entry would stay for the life of the process.
    self.resource_sessions.prune(&self.resource_names);
    if (!self.resource_names.dirty) return;
    const f = &(self.resource_history_file orelse return);
    const bytes = self.resource_names.encode(self.alloc) catch return;
    defer self.alloc.free(bytes);
    f.keepNames(bytes);
}

/// A pane's level as its group's dot and its card say it (task 2015):
/// `none` unread, `killed` for ten minutes after a stop, else its judge's.
fn resourceTone(self: *App, id: poltergeistpkg.Bus.Id, wall: i64) poltergeistpkg.ResourcePage.Tone {
    const Page = poltergeistpkg.ResourcePage;
    if (!self.resource_usage.contains(id)) return .none;
    if (self.resource_killed.get(id)) |k| if (wall - k.at_ms <= Page.killed_shown_ms) return .killed;
    const j = self.resource_judges.getPtr(id) orelse return .ok;
    return Page.toneOf(poltergeistpkg.ResourceHistory.levelOf(&j.state));
}

/// Every read pane's level, for the snapshot.
fn resourceLevels(self: *App, alloc: Allocator) Allocator.Error![]const poltergeistpkg.ControlRoom.ResourceLevel {
    const wall = self.poltergeistWallMs();
    const out = try alloc.alloc(poltergeistpkg.ControlRoom.ResourceLevel, self.resource_usage.count());
    var it = self.resource_usage.keyIterator();
    var i: usize = 0;
    while (it.next()) |id| : (i += 1) out[i] = .{ .id = id.*, .tone = self.resourceTone(id.*, wall) };
    return out;
}

/// After a reading: when any pane's level moved, the control room's dots
/// did too.
fn noteResourceTones(self: *App) void {
    const wall = self.poltergeistWallMs();
    var changed = false;
    var it = self.resource_tones.iterator();
    while (it.next()) |kv| if (!self.resource_usage.contains(kv.key_ptr.*)) {
        changed = true;
        self.resource_tones.removeByPtr(kv.key_ptr);
    };
    var ut = self.resource_usage.keyIterator();
    while (ut.next()) |id| {
        const tone = self.resourceTone(id.*, wall);
        const gop = self.resource_tones.getOrPut(self.alloc, id.*) catch continue;
        if (gop.found_existing and gop.value_ptr.* == tone) continue;
        gop.value_ptr.* = tone;
        changed = true;
    }
    if (changed) self.controlRoomTouch();
}

/// Every pane's job, read now, as one reading (Windows).
fn takeJobReadings(self: *App) void {
    var usage: std.ArrayListUnmanaged(poltergeistpkg.ledger.Usage) = .empty;
    defer usage.deinit(self.alloc);
    for (self.surfaces.items) |v| {
        const surface = v.core();
        if (self.isChatSurface(surface.id)) continue;
        const r = surface.io.resourceReading(self.alloc) orelse continue;
        usage.append(self.alloc, .{
            .id = surface.id,
            .mem = r.mem,
            .procs = r.procs,
            .top = r.top,
            .top_len = r.top_len,
            .top_count = r.top_count,
            .top_mem = r.top_mem,
            .cpu_ns = r.cpu_ns,
            .started_ms = r.started_ms,
        }) catch return;
    }
    self.useResourceReading(usage.items);
}

/// One line a minute: the three panes holding the most. What a reading
/// was, for anybody looking back at a night.
fn logResources(self: *App, usage: []const poltergeistpkg.ledger.Usage) void {
    const now_ms = self.poltergeistElapsedMs();
    if (self.resources_logged_ms) |at| if (now_ms -| at < resources_log_every_ms) return;
    self.resources_logged_ms = now_ms;
    var top: [3]?poltergeistpkg.ledger.Usage = .{ null, null, null };
    for (usage) |u| {
        var i: usize = 0;
        while (i < top.len) : (i += 1) {
            if (top[i] == null or u.mem > top[i].?.mem) {
                var k = top.len - 1;
                while (k > i) : (k -= 1) top[k] = top[k - 1];
                top[i] = u;
                break;
            }
        }
    }
    for (top) |t| if (t) |u| log.info("resources: 0x{x} {d} MB in {d} processes, most in {s} x{d} ({d} MB)", .{
        u.id, u.mem >> 20, u.procs, u.topName(), u.top_count, u.top_mem >> 20,
    });
}

fn controlRoomDue(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.poltergeist_stopping.load(.acquire)) return;
    self.control_due.store(true, .release);
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// The one that reads the allowance files, made the first time it is
/// wanted.
fn quotaWatch(self: *App) *poltergeistpkg.QuotaWatch {
    if (self.quota_watch == null) self.quota_watch = .{
        .alloc = self.alloc,
        .io = global.io(),
        .fire = quotaChanged,
        .ctx = self,
    };
    return &self.quota_watch.?;
}

/// The allowance thread's whole job on this side: say that there is a new
/// number and get `tick` called.
fn quotaChanged(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.poltergeist_stopping.load(.acquire)) return;
    self.quota_changed.store(true, .release);
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// Bring the control room's snapshot up to date if anything may have
/// changed it, tell the apprt if it did, and set the next wake.
///
/// **Two ways in and no third.** Something happened on this thread
/// (`control_dirty`), or the moment `ControlRoom` asked to be woken at has
/// come (`control_due`). There is no interval: with neither, this returns
/// having read two flags.
fn controlRoomTick(self: *App, rt_app: *apprt.App) void {
    if (self.poltergeist_stopping.load(.acquire)) return;
    const due = self.control_due.swap(false, .acq_rel);
    const quota_new = self.quota_changed.swap(false, .acq_rel);
    const identity_new = self.identity_changed.swap(false, .acq_rel);
    const dirty = self.control_dirty or quota_new or identity_new;
    if (!due and !dirty) return;

    // An agent with no hooks has just been identified: its session, if it
    // said one, is written down here, as a hook's is (task 2084).
    if (identity_new) self.noteIdentifiedSessions();

    // Something happened in a terminal, which is when an allowance moves:
    // have the files read. Not when the only news is that they were read.
    if (self.control_dirty) self.quotaWatch().kick();
    self.control_dirty = false;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const now_ms = self.poltergeistElapsedMs();
    // Before the snapshot: a step that settles a take-over is in this one.
    const take_over_wake = self.takeOverStep(now_ms);
    // Before it too: a start whose project marks no supervisor's pane opens
    // its tab here, not while the snapshot is being made (task 1794).
    self.startHeldInANewTab(rt_app, now_ms);
    // In this snapshot: a start whose CLI is asking, or has stopped asking.
    _ = self.holdStartupQuestions(now_ms);
    // A trust box answered since: the first prompt it was holding back.
    self.payFirstPrompts();
    var terminals: std.ArrayListUnmanaged(poltergeistpkg.ControlRoom.Terminal) = .empty;
    for (self.surfaces.items) |v| {
        const surface: *Surface = v.core();
        const id = poltergeistpkg.Bus.idOf(surface);
        if (self.isChatSurface(id)) continue;

        // Which window and tab it is in is the apprt's to say, as it is for
        // `terminal_list`; zero is "did not say".
        var window: u64 = 0;
        var tab: u64 = 0;
        _ = rt_app.performAction(
            .{ .surface = surface },
            .poltergeist_grouping,
            .{ .window = &window, .tab = &tab },
        ) catch {};

        terminals.append(alloc, .{
            .id = id,
            .title = self.footingOf(alloc, id).title,
            .window = if (window == 0) null else window,
            .tab = if (tab == 0) null else tab,
            // A terminal whose process has ended is there to look at and
            // not to work in. Whether it ended badly is the bus's note
            // (`Surface.childExited`); `facts` reads it when this says
            // nothing more exact.
            .process = if (!surface.child_exited)
                .running
            else if (self.poltergeist.get(id)) |e|
                (if (e.left) |l| switch (l.why) {
                    .failed => poltergeistpkg.Attention.Process{ .agent_exited = l.at_ms },
                    .unknown => .gone,
                } else .gone)
            else
                .gone,
            .agent_present = self.agentPresent(id),
            .at_prompt = surface.isAtShellPrompt(),
            .role = if (self.personas.launchOf(id)) |l| l.role else self.personas.stateOf(id).key orelse "",
            .launched_cli = if (self.personas.launchOf(id)) |l| l.choice.cli else "",
            .still_ms = surface.poltergeist_threshold_ms,
            .hookless = self.hooklessOf(alloc, id),
        }) catch return;
    }

    var quota_buf: [std.enums.values(poltergeistpkg.quota.Family).len]poltergeistpkg.quota.Reading = undefined;
    const quota_read: []const poltergeistpkg.quota.Reading =
        if (self.quota_watch) |*w| w.readings(&quota_buf) else &.{};
    // **What the person has of their own, read once** (task 2156 v3): all
    // five things below that need it are handed this one answer, so that
    // none of them can be holding an answer a later read freed.
    const own = self.ownClis();
    // The roles a supervisor can be started in: the ones that make a
    // terminal a supervisor and have a CLI to start. In the set's order,
    // which puts the one Polter ships first.
    const roles = self.controlStartRoles(alloc, own) catch return;
    const cli_resume = self.controlCliResume(alloc) catch return;
    const projects = self.projectsWork(alloc, now_ms) catch return;

    const wall_ms = self.poltergeistWallMs();
    const outcome = self.control_room.refresh(.{
        .bus = &self.poltergeist,
        .chat = &self.chat,
        .terminals = terminals.items,
        .thresholds = .from(
            .{ .quiescence_ms = self.control_still_ms },
            self.poltergeist.config,
        ),
        .tasks = &self.tasks,
        .quota = quota_read,
        .retention_waiting = if (self.sweeper) |*w| w.waitingBytes() else null,
        .supervisor_roles = roles,
        .cli_resume = cli_resume,
        .cli_standings = self.controlCliStandings(alloc, own) catch return,
        .projects = projects,
        .cli_names = self.controlCliNames(alloc, own) catch return,
        .own_clis = own,
        .home = self.controlHome(),
        .record_root = if (self.group_log) |*l| l.dir else "",
        .fix_sent = &self.control_fix_sent,
        .asks = &self.control_asks,
        .take_over = self.takeOverIn(),
        .resource_levels = self.resourceLevels(alloc) catch return,
        .now_ms = now_ms,
        .wall_ms = @intCast(@max(0, wall_ms)),
    }, if (dirty) .event else .timer) catch |err| {
        log.warn("control room: could not work out the snapshot err={}", .{err});
        return;
    };

    if (outcome.notify) |rev| {
        _ = rt_app.performAction(.app, .control_room_changed, .{ .rev = rev }) catch |err| {
            log.warn("control room: could not tell the apprt err={}", .{err});
        };
    }

    // The notifications are looked at on the same two occasions: something
    // happened, or a moment one of them is waiting for has come.
    const notify_wake = self.controlNotifyStep(rt_app, alloc, now_ms) catch |err| wake: {
        log.warn("control room: could not decide the notifications err={}", .{err});
        break :wake null;
    };
    const both: ?u64 = if (notify_wake) |n|
        (if (outcome.wake_ms) |o| @min(o, n) else n)
    else
        outcome.wake_ms;
    const wake_ms: ?u64 = if (take_over_wake) |t| (if (both) |b| @min(b, t) else t) else both;

    if (wake_ms != null and self.control_wake == null) {
        self.control_wake = .{ .io = global.io(), .fire = controlRoomDue, .ctx = self };
        self.control_wake.?.start() catch |err| {
            log.warn("control room: no wake thread, thresholds will show late err={}", .{err});
            self.control_wake = null;
        };
    }
    if (self.control_wake) |*w| w.arm(wake_ms, now_ms);
}

/// Decide the control room's notifications (`ControlNotify`) and raise the
/// ones that are due. The moment to look again, or null.
///
/// What it is told about the person: which cards are in sight, from the
/// host (`control_sight`), and which terminals have the keyboard, from
/// each surface's own focus -- which a host gives a surface only while its
/// window has the keyboard, so "in that terminal" is per window.
fn controlNotifyStep(self: *App, rt_app: *apprt.App, arena: Allocator, now_ms: u64) !?u64 {
    var in_use: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
    for (self.surfaces.items) |v| {
        const surface: *Surface = v.core();
        if (surface.focused) try in_use.append(arena, poltergeistpkg.Bus.idOf(surface));
    }
    const hours: poltergeistpkg.ControlNotify.Hours = if (self.poltergeist_notify_window) |w| hours: {
        const m = w.minutesUntilInside(localMinuteNow());
        break :hours if (m == 0) .open else .{ .closed_for_ms = @as(u64, m) * std.time.ms_per_min };
    } else .open;

    const d = try self.control_notify.step(self.alloc, arena, self.control_room.notify_rows, .{
        .cards_in_sight = self.control_sight.inSight(),
        .terminals_in_use = in_use.items,
    }, hours, now_ms);

    for (d.held) |h| log.info("control room: not calling about group={s} kind={t}: {t}", .{ h.group, h.signature.kind, h.why });
    for (d.alerts) |a| {
        const kind: apprt.action.ControlRoomAlert.Kind = switch (a.kind) {
            .needs_approval => .needs_approval,
            .needs_answer => .needs_answer,
            .failed => .failed,
            // `ControlNotify.interrupts` lets nothing else through.
            else => continue,
        };
        const group = try arena.dupeZ(u8, a.group);
        const who = try arena.dupeZ(u8, a.who);
        const text = try arena.dupeZ(u8, a.text);
        const alert: apprt.action.ControlRoomAlert.Alert = .{
            .kind = kind,
            .group = group.ptr,
            .more = @intCast(@min(a.more, std.math.maxInt(u32))),
            .who = who.ptr,
            .text = text.ptr,
        };
        const taken = rt_app.performAction(.app, .control_room_alert, .{ .alert = &alert }) catch |err| {
            log.warn("control room: calling about group={s} failed err={}", .{ a.group, err });
            continue;
        };
        log.info("control room: calling about group={s} kind={t} more={d} taken={}", .{ a.group, a.kind, a.more, taken });
    }
    return d.wake_ms;
}

/// The host's word on its control room: in front or not, and which cards
/// it has on screen. Replaces the last one; the notifications read it the
/// next time they are decided.
pub fn controlPresence(self: *App, json: []const u8) !void {
    const sight = try poltergeistpkg.ControlNotify.Sight.parse(self.alloc, json);
    self.control_sight.deinit(self.alloc);
    self.control_sight = sight;
    // Hosts say this only when it changes, so one line per change. The line
    // a notification decision can be checked against (task 1531: a round
    // where it never took effect left nothing to read).
    log.info("control room: presence in_front={} cards={d}", .{ sight.in_front, sight.cards.len });
}

/// Something the person did in the control room (`ControlAct.zig` has the
/// request and every refusal). An error is the refusal's name, and means
/// nothing was done: no key, no text, no mark.
///
/// **The person, by construction.** This is reached from the host's own
/// window through `ghostty_app_control_act` and from nowhere else; no agent
/// has a tool that arrives here, and the request has no field to say who
/// is asking.
pub fn controlAct(self: *App, json: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();

    const act = try poltergeistpkg.ControlAct.parse(arena.allocator(), json);
    // Whatever comes of it, what the control room shows may have moved.
    defer self.controlRoomTouch();
    // And a group, its supervisor or its panel may be new: when the next
    // alarm or reminder is due is worked out again (task 2148). The
    // `controlRoomTouch` above is what gets `tick` here to read it.
    defer self.alarm_dirty = true;

    try poltergeistpkg.ControlAct.perform(
        act,
        &self.poltergeist,
        &self.chat,
        .{
            .ctx = self,
            .sendKey = controlActKey,
            .sendText = controlActText,
            .agentPresent = controlActAgentPresent,
            .readScreen = controlActReadScreen,
            .renameGroup = controlActRenameGroup,
            .setBrief = controlActSetBrief,
            .openTasks = controlActOpenTasks,
            .deleteGroup = controlActDeleteGroup,
            .persist = controlActPersist,
            .createGroup = controlActCreateGroup,
            .stewardOf = controlActStewardOf,
            .startSupervisor = controlActStartSupervisor,
            .stateProjects = controlActStateProjects,
            .projectFailed = controlActProjectFailed,
            .projectRemove = controlActProjectRemove,
            .projectRename = controlActProjectRename,
            .projectSay = controlActProjectSay,
            .retentionAgree = controlActRetentionAgree,
            .takeOver = controlActTakeOver,
            .fixCard = controlActFixCard,
            .fixPost = controlActFixPost,
            .askPost = controlActAskPost,
            .fixSend = controlActFixSend,
            .fixSent = controlActFixSent,
            .voice = .{ .clock = controlFixClock, .tr = controlFixTr },
        },
        self.poltergeistElapsedMs(),
        @intCast(@max(0, self.poltergeistWallMs())),
    );
}

/// A terminal's screen for the control room's prompt guard, read the way
/// terminal_read reads it (task 1655).
fn controlActReadScreen(ctx: *anyopaque, alloc: Allocator, id: poltergeistpkg.Bus.Id) anyerror![]const u8 {
    return poltergeistRead(ctx, alloc, id, 0);
}

/// One key into a terminal for the control room, by the road an agent's
/// key takes: not while somebody is typing there, not into a line with a
/// draft in it, and not counted as sent unless the program received it.
fn controlActKey(ctx: *anyopaque, id: poltergeistpkg.Bus.Id, key: []const u8) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.UnknownTerminal;
    surface.poltergeistMayType() catch |err| return controlActRefusal(err);
    const outcome = surface.sendPoltergeistKey(key) catch |err| return controlActRefusal(err);
    if (outcome != .written) return error.KeyFailed;
}

/// A refusal on its way to the control room, which reads it by name.
/// `Composing` (task 1590) goes as `UserPresent`: it is somebody at that
/// keyboard, and the hosts already say that in the person's language; a
/// name they do not know would be shown as a failure with no reason.
fn controlActRefusal(err: anyerror) anyerror {
    return if (err == error.Composing) error.UserPresent else err;
}

/// A line typed and submitted, by `terminal_send`'s road and its guards.
fn controlActText(ctx: *anyopaque, id: poltergeistpkg.Bus.Id, text: []const u8) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.UnknownTerminal;
    surface.typePoltergeistText(text, true) catch |err| return controlActRefusal(err);
}

fn controlActFixCard(ctx: *anyopaque, key: poltergeistpkg.ControlFix.Key) ?poltergeistpkg.ControlFix.Card {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.control_room.fixCard(key);
}

/// "Fix" on a group's card: said in the group by the person and typed into
/// `to` -- `chatPost`, the road a `group_post` mention takes, with its
/// guards and its record.
fn controlActFixPost(
    ctx: *anyopaque,
    group: []const u8,
    text: []const u8,
    to: []poltergeistpkg.ControlFix.Target,
    who: poltergeistpkg.rpc.Typist,
) anyerror!void {
    var deliveries: [poltergeistpkg.Chat.max_mentions]poltergeistpkg.rpc.Delivery = undefined;
    if (to.len > deliveries.len) return error.TooManyMentions;
    for (to, 0..) |t, i| deliveries[i] = .{ .to = t.to };
    _ = try chatPost(ctx, group, poltergeistpkg.Chat.user_id, text, .{
        .from_title = "you",
        .to = deliveries[0..to.len],
        .typist = who,
    });
    for (to, 0..) |*t, i| t.err = deliveries[i].err;
    log.info("control room: fix posted in group={s} typed={d}", .{ group, to.len });
}

/// "Ask the Supervisor…" from a group's menu: `controlActFixPost`'s road,
/// and the ask kept for the snapshot, so the line under the row can say
/// what became of a retry (task 1671).
fn controlActAskPost(
    ctx: *anyopaque,
    group: []const u8,
    text: []const u8,
    to: []poltergeistpkg.ControlFix.Target,
    who: poltergeistpkg.rpc.Typist,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (to.len != 1) return error.BadRequest;
    var deliveries = [_]poltergeistpkg.rpc.Delivery{.{ .to = to[0].to }};
    const posted = try chatPost(ctx, group, poltergeistpkg.Chat.user_id, text, .{
        .from_title = "you",
        .to = &deliveries,
        .typist = who,
    });
    to[0].err = deliveries[0].err;
    const pending = deliveries[0].err != null and self.mention_retries.pending(group, posted.seq, to[0].to);
    self.control_asks.asked(self.alloc, group, posted.seq, deliveries[0].err, pending) catch |err| {
        log.warn("control room: ask in group={s} seq={d} not kept err={}", .{ group, posted.seq, err });
    };
    log.info("control room: ask posted in group={s} seq={d} pending={}", .{ group, posted.seq, pending });
}

/// "Fix" on a lone terminal's card: typed into it, by `terminal_send`'s
/// road. There is no group to keep it in.
fn controlActFixSend(ctx: *anyopaque, id: poltergeistpkg.Bus.Id, text: []const u8, who: poltergeistpkg.rpc.Typist) anyerror!void {
    try poltergeistSendAs(ctx, id, text, true, who);
}

fn controlActFixSent(ctx: *anyopaque, stamp: u64) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.control_fix_sent.mark(self.alloc, stamp);
}

/// The paragraph "Fix" types, in the interface's language: the one the
/// core was started in (`LANG`, which the macOS app sets from its own
/// language choice), as every other word the core writes.
fn controlFixTr(msgid: [:0]const u8) []const u8 {
    return std.mem.span(internal_os.i18n._(msgid.ptr));
}

/// `MM-DD HH:MM`, in the person's timezone: when a failure happened, in
/// the paragraph "Fix" types.
fn controlFixClock(buf: *[19]u8, at_ms: i64) []const u8 {
    const full = poltergeistpkg.daylog.stamp(buf, at_ms);
    return if (full.len >= 16) full[5..16] else full;
}

/// "Rename" from the control room: `group_rename`'s road, by the person.
fn controlActRenameGroup(ctx: *anyopaque, from: []const u8, to: []const u8) anyerror!void {
    try chatRename(ctx, from, to, poltergeistpkg.Chat.user_id);
}

/// "Edit the brief" from the control room: `group_set_brief`'s road.
fn controlActSetBrief(ctx: *anyopaque, group: []const u8, brief: []const u8) anyerror!void {
    _ = try chatSetBrief(ctx, group, brief);
}

fn controlActOpenTasks(ctx: *anyopaque, group: []const u8) usize {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.tasks.openInGroup(group);
}

/// "Delete group" from the control room, after its dialog (task 1659).
///
/// **The one delete that removes the record, and it is the person's.**
/// `chatDestroy` -- `group_destroy`, what an agent can call -- takes a group
/// off the list and leaves every word of it on disk: an agent asked to tidy
/// up must never be able to destroy what the person reads the morning
/// after. The person may, having read a dialog that says what goes and that
/// it does not come back. So here, in this order:
///
///  1. **Its terminals are taken out of it, and none is closed** -- by
///     `group_remove`'s road, so each one's leaving is recorded like any
///     other (into the record that is about to go, and harmless).
///  2. **Everything in memory under its name goes**, by `group_stores.Table`
///     with no `else`, so a table added there without being dropped here
///     does not compile.
///  3. **Its directory under each of `group_stores.Root` is deleted**, with
///     every handle into them let go first. `chat/` last: a crash part way
///     leaves the group listed, with less in it, to be deleted again --
///     never directories no group owns.
///
/// What it does not touch: the stream every group shares (`chat.jsonl`),
/// which the archive plugin follows by seq and which forgets by size on its
/// own; copies a plugin has made elsewhere; and the terminals' own
/// transcripts, which are the terminals' and not the group's. The stream
/// still holding the group's lines is why step 3 holds the record's floor
/// before it deletes anything (`ChatLog.holdFloor`, task 1665): without it
/// the next start fills the group straight back in from the stream.
fn controlActDeleteGroup(ctx: *anyopaque, group: []const u8) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const stores = poltergeistpkg.group_stores;
    if (!self.chat.exists(group)) return error.NoSuchGroup;

    {
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const members = try self.chat.membersOf(arena.allocator(), group);
        for (members) |id| {
            if (id == poltergeistpkg.Chat.user_id) continue;
            chatRemove(ctx, group, id) catch |err| {
                log.warn("control room: could not take {x} out of {s} err={}", .{ id, group, err });
            };
        }
    }

    inline for (comptime std.enums.values(stores.Table)) |table| switch (table) {
        .chat_groups => try self.chat.destroy(group),
        .task_group_field => self.tasks.forgetGroup(group),
        .stats_last => if (self.stats_log) |*l| l.dropGroup(group),
        .mention_retries => self.mention_retries.dropGroup(group),
        .control_asks => self.control_asks.forget(self.alloc, group),
        .resource_names => self.resource_names.dropGroup(self.alloc, group),
        .reclaim_groups => if (self.reclaim) |*r| r.dropGroup(group),
        .overall_rows => if (self.resource_overall) |o| o.forgetGroup(group),
        .alarms => {
            self.alarmsHeld().dropGroup(group);
            self.saveAlarms();
        },
    };

    if (self.poltergeist_state_dir) |dir| {
        closeStoreHandles(self);
        defer self.reopenStoreHandles();
        stores.deleteGroupDirs(self.alloc, global.io(), dir, group) catch |err| {
            log.warn("control room: could not delete the record of {s} err={}", .{ group, err });
            return error.DeleteFailed;
        };
    }

    log.info("control room: group {s} deleted with its record", .{group});
    self.saveSession();
    self.controlRoomTouch();
}

fn controlActAgentPresent(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.agentPresent(id);
}

fn controlActPersist(ctx: *anyopaque, group: []const u8, marks: poltergeistpkg.Chat.Marks) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.group_log) |*l| l.mark(group, marks);
}

/// The person's home directory, looked up once: where the control room
/// offers to start a supervisor when nothing says better. Empty when it
/// cannot be found.
fn controlHome(self: *App) []const u8 {
    if (self.control_home) |h| return h;
    self.control_home = "";
    var environ_map = global.environMap() catch return "";
    defer environ_map.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = (internal_os.home(global.io(), &environ_map, &buf) catch null) orelse return "";
    self.control_home = self.alloc.dupe(u8, found) catch "";
    return self.control_home.?;
}

/// A group made from the control room: the person's, made the way every
/// other group is.
fn controlActCreateGroup(ctx: *anyopaque, name: []const u8) anyerror!void {
    try chatCreate(ctx, name, poltergeistpkg.Chat.user_id);
}

fn controlActStewardOf(ctx: *anyopaque, group: []const u8) ?poltergeistpkg.Bus.Id {
    const self: *App = @ptrCast(@alignCast(ctx));
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    return poltergeistpkg.ControlRoom.stewardOfGroup(arena.allocator(), &self.poltergeist, &self.chat, group);
}

/// Start a supervisor for `group` from the control room: a tab, the role's
/// CLI typed into it, and "this terminal is `group`'s supervisor" held
/// until the agent connects from it (`controlStartConnected`).
///
/// **Nobody's terminal is asking**, which is what sets this apart from
/// `launchPersona`: the launch is the person's (`Chat.user_id`), the tab
/// is asked of the application rather than of a terminal, and the new
/// terminal is the person's own, not one an agent opened.
///
/// The role is the one named, or the one the snapshot names
/// (`ControlRoom.startRoleOf`): what the group's last supervisor wore when
/// that is still a role to start in, else the first. A role set up for
/// several CLIs is started in the last supervisor's when it is one of
/// them, else in its first (`ControlRoom.startCliOf`) -- the control room
/// offers a role and a directory, not a third choice.
///
/// **Which session**: the last supervisor's when `session` is `.last` and
/// `ControlRoom.resumeOf` says it can be gone on with -- the same function
/// the snapshot's `resume` is, asked again now for the role this start
/// uses -- and a new one otherwise. The id rides the launch line as
/// `--resume=`, and from there to the CLI's adapter, which is the one that
/// knows what going on with a session takes and starts a new one if the
/// session turns out to be gone.
fn controlActStartSupervisor(
    ctx: *anyopaque,
    group: []const u8,
    role_asked: []const u8,
    cwd_asked: []const u8,
    cli_asked: []const u8,
    session_asked: poltergeistpkg.ControlAct.Session,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const Chat = poltergeistpkg.Chat;
    const Store = poltergeistpkg.PersonaStore;
    const ControlRoom = poltergeistpkg.ControlRoom;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const last = self.chat.lastSupervisorOf(group);
    // **Once for the whole start** (task 2156 v3): what the person has of
    // their own does not change under a single action, and reading it twice
    // would free the answer the first read handed out.
    const own = self.ownClis();

    // The role: the one named, or the one the snapshot named as the
    // default.
    self.ensurePersonas();
    const p = if (role_asked.len > 0)
        self.personas.set.find(role_asked) orelse return error.NoSuchPersona
    else p: {
        const roles = try self.controlStartRoles(alloc, own);
        const role = ControlRoom.startRoleOf(roles, last) orelse return error.NoSupervisorRole;
        break :p self.personas.set.find(role.key) orelse return error.NoSupervisorRole;
    };
    if (!p.polter.supervisor) return error.NotASupervisorRole;
    // What it can be started in: its CLIs and the person's own ticked for
    // it, alike (task 2156 v3).
    const role = try self.startRoleOf(alloc, p, own);
    if (role.clis.len == 0) return error.NoCli;

    // The CLI: the one picked, or the snapshot's default by the same
    // function -- of the role's CLIs whose plugin is on, the one the last
    // supervisor was started in, else the first. Whether the picked one
    // can start here is `resolveLaunch`'s to refuse, with its reason.
    const cli: []const u8 = if (cli_asked.len > 0)
        (for (role.clis) |c| {
            if (std.mem.eql(u8, c, cli_asked)) break c;
        } else return error.NotSetUpForCli)
    else cli: {
        const here = try ControlRoom.startClisOf(alloc, role, try self.controlCliStandings(alloc, own));
        // None of the role's can start: `resolveLaunch` says which reason,
        // asked of its first.
        break :cli ControlRoom.startCliOf(here, last, own, role.key) orelse role.clis[0];
    };

    // A group that has a project is started in it: the pane has its own
    // directory, and none is opened here.
    const by_project = self.chat.projectOf(group) == .bound;

    // The directory: the one named, or the snapshot's, by the same order.
    const cwd: []const u8 = if (by_project) "" else if (cwd_asked.len > 0) cwd_asked else self.controlStartDir(group);
    const dir_z: [:0]const u8 = if (cwd.len > 0) try startDirZ(alloc, cwd) else "";

    const rt_app = self.poltergeist_rt_app orelse return error.NoRuntime;
    const choice = try self.resolveLaunch(alloc, p.key, cli, null, own);
    const now_ms = self.poltergeistElapsedMs();

    // Whether it goes on with the last session. Asked for the role and the
    // CLI this start uses, which the person may have picked since the
    // snapshot was drawn -- by the key it was picked by, which for one of
    // the person's own is its own (task 2156 v3).
    const go_on = ControlRoom.resumeOf(.{
        .last = last,
        .cli = choice.launcher orelse choice.cli,
        .role = p.key,
        .own = own,
        .cli_resume = try self.controlCliResume(alloc),
        .held = ControlRoom.sessionHeld(&self.poltergeist, try self.liveTerminals(alloc), last.session),
        .last_try_failed = fails: {
            const was = self.chat.startOf(group, now_ms);
            break :fails was.state == .failed and was.resuming;
        },
    });
    const resuming = session_asked == .last and go_on.can;
    // **Going on through something the role no longer has** (task 2156 v5):
    // the Agent CLI the last session was opened through has been deleted or
    // unticked for this role since, and what this start goes in is the CLI
    // underneath it. Said in the group, with the CLI underneath it -- where
    // v3 only said the deleted case, in the terminal, and said nothing at
    // all when it had merely been unticked.
    //
    // **Not only when going on with the session** (review of v5): a new
    // session swaps CLIs for the same reason and used to be swapped in
    // silence, so the person saw the CLI change under them with nothing
    // saying why. The two cases are one sentence each, because what the
    // session is doing differs: one is going on, the other is starting.
    //
    // **One `allocPrint` a branch, not one with the format chosen at
    // run time.** A format string has to be comptime-known, so
    // `allocPrint(alloc, if (resuming) "a" else "b", …)` does not build at
    // all -- and the named test filter did not catch it, because nothing in
    // `test` reaches this function (`ghostty_app_control_act` does). What
    // caught it was `zig build -Demit-macos-app=false`, and that is now part
    // of what is run before this is handed over.
    if (ControlRoom.lostLauncher(last, own, p.key)) |gone| {
        const was = ControlRoom.cliLabelOf(try self.controlCliNames(alloc, own), gone) orelse gone;
        // What it actually went in, which is `choice`'s answer: an own one
        // by its key, else the CLI. `choice` was worked out above, so this
        // is only said about a start that was not refused.
        const now = ControlRoom.cliLabelOf(try self.controlCliNames(alloc, own), choice.launcher orelse choice.cli) orelse choice.cli;
        self.sayInGroup(group, if (resuming)
            try std.fmt.allocPrint(
                alloc,
                "[Polter] The Agent CLI \"{s}\" is no longer switched on for the role {s}, so the session it opened is going on in {s}.",
                .{ was, p.name, now },
            )
        else
            try std.fmt.allocPrint(
                alloc,
                "[Polter] The Agent CLI \"{s}\" is no longer switched on for the role {s}, so this supervisor starts in {s} instead.",
                .{ was, p.name, now },
            ));
    }
    const line = try launchLineFor(alloc, choice, .{
        .group = group,
        .session = if (resuming) last.session else null,
    });
    log.info("control room: starting a supervisor, session={s} ({t})", .{
        if (resuming) "last" else "new",
        if (session_asked == .new) poltergeistpkg.ControlRoom.ResumeOut.Why.none else go_on.why,
    });

    // **Its project, when it has one.** Nothing is opened from here: the
    // start waits, the snapshot orders the host to open the project
    // (`Projects`, `open`), and the launch is held until the host states
    // which terminal is in the supervisor's pane (`projectsWork`).
    if (by_project) {
        try self.chat.beginStart(group, now_ms, now_ms + project_open_ms, resuming, .project);
        errdefer self.chat.endStart(group);
        try self.holdProjectLaunch(group, choice, line);
        log.info("control room: starting a supervisor by opening its group's project, in role {s}", .{choice.key});
        return;
    }

    // From here a refusal has something to take back.
    try self.chat.beginStart(group, now_ms, now_ms + Store.pending_launch_ms, resuming, .directory);
    errdefer self.chat.endStart(group);
    try self.personas.expectLaunch(choice.key, choice.cli, line, Chat.user_id, now_ms);
    errdefer self.personas.dropLaunch();

    // The person clicked "Start": brought forward.
    _ = try self.openStartTab(alloc, rt_app, dir_z, now_ms, .person);
    log.info("control room: starting a supervisor for a group in role {s}", .{choice.key});
}

/// The directory a start in a group's own tab opens in, when none was
/// asked for: its last supervisor's, else the one its members share, else
/// home.
fn controlStartDir(self: *App, group: []const u8) []const u8 {
    const last = self.chat.lastSupervisorOf(group);
    if (last.dir.len > 0) return last.dir;
    const common = self.chat.commonDirOf(group);
    if (common.len > 0) return common;
    return self.controlHome();
}

/// `cwd` as a tab is opened in, once it is known to be a directory.
fn startDirZ(alloc: Allocator, cwd: []const u8) ![:0]const u8 {
    if (!std.fs.path.isAbsolute(cwd)) return error.NotAbsolute;
    var dir = std.Io.Dir.openDirAbsolute(global.io(), cwd, .{}) catch
        return error.NoSuchDirectory;
    defer dir.close(global.io());
    const stat = dir.stat(global.io()) catch return error.NoSuchDirectory;
    if (stat.kind != .directory) return error.NotADirectory;
    return try alloc.dupeZ(u8, cwd);
}

/// Ask for the tab a start's launch waits for (`personas.expectLaunch`),
/// in `dir_z`, and answer the terminal it is: null when none appeared.
/// `by` is who wants it (task 1823): the person's click in the control
/// room brings it forward, the core's own start does not.
fn openStartTab(
    self: *App,
    alloc: Allocator,
    rt_app: *apprt.App,
    dir_z: [:0]const u8,
    now_ms: u64,
    by: apprt.action.NewTab.By,
) !?poltergeistpkg.Bus.Id {
    var before: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, void) = .empty;
    for (self.surfaces.items) |v| try before.put(alloc, v.core().id, {});

    // Asked of the application. A host that only puts a tab beside a
    // terminal says it did nothing, and is asked again with one.
    var answer: apprt.action.NewTab.Result = .unanswered;
    var asked = rt_app.performAction(
        .app,
        .new_tab,
        .{ .working_directory = dir_z, .result = &answer, .by = by },
    ) catch false;
    if (!asked) for (self.surfaces.items) |v| {
        if (self.isChatSurface(v.core().id)) continue;
        answer = .unanswered;
        asked = rt_app.performAction(
            .{ .surface = v.core() },
            .new_tab,
            .{ .working_directory = dir_z, .result = &answer, .by = by },
        ) catch false;
        break;
    };
    try tabWasAsked(asked, answer);

    // A host that makes the tab inside the call has already had it claim
    // the launch (`claimPendingLaunch`). One that had not: it is this
    // terminal's now, the same way.
    for (self.surfaces.items) |v| {
        const id = v.core().id;
        if (before.contains(id) or self.isChatSurface(id)) continue;
        if (self.personas.takeLaunch(now_ms)) |taken| {
            var launch = taken;
            defer launch.deinit();
            try self.startRoleInAs(id, launch.by, .{ .key = launch.key, .cli = launch.cli }, launch.line, .agent, launch.effective);
            self.controlStartOpened(id);
        }
        return id;
    }
    return null;
}

/// A launch held for its project's supervisor's pane, where the project is
/// open and marks none (task 1794): started in a new tab instead, in the
/// group's last supervisor's directory, and that tab is to become a page
/// of the project with its pane marked (`project_seating`). On a tick, not
/// inside the snapshot that found it.
fn startHeldInANewTab(self: *App, rt_app: *apprt.App, now_ms: u64) void {
    const held = if (self.project_launch) |*l| l else return;
    if (!held.no_seat) return;
    defer {
        held.arena.deinit();
        self.project_launch = null;
    }
    const Store = poltergeistpkg.PersonaStore;
    const group = held.group;
    // Its time ran out before this tick: it failed as a project start, and
    // is not brought back as another kind.
    if (!self.chat.startAwaitingProject(group, now_ms)) return;
    const project = switch (self.chat.projectOf(group)) {
        .bound => |name| name,
        else => return,
    };
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cwd = self.controlStartDir(group);
    log.warn("control room: project {s} is open and marks no pane as its supervisor's; starting the supervisor of {s} in a new tab of it, in {s}", .{ project, group, cwd });
    const dir_z = startDirZ(alloc, cwd) catch |err| {
        log.warn("control room: could not start the supervisor in a new tab of its project: its directory err={}", .{err});
        self.chat.failStart(group, .terminal_never_opened);
        return;
    };
    if (!self.chat.startByDirectory(group, now_ms + Store.pending_launch_ms)) return;
    self.personas.expectLaunch(held.key, held.cli, held.line, poltergeistpkg.Chat.user_id, now_ms) catch {
        self.chat.failStart(group, .terminal_never_opened);
        return;
    };

    // Before the tab is asked for, with no terminal: the tab that claims
    // the launch fills it in (`controlStartOpened`), inside the ask on
    // macOS, after it on Windows, whose `new_tab` is posted -- so what the
    // ask answers is not waited for (task 1794).
    const owned = self.alloc.dupe(u8, group) catch {
        self.personas.dropLaunch();
        self.chat.failStart(group, .terminal_never_opened);
        return;
    };
    self.dropProjectSeating();
    self.project_seating = .{ .group = owned, .terminal = null };

    // Later than the click, and the core's doing: in the background (task
    // 1823), whatever the person has moved on to.
    _ = self.openStartTab(alloc, rt_app, dir_z, now_ms, .core) catch |err| {
        log.warn("control room: could not open a tab for the supervisor err={}", .{err});
        self.personas.dropLaunch();
        self.chat.failStart(group, .terminal_never_opened);
        self.dropProjectSeating();
        return;
    };
    self.controlRoomTouch();
}

/// An agent judged in a project's supervisor's pane that has left since is
/// forgotten, so the next one there is judged (task 1795) -- also one whose
/// CLI says no session id, and whose first request comes after its left
/// was taken back. `SeatJudged.seen` is the rule: a leave is the left
/// turning true, not a left that is still there.
fn forgetSeatAgentsThatLeft(self: *App) void {
    while (true) {
        var it = self.seat_judged.by_terminal.iterator();
        const left = while (it.next()) |e| {
            const now = self.poltergeist.agentHasLeft(e.key_ptr.*);
            if (now and !e.value_ptr.left) break e.key_ptr.*;
            // Or its round is over (task 1829): a refused agent is not
            // watched, and leaves no left.
            if (self.agentRound(e.key_ptr.*) != e.value_ptr.round) break e.key_ptr.*;
            e.value_ptr.left = now;
        } else return;
        self.seat_judged.gone(left);
    }
}

/// `Server.agentRound`: which time an agent has been connected from `id`,
/// 0 for none.
fn agentRound(self: *App, id: poltergeistpkg.Bus.Id) u64 {
    if (self.poltergeist_server) |*srv| return srv.agentRound(id);
    return 0;
}

fn dropProjectSeating(self: *App) void {
    if (self.project_seating) |s| self.alloc.free(s.group);
    self.project_seating = null;
}

/// The tab a start opened to be seated is done with: the host says its
/// pane is the project's marked one, or it is gone (task 1794).
fn settleProjectSeating(self: *App) void {
    const seat = self.project_seating orelse return;
    // A group no longer tied to a project has nothing to be seated in.
    const name = switch (self.chat.projectOf(seat.group)) {
        .bound => |n| n,
        else => return self.dropProjectSeating(),
    };
    const seated = if (self.projects.find(name)) |p|
        seat.terminal != null and p.supervisor != null and p.supervisor.? == seat.terminal.?
    else
        false;
    const gone = if (seat.terminal) |t| for (self.surfaces.items) |v| {
        if (v.core().id == t) break false;
    } else true else false;
    if (!seat.over(self.chat.startAwaitingTerminal(self.poltergeistElapsedMs()), seated, gone)) return;
    if (seated) {
        log.info("control room: the tab started for {s}'s supervisor is its project's supervisor's pane now", .{seat.group});
    } else if (seat.terminal == null) {
        log.warn("control room: no tab came for {s}'s supervisor; nothing to seat", .{seat.group});
    }
    self.dropProjectSeating();
}

/// The terminal a control-room start was waiting for is `id`: from now it
/// is the agent in it that is waited for.
fn controlStartOpened(self: *App, id: poltergeistpkg.Bus.Id) void {
    const now_ms = self.poltergeistElapsedMs();
    const group = self.chat.startAwaitingTerminal(now_ms) orelse return;
    // The tab a start opened to be seated in its project (task 1794).
    if (self.project_seating) |*s| if (s.opened(group, id))
        log.info("control room: the tab {x} claimed {s}'s supervisor's launch, and is to be seated", .{ id, group });
    self.chat.startOpened(group, id, now_ms + poltergeistpkg.PersonaStore.standing_wait_ms);
    self.controlRoomTouch();
}

/// An agent has connected from `id`. If the control room started it there
/// to be a group's supervisor and it now is one, it goes into that group
/// -- which is what makes it the group's supervisor in the snapshot, and
/// what the control room then shows on its right-hand side.
///
/// Only a terminal that *is* a supervisor: the standing comes from the
/// role (`PersonaStore.claimStanding`), and a role whose standing ran out
/// leaves the start to fail by its own deadline rather than putting a
/// plain agent in charge of a group.
fn controlStartConnected(self: *App, id: poltergeistpkg.Bus.Id) void {
    const now_ms = self.poltergeistElapsedMs();
    const group = self.chat.startingIn(id, now_ms) orelse return;
    if (!self.poltergeist.isSupervisor(id)) return;

    chatAdd(self, group, id, .all) catch |err| {
        log.warn("control room: could not put the supervisor it started in its group err={}", .{err});
        return;
    };
    // Over, and remembered: this terminal's `me` says which group it was
    // started for.
    self.chat.startMade(group, id);
    log.info("control room: the supervisor it started connected and is in its group", .{});
    self.controlRoomTouch();

    // **Its CLI had none of Polter's tools in its first turn** (task 1746):
    // the role's instructions went in as that turn and told it to answer in
    // a word and wait. What to do first is said now, as a second message,
    // once that turn is over -- a session picked up again too: its first
    // turn has no tools either (measured, round two).
    //
    // Each way out says so (task 1787): this used to go quiet at every one,
    // and a second message that never came left nothing in the log to find.
    const cli = if (self.personas.launchOf(id)) |l| l.choice.cli else {
        log.info("control room: no second message for 0x{x}: its launch is not known", .{id});
        return;
    };
    self.ensurePlugins();
    const says = poltergeistpkg.Plugin.startupFor(self.poltergeist_says, cli) orelse {
        log.info("control room: no second message for 0x{x}: {s} declares nothing it shows at startup", .{ id, cli });
        return;
    };
    if (!says.tools_from_second_turn) {
        log.info("control room: no second message for 0x{x}: {s} has Polter's tools from its first turn", .{ id, cli });
        return;
    }
    var buf: [poltergeistpkg.OwedTells.max_line + 1]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, start_line_fmt, .{group}) catch {
        log.warn("control room: the group's name is too long for the started supervisor's second message; not sent", .{});
        return;
    };
    self.start_lines.owe(id, line) catch |err| {
        log.warn("control room: could not keep the started supervisor's second message err={}", .{err});
        return;
    };
    self.noteStartOwed(id, group);
    self.payStartLines();
}

const StartOwed = struct { at_ms: u64, group: []u8 };

/// Remember when the second message for `id` was first owed, and for which
/// group. A message owed again keeps its first moment: the wait for the
/// agent does not start over.
fn noteStartOwed(self: *App, id: poltergeistpkg.Bus.Id, group: []const u8) void {
    if (self.start_owed.contains(id)) return;
    const copy = self.alloc.dupe(u8, group) catch return;
    self.start_owed.put(self.alloc, id, .{ .at_ms = self.poltergeistElapsedMs(), .group = copy }) catch self.alloc.free(copy);
}

fn forgetStartOwed(self: *App, id: poltergeistpkg.Bus.Id) void {
    if (self.start_owed.fetchRemove(id)) |kv| self.alloc.free(kv.value.group);
}

/// The second message (`start_lines`): what the role's instructions said to
/// do first, now that Polter's tools are there.
///
/// It names the tools, because a first turn that reached Polter some other
/// way is copied in the turns after it: an agy supervisor whose first turn
/// started `polter +mcp` from Python still did so in its second (task 1740,
/// seq 51). Only Antigravity declares a second turn, so the names are its.
const start_line_fmt = "Start now. Polter's tools are loaded: call them directly (in Antigravity " ++
    "their names begin polter_polter/), never by starting polter from a shell. Call me, read " ++
    "the group `{s}`, then wait for the person.";

/// How often an owed second message is looked at again while its CLI's
/// first turn is still going and nothing else comes round.
const start_line_look_ms: u64 = 2_000;

/// Type the second messages owed (`start_lines`) whose first turn is over,
/// each once.
fn payStartLines(self: *App) void {
    if (self.start_lines.lines.count() > 0) self.start_lines.pay(self, startLineTry);
    self.checkStartLines();
    if (self.start_lines.lines.count() > 0 or self.start_checks.count() > 0) self.noticeRetryIn(start_line_look_ms);
}

const StartCheck = struct { line: []u8, typed_ms: u64, tries: u8 };

/// A second message was typed into `id`: looked at again a moment later
/// (`checkStartLines`).
fn noteStartLineTyped(self: *App, id: poltergeistpkg.Bus.Id, line: []const u8) void {
    const now_ms = self.poltergeistElapsedMs();
    const got = self.start_checks.getOrPut(self.alloc, id) catch return;
    if (got.found_existing) {
        got.value_ptr.typed_ms = now_ms;
        got.value_ptr.tries +|= 1;
        return;
    }
    const copy = self.alloc.dupe(u8, line) catch {
        _ = self.start_checks.remove(id);
        return;
    };
    got.value_ptr.* = .{ .line = copy, .typed_ms = now_ms, .tries = 1 };
}

/// Whether each second message typed has reached its CLI (task 1746, round
/// two; `rpc.lineCheck`): its first words on the screen, or a turn begun
/// since. One that has not is typed again once -- through `startLineTry`,
/// so again only with the turn over and the input box showing -- and one
/// that has not after that is said in the log and given up on.
fn checkStartLines(self: *App) void {
    if (self.start_checks.count() == 0) return;
    const now_ms = self.poltergeistElapsedMs();
    var done: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
    defer done.deinit(self.alloc);
    var it = self.start_checks.iterator();
    while (it.next()) |kv| {
        const id = kv.key_ptr.*;
        const c = kv.value_ptr.*;
        if (self.findSurfaceByID(id) == null or !self.agentPresent(id)) {
            done.append(self.alloc, id) catch break;
            continue;
        }
        const agent = self.poltergeist.agentOf(id);
        const turn_since = agent.known() and agent.state == .in_turn and agent.since_ms >= c.typed_ms;
        const head = c.line[0..@min(c.line.len, start_line_head)];
        const on_screen = on: {
            const screen = poltergeistRead(self, self.alloc, id, 0) catch break :on false;
            defer self.alloc.free(screen);
            break :on std.mem.indexOf(u8, screen, head) != null;
        };
        switch (poltergeistpkg.rpc.lineCheck(on_screen, turn_since, now_ms -| c.typed_ms, c.tries)) {
            .reached => {
                log.info("control room: the started supervisor's second message reached it id={x} tries={d}", .{ id, c.tries });
                done.append(self.alloc, id) catch break;
            },
            .wait => {},
            .again => {
                log.warn("control room: the started supervisor's second message did not show; typing it again id={x}", .{id});
                self.start_lines.owe(id, c.line) catch {};
            },
            .give_up => {
                log.warn("control room: the started supervisor's second message did not reach it after {d} tries; not typed again -- it waits at its first answer id={x}", .{ c.tries, id });
                done.append(self.alloc, id) catch break;
            },
        }
    }
    for (done.items) |id| {
        if (self.start_checks.fetchRemove(id)) |kv| self.alloc.free(kv.value.line);
    }
}

/// How much of a second message's start is looked for on the screen: its
/// first words, which fit on one row of any terminal it is typed into.
const start_line_head = 24;

/// One owed second message: kept while its CLI's first turn is still going
/// (`Plugin.StartupSays.firstTurnOver`) or while the terminal refuses a
/// line -- the person typing, a draft, a box (`Surface.mayType`) -- and
/// typed once, after.
fn startLineTry(self: *App, id: poltergeistpkg.Bus.Id, line: []const u8) poltergeistpkg.OwedTells.Outcome {
    const surface = self.findSurfaceByID(id) orelse {
        log.info("control room: the started supervisor's second message is not typed: its terminal is closed id={x}", .{id});
        self.forgetStartOwed(id);
        return .gone;
    };
    // **Its agent may not have connected yet** (task 1787): agy's hook can
    // come before its MCP server, and this used to drop the line right
    // there, without a word.
    if (!self.agentPresent(id)) {
        const owed_ms = if (self.start_owed.get(id)) |o| o.at_ms else self.poltergeistElapsedMs();
        switch (poltergeistpkg.rpc.startLineWithoutAgent(surface.shellIdle(), self.poltergeistElapsedMs() -| owed_ms)) {
            .wait => return .refused,
            .gone => {
                log.info("control room: the started supervisor's second message is not typed: its CLI has exited id={x}", .{id});
                self.forgetStartOwed(id);
                return .gone;
            },
            .give_up => {
                log.warn("control room: the started supervisor's second message is not typed: no agent connected from its terminal within {d}s; given up id={x}", .{ poltergeistpkg.rpc.start_line_agent_wait_ms / std.time.ms_per_s, id });
                self.startLineGivenUp(id);
                return .gone;
            },
        }
    }
    // A copy, kept for as long as the name read out of it is used.
    const agent = self.poltergeist.agentOf(id);
    const cli = if (self.personas.launchOf(id)) |l| l.choice.cli else {
        log.warn("control room: the started supervisor's second message is not typed: its launch is no longer known id={x}", .{id});
        self.forgetStartOwed(id);
        return .gone;
    };
    const says = poltergeistpkg.Plugin.startupFor(self.poltergeist_says, cli) orelse {
        log.warn("control room: the started supervisor's second message is not typed: {s} no longer declares its startup id={x}", .{ cli, id });
        self.forgetStartOwed(id);
        return .gone;
    };
    const said: ?bool = if (agent.hooks == .live) agent.state == .ended else null;
    const screen = poltergeistRead(self, self.alloc, id, 0) catch return .refused;
    defer self.alloc.free(screen);
    if (!says.firstTurnOver(said, screen)) return .refused;
    const typed = surface.typePoltergeistNotice(line) catch |err| {
        log.warn("control room: the started supervisor's second message could not be typed err={} id={x}", .{ err, id });
        self.forgetStartOwed(id);
        return .gone;
    };
    if (typed) {
        log.info("control room: the started supervisor's second message is typed id={x}", .{id});
        self.noteStartLineTyped(id, line);
        self.forgetStartOwed(id);
        return .typed;
    }
    if (surface.poltergeist_notice_refused) return .refused;
    log.warn("control room: the started supervisor's second message was not taken by its terminal id={x}", .{id});
    self.forgetStartOwed(id);
    return .gone;
}

/// A second message given up on because no agent ever connected (task
/// 1787): said where the person who started it will see it.
fn startLineGivenUp(self: *App, id: poltergeistpkg.Bus.Id) void {
    const owed = self.start_owed.fetchRemove(id) orelse return;
    defer self.alloc.free(owed.value.group);
    self.sayStartLineGivenUp(owed.value.group, id);
}

/// Into the group's record, where the control room shows it to the person
/// who started the supervisor (task 1787). The record has no author of its
/// own for Polter, so it is signed with the terminal it is about and says
/// who is speaking in its first word.
fn sayStartLineGivenUp(self: *App, group: []const u8, id: poltergeistpkg.Bus.Id) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "[Polter] This supervisor's second message was not typed: no agent connected from its terminal " ++
            "within {d}s. It waits at its first answer -- tell it in its tab to call me and read the group `{s}`.",
        .{ poltergeistpkg.rpc.start_line_agent_wait_ms / std.time.ms_per_s, group },
    ) catch return;
    _ = chatPost(self, group, id, text, .none) catch |err| {
        log.warn("control room: could not say in group {s} that the second message was given up err={}", .{ group, err });
        return;
    };
    self.controlRoomTouch();
}

/// How a first prompt Polter types ends: the same words `-i` carries
/// (`plugins/antigravity/adapter.py`, `FIRST_PROMPT_END`), for the same
/// reason -- the CLI's first turn has none of Polter's tools
/// (`Plugin.StartupSays.tools_from_second_turn`).
const first_prompt_end = "This message is how you are given your instructions; it is not a task. " ++
    "Polter's tools are not loaded yet in this turn, so do not try to reach them: " ++
    "answer with the one word \"Ready\" and call no tool at all. " ++
    "The next message says when to start.";

/// Type the first prompts owed (`first_prompts`) whose terminal is ready
/// for one, each once, and forget the ones nothing is left to owe.
fn payFirstPrompts(self: *App) void {
    if (self.first_prompts.count() == 0) return;
    var done: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
    defer done.deinit(self.alloc);
    var it = self.first_prompts.keyIterator();
    while (it.next()) |id| {
        if (self.firstPromptTry(id.*)) done.append(self.alloc, id.*) catch break;
    }
    for (done.items) |id| _ = self.first_prompts.remove(id);
    if (self.first_prompts.count() > 0) self.noticeRetryIn(start_line_look_ms);
}

/// One owed first prompt. Answers whether it is settled: typed, or nothing
/// left to owe. **Not a byte while the trust box is up**
/// (`rpc.firstPromptStep`): its return would answer it.
fn firstPromptTry(self: *App, id: poltergeistpkg.Bus.Id) bool {
    if (self.findSurfaceByID(id) == null) return true;
    switch (poltergeistpkg.rpc.firstPromptStep(self.agentPresent(id), self.startupReachRaw(id))) {
        .wait => return false,
        .drop => return true,
        .type => {},
    }
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const text = self.firstPromptText(arena.allocator(), id) orelse {
        log.warn("poltergeist: 0x{x} owes a first prompt and its role has no instructions any more; nothing typed", .{id});
        return true;
    };
    poltergeistSendAs(self, id, text, true, .agent) catch |err| switch (err) {
        // The person is at it, a draft, a box: the next look tries again.
        error.UserPresent, error.Composing, error.DraftInLine, error.ApprovalOnScreen => return false,
        else => {
            log.warn("poltergeist: could not type the first prompt into 0x{x} err={}", .{ id, err });
            return true;
        },
    };
    log.info("poltergeist: the first prompt is typed into 0x{x}", .{id});
    return true;
}

/// The role's instructions as `+launch` would have passed them -- with the
/// group a control-room start is for -- and how a first prompt ends.
fn firstPromptText(self: *App, aa: Allocator, id: poltergeistpkg.Bus.Id) ?[]const u8 {
    const launch = self.personas.launchOf(id) orelse return null;
    const p = self.personas.set.find(launch.role) orelse return null;
    const group = self.chat.startingIn(id, self.poltergeistElapsedMs());
    const own = (poltergeistpkg.persona.launchedInstructions(aa, p, launch, group) catch return null) orelse return null;
    return std.mem.concat(aa, u8, &.{ own, "\n\n", first_prompt_end }) catch null;
}

/// How long a start waits for the host to open the group's project and
/// say which terminal is in the supervisor's pane. Longer than a tab gets:
/// a project is several windows and every page's shell.
const project_open_ms: u64 = 30_000;

const ProjectLaunch = struct {
    arena: std.heap.ArenaAllocator,
    group: []const u8,
    key: []const u8,
    cli: []const u8,
    line: []const u8,
    /// The host stated the project open with no pane marked as the
    /// supervisor's: the launch goes into a new tab of it on the next tick
    /// (`startHeldInANewTab`), not here in the middle of a snapshot.
    no_seat: bool,
};

fn holdProjectLaunch(self: *App, group: []const u8, choice: LaunchChoice, line: []const u8) Allocator.Error!void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const held: ProjectLaunch = .{
        .arena = undefined,
        .group = try aa.dupe(u8, group),
        .key = try aa.dupe(u8, choice.key),
        .cli = try aa.dupe(u8, choice.cli),
        .line = try aa.dupe(u8, line),
        .no_seat = false,
    };
    if (self.project_launch) |*old| old.arena.deinit();
    self.project_launch = held;
    self.project_launch.?.arena = arena;
}

/// Every group as `Projects` needs to see it. Borrowed from `alloc` and
/// from `chat`; good until the next change to either.
fn projectViews(self: *App, alloc: Allocator, now_ms: u64) Allocator.Error![]const poltergeistpkg.Projects.GroupView {
    const Chat = poltergeistpkg.Chat;
    const live = try self.liveTerminals(alloc);
    const names = try self.chat.groupsFor(alloc, Chat.user_id, live);
    const views = try alloc.alloc(poltergeistpkg.Projects.GroupView, names.len);
    for (names, views) |name, *v| {
        const members = self.chat.membersOf(alloc, name) catch &.{};
        var supervisors: usize = 0;
        for (members) |id| {
            if (id == Chat.user_id) continue;
            if (std.mem.indexOfScalar(poltergeistpkg.Bus.Id, live, id) == null) continue;
            if (self.poltergeist.isSupervisor(id)) supervisors += 1;
        }
        v.* = .{
            .name = name,
            .tie = self.chat.projectOf(name),
            .steward = poltergeistpkg.ControlRoom.stewardOfGroup(alloc, &self.poltergeist, &self.chat, name),
            .supervisors = supervisors,
            .claim = self.chat.projectClaimOf(name),
            .awaiting_open = self.chat.startAwaitingProject(name, now_ms),
            .seating = if (self.project_seating) |seat|
                (if (std.mem.eql(u8, seat.group, name)) seat.terminal else null)
            else
                null,
        };
    }
    return views;
}

/// Every open terminal an agent opened, and whose agent.
fn projectOpened(self: *App, alloc: Allocator) Allocator.Error![]const poltergeistpkg.Projects.Opened {
    var out: std.ArrayListUnmanaged(poltergeistpkg.Projects.Opened) = .empty;
    for (self.surfaces.items) |v| {
        const id = v.core().id;
        const by = self.poltergeist.openedBy(id) orelse continue;
        try out.append(alloc, .{ .terminal = id, .by = by });
    }
    return out.items;
}

/// Bring the ties between groups and projects up to date and say what is
/// left for the host: `Projects.reconcile`, with what it asks of this half
/// carried out -- a tie written down, a tie dropped -- and asked again
/// until it asks for nothing more. Then, for a start that is waiting for
/// its project: if the host has stated it open, the launch goes into the
/// supervisor's pane.
///
/// Called while the control room's snapshot is being made, which is after
/// anything that could have changed the answer (`controlRoomTouch`).
fn projectsWork(self: *App, alloc: Allocator, now_ms: u64) Allocator.Error!poltergeistpkg.ControlRoom.ProjectsIn {
    const Projects = poltergeistpkg.Projects;

    // A commit changes a tie, and the next asking then has something else
    // to say about it (tied, so now rename). Three rounds is one more than
    // any chain there is; a fourth would be two commits undoing each other.
    var round: usize = 0;
    var out: Projects.Outcome = undefined;
    while (true) : (round += 1) {
        const views = try self.projectViews(alloc, now_ms);
        out = try self.projects.reconcile(alloc, views, try self.projectOpened(alloc));
        if (out.commits.len == 0 or round == 3) break;
        for (out.commits) |c| {
            // Copied first: the name is borrowed from the tie it replaces.
            const tie: poltergeistpkg.Chat.ProjectTie = if (c.project) |name|
                .{ .bound = try alloc.dupe(u8, name) }
            else
                .undecided;
            const changed = self.chat.setProject(c.group, tie) catch continue;
            if (!changed) continue;
            // Settled, one way or the other: whoever took it up has been
            // answered, and is not asked on behalf of again.
            self.chat.setProjectClaim(c.group, null);
            if (self.group_log) |*l| l.project(c.group, self.chat.projectOf(c.group));
            self.noteGroupProject(c.group);
            log.info("poltergeist: a group's project {s}", .{if (c.project == null) "is gone; it is started by directory again" else "is written down"});
        }
    }

    self.settleProjectSeating();
    self.forgetSeatAgentsThatLeft();
    self.deliverProjectLaunch(now_ms);

    return .{ .table = &self.projects, .standings = out.standings, .orders = out.orders };
}

/// The launch a start is holding goes into the supervisor's pane of its
/// group's project, once the host has stated that project open and said
/// which terminal that is.
fn deliverProjectLaunch(self: *App, now_ms: u64) void {
    const held = if (self.project_launch) |*l| l else return;
    // The start it was for is over -- made, failed, or timed out.
    if (!self.chat.startAwaitingProject(held.group, now_ms)) {
        held.arena.deinit();
        self.project_launch = null;
        return;
    }
    const tie = self.chat.projectOf(held.group);
    if (tie != .bound) return;
    const pane = switch (poltergeistpkg.Projects.launchPlace(self.projects.find(tie.bound))) {
        .not_open => return,
        // Waiting would never change this: the next tick starts it in a
        // new tab of the project (task 1794).
        .no_seat => {
            if (!held.no_seat) {
                held.no_seat = true;
                self.controlRoomTouch();
            }
            return;
        },
        .pane => |pane| pane,
    };

    self.chat.startOpened(held.group, pane, now_ms + poltergeistpkg.PersonaStore.standing_wait_ms);
    self.startRoleIn(pane, poltergeistpkg.Chat.user_id, .{ .key = held.key, .cli = held.cli }, held.line, .agent) catch |err| {
        log.warn("control room: could not start the supervisor in its project's pane err={}", .{err});
        self.chat.failStart(held.group, .agent_never_connected);
    };
    held.arena.deinit();
    self.project_launch = null;
}

/// The host's statement of every project (`ControlAct`, `projects`).
fn controlActStateProjects(ctx: *anyopaque, statement: poltergeistpkg.Projects.Statement) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const list = statement.list;
    if (try self.projects.state(list, statement.unreadable)) {
        // Said when it changes, not at every statement (task 1807).
        if (statement.unreadable.len == 0) {
            log.info("projects: every project file reads again", .{});
        } else for (statement.unreadable) |f| {
            log.warn("projects: the project file {s} could not be read; a group whose project is not listed keeps it until it reads or is removed", .{f});
        }
    }
    self.noteTerminalProjects();

    // The panes a project's supervisor opened, said back after a restart
    // or a restore: the terminals are new and nothing in memory knows
    // them. Each is recorded as a worker of the terminal now in the
    // supervisor's pane (`statedWorker`), so the next worker joins their
    // stack and a free one is used again (task 1857).
    for (list) |p| {
        // The group's supervisor before the pane the file marks (task
        // 1875): the seat follows the supervisor only at the next save, and
        // until then the file's pane is the one taken over from -- whose
        // workers this would hand back to it.
        const steward = if (p.group) |g| self.projectStewardOf(g, p.name) else null;
        const boss = workersBoss(p.supervisor, steward) orelse continue;
        self.rehomeStatedWorkers(p.name, p.workers, boss);
    }
}

/// Whose the workers a project's file marks are (task 1875): the group's
/// supervisor when it has one minding it, the terminal in the pane the file
/// marks as the supervisor's when not.
fn workersBoss(seat: ?poltergeistpkg.Bus.Id, steward: ?poltergeistpkg.Bus.Id) ?poltergeistpkg.Bus.Id {
    return steward orelse seat;
}

/// The supervisor minding `group`, when `group`'s project is `project`.
fn projectStewardOf(self: *App, group: []const u8, project: []const u8) ?poltergeistpkg.Bus.Id {
    const tie = self.chat.projectOf(group);
    if (tie != .bound or !std.mem.eql(u8, tie.bound, project)) return null;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    return poltergeistpkg.ControlRoom.stewardOfGroup(arena.allocator(), &self.poltergeist, &self.chat, group);
}

/// The panes `project`'s file marks as its supervisor's (`workers`) are
/// `boss`'s workers (`statedWorker`, task 1857).
fn rehomeStatedWorkers(self: *App, project: []const u8, workers: []const poltergeistpkg.Bus.Id, boss: poltergeistpkg.Bus.Id) void {
    for (workers) |w| {
        switch (statedWorker(boss, w, self.poltergeist.workerOf(w), self.poltergeist.openedBy(w))) {
            .keep => {},
            .record => {
                self.markAgentOpened(w, boss);
                self.poltergeistRecordWorker(boss, w);
                log.info("projects: terminal {x} in a pane {s}'s supervisor opened is {x}'s worker again", .{ w, project, boss });
            },
            .rehome => |from| {
                if (self.poltergeist_workers.getPtr(from)) |l| {
                    if (std.mem.indexOfScalar(poltergeistpkg.Bus.Id, l.items, w)) |i| _ = l.orderedRemove(i);
                }
                self.markAgentOpened(w, boss);
                self.poltergeistRecordWorker(boss, w);
                log.info("projects: terminal {x} in a pane {s}'s supervisor opened was {x}'s worker; {x} is the supervisor now", .{ w, project, from, boss });
            },
        }
    }
}

/// `id` joined `group` and is its supervisor now: the workers its project's
/// file marks are its at once (task 1875), not at the next statement -- by
/// which time its first worker has been placed beside it, starting a
/// column of its own (Windows, 2026-10-20: `placed:split` in its own tab,
/// and the move logged in the same millisecond, after).
fn takeUpStatedWorkers(self: *App, group: []const u8, id: poltergeistpkg.Bus.Id) void {
    if (!self.poltergeist.isSupervisor(id)) return;
    const tie = self.chat.projectOf(group);
    if (tie != .bound) return;
    const p = self.projects.find(tie.bound) orelse return;
    const steward = self.projectStewardOf(group, p.name) orelse return;
    if (steward != id) return;
    self.rehomeStatedWorkers(p.name, p.workers, id);
}

test "1875: a project's workers are its group's supervisor's before the seat has followed it" {
    const testing = std.testing;
    // Taken over: the group's supervisor, not the pane the file still marks.
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, 0xb2), workersBoss(0xa1, 0xb2));
    // Nobody minding the group: the file's pane, as before (task 1857).
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, 0xa1), workersBoss(0xa1, null));
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, 0xb2), workersBoss(null, 0xb2));
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, null), workersBoss(null, null));
}

/// What a pane the project file marks as its supervisor's (`by_supervisor`)
/// makes of terminal `w`, with `boss` the terminal in the supervisor's pane
/// now (task 1857).
///
/// - Recorded when nothing in this run says who opened it: it came back
///   with the project.
/// - **Moved over** when it is recorded as another terminal's worker: it
///   was recorded under whoever was in the supervisor's pane when the
///   project was first stated, and the supervisor took up its post
///   somewhere else since -- in a new tab of the project (task 1794). It
///   used to be left there, so the new supervisor's next worker started a
///   stack of its own beside the old one (1:1:2).
/// - Left alone when an agent opened it in this run and not as a worker --
///   that terminal is that agent's -- and when it already is `boss`'s.
const StatedWorker = union(enum) {
    keep,
    record,
    rehome: poltergeistpkg.Bus.Id,
};

fn statedWorker(boss: poltergeistpkg.Bus.Id, w: poltergeistpkg.Bus.Id, worker_of: ?poltergeistpkg.Bus.Id, opened_by: ?poltergeistpkg.Bus.Id) StatedWorker {
    if (w == boss) return .keep;
    if (worker_of) |was| return if (was == boss) .keep else .{ .rehome = was };
    if (opened_by) |by| if (by != boss) return .keep;
    return .record;
}

test "1857: a pane the file marks as the supervisor's is the supervisor's now, wherever it was recorded" {
    const testing = std.testing;
    // Came back with the project: nothing known.
    try testing.expectEqual(StatedWorker.record, statedWorker(0xa1, 0xb1, null, null));
    // Already the supervisor's.
    try testing.expectEqual(StatedWorker.keep, statedWorker(0xa1, 0xb1, 0xa1, 0xa1));
    // Recorded under the pane's terminal before the supervisor took up its
    // post in a new tab: moved over.
    const moved = statedWorker(0xa2, 0xb1, 0xa1, 0xa1);
    try testing.expectEqual(StatedWorker{ .rehome = 0xa1 }, moved);
    // Opened this run by another agent, not as a worker: left alone.
    try testing.expectEqual(StatedWorker.keep, statedWorker(0xa1, 0xb1, null, 0xc3));
    // Opened by the supervisor, not yet recorded: recorded.
    try testing.expectEqual(StatedWorker.record, statedWorker(0xa1, 0xb1, null, 0xa1));
    // The supervisor's own pane is never its worker.
    try testing.expectEqual(StatedWorker.keep, statedWorker(0xa1, 0xa1, null, null));
}

/// The host could not open a project it was ordered to. The start that
/// was waiting fails now; a file that is gone also unties its group, at
/// once rather than at the host's next statement.
fn controlActProjectFailed(ctx: *anyopaque, name: []const u8, why: poltergeistpkg.ControlAct.ProjectFailure) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const now_ms = self.poltergeistElapsedMs();
    const views = try self.projectViews(arena.allocator(), now_ms);
    const found = poltergeistpkg.Projects.groupOf(views, name) orelse return error.NoSuchProject;
    // Copied: untying frees the name it is found by, and the group's is
    // the chat's own.
    const group = try arena.allocator().dupe(u8, found);

    if (self.chat.startAwaitingProject(group, now_ms)) {
        // The project did not come (task 1794 gave both hosts the word).
        self.chat.failStart(group, .project_never_opened);
    }
    // Not found while some project file does not read is not known to be
    // gone: a host finds a project by reading its file (task 1807).
    if (why == .not_found and self.projects.unreadable.len > 0) {
        log.warn("control room: a group's project was not found, and a project file could not be read; the group keeps it", .{});
    } else if (why == .not_found) {
        if (self.chat.setProject(group, .undecided) catch false) {
            self.chat.setProjectClaim(group, null);
            if (self.group_log) |*l| l.project(group, .undecided);
            self.noteGroupProject(group);
        }
    }
    log.info("control room: a group's project did not open ({t})", .{why});
}

fn controlActProjectRemove(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const views = try self.projectViews(arena.allocator(), self.poltergeistElapsedMs());
    try self.projects.mayRemove(views, id);
}

/// A project is about to be renamed. One that is a group's is renamed by
/// renaming the group -- the person's doing, like any rename from the
/// interface -- and the host is then ordered to rename the file.
/// The person said OK to the first sweep of old records: written down,
/// and the sweep run now.
fn controlActRetentionAgree(ctx: *anyopaque) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.agreeToRetention("acknowledged");
}

/// Write the person's agreement to sweeping and sweep now. Also what a
/// change to the limits means while the first sweep is waiting: they have
/// seen the notice and said what they want kept instead.
pub fn agreeToRetention(self: *App, how: []const u8) void {
    const dir = self.sweep_state_dir orelse return;
    poltergeistpkg.Sweeper.writeConsent(global.io(), dir, self.poltergeistWallMs(), how);
    if (self.sweeper) |*w| w.sweepNow();
}

fn controlActProjectRename(ctx: *anyopaque, from: []const u8, to: []const u8) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const views = try self.projectViews(arena.allocator(), self.poltergeistElapsedMs());
    const found = poltergeistpkg.Projects.groupOf(views, from) orelse return;
    const group = try arena.allocator().dupe(u8, found);
    try chatRename(ctx, group, to, poltergeistpkg.Chat.user_id);
}

/// The person's word on a group's project (task 1713,
/// `project-link-interface.md` §1): what `group_project use / drop` lets a
/// supervisor say, said by the person -- so no standing is asked. The group
/// is known to be there (`ControlAct` asked).
fn controlActProjectSay(ctx: *anyopaque, group: []const u8, say: poltergeistpkg.ControlAct.ProjectSay) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    defer self.controlRoomTouch();
    switch (say) {
        .decline => {
            if (try self.chat.setProject(group, .declined)) {
                if (self.group_log) |*l| l.project(group, .declined);
                self.noteGroupProject(group);
            }
            self.chat.setProjectClaim(group, null);
        },
        .undecline => {
            if (self.chat.projectOf(group) != .declined) return;
            _ = try self.chat.setProject(group, .undecided);
            if (self.group_log) |*l| l.project(group, .undecided);
            self.noteGroupProject(group);
            // The group's supervisor, when it has one, is taken as having
            // said yes: `offer` works the project out again now, rather
            // than at the next take-up.
            var arena: std.heap.ArenaAllocator = .init(self.alloc);
            defer arena.deinit();
            if (poltergeistpkg.ControlRoom.stewardOfGroup(arena.allocator(), &self.poltergeist, &self.chat, group)) |id| {
                self.chat.setProjectClaim(group, null);
                self.chat.setProjectClaim(group, .{ .terminal = id, .said = true });
            }
        },
        .link => |name| {
            var arena: std.heap.ArenaAllocator = .init(self.alloc);
            defer arena.deinit();
            const views = try self.projectViews(arena.allocator(), self.poltergeistElapsedMs());
            try self.projects.mayLink(views, group, name);
            if (try self.chat.setProject(group, .{ .bound = name })) {
                if (self.group_log) |*l| l.project(group, .{ .bound = name });
                self.noteGroupProject(group);
            }
            // Bound: `reconcile` writes the group into the file and renames
            // the project to the group's name, by orders, as for any group.
            self.chat.setProjectClaim(group, null);
        },
        .not_now => {
            const times = try self.chat.sayProjectNotNow(group);
            if (self.group_log) |*l| l.projectNotNow(group, times);
        },
    }
}

/// A supervisor has taken groups up: made one, joined one, been started
/// for one. Every group it is now the supervisor of and that nobody has
/// said anything about a project for is marked as taken up by it, which
/// is what `Projects` goes by to offer an old group a project.
fn takeUpGroups(self: *App, id: poltergeistpkg.Bus.Id) void {
    const Chat = poltergeistpkg.Chat;
    if (id == Chat.user_id or !self.poltergeist.isSupervisor(id)) return;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const live = self.liveTerminals(alloc) catch return;
    const names = self.chat.groupsFor(alloc, id, live) catch return;
    for (names) |name| {
        if (self.chat.projectOf(name) != .undecided) continue;
        const steward = poltergeistpkg.ControlRoom.stewardOfGroup(alloc, &self.poltergeist, &self.chat, name);
        if (steward == null or steward.? != id) continue;
        self.chat.setProjectClaim(name, .{ .terminal = id, .said = false });
    }
    self.controlRoomTouch();
}

/// `group_project`: a supervisor says a group uses the project its tab is
/// in, or has none.
fn poltergeistGroupProject(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
    group: []const u8,
    use: bool,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const Projects = poltergeistpkg.Projects;
    if (!self.chat.exists(group)) return error.NoSuchGroup;
    defer self.controlRoomTouch();

    const views = try self.projectViews(alloc, self.poltergeistElapsedMs());
    var why: Projects.Why = undefined;
    if (use) {
        why = try self.projects.judge(alloc, views, group, id);
        if (Projects.refusalOf(why)) |refusal| return refusal;
        if (why == .pending) {
            // Having said no before is unsaid by saying yes.
            if (self.chat.projectOf(group) == .declined) {
                _ = try self.chat.setProject(group, .undecided);
                if (self.group_log) |*l| l.project(group, .undecided);
                self.noteGroupProject(group);
            }
            self.chat.setProjectClaim(group, null);
            self.chat.setProjectClaim(group, .{ .terminal = id, .said = true });
        }
    } else {
        const steward = poltergeistpkg.ControlRoom.stewardOfGroup(alloc, &self.poltergeist, &self.chat, group);
        if (steward == null or steward.? != id) return error.NotItsSupervisor;
        if (try self.chat.setProject(group, .declined)) {
            if (self.group_log) |*l| l.project(group, .declined);
            self.noteGroupProject(group);
        }
        self.chat.setProjectClaim(group, null);
        why = .declined;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    const tie = self.chat.projectOf(group);
    try out.writer.print("{{\"group\":{f},\"tie\":\"{s}\",\"project\":", .{ std.json.fmt(group, .{}), @tagName(tie) });
    switch (tie) {
        .bound => |name| try out.writer.print("{f}", .{std.json.fmt(name, .{})}),
        .undecided, .declined => try out.writer.writeAll("null"),
    }
    try out.writer.print(",\"why\":\"{s}\"}}", .{@tagName(why)});
    return out.written();
}

/// The roles a supervisor can be started in: the ones that make a terminal
/// a supervisor and have a CLI to start, each with the CLIs it is set up
/// for. In the set's order, which puts the one Polter ships first. The
/// snapshot and the start both read this, so they name the same default.
fn controlStartRoles(self: *App, alloc: Allocator, own: []const poltergeistpkg.ControlRoom.OwnCli) Allocator.Error![]const poltergeistpkg.ControlRoom.StartRole {
    self.ensurePersonas();
    var roles: std.ArrayListUnmanaged(poltergeistpkg.ControlRoom.StartRole) = .empty;
    for (self.personas.set.personas) |p| {
        if (!p.polter.supervisor) continue;
        const role = try self.startRoleOf(alloc, p, own);
        if (role.clis.len == 0) continue;
        try roles.append(alloc, role);
    }
    return roles.items;
}

/// The Agent CLIs `p` can be started in, as one list (task 2156 v3): the
/// CLIs it is set up for, then each of the person's own ticked for it.
/// **Every place a CLI is picked for a role reads this**, so a preset and
/// one of the person's own are offered, defaulted and refused alike.
fn startRoleOf(self: *App, alloc: Allocator, p: poltergeistpkg.persona.Persona, own: []const poltergeistpkg.ControlRoom.OwnCli) Allocator.Error!poltergeistpkg.ControlRoom.StartRole {
    _ = self;
    const clis = try alloc.alloc([]const u8, p.clis.len);
    for (p.clis, clis) |c, *k| k.* = c.cli;
    return poltergeistpkg.ControlRoom.withOwn(alloc, .{ .key = p.key, .name = p.name, .clis = clis }, own);
}

/// Which agent CLIs can go on with a session, as far as their adapters
/// have been asked (`agent_cli.Cache`).
///
/// **Asking is started here, and only when it would matter**: an adapter is
/// a process, and a machine none of whose groups has a session written
/// down has no use for the answer. Until it comes this is `unread`, which
/// the snapshot says as its own reason and asks to be drawn again for.
/// What each agent CLI is called to a person, for the snapshot: its
/// adapter's own label, as last read. Empty until a read has finished
/// (`controlCliResume` starts one); the snapshot then says a CLI has no
/// name, and a host writes its key.
fn controlCliNames(self: *App, alloc: Allocator, own: []const poltergeistpkg.ControlRoom.OwnCli) Allocator.Error![]const poltergeistpkg.ControlRoom.CliName {
    const read = try self.poltergeist_agent_clis.names(global.io(), alloc);
    const out = try alloc.alloc(poltergeistpkg.ControlRoom.CliName, read.len);
    for (read, out) |n, *o| o.* = .{ .key = n.key, .label = n.label };
    return poltergeistpkg.ControlRoom.namesWithOwn(alloc, out, own);
}

/// The Agent CLIs of the person's own, as the control room offers them
/// (task 2156 v3). **Read at most once per round** (see `ownClisNeedsRead`):
/// what comes back are slices into `poltergeist_own_arena`, and a second
/// read in the same round would have to free the arena the first one's
/// answer is in -- a `use-after-free` for everything already holding it.
/// `startRoleOf`, `controlCliNames`, `controlCliStandings`, `resolveLaunch`
/// and the snapshot all ask inside one round.
///
/// A round is ended by `ownClisRound`, which the app loop calls once per
/// turn: the next round re-stats launchers.json, and reads it again only
/// when its size or time has moved since.
fn ownClis(self: *App) []const poltergeistpkg.ControlRoom.OwnCli {
    if (!ownClisNeedsRead(self.own_round, self.poltergeist_own_round)) return self.poltergeist_own_clis;
    // From here on this round's answer is this call's: no later read in
    // this round will replace it, so nothing anybody takes now goes stale.
    self.poltergeist_own_round = self.own_round;

    var tmp: std.heap.ArenaAllocator = .init(self.alloc);
    defer tmp.deinit();
    const path = launchersPath(tmp.allocator()) catch return self.poltergeist_own_clis;
    const st = std.Io.Dir.cwd().statFile(global.io(), path, .{}) catch {
        self.setOwnClis(null, null);
        return &.{};
    };
    if (self.poltergeist_own_seen) |seen| {
        if (seen.size == st.size and seen.mtime == st.mtime.nanoseconds) return self.poltergeist_own_clis;
    }
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    const own = ownClisOf(arena.allocator(), self.launcherSet(tmp.allocator())) catch {
        arena.deinit();
        return self.poltergeist_own_clis;
    };
    self.setOwnClis(arena, own);
    self.poltergeist_own_seen = .{ .size = st.size, .mtime = st.mtime.nanoseconds };
    return own;
}

/// Whether this round still has to read launchers.json (task 2156 v3's
/// must-fix): **not when it already did**, whatever the file has done since.
///
/// **Reading again is what frees the answer somebody is holding**, so the
/// question is not "has the file moved" but "does this round already have an
/// answer". A round is one turn of the app loop (`ownClisRound`); inside it
/// the person's own Agent CLIs are one fact, and a file written by another
/// process halfway through it is seen at the next turn.
fn ownClisNeedsRead(round: u64, kept_round: u64) bool {
    return round != kept_round;
}

/// Move to the next round: the next `ownClis` looks at launchers.json
/// again. Called once at the top of each turn of the app loop, so that
/// everything one turn asks gets one answer, and nothing is freed under
/// anybody within it.
fn ownClisRound(self: *App) void {
    self.own_round +%= 1;
}

fn setOwnClis(self: *App, arena: ?std.heap.ArenaAllocator, own: ?[]const poltergeistpkg.ControlRoom.OwnCli) void {
    if (self.poltergeist_own_arena) |*a| a.deinit();
    self.poltergeist_own_arena = arena;
    self.poltergeist_own_clis = own orelse &.{};
    self.poltergeist_own_seen = null;
}

fn ownClisOf(aa: Allocator, set: poltergeistpkg.Launchers.Set) Allocator.Error![]const poltergeistpkg.ControlRoom.OwnCli {
    const out = try aa.alloc(poltergeistpkg.ControlRoom.OwnCli, set.launchers.len);
    for (set.launchers, out) |l, *o| {
        const roles = try aa.alloc([]const u8, l.roles.len);
        for (l.roles, roles) |r, *d| d.* = try aa.dupe(u8, r);
        o.* = .{ .key = try aa.dupe(u8, l.key), .name = try aa.dupe(u8, l.name), .base = try aa.dupe(u8, l.base), .roles = roles };
    }
    return out;
}

/// Every agent CLI a plugin here manages, and whether it can be started
/// (`agent_cli.survey`): plugin on and adapter runnable, plugin off, or on
/// with an adapter nothing here can run (task 1677). Read when the plugins
/// are (`ensurePlugins`, again by `reloadPlugins` when one is switched on
/// or off), so that drawing the snapshot walks no directory and starts
/// nothing. Null when the plugins could not be read.
///
/// **And whether it can be started at all** (tasks 1744, 2237): one an
/// adapter's last inventory said is not on the login shell's PATH stands
/// `not_installed`, and one whose adapter said the program here is not a
/// version it serves stands `wrong_version` (`ControlRoom.installedHere`).
/// Before a read nobody knows, and it is offered as before. The same answer
/// for the snapshot, the control room's start and `resolveLaunch`.
fn controlCliStandings(self: *App, alloc: Allocator, own: []const poltergeistpkg.ControlRoom.OwnCli) Allocator.Error!?[]const poltergeistpkg.ControlRoom.CliStanding {
    self.ensurePlugins();
    if (self.poltergeist_plugin_arena == null) return null;
    const cannot = try self.cannotStart(alloc);
    const here = try poltergeistpkg.ControlRoom.installedHere(alloc, self.poltergeist_cli_standings, cannot);
    // The person's own stand as their bases do (task 2156 v3).
    return try poltergeistpkg.ControlRoom.standingsWithOwn(alloc, here, own);
}

/// What the last inventory read said about the CLIs whose programs are here
/// but cannot be started, or null when nothing has been read (tasks 1744,
/// 2237). Copied into `alloc`; the empty lists are free.
fn cannotStart(self: *App, alloc: Allocator) Allocator.Error!?poltergeistpkg.ControlRoom.NotStartable {
    const serves = (try self.poltergeist_agent_clis.cannotStart(global.io(), alloc)) orelse return null;
    return .{ .missing = serves.missing, .wrong_version = serves.wrong_version };
}

fn controlCliResume(self: *App, alloc: Allocator) Allocator.Error!poltergeistpkg.ControlRoom.CliResume {
    const io = global.io();
    if (try self.poltergeist_agent_clis.resumable(io, alloc)) |keys| return .{ .read = keys };
    // Started whether or not a session was kept: the same read says which
    // CLIs' programs are here at all (task 1744).
    if (!self.poltergeist_agent_clis.askedFor(io)) self.poltergeist_agent_clis.refresh(io);
    return .unread;
}

/// Write down, for every group terminal `id` is the supervisor of, what
/// that supervisor is now: where it works, the role it wears, its CLI, the
/// session its CLI says it is in, and that it was heard from this moment.
///
/// **A terminal that is the supervisor of several groups is written down
/// in each of them**, the same record. They are one agent in one session,
/// and whichever group it is next started from is the one that goes on
/// with it; the others then find an open terminal in that session and say
/// `session_in_use` rather than start a second agent in it.
///
/// "The supervisor of" is the control room's rule, one to a group
/// (`ControlRoom.stewardOfGroup`): a second supervisor that joins a group
/// somebody else minds does not become where that group's is started.
///
/// What is not known *now* is written as not known, with one exception:
/// a directory. A terminal that cannot say where it is (its shell gave no
/// `pwd`) leaves the directory the group already had, because where to
/// start the next one is worth more stale than empty.
///
/// `keep` says whether a change of nothing but "heard at" is worth a write
/// to disk. It is for the events that are rare and mark something -- a
/// session beginning, a turn ending -- and not for every hook.
fn noteSupervisor(self: *App, id: poltergeistpkg.Bus.Id, keep: enum { write, only_a_change }) void {
    const Chat = poltergeistpkg.Chat;
    if (id == Chat.user_id or !self.poltergeist.isSupervisor(id)) return;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const live = self.liveTerminals(alloc) catch return;
    const names = self.chat.groupsFor(alloc, id, live) catch return;
    if (names.len == 0) return;

    const footing = self.footingOf(alloc, id);
    const agent = self.poltergeist.agentOf(id);
    const launch = self.personas.launchOf(id);
    const role: []const u8 = if (launch) |l| l.role else self.personas.stateOf(id).key orelse "";
    const cli: []const u8 = agent.cli.get() orelse if (launch) |l| l.choice.cli else "";
    const wall_ms: u64 = @intCast(@max(0, self.poltergeistWallMs()));

    var touched = false;
    for (names) |name| {
        const steward = poltergeistpkg.ControlRoom.stewardOfGroup(alloc, &self.poltergeist, &self.chat, name);
        if (steward == null or steward.? != id) continue;

        const was = self.chat.lastSupervisorOf(name);
        const now: Chat.LastSupervisor = .{
            .dir = if (footing.cwd.len > 0) footing.cwd else was.dir,
            .dir_from = if (footing.cwd.len > 0) .supervisor else was.dir_from,
            .role = role,
            .cli = cli,
            // The Agent CLI of the person's own it went through, so that
            // going on with its session goes through it again (task 2156 v3).
            .launcher = agent.launcher.get() orelse "",
            .session = Chat.sessionToWrite(agent.session_id.get(), was, self.chat.resumingIn(name, id)),
            .heard_ms = wall_ms,
        };
        const change = self.chat.setLastSupervisor(name, now) catch continue;
        const write = switch (change) {
            .same => false,
            .heard => keep == .write,
            .who => true,
        };
        if (change == .who) touched = true;
        // Read back rather than `now`: what the chat holds is what was
        // decided, and it owns its strings.
        if (write) if (self.group_log) |*l| l.supervisor(name, self.chat.lastSupervisorOf(name));
    }
    if (touched) self.controlRoomTouch();
}

/// The agent CLI in `id` said something through its hooks (`rpc`,
/// `agentHeard`). If that terminal is a group's supervisor, what is
/// written down of it follows: this is the only place a session that
/// changed under a running agent -- `/clear` gives Claude Code a new one,
/// measured on 2.1.296 -- reaches the group's record.
fn poltergeistAgentHeard(
    ctx: *anyopaque,
    _: *poltergeistpkg.Bus,
    id: poltergeistpkg.Bus.Id,
    kind: poltergeistpkg.agent_event.Kind,
) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.noteSupervisor(id, switch (kind) {
        .session_started, .turn_ended => .write,
        .turn_started,
        .turn_failed,
        .turn_retrying,
        .awaiting_approval,
        .awaiting_input,
        => .only_a_change,
        // Not an agent speaking: the launcher's own two, and a file.
        .hooks_expected, .launch_failed, .launched_for_group, .launched_with, .allowance_written, .context_reported => return,
        // Said after every tool call, and about the turn rather than the
        // session: what this keeps (who, which session) the events above
        // have already said, and walking the groups on each tool call
        // would be the cost without the news.
        .turn_resumed => return,
        // The other end of the same tool call (task 1625), for the same
        // reason.
        .tool_started => return,
    });
}

/// Where terminal `id` stands with the groups, for its own `me`.
fn poltergeistMembership(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
) anyerror!poltergeistpkg.wire.Membership {
    const self: *App = @ptrCast(@alignCast(ctx));
    const groups = try chatGroups(ctx, alloc, id);
    var mine: std.ArrayListUnmanaged([]const u8) = .empty;
    for (groups) |name| {
        const steward = poltergeistpkg.ControlRoom.stewardOfGroup(alloc, &self.poltergeist, &self.chat, name);
        if (steward != null and steward.? == id) try mine.append(alloc, name);
    }
    return .{
        .groups = groups,
        .supervisor_of = mine.items,
        .started_for = if (self.chat.startedFor(id)) |name| try alloc.dupe(u8, name) else null,
        .projects = projects: {
            // Asked the way the snapshot asks, and nothing is carried out:
            // this only says where each of its groups stands.
            const views = try self.projectViews(alloc, self.poltergeistElapsedMs());
            const stand = try self.projects.reconcile(alloc, views, &.{});
            const out = try alloc.alloc(poltergeistpkg.wire.Membership.GroupProject, mine.items.len);
            for (mine.items, out) |name, *o| {
                const tie = self.chat.projectOf(name);
                o.* = .{
                    .group = name,
                    .tie = tie,
                    .project = switch (tie) {
                        .bound => |project| try alloc.dupe(u8, project),
                        .undecided, .declined => null,
                    },
                    .why = for (stand.standings) |s| {
                        if (std.mem.eql(u8, s.group, name)) break s.why;
                    } else .projects_unknown,
                };
            }
            break :projects out;
        },
    };
}

/// The control room's snapshot as JSON; `ControlRoom.zig` has the shape.
/// Borrowed until the next `tick`. Empty before the first one.
/// One page of the control room's right side (task 2015,
/// `ghostty_app_control_page`): the answer to `req`, as JSON; empty for "no
/// answer yet". Borrowed until the next call.
///
/// An answer that did not fit the host's buffer (`cap`) is held, and the
/// same request asked again gets those bytes and not a new reading -- so a
/// host may ask for the length first and then for the page.
pub fn controlPage(self: *App, req: []const u8, cap: usize) []const u8 {
    if (self.page_held and std.mem.eql(u8, self.page_req.items, req)) {
        self.page_held = false;
        return self.page_out.items;
    }
    self.page_held = false;
    self.page_req.clearRetainingCapacity();
    self.page_out.clearRetainingCapacity();
    self.page_req.appendSlice(self.alloc, req) catch return "";
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const out = self.renderPage(arena.allocator(), req) catch |err| out: {
        log.warn("control room: could not work out a page err={}", .{err});
        break :out "";
    };
    self.page_out.appendSlice(self.alloc, out) catch return "";
    self.page_held = out.len > 0 and out.len + 1 > cap;
    return self.page_out.items;
}

const PageRequest = struct {
    page: []const u8 = "",
    group: []const u8 = "",
    span: []const u8 = "day",
    since: u64 = 0,
    open_task: ?u64 = null,
    /// The task page's selected one (task 2083): what Enter's hint speaks of.
    selected: ?u64 = null,
    closed: bool = false,
    /// The task page's filter box (task 2083): absent with none.
    filter: ?[]const u8 = null,
};

fn renderPage(self: *App, arena: Allocator, req: []const u8) Allocator.Error![]const u8 {
    const r = std.json.parseFromSliceLeaky(PageRequest, arena, req, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return "{\"error\":\"BadRequest\"}",
    };
    if (std.mem.eql(u8, r.page, "resources")) return self.renderResources(arena, r);
    if (std.mem.eql(u8, r.page, "tasks")) return self.renderTasks(arena, r);
    if (std.mem.eql(u8, r.page, "workdirs")) return self.renderWorkdirs(arena, r);
    if (std.mem.eql(u8, r.page, "overall")) return self.renderOverall(arena, r);
    return "{\"error\":\"BadRequest\"}";
}

/// The overall view's page (task 2149 §6, the third block of slice 2): the
/// same answer `resource_overview` hands a supervisor, over the door the
/// hosts already read their pages through (`ghostty_app_control_page`).
///
/// **`overallAnswer` is the one reading**, so what the page draws and what
/// the tool says cannot drift apart -- a second path here would be a second
/// answer, and the page's is the one somebody is looking at.
///
/// **Empty before the first reading is taken.** Zero bytes is this door's
/// "no answer yet" and a host draws nothing then (`ControlRoomPageSource`):
/// there is no page yet, and an empty one would be drawn as a machine that
/// costs nothing.
fn renderOverall(self: *App, arena: Allocator, r: PageRequest) Allocator.Error![]const u8 {
    return self.overallAnswer(arena, r.group, 0) catch |err| switch (err) {
        error.NoReading => "",
        // As the performance page refuses one: a name nobody has is said,
        // not answered with an empty list.
        error.NoSuchGroup => "{\"error\":\"NoSuchGroup\"}",
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// The terminals of the group a page is about, in the order to draw them:
/// its supervisor, the others as the group lists them, the person's own
/// last.
const PagePane = struct { id: poltergeistpkg.Bus.Id, name: []const u8, role: poltergeistpkg.ResourcePage.Role };

fn pagePanes(self: *App, arena: Allocator, group: []const u8) Allocator.Error!?[]const PagePane {
    const row = for (self.control_room.route_rows) |r| {
        if (std.mem.eql(u8, r.group, group)) break r;
    } else return null;
    var out: std.ArrayListUnmanaged(PagePane) = .empty;
    for (row.members, row.titles) |id, title| {
        const steward = if (row.steward) |s| s == id else false;
        if (steward) try out.insert(arena, 0, .{ .id = id, .name = title, .role = .supervisor });
    }
    for (row.members, row.titles, row.own) |id, title, own| {
        const steward = if (row.steward) |s| s == id else false;
        if (!steward and !own) try out.append(arena, .{ .id = id, .name = title, .role = .worker });
    }
    for (row.members, row.titles, row.own) |id, title, own| {
        const steward = if (row.steward) |s| s == id else false;
        if (!steward and own) try out.append(arena, .{ .id = id, .name = title, .role = .own });
    }
    return out.items;
}

/// The working directories of a group (task 2145 C1,
/// `poltergeist.files.Workdirs`): worked out from the terminals now in the
/// control room's groups and the worktrees the ledger remembers; nothing is
/// kept between two asks.
fn renderWorkdirs(self: *App, arena: Allocator, r: PageRequest) Allocator.Error![]const u8 {
    const Workdirs = poltergeistpkg.files.Workdirs;
    if (!self.chat.exists(r.group)) return "{\"error\":\"NoSuchGroup\"}";
    var terms: std.ArrayListUnmanaged(Workdirs.Term) = .empty;
    for (self.control_room.route_rows) |row| {
        for (row.members, row.titles, row.own) |id, title, own| {
            const steward = if (row.steward) |s| s == id else false;
            try terms.append(arena, .{
                .id = id,
                .title = title,
                .role = if (steward) .supervisor else if (own) .own else .worker,
                .group = row.group,
                .cwd = self.terminalCwd(arena, id),
            });
        }
    }
    var trees: std.ArrayListUnmanaged(Workdirs.Tree) = .empty;
    if (self.poltergeist_worktrees) |*ledger| for (ledger.entries.items) |e| {
        const ids = try arena.alloc(u64, if (e.terminal != null) 2 else 1);
        ids[0] = e.by;
        if (e.terminal) |t| ids[1] = t;
        try trees.append(arena, .{ .name = e.name, .path = e.path, .terminals = ids });
    };
    const dirs = try Workdirs.compute(arena, global.io(), r.group, terms.items, trees.items, self.controlHome());
    var out: std.Io.Writer.Allocating = .init(arena);
    Workdirs.writeJson(&out.writer, r.group, dirs) catch return error.OutOfMemory;
    return out.written();
}

fn renderTasks(self: *App, arena: Allocator, r: PageRequest) Allocator.Error![]const u8 {
    const Page = poltergeistpkg.TaskPage;
    if (!self.chat.exists(r.group)) return "{\"error\":\"NoSuchGroup\"}";
    const wall = self.poltergeistWallMs();

    // The panel, whole: the same page `task_list` reads for the supervisor.
    const win = try self.tasks.page(arena, r.group, .{});
    const tasks = try arena.alloc(Page.Task, win.tasks.len);
    for (win.tasks, tasks) |t, *out| out.* = .{
        .id = t.id,
        .title = t.title,
        .state = t.state,
        .progress = t.progress,
        .owner = try self.memberName(arena, r.group, t.owner),
    };

    // The record, newest pages back to its start or to what one page holds
    // -- the same record `task_history` reads.
    var events: std.ArrayListUnmanaged(Page.Event) = .empty;
    if (self.task_log) |*l| {
        const page = try l.history(arena, r.group, 0, poltergeistpkg.TaskLog.max_history_limit);
        for (page.events) |e| {
            const op = std.meta.stringToEnum(poltergeistpkg.TaskLog.Op, e.op) orelse continue;
            try events.append(arena, .{
                .at_ms = e.at_ms,
                .op = op,
                .task = e.task,
                .progress = std.meta.stringToEnum(poltergeistpkg.Tasks.Progress, e.progress) orelse .queued,
                .owner = try self.memberName(arena, r.group, e.owner),
                .via = e.via,
            });
        }
    }

    // What the group said of the open one, the last week of it.
    var said: std.ArrayListUnmanaged(Page.Said) = .empty;
    if (r.open_task) |id| if (self.chat_log) |*l| {
        var tag: [24]u8 = undefined;
        const match = std.fmt.bufPrint(&tag, "#{d}", .{id}) catch "";
        // `.everything`: this is the task page in the control room, which
        // is the person's view of their own groups.
        const page = try l.history(arena, r.group, 0, 200, .{ .since_ms = wall - Page.said_ms, .match = match }, .everything);
        // Newest first from the record; the page reads oldest first.
        var i = page.entries.len;
        while (i > 0) : (i -= 1) {
            const e = page.entries[i - 1];
            if (!Page.mentions(e.text, id)) continue;
            try said.append(arena, .{ .at_ms = e.at_ms, .who = e.author, .text = e.text });
        }
    };

    return Page.render(arena, .{
        .group = r.group,
        .goal = self.chat.briefOf(r.group) catch "",
        .tasks = tasks,
        .events = events.items,
        .open_task = r.open_task,
        .selected = r.selected,
        .said = said.items,
        .closed = r.closed,
        .filter = r.filter,
        .now_ms = wall,
        .offset_ms = poltergeistpkg.daylog.localOffsetMs(wall),
        .tr = resourceTr,
    });
}

/// What a terminal is called on the task page: its title in the group, in
/// another group, or as the history last knew it; empty for nobody.
fn memberName(self: *App, arena: Allocator, group: []const u8, id: poltergeistpkg.Bus.Id) Allocator.Error![]const u8 {
    if (id == poltergeistpkg.Tasks.nobody) return "";
    for ([_]bool{ true, false }) |same_group| {
        for (self.control_room.route_rows) |row| {
            if (same_group != std.mem.eql(u8, row.group, group)) continue;
            for (row.members, row.titles) |m, t| if (m == id) return t;
        }
    }
    if (self.resource_names.get(id)) |e| return e.name;
    return std.fmt.allocPrint(arena, "0x{x}", .{id});
}

const GoneNames = struct {
    names: *const poltergeistpkg.ResourceNames,
    group: []const u8,

    fn of(ctx: *const anyopaque, id: u64) ?[]const u8 {
        const self: *const GoneNames = @ptrCast(@alignCast(ctx));
        const e = self.names.get(id) orelse return null;
        if (!std.mem.eql(u8, e.group, self.group)) return null;
        return e.name;
    }
};

/// Which terminal ran which agent session, and when each row's name was
/// last true: the two hooks `ResourcePage` folds rows by (task 2234).
///
/// **Two things the app already keeps, read rather than copied.** The
/// session table says which ids are one terminal (`resource_sessions`,
/// 2234); the name's age is `ResourceNames`' own `seen_ms`, written every
/// reading already, so a merged row can be named after the run that read
/// it latest without a second copy of anything.
const AppSessions = struct {
    table: *const poltergeistpkg.ResourcePage.SessionTable,
    names: *const poltergeistpkg.ResourceNames,

    fn of(ctx: ?*anyopaque, id: u64) u64 {
        const self: *const AppSessions = @ptrCast(@alignCast(ctx.?));
        return self.table.keyOf(id);
    }

    /// Null when this terminal was never named: the row that came first
    /// keeps its name then, which is the card's own reading of it.
    fn seen(ctx: ?*anyopaque, id: u64) ?i64 {
        const self: *const AppSessions = @ptrCast(@alignCast(ctx.?));
        const e = self.names.get(id) orelse return null;
        return e.seen_ms;
    }
};

fn renderResources(self: *App, arena: Allocator, r: PageRequest) Allocator.Error![]const u8 {
    const Page = poltergeistpkg.ResourcePage;
    const Grid = poltergeistpkg.ResourceGrid;
    const procscan = poltergeistpkg.procscan;
    const panes_in = try self.pagePanes(arena, r.group) orelse return "{\"error\":\"NoSuchGroup\"}";
    const span = std.meta.stringToEnum(Grid.Span, r.span) orelse return "{\"error\":\"BadRequest\"}";
    const wall = self.poltergeistWallMs();
    const offset = poltergeistpkg.daylog.localOffsetMs(wall);

    const panes = try arena.alloc(Page.Pane, panes_in.len);
    for (panes_in, panes) |p, *out| {
        const level: poltergeistpkg.ResourceHistory.Level = if (self.resource_judges.getPtr(p.id)) |j| poltergeistpkg.ResourceHistory.levelOf(&j.state) else .ok;
        out.* = .{
            .id = p.id,
            .name = p.name,
            .role = p.role,
            .usage = self.resource_usage.get(p.id),
            .lim = self.poltergeist.limitsOf(p.id),
            .level = level,
            .recent = self.resource_recent.getPtr(p.id),
            .killed = self.resource_killed.get(p.id),
        };
    }

    // The history: every day file, and the half hours still open.
    const days: []const u8 = if (self.resource_history_file) |f|
        (if (std.fs.path.dirname(f.dir)) |state| try Grid.readDays(arena, f.io, state) else "")
    else
        "";
    var open: std.ArrayListUnmanaged(poltergeistpkg.ResourceHistory.Closed) = .empty;
    var it = self.resource_history.slots.iterator();
    while (it.next()) |kv| try open.append(arena, .{ .pane = kv.key_ptr.*, .slot = kv.value_ptr.* });
    const grid = try Grid.build(arena, span, wall, offset, days, open.items);
    const day_grid = if (span == .day) grid else try Grid.build(arena, .day, wall, offset, days, open.items);
    const gone: GoneNames = .{ .names = &self.resource_names, .group = r.group };
    // `var` so that `&app_sessions` is a `*AppSessions` the page's `?*anyopaque`
    // takes; a `const` makes it `*const` and `@ptrCast` refuses to drop that.
    var app_sessions: AppSessions = .{ .table = &self.resource_sessions, .names = &self.resource_names };

    // The day's stops and warnings among this group's terminals, living
    // and gone: cells with one in them.
    var kills: usize = 0;
    var warns: usize = 0;
    for (day_grid.rows) |row| {
        const mine = for (panes_in) |p| {
            if (p.id == row.pane) break true;
        } else GoneNames.of(&gone, row.pane) != null;
        if (!mine) continue;
        for (row.cells) |cell| if (cell.mark) |m| switch (m.what) {
            .kill => kills += 1,
            .warn, .withheld => warns += 1,
        };
    }

    return Page.render(arena, .{
        .group = r.group,
        .seq = self.resource_seq,
        .since = r.since,
        .now_ms = wall,
        .offset_ms = offset,
        .period_ms = @intCast(poltergeistpkg.ResourceSampler.period_ms),
        .machine = .{
            .used = procscan.machineUsed(),
            .phys = procscan.physicalMemory(),
            .swap = procscan.swapUsed(),
            .pressure = procscan.pressureLevel(),
        },
        .panes = panes,
        .grid = &grid,
        .kills_24h = kills,
        .warns_24h = warns,
        .gone_name = GoneNames.of,
        .gone_ctx = &gone,
        .sessions = .{ .key = AppSessions.of, .seen = AppSessions.seen, .ctx = @ptrCast(&app_sessions) },
        .tr = resourceTr,
    });
}

/// Only what `controlPage` reaches, as task 1730's tests build an `App`: a
/// whole one wants the runtime's surfaces, which a test build has none of.
const PageWorld = struct {
    app: App,

    fn init(self: *PageWorld, alloc: Allocator) !void {
        const P = poltergeistpkg;
        self.app = undefined;
        const app = &self.app;
        app.alloc = alloc;
        app.surfaces = .empty;
        app.page_req = .empty;
        app.page_out = .empty;
        app.page_held = false;
        app.control_home = "";
        app.control_room = .init(alloc);
        app.resource_usage = .empty;
        app.resource_judges = .empty;
        app.resource_recent = .empty;
        app.resource_killed = .empty;
        app.resource_history = .{};
        app.resource_history_file = null;
        app.resource_names = .{};
        app.resource_sessions = .{};
        app.resource_overall = null;
        app.overall_wall_ms_for_test = null;
        app.group_log = null;
        app.resource_seq = 1;
        app.poltergeist = .init(alloc, .{});
        app.chat = .init(alloc, .{});
        app.tasks = .init(alloc, .{});
        app.task_log = null;
        app.chat_log = null;

        // web-app: its supervisor 0xa1 and a worker 0xb1, both read; the
        // supervisor's half hour open now.
        try app.chat.create("web-app", 0xa1);
        app.control_room.route_rows = &.{.{
            .group = "web-app",
            .steward = 0xa1,
            .members = &.{ 0xa1, 0xb1 },
            .titles = &.{ "design-system", "ocr-mask" },
            .own = &.{ false, false },
        }};
        try app.resource_usage.put(alloc, 0xa1, .{ .id = 0xa1, .mem = 1 << 30, .procs = 6 });
        try app.resource_usage.put(alloc, 0xb1, .{ .id = 0xb1, .mem = 3 << 30, .procs = 9 });
        const now = app.poltergeistWallMs();
        _ = try app.resource_history.note(alloc, 0xa1, now, P.daylog.localOffsetMs(now), .warn1, 1 << 30, 6);

        // Its tasks: one being done by the worker, one closed.
        const t1 = try app.tasks.create("web-app", "PATCH /api/tasks takes a list of ids", .feature);
        try app.tasks.assign(t1, 0xb1);
        const t2 = try app.tasks.create("web-app", "List and filter", .feature);
        try app.tasks.close(t2);
    }

    fn deinit(self: *PageWorld) void {
        const app = &self.app;
        const alloc = app.alloc;
        app.page_req.deinit(alloc);
        app.page_out.deinit(alloc);
        app.control_room.route_rows = &.{};
        app.control_room.deinit();
        app.resource_usage.deinit(alloc);
        app.resource_judges.deinit(alloc);
        app.resource_recent.deinit(alloc);
        app.resource_killed.deinit(alloc);
        app.resource_history.deinit(alloc);
        app.resource_names.deinit(alloc);
        app.resource_sessions.deinit(alloc);
        if (app.resource_overall) |o| o.destroy();
        app.resource_overall = null;
        app.poltergeist.deinit();
        app.chat.deinit();
        app.tasks.deinit();
    }

    /// The page for `req`, as a host gets it with a buffer big enough,
    /// parsed into `arena`.
    fn ask(self: *PageWorld, arena: Allocator, req: []const u8) !std.json.Value {
        const out = self.app.controlPage(req, 1 << 20);
        return std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{});
    }

    /// Give the page world a reading to answer from (task 2149): one
    /// sample, at a moment fixed so that two answers can be compared.
    fn sample(self: *PageWorld, alloc: Allocator) !void {
        const app = &self.app;
        const overall = try poltergeistpkg.Overall.create(alloc);
        app.resource_overall = overall;
        const start: i64 = 1_700_000_000_000;
        const at: i64 = start + 5 * poltergeistpkg.Overall.hour_ms;
        app.overall_wall_ms_for_test = at;

        const chat = poltergeistpkg.Overall.PaneReading.named(0xc1, .chat, "web-app", 700 << 20, 2);
        var panes: [1]poltergeistpkg.Overall.PaneReading = .{chat};
        overall.sample(.{
            .now_ms = at,
            .start_ms = start,
            .machine = .{
                .mem_total = 32 << 30,
                .mem_used = 20 << 30,
                .swap_used = 18 << 30,
                .swap_total = 24 << 30,
                .disk_free = 9 << 30,
            },
            .main = .{ .id = 0, .root_pid = 4242, .mem = 512 << 20, .procs = 1 },
            .panes = &panes,
        });
    }
};

test "2015: control_page answers a group's 24 hours and 7 days, its tasks, and refuses a span it does not know" {
    const testing = std.testing;
    var w: PageWorld = undefined;
    try w.init(testing.allocator);
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Each span: its own count of cells, in every terminal's row.
    const Want = struct { span: []const u8, cells: i64 };
    for ([_]Want{ .{ .span = "day", .cells = 48 }, .{ .span = "week", .cells = 42 } }) |want| {
        const req = try std.fmt.allocPrint(a, "{{\"page\":\"resources\",\"group\":\"web-app\",\"span\":\"{s}\",\"since\":0}}", .{want.span});
        const v = try w.ask(a, req);
        const grid = v.object.get("grid").?.object;
        try testing.expectEqualStrings(want.span, grid.get("span").?.string);
        try testing.expectEqual(want.cells, grid.get("cells").?.integer);
        const panes = grid.get("panes").?.array.items;
        try testing.expectEqual(@as(usize, 2), panes.len);
        for (panes) |pane| {
            const n: i64 = @intCast(pane.object.get("cells").?.array.items.len);
            try testing.expectEqual(want.cells, n);
        }
        // The supervisor's open half hour is in its last cell either way.
        const last = panes[0].object.get("cells").?.array.items;
        try testing.expectEqualStrings("warn1", last[last.len - 1].string);
        // The supervisor first, by its title.
        try testing.expectEqualStrings("design-system", v.object.get("cards").?.array.items[0].object.get("name").?.string);
    }

    // The task page: the open task with its owner by name, the closed
    // one counted.
    {
        const v = try w.ask(a, "{\"page\":\"tasks\",\"group\":\"web-app\",\"closed\":false}");
        const open = v.object.get("open").?.array.items;
        try testing.expectEqual(@as(usize, 1), open.len);
        try testing.expectEqualStrings("ocr-mask", open[0].object.get("owner").?.string);
        try testing.expectEqual(@as(i64, 1), v.object.get("closed_count").?.integer);
    }

    // What it will not answer.
    try testing.expectEqualStrings("{\"error\":\"BadRequest\"}", w.app.controlPage("{\"page\":\"resources\",\"group\":\"web-app\",\"span\":\"month\"}", 1 << 20));
    try testing.expectEqualStrings("{\"error\":\"NoSuchGroup\"}", w.app.controlPage("{\"page\":\"resources\",\"group\":\"nope\",\"span\":\"day\"}", 1 << 20));
    try testing.expectEqualStrings("{\"error\":\"BadRequest\"}", w.app.controlPage("not json", 1 << 20));
}

// The two doors onto the overall answer are one answer (task 2149, slice
// 2): `resource_overview` -- what a supervisor's tool call gets -- and the
// `overall` page, which is what the host draws. **Byte for byte**, because
// a supervisor reading the tool's figures while somebody reads the page's
// is exactly the case where two answers cost somebody an afternoon.
//
// The moment is fixed (`overall_wall_ms_for_test`): the answer carries
// `at`, and two reads of the real clock a millisecond apart would make
// this a test about the clock.
test "2149: the overall page and resource_overview answer the same bytes" {
    const testing = std.testing;
    var w: PageWorld = undefined;
    try w.init(testing.allocator);
    defer w.deinit();
    try w.sample(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every pair of arguments the page can ask for -- `resource_overview`
    // has one more (`pid`, for one process and its 24 hours of points),
    // which is the tool's alone and is not a page.
    const Cases = struct { page: []const u8, group: []const u8 };
    for ([_]Cases{
        .{ .page = "{\"page\":\"overall\"}", .group = "" },
        .{ .page = "{\"page\":\"overall\",\"group\":\"web-app\"}", .group = "web-app" },
    }) |c| {
        const tool = try poltergeistResourceOverview(&w.app, a, .{ .resource_overview = .{ .group = c.group } });
        const page = w.app.controlPage(c.page, 1 << 20);
        try testing.expectEqualStrings(tool, page);
        // And it is the whole answer, not two empty buffers agreeing.
        try testing.expect(std.mem.indexOf(u8, page, "\"processes\"") != null);
    }

    // A group nobody has is refused by both, and by name.
    try testing.expectError(error.NoSuchGroup, poltergeistResourceOverview(&w.app, a, .{ .resource_overview = .{ .group = "nope" } }));
    try testing.expectEqualStrings("{\"error\":\"NoSuchGroup\"}", w.app.controlPage("{\"page\":\"overall\",\"group\":\"nope\"}", 1 << 20));

    // Before the first reading: empty, which is this door's "no answer yet"
    // (a host draws nothing then), and not a page saying Polter costs 0.
    const held = w.app.resource_overall;
    w.app.resource_overall = null;
    try testing.expectEqualStrings("", w.app.controlPage("{\"page\":\"overall\"}", 1 << 20));
    try testing.expectError(error.NoReading, poltergeistResourceOverview(&w.app, a, .{ .resource_overview = .{} }));
    w.app.resource_overall = held;
}

test "2015: control_page holds an answer that did not fit, for the same request asked again" {
    const testing = std.testing;
    var w: PageWorld = undefined;
    try w.init(testing.allocator);
    defer w.deinit();
    const req = "{\"page\":\"resources\",\"group\":\"web-app\",\"span\":\"day\",\"since\":0}";

    // A host asks for the length first (no buffer): the answer is held...
    const first = try testing.allocator.dupe(u8, w.app.controlPage(req, 0));
    defer testing.allocator.free(first);
    try testing.expect(first.len > 0);
    // ...and the same request then gets those bytes, not a new reading.
    w.app.resource_seq += 1;
    try testing.expectEqualStrings(first, w.app.controlPage(req, first.len + 1));
    // Taken: the next ask is a new reading.
    const third = w.app.controlPage(req, 1 << 20);
    try testing.expect(!std.mem.eql(u8, first, third));
}

// The working-directory page where the runtime has no surfaces at all: this
// is a test build's world, and the page still has to answer. Its terminals
// have no shell that ever said where it was, so every row left is one whose
// directory the worktree ledger knows -- and a terminal whose cwd is not
// known is not a row of its own (`Workdirs.compute` skips it).
test "2145 C1: the workdirs page answers where the runtime has no surfaces, and cwd is null" {
    const testing = std.testing;
    var w: PageWorld = undefined;
    try w.init(testing.allocator);
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The runtime this test is built against has no `core` on its Surface:
    // that is the whole reason the page's path through `terminalCwd` and
    // `findSurfaceByID` used to fail to compile. Guarded, so that a runtime
    // that *does* have one says so instead of quietly testing nothing.
    if (comptime @hasDecl(apprt.Surface, "core")) return error.SkipZigTest;

    // A worktree of the group's supervisor, on a real directory, so that the
    // page has one row to write.
    const tmp = testing.tmpDir(.{});
    var tmp_dir = tmp;
    defer tmp_dir.cleanup();
    const real = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", a);
    w.app.poltergeist_worktrees = .{ .alloc = testing.allocator };
    defer w.app.poltergeist_worktrees.?.entries.deinit(testing.allocator);
    try w.app.poltergeist_worktrees.?.entries.append(testing.allocator, .{
        .name = "wt-shop",
        .repo = "shop",
        .path = real,
        .branch = "wt/shop",
        .base = "0",
        .by = 0xa1,
    });

    const v = try w.ask(a, "{\"page\":\"workdirs\",\"group\":\"web-app\"}");
    try testing.expectEqualStrings("workdirs", v.object.get("page").?.string);
    try testing.expectEqualStrings("web-app", v.object.get("group").?.string);

    // The supervisor 0xa1 is in the group and the worktree is its, so its row
    // is there -- as a **tree**, with the tree's name and nobody in `who`:
    // the supervisor's own directory is not a row, because with no surfaces
    // `terminalCwd` answered null for it, and a terminal whose cwd is not
    // known is not a row. A row that invented a terminal for the tree would
    // read here as one.
    const dirs = v.object.get("dirs").?.array.items;
    try testing.expectEqual(@as(usize, 1), dirs.len);
    try testing.expectEqualStrings(real, dirs[0].object.get("path").?.string);
    try testing.expectEqualStrings("tree", dirs[0].object.get("kind").?.string);
    try testing.expectEqualStrings("wt-shop", dirs[0].object.get("tree_name").?.string);
    try testing.expectEqual(@as(usize, 0), dirs[0].object.get("who").?.array.items.len);
    try testing.expect(dirs[0].object.get("readable").?.bool);
}

pub fn controlSnapshotJson(self: *const App) []const u8 {
    return self.control_room.json;
}

/// The group a click on a notification from terminal `id` opens the
/// control room at, by the snapshot last worked out
/// (`ControlRoom.groupToShow`); null when it is in none. Borrowed until the
/// next `tick`.
pub fn notificationGroup(self: *const App, id: poltergeistpkg.Bus.Id) ?[]const u8 {
    return poltergeistpkg.ControlRoom.groupToShow(self.control_room.route_rows, id);
}

/// What the configuration says about how the bus behaves, over `base`.
/// Every setting the bus reads is named here, so that the place they are
/// applied cannot apply three of them and forget the fourth.
fn busConfigFrom(base: poltergeistpkg.Bus.Config, config: *const Config) poltergeistpkg.Bus.Config {
    var out = base;
    out.notice_interval_ms = config.@"poltergeist-notice-interval".duration / std.time.ns_per_ms;
    out.stand_down_allowed = config.@"poltergeist-supervisor-stand-down";
    out.may_authorise = config.@"poltergeist-may-authorise";
    out.calls_silent_after_ms = config.@"poltergeist-calls-silent-after".duration / std.time.ns_per_ms;
    return out;
}

/// Bring Poltergeist's settings in line with `config`: what the bus does
/// by default, and the thresholds the app keeps beside it.
///
/// **Called as every surface starts, and on a reload** -- because
/// `updateConfig` runs only on a reload and neither apprt calls it at
/// launch. Until this existed, these were written in `updateConfig` and
/// nowhere else, so **the configuration a person started Polter with never
/// reached the bus at all**: it ran on the defaults compiled into
/// `Bus.Config` until somebody reloaded by hand. For most of them that is a
/// wrong number. For `poltergeist-may-authorise` it is a gate the person
/// shut and the core held open: `false` in the file, the menu item drawn
/// unticked by the host (which reads the file itself), and every terminal
/// answering "a supervisor may answer my prompts" (the Windows machine,
/// 2026-10-13; the same code runs on macOS).
///
/// A terminal's own choice (`Bus.Entry.may_authorise`) is beside the
/// default, not under it, so neither this nor a reload undoes one.
pub fn applyPoltergeistSettings(self: *App, config: *const Config) void {
    self.poltergeist.config = busConfigFrom(self.poltergeist.config, config);
    self.control_still_ms =
        config.@"poltergeist-quiescence-after".duration / std.time.ns_per_ms;

    self.poltergeist_task_idle_ms =
        config.@"poltergeist-task-idle-after".duration / std.time.ns_per_ms;
    self.poltergeist_silence_remind_ms =
        config.@"poltergeist-silence-remind-after".duration / std.time.ns_per_ms;
    // The period a reminder is planned at just moved: work out the next
    // moment again rather than wait for the one already armed, which was
    // computed from the old value (task 2148).
    self.alarm_dirty = true;
    self.poltergeist_group_quiet_ms =
        config.@"poltergeist-group-quiet-after".duration / std.time.ns_per_ms;
    self.poltergeist_worker_nudge_ms =
        config.@"poltergeist-worker-nudge-after".duration / std.time.ns_per_ms;
    self.poltergeist_compact_after = config.@"poltergeist-compact-after".value;
    self.poltergeist_screenshot_allowed = config.@"screenshot-agent-access" == .allow;
    self.stall_watch.threshold_ns.store(
        @intCast(config.@"poltergeist-stall-warn-after".duration),
        .monotonic,
    );
    self.poltergeist_worktree_location = switch (config.@"poltergeist-worktree-location") {
        .beside => .beside,
        .inside => .inside,
    };
    self.sweep_limits = SweepLimits.from(config);
    self.configureSweeper();

    // The default may have moved under every terminal that has not said
    // for itself: the menus read it off the mark, the control room off the
    // snapshot.
    self.refreshPoltergeistTabs();
}

test "poltergeist settings: what the configuration says reaches the bus, the shut gate above all" {
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();

    // As shipped: a supervisor may answer.
    const shipped = busConfigFrom(.{}, &config);
    try std.testing.expect(shipped.may_authorise);

    // The person shuts it, and changes the other three while they are there.
    config.@"poltergeist-may-authorise" = false;
    config.@"poltergeist-supervisor-stand-down" = !shipped.stand_down_allowed;
    config.@"poltergeist-notice-interval" = .{ .duration = 7 * std.time.ns_per_s };
    config.@"poltergeist-calls-silent-after" = .{ .duration = 3 * std.time.ns_per_min };
    const shut = busConfigFrom(.{}, &config);
    try std.testing.expect(!shut.may_authorise);
    try std.testing.expectEqual(!shipped.stand_down_allowed, shut.stand_down_allowed);
    try std.testing.expectEqual(@as(u64, 7_000), shut.notice_interval_ms);
    try std.testing.expectEqual(@as(u64, 180_000), shut.calls_silent_after_ms);

    // And a bus run on that is one where the gate is shut for a terminal
    // nobody has said otherwise about.
    var bus: poltergeistpkg.Bus = .init(std.testing.allocator, shut);
    defer bus.deinit();
    try bus.register(0xb1);
    try std.testing.expect(!bus.mayAuthorise(0xb1));
    try std.testing.expectEqual(poltergeistpkg.Bus.Answer.off, bus.answer(0xb1));
}

/// Update the configuration associated with the app. This can only be
/// called from the main thread. The caller owns the config memory. The
/// memory can be freed immediately when this returns.
pub fn updateConfig(self: *App, rt_app: *apprt.App, config: *const Config) !void {
    // Bring the agent socket in line with the config. Failing to open it
    // must never take the app down with it: the terminal has to keep
    // working whether or not agents can reach it.
    self.poltergeist_rt_app = rt_app;
    self.syncPoltergeistServer(
        config.@"poltergeist-mcp",
        config.@"poltergeist-max-agents",
    ) catch |err| {
        log.warn("poltergeist: could not open the agent socket err={}", .{err});
    };

    self.applyPoltergeistSettings(config);

    self.poltergeist_notify_window =
        poltergeistpkg.notify.Window.parse(config.@"poltergeist-notify-window");
    self.refreshPoltergeistConfigText(config);
    self.ensurePlugins();

    // Here for the ordering, not for the reload. The archives are looked
    // for exactly once, and the two things that have to have happened
    // first -- the log opening and the plugin list being read -- arrive in
    // whichever order the apprt happens to produce; this is the second of
    // the two places that notices they both have. Once they have been
    // looked for it does nothing, so a plugin installed while Polter is
    // running still waits for a restart, the same as a notification one.
    self.ensureResidents();

    // Moved into each plugin's own file, so that one plugin's state lives in
    // one place and a settings UI can own it. Said plainly rather than
    // ignored in silence: somebody who set this expects it to do something.
    if (config.@"poltergeist-notify".list.items.len > 0) {
        log.warn(
            "poltergeist-notify no longer does anything; a plugin is switched " ++
                "on by \"enabled\" in $XDG_CONFIG_HOME/polter/plugins/<name>.json",
            .{},
        );
    }

    // Go through and update all of the surface configurations.
    for (self.surfaces.items) |surface| {
        try surface.core().handleMessage(.{ .change_config = config });
    }

    // Apply our conditional state. If we fail to apply the conditional state
    // then we log and attempt to move forward with the old config.
    // We only apply this to the app-level config because the surface
    // config applies its own conditional state.
    var applied_: ?configpkg.Config = config.changeConditionalState(
        self.config_conditional_state,
    ) catch |err| err: {
        log.warn("failed to apply conditional state to config err={}", .{err});
        break :err null;
    };
    defer if (applied_) |*c| c.deinit();
    const applied: *const configpkg.Config = if (applied_) |*c| c else config;

    // Notify the apprt that the app has changed configuration.
    _ = try rt_app.performAction(
        .app,
        .config_change,
        .{ .config = applied },
    );
}

/// Add an initialized surface. This is really only for the runtime
/// implementations to call and should NOT be called by general app users.
/// The surface must be from the pool.
/// Handle a quiescence report from one surface.
///
/// The bus decides whether this is worth saying at all -- it knows who is
/// supervising, who has clocked off, and how recently this terminal last
/// spoke. If it is, the notice is typed into the supervisor's terminal as
/// if the user had typed it.
///
/// The notice carries an id and two durations, never screen contents. The
/// supervisor reads the other terminal itself if it wants to know what is
/// on it, which keeps the judgement on the AI's side and keeps a whole
/// screen out of its context.
fn poltergeistReport(
    self: *App,
    from: poltergeistpkg.Bus.Id,
    event: poltergeistpkg.Sampler.Event,
) void {
    // Whatever comes of the report, the tabs should say what is true now.
    defer self.refreshPoltergeistTabs();

    const now_ms = self.poltergeistElapsedMs();

    // Into the box. Nothing goes to the supervisor at this instant: a
    // report is a change of state, not an errand, and interrupting somebody
    // once per event per terminal is how a helpful signal turns into noise
    // that gets ignored or switched off.
    _ = self.poltergeist.report(from, event, now_ms);
    // A screen that went still on a declined box: the turn is over, and
    // said so before the quiet report goes anywhere (task 2021).
    _ = self.considerDeclined(from, now_ms);

    // Before the hand-over, so anything worked out this pass rides out in
    // the same line rather than waiting a whole interval behind it.
    self.considerGroupNotes(now_ms);
    // Before `considerCalls`, which asks the same question (#63).
    self.notePoltergeistAgentsHere();
    _ = self.considerLaunches(now_ms);
    _ = self.poltergeist.considerCalls(now_ms);
    _ = self.poltergeist.considerAgents(now_ms);
    self.considerWorkerNudge(from, event);
    self.deliverPoltergeistNotices(now_ms);
}

/// A moving screen has restated its quiet time (`Sampler.heartbeat`).
///
/// **This is the only thing that runs while a screen is moving**, and that
/// is why it now does more than record the figure. The box is otherwise
/// handed over when a quiet report arrives, and a terminal stuck printing
/// retry countdowns never sends one -- so a call-silence line about it
/// (`Bus.considerCalls`) would sit in the box with nothing to carry it,
/// exactly while it matters. Delivery is still bounded by
/// `poltergeist-notice-interval`, and an empty box interrupts nobody, so
/// this changes when a waiting line goes out, never how often.
///
/// The tabs are redrawn for the same reason: a supervisor's hollow flag
/// has to appear while everything around it is busy.
///
/// ⚠️ **Not a timer.** A window with nothing watched in it sends no
/// heartbeats and no reports, and then nothing here runs -- the gap
/// `considerGroupNotes` names, and the same one.
fn poltergeistHeartbeat(
    self: *App,
    from: poltergeistpkg.Bus.Id,
    quiet_ms: u64,
) void {
    const now_ms = self.poltergeistElapsedMs();
    self.poltergeist.noteQuiet(from, quiet_ms, now_ms);
    self.capturePermissionBox(from, now_ms);
    self.considerScreenApproval(from, now_ms);
    _ = self.considerDeclined(from, now_ms);
    self.notePoltergeistAgentsHere();
    _ = self.considerLaunches(now_ms);
    _ = self.poltergeist.considerCalls(now_ms);
    _ = self.poltergeist.considerAgents(now_ms);
    self.deliverPoltergeistNotices(now_ms);
    self.refreshPoltergeistTabs();
}

/// Capture a permission box whose own rows keep redrawing, once it has
/// been drawn (task 1655): `Bus.promptStanding` compares the screen with it
/// when the box is answered, since "the screen has not moved" can never be
/// true of it. Here because a heartbeat is what arrives while a screen
/// moves -- a still one needs nothing captured -- and read the way
/// terminal_read reads, which is how the answer side reads it too.
fn capturePermissionBox(self: *App, id: poltergeistpkg.Bus.Id, now_ms: u64) void {
    if (!self.poltergeist.wantsBoxPrint(id, now_ms)) return;
    const event_ms = self.poltergeist.agentOf(id).eventMs();
    const screen = poltergeistRead(self, self.alloc, id, 0) catch |err| {
        log.debug("poltergeist: could not read the box id={x} err={}", .{ id, err });
        return;
    };
    defer self.alloc.free(screen);
    const kept = self.poltergeist.noteBoxPrint(id, event_ms, screen);
    log.info("poltergeist: permission box captured id={x} event_ms={d} kept={}", .{ id, event_ms, kept });
}

/// Read an approval box off the screen, for a CLI whose hooks are live and
/// have no event for one (task 1682: Antigravity). Here for the reason
/// `capturePermissionBox` is: a heartbeat comes every few seconds until a
/// screen has been reported still (`Sampler.heartbeat`), still or not, so
/// a box that has just been drawn is read within one of them -- where the
/// quiet report would wait `poltergeist-quiescence-after`.
///
/// Read only when all three hold: the bus wants it (hooks live, and a tool
/// running or a wait the screen already said), and the CLI's plugin
/// declares `hooks_report_approval: false` with a box to look for. A
/// Claude Code or Codex terminal is never read here.
fn considerScreenApproval(self: *App, id: poltergeistpkg.Bus.Id, now_ms: u64) void {
    if (!self.poltergeist.wantsScreenApproval(id)) return;
    // A copy, kept for as long as the name read out of it is used.
    const agent = self.poltergeist.agentOf(id);
    const cli = agent.cli.get() orelse return;
    self.ensurePlugins();
    const says = poltergeistpkg.Plugin.screenApprovalFor(self.poltergeist_says, cli) orelse return;
    const screen = poltergeistRead(self, self.alloc, id, 0) catch |err| {
        log.debug("poltergeist: could not read for a box id={x} err={}", .{ id, err });
        return;
    };
    defer self.alloc.free(screen);
    const said = says.approvalSaid(screen);
    // Kept in the bus before `screen` is freed: its note is copied there.
    if (self.poltergeist.noteScreenApproval(id, said, now_ms)) {
        log.info("poltergeist: approval box on screen id={x}", .{id});
    }
}

/// Read a box declined at the terminal off the screen (task 2021): Esc, or
/// No with nothing typed, ends Claude Code's turn and fires no hook (#879),
/// so the wait its `PermissionRequest` put in place would stand for as
/// long as the terminal is open. Asked on every heartbeat and every quiet
/// report -- the screen moves while the box goes and then goes still --
/// and before a line is typed in (`approvalOnScreen`), which is the one
/// that cannot wait for either. Read only when the bus wants it (a hook's
/// wait, past the redraw grace) and the CLI's plugin declares how.
///
/// Answers whether the wait was ended.
fn considerDeclined(self: *App, id: poltergeistpkg.Bus.Id, now_ms: u64) bool {
    if (!self.poltergeist.wantsDeclined(id, now_ms)) return false;
    // A copy, kept for as long as the name read out of it is used.
    const agent = self.poltergeist.agentOf(id);
    const cli = agent.cli.get() orelse return false;
    self.ensurePlugins();
    const says = poltergeistpkg.Plugin.declinedFor(self.poltergeist_says, cli) orelse return false;
    const screen = poltergeistRead(self, self.alloc, id, 0) catch |err| {
        log.debug("poltergeist: could not read for a declined box id={x} err={}", .{ id, err });
        return false;
    };
    defer self.alloc.free(screen);
    const said = says.declinedSaid(screen) orelse return false;
    _ = self.poltergeist.noteDeclined(id, said, now_ms);
    log.info("poltergeist: approval box declined at the terminal id={x} said=\"{s}\"", .{ id, said });
    self.refreshPoltergeistTabs();
    self.controlRoomTouch();
    return true;
}

/// Remind one worker that printing is not reporting, once, when it stops.
///
/// **The asymmetry this closes.** A supervisor reaches a worker by typing
/// into it -- that is what `task_assign` and `terminal_send` do. A worker
/// reaches its supervisor only by calling `task_progress` or `group_post`
/// of its own accord, and nothing anywhere asks it to. So a worker that
/// finishes writes its account to its own screen and stops, and what the
/// system observes is a still screen: **done and stuck look identical**,
/// and the supervisor has to go and read the terminal to tell which.
///
/// This does not fix that by asking for a report. It puts the two calls in
/// front of the worker at the moment it has just stopped, and says plainly
/// that doing nothing is one of the answers -- see `notes.nudge` for why
/// that wording matters.
fn considerWorkerNudge(
    self: *App,
    id: poltergeistpkg.Bus.Id,
    event: poltergeistpkg.Sampler.Event,
) void {
    if (self.poltergeist_worker_nudge_ms == 0) return;

    // Only a screen that has stopped. `resumed` is the opposite of the
    // case this is for.
    const quiet_ms: u64 = switch (event) {
        .quiescent, .still_quiescent => |r| r.quiet_ms,
        .resumed => return,
    };
    if (quiet_ms < self.poltergeist_worker_nudge_ms) return;

    // A terminal that has clocked off is supposed to be quiet, and a
    // supervisor is not holding work of its own.
    const entry = self.poltergeist.get(id) orelse return;
    if (entry.duty == .off) return;
    if (entry.role == .supervisor) return;

    // What this terminal is holding, across every group. Nothing open
    // means there is nothing to report on, and nothing to say.
    var open: std.ArrayListUnmanaged(u64) = .empty;
    defer open.deinit(self.alloc);

    var groups = self.chat.groups.keyIterator();
    while (groups.next()) |name| {
        const mine = self.tasks.forWorker(self.alloc, name.*, id) catch continue;
        defer self.alloc.free(mine);

        for (mine) |t| {
            if (t.state != .open) continue;
            if (self.poltergeist_nudged.contains(t.id)) continue;
            open.append(self.alloc, t.id) catch break;
        }
    }
    if (open.items.len == 0) return;

    var buf: [poltergeistpkg.provision.max_message]u8 = undefined;
    const line = poltergeistpkg.notes.nudge(&buf, quiet_ms, open.items);
    if (line.len == 0) return;

    // Marked before the telling, not after: `tellSurface` cannot say
    // whether the agent read it, and a reminder that repeats because the
    // delivery could not be confirmed is exactly the nagging this is
    // bounded to avoid.
    for (open.items) |task| {
        self.poltergeist_nudged.put(self.alloc, task, {}) catch {};
    }

    self.tellSurface(id, line);
}
/// How often the group notes are worked out again.
///
/// Five minutes because working them out reads the panel's record off
/// disk, and because nothing they report changes faster than that: the
/// shortest thing they say is measured in hours. The hand-over that
/// carries them is separately bounded by `poltergeist-notice-interval`,
/// which is the number that decides how often anybody is interrupted.
const notes_every_ms = 5 * std.time.ms_per_min;

/// The most events one note is worked out over.
///
/// A night of real work is a few hundred, so this is a wall rather than a
/// budget. Past it the oldest end is not counted, which understates the
/// silences rather than inventing one.
const notes_max_events = 4000;

/// Work out what each group's supervisor should be told, and leave it in
/// that supervisor's box.
///
/// **Into the same box and on the same clock as the quiet reports.**
/// `poltergeist-notice-interval` exists to bound how often a supervisor is
/// interrupted at all, and a second channel with its own schedule would be
/// a way round the one number the user set to answer that question --
/// however good the reason for the interruption.
///
/// Driven by reports arriving rather than by a timer of its own, the same
/// way `deliverPoltergeistNotices` is. That leaves one gap and it is worth
/// naming: a window with no watched terminal in it produces no reports, so
/// nothing here runs. Such a window has no supervision arrangement at all,
/// and the statistics tab is the thing that answers for it -- it is read
/// rather than delivered.
fn considerGroupNotes(self: *App, now_ms: u64) void {
    if (self.poltergeist_notes_ms) |last| {
        if (now_ms -| last < notes_every_ms) return;
    }
    self.poltergeist_notes_ms = now_ms;

    const wall = self.poltergeistWallMs();

    var it = self.chat.groups.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        const owner = kv.value_ptr.created_by;

        // **A group nobody has taken up has nobody to tell.** After a
        // restart every group comes back as a shell owned by `user_id`,
        // which is not a claim that the person made it -- it is the
        // absence of a claim, and it stands until a supervisor takes the
        // group up. Leaving a note for id zero would be leaving it for a
        // terminal that does not exist.
        //
        // The snapshot is not conditional on that, and deliberately: it
        // interrupts nobody, and a group running with no supervisor is
        // exactly the case where the morning has nothing else to read.
        const tell: ?poltergeistpkg.Bus.Id = if (owner != poltergeistpkg.Chat.user_id and
            self.poltergeist.isSupervisor(owner)) owner else null;
        const snap = if (self.stats_log) |*l| l.due(name, wall) else false;
        if (tell == null and !snap) continue;

        self.readGroupRecord(name, kv.value_ptr.last_ms, wall, tell, snap);
    }
}

/// Read one group's panel and record once, and use it for both jobs.
///
/// Once, because both of them want the same two reads off disk and this
/// runs on the app thread. The judgement-free arithmetic is in
/// `poltergeist/notes.zig` and `StatsLog.summarise`, which have tests;
/// what is left here is the fetching, which this file cannot test anyway.
fn readGroupRecord(
    self: *App,
    group: []const u8,
    last_said_ms: u64,
    wall_ms: i64,
    /// The supervisor to leave the line with, or null for a group nobody
    /// has taken up.
    tell: ?poltergeistpkg.Bus.Id,
    snap: bool,
) void {
    const l = if (self.task_log) |*v| v else return;

    const page = l.history(self.alloc, group, 0, notes_max_events) catch return;
    defer poltergeistpkg.TaskLog.freePage(self.alloc, page);

    const panel = self.tasks.inGroup(self.alloc, group) catch return;
    defer self.alloc.free(panel);

    if (tell) |to| {
        var open: std.ArrayListUnmanaged(poltergeistpkg.notes.Task) = .empty;
        defer open.deinit(self.alloc);
        for (panel) |t| open.append(self.alloc, .{
            .id = t.id,
            .open = t.state == .open,
        }) catch break;

        var buf: [poltergeistpkg.Bus.memo_bytes]u8 = undefined;
        const line = poltergeistpkg.notes.line(&buf, .{
            .group = group,
            .now_ms = wall_ms,
            .last_said_ms = @intCast(last_said_ms),
            .task_idle_ms = self.poltergeist_task_idle_ms,
            .group_quiet_ms = self.poltergeist_group_quiet_ms,
            .chat_bytes = self.chat.bytesOf(group),
            .compact_after_bytes = self.poltergeist_compact_after,
            .tasks = open.items,
            .events = page.events,
        });

        // An empty line clears the slot rather than leaving yesterday's
        // sentence to be handed over as though it were still true.
        _ = self.poltergeist.leaveNote(to, line);
    }

    if (!snap) return;
    const sl = if (self.stats_log) |*v| v else return;

    var counted: std.ArrayListUnmanaged(poltergeistpkg.StatsLog.Task) = .empty;
    defer counted.deinit(self.alloc);
    for (panel) |t| counted.append(self.alloc, .{
        .id = t.id,
        .state = switch (t.state) {
            .open => .open,
            .closed => .closed,
            .cancelled => .cancelled,
        },
    }) catch break;

    const silent: u64 = if (last_said_ms > 0)
        @intCast(@max(wall_ms - @as(i64, @intCast(last_said_ms)), 0))
    else
        0;

    sl.append(wall_ms, group, poltergeistpkg.StatsLog.summarise(
        wall_ms,
        self.poltergeist_task_idle_ms,
        silent,
        counted.items,
        page.events,
    ));
}

/// Hand the box to the supervisor, if it is time and there is anything in
/// it.
///
/// Driven by reports arriving rather than by a timer of its own. A terminal
/// that is still quiet keeps reporting on the sampler's repeat interval, so
/// there is always something to drive the next hand-over while anything is
/// waiting; and when every terminal is busy there is nothing to hand over.
/// The supervisor can also read the box itself at any time, which is what
/// covers the gap after the last report of all.
fn deliverPoltergeistNotices(self: *App, now_ms: u64) void {
    // Whether each watched terminal still has an agent in it, asked now,
    // because the lines below are written now (#63). The bus cannot see
    // connections; an agent that exits leaves everything it knows as it
    // was, and a bare shell would be reported as a worker standing by.
    self.notePoltergeistAgentsHere();

    // Each supervisor gets its own box, on its own clock. A shared one
    // would hand each of them the other's reports: twice the interruption,
    // and half of it about terminals they cannot read anyway.
    var supervisors: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
    defer supervisors.deinit(self.alloc);

    var it = self.poltergeist.entries.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.role != .supervisor) continue;
        supervisors.append(self.alloc, kv.key_ptr.*) catch return;
    }

    for (supervisors.items) |to| {
        const surface = self.findSurfaceByID(to) orelse {
            // That supervisor's terminal went away. Releasing it here also
            // releases the terminals it was minding, which then belong to
            // nobody until somebody claims them -- better than reporting
            // into a terminal that is gone.
            self.poltergeist.unregister(to);
            continue;
        };

        var buf: [255:0]u8 = undefined;
        // `chat.peers()`: a terminal the user watched by hand has no minder,
        // and with several supervisors it is the groups that say whose work
        // it is part of (#1064). The bus cannot know that; the chat does.
        const line = self.poltergeist.drainIfDue(to, now_ms, &buf, self.chat.peers()) orelse continue;
        buf[line.len] = 0;

        const agent_here = self.agentPresent(to);
        log.info("poltergeist: hand-over queued id={x} agent_present={} -> {s}", .{
            to,
            agent_here,
            if (agent_here) "to type" else "to print",
        });
        const msg: apprt.surface.Message = if (agent_here)
            .{ .poltergeist_handover = buf }
        else
            .{ .poltergeist_alert = buf };
        self.surfaceMessage(surface, msg) catch |err| {
            log.warn("poltergeist: could not deliver notices err={}", .{err});
        };
    }
}

/// Tell the bus, for every watched terminal and every supervisor, whether
/// an agent is connected from it (`Server.agentPresent`) -- see
/// `Bus.Entry.agent_here`.
///
/// **Supervisors too** (task 1762): this is the only road by which the bus
/// learns that an agent has gone (`Bus.considerLinks`), and a supervisor's
/// agent is the one nobody else is watching. Left out, an agy supervisor
/// ended in the middle of a turn stayed `in_turn` and its group's
/// supervisor for good.
fn notePoltergeistAgentsHere(self: *App) void {
    const now_ms = self.poltergeistElapsedMs();
    // An agent said to have left here, or back (task 1802): nothing else
    // that runs this marks the control room, and a supervisor whose agent
    // had gone was shown "Working" for minutes on Windows.
    const left_before = self.poltergeist.left_changes;
    defer if (self.poltergeist.left_changes != left_before) self.controlRoomTouch();
    var it = self.poltergeist.entries.iterator();
    while (it.next()) |kv| {
        switch (kv.value_ptr.role) {
            .watched, .supervisor => {},
            .none => continue,
        }
        const id = kv.key_ptr.*;
        const here = self.agentPresent(id);
        const was_here = kv.value_ptr.agent_here == true;
        const pid: ?u64 = if (!here) null else if (self.poltergeist_server) |*srv| srv.agentPid(id) else null;
        const program: ?poltergeistpkg.Bus.Program = if (pid) |p| .{
            .pid = p,
            .started = if (poltergeistpkg.process_info.of(p)) |info| info.started else null,
        } else null;
        self.poltergeist.noteAgentHere(id, here, program, now_ms);
        // An agent that has come to this terminal starts its quiet now
        // (task 2411): an agent that went and came back between two of the
        // clock's looks must not carry its old silence with it.
        if (here and !was_here) self.noteHeard(id);
    }
    // A connection gone while its program runs (task 1668, #83).
    _ = self.poltergeist.considerLinks(now_ms, self, poltergeistProgramRuns);
}

/// Whether the program an agent connected from is still running in that
/// terminal, for `Bus.considerLinks`. Three ways it is not, each of which
/// once reported a Codex that had quit with `/exit` as still running
/// (#1669 c1669-12): the terminal's shell is back at its prompt; the
/// process has exited and is a zombie nobody has collected; or the number
/// now belongs to a process that started at another time. A process that
/// cannot be read is taken as not running: this report is only worth
/// making when it is certain.
///
/// **With no program to look at** -- every agent on Windows, where no pid
/// is read (`agent_cli.Sighting.pid`), and one that never said -- only the
/// shell can answer, and only "no": back at its prompt is gone, anything
/// else is not known to have gone, and is answered as still running so
/// that nothing is concluded from it (task 1762).
fn poltergeistProgramRuns(ctx: *anyopaque, id: poltergeistpkg.Bus.Id, maybe: ?poltergeistpkg.Bus.Program) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.findSurfaceByID(id)) |surface| if (surface.shellIdle()) return false;
    const program = maybe orelse return true;
    const info = poltergeistpkg.process_info.of(program.pid) orelse return false;
    if (info.zombie) return false;
    if (program.started) |started| if (info.started != started) return false;
    return true;
}

/// Find every plugin that is installed and switched on.
///
/// Once, at startup, and again whenever `reloadPlugins` throws the arena
/// away. A plugin that will not load is skipped with a warning rather than
/// taken as fatal: the terminal has to work whether or not a notification
/// channel does.
///
/// Enumerated rather than named in the config: a plugin's own file says
/// whether it is on (`Plugin.Settings`), so there is nothing for the main
/// config to list, and a settings UI can switch one on without editing a
/// file the user hand-writes.
///
/// Both places are read, the user's first. A plugin shipped with Polter and
/// one written by hand are the same thing to everything downstream; only the
/// user's copy wins when the names collide, so a shipped plugin can be
/// replaced without touching the bundle.
pub fn ensurePlugins(self: *App) void {
    if (self.poltergeist_plugin_arena != null) return;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    const alloc = arena.allocator();

    const io = global.io();

    var environ_map = global.environMap() catch {
        arena.deinit();
        return;
    };
    defer environ_map.deinit();

    const found = self.scanPlugins(alloc, io, &environ_map, false);
    // The first walk has said any strays; the walks after it do not.
    self.poltergeist_strays_said = true;

    // The manifests alone are kept. The settings are read again where they
    // are used -- `ensureResidents` at the moment it starts a child, the
    // notification path on every send -- because a parameter changed while
    // Polter runs must take effect without a restart.
    const manifests = alloc.alloc(poltergeistpkg.Plugin.Manifest, found.len) catch {
        arena.deinit();
        return;
    };
    for (found, 0..) |f, i| manifests[i] = f.manifest;

    // The title and screen declarations, from every plugin installed. A
    // second walk rather than a flag on the first: what runs is the
    // switched-on ones, and the first walk is that list. Reading a title or
    // a screen starts nothing and writes nothing.
    var says: std.ArrayListUnmanaged(poltergeistpkg.Plugin.Manifest) = .empty;
    for (self.scanPlugins(alloc, io, &environ_map, true)) |f| {
        if (f.manifest.title_says.awaiting_approval.len == 0 and
            !f.manifest.screen_says.declared() and
            !f.manifest.startup_says.declared()) continue;
        says.append(alloc, f.manifest) catch break;
    }

    // Where each agent CLI stands (task 1677), for the control room's
    // start screen: a walk of its own, as `agent_cli.survey` is the one
    // definition of "can be started here".
    var standings: std.ArrayListUnmanaged(poltergeistpkg.ControlRoom.CliStanding) = .empty;
    for (poltergeistpkg.agent_cli.survey(alloc, io, &environ_map)) |f| {
        standings.append(alloc, .{ .key = f.adapter.key, .standing = switch (f.standing) {
            .ok => .ok,
            .off => .plugin_off,
            .cannot_run => .cannot_run,
        } }) catch break;
    }

    self.poltergeist_plugins = manifests;
    self.poltergeist_says = says.items;
    self.poltergeist_cli_standings = standings.items;
    self.poltergeist_plugin_arena = arena;

    log.info(
        "poltergeist: {d} plugin(s) ready -- {d} on chat, {d} on notifications, " ++
            "{d} on provisioning",
        .{
            manifests.len,
            poltergeistpkg.notify.count(manifests, .chat),
            poltergeistpkg.notify.count(manifests, .terminal_quiet),
            poltergeistpkg.notify.count(manifests, .provision),
        },
    );
}

/// One plugin as found on disk, together with what the user configured for
/// it.
///
/// Kept as one thing because everything that walks the plugin directories
/// wants both, and reading the settings a second time somewhere else is how
/// the two come to disagree about what is switched on.
const Installed = struct {
    manifest: poltergeistpkg.Plugin.Manifest,
    settings: poltergeistpkg.Plugin.Settings,
    /// Its directory, when it is in the bundle's plugin directory and that
    /// directory's `SHIPPED` does not name it (task 1683): left over from
    /// another release. Null for a shipped plugin, for one in the user's
    /// own directory, and for any in a bundle with no list to hold it to.
    /// It is loaded all the same; `plugin_list` says so.
    stray: ?[]const u8,
};

/// Every plugin in the search path, nearest first.
///
/// `keep_disabled` is the whole reason this is separate from
/// `ensurePlugins`: what *runs* is only the plugins that are switched on,
/// but the question `plugin_list` answers is "what is here and is it on",
/// and a plugin that is off is exactly what somebody is asking about.
///
/// Everything returned belongs to `arena`.
fn scanPlugins(
    self: *App,
    arena: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    keep_disabled: bool,
) []const Installed {
    var found: std.ArrayListUnmanaged(Installed) = .empty;

    // Two dedupes, and they are not the same one twice. `dirs` is what makes
    // a user's copy of a shipped plugin win: the search path is nearest
    // first, so the second directory of a name is the one to drop.
    var dirs: std.StringHashMapUnmanaged(void) = .empty;

    // `keys` is the one that matters. Everything downstream keys on
    // `manifest.key` and not on the directory: `pluginSettings` reads
    // `<key>.json` and `archiveFor` looks one up by key. Two directories
    // whose manifests claim one key would therefore share a settings file
    // and start two resident copies of one plugin, each subscribing and
    // each storing every message -- see `dev-docs/poltergeist/plugins.md`.
    var keys: std.StringHashMapUnmanaged([]const u8) = .empty;

    for (poltergeistpkg.Plugin.searchBases(arena, io, environ_map)) |b| {
        const base = b.path;
        var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        // What this release says it put here, read once per directory: only
        // the bundle's has a list, and a bundle with none (an older release,
        // a build tree) holds nothing to it.
        const shipped: poltergeistpkg.Plugin.Shipped = if (b.bundled)
            poltergeistpkg.Plugin.Shipped.read(arena, io, base)
        else
            .unknown;

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            // A leading underscore means "this directory is not a plugin".
            // `plugins/_sdk/` is the thin client a plugin author copies
            // from; it has no manifest by design, and warning about it on
            // every scan would train people to ignore the one warning that
            // means a real plugin failed to load.
            if (entry.name.len > 0 and entry.name[0] == '_') continue;

            if (dirs.contains(entry.name)) continue;

            const name = arena.dupe(u8, entry.name) catch continue;
            dirs.put(arena, name, {}) catch {};

            const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ base, name }) catch continue;

            // Not one this release shipped: said, once per process, and
            // loaded all the same -- refusing it would be a behaviour change
            // the person did not ask for, and the line says how to undo it.
            const stray: ?[]const u8 = switch (shipped.of(b.bundled, name)) {
                .stray => path,
                .user, .unknown, .shipped => null,
            };
            if (stray != null and !self.poltergeist_strays_said) log.warn(
                "plugin {s} in the bundled plugins directory is not part of this " ++
                    "release (probably left over from an older one unpacked over it); " ++
                    "delete {s}",
                .{ name, path },
            );

            const manifest = poltergeistpkg.Plugin.load(arena, io, path) catch |err| {
                log.warn("poltergeist: plugin {s} would not load err={}", .{ name, err });
                continue;
            };

            if (keys.get(manifest.key)) |first| {
                log.warn(
                    "poltergeist: {s} and {s} both claim the key {s}; the second is " ++
                        "passed over, because two copies of one plugin would share " ++
                        "its settings and its cursor",
                    .{ first, path, manifest.key },
                );
                continue;
            }
            keys.put(arena, manifest.key, path) catch {};

            const settings = self.pluginSettings(arena, io, environ_map, manifest.key);
            if (!keep_disabled and !settings.enabled) {
                log.debug("poltergeist: plugin {s} is installed but off", .{manifest.key});
                continue;
            }

            // **Nothing to run here is not a failure, and it is known now.**
            // A plugin that declares only a `.sh` cannot start on Windows;
            // said here, once, it costs a line. Left to the spawn it becomes
            // `error.InvalidExe`, a back-off, a restart and the same failure
            // again -- a loop that from the plugin's side is indistinguishable
            // from idling. See `Plugin.Manifest.runnable`.
            //
            // Only for plugins that are switched on: an unsupported plugin
            // nobody enabled has nothing to say.
            if (!manifest.runnable) {
                log.info(
                    "poltergeist: plugin {s} declares nothing this system can run " ++
                        "({s}); installed and enabled, but not started",
                    .{ manifest.key, manifest.exec },
                );
                continue;
            }

            found.append(arena, .{
                .manifest = manifest,
                .settings = settings,
                .stray = stray,
            }) catch continue;
        }
    }

    return found.items;
}

/// Read the plugin directories again, because something about them changed.
///
/// Safe to do while archives are running, and that rests on two facts rather
/// than on hope: `Archive.Options` says every field is copied, so a resident
/// plugin borrows nothing from the arena being thrown away; and both readers
/// of `poltergeist_plugins` -- `notifyUser` and `ensureResidents` -- run on the
/// app thread, which is the thread this is called on.
pub fn reloadPlugins(self: *App) void {
    // Cleared before the arena goes, not after. `ensurePlugins` has early
    // returns -- no environment, no memory -- and none of them assigns a new
    // list; the other order would leave this slice pointing into freed
    // memory for whichever notification came next.
    self.poltergeist_plugins = &.{};
    self.poltergeist_says = &.{};
    self.poltergeist_cli_standings = &.{};
    if (self.poltergeist_plugin_arena) |*a| a.deinit();
    self.poltergeist_plugin_arena = null;

    self.ensurePlugins();

    // A plugin switched on or off can add or take away an agent CLI, and
    // the role menus offer only the CLIs this cache lists (#1670) -- while
    // a role started without a CLI is matched against the plugin
    // directories afresh (#1667). Left alone, the menu would go on offering
    // a CLI whose plugin is off until the next restart. A cache nobody has
    // asked for stays unread.
    const io = global.io();
    if (self.poltergeist_agent_clis.askedFor(io)) self.poltergeist_agent_clis.refresh(io);
}

/// A terminal's program set its title (task 1656). Asked of every title,
/// and answered from the plugins' declarations: a CLI with no hooks that
/// says in its title that it waits on an approval is put in the
/// supervisor's box the way a hook would put it, and stops being reported
/// so the moment the title changes.
///
/// On the app thread, from `Surface.handleMessage` -- which is also where
/// the bus is read and written everywhere else.
pub fn poltergeistTitle(self: *App, id: poltergeistpkg.Bus.Id, title: []const u8) void {
    self.ensurePlugins();
    const waits_for = poltergeistpkg.Plugin.titleAwaitsApproval(self.poltergeist_says, title);
    const now_ms = self.poltergeistElapsedMs();
    const raised = self.poltergeist.noteTitle(id, waits_for, title, now_ms) catch |err| {
        log.warn("poltergeist: could not note the title of {x} err={}", .{ id, err });
        return;
    };
    if (raised) {
        log.info("poltergeist: {x} title says it awaits approval ({s})", .{ id, waits_for orelse "" });
        self.deliverPoltergeistNotices(now_ms);
    }
}

/// One plugin's own settings file, nearest first.
///
/// The user's `<config>/polter/plugins/<key>.json` is looked at first, and a
/// `settings.json` sitting inside the plugin's own directory after it -- so a
/// plugin a release ships can arrive already configured, while anything the
/// user has said about it wins for good. Only the first file found is read;
/// `Plugin.Settings.readFirst` says why the two are not merged, and the short
/// version is that merging cannot tell "switched off" from "never
/// configured", which would let an upgrade switch a plugin back on.
///
/// The fallback walks the whole search path rather than the bundle alone,
/// because a plugin directory dropped into the config directory by hand is
/// installed the same way and may carry the same file.
///
/// Nothing here writes: the settings file `plugin_configure` writes is still
/// the one in the config directory and only that one.
fn pluginSettings(
    self: *App,
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) poltergeistpkg.Plugin.Settings {
    _ = self;
    return poltergeistpkg.Plugin.settingsFor(alloc, io, environ_map, key);
}

fn findPluginDir(
    self: *App,
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) ?[]const u8 {
    _ = self;

    if (internal_os.xdg.config(
        io,
        alloc,
        environ_map,
        .{ .subdir = "polter/plugins" },
    )) |base| {
        const dir = std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, key }) catch return null;
        if (std.Io.Dir.cwd().openDir(io, dir, .{})) |*d| {
            var handle = d.*;
            handle.close(io);
            return dir;
        } else |_| {}
    } else |_| {}

    const resources = internal_os.resourcesDir(alloc) catch return null;
    const app_path = resources.app_path orelse return null;

    const dir = std.fmt.allocPrint(alloc, "{s}/polter/plugins/{s}", .{ app_path, key }) catch
        return null;
    if (std.Io.Dir.cwd().openDir(io, dir, .{})) |*d| {
        var handle = d.*;
        handle.close(io);
        return dir;
    } else |_| {}

    return null;
}

/// Write down what tomorrow needs, now.
///
/// Called after anything that changes the arrangement -- a group made, a
/// member added or removed, a brief written, a role changed, a terminal
/// held to its work or let go.
/// Not at exit: the cases this exists for are the machine shutting down
/// and Polter being killed, and neither of those runs an exit path.
///
/// Cheap enough to do eagerly: a few hundred bytes, and these events are
/// rare. Skipped entirely when there is nowhere to write.
pub fn saveSession(self: *App) void {
    const path = self.poltergeist_session_path orelse return;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const snapshot = self.sessionSnapshot(alloc) catch |err| {
        log.warn("poltergeist: could not gather the session err={}", .{err});
        return;
    };

    poltergeistpkg.Session.write(alloc, global.io(), path, snapshot);
}

/// Everything worth writing down, borrowed from `alloc`.
fn sessionSnapshot(
    self: *App,
    alloc: Allocator,
) Allocator.Error!poltergeistpkg.Session.Snapshot {
    const live = try self.liveTerminals(alloc);
    const names = try self.chat.groupsFor(alloc, poltergeistpkg.Chat.user_id, live);

    var groups: std.ArrayListUnmanaged(poltergeistpkg.Session.Group) = .empty;
    for (names) |name| {
        const ids = self.chat.membersOf(alloc, name) catch continue;

        var members: std.ArrayListUnmanaged(poltergeistpkg.Session.Member) = .empty;
        for (ids) |id| {
            // The user is in every group and has no terminal of their own,
            // so there is nothing about them to write down.
            if (id == poltergeistpkg.Chat.user_id) continue;

            // Asked again here, not only when the member was added and
            // when it last spoke. A terminal added in the second before
            // its shell reported a working directory had nothing to
            // record, and a supervisor -- which mostly reads -- may never
            // post at all, so it would keep that blank for good. This is
            // the moment the record is being written down, which makes it
            // the moment to make it as true as we can.
            self.refreshFooting(name, id);

            const footing = self.chat.footingOf(name, id) orelse continue;
            const entry = self.poltergeist.get(id);

            try members.append(alloc, .{
                .cwd = footing.cwd,
                .title = footing.title,
                .role = if (entry) |e| e.role else .none,
                .held = if (entry) |e| e.held else false,
            });
        }

        try groups.append(alloc, .{
            .name = name,
            .brief = self.chat.briefOf(name) catch "",
            .members = members.items,
        });
    }

    // Every terminal on screen, not only the ones in a group. A terminal
    // nobody put under watch has no other record anywhere, so leaving it
    // out means it simply vanishes at the restart -- and it may be the
    // shell somebody had a build running in, which is worth as much to
    // them as any agent.
    var terminals: std.ArrayListUnmanaged(poltergeistpkg.Session.Terminal) = .empty;
    if (poltergeistOpenTerminals(self, alloc)) |places| {
        for (places) |place| {
            if (place.cwd.len == 0 and place.title.len == 0) continue;
            try terminals.append(alloc, .{
                .cwd = place.cwd,
                .title = place.title,
            });
        }
    } else |err| {
        log.warn("poltergeist: could not list terminals to save err={}", .{err});
    }

    return .{ .groups = groups.items, .terminals = terminals.items };
}

/// Open the chat log if the config wants it and it is not open yet.
///
/// Same reasoning as the socket: `updateConfig` runs only on a config
/// *reload*, which neither apprt does at launch, so waiting for it would
/// mean nothing was written down until somebody reloaded by hand.
/// The limits of everything the sweeper keeps, from the configuration.
const SweepLimits = struct {
    const Limits = poltergeistpkg.Retention.Limits;
    logs: Limits = .unlimited,
    shots: Limits = .unlimited,
    group: Limits = .unlimited,
    project: Limits = .unlimited,
    other: Limits = .unlimited,
    /// False until a configuration has been read: until then nothing is
    /// swept rather than everything being kept by the defaults' absence.
    known: bool = false,

    fn from(config: *const Config) SweepLimits {
        return .{
            .logs = .fromConfig(config.@"poltergeist-log-keep-days".value, config.@"poltergeist-log-max-mb".value),
            .shots = .fromConfig(config.@"poltergeist-shots-keep-days".value, config.@"poltergeist-shots-max-mb".value),
            .group = .fromConfig(std.math.maxInt(u32), config.@"poltergeist-terminal-log-group-max-mb".value),
            .project = .fromConfig(config.@"poltergeist-terminal-log-project-keep-days".value, config.@"poltergeist-terminal-log-project-max-mb".value),
            .other = .fromConfig(config.@"poltergeist-terminal-log-keep-days".value, config.@"poltergeist-terminal-log-max-mb".value),
            .known = true,
        };
    }
};

/// Start the sweeper, once, in the state directory. Called as each
/// terminal starts; only the first does anything. Never by a command
/// Polter runs: those do not have an `App`.
pub fn ensureSweeper(self: *App) void {
    if (self.sweeper != null) return;

    const io = global.io();
    var environ_map = global.environMap() catch return;
    defer environ_map.deinit();
    const state_dir = internal_os.xdg.state(io, self.alloc, &environ_map, .{ .subdir = "polter" }) catch |err| {
        log.warn("poltergeist: no state directory to keep tidy err={}", .{err});
        return;
    };
    self.sweep_state_dir = state_dir;
    self.sweeper = .init(self.alloc, io);
    // Held until the backfill's lines are written, if one is reading.
    if (self.sweeper) |*w| {
        w.held = self.backfill_pending;
        w.on_waiting = .{ .f = sweeperWaitingChanged, .ctx = self };
    }
    self.configureSweeper();
    if (self.sweeper) |*w| w.start() catch |err| {
        log.warn("poltergeist: could not start the sweeper err={}", .{err});
    };
}

/// Hand the sweeper what it is to keep, now: the limits, and where the
/// host puts screenshots.
fn configureSweeper(self: *App) void {
    const w = if (self.sweeper) |*v| v else return;
    const state_dir = self.sweep_state_dir orelse return;
    if (!self.sweep_limits.known) return;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const shots_dir: ?[]const u8 = shots: {
        const reply = poltergeistScreenshotHost(self, arena.allocator(), poltergeistpkg.Chat.user_id, .{
            .op = .directory,
            .spec = poltergeistpkg.screenshot.directory_spec,
        }, "") catch break :shots null;
        break :shots switch (reply) {
            .done => |json| poltergeistpkg.screenshot.directoryOf(arena.allocator(), json),
            else => null,
        };
    };

    if (self.sweep_shots_dir) |d| self.alloc.free(d);
    self.sweep_shots_dir = if (shots_dir) |d| self.alloc.dupe(u8, d) catch null else null;

    const l = self.sweep_limits;
    // A change of limits while the first sweep waits is the person
    // answering the notice: they have said what to keep instead.
    if (w.waitingBytes() != null and !std.meta.eql(l, self.sweep_limits_seen)) {
        self.agreeToRetention("settings-changed");
    }
    self.sweep_limits_seen = l;
    w.configure(.{
        .state_dir = state_dir,
        .shots_dir = shots_dir,
        .logs = l.logs,
        .shots = l.shots,
        .group = l.group,
        .project = l.project,
        .other = l.other,
    }) catch |err| log.warn("poltergeist: could not configure the sweeper err={}", .{err});
}

pub fn ensureChatLog(self: *App, want: bool) void {
    if (!want or self.chat_log != null) return;

    const io = global.io();
    var environ_map = global.environMap() catch return;
    defer environ_map.deinit();

    const state_dir = internal_os.xdg.state(
        io,
        self.alloc,
        &environ_map,
        .{ .subdir = "polter" },
    ) catch |err| {
        log.warn("poltergeist: no state directory for the chat log err={}", .{err});
        return;
    };
    defer self.alloc.free(state_dir);

    // **Before any log is opened.** A rename the last run did not finish
    // leaves some of a group's records under the old name and some under
    // the new, and a log opened on that would read half of them. Finishing
    // it first means nothing here ever sees the middle.
    //
    // If it cannot be finished the logs stay closed -- the same as having
    // no state directory -- rather than opening on records that are in two
    // places. The intent is left for a person to read.
    //
    // **`Locked` is waited for.** The lock is the kernel's, so it is only
    // ever held by a process that is alive -- another Polter in the middle
    // of renaming a group, which is a matter of seconds. Giving up at once
    // is what once made every group vanish on a start that came a moment
    // too early. Once, and not for every window.
    const wait: poltergeistpkg.GroupRename.Wait = if (self.poltergeist_waited_for_rename)
        .{ .max_ms = 0 }
    else
        .{};
    self.poltergeist_waited_for_rename = true;
    if (poltergeistpkg.GroupRename.recoverWaiting(.{
        .alloc = self.alloc,
        .io = io,
        .state_dir = state_dir,
    }, wait)) |done| {
        if (done.finished) log.info("poltergeist: finished a group rename the last run left", .{});
        if (done.abandoned) log.warn("poltergeist: dropped a group rename that could not be redone", .{});
    } else |err| {
        log.warn("poltergeist: a group rename is unfinished and could not be continued err={}; the logs stay closed", .{err});
        self.noteLogProblem(state_dir, poltergeistpkg.GroupRename.startupProblem(err));
        return;
    }

    self.chat_log = poltergeistpkg.ChatLog.open(self.alloc, io, state_dir) catch |err| {
        log.warn("poltergeist: could not open the chat log err={}", .{err});
        self.noteLogProblem(state_dir, "the chat log could not be opened");
        return;
    };
    self.clearLogProblem();
    self.poltergeist_state_dir = self.alloc.dupe(u8, state_dir) catch null;
    if (self.poltergeist_worktrees == null) {
        const file = std.fs.path.join(self.alloc, &.{ state_dir, "worktrees.json" }) catch null;
        defer if (file) |f| self.alloc.free(f);
        if (file) |f| if (poltergeistpkg.worktree.Ledger.init(self.alloc, f)) |ledger| {
            self.poltergeist_worktrees = ledger;
            self.poltergeist_worktrees.?.load(io);
        } else |_| {};
    }

    // Same directory, and the log having opened means it exists.
    if (self.poltergeist_session_path == null) {
        self.poltergeist_session_path = poltergeistpkg.Session.defaultPath(
            self.alloc,
            state_dir,
        ) catch null;

        if (self.poltergeist_session_path) |p| {
            self.poltergeist_recall = .open(self.alloc, io, p);
        }
    }

    // The panel, out of the same state directory and in the same shape --
    // one directory per group, one file per day. **Read back immediately**,
    // because a panel that is only written is the blank screen at nine the
    // next morning that this whole thing exists to prevent.
    if (poltergeistpkg.TaskLog.open(self.alloc, io, state_dir)) |l| {
        self.task_log = l;
        if (self.task_log) |*t| t.restore(&self.tasks);
    } else |err| {
        log.warn("poltergeist: could not open the task log err={}", .{err});
    }

    // The resource history (task 1993): written only, like the stats.
    if (poltergeistpkg.ResourceHistory.File.init(self.alloc, io, state_dir)) |f| {
        self.resource_history_file = f;
        // The half hours the last run was stopped in, before any of ours.
        if (self.resource_history_file) |*h| {
            h.recover(self.alloc);
            if (h.readNames(self.alloc)) |bytes| {
                defer self.alloc.free(bytes);
                if (poltergeistpkg.ResourceNames.decode(self.alloc, bytes)) |n| {
                    self.resource_names.deinit(self.alloc);
                    self.resource_names = n;
                } else |_| {}
            }
        }
    } else |err| {
        log.warn("poltergeist: could not set up the resource history err={}", .{err});
    }

    // Beside it, and never read back here: the hourly snapshot is for the
    // morning, and the morning reads it with `cat`.
    if (poltergeistpkg.StatsLog.open(self.alloc, io, state_dir)) |l| {
        self.stats_log = l;
    } else |err| {
        log.warn("poltergeist: could not open the stats log err={}", .{err});
    }

    // Who was in which group: what a transcript is found by later.
    if (poltergeistpkg.SessionLog.open(self.alloc, io, state_dir)) |l| {
        self.session_log = l;
        // Groups from before this record: who was in them, as far as the
        // chat and the panel say. Read on a thread of its own; written
        // here when it is done (`storageTick`).
        if (std.heap.page_allocator.dupe(u8, state_dir)) |dir| {
            if (std.Thread.spawn(.{}, backfillMain, .{ self, dir })) |t| {
                self.backfill_thread = t;
                self.backfill_pending = true;
            } else |err| {
                std.heap.page_allocator.free(dir);
                log.warn("poltergeist: could not start reading the older groups err={}", .{err});
            }
        } else |_| {}
    } else |err| {
        log.warn("poltergeist: could not open the session log err={}", .{err});
    }
    if (poltergeistpkg.TerminalMeta.open(self.alloc, io, state_dir)) |m| {
        self.terminal_meta = m;
    } else |err| {
        log.warn("poltergeist: could not open the terminal notes err={}", .{err});
    }
    if (self.reclaim == null) self.reclaim = readReclaim(self.alloc, io, state_dir);
    // Which session each terminal that is not here any more ran, once at
    // startup: the performance page draws one row per session, and the ids
    // of earlier runs are exactly what it has to fold together (task 2234).
    self.seedResourceSessions(io, state_dir);

    // And the groups those tasks are filed under. **Before this, the panel
    // came back and the group it belongs to did not** -- last night's tasks
    // on screen under a group that no longer existed. The shells go back
    // first-class, out of the record directories that are already there.
    //
    // Names and notes only. Nobody is put back in a group here; who was in
    // it is a judgement about which terminal on screen is which, and that is
    // the supervisor's to make out of `session_recall`. See `GroupLog.zig`.
    // The one exception is not a judgement: an agent that says the session
    // an old member ended on goes back in (`reclaimSession`, task 1978).
    if (poltergeistpkg.GroupLog.open(self.alloc, io, state_dir)) |l| {
        self.group_log = l;
        self.restoreChatGroups();
    } else |err| {
        log.warn("poltergeist: could not open the group log err={}", .{err});
    }

    // The log has just opened, which is the earliest moment there is
    // anything for an archive plugin to follow.
    self.ensureResidents();
}

/// Remember that the logs are closed and why, and tell the person once.
///
/// Called with the state directory so the text can name the place to look.
/// What it says is the same to the supervisor (`group_list`) and to the
/// person: nothing was lost, the groups on disk are not loaded, nothing is
/// being recorded, and what to do about it.
fn noteLogProblem(self: *App, state_dir: []const u8, why: []const u8) void {
    const text = poltergeistpkg.GroupRename.problemText(self.alloc, state_dir, why) catch return;

    if (self.poltergeist_log_problem) |old| self.alloc.free(old);
    self.poltergeist_log_problem = text;

    // **Queued, never shown from here.** This runs inside `Surface.init`
    // (through `ensureChatLog`), where `addSurface` has already put the
    // surface in the list but its core does not exist yet; `poltergeistAlert`
    // would reach for `surfaces.items[0].core()` and take it for a live
    // terminal. On Windows that was the host dying at start with 0xc0000005
    // whenever a rename could not be continued. The queue is drained at the
    // end of that same `Surface.init` (`flushPoltergeistAlerts`), when there
    // is somewhere to print.
    //
    // **Once per window**: every window's init runs `ensureChatLog` and gets
    // here again, so every window is told, not only the first. With no window
    // there is no `Surface.init` and so no call at all; the problem is
    // recorded the moment the first window opens, and `group_list` says so
    // to anyone who asks before that.
    if (self.alloc.dupe(u8, text)) |line| {
        self.poltergeist_alerts.append(self.alloc, line) catch self.alloc.free(line);
    } else |_| {}

    // **And once more, later.** What is printed during `Surface.init` goes
    // into the terminal before the program in it has started, and on Windows
    // the pseudoconsole that starts it clears the screen as it does: the
    // plugin line that printed a second later survived, this one did not.
    // (That is the reading of a real-machine report, not something seen from
    // here; the delay is `late_alert_ms`, and what to look for on the
    // machine is in the task report.) Posted from a thread, to the mailbox,
    // the way a plugin's failure is -- the path already known to reach the
    // screen -- and shown by `poltergeistAlert`, which is safe by then.
    if (self.poltergeist_late_alert == null) {
        if (self.alloc.dupe(u8, text)) |line| {
            if (std.Thread.spawn(.{}, lateAlertMain, .{ self, line })) |t| {
                self.poltergeist_late_alert = t;
            } else |_| self.alloc.free(line);
        } else |_| {}
    }
}

/// How long after the problem is found before it is said again. Longer than
/// the moment a shell takes to start and clear its screen, short enough to
/// be read as part of starting up. **A guess until it is measured on the
/// Windows machine**; the number lives here so that adjusting it is one line.
const late_alert_ms: i64 = 3000;

fn lateAlertMain(self: *App, line: []u8) void {
    defer self.alloc.free(line);

    var waited: i64 = 0;
    while (waited < late_alert_ms) : (waited += 100) {
        if (self.poltergeist_stopping.load(.acquire)) return;
        std.Io.sleep(global.io(), .fromMilliseconds(100), .awake) catch return;
    }
    if (self.poltergeist_stopping.load(.acquire)) return;

    submitPoltergeistAlert(@ptrCast(self), line);
}

/// Stop recording, and say why. Used when a rename is left to be finished at
/// the next start: see `chatRename`.
fn closeRecordsAfterDeferredRename(self: *App, state_dir: []const u8) void {
    // `state_dir` is `poltergeist_state_dir`, which is freed below.
    const dir = self.alloc.dupe(u8, state_dir) catch return;
    defer self.alloc.free(dir);

    if (self.chat_log) |*l| l.deinit();
    self.chat_log = null;
    if (self.task_log) |*l| l.deinit();
    self.task_log = null;
    if (self.stats_log) |*l| l.deinit();
    self.stats_log = null;
    if (self.session_log) |*l| l.deinit();
    self.session_log = null;
    if (self.terminal_meta) |*m| m.deinit();
    self.terminal_meta = null;
    if (self.group_log) |*l| l.deinit();
    self.group_log = null;
    if (self.poltergeist_state_dir) |p| self.alloc.free(p);
    self.poltergeist_state_dir = null;

    self.noteLogProblem(dir, poltergeistpkg.GroupRename.startupProblem(error.Deferred));
}

fn clearLogProblem(self: *App) void {
    if (self.poltergeist_log_problem) |old| self.alloc.free(old);
    self.poltergeist_log_problem = null;
}

/// `Host.logProblem`.
fn logProblem(ctx: *anyopaque, alloc: Allocator) anyerror!?[]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const text = self.poltergeist_log_problem orelse return null;
    return try alloc.dupe(u8, text);
}

/// Put last night's group shells back into the chat.
///
/// Each one is a name, a note, and when anything was last said in it.
/// Nobody is added: a restored group has only the person at the keyboard
/// in it, which makes it inactive, which is exactly the state "there is a
/// group here and nobody is working in it" should look like. A supervisor
/// taking it up again is what `group_add` is for, and that is the step
/// that needs a judgement nobody else can make.
///
/// A shell whose name the chat will not accept, or that is already there,
/// is skipped. Both are answers rather than failures: the first is a
/// directory somebody made by hand, and the second means what is in memory
/// is newer than what is on disk.
fn restoreChatGroups(self: *App) void {
    const gl = if (self.group_log) |*v| v else return;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const shells = gl.restore(alloc) catch |err| {
        log.warn("poltergeist: could not read the group list err={}", .{err});
        return;
    };

    // Newest first, and stopped short of the ceiling.
    //
    // **The list on disk never expires and `Chat.max_groups` is 32.** Left
    // alone, a machine with a few weeks of history would come up with every
    // slot filled by whatever order the filesystem happened to hand the
    // directories back in, and the first `group_create` of the morning
    // would be refused -- a supervisor unable to make a group, for a reason
    // nothing on screen explains.
    //
    // So the room is left on purpose and the groups that lose are the ones
    // last spoken in, which is the same order the list is shown in. The
    // older ones are still on disk with every word in them; what they are
    // short of is a way to be picked out again, and that is worth writing
    // down rather than leaving to be discovered.
    std.mem.sort(poltergeistpkg.GroupLog.Shell, shells, {}, newestShellFirst);

    const ceiling = self.chat.config.max_groups -| restore_reserve;

    // Read at most once, and only if some group needs it.
    var last_night: LastNight = .unread;

    var back: usize = 0;
    for (shells) |shell| {
        if (back >= ceiling) break;
        self.chat.restoreShell(shell.name, shell.brief, shell.last_ms, shell.marks) catch continue;
        _ = self.chat.setLastSupervisor(shell.name, shell.supervisor) catch .same;
        _ = self.chat.setProject(shell.name, shell.project) catch false;
        self.chat.restoreProjectNotNow(shell.name, shell.project_not_now);
        if (shell.supervisor.dir.len == 0) self.backfillSupervisorDir(alloc, gl, shell.name, &last_night);
        back += 1;
    }

    if (back > 0) log.info("poltergeist: {d} group(s) back from last night", .{back});
    if (shells.len > back) log.info(
        "poltergeist: {d} older group(s) left on disk, room kept for new ones",
        .{shells.len - back},
    );
}

/// The session snapshot the run before left (`Session`), read when the
/// first group needs it. `none` is "looked, and there is nothing to read".
const LastNight = union(enum) {
    unread,
    none,
    read: poltergeistpkg.Session.Snapshot,
};

/// A group that came back with no directory for its supervisor: every one
/// written before that was kept. If the session snapshot of the run before
/// still has the terminal that was this group's supervisor, where it stood
/// is taken as the directory -- **once, marked as a guess**
/// (`dir_from: session_snapshot`), and written down so that the next start
/// does not depend on a file the first change of this run overwrites.
///
/// Only a directory. Nothing else about that supervisor was ever recorded,
/// and none of it is made up: no role, no CLI, no session, and `heard_ms`
/// stays null -- "no supervisor was ever recorded" is still the truth.
///
/// With more than one supervisor in the group last night, the first as the
/// snapshot lists them: which of them minded the group is not written
/// anywhere, and the guess is said to be one.
fn backfillSupervisorDir(
    self: *App,
    arena: Allocator,
    gl: *poltergeistpkg.GroupLog,
    group: []const u8,
    last_night: *LastNight,
) void {
    if (last_night.* == .unread) {
        const path = self.poltergeist_session_path orelse {
            last_night.* = .none;
            return;
        };
        last_night.* = if (poltergeistpkg.Session.read(arena, global.io(), path)) |snap|
            .{ .read = snap }
        else
            .none;
    }
    const snap = switch (last_night.*) {
        .read => |v| v,
        .unread, .none => return,
    };
    const dir = poltergeistpkg.Session.supervisorDirIn(snap, group) orelse return;

    var guessed = self.chat.lastSupervisorOf(group);
    guessed.dir = dir;
    guessed.dir_from = .session_snapshot;
    const change = self.chat.setLastSupervisor(group, guessed) catch return;
    if (change == .who) gl.supervisor(group, self.chat.lastSupervisorOf(group));
    log.info("poltergeist: a group with no supervisor directory took one from last run's session snapshot", .{});
}

/// How many of `Chat.max_groups` are held back from the restore, so the
/// supervisor can always make groups on a machine with a long history.
const restore_reserve: usize = 8;

fn newestShellFirst(
    _: void,
    a: poltergeistpkg.GroupLog.Shell,
    b: poltergeistpkg.GroupLog.Shell,
) bool {
    if (a.last_ms != b.last_ms) return a.last_ms > b.last_ms;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Start every plugin that is installed, switched on, and subscribed to
/// something.
///
/// One thread and one child process each, for as long as the app is up.
/// There is no longer a kind to select on: what starts is what has a
/// non-empty `wants.events`, and what a plugin then receives is whichever
/// of those events it asked for. See `poltergeist/Resident.zig` for what
/// being resident costs and `dev-docs/poltergeist/plugins.md` for the protocol.
///
/// Nothing here fails quietly. A plugin that will not start, or that
/// subscribes to nothing and so has nothing to be given, is named in a
/// warning -- a plugin that silently does not run is the one failure the
/// whole feature is supposed to be proof against.
pub fn ensureResidents(self: *App) void {
    if (self.poltergeist_residents_started) return;

    // Asked for rather than assumed, and this matters: on the first surface
    // `ensureChatLog` runs *before* `ensurePlugins`, so the plugin list
    // would still be empty here and every archive would silently never
    // start. Loading is guarded on its own arena and costs nothing the
    // second time, which is cheaper than depending on somebody else's call
    // order.
    self.ensurePlugins();
    if (self.poltergeist_plugin_arena == null) return;

    // Set before the loop, not after: a failure part way through must not
    // leave this to be tried again and start a second copy of everything
    // that did work.
    self.poltergeist_residents_started = true;

    const io = global.io();

    var environ_map = global.environMap() catch |err| {
        log.warn("poltergeist: no environment for the archive err={}", .{err});
        return;
    };
    defer environ_map.deinit();

    var scratch: std.heap.ArenaAllocator = .init(self.alloc);
    defer scratch.deinit();
    const alloc = scratch.allocator();

    for (self.poltergeist_plugins) |manifest| {
        // Read again rather than remembered: `ensurePlugins` looks only at
        // whether a plugin is switched on and throws its parameters away.
        // A resident plugin's database lives in those.
        const settings = self.pluginSettings(alloc, io, &environ_map, manifest.key);
        _ = self.startResident(manifest, settings);
    }

    // Only when there is something to say, so the ordinary install -- which
    // has no resident plugin at all -- stays quiet.
    //
    // **"resident", not "archive", and that is a correction rather than a
    // rewording.** This counts `poltergeist_residents`, which is every plugin
    // that subscribes to anything; the loop above offers all of
    // `poltergeist_plugins` and `startResident` turns away exactly two --
    // one that subscribes to nothing, and a duplicate. **There is no archive
    // test, and there could not be one**: `archive` is not a field, a kind or
    // a flag anywhere in a manifest. It is a name people give a plugin
    // (`chat-archive` in the fixtures), so nothing here can tell an archive
    // from any other resident.
    //
    // The number itself is worth printing -- each of these is a thread -- so
    // the repair is to call it what it counts. **A reader who saw "3 archive
    // plugins" next to a line about one subscriber concluded there were three
    // archives**, which is the reading this line was producing.
    if (self.poltergeist_residents.items.len > 0) log.info(
        "poltergeist: {d} resident plugin(s) running",
        .{self.poltergeist_residents.items.len},
    );
}

/// Where every plugin's log file goes, made if it is not there.
///
/// Made here rather than by each resident, because every resident would
/// otherwise race to make the same directory on the first start. Empty when
/// there is no state directory to be had -- the one case where a plugin runs
/// with its standard error inherited the way it used to be, into Polter's
/// own, which inside a packaged app is nowhere anybody can read.
fn pluginLogDir(self: *App) []const u8 {
    if (self.poltergeist_log_dir) |d| return d;

    const io = global.io();
    self.poltergeist_log_dir = dir: {
        var environ_map = global.environMap() catch break :dir "";
        defer environ_map.deinit();

        const state = internal_os.xdg.state(
            io,
            self.alloc,
            &environ_map,
            .{ .subdir = "polter" },
        ) catch |err| {
            log.warn("poltergeist: no state directory for the plugin logs err={}", .{err});
            break :dir "";
        };
        defer self.alloc.free(state);

        const dir = poltergeistpkg.PluginLog.dirIn(self.alloc, state) catch break :dir "";

        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                log.warn("poltergeist: could not make {s} err={}", .{ dir, err });
                self.alloc.free(dir);
                break :dir "";
            },
        };
        break :dir dir;
    };

    return self.poltergeist_log_dir.?;
}

/// Start one resident plugin, unless there is a reason not to.
///
/// Returns whether this call started one. Everything that says no says so in
/// the log first, except the two that are ordinary and quiet: a plugin that
/// subscribes to nothing, and a copy that is already running.
///
/// ⚠️ **This used to say the quiet pair was "a plugin that is not an archive"
/// and a duplicate.** There is no such test here and there never was one to
/// write: nothing in a manifest says a plugin is an archive -- it is a name
/// (`chat-archive`), not a field. So the sentence described a filter that
/// does not exist, and the log line at the caller counted every resident
/// while calling them archives. Both are the same mistake in two places.
///
/// The duplicate check is not tidiness. Two copies of one plugin confirm
/// into the same cursor file, and the cursor can then go backwards or skip
/// -- the one failure `dev-docs/poltergeist/plugins.md` spends a section ruling
/// out. This is the only path that starts one, so it is where the guarantee
/// belongs.
fn startResident(
    self: *App,
    manifest: poltergeistpkg.Plugin.Manifest,
    settings: poltergeistpkg.Plugin.Settings,
) bool {
    if (manifest.wants.empty()) {
        log.warn(
            "poltergeist: plugin {s} subscribes to nothing, so it is not " ++
                "started; add \"wants\": {{\"events\": [\"chat\"]}} -- or whichever " ++
                "events it is for -- to its plugin.json",
            .{manifest.key},
        );
        return false;
    }

    if (manifest.wants.groupless()) log.warn(
        "poltergeist: plugin {s} subscribes to chat and names no groups, so it " ++
            "will be started and handed nothing; add \"wants\": " ++
            "{{\"groups\": [\"*\"]}} to its plugin.json",
        .{manifest.key},
    );

    if (self.residentFor(manifest.key) != null) return false;

    // A fresh map each, and deliberately no `defer`: `start` takes the
    // environment over the moment it is called, on its failure paths too.
    const env = global.environMap() catch return false;

    // The plugin's own token, minted here because this is the one place a
    // child is started. Failing to mint one is not a reason not to run the
    // plugin: it still gets its events, it simply has nowhere to call. That
    // is the narrow direction, and it keeps a plugin that never calls
    // anything working when the socket is not up.
    const token = token: {
        const server = if (self.poltergeist_server) |*srv| srv else break :token "";
        break :token server.issuePluginToken(
            manifest.key,
            manifest.wants.calls,
        ) catch |err| {
            log.warn(
                "poltergeist: plugin {s} gets no token err={}, so it will be fed " ++
                    "events but cannot call anything",
                .{ manifest.key, err },
            );
            break :token "";
        };
    };

    const archive = poltergeistpkg.Resident.start(self.alloc, global.io(), .{
        .key = manifest.key,
        .exec = manifest.exec,
        .timeout_ms = manifest.timeout_ms,
        .wants = manifest.wants,
        .params = settings.params,
        .socket = if (self.poltergeist_server) |*srv| srv.path else "",
        .token = token,
        .feed = &self.poltergeist_feed,
        .environ = env,
        .log_dir = self.pluginLogDir(),

        // So that a plugin failing is not only a log line. `App` outlives
        // every resident -- `deinit` stops and destroys them before it
        // returns -- so the pointer is good for as long as the thread that
        // holds it.
        .alert = .{ .ctx = self, .func = submitPoltergeistAlert },
    }) catch |err| {
        log.warn(
            "poltergeist: plugin {s} would not start err={}",
            .{ manifest.key, err },
        );
        return false;
    };

    self.poltergeist_residents.append(self.alloc, archive) catch {
        // Never orphan a running thread over a failed append.
        archive.destroy();
        return false;
    };

    return true;
}

/// Stop and forget the running copy of one plugin, if there is one, so the
/// next `startResident` starts it afresh. Returns whether there was one.
///
/// Its tokens go with it: the next copy is minted its own, and a socket the
/// old one left open must not go on acting as the plugin.
fn stopResident(self: *App, key: []const u8) bool {
    for (self.poltergeist_residents.items, 0..) |r, i| {
        if (!std.mem.eql(u8, r.key, key)) continue;
        _ = self.poltergeist_residents.orderedRemove(i);
        r.destroy();
        if (self.poltergeist_server) |*srv| srv.revokePluginTokens(key);
        log.info("poltergeist: plugin {s} stopped to be started with new settings", .{key});
        return true;
    }
    return false;
}

/// The running copy of one archive plugin, if there is one.
///
/// Walked rather than mapped: there are single digits of these, and
/// `Archive.key` is written once in `start` and never again, so reading it
/// from here needs no lock.
fn residentFor(self: *App, key: []const u8) ?*poltergeistpkg.Resident {
    for (self.poltergeist_residents.items) |archive| {
        if (std.mem.eql(u8, archive.key, key)) return archive;
    }
    return null;
}

/// Open the agent socket if the config wants it and it is not open yet.
///
/// Called as a surface starts, because `updateConfig` runs only on a config
/// *reload* -- neither apprt calls it at launch. Without this a user who
/// set `poltergeist-mcp` in their config file would find no socket until
/// they reloaded by hand, which reads as the feature being broken.
pub fn ensurePoltergeistServer(
    self: *App,
    rt_app: *apprt.App,
    want: bool,
    max_agents: u16,
) void {
    if (!want or self.poltergeist_server != null) return;
    self.poltergeist_rt_app = rt_app;
    self.syncPoltergeistServer(true, max_agents) catch |err| {
        log.warn("poltergeist: could not open the agent socket err={}", .{err});
    };
}

/// Make sure an agent's runtime knows these tools exist.
///
/// The socket and the token are in every terminal's environment already;
/// this is what makes the tools appear in a session at all -- and it is
/// done by a plugin, because "which shape does a runtime read" is the one
/// question that has a different answer for every agent CLI. The core's
/// side is the data: this binary, this build, these skills and where their
/// files are. See `poltergeist/provision.zig` and
/// `dev-docs/poltergeist/boundary.md` section 3.
///
/// Whatever fails here is put on a terminal's screen rather than into the
/// log. What fails is the agent's tool surface, so the agent is exactly the
/// party that cannot be told about it.
pub fn ensureMcpRegistered(self: *App, want: bool) void {
    if (!want or self.poltergeist_registered) return;
    self.poltergeist_registered = true;

    // Provisioning is a plugin now, so the plugin list has to have been
    // read. Idempotent, and `Surface.init` calls it again a few lines
    // later anyway -- said here so that this does not depend on the order
    // two calls in another file happen to be written in.
    self.ensurePlugins();
    _ = self.publishProvision(null);
}

/// Publish what Polter is to the provisioning plugins: `ensureMcpRegistered`
/// once at the start, and again whenever the text of a skill changes under
/// them (`skillsChanged`) -- a plugin mirrors the files it is handed, and
/// one it was handed before the edit is one it has no reason to read again.
///
/// `to` names one subscriber instead of all of them: the plugin switched on,
/// or restarted with new settings, while Polter was running (#1673). It
/// subscribed after this run's event went by, and the feed keeps no history,
/// so without this it waited for the next restart while `plugin_configure`
/// told the agent it was being fed. Returns whether the event went out.
fn publishProvision(self: *App, to: ?*poltergeistpkg.Feed.Subscription) bool {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const io = global.io();

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0 .. std.process.executablePath(io, &exe_buf) catch |err| {
        log.warn("poltergeist: could not find my own path err={}", .{err});
        return false;
    }];

    // # Two silent exits used to be here, and the silence was the defect
    //
    // Neither of these can stop provisioning from being *wanted*; they can
    // only stop it from being *told*. A `return` with nothing said turns
    // "the whole AI-runtime integration is missing" into a symptom with no
    // trail: the plugin still starts, still completes its handshake, and
    // then waits on a batch that is never published. What comes back is
    // "the plugin does nothing", and nothing in any log points here.
    //
    // So both say what happened **and what it costs**. A log line that
    // reports a fact without its consequence gets read as noise and
    // stepped over.
    var environ_map = global.environMap() catch |err| {
        log.warn(
            "poltergeist: cannot read this process's environment err={}; " ++
                "no provisioning plugin will be told that Polter exists, so no " ++
                "agent runtime will be registered",
            .{err},
        );
        return false;
    };
    defer environ_map.deinit();

    // **`HOME` is a POSIX name and Windows does not set it.**
    //
    // This line read the variable directly and returned when it was absent,
    // which on Windows is always -- so on that platform this function has
    // never reached its `publish` below, and every provisioning plugin has
    // sat on an empty queue since the day it was written.
    //
    // The repository already knew: `os/homedir.zig` has a Windows branch
    // reading `HOMEDRIVE` + `HOMEPATH`. **Only this line did not.** Asking
    // that function is the whole of the platform fix, and it changes nothing
    // on POSIX, where it reads `HOME` first.
    //
    // **And when it still cannot be found, the batch goes out anyway.** The
    // value is carried in the event and is not used here for anything, so
    // withholding the entire event over it trades a plugin that can report
    // its own problem for one that cannot say anything at all -- and the
    // plugin SDK already handles an empty home explicitly, logging
    // `status=failed step=parse` into its own file, which is where somebody
    // looking would look. **A failure in the plugin's log beats a silence in
    // ours.**
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home: []const u8 = home: {
        const found = internal_os.home(io, &environ_map, &home_buf) catch |err| {
            log.warn("poltergeist: home directory lookup failed err={}", .{err});
            break :home null;
        };
        break :home found;
    } orelse blk: {
        log.warn(
            "poltergeist: cannot determine the home directory (looked at HOME on " ++
                "POSIX, HOMEDRIVE+HOMEPATH on Windows); the provisioning event is " ++
                "still published with an empty one, so the plugin will report " ++
                "`status=failed step=parse` in its own log rather than waiting " ++
                "silently for a batch that never comes",
            .{},
        );
        break :blk "";
    };

    // Before anything is published, because a subscription starts empty by
    // definition: an event handed to the feed before the plugins subscribe
    // is an event nobody was listening for. `ensureChatLog` calls this too
    // and it is idempotent -- said here so that provisioning does not
    // depend on the order two calls in another file happen to be written.
    self.ensureResidents();

    // Nothing switched on that would tell any runtime anything, while the
    // config says to register. Nothing failed -- there is simply no plugin
    // to do it, and that is a thing the user asked for that will not
    // happen, which is the same silence this whole path exists to end.
    if (poltergeistpkg.notify.count(self.poltergeist_plugins, .provision) == 0) {
        const line = poltergeistpkg.provision.nothingInstalled(self.alloc) catch return false;
        self.poltergeist_alerts.append(self.alloc, line) catch self.alloc.free(line);
        return false;
    }

    // The skills are half of it. One the runtime has never heard of is one
    // it cannot match against what the user asked for, which is how a
    // supervisor ends up reaching for its own subagent tool instead. The
    // user's own copy is what gets handed over, the same order
    // `skill_read` resolves in: editing one file should change Polter's
    // behaviour everywhere, not in one of two places.
    //
    // **Which skills there are is read from the resources directory**, and
    // the plugins take away a `polter-*` skill that has stopped being
    // listed. So when that directory cannot be read the list handed over is
    // left empty, which both plugin SDKs read as "nothing was said about
    // skills" and do nothing for -- they prune only against a list that has
    // something in it. `skill_store.provisioned` is where "could not be
    // read" and "is empty" are kept apart.
    var skills: std.ArrayListUnmanaged(poltergeistpkg.provision.Skill) = .empty;
    const config_dir = internal_os.xdg.config(io, alloc, &environ_map, .{}) catch null;
    const resources = internal_os.resourcesDir(alloc) catch null;

    if (poltergeistpkg.skill_store.provisioned(
        alloc,
        io,
        config_dir,
        if (resources) |r| r.app_path else null,
    ) catch null) |handed| {
        for (handed) |h| skills.append(alloc, .{ .name = h.name, .path = h.path }) catch {};
        // A list cut short by a failed append is a partial list, and a
        // partial list is the one that gets skills taken away.
        if (skills.items.len != handed.len) skills.clearRetainingCapacity();
    }

    // Published, not run. There is no provisioning pass any more: a
    // provisioning plugin is a resident subscribed to one event, and this
    // is that event. `publish` copies everything into each subscriber's own
    // queue, so the arena above may go away the moment this returns.
    const event = poltergeistpkg.provision.published(
        .{
            .exe = exe,
            .version = build_config.version_string,
            .home = home,
            .skills = skills.items,
        },
        self.poltergeistWallMs(),
    );

    if (to) |sub| {
        self.poltergeist_feed.publishTo(sub, event);
        log.info("poltergeist: handed what Polter is to one provisioning plugin started late", .{});
        return true;
    }

    self.poltergeist_feed.publish(event);
    log.info(
        "poltergeist: handed what Polter is to {d} provisioning plugin(s)",
        .{poltergeistpkg.notify.count(self.poltergeist_plugins, .provision)},
    );
    return true;
}

/// Put everything that has been waiting on a terminal that now exists.
///
/// Called from the end of `Surface.init`, which is the first moment there
/// is anywhere to write: `addSurface` runs before the core surface exists
/// at all. Drained, so a second window does not repeat it.
pub fn flushPoltergeistAlerts(self: *App, surface: *Surface) void {
    if (self.poltergeist_alerts.items.len == 0) return;

    for (self.poltergeist_alerts.items) |line| {
        defer self.alloc.free(line);
        self.showPoltergeistAlert(surface, line);
    }

    self.poltergeist_alerts.clearAndFree(self.alloc);
}

/// Open or close the agent socket to match the config.
///
/// Turning it off tears the socket down rather than leaving it listening,
/// since the point of turning it off is that nothing should be able to
/// reach in any more.
fn syncPoltergeistServer(self: *App, want: bool, max_agents: u16) !void {
    if (!want) {
        if (self.poltergeist_server) |*srv| {
            srv.deinit();
            self.poltergeist_server = null;
            log.info("poltergeist: agent socket closed", .{});
        }
        return;
    }

    if (self.poltergeist_server != null) return;

    const io = global.io();
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    const state_dir = try internal_os.xdg.state(
        io,
        self.alloc,
        &environ_map,
        .{ .subdir = "polter" },
    );
    defer self.alloc.free(state_dir);

    // Nothing else creates this on a fresh machine, and a missing
    // directory would make listen fail with a single warning that reads
    // like the feature is broken.
    std.Io.Dir.cwd().createDirPath(io, state_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // A socket file outlives the process that bound it, so a machine that has
    // run Polter a few dozen times has a few dozen of them. Sweeping before we
    // bind our own means we never probe ourselves, and only sockets nothing is
    // listening on are removed -- a live instance's is left alone.
    poltergeistpkg.Server.sweepStale(self.alloc, io, state_dir);

    const path = try poltergeistpkg.Server.defaultPath(self.alloc, io, state_dir);
    defer self.alloc.free(path);

    self.poltergeist_server = try .init(self.alloc, io, path, .{
        .ctx = self,
        .func = submitPoltergeistRequest,
        .full = poltergeistAgentsFull,
        .agent_gone = poltergeistAgentGone,
    }, max_agents);
    errdefer {
        self.poltergeist_server.?.deinit();
        self.poltergeist_server = null;
    }

    try self.poltergeist_server.?.start();
    log.info("poltergeist: agent socket open at {s}", .{path});
}

/// An agent was turned away because every slot on the socket is taken.
///
/// # Why this is an alert and not a notice
///
/// A notice is *typed into* a terminal, so its reader is whatever agent is
/// running there. There is no agent here -- that is the whole problem, the
/// one that just started has no tools -- so the reader is the person, and an
/// alert is what gets printed rather than fed to a program.
///
/// # Why it does not name the terminal
///
/// The slot is claimed before the handshake, so at the moment of refusal the
/// server does not know which terminal the connection came from: no token
/// has been read, no `Caller` resolved. Naming the wrong terminal would be
/// worse than naming none, and the person who just started an agent is
/// looking at the right window anyway.
fn poltergeistAgentsFull(ctx: *anyopaque, in_use: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx));

    // The number is in the sentence because the setting is the fix, and a
    // person who is told "the limit" without being told what it is has to
    // go and find it -- which today meant reading it out of the source.
    const line = std.fmt.allocPrint(
        self.alloc,
        "Polter: an agent could not connect -- all {d} agent slots are in use. " ++
            "Close a terminal running an agent, or raise `poltergeist-max-agents` " ++
            "in your config and restart Polter.",
        .{in_use},
    ) catch return;

    if (self.mailbox.push(
        global.io(),
        .{ .poltergeist_alert = line },
        .{ .instant = {} },
    ) == 0) {
        // `.instant` and not `.forever`: this runs on the accept thread,
        // and a full mailbox must not stop it accepting. Losing one alert
        // costs a sentence; blocking here costs every later connection.
        self.alloc.free(line);
        return;
    }

    // Same reason `submitPoltergeistRequest` does it: queuing is not
    // delivering, and the app loop sleeps until something wakes it.
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// Hand a request from a connection thread to the app thread.
///
/// Pushed with a blocking timeout rather than dropped: the connection
/// thread is already waiting on this, and losing it would leave the agent
/// waiting for an answer that is never coming.
fn submitPoltergeistRequest(
    ctx: *anyopaque,
    pending: *poltergeistpkg.Server.Pending,
) void {
    const self: *App = @ptrCast(@alignCast(ctx));

    // A zero return means the push failed, in which case nothing will ever
    // take the reference off our hands.
    // Instant: the queue has room for every connection there can be
    // (`PoltergeistRequests`), so a push that finds it full is a broken
    // count, and is answered rather than left to wait.
    if (self.poltergeist_requests.push(
        global.io(),
        pending,
        .{ .instant = {} },
    ) == 0) {
        log.warn("poltergeist: could not queue an agent request", .{});
        // **Answered before it is let go** (task 1685): the connection
        // thread is waiting on `done`, and a reference dropped without an
        // answer left it waiting for ever (`Server.serveOne`).
        pending.complete(global.io(), .{ .failed = .{
            .code = "Busy",
            .message = "Polter could not take the request; try again",
        } });
        pending.release();
        return;
    }

    // Queuing is not delivering. The app loop sleeps until something wakes
    // it, so without this the request sits in the mailbox until some
    // unrelated event -- a keystroke, a redraw, the next quiescence sample
    // -- happens to wake the loop for its own reasons. Measured on a real
    // machine that meant replies arriving between 50ms and never: the agent
    // saw an occasional fast answer and an occasional timeout, with no
    // pattern to it.
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// Take a plugin's failure off its own thread and give it to the app.
///
/// Called from a resident's thread (`Resident.Alert`), so it does exactly
/// one thing: copy the line and post it. It must not look at a surface --
/// those belong to the app thread -- and it must not block, because this
/// thread is the one keeping that plugin's child to its deadline.
///
/// **Pushed with `instant`, not `forever`**, which is the opposite of what
/// `submitPoltergeistRequest` does, and for the opposite reason: nobody is
/// waiting on this, and a resident parked on a full mailbox is a plugin
/// nobody is holding to time. A mailbox that full means the app thread is
/// already in trouble; the line is dropped and said in the log, which is
/// where it was going anyway before this path existed.
fn submitPoltergeistAlert(ctx: *anyopaque, line: []const u8) void {
    const self: *App = @ptrCast(@alignCast(ctx));

    // Copied because the caller's buffer dies with the call. Freed by
    // `poltergeistAlert`, or here if it never gets that far.
    const owned = self.alloc.dupe(u8, line) catch {
        log.warn("poltergeist: no memory to show a plugin failure: {s}", .{line});
        return;
    };

    if (self.mailbox.push(
        global.io(),
        .{ .poltergeist_alert = owned },
        .{ .instant = {} },
    ) == 0) {
        log.warn("poltergeist: could not queue a plugin failure: {s}", .{line});
        self.alloc.free(owned);
        return;
    }

    // Queuing is not delivering; the app loop sleeps until something wakes
    // it. Same reason as `submitPoltergeistRequest`, and it matters more
    // here: nothing else is going to happen on an idle machine at 3am,
    // which is exactly when this line is worth having.
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// Show one plugin failure. Runs on the app thread.
///
/// **Straight to a terminal when there is one.** The queue is the answer to
/// "there is no window yet", which is the case at startup and only then;
/// once a terminal exists, holding the line back would mean a plugin that
/// broke at 3am is reported the next time somebody opens a tab.
///
/// Takes ownership of `line`.
fn poltergeistAlert(self: *App, line: []const u8) void {
    if (self.surfaces.items.len > 0) {
        defer self.alloc.free(line);
        self.showPoltergeistAlert(self.surfaces.items[0].core(), line);
        return;
    }

    // Queued rather than dropped: no surface means no user either, and a
    // message thrown away for want of a window is the silence this whole
    // path exists to end.
    self.poltergeist_alerts.append(self.alloc, line) catch self.alloc.free(line);
}

/// Print one line where the person will see it.
///
/// `poltergeist_alert` and not `poltergeist_notice`, and the difference is
/// the recipient: a notice is *typed into* a terminal, so it is addressed
/// to whatever is running in there; an alert is *printed*, so the reader is
/// the person and the agent does not take it as input.
fn showPoltergeistAlert(self: *App, surface: *Surface, line: []const u8) void {
    _ = self;

    var msg: apprt.surface.Message = .{ .poltergeist_alert = undefined };
    const n = @min(line.len, msg.poltergeist_alert.len - 1);
    @memcpy(msg.poltergeist_alert[0..n], line[0..n]);
    msg.poltergeist_alert[n] = 0;

    surface.handleMessage(msg) catch |err| {
        log.warn("poltergeist: could not show an alert err={}", .{err});
    };
}

/// Answer one agent request. Runs on the app thread, which is the only
/// thread that may touch the bus or a surface.
fn poltergeistRequest(self: *App, pending: *poltergeistpkg.Server.Pending) void {
    // The reference taken when this was handed over. Releasing it here is
    // what lets the connection thread's frame go away safely even if
    // shutdown answered the request before we got to it.
    defer pending.release();

    // A request can clock a terminal off or on, which is exactly the sort
    // of thing the tabs are there to show. Cheap enough to do after every
    // request: each surface compares its own mark and does nothing when it
    // has not moved.
    defer self.refreshPoltergeistTabs();

    // Duty changes are part of the arrangement, so they go in the notes
    // for tomorrow. The group calls save themselves; these do not pass
    // through the chat at all.
    defer switch (pending.request) {
        .clock_out, .clock_in => self.saveSession(),
        else => {},
    };

    // The server resolved the token to a surface, exactly as it does for
    // an agent's sidecar. One more question decides whose request this is:
    // a surface this app opened for the chat speaks for the person at the
    // keyboard, and nothing else does.
    // A chat surface is still a *terminal*, which is why this substitution
    // is only ever made on one: a plugin has no surface, so there is
    // nothing here it could be mistaken for -- least of all the user.
    const caller: poltergeistpkg.Bus.Caller = caller: {
        const id = pending.caller.terminalId() orelse break :caller pending.caller;
        if (self.isChatSurface(id)) break :caller .{ .terminal = poltergeistpkg.Chat.user_id };
        break :caller .{ .terminal = id };
    };

    // Anything arriving is a chance to notice a wait that has run out.
    // See `persona_wait_timeout_ms` for what this is and is not.
    self.sweepPersonaWaits();
    self.sweepScreenshotWaits();
    self.sweepFreshAssigns();

    // **Held rather than answered**, when it is a wait and nothing has
    // moved. Done here rather than in `dispatch` because `dispatch` is pure
    // and synchronous: blocking in there would stop the app thread, which
    // is every terminal's thread.
    // A launched role's standing is claimed here too, before a wait is
    // parked: `dispatch` does it for everything else, but a slot process's
    // `persona_wait` may be held instead of dispatched, and that is as much
    // the agent arriving as its sidecar's first call.
    poltergeistpkg.rpc.arrived(&self.poltergeist, self.poltergeistHost(), caller, pending.request);

    if (pending.request == .persona_wait) {
        if (self.parkPersonaWait(pending, caller)) return;
    }

    // A host function may park this request instead of answering it (a
    // screenshot the apprt has not finished). It finds the request here.
    self.poltergeist_dispatching = pending;
    self.poltergeist_parked = false;
    defer self.poltergeist_dispatching = null;

    const response = poltergeistpkg.rpc.dispatch(
        pending.arena.allocator(),
        &self.poltergeist,
        self.poltergeistHost(),
        caller,
        pending.request,
    ) catch |err| switch (err) {
        error.OutOfMemory => poltergeistpkg.wire.Response{ .failed = .{
            .code = "OutOfMemory",
            .message = "out of memory",
        } },
    };

    // After, so a call that made this terminal a supervisor or put it under
    // watch is counted on the entry it made. A supervisor's hollow flag
    // (`Bus.TabMark.supervisor_silent`) is the one mark a call can change,
    // so that is the one case that redraws the tabs: doing it on every
    // request would walk every surface for nothing.
    const now_ms = self.poltergeistElapsedMs();
    const was_silent = if (caller.terminalId()) |id|
        self.poltergeist.tabMark(id, now_ms, 0) == .supervisor_silent
    else
        false;
    poltergeistpkg.rpc.noteCall(&self.poltergeist, caller, pending.request, now_ms);
    // An agent that is asking Polter things is alive and working, so a
    // supervisor's quiet starts again here too, not only when a line is
    // typed into its terminal (task 2148). A supervisor stuck on a
    // condition is one that has stopped asking anything.
    //
    // ⚠️ **The same filter `noteCall` uses, and it has to be the same one.**
    // `isAgentCall` is where the hooks and the sidecar are kept out
    // (`agent_event`, `hook_context`, `persona_face`, `persona_slot`,
    // `session_file`, `persona_wait`), and the reason is exactly this
    // reminder's case: a CLI stuck in a retry loop sends an `agent_event`
    // every time it gives up, so counting those would refresh its own
    // silence clock for ever and the reminder would never come -- for the
    // one terminal it exists for. Asking `isAgentCall` rather than writing
    // a second list is what keeps the two answers from drifting.
    if (poltergeistpkg.rpc.heardByAgent(caller, std.meta.activeTag(pending.request))) |id| self.noteHeard(id);
    // And a request is where a group, a supervisor or a task comes from,
    // so when the next alarm or reminder is due is worked out again
    // (`alarm_dirty`). Cheap: it walks the groups and counts tasks.
    self.alarm_dirty = true;
    if (was_silent) self.refreshPoltergeistTabs();

    // A launch that never got its agent, said on the next request from
    // anybody (task 1712). Here as well as on the screen reports because a
    // terminal nobody watches sends none, and the supervisor that ran the
    // launch is asking for things all the time.
    if (self.considerLaunches(now_ms)) self.deliverPoltergeistNotices(now_ms);

    // An agent's hook may have put something in a box (a turn ended, a
    // prompt is up). Offered now rather than on the next screen report,
    // which for a terminal that has just gone still is a whole threshold
    // away; still bounded by `poltergeist-notice-interval`.
    if (pending.request == .agent_event) {
        if (caller.terminalId()) |id| self.noteAgentSession(id, pending.request.agent_event);
        // A clear a `task_assign` is waiting on (#64).
        if (caller.terminalId()) |id| self.finishFreshAssigns(id, pending.request.agent_event);
        // `+launch` started the CLI without its first prompt (task 1746).
        if (caller.terminalId()) |id| {
            const ev = pending.request.agent_event;
            if (ev.event == .hooks_expected and poltergeistpkg.agent_event.firstPromptOwed(ev.detail)) {
                self.first_prompts.put(self.alloc, id, {}) catch |err| {
                    log.warn("poltergeist: could not keep a first prompt owed err={}", .{err});
                };
                log.info("poltergeist: 0x{x} was started without its first prompt; it is typed once its input box shows", .{id});
            }
        }
        _ = self.poltergeist.considerAgents(now_ms);
        self.deliverPoltergeistNotices(now_ms);
        // A turn that ended may be the first one a started supervisor's
        // second message waits for (task 1746).
        self.payStartLines();

        // The status line has written a new allowance: read it now. It is
        // the only thing that will ever say so -- the file is not watched,
        // and whatever else happens in a terminal may have happened before
        // it was written.
        if (pending.request.agent_event.event == .allowance_written) self.quotaWatch().written();
    }

    // Parked: the apprt answers it later, through
    // `poltergeistScreenshotComplete`, or the sweep does when its time is up.
    if (self.poltergeist_parked) {
        self.poltergeist_parked = false;
        return;
    }

    pending.complete(global.io(), response);
}

fn poltergeistScreenshotAllowed(ctx: *anyopaque) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.poltergeist_screenshot_allowed;
}

/// Hand one screenshot request to the apprt.
///
/// The buffer is ours, as it is for a layout. A `pending` answer parks the
/// request being dispatched under the token the apprt was given.
fn poltergeistScreenshotHost(
    ctx: *anyopaque,
    alloc: Allocator,
    by: poltergeistpkg.Bus.Id,
    request: poltergeistpkg.screenshot.HostRequest,
    directory: []const u8,
) anyerror!poltergeistpkg.screenshot.HostReply {
    _ = by;
    const self: *App = @ptrCast(@alignCast(ctx));
    const rt_app = self.poltergeist_rt_app orelse return .unsupported;

    const target: apprt.Target = if (request.surface) |id|
        .{ .surface = self.findSurfaceByID(id) orelse return error.NoSuchTerminal }
    else
        .app;

    const buf = try alloc.alloc(u8, poltergeistpkg.screenshot.host_buffer_bytes);
    const token = self.poltergeist_screenshot_waits.issue();
    var out: apprt.action.PoltergeistScreenshot.Out = .{
        .token = token,
        .buf = buf.ptr,
        .cap = buf.len,
    };

    _ = rt_app.performAction(
        target,
        .poltergeist_screenshot,
        .{ .spec = request.spec, .out = &out },
    ) catch |err| {
        log.warn("poltergeist: screenshot action failed err={}", .{err});
        return error.ScreenshotFailed;
    };

    const said = buf[0..@min(out.len, buf.len)];
    switch (out.result) {
        .unsupported => return .unsupported,
        .done => return .{ .done = said },
        .refused => return .{ .refused = said },
        .pending => {
            // Nothing to park it on, or an operation that has no business
            // taking time: the apprt will call back with a token nobody
            // holds, which is logged and dropped.
            const pending = self.poltergeist_dispatching orelse return .unsupported;
            if (request.timeout_ms == 0) return .{ .refused = "" };

            try self.poltergeist_screenshot_waits.park(self.alloc, .{
                .token = token,
                .held = pending,
                .op = request.op,
                // `alloc` is the request's own arena, so this lives exactly
                // as long as the request does.
                .directory = try alloc.dupe(u8, directory),
                .deadline_ms = self.poltergeistElapsedMs() + request.timeout_ms,
            });
            pending.retain();
            self.poltergeist_parked = true;
            return .pending;
        },
    }
}

fn poltergeistScreenshotInteractive(ctx: *anyopaque) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    const rt_app = self.poltergeist_rt_app orelse return false;
    return rt_app.performAction(.app, .screenshot, {}) catch false;
}

fn poltergeistScreenshotCwd(ctx: *anyopaque, alloc: Allocator, id: poltergeistpkg.Bus.Id) ?[]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return null;
    return surface.pwd(alloc) catch null;
}

fn poltergeistScreenshotIo(ctx: *anyopaque) std.Io {
    _ = ctx;
    return global.io();
}

/// The apprt has finished a screenshot it answered `pending` to.
///
/// `result` is the raw enum value from the C side. A token nobody holds is
/// one that was answered already or ran out of time; it is logged, because
/// a host that calls back twice has a bug worth seeing, and dropped.
pub fn poltergeistScreenshotComplete(
    self: *App,
    token: u64,
    result: c_int,
    json: []const u8,
) void {
    const shot = poltergeistpkg.screenshot;
    const entry = self.poltergeist_screenshot_waits.take(token) orelse {
        log.warn("poltergeist: screenshot completion for token {d}, which is not waiting", .{token});
        return;
    };
    defer entry.held.release();

    const alloc = entry.held.arena.allocator();
    // Copied: the apprt's bytes are valid only for this call.
    const text = alloc.dupe(u8, json) catch "";

    const R = apprt.action.PoltergeistScreenshot.Result;
    const answer: shot.Answer = if (result == @intFromEnum(R.done))
        shot.finish(alloc, entry.op, entry.directory, text)
    else if (result == @intFromEnum(R.refused))
        .{ .failed = shot.refusal(alloc, text) }
    else
        // `unsupported` or `pending` are not answers to have waited for.
        .{ .failed = shot.refusal(alloc, "") };

    entry.held.complete(global.io(), switch (answer) {
        .json => |j| .{ .json = j },
        .failed => |f| .{ .failed = .{ .code = f.code, .message = f.message } },
    });
}

/// Answer screenshots whose apprt never called back.
/// Hold the `task_assign` being dispatched until its /clear is confirmed
/// (`Host.parkAssign`, #64). Woken by the notice retry when the wait runs
/// out, so an idle app does not keep it past its ten seconds.
fn poltergeistParkAssign(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    task: u64,
    before: ?[]const u8,
    confirm: poltergeistpkg.fresh_assign.Confirm,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const pending = self.poltergeist_dispatching orelse return error.NothingToHold;
    try self.fresh_assigns.park(self.alloc, pending, id, task, before, confirm, self.poltergeistElapsedMs());
    pending.retain();
    self.poltergeist_parked = true;
    self.noticeRetryIn(confirm.holdMs() + chat_notice_retry_margin_ms);
}

/// The CLI in `id` said something: answer any fresh assignment its clear
/// was waiting for.
fn finishFreshAssigns(self: *App, id: poltergeistpkg.Bus.Id, ev: poltergeistpkg.agent_event.Event) void {
    if (self.fresh_assigns.entries.items.len == 0) return;
    log.info("poltergeist: agent event while a fresh assignment waits id={x} event={t} detail={s} session={s}", .{
        id, ev.event, ev.detail orelse "", ev.session_id orelse "",
    });
    while (self.fresh_assigns.takeCleared(id, ev.event, ev.detail, ev.session_id)) |e| {
        log.info("poltergeist: fresh assignment cleared task={d} id={x}", .{ e.task, e.id });
        self.finishFreshAssign(e, .confirmed);
    }
}

fn sweepFreshAssigns(self: *App) void {
    const now_ms = self.poltergeistElapsedMs();
    while (self.fresh_assigns.takeExpired(now_ms)) |e| {
        switch (e.confirm) {
            .session_start => {
                log.warn("poltergeist: fresh assignment not confirmed cleared within {d}ms task={d} id={x}; typing it anyway", .{
                    poltergeistpkg.fresh_assign.wait_ms, e.task, e.id,
                });
                self.finishFreshAssign(e, .unconfirmed);
            },
            // Expected: this CLI confirms its clear with the turn the
            // line starts.
            .next_turn => {
                log.info("poltergeist: fresh assignment settled task={d} id={x}; the clear is confirmed by the next turn", .{ e.task, e.id });
                self.finishFreshAssign(e, .pending);
            },
        }
    }
    // A wake that came a little early leaves one behind: come back for it.
    for (self.fresh_assigns.entries.items) |e| {
        self.noticeRetryIn(e.deadline_ms -| now_ms + chat_notice_retry_margin_ms);
    }
}

fn finishFreshAssign(
    self: *App,
    e: poltergeistpkg.fresh_assign.Waits(*poltergeistpkg.Server.Pending).Entry,
    cleared: poltergeistpkg.rpc.Fresh,
) void {
    defer poltergeistpkg.fresh_assign.Waits(*poltergeistpkg.Server.Pending).free(self.alloc, e);
    const response = poltergeistpkg.rpc.finishFreshAssign(
        e.held.arena.allocator(),
        self.poltergeistHost(),
        e.task,
        e.id,
        cleared,
    ) catch poltergeistpkg.wire.Response{ .failed = .{ .code = "OutOfMemory", .message = "out of memory" } };
    e.held.complete(global.io(), response);
    e.held.release();
}

fn sweepScreenshotWaits(self: *App) void {
    const now_ms = self.poltergeistElapsedMs();
    while (self.poltergeist_screenshot_waits.takeExpired(now_ms)) |entry| {
        log.warn("poltergeist: screenshot token {d} timed out", .{entry.token});
        entry.held.complete(global.io(), .{ .failed = .{
            .code = poltergeistpkg.screenshot.timeout.code,
            .message = poltergeistpkg.screenshot.timeout.message,
        } });
        entry.held.release();
    }
}

/// Put a terminal into a persona, and tell everything that is waiting.
///
/// The three steps are one call on purpose: a persona that changed without
/// waking the waits is a change that the agent in that terminal never hears
/// about, and a persona that changed without refreshing the tabs is a tab
/// that goes on claiming the old one. Both are the interface disagreeing
/// with the truth, which is the failure this whole feature is built not to
/// have.
pub fn setSurfacePersona(
    self: *App,
    id: poltergeistpkg.Bus.Id,
    key: []const u8,
) !void {
    self.ensurePersonas();
    try self.personas.setPersona(id, key);
    self.wakePersonaWaits(id);
    self.refreshPoltergeistTabs();
}

/// Every role in the library, as JSON. The window and `role_list` both
/// read this, so they cannot be told two different stories.
pub fn personaCatalogJson(self: *App, alloc: Allocator) ![]u8 {
    self.ensurePersonas();
    const path = poltergeistpkg.PersonaStore.defaultPath(alloc) catch null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try self.personas.writeCatalogJson(&out.writer, path);
    return try out.toOwnedSlice();
}

/// Write one role into the library. The window (`who` = user) and
/// `role_put` (`who` = supervisor) both come here; `PersonaStore.put` is
/// the one writer underneath, and holds a supervisor to what it may set.
pub fn putPersona(self: *App, json: []const u8, who: poltergeistpkg.Bus.Authority) !void {
    self.ensurePersonas();
    const path = try poltergeistpkg.PersonaStore.defaultPath(self.alloc);
    defer self.alloc.free(path);
    try self.personas.put(global.io(), path, json, who);
    self.personasChanged();
}

/// Put an official role back to the shipped one (`PersonaStore.restore`).
/// The role library only: no agent reaches this.
pub fn restorePersona(self: *App, key: []const u8, everything: bool) !void {
    self.ensurePersonas();
    const path = try poltergeistpkg.PersonaStore.defaultPath(self.alloc);
    defer self.alloc.free(path);
    // The skills' directories, because restoring everything sets every
    // person's copy of a shipped skill aside too (task 1514).
    const dirs = self.skillDirs();
    defer if (dirs.config_root) |d| self.alloc.free(d);
    try self.personas.restore(global.io(), path, key, everything, .{
        .config_root = dirs.config_root,
        .resources = dirs.resources,
    });
    self.personasChanged();
    // Moving the whole file aside takes the skills' records with it, and
    // their copies (`skill_store.setAllAside`).
    if (everything) self.skillsChanged();
}

/// "Keep mine" on an official role the shipped version has moved under
/// (`PersonaStore.acknowledge`). The role library only.
pub fn acknowledgePersona(self: *App, key: []const u8) !void {
    self.ensurePersonas();
    const path = try poltergeistpkg.PersonaStore.defaultPath(self.alloc);
    defer self.alloc.free(path);
    try self.personas.acknowledge(global.io(), path, key);
    self.personasChanged();
}

/// Keep a role the file holds under an official key as the person's own
/// (`PersonaStore.adopt`).
pub fn adoptPersona(self: *App, key: []const u8) !void {
    self.ensurePersonas();
    const path = try poltergeistpkg.PersonaStore.defaultPath(self.alloc);
    defer self.alloc.free(path);
    try self.personas.adopt(global.io(), path, key);
    self.personasChanged();
}

pub fn deletePersona(self: *App, key: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    _ = try self.deletePersonaDropping(arena.allocator(), key);
}

/// Delete a role, and take every squad seat made from it out of the
/// templates **after** the role is gone (`SquadStore.dropRole`: the role
/// first, so that a crash between the two leaves seats that read as
/// `role_missing`, which the next squad write sweeps). Answers the seats
/// taken out, in `alloc`.
///
/// A `squads.json` that cannot be read leaves the seats where they are and
/// is logged: the role is deleted either way, and deleting it must not be
/// the thing that fails because a second file is broken.
pub fn deletePersonaDropping(self: *App, alloc: Allocator, key: []const u8) ![]const poltergeistpkg.squad.Removed {
    self.ensurePersonas();
    const path = try poltergeistpkg.PersonaStore.defaultPath(self.alloc);
    defer self.alloc.free(path);
    try self.personas.remove(global.io(), path, key);
    self.personasChanged();

    self.ensureSquads();
    const squads_path = poltergeistpkg.SquadStore.defaultPath(self.alloc) catch return &.{};
    defer self.alloc.free(squads_path);
    return self.squads.dropRole(global.io(), squads_path, alloc, key, self.squadRoles()) catch |err| {
        log.warn("poltergeist: role {s} is deleted but its squad seats could not be taken out err={}", .{ key, err });
        return &.{};
    };
}

/// After the library changed: every terminal wearing a role has just been
/// re-dressed in the new version of it (`PersonaStore.rebindStates`), so
/// every one of them is told, and every tab redrawn. Waking only the
/// terminal whose window made the edit would leave the others handing out
/// the old role with nobody noticing.
fn personasChanged(self: *App) void {
    var ids: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
    defer ids.deinit(self.alloc);
    var it = self.personas.states.keyIterator();
    while (it.next()) |id| ids.append(self.alloc, id.*) catch {};
    for (ids.items) |id| self.wakePersonaWaits(id);
    self.refreshPoltergeistTabs();
}

/// Why a CLI a plugin manages is held back from the lists a host offers,
/// or null when it is offered (tasks 1677, 2237).
///
/// **Pure, so every case is a test.** `standing` is the plugin's own answer
/// (`plugin_off`, `cannot_run`); a plugin that is on and runnable is offered
/// unless the last inventory said the program here is not one it serves
/// (`serves: false` → `wrong_version`). A CLI whose program is *not here*
/// (`installed: false`) is deliberately not here: it is in `clis` with
/// `installed` false, which is where a host reads it, and holding it back
/// as well would be the same fact said twice.
fn heldBackReason(
    standing: poltergeistpkg.agent_cli.Standing,
    wrong_version: []const []const u8,
    key: []const u8,
) ?[]const u8 {
    return switch (standing) {
        .off => "plugin_off",
        .cannot_run => "cannot_run",
        .ok => if (isAnyOf(wrong_version, key)) "wrong_version" else null,
    };
}

/// What each agent CLI here offers, as JSON (`agent_cli.Cache`). A copy of
/// the cache; `refresh` starts a new read on its own thread first.
///
/// **`own` is added here** (task 2156 v5): the Agent CLIs of the person's
/// own, each with the roles it is ticked for, so that **every** place that
/// lists a role's CLIs can list these beside the presets -- the role
/// library, the `Role ▸` menu on both hosts, and the launch button under
/// the role. Until v5 the only reader of the person's own was the control
/// room, through `ownClis`; the role library and the menus read this one
/// call, which knew nothing about them.
///
/// Read once per round (`ownClis`), so this is the same answer the control
/// room is using in this round: two readers of one round cannot disagree
/// about which roles an Agent CLI of the person's own is ticked for.
pub fn agentClisJson(self: *App, alloc: Allocator, refresh: bool) ![]u8 {
    if (refresh) self.poltergeist_agent_clis.refresh(global.io());
    const cached = try self.poltergeist_agent_clis.snapshot(global.io(), alloc);

    // `held_back` (task 1677): every CLI a plugin manages that is not in
    // `clis` because it cannot be started, and why -- a switch in Plugins
    // (`plugin_off`), nothing here can run its adapter (`cannot_run`), or
    // the program on this machine is not the version its plugin starts
    // (`wrong_version`, task 2237).
    //
    // **`wrong_version` belongs here and `not_installed` does not.** A CLI
    // whose program is missing is in `clis` with `installed` false, and a
    // host already reads it there (task 1744); a wrong version has no such
    // field, so without this list the menu would offer a CLI that refuses
    // the moment it is clicked. Both are held back from the menus by the
    // host, which is the same treatment reached two ways.
    //
    // Read afresh, as `resolveLaunch` reads it: a directory walk, no
    // process. A CLI a role names that is in neither list has no plugin
    // (`no_plugin`), which only a role can say.
    const cannot: poltergeistpkg.ControlRoom.NotStartable = (try self.cannotStart(alloc)) orelse .{};
    var env = try global.environMap();
    defer env.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    // The cache writes one object; its closing brace is the last byte.
    try w.writeAll(cached[0 .. cached.len - 1]);
    try w.writeAll(",\"held_back\":[");
    var n: usize = 0;
    for (poltergeistpkg.agent_cli.survey(alloc, global.io(), &env)) |f| {
        const why = heldBackReason(f.standing, cannot.wrong_version, f.adapter.key) orelse continue;
        if (n > 0) try w.writeAll(",");
        try w.print("{{\"key\":{f},\"label\":{f},\"why\":\"{s}\"}}", .{
            std.json.fmt(f.adapter.key, .{}),
            std.json.fmt(f.adapter.label, .{}),
            why,
        });
        n += 1;
    }
    // The Agent CLIs of the person's own (task 2156 v5), written exactly as
    // the settings form is given them (`Launchers.writeSafe`): a variable's
    // name, never its value. Every host that draws a role's CLIs reads this
    // list, so this is the one place they have to be put in front of it.
    try w.writeAll("],\"own\":");
    try poltergeistpkg.Launchers.writeOwn(w, self.ownClis());
    try w.writeAll("}");
    return try out.toOwnedSlice();
}

test "2237: a CLI the machine has the wrong version of is held back, and one the machine has not is not" {
    const testing = std.testing;
    const wrong = [_][]const u8{"opencode"};
    // The two the plugin itself answers: a switch, and an adapter nothing
    // here can run.
    try testing.expectEqualStrings("plugin_off", heldBackReason(.off, &.{}, "opencode").?);
    try testing.expectEqualStrings("cannot_run", heldBackReason(.cannot_run, &.{}, "opencode").?);
    // On and runnable, and the last inventory said the program here is not
    // one it serves: held back, and **by the name of that reason**, which is
    // what tells a host to say "turn the other plugin on" rather than "this
    // plugin is off".
    try testing.expectEqualStrings("wrong_version", heldBackReason(.ok, &wrong, "opencode").?);
    // Another key's wrong version is not this key's.
    try testing.expect(heldBackReason(.ok, &wrong, "codex") == null);
    // Nothing said about a version: offered, as before.
    try testing.expect(heldBackReason(.ok, &.{}, "opencode") == null);
}

pub const LaunchPersonaError = error{
    NoSuchPersona,
    NotSetUpForCli,
    CliOff,
    CliUnavailable,
    /// Its adapter says the CLI's program is not on this machine (task
    /// 1744): installing it is what the person does, not a switch.
    CliNotInstalled,
    /// Its adapter says the program on this machine is not one it serves
    /// (task 2237): the person installs nothing -- the plugin for the
    /// version that is here is the one to turn on. Kept apart from
    /// `CliNotInstalled`, which is "install it".
    CliWrongVersion,
    NoCli,
    ChooseCli,
    NoExecutable,
};

/// A role and the CLI to start it in, checked against the library.
// --------------------------------------------- the person's launchers (2156)

fn launchersPath(alloc: Allocator) ![]const u8 {
    const personas = try poltergeistpkg.PersonaStore.defaultPath(alloc);
    defer alloc.free(personas);
    return poltergeistpkg.Launchers.pathBeside(alloc, personas);
}

/// The launchers of the person's own, read now; none when there is no file
/// or it does not read (said in the log). In `aa`.
fn launcherSet(self: *App, aa: Allocator) poltergeistpkg.Launchers.Set {
    _ = self;
    const path = launchersPath(aa) catch return .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(global.io(), path, aa, .limited(poltergeistpkg.Launchers.max_bytes)) catch return .{};
    const got = poltergeistpkg.Launchers.parseLeaky(aa, bytes) catch {
        log.warn("launchers: {s} does not read; none are offered", .{path});
        return .{};
    };
    if (got.skipped > 0) log.warn("launchers: {d} in {s} did not read and were left out", .{ got.skipped, path });
    return got.set;
}

/// Written whole and atomically, owner-only: it may hold a token the
/// person chose to write into it.
fn writeLauncherSet(aa: Allocator, set: poltergeistpkg.Launchers.Set) !void {
    const io = global.io();
    const path = try launchersPath(aa);
    var buf: std.Io.Writer.Allocating = .init(aa);
    try poltergeistpkg.Launchers.writeFile(&buf.writer, set);
    const dir = std.fs.path.dirname(path) orelse return error.WriteFailed;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return error.WriteFailed;
    defer d.close(io);
    var atomic = d.createFileAtomic(io, std.fs.path.basename(path), .{
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0) .fromMode(0o600) else .default_file,
        .replace = true,
    }) catch return error.WriteFailed;
    defer atomic.deinit(io);
    atomic.file.writeStreamingAll(io, buf.written()) catch return error.WriteFailed;
    atomic.replace(io) catch return error.WriteFailed;
}

/// The agent CLIs this machine has a plugin for: the preset launchers, and
/// what a launcher of the person's own may stand on.
fn presetLaunchers(aa: Allocator) ![]const poltergeistpkg.agent_cli.Found {
    var env = try global.environMap();
    defer env.deinit();
    return poltergeistpkg.agent_cli.survey(aa, global.io(), &env);
}

/// A line in `group`, from Polter itself: the control room's own sentences
/// (task 2156 v5 -- "退回底子 CLI 也要说出来", and "发言人写 Polter").
///
/// **Signed `[Polter]` in its first word *and* authored by Polter**, which
/// are two different things and both were needed. The signature was there
/// from the start; the author was `Chat.user_id`, so the group drew these
/// under the person's name -- `chatMemberTitle` answers "you" for that id
/// and two hosts colour it as the person (`cli/chat.zig` reads `from_user`
/// off the same zero). The word said Polter and the name said the person.
/// Now `Chat.postAsPolter` writes them under `Chat.polter_id`, which names
/// itself "Polter" and is nobody's member.
///
/// Nothing waits on it, and a group that cannot be posted into is logged
/// rather than raised -- the fall-back has already happened and works
/// either way.
fn sayInGroup(self: *App, group: []const u8, text: []const u8) void {
    const at: u64 = @intCast(self.poltergeistWallMs());
    const posted = self.chat.postAsPolter(group, text, at) catch |err| {
        log.warn("control room: could not say in {s} that an Agent CLI went away err={}", .{ group, err });
        return;
    };
    // The same two things `chatPost` does for a message that came in over
    // the socket, and neither is optional: without `logChat` the sentence is
    // in the group for tonight and gone from the record tomorrow, and
    // without the sweep nobody is notified that it arrived.
    self.logChat(group, posted.seq, poltergeistpkg.Chat.polter_id, at, false, text, 0);
    self.tellTerminalsAboutMessages();
    self.controlRoomTouch();
}

/// A line in every group `by` supervises, and in the log, saying what was
/// changed -- names only (task 2156: "改动要留痕").
fn launcherTrace(self: *App, by: poltergeistpkg.Bus.Id, text: []const u8) void {
    log.info("launchers: {x} {s}", .{ by, text });
    const now: u64 = @intCast(@max(self.poltergeistWallMs(), 0));
    var it = self.chat.groups.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.created_by != by) continue;
        _ = self.chat.post(kv.key_ptr.*, by, text, now) catch {};
    }
}

/// The Agent CLI page of the settings window (task 2156): every preset with
/// whether it can run here, the person's own **with their values** -- this
/// is the one place those are shown, the form that edits them -- and every
/// role, for the switches. In `alloc`.
pub fn settingsLaunchersJson(self: *App, alloc: Allocator) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const set = self.launcherSet(aa);
    const found = try presetLaunchers(aa);
    self.ensurePersonas();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"presets\":[");
    for (found, 0..) |f, i| try w.print("{s}{{\"key\":{f},\"name\":{f},\"standing\":\"{t}\"}}", .{ if (i == 0) "" else ",", std.json.fmt(f.adapter.key, .{}), std.json.fmt(f.adapter.label, .{}), f.standing });
    try w.writeAll("],\"roles\":[");
    for (self.personas.set.personas, 0..) |p, i| try w.print("{s}{{\"key\":{f},\"name\":{f}}}", .{ if (i == 0) "" else ",", std.json.fmt(p.key, .{}), std.json.fmt(p.name, .{}) });
    try w.writeAll("],\"file\":");
    try poltergeistpkg.Launchers.writeFile(w, set);
    try w.writeAll("}");
    return out.toOwnedSlice();
}

/// The settings form saving one Agent CLI of the person's own.
///
/// **It carries no roles any more** (task 2156 v5): the Agent CLI page is
/// the name, the CLI underneath, the command, its variables and its
/// arguments, and which roles may start in it is decided in the role
/// library (`ghostty_app_role_launcher_set`). So the switches the file
/// holds are kept -- `keep_roles` is true -- and a form that arrived
/// without them cannot clear them. A `roles` list that is in the JSON is
/// still written, which is what `launcher_put` sends.
pub fn settingsPutLauncher(self: *App, json: []const u8) !void {
    const L = poltergeistpkg.Launchers;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var l = L.parseOneLeaky(aa, json) catch return error.BadLauncher;
    var env = try global.environMap();
    defer env.deinit();
    l.command = try L.expandHome(aa, l.command, env.get("HOME") orelse env.get("USERPROFILE"));
    const found = try presetLaunchers(aa);
    const bases = try aa.alloc([]const u8, found.len);
    for (found, bases) |f, *b| b.* = f.adapter.key;
    try L.validate(l, bases);
    try writeLauncherSet(aa, try L.put(aa, self.launcherSet(aa), l, true));
    log.info("launchers: the settings window saved {s} (base {s}, {d} variable(s))", .{ l.key, l.base, l.env.len });
}

/// The role library switching one Agent CLI of the person's own on or off
/// for a role, as `role_launcher_set` does (task 2156 v3).
pub fn settingsRoleLauncherSet(self: *App, role: []const u8, key: []const u8, on: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    self.ensurePersonas();
    if (self.personas.set.find(role) == null) return error.NoSuchPersona;
    try writeLauncherSet(aa, try poltergeistpkg.Launchers.setRole(aa, self.launcherSet(aa), key, role, on));
    log.info("launchers: the role library switched {s} {s} for the role {s}", .{ key, if (on) "on" else "off", role });
}

pub fn settingsDeleteLauncher(self: *App, key: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    try writeLauncherSet(aa, try poltergeistpkg.Launchers.delete(aa, self.launcherSet(aa), key));
    log.info("launchers: the settings window deleted {s}", .{key});
}

fn poltergeistLaunchers(
    ctx: *anyopaque,
    alloc: Allocator,
    by: poltergeistpkg.Bus.Id,
    op: poltergeistpkg.rpc.LauncherOp,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const L = poltergeistpkg.Launchers;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const set = self.launcherSet(aa);
    const found = try presetLaunchers(aa);
    const bases = try aa.alloc([]const u8, found.len);
    for (found, bases) |f, *b| b.* = f.adapter.key;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    switch (op) {
        .list => {
            try w.writeAll("{\"presets\":[");
            for (found, 0..) |f, i| try w.print("{s}{{\"key\":{f},\"name\":{f},\"standing\":\"{t}\"}}", .{ if (i == 0) "" else ",", std.json.fmt(f.adapter.key, .{}), std.json.fmt(f.adapter.label, .{}), f.standing });
            try w.writeAll("],\"custom\":[");
            for (set.launchers, 0..) |l, i| {
                if (i > 0) try w.writeAll(",");
                try L.writeSafe(w, l);
            }
            try w.writeAll("]}");
        },
        .put => |text| {
            var l = L.parseOneLeaky(aa, text) catch |err| return switch (err) {
                error.OutOfMemory => err,
                else => error.BadLauncher,
            };
            var env = try global.environMap();
            defer env.deinit();
            l.command = try L.expandHome(aa, l.command, env.get("HOME") orelse env.get("USERPROFILE"));
            // A new one is off for every role; an edit keeps its switches.
            l.roles = &.{};
            try L.validate(l, bases);
            const was = set.find(l.key) != null;
            const next = try L.put(aa, set, l, true);
            try writeLauncherSet(aa, next);
            var line: std.Io.Writer.Allocating = .init(aa);
            try line.writer.print("{s} the Agent CLI {s} (\"{s}\", on {s}, variables: ", .{ if (was) "Changed" else "Added", l.key, l.name, l.base });
            for (l.env, 0..) |e, i| try line.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", e.name });
            if (l.env.len == 0) try line.writer.writeAll("none");
            try line.writer.writeAll(").");
            self.launcherTrace(by, line.written());
            try L.writeSafe(w, next.find(l.key).?);
        },
        .delete => |key| {
            const next = try L.delete(aa, set, key);
            try writeLauncherSet(aa, next);
            self.launcherTrace(by, try std.fmt.allocPrint(aa, "Deleted the Agent CLI {s}; the roles it was on for no longer have it.", .{key}));
            try w.print("{{\"deleted\":{f}}}", .{std.json.fmt(key, .{})});
        },
        .role => |r| {
            self.ensurePersonas();
            if (self.personas.set.find(r.role) == null) return error.NoSuchPersona;
            const next = try L.setRole(aa, set, r.launcher, r.role, r.on);
            try writeLauncherSet(aa, next);
            self.launcherTrace(by, try std.fmt.allocPrint(aa, "Switched the Agent CLI {s} {s} for the role {s}.", .{ r.launcher, if (r.on) "on" else "off", r.role }));
            try L.writeSafe(w, next.find(r.launcher).?);
        },
    }
    return out.toOwnedSlice();
}

/// `cli` is always an agent CLI's key; a launcher of the person's own is
/// `launcher`, started on its base (task 2156).
const LaunchChoice = struct {
    key: []const u8,
    cli: []const u8,
    launcher: ?[]const u8 = null,
    /// A squad seat's role with the squad's word laid over it
    /// (`squad.resolve`); null for a start that is not one. Where it is
    /// set, nothing downstream reads the role library again for what the
    /// squad may have changed.
    resolved: ?poltergeistpkg.squad.Resolved = null,
};

/// Everything that can be refused about a launch, refused before anything
/// opens or is typed: a role that does not exist, that is not set up for
/// the CLI asked for, or whose CLI has no adapter here (its plugin is off,
/// or its adapter cannot run) must not leave an empty tab or a half-typed
/// line behind as its only answer. Copies into `alloc`.
///
/// No CLI named: `Persona.defaultCli`, with `by` -- the terminal that
/// asked -- standing for "the CLI of whoever asked" (task 1677): a
/// supervisor running in Codex opens Codex workers. Null for a start
/// nobody's terminal asked for.
fn resolveLaunch(
    self: *App,
    alloc: Allocator,
    key: []const u8,
    cli: []const u8,
    by: ?poltergeistpkg.Bus.Id,
    own: []const poltergeistpkg.ControlRoom.OwnCli,
) !LaunchChoice {
    return self.resolveLaunchSeat(alloc, key, cli, by, own, null);
}

/// `resolveLaunch` for a squad's seat when `seat_over` is set: the checks
/// below are made against **what the seat will start**, not against the
/// role. A squad that moves a member to another CLI is judged on that CLI's
/// entry (which `squad.resolve` makes, empty if the role has none), so the
/// role's own `NotSetUpForCli` / `NoCli` do not refuse it (plan v3 item 13).
fn resolveLaunchSeat(
    self: *App,
    alloc: Allocator,
    key: []const u8,
    cli_asked: []const u8,
    by: ?poltergeistpkg.Bus.Id,
    own: []const poltergeistpkg.ControlRoom.OwnCli,
    seat_over: ?poltergeistpkg.squad.Override,
) !LaunchChoice {
    self.ensurePersonas();
    const role = self.personas.set.find(key) orelse return error.NoSuchPersona;
    var p = role;
    var cli = cli_asked;
    if (seat_over) |over| {
        // A CLI the person's squad names, when the caller named none.
        if (cli_asked.len == 0) cli = over.cli orelse "";
        // Named by the squad, or named by the caller and set up in the
        // role: the entry for it is what is judged, and the squad may have
        // given the role an entry it did not have. A caller's CLI that the
        // role is not set up for stays a launcher or a refusal below.
        if (cli.len > 0 and (cli_asked.len == 0 or role.cli(cli) != null)) {
            p = (poltergeistpkg.squad.resolve(alloc, role, over, cli, &.{}, null) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.NoCli,
            }).persona;
        }
    }
    // A launcher of the person's own, by its key where the CLI goes (task
    // 2156): switched on for this role, and started on its base with the
    // role's choices for that CLI -- every check below is the base's.
    // A role need not be set up for the base itself: it then starts with
    // nothing chosen for it, as `+launch` does.
    var via: ?[]const u8 = null;
    var asked = cli;
    if (cli.len > 0 and p.cli(cli) == null) {
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        if (self.launcherSet(arena.allocator()).find(cli)) |l| {
            if (!l.enabledFor(p.key)) return error.LauncherNotOn;
            via = try alloc.dupe(u8, l.key);
            asked = try alloc.dupe(u8, l.base);
        }
    }
    // None named, and the role has some of the person's own ticked (task
    // 2156 v3): those count as its CLIs do. Which one is `ControlRoom.pickOwn`,
    // so that what it decides can be read without an App.
    if (cli.len == 0) {
        const by_via: []const u8 = if (by) |id|
            (if (id == poltergeistpkg.Chat.user_id) "" else self.poltergeist.agentOf(id).launcher.get() orelse "")
        else
            "";
        const by_cli: ?[]const u8 = if (by) |id|
            (if (id == poltergeistpkg.Chat.user_id) null else self.poltergeist.agentOf(id).cli.get())
        else
            null;
        var ticked: std.ArrayListUnmanaged(poltergeistpkg.ControlRoom.OwnCli) = .empty;
        for (own) |o| for (o.roles) |r| {
            if (std.mem.eql(u8, r, p.key)) try ticked.append(alloc, o);
        };
        if (poltergeistpkg.ControlRoom.pickOwn(
            ticked.items,
            p.clis.len,
            by_via,
            by_cli,
            if (by_cli) |c| p.cli(c) != null else false,
        )) |pick| switch (pick) {
            .own => |o| {
                via = try alloc.dupe(u8, o.key);
                asked = try alloc.dupe(u8, o.base);
            },
            .cli => |c| asked = try alloc.dupe(u8, c),
            .choose => return error.ChooseCli,
        };
    }
    if (via == null) {
        if (p.clis.len == 0) return error.NoCli;
        if (asked.len > 0 and p.cli(asked) == null) return error.NotSetUpForCli;
    }

    // Which CLIs have an adapter here. This reads the plugin directories
    // and their manifests and starts nothing -- whether an adapter can run
    // is settled by its file's kind (`Plugin.Manifest.runnable`), not by a
    // PATH -- so it is fit for this thread.
    var env = try global.environMap();
    defer env.deinit();
    const surveyed = poltergeistpkg.agent_cli.survey(alloc, global.io(), &env);
    // And what the last inventory found cannot start here (tasks 1744,
    // 2237): not a default, and refused by name when asked for. Nothing
    // read yet is not "cannot".
    const cannot: poltergeistpkg.ControlRoom.NotStartable = (try self.cannotStart(alloc)) orelse .{};
    var ok: std.ArrayListUnmanaged([]const u8) = .empty;
    for (surveyed) |f| if (f.standing == .ok and whyNotStartable(cannot, f.adapter.key) == null)
        try ok.append(alloc, f.adapter.key);
    const keys = ok.items;

    // The asker's own CLI, for `defaultCli`: named apart from `own`, which
    // is what the person has of their own.
    const asker_cli: ?[]const u8 = if (by) |id|
        (if (id == poltergeistpkg.Chat.user_id) null else self.poltergeist.agentOf(id).cli.get())
    else
        null;
    const chosen: []const u8 = if (asked.len > 0) asked else try p.defaultCli(keys, asker_cli);
    // The refusals, because the person does something different about each:
    // a plugin that is off is a switch in Plugins; one whose adapter
    // nothing here can run, or no plugin at all, no switch fixes; a
    // program that is not here is installed; and one that is here at
    // another major version is not installed at all -- the other plugin is
    // turned on (task 2237).
    for (surveyed) |f| {
        if (!std.mem.eql(u8, f.adapter.key, chosen)) continue;
        switch (f.standing) {
            .ok => if (whyNotStartable(cannot, chosen)) |why| return why,
            .off => return error.CliOff,
            .cannot_run => return error.CliUnavailable,
        }
        break;
    } else return error.CliUnavailable;
    const resolved: ?poltergeistpkg.squad.Resolved = if (seat_over) |over|
        (poltergeistpkg.squad.resolve(alloc, role, over, chosen, keys, asker_cli) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NoCli => error.NoCli,
            error.ChooseCli => error.ChooseCli,
        })
    else
        null;
    return .{ .key = try alloc.dupe(u8, p.key), .cli = try alloc.dupe(u8, chosen), .launcher = via, .resolved = resolved };
}

/// The error for a CLI whose program is here but cannot be started, or null
/// when it can. `missing` first: an adapter that said that has no version
/// to judge, and one key is never in both lists.
fn whyNotStartable(cannot: poltergeistpkg.ControlRoom.NotStartable, key: []const u8) ?LaunchPersonaError {
    if (isAnyOf(cannot.missing, key)) return error.CliNotInstalled;
    if (isAnyOf(cannot.wrong_version, key)) return error.CliWrongVersion;
    return null;
}

fn isAnyOf(keys: []const []const u8, key: []const u8) bool {
    for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// The line typed into a terminal to start a role there:
/// `'<this executable>' +launch <role> <cli>` -- on Windows
/// `& '<polter-cli.exe>' +launch …`, see below. Both keys are `[a-z0-9-]`
/// by construction, so the only thing that needs quoting is the path.
fn launchLine(alloc: Allocator, choice: LaunchChoice) ![]const u8 {
    return launchLineFor(alloc, choice, .none);
}

/// `launchLine`, with the two words only the control room adds
/// (`agent_cli.LaunchFor`): the group a supervisor is started for and the
/// session it goes on with.
fn launchLineFor(
    alloc: Allocator,
    choice: LaunchChoice,
    extra: poltergeistpkg.agent_cli.LaunchFor,
) ![]const u8 {
    const io = global.io();
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0 .. std.process.executablePath(io, &exe_buf) catch
        return error.NoExecutable];

    var line: std.Io.Writer.Allocating = .init(alloc);
    if (comptime builtin.os.tag == .windows) {
        // Three differences from POSIX. The line is run by `polter-cli.exe`,
        // the console build beside this one: `+launch` puts an agent CLI on
        // the tab's console, and the GUI build has none to give it (the
        // reason `+chat` goes there too). It is typed for PowerShell, the
        // shell a Windows tab starts, where a quoted path is run with `&`
        // and a quote inside single quotes is doubled. And there is no exec,
        // which `cli/launch.zig` deals with.
        const dir = std.fs.path.dirname(exe) orelse return error.NoExecutable;
        const cli_exe = try std.fs.path.join(alloc, &.{ dir, "polter-cli.exe" });
        std.Io.Dir.cwd().access(io, cli_exe, .{}) catch return error.NoExecutable;
        try line.writer.writeAll("& '");
        for (cli_exe) |c| {
            if (c == '\'') try line.writer.writeAll("''") else try line.writer.writeByte(c);
        }
    } else {
        try line.writer.writeAll("'");
        for (exe) |c| {
            if (c == '\'') try line.writer.writeAll("'\\''") else try line.writer.writeByte(c);
        }
    }
    try line.writer.writeAll("'");
    var with = extra;
    if (choice.launcher) |l| with.launcher = l;
    try poltergeistpkg.agent_cli.writeLaunchWords(&line.writer, choice.key, choice.cli, with);
    return line.written();
}

/// Put a terminal in the role, give it the role's Polter standing, and
/// type the line that starts it there. `by` is the terminal the launch was
/// asked from -- a supervisor's for `role_launch`, the clicked one for the
/// menu, and `id` itself when the role starts where it was clicked.
fn startRoleIn(
    self: *App,
    id: poltergeistpkg.Bus.Id,
    by: poltergeistpkg.Bus.Id,
    choice: LaunchChoice,
    line: []const u8,
    who: Surface.Typist,
) anyerror!void {
    return self.startRoleInAs(id, by, choice, line, who, null);
}

/// `startRoleIn` for a squad's seat when `effective` is set: the launch is
/// recorded with the squad's settings, and once the line is typed the
/// terminal takes its seat in the task.
fn startRoleInAs(
    self: *App,
    id: poltergeistpkg.Bus.Id,
    by: poltergeistpkg.Bus.Id,
    choice: LaunchChoice,
    line: []const u8,
    who: Surface.Typist,
    effective: ?poltergeistpkg.persona.Effective,
) anyerror!void {
    const surface = self.findSurfaceByID(id) orelse return error.UnknownTerminal;

    // Asked before the role is recorded: a launch that cannot be typed must
    // not leave the terminal wearing a role it never started (#1202).
    try surface.mayTypeAs(who);

    // Wearing the role, the launch recorded for `terminal_capabilities`
    // (copied now: an edit to the role later does not reach a CLI that is
    // already running), and the role's Polter half **held for the agent,
    // not applied** -- applied before the line was typed, a `+launch` that
    // failed left a supervisor with no agent in it (measured on the Windows
    // machine). All three in `PersonaStore.startRole`, the one place every
    // way of starting a role goes through.
    self.ensurePersonas();
    self.personas.startRoleAs(id, by, choice.key, choice.cli, self.poltergeistElapsedMs(), effective) catch |err| {
        log.warn("poltergeist: starting {s} but could not record it err={}", .{ choice.key, err });
    };
    self.wakePersonaWaits(id);
    self.refreshPoltergeistTabs();
    if (self.terminal_meta) |*m| m.role(id, self.poltergeistWallMs(), choice.key);

    try surface.typePoltergeistTextAs(line, true, who);
    // A supervisor's launch line is a line that supervisor submitted there
    // (`Bus.noteTypedBy`, task 1971): what puts the agent in the group the
    // line names (`launchJoin`'s `join_as_typed`) even before the pane is
    // recorded as its worker -- a split on Windows is attributed later.
    if (self.poltergeist.isSupervisor(by)) self.poltergeist.noteTypedBy(id, by, self.poltergeistElapsedMs()) catch {};
    // Its CLI is starting from now until its agent is heard (task 1974).
    self.launching.put(self.alloc, id, .{
        .deadline_ms = self.poltergeistElapsedMs() +| poltergeistpkg.Bus.launch_agent_wait_ms,
        .typed_at = .now(global.io(), .boot),
    }) catch {};
    if (effective) |e| self.joinSeat(id, e);
}

/// A terminal started for a squad's seat takes it: the seat is `filled`,
/// the lead's terminal becomes the task's owner, and the joining is
/// written down. After the line is typed, so a start that could not be
/// typed leaves the seat empty.
fn joinSeat(self: *App, id: poltergeistpkg.Bus.Id, e: poltergeistpkg.persona.Effective) void {
    const at = self.taskWallMs();
    self.tasks.join(e.task, e.alias, "", id, "", at, e.lead) catch |err| {
        log.warn("poltergeist: terminal {x} could not take the seat {s} of task {d} err={}", .{ id, e.alias, e.task, err });
        return;
    };
    self.logSeat(.joined, e.task, e.alias, id);
    self.controlRoomTouch();
}

/// Write down that a terminal took, or gave up, a seat.
fn logSeat(self: *App, op: poltergeistpkg.TaskLog.MemberOp, task: u64, alias: []const u8, id: poltergeistpkg.Bus.Id) void {
    const l = if (self.task_log) |*v| v else return;
    const t = self.tasks.get(task) orelse return;
    l.appendMember(self.taskWallMs(), op, t, .{ .alias = alias, .id = id, .session = "" });
}

/// A request has come from terminal `id` (`rpc.arrived`): if a role launch
/// is holding a standing for the agent it started there, give it now --
/// before that request is answered, so the agent's first `me` already
/// reads it. The bus half is `PersonaStore.claimStanding`; what is left
/// here is the half that lives on the surface.
fn poltergeistAgentArrived(
    ctx: *anyopaque,
    bus: *poltergeistpkg.Bus,
    id: poltergeistpkg.Bus.Id,
) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.identifyIfHandStarted(bus, id);
    // Before the standing's early return: an agent started by hand in a
    // project's supervisor's pane has no standing to claim (task 1795).
    self.seatAgentArrived(id);
    // A supervisor's terminal whose group somebody else has now: what the
    // agent before it had there is not this one's (task 1864).
    self.dropIfSuperseded(id);
    // A launch said which group its agent is for (task 1844): judged now
    // that the agent is heard, once.
    self.launchGroupArrived(id);
    // Its launch has an agent: the pane is that agent's (task 1974).
    _ = self.launching.remove(id);
    const applied = self.personas.claimStanding(bus, id, self.poltergeistElapsedMs()) orelse return;
    defer self.refreshPoltergeistTabs();
    defer self.saveSession();
    // After the standing: a supervisor the control room started is put in
    // its group once it is one.
    self.controlStartConnected(id);

    const surface = self.findSurfaceByID(id) orelse return;
    if (applied.watched_by != null) surface.setPoltergeistWatching(true);
    if (applied.want.quiet_ms) |ms| surface.setPoltergeistThreshold(ms);
}

/// `id` joined `group`: every other member it took the group over from
/// gives its place up (`ControlRoom.supersededIn`, task 1864).
fn dropSupersededBy(self: *App, group: []const u8, id: poltergeistpkg.Bus.Id) void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const members = self.chat.membersOf(arena.allocator(), group) catch return;
    for (members) |m| {
        if (m != id) _ = self.dropSuperseded(group, m);
    }
}

/// An agent is talking to Polter from supervisor `id`: in each group it was
/// taken over from while it was away, it gives up its place (task 1864).
/// The other side of `dropSupersededBy`, for a takeover no add went
/// through. Asked at every request, so the cheap question is first.
fn dropIfSuperseded(self: *App, id: poltergeistpkg.Bus.Id) void {
    if (!self.poltergeist.isSupervisor(id)) return;
    var any = false;
    var it = self.chat.groups.keyIterator();
    // Only members of the group are taken out, never a group: the
    // iteration is over a map nothing below changes.
    while (it.next()) |name| {
        if (self.dropSuperseded(name.*, id)) any = true;
    }
    if (any) self.saveSession();
}

/// `id` gives up its place in `group`, and its standing with it when it is
/// in no group now, if somebody else minds `group`; the group's workers it
/// was minding go to that one. True when it did.
fn dropSuperseded(self: *App, group: []const u8, id: poltergeistpkg.Bus.Id) bool {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const dropped = (poltergeistpkg.ControlRoom.dropSuperseded(
        arena.allocator(),
        &self.poltergeist,
        &self.chat,
        group,
        id,
    ) catch return false) orelse return false;
    // The same record a `group_remove` leaves.
    if (self.session_log) |*l| l.left(group, self.poltergeistWallMs(), id, false);
    log.info("poltergeist: 0x{x} gives up its place in {s}, which 0x{x} minds now, " ++
        "and is a supervisor still: {}", .{ id, group, dropped.by, self.poltergeist.isSupervisor(id) });
    for (dropped.passed) |w| log.info("poltergeist: watching of 0x{x} passes to 0x{x}", .{ w, dropped.by });
    self.refreshPoltergeistTabs();
    return true;
}

/// An agent is talking to Polter from `id`. When `id` is in the pane a
/// group's project marks as its supervisor's, the agent is that group's
/// supervisor and is put in the group -- unless the group has one already,
/// which a project may not have two of, and which is said in the group
/// instead (task 1795, `Projects.seatClaim`). Decided once per terminal.
///
/// Only this road: `become_supervisor` and `group_add` by hand are left as
/// they are, so a person can still take a group over themselves.
fn seatAgentArrived(self: *App, id: poltergeistpkg.Bus.Id) void {
    const bus = &self.poltergeist;
    // The one that was judged here has left since: whoever this is, is
    // judged. Not while a left from before it is still on the bus.
    const left = bus.agentHasLeft(id);
    // And which agent this is, by its connection (task 1829): a request
    // with no agent connected -- a hook's, before its CLI has -- judges
    // nothing; the agent's own first request does.
    const round = self.agentRound(id);
    self.seat_judged.seen(id, left, round);
    if (round == 0) return;
    const agent = poltergeistpkg.Projects.SeatJudged.agentKey(bus.agentOf(id).session_id.get());
    // The cheap questions first: this runs at every request.
    if (!self.seat_judged.due(id, agent)) return;
    if (!self.projects.isSeated(id)) return;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now_ms = self.poltergeistElapsedMs();
    const views = self.projectViews(alloc, now_ms) catch return;
    const supervises_another = for (views) |v| {
        if (v.steward) |s| if (s == id) break true;
    } else false;
    const claim = self.projects.seatClaim(views, .{
        .terminal = id,
        .watched = bus.roleOf(id) == .watched,
        .supervises_another = supervises_another,
        .being_started = self.chat.startingIn(id, now_ms) != null,
    });
    var buf: [512]u8 = undefined;
    switch (claim) {
        .none => return,
        .watched => |w| {
            self.seat_judged.judged(self.alloc, id, agent, left, round) catch {};
            log.warn("poltergeist: an agent in project {s}'s supervisor's pane is watched by a supervisor; not made {s}'s", .{ w.project, w.group });
        },
        .refuse => |r| {
            self.seat_judged.judged(self.alloc, id, agent, left, round) catch {};
            log.warn("poltergeist: an agent in project {s}'s supervisor's pane, but {s} has a supervisor already; not made one", .{ r.project, r.group });
            // What the agent before it had there goes with the refusal
            // (task 1836): it is not the supervisor, and not in the group.
            const was_member = self.chat.isMember(r.group, id);
            if (poltergeistpkg.ControlRoom.dropRefusedSeat(bus, &self.chat, r.group, id)) {
                // The same record a `group_remove` leaves.
                if (was_member) if (self.session_log) |*l| l.left(r.group, self.poltergeistWallMs(), id, false);
                log.info("poltergeist: the refused pane 0x{x} gives up the supervisor's standing and its place in {s} that the agent before it had", .{ id, r.group });
                self.refreshPoltergeistTabs();
                self.saveSession();
            }
            const text = std.fmt.bufPrint(&buf, "[Polter] An agent started in project {s}'s supervisor's pane (0x{x:0>16}), " ++
                "but {s} already has a supervisor (0x{x:0>16}): it was not made one. A project has one supervisor.", .{ r.project, id, r.group, r.steward }) catch return;
            _ = chatPost(self, r.group, r.steward, text, .none) catch |err| {
                log.warn("poltergeist: could not say so in {s} err={}", .{ r.group, err });
            };
            self.controlRoomTouch();
        },
        .take => |t| {
            self.seat_judged.judged(self.alloc, id, agent, left, round) catch {};
            if (!bus.isSupervisor(id)) bus.addSupervisor(id) catch |err| {
                log.warn("poltergeist: could not make the agent in {s}'s supervisor's pane a supervisor err={}", .{ t.project, err });
                return;
            };
            chatAdd(self, t.group, id, .all) catch |err| {
                log.warn("poltergeist: could not put the supervisor in {s} err={}", .{ t.group, err });
                return;
            };
            log.info("poltergeist: the agent in project {s}'s supervisor's pane is {s}'s supervisor now", .{ t.project, t.group });
            const text = std.fmt.bufPrint(&buf, "[Polter] This terminal is in project {s}'s supervisor's pane, " ++
                "and is {s}'s supervisor now.", .{ t.project, t.group }) catch return;
            _ = chatPost(self, t.group, id, text, .none) catch |err| {
                log.warn("poltergeist: could not say so in {s} err={}", .{ t.group, err });
            };
            const told = std.fmt.bufPrint(&buf, "[Polter] This terminal is in the supervisor's pane of project {s}, " ++
                "so you are the supervisor of group `{s}` now. Read the `supervising` skill with the polter " ++
                "MCP tool skill_read, then group_read `{s}` and task_list before doing anything else.", .{ t.project, t.group, t.group }) catch return;
            self.tellSurface(id, told);
            self.refreshPoltergeistTabs();
            self.saveSession();
        },
    }
}

/// An agent that is talking to Polter from `id` with no hooks and no role
/// launch behind it was started by hand: ask the adapters who it is (task
/// 1635). Once per agent -- `Identities.ask` does nothing for a terminal
/// it already has -- and forgotten when the agent goes (`controlRoomTick`).
fn identifyIfHandStarted(self: *App, bus: *poltergeistpkg.Bus, id: poltergeistpkg.Bus.Id) void {
    if (self.personas.launchOf(id) != null) return;
    if (bus.agentOf(id).hooks != .none) return;
    const srv = if (self.poltergeist_server) |*s| s else return;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const sighting = srv.sightingOf(arena.allocator(), id) catch return;
    self.identities.ask(global.io(), id, sighting, self.terminalCwd(arena.allocator(), id), self.poltergeistElapsedMs());
}

/// Where the shell in `id` last said it was, or null. With an agent CLI in
/// the foreground that is the directory it was started in, which is what an
/// adapter can match the CLI's own session records against when the process
/// does not say (task 1667: a Codex whose session runs in its app-server
/// daemon).
fn terminalCwd(self: *App, alloc: Allocator, id: poltergeistpkg.Bus.Id) ?[]const u8 {
    const surface = self.findSurfaceByID(id) orelse return null;
    return surface.pwd(alloc) catch null;
}

/// What the control room is told about an agent started by hand in `id`
/// (task 1635). Asks the adapters the first time it is wanted -- an agent
/// that has not called a tool yet has sent no request to start the asking
/// from -- and forgets the answer once the agent has gone.
fn hooklessOf(self: *App, arena: Allocator, id: poltergeistpkg.Bus.Id) poltergeistpkg.ControlRoom.Hookless {
    const io = global.io();
    if (!self.agentPresent(id)) {
        self.identities.forget(io, id);
        return .no;
    }
    if (self.personas.launchOf(id) != null) return .no;
    if (self.poltergeist.agentOf(id).hooks != .none) return .no;
    const v = (self.identities.view(io, arena, id) catch return .asking) orelse {
        self.identifyIfHandStarted(&self.poltergeist, id);
        return .asking;
    };
    const now_ms = self.poltergeistElapsedMs();
    // When its session was last written goes on changing: ask again now
    // and then, so that "is it still that session" is not an hour old.
    if (v.state == .known) if (self.poltergeist_server) |*srv| {
        const sighting = srv.sightingOf(arena, id) catch poltergeistpkg.agent_cli.Sighting.none;
        // An answer with no session in it is asked again soon (task 1674):
        // the first ask comes before the CLI's first turn, when it has no
        // record yet, and a take-over within the minute after that turn
        // used to be offered "a new session" for a Codex that had one.
        const every = if (v.identified.session == null) identity_unsure_refresh_ms else identity_refresh_ms;
        self.identities.refresh(io, id, sighting, self.terminalCwd(arena, id), now_ms, every);
    };
    return switch (v.state) {
        .asking => .asking,
        .unknown => .unknown,
        .known => known: {
            const wall: i64 = self.poltergeistWallMs();
            const last_call: ?i64 = if (self.poltergeist.callSilentMs(id, now_ms)) |silent| wall - @as(i64, @intCast(silent)) else null;
            const session = v.identified.session;
            const written = v.identified.session_written_ms;
            break :known .{ .known = .{
                .label = v.label,
                .session = session != null,
                .session_short = if (session) |sid| sid[0..@min(8, sid.len)] else "",
                .sure = session != null and poltergeistpkg.TakeOver.sure(written, last_call),
                .written_min = if (written) |w| @intCast(@divFloor(@max(0, wall - w), std.time.ms_per_min)) else null,
                .can_quit = v.identified.quit != null,
            } };
        },
    };
}

/// How often what an adapter said of a hand-started agent is asked again.
const identity_refresh_ms: u64 = 60 * std.time.ms_per_s;

/// How often an answer that named no session is asked again (task 1674).
const identity_unsure_refresh_ms: u64 = 5 * std.time.ms_per_s;

/// A take-over under way (task 1635).
const TakeOverRun = struct {
    group: []u8,
    terminal: poltergeistpkg.Bus.Id,
    phase: poltergeistpkg.TakeOver.Phase,
    /// When the phase is next looked at, or gives up.
    at_ms: u64,
    /// The screen as it was when last looked at: it has to be the same
    /// `settle_ms` later.
    screen: []u8,
    /// How many more times a screen that moved is looked at again.
    tries: u8 = poltergeistpkg.TakeOver.settle_tries,
    /// The CLI to start again, and the session it goes on with.
    cli: []u8,
    /// The Agent CLI of the person's own the supervisor that quit was started
    /// through, by key (task 2156 v3); empty for the CLI as its plugin starts
    /// it. Taken at the press, while its agent is still there to be asked:
    /// nothing says it once the agent has gone.
    launcher: []u8,
    session: ?[]u8,

    fn deinit(self: *TakeOverRun, alloc: Allocator) void {
        alloc.free(self.group);
        alloc.free(self.screen);
        alloc.free(self.cli);
        alloc.free(self.launcher);
        if (self.session) |sid| alloc.free(sid);
    }
};

const TakeOverFailed = struct {
    group: []u8,
    why: poltergeistpkg.TakeOver.Why,
};

/// How often a take-over that waits on something looks again.
const take_over_poll_ms: u64 = 500;

/// "Let the control room take over?": check that there is something to
/// take over, look at its screen, and leave the rest to `takeOverStep`.
/// **Nothing is typed here**: the screen has to be the same in
/// `TakeOver.settle_ms`, and then it is the step that types.
fn controlActTakeOver(ctx: *anyopaque, group: []const u8) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.take_over != null) return error.AlreadyTakingOver;
    const id = controlActStewardOf(ctx, group) orelse return error.NotStartedByHand;
    const surface = self.findSurfaceByID(id) orelse return error.NotStartedByHand;
    if (!self.agentPresent(id) or self.personas.launchOf(id) != null or
        self.poltergeist.agentOf(id).hooks != .none) return error.NotStartedByHand;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = global.io();
    const v = (try self.identities.view(io, aa, id)) orelse return error.NotStartedByHand;
    if (v.state != .known or v.identified.quit == null) return error.NotStartedByHand;
    surface.mayTypeAs(.agent) catch |err| return controlActRefusal(err);

    const screen = try surface.activeText(aa);
    const now_ms = self.poltergeistElapsedMs();
    var run: TakeOverRun = .{
        .group = try self.alloc.dupe(u8, group),
        .terminal = id,
        .phase = .settling,
        .at_ms = now_ms + poltergeistpkg.TakeOver.settle_ms,
        .screen = &.{},
        .cli = &.{},
        .launcher = &.{},
        .session = null,
    };
    errdefer run.deinit(self.alloc);
    run.screen = try self.alloc.dupe(u8, screen);
    run.cli = try self.alloc.dupe(u8, v.key);
    // What it was started through (task 2156 v3), asked here, at the press:
    // the agent is still there to be asked, and the bus forgets it when the
    // CLI quits (`Bus.noteLeft`).
    run.launcher = try self.alloc.dupe(u8, self.poltergeist.agentOf(id).launcher.get() orelse "");
    if (v.identified.session) |sid| run.session = try self.alloc.dupe(u8, sid);
    self.take_over = run;
    // Asked again now, whatever its age: the answer the settling step reads
    // is the one taken at the press, not one from up to a minute before.
    if (self.poltergeist_server) |*srv| {
        const sighting = srv.sightingOf(aa, id) catch poltergeistpkg.agent_cli.Sighting.none;
        self.identities.refresh(io, id, sighting, self.terminalCwd(aa, id), now_ms, 0);
    }
    if (self.take_over_failed) |f| {
        self.alloc.free(f.group);
        self.take_over_failed = null;
    }
    log.info("control room: taking over the supervisor of a group, cli={s} session={s}", .{
        v.key, if (v.identified.session != null) "found" else "none",
    });
    self.controlRoomTouch();
}

/// What the snapshot is told of the take-over (`ControlRoom.TakeOverIn`).
fn takeOverIn(self: *App) ?poltergeistpkg.ControlRoom.TakeOverIn {
    if (self.take_over) |t| return .{ .group = t.group, .state = .{ .running = t.phase } };
    if (self.take_over_failed) |f| return .{ .group = f.group, .state = .{ .failed = f.why } };
    return null;
}

/// Stop the take-over without taking over, and say why.
fn takeOverFail(self: *App, why: poltergeistpkg.TakeOver.Why) void {
    var run = self.take_over orelse return;
    self.take_over = null;
    log.warn("control room: the take-over stopped ({t})", .{why});
    if (self.take_over_failed) |f| self.alloc.free(f.group);
    self.take_over_failed = .{ .group = run.group, .why = why };
    run.group = &.{};
    run.deinit(self.alloc);
    self.controlRoomTouch();
}

/// Move a take-over on, if one is under way and its moment has come.
/// Returns when it next wants to be looked at.
///
/// **Settling**: the same screen as at the press, and the adapter's rule
/// says it is waiting at its prompt; then the quit is typed, through the
/// guards an agent's text goes through. **Quitting**: its sidecar has gone
/// and its shell is at the prompt again; then the supervisor's role is
/// started there, going on with the session, the way the control room
/// starts one. **Starting**: `+launch` has said it is coming (its hooks are
/// expected); then it is over. Each has its deadline, and each way of not
/// getting there is said (`TakeOver.Why`).
fn takeOverStep(self: *App, now_ms: u64) ?u64 {
    const run = if (self.take_over) |*t| t else return null;
    const TakeOver = poltergeistpkg.TakeOver;
    const surface = self.findSurfaceByID(run.terminal) orelse {
        self.takeOverFail(.did_not_quit);
        return null;
    };
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    switch (run.phase) {
        .settling => {
            if (now_ms < run.at_ms) return run.at_ms;
            // Each way of not going on says which it was: they all tell the
            // person "busy", and only the log can tell them apart.
            const v = (self.identities.view(global.io(), aa, run.terminal) catch null) orelse {
                log.warn("control room: take-over: the terminal is no longer identified", .{});
                self.takeOverFail(.busy);
                return null;
            };
            const quit = v.identified.quit orelse {
                log.warn("control room: take-over: its adapter has no screen rule any more", .{});
                self.takeOverFail(.busy);
                return null;
            };
            // The answer asked for at the press, when it has come.
            const use = TakeOver.sessionToUse(run.session, v.identified.session);
            if (use) |sid| if (run.session == null or !std.mem.eql(u8, run.session.?, sid)) {
                const kept = self.alloc.dupe(u8, sid) catch {
                    self.takeOverFail(.busy);
                    return null;
                };
                if (run.session) |old| self.alloc.free(old);
                run.session = kept;
                log.info("control room: take-over: its session is known now", .{});
            };
            if (!self.agentPresent(run.terminal)) {
                log.warn("control room: take-over: its agent went away before the quit", .{});
                self.takeOverFail(.busy);
                return null;
            }
            surface.mayTypeAs(.agent) catch |err| {
                log.warn("control room: take-over: may not type into it err={}", .{err});
                self.takeOverFail(.typing);
                return null;
            };
            const screen = surface.activeText(aa) catch |err| {
                log.warn("control room: take-over: could not read its screen err={}", .{err});
                self.takeOverFail(.busy);
                return null;
            };
            switch (TakeOver.settle(run.screen, screen, quit, run.tries)) {
                .quit => {},
                .again => {
                    log.info("control room: take-over: the screen moved, looking again ({d} left)", .{run.tries});
                    const kept = self.alloc.dupe(u8, screen) catch {
                        self.takeOverFail(.busy);
                        return null;
                    };
                    self.alloc.free(run.screen);
                    run.screen = kept;
                    run.tries -= 1;
                    run.at_ms = now_ms + TakeOver.settle_ms;
                    return run.at_ms;
                },
                .busy => {
                    log.warn("control room: take-over: busy, moved={} ready={}", .{
                        !std.mem.eql(u8, screen, run.screen), TakeOver.ready(screen, quit),
                    });
                    self.takeOverFail(.busy);
                    return null;
                },
            }
            surface.typePoltergeistTextAs(quit.text, true, .agent) catch {
                self.takeOverFail(.typing);
                return null;
            };
            log.info("control room: take-over typed the quit, waiting for it to end", .{});
            run.phase = .quitting;
            run.at_ms = now_ms + TakeOver.quit_ms;
            self.controlRoomTouch();
            return now_ms + take_over_poll_ms;
        },
        .quitting => {
            const present = self.agentPresent(run.terminal);
            if (TakeOver.quitDone(present, surface.shellIdle())) {
                if (present) log.info("control room: take-over: its shell is back at the prompt and its Polter connection stays; going on", .{});
                self.takeOverLaunch(aa, now_ms) catch |err| {
                    log.warn("control room: take-over could not start it again err={}", .{err});
                    self.takeOverFail(.cannot_start);
                    return null;
                };
                return now_ms + take_over_poll_ms;
            }
            if (now_ms >= run.at_ms) {
                self.takeOverFail(.did_not_quit);
                return null;
            }
            return now_ms + take_over_poll_ms;
        },
        .starting => {
            if (self.poltergeist.agentOf(run.terminal).hooks != .none) {
                log.info("control room: take-over done, its hooks are expected", .{});
                var done = self.take_over.?;
                self.take_over = null;
                done.deinit(self.alloc);
                self.controlRoomTouch();
                return null;
            }
            if (now_ms >= run.at_ms) {
                self.takeOverFail(.did_not_start);
                return null;
            }
            return now_ms + take_over_poll_ms;
        },
    }
}

/// The CLI has quit: start the supervisor's role in its terminal, going on
/// with its session, recorded as the control room records a start.
fn takeOverLaunch(self: *App, aa: Allocator, now_ms: u64) !void {
    const run = &self.take_over.?;
    const ControlRoom = poltergeistpkg.ControlRoom;
    const Store = poltergeistpkg.PersonaStore;
    self.ensurePersonas();
    const last = self.chat.lastSupervisorOf(run.group);
    // Once for the whole take-over, as the start does (task 2156 v3).
    const own = self.ownClis();
    const roles = try self.controlStartRoles(aa, own);
    const role = ControlRoom.startRoleOf(roles, last) orelse return error.NoSupervisorRole;
    // Through what the supervisor that quit was started through, while it is
    // still there and still ticked for this role (task 2156 v3): a take-over
    // is the same start the person made, put back. On its CLI otherwise.
    const cli = ControlRoom.takeOverThrough(run.launcher, run.cli, own, role.key);
    // **A take-over that goes in the CLI underneath says so** (task 2156
    // v5): the supervisor that quit was started through an Agent CLI of the
    // person's own that has been deleted or unticked for this role since,
    // and what the control room is putting back is not what was there.
    //
    // **`resolveLaunch` first, and the sentence only if it agreed** (review
    // of v5). Said the other way round, a role not set up for the CLI
    // underneath heard "…so the take-over starts Z instead" and then got
    // `NotSetUpForCli` -- the words and what happened were two different
    // things. Where it refuses, the refusal is what the person is told, and
    // the group hears nothing that did not come true.
    const choice = try self.resolveLaunch(aa, role.key, cli, null, own);
    if (ControlRoom.lostLauncher(last, own, role.key)) |gone| {
        const was = ControlRoom.cliLabelOf(try self.controlCliNames(aa, own), gone) orelse gone;
        // What it actually went in, which is `choice`'s answer and not the
        // name asked for: `resolveLaunch` is the one that decided.
        const now = ControlRoom.cliLabelOf(try self.controlCliNames(aa, own), choice.launcher orelse choice.cli) orelse choice.cli;
        self.sayInGroup(run.group, try std.fmt.allocPrint(
            aa,
            "[Polter] The Agent CLI \"{s}\" is no longer switched on for the role {s}, so the take-over starts {s} instead.",
            .{ was, role.name, now },
        ));
    }
    const line = try launchLineFor(aa, choice, .{ .group = run.group, .session = run.session });

    self.chat.beginStart(run.group, now_ms, now_ms + Store.pending_launch_ms, run.session != null, .directory) catch {};
    self.chat.startOpened(run.group, run.terminal, now_ms + Store.standing_wait_ms);
    errdefer self.chat.endStart(run.group);
    // What was known of the CLI that quit is not what the new one is.
    self.identities.forget(global.io(), run.terminal);
    try self.startRoleIn(run.terminal, poltergeistpkg.Chat.user_id, choice, line, .agent);
    log.info("control room: take-over started the supervisor again, role {s}, session={s}", .{
        choice.key, if (run.session != null) "going on" else "new",
    });
    run.phase = .starting;
    run.at_ms = now_ms + poltergeistpkg.TakeOver.start_ms;
    self.controlRoomTouch();
}

/// `+launch` in terminal `id` says its CLI did not start (`rpc`,
/// `launchFailed`). Nothing waits on an agent from there any longer: the
/// standing a role launch held for it is dropped, and a group the control
/// room was starting a supervisor for in that terminal has failed -- now,
/// with the reason `+launch` gave, and not a minute from now with the one
/// reason a timer can give.
/// `+launch --group=<name>` in `id` (task 1844): kept until the agent it
/// starts is heard (`launchGroupArrived`). A later launch in the same
/// terminal replaces it; a name that is no group's name is not kept.
fn poltergeistLaunchedForGroup(ctx: *anyopaque, id: poltergeistpkg.Bus.Id, group: []const u8) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (!poltergeistpkg.Chat.isValidName(group)) {
        log.info("poltergeist: a launch in 0x{x} named a group that is no group's name; ignored", .{id});
        return;
    }
    const owned = self.alloc.dupe(u8, group) catch return;
    const was = self.launch_groups.fetchPut(self.alloc, id, owned) catch {
        self.alloc.free(owned);
        return;
    };
    if (was) |kv| self.alloc.free(kv.value);
    log.info("poltergeist: a launch in 0x{x} is for {s}; judged when its agent is heard", .{ id, group });
}

/// Whether the agent a `+launch --group=` started goes in that group, and
/// why (task 1844). **Only a launch the group's supervisor made**: the
/// terminal is that supervisor's worker, or the last line submitted into
/// it was that supervisor's (`Bus.typedBy`) -- which is how a supervisor
/// brings its workers back after a restart, typing `polter +launch …
/// --group=… --resume=…` into each. `group_add` stays the supervisor's;
/// this does not let a terminal put itself anywhere.
pub const LaunchJoin = enum {
    join_as_worker,
    join_as_typed,
    no_group,
    already_in,
    no_supervisor,
    is_the_supervisor,
    not_its_supervisors,

    /// Whether the log says this one. Not for the group's supervisor
    /// itself (task 1876): the control room starts it with `--group=`,
    /// puts it in on its own, and a line saying it was "not put in" read
    /// as something gone wrong.
    pub fn said(self: LaunchJoin) bool {
        return self != .is_the_supervisor;
    }

    /// The words the log line says, which is how a run on the machine
    /// tells which way it went.
    pub fn why(self: LaunchJoin) []const u8 {
        return switch (self) {
            .join_as_worker => "it is a worker of the group's supervisor",
            .join_as_typed => "the group's supervisor typed the launch",
            .no_group => "there is no group by that name",
            .already_in => "it is in the group already",
            .no_supervisor => "the group has no supervisor to have launched it",
            .is_the_supervisor => "it is the group's supervisor (the control room puts that one in)",
            .not_its_supervisors => "neither its supervisor's worker nor launched by its supervisor",
        };
    }

    pub fn joins(self: LaunchJoin) bool {
        return self == .join_as_worker or self == .join_as_typed;
    }
};

/// `starting` is the control room starting `id` as this group's
/// supervisor (`Chat.startingIn`): heard before it is one, the group has
/// no supervisor yet, and it is that supervisor.
pub fn launchJoin(
    group_exists: bool,
    already_in: bool,
    starting: bool,
    steward: ?poltergeistpkg.Bus.Id,
    id: poltergeistpkg.Bus.Id,
    worker_of: ?poltergeistpkg.Bus.Id,
    typed_by: ?poltergeistpkg.Bus.Id,
) LaunchJoin {
    if (!group_exists) return .no_group;
    if (already_in) return .already_in;
    if (starting) return .is_the_supervisor;
    const s = steward orelse return .no_supervisor;
    if (s == id) return .is_the_supervisor;
    if (worker_of == s) return .join_as_worker;
    if (typed_by == s) return .join_as_typed;
    return .not_its_supervisors;
}

/// The agent in `id` is heard: if a launch said which group it is for,
/// that launch is judged now, once, and the log says which way and why.
fn launchGroupArrived(self: *App, id: poltergeistpkg.Bus.Id) void {
    const bus = &self.poltergeist;
    const now_ms = self.poltergeistElapsedMs();
    // Spent by whichever agent is heard first, a launch for a group or not
    // (task 1876): the line a supervisor typed started that one.
    const typed_by = bus.takeTypedBy(id, now_ms);
    const kv = self.launch_groups.fetchRemove(id) orelse return;
    defer self.alloc.free(kv.value);
    const group = kv.value;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const exists = self.chat.exists(group);
    const starting = if (self.chat.startingIn(id, now_ms)) |g| std.mem.eql(u8, g, group) else false;
    const verdict = launchJoin(
        exists,
        exists and self.chat.isMember(group, id),
        starting,
        if (exists) poltergeistpkg.ControlRoom.stewardOfGroup(arena.allocator(), bus, &self.chat, group) else null,
        id,
        bus.workerOf(id),
        typed_by,
    );
    if (!verdict.joins()) {
        if (verdict.said()) log.info("poltergeist: the agent 0x{x} launched for {s} is not put in it: {s}", .{ id, group, verdict.why() });
        return;
    }
    chatAdd(self, group, id, .all) catch |err| {
        log.warn("poltergeist: the agent 0x{x} launched for {s} could not be put in it ({s}) err={}", .{ id, group, verdict.why(), err });
        return;
    };
    log.info("poltergeist: the agent 0x{x} launched for {s} joined it: {s}", .{ id, group, verdict.why() });
    self.controlRoomTouch();
}

test "1844: a launch for a group is put in it only when the group's supervisor made it" {
    const s: poltergeistpkg.Bus.Id = 0x5;
    const w: poltergeistpkg.Bus.Id = 0xa1;
    // The supervisor's worker, after a restart its project put it back.
    try std.testing.expectEqual(LaunchJoin.join_as_worker, launchJoin(true, false, false, s, w, s, null));
    // A plain tab the supervisor typed the launch into: no worker of it
    // any more, but the line was its.
    try std.testing.expectEqual(LaunchJoin.join_as_typed, launchJoin(true, false, false, s, w, null, s));
    // Typed by somebody else, or by nobody: not in.
    try std.testing.expectEqual(LaunchJoin.not_its_supervisors, launchJoin(true, false, false, s, w, null, 0x9));
    try std.testing.expectEqual(LaunchJoin.not_its_supervisors, launchJoin(true, false, false, s, w, 0x9, null));
    // No such group; in it already; nobody minds it; it is the one that does.
    try std.testing.expectEqual(LaunchJoin.no_group, launchJoin(false, false, false, null, w, s, s));
    try std.testing.expectEqual(LaunchJoin.already_in, launchJoin(true, true, false, s, w, s, s));
    try std.testing.expectEqual(LaunchJoin.no_supervisor, launchJoin(true, false, false, null, w, s, s));
    try std.testing.expectEqual(LaunchJoin.is_the_supervisor, launchJoin(true, false, false, s, s, null, s));
    // The control room starting it as the supervisor (task 1876): heard
    // before it is one, so nobody minds the group yet -- it is the
    // supervisor, and the log says nothing about it.
    try std.testing.expectEqual(LaunchJoin.is_the_supervisor, launchJoin(true, false, true, null, s, null, null));
    try std.testing.expectEqual(LaunchJoin.no_supervisor, launchJoin(true, false, false, null, s, null, null));
    for (std.enums.values(LaunchJoin)) |v| try std.testing.expectEqual(v != .is_the_supervisor, v.said());
    // Only the two joins join.
    for (std.enums.values(LaunchJoin)) |v| try std.testing.expectEqual(v == .join_as_worker or v == .join_as_typed, v.joins());
}

fn poltergeistLaunchFailed(
    ctx: *anyopaque,
    _: *poltergeistpkg.Bus,
    id: poltergeistpkg.Bus.Id,
    why: poltergeistpkg.agent_event.LaunchFailure,
    note: ?[]const u8,
) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    _ = self.personas.dropStanding(id);
    _ = self.launching.remove(id);
    defer self.refreshPoltergeistTabs();

    // Whoever ran the launch hears that it failed, watch or no watch (task
    // 1667): a role whose watch waits for its agent never gets one when the
    // agent never comes.
    if (self.personas.launcherOf(id)) |by| {
        const told = self.poltergeist.tellLaunchFailed(id, by, @tagName(why), note, self.poltergeistElapsedMs()) catch false;
        if (told) log.info("poltergeist: told 0x{x} that the launch in 0x{x} started nothing ({t})", .{ by, id, why });
    }

    const group = self.chat.startingIn(id, self.poltergeistElapsedMs()) orelse return;
    self.chat.failStart(group, poltergeistpkg.Chat.startFailureOf(why));
    log.info("control room: the supervisor it was starting did not start; its launcher said so ({t})", .{why});
    self.controlRoomTouch();
}

/// Every terminal still waiting for the agent a launch started in it, whose
/// CLI is asking the person a question before it will start -- Antigravity's
/// folder trust box, as its plugin declares it (`Plugin.StartupSays.blocks`)
/// -- has its waits held while the question is up (task 1746): the
/// standing held for its agent, the bus's minute for the launch
/// (`considerLaunches`), and a control-room start, which also says it is
/// asking so the person is told to go and answer it. **Nothing is typed
/// and nothing is answered**: whether to trust a folder is the person's
/// decision. Each wait runs again, a whole minute, once the question has
/// gone. Answers whether what the control room shows changed.
fn holdStartupQuestions(self: *App, now_ms: u64) bool {
    const Store = poltergeistpkg.PersonaStore;
    var changed = false;
    var any_waiting = false;
    var boxed = false;
    for (self.surfaces.items) |v| {
        const id = v.core().id;
        if (self.isChatSurface(id)) continue;
        const group = self.chat.startingIn(id, now_ms);
        const waiting = group != null or
            self.personas.heldStanding(id, now_ms) != null or
            self.poltergeist.launchExitIsFailure(id);
        // One whose state still says it is asking is looked at too, so that
        // the state goes when the question does.
        const said_asking = blk: {
            const a = self.poltergeist.agentOf(id);
            break :blk a.said_by == .screen and a.state == .awaiting_input;
        };
        if (!waiting and !said_asking) continue;
        any_waiting = any_waiting or waiting;
        const said = if (self.agentPresent(id)) null else self.startupQuestionText(id);
        const asking = said != null;
        // Its state, and a line for whoever is minding it or launched it
        // (`Bus.noteStartupQuestion`): a worker a supervisor started in a
        // folder its CLI does not trust yet is otherwise just silent.
        if (self.poltergeist.noteStartupQuestion(id, said, self.personas.launcherOf(id), now_ms)) boxed = true;
        if (asking) {
            _ = self.personas.extendStanding(id, now_ms + Store.standing_wait_ms, now_ms);
            _ = self.poltergeist.holdLaunch(id, now_ms);
            if (self.launching.getPtr(id)) |l| l.deadline_ms = @max(l.deadline_ms, now_ms +| poltergeistpkg.Bus.launch_agent_wait_ms);
        }
        if (group) |g| {
            if (self.chat.startAsking(g, asking, now_ms + Store.standing_wait_ms, now_ms)) {
                log.info("control room: the supervisor being started {s} asking the person a question in its tab", .{if (asking) "is" else "is no longer"});
                changed = true;
            }
        }
    }
    if (boxed) {
        self.deliverPoltergeistNotices(now_ms);
        changed = true;
    }
    // A question on a screen says nothing when it comes up: while a launch
    // waits for its agent, its screen is looked at again soon.
    if (any_waiting) self.noticeRetryIn(start_line_look_ms);
    return changed;
}

/// Whether the CLI started in `id` shows a question its plugin says must
/// not be typed into (`Plugin.StartupSays.blocks`). The CLI is the one the
/// role launch recorded, or else the one its hooks named.
pub fn startupQuestionUp(self: *App, id: poltergeistpkg.Bus.Id) bool {
    return self.startupQuestionText(id) != null;
}

/// The declared text of the question `startupQuestionUp` sees, or null.
/// It lives as long as the plugins' declarations do.
fn startupQuestionText(self: *App, id: poltergeistpkg.Bus.Id) ?[]const u8 {
    // A copy, kept for as long as the name read out of it is used.
    const agent = self.poltergeist.agentOf(id);
    const cli = if (self.personas.launchOf(id)) |l| l.choice.cli else agent.cli.get() orelse return null;
    self.ensurePlugins();
    const says = poltergeistpkg.Plugin.startupFor(self.poltergeist_says, cli) orelse return null;
    if (says.blocks.len == 0) return null;
    const screen = poltergeistRead(self, self.alloc, id, 0) catch |err| {
        log.debug("poltergeist: could not read a starting CLI for a question id={x} err={}", .{ id, err });
        return null;
    };
    defer self.alloc.free(screen);
    // Only this session's: a question above the restored history's
    // marker is the last session's, and is not on this terminal (task
    // 1862).
    return says.blockSaid(scrollback.sinceRestored(screen, scrollback.boundaryWording()));
}

/// Every launch that has waited `Bus.launch_agent_wait_ms` with no agent
/// connecting from its terminal is said to have failed, the way `+launch`
/// says a failure (task 1712): the bus takes back what it expected, the
/// standing and a control-room start are let go, and whoever ran the launch
/// is told. Answers whether there was any.
///
/// Before it, a CLI that exited at once on POSIX -- where `+launch` becomes
/// the CLI and is not there to see it -- left `hooks: expected` standing
/// and nobody told. `notePoltergeistAgentsHere` should have run first, so
/// an agent that is there has been seen to be.
fn considerLaunches(self: *App, now_ms: u64) bool {
    // A launch whose CLI is waiting on the person is not one that failed.
    if (self.holdStartupQuestions(now_ms)) self.controlRoomTouch();
    self.payFirstPrompts();
    var any = false;
    // Each one answered takes its expectation back, so this ends; the
    // bound is for a bus that, by some fault, did not.
    var left: usize = self.poltergeist.entries.count();
    while (left > 0) : (left -= 1) {
        const id = self.poltergeist.launchWithNoAgent(now_ms, self, poltergeistAgentPresent) orelse break;
        var ev: poltergeistpkg.agent_event.Event = .none;
        ev.event = .launch_failed;
        ev.detail = @tagName(poltergeistpkg.agent_event.LaunchFailure.no_agent);
        _ = self.poltergeist.agentEvent(id, ev, now_ms) catch break;
        poltergeistLaunchFailed(self, &self.poltergeist, id, .no_agent, null);
        log.info("poltergeist: no agent connected from 0x{x} within a minute of its launch", .{id});
        any = true;
    }
    return any;
}

/// Open a terminal for a role and start the role there: a tab or a split,
/// placed by `poltergeistOpenTerminal` exactly as `terminal_open` places
/// one, so the two tools cannot disagree about what `auto`, `tab` and
/// `here` mean.
///
/// The new terminal's id is null when the runtime has not made it by the
/// time this returns -- every split, and every tab on Windows. Null is not a
/// failure: the launch waits in `PersonaStore.pending_launch`, and the next
/// terminal to finish starting claims it (`claimPendingLaunch`) and goes
/// through the same `startRoleIn`. Measured on the Windows test machine:
/// before the waiting existed, a supervisor's `role_launch` there always
/// answered `OpenedEmpty` and left a bare shell.
///
/// A role whose `open` is `tab` ("always in a new tab") gets a tab when the
/// caller left the placement to Polter (`auto`); a caller that named a
/// placement gets that.
pub fn launchPersona(
    self: *App,
    alloc: Allocator,
    by: poltergeistpkg.Bus.Id,
    key: []const u8,
    cli: []const u8,
    cwd: []const u8,
    place: poltergeistpkg.rpc.Placement,
    /// A terminal that is already open, to start the role in instead of
    /// opening one. The caller named it, which is the say-so a pane the
    /// person opened themselves needs.
    into: ?poltergeistpkg.Bus.Id,
    /// A terminal whose tab the new one is opened in, as a pane (task 1571).
    beside: ?poltergeistpkg.Bus.Id,
    /// `role_launch`'s `group` (task 1971): empty for the caller's own,
    /// null for a launch that is not a supervisor's -- a person's click.
    group: ?[]const u8,
) anyerror!poltergeistpkg.rpc.Opened {
    return self.launchPersonaSeat(alloc, by, key, cli, cwd, place, into, beside, group, null);
}

/// What a seat of a squad starts as, to be carried to wherever the start
/// is finished (see `persona.Effective`).
fn effectiveOf(alloc: Allocator, choice: LaunchChoice, seat: poltergeistpkg.rpc.MemberSeat) !poltergeistpkg.persona.Effective {
    const r = choice.resolved orelse return error.NoCli;
    return .{
        .task = seat.task,
        .alias = seat.alias,
        .lead = seat.lead,
        .choice = r.choice,
        .cli_skills = r.persona.cli_skills,
        .cli_mcp = r.persona.cli_mcp,
        // Replaced, not merely different: empty says "this seat gets none",
        // which must not read as "the role's".
        .instructions = if (r.instructions_replaced) (r.persona.instructions orelse "") else null,
        .brief = try poltergeistpkg.persona.memberBrief(alloc, seat.task, seat.alias, seat.mates),
    };
}

/// A seat's start in words, for `role_launch`'s reply.
fn seatNote(alloc: Allocator, seat: poltergeistpkg.rpc.MemberSeat, choice: LaunchChoice) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const r = choice.resolved.?;
    try w.writer.print("Seat \"{s}\" of task {d} starts as {s}", .{ seat.alias, seat.task, choice.cli });
    if (r.choice.model) |m| try w.writer.print(" ({s})", .{m});
    if (r.from_squad.len > 0 or seat.over.cli != null) {
        try w.writer.writeAll("; taken from the squad:");
        if (seat.over.cli != null) try w.writer.writeAll(" cli");
        for (r.from_squad) |f| try w.writer.print(" {s}", .{f});
    }
    if (r.dropped.len > 0) {
        try w.writer.writeAll("; left behind:");
        for (r.dropped) |d| try w.writer.print(" [{s}]", .{d});
    }
    try w.writer.writeAll(". It takes the seat once its terminal is up.");
    return w.written();
}

/// `launchPersona`, and a squad's seat when `seat` is set: the role is
/// started as the squad's override leaves it, and the terminal takes the
/// seat. See `resolveLaunchSeat`, `effectiveOf`.
pub fn launchPersonaSeat(
    self: *App,
    alloc: Allocator,
    by: poltergeistpkg.Bus.Id,
    key: []const u8,
    cli: []const u8,
    cwd: []const u8,
    place: poltergeistpkg.rpc.Placement,
    into: ?poltergeistpkg.Bus.Id,
    beside: ?poltergeistpkg.Bus.Id,
    group: ?[]const u8,
    seat: ?poltergeistpkg.rpc.MemberSeat,
) anyerror!poltergeistpkg.rpc.Opened {
    const choice = try self.resolveLaunchSeat(alloc, key, cli, by, self.ownClis(), if (seat) |s| s.over else null);
    const effective: ?poltergeistpkg.persona.Effective = if (seat) |s| try effectiveOf(alloc, choice, s) else null;
    const seat_note: ?[]const u8 = if (seat) |s| try seatNote(alloc, s, choice) else null;
    const seat_word: ?[]const u8 = if (seat) |s| try poltergeistpkg.squad.encodeSeat(alloc, .{
        .alias = s.alias,
        .role = choice.key,
        .required = false,
        .lead = false,
        .override = s.over,
    }, effective.?.brief) else null;
    // **Its group, on the line** (task 1971): `+launch --group=` tells
    // Polter before the CLI starts, and the agent is put in the group when
    // it is heard -- before its first request is answered (`arrived`), so
    // its first `group_read` is a member's. It used to be put in by the
    // supervisor's own `group_add`, after; until then every group call the
    // worker made came back NotAMember.
    const joining: LaunchGroup = if (group) |named| try self.launchGroupOf(alloc, by, named) else .{ .none = .not_asked };
    const line = try launchLineFor(alloc, choice, .{ .group = joining.name(), .session = null, .seat = seat_word });
    const join_note = joining.note();

    if (into) |target| {
        // It is where it is: a directory would have to be typed into it.
        if (cwd.len > 0) return error.InWithCwd;
        try self.launchPersonaIn(target, by, choice, line, effective);
        return .{ .id = target, .placed = .{ .reused = .asked }, .joins = joining.name(), .join_note = join_note, .seat = seat_note };
    }

    const anchor: ?*Surface = if (beside) |id|
        self.findSurfaceByID(id) orelse return error.UnknownTerminal
    else
        null;

    const where: poltergeistpkg.rpc.Placement = if (anchor != null) .here else if (place == .auto) auto: {
        const p = self.personas.set.find(choice.key) orelse break :auto .auto;
        break :auto if (p.polter.open == .tab) .tab else .auto;
    } else place;

    // **Before a pane is made, one of this supervisor's own that is free
    // is used again** -- only under `auto`, where the caller left the
    // place to Polter. A pane it opened for a worker whose agent has gone
    // is an empty seat in the row it built; opening another beside it is
    // how a tab filled with idle shells while new workers went to new tabs
    // (task 1492). The person's own panes are never candidates: only what
    // `poltergeist_workers` says this supervisor opened.
    var passed_over: ?poltergeistpkg.rpc.PassedOver = null;
    if (where == .auto) {
        const found = try self.poltergeistFreeWorker(alloc, by, cwd);
        if (found.free) |free| {
            if (self.launchPersonaIn(free, by, choice, line, effective)) {
                return .{ .id = free, .placed = .{ .reused = .free_worker }, .joins = joining.name(), .join_note = join_note, .seat = seat_note };
            } else |err| {
                // It was free when it was looked at and is not now: a new
                // pane is the answer it would have been without this.
                log.info("poltergeist: worker pane {x} could not be used again ({}); opening another", .{ free, err });
            }
        }
        if (found.passed_over) |over| {
            log.info("poltergeist: worker pane {x} not used again: {t}; opening another", .{ over.id, over.why });
            passed_over = over;
        }
    }

    // Set before the terminal is asked for: a runtime that creates the
    // surface synchronously runs its `init` -- and so the claim -- inside
    // the call.
    try self.personas.expectLaunchAs(choice.key, choice.cli, line, by, self.poltergeistElapsedMs(), effective);
    // A launch whose terminal was refused must not wait for the next
    // terminal anybody opens.
    errdefer self.personas.dropLaunch();
    // Asked before the pane is made: once it is, it may already be the
    // newest of this supervisor's workers, and the answer would be itself.
    const stack: ?poltergeistpkg.Bus.Id = if (anchor == null and where == .here)
        try self.poltergeistStackOf(alloc, by)
    else
        null;
    var opened = try self.openTerminalAt(alloc, cwd, by, where, anchor);
    opened.passed_over = passed_over;
    opened.joins = joining.name();
    opened.join_note = join_note;
    opened.stack = stack;
    opened.seat = seat_note;
    if (opened.id) |new| {
        // Claimed already when the surface was made inside the call; if not,
        // it is this terminal's now -- taken the same way a late one takes
        // it, so the two cannot start a role differently.
        if (self.personas.takeLaunch(self.poltergeistElapsedMs())) |taken| {
            var p = taken;
            defer p.deinit();
            try self.startRoleInAs(new, p.by, .{ .key = p.key, .cli = p.cli }, p.line, .agent, p.effective);
        }
    }
    return opened;
}

/// Start a role in a terminal that is already open, for an agent.
///
/// **Only into a shell that is waiting and empty**, each asked of the part
/// of the program that knows: no agent connected from it (`agentPresent`
/// -- the bus's answer, any CLI talking to Polter), at its prompt (shell
/// integration's, the one closing a tab asks), and no half-typed line
/// (`draftFor(.agent)`, which errs towards "there is one"). A launch line
/// typed into anything else is typed into somebody's work.
fn launchPersonaIn(
    self: *App,
    target: poltergeistpkg.Bus.Id,
    by: poltergeistpkg.Bus.Id,
    choice: LaunchChoice,
    line: []const u8,
    effective: ?poltergeistpkg.persona.Effective,
) anyerror!void {
    const surface = self.findSurfaceByID(target) orelse return error.UnknownTerminal;
    const seat: FreeWorker.Seat = .{
        .here = true,
        .shielded = self.poltergeist.isShielded(target),
        .workers_refused = self.poltergeist.workersOf(target) == .refused,
        .agent = self.agentPresent(target),
        .launching = self.stillLaunching(target, surface),
        .at_prompt = surface.isAtShellPrompt(),
        .draft = surface.draftFor(.agent),
        .dir_fits = true,
    };
    if (seat.why()) |why| return switch (why) {
        .agent => error.AgentThere,
        .launching => error.AgentStarting,
        .not_at_prompt => error.NotAtPrompt,
        .draft => error.DraftInLine,
        // The rpc refuses both before a host is asked; this is the same
        // answer for anything that reaches here another way.
        .shielded => error.Shielded,
        .workers_refused => error.WorkersRefused,
        .elsewhere, .other_directory => unreachable,
    };
    try self.startRoleInAs(target, by, choice, line, .agent, effective);
}

/// One of `by`'s own worker panes that a role can be started in now, the
/// oldest first; null when there is none. `cwd` is where the role is to
/// start: empty for "wherever", and otherwise only a pane already standing
/// there will do -- nothing is typed to move one.
fn poltergeistFreeWorker(
    self: *App,
    alloc: Allocator,
    by: poltergeistpkg.Bus.Id,
    cwd: []const u8,
) Allocator.Error!FreeWorker.Found {
    const none: FreeWorker.Found = .{ .free = null, .passed_over = null };
    const workers: []const poltergeistpkg.Bus.Id = if (self.poltergeist_workers.get(by)) |l| l.items else return none;
    const caller = self.findSurfaceByID(by) orelse return none;
    const tab = poltergeistTabOf(caller);
    const now = try self.poltergeistSeen(alloc);
    defer alloc.free(now);

    const seats = try alloc.alloc(FreeWorker.Seat, workers.len);
    defer alloc.free(seats);
    for (workers, seats) |w, *seat| {
        const surface = self.findSurfaceByID(w);
        const here = if (surface != null) for (now) |seen| {
            if (seen.id == w) break WorkerColumn.sameTab(seen.tab, tab);
        } else false else false;
        seat.* = .{
            .here = here,
            .shielded = self.poltergeist.isShielded(w),
            .workers_refused = self.poltergeist.workersOf(w) == .refused,
            .agent = self.agentPresent(w),
            .launching = if (surface) |s| self.stillLaunching(w, s) else false,
            .at_prompt = if (surface) |s| s.isAtShellPrompt() else false,
            .draft = if (surface) |s| s.draftFor(.agent) else true,
            .dir_fits = cwd.len == 0 or if (surface) |s| dir: {
                const at = (s.pwd(alloc) catch null) orelse break :dir false;
                defer alloc.free(at);
                break :dir std.mem.eql(u8, at, cwd);
            } else false,
        };
    }
    if (FreeWorker.pick(seats)) |at| return .{ .free = workers[at], .passed_over = null };
    const over = FreeWorker.passedOver(seats) orelse return none;
    return .{ .free = null, .passed_over = .{ .id = workers[over.at], .why = over.why } };
}

/// Whether the launch typed into `id` is still starting its CLI
/// (`FreeWorker.Launching`). One that is not any more is forgotten.
fn stillLaunching(self: *App, id: poltergeistpkg.Bus.Id, surface: *Surface) bool {
    const l = self.launching.get(id) orelse return false;
    if (l.holds(self.poltergeistElapsedMs(), surface.last_key_time)) return true;
    _ = self.launching.remove(id);
    return false;
}

/// Whether a pane a supervisor opened for a worker can have a role started
/// in it again. Out of the functions above so that the rule is tested
/// without a window system: they gather the five facts, this decides.
const FreeWorker = struct {
    const Seat = struct {
        /// Still open, and in the supervisor's tab.
        here: bool,
        /// The user has shielded it. Nothing is typed into a shielded
        /// terminal, this launch included -- `in` was refused for it and
        /// `auto` never asked until task 1699.
        shielded: bool,
        /// The user keeps it for their own commands (task 1699).
        workers_refused: bool,
        /// An agent is connected to Polter from it.
        agent: bool,
        /// A launch line went in and its agent has not been heard yet
        /// (`Launching`, task 1974).
        launching: bool,
        at_prompt: bool,
        /// A half-typed line is in front of whoever uses it next.
        draft: bool,
        /// It stands where the role is to start, or nowhere was named.
        dir_fits: bool,

        const Why = enum { elsewhere, shielded, workers_refused, agent, launching, not_at_prompt, draft, other_directory };

        /// Why this one cannot be used; null when it can. In the order a
        /// caller would want to hear it: an agent that is there is the
        /// reason whatever its screen looks like.
        fn why(self: Seat) ?Why {
            if (!self.here) return .elsewhere;
            // The user's word comes before anything the screen says.
            if (self.shielded) return .shielded;
            if (self.workers_refused) return .workers_refused;
            if (self.agent) return .agent;
            // **Before the screen is asked** (task 1974): a CLI that is
            // starting can leave the cursor on the prompt's row, and a
            // shell can draw its prompt before it has read the launch line
            // typed ahead of it. Either read as an empty prompt, and the
            // next worker's launch line went into the first one's CLI.
            if (self.launching) return .launching;
            if (!self.at_prompt) return .not_at_prompt;
            if (self.draft) return .draft;
            if (!self.dir_fits) return .other_directory;
            return null;
        }
    };

    /// The first that can be used, oldest first, so the same panes are
    /// filled in the same order they were made.
    fn pick(seats: []const Seat) ?usize {
        for (seats, 0..) |seat, i| {
            if (seat.why() == null) return i;
        }
        return null;
    }

    /// When none can be used: the one `pick` would have taken first, and
    /// what kept it -- said in the reply (`rpc.PassedOver`, #1498). A pane
    /// that is not in the caller's tab was never in the running, so it is
    /// not named; null when no pane was.
    fn passedOver(seats: []const Seat) ?struct { at: usize, why: poltergeistpkg.rpc.PassedOver.Why } {
        for (seats, 0..) |seat, i| {
            const why: poltergeistpkg.rpc.PassedOver.Why = switch (seat.why() orelse continue) {
                .elsewhere => continue,
                .shielded => .shielded,
                .workers_refused => .workers_refused,
                .agent => .agent,
                .launching => .launching,
                .not_at_prompt => .not_at_prompt,
                .draft => .draft,
                .other_directory => .other_directory,
            };
            return .{ .at = i, .why = why };
        }
        return null;
    }

    /// A launch line typed into a pane, until its agent is heard (task
    /// 1974): `App.launching`.
    const Launching = struct {
        /// When it stops counting with no word: `launch_agent_wait_ms`
        /// after the line went in, held while its CLI asks the person
        /// something before it starts (`holdStartupQuestions`).
        deadline_ms: u64,
        /// When the line went in, on the clock of `Surface.last_key_time`.
        typed_at: std.Io.Timestamp,

        /// Whether it still counts at `now_ms`. Not once the person has
        /// pressed a key there since: they have taken the pane over, and
        /// what is in it is theirs to say.
        fn holds(self: Launching, now_ms: u64, last_key: ?std.Io.Timestamp) bool {
            if (now_ms > self.deadline_ms) return false;
            if (last_key) |k| if (k.nanoseconds > self.typed_at.nanoseconds) return false;
            return true;
        }
    };

    /// What `poltergeistFreeWorker` found: a pane to use, or the one that
    /// was passed over. At most one of the two.
    const Found = struct {
        free: ?poltergeistpkg.Bus.Id,
        passed_over: ?poltergeistpkg.rpc.PassedOver,
    };
};

test "1974: a pane whose launch is still starting its CLI is not free, whatever its screen says" {
    const testing = std.testing;
    // The demo's second worker (2026-10-21): the first one's Codex was at
    // "Starting MCP servers", no agent heard yet, and its screen read as an
    // empty prompt -- so it was taken, and agy's launch line went into Codex.
    const starting: FreeWorker.Seat = .{ .here = true, .shielded = false, .workers_refused = false, .agent = false, .launching = true, .at_prompt = true, .draft = false, .dir_fits = true };
    const why = starting.why();
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, .launching), why);
    try testing.expectEqual(@as(?usize, null), FreeWorker.pick(&.{starting}));
    // Said in the reply, so the supervisor knows why a new pane was opened.
    const over = FreeWorker.passedOver(&.{starting}).?;
    try testing.expectEqual(poltergeistpkg.rpc.PassedOver.Why.launching, over.why);
    // An agent that is there is still the first reason.
    var both = starting;
    both.agent = true;
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, .agent), both.why());

    // How long it counts: until its minute is up, or the person presses a
    // key there after the line went in -- then the pane is theirs.
    const typed: std.Io.Timestamp = .{ .nanoseconds = 1_000 };
    const l: FreeWorker.Launching = .{ .deadline_ms = 60_000, .typed_at = typed };
    try testing.expect(l.holds(59_999, null));
    try testing.expect(l.holds(60_000, null));
    try testing.expect(!l.holds(60_001, null));
    try testing.expect(l.holds(10, .{ .nanoseconds = 500 }));
    try testing.expect(!l.holds(10, .{ .nanoseconds = 2_000 }));
}

test "a worker's pane is used again only when it is ours, empty, waiting and where the role is to start" {
    const testing = std.testing;
    const free: FreeWorker.Seat = .{ .here = true, .shielded = false, .workers_refused = false, .agent = false, .launching = false, .at_prompt = true, .draft = false, .dir_fits = true };
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, null), free.why());

    // Each of the five on its own is enough to leave it alone.
    var seat = free;
    seat.here = false;
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, .elsewhere), seat.why());
    seat = free;
    seat.agent = true;
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, .agent), seat.why());
    seat = free;
    seat.at_prompt = false;
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, .not_at_prompt), seat.why());
    seat = free;
    seat.draft = true;
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, .draft), seat.why());
    seat = free;
    seat.dir_fits = false;
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, .other_directory), seat.why());
    // The user's two marks (task 1699), each enough on its own, and said
    // ahead of anything the screen says: a pane the user keeps for their
    // own commands is that whatever is running in it.
    seat = free;
    seat.shielded = true;
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, .shielded), seat.why());
    seat = free;
    seat.workers_refused = true;
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, .workers_refused), seat.why());
    seat.agent = true;
    seat.at_prompt = false;
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, .workers_refused), seat.why());
    try testing.expectEqual(@as(?usize, 1), FreeWorker.pick(&.{ seat, free }));
    try testing.expectEqual(poltergeistpkg.rpc.PassedOver.Why.workers_refused, FreeWorker.passedOver(&.{seat}).?.why);
    // An agent that is there is the reason, whatever else is true.
    seat = .{ .here = true, .shielded = false, .workers_refused = false, .agent = true, .launching = false, .at_prompt = false, .draft = true, .dir_fits = false };
    try testing.expectEqual(@as(?FreeWorker.Seat.Why, .agent), seat.why());

    // The oldest that can be used, and none when none can.
    var busy = free;
    busy.agent = true;
    try testing.expectEqual(@as(?usize, 1), FreeWorker.pick(&.{ busy, free, free }));
    try testing.expectEqual(@as(?usize, 0), FreeWorker.pick(&.{ free, busy }));
    try testing.expectEqual(@as(?usize, null), FreeWorker.pick(&.{ busy, busy }));
    try testing.expectEqual(@as(?usize, null), FreeWorker.pick(&.{}));
}

// When nothing can be used, the reply names the pane `auto` would have taken
// and why (#1498): the oldest of the caller's in its tab, and only those.
test "the worker pane passed over is the oldest in the tab, with its reason (#1498)" {
    const testing = std.testing;
    const free: FreeWorker.Seat = .{ .here = true, .shielded = false, .workers_refused = false, .agent = false, .launching = false, .at_prompt = true, .draft = false, .dir_fits = true };

    var gone = free;
    gone.here = false;
    var agent = free;
    agent.agent = true;
    var running = free;
    running.at_prompt = false;

    // A pane elsewhere is skipped; the first in the tab is named.
    const over = FreeWorker.passedOver(&.{ gone, agent, running }).?;
    try testing.expectEqual(@as(usize, 1), over.at);
    try testing.expectEqual(poltergeistpkg.rpc.PassedOver.Why.agent, over.why);

    try testing.expectEqual(poltergeistpkg.rpc.PassedOver.Why.not_at_prompt, FreeWorker.passedOver(&.{running}).?.why);

    // None in the tab: nobody was passed over.
    try testing.expect(FreeWorker.passedOver(&.{ gone, gone }) == null);
    try testing.expect(FreeWorker.passedOver(&.{}) == null);
}

/// Called by a surface at the end of its `init`: if the tool surface asked
/// for a terminal the runtime had not made yet, this is it, and an agent
/// opened it (`Bus.Entry.opened_by_agent`, #989).
pub fn claimAgentOpened(self: *App, surface: *Surface) void {
    const pending = self.poltergeist_agent_open orelse return;
    self.poltergeist_agent_open = null;
    if (self.poltergeistElapsedMs() > pending.deadline_ms) return;
    self.markAgentOpened(surface.id, pending.by);
}

/// Record that the agent in `by` opened `id`. A failure to record leaves it
/// the user's -- the safe way round: an agent is refused a close it could
/// have made, rather than allowed one it should not.
fn markAgentOpened(self: *App, id: poltergeistpkg.Bus.Id, by: poltergeistpkg.Bus.Id) void {
    self.poltergeist.markOpenedByAgent(id, by) catch |err| {
        log.warn("poltergeist: could not record that an agent opened terminal {x} err={}", .{ id, err });
        return;
    };
    // Said in the same words the menu switch logs, so one grep finds every
    // state the switch was in. Being opened by an agent no longer changes
    // it (`Bus.markOpenedByAgent`): this is the default, read back.
    const may = self.poltergeist.mayAuthorise(id);
    log.info("poltergeist: terminal {x} was opened by an agent ({x}); supervisor may answer prompts here: {}", .{ id, by, may });
    // The menu item shows the switch, and reads it off the tab's mark.
    if (may) self.refreshPoltergeistTabs();
}

/// Called by a surface at the end of its `init`, the first moment it can be
/// typed into: if a role launch is waiting for a terminal, this is it --
/// a split's as much as a tab's.
pub fn claimPendingLaunch(self: *App, surface: *Surface) void {
    var p = self.personas.takeLaunch(self.poltergeistElapsedMs()) orelse return;
    defer p.deinit();
    // The person's launch from the control room: this is the terminal its
    // group has been waiting for, whether or not the role starts in it.
    const from_control_room = p.by == poltergeistpkg.Chat.user_id;
    if (from_control_room) self.controlStartOpened(surface.id);
    self.startRoleInAs(surface.id, p.by, .{ .key = p.key, .cli = p.cli }, p.line, .agent, p.effective) catch |err| {
        log.warn("poltergeist: could not start role {s} in its terminal err={}", .{ p.key, err });
        if (from_control_room) if (self.chat.startingIn(surface.id, self.poltergeistElapsedMs())) |group| {
            self.chat.failStart(group, .agent_never_connected);
        };
    };
}

/// What clicking a role in a terminal's menu did.
pub const RoleChoice = enum { worn, started_here, started_in_tab };

/// The one thing a click on a role does, decided here rather than by which
/// menu the person happened to open (the owner's ask: "让程序来判断用户的意图").
///
///   * **An agent is connected to Polter from this terminal**, or the role
///     has no agent CLI to start: the role is put on the terminal, hot. That
///     is the running agent changing hats. What only a start can apply --
///     the CLI's own skills and servers -- waits for the next start, and the
///     menu says so (`PersonaHostClass`).
///   * **The terminal is at its shell prompt**: the CLI is started *here*,
///     in this terminal, rather than in a new tab.
///   * **Something else is running**: a new tab, because typing a command
///     into a program that is not a shell is typing into somebody's work.
///
/// "Is an agent here" is the bus's answer (`Server.agentPresent`), not a
/// list of CLI names: any CLI talking to Polter counts, so nothing here
/// knows Claude Code. "At the prompt" is shell integration's, the same
/// answer that decides whether closing the tab asks first.
///
/// `arg` is `<key>` or `<key>,<cli>`.
pub fn choosePersona(self: *App, id: poltergeistpkg.Bus.Id, arg: []const u8) anyerror!RoleChoice {
    self.ensurePersonas();
    const comma = std.mem.indexOfScalar(u8, arg, ',');
    const key = if (comma) |c| arg[0..c] else arg;
    const cli = if (comma) |c| arg[c + 1 ..] else "";

    const p = self.personas.set.find(key) orelse return error.NoSuchPersona;

    // "Always in a new tab" is the user saying which of these they mean,
    // ahead of time, so none of the guessing below applies -- including
    // wearing it here when an agent is connected.
    const new_tab = p.polter.open == .tab and p.clis.len > 0;

    const agent_here = if (self.poltergeist_server) |*srv| srv.agentPresent(id) else false;
    if (!new_tab and (agent_here or p.clis.len == 0)) {
        try self.setSurfacePersona(id, key);
        return .worn;
    }

    const surface = self.findSurfaceByID(id) orelse return error.UnknownTerminal;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    // Half a line in front of the person is not "at the prompt" for this:
    // the launch would be typed into the middle of it, so it gets a tab.
    if (!new_tab and surface.isAtShellPrompt() and !surface.draftFor(.person)) {
        const choice = try self.resolveLaunch(aa, key, cli, id, self.ownClis());
        // The person's own click: the keys that opened this tab are not an
        // agent intruding (#1202).
        try self.startRoleIn(id, id, choice, try launchLine(aa, choice), .person);
        return .started_here;
    }
    _ = try self.launchPersona(aa, id, key, cli, "", .tab, null, null, null);
    return .started_in_tab;
}

fn poltergeistPersonaCatalog(ctx: *anyopaque, alloc: Allocator) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.personaCatalogJson(alloc);
}

fn poltergeistPersonaPut(ctx: *anyopaque, json: []const u8) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    // The tool surface: only a supervisor reaches `role_put`.
    return self.putPersona(json, .supervisor);
}

fn poltergeistPersonaDelete(ctx: *anyopaque, alloc: Allocator, key: []const u8) anyerror![]const poltergeistpkg.squad.Removed {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.deletePersonaDropping(alloc, key);
}

fn poltergeistAgentClis(ctx: *anyopaque, alloc: Allocator, refresh: bool) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.agentClisJson(alloc, refresh);
}

fn poltergeistPromptScreens(ctx: *anyopaque) []const poltergeistpkg.Plugin.Manifest {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.ensurePlugins();
    return self.poltergeist_says;
}

fn poltergeistPersonaLaunch(
    ctx: *anyopaque,
    alloc: Allocator,
    by: poltergeistpkg.Bus.Id,
    key: []const u8,
    cli: []const u8,
    cwd: []const u8,
    place: poltergeistpkg.rpc.Placement,
    into: ?poltergeistpkg.Bus.Id,
    beside: ?poltergeistpkg.Bus.Id,
    group: []const u8,
    seat: ?poltergeistpkg.rpc.MemberSeat,
) anyerror!poltergeistpkg.rpc.Opened {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.launchPersonaSeat(alloc, by, key, cli, cwd, place, into, beside, group, seat);
}

/// The group a supervisor's `role_launch` puts its worker in (task 1971):
/// the one it supervises, or the one it named of those -- and none, said
/// why, otherwise. Pure, so the rule is tested without an app.
pub const LaunchGroup = union(enum) {
    join: []const u8,
    none: Why,

    pub const Why = enum {
        /// Not a supervisor's launch: a person's click.
        not_asked,
        /// The caller supervises no group.
        no_group,
        /// It supervises several and named none of them.
        several,
        /// It named a group it does not supervise.
        not_yours,
    };

    /// `stewarded` is the groups `by` supervises, `named` the one asked
    /// for (empty for "mine").
    pub fn of(stewarded: []const []const u8, named: []const u8) LaunchGroup {
        if (named.len > 0) {
            for (stewarded) |g| if (std.mem.eql(u8, g, named)) return .{ .join = g };
            return .{ .none = .not_yours };
        }
        return switch (stewarded.len) {
            0 => .{ .none = .no_group },
            1 => .{ .join = stewarded[0] },
            else => .{ .none = .several },
        };
    }

    pub fn name(self: LaunchGroup) ?[]const u8 {
        return switch (self) {
            .join => |g| g,
            .none => null,
        };
    }

    /// What the reply says when it is put in none and the caller might
    /// have thought otherwise; null when there is nothing to say.
    pub fn note(self: LaunchGroup) ?[]const u8 {
        return switch (self) {
            .join => null,
            .none => |why| switch (why) {
                .not_asked, .no_group => null,
                .several => "not put in a group: you supervise more than one; pass `group` to " ++
                    "have it put in one, or group_add it.",
                .not_yours => "not put in that group: you are not its supervisor. Pass one you " ++
                    "supervise, or leave `group` out.",
            },
        };
    }
};

test "1971: a supervisor's worker goes in the group it supervises, and says why when it goes in none" {
    const testing = std.testing;
    const one = [_][]const u8{"shop-web"};
    const two = [_][]const u8{ "api-server", "shop-web" };

    // The demo: one group, nothing named -- that one.
    const mine = LaunchGroup.of(&one, "");
    try testing.expectEqualStrings("shop-web", mine.name() orelse return error.NotJoined);
    try testing.expect(mine.note() == null);

    // Several, named one of them: that one. Named none: none, and said.
    try testing.expectEqualStrings("api-server", LaunchGroup.of(&two, "api-server").name().?);
    const several = LaunchGroup.of(&two, "");
    try testing.expect(several.name() == null);
    try testing.expect(std.mem.indexOf(u8, several.note().?, "pass `group`") != null);

    // Named one it does not supervise: none, and said.
    const theirs = LaunchGroup.of(&one, "docs-site");
    try testing.expect(theirs.name() == null);
    const why = theirs.note().?;
    try testing.expect(std.mem.indexOf(u8, why, "not its supervisor") != null);

    // No group at all: nothing to join, nothing to say.
    const lone = LaunchGroup.of(&.{}, "");
    try testing.expect(lone.name() == null);
    try testing.expect(lone.note() == null);
}

/// The groups `by` supervises (`ControlRoom.stewardOfGroup`), sorted, and
/// what `LaunchGroup.of` makes of them with `named`.
fn launchGroupOf(self: *App, alloc: Allocator, by: poltergeistpkg.Bus.Id, named: []const u8) Allocator.Error!LaunchGroup {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    var mine: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = self.chat.groups.keyIterator();
    while (it.next()) |g| {
        const steward = poltergeistpkg.ControlRoom.stewardOfGroup(arena.allocator(), &self.poltergeist, &self.chat, g.*) orelse continue;
        if (steward == by) try mine.append(alloc, try alloc.dupe(u8, g.*));
    }
    std.mem.sort([]const u8, mine.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return LaunchGroup.of(mine.items, named);
}

/// Take a terminal out of any persona, back to handing out everything.
pub fn clearSurfacePersona(self: *App, id: poltergeistpkg.Bus.Id) !void {
    self.ensurePersonas();
    try self.personas.clearPersona(id);
    self.wakePersonaWaits(id);
    self.refreshPoltergeistTabs();
}

/// Hold a `persona_wait` if there is nothing to tell it yet.
///
/// Returns true when the request has been parked and must not be answered
/// by the caller.
///
/// **The bookkeeping is in `poltergeist/PersonaWaits.zig`**, which is where
/// it can be tested: held here it was reachable only through a running
/// application, and it was the one part of the persona path that nothing
/// could put a floor under.
fn parkPersonaWait(
    self: *App,
    pending: *poltergeistpkg.Server.Pending,
    caller: poltergeistpkg.Bus.Caller,
) bool {
    const id = caller.terminalId() orelse return false;
    const req = pending.request.persona_wait;

    self.ensurePersonas();

    return self.poltergeist_persona_waits.park(
        pending,
        id,
        req.slot,
        req.epoch,
        self.personas.stateOf(id).epoch,
        self.poltergeistElapsedMs(),
    );
}

/// Answer every wait this terminal has parked, because something moved.
fn wakePersonaWaits(self: *App, id: poltergeistpkg.Bus.Id) void {
    const woken = self.poltergeist_persona_waits.take(self.alloc, id) catch return;
    defer self.alloc.free(woken);
    for (woken) |w| self.answerPersonaWait(w, false);
}

/// Answer waits whose deadline has passed.
fn sweepPersonaWaits(self: *App) void {
    const due = self.poltergeist_persona_waits.takeExpired(
        self.alloc,
        self.poltergeistElapsedMs(),
    ) catch return;
    defer self.alloc.free(due);
    for (due) |w| self.answerPersonaWait(w, true);
}

fn answerPersonaWait(
    self: *App,
    w: poltergeistpkg.PersonaWaits.Entry,
    timed_out: bool,
) void {
    const answer = poltergeistPersonaSlot(self, w.id, w.slot) catch {
        self.poltergeist_persona_waits.answerFailed(
            w,
            "PersonaFailed",
            "could not work out what this terminal is wearing",
        );
        return;
    };

    self.poltergeist_persona_waits.answer(
        w,
        .{ .wanted = answer.wanted, .epoch = answer.epoch },
        timed_out,
    );
}

/// Whether this surface is one the app opened to run the chat interface.
fn isChatSurface(self: *const App, id: poltergeistpkg.Bus.Id) bool {
    for (self.chat_surfaces.items) |v| if (v == id) return true;
    return false;
}

/// Record that a surface is running the chat, so its requests count as the
/// user's. Called by the apprt after it has opened one.
pub fn addChatSurface(self: *App, id: poltergeistpkg.Bus.Id) Allocator.Error!void {
    if (self.isChatSurface(id)) return;
    try self.chat_surfaces.append(self.alloc, id);
}

/// Forget one, because the terminal running it has gone.
pub fn removeChatSurface(self: *App, id: poltergeistpkg.Bus.Id) void {
    for (self.chat_surfaces.items, 0..) |v, i| {
        if (v == id) {
            _ = self.chat_surfaces.swapRemove(i);
            return;
        }
    }
}

fn poltergeistHost(self: *App) poltergeistpkg.rpc.Host {
    return .{ .ctx = self, .vtable = &.{
        .readTerminal = poltergeistRead,
        .sendText = poltergeistSend,
        .parkAssign = poltergeistParkAssign,
        .agentPresent = poltergeistAgentPresent,
        .startupReach = poltergeistStartupReach,
        .startupQuestion = poltergeistStartupQuestion,
        .personaFace = poltergeistPersonaFace,
        .terminalCapabilities = poltergeistTerminalCapabilities,
        .agentArrived = poltergeistAgentArrived,
        .agentHeard = poltergeistAgentHeard,
        .launchFailed = poltergeistLaunchFailed,
        .launchedForGroup = poltergeistLaunchedForGroup,
        .launchers = poltergeistLaunchers,
        .personaCatalog = poltergeistPersonaCatalog,
        .personaPut = poltergeistPersonaPut,
        .personaDelete = poltergeistPersonaDelete,
        .agentClis = poltergeistAgentClis,
        .promptScreens = poltergeistPromptScreens,
        .personaLaunch = poltergeistPersonaLaunch,
        .personaSlot = poltergeistPersonaSlot,
        .sendKey = poltergeistSendKey,
        .performAction = poltergeistPerformAction,
        .quietMs = poltergeistQuiet,
        .callSilentMs = poltergeistCallSilent,
        .nowMs = poltergeistNow,
        .resourceUsage = poltergeistResourceUsage,
        .resourceOverview = poltergeistResourceOverview,
        .openTerminals = poltergeistOpenTerminals,
        .openTerminal = poltergeistOpenTerminal,
        .worktreePrepare = poltergeistWorktreePrepare,
        .worktreeOpened = poltergeistWorktreeOpened,
        .worktreeAt = poltergeistWorktreeAt,
        .worktreeStatus = poltergeistWorktreeStatus,
        .worktreeRemove = poltergeistWorktreeRemove,
        .worktreeTieTask = poltergeistWorktreeTieTask,
        .worktreeForTask = poltergeistWorktreeForTask,
        .taskTreeBase = poltergeistTaskTreeBase,
        .taskSetWorktree = poltergeistTaskSetWorktree,
        .taskTreePrepare = poltergeistTaskTreePrepare,
        .worktreeCloseout = poltergeistWorktreeCloseout,
        .parkedText = poltergeistParkedText,
        .worktreeStanding = poltergeistWorktreeStanding,
        .configText = poltergeistConfigText,
        .setWatching = poltergeistSetWatching,
        .stoodDown = poltergeistStoodDown,
        .drainNotices = poltergeistDrainNotices,
        .setThreshold = poltergeistThreshold,
        .readSkill = poltergeistSkill,
        .chatCreate = chatCreate,
        .chatDestroy = chatDestroy,
        .chatRename = chatRename,
        .logProblem = logProblem,
        .chatAdd = chatAdd,
        .chatRemove = chatRemove,
        .chatCompact = chatCompact,
        .chatPost = chatPost,
        .notifyUser = notifyUser,
        .sessionRecall = sessionRecall,
        .sessionFile = sessionFile,
        .chatSetBrief = chatSetBrief,
        .groupProject = poltergeistGroupProject,
        .chatGroupInfo = chatGroupInfo,
        .chatOwner = chatOwner,
        .chatMembers = chatMembers,
        .chatGroups = chatGroups,
        .membership = poltergeistMembership,
        .chatRead = chatRead,
        .channelSeats = channelSeats,
        .channelReaders = channelReaders,
        .chatHistory = chatHistory,
        .recordTool = recordTool,
        .pluginList = pluginList,
        .pluginRoots = pluginRoots,
        .pluginConfigure = pluginConfigure,
        .pluginTest = pluginTest,
        .taskCreate = taskCreate,
        .taskCreateSquad = taskCreateSquad,
        .taskJoin = taskJoin,
        .taskLeave = taskLeave,
        .squadCatalog = poltergeistSquadCatalog,
        .squadGet = poltergeistSquadGet,
        .squadPut = poltergeistSquadPut,
        .squadDelete = poltergeistSquadDelete,
        .squadRefusal = poltergeistSquadRefusal,
        .squadSummary = poltergeistSquadSummary,
        .roleIsSupervisor = poltergeistRoleIsSupervisor,
        .typeBlocker = poltergeistTypeBlocker,
        .hasDraft = poltergeistHasDraft,
        .taskEdit = taskEdit,
        .layout = poltergeistLayout,
        .tabMove = polterTabMove,
        .paneMove = polterPaneMove,
        .highlight = polterHighlight,
        .userPresent = polterUserPresent,
        .screenshotAllowed = poltergeistScreenshotAllowed,
        .screenshotHost = poltergeistScreenshotHost,
        .screenshotInteractive = poltergeistScreenshotInteractive,
        .screenshotCwd = poltergeistScreenshotCwd,
        .screenshotIo = poltergeistScreenshotIo,
        .taskAssign = taskAssign,
        .taskClose = taskClose,
        .taskOwner = taskOwner,
        .taskCancel = taskCancel,
        .taskProgress = taskProgress,
        .alarm = alarmOp,
        .taskList = taskList,
        .taskHistory = taskHistory,
    } };
}

// -- the plugin tools' side of the host -------------------------------------
//
// All four run on the app thread: `poltergeistRequest` dispatches there, and
// so do `notifyUser` and `ensureResidents`. That is what makes it safe for a
// configure to throw the plugin arena away and read the directories again
// while archives are running.
//
// The allocator handed in is the request's own arena, so everything scanned
// can go straight into it and nothing has to be duplicated afterwards.

/// Every plugin installed, switched on or not.
///
/// Off is not a reason to leave one out: "what is here and is it on" is the
/// question this answers, and the plugin somebody is asking about is usually
/// the one that is not doing anything.
fn pluginList(
    ctx: *anyopaque,
    alloc: Allocator,
    key: []const u8,
) anyerror![]const poltergeistpkg.rpc.PluginView {
    return pluginListFor(@ptrCast(@alignCast(ctx)), alloc, key, false);
}

/// `pluginList`, and whether the reader is a person (the settings window)
/// rather than an agent: only then does each row carry `note_say`, the note
/// to be said in the person's language (#1644).
fn pluginListFor(
    self: *App,
    alloc: Allocator,
    key: []const u8,
    for_person: bool,
) anyerror![]const poltergeistpkg.rpc.PluginView {
    const io = global.io();
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    var out: std.ArrayListUnmanaged(poltergeistpkg.rpc.PluginView) = .empty;

    for (self.scanPlugins(alloc, io, &environ_map, true)) |installed| {
        const manifest = installed.manifest;
        if (key.len > 0 and !std.mem.eql(u8, key, manifest.key)) continue;

        var params: std.ArrayListUnmanaged(poltergeistpkg.rpc.PluginParamView) = .empty;

        // Every declared parameter, whether or not it has a value -- and the
        // ones with no value matter more than the ones with. They are the
        // only way `rpc.dispatch` learns that a parameter is `secret`, or
        // what its `enum` allows, *before* an agent writes it for the first
        // time. A listing that walked the configured values instead would
        // drop that rule on exactly the write that most needs it.
        for (manifest.params) |spec| {
            try params.append(alloc, poltergeistpkg.rpc.viewOf(
                spec,
                configuredValue(installed.settings.params, spec.name),
            ));
        }

        // Then whatever is in the file that the manifest does not declare.
        // Shown rather than hidden, because an audit has to see the whole
        // file. What these are **not** is a schema: their `secret: false`
        // and empty `choices` are the absence of a declaration, not a
        // declaration of absence, and nothing may read one as permission to
        // write. `pluginConfigure` refuses every undeclared name outright.
        for (installed.settings.params) |configured| {
            if (manifest.param(configured.name) != null) continue;

            try params.append(alloc, poltergeistpkg.rpc.undeclaredView(
                configured.name,
                configured.value,
            ));
        }

        // Handed over exactly as the manifest declared them, unread: an
        // agent has to be able to tell the user what it is about to switch
        // on.
        // The events, as the wire names them. Rendered here rather than in
        // `wire.zig` so that the one place that knows a `Plugin.Event`'s
        // spelling is `Plugin.Event` itself.
        const events = try alloc.alloc([]const u8, manifest.wants.events.len);
        for (manifest.wants.events, events) |e, *dst| dst.* = e.wireName();

        var view: poltergeistpkg.rpc.PluginView = .{
            .key = manifest.key,
            .name = manifest.name,
            .enabled = installed.settings.enabled,
            .stray = installed.stray != null,
            .events = events,
            .calls = manifest.wants.calls,
            .groups = manifest.wants.groups,
            .network = manifest.wants.network,
            .exec = manifest.wants.exec,
            .params = params.items,
        };

        // Every plugin is resident now, so every plugin has a state worth
        // reporting -- and this is exactly where a notification channel's
        // health used to be invisible: it was a fork that had already
        // exited, so there was nothing left to ask.
        //
        // Left empty when no copy is running, rather than reported as
        // zero. `wire.writePlugin` leaves the whole group out then, and
        // an absent `cursor` reads as "not being measured" where a `0`
        // would read as "measured, and it is nothing".
        const resident = self.residentFor(manifest.key);
        const status = if (resident) |a| a.status() else null;
        if (status) |st| {
            view.state = @tagName(st.state);
            view.cursor = st.cursor;
            view.failures = st.failures;
        }

        // Against the running copy's own parameters, which it was started
        // with and keeps through every restart of its child: the one record
        // of "what is running" that a save by anybody -- the window, a
        // plugin's page, an agent -- cannot leave behind (#1697).
        view.restart_pending = poltergeistpkg.report.restartPending(
            if (resident) |r| r.params else null,
            installed.settings,
        );

        const facts: poltergeistpkg.report.ResidentFacts = .{
            .key = manifest.key,
            .enabled = installed.settings.enabled,
            .declares_events = !manifest.wants.empty(),
            .groupless = manifest.wants.groupless(),
            .log_open = self.chat_log != null,
            .status = status,
            .stray = installed.stray,
        };
        view.note = try poltergeistpkg.report.residentNote(alloc, facts);
        if (for_person) view.note_say = try poltergeistpkg.report.residentNoteSay(alloc, facts);

        try out.append(alloc, view);
    }

    // A key that matched nothing comes back as an empty listing rather than
    // an error: a listing that found nothing is still a listing, and
    // `UnknownPlugin`'s "plugin_list shows what is" would be pointing this
    // reply back at itself.
    return out.items;
}

/// Every plugin, as the JSON document `plugin_list` answers with -- the
/// same `wire.writeResponse` rendering of the same `pluginList`. The
/// settings window reads this, so it and an agent cannot be told two
/// different stories about a plugin (settings.md §5.1). The one addition is
/// `note_say`, the same story told to a person in their language (#1644).
pub fn pluginListJson(self: *App, alloc: Allocator) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const list = try pluginListFor(self, arena.allocator(), "", true);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try poltergeistpkg.wire.writeResponse(&out.writer, .{ .plugins = list });
    return try out.toOwnedSlice();
}

/// Test one plugin the way `plugin_test` does, for the settings window's
/// Test button: the same function, with no terminal asking (settings.md
/// §5.2). The same one-a-minute budget applies, so a click and an agent
/// share it. Returns the sentence `plugin_test` would have answered with.
pub fn testPlugin(self: *App, alloc: Allocator, key: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const said = try pluginTest(self, arena.allocator(), key, 0);
    return try alloc.dupe(u8, said);
}

/// The value configured for a name, or empty when there is none.
fn configuredValue(
    params: []const poltergeistpkg.Plugin.Param,
    name: []const u8,
) []const u8 {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return "";
}

/// Where a `file:` reference written through the tool surface may point.
///
/// The user's polter config and state directories. Both come back absolute
/// with `~` already resolved, because `xdg` builds them out of `HOME` --
/// which is the precondition `rpc.Guard.roots` documents for itself.
///
/// The subdirectory is `polter`, not `polter/plugins`: a credential file
/// dropped beside the settings is the case this exists for.
///
/// **The state directory is the wide half of this, and knowingly so.**
/// `$XDG_STATE_HOME/polter` is where `chat/chat.jsonl` and the per-plugin
/// cursors live, so a `file:` reference naming the chat log would hand its
/// first line to a notification plugin as a parameter value. That is what a
/// `file:` reference *is* -- it moves a file's contents into a parameter --
/// and `roots` is the only thing deciding which files. It is written this
/// way because `dev-docs/poltergeist/mcp.md` names both directories twice; if
/// that is revisited, the two narrowings on the table are dropping the state
/// root entirely, or replacing it with a `secrets` subdirectory meant only
/// for credentials.
///
/// An allocation failure or a missing environment returns an **empty slice,
/// not an error**: empty makes `Guard.underRoot` refuse every `file:`
/// reference, and refusing is the right direction when containment could not
/// be worked out.
fn pluginRoots(_: *anyopaque, alloc: Allocator) anyerror![]const []const u8 {
    const io = global.io();

    var environ_map = global.environMap() catch return &.{};
    defer environ_map.deinit();

    var out: std.ArrayListUnmanaged([]const u8) = .empty;

    if (internal_os.xdg.config(io, alloc, &environ_map, .{ .subdir = "polter" })) |base| {
        out.append(alloc, base) catch return &.{};
    } else |_| {}

    if (internal_os.xdg.state(io, alloc, &environ_map, .{ .subdir = "polter" })) |base| {
        out.append(alloc, base) catch return &.{};
    } else |_| {}

    return out.items;
}

/// Write a plugin's settings file, and say what that does and does not take
/// effect on.
///
/// The order below is the design, not an implementation detail: the plugin
/// is resolved first so an unknown name costs nothing, the two refusals come
/// before anything is written, and the write happens before anything is
/// started so that what starts is what is on disk.
fn pluginConfigure(
    ctx: *anyopaque,
    alloc: Allocator,
    key: []const u8,
    enable: ?bool,
    params: []const poltergeistpkg.Plugin.Param,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const done = try self.configurePlugin(alloc, key, enable, params, .supervisor);
    return done.said;
}

/// What a configure did: the sentence `plugin_configure` answers with, and
/// whether the plugin's resident copy was already running -- in which case
/// it keeps the settings it started with until Polter restarts, which is
/// what the settings window's "restart to apply" banner is for
/// (settings.md §5.1).
pub const PluginConfigured = struct {
    said: []const u8,
    started: poltergeistpkg.report.Started,
};

/// Write one plugin's settings: `plugin_configure` (`who` = supervisor) and
/// the settings window (`who` = user) both come here, the way `putPersona`
/// is the one writer for roles.
///
/// Three things are the agent's alone to be refused, and the person at the
/// window may do: switch a plugin off, write a `cmd:` reference, and --
/// since the window sends its whole form -- say `enable` either way rather
/// than only ever towards on. Everything else is the same path: declared
/// names only, merged into what is there, written, reloaded, and started
/// if it was just switched on and nothing is running it.
pub fn configurePlugin(
    self: *App,
    alloc: Allocator,
    key: []const u8,
    enable: ?bool,
    params: []const poltergeistpkg.Plugin.Param,
    who: poltergeistpkg.Bus.Authority,
) !PluginConfigured {
    const io = global.io();
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    const installed = self.installedPlugin(alloc, io, &environ_map, key) orelse
        return error.NoSuchPlugin;
    const manifest = installed.manifest;

    // `rpc.Guard.enabling` already refuses this with the sentence an agent
    // reads. This is the second lock, on the thing that actually writes: a
    // plugin is the channel the person hears about things on, and no agent
    // may quiet it. The person at the settings window may.
    const enabled = try pluginEnabledAfter(who, installed.settings.enabled, enable);

    for (params) |change| {
        // Independent of whatever dispatch checked, and it is this check
        // that closes the undeclared-name hole for good: a name the schema
        // does not carry cannot be judged secret, so it cannot be written.
        _ = manifest.param(change.name) orelse return error.UnknownParameter;

        // Over the requested changes **only**, never over the merged result.
        // A user who hand-wrote `"dsn": "cmd:op read ..."` -- the form the
        // documentation recommends -- must still be able to have `backend`
        // set; `merge` carries their line through untouched, and carrying an
        // existing line through is not writing a new one. Checking the merge
        // instead would make every properly configured plugin permanently
        // unconfigurable, and it would look like a refusal rather than a bug.
        try pluginValueAllowed(who, change.value);
    }

    var next = try installed.settings.merge(alloc, params);

    // `merge` deliberately leaves this alone; deciding it is the caller's.
    next.enabled = enabled;
    const switched_on = next.enabled and !installed.settings.enabled;

    // Keyed on `manifest.key` rather than the directory name, and written
    // into the user's config: that is where `pluginSettings` reads from, so
    // a shipped plugin's settings land beside the user's own.
    const base = internal_os.xdg.config(
        io,
        alloc,
        &environ_map,
        .{ .subdir = "polter/plugins" },
    ) catch return error.NoConfigDir;

    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ base, manifest.key });
    try next.write(alloc, io, path);

    self.reloadPlugins();

    // **A provisioning plugin is restarted when its settings change**, and
    // no other kind is (#1673). Its whole job is one event per run, which
    // has already gone by: the copy that is running acted on the old
    // settings, and "takes effect the next time Polter starts" left the
    // CLI registered the old way until then. Restarting costs it nothing it
    // would keep -- it has no queue worth having, the event is handed again
    // below -- which is not true of an archive, whose queued messages would
    // go with it. Compared, not counted: the settings window sends its
    // whole form on every save.
    const provisions = manifest.wants.subscribes(.provision);
    const restarted = poltergeistpkg.report.restartsForSettings(
        provisions,
        next.enabled,
        next.sameParams(installed.settings),
    ) and self.stopResident(manifest.key);

    const started: poltergeistpkg.report.Started = if (manifest.wants.empty())
        .subscribes_to_nothing
    else if (self.residentFor(manifest.key) != null)
        .already_running
    else if ((switched_on or restarted) and
        self.startResidentNow(alloc, io, &environ_map, manifest.key))
        .started_now
    else
        .not_started;

    // The event it missed by starting late, to it alone. Only once Polter
    // has registered in this run: before that nobody has been handed one,
    // and `ensureMcpRegistered` will hand it to this plugin with the rest.
    const provision: poltergeistpkg.report.Provision = switch (poltergeistpkg.report.provisionStep(
        provisions,
        started,
        self.poltergeist_registered,
    )) {
        .none => .none,
        .withhold => .withheld,
        .hand => hand: {
            const r = self.residentFor(manifest.key) orelse break :hand .failed;
            if (!self.publishProvision(r.sub)) break :hand .failed;
            break :hand if (restarted) .restarted else .handed;
        },
    };

    const said = try poltergeistpkg.report.configured(
        alloc,
        manifest.key,
        switched_on,
        params.len > 0,
        started,
        provision,
    );
    if (started != .not_started) return .{ .said = said, .started = started };

    // Why it is not running is `residentNote`'s to say, so it is said in one
    // place and never written out twice.
    const note = try poltergeistpkg.report.residentNote(alloc, .{
        .key = manifest.key,
        .enabled = next.enabled,
        .declares_events = !manifest.wants.empty(),
        .groupless = manifest.wants.groupless(),
        .log_open = self.chat_log != null,
        .status = null,
        .stray = installed.stray,
    });
    if (note.len == 0) return .{ .said = said, .started = started };

    return .{
        .said = try std.fmt.allocPrint(alloc, "{s} {s}", .{ said, note }),
        .started = started,
    };
}

/// Whether a plugin is on after a configure. An agent can only move it
/// towards on: a plugin is the channel the person hears about things on,
/// and no agent may quiet it (`error.WillNotDisable`, the second lock
/// behind `rpc.Guard.enabling`). The person says it either way, and saying
/// nothing keeps what was there.
fn pluginEnabledAfter(
    who: poltergeistpkg.Bus.Authority,
    was: bool,
    enable: ?bool,
) error{WillNotDisable}!bool {
    return switch (who) {
        .supervisor => if (enable) |e|
            (if (e) true else error.WillNotDisable)
        else
            was,
        .user => enable orelse was,
    };
}

/// Whether a configure may write this value. `cmd:` is refused to an agent
/// -- a command it chose would run on the next plugin call -- and allowed
/// to the person: it is the form the settings window itself tells them to
/// use for a password manager. Checked over the requested changes only,
/// never over the merged result (see `configurePlugin`).
fn pluginValueAllowed(
    who: poltergeistpkg.Bus.Authority,
    value: []const u8,
) error{WillNotWriteCmd}!void {
    if (who != .supervisor) return;
    if (poltergeistpkg.secret.classify(value)) |prefix| {
        if (prefix == .cmd) return error.WillNotWriteCmd;
    }
}

test "a plugin configure: only the person may switch one off" {
    try std.testing.expectError(error.WillNotDisable, pluginEnabledAfter(.supervisor, true, false));
    try std.testing.expectError(error.WillNotDisable, pluginEnabledAfter(.supervisor, false, false));
    try std.testing.expect(try pluginEnabledAfter(.supervisor, false, true));
    try std.testing.expect(try pluginEnabledAfter(.supervisor, true, null));
    try std.testing.expect(!try pluginEnabledAfter(.supervisor, false, null));

    try std.testing.expect(!try pluginEnabledAfter(.user, true, false));
    try std.testing.expect(try pluginEnabledAfter(.user, false, true));
    try std.testing.expect(try pluginEnabledAfter(.user, true, null));
    try std.testing.expect(!try pluginEnabledAfter(.user, false, null));
}

test "configure answers with report.Started's tag names" {
    // `ghostty_app_plugin_configure` writes these names and the macOS
    // settings window reads them (`PluginStarted`); a rename here has to
    // fail somewhere.
    const Started = poltergeistpkg.report.Started;
    try std.testing.expectEqualStrings("already_running", @tagName(Started.already_running));
    try std.testing.expectEqualStrings("started_now", @tagName(Started.started_now));
    try std.testing.expectEqualStrings("not_started", @tagName(Started.not_started));
    try std.testing.expectEqualStrings("subscribes_to_nothing", @tagName(Started.subscribes_to_nothing));
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(Started).@"enum".fields.len);
}

test "a plugin configure: only the person may write a cmd: reference" {
    try std.testing.expectError(error.WillNotWriteCmd, pluginValueAllowed(.supervisor, "cmd:op read x"));
    try pluginValueAllowed(.supervisor, "env:HOOK");
    try pluginValueAllowed(.supervisor, "https://example.invalid/hook");
    try pluginValueAllowed(.user, "cmd:op read x");
}

/// The settings window's save (settings.md §5.2): `json` is a
/// `Plugin.Settings.Change`, and it goes through `configurePlugin` as the
/// user. Returns how the resident copy stands afterwards.
pub fn configurePluginJson(
    self: *App,
    alloc: Allocator,
    key: []const u8,
    json: []const u8,
) !poltergeistpkg.report.Started {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const change = try poltergeistpkg.Plugin.Settings.parseChange(a, json);
    const done = try self.configurePlugin(a, key, change.enable, change.params, .user);
    return done.started;
}

/// Start the archive plugin called `key`, taking the manifest out of the
/// list as it stands **now**.
///
/// After a reload, so what gets started is what was just written rather than
/// what was read before the write.
fn startResidentNow(
    self: *App,
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) bool {
    for (self.poltergeist_plugins) |manifest| {
        if (!std.mem.eql(u8, manifest.key, key)) continue;
        const settings = self.pluginSettings(alloc, io, environ_map, manifest.key);
        return self.startResident(manifest, settings);
    }
    return false;
}

/// The installed plugin with this key, switched on or not.
fn installedPlugin(
    self: *App,
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) ?Installed {
    for (self.scanPlugins(alloc, io, environ_map, true)) |installed| {
        if (std.mem.eql(u8, installed.manifest.key, key)) return installed;
    }
    return null;
}

/// Prove a plugin works before the night it is needed.
///
/// A plugin subscribed to `terminal.quiet` is really sent through, going
/// round `notify.decide` on purpose: quiet hours do not apply, because the
/// point of a test is that it goes out, and the tool's own description says
/// so. Every word of what goes out is written here -- the schema has no
/// free-text field, and that is what keeps this from being an unconstrained
/// outbound channel with the constrained one (`notify_user`) sitting next
/// to it as the long way round.
///
/// **Nothing is ever started to test a plugin**, whatever it subscribes to.
/// Every plugin is resident, and a second copy would be a second subscriber
/// handed everything twice. See `poltergeist/report.zig` for the sentences.
fn pluginTest(
    ctx: *anyopaque,
    alloc: Allocator,
    key: []const u8,
    by: poltergeistpkg.Bus.Id,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    const io = global.io();
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    // Resolved first, so an unknown name does not spend the budget below.
    const installed = self.installedPlugin(alloc, io, &environ_map, key) orelse
        return error.NoSuchPlugin;

    // Global rather than per key: this protects the person, not the plugin,
    // and a person with four channels configured is one person. The branch
    // that only reports on a resident spends it too, as specified.
    const now = self.poltergeistElapsedMs();
    if (self.poltergeist_plugin_tested_ms) |last| {
        if (now -| last < std.time.ms_per_min) return error.TooSoon;
    }
    self.poltergeist_plugin_tested_ms = now;

    // Every plugin is resident, so nothing is ever started to test one: a
    // second copy would be a second subscriber handed everything twice. The
    // answer to "does it work" is the running copy's own account of itself,
    // which for a notification channel is a strictly better answer than the
    // old one -- a test notification proved the fork worked at that
    // instant, and said nothing about the night it was needed.
    if (!installed.manifest.wants.subscribes(.terminal_quiet)) {
        return poltergeistpkg.report.residentStatus(alloc, .{
            .key = installed.manifest.key,
            .enabled = installed.settings.enabled,
            .declares_events = !installed.manifest.wants.empty(),
            .groupless = installed.manifest.wants.groupless(),
            .log_open = self.chat_log != null,
            .status = if (self.residentFor(installed.manifest.key)) |a| a.status() else null,
            .stray = installed.stray,
        });
    }

    // The terminal's name goes in the field `notifyUser` already puts it in,
    // and nowhere else. A tab title is something the agent in that terminal
    // can set, so splicing it into the body would open a path from an agent
    // to the wording of a notification -- and this tool exists precisely
    // because its wording is not the agent's.
    var name_buf: [256]u8 = undefined;
    var name_fixed: std.heap.FixedBufferAllocator = .init(&name_buf);
    const terminal_name = if (by != 0)
        self.chatMemberTitle(name_fixed.allocator(), by) catch ""
    else
        "";

    const event: poltergeistpkg.notify.Event = .{
        .reason = .scheduling,
        .title = "Polter test",
        .body = "A test of this notification channel, asked for through Polter's " ++
            "plugin_test tool. Nothing is wrong. If this reached you, the channel works.",
        .terminal = by,
        .terminal_name = terminal_name,
        .at_ms = self.poltergeistWallMs(),
    };

    // **The one plugin that was named is no longer a thing this can do.**
    // A notification is published on the feed, and the feed has no way to
    // address one subscriber -- by design: the whole point of it is that
    // the publisher knows nothing about who is listening. So a test goes to
    // every channel the user has switched on, and the reply says so rather
    // than implying otherwise.
    //
    // What is *not* given up is that a test really goes out: this is a real
    // event on the real path, which is the only kind of test worth having
    // on the night it matters. `notify.decide` is deliberately skipped --
    // quiet hours do not apply to a test, and the tool's own description
    // says so.
    self.poltergeist_feed.publish(poltergeistpkg.notify.published(event));

    const channels = poltergeistpkg.notify.count(
        self.poltergeist_plugins,
        .terminal_quiet,
    );

    return poltergeistpkg.report.tested(
        alloc,
        installed.manifest.key,
        installed.settings.enabled,
        channels,
        if (self.residentFor(installed.manifest.key)) |a| a.status() else null,
    );
}

fn poltergeistRead(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
    lines: u16,
) anyerror![]const u8 {
    _ = lines;
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.NoSuchTerminal;

    // The pins have to be taken under the same lock that the read happens
    // under. The terminal belongs to the IO thread, and building a
    // selection first would let it scroll or reclaim a page in between --
    // leaving the pins pointing at freed nodes by the time they are used.
    surface.renderer_state.mutex.lockUncancelable(global.io());
    defer surface.renderer_state.mutex.unlock(global.io());

    // The visible screen. `lines` is not honoured yet: selecting further
    // back needs a pin walk into the scrollback, and handing back the wrong
    // rows would be worse than not offering it.
    const screen = surface.io.terminal.screens.active;
    const tl = screen.pages.getTopLeft(.viewport);
    const br = screen.pages.getBottomRight(.viewport) orelse tl;
    const sel: terminal.Selection = .init(tl, br, false);

    const text = try surface.dumpTextLocked(alloc, sel);
    return screenCopy(alloc, text.text);
}

/// What a read hands back: the text at exactly its own length, the
/// selection's own copy freed. The selection's carries a 0 after it
/// (`[:0]const u8`), and the callers free what they get as `[]const u8`:
/// handed that one, every free was a byte short of the allocation, which
/// the debug allocator said on every read (`Allocation size 386 bytes does
/// not match free size 385`, task 1746, measured on a Debug build).
fn screenCopy(alloc: Allocator, text: [:0]const u8) Allocator.Error![]const u8 {
    defer alloc.free(text);
    return alloc.dupe(u8, text);
}

test "poltergeistRead: what a read hands back is freed at the size it was allocated" {
    // `testing.allocator` says a free of the wrong size as an error, which
    // fails the test.
    const alloc = std.testing.allocator;
    const read = try alloc.dupeZ(u8, "$ ls\nREADME.md\n");
    const screen = try screenCopy(alloc, read);
    defer alloc.free(screen);
    try std.testing.expectEqualStrings("$ ls\nREADME.md\n", screen);
}

/// Ask an apprt to rearrange a tab's panes.
///
/// **The core is a conduit here and nothing more.** It does not know which
/// surfaces share a tab -- it has to ask, and `poltergeist_tab_panes` exists
/// because of that -- so the shape travels as text and the apprt, which owns
/// the tree, is the one that parses, validates and answers.
///
/// The reply buffer is the caller's, filled by the apprt. `unsupported` is a
/// first-class answer: GTK does not implement this action, and the tool
/// says so plainly rather than reporting a layout it did not set.
fn poltergeistLayout(
    ctx: *anyopaque,
    alloc: Allocator,
    call: poltergeistpkg.rpc.LayoutCall,
) anyerror!poltergeistpkg.rpc.LayoutAnswer {
    const self: *App = @ptrCast(@alignCast(ctx));
    const arrange = poltergeistpkg.arrange;

    // **Which surface the action is aimed at**: the pane that says which
    // tab, or the terminal a new tab goes beside. A shape for a new window
    // names neither, and is aimed at the first terminal it names -- or any
    // terminal at all, for one made only of new cells -- because an action
    // has to be aimed somewhere and the apprt does not lay that one out.
    const aimed: u64 = if (call.id != 0) call.id else if (call.into.terminal()) |t| t else 0;
    const named = named: {
        var list: std.ArrayList(poltergeistpkg.Bus.Id) = .empty;
        errdefer list.deinit(alloc);
        var it: arrange.PaneIter = .init(alloc, call.spec);
        defer it.deinit();
        while (it.next() catch null) |id| try list.append(alloc, id);
        break :named try list.toOwnedSlice(alloc);
    };
    defer alloc.free(named);

    const surface: *Surface = if (aimed != 0)
        self.findSurfaceByID(aimed) orelse return error.NoSuchTerminal
    else if (named.len > 0)
        self.findSurfaceByID(named[0]) orelse return error.NoSuchTerminal
    else if (self.surfaces.items.len > 0)
        self.surfaces.items[0].core()
    else
        return error.NoSuchTerminal;

    // A `stack` cell goes through as it is: the macOS host and, from task
    // 1583, the Windows host read it. (Windows refused it here with
    // NotBuiltYet until then.)

    // ⚠️ **The two namespaces, and the whole of task 406.** A caller writes
    // the terminal ids it uses everywhere else; the apprt owns the tree and
    // knows its panes by a private numbering **no tool hands out**. The first
    // version let the caller's ids through untranslated, so a layout written
    // exactly as the tool described it came back "the layout leaves out pane
    // 1" -- about a pane that was in it.
    //
    // The translation is here because this is the only side that can do it:
    // the apprt has never seen a terminal id, and `findSurfaceByID` is the
    // map. Both directions, so the ids in the reply are ones the caller can
    // hand to `terminal_read`.
    const in_spec = self.layoutIdsToSurfaces(alloc, call.spec) catch |err| switch (err) {
        error.UnknownPane => return .{
            .applied = false,
            .text = try alloc.dupe(u8, "the layout names a terminal that does not exist. " ++
                "Use the ids terminal_list gives you -- the same ones terminal_read and " ++
                "terminal_send take."),
        },
        error.BadLayout => return .{
            .applied = false,
            .text = try alloc.dupe(u8, "the layout is not an object tree of cells"),
        },
        else => return err,
    };
    defer alloc.free(in_spec);

    // **The envelope** (task 1571): the shape, and where it goes when that
    // is not the tab of the surface the action is aimed at. `into`'s
    // terminal is a surface handle by the time the apprt sees it, as every
    // `pane` cell is.
    const envelope = envelope: {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        errdefer buf.deinit();
        const w = &buf.writer;
        try w.writeAll("{\"layout\":");
        try w.writeAll(in_spec);
        switch (call.into) {
            .none => {},
            .new_window => try w.writeAll(",\"into\":{\"new_window\":true}"),
            .new_tab_beside => |id| {
                const beside = self.findSurfaceByID(id) orelse return error.NoSuchTerminal;
                try w.print(",\"into\":{{\"new_tab_beside\":\"0x{x}\"}}", .{@intFromPtr(beside.rt_surface)});
            },
        }
        try w.writeAll("}");
        break :envelope try buf.toOwnedSliceSentinel(0);
    };
    defer alloc.free(envelope);

    // Where every named terminal was before, so the reply can say where each
    // one went (the supervisor, task 1571: two readings, before and after).
    const before = try alloc.alloc(arrange.Where, named.len);
    defer alloc.free(before);
    for (named, before) |id, *w| w.* = self.polterWhere(id);

    // The panes there before, so the ones the layout makes can be told apart
    // afterwards and marked as opened by an agent (#989).
    var existed: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, void) = .empty;
    defer existed.deinit(alloc);
    for (self.surfaces.items) |v| try existed.put(alloc, v.core().id, {});

    // **The caller's buffer, sized once.** An apprt that needs more room says
    // so in its reason rather than truncating; see the ABI note on `Out`.
    const buf = try alloc.alloc(u8, 8 * 1024);
    defer alloc.free(buf);

    var out: apprt.action.PoltergeistLayout.Out = .{
        .buf = buf.ptr,
        .cap = buf.len,
    };

    _ = surface.rt_app.performAction(
        .{ .surface = surface },
        .poltergeist_layout,
        .{ .spec = envelope, .out = &out },
    ) catch |err| {
        log.warn("poltergeist: layout action failed err={}", .{err});
        return error.LayoutFailed;
    };

    const said = buf[0..@min(out.len, buf.len)];
    return switch (out.result) {
        // **A cell nobody wrote reads as "not done"**, which is why zero is
        // this value and why it is answered as its own thing rather than as
        // a failure to be guessed at.
        .unsupported => error.LayoutUnsupported,
        // ⚠️ **The refusal text goes through the same map as the reply.**
        // Task 412: the reply was translated and this was not, so a refusal
        // read "the layout leaves out terminal 0x1e066b80000" -- a surface
        // handle, in a sentence that tells the caller to go look at a
        // terminal. Feeding that number to `terminal_read` fails, and the
        // caller has no way to see why.
        .refused => refused: {
            const r = try polterRefusal(alloc, said);
            break :refused .{
                .applied = false,
                .code = r.code,
                .text = try self.layoutHandlesInText(alloc, r.message),
            };
        },
        .applied => applied: {
            // ⚠️ Only the panes the runtime made inside the call. An apprt
            // that makes them later would leave them unmarked -- the user's
            // -- and an agent closing one busy would be refused, which is
            // the safe way to be wrong.
            for (self.surfaces.items) |v| {
                const new = v.core().id;
                if (!existed.contains(new) and !self.isChatSurface(new)) self.markAgentOpened(new, aimed);
            }

            const after = try alloc.alloc(arrange.Where, named.len);
            defer alloc.free(after);
            for (named, after) |id, *w| w.* = self.polterWhere(id);
            const moved = try arrange.moves(alloc, named, before, after);
            defer alloc.free(moved);

            const reply = try self.layoutSurfacesToIds(alloc, said);
            defer alloc.free(reply);
            break :applied .{
                .applied = true,
                .text = try arrange.withMoves(alloc, reply, moved),
            };
        },
    };
}

/// A refusal from the apprt, split into its code and its sentence. The apprt
/// writes a bare sentence for `Refused` and `{"code","message"}` for any
/// other code -- `Lent`, which only it can know (task 1571). The sentence is
/// still in the apprt's numbering: the caller translates it.
fn polterRefusal(alloc: Allocator, said: []const u8) !struct { code: []const u8, message: []const u8 } {
    if (std.json.parseFromSlice(struct { code: []const u8, message: []const u8 }, alloc, said, .{})) |parsed| {
        defer parsed.deinit();
        return .{
            .code = try alloc.dupe(u8, parsed.value.code),
            .message = try alloc.dupe(u8, parsed.value.message),
        };
    } else |_| {}
    return .{ .code = "Refused", .message = said };
}

/// Where a terminal is: its window, its tab, and the tab's place in the
/// strip, as the apprt answers. Every field null when it does not.
fn polterWhere(self: *App, id: poltergeistpkg.Bus.Id) poltergeistpkg.arrange.Where {
    const surface = self.findSurfaceByID(id) orelse return .{};
    const g = polterGrouping(surface, null);
    return .{ .window = g.window, .tab = g.tab, .tab_index = g.tab_index };
}

/// The answer to `poltergeist_grouping`, with the tab's place and -- when
/// `title` is a buffer -- its title. Zero and `TabInfo.unknown` become null:
/// "nobody said", never "nowhere".
fn polterGrouping(surface: *Surface, title: ?[]u8) struct {
    window: ?u64,
    tab: ?u64,
    tab_index: ?u32,
    tab_title: ?[]const u8,
} {
    var window: u64 = 0;
    var tab: u64 = 0;
    var info: apprt.action.PoltergeistGrouping.TabInfo = .{};
    if (title) |t| {
        info.title = t.ptr;
        info.cap = t.len;
    }
    _ = surface.rt_app.performAction(
        .{ .surface = surface },
        .poltergeist_grouping,
        .{ .window = &window, .tab = &tab, .info = &info },
    ) catch {};
    const index: ?u32 = if (info.index == apprt.action.PoltergeistGrouping.TabInfo.unknown) null else info.index;
    return .{
        .window = if (window == 0) null else window,
        .tab = if (tab == 0) null else tab,
        .tab_index = index,
        // A title is only believed with a place: an apprt that does not
        // fill the cell writes neither.
        .tab_title = if (title) |t| (if (index != null) utf8Prefix(t[0..@min(info.len, t.len)]) else null) else null,
    };
}

/// The longest prefix of `s` that is whole UTF-8: a title cut to fit the
/// buffer can end inside a character, and the writer would refuse it.
fn utf8Prefix(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(s[0..end])) end -= 1;
    return s[0..end];
}

/// Move a tab for `terminal_tab_move` (task 1571).
fn polterTabMove(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
    index: u32,
    window: poltergeistpkg.Bus.Id,
) anyerror!poltergeistpkg.rpc.LayoutAnswer {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.NoSuchTerminal;
    const handle: u64 = if (window != 0) h: {
        const w = self.findSurfaceByID(window) orelse return error.NoSuchTerminal;
        break :h @intFromPtr(w.rt_surface);
    } else 0;

    const before = self.polterWhere(id);

    const buf = try alloc.alloc(u8, 4 * 1024);
    defer alloc.free(buf);
    var out: apprt.action.PoltergeistLayout.Out = .{ .buf = buf.ptr, .cap = buf.len };
    _ = surface.rt_app.performAction(
        .{ .surface = surface },
        .polter_tab_move,
        .{ .index = index, .window = handle, .out = &out },
    ) catch |err| {
        log.warn("polter: tab move action failed err={}", .{err});
        return error.TabMoveFailed;
    };

    const said = buf[0..@min(out.len, buf.len)];
    return switch (out.result) {
        .unsupported => error.LayoutUnsupported,
        .refused => refused: {
            const r = try polterRefusal(alloc, said);
            break :refused .{
                .applied = false,
                .code = r.code,
                .text = try self.layoutHandlesInText(alloc, r.message),
            };
        },
        .applied => applied: {
            // The reply is the core's, from the two readings, so it reads
            // the same on every platform -- the apprt's text is not used.
            const after = self.polterWhere(id);
            const list = [_]poltergeistpkg.arrange.Move{.{ .id = id, .from = before, .to = after }};
            break :applied .{
                .applied = true,
                .text = try poltergeistpkg.arrange.withMoves(alloc, "{}", &list),
            };
        },
    };
}

/// Move a terminal into a stack for `terminal_stack` (task 1797). `onto ==
/// by` is `by`'s own stack, worked out by the rule the next worker would go
/// by (`WorkerColumn.lastHere`): the pane of its newest worker still in its
/// tab, `id` itself not counted, or -- none -- a pane split off `by` to the
/// right, which is the stack to come.
fn polterPaneMove(
    ctx: *anyopaque,
    alloc: Allocator,
    by: poltergeistpkg.Bus.Id,
    id: poltergeistpkg.Bus.Id,
    onto: poltergeistpkg.Bus.Id,
) anyerror!poltergeistpkg.rpc.LayoutAnswer {
    const self: *App = @ptrCast(@alignCast(ctx));
    const As = apprt.action.PoltergeistMovePane.As;
    const moved = self.findSurfaceByID(id) orelse return error.NoSuchTerminal;

    const Where = struct { target: *Surface, as: As };
    const where: Where = if (onto == by) mine: {
        const sup = self.findSurfaceByID(by) orelse return error.NoSuchTerminal;
        var others: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
        defer others.deinit(alloc);
        if (self.poltergeist_workers.get(by)) |l| for (l.items) |w| if (w != id) try others.append(alloc, w);
        const now = try self.poltergeistSeen(alloc);
        defer alloc.free(now);
        if (WorkerColumn.lastHere(others.items, now, poltergeistTabOf(sup))) |w| {
            if (self.findSurfaceByID(w)) |t| break :mine .{ .target = t, .as = .stack };
        }
        break :mine .{ .target = sup, .as = .split_right };
    } else .{ .target = self.findSurfaceByID(onto) orelse return error.NoSuchTerminal, .as = .stack };
    const target = where.target;
    const as = where.as;

    const before = self.polterWhere(id);
    const buf = try alloc.alloc(u8, 4 * 1024);
    defer alloc.free(buf);
    var out: apprt.action.PoltergeistLayout.Out = .{ .buf = buf.ptr, .cap = buf.len };
    _ = moved.rt_app.performAction(
        .{ .surface = moved },
        .poltergeist_move_pane,
        .{ .onto = @intFromPtr(target.rt_surface), .as = as, .out = &out },
    ) catch |err| {
        log.warn("polter: pane move action failed err={}", .{err});
        return error.MoveFailed;
    };

    const said = buf[0..@min(out.len, buf.len)];
    return switch (out.result) {
        .unsupported => error.LayoutUnsupported,
        .refused => refused: {
            const r = try polterRefusal(alloc, said);
            break :refused .{
                .applied = false,
                .code = r.code,
                .text = try self.layoutHandlesInText(alloc, r.message),
            };
        },
        .applied => applied: {
            log.info("polter: moved {x} {t} {x} for {x}", .{ id, as, target.id, by });
            // In `by`'s stack now: the newest of its workers there, which
            // is where its next one goes.
            if (onto == by) {
                if (self.poltergeist_workers.getPtr(by)) |l| {
                    if (std.mem.indexOfScalar(poltergeistpkg.Bus.Id, l.items, id)) |i| _ = l.orderedRemove(i);
                }
                self.poltergeistRecordWorker(by, id);
            }
            const after = self.polterWhere(id);
            const list = [_]poltergeistpkg.arrange.Move{.{ .id = id, .from = before, .to = after }};
            break :applied .{
                .applied = true,
                .text = try poltergeistpkg.arrange.withMoves(alloc, "{}", &list),
            };
        },
    };
}

/// Light a terminal up for `terminal_highlight` (task 1689). The apprt does
/// everything that is seen and answers before it returns; this turns its
/// answer into the tool's and writes the line that says it started. The
/// line that says why it ended is the apprt's, since only it knows.
fn polterHighlight(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
    seconds: u32,
    label: ?[]const u8,
) anyerror!poltergeistpkg.rpc.HighlightAnswer {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.NoSuchTerminal;
    const label_z: ?[:0]const u8 = if (label) |l| try alloc.dupeZ(u8, l) else null;

    const buf = try alloc.alloc(u8, 4 * 1024);
    defer alloc.free(buf);
    var out: apprt.action.PoltergeistLayout.Out = .{ .buf = buf.ptr, .cap = buf.len };
    _ = surface.rt_app.performAction(
        .{ .surface = surface },
        .polter_highlight,
        .{ .seconds = seconds, .label = if (label_z) |l| l.ptr else null, .out = &out },
    ) catch |err| {
        log.warn("polter: highlight action failed err={}", .{err});
        return error.HighlightFailed;
    };

    const said = buf[0..@min(out.len, buf.len)];
    const answer = switch (out.result) {
        .unsupported => return error.HighlightUnsupported,
        .refused => refused: {
            const r = try polterRefusal(alloc, said);
            break :refused poltergeistpkg.rpc.HighlightAnswer{ .refused = .{ .code = r.code, .message = r.message } };
        },
        .applied => try self.highlightApplied(alloc, said, seconds, self.poltergeistWallMs()),
    };

    switch (answer) {
        .shown => |v| log.info(
            "highlight start id=0x{x:0>16} seconds={d} label={} window={} tab={} stack={} front={t} timer={t} replaced=0x{x:0>16}",
            .{ id, seconds, label != null, v.switched.window, v.switched.tab, v.switched.stack, v.front, v.timer, v.replaced orelse 0 },
        ),
        .ended => |e| log.info("highlight cancel id=0x{x:0>16} was_lit={}", .{ id, e }),
        .refused => |r| log.info("highlight refused id=0x{x:0>16} code={s}", .{ id, r.code }),
    }
    return answer;
}

/// The apprt's `applied` text as the tool's answer. A word the core does not
/// know for `front` is `unknown`, said in the log -- never `refused`, which
/// would tell the person something nobody read.
fn highlightApplied(
    self: *const App,
    alloc: Allocator,
    said: []const u8,
    seconds: u32,
    now_ms: i64,
) !poltergeistpkg.rpc.HighlightAnswer {
    return parseHighlightApplied(alloc, said, seconds, now_ms, self, struct {
        fn lookup(ctx: *const anyopaque, handle: u64) ?u64 {
            const app: *const App = @ptrCast(@alignCast(ctx));
            return app.surfaceIdOfHandle(handle);
        }
    }.lookup);
}

/// The parse itself, with the handle map passed in so it can be tested
/// without an `App`.
fn parseHighlightApplied(
    alloc: Allocator,
    said: []const u8,
    seconds: u32,
    now_ms: i64,
    ctx: *const anyopaque,
    lookup: *const fn (*const anyopaque, u64) ?u64,
) !poltergeistpkg.rpc.HighlightAnswer {
    const Answer = poltergeistpkg.rpc.HighlightAnswer;
    const Said = struct {
        ended: ?bool = null,
        switched: ?struct { window: bool = false, tab: bool = false, stack: bool = false } = null,
        front: ?[]const u8 = null,
        timer: ?[]const u8 = null,
        replaced: u64 = 0,
    };
    const parsed = std.json.parseFromSlice(Said, alloc, said, .{ .ignore_unknown_fields = true }) catch {
        log.warn("polter: highlight answer is not what the interface says: {s}", .{said});
        return .{ .refused = .{ .code = "HighlightFailed", .message = "the apprt's answer could not be read" } };
    };
    defer parsed.deinit();
    const v = parsed.value;
    if (seconds == 0) return .{ .ended = v.ended orelse false };

    const front: Answer.Front = if (v.front) |w| std.meta.stringToEnum(Answer.Front, w) orelse unknown: {
        log.warn("polter: highlight front={s} is not a word the core knows; reported as unknown", .{w});
        break :unknown .unknown;
    } else .unknown;
    const timer: Answer.Timer = if (v.timer) |w| std.meta.stringToEnum(Answer.Timer, w) orelse .waiting else .waiting;
    const sw: @TypeOf(v.switched.?) = v.switched orelse .{};
    return .{
        .shown = .{
            .switched = .{ .window = sw.window, .tab = sw.tab, .stack = sw.stack },
            .front = front,
            .timer = timer,
            // A handle that no longer names a surface was closed in between;
            // there is no id left to give.
            .replaced = if (v.replaced == 0) null else lookup(ctx, v.replaced),
            .until_ms = now_ms + @as(i64, seconds) * std.time.ms_per_s,
        },
    };
}

test "a highlight answer with a front word the core does not know is unknown, not refused" {
    const alloc = std.testing.allocator;
    const none = struct {
        fn lookup(_: *const anyopaque, handle: u64) ?u64 {
            return if (handle == 0x77) 0xabc else null;
        }
    }.lookup;
    const a = try parseHighlightApplied(
        alloc,
        "{\"switched\":{\"window\":false,\"tab\":true,\"stack\":true},\"front\":\"sideways\",\"timer\":\"running\",\"replaced\":119}",
        30,
        1000,
        &none,
        none,
    );
    try std.testing.expectEqual(poltergeistpkg.rpc.HighlightAnswer.Front.unknown, a.shown.front);
    try std.testing.expect(a.shown.switched.tab);
    try std.testing.expect(a.shown.switched.stack);
    try std.testing.expect(!a.shown.switched.window);
    try std.testing.expectEqual(@as(?u64, 0xabc), a.shown.replaced);
    try std.testing.expectEqual(@as(i64, 31000), a.shown.until_ms);

    const b = try parseHighlightApplied(alloc, "{\"front\":\"refused\",\"timer\":\"running\",\"replaced\":0}", 5, 0, &none, none);
    try std.testing.expectEqual(poltergeistpkg.rpc.HighlightAnswer.Front.refused, b.shown.front);
    try std.testing.expectEqual(@as(?u64, null), b.shown.replaced);

    const c = try parseHighlightApplied(alloc, "{\"ended\":true}", 0, 0, &none, none);
    try std.testing.expect(c.ended);
}

/// For `UserPresent` on a move (task 1571): a terminal somebody is at --
/// `id`, or with `whole_tab` any terminal in its tab. A key within the quiet
/// window (the clock `terminal_send` is refused by), or an input method
/// composing there (task 1578); see `Surface.presenceForMove`.
fn polterUserPresent(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    whole_tab: bool,
    except: poltergeistpkg.Bus.Id,
) ?poltergeistpkg.rpc.Present {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return null;
    if (id != except) if (polterPresent(surface)) |p| return p;
    if (!whole_tab) return null;
    const tab = poltergeistTabOf(surface) orelse return null;
    for (self.surfaces.items) |v| {
        const other = v.core();
        if (other == surface or other.id == except) continue;
        if (poltergeistTabOf(other) != tab) continue;
        if (polterPresent(other)) |p| return p;
    }
    return null;
}

/// `Surface.presenceForMove`, as the tool surface's answer.
fn polterPresent(surface: *Surface) ?poltergeistpkg.rpc.Present {
    return switch (surface.presenceForMove()) {
        .absent => null,
        .keyed => .{ .id = surface.id },
        .composing => .{ .id = surface.id, .composing = true },
    };
}

/// Rewrite a layout's `pane` cells from terminal ids to surface handles.
///
/// The handle is what every action target already carries, so it is the one
/// currency this side and the apprt both hold. See the note at the call.
fn layoutIdsToSurfaces(self: *App, alloc: Allocator, text: []const u8) ![]const u8 {
    return self.rewriteLayout(alloc, text, true);
}

/// And back, so the reply names terminals rather than handles.
fn layoutSurfacesToIds(self: *App, alloc: Allocator, text: []const u8) ![]const u8 {
    return self.rewriteLayout(alloc, text, false) catch |err| switch (err) {
        // A handle this side cannot place is a bug over there, and the raw
        // text is more use to whoever chases it than a swallowed error.
        error.UnknownPane, error.BadLayout => try alloc.dupe(u8, text),
        else => err,
    };
}

fn rewriteLayout(
    self: *App,
    alloc: Allocator,
    text: []const u8,
    to_surface: bool,
) ![]const u8 {
    const Map = struct {
        fn toSurface(ctx: *const anyopaque, id: u64) ?u64 {
            const app: *App = @ptrCast(@alignCast(@constCast(ctx)));
            const s = app.findSurfaceByID(id) orelse return null;
            return @intFromPtr(s.rt_surface);
        }
        fn toId(ctx: *const anyopaque, handle: u64) ?u64 {
            const app: *const App = @ptrCast(@alignCast(ctx));
            return app.surfaceIdOfHandle(handle);
        }
    };
    return rewriteLayoutWith(alloc, text, self, if (to_surface) Map.toSurface else Map.toId, to_surface);
}

/// `rewriteLayout` with the map passed in, so it can be tested without an
/// `App`: every `pane` cell's number is replaced by what `map` gives for it.
fn rewriteLayoutWith(
    alloc: Allocator,
    text: []const u8,
    ctx: *const anyopaque,
    map: *const fn (*const anyopaque, u64) ?u64,
    to_surface: bool,
) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch
        return error.BadLayout;
    defer parsed.deinit();

    // The new cell strings live in the parse's own arena, freed with it.
    try rewriteLayoutValue(parsed.arena.allocator(), &parsed.value, ctx, map, to_surface);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();
    std.json.Stringify.value(parsed.value, .{}, &buf.writer) catch return error.BadLayout;
    return buf.toOwnedSlice();
}

fn rewriteLayoutValue(
    alloc: Allocator,
    v: *std.json.Value,
    ctx: *const anyopaque,
    map: *const fn (*const anyopaque, u64) ?u64,
    to_surface: bool,
) !void {
    switch (v.*) {
        .object => |*o| {
            if (o.getPtr("pane")) |cell| {
                if (cell.* == .string) {
                    const n = std.fmt.parseUnsigned(u64, cell.string, 0) catch
                        return error.BadLayout;
                    const mapped = map(ctx, n) orelse return error.UnknownPane;
                    // **A terminal id as `terminal_list` writes it**, all
                    // sixteen digits (task 1600: `0x2566…` came back for
                    // `0x02566…`, and a caller comparing the two found no
                    // match). A handle for the apprt is read as a number.
                    cell.* = .{ .string = if (to_surface)
                        try std.fmt.allocPrint(alloc, "0x{x}", .{mapped})
                    else
                        try std.fmt.allocPrint(alloc, "0x{x:0>16}", .{mapped}) };
                }
            }
            for (o.values()) |*child| try rewriteLayoutValue(alloc, child, ctx, map, to_surface);
        },
        .array => |*a| for (a.items) |*child| try rewriteLayoutValue(alloc, child, ctx, map, to_surface),
        else => {},
    }
}

/// Replace every surface handle in free text with the terminal id behind it.
///
/// **For prose, where the reply's rewrite cannot reach.** `rewriteLayout`
/// walks a JSON tree and edits `pane` cells; a refusal is a sentence, and the
/// handles in it were being handed to the caller untranslated (task 412).
///
/// ⚠️ **A number this app does not recognise is left exactly as it was.** The
/// apprt writes ratios, counts and its own private pane numbers into these
/// sentences too, and a scan that rewrote whatever looked like a handle would
/// turn one of those into a terminal id that means something else. Only
/// `surfaceIdOfHandle` -- the same map the reply uses, not a second one --
/// decides, and it answers by comparing against surfaces this app holds.
fn layoutHandlesInText(self: *const App, alloc: Allocator, text: []const u8) ![]const u8 {
    return rewriteHandles(alloc, text, self, struct {
        fn lookup(ctx: *const anyopaque, handle: u64) ?u64 {
            const app: *const App = @ptrCast(@alignCast(ctx));
            return app.surfaceIdOfHandle(handle);
        }
    }.lookup);
}

/// The text scan itself, with the map passed in so it can be tested without
/// an `App`.
fn rewriteHandles(
    alloc: Allocator,
    text: []const u8,
    ctx: *const anyopaque,
    lookup: *const fn (*const anyopaque, u64) ?u64,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        // `0x` only where a number can start: `0x` inside a word is part of
        // the word, not a handle.
        const starts = text[i] == '0' and
            i + 1 < text.len and
            (text[i + 1] == 'x' or text[i + 1] == 'X') and
            (i == 0 or !std.ascii.isAlphanumeric(text[i - 1]));
        if (!starts) {
            try out.append(alloc, text[i]);
            i += 1;
            continue;
        }

        var j = i + 2;
        while (j < text.len and std.ascii.isHex(text[j])) j += 1;
        const digits = text[i + 2 .. j];
        const value: ?u64 = if (digits.len == 0)
            null
        else
            std.fmt.parseUnsigned(u64, digits, 16) catch null;

        if (value) |v| {
            if (lookup(ctx, v)) |sid| {
                // As `terminal_list` writes it (task 1600).
                try out.print(alloc, "0x{x:0>16}", .{sid});
                i = j;
                continue;
            }
        }

        // Not ours: copied through byte for byte, including the `0x`.
        try out.appendSlice(alloc, text[i..j]);
        i = j;
    }

    return out.toOwnedSlice(alloc);
}

/// The terminal id behind a surface handle, or null if this app has no such
/// surface. **Compared rather than cast**: a handle from the apprt is a
/// number until it matches one this side is holding.
fn surfaceIdOfHandle(self: *const App, handle: u64) ?u64 {
    for (self.surfaces.items) |v| {
        if (@intFromPtr(v) == handle) return v.core().id;
    }
    return null;
}

fn poltergeistSend(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    text: []const u8,
    submit: bool,
) anyerror!void {
    try poltergeistSendAs(ctx, id, text, submit, .agent);
}

/// `poltergeistSend`, typed as `who` (task 1738: a group post the person
/// made from the control room).
fn poltergeistSendAs(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    text: []const u8,
    submit: bool,
    who: poltergeistpkg.rpc.Typist,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.NoSuchTerminal;
    self.noteAnswerSwitchNotConsulted(id, "terminal_send", text.len, submit, poltergeistpkg.prompts.couldAnswer(text));
    try surface.typePoltergeistTextAs(text, submit, who);
}

/// Record a write into a terminal that the answer switch did **not** stop.
///
/// # Why there is a line here at all
///
/// The switch on `Bus.Entry.may_authorise` stops two things: the tool that
/// answers a prompt, and the keys that take an option in one. It does not
/// stop text plus a return, and it cannot -- **that is also how a task is
/// assigned**, and at this interface the two are the same act. So the path
/// stays open.
///
/// **A protection with a bypass everybody knows about is a different thing
/// from one with a bypass nobody wrote down**, and that difference is the
/// whole of what makes the switch honest rather than decorative. It was
/// promised to the user in those words -- "not prevention, book-keeping" --
/// and until this function existed only half of it was true: the bypass was
/// published and **silent**.
///
/// # Why every send, and not only the suspicious ones
///
/// Because "suspicious" cannot be decided here, and a record with a judgement
/// in it is a record with a hole the size of the judgement. Every write to a
/// terminal whose switch is off goes in the log, without exception.
///
/// ⚠️ **Which means this line appears on ordinary work** at such a terminal.
/// It used to be most terminals -- the switch was off until somebody
/// switched it on -- and since 2026-10-12 it is only the ones the person
/// has switched off, where the record matters most: they said no, and this
/// is what was typed there anyway. It is accepted rather than tuned away, and `could_answer`
/// is what makes it bearable: the record is complete and *sorted*, so a
/// reader greps the flag rather than reading everything. **The flag labels;
/// it never decides.** Getting it wrong costs one line's filing and nobody's
/// capability, which is exactly why a guess is allowed here and was turned
/// down twice in the code this is attached to.
///
/// # What it must not be read as
///
/// **Not a refusal.** Nothing was stopped; the sentence says so in as many
/// words, because a log line naming a permission switch reads as a denial
/// unless it says otherwise, and a reader who takes it that way will believe
/// the terminal is protected.
fn noteAnswerSwitchNotConsulted(
    self: *App,
    id: poltergeistpkg.Bus.Id,
    via: []const u8,
    /// How much text is going in, when this side knows. **Null rather than
    /// zero for the paths that do not**: a paste's payload is the
    /// clipboard's, and the action string's own length is not it. A `0`
    /// there would read as "nothing was written", which is the opposite of
    /// what happened.
    bytes: ?usize,
    submit: bool,
    could_answer: poltergeistpkg.prompts.CouldAnswer,
) void {
    // The switch being on is the user's grant: there is no bypass to record,
    // because there is nothing being got around.
    if (self.poltergeist.mayAuthorise(id)) return;

    var size: [24]u8 = undefined;
    const size_txt: []const u8 = if (bytes) |n|
        std.fmt.bufPrint(&size, "{d}", .{n}) catch "?"
    else
        "?";

    log.info(
        "poltergeist: {s} id={x} bytes={s} submit={} could_answer={s} -- " ++
            "the answer switch is off for this terminal and did NOT stop this; " ++
            "this path is not covered by it",
        .{ via, id, size_txt, submit, could_answer.tag() },
    );
}

/// Press a key in a terminal.
///
/// The surface is found first and the key parsed inside it, for the same
/// reason `poltergeistPerformAction` looks the surface up before parsing:
/// an id that names nothing and a key that does not parse are different
/// mistakes and want different answers.
fn poltergeistSendKey(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    key: []const u8,
) anyerror!poltergeistpkg.keys.Outcome {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.NoSuchTerminal;
    return try surface.sendPoltergeistKey(key);
}

/// Do one of the terminal's own keybinding actions to it.
///
/// The same two calls the menu bar makes -- parse the string, hand it to
/// `performBindingAction` -- so an agent asking for `new_tab` and a person
/// pressing the key for it end up in exactly the same place. There is no
/// second implementation to drift.
///
/// The surface must be found before the action is parsed: an id that names
/// nothing is a different mistake from an action that does not parse, and
/// the two want different answers from the agent that made them.
fn poltergeistPerformAction(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    action: []const u8,
    confirm_close: bool,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.UnknownTerminal;

    const parsed = input.Binding.Action.parse(action) catch |err| {
        log.warn("poltergeist: action {s} would not parse err={}", .{ action, err });
        return error.InvalidAction;
    };

    // **The actions that write into somebody's input line answer to the
    // same guard `terminal_send` does.**
    //
    // `paste_from_clipboard` aimed at another terminal does what
    // `terminal_send` does -- it puts characters in that terminal's input
    // line -- and until this was here it did so with no guard at all, while
    // the identical act one call over was refused. The defect the user
    // reported is "my half-written line was submitted with it"; a paste
    // does that just as well as a notice.
    //
    // These were already refused at the *caller's own* terminal, with
    // `SelfTarget`, because the text would come back to the caller. That is
    // a different question from this one and neither covers the other.
    //
    // **`cursor_key` is deliberately not in this list.** It adds nothing to
    // a line; it moves around inside one. It belongs to the family
    // `sendPoltergeistKey` is in -- a named key at a named moment -- and
    // that family is argued there.
    const writes_into_the_line = switch (parsed) {
        .text, .csi, .esc, .paste_from_clipboard, .paste_from_selection => true,
        .write_screen_file, .write_scrollback_file, .write_selection_file => |v| v.action == .paste,
        else => false,
    };
    if (writes_into_the_line) {
        // **The same record, from the other door.** A paste aimed at another
        // terminal writes into its input line exactly as `terminal_send`
        // does; one of them recorded and the other not would be a book with
        // a hole in it, and the hole would be the quieter door.
        //
        // `unknown` rather than `no`: what a paste will write is the
        // clipboard's and is not visible from here. Some of these actions do
        // carry their text -- `text:hello` -- but they are handed over as a
        // parsed action rather than as a string this function holds, and
        // guessing at it from the action name would be a worse answer than
        // saying plainly that this side did not see it.
        self.noteAnswerSwitchNotConsulted(id, "terminal_action", null, true, .unknown);
        try surface.poltergeistMayType();
    }

    // The actions that do not go through `performBindingAction`, and they
    // are all one family: the closes. Both halves of the reason are things
    // `performBindingAction` cannot do. It closes the way the user closes,
    // which always asks -- so a supervisor closing a worker it is minding
    // got a dialog nobody was there to press. And it answers `true` the
    // moment the request is handed to the runtime, so a close that raised a
    // dialog came back as `{"ok":true}` for a terminal that was still open.
    //
    // `confirm_close` is carried down from the tool surface, which is the
    // side that knows the target's mark, and each of these paths says on the
    // way back whether a dialog went up. Everything else still goes through
    // the shared path, which is the point of this whole surface.
    switch (parsed) {
        // The surface closes itself, or refuses -- never a dialog (#989).
        .close_surface => return switch (surface.closeFromTool(confirm_close)) {
            .close => {},
            .refuse_users_terminal => error.CloseRefusedUsersTerminal,
            .refuse_locked => error.CloseRefusedLocked,
        },

        // A tab and a window are the apprt's to close and the apprt's to
        // ask about -- a surface knows whether *it* needs confirming, and
        // nothing in the core knows which surfaces share a tab. So the
        // question and the answer both go out through `poltergeist_close`
        // rather than being decided here. See `apprt.action.PoltergeistClose`.
        //
        // `readonly` is folded in here rather than in `rpc.zig` for the same
        // reason it is in `Surface.toolCloseVerdict`: it is this surface's
        // state, and the tool surface has no way to read it. The apprt folds
        // in the rest of the tab on top of this, because a tab is more
        // surfaces than the one that was named.
        .close_tab => |mode| return self.poltergeistClose(surface, .{
            .scope = switch (mode) {
                .this => .this_tab,
                .other => .other_tabs,
                .right => .tabs_to_the_right,
            },
            .confirm = poltergeistpkg.actions.confirmsCloseProtected(
                confirm_close,
                surface.readonly,
            ),
        }),

        .close_window => return self.poltergeistClose(surface, .{
            .scope = .window,
            .confirm = poltergeistpkg.actions.confirmsCloseProtected(
                confirm_close,
                surface.readonly,
            ),
        }),

        // An agent's `new_tab` is the core's, not the person's key (task
        // 1823): the same action the key sends, opened in the background.
        .new_tab => {
            if (!(try surface.rt_app.performAction(.{ .surface = surface }, .new_tab, .{ .by = .core }))) return error.ActionIgnored;
            return;
        },

        else => {},
    }

    // **An action this tool runs is Poltergeist typing, seen from the
    // viewport's side** (task 2233). A person's own `text:` / `csi:` /
    // `cursor_key` key scrolls to the bottom, because they are about to type
    // where the viewport should be; the same action aimed at somebody else's
    // terminal by an agent is not that. Several of these branches scroll
    // unconditionally, so an agent answering a box, sending a control
    // sequence or pasting into a terminal whose owner had scrolled up to
    // read was dragging them back to the bottom -- once per call, through
    // the one door that was left.
    //
    // The flag is set here rather than inside `performBindingAction` itself,
    // because that function is what the person's key goes through too, and
    // their key must keep scrolling. Held across the call and restored after
    // it, the way the two typing entry points in `Surface` do it, so an
    // error return cannot leave it set.
    const typing = surface.poltergeist_typing;
    defer surface.poltergeist_typing = typing;
    surface.poltergeist_typing = Surface.typingDuringAgentAction(typing, parsed);

    // The return says whether the terminal took it. False is not a failure
    // of ours -- `toggle_split_zoom` on a window with no splits does
    // nothing, and rightly -- but the agent asked for something to happen,
    // so it is told that nothing did.
    if (!(try surface.performBindingAction(parsed))) return error.ActionIgnored;
}

/// Ask the apprt to close a tab or a window for the tool surface, and turn
/// what it says back into the two answers this surface has.
///
/// The `result` cell starts at `.unsupported` and is passed by pointer, so
/// an apprt that does not implement this -- GTK today -- leaves it there and
/// the caller is told nothing happened. Reading `performAction`'s `bool`
/// alone would not do: it says "I handled this action", which is true of a
/// close that put a dialog up and true of a close that went through, and
/// telling those two apart is the whole reason this action exists.
fn poltergeistClose(
    self: *App,
    surface: *Surface,
    req: struct {
        scope: apprt.action.PoltergeistClose.Scope,
        confirm: bool,
    },
) anyerror!void {
    _ = self;

    var result: apprt.action.PoltergeistClose.Result = .unsupported;
    const handled = try surface.rt_app.performAction(
        .{ .surface = surface },
        .poltergeist_close,
        .{
            .scope = req.scope,
            .confirm = req.confirm,
            .result = &result,
        },
    );

    // An apprt that says it did not handle the action has not written the
    // cell either, and both readings lead to the same place; checked anyway
    // so that a future apprt returning `false` after writing `closed` is a
    // contradiction that resolves the safe way.
    if (!handled) return error.ActionIgnored;

    // The three-way answer, decided next to the enum rather than here --
    // nothing in this file is reached by a test, and a rule written in an
    // untested place is a rule nobody can check. See `Result.toolAnswer`.
    return result.toolAnswer();
}

fn poltergeistSetWatching(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    watching: bool,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.UnknownTerminal;
    surface.setPoltergeistWatching(watching);

    // Being put under supervision changes what may happen to this terminal,
    // so the terminal is told -- the same reason the keybind path tells it.
    if (watching) {
        self.tellSurface(id, "[Polter] A supervisor is now watching this " ++
            "terminal and will be told when your screen has been still for a " ++
            "while. It may read your screen and write to you. Nothing is " ++
            "watching what you type.");
    }

    self.saveSession();
}

/// A supervisor has just taken itself off duty.
///
/// The bus has already forgotten the standing; what is left is everything
/// outside it. The tab mark is refreshed for the same reason the keybind
/// refreshes it -- a terminal that is no longer in charge should stop
/// saying it is at once, not whenever something else happens to redraw.
/// And the arrangement is written down, because a supervisor that stood
/// down last night is not one tomorrow's recall should describe as still
/// minding anybody.
fn poltergeistStoodDown(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    _ = id;
    self.refreshPoltergeistTabs();
    self.saveSession();
}

/// What a terminal with no agent connected shows of the CLI started in it
/// (task 1682, `rpc.Host.startupReach`). Only for a terminal a launch said
/// to expect an agent in (`hooks == .expected`) whose CLI's plugin
/// declares `startup_says`; the screen is read the way terminal_read reads
/// it. Anything else is `none`, which keeps the rule as it was: no agent,
/// nothing typed.
/// Whether a question its CLI asks before it starts is on `id`'s screen,
/// whatever the agent there says (`rpc.Host.startupQuestion`, task 1746).
fn poltergeistStartupQuestion(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.startupQuestionUp(id);
}

fn poltergeistStartupReach(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) poltergeistpkg.rpc.StartupReach {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.startupReachOf(id);
}

/// Whether this terminal's agent is at a permission box now (task 1682):
/// the question every agent's write asks before typing (`Surface.mayTypeAs`),
/// since a return typed into a box answers it -- at best as a no, at worst
/// as the person's yes (measured: a set_watch notice approved a shell
/// command in Antigravity). Two ways it can be known:
///
/// - **the agent said so**: `awaiting_approval`, by its hooks (Claude Code's
///   `PermissionRequest`, Codex's) or by the title its plugin declares --
///   for every CLI, which is the change to Claude Code and Codex: a mention
///   or a notice waits until the box is answered, where it was typed into
///   it before;
/// - **the screen shows one** its CLI's plugin declares, for a CLI whose
///   hooks are live and say nothing about approvals
///   (`hooks_report_approval: false`) -- read the way terminal_read reads.
///
/// `awaiting_input` is not a box and is not counted. The keys that answer a
/// box (terminal_key, terminal_answer_prompt) do not ask this.
pub fn approvalOnScreen(self: *App, id: poltergeistpkg.Bus.Id) bool {
    // A copy, kept for as long as the name read out of it is used.
    // A box declined at the terminal is not on the screen, whatever the
    // last hook said (task 2021).
    if (self.considerDeclined(id, self.poltergeistElapsedMs())) return false;
    const agent = self.poltergeist.agentOf(id);
    if (agent.known() and agent.state == .awaiting_approval) return true;
    if (agent.hooks != .live) return false;
    const cli = agent.cli.get() orelse return false;
    self.ensurePlugins();
    const says = poltergeistpkg.Plugin.screenApprovalFor(self.poltergeist_says, cli) orelse return false;
    const screen = poltergeistRead(self, self.alloc, id, 0) catch |err| {
        log.debug("poltergeist: could not read for a box before typing id={x} err={}", .{ id, err });
        return false;
    };
    defer self.alloc.free(screen);
    return says.approvalSaid(screen) != null;
}

fn startupReachOf(self: *App, id: poltergeistpkg.Bus.Id) poltergeistpkg.rpc.StartupReach {
    // Nobody's line before the first prompt Polter owes it (task 1746).
    return poltergeistpkg.rpc.reachWhileOwed(self.startupReachRaw(id), self.first_prompts.contains(id));
}

/// What the screen of a terminal with no agent says, before whether Polter
/// owes it a first prompt is asked (`startupReachOf`).
fn startupReachRaw(self: *App, id: poltergeistpkg.Bus.Id) poltergeistpkg.rpc.StartupReach {
    // A copy, kept for as long as the name read out of it is used.
    const agent = self.poltergeist.agentOf(id);
    if (agent.hooks != .expected) return .none;
    const cli = agent.cli.get() orelse return .none;
    self.ensurePlugins();
    const says = poltergeistpkg.Plugin.startupFor(self.poltergeist_says, cli) orelse return .none;
    const screen = poltergeistRead(self, self.alloc, id, 0) catch |err| {
        log.debug("poltergeist: could not read a starting CLI id={x} err={}", .{ id, err });
        return .none;
    };
    defer self.alloc.free(screen);
    return switch (says.verdict(screen)) {
        .blocked => .blocked,
        .ready => if (says.ready_without_agent) .ready else .none,
        .neither => .none,
    };
}

fn poltergeistAgentPresent(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.agentPresent(id);
}

/// Which of Polter's tools this terminal may see.
///
/// **Worked out from `rpc.Method` rather than from a list kept beside it.**
/// The tools and the host's methods are the same set -- `cli/mcp.zig` has a
/// test both ways round asserting it -- so deriving the names from the enum
/// means a tool added upstream is covered here the moment it exists. A list
/// would be wrong the first time somebody added one, and wrong silently: the
/// new tool would simply never be filtered.
fn poltergeistPersonaFace(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
) anyerror!poltergeistpkg.rpc.Host.PersonaFace {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.ensurePersonas();
    return .{
        .tools = try self.visibleTools(alloc, id),
        .epoch = self.personas.stateOf(id).epoch,
    };
}

/// The Polter tools `id` may see. One function, so `persona_face` and
/// `terminal_capabilities` cannot give two answers about one terminal.
fn visibleTools(self: *App, alloc: Allocator, id: poltergeistpkg.Bus.Id) ![]const []const u8 {
    const all = std.enums.values(poltergeistpkg.rpc.Method);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer names.deinit(alloc);
    try names.ensureTotalCapacity(alloc, all.len);

    for (all) |m| {
        const name = @tagName(m);
        if (!self.personas.toolVisible(id, name)) continue;
        names.appendAssumeCapacity(name);
    }
    return try names.toOwnedSlice(alloc);
}

/// What one terminal can do, for a supervisor (`terminal_capabilities`).
/// Only the role half and the tools: the standing is the bus's and `rpc`
/// fills it in.
fn poltergeistTerminalCapabilities(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
) anyerror!poltergeistpkg.rpc.Host.Capabilities {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.findSurfaceByID(id) == null) return error.UnknownTerminal;
    self.ensurePersonas();

    // The cache's copy, never a read: asking an adapter runs a process and
    // this is the app thread. A cache nobody has filled yet comes back as
    // `stale`, and says so.
    const clis = try self.agentClisJson(alloc, false);
    return .{
        .persona = try self.personas.capabilities(alloc, id, clis, self.poltergeistElapsedMs()),
        .tools = try self.visibleTools(alloc, id),
    };
}

/// Whether this terminal's persona wants a named upstream slot.
///
/// A terminal wearing no persona wants everything, which is what Polter
/// does today -- so a machine with no `personas.json` behaves exactly as it
/// did before this existed.
fn poltergeistPersonaSlot(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    slot: []const u8,
) anyerror!poltergeistpkg.rpc.Host.PersonaSlot {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.ensurePersonas();

    const state = self.personas.stateOf(id);
    if (state.key == null) return .{ .wanted = true, .epoch = state.epoch };

    for (state.effective.slots) |name| {
        if (std.mem.eql(u8, name, slot)) {
            return .{ .wanted = true, .epoch = state.epoch };
        }
    }
    return .{ .wanted = false, .epoch = state.epoch };
}

fn poltergeistQuiet(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) u64 {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.poltergeist.quietMs(id, self.poltergeistElapsedMs());
}

fn poltergeistCallSilent(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) ?u64 {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.poltergeist.callSilentMs(id, self.poltergeistElapsedMs());
}

fn poltergeistNow(ctx: *anyopaque) u64 {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.poltergeistElapsedMs();
}

fn poltergeistResourceUsage(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) ?poltergeistpkg.ledger.Usage {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.resource_usage.get(id);
}

/// Which group a terminal is in, for the overall reading's sidecar rows
/// (task 2149): read from the control room's rows, the same place the
/// performance page reads a terminal's group from.
fn overallGroupOfPane(ctx: ?*const anyopaque, pane: u64) []const u8 {
    const self: *const App = @ptrCast(@alignCast(ctx orelse return ""));
    for (self.control_room.route_rows) |row| {
        for (row.members) |m| if (m == pane) return row.group;
    }
    return "";
}

/// `resource_overview`'s answer (task 2149): Polter's own processes, the
/// machine, and what the core knows that no process table does.
fn poltergeistResourceOverview(ctx: *anyopaque, alloc: Allocator, req: poltergeistpkg.rpc.Request) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const p = req.resource_overview;
    return self.overallAnswer(alloc, p.group, p.pid);
}

/// The whole answer `resource_overview` gives and the overall page draws
/// (task 2149): Polter's own processes, the machine, and what the core
/// knows that no process table does.
///
/// **One function, because there is one answer.** The MCP tool and the page
/// are two doors onto the same reading; a second walk here would be a
/// second answer, and the page's is the one somebody is looking at while a
/// supervisor quotes the tool's. `error.NoReading` before the first
/// sampling, and `error.NoSuchGroup` for a name nobody has -- answering an
/// empty list for one would read as "it costs nothing".
///
/// `group` empty is every group; `pid` zero is every process.
fn overallAnswer(self: *App, alloc: Allocator, group: []const u8, pid: u32) (Allocator.Error || error{ NoReading, NoSuchGroup })![]const u8 {
    const overall = self.resource_overall orelse return error.NoReading;
    if (group.len > 0 and !self.chat.exists(group)) return error.NoSuchGroup;

    var facts: std.ArrayListUnmanaged(poltergeistpkg.OverallPage.GroupFacts) = .empty;
    defer facts.deinit(alloc);
    for (self.control_room.route_rows) |row| {
        var tasks: u32 = 0;
        var tasks_open: u32 = 0;
        if (self.tasks.inGroup(alloc, row.group)) |list| {
            defer alloc.free(list);
            tasks = @intCast(list.len);
            for (list) |t| if (t.state == .open) {
                tasks_open += 1;
            };
        } else |_| {}
        const record: u64 = if (self.group_log) |*l| l.recordBytes(alloc, row.group) else 0;
        // The group page's segment bar: three widths in MiB, from the same
        // reading the performance page draws its cards from. **The fourth
        // (the group's own chat) is not here**: it is a row in `Overall`,
        // and this file hands no reading to it.
        var supervisor_mib: u64 = 0;
        var workers_mib: u64 = 0;
        var yours_mib: u64 = 0;
        for (row.members, row.own) |id, own| {
            const usage = self.resource_usage.get(id) orelse continue;
            const mib = usage.mem >> 20;
            if (own) {
                yours_mib += mib;
            } else if (row.steward) |s| {
                if (s == id) supervisor_mib += mib else workers_mib += mib;
            } else {
                workers_mib += mib;
            }
        }
        try facts.append(alloc, .{
            .group = row.group,
            .tasks = tasks,
            .tasks_open = tasks_open,
            .record_bytes = record,
            .supervisor_mib = supervisor_mib,
            .workers_mib = workers_mib,
            .yours_mib = yours_mib,
        });
    }

    const wall = self.overall_wall_ms_for_test orelse self.poltergeistWallMs();
    return poltergeistpkg.OverallPage.render(alloc, overall, .{
        .now_ms = wall,
        .offset_ms = poltergeistpkg.daylog.localOffsetMs(wall),
        .mem_total = poltergeistpkg.procscan.physicalMemory(),
        .groups = facts.items,
        .groupOfPane = overallGroupOfPane,
        .ctx = self,
        .only_group = group,
        .only_pid = pid,
    });
}

/// Every terminal on screen, with where it is and what it is called.
///
/// The chat interface is left out: it is a window onto the conversation,
/// not a terminal anybody could resume, and listing it would put a thing
/// the supervisor cannot act on into the list it uses to decide.
/// Open a terminal in the same window, starting in `cwd`.
///
/// The tab is opened from the caller's own terminal, so it lands in the
/// caller's window -- which is the only window Poltergeist has any view of.
///
/// **The id comes back by looking, not by being told.** Creating a surface
/// goes out through the apprt and comes back in when the runtime gets round
/// to it; on macOS that is a notification, delivered synchronously today and
/// under no obligation to stay that way. So the surfaces are counted before
/// and after, and if a new one has appeared by the time the action returns it
/// is named. If none has, that is not a failure -- the tab is still opening
/// -- and the caller is told to go and look. Waiting on it here would park
/// the socket thread on something the UI thread has to finish.
/// Render the configuration as text if that has not been done yet.
///
/// **Called as a surface starts, because `updateConfig` runs only on a
/// config reload and neither apprt calls it at launch.** The same reason
/// the socket, the chat log, the notify window and the plugins are all
/// primed there -- this was the one thing on that list that was left to
/// the reload.
///
/// What it cost: `config_get` answered *"the configuration has not been
/// read yet"* to every agent that asked, on a running app with its windows
/// open, until somebody happened to reload the config. The configuration
/// had of course been read; **this rendering of it had not**, and the
/// message named the wrong one of the two.
///
/// Idempotent, like the other `ensure` calls it sits with: every surface
/// runs this and only the first does the work. The reload path still goes
/// through `refreshPoltergeistConfigText` directly, because there the point
/// is to replace what is already there.
pub fn ensurePoltergeistConfigText(self: *App, config: *const Config) void {
    if (self.poltergeist_config_text.len > 0) return;
    self.refreshPoltergeistConfigText(config);
}

/// Read `personas.json`, once, the first time anybody asks.
///
/// Lazy for `ensurePoltergeistConfigText`'s reason: a user who has never
/// written one should not pay a file read at startup. Idempotent -- every
/// caller runs it and only the first does the work.
///
/// **It answers "we looked" even when it finds nothing**, which is what
/// lets the interface tell "you have not defined any personas" apart from
/// "nobody has read the file yet". Those two want different sentences and
/// an empty list cannot carry both.
pub fn ensurePersonas(self: *App) void {
    if (self.personas_attempted) return;
    self.personas_attempted = true;

    const path = poltergeistpkg.PersonaStore.defaultPath(self.alloc) catch |err| {
        log.warn("poltergeist: could not work out where personas.json lives err={}", .{err});
        return;
    };
    defer self.alloc.free(path);

    self.personas.load(global.io(), path);
}

pub fn ensureSquads(self: *App) void {
    if (self.squads_attempted) return;
    self.squads_attempted = true;

    const path = poltergeistpkg.SquadStore.defaultPath(self.alloc) catch |err| {
        log.warn("poltergeist: could not work out where squads.json lives err={}", .{err});
        return;
    };
    defer self.alloc.free(path);

    self.squads.load(global.io(), path);
}

/// The library as `squad.statusOf` wants it: null when `personas.json` is
/// not readable, which is not the same as having no roles.
fn squadRoles(self: *App) ?poltergeistpkg.persona.Set {
    self.ensurePersonas();
    if (self.personas.load_error != null or !self.personas.loaded) return null;
    return self.personas.set;
}

/// Every squad template, as JSON (`SquadStore.writeCatalogJson`).
pub fn squadCatalogJson(self: *App, alloc: Allocator) ![]u8 {
    self.ensureSquads();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try self.squads.writeCatalogJson(&out.writer, self.squadRoles());
    return try out.toOwnedSlice();
}

/// Write one template. The window (`who` = user) and `squad_put`
/// (`who` = supervisor) both come here; `SquadStore.put` is the one writer.
pub fn putSquad(self: *App, json: []const u8, who: poltergeistpkg.Bus.Authority) !void {
    self.ensureSquads();
    const path = try poltergeistpkg.SquadStore.defaultPath(self.alloc);
    defer self.alloc.free(path);
    try self.squads.put(global.io(), path, json, self.squadRoles(), who);
}

pub fn deleteSquad(self: *App, key: []const u8, who: poltergeistpkg.Bus.Authority) !void {
    self.ensureSquads();
    const path = try poltergeistpkg.SquadStore.defaultPath(self.alloc);
    defer self.alloc.free(path);
    try self.squads.remove(global.io(), path, key, who);
}

/// Re-render the configuration as text.
///
/// Failure leaves the previous text in place rather than clearing it: an
/// agent reading a slightly stale value is better off than one told there is
/// no configuration at all, and the next reload will try again.
///
/// ⚠️ **On the very first render there is no previous text to leave**, so a
/// failure here is the one way `poltergeistConfigText` can still answer
/// `NoConfig` on a running app -- see the note there.
fn refreshPoltergeistConfigText(self: *App, config: *const Config) void {
    const fmt: configpkg.FileFormatter = .{ .alloc = self.alloc, .config = config };

    var out: std.Io.Writer.Allocating = .init(self.alloc);
    defer out.deinit();
    fmt.format(&out.writer) catch |err| {
        log.warn("poltergeist: could not render the config err={}", .{err});
        return;
    };

    const text = out.toOwnedSlice() catch return;
    if (self.poltergeist_config_text.len > 0) self.alloc.free(self.poltergeist_config_text);
    self.poltergeist_config_text = text;
}

/// The configuration, or the lines of it that begin with `key`.
///
/// Lines rather than a value, because a key may appear more than once --
/// `poltergeist-notify` is written once per channel -- and handing back the
/// first would quietly lose the rest.
fn poltergeistConfigText(
    ctx: *anyopaque,
    alloc: Allocator,
    key: []const u8,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    // **Still reachable, and only one way in.** Every surface primes this
    // as it starts (`ensurePoltergeistConfigText`), so an app with a window
    // open has it -- which is what this branch used to answer wrongly. What
    // is left is the render itself failing on its first try, which leaves
    // the text empty because there is no earlier value to fall back to.
    // Rare, and not the same thing as "not read yet", but a real state: the
    // agent is better told there is nothing to give it than handed "".
    if (self.poltergeist_config_text.len == 0) return error.NoConfig;
    if (key.len == 0) return alloc.dupe(u8, self.poltergeist_config_text);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var it = std.mem.splitScalar(u8, self.poltergeist_config_text, '\n');
    while (it.next()) |line| {
        // The whole key, not a prefix of it: `poltergeist-watch` must not
        // match `poltergeist-watch-something` that upstream adds later.
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = line[key.len..];
        if (!std.mem.startsWith(u8, rest, " =")) continue;

        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }

    if (out.items.len == 0) return error.NoSuchKey;
    return out.items;
}

/// Attribute the split asked for last time to the surface that appeared.
///
/// **Called at the start of the next placement, which is the first moment the
/// surface is certainly there.** Doing it any earlier is what capped the
/// placement at one worker: the code looked for a surface that the apprt had
/// not created yet, found none, and recorded nothing -- so the second worker
/// saw no worker of its own in the tab and read the tab as somebody else's.
/// `poltergeistSettlePendingWorker` from the notice wake (task 1848), and
/// the next wake asked for while it is still not there. The settlement
/// gives up by itself after `worker_wait_ms`.
fn settlePendingWorkerOnTime(self: *App) void {
    if (self.poltergeist_pending_worker == null) return;
    self.poltergeistSettlePendingWorker(self.alloc) catch |err| {
        log.warn("poltergeist: could not look for the worker asked for err={}", .{err});
        return;
    };
    if (self.poltergeist_pending_worker != null) self.noticeRetryIn(worker_wait_look_ms);
}

fn poltergeistSettlePendingWorker(self: *App, alloc: Allocator) Allocator.Error!void {
    var pending = self.poltergeist_pending_worker orelse return;

    const now = try self.poltergeistSeen(alloc);
    defer alloc.free(now);
    if (pending.attribute(now, &.{})) |id| {
        self.poltergeistRecordWorker(pending.by, id);
        self.claimLaunchLimits(pending.by, id);
        log.info("poltergeist: recorded terminal {x} as a worker of {x}", .{ id, pending.by });
        self.poltergeist_pending_worker = null;
        pending.deinit(self.alloc);
        return;
    }

    // **Nothing yet.** Which is not the same as nothing ever: the apprt
    // performs a split on its own thread, so a call that follows the last one
    // closely enough looks before the terminal exists. Waited for as long as
    // a worker request is parked for it (task 1797, Q3).
    const now_ms = self.poltergeistElapsedMs();
    if (!pending.overdue(now_ms)) {
        self.poltergeist_pending_worker = pending;
        return;
    }

    // ⚠️ **Given up on, and said.** The split was refused, or the person
    // closed the pane before this ran. Left in place it would wedge every
    // later placement, which is a worse failure than the one it was guarding
    // against.
    self.poltergeist_pending_worker = null;
    pending.deinit(self.alloc);
    log.info(
        "poltergeist: the terminal asked for {d}ms ago never appeared; " ++
            "the next worker is placed without it",
        .{now_ms -| pending.asked_ms},
    );
}

/// Every surface but the chat, with the tab each is in. See `Seen`.
fn poltergeistSeen(self: *App, alloc: Allocator) Allocator.Error![]Seen {
    var out: std.ArrayListUnmanaged(Seen) = .empty;
    errdefer out.deinit(alloc);
    for (self.surfaces.items) |v| {
        const s = v.core();
        if (self.isChatSurface(s.id)) continue;
        try out.append(alloc, .{ .id = s.id, .tab = poltergeistTabOf(s) });
    }
    return out.toOwnedSlice(alloc);
}

/// The tab a surface is in, as the apprt's opaque key, or null when the
/// apprt did not say -- one that does not implement the question, or a
/// surface in no tab at all (on macOS, a closed tab kept alive for undo).
fn poltergeistTabOf(surface: *Surface) ?u64 {
    var window: u64 = 0;
    var tab: u64 = 0;
    _ = surface.rt_app.performAction(
        .{ .surface = surface },
        .poltergeist_grouping,
        .{ .window = &window, .tab = &tab },
    ) catch {};
    return if (tab == 0) null else tab;
}

/// A surface as attribution sees it: which one, and which tab it is in.
const Seen = struct {
    id: poltergeistpkg.Bus.Id,
    /// Null when the apprt did not say; see `poltergeistTabOf`.
    tab: ?u64,
};

/// A split asked for whose terminal has not appeared yet. See
/// `poltergeist_pending_worker`.
const PendingWorker = struct {
    by: poltergeistpkg.Bus.Id,
    before: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, void),

    /// The tab the split was asked for in -- the tab of the surface being
    /// split, which is where its terminal will appear. Null when the apprt
    /// does not say which tab anything is in.
    tab: ?u64,

    /// When it was asked for (`poltergeistElapsedMs`).
    ///
    /// **Because "not yet" and "never" are different answers.** Two calls
    /// back to back leave the first split still on the apprt's queue, so the
    /// first look finds nothing -- and dropping the record there is what let
    /// the second call place a worker as though the first had not happened.
    /// Kept for `worker_wait_ms` (task 1797, Q3; it was two looks, however
    /// far apart), then given up on, so a split that really was refused
    /// cannot wedge every later placement. No default: a record that does
    /// not say when would never be overdue, or always.
    asked_ms: u64,

    fn deinit(self: *PendingWorker, alloc: Allocator) void {
        self.before.deinit(alloc);
    }

    fn overdue(self: *const PendingWorker, now_ms: u64) bool {
        return now_ms >= self.asked_ms +| worker_wait_ms;
    }

    /// Which of `now` is the terminal this split produced.
    ///
    /// **The rule is "new since the split was asked for, in the tab it was
    /// asked for in, and not the chat".**
    /// Split out from the App so the sequence it belongs to can be tested
    /// without a window system -- and the sequence is the whole point, since
    /// the defect it replaced was one of timing rather than of rule.
    fn attribute(
        self: *const PendingWorker,
        now: []const Seen,
        chat: []const poltergeistpkg.Bus.Id,
    ) ?poltergeistpkg.Bus.Id {
        for (now) |seen| {
            const id = seen.id;
            if (self.before.contains(id)) continue;
            // ⚠️ **Only in the tab the split was asked for in** (task 881).
            // Anything else new since then -- a terminal somebody opened in
            // another tab, or another supervisor's -- used to be taken for
            // this worker whenever it came first in the list, and the next
            // worker was then split beside it, in a tab nobody was looking
            // at. A surface whose tab is not known is not known to be here.
            // Only when the apprt says nothing about tabs at all is there no
            // tab to hold it to.
            if (self.tab) |want| if (seen.tab != want) continue;
            if (std.mem.indexOfScalar(poltergeistpkg.Bus.Id, chat, id) != null) continue;
            return id;
        }
        return null;
    }

    /// What a split the apprt has said it will make leaves behind: its
    /// terminal, if it is already there, or the question to ask next time.
    ///
    /// `before` is the surfaces from **before** the split was asked for;
    /// `now` is the surfaces after `performAction` came back.
    fn afterSplit(
        alloc: Allocator,
        by: poltergeistpkg.Bus.Id,
        asked_ms: u64,
        tab: ?u64,
        before: *const std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, void),
        now: []const Seen,
        chat: []const poltergeistpkg.Bus.Id,
    ) Allocator.Error!AfterSplit {
        // ⚠️ **The snapshot from before the split, never one taken after.**
        // An apprt that splits synchronously (macOS) has already added the
        // worker by now, and a snapshot taken here would hold it -- so
        // nothing would ever be new against it, and the next placement
        // would wait on a split that had finished (task 877).
        var pending: PendingWorker = .{ .by = by, .asked_ms = asked_ms, .tab = tab, .before = try before.clone(alloc) };

        // And a worker that is already here is attributed now, not on the
        // next call: there is nothing to wait for.
        if (pending.attribute(now, chat)) |id| {
            pending.deinit(alloc);
            return .{ .appeared = id };
        }
        return .{ .pending = pending };
    }
};

const AfterSplit = union(enum) {
    appeared: poltergeistpkg.Bus.Id,
    pending: PendingWorker,
};

/// Test fixture: `ids`, all in one `tab`.
fn seenIn(comptime tab: ?u64, comptime ids: []const poltergeistpkg.Bus.Id) [ids.len]Seen {
    var out: [ids.len]Seen = undefined;
    for (ids, 0..) |id, i| out[i] = .{ .id = id, .tab = tab };
    return out;
}

test "a terminal opened in another tab is not taken for the worker (task 881)" {
    // The Windows host splits asynchronously, so the worker is attributed on
    // the next placement -- and anything that appeared in between was a
    // candidate. Here the split was asked for in tab 7, and before the next
    // placement somebody opened terminal 3 in tab 9; it comes first in the
    // list, as a surface added earlier would.
    const testing = std.testing;
    const alloc = testing.allocator;

    var pending: PendingWorker = .{ .by = 1, .asked_ms = 0, .tab = 7, .before = .empty };
    defer pending.deinit(alloc);
    try pending.before.put(alloc, 1, {});

    const stranger_first = [_]Seen{
        .{ .id = 1, .tab = 7 },
        .{ .id = 3, .tab = 9 },
        .{ .id = 2, .tab = 7 },
    };
    const found = pending.attribute(&stranger_first, &.{});
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, 2), found);

    // Only the stranger so far, the worker not yet made: nothing, rather
    // than the stranger.
    const only_stranger = [_]Seen{ .{ .id = 1, .tab = 7 }, .{ .id = 3, .tab = 9 } };
    const too_early = pending.attribute(&only_stranger, &.{});
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, null), too_early);

    // A surface in no tab -- a closed tab kept alive for undo on macOS --
    // is not in the tab either.
    const in_no_tab = [_]Seen{ .{ .id = 1, .tab = 7 }, .{ .id = 4, .tab = null } };
    const orphan = pending.attribute(&in_no_tab, &.{});
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, null), orphan);

    // An apprt that never says which tab anything is in keeps the old rule
    // rather than attributing nothing at all.
    var blind: PendingWorker = .{ .by = 1, .asked_ms = 0, .tab = null, .before = .empty };
    defer blind.deinit(alloc);
    try blind.before.put(alloc, 1, {});
    const unknown = [_]Seen{ .{ .id = 1, .tab = null }, .{ .id = 2, .tab = null } };
    const blind_found = blind.attribute(&unknown, &.{});
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, 2), blind_found);
}

test "a split that has already happened is attributed at once (task 877)" {
    // Measured 2026-09-28 on macOS: the first `here` came back with the new
    // terminal's id, so that split was complete before `performAction`
    // returned. The snapshot of "what was here before" was taken after it,
    // so it held the new worker too, nothing was ever new against it, and
    // the next `here` fell back to a tab as `last_worker_pending`.
    const testing = std.testing;
    const alloc = testing.allocator;

    var before: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, void) = .empty;
    defer before.deinit(alloc);
    try before.put(alloc, 1, {});

    // Synchronous: the worker is already in the list.
    var sync = try PendingWorker.afterSplit(alloc, 1, 0, 7, &before, &seenIn(7, &.{ 1, 2 }), &.{});
    defer if (sync == .pending) sync.pending.deinit(alloc);

    // Found at all -- now, or by the next call looking at the same list.
    // This is the half the second `here` depended on.
    const found: ?poltergeistpkg.Bus.Id = switch (sync) {
        .appeared => |id| id,
        .pending => |*p| p.attribute(&seenIn(7, &.{ 1, 2 }), &.{}),
    };
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, 2), found);

    // And found now: there is nothing to wait for.
    const at_once = sync == .appeared;
    try testing.expect(at_once);

    // Asynchronous: not there yet, and found against the same `before` on
    // the next call.
    var later = try PendingWorker.afterSplit(alloc, 1, 0, 7, &before, &seenIn(7, &.{1}), &.{});
    defer if (later == .pending) later.pending.deinit(alloc);
    try testing.expect(later == .pending);
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, 2), later.pending.attribute(&seenIn(7, &.{ 1, 2 }), &.{}));
}

test "a worker is attributed after its terminal exists, not when it was asked for" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // The tab as it stood when the split was asked for: the supervisor alone.
    var pending: PendingWorker = .{ .by = 1, .asked_ms = 0, .tab = 7, .before = .empty };
    defer pending.deinit(alloc);
    try pending.before.put(alloc, 1, {});

    // ⚠️ **The moment the split was asked for.** An apprt that splits
    // asynchronously (the Windows host) has not changed the surface list yet. Anything that
    // tries to attribute here finds nothing -- which is exactly what capped
    // the placement at one worker on the real machine.
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, null), pending.attribute(&seenIn(7, &.{1}), &.{}));

    // The next placement is a later moment, and the terminal is there by then.
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, 2), pending.attribute(&seenIn(7, &.{ 1, 2 }), &.{}));

    // A chat surface opened in between is not the worker.
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, 3), pending.attribute(&seenIn(7, &.{ 1, 2, 3 }), &.{2}));
}

/// How long a worker request waits for the worker its supervisor asked for
/// just before (task 1797, Q3). The next one is stacked onto that one, and
/// on the Windows host it is made after `performAction` returns; past this
/// it is placed without it, and the log says so.
const worker_wait_ms: u64 = 3_000;

/// How often a parked worker request is looked at again while it waits.
const worker_wait_look_ms: u64 = 250;

/// A worker request parked by `openTerminalAt` until the worker before it
/// has appeared. See `poltergeist_worker_waits`.
const WorkerWait = struct {
    /// The request, with a reference of the wait's own.
    held: *poltergeistpkg.Server.Pending,
    /// When the wait gives up (`poltergeistElapsedMs`). Kept across the
    /// looks: a request dispatched again and parked again waits out the
    /// same three seconds, not three more.
    deadline_ms: u64,
    /// Handed back to the mailbox and not dispatched yet: not handed twice.
    requeued: bool = false,
};

/// Hand the parked worker requests back to be dispatched again: each one
/// every `worker_wait_look_ms`, and one whose time is up so that it is
/// placed without the worker it waited for. Called with the other sweeps.
fn sweepWorkerWaits(self: *App) void {
    if (self.poltergeist_worker_waits.items.len == 0) return;
    for (self.poltergeist_worker_waits.items) |*w| {
        if (w.requeued) continue;
        // A reference for the mailbox, which `poltergeistRequest` releases
        // as it does every request's; the wait's own is released when the
        // request finds it again (`takeWorkerWait`).
        w.held.retain();
        if (self.poltergeist_requests.push(global.io(), w.held, .{ .instant = {} }) == 0) {
            w.held.release();
            log.warn("poltergeist: could not hand a waiting worker request back; looked at again next time", .{});
            continue;
        }
        w.requeued = true;
    }
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
    self.noticeRetryIn(worker_wait_look_ms);
}

/// The wait the request being dispatched was parked in, taken out of the
/// list: its deadline, or null when it was not parked.
fn takeWorkerWait(self: *App) ?u64 {
    const pending = self.poltergeist_dispatching orelse return null;
    for (self.poltergeist_worker_waits.items, 0..) |w, i| {
        if (w.held != pending) continue;
        _ = self.poltergeist_worker_waits.swapRemove(i);
        // The mailbox's reference keeps it alive for this dispatch.
        w.held.release();
        return w.deadline_ms;
    }
    return null;
}

/// Park the request being dispatched until `deadline_ms`. False when there
/// is nothing to park -- not dispatched from a request -- and the caller
/// places without waiting.
fn parkWorkerWait(self: *App, deadline_ms: u64) Allocator.Error!bool {
    const pending = self.poltergeist_dispatching orelse return false;
    try self.poltergeist_worker_waits.append(self.alloc, .{ .held = pending, .deadline_ms = deadline_ms });
    pending.retain();
    self.poltergeist_parked = true;
    self.noticeRetryIn(worker_wait_look_ms);
    return true;
}

/// Where a supervisor's next worker goes, given only facts (task 1797).
///
/// **Split out so the rule can be tested without an apprt.** The user's
/// rule: the supervisor's tab is two panes, the supervisor on the left and
/// one stack of its workers on the right. So the first worker splits the
/// supervisor to the right, and every one after it joins that pane's stack,
/// in front -- no columns, no count, and no tab for a worker any more.
const WorkerPlacement = union(enum) {
    /// None of this supervisor's workers is in its tab now: split the
    /// supervisor to the right. The pane made is the stack to come.
    beside_supervisor,
    /// Stacked in front of this worker, the newest of the supervisor's own
    /// still in its tab: **a worker pane, by identity** -- never a pane by
    /// position, so a pane the person opened beside the supervisor is not
    /// stacked into (Q5).
    onto_worker: poltergeistpkg.Bus.Id,
    /// A worker this supervisor asked for has not appeared yet, and where
    /// the next one goes depends on it: wait (Q3).
    wait,
    /// The apprt does not say how many terminals share a tab, so it cannot
    /// be told which tab anything is in: a tab.
    new_tab,

    /// `panes` is how many terminals share the supervisor's tab, as the
    /// apprt counted them; zero means it did not answer. `last_here` is
    /// `WorkerColumn.lastHere`. `unsettled` is whether a terminal this
    /// supervisor asked for has not appeared yet.
    fn decide(panes: u32, last_here: ?poltergeistpkg.Bus.Id, unsettled: bool) WorkerPlacement {
        // ⚠️ **A worker that has not appeared is not a pane to stack onto
        // or to step past.** Placing anyway would put the next one beside
        // the supervisor as a second stack, or onto an older worker.
        if (unsettled) return .wait;
        if (panes == 0) return .new_tab;
        if (last_here) |w| return .{ .onto_worker = w };
        return .beside_supervisor;
    }
};

/// This supervisor's workers as the placement sees them.
///
/// **Split out for the same reason as `WorkerPlacement`**: "ours, and only
/// ours" is what a count of panes cannot say, and it is tested here without
/// a window system.
const WorkerColumn = struct {
    /// The newest of `workers` (the supervisor's list, oldest first) that
    /// is still open and in `tab`, the supervisor's tab; `now` is every
    /// surface but the chat. One the person closed or dragged elsewhere is
    /// stepped over, and the one before it is the stack.
    fn lastHere(workers: []const poltergeistpkg.Bus.Id, now: []const Seen, tab: ?u64) ?poltergeistpkg.Bus.Id {
        var i = workers.len;
        while (i > 0) {
            i -= 1;
            const w = workers[i];
            const here = for (now) |seen| {
                if (seen.id == w) break sameTab(seen.tab, tab);
            } else false;
            if (here) return w;
        }
        return null;
    }

    /// Null is "the apprt did not say", and two of those are the same tab
    /// only in the sense that nothing tells them apart.
    fn sameTab(a: ?u64, b: ?u64) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return x == y;
    }
};

test "1797: the first worker splits the supervisor, every one after it joins that stack" {
    const testing = std.testing;
    const settled = false;

    // Nobody answered: a tab, whatever else is true.
    try testing.expectEqual(WorkerPlacement.new_tab, WorkerPlacement.decide(0, null, settled));
    try testing.expectEqual(WorkerPlacement.new_tab, WorkerPlacement.decide(0, 2, settled));

    // The supervisor alone, or with the person's own panes: beside it.
    const first = WorkerPlacement.decide(1, null, settled);
    try testing.expectEqual(WorkerPlacement.beside_supervisor, first);
    const among_theirs = WorkerPlacement.decide(4, null, settled);
    try testing.expectEqual(WorkerPlacement.beside_supervisor, among_theirs);

    // One of ours here: onto it, however many there are -- no columns, no
    // tab at seven.
    const second = WorkerPlacement.decide(2, 2, settled);
    try testing.expectEqual(WorkerPlacement{ .onto_worker = 2 }, second);
    const ninth = WorkerPlacement.decide(2, 9, settled);
    try testing.expectEqual(WorkerPlacement{ .onto_worker = 9 }, ninth);

    // The one asked for before has not appeared: wait, whatever is here.
    const early = WorkerPlacement.decide(2, 2, true);
    try testing.expectEqual(WorkerPlacement.wait, early);
    const early_first = WorkerPlacement.decide(1, null, true);
    try testing.expectEqual(WorkerPlacement.wait, early_first);
}

test "1797: the stack is the newest worker of ours still in the tab, by identity" {
    const testing = std.testing;
    const tab: ?u64 = 7;
    const now = [_]Seen{
        // The supervisor.
        .{ .id = 1, .tab = tab },
        .{ .id = 2, .tab = tab },
        .{ .id = 3, .tab = tab },
        // One of ours that the person dragged to another tab.
        .{ .id = 5, .tab = 8 },
        // A terminal the person opened here: in the tab, and not ours.
        .{ .id = 6, .tab = tab },
    };
    // The newest (5) is elsewhere, 9 was closed: 3 is the stack.
    const stack = WorkerColumn.lastHere(&.{ 2, 3, 5, 9 }, &now, tab);
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, 3), stack);
    // None of ours here: the person's pane (6) is never one.
    const none = WorkerColumn.lastHere(&.{ 5, 9 }, &now, tab);
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, null), none);
    const empty = WorkerColumn.lastHere(&.{}, &now, tab);
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, null), empty);
    // The supervisor's own tab moved (rule 4): ours are in the old one.
    const moved = WorkerColumn.lastHere(&.{ 2, 3 }, &now, 8);
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, null), moved);
    // An apprt that says nothing about tabs: every open worker counts.
    const blind = [_]Seen{ .{ .id = 1, .tab = null }, .{ .id = 2, .tab = null } };
    const unknown = WorkerColumn.lastHere(&.{2}, &blind, null);
    try testing.expectEqual(@as(?poltergeistpkg.Bus.Id, 2), unknown);
}

/// Where `poltergeistPlaceWorker` says the next worker goes: a split, onto
/// a stack, a wait, or a tab and the reason -- the reason travels to the
/// caller in the reply (issue #17), not only to the log.
const WorkerSpot = union(enum) {
    split: Split,
    /// `poltergeist_new_stacked` on this worker's surface (task 1797).
    stack: *Surface,
    /// A worker this supervisor asked for has not appeared yet.
    wait,
    tab: poltergeistpkg.rpc.TabWhy,

    const Split = struct { target: *Surface, direction: apprt.action.SplitDirection };
};

/// `id` has appeared as the worker `by` launched: the resource lines that
/// launch asked for go on it now (task 1993, `Bus.claimPendingLimits`).
/// Here and not in `poltergeistRecordWorker`, which also records a pane
/// that was moved or re-homed -- that one asked for no lines.
fn claimLaunchLimits(self: *App, by: poltergeistpkg.Bus.Id, id: poltergeistpkg.Bus.Id) void {
    if (self.poltergeist.claimPendingLimits(by, id, self.poltergeistElapsedMs()))
        log.info("resources: terminal {x} took the lines {x}'s launch asked for", .{ id, by });
}

/// Add `id` to the end of `by`'s workers. See `poltergeist_workers`.
fn poltergeistRecordWorker(self: *App, by: poltergeistpkg.Bus.Id, id: poltergeistpkg.Bus.Id) void {
    // On the bus as well, for the snapshot's `who.worker_of`: what a host
    // keeps with a project, and says back after a restart to land here
    // again (#1498).
    self.poltergeist.markWorkerOf(id, by) catch |err| {
        log.warn("poltergeist: could not record terminal {x} as a worker of {x} err={}", .{ id, by, err });
    };
    const entry = self.poltergeist_workers.getOrPut(self.alloc, by) catch return;
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    entry.value_ptr.append(self.alloc, id) catch {};
}

/// The terminal whose pane `by`'s next worker would be stacked onto under
/// `auto`, by the same `WorkerPlacement` -- null when `auto` would split it
/// off `by` or open a tab. Asked for a worker launched `here`, which is not
/// put there, so that the reply can say where the stack is (task 1958).
/// Changes nothing: no wait, no list cleared.
fn poltergeistStackOf(self: *App, alloc: Allocator, by: poltergeistpkg.Bus.Id) Allocator.Error!?poltergeistpkg.Bus.Id {
    const surface = self.findSurfaceByID(by) orelse return null;
    var panes: u32 = 0;
    _ = surface.rt_app.performAction(
        .{ .surface = surface },
        .poltergeist_tab_panes,
        .{ .count = &panes },
    ) catch {};
    const workers: []const poltergeistpkg.Bus.Id = if (self.poltergeist_workers.get(by)) |l| l.items else &.{};
    const now = try self.poltergeistSeen(alloc);
    defer alloc.free(now);
    const last = WorkerColumn.lastHere(workers, now, poltergeistTabOf(surface));
    return switch (WorkerPlacement.decide(panes, last, false)) {
        .onto_worker => |w| w,
        .beside_supervisor, .new_tab, .wait => null,
    };
}

/// Where `by`'s next worker goes, by `WorkerPlacement`. `waited_out` is a
/// request that has waited `worker_wait_ms` for the worker before it: it
/// is placed as if that one were not coming.
fn poltergeistPlaceWorker(
    self: *App,
    alloc: Allocator,
    rt_app: *apprt.App,
    surface: *Surface,
    by: poltergeistpkg.Bus.Id,
    waited_out: bool,
) Allocator.Error!WorkerSpot {
    // **The question only the apprt can answer.** Zero comes back when it did
    // not answer at all -- no apprt writes zero, because a tab holding this
    // surface holds at least it.
    var panes: u32 = 0;
    _ = rt_app.performAction(
        .{ .surface = surface },
        .poltergeist_tab_panes,
        .{ .count = &panes },
    ) catch {};

    if (waited_out) if (self.poltergeist_pending_worker) |*p| if (p.by == by) {
        // ⚠️ **Said, and placed: never dropped** (Q3).
        log.info(
            "poltergeist: waited {d}ms for the worker asked for before this one and it has not " ++
                "appeared; this one is placed without it",
            .{worker_wait_ms},
        );
        p.deinit(self.alloc);
        self.poltergeist_pending_worker = null;
    };

    const workers: []const poltergeistpkg.Bus.Id = if (self.poltergeist_workers.get(by)) |l| l.items else &.{};
    const now = try self.poltergeistSeen(alloc);
    defer alloc.free(now);
    const last = WorkerColumn.lastHere(workers, now, poltergeistTabOf(surface));
    const unsettled = if (self.poltergeist_pending_worker) |p| p.by == by else false;

    switch (WorkerPlacement.decide(panes, last, unsettled)) {
        .beside_supervisor => {
            // None of ours is left in this tab, so whatever the list still
            // names is closed or elsewhere: the new worker starts it again.
            if (self.poltergeist_workers.getPtr(by)) |l| l.clearRetainingCapacity();
            return .{ .split = .{ .target = surface, .direction = .right } };
        },
        .onto_worker => |id| {
            // In `now` a moment ago, so it is there; a lookup that fails is
            // still an answer.
            if (self.findSurfaceByID(id)) |t| return .{ .stack = t };
            if (self.poltergeist_workers.getPtr(by)) |l| l.clearRetainingCapacity();
            return .{ .split = .{ .target = surface, .direction = .right } };
        },
        .wait => return .wait,
        .new_tab => {
            log.info(
                "poltergeist: falling back to a tab -- this apprt does not say how " ++
                    "full a tab is",
                .{},
            );
            return .{ .tab = .no_pane_count };
        },
    }
}

// -- worktrees (task 1702) ---------------------------------------------------
//
// The rules are `poltergeist/worktree.zig`'s and are tested there, on
// repositories made under /tmp; these only find the ledger, the directory and
// the clock.
//
// **No git checkout on the app thread.** It is every terminal's thread and
// the person's window waits on it, and making a tree of this repository
// checks out six thousand files. So a request for a tree starts a
// `worktree.Job`, parks the request -- as a screenshot does -- and is
// dispatched again, the same request, when the job's thread hands it back;
// the second time round the tree is there and the terminal is opened as for
// any other directory. So do `worktree_status`, `worktree_remove` and what
// closing or cancelling a task does to its tree: each runs git several times
// and a removal deletes a directory, so each is a `worktree.Work` on the same
// kind of thread (task 2472), the request parked the same way.

const WorktreeWait = struct {
    job: *poltergeistpkg.worktree.Job,
    /// The request it parked, with a reference of its own.
    held: *poltergeistpkg.Server.Pending,
    /// For a close or a cancel: what the reply says of the members, to go
    /// after its first sentence. Owned (the app's allocator).
    preface: []u8 = &.{},
};

/// A finished job taken off the list: give it back with `deinit` once its
/// result has been read.
const WorktreeTaken = struct {
    job: *poltergeistpkg.worktree.Job,
    held: *poltergeistpkg.Server.Pending,
    preface: []u8,

    fn result(self: WorktreeTaken) poltergeistpkg.worktree.Result {
        return self.job.result.?;
    }

    fn deinit(self: WorktreeTaken, app: *App) void {
        self.job.destroy();
        self.held.release();
        app.alloc.free(self.preface);
    }
};

/// The job's thread: give the parked request back to the app thread, where
/// it is dispatched again and finds its tree made. Reads nothing of the job
/// but which request it was for.
fn worktreeJobDone(ctx: *anyopaque, job: *poltergeistpkg.worktree.Job) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const pending: *poltergeistpkg.Server.Pending = @ptrCast(@alignCast(job.user.?));
    // A reference for the mailbox, which `poltergeistRequest` releases as it
    // does every request's; the one the wait holds is released when the
    // wait is taken. A push that failed leaves the wait to be freed at quit.
    pending.retain();
    if (self.poltergeist_requests.push(global.io(), pending, .{ .instant = {} }) == 0) {
        log.warn("worktree: could not hand a finished worktree back to the app thread", .{});
        pending.release();
        return;
    }
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// The build leases, made when first asked about.
fn leases(self: *App) *poltergeistpkg.worktree.Leases {
    if (self.worktree_leases == null) self.worktree_leases = .init(self.alloc);
    return &self.worktree_leases.?;
}

/// The ledger, made in memory when no state directory was ever known.
fn worktreeLedger(self: *App) ?*poltergeistpkg.worktree.Ledger {
    if (self.poltergeist_worktrees == null) {
        self.poltergeist_worktrees = poltergeistpkg.worktree.Ledger.init(self.alloc, null) catch return null;
    }
    return &self.poltergeist_worktrees.?;
}

/// The tree `cwd` is in, for a terminal's environment (`POLTER_WORKTREE`).
/// Never makes the ledger: a terminal opened before the state directory is
/// known is in no tree Polter knows of.
pub fn worktreePathAt(self: *App, cwd: []const u8) ?[]const u8 {
    const ledger = if (self.poltergeist_worktrees) |*l| l else return null;
    const i = ledger.containing(cwd) orelse return null;
    return ledger.entries.items[i].path;
}

/// Run `work` on a thread of its own, for the request being dispatched.
///
/// **The first time** it starts the job, parks the request and answers
/// `error.WorktreePending`, which `rpc` turns into a reply that is never
/// sent. **The second time round** -- the job's thread dispatched the same
/// request again -- it hands back the finished job. App thread only.
fn worktreeRun(self: *App, work: poltergeistpkg.worktree.Work, preface: []const u8) anyerror!WorktreeTaken {
    const io = global.io();
    const ledger = self.worktreeLedger() orelse return error.OutOfMemory;
    // Nothing to park it on means nothing to answer it later with.
    const pending = self.poltergeist_dispatching orelse return error.CannotWait;

    for (self.poltergeist_worktree_jobs.items, 0..) |w, i| {
        if (w.held != pending) continue;
        if (!w.job.finished.load(.acquire)) {
            // Dispatched again before its job was done -- which nothing
            // does -- so it waits again rather than answer too early.
            self.poltergeist_parked = true;
            return error.WorktreePending;
        }
        _ = self.poltergeist_worktree_jobs.swapRemove(i);
        return .{ .job = w.job, .held = w.held, .preface = w.preface };
    }

    // The first time: start it, and park the request.
    const job = try poltergeistpkg.worktree.Job.create(std.heap.smp_allocator, .{ .io = io }, work, ledger.entries.items, worktreeJobDone, self);
    job.user = pending;
    const kept = try self.alloc.dupe(u8, preface);
    self.poltergeist_worktree_jobs.append(self.alloc, .{ .job = job, .held = pending, .preface = kept }) catch |err| {
        self.alloc.free(kept);
        job.destroy();
        return err;
    };
    pending.retain();
    job.start() catch |err| {
        _ = self.poltergeist_worktree_jobs.pop();
        self.alloc.free(kept);
        pending.release();
        job.destroy();
        return err;
    };
    self.poltergeist_parked = true;
    log.info("worktree: {s} off the app thread; the request waits", .{@tagName(work)});
    return error.WorktreePending;
}

fn poltergeistWorktreePrepare(
    ctx: *anyopaque,
    alloc: Allocator,
    by: poltergeistpkg.Bus.Id,
    cwd: []const u8,
    name: []const u8,
) anyerror!poltergeistpkg.worktree.Prepared {
    const self: *App = @ptrCast(@alignCast(ctx));
    const io = global.io();
    const dir = if (cwd.len > 0) cwd else self.terminalCwd(alloc, by) orelse return error.NoDirectory;
    if (!std.fs.path.isAbsolute(dir)) return error.NotAbsolute;
    // The same check a terminal opened there is put through, so a tree is
    // never asked of a directory the terminal could not then be opened in.
    _ = try poltergeistpkg.workdir.check(alloc, io, dir);
    const ledger = self.worktreeLedger() orelse return error.OutOfMemory;

    // The second time round: its job has finished. Written down here, on
    // the ledger's thread, and copied out of the job before it goes.
    const now: std.Io.Timestamp = .now(io, .real);
    const taken = try self.worktreeRun(.{ .manual = .{
        .dir = dir,
        .name = name,
        .location = self.poltergeist_worktree_location,
        .by = by,
        .now_ms = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms)),
    } }, "");
    defer taken.deinit(self);
    const done = try poltergeistpkg.worktree.commit(io, ledger, taken.result().prepared);
    return try done.dupe(alloc);
}

/// The directory a task's tree would be made from: where its supervisor
/// stands. (`group_project` ties a group to a *project*, which is a set of
/// tabs rather than a directory, so it has no directory to offer.)
fn poltergeistTaskTreeBase(
    ctx: *anyopaque,
    alloc: Allocator,
    group: []const u8,
    by: poltergeistpkg.Bus.Id,
) ?poltergeistpkg.rpc.TreeBase {
    _ = group;
    const self: *App = @ptrCast(@alignCast(ctx));
    const dir = self.terminalCwd(alloc, by) orelse return null;
    if (dir.len == 0) return null;
    return .{ .dir = dir, .git = poltergeistpkg.worktree.looksLikeRepo(global.io(), dir) };
}

fn poltergeistTaskSetWorktree(ctx: *anyopaque, task: u64, state: poltergeistpkg.Tasks.WorktreeState) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.tasks.setWorktree(task, state);
    self.logTask(.edited, task);
}

/// The tree of a task, for its first seat. Found when it is already there
/// (no thread); made off the app thread when it is not.
fn poltergeistTaskTreePrepare(
    ctx: *anyopaque,
    alloc: Allocator,
    by: poltergeistpkg.Bus.Id,
    task: u64,
) anyerror!poltergeistpkg.worktree.Prepared {
    const self: *App = @ptrCast(@alignCast(ctx));
    const wt = poltergeistpkg.worktree;
    const io = global.io();
    const ledger = self.worktreeLedger() orelse return error.OutOfMemory;
    const t = self.tasks.get(task) orelse return error.NoSuchTask;

    // Made already: the next seat of the squad finds it without a thread.
    if (ledger.taskTree(task)) |i| {
        const e = ledger.entries.items[i];
        if (wt.pathExists(io, e.path)) return .{ .tree = .{ .entry = try e.dupe(alloc), .reused = true } };
    }

    // The repository the task's tree is already in, else where the caller is.
    const dir = if (ledger.taskTree(task)) |i|
        ledger.entries.items[i].repo
    else
        self.terminalCwd(alloc, by) orelse return error.NoDirectory;
    if (!std.fs.path.isAbsolute(dir)) return error.NotAbsolute;
    _ = try poltergeistpkg.workdir.check(alloc, io, dir);

    const now: std.Io.Timestamp = .now(io, .real);
    const taken = try self.worktreeRun(.{ .task = .{
        .dir = dir,
        .group = t.group,
        .task = task,
        .location = self.poltergeist_worktree_location,
        .by = by,
        .now_ms = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms)),
    } }, "");
    defer taken.deinit(self);
    const done = try wt.commit(io, ledger, taken.result().prepared);
    return try done.dupe(alloc);
}

/// What closing or cancelling `ask.task` does to its tree, as the reply.
/// Null when there is no tree. The lease is read (closed) or let go
/// (cancelled) here, on the app thread, because `Leases` is not for threads.
fn poltergeistWorktreeCloseout(
    ctx: *anyopaque,
    alloc: Allocator,
    ask: poltergeistpkg.rpc.CloseoutAsk,
) anyerror!?[]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const ledger = self.worktreeLedger() orelse return null;
    const now_ms: i64 = @intCast(self.poltergeistElapsedMs());

    if (ask.mode == .cancelled) {
        // The task is over: nobody builds for it any more.
        if (try self.leases().releaseTask(alloc, ask.task, now_ms)) |ev| {
            log.info("worktree: lease on task {d} let go ({t}), held {d} ms by {s}", .{ ev.task, ev.why, ev.held_ms, ev.alias });
        }
    }
    if (ledger.taskTree(ask.task) == null) return null;

    const taken = try self.worktreeRun(.{ .closeout = .{ .task = ask.task, .in = .{
        .mode = ask.mode,
        .standing = ask.standing,
        .lease = self.leases().status(ask.task),
        .building = ask.building,
    } } }, ask.preface);
    defer taken.deinit(self);
    return try closeoutText(alloc, ledger, taken);
}

/// The reply a finished close or cancel job comes to; the ledger is brought
/// into line with what its private copy did.
fn closeoutText(
    alloc: Allocator,
    ledger: *poltergeistpkg.worktree.Ledger,
    taken: WorktreeTaken,
) anyerror![]const u8 {
    const wt = poltergeistpkg.worktree;
    const res = taken.result();
    _ = wt.forgetGone(global.io(), ledger, res);
    return switch (res) {
        .closeout => |c| try wt.withPreface(alloc, c.note, taken.preface, c.task, c.mode),
        .refused => |r| try std.fmt.allocPrint(alloc, "{s} Its worktree was not touched: {s}", .{ taken.preface, r.message }),
        else => error.WorktreeFailed,
    };
}

/// The second time round of a parked close or cancel: its reply, or, when
/// the job is somehow not finished, parked again.
fn poltergeistParkedText(ctx: *anyopaque, alloc: Allocator) ?[]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const pending = self.poltergeist_dispatching orelse return null;
    const ledger = self.worktreeLedger() orelse return null;
    for (self.poltergeist_worktree_jobs.items, 0..) |w, i| {
        if (w.held != pending) continue;
        if (w.job.work != .closeout) return null;
        if (!w.job.finished.load(.acquire)) {
            self.poltergeist_parked = true;
            return "";
        }
        _ = self.poltergeist_worktree_jobs.swapRemove(i);
        const taken: WorktreeTaken = .{ .job = w.job, .held = w.held, .preface = w.preface };
        defer taken.deinit(self);
        return closeoutText(alloc, ledger, taken) catch |err| {
            log.warn("worktree: the answer to a close could not be made: {t}", .{err});
            return alloc.dupe(u8, "The task is closed; what became of its worktree could not be told.") catch null;
        };
    }
    return null;
}

/// Terminals whose working directory is in `task`'s tree, other than `skip`.
fn poltergeistWorktreeStanding(
    ctx: *anyopaque,
    alloc: Allocator,
    task: u64,
    skip: []const poltergeistpkg.Bus.Id,
) anyerror![]const poltergeistpkg.Bus.Id {
    const self: *App = @ptrCast(@alignCast(ctx));
    const ledger = if (self.poltergeist_worktrees) |*l| l else return &.{};
    const i = ledger.taskTree(task) orelse return &.{};
    const path = ledger.entries.items[i].path;
    var out: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
    for (self.surfaces.items) |v| {
        const id = v.core().id;
        if (std.mem.indexOfScalar(poltergeistpkg.Bus.Id, skip, id) != null) continue;
        const cwd = self.terminalCwd(alloc, id) orelse continue;
        if (poltergeistpkg.worktree.within(path, cwd)) try out.append(alloc, id);
    }
    return out.items;
}

fn poltergeistWorktreeOpened(ctx: *anyopaque, path: []const u8, id: poltergeistpkg.Bus.Id) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const ledger = self.worktreeLedger() orelse return;
    for (ledger.entries.items) |*e| if (std.mem.eql(u8, e.path, path)) {
        e.terminal = id;
        ledger.save(global.io()) catch |err| log.warn("worktree: could not save the ledger err={}", .{err});
        return;
    };
}

fn poltergeistWorktreeAt(ctx: *anyopaque, alloc: Allocator, cwd: []const u8) ?poltergeistpkg.worktree.Tag {
    const self: *App = @ptrCast(@alignCast(ctx));
    const ledger = if (self.poltergeist_worktrees) |*l| l else return null;
    const tag = ledger.tagAt(cwd) orelse return null;
    return .{
        .name = alloc.dupe(u8, tag.name) catch return null,
        .branch = alloc.dupe(u8, tag.branch) catch return null,
        .path = alloc.dupe(u8, tag.path) catch return null,
    };
}

fn poltergeistWorktreeStatus(
    ctx: *anyopaque,
    alloc: Allocator,
    name: []const u8,
    repo: []const u8,
    task: u64,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const wt = poltergeistpkg.worktree;
    const ledger = self.worktreeLedger() orelse return error.OutOfMemory;
    // No trees at all: nothing to look at, and no reason to start a thread.
    if (ledger.entries.items.len == 0) {
        if (name.len > 0 or task != 0) return error.NoSuchWorktree;
        return try alloc.dupe(u8, "[]");
    }

    const taken = try self.worktreeRun(.{ .status = .{ .name = name, .repo = repo, .task = task } }, "");
    defer taken.deinit(self);
    const rows = switch (taken.result()) {
        .statuses => |s| s,
        .refused => |r| return if (std.mem.eql(u8, r.code, "NoSuchWorktree")) error.NoSuchWorktree else error.Ambiguous,
        else => return error.WorktreeFailed,
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    var w: std.json.Stringify = .{ .writer = &out.writer };
    if (!rows.single) try w.beginArray();
    for (rows.rows) |row| {
        var s = row;
        if (s.entry.kind == .task) if (s.entry.task) |t| {
            if (self.tasks.get(t)) |tk| s.group_now = tk.group;
            s.lease = self.leases().status(t);
        };
        try wt.writeStatus(&w, s);
    }
    if (!rows.single) try w.endArray();
    return out.written();
}

fn poltergeistWorktreeRemove(
    ctx: *anyopaque,
    alloc: Allocator,
    name: []const u8,
    repo: []const u8,
    task: u64,
) anyerror!poltergeistpkg.worktree.Removed {
    const self: *App = @ptrCast(@alignCast(ctx));
    const wt = poltergeistpkg.worktree;
    const ledger = self.worktreeLedger() orelse return error.OutOfMemory;
    const taken = try self.worktreeRun(.{ .remove = .{ .name = name, .repo = repo, .task = task } }, "");
    defer taken.deinit(self);
    const res = taken.result();
    _ = wt.forgetGone(global.io(), ledger, res);
    return switch (res) {
        .removed => |r| switch (r.what) {
            .removed => |x| .{ .removed = .{
                .path = try alloc.dupe(u8, x.path),
                .branch_kept = if (x.branch_kept) |b| try alloc.dupe(u8, b) else null,
            } },
            .forgotten => |p| .{ .forgotten = try alloc.dupe(u8, p) },
            .refused => |f| .{ .refused = .{ .code = try alloc.dupe(u8, f.code), .message = try alloc.dupe(u8, f.message) } },
        },
        .refused => |f| .{ .refused = .{ .code = try alloc.dupe(u8, f.code), .message = try alloc.dupe(u8, f.message) } },
        else => error.WorktreeFailed,
    };
}

fn poltergeistWorktreeTieTask(ctx: *anyopaque, task: u64, id: poltergeistpkg.Bus.Id) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const ledger = if (self.poltergeist_worktrees) |*l| l else return;
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const cwd = self.terminalCwd(fba.allocator(), id) orelse "";
    if (ledger.tieTask(task, id, cwd)) {
        ledger.save(global.io()) catch |err| log.warn("worktree: could not save the ledger err={}", .{err});
    }
}

fn poltergeistWorktreeForTask(
    ctx: *anyopaque,
    alloc: Allocator,
    task: u64,
    owner: poltergeistpkg.Bus.Id,
) ?poltergeistpkg.worktree.Tag {
    const self: *App = @ptrCast(@alignCast(ctx));
    const ledger = if (self.poltergeist_worktrees) |*l| l else return null;
    const cwd = if (owner != 0) self.terminalCwd(alloc, owner) orelse "" else "";
    const i = ledger.forTask(task, cwd) orelse return null;
    const e = ledger.entries.items[i];
    return .{ .name = e.name, .branch = e.branch, .path = e.path };
}

fn poltergeistOpenTerminal(
    ctx: *anyopaque,
    alloc: Allocator,
    cwd: []const u8,
    by: poltergeistpkg.Bus.Id,
    place: poltergeistpkg.rpc.Placement,
) anyerror!poltergeistpkg.rpc.Opened {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.openTerminalAt(alloc, cwd, by, place, null);
}

/// `poltergeistOpenTerminal`, with the tab it goes in named by `beside`
/// rather than by the caller (task 1571). With `beside`, the terminal is a
/// pane split off `beside`, to its right, or nothing: **never a tab**,
/// because a tab is the overflow the parameter exists to prevent.
///
/// `error.WorkerPending` is a request parked to wait for the worker before
/// it (task 1797, Q3): nothing is answered, and the request is dispatched
/// again.
fn openTerminalAt(
    self: *App,
    alloc: Allocator,
    cwd: []const u8,
    by: poltergeistpkg.Bus.Id,
    place: poltergeistpkg.rpc.Placement,
    beside: ?*Surface,
) anyerror!poltergeistpkg.rpc.Opened {
    const surface = beside orelse self.findSurfaceByID(by) orelse return error.UnknownTerminal;

    // Checked here so a directory that is not there is refused rather than
    // quietly ignored. The apprt logs and carries on -- which is right for a
    // config file read at startup and wrong for a request somebody is
    // waiting on an answer to.
    //
    // **And one it can be in** (task 1667): a directory that is there but
    // cannot be entered used to pass, and the shell started in `/` instead.
    var dir_z: [:0]const u8 = "";
    if (cwd.len > 0) dir_z = try poltergeistpkg.workdir.check(alloc, global.io(), cwd);

    // **Settle the split asked for last time, now that its terminal exists.**
    //
    // It could not be settled when it was asked for: an apprt that splits
    // asynchronously had not made the surface yet. It is there now --
    // this call is a later moment, and every one of them is.
    try self.poltergeistSettlePendingWorker(alloc);

    var before: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, void) = .empty;
    defer before.deinit(alloc);
    for (self.surfaces.items) |v| try before.put(alloc, v.core().id, {});

    const rt_app = self.poltergeist_rt_app orelse return error.NoRuntime;

    // **An agent is opening this terminal** (#989), so it is marked as one
    // whenever it appears: now, if the runtime makes it inside the calls
    // below (its `init` claims this), or later, if it makes it after this
    // returns. Taken back below when the terminal is found here.
    self.poltergeist_agent_open = .{
        .deadline_ms = self.poltergeistElapsedMs() + poltergeistpkg.PersonaStore.pending_launch_ms,
        .by = by,
    };
    // A terminal that was never made must not leave the mark waiting for the
    // next one somebody else opens.
    errdefer self.poltergeist_agent_open = null;

    // **Where it goes, decided here and nowhere else.**
    //
    // The caller says it wants a terminal; it never says where. A position in
    // the request would be a rule every agent recomputes, and six agents
    // recomputing one rule get six answers whose wrong ones read exactly
    // like the right ones. The two apprts answer factual questions -- how
    // full is this tab, which tab is this in -- and hold none of the rule.
    const placed: poltergeistpkg.rpc.Placed = placed: {
        // ⚠️ **`tab` is a guarantee, not a preference.** It exists so a
        // caller can say "not in with the others", and a request that quietly
        // became a split would leave it no way to tell and no other way to
        // ask. So it never reaches the placement at all.
        if (place == .tab) break :placed .{ .tab = .asked };

        // `beside` names the tab, and `here` the caller's: a pane split off
        // that terminal, to its right (task 1797 leaves both as they were
        // meant -- "a pane of its own here", for what is not a worker of
        // the stack). `auto` and `stack` are the supervisor's stack.
        const first: WorkerSpot = if (beside) |b|
            .{ .split = .{ .target = b, .direction = .right } }
        else if (place == .here)
            .{ .split = .{ .target = surface, .direction = .right } }
        else spot: {
            const now_ms = self.poltergeistElapsedMs();
            const deadline = self.takeWorkerWait() orelse now_ms +| worker_wait_ms;
            const spot = try self.poltergeistPlaceWorker(alloc, rt_app, surface, by, now_ms >= deadline);
            if (spot != .wait) break :spot spot;
            // **Parked, not refused and not dropped** (Q3): dispatched again
            // every `worker_wait_look_ms` until the worker before it is
            // there, and placed without it at the deadline.
            if (try self.parkWorkerWait(deadline)) return error.WorkerPending;
            break :spot try self.poltergeistPlaceWorker(alloc, rt_app, surface, by, true);
        };

        // Asked before the split or the stack: the tab its terminal will
        // appear in, and the only tab attribution may find it in (task 881).
        var made_in: ?u64 = null;
        const how: enum { split, stack } = spot: switch (first) {
            .tab => |why| {
                // **`here` was asked for and did not happen, and that is worth
                // a second line.** For `auto` a tab is one of the normal
                // answers; for `here` it is the caller not getting what it
                // named. A fallback nobody distinguished would read as `here`
                // having worked.
                if (place == .here) log.info(
                    "poltergeist: `here` was asked for and could not be given; " ++
                        "the terminal went into a tab -- see the line above for why",
                    .{},
                );
                break :placed .{ .tab = why };
            },

            // Only once the worker before it has been given up on, which
            // clears it: said, and placed beside the supervisor.
            .wait => {
                log.warn("poltergeist: the placement still waited after its wait ran out; splitting beside the supervisor", .{});
                continue :spot .{ .split = .{ .target = surface, .direction = .right } };
            },

            .stack => |target| {
                // **Not into a pane the user keeps for their own commands**
                // (task 1699): a stack would cover it.
                if (self.poltergeist.workersOf(target.id) == .refused) {
                    log.info(
                        "poltergeist: the worker pane a worker would be stacked onto ({x}) is kept for " ++
                            "the user's commands; the terminal goes beside the supervisor",
                        .{target.id},
                    );
                    continue :spot .{ .split = .{ .target = surface, .direction = .right } };
                }
                made_in = poltergeistTabOf(target);
                var result: apprt.action.PoltergeistNewStacked.Result = .unsupported;
                _ = rt_app.performAction(
                    .{ .surface = target },
                    .poltergeist_new_stacked,
                    .{ .working_directory = dir_z, .result = &result },
                ) catch {};
                if (result == .will_stack) break :spot .stack;
                // An apprt with no stacks (GTK), or one that could not take it
                // now: a split, as before stacks, and said.
                log.info(
                    "poltergeist: the apprt would not stack a worker onto {x}; splitting beside the supervisor",
                    .{target.id},
                );
                continue :spot .{ .split = .{ .target = surface, .direction = .right } };
            },

            .split => |w| {
                // **Not out of a pane the user keeps for their own commands**
                // (task 1699): a split takes half of its room. `beside` never
                // gets here for one -- the rpc refused it by name.
                if (beside == null and self.poltergeist.workersOf(w.target.id) == .refused) {
                    log.info(
                        "poltergeist: the pane a worker would be split out of ({x}) is kept for the user's commands; " ++
                            "the terminal goes into a tab",
                        .{w.target.id},
                    );
                    break :placed .{ .tab = .workers_refused };
                }
                made_in = poltergeistTabOf(w.target);
                var result: apprt.action.NewSplit.Result = .unsupported;
                _ = rt_app.performAction(
                    .{ .surface = w.target },
                    .new_split,
                    .{
                        .direction = w.direction,
                        .working_directory = dir_z,
                        .result = &result,
                    },
                ) catch {
                    if (beside != null) return error.NoRoomBeside;
                    break :placed .{ .tab = .split_failed };
                };
                if (result == .will_split) break :spot .split;
                // `beside` is a pane or nothing: the fallback below is the tab
                // it exists to prevent.
                if (beside != null) return error.NoRoomBeside;
                // ⚠️ **A live path, not a defensive one.** GTK cannot start a
                // split in a named directory, so it refuses rather than opening
                // one in the wrong place; every worker opened on Linux comes
                // through here.
                log.info(
                    "poltergeist: falling back to a tab -- this apprt would not split into {s}",
                    .{if (dir_z.len > 0) dir_z else "the inherited directory"},
                );
                break :placed .{ .tab = .split_refused };
            },
        };

        // **Attributed now if its terminal is already here, remembered as a
        // question if not.** `will_split` and `will_stack` are the apprt
        // saying it *will*: the Windows host queues the work and returns
        // before it has happened, while macOS makes it synchronously -- the
        // notification it posts is delivered before `performAction` returns.
        // Both are handled by `PendingWorker.afterSplit`.
        const now = try self.poltergeistSeen(alloc);
        defer alloc.free(now);
        switch (try PendingWorker.afterSplit(self.alloc, by, self.poltergeistElapsedMs(), made_in, &before, now, &.{})) {
            .appeared => |id| {
                self.poltergeistRecordWorker(by, id);
                self.claimLaunchLimits(by, id);
            },
            .pending => |p| {
                if (self.poltergeist_pending_worker) |*old_pending| old_pending.deinit(self.alloc);
                self.poltergeist_pending_worker = p;
                // Looked for on a timer, not only at the next placement
                // (task 1848): the last worker of a run has no next one, and
                // was never recorded -- no `worker_of`, no `by_supervisor`.
                self.noticeRetryIn(worker_wait_look_ms);
            },
        }
        break :placed switch (how) {
            .split => .split,
            .stack => .stack,
        };
    };

    if (opensATab(placed)) {
        var answer: apprt.action.NewTab.Result = .unanswered;
        // An agent asked for it: in the background (task 1823).
        const performed = rt_app.performAction(
            .{ .surface = surface },
            .new_tab,
            .{ .working_directory = dir_z, .result = &answer, .by = .core },
        ) catch false;
        try tabWasAsked(performed, answer);
    }

    for (self.surfaces.items) |v| {
        const id = v.core().id;
        if (before.contains(id)) continue;
        if (self.isChatSurface(id)) continue;
        // ⚠️ **Nothing is recorded here.** This loop only sees a surface that
        // already exists, and a split's surface never does yet -- that is the
        // defect this replaced. The worker is attributed on the next call,
        // through `poltergeist_pending_worker`.
        //
        // Who opened it is, though (#989): it is here, it is new, and the
        // agent asked for it. Its own `init` may already have claimed the
        // mark; either way the claim waiting for a later terminal is spent.
        self.poltergeist_agent_open = null;
        self.markAgentOpened(id, by);
        return .{ .id = id, .placed = placed };
    }
    return .{ .id = null, .placed = placed };
}

/// Whether a terminal placed so is still to be asked of the apprt as a tab.
/// A split and a stack were asked for already, of the pane they go in.
///
/// ⚠️ **A switch, not `!= .split`** (task 1861). That test was written when
/// a split was the only other answer; `stack` came with task 1797 and fell
/// on the tab side of it, so every stacked worker was made twice -- in the
/// stack, and as an empty tab beside it (Windows, 2026-10-20). Written out,
/// the next kind of placement is a compile error here until somebody says
/// which side it is on.
fn opensATab(placed: poltergeistpkg.rpc.Placed) bool {
    return switch (placed) {
        .tab => true,
        .split, .stack => false,
        // Nothing is opened for a terminal that was there already.
        .reused => false,
    };
}

test "poltergeist: 1861 a stacked worker is not opened a second time as a tab" {
    try std.testing.expect(!opensATab(.stack));
    try std.testing.expect(!opensATab(.split));
    try std.testing.expect(!opensATab(.{ .reused = .free_worker }));
    try std.testing.expect(opensATab(.{ .tab = .asked }));
    try std.testing.expect(opensATab(.{ .tab = .split_refused }));
}

/// What the apprt's answer to "open a tab" means to whoever asked for a
/// terminal. `performed` is that answer: false when it asked nobody for a
/// tab -- and then there is none and none is coming.
///
/// **It used to be thrown away**, and a request that opened nothing was
/// answered `{"ok":true,"placed":"tab"}` with no id. That is also what a
/// tab the runtime has not made *yet* looks like, so the caller waited for
/// a terminal that was never asked for (a supervisor whose terminal the
/// control room had borrowed, six times in a row, 2026-10-13).
///
/// `answer` is what the apprt wrote when it can say more than that
/// (`apprt.action.NewTab.Result`): it "performs" a request it turned down by
/// telling the person, and only the cell says so.
fn tabWasAsked(performed: bool, answer: apprt.action.NewTab.Result) error{OpenFailed}!void {
    if (!performed or answer == .refused) {
        log.warn(
            "poltergeist: the apprt opened no tab for the terminal that was asked for (performed={}, answer={s})",
            .{ performed, @tagName(answer) },
        );
        return error.OpenFailed;
    }
}

test "poltergeist: a tab the apprt did not open is a failure, not a terminal that is on its way" {
    // An apprt that says nothing more is taken at its word, as before...
    try tabWasAsked(true, .unanswered);
    try tabWasAsked(true, .will_open);
    try std.testing.expectError(error.OpenFailed, tabWasAsked(false, .unanswered));
    // ...and one that dealt with the request by turning it down has not
    // opened anything, whatever it returned.
    try std.testing.expectError(error.OpenFailed, tabWasAsked(true, .refused));
    try std.testing.expectError(error.OpenFailed, tabWasAsked(false, .refused));
}

fn poltergeistOpenTerminals(
    ctx: *anyopaque,
    alloc: Allocator,
) anyerror![]const poltergeistpkg.rpc.Place {
    const self: *App = @ptrCast(@alignCast(ctx));

    var out: std.ArrayListUnmanaged(poltergeistpkg.rpc.Place) = .empty;
    errdefer out.deinit(alloc);

    for (self.surfaces.items) |v| {
        const surface: *Surface = v.core();
        if (self.isChatSurface(surface.id)) continue;

        const footing = self.footingOf(alloc, surface.id);

        // **The question only the apprt can answer**, the same way
        // `poltergeist_tab_panes` is. Zero comes back when it did not answer
        // at all -- an on-screen surface is in some window and some tab, so
        // no apprt writes zero -- and zero becomes null rather than a group
        // of its own. A terminal nobody grouped must not be reported as
        // being somewhere.
        //
        // The tab's place and title come with it (task 1571). The title is
        // copied out of the buffer: the strings in a `Place` outlive this.
        var title_buf: [512]u8 = undefined;
        const g = polterGrouping(surface, &title_buf);

        try out.append(alloc, .{
            .id = poltergeistpkg.Bus.idOf(surface),
            .cwd = footing.cwd,
            .title = footing.title,
            .window = g.window,
            .tab = g.tab,
            .tab_index = g.tab_index,
            .tab_title = if (g.tab_title) |t| try alloc.dupe(u8, t) else null,
        });
    }

    return out.toOwnedSlice(alloc);
}

/// The supervisor reading its own box, which is not the scheduled
/// hand-over and so is never held back for it. Consuming, like the
/// hand-over: what is read here will not arrive again on the interval.
fn poltergeistDrainNotices(
    ctx: *anyopaque,
    alloc: Allocator,
    to: poltergeistpkg.Bus.Id,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    var buf: [255]u8 = undefined;
    const line = self.poltergeist.drain(
        to,
        self.poltergeistElapsedMs(),
        &buf,
        self.chat.peers(),
    ) orelse return "";
    return alloc.dupe(u8, line);
}

fn chatCreate(ctx: *anyopaque, group: []const u8, by: poltergeistpkg.Bus.Id) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));

    var buf: [2048]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buf);
    const footing = self.footingOf(fixed.allocator(), by);
    var held: poltergeistpkg.Bus.Agent = undefined;
    try createGroup(
        &self.chat,
        if (self.session_log) |*l| l else null,
        group,
        by,
        footing,
        self.poltergeistWallMs(),
        self.memberOf(by, footing, &held),
    );

    // Written down now rather than when something is first said in it: a
    // group made at midnight and never spoken in would otherwise leave no
    // directory at all, and would not be in the list in the morning.
    if (self.group_log) |*l| l.note(group, "");

    // Made by a supervisor: it is this group's, and what it is is written
    // down for whoever starts the next one.
    self.noteSupervisor(by, .write);
    self.takeUpGroups(by);

    self.saveSession();
}

/// Bring every tab's Poltergeist mark in line with the state behind it.
///
/// Cheap: each surface compares the mark it last set and does nothing when
/// it has not moved, so this can be called whenever anything happens.
pub fn refreshPoltergeistTabs(self: *App) void {
    // Whatever moved a tab's mark moved the control room too.
    self.controlRoomTouch();
    for (self.surfaces.items) |rt_surface| {
        rt_surface.core().updatePoltergeistTabMark();
    }
}

/// The ids of the terminals that are open right now. Borrowed from
/// `alloc`.
///
/// The other half of every "is anybody in this group" question. A group's
/// membership list says who was put in it; this says which of those the
/// app still has, and `Chat.isActive` is where the two meet. It lives here
/// rather than in `poltergeist/Chat.zig` because that file is the model
/// and does not know what a window is.
fn liveTerminals(
    self: *const App,
    alloc: Allocator,
) Allocator.Error![]const poltergeistpkg.Bus.Id {
    const out = try alloc.alloc(
        poltergeistpkg.Bus.Id,
        self.surfaces.items.len,
    );
    for (self.surfaces.items, 0..) |rt_surface, i| out[i] = rt_surface.core().id;
    return out;
}

/// Whether a group has any terminal in it that is still open.
///
/// Out of memory answers yes. The only caller refuses on yes, and being
/// unable to work out whether a destruction would reach anybody is not a
/// reason to go ahead with it.
fn chatGroupActive(self: *App, group: []const u8) bool {
    const live = self.liveTerminals(self.alloc) catch return true;
    defer self.alloc.free(live);
    return self.chat.isActive(group, live);
}

fn chatDestroy(ctx: *anyopaque, group: []const u8) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));

    // **A group with terminals working in it is not deleted.**
    //
    // The test is whether removing it would reach anybody. An empty group
    // is a name and a file and nobody to disturb, so letting it go costs
    // nothing. A group with terminals in it is a conversation they are
    // in: destroying it takes them out of it without telling them, and
    // the panel their tasks are on goes with it. Take the members out
    // first -- `group_remove` -- and then it is an empty group like any
    // other.
    //
    // Asked here rather than in the chat view, so that it holds for an
    // agent calling `group_destroy` as well as for somebody pressing `d`.
    // The view has no way to know this and does not need one; it shows
    // whatever the host says.
    //
    // Checked before existence would be, so ask that first: "no group by
    // that name" is the more useful answer for a name that is not there.
    if (!self.chat.exists(group)) return error.NoSuchGroup;
    if (self.chatGroupActive(group)) return error.GroupActive;

    try self.chat.destroy(group);

    // The panel goes with the group. A task belongs to a group, so tasks
    // outliving it would be work in a place nobody can look at -- and the
    // conversations view draws the panel per group, so there would be
    // nowhere to draw them.
    self.tasks.forgetGroup(group);

    // **Off the list, not off the disk.** Every word said in this group is
    // still in `<state>/chat/<group>/` and nothing here goes near it; all
    // that changes is that the group stops being offered in the list. The
    // record red line in `dev-docs/poltergeist/gaps.md` is what this is: the
    // record is never what gets deleted.
    if (self.group_log) |*l| l.forget(group);

    self.saveSession();
}

/// Give a group a new name, on disk and in memory. See `GroupRename.zig`
/// for how the disk half is done and `group_stores.zig` for what there is to
/// do; this is the memory half and the order they happen in.
///
/// **Disk first.** It is the half that can be refused for reasons outside
/// the program, and the one that is checked before anything is replaced; a
/// refusal leaves the disk and memory exactly as they were. Memory comes
/// after, and what is in it cannot fail in any way that matters: a restart
/// reads the disk, which already says the new name.
fn chatRename(
    ctx: *anyopaque,
    group: []const u8,
    to: []const u8,
    by: poltergeistpkg.Bus.Id,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const stores = poltergeistpkg.group_stores;

    if (!self.chat.exists(group)) return error.NoSuchGroup;
    if (!poltergeistpkg.Chat.isValidName(to)) return error.BadName;
    if (std.mem.eql(u8, group, to)) return;
    if (self.chat.exists(to)) return error.GroupExists;

    if (self.poltergeist_state_dir) |dir| {
        _ = poltergeistpkg.GroupRename.rename(.{
            .alloc = self.alloc,
            .io = global.io(),
            .state_dir = dir,
        }, group, to, .{ .ctx = self, .close_handles = closeStoreHandles }) catch |err| {
            // The swap may have closed the handles before it stopped.
            self.reopenStoreHandles();
            log.warn("poltergeist: group rename {s} -> {s} refused err={}", .{ group, to, err });

            // **Begun and not finishable now.** The disk is part way (or its
            // intent could not be cleared), and the next start will carry the
            // rename through. Until then nothing may be written into the old
            // place: a write by the old name would make a directory there
            // for the restart to trip over. So the records are closed, and
            // the person and the supervisor are told why.
            if (err == error.Deferred) self.closeRecordsAfterDeferredRename(dir);
            return poltergeistpkg.GroupRename.refusal(err);
        };
    }

    // Every table in memory, by the list. No `else`.
    inline for (comptime std.enums.values(stores.Table)) |table| switch (table) {
        .chat_groups => try self.chat.rename(group, to),
        .task_group_field => try self.tasks.renameGroup(group, to),
        .stats_last => if (self.stats_log) |*l| try l.renameGroup(group, to),
        .mention_retries => try self.mention_retries.renameGroup(group, to),
        .control_asks => try self.control_asks.renameGroup(self.alloc, group, to),
        .resource_names => try self.resource_names.renameGroup(self.alloc, group, to),
        .reclaim_groups => if (self.reclaim) |*r| try r.renameGroup(group, to),
        .overall_rows => if (self.resource_overall) |o| o.renameGroup(group, to),
        .alarms => {
            try self.alarmsHeld().renameGroup(group, to);
            self.saveAlarms();
        },
    };

    self.reopenStoreHandles();

    // Say that the group is listed under its new name even if its
    // directory was never made.
    if (self.group_log) |*l| l.note(to, self.chat.briefOf(to) catch "");

    // Said in the group, so the members find out the next time they read
    // it, and so the record says when and from what. From the caller when
    // it is in the group (its title is then the author), else the person.
    const from: poltergeistpkg.Bus.Id = if (self.chat.floorOf(to, by)) |_| by else |_| poltergeistpkg.Chat.user_id;
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "group renamed: {s} -> {s}. Same group: members, tasks and numbers, and everything said so far are unchanged.",
        .{ group, to },
    ) catch "group renamed";
    const at: u64 = @intCast(self.poltergeistWallMs());
    if (self.chat.post(to, from, text, at)) |posted| {
        self.logChat(to, posted.seq, from, at, false, text, 0);
        self.tellTerminalsAboutMessages();
    } else |err| {
        log.warn("poltergeist: could not record a group rename in the group err={}", .{err});
    }

    self.saveSession();
    // A group that has a project: the project is to bear the new name,
    // which the snapshot now orders (`Projects`, `rename`).
    self.controlRoomTouch();
}

/// `GroupRename.Hooks.close_handles`: every handle into the files a rename
/// replaces. Written as a `switch` over the list so that a handle added to
/// it without being closed here does not compile.
fn closeStoreHandles(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    inline for (comptime std.enums.values(poltergeistpkg.group_stores.Handle)) |h| switch (h) {
        .chat_log_stream, .chat_log_tree => if (self.chat_log) |*l| l.closeHandles(),
        .task_log_tree => if (self.task_log) |*l| l.closeHandles(),
        .stats_log_tree => if (self.stats_log) |*l| l.closeHandles(),
        .session_log_tree => if (self.session_log) |*l| l.closeHandles(),
    };
}

fn reopenStoreHandles(self: *App) void {
    if (self.chat_log) |*l| l.reopenHandles();
}

// -- the panel ---------------------------------------------------------------
//
// All of these run on the app thread, the same as the chat's half of the
// host: `poltergeistRequest` dispatches there.

/// Wall-clock milliseconds, for the record on disk.
///
/// The panel model has no clock -- time arrives as a parameter everywhere
/// in `poltergeist/` -- and the record is filed by local day, so this is
/// where the two meet.
pub fn taskWallMs(self: *App) i64 {
    return self.poltergeistWallMs();
}

/// Write one thing that happened, if there is anywhere to write it.
fn logTask(self: *App, op: poltergeistpkg.TaskLog.Op, id: u64) void {
    // A task handed to somebody is a fresh piece of work, whether it is a
    // new owner or the same one being given it again -- so the reminder
    // this task has already had does not count against the new stretch.
    // Every other event leaves the mark alone: a worker that reported and
    // carried on does not need telling twice.
    if (op == .assigned) _ = self.poltergeist_nudged.remove(id);

    const l = if (self.task_log) |*v| v else return;
    const task = self.tasks.get(id) orelse return;
    l.append(self.taskWallMs(), op, task);
}

fn taskCreateSquad(
    ctx: *anyopaque,
    group: []const u8,
    title: []const u8,
    kind: poltergeistpkg.Tasks.Kind,
    squad_key: []const u8,
    seats: []const poltergeistpkg.rpc.PlannedSeat,
) anyerror!u64 {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (!self.chat.exists(group)) return error.NoSuchGroup;

    const id = try self.tasks.create(group, title, kind);
    errdefer self.tasks.cancel(id) catch {};
    try self.tasks.setSquad(id, squad_key);
    for (seats) |seat| try self.tasks.addSlot(id, seat.alias, seat.role);
    // After the seats, so the `created` line carries them (every line
    // carries the whole task).
    self.logTask(.created, id);
    return id;
}

fn taskJoin(ctx: *anyopaque, task: u64, alias: []const u8, id: poltergeistpkg.Bus.Id, lead: bool) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.tasks.join(task, alias, "", id, "", self.taskWallMs(), lead);
    self.logSeat(.joined, task, alias, id);
    // An agent already running has said its session long ago, and will only
    // repeat it: `noteSession` calls that no news and never gets here (task
    // 2470). So what the bus already knows is taken now.
    const agent = self.poltergeist.agentOf(id);
    if (agent.cli.get()) |cli| {
        if (agent.session_id.get()) |sid| self.backfillMemberSession(id, cli, sid);
    }
    self.controlRoomTouch();
}

fn taskLeave(ctx: *anyopaque, task: u64, alias: []const u8) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const t = self.tasks.get(task) orelse return error.NoSuchTask;
    var id: poltergeistpkg.Bus.Id = 0;
    for (t.members) |m| {
        if (std.mem.eql(u8, m.alias, alias)) id = m.id;
    }
    try self.tasks.leave(task, alias, self.taskWallMs());
    self.logSeat(.left, task, alias, id);
    self.controlRoomTouch();
}

fn poltergeistSquadCatalog(ctx: *anyopaque, alloc: Allocator) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.squadCatalogJson(alloc);
}

fn poltergeistSquadGet(ctx: *anyopaque, key: []const u8) ?poltergeistpkg.squad.Squad {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.ensureSquads();
    return self.squads.set.find(key);
}

fn poltergeistSquadPut(ctx: *anyopaque, json: []const u8, who: poltergeistpkg.Bus.Authority) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.putSquad(json, who);
}

fn poltergeistSquadDelete(ctx: *anyopaque, key: []const u8, who: poltergeistpkg.Bus.Authority) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.deleteSquad(key, who);
}

fn poltergeistSquadRefusal(ctx: *anyopaque) ?[]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.squads.last_refusal;
}

/// What a seat would start as, for a plan: the CLI and model once the
/// squad's override is over the role. Null when the role is gone or the CLI
/// cannot be worked out (the plan then says nothing of it, rather than a
/// guess).
fn poltergeistSquadSummary(
    ctx: *anyopaque,
    alloc: Allocator,
    by: poltergeistpkg.Bus.Id,
    role: []const u8,
    over: poltergeistpkg.squad.Override,
) ?poltergeistpkg.rpc.SeatSummary {
    const self: *App = @ptrCast(@alignCast(ctx));
    const choice = self.resolveLaunchSeat(alloc, role, "", by, self.ownClis(), over) catch return null;
    const r = choice.resolved orelse return null;
    return .{ .cli = choice.cli, .model = r.choice.model };
}

fn poltergeistRoleIsSupervisor(ctx: *anyopaque, key: []const u8) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.ensurePersonas();
    if (std.mem.eql(u8, key, poltergeistpkg.persona.supervisor_key)) return true;
    const p = self.personas.set.find(key) orelse return false;
    return p.polter.supervisor;
}

/// Why a line typed into `id` now would not be taken, by the name of the
/// error `Surface.mayTypeAs` gives: the answer `task_cancel` of a squad
/// asks of every seat before it types into any of them.
/// Whether closing `id` would lose a half-typed line (`draftFor(.agent)`,
/// which errs towards "there is one"). A terminal that is not found has
/// nothing to lose.
fn poltergeistHasDraft(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return false;
    return surface.draftFor(.agent);
}

fn poltergeistTypeBlocker(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) ?[]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return "NoSuchTerminal";
    surface.mayTypeAs(.agent) catch |err| return @errorName(err);
    return null;
}

fn taskCreate(
    ctx: *anyopaque,
    group: []const u8,
    title: []const u8,
    kind: poltergeistpkg.Tasks.Kind,
) anyerror!u64 {
    const self: *App = @ptrCast(@alignCast(ctx));

    // A task in a group nobody made would be work in a place with no
    // members and no panel to draw it on.
    if (!self.chat.exists(group)) return error.NoSuchGroup;

    const id = try self.tasks.create(group, title, kind);
    self.logTask(.created, id);
    return id;
}

/// Correct a task already on the panel.
///
/// **Recorded before it is answered**, like every other change here: the
/// panel's value is that it is a written record, and a correction nobody can
/// see afterwards would take that away from exactly the tasks most worth
/// checking. `null` means "leave this one alone", so a caller changing only
/// the kind does not have to restate a title it might get wrong.
fn taskEdit(
    ctx: *anyopaque,
    task: u64,
    title: ?[]const u8,
    kind: ?poltergeistpkg.Tasks.Kind,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (title) |t| try self.tasks.setTitle(task, t);
    if (kind) |k| try self.tasks.setKind(task, k);
    self.logTask(.edited, task);
}

fn taskAssign(ctx: *anyopaque, task: u64, id: poltergeistpkg.Bus.Id) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.tasks.assign(task, id);
    self.logTask(.assigned, task);
}

fn taskClose(ctx: *anyopaque, task: u64) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.tasks.close(task);
    self.logTask(.closed, task);
}

/// Who has a task and what it is called.
///
/// Asked by `rpc.dispatch` just before it types a cancellation into that
/// terminal. **The ordering -- tell the worker, then take the task off its
/// list -- lives there rather than here**, because there is where it can be
/// tested: this file has no tests, and a rule that only exists in a comment
/// in an untested file is a rule until somebody tidies it.
fn taskOwner(ctx: *anyopaque, task: u64) anyerror!poltergeistpkg.rpc.TaskOwner {
    const self: *App = @ptrCast(@alignCast(ctx));
    const t = self.tasks.get(task) orelse return error.NoSuchTask;
    return .{ .owner = t.owner, .title = t.title, .open = t.state == .open, .group = t.group, .worktree = t.worktree };
}

/// Mark a task cancelled. The worker has already been told; see above.
fn taskCancel(ctx: *anyopaque, task: u64) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.tasks.cancel(task);
    self.logTask(.cancelled, task);
}

fn taskProgress(
    ctx: *anyopaque,
    task: u64,
    by: poltergeistpkg.Bus.Id,
    progress: []const u8,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));

    const value = std.meta.stringToEnum(
        poltergeistpkg.Tasks.Progress,
        progress,
    ) orelse return error.BadProgress;

    try self.tasks.setProgress(task, by, value);
    self.logTask(.progressed, task);
}

// ------------------------------------------------- alarms and quiet (2148)

/// The alarms, read from the state directory the first time.
fn alarmsHeld(self: *App) *poltergeistpkg.Alarms {
    if (self.alarms == null) {
        self.alarms = .init(self.alloc);
        self.alarms.?.started_ms = self.poltergeistElapsedMs();
        if (self.alarmsPath()) |path| {
            defer self.alloc.free(path);
            if (std.Io.Dir.cwd().readFileAlloc(global.io(), path, self.alloc, .limited(256 * 1024))) |bytes| {
                defer self.alloc.free(bytes);
                if (!self.alarms.?.load(bytes)) log.warn("alarms: {s} will not parse; starting with none", .{path});
            } else |_| {}
        }
    }
    return &self.alarms.?;
}

fn alarmsPath(self: *App) ?[]const u8 {
    const dir = self.poltergeist_state_dir orelse return null;
    return std.fs.path.join(self.alloc, &.{ dir, "alarms.json" }) catch null;
}

/// Written whole and atomically, owner-only, as `Session.write` does; a
/// failure is logged and the alarms go on in memory.
fn saveAlarms(self: *App) void {
    const al = &(self.alarms orelse return);
    const path = self.alarmsPath() orelse return;
    defer self.alloc.free(path);
    var buf: std.Io.Writer.Allocating = .init(self.alloc);
    defer buf.deinit();
    al.render(&buf.writer) catch return;
    const io = global.io();
    const dir = std.fs.path.dirname(path) orelse return;
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch |err| {
        log.warn("alarms: could not open {s} err={}", .{ dir, err });
        return;
    };
    defer d.close(io);
    var atomic = d.createFileAtomic(io, std.fs.path.basename(path), .{
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0) .fromMode(0o600) else .default_file,
        .replace = true,
    }) catch |err| {
        log.warn("alarms: could not write err={}", .{err});
        return;
    };
    defer atomic.deinit(io);
    atomic.file.writeStreamingAll(io, buf.written()) catch |err| {
        log.warn("alarms: could not write err={}", .{err});
        return;
    };
    atomic.replace(io) catch |err| log.warn("alarms: could not commit err={}", .{err});
}

/// Everything `Alarms` needs about one group, read once: who made it, who
/// is in it, which of them mind it, what is on its panel, and how long the
/// supervisor's terminal has been quiet. Null when there is no such group.
///
/// **The supervisor is worked out from this, by `Alarms.supervisor`, which
/// is the rule the whole product uses** (`ControlRoom.stewardAmong`).
/// Round 1 read `Chat.created_by` alone, and that is a different question
/// with a different answer: a group the person made from the control room
/// has no `created_by` that is a supervisor at all, a group whose
/// supervisor was replaced has a `created_by` that is not one any more, and
/// after a restart the creating terminal is gone while the group and its
/// alarms are not -- which is the case alarms are kept by group *for*.
///
/// **This writes `heard`** (task 2411), through `Alarms.observeGroup`: a
/// minding supervisor whose agent is here is observed at `now`, and one
/// whose agent is not here is forgotten. Not a read.
fn quietIn(
    self: *App,
    arena: Allocator,
    group: []const u8,
    now: u64,
    wall: i64,
) ?poltergeistpkg.Alarms.Quiet {
    const al = self.alarmsHeld();
    // Writes `heard` (task 2411): a minding supervisor whose agent is here
    // starts its quiet at the moment it is first seen here, and one whose
    // agent is not here is forgotten, so its quiet starts again on arrival.
    // Those of the members that mind the group (`ControlRoom.minds`) are
    // worked out in `Alarms.observeGroup`: a supervisor whose agent has left
    // holds a terminal nobody is listening in.
    const found = al.observeGroup(arena, &self.poltergeist, &self.chat, group, now, .{
        .ctx = self,
        .here = presenceIn,
    }) orelse return null;

    var q: poltergeistpkg.Alarms.Quiet = .{
        .created_by = self.chat.createdBy(group) catch poltergeistpkg.Chat.user_id,
        .members = found.members,
        .minding = found.minding,
        .unfinished = self.unfinishedIn(group),
        // Filled in below, from whichever terminal the rule picks: it is
        // the chosen one's agent and quiet that decide anything.
        .agent_here = false,
        .alarm_pending = al.pendingIn(group, wall),
        .since_heard_ms = 0,
        .after_ms = self.poltergeist_silence_remind_ms,
    };
    const sup = poltergeistpkg.Alarms.supervisor(q);
    q.agent_here = if (sup) |s| self.agentPresent(s) else false;
    q.since_heard_ms = if (sup) |s| al.quietOf(s, now) else 0;
    return q;
}

/// The supervisor of `group` now, if it has one, by that same rule.
fn groupSupervisor(self: *App, group: []const u8) ?poltergeistpkg.Bus.Id {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const q = self.quietIn(arena.allocator(), group, self.poltergeistElapsedMs(), self.poltergeistWallMs()) orelse return null;
    return poltergeistpkg.Alarms.supervisor(q);
}

/// The local offset, for saying an alarm's moment as a time of day.
fn alarmOffsetS(self: *App) i64 {
    return @divFloor(poltergeistpkg.daylog.localOffsetMs(self.poltergeistWallMs()), std.time.ms_per_s);
}

/// `group`'s supervisor's own line in its group: no mention, so it is
/// delivered to nobody (task 2148: the record says when it meant to look).
fn alarmTrace(self: *App, ev: poltergeistpkg.Alarms.Event, a: poltergeistpkg.Alarms.Alarm, by: poltergeistpkg.Bus.Id) void {
    var buf: [512]u8 = undefined;
    const line = poltergeistpkg.Alarms.traceLine(&buf, ev, a, self.alarmOffsetS());
    if (line.len == 0) return;
    _ = self.chat.post(a.group, by, line, self.poltergeistWallMsU()) catch |err|
        log.warn("alarms: could not say it in {s} err={}", .{ a.group, err });
}

fn poltergeistWallMsU(self: *App) u64 {
    return @intCast(@max(self.poltergeistWallMs(), 0));
}

fn alarmOp(
    ctx: *anyopaque,
    alloc: Allocator,
    by: poltergeistpkg.Bus.Id,
    op: poltergeistpkg.rpc.AlarmOp,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const group = switch (op) {
        inline else => |o| o.group,
    };
    if (!self.chat.exists(group)) return error.NoSuchGroup;
    if (self.groupSupervisor(group) != by) return error.NotTheGroupsSupervisor;
    const al = self.alarmsHeld();
    const now = self.poltergeistWallMs();
    const offset = self.alarmOffsetS();
    switch (op) {
        .set => |o| {
            const a = try al.set(o.group, o.minutes, o.note, now);
            self.saveAlarms();
            self.alarmTrace(.set, a, by);
            self.considerSupervisorClocks();
            var line: [256]u8 = undefined;
            const due = poltergeistpkg.Alarms.traceLine(&line, .set, a, offset);
            return std.fmt.allocPrint(alloc, "Alarm {d} set. {s}", .{ a.id, due });
        },
        .list => {
            var out: std.Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            var n: usize = 0;
            for (al.list.items) |a| {
                if (!std.mem.eql(u8, a.group, group)) continue;
                var line: [256]u8 = undefined;
                const what = poltergeistpkg.Alarms.traceLine(&line, .set, a, offset);
                try out.writer.print("{s}{s}{s}", .{ if (n == 0) "" else "\n", what, if (a.due_ms <= now) " (due; waiting for an agent in the supervisor's terminal)" else "" });
                n += 1;
            }
            if (n == 0) try out.writer.writeAll("No alarm is set for this group.");
            return out.toOwnedSlice();
        },
        .cancel => |o| {
            const a = al.cancel(o.group, o.id) orelse return error.NoSuchAlarm;
            defer al.release(a);
            self.saveAlarms();
            self.alarmTrace(.cancelled, a, by);
            self.considerSupervisorClocks();
            return std.fmt.allocPrint(alloc, "Alarm {d} cancelled.", .{a.id});
        },
    }
}

/// Polter typed into terminal `id` (`Surface.typePoltergeistNotice`), or an
/// agent in it called a Polter tool (`poltergeistRequest`): its supervisor
/// is alive and its quiet starts again from now.
pub fn noteHeard(self: *App, id: poltergeistpkg.Bus.Id) void {
    self.alarmsHeld().noteHeard(id, self.poltergeistElapsedMs());
}

/// Ring what is due for a group that can be told, remind a supervisor that
/// has heard nothing for too long, and arm the wake for the next of either
/// (task 2148). On the app thread.
fn considerSupervisorClocks(self: *App) void {
    self.alarm_dirty = false;
    const al = self.alarmsHeld();
    const wall = self.poltergeistWallMs();
    const now = self.poltergeistElapsedMs();
    const offset = self.alarmOffsetS();

    // Groups that are gone take their alarms with them.
    const Exists = struct {
        fn f(app: *App, group: []const u8) bool {
            return app.chat.exists(group);
        }
        fn ready(app: *App, group: []const u8) bool {
            const sup = app.groupSupervisor(group) orelse return false;
            return app.agentPresent(sup) and app.findSurfaceByID(sup) != null;
        }
    };
    var changed = al.forgetGroupsNotIn(self, Exists.f) > 0;

    // And terminals that are gone take their quiet with them: the table is
    // keyed by terminal id and would otherwise only grow (#2147's shape).
    const Here = struct {
        fn f(app: *App, id: u64) bool {
            return app.findSurfaceByID(id) != null;
        }
    };
    // Not `changed`: nothing about this is worth writing to `alarms.json`,
    // which holds alarms and not quiet.
    _ = al.forgetTerminalsNotIn(self, Here.f);

    // Ring what is due, where somebody can hear it. A line not typed (the
    // person is typing there) goes back and is tried again shortly.
    var retry = false;
    while (al.takeDue(wall, self, Exists.ready)) |a| {
        const sup = self.groupSupervisor(a.group).?;
        const surface = self.findSurfaceByID(sup).?;
        var buf: [255]u8 = undefined;
        const line = poltergeistpkg.Alarms.ringLine(&buf, a, wall, offset);
        const typed = surface.typePoltergeistNotice(line) catch false;
        if (!typed) {
            al.restore(a) catch al.release(a);
            retry = true;
            break;
        }
        log.info("alarms: #{d} of {s} rang for {x}", .{ a.id, a.group, sup });
        self.alarmTrace(.rang, a, sup);
        al.release(a);
        changed = true;
    }
    if (changed) self.saveAlarms();

    // The quiet reminder, group by group. What each group comes to is
    // `Alarms.plan`'s to decide, because both of round 1's defects were in
    // that arithmetic and neither could be read here.
    var next_quiet: ?u64 = null;
    const after = self.poltergeist_silence_remind_ms;
    // One arena for the loop, reset per group: `quietIn` allocates the
    // member lists, and a group's list is dead the moment its turn is over.
    var quiet_arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer quiet_arena.deinit();
    var it = self.chat.groups.iterator();
    while (it.next()) |kv| {
        const group = kv.key_ptr.*;
        defer _ = quiet_arena.reset(.retain_capacity);
        const q = self.quietIn(quiet_arena.allocator(), group, now, wall) orelse continue;
        const sup = poltergeistpkg.Alarms.supervisor(q) orelse continue;
        var r = poltergeistpkg.Alarms.plan(q, now, poltergeistpkg.Alarms.waiting_recheck_ms);
        if (r.say) {
            const typed = if (self.findSurfaceByID(sup)) |surface| typed: {
                var buf: [255]u8 = undefined;
                const line = poltergeistpkg.Alarms.quietLine(&buf, group, after);
                break :typed surface.typePoltergeistNotice(line) catch false;
            } else false;
            log.info("alarms: {s} quiet {d} ms, reminded {x} typed={}", .{ group, q.since_heard_ms, sup, typed });
            if (!typed) {
                // Nowhere it could be said: that is not a moment whose
                // passing changes anything, so look again shortly rather
                // than arm the moment that has already gone by.
                retry = true;
                r = .{ .say = false, .wake = now +| poltergeistpkg.Alarms.waiting_recheck_ms };
            }
        }
        if (r.wake) |at| next_quiet = if (next_quiet) |t| @min(t, at) else at;
    }

    // The next moment: an alarm's, a quiet's, or a minute on while one is
    // due with nobody to hear it or a line was refused.
    var wake: ?u64 = next_quiet;
    if (al.nextDue(wall)) |due| {
        const at = now + @as(u64, @intCast(@max(due - wall, 0)));
        wake = if (wake) |w| @min(w, at) else at;
    }
    if (retry or al.anyWaiting(wall)) {
        const at = now + poltergeistpkg.Alarms.waiting_recheck_ms;
        wake = if (wake) |w| @min(w, at) else at;
    }
    if (self.alarm_wake == null) {
        self.alarm_wake = .{ .io = global.io(), .fire = alarmClockDue, .ctx = self };
        self.alarm_wake.?.start() catch |err| {
            // Once, not once per tick: see `alarm_wake_warned`.
            if (!self.alarm_wake_warned) {
                self.alarm_wake_warned = true;
                log.warn("alarms: no wake thread; alarms ring only when something else happens err={}", .{err});
            }
            self.alarm_wake = null;
            return;
        };
    }
    self.alarm_wake.?.arm(wake, now);
}

/// Tasks of `group` not closed or cancelled -- `done` among them: the
/// supervisor has still to check those (task 2148).
///
/// **Counted, not collected.** This used to build the whole panel for the
/// group with `Tasks.inGroup` and throw it away, once per group per call --
/// and in a Debug build each of those was an allocation with six frames of
/// stack captured. The sample taken while the app thread burnt a core
/// (2026-10-24, `§6`) is 770 of 965 samples inside here. The state it
/// counts is the same one `Tasks.openInGroup` counts, so it is asked.
fn unfinishedIn(self: *App, group: []const u8) usize {
    return self.tasks.openInGroup(group);
}

fn alarmClockDue(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.poltergeist_stopping.load(.acquire)) return;
    self.alarm_due.store(true, .release);
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

fn taskList(
    ctx: *anyopaque,
    alloc: Allocator,
    group: []const u8,
    who: poltergeistpkg.Bus.Id,
    whole_panel: bool,
    q: poltergeistpkg.rpc.TaskQuery,
) anyerror!poltergeistpkg.rpc.TaskWindow {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (!self.chat.exists(group)) return error.NoSuchGroup;

    // A name the caller typed, turned into the panel's own enum here so a
    // wrong one is a refusal rather than a silent "no filter at all" --
    // which would answer a narrower question with the whole panel.
    const want_state: ?poltergeistpkg.Tasks.State = if (q.state.len == 0)
        null
    else
        std.meta.stringToEnum(poltergeistpkg.Tasks.State, q.state) orelse
            return error.BadState;

    const filter: poltergeistpkg.Tasks.Page = .{
        .limit = q.limit,
        .before = q.before,
        .state = want_state,
        .owner = q.owner,
        .match = q.match,
    };

    // The two filters, and they are two functions rather than one with a
    // flag through it. See `poltergeist/Tasks.zig`.
    const win = if (whole_panel)
        try self.tasks.page(alloc, group, filter)
    else
        try self.tasks.pageForWorker(alloc, group, who, filter);
    const list = win.tasks;
    defer alloc.free(list);

    const out = try alloc.alloc(poltergeistpkg.rpc.TaskView, list.len);
    for (list, 0..) |t, i| out[i] = .{
        .id = t.id,
        // Copied: the reply is written by the connection thread after this
        // returns, and the panel can change in between.
        .title = try alloc.dupe(u8, t.title),
        .owner = t.owner,
        .state = @tagName(t.state),
        .progress = @tagName(t.progress),
        .kind = @tagName(t.kind),
    };
    return .{ .rows = out, .more = win.more };
}

/// What happened to a group's panel, out of the record on disk.
///
/// Membership is asked the way `chatHistory` asks it, through the same one
/// call: whether this terminal is in the group and how far back it may look
/// are the same fact, and answering only the first would hand a terminal
/// added with `history: none` a column-by-column account of the night it
/// was added not to see. `NoSuchGroup` and `NotAMember` travel up as they
/// are.
fn taskHistory(
    ctx: *anyopaque,
    alloc: Allocator,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
    before_seq: u64,
    limit: usize,
) anyerror!poltergeistpkg.rpc.TaskPage {
    const self: *App = @ptrCast(@alignCast(ctx));

    const floor = try self.chat.floorOf(group, id);

    // Nothing was ever written down, so there is nothing behind the panel
    // to page back into.
    const l = if (self.task_log) |*v| v else {
        // Not "no history": the records are closed because something went
        // wrong, which is a different answer.
        if (self.poltergeist_log_problem != null) return error.LogsClosed;
        return .{ .events = &.{}, .more = false };
    };

    // A member kept out of what was said is kept out of what was done.
    //
    // The chat log's floor is a line number in *that* record and there is
    // nothing to map it onto here -- the task record carries no such
    // number, by design. So the floor is read as the one thing it says
    // plainly: this member was not there for the beginning. Which events
    // predate its joining cannot be worked out, so none are handed over
    // rather than some. The supervisor and the person at the keyboard have
    // no floor and see all of it, which is who the statistics page is for.
    if (floor.seq > 0) return .{ .events = &.{}, .more = false };

    const page = try l.history(alloc, group, before_seq, limit);

    // Handed straight across. Both sides already own their strings through
    // `alloc`, so this is a change of type and nothing else -- but the two
    // types stay separate: `TaskLog.Event` is what the record holds and
    // `rpc.TaskEvent` is what the protocol promises, and a record that
    // grows a field should not silently become a protocol that has one.
    const out = try alloc.alloc(poltergeistpkg.rpc.TaskEvent, page.events.len);
    for (page.events, 0..) |e, i| out[i] = .{
        .seq = e.seq,
        .at_ms = e.at_ms,
        .op = e.op,
        .task = e.task,
        .title = e.title,
        .owner = e.owner,
        .state = e.state,
        .progress = e.progress,
        .reowned = if (e.from != poltergeistpkg.Tasks.nobody) .{ .from = e.from, .via = e.via } else null,
    };
    alloc.free(page.events);

    return .{ .events = out, .more = page.more };
}

fn chatAdd(
    ctx: *anyopaque,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
    history: poltergeistpkg.Chat.History,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));

    // Recorded here, by us, because these are facts we already hold.
    // Asking the supervisor to tell us where a terminal is working would
    // only add a chance for it to be told wrong.
    var buf: [2048]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buf);
    const footing = self.footingOf(fixed.allocator(), id);

    // A project has one supervisor (task 1797): a second one is refused
    // here, the one place every add goes through.
    {
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        if (poltergeistpkg.ControlRoom.projectSupervisorBesides(arena.allocator(), &self.poltergeist, &self.chat, group, id)) |other| {
            log.info("poltergeist: not adding supervisor {x} to {s}: its project's supervisor is {x}", .{ id, group, other });
            return error.ProjectHasSupervisor;
        }
    }

    try self.chat.add(group, id, history, footing);
    self.noteJoined(group, id, footing);

    // A supervisor joining takes the group over from one whose agent has
    // left (task 1864): that one gives it up now, not when its next agent
    // turns up as a second supervisor.
    self.dropSupersededBy(group, id);
    // And the workers its project's file marks are its now, before its
    // first one is placed (task 1875).
    self.takeUpStatedWorkers(group, id);

    // A supervisor joining: if that makes it this group's, what it is is
    // written down for whoever starts the next one.
    self.noteSupervisor(id, .write);
    self.takeUpGroups(id);

    // `history: none` means nothing from before now, and "before now"
    // includes the file. The group in memory cannot say where that reaches
    // -- after a restart it is empty while `chat.jsonl` still holds last
    // night under the same name -- so the one thing holding the log says
    // it. Without this the terminal is kept out by `group_read` and handed
    // all of it by `group_history`.
    if (history == .none) {
        if (self.chat_log) |*l| self.chat.setLogFloor(group, id, l.head());
    }

    self.saveSession();
}

/// Bring a member's recorded footing up to date, if we learned anything.
///
/// **Only overwrites with something.** When a terminal has closed there
/// is no surface to ask, and that is exactly when the old record matters
/// most -- it is what tomorrow's restart has to go on. Blanking it here
/// would throw away the answer at the moment the question gets asked.
fn refreshFooting(
    self: *App,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
) void {
    if (id == poltergeistpkg.Chat.user_id) return;

    var buf: [2048]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buf);
    const now = self.footingOf(fixed.allocator(), id);
    if (now.cwd.len == 0 and now.title.len == 0) return;

    self.chat.setFooting(group, id, now) catch |err| {
        log.debug("poltergeist: could not update footing err={}", .{err});
    };
}

/// Where a terminal is working, for finding it again after a restart.
///
/// Best effort throughout: a bare shell may have no title, and the
/// working directory is only known once the shell has reported one. An
/// empty field is an honest "we do not know", which beats refusing to
/// record the member at all.
fn footingOf(
    self: *App,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
) poltergeistpkg.Chat.Footing {
    const surface = self.findSurfaceByID(id) orelse return .{};

    var out: poltergeistpkg.Chat.Footing = .{};

    if (surface.pwd(alloc) catch null) |dir| out.cwd = dir;

    if (surface.rt_surface.getTitle()) |title| {
        if (title.len > 0) out.title = alloc.dupe(u8, title) catch "";
    }

    return out;
}

/// Write down that `id` joined `group`, with what is known of it now
/// (task 1511). The footing is the one `Chat.add` was just given.
fn noteJoined(self: *App, group: []const u8, id: poltergeistpkg.Bus.Id, footing: poltergeistpkg.Chat.Footing) void {
    const l = if (self.session_log) |*v| v else return;
    var held: poltergeistpkg.Bus.Agent = undefined;
    l.joined(group, self.poltergeistWallMs(), id, self.memberOf(id, footing, &held), false);
}

/// What is known of `id` now, as a group's record keeps it. The agent's
/// strings are copied into `held`, which the caller keeps until the line is
/// written -- see `heldMember`.
fn memberOf(self: *App, id: poltergeistpkg.Bus.Id, footing: poltergeistpkg.Chat.Footing, held: *poltergeistpkg.Bus.Agent) poltergeistpkg.SessionLog.Member {
    const role: []const u8 = if (self.personas.launchOf(id)) |launch| launch.role else switch (self.poltergeist.roleOf(id)) {
        .supervisor => "supervisor",
        .watched => "worker",
        else => "",
    };
    const transcript_path = if (self.terminal_meta) |*m| m.transcriptPathOf(id) else "";
    return heldMember(&self.poltergeist, id, role, footing, transcript_path, held);
}

/// A member whose CLI and session are copied into `held` rather than
/// borrowed from the bus (task 1732). The bus keeps its agents in a hash
/// map, and a map that grows moves them: a slice into the bus is only as
/// good as the bus staying still until the line is written, which nothing
/// here promises. The copy is the caller's, and lives as long as it says.
fn heldMember(
    bus: *const poltergeistpkg.Bus,
    id: poltergeistpkg.Bus.Id,
    role: []const u8,
    footing: poltergeistpkg.Chat.Footing,
    transcript_path: []const u8,
    held: *poltergeistpkg.Bus.Agent,
) poltergeistpkg.SessionLog.Member {
    held.* = bus.agentOf(id).*;
    return .{
        .role = role,
        .cli = held.cli.get() orelse "",
        .launcher = held.launcher.get() orelse "",
        .cwd = footing.cwd,
        .title = footing.title,
        .session_id = held.session_id.get() orelse "",
        .transcript_path = transcript_path,
    };
}

test "1732: a member's cli is still its name when the bus has grown before the join is written" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-heldmember-{x}", .{&raw});
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }
    try std.Io.Dir.cwd().createDirPath(io, dir);

    // The bus on an arena: what its map lets go of when it grows is
    // scribbled over (`Allocator.free`) but stays mapped, so a slice left
    // pointing there reads garbage instead of faulting.
    var bus_arena: std.heap.ArenaAllocator = .init(alloc);
    defer bus_arena.deinit();
    var bus: poltergeistpkg.Bus = .init(bus_arena.allocator(), .{});
    defer bus.deinit();
    try bus.register(0x11);
    bus.entries.getPtr(0x11).?.agent.cli.set("claude-code");

    var held: poltergeistpkg.Bus.Agent = undefined;
    const member = heldMember(&bus, 0x11, "worker", .{ .cwd = "/work/repo" }, "", &held);

    // Other terminals arrive before the line is written, enough of them
    // that the bus's map has to grow and move what it held.
    const before = bus.entries.capacity();
    var id: poltergeistpkg.Bus.Id = 0x1000;
    while (bus.entries.capacity() == before) : (id += 1) try bus.register(id);

    const at: i64 = 1_700_000_000_000;
    {
        var l = try poltergeistpkg.SessionLog.open(alloc, io, dir);
        defer l.deinit();
        l.joined("build", at, 0x11, member, false);
    }

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const r = try poltergeistpkg.SessionLog.read(arena.allocator(), io, dir);
    try testing.expectEqual(@as(usize, 1), r.stints.len);
    try testing.expectEqualStrings("claude-code", r.stints[0].cli);
}

/// Make a group, with its creator in it and written down as having joined.
///
/// The creator is a member from the first moment (`Chat.create`), and what
/// it does there is as much the group's work as anything a terminal added
/// later does -- so a supervisor looking back through the group has to
/// find it too. Before the tenth run found it, only `chatAdd` wrote the
/// join, and a group's own creator was missing from its record.
///
/// The person at the keyboard is in every group as well: these are
/// conversations happening on their machine, and a window they could read
/// but not answer in would be a strange thing to build. They have no
/// terminal of their own, so there is nothing to write down about where
/// they are working, and nothing for anyone to look back through.
fn createGroup(
    chat: *poltergeistpkg.Chat,
    sessions: ?*poltergeistpkg.SessionLog,
    group: []const u8,
    by: poltergeistpkg.Bus.Id,
    footing: poltergeistpkg.Chat.Footing,
    at_ms: i64,
    member: poltergeistpkg.SessionLog.Member,
) !void {
    try chat.create(group, by);
    try chat.add(group, poltergeistpkg.Chat.user_id, .all, .{});
    if (by == poltergeistpkg.Chat.user_id) return;
    try chat.setFooting(group, by, footing);
    if (sessions) |l| l.joined(group, at_ms, by, member, false);
}

test "a group's creator is written down as having joined it, the person at the keyboard is not" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-creategroup-{x}", .{&raw});
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var chat: poltergeistpkg.Chat = .init(alloc, .{});
    defer chat.deinit();
    const at: i64 = 1_700_000_000_000;
    {
        var l = try poltergeistpkg.SessionLog.open(alloc, io, dir);
        defer l.deinit();
        try createGroup(&chat, &l, "build", 0x11, .{ .cwd = "/work/repo", .title = "✳ boss" }, at, .{ .role = "supervisor", .cwd = "/work/repo" });
        // Restoring a group after a restart makes it in the person's name.
        try createGroup(&chat, &l, "ops", poltergeistpkg.Chat.user_id, .{}, at + 1, .{});
    }

    try testing.expect(chat.isMember("build", 0x11));
    try testing.expect(chat.isMember("build", poltergeistpkg.Chat.user_id));
    try testing.expectEqualStrings("/work/repo", chat.footingOf("build", 0x11).?.cwd);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const r = try poltergeistpkg.SessionLog.read(arena.allocator(), io, dir);
    try testing.expectEqual(@as(usize, 1), r.stints.len);
    const s = r.stints[0];
    try testing.expectEqualStrings("build", s.group);
    try testing.expectEqual(@as(u64, 0x11), s.terminal);
    try testing.expectEqual(at, s.from_ms);
    try testing.expectEqualStrings("supervisor", s.role);
}

/// What earlier runs wrote about their terminals, as `Reclaim` reads it.
/// Null when nothing could be read: then nothing is taken up.
/// The agent session each terminal of earlier runs ended on, read once, so
/// the performance page can draw one row per session (task 2234). A file
/// that cannot be read is left out, as a terminal with no session.
///
/// **The notes are the same ones `Reclaim` reads**, so this costs one pass
/// over `<state>/terminals` at startup and nothing afterwards.
fn seedResourceSessions(self: *App, io: std.Io, state_dir: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const notes = poltergeistpkg.TerminalMeta.read(arena.allocator(), io, state_dir) catch return;
    self.resource_sessions.seed(self.alloc, notes);
}

fn readReclaim(alloc: Allocator, io: std.Io, state_dir: []const u8) ?poltergeistpkg.Reclaim {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const notes = poltergeistpkg.TerminalMeta.read(arena.allocator(), io, state_dir) catch return null;
    const record = poltergeistpkg.SessionLog.read(arena.allocator(), io, state_dir) catch return null;
    return poltergeistpkg.Reclaim.build(alloc, notes, record.stints) catch null;
}

/// A terminal said a session that a terminal of an earlier run ended on
/// (task 1978): it is that agent, back under a new id. Its open tasks are
/// its again and it is back in the groups it never left, each written
/// down and said in the group.
fn reclaimSession(self: *App, id: poltergeistpkg.Bus.Id, cli: []const u8, session_id: []const u8) void {
    const Reclaim = poltergeistpkg.Reclaim;
    const r = if (self.reclaim) |*v| v else return;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const live = self.liveTerminals(a) catch return;
    const got = r.claim(a, id, cli, session_id, live) catch return;
    if (got.terminals.len == 0) return;

    const moved = self.reownTasks(a, id, got.terminals, cli, session_id) catch return;

    // The same way `group_add` puts a terminal in a group, with nothing
    // from before: the agent read what it read in its earlier life.
    var joined: std.ArrayListUnmanaged([]const u8) = .empty;
    for (got.groups) |group| {
        if (!self.chat.exists(group) or self.chat.isMember(group, id)) continue;
        chatAdd(self, group, id, .none) catch |err| {
            log.info("poltergeist: {x} could not go back in {s} err={}", .{ id, group, err });
            continue;
        };
        joined.append(a, group) catch {};
    }

    var via_buf: [96]u8 = undefined;
    const via = poltergeistpkg.TaskLog.viaText(&via_buf, cli, session_id);
    log.info("poltergeist: {x} is back as {s}: {d} task(s), {d} group(s)", .{ id, via, moved.len, joined.items.len });

    // Said in each group it is now in that this touched.
    var back: std.ArrayListUnmanaged(Reclaim.Task) = .empty;
    for (moved) |task| if (self.tasks.get(task)) |t| back.append(a, .{ .id = task, .group = t.group }) catch {};
    const said = Reclaim.groupsToTell(a, joined.items, back.items) catch return;
    for (said) |group| {
        if (!self.chat.isMember(group, id)) continue;
        var text: std.Io.Writer.Allocating = .init(a);
        Reclaim.notice(&text.writer, .{
            .id = id,
            .via = via,
            .was = got.terminals,
            .group = group,
            .tasks = back.items,
            .rejoined = Reclaim.contains(joined.items, group),
        }) catch continue;
        const now: u64 = @intCast(self.poltergeistWallMs());
        if (self.chat.post(group, id, text.written(), now)) |posted| {
            self.logChat(group, posted.seq, id, now, false, text.written(), 0);
        } else |err| {
            log.warn("poltergeist: could not say in {s} that {x} is back err={}", .{ group, id, err });
        }
    }
    self.tellTerminalsAboutMessages();
    self.controlRoomTouch();
}

/// Every open task the old terminals had, handed to `id` and written down
/// as `reowned` with the session it went by. The ids moved, in `alloc`.
fn reownTasks(
    self: *App,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
    was: []const poltergeistpkg.Bus.Id,
    cli: []const u8,
    session_id: []const u8,
) Allocator.Error![]const poltergeistpkg.Tasks.TaskId {
    const at = self.taskWallMs();
    var moved: std.ArrayListUnmanaged(poltergeistpkg.Tasks.TaskId) = .empty;
    for (was) |old| {
        const before = moved.items.len;
        try self.tasks.reown(alloc, old, id, at, &moved);
        for (moved.items[before..]) |task| {
            // A fresh stretch, the same as a task handed over.
            _ = self.poltergeist_nudged.remove(task);
            const t = self.tasks.get(task) orelse continue;
            if (self.task_log) |*l| l.appendReowned(at, t, .{ .from = old, .cli = cli, .session_id = session_id });
        }
    }
    return moved.items;
}

test "1978: tasks taken up are written as reowned, with the session they went by, and stay taken up after a restart" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const P = poltergeistpkg;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-reown-{x}", .{&raw});
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var app: App = undefined;
    app.alloc = alloc;
    app.tasks = .init(alloc, .{});
    defer app.tasks.deinit();
    app.poltergeist_nudged = .empty;
    defer app.poltergeist_nudged.deinit(alloc);
    app.task_log = try P.TaskLog.open(alloc, io, dir);
    defer app.task_log.?.deinit();

    const mine = try app.tasks.create("build", "mine", .feature);
    try app.tasks.assign(mine, 0xa);
    const done = try app.tasks.create("build", "done", .feature);
    try app.tasks.assign(done, 0xa);
    try app.tasks.close(done);
    try app.poltergeist_nudged.put(alloc, mine, {});

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const moved = try app.reownTasks(arena.allocator(), 0x100, &.{0xa}, "claude-code", "55a835df-016b-41d7-829e-f4c3c2cec25d");
    try testing.expectEqualSlices(P.Tasks.TaskId, &.{mine}, moved);
    try testing.expect(!app.poltergeist_nudged.contains(mine));

    const page = try app.task_log.?.history(alloc, "build", 0, 50);
    defer P.TaskLog.freePage(alloc, page);
    const last = page.events[page.events.len - 1];
    try testing.expectEqualStrings("reowned", last.op);
    try testing.expectEqual(mine, last.task);
    try testing.expectEqual(@as(P.Tasks.Id, 0x100), last.owner);
    try testing.expectEqual(@as(P.Tasks.Id, 0xa), last.from);
    try testing.expectEqualStrings("claude-code 55a835df", last.via);

    // The next run replays the record: the task is the new terminal's.
    var again: P.Tasks = .init(alloc, .{});
    defer again.deinit();
    app.task_log.?.restore(&again);
    try testing.expectEqual(@as(P.Tasks.Id, 0x100), again.get(mine).?.owner);
}

/// An agent said which session it is: beside its transcript, and in every
/// group it is in, when that is news.
fn noteAgentSession(self: *App, id: poltergeistpkg.Bus.Id, ev: poltergeistpkg.agent_event.Event) void {
    const sid = ev.session_id orelse return;
    self.noteSession(id, ev.cli, sid, ev.transcript_path orelse "");
}

/// The sessions only an adapter knows (task 2084): agents with no hooks,
/// said by `Identities` instead (`Identities.sessionToNote` says when).
/// Written down and reclaimed by, exactly as a hook's would be.
fn noteIdentifiedSessions(self: *App) void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    for (self.surfaces.items) |v| {
        const id = poltergeistpkg.Bus.idOf(v.core());
        if (self.isChatSurface(id)) continue;
        const view = self.identities.view(global.io(), a, id) catch continue;
        const hooks_live = self.poltergeist.agentOf(id).hooks == .live;
        const said = poltergeistpkg.Identities.sessionToNote(view, hooks_live) orelse continue;
        self.noteSession(id, said.cli, said.session, "");
    }
}

/// A terminal's agent is in `session_id`: beside its transcript, and in
/// every group it is in, when that is news -- and, when an agent of an
/// earlier run ended in it, that agent is back (`reclaimSession`).
fn noteSession(self: *App, id: poltergeistpkg.Bus.Id, cli: []const u8, sid: []const u8, path: []const u8) void {
    const m = if (self.terminal_meta) |*v| v else return;
    const at = self.poltergeistWallMs();
    if (!m.agent(id, at, cli, sid, path)) return;
    // Which session this terminal runs, for the performance page: one row
    // per session rather than one per id (task 2234). Written here, the
    // one place every agent that says its session goes through.
    self.resource_sessions.note(self.alloc, id, cli, sid);
    self.reclaimSession(id, cli, sid);
    self.backfillMemberSession(id, cli, sid);
    const l = if (self.session_log) |*v| v else return;
    var it = self.chat.groups.iterator();
    while (it.next()) |kv| {
        if (!self.chat.isMember(kv.key_ptr.*, id)) continue;
        l.agent(kv.key_ptr.*, at, id, .{ .cli = cli, .launcher = self.poltergeist.agentOf(id).launcher.get() orelse "", .session_id = sid, .transcript_path = path });
    }
}

/// The agent in `id` has said its session: the places it holds in a squad,
/// and their open stretches, were written with "" when it took them, before
/// the agent existed (task 2470). After `reclaimSession`, so a place handed
/// to this terminal by a reclaim is filled in the same breath.
fn backfillMemberSession(self: *App, id: poltergeistpkg.Bus.Id, cli: []const u8, sid: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var via_buf: [96]u8 = undefined;
    const via = poltergeistpkg.TaskLog.viaText(&via_buf, cli, sid);
    const at = self.taskWallMs();
    var changed: std.ArrayListUnmanaged(poltergeistpkg.Tasks.TaskId) = .empty;
    self.tasks.noteSession(a, id, via, at, &changed) catch return;
    if (changed.items.len > 0) self.controlRoomTouch();
    // Written with the same `at` the spans were moved at, so a replay ends
    // and opens them at the same moment.
    const l = if (self.task_log) |*v| v else return;
    for (changed.items) |task| {
        const t = self.tasks.get(task) orelse continue;
        for (t.members) |m| {
            if (m.slot == .filled and m.id == id) l.appendMember(at, .session, t, .{ .alias = m.alias, .id = id, .session = via });
        }
    }
}

/// The host has said which tab is in which project: each terminal's, as
/// far as it changed.
fn noteTerminalProjects(self: *App) void {
    const m = if (self.terminal_meta) |*v| v else return;
    const at = self.poltergeistWallMs();
    for (self.surfaces.items) |rt| {
        const id = poltergeistpkg.Bus.idOf(rt.core());
        m.project(id, at, if (self.projects.projectOf(id)) |p| p.name else null);
    }
}

/// A group's tie to a project changed: written beside who was in it, so
/// that "which project" can be asked of a time and not only of now.
fn noteGroupProject(self: *App, group: []const u8) void {
    const l = if (self.session_log) |*v| v else return;
    const name: ?[]const u8 = switch (self.chat.projectOf(group)) {
        .bound => |n| n,
        .undecided, .declined => null,
    };
    l.project(group, self.poltergeistWallMs(), name);
}

/// A terminal is going: it leaves every group it is in, on the record.
/// Called by `Surface.deinit` before `Chat.forget` takes it out of memory.
pub fn poltergeistTerminalGone(self: *App, id: poltergeistpkg.Bus.Id) void {
    if (self.session_log) |*l| {
        const at = self.poltergeistWallMs();
        var it = self.chat.groups.iterator();
        while (it.next()) |kv| {
            if (self.chat.isMember(kv.key_ptr.*, id)) l.left(kv.key_ptr.*, at, id, false);
        }
    }
    if (self.terminal_meta) |*m| m.forget(id);
}

fn channelSeats(
    ctx: *anyopaque,
    alloc: Allocator,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
) anyerror![]const poltergeistpkg.rpc.ChannelSeat {
    const self: *App = @ptrCast(@alignCast(ctx));
    const nobody = poltergeistpkg.Tasks.nobody;
    if (id == nobody) return &.{};

    const list = try self.tasks.inGroup(alloc, group);
    defer alloc.free(list);

    var out: std.ArrayListUnmanaged(poltergeistpkg.rpc.ChannelSeat) = .empty;
    errdefer out.deinit(alloc);
    for (list) |t| {
        // Holding a place now: the lead, or a filled place.
        var holds = t.owner == id;
        for (t.members) |m| {
            if (m.slot == .filled and m.id == id) holds = true;
        }

        // Having held one: the last stretch's end is where reading stops.
        var held = false;
        var left: i64 = 0;
        for (t.spans) |sp| {
            if (sp.id != id) continue;
            held = true;
            if (sp.to_ms) |to| left = @max(left, to) else holds = true;
        }
        if (!holds and !held) continue;

        try out.append(alloc, .{
            .task = t.id,
            .until_ms = if (holds) null else @intCast(@max(left, 0)),
            .current = holds and t.state == .open,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn channelReaders(
    ctx: *anyopaque,
    alloc: Allocator,
    group: []const u8,
    task: u64,
) anyerror!?[]const poltergeistpkg.Bus.Id {
    const self: *App = @ptrCast(@alignCast(ctx));
    const nobody = poltergeistpkg.Tasks.nobody;
    const t = self.tasks.get(task) orelse return null;
    if (!std.mem.eql(u8, t.group, group)) return null;

    var out: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
    errdefer out.deinit(alloc);
    if (t.owner != nobody) try out.append(alloc, t.owner);
    for (t.members) |m| {
        if (m.slot != .filled or m.id == nobody) continue;
        if (std.mem.indexOfScalar(poltergeistpkg.Bus.Id, out.items, m.id) == null) try out.append(alloc, m.id);
    }
    return out.toOwnedSlice(alloc);
}

fn chatOwner(ctx: *anyopaque, group: []const u8) anyerror!poltergeistpkg.Bus.Id {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.chat.createdBy(group);
}

fn chatRemove(
    ctx: *anyopaque,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.chat.remove(group, id);
    if (self.session_log) |*l| l.left(group, self.poltergeistWallMs(), id, false);
    self.saveSession();
}

fn chatCompact(
    ctx: *anyopaque,
    group: []const u8,
    through: u64,
    channel: u64,
    summary: []const u8,
    by: poltergeistpkg.Bus.Id,
) anyerror!poltergeistpkg.Chat.Kept {
    const self: *App = @ptrCast(@alignCast(ctx));
    const at: u64 = @intCast(self.poltergeistWallMs());
    const done = try self.chat.compact(group, through, channel, summary, by, at);
    const seq = done.seq;

    // Written after the messages it replaced, not over them. Compaction
    // frees the agents' context; it is not an instruction to forget, and
    // the record of a night is worth more than the shape it was in when
    // the supervisor tidied up.
    self.logChat(group, seq, by, at, true, summary, channel);

    return done.wrote;
}

fn chatPost(
    ctx: *anyopaque,
    group: []const u8,
    from: poltergeistpkg.Bus.Id,
    text: []const u8,
    mentions: poltergeistpkg.rpc.Mentions,
) anyerror!poltergeistpkg.Chat.Posted {
    const self: *App = @ptrCast(@alignCast(ctx));
    const at: u64 = @intCast(self.poltergeistWallMs());

    var named: [poltergeistpkg.Chat.max_mentions]poltergeistpkg.Bus.Id = undefined;
    if (mentions.to.len > named.len) return error.TooManyMentions;
    for (mentions.to, 0..) |d, i| named[i] = d.to;
    const posted = try self.chat.postIn(group, from, text, named[0..mentions.to.len], mentions.channel, null, at);
    const seq = posted.seq;

    // A terminal's title moves with its work, so the record follows it.
    // Speaking is the right moment: it is infrequent, and a terminal that
    // just spoke is one whose title means something.
    self.refreshFooting(group, from);

    // Written down after the model accepted it, so the record holds what
    // was actually said rather than what somebody tried to say.
    self.logChat(group, seq, from, at, false, text, mentions.channel);

    // **Typed before the notices go out**, not after: a notice lands in the
    // input box without a return, and a named terminal handed one first
    // would then refuse its own mention as `DraftInLine`. A terminal typed
    // into here is marked as told, so the sweep below does not put a second
    // line in behind the first.
    //
    // Through `poltergeistSend`, the same door `terminal_send` uses, so
    // `UserPresent` and `DraftInLine` apply unchanged. What it types is the
    // text as the group keeps it -- `Chat.formatDelivery` folds the line
    // breaks, nothing else -- so the terminal and the record say the same.
    if (mentions.to.len > 0) {
        const kept = self.chat.messageText(group, seq) orelse text;
        const line = try poltergeistpkg.Chat.formatDelivery(
            self.alloc,
            group,
            seq,
            from,
            mentions.from_title,
            kept,
        );
        defer self.alloc.free(line);

        const now_ms = self.poltergeistElapsedMs();
        for (mentions.to) |*d| {
            poltergeistSendAs(self, d.to, line, true, mentions.typist) catch |err| {
                d.err = err;
                // Typed again later when the refusal clears by itself
                // (#60); `group_post`'s row says so from the same rule.
                const queued = self.mention_retries.add(group, seq, from, d.to, mentions.typist, line, err, now_ms) catch |e| q: {
                    log.warn("poltergeist: mention to {x} not queued for retry err={}", .{ d.to, e });
                    break :q null;
                };
                if (queued) |delay| self.noticeRetryIn(delay + chat_notice_retry_margin_ms);
                continue;
            };
            self.chat.markTold(group, d.to, now_ms);
        }
    }

    self.tellTerminalsAboutMessages();

    // Handed straight back: whether it all fitted is not this layer's to
    // interpret, and the sentence the writer reads is built where the reply
    // is written. The same shape `setBrief` already answers with.
    return posted;
}

/// Type again the mentions whose retry is due (#60), and tell the author
/// about any that the last try could not deliver either.
fn retryMentions(self: *App, now_ms: u64) void {
    var due: std.ArrayListUnmanaged(poltergeistpkg.MentionRetry.Entry) = .empty;
    defer due.deinit(self.alloc);
    self.mention_retries.takeDue(now_ms, &due) catch return;

    for (due.items) |e| {
        // **Nobody listening, nothing typed** -- the gate `group_post`
        // asked when the mention was made (#1533), asked again: an agent
        // that has exited since leaves a shell that would run the line.
        var refused: anyerror = error.NoAgent;
        // The CLI started there and not yet connected counts as `group_post`
        // counts it (task 1682, `rpc.mayType`): its input box showing.
        const reach: poltergeistpkg.rpc.StartupReach = if (self.agentPresent(e.to)) .ready else self.startupReachOf(e.to);
        const outcome: poltergeistpkg.MentionRetry.Outcome = if (reach == .blocked)
            .{ .gave_up = "StartupPrompt" }
        else if (reach == .none)
            .{ .gave_up = "NoAgent" }
        else if (poltergeistSendAs(self, e.to, e.line, true, e.typist)) |_| {
            self.chat.markTold(e.group, e.to, now_ms);
            log.info("poltergeist: mention delivered on retry group={s} seq={d} to={x}", .{ e.group, e.seq, e.to });
            // The control room's ask, if it was one, says so (task 1671).
            if (e.from == poltergeistpkg.Chat.user_id and self.control_asks.settled(e.group, e.seq, null)) self.controlRoomTouch();
            self.mention_retries.free(e);
            continue;
        } else |err| o: {
            refused = err;
            break :o self.mention_retries.requeue(e, err, now_ms);
        };

        switch (outcome) {
            .again => |delay| {
                log.info("poltergeist: mention refused again, retrying group={s} seq={d} to={x} err={}", .{ e.group, e.seq, e.to, refused });
                self.noticeRetryIn(delay + chat_notice_retry_margin_ms);
            },
            .gave_up => |code| {
                if (e.from == poltergeistpkg.Chat.user_id and self.control_asks.settled(e.group, e.seq, code)) self.controlRoomTouch();
                self.tellMentionGaveUp(e, code);
                self.mention_retries.free(e);
            },
        }
    }
    // A wake that came a little early took nothing: come back for it.
    if (self.mention_retries.nextDueMs()) |at| {
        self.noticeRetryIn(at -| now_ms + chat_notice_retry_margin_ms);
    }
}

/// The last retry of a mention was refused too: say so in the author's own
/// terminal, the one place it will be read (#60). Refused there as well, it
/// is only logged -- a retry of the retry would be the same silence later.
fn tellMentionGaveUp(self: *App, e: poltergeistpkg.MentionRetry.Entry, code: []const u8) void {
    log.warn("poltergeist: mention not delivered after retries group={s} seq={d} to={x} code={s}", .{ e.group, e.seq, e.to, code });
    if (e.from == poltergeistpkg.Chat.user_id or !self.agentPresent(e.from)) return;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    poltergeistpkg.MentionRetry.writeGaveUp(&w, e.group, e.seq, e.to, code) catch return;
    poltergeistSend(self, e.from, w.buffered(), true) catch |err| {
        log.warn("poltergeist: could not tell {x} its mention was not delivered err={}", .{ e.from, err });
    };
}

/// Put one message in the log on disk, if there is one.
///
/// The author's name is resolved here rather than at read time because a
/// terminal's title changes, and worse, the terminal goes away: a record
/// written tonight has to still say who spoke when it is read tomorrow.
///
/// `seq` is the group's own count for the message, carried in only so the
/// line it became on disk can be tied back to it. With no log, or with a
/// write that failed, the message keeps `log_seq = 0` -- which is what a
/// reader paging backwards has to see to know the trail stops there.
fn logChat(
    self: *App,
    group: []const u8,
    seq: u64,
    from: poltergeistpkg.Bus.Id,
    at_ms: u64,
    summary: bool,
    text: []const u8,
    channel: u64,
) void {
    const l = if (self.chat_log) |*v| v else return;

    var buf: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buf);
    const author = self.chatMemberTitle(fixed.allocator(), from) catch "";

    const at_wall_ms: i64 = @intCast(at_ms);

    const log_seq = l.append(
        group,
        from,
        author,
        at_wall_ms,
        summary,
        text,
        channel,
    );
    if (log_seq != 0) self.chat.setLogSeq(group, seq, log_seq);

    // Handed to whoever is listening, after the record and never instead
    // of it: the record is what is read back, and a plugin keeps an extra
    // copy of what it is told. `publish` cannot fail and does not wait, so
    // nothing a plugin does is felt on this path.
    //
    // The seq is the one the record stamped on the message. It is an
    // identity and not a position in any file -- it is what lets a plugin
    // store the same message twice and end up with one row -- so with no
    // record there is no identity to hand out, and nothing is published.
    if (log_seq != 0) self.poltergeist_feed.publish(.{ .chat = .{
        .seq = log_seq,
        .at_ms = at_wall_ms,
        .group = group,
        .author = author,
        .summary = summary,
        .text = text,
        .channel = channel,
    } });
}

fn chatGroups(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
) anyerror![]const []const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    const live = try self.liveTerminals(alloc);
    defer alloc.free(live);

    const names = try self.chat.groupsFor(alloc, id, live);
    errdefer alloc.free(names);

    // Copied, not borrowed: the reply is written by the connection thread
    // after this returns, and a group can be destroyed in between.
    const owned = try alloc.alloc([]const u8, names.len);
    for (names, 0..) |n, i| owned[i] = try alloc.dupe(u8, n);
    alloc.free(names);
    return owned;
}

/// Tell the person something, and say plainly what came of it.
///
/// The supervisor asked for this because it looked at a screen and decided
/// a human was needed; the program never makes that call itself. What it
/// does decide is the hour: a scheduling question inside quiet hours is
/// handed back to the supervisor, while an authorisation prompt goes out
/// regardless -- the terminal is stopped until somebody answers, so holding
/// one back does not protect anyone's sleep, it just wastes the night.
///
/// ⚠️ **The reason used to be "nobody may answer those for somebody else",
/// and `terminal_answer_prompt` made that false** for a terminal whose
/// switch the user has turned on. The rule this comment defends is
/// unchanged; only the reason given for it had to be. A supervisor that
/// *can* answer will answer rather than notify, and one that cannot still
/// needs the person at whatever hour it is.
///
/// The reply is a sentence rather than a code because the supervisor has
/// to act on it: if nothing was sent, waiting for an answer is waiting for
/// nothing.
fn notifyUser(
    ctx: *anyopaque,
    alloc: Allocator,
    reason_text: []const u8,
    title: []const u8,
    body: []const u8,
    id: poltergeistpkg.Bus.Id,
    from: poltergeistpkg.Bus.Id,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    const reason: poltergeistpkg.notify.Reason =
        if (std.mem.eql(u8, reason_text, "authorisation"))
            .authorisation
        else
            .scheduling;

    // **The system's own notification, for a worker that needs the person**
    // (the user's decision, 2026-10-13: "要"). It needs no plugin, so the
    // default installation -- where no plugin subscribes and the answer
    // below is "nobody was told" -- still reaches somebody. Raised from the
    // caller's window: the person is being called to the supervisor, which
    // is where the question is put to them.
    //
    // Not held to `desktop-notifications`: that switch is about programs
    // running in a terminal raising notifications with an escape sequence,
    // and this is Polter's own.
    const system: poltergeistpkg.notify.System = switch (reason) {
        .scheduling => .not_asked,
        .authorisation => self.raiseSystemNotification(from, title, body),
    };
    // **And the control room**: the caller's group is one that is waiting
    // for the person from now, in the supervisor's own words, without the
    // minute a worker's prompt otherwise spends being the supervisor's
    // (`Bus.raise`). Only for `authorisation`: a scheduling question is one
    // the supervisor could answer itself.
    const raised: poltergeistpkg.notify.Raised = switch (reason) {
        .scheduling => .not_asked,
        .authorisation => raised: {
            const said = if (body.len == 0)
                try alloc.dupe(u8, title)
            else
                try std.fmt.allocPrint(alloc, "{s}: {s}", .{ title, body });
            defer alloc.free(said);
            const took = self.poltergeist.raise(from, self.poltergeistElapsedMs(), said) catch |err| {
                log.warn("poltergeist: could not record what was raised err={}", .{err});
                break :raised .not_a_terminal;
            };
            if (took) self.controlRoomTouch();
            // A terminal in no group is on a row of its own, and is told
            // so: "your group" was the answer it got (task 1544).
            break :raised poltergeistpkg.notify.Raised.of(took, self.inAnyGroup(from));
        },
    };
    const plugins = try self.notifyPlugins(alloc, reason, title, body, id);
    defer alloc.free(plugins);
    return poltergeistpkg.notify.reply(alloc, raised, system, plugins);
}

/// Whether terminal `id` is a member of any group.
fn inAnyGroup(self: *const App, id: poltergeistpkg.Bus.Id) bool {
    var it = self.chat.groups.iterator();
    while (it.next()) |kv| {
        if (self.chat.isMember(kv.key_ptr.*, id)) return true;
    }
    return false;
}

/// Raise the operating system's notification from `from`'s window and say
/// what became of it. Never fails: a notification that could not be raised
/// is an answer, not an error.
fn raiseSystemNotification(
    self: *App,
    from: poltergeistpkg.Bus.Id,
    title: []const u8,
    body: []const u8,
) poltergeistpkg.notify.System {
    // A caller that is not a terminal carries `Bus.not_a_terminal`, which no
    // surface is ever given, so it is simply not found.
    const surface = self.findSurfaceByID(from) orelse return .no_terminal;
    const title_z = self.alloc.dupeZ(u8, title) catch return .not_taken;
    defer self.alloc.free(title_z);
    const body_z = self.alloc.dupeZ(u8, body) catch return .not_taken;
    defer self.alloc.free(body_z);
    const raised = surface.raiseDesktopNotification(title_z, body_z) catch |err| {
        log.warn("poltergeist: could not raise a system notification err={}", .{err});
        return .not_taken;
    };
    return poltergeistpkg.notify.System.ofRaised(raised);
}

/// The plugin half of `notifyUser`: who subscribed, whether the hour allows
/// it, and how many of them are up. A sentence the caller owns.
fn notifyPlugins(
    self: *App,
    alloc: Allocator,
    reason: poltergeistpkg.notify.Reason,
    title: []const u8,
    body: []const u8,
    id: poltergeistpkg.Bus.Id,
) anyerror![]const u8 {
    var name_buf: [256]u8 = undefined;
    var name_fixed: std.heap.FixedBufferAllocator = .init(&name_buf);
    const terminal_name = if (id != 0)
        self.chatMemberTitle(name_fixed.allocator(), id) catch ""
    else
        "";

    const event: poltergeistpkg.notify.Event = .{
        .reason = reason,
        .title = title,
        .body = body,
        .terminal = id,
        .terminal_name = terminal_name,
        .at_ms = self.poltergeistWallMs(),
    };

    switch (poltergeistpkg.notify.decide(
        event,
        self.poltergeist_notify_window,
        localMinuteNow(),

        // The plugins that subscribed to this, and nothing else. There is
        // no kind to count any more, so there is no list of kinds to forget
        // one from: a plugin is a notification channel exactly when its own
        // manifest asked for `terminal.quiet`.
        poltergeistpkg.notify.count(self.poltergeist_plugins, .terminal_quiet),
    )) {
        .nowhere_to_send => return alloc.dupe(
            u8,
            "nobody was told: no notification plugin is switched on. " ++
                "Set \"enabled\" in a plugin's file under " ++
                "$XDG_CONFIG_HOME/polter/plugins/, or handle this yourself.",
        ),

        .leave_to_supervisor => return alloc.dupe(
            u8,
            "not sent: outside the hours the user allows for questions " ++
                "like this. Decide it yourself and say so in the group.",
        ),

        .tell => {},
    }

    self.poltergeist_feed.publish(poltergeistpkg.notify.published(event));

    // **What the supervisor is told changed here, and it is a real loss.**
    // A one-shot notifier was forked, and its exit code said whether the
    // message went out; the answer could be "sent through 2 of 3". A
    // resident one is handed the event and answers on its own thread, some
    // time after this call has returned, so nothing here can wait for that
    // without putting the app thread behind somebody's webhook.
    //
    // What is said instead is what *is* known at this instant, and it is
    // not nothing: how many channels asked for this event, and how many of
    // them have a child that is currently up. A plugin that is backing off
    // or dormant is precisely the one whose message is not going anywhere,
    // and that is the fact the supervisor needed the exit code for.
    var running: usize = 0;
    for (self.poltergeist_residents.items) |r| {
        if (!self.pluginSubscribes(r.key, .terminal_quiet)) continue;
        switch (r.status().state) {
            .starting, .feeding => running += 1,
            .backing_off, .dormant, .stopped => {},
        }
    }

    const channels = poltergeistpkg.notify.count(
        self.poltergeist_plugins,
        .terminal_quiet,
    );

    if (running == 0) return std.fmt.allocPrint(
        alloc,
        "handed to {d} channel(s), and none of them has a plugin running right now " ++
            "-- they are backing off or dormant, and plugin_list says which. Do not " ++
            "wait for an answer.",
        .{channels},
    );

    return std.fmt.allocPrint(
        alloc,
        "handed to {d} of {d} channel(s) that are running. They deliver on their own " ++
            "threads, so this is not a delivery receipt; plugin_list says how each is " ++
            "getting on.",
        .{ running, channels },
    );
}

/// Whether the plugin called `key` subscribed to `e`.
///
/// Asked of the manifest list rather than of the resident, because the
/// resident's copy of `wants` is its own and this is the list the user's
/// files produced. They agree; asking the one that can be re-read is what
/// keeps them agreeing.
fn pluginSubscribes(
    self: *const App,
    key: []const u8,
    e: poltergeistpkg.Plugin.Event,
) bool {
    for (self.poltergeist_plugins) |m| {
        if (!std.mem.eql(u8, m.key, key)) continue;
        return m.wants.subscribes(e);
    }
    return false;
}

/// Minutes since local midnight.
fn localMinuteNow() u16 {
    const wall: std.Io.Timestamp = .now(global.io(), .real);
    const secs: i64 = @intCast(@divTrunc(wall.nanoseconds, std.time.ns_per_s));

    var tm: internal_os.Tm = undefined;
    if (internal_os.localtime_r(&secs, &tm) == null) return 0;

    const h: u16 = @intCast(@mod(tm.hour, 24));
    const m: u16 = @intCast(@mod(tm.min, 60));
    return h * 60 + m;
}

/// A plugin's configured parameters, from its own JSON file.
fn pluginParams(
    ctx: *anyopaque,
    alloc: Allocator,
    key: []const u8,
) anyerror![]const poltergeistpkg.Plugin.Param {
    const self: *App = @ptrCast(@alignCast(ctx));

    const io = global.io();
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    return self.pluginSettings(alloc, io, &environ_map, key).params;
}

/// Hand back last night's arrangement, as it was written down.
///
/// Verbatim, unparsed. The program has no use for it -- it is material for
/// the supervisor to read and act on, and re-encoding it here would only
/// add a place for the two shapes to drift apart.
fn sessionRecall(ctx: *anyopaque, alloc: Allocator) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    return alloc.dupe(u8, self.poltergeist_recall.text());
}

/// The path `saveSession` writes, for `polter +chat` to read (#1524).
fn sessionFile(ctx: *anyopaque, alloc: Allocator) anyerror!?[]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const path = self.poltergeist_session_path orelse return null;
    return try alloc.dupe(u8, path);
}

/// Say what a group is for.
fn chatSetBrief(
    ctx: *anyopaque,
    group: []const u8,
    text: []const u8,
) anyerror!poltergeistpkg.Chat.Kept {
    const self: *App = @ptrCast(@alignCast(ctx));
    const kept = try self.chat.setBrief(group, text);

    // Taken back out of the chat rather than written from `text`, so what
    // lands on disk is what the chat actually kept -- trimmed, and cut to
    // the length it enforces.
    if (self.group_log) |*l| l.note(group, self.chat.briefOf(group) catch text);

    self.saveSession();

    // Handed straight back: whether it all fitted is not this layer's to
    // interpret, and the sentence the writer reads is built where the
    // reply is written.
    return kept;
}

/// The groups a terminal may see, each with that group's note.
///
/// `all` widens the listing past this terminal's own memberships. It does
/// not decide whether the note comes along -- see the vtable for what that
/// conflation cost.
fn chatGroupInfo(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
    all: bool,
) anyerror![]poltergeistpkg.rpc.ChatGroupInfo {
    const self: *App = @ptrCast(@alignCast(ctx));

    const live = try self.liveTerminals(alloc);
    defer alloc.free(live);

    // `all` is about the listing only. The brief comes back for every
    // group in it, to whoever can see the group: a brief the members
    // cannot read is a briefing that was never delivered, and it looks
    // delivered from where it was written.
    const names = try self.chat.groupsSeenBy(alloc, id, live, all);
    defer alloc.free(names);

    const out = try alloc.alloc(poltergeistpkg.rpc.ChatGroupInfo, names.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |g| {
            alloc.free(g.name);
            if (g.brief.len > 0) alloc.free(g.brief);
        }
        alloc.free(out);
    }

    for (names, 0..) |n, i| {
        // Copied for the same reason as above: the reply is written after
        // this returns, and the chat can move underneath it.
        const brief = brief: {
            const b = self.chat.briefOf(n) catch "";
            break :brief if (b.len > 0) try alloc.dupe(u8, b) else "";
        };
        const joined = self.chat.hasMember(n, id);

        out[i] = .{ .name = try alloc.dupe(u8, n), .brief = brief, .joined = joined };
        filled += 1;
    }
    return out;
}

/// Who is in a group, each named the way a person can find them.
fn chatMembers(
    ctx: *anyopaque,
    alloc: Allocator,
    group: []const u8,
) anyerror![]const poltergeistpkg.rpc.ChatMember {
    const self: *App = @ptrCast(@alignCast(ctx));

    const ids = try self.chat.membersOf(alloc, group);
    defer alloc.free(ids);

    const out = try alloc.alloc(poltergeistpkg.rpc.ChatMember, ids.len);
    var named: usize = 0;
    errdefer {
        for (out[0..named]) |m| alloc.free(m.title);
        alloc.free(out);
    }

    for (ids, 0..) |id, i| {
        out[i] = .{ .id = id, .title = try self.chatMemberTitle(alloc, id) };
        named += 1;
    }
    return out;
}

/// What to call a terminal where a person will read it.
///
/// Its tab title first, so the name in the chat and the name on the tab are
/// the same string and a reader can tell which window a message came from.
/// An id cannot be matched against anything on screen, so it is the last
/// resort rather than the obvious answer.
///
/// A terminal only has a title once the program in it sets one. Agent CLIs
/// do; a bare shell sitting at a prompt may not, and then the directory it
/// is in says far more about which window it is than sixteen hex digits.
///
/// **Polter itself is neither the person nor a terminal** and has a name of
/// its own (task 2156 v5, `Chat.polter_id`). Before this, a control-room
/// sentence went in under `user_id` and the group showed it as the person
/// speaking; there is no terminal to look up, so without this branch it
/// would have come out as `0xffffffffffffffff`.
fn chatMemberTitle(
    self: *App,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
) Allocator.Error![]const u8 {
    if (id == poltergeistpkg.Chat.user_id) return alloc.dupe(u8, "you");
    if (id == poltergeistpkg.Chat.polter_id) return alloc.dupe(u8, "Polter");

    const surface = self.findSurfaceByID(id) orelse
        return std.fmt.allocPrint(alloc, "0x{x:0>16}", .{id});

    if (surface.rt_surface.getTitle()) |title| {
        if (title.len > 0) return alloc.dupe(u8, title);
    }

    if (surface.pwd(alloc) catch null) |dir| {
        defer alloc.free(dir);
        if (dir.len > 0) {
            const base = std.fs.path.basename(dir);
            return alloc.dupe(u8, if (base.len > 0) base else dir);
        }
    }

    return std.fmt.allocPrint(alloc, "0x{x:0>16}", .{id});
}

fn chatRead(
    ctx: *anyopaque,
    alloc: Allocator,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
    since: ?u64,
    scope: poltergeistpkg.Chat.Scope,
) anyerror!poltergeistpkg.rpc.ChatBatch {
    const self: *App = @ptrCast(@alignCast(ctx));

    // **The budget is handed down rather than applied up here**, because
    // whoever cuts the batch is the one that may say what has been seen.
    // See `Chat.Budget`, and task 579 for what the two being separate cost.
    const batch = try self.chat.read(alloc, group, id, since, .{
        .bytes = poltergeistpkg.rpc.read_budget_bytes,
        .per_line = poltergeistpkg.rpc.read_line_overhead_bytes,
    }, scope);
    const messages = batch.messages;
    defer alloc.free(messages);

    const out = try alloc.alloc(poltergeistpkg.rpc.ChatLine, messages.len);
    errdefer alloc.free(out);

    for (messages, 0..) |m, i| {
        // Copied for the same reason: the log trims itself as it grows.
        out[i] = .{
            .seq = m.seq,
            .log_seq = m.log_seq,
            .from = m.from,
            .author = try self.chatMemberTitle(alloc, m.from),

            // Already the wall clock: a message is stamped when it is
            // posted, from the real clock, so there is nothing to convert.
            .at_ms = @intCast(m.at_ms),

            .summary = m.summary,
            .text = try alloc.dupe(u8, m.text),
        };
    }

    return .{ .lines = out, .more = batch.more };
}

/// Read further back than the group still holds, out of the log on disk.
/// `record_*` and `log_*`: who the caller is, as `RecordTools` needs it,
/// and the state directory. The rule is all `RecordTools`'s.
fn recordTool(
    ctx: *anyopaque,
    alloc: Allocator,
    caller: poltergeistpkg.Bus.Id,
    req: poltergeistpkg.rpc.Request,
) anyerror!poltergeistpkg.RecordTools.Answer {
    const self: *App = @ptrCast(@alignCast(ctx));
    const Tools = poltergeistpkg.RecordTools;
    const state_dir = self.sweep_state_dir orelse self.poltergeist_state_dir orelse return error.LogsClosed;
    const io = global.io();

    // The groups the caller supervises now, and their projects.
    var supervises: std.ArrayListUnmanaged([]const u8) = .empty;
    var projects: std.ArrayListUnmanaged([]const u8) = .empty;
    if (self.poltergeist.isSupervisor(caller)) {
        var it = self.chat.groups.iterator();
        while (it.next()) |kv| {
            if (!self.chat.isMember(kv.key_ptr.*, caller)) continue;
            try supervises.append(alloc, try alloc.dupe(u8, kv.key_ptr.*));
            switch (self.chat.projectOf(kv.key_ptr.*)) {
                .bound => |name| try projects.append(alloc, try alloc.dupe(u8, name)),
                .undecided, .declined => {},
            }
        }
    }
    const access: Tools.Access = .{ .caller = caller, .supervises = supervises.items, .projects = projects.items };

    return switch (req) {
        .record_list => |p| blk: {
            const scope = recordScope(p.group, p.project, p.task, p.terminal, p.session_id) orelse break :blk tooManyScopes();
            break :blk try Tools.list(alloc, io, state_dir, access, .{
                .scope = scope,
                .since_ms = p.since_ms,
                .until_ms = p.until_ms,
                .cursor = p.cursor,
                .limit = p.limit,
            });
        },
        .record_search => |p| blk: {
            const scope = recordScope(p.group, p.project, p.task, p.terminal, p.session_id) orelse break :blk tooManyScopes();
            break :blk try Tools.search(alloc, io, state_dir, access, .{
                .scope = scope,
                .query = p.query,
                .since_ms = p.since_ms,
                .until_ms = p.until_ms,
                .after_file = p.after_file,
                .after_line = p.after_line,
            });
        },
        .record_read => |p| try Tools.read(alloc, io, state_dir, access, .{
            .terminal = p.terminal,
            .day = p.day,
            .part = p.part,
            .from_line = p.from_line,
            .limit = p.limit,
        }),
        .log_list => try Tools.logList(alloc, io, state_dir),
        .log_read => |p| try Tools.logRead(alloc, io, state_dir, .{
            .name = p.name,
            .from_line = p.from_line,
            .limit = p.limit,
        }),
        else => unreachable,
    };
}

/// Which one thing a look back is about; null when it named more than one.
fn recordScope(group: []const u8, project: []const u8, task: u64, who: ?poltergeistpkg.Bus.Id, session_id: []const u8) ?poltergeistpkg.RecordTools.Scope {
    var n: usize = 0;
    var scope: poltergeistpkg.RecordTools.Scope = .mine;
    if (group.len > 0) {
        n += 1;
        scope = .{ .group = group };
    }
    if (project.len > 0) {
        n += 1;
        scope = .{ .project = project };
    }
    if (task != 0) {
        n += 1;
        scope = .{ .task = task };
    }
    if (who) |t| {
        n += 1;
        scope = .{ .terminal = t };
    }
    if (session_id.len > 0) {
        n += 1;
        scope = .{ .session = session_id };
    }
    return if (n > 1) null else scope;
}

test "record tools: one scope or none, never two" {
    try std.testing.expect(recordScope("", "", 0, null, "").? == .mine);
    try std.testing.expectEqualStrings("build", recordScope("build", "", 0, null, "").?.group);
    try std.testing.expectEqual(@as(u64, 7), recordScope("", "", 7, null, "").?.task);
    try std.testing.expect(recordScope("build", "", 7, null, "") == null);
    try std.testing.expect(recordScope("", "p", 0, 0x11, "") == null);
}

fn tooManyScopes() poltergeistpkg.RecordTools.Answer {
    return .{ .refused = .{
        .code = "BadParams",
        .message = "name one of group, project, task, terminal or session_id -- or none, for your own record.",
    } };
}

fn chatHistory(
    ctx: *anyopaque,
    alloc: Allocator,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
    before_seq: u64,
    limit: usize,
    filter: poltergeistpkg.rpc.ChatFilter,
    scope: poltergeistpkg.Chat.Scope,
) anyerror!poltergeistpkg.rpc.ChatPage {
    const self: *App = @ptrCast(@alignCast(ctx));

    // One question, not two. Whether this terminal is in the group and how
    // far back it may look are the same fact, and asking only the first
    // would hand a terminal added with `history: none` exactly what it was
    // added not to see. `NoSuchGroup` and `NotAMember` travel up as they
    // are; the tool surface turns them into sentences an agent can act on.
    const floor = try self.chat.floorOf(group, id);

    // No log on disk, so there is nothing behind the group to page back
    // into.
    const l = if (self.chat_log) |*v| v else {
        if (self.poltergeist_log_problem != null) return error.LogsClosed;
        return .{ .lines = &.{}, .more = false };
    };

    // This member was kept out of something, but nothing says which line
    // on disk that bar sits at -- the messages predate the log, or were
    // never written down. Since the bound cannot be proved, give less
    // rather than risk giving more.
    //
    // `barred` and not `floor.seq > 0`: a compaction raises the floor of a
    // member that was kept out of nothing, so the seq alone would read a
    // whole group as barred the first time its supervisor compacted -- and
    // shut off the one tool that reaches what the compaction took away.
    if (floor.barred and floor.log_seq == 0) return .{ .lines = &.{}, .more = false };

    const page = try l.history(alloc, group, before_seq, limit, filter, scope);

    // Entries come back oldest first, so anything barred is a prefix.
    var k: usize = 0;
    while (k < page.entries.len and page.entries[k].seq <= floor.log_seq) k += 1;
    const visible = page.entries[k..];

    const out = try alloc.alloc(poltergeistpkg.rpc.ChatLine, visible.len);
    for (visible, 0..) |e, i| {
        out[i] = .{
            // The log never recorded the group's own count. Inventing one
            // would be handed straight back as `group_compact`'s `through`,
            // which counts something else entirely.
            .seq = 0,
            .log_seq = e.seq,
            .from = e.from,

            // The name the log recorded, not what the tab says now: the
            // terminal that spoke is very likely closed, and the record is
            // the only place that name still exists.
            .author = e.author,

            // Wall-clock, as it was written. The live log is stamped the
            // same way now, so history and memory read alike.
            .at_ms = e.at_ms,

            .summary = e.summary,
            .text = e.text,
        };
    }

    // Once anything was filtered out, everything older is barred too, so
    // there is nothing further to offer this member.
    return .{ .lines = out, .more = if (k > 0) false else !page.exhausted };
}

/// Tell every terminal that has messages waiting that it has them.
///
/// A count and how to fetch, never the messages themselves. What an agent
/// does about it is its own decision, and one it can decline.
fn tellTerminalsAboutMessages(self: *App) void {
    const now_ms = self.poltergeistElapsedMs();

    // Worked out once for the whole sweep rather than per surface: it is
    // the same answer every time round, and the list does not move while
    // this runs.
    const live = self.liveTerminals(self.alloc) catch return;
    defer self.alloc.free(live);

    for (self.surfaces.items) |rt_surface| {
        const surface = rt_surface.core();

        const names = self.chat.groupsFor(self.alloc, surface.id, live) catch continue;
        defer self.alloc.free(names);

        // **A terminal somebody is minding is not the group's to
        // interrupt.** Its supervisor directs it by typing into its input
        // box, which is a channel a notice cannot compete with; three
        // workers reporting used to interrupt all three, and none of them
        // needed to know what the others were doing.
        //
        // Asked of the *reader's* mark rather than of who spoke, so there
        // is one rule and no special case for the person at the keyboard:
        // the user carries no mark, is minded by nobody, and is told.
        // A terminal with no mark is told for the same reason -- nobody is
        // directing it, so the group is the only channel it has.
        // **The whole standing, not one bit of it.** This was
        // `roleOf(...) == .watched`, which put "minded" on one side and
        // *everything else* on the other -- so releasing a worker moved it
        // into the told bucket and its notices came back on (task 413). The
        // rule is `Chat.waking`'s to state; this hands over the answer it
        // needs and nothing more.
        const role = self.poltergeist.roleOf(surface.id);

        for (names) |name| {
            // Still the whole count, deliberately. Not being woken is not
            // being kept out: whatever this terminal has waiting is what
            // `group_read` will hand it, and the notice says so honestly.
            //
            // **Only what this terminal may read**: a notice that counted a
            // squad's channel for somebody outside it would tell them a
            // number that `group_read` can never account for.
            var scope_arena: std.heap.ArenaAllocator = .init(self.alloc);
            defer scope_arena.deinit();
            const notice = self.poltergeistHost().noticeFor(scope_arena.allocator(), &self.poltergeist, &self.chat, name, surface.id);
            const scope = notice.scope;
            const count = notice.count;
            if (count == 0) continue;
            if (!self.chat.shouldNotify(
                name,
                surface.id,
                now_ms,
                chat_notice_gap_ms,
                role,
                scope,
            )) {
                // Told too recently, with something still waiting: this
                // sweep only runs when somebody posts, so without coming
                // back the message that arrived inside the gap is never
                // announced at all.
                if (self.chat.notifyWaitMs(name, surface.id, now_ms, chat_notice_gap_ms, role, scope)) |ms| {
                    self.noticeRetryIn(ms + chat_notice_retry_margin_ms);
                }
                continue;
            }

            var buf: [255:0]u8 = undefined;
            const line = poltergeistpkg.Chat.formatNotice(name, count, &buf) catch
                continue;
            buf[line.len] = 0;

            self.surfaceMessage(surface, self.noticeFor(surface.id, buf)) catch |err| {
                log.warn("poltergeist: could not deliver a message notice err={}", .{err});
            };
        }
    }
}

/// Tell a terminal something about its own standing.
///
/// **Because a role nobody is told about is a role nobody plays.** Making a
/// terminal the supervisor used to set a flag in the bus and nothing else:
/// the agent inside it was never told, so it had no reason to look for the
/// `supervising` skill or the group tools, and it reached for whatever
/// messaging its own runtime advertised instead. Watched in one place,
/// working in another, and no record either would survive a restart.
///
/// Delivered through the ordinary notice path, so it inherits the guard
/// against interrupting somebody mid-sentence and simply does not arrive
/// if the person is typing.
pub fn tellSurface(self: *App, id: poltergeistpkg.Bus.Id, text: []const u8) void {
    const surface = self.findSurfaceByID(id) orelse return;

    var buf: [255:0]u8 = undefined;
    if (text.len >= buf.len) return;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;

    const msg = self.noticeFor(id, buf);
    self.surfaceMessage(surface, msg) catch |err| {
        log.warn("poltergeist: could not tell a terminal its standing err={}", .{err});
    };
    // Refused for a reason that clears -- a key, a draft, a permission box
    // (`Surface.typePoltergeistNotice` sets the flag only then): said once
    // it has, rather than never (task 1682). The refusal set its own wake.
    if (msg == .poltergeist_notice and surface.poltergeist_notice_refused) {
        self.owed_tells.owe(id, text) catch |err| {
            log.warn("poltergeist: could not keep a refused standing line err={}", .{err});
        };
    }
}

/// Type the standing lines that were refused (`owed_tells`), each once.
fn payOwedTells(self: *App) void {
    self.owed_tells.pay(self, owedTellTry);
}

fn owedTellTry(self: *App, id: poltergeistpkg.Bus.Id, line: []const u8) poltergeistpkg.OwedTells.Outcome {
    const surface = self.findSurfaceByID(id) orelse return .gone;
    if (!self.agentPresent(id)) return .gone;
    const typed = surface.typePoltergeistNotice(line) catch return .gone;
    if (typed) {
        log.info("poltergeist: standing line typed on retry id={x}", .{id});
        return .typed;
    }
    return if (surface.poltergeist_notice_refused) .refused else .gone;
}

/// Whether an agent is listening in this terminal right now.
///
/// `false` when Poltergeist's server is not running: there is then no
/// socket for a sidecar to be on, so no terminal can have an agent
/// reachable through one. It is also the safe answer -- see `noticeFor`.
pub fn agentPresent(self: *App, id: poltergeistpkg.Bus.Id) bool {
    if (self.poltergeist_server) |*srv| return srv.agentPresent(id);
    return false;
}

/// `agentPresent` as `Alarms.Presence` asks it (task 2411).
fn presenceIn(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.agentPresent(id);
}

/// Pick how a line reaches a terminal: typed at whatever is running there,
/// or printed on the screen for the person.
///
/// # The defect this exists for
///
/// Every notice was typed into the pty, as if the user had typed it, and
/// with a return after it. In a terminal running an agent that is right --
/// it is how the agent is told anything. **In a terminal running a bare
/// shell, the shell ran it.** Three terminals in one session answered a
/// task notification with
/// `expression or statement contains unexpected token "Task"`, in red, on
/// the user's screen.
///
/// # Why this test and not the obvious one
///
/// `typePoltergeistText` already reads bracketed-paste mode, and the
/// tempting move is to reuse it. Two reasons not to. It is consulted only
/// for multi-line text, and every line here is one line, so it never had a
/// say. And it would not have helped: bracketed paste frames a paste, it
/// does not stop the return that follows, so a shell with the mode on runs
/// the line just the same. A live MCP connection is the only signal a bare
/// shell cannot produce.
///
/// **Printing is the safe answer**, which is why anything unknown lands
/// there: a line printed to somebody running an agent is a line that agent
/// does not read, and a line typed at a shell is a command it runs.
fn noticeFor(
    self: *App,
    id: poltergeistpkg.Bus.Id,
    buf: [255:0]u8,
) apprt.surface.Message {
    const agent_here = self.agentPresent(id);
    // The first of the two answers a notice gets; the second is asked when
    // it is typed (`Surface.typePoltergeistNotice`). Both logged (#1534).
    log.info("poltergeist: notice queued id={x} agent_present={} -> {s}", .{
        id,
        agent_here,
        if (agent_here) "to type" else "to print",
    });
    return if (agent_here)
        .{ .poltergeist_notice = buf }
    else
        .{ .poltergeist_alert = buf };
}

/// How long this app has been awake, in milliseconds. **A duration, never
/// a time of day.**
///
/// `.awake` excludes time the machine is suspended, which is exactly right
/// for the thing this measures: a laptop shut overnight has not left its
/// terminals "still for eight hours", and quiescence, the notice interval
/// and every rate limit here are asking "how long since", not "when".
///
/// **It is not a clock you can turn into a timestamp.** There used to be a
/// paired `poltergeist_epoch_wall_ms` here, and a wall time was recovered
/// as epoch + this. That is wrong by however long the machine has slept
/// since Polter started, it only ever grows, and it was silent: on the
/// machine this was found on, a chat message sent after a lid had been
/// closed for two hours was stamped, filed and displayed two hours early,
/// and the day file for the following day was never opened because the
/// clock had not reached midnight. Anything that needs a time of day calls
/// `poltergeistWallMs`, which reads the real clock. The field is gone so
/// that the arithmetic cannot be written again.
pub fn poltergeistElapsedMs(self: *App) u64 {
    const epoch = self.poltergeist_epoch orelse epoch: {
        const t: std.Io.Timestamp = .now(global.io(), .awake);
        self.poltergeist_epoch = t;
        break :epoch t;
    };
    const now: std.Io.Timestamp = .now(global.io(), .awake);
    return @intCast(std.math.clamp(
        epoch.durationTo(now).toMilliseconds(),
        0,
        std.math.maxInt(i64),
    ));
}

/// The wall clock, in milliseconds, for anything that is a time of day:
/// when a message was sent, which local day a record is filed under, what
/// a notification says happened when.
///
/// Read at the moment of stamping rather than derived from anything, so
/// that suspending the machine cannot put it behind. It can step backwards
/// when the system clock is corrected, which is what every chat program
/// lives with: ordering here is by `seq`, never by time.
pub fn poltergeistWallMs(self: *App) i64 {
    _ = self;
    return poltergeistpkg.daylog.nowMs(global.io());
}

/// Load a skill, preferring the user's copy.
///
/// The user layer is checked first so that editing a file is how you change
/// what a supervisor does, without touching the install and without the
/// change being undone by the next upgrade. Which copy that is, is
/// `skill_store.resolve`'s to say -- the same answer the provisioning
/// plugins are handed.
fn poltergeistSkill(
    ctx: *anyopaque,
    alloc: Allocator,
    name: []const u8,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const dirs = self.skillDirs();
    defer if (dirs.config_root) |d| self.alloc.free(d);
    return poltergeistpkg.skill_store.readBody(alloc, global.io(), name, dirs.config_root, dirs.resources);
}

const SkillDirs = struct {
    /// The configuration root (`~/.config`), owned; null when not found.
    config_root: ?[]u8,
    /// The app-visible resources: this runs inside Ghostty, not in a
    /// sandboxed host.
    resources: ?[]const u8,
};

fn skillDirs(self: *App) SkillDirs {
    const resources = global.resourcesDir().app();
    var environ_map = global.environMap() catch return .{ .config_root = null, .resources = resources };
    defer environ_map.deinit();
    return .{
        .config_root = internal_os.xdg.config(global.io(), self.alloc, &environ_map, .{}) catch null,
        .resources = resources,
    };
}

/// Every skill Polter ships, with its text and where it stands against the
/// person's copy, as JSON for the role library.
pub fn officialSkillsJson(self: *App, alloc: Allocator) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const dirs = self.skillDirs();
    defer if (dirs.config_root) |d| self.alloc.free(d);
    const path = try poltergeistpkg.PersonaStore.defaultPath(aa);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try poltergeistpkg.skill_store.writeCatalogJson(
        &out.writer,
        aa,
        global.io(),
        dirs.config_root,
        dirs.resources,
        poltergeistpkg.PersonaStore.readOverrides(aa, global.io(), path),
    );
    return try out.toOwnedSlice();
}

/// Save the person's copy of a shipped skill. The role library only: no
/// agent reaches this.
pub fn putOfficialSkill(self: *App, name: []const u8, text: []const u8) !void {
    const dirs = self.skillDirs();
    defer if (dirs.config_root) |d| self.alloc.free(d);
    const path = try poltergeistpkg.PersonaStore.defaultPath(self.alloc);
    defer self.alloc.free(path);
    try poltergeistpkg.skill_store.put(self.alloc, global.io(), name, text, dirs.config_root, dirs.resources, path);
    self.skillsChanged();
}

/// Put a shipped skill back to the shipped text.
pub fn restoreOfficialSkill(self: *App, name: []const u8) !void {
    const dirs = self.skillDirs();
    defer if (dirs.config_root) |d| self.alloc.free(d);
    const path = try poltergeistpkg.PersonaStore.defaultPath(self.alloc);
    defer self.alloc.free(path);
    try poltergeistpkg.skill_store.restore(self.alloc, global.io(), name, dirs.config_root, path);
    self.skillsChanged();
}

/// "Keep mine" on a shipped skill the official text has moved under
/// (`skill_store.acknowledge`). The text in use does not change, so nobody
/// is told again.
pub fn acknowledgeOfficialSkill(self: *App, name: []const u8) !void {
    const dirs = self.skillDirs();
    defer if (dirs.config_root) |d| self.alloc.free(d);
    const path = try poltergeistpkg.PersonaStore.defaultPath(self.alloc);
    defer self.alloc.free(path);
    try poltergeistpkg.skill_store.acknowledge(self.alloc, global.io(), name, dirs.config_root, dirs.resources, path);
}

/// After a skill's text changed. `skill_read` reads the file each time and
/// needs nothing; the copies the agent CLIs keep are the plugins' to
/// rewrite, so they are told again -- when they were told the first time.
fn skillsChanged(self: *App) void {
    if (self.poltergeist_registered) _ = self.publishProvision(null);
}

fn poltergeistThreshold(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    ms: u64,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.NoSuchTerminal;
    surface.setPoltergeistThreshold(ms);
}

pub fn addSurface(
    self: *App,
    rt_surface: *apprt.Surface,
) Allocator.Error!void {
    try self.surfaces.append(self.alloc, rt_surface);
    self.controlRoomTouch();

    // Deliberately not registering with the Poltergeist bus here. Both
    // apprts call this *before* the core surface exists -- GTK's `core()`
    // unwraps a null and embedded's is still `undefined` -- so there is no
    // id to read yet. The bus registers a terminal the first time it is
    // named as supervisor or put under watch, which is the only point at
    // which it needs to know about it anyway.

    // Since we have non-zero surfaces, we can cancel the quit timer.
    // It is up to the apprt if there is a quit timer at all and if it
    // should be canceled.
    _ = rt_surface.rtApp().performAction(
        .app,
        .quit_timer,
        .stop,
    ) catch |err| {
        log.warn("error stopping quit timer err={}", .{err});
    };
}

/// Delete the surface from the known surface list. This will NOT call the
/// destructor or free the memory.
pub fn deleteSurface(self: *App, rt_surface: *apprt.Surface) void {
    // If this surface is the focused surface then we need to clear it.
    // There was a bug where we relied on hasSurface to return false and
    // just let focused surface be but the allocator was reusing addresses
    // after free and giving false positives, so we must clear it.
    if (self.focused_surface) |focused| {
        if (focused == rt_surface.core()) {
            self.focused_surface = null;
        }
    }

    var i: usize = 0;
    while (i < self.surfaces.items.len) {
        if (self.surfaces.items[i] == rt_surface) {
            _ = self.surfaces.swapRemove(i);
            // Gone: a terminal that is given this id later is another one.
            self.projects.forget(poltergeistpkg.Bus.idOf(rt_surface.core()));
            self.seat_judged.gone(poltergeistpkg.Bus.idOf(rt_surface.core()));
            if (self.launch_groups.fetchRemove(poltergeistpkg.Bus.idOf(rt_surface.core()))) |kv| self.alloc.free(kv.value);
            _ = self.launching.remove(poltergeistpkg.Bus.idOf(rt_surface.core()));
            self.historyPaneGone(poltergeistpkg.Bus.idOf(rt_surface.core()));
            self.controlRoomTouch();
            continue;
        }

        i += 1;
    }

    // If we have no surfaces, we can start the quit timer. It is up to the
    // apprt to determine if this is necessary.
    if (self.surfaces.items.len == 0) _ = rt_surface.rtApp().performAction(
        .app,
        .quit_timer,
        .start,
    ) catch |err| {
        log.warn("error starting quit timer err={}", .{err});
    };
}

/// The last focused surface. This is only valid while on the main thread
/// before tick is called.
pub fn focusedSurface(self: *const App) ?*Surface {
    const surface = self.focused_surface orelse return null;
    if (!self.hasSurface(surface)) return null;
    return surface;
}

/// Returns true if confirmation is needed to quit the app. It is up to
/// the apprt to call this.
pub fn needsConfirmQuit(self: *const App) bool {
    for (self.surfaces.items) |v| {
        if (v.core().needsConfirmQuit()) return true;
    }

    return false;
}

/// How often the stall watch looks at the app thread.
const stall_watch_every_ms = 250;

/// What the stall watch calls a mailbox message: its tag, and for an
/// agent's request the method and the terminal. All static or plain values,
/// so the app thread copies nothing to say it.
fn stallLabel(message: Message) poltergeistpkg.StallWatch.Label {
    return switch (message) {
        inline else => |_, tag| .{ .kind = @tagName(tag) },
    };
}

/// What the stall watch calls an agent's request: the method and the
/// terminal. Its kind is still `poltergeist_request`, the name it had as a
/// mailbox message, so a log read before and after task 1730 says the same.
fn requestStallLabel(p: *const poltergeistpkg.Server.Pending) poltergeistpkg.StallWatch.Label {
    return .{
        .kind = "poltergeist_request",
        .method = @tagName(p.request),
        .caller = p.caller.terminalId() orelse 0,
    };
}

/// Drain the agents' requests (task 1730), one item each for the stall watch.
fn drainPoltergeistRequests(self: *App) void {
    const Handle = struct {
        fn handle(app: *App, p: *poltergeistpkg.Server.Pending) void {
            app.poltergeistRequest(p);
        }
    };
    if (drainRequests(&self.poltergeist_requests, &self.stall_watch, self, Handle.handle)) self.control_dirty = true;
}

/// The loop `drainPoltergeistRequests` runs, apart from what answering a
/// request needs of the app -- which a test build cannot compile -- so that
/// it can be run in one: everything in `queue`, each between `begin` and
/// `end` on `watch`, handed to `handle`. Whether there was any.
fn drainRequests(
    queue: *PoltergeistRequests,
    watch: *poltergeistpkg.StallWatch,
    ctx: anytype,
    comptime handle: fn (@TypeOf(ctx), *poltergeistpkg.Server.Pending) void,
) bool {
    var any = false;
    while (queue.pop(global.io())) |p| {
        watch.begin(poltergeistpkg.StallWatch.nowNs(global.io()), requestStallLabel(p));
        defer watch.end(poltergeistpkg.StallWatch.nowNs(global.io()));
        any = true;
        handle(ctx, p);
    }
    return any;
}

/// Drain the mailbox.
fn drainMailbox(self: *App, rt_app: *apprt.App) !void {
    while (self.mailbox.pop(global.io())) |message| {
        // One message, one item for the stall watch (task 1729).
        self.stall_watch.begin(poltergeistpkg.StallWatch.nowNs(global.io()), stallLabel(message));
        defer self.stall_watch.end(poltergeistpkg.StallWatch.nowNs(global.io()));
        // Anything that arrives here may have changed what the control
        // room shows, and working out that it did not is cheaper than a
        // list of which messages can.
        self.control_dirty = true;
        if (comptime std.log.logEnabled(.debug, .app)) {
            switch (message) {
                // these tend to be way too verbose for normal debugging
                else => log.debug("mailbox message={t}", .{message}),
            }
        }
        switch (message) {
            .open_config => |v| try self.performAction(
                rt_app,
                .{
                    .open_config = switch (v) {
                        .os_open => .os_open,
                        .new_window => .new_window,
                    },
                },
            ),
            .new_window => |msg| try self.newWindow(rt_app, msg),
            .close => |surface| self.closeSurface(surface),
            .surface_message => |msg| try self.surfaceMessage(msg.surface, msg.message),
            .poltergeist_report => |msg| self.poltergeistReport(msg.from, msg.event),
            .poltergeist_quiet => |msg| self.poltergeistHeartbeat(msg.from, msg.quiet_ms),
            .poltergeist_sampling => |msg| {
                if (!msg.started) log.warn(
                    "poltergeist: sampling could not start for terminal 0x{x:0>16}; it is marked watched with nothing measuring it",
                    .{msg.from},
                );
                self.poltergeist.noteSampling(msg.from, msg.started, self.poltergeistElapsedMs());
            },
            .poltergeist_alert => |line| self.poltergeistAlert(line),

            // If we're quitting, then we set the quit flag and stop
            // draining the mailbox immediately. This lets us defer
            // mailbox processing to the next tick so that the apprt
            // can try to quit as quickly as possible.
            .quit => {
                log.info("quit message received, short circuiting mailbox drain", .{});
                try self.performAction(rt_app, .quit);
                return;
            },
        }
    }
}

pub fn closeSurface(self: *App, surface: *Surface) void {
    if (!self.hasSurface(surface)) return;
    surface.close();
}

pub fn focusSurface(self: *App, surface: *Surface) void {
    if (!self.hasSurface(surface)) return;
    self.focused_surface = surface;
}

/// Create a new window
pub fn newWindow(self: *App, rt_app: *apprt.App, msg: Message.NewWindow) !void {
    const target: apprt.Target = target: {
        const parent = msg.parent orelse break :target .app;
        if (self.hasSurface(parent)) break :target .{ .surface = parent };
        break :target .app;
    };

    _ = try rt_app.performAction(
        target,
        .new_window,
        {},
    );
}

/// Handle an app-level focus event. This should be called whenever
/// the focus state of the entire app containing Ghostty changes.
/// This is separate from surface focus events. See the `focused`
/// field for more information.
pub fn focusEvent(self: *App, focused: bool) void {
    // Prevent redundant focus events
    if (self.focused == focused) return;

    log.debug("focus event focused={}", .{focused});
    self.focused = focused;
}

/// Handle a key event at the app-scope. If this key event is used,
/// this will return true and the caller shouldn't continue processing
/// the event. If the event is not used, this will return false.
///
/// If the app currently has focus then all key events are processed.
/// If the app does not have focus then only global key events are
/// processed.
pub fn keyEvent(
    self: *App,
    rt_app: *apprt.App,
    event: input.KeyEvent,
) bool {
    switch (event.action) {
        // We don't care about key release events.
        .release => return false,

        // Continue processing key press events.
        .press, .repeat => {},
    }

    // Get the keybind entry for this event. We don't support key sequences
    // so we can look directly in the top-level set.
    const entry = rt_app.config.keybind.set.getEvent(event) orelse return false;
    const leaf: input.Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
        // Sequences aren't supported. Our configuration parser verifies
        // this for global keybinds but we may still get an entry for
        // a non-global keybind.
        .leader => return false,

        // Leaf entries are good
        inline .leaf, .leaf_chained => |leaf| leaf.generic(),
    };
    const actions: []const input.Binding.Action = leaf.actionsSlice();
    assert(actions.len > 0);

    // If we aren't focused, then we only process global keybinds.
    if (!self.focused and !leaf.flags.global) return false;

    // Global keybinds are done using performAll so that they
    // can target all surfaces too.
    if (leaf.flags.global) {
        self.performAllChainedAction(rt_app, actions);
        return true;
    }

    // Must be focused to process non-global keybinds
    assert(self.focused);
    assert(!leaf.flags.global);

    // If we are focused, then we process keybinds only if they are
    // app-scoped. Otherwise, we do nothing. Surface-scoped should
    // be processed by Surface.keyEvent. For chained actions, all
    // actions must be app-scoped.
    for (actions) |action| if (action.scoped(.app) == null) return false;
    for (actions) |action| {
        self.performAction(
            rt_app,
            action.scoped(.app).?,
        ) catch |err| {
            log.warn("error performing app keybind action action={s} err={}", .{
                @tagName(action),
                err,
            });
        };
    }

    return true;
}

/// Call to notify Ghostty that the color scheme for the app has changed.
/// "Color scheme" in this case refers to system themes such as "light/dark".
pub fn colorSchemeEvent(
    self: *App,
    rt_app: *apprt.App,
    scheme: apprt.ColorScheme,
) !void {
    const new_scheme: configpkg.ConditionalState.Theme = switch (scheme) {
        .light => .light,
        .dark => .dark,
    };

    // If our scheme didn't change, then we don't do anything.
    if (self.config_conditional_state.theme == new_scheme) return;

    // Setup our conditional state which has the current color theme.
    self.config_conditional_state.theme = new_scheme;

    // Request our configuration be reloaded because the new scheme may
    // impact the colors of the app.
    _ = try rt_app.performAction(
        .app,
        .reload_config,
        .{ .soft = true },
    );
}

/// Perform a binding action. This only accepts actions that are scoped
/// to the app. Callers can use performAllAction to perform any action
/// and any non-app-scoped actions will be performed on all surfaces.
pub fn performAction(
    self: *App,
    rt_app: *apprt.App,
    action: input.Binding.Action.Scoped(.app),
) !void {
    switch (action) {
        .unbind => unreachable,
        .ignore => {},
        .quit => _ = try rt_app.performAction(.app, .quit, {}),
        .new_window => _ = try self.newWindow(rt_app, .{ .parent = null }),
        .open_config => |v| _ = try rt_app.performAction(
            .app,
            .open_config,
            switch (v) {
                .os_open => .os_open,
                .new_window => .new_window,
            },
        ),
        .reload_config => _ = try rt_app.performAction(.app, .reload_config, .{}),
        .close_all_windows => _ = try rt_app.performAction(.app, .close_all_windows, {}),
        .toggle_quick_terminal => _ = try rt_app.performAction(.app, .toggle_quick_terminal, {}),
        .toggle_visibility => _ = try rt_app.performAction(.app, .toggle_visibility, {}),
        .check_for_updates => _ = try rt_app.performAction(.app, .check_for_updates, {}),
        .screenshot => _ = try rt_app.performAction(.app, .screenshot, {}),
        .poltergeist_toggle_control_room => _ = try rt_app.performAction(.app, .toggle_poltergeist_control_room, {}),
        .show_gtk_inspector => _ = try rt_app.performAction(.app, .show_gtk_inspector, {}),
        .undo => _ = try rt_app.performAction(.app, .undo, {}),

        .redo => _ = try rt_app.performAction(.app, .redo, {}),
    }
}

/// Performs a chained action. We will continue executing each action
/// even if there is a failure in a prior action.
pub fn performAllChainedAction(
    self: *App,
    rt_app: *apprt.App,
    actions: []const input.Binding.Action,
) void {
    for (actions) |action| {
        self.performAllAction(rt_app, action) catch |err| {
            log.warn("error performing chained action action={s} err={}", .{
                @tagName(action),
                err,
            });
        };
    }
}

/// Perform an app-wide binding action. If the action is surface-specific
/// then it will be performed on all surfaces. To perform only app-scoped
/// actions, use performAction.
pub fn performAllAction(
    self: *App,
    rt_app: *apprt.App,
    action: input.Binding.Action,
) !void {
    switch (action.scope()) {
        // App-scoped actions are handled by the app so that they aren't
        // repeated for each surface (since each surface forwards
        // app-scoped actions back up).
        .app => try self.performAction(
            rt_app,
            action.scoped(.app).?, // asserted through the scope match
        ),

        // Surface-scoped actions are performed on all surfaces. Errors
        // are logged but processing continues.
        .surface => for (self.surfaces.items) |surface| {
            _ = surface.core().performBindingAction(action) catch |err| {
                log.warn("error performing binding action on surface id={x} err={}", .{
                    surface.core().id,
                    err,
                });
            };
        },
    }
}

/// Handle a window message
fn surfaceMessage(self: *App, surface: *Surface, msg: apprt.surface.Message) !void {
    // We want to ensure our window is still active. Window messages
    // are quite rare and we normally don't have many windows so we do
    // a simple linear search here.
    if (self.hasSurface(surface)) {
        try surface.handleMessage(msg);
    }

    // Window was not found, it probably quit before we handled the message.
    // Not a problem.
}

fn hasSurface(self: *const App, surface: *const Surface) bool {
    for (self.surfaces.items) |v| {
        if (v.core() == surface) return true;
    }

    return false;
}

/// Search for a surface by a 64 bit unique ID.
pub fn findSurfaceByID(self: *const App, id: u64) ?*Surface {
    // A runtime whose surfaces are not a real app's (`none`, which is what a
    // test build is) has nothing to look in: its `Surface` has no `core`, and
    // a list of them can never hold one. So the answer is here rather than at
    // each caller who happens to be reachable from a test -- Zig analyzes a
    // test's callees, and one that reaches this function used to fail to
    // compile for a reason that had nothing to do with the test.
    if (comptime !@hasDecl(apprt.Surface, "core")) return null;

    for (self.surfaces.items) |v| {
        const surface: *Surface = v.core();
        if (surface.id == id) return surface;
    }

    return null;
}

/// The message types that can be sent to the app thread.
pub const Message = union(enum) {
    // Open the configuration file
    open_config: OpenConfig,

    /// Create a new terminal window.
    new_window: NewWindow,

    /// Close a surface. This notifies the runtime that a surface
    /// should close.
    close: *Surface,

    /// Quit
    quit: void,

    /// A message for a specific surface.
    surface_message: struct {
        surface: *Surface,
        message: apprt.surface.Message,
    },

    /// A surface reporting that its screen has gone quiet, or come back.
    ///
    /// Routed through the app rather than sent surface to surface because
    /// only the app knows who is supervising whom, and because the sending
    /// surface must not learn anything about the receiving one.
    poltergeist_report: struct {
        from: poltergeistpkg.Bus.Id,
        event: poltergeistpkg.Sampler.Event,
    },

    /// A surface restating how long its screen has been unchanged, on a
    /// tick that produced no report.
    ///
    /// Deliberately not a `poltergeist_report`: nobody is told, no round is
    /// counted, no tab is redrawn. It exists because the report stream says
    /// nothing at all while a screen is moving, and the supervisor's figure
    /// is extrapolated from the last thing it was told. See
    /// `Sampler.heartbeat`.
    poltergeist_quiet: struct {
        from: poltergeistpkg.Bus.Id,
        quiet_ms: u64,
    },

    /// A surface's IO thread answering a request to sample it: whether the
    /// sampling is running. Sent for every such request, including the
    /// ones a failed IO thread would otherwise have dropped unread, so
    /// `terminal_list` can say a watch has nothing under it (task 731).
    poltergeist_sampling: struct {
        from: poltergeistpkg.Bus.Id,
        started: bool,
    },

    /// A plugin has stopped working, in a sentence meant for the person.
    ///
    /// Routed through the app because the failure happens on a resident's
    /// own thread and the screen belongs to this one. The line is owned and
    /// is freed once it has been shown or queued.
    poltergeist_alert: []const u8,

    const NewWindow = struct {
        /// The parent surface
        parent: ?*Surface = null,
    };

    pub const OpenConfig = enum {
        /// Open the config in the OS default editor.
        os_open,
        /// Open the config in a new window using $EDITOR or $VISUAL
        new_window,
    };
};

/// Mailbox is the way that other threads send the app thread messages.
/// The queue agents' requests wait in for the app thread (task 1730).
///
/// **Room for every connection there can be.** Each connection to the
/// server is lock-step -- one request, then its answer -- so the live
/// connections' requests are at most `Server.slotCount` of whatever
/// `poltergeist-max-agents` says, and the queue holds that many for any
/// configuration (checked below, at compile time). A request handed back by
/// a worktree job is one whose connection is still waiting on it, so it is
/// not one more.
///
/// ⚠️ **Not quite never full.** Since task 1727 a connection whose client
/// has gone stops waiting and gives its slot up while its request may still
/// be here; a new connection can then take the slot and queue another. Such
/// leftovers pile up only while the app thread is not draining -- a stall --
/// and only as fast as clients go away and come back. A push that finds the
/// queue full anyway does not wait: it is answered `Busy` at once
/// (`submitPoltergeistRequest`), and no terminal is held up either way.
pub const PoltergeistRequests = BlockingQueue(*poltergeistpkg.Server.Pending, poltergeist_request_room);
const poltergeist_request_room = poltergeistpkg.Server.limit_max_connections;
comptime {
    // As many as the largest `poltergeist-max-agents` a config can hold
    // makes slots for -- the setting's own type, through the server's own
    // clamp, so neither can grow past this without this failing to build.
    const most = poltergeistpkg.Server.slotCount(std.math.maxInt(@FieldType(configpkg.Config, "poltergeist-max-agents")));
    if (poltergeist_request_room < most) @compileError("the queue for agents' requests is smaller than the connections there can be");
}

pub const Mailbox = struct {
    /// The type used for sending messages to the app thread.
    pub const Queue = BlockingQueue(Message, 64);

    rt_app: *apprt.App,
    mailbox: *Queue,

    /// Send a message to the surface.
    pub fn push(self: Mailbox, msg: Message, timeout: Queue.Timeout) Queue.Size {
        const result = self.mailbox.push(global.io(), msg, timeout);

        // Wake up our app loop
        self.rt_app.wakeup();

        return result;
    }
};

// Wasm API.
pub const Wasm = if (!builtin.target.isWasm()) struct {} else struct {
    const wasm = @import("os/wasm.zig");
    const alloc = wasm.alloc;

    // export fn app_new(config: *Config) ?*App {
    //     return app_new_(config) catch |err| { log.err("error initializing app err={}", .{err});
    //         return null;
    //     };
    // }
    //
    // fn app_new_(config: *Config) !*App {
    //     const app = try App.create(alloc, config);
    //     errdefer app.destroy();
    //
    //     const result = try alloc.create(App);
    //     result.* = app;
    //     return result;
    // }
    //
    // export fn app_free(ptr: ?*App) void {
    //     if (ptr) |v| {
    //         v.destroy();
    //         alloc.destroy(v);
    //     }
    // }
};

test "task 1600: every terminal id handed to a caller is written as terminal_list writes it" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // A terminal id with a leading zero digit: the one a real machine lost
    // (0x2566… where terminal_list said 0x02566…). Handle 0x1e066b80000.
    const Map = struct {
        fn toId(_: *const anyopaque, handle: u64) ?u64 {
            return if (handle == 0x1e066b80000) 0x02566e9a51296e32 else null;
        }
        fn toSurface(_: *const anyopaque, id: u64) ?u64 {
            return if (id == 0x02566e9a51296e32) 0x1e066b80000 else null;
        }
    };
    const ctx: *const anyopaque = @ptrCast(&Map{});
    var listed: [18]u8 = undefined;
    const want = try std.fmt.bufPrint(&listed, "0x{x:0>16}", .{@as(u64, 0x02566e9a51296e32)});
    try testing.expectEqualStrings("0x02566e9a51296e32", want);

    // The layout's reply.
    {
        const got = try rewriteLayoutWith(alloc, "{\"stack\":[{\"pane\":\"0x1e066b80000\"}],\"shown\":0}", ctx, Map.toId, false);
        defer alloc.free(got);
        try testing.expectEqualStrings("{\"stack\":[{\"pane\":\"0x02566e9a51296e32\"}],\"shown\":0}", got);
    }
    // A refusal's sentence.
    {
        const got = try rewriteHandles(alloc, "the layout names terminal 0x1e066b80000 twice.", ctx, Map.toId);
        defer alloc.free(got);
        try testing.expectEqualStrings("the layout names terminal 0x02566e9a51296e32 twice.", got);
    }
    // And the caller's id still finds its surface on the way in.
    {
        const got = try rewriteLayoutWith(alloc, "{\"pane\":\"0x02566e9a51296e32\"}", ctx, Map.toSurface, true);
        defer alloc.free(got);
        try testing.expectEqualStrings("{\"pane\":\"0x1e066b80000\"}", got);
    }
}

test "a refusal names terminals, and leaves every other number alone" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A map with one surface in it: handle 0x1e066b80000 is terminal
    // 0x7c09e65171296e32. Everything else is not this app's.
    const Map = struct {
        fn lookup(_: *const anyopaque, handle: u64) ?u64 {
            return if (handle == 0x1e066b80000) 0x7c09e65171296e32 else null;
        }
    };
    const ctx: *const anyopaque = @ptrCast(&Map{});

    {
        // ⚠️ The sentence measured on the machine (task 412). The number in
        // it was a surface handle, in a sentence telling the caller to go
        // look at a terminal.
        const got = try rewriteHandles(
            alloc,
            "the layout leaves out terminal 0x1e066b80000, which is in this tab.",
            ctx,
            Map.lookup,
        );
        defer alloc.free(got);
        try testing.expectEqualStrings(
            "the layout leaves out terminal 0x7c09e65171296e32, which is in this tab.",
            got,
        );
    }

    {
        // **A number this app does not hold is not a handle.** The apprt puts
        // its own pane numbers and other values in these sentences, and
        // rewriting one of those would hand back an id that means something
        // else -- worse than the defect, because it would look right.
        const said = "0x16 is not a terminal in this tab; ratio 0.5; 0x1e066b80001 either";
        const got = try rewriteHandles(alloc, said, ctx, Map.lookup);
        defer alloc.free(got);
        try testing.expectEqualStrings(said, got);
    }

    {
        // Two in one sentence, and `0x` inside a word is part of the word.
        const got = try rewriteHandles(
            alloc,
            "0x1e066b80000 and 0x1e066b80000 (id0x1e066b80000)",
            ctx,
            Map.lookup,
        );
        defer alloc.free(got);
        try testing.expectEqualStrings(
            "0x7c09e65171296e32 and 0x7c09e65171296e32 (id0x1e066b80000)",
            got,
        );
    }

    {
        // A bare `0x` and an empty string: no digits, nothing to look up,
        // nothing lost.
        const got = try rewriteHandles(alloc, "0x and 0X", ctx, Map.lookup);
        defer alloc.free(got);
        try testing.expectEqualStrings("0x and 0X", got);
    }
}

/// Task 1730: what a burst of agent requests does to the app mailbox it
/// shares with every terminal's IO thread. **A measurement, run as a test**
/// so that it runs against the mailbox as it is built -- the real queue
/// type, its real capacity, its real messages -- and not against a copy of
/// its numbers.
///
/// The burst is the one a role change makes (`#1685` ②): every sidecar's
/// notifier has a `persona_wait` parked in the app, which answers all of
/// them while handling the one message that changed the role. Each notifier
/// asks again at once -- it has waited longer than its floor
/// (`mcp.min_wait_ms`) -- and each agent whose tools changed lists them
/// again, which is one more request on the sidecar's other connection. Each
/// connection is lock-step, so that is at most two requests a sidecar.
/// Meanwhile a terminal that sets its title pushes the way `stream_handler`
/// does: instantly, and when that fails, for ever -- with the IO thread
/// stopped until it goes in.
const MailboxBurst = struct {
    const Q = Mailbox.Queue;
    const R = PoltergeistRequests;

    /// Where the agents' requests go: into the mailbox, as they did until
    /// task 1730, or into their own queue, as `submitPoltergeistRequest`
    /// puts them now.
    pub const Route = enum { mailbox, own };

    pub const Params = struct {
        route: Route,
        sidecars: usize,
        /// Terminals setting their titles while it happens.
        titles: usize,
        title_every_us: u64,
        /// What the app thread still has to do after answering the waits,
        /// before it next looks at the mailbox.
        rest_us: u64,
        /// What each message then costs it.
        per_message_us: u64,
        /// From a notifier's answer to its agent's next request on the
        /// other connection (`tools/list_changed`, `tools/list`).
        turnaround_us: u64,
    };

    pub const Readings = struct {
        requests: usize = 0,
        /// The most messages the mailbox held.
        queued_max: u32 = 0,
        /// The most requests their own queue held, and pushes it refused.
        requests_queued_max: u32 = 0,
        requests_refused: usize = 0,
        /// Requests whose push had to wait for room, and the longest wait.
        requests_waited: usize = 0,
        request_wait_max_us: u64 = 0,
        title_pushes: usize = 0,
        /// Title pushes the mailbox had no room for at once: the IO thread
        /// stopped until it did, for at most this long.
        titles_blocked: usize = 0,
        title_block_max_us: u64 = 0,
    };

    /// A push that took longer than this waited for room.
    const waited_us: u64 = 200;

    const Shared = struct {
        q: *Q,
        r: *R,
        io: std.Io,
        p: Params,
        go_ns: std.atomic.Value(i64) = .init(0),
        stop: std.atomic.Value(bool) = .init(false),
        pushed: std.atomic.Value(usize) = .init(0),
        queued_max: std.atomic.Value(u32) = .init(0),
        requests_queued_max: std.atomic.Value(u32) = .init(0),
        requests_refused: std.atomic.Value(usize) = .init(0),
        requests_waited: std.atomic.Value(usize) = .init(0),
        request_wait_max_us: std.atomic.Value(u64) = .init(0),
        title_pushes: std.atomic.Value(usize) = .init(0),
        titles_blocked: std.atomic.Value(usize) = .init(0),
        title_block_max_us: std.atomic.Value(u64) = .init(0),
        titles_done: std.atomic.Value(usize) = .init(0),
        pending: poltergeistpkg.Server.Pending = undefined,

        fn now(self: *Shared) i64 {
            return @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds);
        }

        fn spinUntil(self: *Shared, at_ns: i64) void {
            while (self.now() < at_ns) std.atomic.spinLoopHint();
        }

        /// A producer's own waiting sleeps: a hundred threads spinning
        /// would take the cores the app thread's work is measured on.
        fn sleepUntil(self: *Shared, at_ns: i64) void {
            while (true) {
                const left = at_ns - self.now();
                if (left <= 0) return;
                std.Io.sleep(self.io, .fromNanoseconds(@intCast(@min(left, 200_000))), .awake) catch return;
            }
        }

        fn waitForGo(self: *Shared) i64 {
            while (true) {
                const go = self.go_ns.load(.acquire);
                if (go != 0) return go;
                std.Io.sleep(self.io, .fromMicroseconds(50), .awake) catch {};
            }
        }

        fn noteLen(self: *Shared, len: u32) void {
            _ = self.queued_max.fetchMax(len, .monotonic);
        }

        fn request(self: *Shared, delay_us: u64) void {
            const go = self.waitForGo();
            self.sleepUntil(go + @as(i64, @intCast(delay_us)) * 1000);
            const t0 = self.now();
            switch (self.p.route) {
                // How it was: a slot in the mailbox, waited for.
                .mailbox => self.noteLen(self.q.push(self.io, .{ .poltergeist_alert = "" }, .{ .forever = {} })),
                // How `submitPoltergeistRequest` does it now.
                .own => {
                    const len = self.r.push(self.io, &self.pending, .{ .instant = {} });
                    if (len == 0) _ = self.requests_refused.fetchAdd(1, .monotonic);
                    _ = self.requests_queued_max.fetchMax(len, .monotonic);
                },
            }
            const us: u64 = @intCast(@divFloor(self.now() - t0, 1000));
            if (us > waited_us) {
                _ = self.requests_waited.fetchAdd(1, .monotonic);
                _ = self.request_wait_max_us.fetchMax(us, .monotonic);
            }
            _ = self.pushed.fetchAdd(1, .release);
        }

        fn title(self: *Shared, k: usize) void {
            const go = self.waitForGo();
            // Spread over the period, as terminals with nothing to do with
            // each other are: one of them sets its title every
            // `title_every_us / titles`.
            var at = go + @as(i64, @intCast(k * self.p.title_every_us / @max(self.p.titles, 1))) * 1000;
            while (!self.stop.load(.acquire)) {
                self.sleepUntil(at);
                const msg: Message = .{ .poltergeist_quiet = .{ .from = k, .quiet_ms = 0 } };
                _ = self.title_pushes.fetchAdd(1, .monotonic);
                var len = self.q.push(self.io, msg, .{ .instant = {} });
                if (len == 0) {
                    const t0 = self.now();
                    len = self.q.push(self.io, msg, .{ .forever = {} });
                    const us: u64 = @intCast(@divFloor(self.now() - t0, 1000));
                    _ = self.titles_blocked.fetchAdd(1, .monotonic);
                    _ = self.title_block_max_us.fetchMax(us, .monotonic);
                }
                self.noteLen(len);
                at += @as(i64, @intCast(self.p.title_every_us)) * 1000;
            }
            _ = self.titles_done.fetchAdd(1, .release);
        }
    };

    fn run(alloc: Allocator, io: std.Io, p: Params) !Readings {
        const q = try Q.create(alloc);
        defer q.destroy(alloc);
        const r = try alloc.create(R);
        defer alloc.destroy(r);
        r.* = .{};
        var s: Shared = .{ .q = q, .r = r, .io = io, .p = p };

        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(alloc);
        for (0..p.sidecars) |_| {
            // The notifier asks again at once; its agent's next request
            // follows on the other connection.
            try threads.append(alloc, try std.Thread.spawn(.{}, Shared.request, .{ &s, 0 }));
            try threads.append(alloc, try std.Thread.spawn(.{}, Shared.request, .{ &s, p.turnaround_us }));
        }
        var titles: std.ArrayList(std.Thread) = .empty;
        defer titles.deinit(alloc);
        for (0..p.titles) |k| try titles.append(alloc, try std.Thread.spawn(.{}, Shared.title, .{ &s, k }));

        // The app thread: the waits are answered now, then the rest of
        // that message, then the mailbox one message at a time.
        const go = s.now();
        s.go_ns.store(go, .release);
        s.spinUntil(go + @as(i64, @intCast(p.rest_us)) * 1000);
        const want = 2 * p.sidecars;
        var requests: usize = 0;
        // Until every request is either taken or was refused: one refused
        // is never there to take, and waiting for it would spin for ever.
        while (requests + s.requests_refused.load(.acquire) < want or s.pushed.load(.acquire) < want) {
            // One tick: the mailbox, then -- on their own route -- the
            // requests, as `tick` does.
            var any = false;
            while (q.pop(io)) |m| {
                any = true;
                if (p.route == .mailbox and m == .poltergeist_alert) requests += 1;
                s.spinUntil(s.now() + @as(i64, @intCast(p.per_message_us)) * 1000);
            }
            if (p.route == .own) while (r.pop(io)) |_| {
                any = true;
                requests += 1;
                s.spinUntil(s.now() + @as(i64, @intCast(p.per_message_us)) * 1000);
            };
            if (!any) std.atomic.spinLoopHint();
        }
        s.stop.store(true, .release);
        // Drained until every title thread is out: one may be waiting in a
        // push for room only this loop can make.
        while (s.titles_done.load(.acquire) < p.titles) {
            if (q.pop(io) == null) std.atomic.spinLoopHint();
        }
        for (titles.items) |th| th.join();
        while (q.pop(io)) |_| {}
        while (r.pop(io)) |_| {}
        for (threads.items) |th| th.join();
        return .{
            .requests = requests,
            .queued_max = s.queued_max.load(.monotonic),
            .requests_queued_max = s.requests_queued_max.load(.monotonic),
            .requests_refused = s.requests_refused.load(.monotonic),
            .requests_waited = s.requests_waited.load(.monotonic),
            .request_wait_max_us = s.request_wait_max_us.load(.monotonic),
            .title_pushes = s.title_pushes.load(.monotonic),
            .titles_blocked = s.titles_blocked.load(.monotonic),
            .title_block_max_us = s.title_block_max_us.load(.monotonic),
        };
    }
};

test "task 1730: on their own queue, a role change's burst of agent requests stops no terminal" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // The burst the report describes: forty sidecars, twenty terminals
    // setting their titles, the app still busy for 50 ms after it answered
    // the waits. Two requests a sidecar is eighty, more than the mailbox's
    // sixty-four -- which was the trouble while they went there.
    const p: MailboxBurst.Params = .{
        .route = .own,
        .sidecars = 40,
        .titles = 20,
        .title_every_us = 100_000,
        .rest_us = 50_000,
        .per_message_us = 200,
        .turnaround_us = 2_000,
    };
    const r = try MailboxBurst.run(alloc, io, p);
    std.debug.print(
        "task 1730 own: requests={d} requests_queued_max={d} requests_refused={d} queued_max={d} title_pushes={d} titles_blocked={d} title_block_max_us={d}\n",
        .{ r.requests, r.requests_queued_max, r.requests_refused, r.queued_max, r.title_pushes, r.titles_blocked, r.title_block_max_us },
    );
    try testing.expectEqual(@as(usize, 80), r.requests);
    // No terminal setting its title waited for room.
    try testing.expectEqual(@as(usize, 0), r.titles_blocked);
    // Every request went in at once, the queue never full.
    try testing.expectEqual(@as(usize, 0), r.requests_refused);
    const room = r.requests_queued_max <= 2 * p.sidecars;
    try testing.expect(room);
    // What the mailbox held is the terminals' own: one message each at most.
    const own_only = r.queued_max <= p.titles;
    try testing.expect(own_only);
}

test "task 1730: an agent's request alone, with the mailbox empty, is queued on its own and the app woken" {
    // The other half of being "taken promptly": a request is not left
    // until some unrelated message wakes the app loop
    // (`submitPoltergeistRequest`'s wake), and it does not take a slot of
    // the mailbox.
    const testing = std.testing;

    // Only what the hand-over touches: the two queues and the runtime it
    // wakes. A whole `App` in a test build would want the runtime's
    // surfaces, which `apprt.none` does not have.
    var app: App = undefined;
    app.mailbox = .{};
    app.poltergeist_requests = .{};
    var rt: apprt.App = .{};
    app.poltergeist_rt_app = &rt;

    var pending: poltergeistpkg.Server.Pending = undefined;
    submitPoltergeistRequest(&app, &pending);

    const woken = rt.wakeups;
    try testing.expectEqual(@as(usize, 1), woken);
    const in_mailbox = app.mailbox.pop(global.io());
    try testing.expect(in_mailbox == null);
    const queued = app.poltergeist_requests.pop(global.io());
    try testing.expect(queued == &pending);
}

test "task 1730: draining the requests' queue answers what is queued, with nothing in the mailbox" {
    // The other half of "taken promptly": woken is not answered. The loop
    // `tick` runs after the mailbox (`drainPoltergeistRequests`), with a
    // stand-in for answering -- the app's own needs the runtime's surfaces,
    // which a test build has none of; the next test holds `tick` to it.
    const testing = std.testing;
    const alloc = testing.allocator;

    const queue = try alloc.create(PoltergeistRequests);
    defer alloc.destroy(queue);
    queue.* = .{};
    var watch: poltergeistpkg.StallWatch = .{};

    const Answer = struct {
        answered: usize = 0,
        fn handle(self: *@This(), p: *poltergeistpkg.Server.Pending) void {
            p.complete(global.io(), .{ .failed = .{ .code = "Test", .message = "answered" } });
            self.answered += 1;
            p.release();
        }
    };
    var answer: Answer = .{};

    // Requests the way the server makes them: ours, and one more for the
    // app, which drops it when it has answered.
    var pendings: [3]*poltergeistpkg.Server.Pending = undefined;
    for (&pendings, 0..) |*slot, k| {
        const p = try alloc.create(poltergeistpkg.Server.Pending);
        p.* = .{ .alloc = alloc, .caller = .{ .terminal = 0x1730 + k }, .request = .me, .arena = .init(alloc) };
        p.retain();
        const queued = queue.push(global.io(), p, .{ .instant = {} });
        try testing.expect(queued != 0);
        slot.* = p;
    }
    defer for (pendings) |p| p.release();

    const any = drainRequests(queue, &watch, &answer, Answer.handle);
    try testing.expect(any);
    try testing.expectEqual(@as(usize, 3), answer.answered);
    for (pendings) |p| {
        const settled = p.settled.load(.acquire);
        try testing.expect(settled);
    }
    const left = queue.pop(global.io());
    try testing.expect(left == null);
    // Nothing queued: nothing done, and said so.
    const none = drainRequests(queue, &watch, &answer, Answer.handle);
    try testing.expect(!none);
}

test "task 1730: tick drains the requests' queue after the mailbox" {
    // **Read off the source, because `tick` cannot run in a test build**:
    // it reaches the runtime's surfaces, and `apprt.none` has none of their
    // methods. A tick that drained the mailbox and forgot the requests
    // would leave every agent waiting for ever while every other test
    // here passed, so the call is looked for where it has to be.
    const testing = std.testing;
    const src = @embedFile("App.zig");
    const start = std.mem.indexOf(u8, src, "\npub fn tick(") orelse return error.NoTick;
    const end = start + (std.mem.indexOf(u8, src[start..], "\n}\n") orelse return error.NoEnd);
    const body = src[start..end];
    const mailbox = std.mem.indexOf(u8, body, "try self.drainMailbox(rt_app);") orelse return error.NoMailboxDrain;
    const requests = std.mem.indexOf(u8, body, "\n    self.drainPoltergeistRequests();");
    const drained = requests != null;
    try testing.expect(drained);
    const after = requests.? > mailbox;
    try testing.expect(after);
}

test "task 1730: the burst, measured over the sizes and costs it can have" {
    // Not a check: the table the change was argued from, both ways. Each
    // line one run; see `MailboxBurst.Readings`.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    for ([_]MailboxBurst.Route{ .mailbox, .own }) |route| {
        // None at all first: the terminals alone, to see what they do by
        // themselves.
        for ([_]usize{ 0, 10, 20, 32, 40 }) |sidecars| {
            for ([_]u64{ 0, 5_000, 50_000 }) |rest_us| {
                for ([_]u64{ 50, 500 }) |per_message_us| {
                    const r = try MailboxBurst.run(alloc, io, .{
                        .route = route,
                        .sidecars = sidecars,
                        .titles = 20,
                        .title_every_us = 100_000,
                        .rest_us = rest_us,
                        .per_message_us = per_message_us,
                        .turnaround_us = 2_000,
                    });
                    std.debug.print(
                        "task 1730 table: route={t} sidecars={d} rest_us={d} per_message_us={d} -> queued_max={d} requests_queued_max={d} requests_refused={d} requests_waited={d} request_wait_max_us={d} title_pushes={d} titles_blocked={d} title_block_max_us={d}\n",
                        .{ route, sidecars, rest_us, per_message_us, r.queued_max, r.requests_queued_max, r.requests_refused, r.requests_waited, r.request_wait_max_us, r.title_pushes, r.titles_blocked, r.title_block_max_us },
                    );
                }
            }
        }
    }
}

test "2156 v3: the person's own Agent CLIs are read once a round, so nothing a round took is freed under it" {
    const testing = std.testing;

    // A round that has not read yet reads; one that has, does not --
    // **whatever the file has done since**, because reading again is what
    // would free the answer everything in the round is holding.
    try testing.expect(ownClisNeedsRead(7, std.math.maxInt(u64)));
    try testing.expect(ownClisNeedsRead(7, 6));
    try testing.expect(!ownClisNeedsRead(7, 7));
    // The first round of all reads, and so does the round after a wrap.
    try testing.expect(ownClisNeedsRead(0, std.math.maxInt(u64)));
    try testing.expect(ownClisNeedsRead(0, std.math.maxInt(u64) - 1));

    // Moving the round on is what asks for the next read.
    var app: App = undefined;
    app.own_round = 0;
    app.poltergeist_own_round = 0;
    try testing.expect(!ownClisNeedsRead(app.own_round, app.poltergeist_own_round));
    app.ownClisRound();
    try testing.expect(ownClisNeedsRead(app.own_round, app.poltergeist_own_round));
    app.ownClisRound();
    try testing.expect(app.own_round == 2);
}
