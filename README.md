<h1>
<p align="center">
  <img src="images/icons/icon_256.png" alt="Polter" width="128">
  <br>Polter
</h1>
  <p align="center">
    A terminal that can mind several AI agents at once.
    <br />
    <a href="#what-this-is">What this is</a>
    ·
    <a href="#getting-started">Getting started</a>
    ·
    <a href="#which-agents-this-works-with">Which agents</a>
    ·
    <a href="#plugins">Plugins</a>
    ·
    <a href="#relationship-to-ghostty">Relationship to Ghostty</a>
  </p>
</p>

## What this is

Polter is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) that
turns the terminal into a host for agent loops. Several terminals run AI
agents; one of them is the **supervisor** and can see how long the others
have been still, read their screens, talk to them in group chats, and
decide what to do about it.

The program itself never judges. It measures how long a screen has gone
unchanged and carries messages -- **is that agent stuck or thinking** is a
question it refuses to answer, because answering it wrongly is worse than
not answering. That judgement belongs to the supervisor, and the boundary
is argued out in [`docs/poltergeist/`](docs/poltergeist/README.md).

Some things it deliberately will not do:

- **Never answer a permission prompt for an agent.** Not even optionally,
  and there is no allow-list to turn on. Pressing "yes" on somebody else's
  authorisation defeats their safety model, so when one is waiting the
  person is told -- at any hour, because nobody else may answer it.
- **Never manage your tasks.** A group can carry a note saying what it is
  for. Giving that note a status field would be the start of a task
  tracker, and there are enough of those.
- **Never touch a terminal somebody else has arranged something around.**
  What decides whether an agent may reach a terminal is that terminal's
  own mark, not who is asking: a supervisor may reach any Polter terminal,
  and anybody else may reach only a terminal that carries no mark at all.
  An agent that is being watched, or that is a supervisor, is somebody's
  arrangement, and rearranging it is not a stranger's to do.
- **Never press Polter's own switches.** The menu items that make a
  supervisor, hold a terminal to its work, or shield it are the user's;
  the tool that opens the rest of the menu to an agent refuses every one
  of them. This closed a real hole -- an agent could lift the hold you had
  set and then clock the terminal off a moment later.

Status: **an experiment that works**. It has been run end to end with the
real Claude Code CLI, and several fatal bugs it found were ones no unit
test could have -- see the verification notes in the design docs.

## Getting started

The shortest useful path: open some tabs, start an agent in each, make one
of them the supervisor, and tell that one what the work is. Nothing below
requires editing a config file.

### 1. Open the tabs and start the agents

Polter does not start agents and does not hand out their work. Open a tab
per piece of work, `cd` to the right directory, and start Claude Code in
each one the way you always do. One of those tabs will become the
supervisor; give it the tab you would have used to keep an eye on things
anyway.

### 2. Make one terminal the supervisor

In that tab, use **Agents → Make This Terminal a Supervisor** (it is also
in the command palette, and bindable to a key as the `poltergeist_supervisor`
action -- there is no default binding). The same item toggles it back off,
and a window may hold more than one supervisor, each minding its own piece
of work.

The moment you do this, Polter types a line into that terminal telling the
agent what just happened and to read its `supervising` skill first. So the
agent has already been told the mechanics before you say anything.

An agent can also ask for the job itself, with the `become_supervisor`
tool. That is open to a terminal nobody is watching and refused to one
that is: a watched terminal is the likeliest to be reading things off the
network, and a line of injected text must not be able to promote anybody.

### 3. Say what the work is

That is the whole of your job. The supervisor sets up the groups, claims
the terminals and starts the clocks itself. Something like:

> You are the supervisor now. Three tabs beside you: one porting the
> parser, one on the docs, one running the fuzzers. Put them in a group,
> watch all three, and check on them while I sleep. Wake me only if one is
> stopped on a permission prompt.

or, shorter:

> Take charge of the other tabs in this window. Group them, watch them,
> and keep them moving; tell me in the morning what happened.

