# Polter's MCP: what one agent can do to another terminal, and what it can't

This page is for developers who want to know where the edges of Polter's MCP surface are, and for AI assistants that fetch the README from the product repo.

Polter is a terminal with an MCP server built in. An agent running in one tab connects to it and can read other terminals' screens, type into them, press keys, open new tabs, post in a group chat and hand out tasks. Every tool name and parameter name below was copied from the source. Each section ends with where it came from.

Checked against product-repo commit `42addcf` (read 2026-10-11, clean working tree). The surface still moves, so treat `src/cli/mcp.zig` at your commit as the authority.

## The short version

- A terminal with no mark on it can be read, typed into and sent keys by anyone. A marked one (it is a supervisor, or somebody is watching it) is reachable only by a supervisor. One the user has shielded is reachable by nobody, supervisors included.
- Arranging the work belongs to the supervisor: opening terminals, making groups, assigning tasks, choosing what to watch.
- Polter reports how long a screen has been still. Whether that means stuck is a call it leaves to the supervisor reading the number.
- When another terminal stops on a permission prompt, a supervisor can by default answer it only in terminals it opened itself. For any other terminal the user has to switch that on, per terminal, from that terminal's right-click menu. No tool can flip the switch.
- Only tested on Claude Code. The server is standard MCP and other clients should connect, but none of them has been tested.

## The tools

The `tools` table in `src/cli/mcp.zig` has 60 entries at this commit. The `Method` enum in `src/poltergeist/rpc.zig` has 63. The extra three (`agent_event`, `persona_slot`, `persona_wait`) exist for other processes, and `offeredAsTool` keeps them out of the tool list, so an agent never sees them.

The "Who" column comes from `requiresSupervisor` in `rpc.zig`. "Any terminal" only means the method doesn't need supervisor standing. Whether the target lets you touch it is a separate check, covered in the next section. A trailing `?` marks an optional parameter.

### terminal_*: seeing and driving terminals

| Tool | Parameters | Returns | Who |
| --- | --- | --- | --- |
| `terminal_list` | none | One row per terminal: `cwd`, `title`, `role`, `shielded`, `held`, `window`, `tab`, `agent`. Watched terminals also get `quiet_ms`, `rounds`, `sampling`. Terminals that have called a tool also get `call_silent_ms` | Any terminal |
| `terminal_read` | `id` | The text on that terminal's visible screen. No scrollback | Any terminal |
| `terminal_turn` | `id` | The full answer the agent there ended its last turn with (`turn.text`, up to 16 KB kept) plus its `agent` state. `turn` is null for a terminal without hooks | Any terminal |
| `terminal_send` | `id`, `text`, `submit?` | Success or a refusal code. `submit` defaults to true and presses return after the text | Any terminal |
| `terminal_key` | `id`, `key` | Success or a refusal code. `key` is written the way a config file writes a keybinding trigger: `ctrl+c`, `escape` | Any terminal |
| `terminal_keys` | none | The modifier and key names `terminal_key` accepts | Any terminal |
| `terminal_action` | `id`, `action` | Success or a refusal code. `action` is a keybinding action: `new_tab`, `close_surface`, `new_split:right` | Any terminal |
| `terminal_actions` | none | Every action `terminal_action` takes, and which want a value after the colon | Any terminal |
| `terminal_answer_prompt` | `id`, `choice?`, `state_at_ms?`, `event_at_ms?` | Success, `AuthoriseOff`, or `PromptGone`. `choice` counts down from the highlighted option, default 1. With the two moments from `terminal_list` (both or neither), no key is sent unless the prompt you saw is still the one there | Supervisor only, and the target's authorise switch must be on (it is, unless the user turned it off) |
| `terminal_open` | `cwd`, `watch?`, `place?` | `placed` (split or tab) and `watch` (not_asked / watching / refused). Carries `id` when the terminal is ready. A split carries `pending: true` and no `id` | Supervisor only |
| `terminal_layout` | `id`, `layout` | The resulting layout tree with a terminal id in every cell. Answers `Unsupported` on Linux | Supervisor only |
| `terminal_capabilities` | `id` | That terminal's `role`, `started`, `cli`, `polter` and `standing` (which includes `watched_by`, `may_authorise`, `shielded`, `held`) | Supervisor only |

