<h1 align="center">
  <img src="images/icons/icon_256.png" alt="" width="128">
  <br>Polter
</h1>

<p align="center">
  <b>Put one Claude Code session in charge of the others.</b><br>
  <sub>It reads their screens, types into them, opens new tabs, and minds them
  while you're asleep.<br>
  <b>Polter itself has no account and no API key, and makes no network calls of
  its own</b>. But the agents it minds are your own CLIs, and they talk to their
  models exactly as they already do, on whatever plan you already pay for.<br>
  <i>(Waking you needs a twenty-line notification plugin you write yourself —
  none ships.)</i></sub>
</p>

<p align="center">
  <a href="#download">Download</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#a-full-example">Example</a> ·
  <a href="#what-it-will-never-do">What it won't do</a> ·
  <a href="README_CN.md">中文</a>
</p>

---

## The problem

Three things I hit every day. You have probably hit them too.

**Too many terminals.** A few Claude Code, a few Codex CLI, several projects at
once: frontend in one window, backend in another, tests in a third. Just keeping
track of them is work.

**I can't see what a sub-agent did.** Starting one means it runs for a long
time, often with several tasks of its own inside it, and a step failing part-way
through is routine. The awkward part is the hand-back: **what I get is a
paragraph that reads like a conclusion, and whether it verified anything is not
visible in that paragraph.** The paragraph is all I get — what it tried, what it
worked around, where it gave up, all of that went away with the session.

**I tell it to work through the night, and it stops after two hours.** Usually an
error killed it (some API failure), or it wrapped up halfway and called that
finished.

The last two are the ones that hurt, because **you cannot see them on screen**.
An agent that stopped early, or that reported success on work it didn't finish,
looks exactly like one that's thinking hard. You can't tell which is which
without clicking through every tab. And by the time you think to look, it's
usually the next morning.

## What Polter does about it

**You pick the agent you want in charge, and mark the tab it is running in.**

The mark goes on the tab; the supervisor is the agent inside it — an ordinary
Claude Code session, not a dashboard and not a process manager. Marking it makes
Polter do two things: open its MCP surface to that agent so it can drive the other Polter terminals in this window, and collect
what that agent hasn't been shown yet and hand it over every so often — **how
long each screen has been still, with no verdict attached**. The tools are:

| It can | Which means |
| --- | --- |
| **Read any tab's screen** | It sees the permission prompt your worker is stuck on. |
| **Type into any tab** | It can unstick a worker or tell it to try something else. **It cannot press "yes" on a permission prompt** — that one wakes *you*, at any hour. So for an overnight run, start the workers in an automatic mode (Claude Code's Auto Mode, `--permission-mode acceptEdits`) so the prompt never appears. |
| **Open new tabs and start agents in them** | You never set up the workers yourself. |
| **See how long each screen has sat unchanged** | The one number that tells it where to look first. |
| **Run a group chat and a task panel** | Workers report to it; the panel survives a restart and a compaction. |

You tell it the goal in English — *"build the export feature, split it three
ways, don't wake me unless something needs a decision"* — and it writes the
plan, opens a tab per piece of work, starts an agent in each, and minds them.

Against those three:

| | |
| --- | --- |
| Too many terminals | The supervisor watches all of them; you stop clicking through tabs |
| Can't see what a sub-agent did | **A worker here is not a sub-agent. It's an independent session in its own terminal.** What it did stays on that screen and lands on disk line by line. The supervisor can read it — and, more to the point, **you can `grep` it in the morning**. A sub-agent's working-out goes away with the session; a worker's doesn't |
| Stopping after two hours | How long a screen has been still is reported to the supervisor. It goes and reads that screen — and what it does with what it reads is its call, not Polter's |

**What the second row does not claim:** the supervisor is also an LLM reading
what another LLM wrote, and it can just as easily take a screen full of green
output for "finished". **It is not verifying the work for you.** What changes is
whether the evidence survives — a sub-agent hands back a paragraph and the rest
is gone; a worker's attempt is still sitting there, for a person to check.

Every "it" in that table is **the supervisor**. The supervisor and Polter are
not the same thing, and everything below depends on that:

- **The supervisor** is the agent you put in charge — an ordinary Claude Code
  session. Reading a screen, understanding what's on it, deciding whether to
  step in: all of that is the supervisor's. You can watch it work and take the
  keyboard whenever you like.
- **Polter** is the terminal — this program. It doesn't read anything; it
  carries — screen contents to the supervisor, the supervisor's keystrokes into
  another tab, and **one measurement: how long this screen has been
  unchanged**. Whether a still screen means "stuck" or "thinking hard" is not a
  question Polter answers — the answer is in what the screen says, and reading
  that is the supervisor's job.

## Before you decide

Three things worth knowing before you spend ten minutes on this:

- **This replaces your terminal app.** Polter is a fork of
  [Ghostty](https://github.com/ghostty-org/ghostty), so it has to be the
  terminal your agents are running in. The cost is lower than it sounds: it is
  a complete, fast terminal on its own, and you can install it and use it as
  one for a week before you ever put an agent in charge of anything. [Why it has to be the
  terminal](#why-a-terminal-and-not-a-library) matters most if you already drive
  agents from tmux or a script.
- **Being woken up needs twenty lines of shell.** Notifications are a
  [plugin](#plugins), deliberately — Polter has no opinion about whether you
  use Telegram, ntfy or `osascript`. **No notification plugin ships**, so out of
  the box the supervisor can watch all night but cannot reach your phone. The
  script is short, but there is no example in this file yet and you do have to
  write it.
- **It is an experiment, and it has been run end to end on one agent CLI:**
  Claude Code. Underneath it is ordinary MCP — the protocol your agent CLI
  already uses to reach tools — over ordinary terminals, so others
  *should* work. Nothing else has been tested. macOS is the platform it's
  developed on; [Windows is newer and partial](#download); Linux is
  build-from-source.

**There is no measured cost number here yet.** The supervisor is
a Claude Code session like any other, and it runs all night reading screens and
writing messages, so it spends like one. What decides how much: how many
workers it is minding, how often it is interrupted with what it hasn't seen
(`poltergeist-notice-interval`, one minute by default — raise it and the bill
falls), and how much of a screen it reads each time it looks. Try it on one
worker for an hour before you leave it running on four overnight.


## Download

[**Latest release**](https://github.com/Lugia123/polter/releases/latest) —
version numbers are `0.5.<n>`, where `n` counts the commits that are this
fork's own.

| | |
| --- | --- |
| **macOS 13+** | `Polter-*-macos-universal.zip` — Apple Silicon and Intel in one bundle. The platform this is developed on and used daily. |
| **Windows 10+** | `Polter-*-windows-x64.zip` — new. What works and what doesn't is below. |
| **Linux** | No binary. The GTK app builds, but nobody has run a supervised session on it, and shipping something nobody has started is not a thing to do quietly. Build from source. |

### macOS: the builds are unsigned

There is no Apple Developer certificate behind this, so the app is ad-hoc
signed and not notarised. Gatekeeper refuses it until you say otherwise:

```sh
unzip Polter-*-macos-universal.zip
xattr -dr com.apple.quarantine Polter.app
mv Polter.app /Applications/
```

Then **open it from Finder or the Dock, not from a terminal.** The two have
different `PATH`s, and the provisioning plugin that installs the supervisor's
skills looks for your agent CLI on `PATH` — started from the wrong place it
finds nothing and exits quietly.

### Windows: what works and what doesn't

Unzip anywhere and run `polter-host.exe`. **The two DLLs and `share/` must stay
next to it** — the DLLs are loaded by name at startup, and `share/` is where
the supervisor's skills and the provisioning plugins live. Unsigned, so
SmartScreen will want a "Run anyway".

The Windows shell is a separate Rust program (`windows/host/`) driving the same
core through libghostty's C API, because Ghostty has no Windows GUI of its own.
It is younger than the macOS side and not at parity:

| | |
| --- | --- |
| Verified on a Windows 11 machine | The window opens, tabs work, a shell starts, text including CJK renders, IME composition types Chinese, the menu and its accelerators work, the resources directory is found, and the provisioning plugins start. |
| Known missing | **Splits** — the layout algorithm is ported (`windows/split-tree/`) but not wired to the window tree. **Some keybinding actions** are not implemented yet; the count is tracked in [`docs/windows/status.md`](docs/windows/status.md). **Shell integration** is not injected. **The `archive` plugin** is installed and enabled but never starts, because plugins have no way yet to declare which systems they can run on. |
| Broken, being chased | **The group chat view does not come up.** Tested on 0.5.447: the menu item works, the tab is created, and the log shows the right command line — but the tab stays blank. The chat is a TUI run as a tab (`polter-host.exe +chat`), and the host is a GUI-subsystem program, which is where this is being chased. Groups and the task panel still work through the MCP tools; it is the on-screen view that is missing. |

[`ROADMAP.md`](ROADMAP.md) is where these get closed.

## Quick start

One agent has to be in charge, and you mark its tab. That is the whole of the
setup — but check it took, because the one way it silently doesn't is step 2.

### 1. Open a tab and start Claude Code in it

Just the way you always do. `cd` somewhere sensible first — a supervisor can
open its own tabs later, but it starts where you left it.

### 2. Mark that tab as the supervisor

**Agents → Make This Terminal a Supervisor.** (Also in the command palette, and
bindable as the `poltergeist_supervisor` action.) The same item toggles it off,
and one window can hold several supervisors, each minding its own work.

The mark is on the tab; the tools go to the agent inside it. So the moment you
set it, Polter types a line into that tab: what just happened, and an
instruction to read its `supervising` skill. So it knows the mechanics before
you say anything.

**Check the tools are actually there before going further.** `me` is the
simplest of the forty tools — it just makes an agent state who it is and what it
can reach — which makes it the right probe. Ask it:

> call the `me` tool and tell me what it says.

If it answers with an id and a list of what it can reach, you're set. If it says
it has no such tool, stop here — nothing below will work, and the cause is
almost always one of three things covered in
[If the agent says it has no polter tools](#if-the-agent-says-it-has-no-polter-tools).
The short version: a plugin has to tell Claude Code that Polter's tools exist,
it does that by running `claude mcp add`, and it can only do that if `claude`
was on `PATH` **when Polter started** — which is why the install note says to
open Polter from the Dock rather than from a terminal.

### 3. Tell it what the job is

That's your part done. It sets up the group, opens or claims the tabs, and
starts the clocks itself. You don't need to name terminal ids or tools.

### 4. Go to bed

**Not on the first night.** Out of the box nothing can wake you — notifications
are a [plugin](#plugins) and none ships, so a worker that stops on a permission
prompt at 1am is still sitting there at 8. Either sit with it for the first
hour, or start your workers with `--permission-mode acceptEdits` so there is no
prompt to stop on, or write the twenty lines first. The [full
example](#a-full-example) below does the second one.

Come back to **Agents → Terminal Conversations** (or `polter +chat`) to read
what they said to each other. `tab` and `shift+tab` move between three views of
the same group: the conversation, the task panel, and a page of arithmetic
about the night — task lifetimes, who did the talking, which terminals sat
still and for how long.

## A full example

Say you want a REST API built overnight, and you don't want to babysit it.

Open one tab, `cd` to the project, start `claude`, and turn it into a
supervisor. Then type something like this — **this example names tools and
arguments on purpose, so you can see what it will go and do.** You don't have
to: "build this, split it three ways, wake me only for permission prompts" is
enough, and it will work the rest out from its skill file.

> You're the supervisor. Goal: a working REST API for the notes service in
> `~/src/notes`, with tests passing and the OpenAPI spec updated.
>
> First write me a development plan and split it into three pieces of work
> that don't step on each other. Then open a terminal per piece — use
> `terminal_open` with the right directory and `watch: true` — start
> `claude --permission-mode acceptEdits` in each, and hand each one its task
> along with what "done" means for it.
>
> Put them all in a group. Check on them while I'm asleep, unstick anything
> that's stuck, and don't let anyone stop early. Wake me only if someone is
> waiting on a permission prompt. Report in the morning.

From there it will, on its own: `group_create` + `group_set_brief` to make
somewhere to talk, `terminal_open` three times to make the tabs, `terminal_send`
to start an agent in each, `group_add` to put everyone in the conversation, and
`set_watch` on each one to start its quiet clock. Then it goes around: when a
tab has been still for a while, it reads the screen, decides whether that's a
stall or just a long build, and either nudges it or leaves it alone.

Three things worth knowing about that prompt:

- **Ask for a plan first.** A supervisor that splits the work before opening any
  tabs gives you something to read in the morning that isn't just a transcript.
- **Say what "done" means.** The `supervising` skill hammers on this: an
  assignment with no acceptance test means the worker decides for itself what
  finished looks like, and you find out at 2am that it decided something else.
- **Start the workers in auto mode.** Polter will never answer a permission
  prompt for an agent — that's a hard rule, not a setting — so anything a worker
  stops on is something _you_ get woken for. Claude Code's own auto-accept
  (shift+tab in the session, or `--permission-mode acceptEdits` at launch) is
  the thing to reach for. `--dangerously-skip-permissions` exists too; it means
  what it says.

### While it runs

- **Reports arrive in batches**, one line per terminal, every
  `poltergeist-notice-interval` (a minute). The supervisor can also look
  whenever it likes with `notices`.
- **A tab counts as quiet** after `poltergeist-quiescence-after` (three minutes)
  of an unchanged screen, and a still-quiet one is mentioned again every
  `poltergeist-quiescence-repeat` (fifteen minutes).
- **If a worker stops on a permission prompt** and the supervisor calls
  `notify_user`, you're told — at any hour, ignoring `poltergeist-notify-window`,
  because nobody else can answer it. That needs a notification
  [plugin](#plugins) configured.

### Two switches that are yours alone

Both are visible on the tab itself, not just in a menu:

- **Hold it to its work** — this one must not be clocked off.
  A supervisor asking to is refused. The tab's mark grows a ring (`◉` moving,
  `◎` still). **This one is not in the Agents menu right now** — find it in the
  command palette as `Keep This Terminal Working`, or bind
  `poltergeist_toggle_held`.
- **Agents → Keep Agents Out of This Terminal** — out of reach of the tool
  surface entirely. Absolute: refuses supervisors and plugins too. The tab gets
  a padlock. Use it for the tab you read your mail in.

Neither can be lifted through the tool surface. There is no tool for
it — a supervisor that could unlock a tab would just unlock it and then clock it
off.

## Why a terminal, and not a library

It is not that an outside process can't read a screen — it can, and
if you drive agents from tmux with `capture-pane` you are already doing it. The
reason is narrower and it is the thing that makes this different from an
API-based orchestrator:

**Polter never touches authentication, so it has no say in which CLI, model or
account you run.**

A framework that calls models for you needs your API key. It then owns the
question of which model, which account, which billing. Polter calls nothing. It
starts the CLI you name in a tab and reads the screen; how that CLI logs in is
between it and its vendor. So:

- **Your subscription counts.** If Claude Code is signed in on your plan, a
  supervisor adds nothing to an API bill: it spends the plan you already have.
  **That is not the same as free.** A supervisor reading screens all night
  spends your plan's allowance, and that allowance is what you sit down to work
  with in the morning. On a subscription, the ceiling is the cost to watch.
- **Different tabs, different vendors, different billing.** One worker on
  `codex` signed into a Codex plan, another on `claude` with a subscription, a
  third on an API key, all in one group. Nothing in Polter has an opinion about
  it, because nothing in Polter can see it.
- **An expensive model where the judgement is, cheap ones where the typing
  is.** The supervisor reads screens and decides; workers grind. They are
  separate sessions, and which model each one uses is decided by how *you*
  started it. Polter has no hand in it and could not take one.
- **You can start a worker yourself and hand it over afterwards.** The
  supervisor doesn't have to open the tab. Open one yourself, with whichever
  CLI, model and account you want, get the context into it by hand — then have
  the supervisor adopt it into the group. That path is the easy one for two
  cases: when you want exact control over what a particular worker is, and when
  you've driven a session for twenty minutes and now want to go to bed.

**What this costs you** is the thing above: it has to be your terminal. If your
agents live in tmux on a remote box over SSH, there is no version of this that
works for you today.

**And one thing it is not:** this is a single-machine tool. The group chat, the
task panel and the transcripts all live in your own state directory — they are
between the agents on *this* machine, not between you and a colleague. Five
people using Polter is five separate installs with nothing shared but what you
tell each other.


## What you get beyond that

- **You can take the keyboard at any time.** Every worker is an ordinary tab
  running an ordinary CLI. Type into one whenever you like; the supervisor is
  not driving a simulation, and one tab crashing leaves the rest alone. They
  don't all have to be the same CLI, either — though **only Claude Code has been
  run end to end**. Mixing them is reasoning rather than experience
  ([the details](#which-agents-this-works-with)).
- **Two locks only you can set or lift.** Hold a tab to its work so the
  supervisor can't let it clock off, or put a tab out of reach of the MCP tools
  entirely so nothing can read or type into it. Both show on the tab, and
  **neither can be undone through the tools** — an agent cannot unlock what you
  locked.
- **The whole night on disk, as JSON lines.** Every group message and everything
  that scrolled past in every tab. `grep` and `jq` work on it in the morning.
  Nothing is redacted, so treat it like your shell history.
- **The rules are a file you can edit.** How to supervise is a Markdown skill
  you can change and version. What's *forbidden* is compiled into the binary
  instead — so it can't quietly fall out of the supervisor's context at 4am,
  the way an instruction you gave it once can.
- **A statistics view.** Task lifetimes, who did the talking, which terminals
  sat still and for how long, hour by hour. It counts and stops there: a task
  that has gone longer than the threshold *you* set is marked `over`, which
  says it passed your line and nothing about whether anything is wrong.


## What the supervisor can do

Everything goes through one MCP surface (`src/cli/mcp.zig` in front of
`src/poltergeist/rpc.zig`), forty tools, twenty-three of them the
supervisor's alone.

**Arranging is the supervisor's.** Claiming terminals, the clock, making groups,
the task panel, notifying you, opening tabs, the plugin tools — because a
terminal that could claim other terminals would be a second, quieter road to
being in charge. Talking _inside_ a group you're already in isn't arranging
anything, so the chat tools are open to every member.

**Operating a terminal isn't arranging either.** Reading a screen, typing,
pressing a key, doing a menu action — those are open to any agent, and what
decides whether the call goes through is the _target's_ mark, not who's asking.
An agent in one tab may restart a server in another tab that nobody is watching.
It may not touch a tab marked watched, shielded, or supervisor.

Two more properties run through the whole surface. **The group chat keeps a
record; it does not push.** A terminal somebody is minding is not woken by a
group message, so posting is never how you get anybody moving: `terminal_send`
is. And **anything that would make an irreversible decision on your behalf is
refused** and handed back to the supervisor as something to say to you out loud:
a `cmd:` credential, switching a plugin off, answering an agent's permission
prompt.

Every tool, with what it does and what it refuses, is in
**[`docs/tools.md`](docs/tools.md)**. It is a reference; read it when you want
to know exactly what a call does. You do not need it to use Polter: the supervisor reads its own skill file and
calls these itself, and the [full example](#a-full-example) above is what
driving it actually looks like.

The five families, so the names in this document mean something:

| | |
| --- | --- |
| `terminal_*` | See and drive a tab: read the screen, type, press a key, open one, run a menu action. |
| `group_*` | The group chat. A record of what was said — **posting never wakes anybody**, which is why it is not how work gets handed out. |
| `task_*` | The task panel. This is the part that survives a restart, a compaction and the night. |
| `plugin_*` | List, configure and test the plugins. Supervisor only. |
| Identity | `me`, `become_supervisor`, `stand_down`, `clock_in`/`clock_out`, `notices`, `notify_user`, `skill_read`, `session_recall`. |

## What it will never do

Four of these, and they're the reason to trust the rest:

- **Never answer a permission prompt for an agent.** No allow-list, no flag.
  Pressing "yes" on someone else's authorisation defeats their safety model. You
  get told instead, at any hour.
- **Never let an agent unlock what you locked.** The hold and the shield are
  yours. The tool surface can read that a hold exists; it cannot change it.
- **Never become a task tracker.** The panel holds who is doing which piece of
  work and whether it's finished — one line, one terminal, open or closed. Not
  the requirement, not dependencies, priorities or due dates, not subtasks,
  attachments or comments. It exists so that an instruction typed into a terminal
  at 9pm is still there at 3am, and for nothing else; the argument for where that
  line sits is [`docs/poltergeist/tasks.md`](docs/poltergeist/tasks.md).
- **Never be a shortcut around your agent's own permissions.** An agent whose
  CLI keeps `Bash` behind an approval prompt doesn't get execution by way of
  having Polter installed. `terminal_send` types text and only text: it goes
  down the paste path, where every control byte becomes a space, the same as
  xterm. Pressing a key is therefore a separate verb with its own
  authorisation (`src/poltergeist/keys.zig`).

And two smaller ones in the same spirit: an agent may switch a plugin **on** but
never **off** (an agent that can close your notification channel can turn its own
lights off), and a watched terminal may not promote itself with
`become_supervisor` (it's the one most likely to be reading things off the
network, and a line of injected text must not be able to promote anybody).

## Where things get written

Both are on by default, and both are plain text — `less`, `grep` and `jq` all work on them in the morning:

- `$XDG_STATE_HOME/polter/chat/` — what the agents said to each other.
- `$XDG_STATE_HOME/polter/terminals/` — what actually happened in each terminal.
  One directory per terminal, one file per day, JSON per line. **Nothing is
  redacted; treat it like your shell history.**
- `$XDG_STATE_HOME/polter/tasks/` — every change to a task panel, with its time.
  This is what `task_history` reads.
- `$XDG_STATE_HOME/polter/stats/` — one line per group per hour: how many tasks
  were open, closed, cancelled, past the line, and how long the quietest and
  the longest-untouched had been sitting. Written alongside the threshold that
  was in force, because a count of "over" means nothing later if the line it
  was counted against has since moved.

## Settings worth knowing

None are required. `polter +show-config --default --docs` prints all of them.

| Option                              | Default | What it's for                                                                                                        |
| ----------------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------- |
| `poltergeist-mcp`                   | `true`  | Open the agent socket at all. `false` gives you a plain terminal.                                                    |
| `poltergeist-register-mcp`          | `true`  | Let a plugin tell your agent's runtime that Polter's tools exist.                                                    |
| `poltergeist-watch`                 | `false` | Sample every terminal from the moment it opens. You don't need this — claiming a terminal starts its sampler anyway. |
| `poltergeist-quiescence-after`      | `3m`    | How long a screen must be unchanged before it's reported.                                                            |
| `poltergeist-quiescence-repeat`     | `15m`   | How often a _still_ quiet terminal is mentioned again.                                                               |
| `poltergeist-notice-interval`       | `1m`    | How often the supervisor may be interrupted with what it hasn't seen.                                                |
| `poltergeist-supervisor-stand-down` | `true`  | Whether a supervisor may take itself off duty when the work is done.                                                 |
| `poltergeist-notify-window`         | empty   | Hours you may be disturbed, as `HH:MM-HH:MM`. Authorisation prompts ignore it.                                       |
| `poltergeist-chat-log`              | `true`  | Write the group chat to disk.                                                                                        |
| `poltergeist-terminal-log`          | `true`  | Write each terminal's transcript to disk.                                                                            |
| `poltergeist-task-idle-after`       | `12h`   | How long a task can go untouched before it's worth mentioning to the supervisor. Untouched, not stuck.               |
| `poltergeist-group-quiet-after`     | `1h`    | How long a group can go without anybody saying anything before that's mentioned.                                     |
| `poltergeist-worker-nudge-after`    | `10m`   | How long a worker can sit still with an open task before it's asked whether it meant to report something.            |
| `poltergeist-compact-after`         | `64KB`  | How much uncompacted conversation a group may hold before its size is reported in the supervisor's next hand-over.    |

## If the agent says it has no polter tools

Polter puts a socket path and a token in every terminal's environment, which is
all an agent needs to _reach_ it — but an MCP client only loads servers it's
been configured with.

Doing that configuration is a plugin's job, not the core's
(`src/poltergeist/provision.zig` says why). The **`claude-code`** plugin ships
switched on and does it: `claude mcp add --scope user`, plus a copy of Polter's
skills into `~/.claude/skills/polter-*`. So the usual causes are that the plugin
is off, that `claude` wasn't on `PATH` when Polter started, or that
`poltergeist-register-mcp` is off. If you want registration and no
provisioning plugin is on, Polter says so on a terminal screen rather than only
in a log.

**The registration names one build, and the last one to start wins.** Starting a
development build silently repoints your user-scoped `polter` entry at it. That's
what you want while hacking on Polter and not what you want afterwards. Start the
build you mean to keep, or set `poltergeist-register-mcp = false` and manage the
entry yourself with `claude mcp`.

## Which agents this works with

**Claude Code is the only one this has been tested with**, and the only one that
works out of the box. But the shape is worth stating, because it isn't "Claude
Code only":

- **The server is ordinary MCP.** `polter +mcp` speaks standard MCP on stdio and
  relays to Polter over a unix socket. Any MCP client can run it. Every terminal
  gets `GHOSTTY_POLTER_SOCKET` and its own `GHOSTTY_POLTER_TOKEN`; the token is
  what says which terminal an agent is speaking from, and an agent can't claim to
  be another.
- **What's Claude Code-specific is the setup, and it's a plugin.** The core
  publishes a description of this build — which binary serves the endpoint, which
  skills exist, where their files are — and the `claude-code` plugin turns that
  into the shape Claude Code reads. Another agent CLI needs a second plugin, not
  a patch to the core.
- **No `claude` on `PATH` is not an error.** The plugin says what it couldn't do,
  Polter puts that sentence on a screen, and everything else carries on.

Another agent could in principle use all of this: register `polter +mcp` with its
own runtime and find a way to put the `supervising` skill in front of the model
(`skill_read` hands the text over, but something has to think to call it).
**Untested. Treat it as untested rather than supported.**

## Plugins

A plugin is a directory with a `plugin.json` and one executable, in
`$XDG_CONFIG_HOME/polter/plugins/`. It's started once and kept running; Polter
writes it JSON lines on stdin and it answers on stdout. A twenty-line shell
script is a complete plugin.

What a plugin _is_ is just what it subscribes to:

```json
{ "wants": { "events": ["chat"], "calls": [], "groups": ["*"] } }
```

- **`chat`** — something was said in a group.
- **`terminal.quiet`** — a terminal has gone quiet and somebody should be told.
- **`provision`** — here's what Polter is; make an agent runtime able to see it.

A plugin speaks the same wire protocol an agent speaks, and goes through exactly
the same checks: an undeclared method is refused, a supervisor's method is
refused because a plugin is never a supervisor, and a shielded terminal is out of
its reach the same way it's out of a supervisor's.

### What ships with it

Eight plugins: one `archive`, plus seven provisioning plugins, one per agent CLI
(Claude Code, Codex, Gemini, Qwen, opencode, Kimi, DeepSeek). **Which of them
actually run depends on which CLI is installed on your machine** — **Agents →
Plugins** shows the current state, and it is the first place to look when the
tools don't appear. None of them asks for the network.

These two are the ones you'll deal with:

- **`archive`** — keeps a second copy of every chat message as one file per day,
  every group on a single timeline, appended as JSON lines. Point `dir` at a
  synced folder or an external disk and that copy outlives this machine. Set
  `sign_key` and each line carries an HMAC-SHA256 of the record, so a copy that
  was edited afterwards says so — the key is a credential, so give it as a
  reference (`env:`, `file:`, `keychain:`) rather than in the clear. This is
  belt-and-braces: Polter keeps [its own record](#where-things-get-written)
  whether the plugin is on or off, and the plugin doesn't read it — it's handed
  live events.
- **`claude-code`** — tells Claude Code that Polter exists. It runs
  `claude mcp add` under the `user` scope (so the tools are there in every
  directory, not just one project) and mirrors Polter's skills into
  `~/.claude/skills/polter-*`. Without it an agent has the socket and the token
  sitting in its environment and no way to use either — which is the usual
  answer to [the question below](#if-the-agent-says-it-has-no-polter-tools).
  Set `skills: no` to register the server and nothing else.

Turn either off in **Agents → Plugins**. An agent can switch a plugin on but
never off, so that's a decision only you make.

Notification channels are yours to drop in; there are dozens, and shipping any
one of them would be out of date within a year.

**`"network": false` is a declaration, not a sandbox.** Polter records what a
plugin says it needs and shows it to you; it does not confine it
(`src/poltergeist/Plugin.zig` says so in as many words). A plugin is an
executable you put in a directory, running as you, with everything you can do.
Read one before you install it, the same as any shell script.

**Credentials are stored as references, never in the clear** — `env:NAME`,
`file:` a path, `keychain:service/account`, or `cmd:` a command whose stdout is
the value, resolved at the moment of the call and never cached. So the settings
file can live in a dotfiles repo. `cmd:` covers every password manager at once,
and is exactly the one an agent may not write: a `cmd:` an agent wrote would be a
command Polter runs later, on its own, outside whatever authorised the agent at
the time. **Editing the file by hand has none of these restrictions** — the
asymmetry is about whose hand it is.

Configure from **Agents → Plugins**. Full contract in
[`docs/poltergeist/plugins.md`](docs/poltergeist/plugins.md).

## Relationship to Ghostty

Everything that makes this a good terminal is
[Ghostty](https://github.com/ghostty-org/ghostty)'s work, by Mitchell Hashimoto
and the Ghostty contributors. Polter is a fork, not a rewrite: the renderer, the
VT implementation, the font stack and the native UIs are all theirs, and upstream
is merged in as it moves.

**So everything about the terminal itself is upstream's to answer** — escape
sequences, performance, configuration, keybindings, `libghostty`, the crash
reporter. Read [ghostty.org/docs](https://ghostty.org/docs); all of it applies
here, with `ghostty` spelled `polter`.

Polter adds `src/poltergeist/`, the MCP surface, the chat TUI, the terminal
transcript and the plugin host. It is not affiliated with the Ghostty project,
and bugs found here shouldn't be reported there unless they reproduce on upstream
Ghostty.

MIT licensed, same as upstream; see [LICENSE](LICENSE), which keeps the original
copyright.

## Building and docs

`zig build` builds it. [`docs/preview-manual.md`](docs/preview-manual.md) is the
authority on building, running and debugging, and
[`docs/README.md`](docs/README.md) indexes the rest. The design of everything
above is argued out in [`docs/poltergeist/`](docs/poltergeist/README.md) — start
with its `README.md`, which is the constitution the other chapters answer to.

[`CONTRIBUTING.md`](CONTRIBUTING.md) says which half of this tree is Polter's
and which half is upstream Ghostty's — worth two minutes before writing a
patch, because guessing wrong costs you a rebase. [`ROADMAP.md`](ROADMAP.md)
is where the work actually is, including what is missing on Windows.