You do not have to name terminal ids or tools. The supervisor calls
`terminal_list` to see what is open, `group_create` and `group_set_brief`
to make somewhere to talk, `set_watch` to claim each terminal, and
`group_add` to put them in the conversation -- that sequence is what its
skill tells it to do.

### 4. The supervised tabs need nothing

Nothing to install, nothing to enable, nothing to type. When a supervisor
claims a terminal, Polter tells the agent in it that it is being watched
and that its screen may be read. Sampling for that terminal starts at the
same moment.

There are two marks on this side that only you can set, and they do
different jobs:

- **Agents → Keep This Terminal Working** marks a tab as one that must not
  be clocked off. Only you can set or lift it; a supervisor asking to
  clock that terminal off is refused.
- **Agents → Keep Agents Out of This Terminal** puts a tab out of reach of
  the tool surface entirely. This one is absolute: it refuses supervisors
  and plugins too, which the hold does not. Use it for the tab you are
  reading your own mail in.

Both show on the tab rather than only in a menu, because a guarantee you
were told about once is a guarantee you will not remember at three in the
morning: a held terminal's mark gains a ring (`◉` moving, `◎` still), and
a shielded one is prefixed with a padlock whatever else it is doing.

### What to expect afterwards

- Reports do not reach the supervisor as they happen. They collect, one
  entry per terminal, and are handed over on `poltergeist-notice-interval`
  (a minute by default) as a single line. The supervisor can also look
  whenever it likes with the `notices` tool.
- A terminal counts as quiet after `poltergeist-quiescence-after` (three
  minutes by default) of an unchanged screen; a still-quiet terminal is
  re-reported every `poltergeist-quiescence-repeat` (fifteen minutes).
- **Agents → Terminal Conversations** opens the chat, so you can read what
  they have been saying to each other. It is also `polter +chat`.
- What the agents said to each other is written under
  `$XDG_STATE_HOME/polter/chat/`, and what actually ran in each terminal
  is written under `$XDG_STATE_HOME/polter/terminals/` -- one directory
  per terminal, one file per day, JSON per line. Both are on by default
  (`poltergeist-chat-log`, `poltergeist-terminal-log`) and both are
  `less`, `grep` and `jq` on the morning after.