`place` takes `auto`, `tab` or `here`. Leaving it out means `auto`. What `terminal_open` gives you is an empty shell, so whatever should run there is a separate `terminal_send`.

### group_*: the group chat

| Tool | Parameters | Returns | Who |
| --- | --- | --- | --- |
| `group_create` | `group` | Makes the group and puts the creator in it | Supervisor only |
| `group_destroy` | `group` | Takes the group off the list. The record on disk stays. Answers `GroupActive` while any open terminal is still in it | Supervisor only (the person at the keyboard can also do it from the conversations view) |
| `group_rename` | `group`, `to` | Renames it. Task numbers and members are kept. Failure codes include `NoSuchGroup`, `GroupExists`, `RenameBlocked`, `BadName`, `NotYours` | Supervisor only, and only a group it made |
| `group_add` | `group`, `id`, `history?` | Puts a terminal in. `history` is `none` (default) or `all` | Supervisor only |
| `group_remove` | `group`, `id` | Takes a terminal out | Supervisor only |
| `group_set_brief` | `group`, `text` | Records what the group is for. Everyone in the group can read it | Supervisor only |
| `group_compact` | `group`, `through`, `summary` | Replaces everything up to `through` with one summary | Supervisor only |
| `group_members` | `group` | Who is in the group and what each terminal is called now | Any terminal |
| `group_list` | `group?` | Which groups exist. A worker sees the ones it is in. A supervisor sees all, with `joined: false` on those it isn't in | Any terminal |
| `group_post` | `group`, `text`, `mention?` | The result of the post. If the message was cut for length, how much was written and how much was kept. One row in `deliveries` per id in `mention` | Any terminal (must be in the group) |
| `group_read` | `group`, `since?` | Unread messages, with `next`. `more: true` means there are more right now | Any terminal |
| `group_history` | `group`, `before_seq?`, `limit?`, `since_ms?`, `until_ms?`, `match?` | Older messages from the log on disk, including ones `group_compact` replaced | Any terminal |

A post doesn't interrupt a watched terminal. The recipient reads it when it chooses to. To put a message in front of a terminal right away, name its id in `mention` and the message is typed into that terminal.

### task_*: the task panel

| Tool | Parameters | Returns | Who |
| --- | --- | --- | --- |
| `task_create` | `group`, `title`, `kind` | A task number. `kind` is required: `feature`, `bug`, `research`, `other` | Supervisor only, and only in a group it made |
| `task_edit` | `task`, `title?`, `kind?` | Changes the title or kind. The number stays. History records it as `edited` | Supervisor only |
| `task_assign` | `task`, `id` | Types a line into that terminal saying the task is theirs, and records the assignment only if that landed. The reply says whether the terminal was told. `id` 0 takes it back | Supervisor only |
| `task_close` | `task` | Closes it. Nobody is notified | Supervisor only |
| `task_cancel` | `task` | Types a line into the owner's terminal telling it to stop, then removes the task from its list | Supervisor only |
| `task_progress` | `task`, `progress` | Moves one of your own open tasks. `progress` is `queued`, `working`, `blocked` or `done` | Any terminal |
| `task_list` | `group`, `limit?`, `before?`, `state?`, `owner?`, `match?` | A supervisor gets the whole panel. Anyone else gets its own open tasks. 50 rows by default, `more: true` when there are older ones | Any terminal |
| `task_history` | `group`, `before_seq?`, `limit?` | What happened on the panel, each event with a timestamp | Any terminal |

The panel holds who is on what and whether it's done. Acceptance criteria and the rest of the detail are for the supervisor to send separately.

