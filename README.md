<h1 align="center">
  <img src="images/icons/icon_256.png" alt="" width="128">
  <br>Polter
</h1>

<p align="center">
  <b>Put one Claude Code session in charge of the others.</b><br>
  <sub>A terminal for running several coding agents in parallel. One session is the
  supervisor: over MCP it reads the text on the others' screens, types into them,
  opens new tabs, and minds them while you're asleep.<br>
  Polter itself has no account and no API key, and makes no network calls of its
  own — except one request to GitHub, and only when you choose Check for Updates.</sub>
</p>

<p align="center">
  <a href="#download">Download</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#compared-to">Compared to</a> ·
  <a href="#settings">Settings</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="README_CN.md">中文</a>
</p>

<p align="center">
  <img src="images/screenshots/group-chat.png" alt="A group chat with several worker terminals, showing a supervisor handing out numbered tasks" width="46%">
  <img src="images/screenshots/group-total.png" alt="The statistics view: which tasks are waiting and how long each terminal has been still" width="52%">
</p>

---

### What it does

Several Claude Code and Codex windows at once are hard to coordinate, sub-agents stop partway through a long run, and an overnight job tends to knock off after two hours. Polter is a terminal with an MCP server built in, so that one agent can orchestrate the rest. You mark one tab as the **supervisor**. It's an ordinary Claude Code session, with these added:

- Read the text on any tab's screen (text, not screenshots)
- Type into any tab
- Open new tabs and splits, and start agents in them
- Make a group chat, hand out tasks, take reports; the panel survives a restart
- Get told how long any tab's screen has been still

A worker is not a sub-agent. It's an independent session in its own terminal, and what it did lands on disk line by line — you can `grep` it in the morning.

The supervisor is not polling. Polter pushes a notice when a screen has stopped moving, so what a quiet night costs in tokens follows how often something stalled, not how long the job ran.

### What else is in it

- **Roles.** A role is a saved way to start an agent CLI: which of its skills and MCP servers it keeps, what it is told on top of its system prompt, which model. They live under `Agents → Role`, and a supervisor can start its own workers wearing one.
- **Projects.** `Project → Save as Project…` keeps a tab — its splits, each pane's directory, command history and scrollback — and `Load Project…` brings it back. macOS and Windows; not on Linux.
- **Who may answer a prompt.** A supervisor may answer permission prompts in the terminals it opened itself, and in no others unless you say so, one terminal at a time (`Agents → Let a Supervisor Answer Prompts Here`). No tool can switch it on, and you can switch it off in a terminal the supervisor opened.
- **One settings window.** Roles, projects, plugins and the config file, in one place and the same on both platforms (`Settings…`).
- **Hooks.** A Claude Code started from a role tells Polter when a turn ends and what it said, so the supervisor is told rather than left to read a still screen. Claude Code only; every other CLI is still watched by its screen.
- **English and Chinese.** The menus and windows follow the system language, or the one picked under `Language`.

### Download