- If a terminal stops on a tool-authorisation prompt, you are notified --
  at any hour, and regardless of `poltergeist-notify-window`. Nobody may
  answer those for you. That notification needs a plugin configured; see
  [Plugins](#plugins).

### If the tools are not there

If the agent says it has no `polter` tools, nothing told its runtime that
Polter exists. Polter puts a socket path and a token in every terminal's
environment, which is all an agent needs to *reach* it -- but an MCP
client only loads servers it has been configured with.

Doing that configuration is a plugin's job, not the core's
(`src/poltergeist/provision.zig` says why). The **`claude-code`** plugin
ships switched on and does it: it runs `claude mcp add --scope user` and
mirrors Polter's skills into `~/.claude/skills/polter-*`. So the usual
causes are that the plugin was switched off, that `claude` was not on
`PATH` when Polter started, or that `poltergeist-register-mcp` was turned
off. When registration is asked for and no provisioning plugin is switched
on, Polter says so on a terminal screen rather than only in a log.

**The registration names one build, and the last one to start wins.** It
is rewritten whenever the existing entry does not name the running
executable, and the path it writes is that executable's own -- so starting
a build from a work tree silently repoints your user-scoped `polter` entry
at it, and the installed app's registration is gone until you next start
the installed app. That is what you want while developing and not what you
want afterwards. If a build you no longer have is registered, start the
one you mean to keep, or set `poltergeist-register-mcp = false` and manage
the entry yourself with `claude mcp`.

### The settings worth knowing about

None of them are required to get started. `polter +show-config --default
--docs` prints every option with its documentation.

| Option | Default | What it is for |
| --- | --- | --- |
| `poltergeist-mcp` | `true` | Open the agent socket at all. `false` gives you a plain terminal. |
| `poltergeist-register-mcp` | `true` | Let a provisioning plugin tell an agent runtime that Polter's tools exist. |
| `poltergeist-watch` | `false` | Whether a terminal is sampled **from the moment it opens**. You do not need this to get started: claiming a terminal starts its sampler either way. Turn it on if you would rather every terminal be watched from birth. |
| `poltergeist-quiescence-after` | `3m` | How long a screen must be unchanged before it is reported. |
| `poltergeist-quiescence-repeat` | `15m` | How often a terminal that is *still* quiet is reported again. |
| `poltergeist-notice-interval` | `1m` | How often the supervisor may be interrupted with what it has not seen. |
| `poltergeist-supervisor-stand-down` | `true` | Whether a supervisor may take itself off duty when the work is done. `false` makes the standing yours alone to withdraw. |
| `poltergeist-notify-window` | empty | The hours you may be disturbed, as `HH:MM-HH:MM`. Authorisation prompts ignore it. |
| `poltergeist-chat-log` | `true` | Write what the terminals say to each other under `$XDG_STATE_HOME/polter/chat/`. |
| `poltergeist-terminal-log` | `true` | Write what actually ran in each terminal under `$XDG_STATE_HOME/polter/terminals/`. Nothing is redacted -- treat it like your shell history. |

## What the supervisor can actually do

Everything an agent does here goes through one MCP surface --
`src/cli/mcp.zig` in front of `src/poltergeist/rpc.zig` -- and the list is
deliberately short. It can:

- **See**: `terminal_list` for how long each screen has been unchanged and
  what marks it carries, `terminal_read` for what is on one, `notices` for
  what has happened since it last looked, `session_recall` for what last
  night's arrangement was, `config_get` for the settings it is working
  under.
- **Talk**: `group_create`, `group_add`, `group_remove`, `group_destroy`,
  `group_post`, `group_read`, `group_history`, `group_members`,
  `group_compact`, `group_set_brief`, `group_list`.
- **Steer**: `terminal_send` to type into a terminal, `terminal_key` to
  press one (`ctrl+c`, `escape`, `ctrl+shift+k` -- the keybinding
  vocabulary, listed by `terminal_keys`), `terminal_action` to do what the
  menu bar does (listed by `terminal_actions`), `terminal_open` to start a
  tab in a directory it chooses, `set_watch` to decide its own reach,
  `clock_out` and `clock_in`, `set_quiescence_threshold`,
  `become_supervisor` and `stand_down`.
- **Reach you**: `notify_user`, through the plugins below.
- **Set up a plugin**: `plugin_list`, `plugin_configure`, `plugin_test`.

Two lines run through that list. **Arranging things is the supervisor's**
-- `set_watch`, the clock, `set_quiescence_threshold`, making and
populating groups, `notify_user`, `terminal_open`, the plugin tools --
because a terminal that could claim other terminals would be a second,
looser road to standing than `become_supervisor`. Talking *inside* a group
it was already put in is not arranging anything, so `group_post`,
`group_read`, `group_history`, `group_members` and `group_list` are open
to every member: a team that cannot talk to each other is not a team.
**Operating a terminal is not arranging either**: reading a screen, typing into one,
pressing a key and doing a menu action are open to any agent, and what
decides whether the call goes through is the *target's* mark. An agent in
one tab may restart a server running in another tab that nobody is
watching; it may not touch one that is watched, or shielded, or a
supervisor.

Two things are missing on purpose. There is no tool for answering another
agent's permission prompt, and there is no tool for lifting the hold or
the shield you put on a terminal -- a supervisor that could lift the hold
would simply lift it and then clock off. Neither will be added;
`src/poltergeist/rpc.zig` says why at the point where they are not.

`terminal_send` types text and only ever text: it goes down the paste path,
which replaces every control byte with a space the way xterm does.
Pressing a key is therefore its own verb with its own authorisation, in
`src/poltergeist/keys.zig`, rather than a relaxation of that rule.

## Which agents this works with

**Claude Code is the only agent this works with out of the box, and the
only one it has been tested with.** The precise shape is worth stating,
because it is not "Claude Code only":

- **The server itself is ordinary MCP.** `polter +mcp` speaks standard
  MCP on stdio and relays it to Polter over a unix socket
  (`src/cli/mcp.zig`). Any MCP client can run it. Every terminal gets
  `GHOSTTY_POLTER_SOCKET` and its own `GHOSTTY_POLTER_TOKEN` in its
  environment; the token is what says which terminal an agent is, and an
  agent cannot claim to be a different one.
- **What is Claude Code-specific is the setup, and it is a plugin.** The
  core publishes a description of this build -- which binary serves the
  endpoint, which skills there are, where their files live -- and the
  `claude-code` plugin turns that into `claude mcp add --scope user` and a
  copy of the skills into `~/.claude/skills/polter-*`. That split is the
  point: another agent CLI needs a second plugin, not a patch to the core.
- **No `claude` on `PATH` is not an error.** The plugin says what it could
  not do, Polter puts that sentence on a terminal screen, and everything
  else carries on -- the agent may be something else entirely.

So another agent can in principle use all of this. It would have to
register the MCP server with its own runtime, pointing at `polter +mcp`,
and find its own way to put the `supervising` skill in front of the model
-- the `skill_read` tool hands the text over, but something has to think
to call it. **We have not tested that with any other agent.** If you try
it, treat it as untested rather than supported.

## Plugins

A plugin is a directory with a `plugin.json` and one executable, in
`$XDG_CONFIG_HOME/polter/plugins/`. There is **one protocol and one
lifetime**: the executable is started once and kept running, Polter writes
it a greeting and then batches of events as JSON lines on stdin, and it
answers each batch on stdout. A twenty-line shell script is still a
complete plugin.

What a plugin *is* is not a kind any more -- it is what it subscribes to.
The manifest says so:

```json
{ "wants": { "events": ["chat"], "calls": [], "groups": ["*"] } }
```

- **`chat`** -- something was said in a group.
- **`terminal.quiet`** -- a terminal has gone quiet and somebody should be
  told.
- **`provision`** -- here is what Polter is; make an agent runtime able to
  see it.

`events` is enforced: a plugin is never handed a kind it did not ask for,
`groups` decides which chat groups may appear in what it is handed, and a
plugin that asks for nothing is not started at all. (`network` and `exec`
in the same block are disclosure for you to read before installing, not a
sandbox. `src/poltergeist/Plugin.zig` says that in as many words.)

This replaced a three-valued `Kind` that decided a lifetime and a contract
at once, so every switch on it had three branches and a fourth was
forgotten -- twice, the second time in the comment left by the first.

**A plugin speaks the same wire protocol an agent speaks.** If it declares
`calls`, it gets a socket and a token and may call those tool methods,
through exactly the checks an agent goes through: an undeclared method is
refused, a supervisor's method is refused because a plugin is never a
supervisor, and a shielded terminal is out of its reach the same way it is
out of a supervisor's. `plugins/_sdk/` holds thin clients (`polter.py`,
standard library only; `polter.sh`, needing a `nc -U`) and **neither has a
function named after a tool** -- a second list of methods is a list
somebody forgets to update.