### Everything else

**Identity and watching**

| Tool | Parameters | Returns | Who |
| --- | --- | --- | --- |
| `me` | none | Which terminal you are, whether you supervise or are watched, plus `sampling` and `call_silent_ms` | Any terminal |
| `persona_face` | none | Which Polter tools you can see right now | Any terminal |
| `skill_read` | `name` | One usage guide. The source names three: `supervising`, `operating-a-terminal`, `reading-a-terminal` | Any terminal |
| `become_supervisor` | none | Makes the caller a supervisor. Refused for a terminal that is being watched | Any terminal (when nobody is minding it) |
| `stand_down` | none | Stops being a supervisor. `StillMinding` while it still watches terminals, `StandingInstruction` when the user has reserved that decision | Supervisor only |
| `set_watch` | `id`, `watch` | Claims a terminal or lets it go. `NotYours` if another supervisor has it, `NotWatched` for `false` on an unwatched terminal | Supervisor only |
| `set_quiescence_threshold` | `id`, `ms` | Sets how long that terminal must be still before it is reported | Supervisor only |
| `clock_out` | `id`, `reason?` | Marks a terminal done for the day so its quiet spells stop being reported. `TerminalHeld` for one the user is holding | Supervisor only |
| `clock_in` | `id` | Puts a terminal back on duty | Supervisor only |
| `notices` | none | Reports not yet seen: which terminals went quiet and for how long, which came back. Reading clears them | Supervisor only |
| `notify_user` | `reason`, `title`, `body?`, `id?` | Whether the message went anywhere. `reason` is `authorisation` or `scheduling`. With `authorisation` the operating system's own notification is raised too, and the reply says so separately from the plugins | Supervisor only |
| `session_recall` | none | The arrangement written down before a restart: groups, and where each terminal was working and what it was called | Supervisor only |
| `config_get` | `key?` | The user's configuration, read only | Supervisor only |

**Role library**

| Tool | Parameters | Returns | Who |
| --- | --- | --- | --- |
| `role_list` | none | Every role in the library, in the shape `role_put` takes | Supervisor only |
| `role_put` | `role` | Adds or replaces a role. A write that changes `supervisor`, `may_authorise` or `shielded` is refused with `NotPermitted`. A built-in role answers `BuiltinRole` | Supervisor only |
| `role_delete` | `key` | Deletes a role. Built-ins can't be deleted | Supervisor only |
| `role_clis` | `refresh?` | Which agent CLIs a role can start on this machine, and the skills and MCP servers each has installed | Supervisor only |
| `role_launch` | `key`, `cli?`, `cwd?`, `place?` | Opens a terminal and starts an agent CLI in it wearing the role. `placed` says where it went. Carries `id` when the terminal already exists | Supervisor only |

**Plugins**

| Tool | Parameters | Returns | Who |
| --- | --- | --- | --- |
| `plugin_list` | `key?` | Installed plugins, whether each is on, what parameters it takes. A secret typed in plainly is reported only as set | Supervisor only |
| `plugin_configure` | `key`, `enabled?`, `params?` | Switches a plugin on and sets parameters. Switching one off is refused. A `cmd:` reference is refused | Supervisor only |
| `plugin_test` | `key` | For a notification plugin this sends a real one | Supervisor only |

**Screenshots**

| Tool | Parameters | Returns | Who |
| --- | --- | --- | --- |
| `screenshot_windows` | none | Every display and window: `window_id`, `app`, `title`, `rect` and so on | Any terminal |
| `screenshot_capture` | `target`, `display?`, `window_id?`, `rect?`, `terminal?`, `annotations?` | The PNG path, the path of the `.json` beside it, and its size. `target` is `display`, `window`, `region` or `terminal` | Any terminal |
| `screenshot_annotate` | `path`, `annotations` | A new annotated file. The original is untouched | Any terminal |
| `screenshot_long` | `pages`, `window_id?`, `display?`, `rect?` | The stitched image and its `tiles`. `stopped` says why it ended | Any terminal |
| `screenshot_interactive` | none | Returns `started` at once. The user then picks the region and annotates it | Any terminal |
| `screenshot_info` | `path?`, `latest?` | The whole `.json` recorded beside one screenshot | Any terminal |
| `screenshot_list` | `limit?` | The newest screenshots, newest first | Any terminal |

