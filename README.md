<h1>
<p align="center">
  <img src="images/icons/icon_256.png" alt="Polter" width="128">
  <br>Polter
</h1>
  <p align="center">
    A terminal that keeps an eye on your AI agents while you sleep.
    <br />
    <a href="#what-it-is">What it is</a>
    ·
    <a href="#what-it-gives-you">What it gives you</a>
    ·
    <a href="#quick-start">Quick start</a>
    ·
    <a href="#a-full-example">Example</a>
    ·
    <a href="#what-it-will-never-do">What it won't do</a>
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

Status: **an experiment that works.** It's been run end to end with the real
Claude Code CLI, and the bugs that found were ones no unit test could have.

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
`src/poltergeist/rpc.zig`), and the list is deliberately short:

- **See** — `terminal_list` (how long each screen has been still, what marks it
  carries), `terminal_read`, `notices`, `session_recall` (what last night's
  arrangement was), `config_get`.
- **Talk** — `group_create`, `group_add`, `group_remove`, `group_destroy`,
  `group_post`, `group_read`, `group_history`, `group_members`, `group_compact`,
  `group_set_brief`, `group_list`.
- **Steer** — `terminal_send` (type), `terminal_key` (press `ctrl+c`, `escape`…),
  `terminal_action` (anything the menu bar does), `terminal_open` (a new tab in a
  directory it picks), `set_watch`, `clock_out` / `clock_in`,
  `set_quiescence_threshold`, `become_supervisor`, `stand_down`.
- **Reach you** — `notify_user`, through a plugin.
- **Set up a plugin** — `plugin_list`, `plugin_configure`, `plugin_test`.

Two lines run through that list.

**Arranging is the supervisor's.** Claiming terminals, the clock, making groups,
notifying you, opening tabs, the plugin tools — because a terminal that could
claim other terminals would be a second, quieter road to being in charge.
Talking _inside_ a group you're already in isn't arranging anything, so the chat
tools are open to every member: a team that can't talk isn't a team.

**Operating a terminal isn't arranging either.** Reading a screen, typing,
pressing a key, doing a menu action — those are open to any agent, and what
decides whether the call goes through is the _target's_ mark, not who's asking.
An agent in one tab may restart a server in another tab that nobody is watching.
It may not touch one that's watched, shielded, or a supervisor.

## What it will never do

Four of these, and they're the reason to trust the rest:

- **Never answer a permission prompt for an agent.** No allow-list, no flag.
  Pressing "yes" on someone else's authorisation defeats their safety model. You
  get told instead, at any hour.
- **Never let an agent unlock what you locked.** The hold and the shield are
  yours. The tool surface can read that a hold exists; it cannot change it.
- **Never manage your tasks.** A group carries a note saying what it's for.
  Giving that note a status field is where a task tracker starts, and there are
  enough of those.
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

Two ship with Polter, both on: **`archive`** (an extra copy of every chat message
on disk — point it at a synced folder and the copy outlives this machine) and
**`claude-code`** (the registration described above). Notification channels are
yours to drop in; there are dozens and shipping any one would date immediately.

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