Three more things a plugin gets:

- **A log.** `$XDG_STATE_HOME/polter/plugins/<key>.log`, holding the
  plugin's own stderr *and* what Polter saw happen to it -- started,
  greeted, refused, killed, backing off -- interleaved under one clock.
  The host captures it, so a plugin has a log whether or not its author
  ever thought about one. Bounded and rotated, because a plugin gone mad
  writes a hundred thousand lines a second. **Agents → Plugins → Show
  Log** opens one.
- **A way to say something to you.** A line it writes may carry a `tell`
  string, and that goes on a terminal screen signed `polter: the "<key>"
  plugin says:` -- control bytes stripped, and rate limited so one plugin
  cannot fill the screen the second plugin's failure needed.
- **A settings page of its own, optionally.** A plugin may ship
  `ui/index.html`; macOS renders it in a `WKWebView` and the bridge is
  narrow on purpose -- the page can read and write **this plugin's own
  settings** and nothing else, cannot read its own `plugin.json`, and
  cannot reach the network. GTK has no web view and falls back to the
  declarative form, which is why the form has to stay good.

Two plugins ship with Polter and both are switched on:

- **`archive`** -- keeps an extra copy of every chat message on the
  filesystem, one file per day, all groups in one timeline. Point it at a
  synced folder and the copy outlives this machine. It is never handed
  Polter's own files: the record on disk is kept whether a plugin is
  installed or not, and what a plugin writes is a second copy.
