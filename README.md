<h1>
<p align="center">
  <img src="images/icons/icon_256.png" alt="Polter" width="128">
  <br>Polter
</h1>
  <p align="center">
    A terminal that keeps an eye on your AI agents while you sleep.
    <br />
    <sub>One tab supervises the others. Entirely local — no account, no API key,
    nothing leaves the machine.</sub>
    <br />
    <br />
    <a href="#what-it-is">What it is</a>
    ·
    <a href="#what-it-gives-you">What it gives you</a>
    ·
    <a href="#quick-start">Quick start</a>
    ·
    <a href="#a-full-example">Example</a>
    ·
    <a href="#what-the-supervisor-can-do">Tools &amp; skills</a>
    ·
    <a href="#what-it-will-never-do">What it won't do</a>
    ·
    <a href="#which-agents-this-works-with">Which agents</a>
    ·
    <a href="README_CN.md">中文</a>
  </p>
</p>

## What it is

Polter is a terminal — a fork of [Ghostty](https://github.com/ghostty-org/ghostty) —
that lets one of your tabs look after the others.

You run AI agents in terminal tabs already. The problem starts when there are
four of them: one is stuck on a question nobody answered, one finished twenty
minutes ago, one is quietly waiting for a build, and you can't tell which is
which without clicking through all four.

So make one tab the **supervisor**. It's just another Claude Code session, but
it can see how long each of the other tabs has been sitting still, read what's
on their screens, type into them, open new ones, and talk to them in a group
chat. You tell it what the job is. It does the minding.

Polter itself never judges. It measures one thing — **how long has this screen
been unchanged** — and carries messages. Whether a still screen means "stuck"
or "thinking hard" is a question it refuses to answer, because answering it
wrong is worse than not answering. That call belongs to the supervisor.

All of it runs on your machine. Polter opens a unix socket in your own runtime
directory and does nothing else: no account, no service of ours to sign in to,
no telemetry, no network call of its own. Your code, your screens and whatever
your agents say to each other stay where they already are. And it never asks you
for an API key, because it never talks to a model — the thinking is done by the
agent CLI you already installed and already trust. Polter only watches, types,
and carries messages. (Upstream Ghostty's crash handler is compiled in and it
too stays local — it writes reports to disk instead of sending them, see
`src/crash/sentry.zig`.)

There is also nothing to set up. One menu item makes a tab the supervisor; every
setting below has a default that works, and you can run the whole thing without
touching any of them. Anything Polter deliberately doesn't do — notifications, in particular —
is a [plugin](#plugins), and a twenty-line shell script is a complete one.

Status: **an experiment that works — on one agent CLI.** It's been run end to
end with the real Claude Code CLI, and the bugs that found were ones no unit test
could have. Everything underneath is ordinary MCP over ordinary terminals, so
other agent CLIs should work too — but _should_ is the honest word here: nothing
else has been tested. [The details are further down](#which-agents-this-works-with),
and if you try one, tell me what happened.

## What it gives you

- **A supervisor that sets its own work up.** Tell it the goal and it writes the
  plan, opens a terminal per piece of work in the right directory
  (`terminal_open`), starts an agent in each, puts them all in a group chat, and
  claims each one so its clock starts. You never type a terminal id.
- **One number per tab instead of a guess.** Polter measures how long each screen
  has been unchanged and hands that over. Reading the screen and deciding what it
  means is the supervisor's job — which is why nothing here breaks when an agent
  CLI changes the way it draws.
- **Real terminals, so you can take over.** Every worker is an ordinary tab
  running an ordinary CLI. Grab the keyboard and type whenever you like; one tab
  crashing leaves the rest alone, and they don't all have to be the same CLI.
- **A group chat they actually use.** Workers talk to each other and to the
  supervisor, the whole thing is on screen in `polter +chat`, and it survives a
  restart.
- **Locks only you can set or lift.** Hold a tab to its work, or put it out of
  reach of the tool surface entirely. Both are visible on the tab, and neither
  can be undone through the tool surface.
- **A night you can read in the morning.** Every group message and everything
  that scrolled past in every tab lands on disk as JSON lines. `grep` and `jq`
  work on it.
- **Judgement you can edit.** How to supervise is a Markdown skill file you can
  change and version. What's forbidden is compiled in, so it can't fall out of a
  long session's context at 4am.

## Quick start

You need one tab to be the boss. That's the whole setup.

### 1. Open a tab and start Claude Code in it

Just the way you always do. `cd` somewhere sensible first — a supervisor can
open its own tabs later, but it starts where you left it.

### 2. Make it the supervisor

**Agents → Make This Terminal a Supervisor.** (Also in the command palette, and
bindable as the `poltergeist_supervisor` action.) The same item toggles it off,
and one window can hold several supervisors, each minding its own work.

Polter immediately types a line into that tab telling the agent what just
happened and to read its `supervising` skill. So it knows the mechanics before
you say anything.

### 3. Tell it what the job is

That's your part done. It sets up the group, opens or claims the tabs, and
starts the clocks itself. You don't need to name terminal ids or tools.

### 4. Go to bed

Come back to **Agents → Terminal Conversations** (or `polter +chat`) to read
what they said to each other.

## A full example

Say you want a REST API built overnight, and you don't want to babysit it.

Open one tab, `cd` to the project, start `claude`, and turn it into a
supervisor. Then type something like this:

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

Both show on the tab, because a guarantee you were told about once is one you
won't remember at 3am:

- **Agents → Keep This Terminal Working** — this one must not be clocked off.
  A supervisor asking to is refused. The tab's mark grows a ring (`◉` moving,
  `◎` still).
- **Agents → Keep Agents Out of This Terminal** — out of reach of the tool
  surface entirely. Absolute: refuses supervisors and plugins too. The tab gets
  a padlock. Use it for the tab you read your mail in.

Neither can be lifted through the tool surface. There's deliberately no tool for
it — a supervisor that could unlock a tab would just unlock it and then clock it
off.

## What the supervisor can do

Everything goes through one MCP surface (`src/cli/mcp.zig` in front of
`src/poltergeist/rpc.zig`), and the list is deliberately short: forty tools,
twenty-three of which are the supervisor's alone. Those are marked 🔑 below.

**Arranging is the supervisor's.** Claiming terminals, the clock, making groups,
the task panel, notifying you, opening tabs, the plugin tools — because a
terminal that could claim other terminals would be a second, quieter road to
being in charge. Talking _inside_ a group you're already in isn't arranging
anything, so the chat tools are open to every member: a team that can't talk
isn't a team.

**Operating a terminal isn't arranging either.** Reading a screen, typing,
pressing a key, doing a menu action — those are open to any agent, and what
decides whether the call goes through is the _target's_ mark, not who's asking.
An agent in one tab may restart a server in another tab that nobody is watching.
It may not touch one that's watched, shielded, or a supervisor.

Two more properties run through the whole surface. **The group chat keeps a
record; it does not push.** A terminal somebody is minding is not woken by a
group message, so posting is never how you get anybody moving — `terminal_send`
is. And **anything that would make an irreversible decision on your behalf is
refused** and handed back to the supervisor as something to say to you out loud:
a `cmd:` credential, switching a plugin off, answering an agent's permission
prompt.

### Seeing and driving a terminal

The reach rule above applies to this whole group: unmarked terminals are open to
anyone, watched ones and supervisors to a supervisor, shielded ones to nobody.

| Tool               | What it does                                                                                                                                                                                                                                                                                                     |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `terminal_list`    | Every terminal Polter knows about: how long each screen has been unchanged, and whether it's on duty. Durations only — `terminal_read` is how you see content.                                                                                                                                                    |
| `terminal_read`    | The visible screen of another terminal. No scrollback; what's on screen now is all there is.                                                                                                                                                                                                                     |
| `terminal_send`    | Type into a terminal exactly as the person at the keyboard would. Control characters are stripped on the way in, so this cannot press `ctrl+c`. `submit` defaults to true.                                                                                                                                        |
| `terminal_key`     | Press a key, written as a Ghostty keybinding trigger: `ctrl+c`, `escape`, `f2`, `arrow_down`. This is the only way to interrupt something. An ordinary character like `a` is refused here — that's `terminal_send`'s job.                                                                                          |
| `terminal_keys`    | The vocabulary `terminal_key` accepts, every modifier and key name. Read it rather than guess at one.                                                                                                                                                                                                             |
| `terminal_action`  | Anything the menu bar does: `new_tab`, `close_surface`, `toggle_fullscreen`, `copy_to_clipboard`, `increase_font_size:1`, `goto_split:left`, `new_split:right`, `inspector:toggle`. `close_surface` can come back `AwaitingConfirmation` — an unmarked terminal with something still running in it gets the same confirmation a person clicking close would, and nothing here can press that button. One you're minding closes without asking. |
| `terminal_actions` | Every action `terminal_action` will take, and which of them want a value after a colon.                                                                                                                                                                                                                          |
| `terminal_open` 🔑 | Open a terminal in this window, starting in a directory you choose (`cwd` must be an absolute path that exists; one that isn't is refused rather than opened somewhere else quietly). Better than `new_tab`, which can only inherit the caller's directory — four pieces of work in four directories can't be set up that way at all. `watch: true` minds it from the moment it exists. The reply carries `id` when the tab was ready in time; without one it turns up in `terminal_list` shortly. |

### Talking, and leaving a record

| Tool                | What it does                                                                                                                                                                                                    |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `group_create` 🔑   | Make a group for terminals to talk in (lowercase letters, digits, dashes). The maker is a member.                                                                                                               |
| `group_destroy` 🔑  | Take a group off the list. Every day file stays on disk; what goes is the group, its members and its tasks. Refused with `GroupActive` while any terminal in it is still open — `group_remove` them first, yourself included. |
| `group_add` 🔑      | Put a terminal in a group. `history: none` starts it from now, `all` hands it everything still on the log.                                                                                                      |
| `group_remove` 🔑   | Take a terminal out of a group.                                                                                                                                                                                 |
| `group_members`     | Who is in a group and what each terminal is currently called. Worth reading before handing out work: a group can't reach a terminal that isn't in it.                                                            |
| `group_post`        | Say something in a group you're in. Others are told there's a message; when they read it is theirs to decide.                                                                                                   |
| `group_read`        | The messages you haven't seen. Pass the last `seq` as `since` to carry on. A message marked `summary` stands in for older ones that were compacted away.                                                        |
| `group_list`        | Which groups you're in.                                                                                                                                                                                         |
| `group_history`     | Further back than memory holds, read from the day files. Page with `before_seq`, using the smallest `log_seq` you've seen; `more: false` means you're at the beginning. The in-group `seq` is always 0 here — the log doesn't record it. |
| `group_compact` 🔑  | Replace everything up to `through` with a summary you write. `/compact`, for a conversation.                                                                                                                    |
| `group_set_brief` 🔑 | Say what a group is for, in your own words. Write it right after creating one — in eight hours `group_list` shows a name you no longer recognise, and that's exactly when you have to decide whether it still needs minding. Only you and the person at the keyboard see it. |

### The task panel

The panel is the only thing that survives a restart, a compaction and the night.
Handing out work is four steps: `task_create` → `group_post` for the record →
`terminal_send` with the actual instruction → `task_assign`.

| Tool              | What it does                                                                                                                                                                                                          |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `task_create` 🔑  | Put one line on a group's panel; it answers with a task number. The acceptance test and the detail go in the message you send the worker, not here. Only in a group you made.                                          |
| `task_assign` 🔑  | Say which terminal is doing it. A line is typed into that terminal saying the task is theirs, and only then does the panel record it — an assignment nobody was told about is one only you can see, and the group cannot carry it because a watched terminal isn't woken by a post. **Read the reply**: if the terminal could not be told, nothing was assigned. What the work *is* still goes in your own `terminal_send`. id `0` takes it back off somebody without cancelling it, and types nothing. |
| `task_close` 🔑   | The work is done and you've checked it. Nothing is sent to the worker: it finished, it reported, this is you agreeing. It stays on the panel to read back in the morning and leaves the worker's own `task_list`.       |
| `task_cancel` 🔑  | Call a task off. A line is typed into the worker's terminal telling it to stop, and only then does the task leave its list — otherwise it has no reason to look at the panel again and carries on with work nobody wants. **Read the reply**: it says whether the worker was actually told. If its terminal has gone, this refuses and the task stays open rather than pretending. |
| `task_progress`   | Move one of your own along: `queued`, `working`, `blocked`, `done`. Yours only, and only while it's open — a closed or cancelled one refuses, which is how you find out you missed a cancellation. Set `blocked` the moment it's true; that's the one a supervisor is watching for. `done` says you believe it's finished, not that it's closed. Report in the group too, naming the number. |
| `task_list`       | The tasks in a group. A supervisor is handed the whole panel, closed and cancelled included; anybody else is handed its own still-open tasks and nothing else — what your peers are doing isn't yours to spend context on. |

### Who you are, and whether you're on duty

| Tool                | What it does                                                                                                                                                                                                     |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `me`                | Which terminal you're running in, and whether you're supervising or supervised.                                                                                                                                  |
| `become_supervisor` | Put yourself forward, when there's work needing co-ordination and nobody is doing it. No arguments. Allowed if nobody is minding you; refused if somebody is — you already have a supervisor, and text arriving in a watched terminal must not be able to rearrange who may reach whom. |
| `stand_down` 🔑     | Stop being one, once the work is finished. Let each terminal go with `set_watch(id, false)` first; refused while you still mind any. Say in the group that you're finishing and why, because afterwards only the user can appoint you again. If the user said the standing is theirs alone to withdraw this comes back `StandingInstruction`, and the answer is to say so rather than look for another way. |
| `clock_out` 🔑      | Mark a terminal done for the day, so its going quiet stops being reported. Refused for one the user is holding to its work.                                                                                       |
| `clock_in` 🔑       | Put one back on duty.                                                                                                                                                                                            |

### Watching, and being told

| Tool                           | What it does                                                                                                                                                                                          |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `set_watch` 🔑                 | Take a terminal under your eye, or let it go. Watching puts its quiet spells in your `notices` and marks the terminal, which is what puts it out of a non-supervisor's reach. It is _not_ why you can read it — any supervisor can read and type into any terminal. `watch` is required and must be spelled exactly; a wrong argument is refused rather than ignored, because the two directions are not equally easy to undo. |
| `set_quiescence_threshold` 🔑  | How long a given terminal must sit still before it counts as quiet, in milliseconds.                                                                                                                  |
| `notices` 🔑                   | What you haven't been shown yet: who went quiet and for how long, who came back. Reading clears them, so nothing arrives twice. You're handed this on a timer too, but calling it yourself each time you finish something beats being interrupted. |
| `notify_user` 🔑               | Ask for the person to be told. `reason: authorisation` for a terminal stopped on a permission prompt — nobody may answer those for it, so they go out at any hour. `reason: scheduling` for a question you could answer yourself (keep going, change tack, give up); those are held back during the hours the user set aside and handed back to you to decide. **Read the reply**: it says whether the message went anywhere. |

### Plugins and settings

| Tool                  | What it does                                                                                                                                                                                                    |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `plugin_list` 🔑      | Which plugins are installed, whether they're on, and what each takes. Configured values don't come back in the clear: a reference (`env:`, `file:`, `keychain:`, `cmd:`) is shown as the user wrote it — where a secret is kept is not the secret — and a value typed in the clear is reported only as set. A long-running archiver also reports its progress and health. |
| `plugin_configure` 🔑 | Switch a plugin on and set its arguments. Credentials may only be given as references — a parameter the plugin marks secret refuses plaintext and says so. `cmd:` is refused outright: that's a command Polter would run later on its own, outside whatever authorised you now, so describe the line and let the user write it. Switching a plugin **off** is refused too — that's the user's channel for hearing things. Read the reply to see whether the change took effect at once or wants a restart. |
| `plugin_test` 🔑      | Prove a plugin works before the night that needs it. A notification plugin really does send one, in Polter's own words, whatever the hour — so do it once, on purpose. An archiver isn't started a second time; what comes back is how the running one is doing, which is usually the answer to "why is nothing being archived". |
| `config_get` 🔑       | What the user has configured — `poltergeist-notice-interval`, `poltergeist-notify-window`, `poltergeist-supervisor-stand-down`, or everything with no key (long, and cut off at the same budget a conversation gets). Read only, and worth reading before you're refused something: the hours you may not disturb anybody and whether you may take yourself off duty are both in here. |

### Surviving a restart, and the skills

| Tool                | What it does                                                                                                                                                                                                     |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `session_recall` 🔑 | Last night's arrangement, written down before the restart: the groups, what each was for, and for every terminal where it was working and what it was called. Read it first after a restart, then look at what's open now and work out for yourself which is which — nothing here does that matching for you, and a wrong guess attaches one terminal's supervision to another without saying so. |
| `skill_read`        | The text of one of Polter's own skills, by `name`. Start with `supervising`.                                                                                                                                     |

### The skills that ship with it

Judgement lives in Markdown, not in the binary. Three files ship, all readable
with `skill_read`:

| Skill                  | When it's for                                                                                                                                                                    |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `supervising`          | Being the supervisor: making a group and handing out work, judging who's stuck from how long a screen has been still, deciding whether to nudge or wait, and writing the arrangement down so it survives a restart. Start here. |
| `reading-a-terminal`   | Telling from what's on a screen what state the agent in it is in — thinking, stopped on a prompt, waiting for authorisation, finished, or actually dead. For when a quiet report lands and you're deciding whether to interrupt. Read it alongside `terminal_read`. |
| `operating-a-terminal` | For an agent that isn't a supervisor but has to touch another tab in the window: reading the marks in `terminal_list` before touching anything, typing, interrupting with `ctrl+c`, stopping a service and starting it again — and why a call was refused. |

A copy at `$XDG_CONFIG_HOME/polter/skills/<name>.md` is checked before the
shipped one, so editing a file is how you change how Polter supervises without
touching the install. The `claude-code` plugin also mirrors them into
`~/.claude/skills/polter-*`, which is what makes Claude Code offer them by name.

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
  at 9pm still exists at 3am, and for nothing else; the argument for where that
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

Both on by default, both `less`, `grep` and `jq` on the morning after:

- `$XDG_STATE_HOME/polter/chat/` — what the agents said to each other.
- `$XDG_STATE_HOME/polter/terminals/` — what actually happened in each terminal.
  One directory per terminal, one file per day, JSON per line. **Nothing is
  redacted; treat it like your shell history.**

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

## If the agent says it has no polter tools

Polter puts a socket path and a token in every terminal's environment, which is
all an agent needs to _reach_ it — but an MCP client only loads servers it's
been configured with.

Doing that configuration is a plugin's job, not the core's
(`src/poltergeist/provision.zig` says why). The **`claude-code`** plugin ships
switched on and does it: `claude mcp add --scope user`, plus a copy of Polter's
skills into `~/.claude/skills/polter-*`. So the usual causes are that the plugin
is off, that `claude` wasn't on `PATH` when Polter started, or that
`poltergeist-register-mcp` is off. When registration is wanted and no
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
  what says which terminal an agent is, and an agent can't claim to be another.
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

### The two that ship with it

Both are installed with Polter and both are on by default. Neither asks for the
network.

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

Notification channels are yours to drop in; there are dozens and shipping any
one would date immediately.

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
