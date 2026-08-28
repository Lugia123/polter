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
- **Never let an agent put text in another agent's input box uninvited.**
  Reach is a star, not a mesh: the supervisor can reach the terminals the
  user placed under it, and they cannot reach each other.

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

You may want one thing on this side: **Agents → Keep This Terminal
Working** marks a tab as one that must not be clocked off. Only you can
set or lift it; a supervisor asking to clock that terminal off is refused.

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
- If a terminal stops on a tool-authorisation prompt, you are notified --
  at any hour, and regardless of `poltergeist-notify-window`. Nobody may
  answer those for you. That notification needs a plugin configured; see
  [Plugins](#plugins).

### If the tools are not there

If the agent says it has no `polter` tools, the registration did not
happen. At startup, when `poltergeist-register-mcp` is on (it is by
default), Polter runs `claude mcp add --scope user polter -e
POLTER_REGISTERED=<version> -- <path to polter> +mcp`, and only when the
existing entry does not already point at this build. So the usual causes
are that `claude` was not on `PATH` when Polter started, or that
`poltergeist-mcp` was turned off. Restart Polter with `claude` on
`PATH`, or register it yourself; see
[Which agents this works with](#which-agents-this-works-with).

**The registration names one build, and the last one to start wins.** It is
rewritten whenever the entry does not name the running executable, and the
path it writes is that executable's own -- so starting a build from a work
tree silently repoints your user-scoped `polter` entry at it, and the
installed app's registration is gone until you next start the installed
app. That is what you want while developing and not what you want
afterwards. If a build you no longer have is registered, start the one you
mean to keep, or set `poltergeist-register-mcp = false` and manage the
entry yourself with `claude mcp`.

### The settings worth knowing about

None of them are required to get started. `polter +show-config --default
--docs` prints every option with its documentation.

| Option | Default | What it is for |
| --- | --- | --- |
| `poltergeist-mcp` | `true` | Open the agent socket at all. `false` gives you a plain terminal. |
| `poltergeist-register-mcp` | `true` | Register Polter with Claude Code so the tools appear. |
| `poltergeist-watch` | `false` | Whether a terminal is sampled **from the moment it opens**. You do not need this to get started: claiming a terminal starts its sampler either way. Turn it on if you would rather every terminal be watched from birth. |
| `poltergeist-quiescence-after` | `3m` | How long a screen must be unchanged before it is reported. |
| `poltergeist-notice-interval` | `1m` | How often the supervisor may be interrupted with what it has not seen. |
| `poltergeist-notify-window` | empty | The hours you may be disturbed, as `HH:MM-HH:MM`. Authorisation prompts ignore it. |
| `poltergeist-chat-log` | `true` | Write what the terminals say to each other under `$XDG_STATE_HOME/polter/chat/`. |

## What the supervisor can actually do

Everything an agent does here goes through one MCP surface --
`src/cli/mcp.zig` -- and the list is deliberately short. It can:

- **See**: `terminal_list` for how long each screen has been unchanged,
  `terminal_read` for what is on one, `notices` for what has happened
  since it last looked, `session_recall` for what last night's arrangement
  was.
- **Talk**: `group_create`, `group_add`, `group_post`, `group_read`,
  `group_history`, `group_compact`, `group_set_brief`.
- **Steer**: `terminal_send` to type into a terminal it is minding,
  `terminal_open` to start one in a directory it chooses, `terminal_action`
  to do what the menu bar does, `set_watch` to decide its own reach,
  `clock_out` and `clock_in`, `stand_down` when the work is done.
- **Reach you**: `notify_user`, through the plugins below.

There is no tool for answering another agent's permission prompt, and
there is no tool for lifting the hold you put on a terminal. Neither will
be added; `src/poltergeist/rpc.zig` says why at the point where they are
not.

## Which agents this works with

**Claude Code is the only agent this works with out of the box, and the
only one it has been tested with.** The precise shape is worth stating,
because it is not "Claude Code only":

- **The server itself is ordinary MCP.** `polter +mcp` speaks standard
  MCP over a unix socket (`src/cli/mcp.zig`). Any MCP client can connect
  to it. Every terminal gets `GHOSTTY_POLTER_SOCKET` and its own
  `GHOSTTY_POLTER_TOKEN` in its environment; the token is what says which
  terminal an agent is, and an agent cannot claim to be a different one.
- **What is Claude Code-specific is the setup.**
  `src/poltergeist/register.zig` runs `claude mcp add --scope user` so the
  tools appear in any directory, and mirrors Polter's skills into
  `~/.claude/skills/polter-supervising/` and
  `~/.claude/skills/polter-reading-a-terminal/` so that runtime can match
  them against what you asked for. Both are conveniences, and both are
  Claude Code's own mechanisms.
- **No `claude` on `PATH` is not an error.** Registration reports
  `unavailable` and Polter carries on unchanged -- the comment in
  `register.zig` says it plainly: the agent may be something else
  entirely.

So another agent can in principle use all of this. It would have to
register the MCP server with its own runtime, pointing at `polter +mcp`,
and find its own way to put the `supervising` skill in front of the model
-- the `skill_read` tool hands the text over, but something has to think
to call it. **We have not tested that with any other agent.** If you try
it, treat it as untested rather than supported.

## Plugins

A plugin is a directory with a `plugin.json` and one executable. Polter
writes JSON to its stdin; that is the whole interface, so a twenty-line
shell script is a complete plugin.

There are two kinds:

- **`notify`** -- one process per notification. Polter writes one line of
  JSON, closes stdin, and reads the exit code: `0` means delivered.
  Used when a terminal needs you.
- **`archive`** -- **resident**. It is handed a stream of newline-delimited
  batches from the chat log and acknowledges each one, keeping a cursor so
  a restart picks up where it left off.

Two ship with Polter: **`webhook`** (POST the notice as JSON to a URL --
Feishu, Slack, Discord, ntfy) and **`chat-archive`** (follow the chat log
into Postgres or a JSONL file).

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
move. For the same reason an agent may switch a
plugin **on** but never **off**: notifications are the channel you hear
about things on, and an agent able to close it can turn its own lights
off. Writing plaintext into a parameter the manifest marks `secret` is
refused too. **Hand-editing the file yourself has none of these
restrictions** -- the asymmetry is about whose hand it is.

You configure plugins from **Agents → Plugins**; a supervisor can also use
`plugin_list`, `plugin_configure` and `plugin_test`. `plugin_test` really
sends a notification, at whatever hour it is, so use it once, deliberately
-- before the night you need it.

Full contract in [`docs/poltergeist/plugins.md`](docs/poltergeist/plugins.md),
a walkthrough of writing one in
[`docs/poltergeist/writing-a-plugin.md`](docs/poltergeist/writing-a-plugin.md),
and the resident half in [`docs/poltergeist/storage.md`](docs/poltergeist/storage.md).

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
TUI, and the notification plugins. It is not affiliated with the Ghostty
project, and bugs found here should not be reported there unless they
reproduce on upstream Ghostty.

MIT licensed, the same as upstream; see [LICENSE](LICENSE), which keeps
the original copyright.

## Building and docs

`zig build` builds it; `docs/preview-manual.md` is the authority on
building, running and debugging, and `docs/README.md` indexes the rest.
The design of everything above is argued out in
[`docs/poltergeist/`](docs/poltergeist/README.md) -- start with its
`README.md`, which is the constitution the other chapters answer to.