- **`claude-code`** -- registers Polter's MCP endpoint with Claude Code
  and mirrors the skills, as described above.

Notification channels are yours to drop in: there are dozens of them and
shipping any one would date immediately.

**Credentials are stored as references, never in the clear.** A parameter
value may be `env:NAME`, `file:` a path, `keychain:service/account`, or
`cmd:` a command whose stdout is the value -- resolved at the moment the
plugin is called, never cached, and never sent as itself if resolution
fails. So the settings file can go in a dotfiles repository.

`cmd:` is the one that matters: it covers every password manager at once
with no adapter for any of them. **And it is exactly the one the tool
surface refuses to write.** An agent may set `env:`, `keychain:` or a
`file:` reference naming a path under your polter config or state
directory, but a `cmd:` it wrote would be a command Polter runs later, on
its own, outside whatever authorised the agent at the time -- so
describing the line and leaving it for you to write is the only correct
move. For the same reason an agent may switch a plugin **on** but never
**off**: notifications are the channel you hear about things on, and an
agent able to close it can turn its own lights off. Writing plaintext into
a parameter the manifest marks `secret` is refused too. **Hand-editing the
file yourself has none of these restrictions** -- the asymmetry is about
whose hand it is.

You configure plugins from **Agents → Plugins**; a supervisor can also use
`plugin_list`, `plugin_configure` and `plugin_test`. `plugin_test` really
publishes a test notification, at whatever hour it is, so use it once,
deliberately -- before the night you need it. What it answers with is not
a delivery receipt: a plugin delivers on its own thread, so what can be
said at the moment of the call is that it went out, how many channels
asked for it, and whether this plugin has a process up to receive it.

Full contract in [`docs/poltergeist/plugins.md`](docs/poltergeist/plugins.md),
including a walkthrough of writing one; the two shipped plugins have a page
each under [`docs/poltergeist/plugin/`](docs/poltergeist/plugin/README.md),
and the core's own storage -- which is not a plugin's data source -- is in
[`docs/poltergeist/storage.md`](docs/poltergeist/storage.md).

## Relationship to Ghostty

Everything that makes this a good terminal is
[Ghostty](https://github.com/ghostty-org/ghostty)'s work, by Mitchell
Hashimoto and the Ghostty contributors. Polter is a fork, not a rewrite:
the renderer, the VT implementation, the font stack and the native UIs are
all theirs, and upstream is merged in as it moves.

**So everything you want to know about the terminal itself is upstream's
to answer**: the escape sequences it supports, its performance, its
configuration, its keybindings, `libghostty`, and the crash reporter. Read
[ghostty.org/docs](https://ghostty.org/docs) and upstream's own
[README](https://github.com/ghostty-org/ghostty/blob/main/README.md); all
of it applies here, with `ghostty` spelled `polter`.

Polter adds `src/poltergeist/`, the MCP surface agents speak to, the chat
TUI, the terminal transcript and the plugin host. It is not affiliated
with the Ghostty project, and bugs found here should not be reported there
unless they reproduce on upstream Ghostty.

MIT licensed, the same as upstream; see [LICENSE](LICENSE), which keeps
the original copyright.

## Building and docs

`zig build` builds it; `docs/preview-manual.md` is the authority on
building, running and debugging, and `docs/README.md` indexes the rest.
The design of everything above is argued out in
[`docs/poltergeist/`](docs/poltergeist/README.md) -- start with its
`README.md`, which is the constitution the other chapters answer to.