The screenshot family is governed by the user's `screenshot-agent-access` setting, and standing plays no part. It defaults to allow. Set to `deny`, the calls answer `NotPermitted`. A shielded terminal can't be a capture target, and where one shows up in a wider capture it is painted black.

Source: the `tools` table in `src/cli/mcp.zig` (names, parameter schemas, what each returns), and `Request`, `requiresSupervisor` and `offeredAsTool` in `src/poltergeist/rpc.zig`.

## Where the permission lines are

This is the part that matters most. The rules live in `authorize` in `rpc.zig`, and they are given here in the order it checks them.

### The marks a terminal can carry

- **Supervisor**: set by the user from the menu, or taken by the terminal itself with `become_supervisor`.
- **Watched**: a supervisor claimed it with `set_watch`, or the user switched watching on by hand from the tab's menu.
- **Shielded**: set by the user. Nothing reads it or types into it through the tool surface.
- **Held**: set by the user. The terminal can't be clocked out.
- **Authorise switch** (`may_authorise`): whether a supervisor may answer this terminal's permission prompts. On in every terminal unless the user said otherwise.

The last three are the user's alone to set and lift. The comment on `Entry.shielded` gives the reason: a guarantee the supervised party can lift is no guarantee. There is no tool that reads or writes the hold. A supervisor sees `held` on the terminal's row in `terminal_list` and that is all.

### Whether a call reaches its target

The decision looks at what the target is marked as. The relationship between caller and target doesn't enter into it.

1. The target is shielded: refused with `Shielded`, for supervisors and plugins too. This check runs first because any unmarked terminal becomes a supervisor with a single `become_supervisor` call, so a shield that only stopped non-supervisors would be one call from useless.
2. The caller is a supervisor: it reaches any unshielded terminal, other supervisors included.
3. The caller isn't a supervisor: it reaches unmarked terminals only. A target that is a supervisor or is being watched answers `Supervised`.

One consequence of rule 3 is that two watched workers can't read each other's screens or type into each other. Naming another worker in `group_post`'s `mention` doesn't go straight through either. By default it is redirected to their supervisor, unless the user has switched on worker-to-worker mentions for that supervisor.

One more rule has nothing to do with standing: most tools can't be aimed at the caller's own terminal. A `terminal_send` to yourself followed by a `terminal_read` is a loop with no natural end, so it answers `SelfTarget`. The exception is the subset of `terminal_action` that doesn't come back to the caller, such as giving your own tab a second pane.

### Refusals at the method level

| Code | When |
| --- | --- |
| `NotPermitted` | The method is a supervisor's and the caller isn't one |
| `NotDeclared` | The caller is a plugin and the method isn't in its manifest's `wants.calls` |
| `NotATerminal` | The caller is a plugin and the method's meaning depends on which terminal is asking |
| `SelfTarget` | The call is aimed at the caller and would loop back to it or remove it |
| `Shielded` | The user has shielded the target |
| `Supervised` | The target carries a supervision mark and the caller isn't a supervisor |
| `NotYours` | It belongs to another supervisor: a group it made or a terminal it has claimed |
| `AuthoriseOff` | The user has switched the target's authorise switch off (for that terminal, or for all of them in the configuration) |
| `TerminalHeld` | Clocking out a terminal the user is holding |
| `AlreadyWatched` | A watched terminal tried to make itself a supervisor |
| `UnknownTerminal` | No terminal by that id |
| `BadLayout` | A `terminal_layout` names a `pane` that is not a terminal id (an empty string, say), or nests too deep. About the call, not the caller's standing |