[**Latest release**](https://github.com/Lugia123/polter/releases/latest)

| | |
| --- | --- |
| **macOS 13+** | `Polter-*-macos-universal.zip`, Apple Silicon and Intel in one bundle |
| **Windows 10+** | `Polter-*-windows-x64.zip`, 70 of the core's 76 actions implemented, 4 refused by name, 2 owed (2026-09-21; how these are counted: `dev-docs/windows/status.md` §2.2 item 2) |
| **Linux** | No binary. Build from source. |

The **macOS** builds are unsigned, so Gatekeeper will stop them:

```sh
unzip Polter-*-macos-universal.zip
xattr -dr com.apple.quarantine Polter.app
mv Polter.app /Applications/
```

Then **open it from Finder or the Dock, not from a terminal** — the `PATH` differs, and the provisioning plugin won't find your agent CLI.

On **Windows**, unzip and run `polter-host.exe`, keeping everything else in the zip beside it — the DLLs, `polter-cli.exe` and `share/`. SmartScreen will ask you to click "Run anyway".

### Prerequisites

An agent CLI, on your `PATH`, and on it at the moment Polter starts. Only tested with Claude Code.

### Quick start

**1. Open a tab and start Claude Code in it.** `cd` to the directory you want it working in.

**2. Mark that tab as the supervisor.** `Agents → Make This Terminal a Supervisor`. Polter then types a line into that tab telling the agent to read its `supervising` skill.

Before going further, check the tools are there. Ask it:

> Call the `me` tool and tell me what it says.

A terminal id back means you're set. If it says it has no such tool, stop here and see the [FAQ](#faq).

**3. Tell it what the job is.** Making the group, opening tabs, claiming them, timing them — all its own. You don't quote terminal ids and you don't name tools.

**4. Go to bed.** Come back to `Agents → Terminal Conversations` (or `polter +chat`) to read what they said. `tab` and `shift+tab` cycle three views: the conversation, the task panel, and the night's account.

### Compared to

Polter's own column is what this repository does. The other columns are from each project's own README or manual, read on 2026-10-04.

| | Polter | tmux | Claude Code sub-agents | [Claude Squad](https://github.com/smtg-ai/claude-squad) | [cmux](https://github.com/manaflow-ai/cmux) |
| --- | --- | --- | --- | --- | --- |
| What it is | A terminal (a Ghostty fork) with an MCP server in it | A terminal multiplexer | A feature inside one Claude Code session | A TUI over tmux and git worktrees | A Ghostty-based macOS terminal |
| Who watches the agents | Another agent, the supervisor | You | The parent session | You, in one window | You, by notification rings and a sidebar |
| A worker is | Its own session in its own terminal | Whatever you start in a pane | A sub-agent of the parent | Its own session in its own worktree | Whatever you start in a pane |
| When one stops moving | The supervisor is told how long it has been still | A highlight in the status line and a bell, if you set `monitor-silence` | — | — | A ring, when the agent signals it |
| Isolation between workers | None of its own; they share your checkout | None | The parent's directory, or a worktree if you ask for one | A git worktree and branch each | None |
| Platforms | macOS, Windows | Unix-like systems | Wherever Claude Code runs | Needs tmux and `gh` | macOS |

What Polter does not have, from that table: it gives workers no worktree of their own, and it has no browser pane, which cmux has. If isolation per task is what you need, Claude Squad's model is the one built for it.

### Settings

Everything has a working default; you can run it without touching any of them. The ones worth knowing:

| Setting | What it does |
| --- | --- |
| `poltergeist-watch` | Whether terminal screens are sampled. Off by default; the supervisor turns it on per terminal with `set_watch`. |
| `poltergeist-quiescence-after` | How long a screen stays still before the supervisor is told |
| `poltergeist-register-mcp` | Whether to register the MCP server at startup. On by default. |

Everything lands under `$XDG_STATE_HOME/polter/`: `chat/` is what the agents said to each other, `terminals/` is what happened in each terminal, `tasks/` is every change to the panel, `stats/` is one line per group per hour. Nothing is redacted — treat it like your shell history.

### What it doesn't do today

- **Won't answer a permission prompt in a terminal you started, unless you said it may there.** It tells you instead. In a terminal the supervisor opened, it may.
- **Won't let an agent undo a lock you set.** The hold and the shield are yours to set and yours to lift.
- **Won't grow into a task system.** The panel holds who is on what, and whether it's done.
- **Won't be a way around an agent's own permissions.** `terminal_send` sends text only, down the paste path, with control bytes turned into spaces.

### FAQ

**The agent says it has no polter tools.** Three causes: the plugin is off, `claude` wasn't on `PATH` when Polter started, or `poltergeist-register-mcp` is off. The registration points at whichever build started last.

**Does it work with other CLIs?** The server is plain MCP, so any MCP client can run it, and seven provisioning plugins ship with it. Only tested with Claude Code — treat the rest as untested.

**Isn't this tmux?** No. tmux arranges panes and leaves the watching to you. Polter tells one agent how long each of the others has been still and lets it read their screens and type into them.

**How does it know an agent is stuck?** It doesn't. It measures one thing — how long a screen has been unchanged — and parses no CLI's output. Whether that's stuck or thinking is the supervisor's call.

**Is this related to Poltergeist?** No. [steipete/poltergeist](https://github.com/steipete/poltergeist) is a file watcher and build tool, and its wrapper command is also called `polter`. The two projects share a ghost and nothing else; `poltergeist-*` here is only the prefix of this project's settings.

**How do I write a plugin?** A directory, a `plugin.json`, and an executable. Twenty lines of shell is a complete plugin.

### Relationship to Ghostty

Everything that makes this a good terminal is [Ghostty](https://github.com/ghostty-org/ghostty)'s doing. Polter is a fork, not a rewrite: the renderer, the VT implementation, the font stack and the native UI are all theirs, and upstream changes get merged in.

So everything about the terminal itself belongs upstream: escape sequences, performance, configuration, keybindings, `libghostty`. See [ghostty.org/docs](https://ghostty.org/docs) and read `ghostty` as `polter`.

What Polter adds is `src/poltergeist/`, the MCP tool surface, the chat TUI, terminal transcripts and the plugin host. This project is not affiliated with the Ghostty project — don't file bugs found here over there unless they reproduce on upstream Ghostty.

Building is in [`dev-docs/preview-manual.md`](dev-docs/preview-manual.md); the design reasoning is under [`dev-docs/poltergeist/`](dev-docs/poltergeist/README.md).

MIT, same as upstream.

---

Thanks to the [LINUX DO](https://linux.do) community, where Polter was first shared.
