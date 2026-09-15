# The tool surface

Every one of Polter's forty MCP tools, what it does, and which are the
supervisor's alone. This is a reference — read it when you want to know exactly
what a call does. [The README](../README.md#what-it-does) has the shape of it in
a short list, which is enough to use the thing.

Tools marked 🔑 are the supervisor's alone.

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
| `group_history`     | Further back than memory holds, read from the day files. Page with `before_seq`, using the smallest `log_seq` you've seen; `more: false` means you're at the beginning. The in-group `seq` is always 0 here — the log doesn't record it. **Searchable**: `match` is a substring of the message text with ASCII case ignored, `since_ms` and `until_ms` bound it in wall-clock time. This is the road back to what a compaction took out of the group — without it, finding one sentence from last night means paging back through the whole night into the context the compaction existed to free. |
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
| `task_history`    | Not what the panel says now, but **when it came to say it**: every create, assign, progress, close and cancel, with its time. `task_list` answers "where does this stand"; this answers "what happened overnight" — which of the two you want is usually obvious once you've asked the wrong one. Pages the same way the conversation does. |

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