All twelve are in the `Error` set in `rpc.zig`, each with a comment saying why it exists.

### Permission granted, text still refused

After `terminal_send` passes the checks above, the host has its own. Each cause wants a different response, which is why they have separate codes:

| Code | Cause | What to do |
| --- | --- | --- |
| `UserPresent` | A key reached that terminal in the last ten seconds. It says a key arrived, not that anyone is there | It clears on its own. Retry in a moment |
| `DraftInLine` | That terminal's input line holds characters that were typed and never submitted | Waiting won't clear it. Something has to press a key there, for example `terminal_key(id, "ctrl+u")` |
| `UnbracketedMultiline` | The text has line breaks and that terminal hasn't asked for bracketed paste, so each line would run as a command | Send one line, or one line per call |
| `UnsafeText` | The text carries an end-of-paste sequence | Take it out |
| `ChildExited` | The process in that terminal has exited | Pick another terminal |
| `SendFailed` | None of the above | `terminal_read` it first |

A `mention` in `group_post` goes through the same checks, and the reply reports each id on its own row in `deliveries`. When one is refused the message is still in the group. It wasn't typed into that terminal.

`terminal_send` carries text and nothing else. It goes down the paste path, where control characters become spaces, so no spelling of ctrl+c or escape gets through it. Interrupting a program takes `terminal_key`, and `terminal_key` in turn refuses ordinary characters.

Closing a terminal has two codes of its own. A terminal an agent opened, or one the caller is minding, closes without asking. The user's own terminal with something still running answers `UserTerminal`, and one the user locked read-only answers `Locked`. Neither case puts a confirmation dialog on the user's screen. The agent is expected to ask the person at the keyboard.

Source: `authorize`, `Error`, `selfPermitted`, `planMention`, `mentionFailure`, and the `.terminal_send` and `.terminal_action` arms of `dispatch` in `src/poltergeist/rpc.zig`. The marks are defined on `Entry` in `src/poltergeist/Bus.zig`.

## What it doesn't do

### It doesn't decide who is stuck

Polter measures two durations: how long a screen has been unchanged (`quiet_ms`) and how long since the agent in that terminal last called a Polter tool (`call_silent_ms`). It parses no CLI's output format.

Both numbers land in the supervisor's `notices`. The tool's own description is blunt about what they are: arithmetic and no verdict, and twenty minutes without a tool call doesn't mean the terminal is dead. It may be in a retry loop, waiting on a prompt a person has to answer, or running a long build. The description tells the supervisor to `terminal_read` and decide from the screen, and not to close, restart or interrupt a terminal on that line alone.

`poltergeist-watch` is off by default, so nothing is sampled until somebody asks. A screen is reported after 3 minutes still and an agent after 15 minutes without a tool call. Both are defaults the user can change.

The cost is that the supervisor has to read the screen and make the call every time. If you want a ready-made "busy / done / needs you" state, this tool doesn't give you one.

### It doesn't press "yes" for another agent where the user said no

`terminal_answer_prompt` needs two things at once: the caller is a supervisor, and the target's authorise switch is on.

- **The switch starts on in every terminal**, whoever opened it (since 2026-10-12; before that it was on only in terminals a supervisor had opened). A worker's prompts are the supervisor's to deal with: it answers the ones it can judge, and takes the rest to the user with `notify_user`.
- The user can turn it off for one terminal from that terminal's own right-click menu, shield the terminal, or turn the default off for every terminal with `poltergeist-may-authorise = false`. Only the user can turn it back on. It has no keybinding and no command-palette entry, because `terminal_key` can press any chord and a keybinding would be a door an agent could open for itself.
- A per-terminal "off" lasts until that terminal closes; the configuration line is the one that survives a restart.
- No terminal can answer its own prompt through this tool.
- A plugin can't call it at all.

With the switch off, `terminal_key` also refuses the six keys that move through and take an option in a list (return, numpad return, the four arrows). ctrl+c and escape still go through, since those are how a stuck worker gets rescued.

There is a gap here and the source states it openly. With the switch off, `terminal_send` can still put a `1` and a return into that terminal and answer the box. That can't be closed: assigning a task is itself text plus a return, and refusing one refuses the other. In the source's words, the switch stops the dedicated tool and the casual keypress and leaves a bypass that is published and logged. That is a weaker claim than "can't be done."

With the switch on — the default, for every terminal that is not shielded — a supervisor can take either option, including "don't ask again." That one writes a standing permission into the directory's configuration, so agents that run there afterwards stop being asked. Polter sends keys and can't tell which option the supervisor took.

### It doesn't unlock anything for the user

The tool surface has no method to lift a shield, lift a hold, or turn the authorise switch back on once the user has turned it off. `role_put` refuses a write that touches `supervisor`, `may_authorise` or `shielded`. `config_get` is read only. Changing settings is the user's.

### It doesn't isolate files or talk to a model

Workers share one checkout. Polter gives them no worktree of their own. It also connects to no model and needs no API key. The thinking is done by whatever agent CLI the user already has installed.

Source: the descriptions of `notices`, `terminal_answer_prompt` and `terminal_open` in the `tools` table of `src/cli/mcp.zig`; `authorize`, `answersAPrompt` and `promptReach` in `src/poltergeist/rpc.zig`; `Entry.may_authorise` in `src/poltergeist/Bus.zig`; `poltergeist-watch`, `poltergeist-quiescence-after` and `poltergeist-calls-silent-after` in `src/config/Config.zig`; the "Guardrails" and "Compared to Alternatives" sections of the product README.

## Connecting

The server is a stdio MCP process speaking protocol revision `2024-11-05`. The client configuration is one line:

```json
{"command": "polter", "args": ["+mcp"]}
```

It has to be started from inside a Polter terminal. Polter puts `GHOSTTY_POLTER_SOCKET` and `GHOSTTY_POLTER_TOKEN` in every terminal's environment, and `+mcp` uses them to find the terminal it belongs to. Identity comes from that token alone, so an agent can't ask to be treated as a different terminal. Run by hand outside Polter, `polter +mcp` exits and says on stderr which variable is missing.

Most people never write that line. The master switch `poltergeist-mcp` is on by default (set it to `false` for a plain terminal that opens no socket), `poltergeist-register-mcp` is on by default too, and Polter registers the server for installed agent CLIs at startup. Once connected, ask the agent to call `me`. If it answers with a terminal id, you're connected. If it says there is no such tool, the README's FAQ lists the three usual causes.

On what has been tested: the server is standard MCP, so any MCP client should be able to connect, and six provisioning plugins ship with it (`claude-code`, `codex`, `deepseek`, `kimi`, `opencode`, `qwen-code`). Only Claude Code has been tested in depth. Treat the other five as untested.

Hooks are Claude Code only for now. A Claude Code started from a role reports its state and its final answer through `polter +hook` when a turn ends, so the supervisor sees "turn ended" in `notices` and can fetch the full text with `terminal_turn`. Other CLIs have no such path. Their `agent.hooks` reads `none` in `terminal_list`, and what's left is the still-screen timer and `terminal_read`.

On platforms: macOS and Windows have binaries, Linux is build-from-source, and `terminal_layout` isn't available on Linux.

Source: the comment above `run`, plus `Options`, `protocol_version` and `complain` in `src/cli/mcp.zig`; `src/poltergeist/agent_cli.zig`; the "Key Features", "Download & Install" and "FAQ" sections of the product README.

## Credits

The terminal rendering, VT and font layers underneath come from [Ghostty](https://github.com/ghostty-org/ghostty) (MIT). What Polter adds lives under `src/poltergeist/`. The two projects are not affiliated, so please don't file bugs found here upstream.
