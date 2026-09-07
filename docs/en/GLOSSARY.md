# Glossary

> Last updated against git commit: `f81dcadc8`
> (`f81dcadc82ea2afdcf2dc92929037701122f05b5`, 2026-08-14)
> How to check: `git log -1 --format='%H %h %ad %s'`

## What this file is for

Most of `docs/` is written in Chinese. This file fixes the English spelling of
every name that both halves of the tree have to agree on, so that a term
introduced in one English document is not silently renamed in the next one.

The rule is the same one [`_conventions.md`](../_conventions.md) applies to the
Chinese side: **do not invent a translation.** Every English term below is one
that already appears in [`README.md`](../../README.md), in a `//!` module
comment under `src/poltergeist/`, or in one of the three skill files under
`src/poltergeist/skills/` — all of which were written in English first. Where
the existing English text uses two names for one thing, the entry says so and
the disagreement is listed under
[What was settled, and what is still open](#what-was-settled-and-what-is-still-open)
rather than papered over here.

Two tables: Polter's own vocabulary first, then the Ghostty core terms that the
translated documents need. The Ghostty half is the mirror image of the table at
[`_conventions.md:60-79`](../_conventions.md) — that table maps English to
Chinese for translators writing Chinese, this one maps it back.

## Polter's vocabulary

| Chinese                   | English                                          | One-line definition                                                                                                                                                                          | Source                                                                           |
| ------------------------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| 总管                      | **supervisor**                                   | The agent the user has put in charge of other terminals — an ordinary agent CLI session, not a dashboard and not a process manager.                                                          | `README.md`, `src/poltergeist/main.zig:1-9`                                      |
| （被监督的）终端 / worker | **worker**                                       | A terminal doing a piece of the work, as seen from the supervisor; it is an independent session in its own tab, never a sub-agent of the supervisor.                                         | `README.md`, `src/poltergeist/skills/supervising.md`                             |
| 群聊                      | **group chat** (a **group**)                     | The place terminals talk. A group is made by the supervisor, which decides who is in it; there are no direct messages, because a two-terminal group is one set of rules instead of two.      | `src/poltergeist/Chat.zig:1-6`                                                   |
| 任务面板                  | **task panel** (the **panel**)                   | One line per piece of work: a title, the terminal responsible, open/closed/cancelled, and a progress word. Deliberately not a task tracker.                                                  | `src/poltergeist/Tasks.zig:1-10`, `docs/poltergeist/tasks.md`                    |
| 静止                      | **quiet** (prose) / **quiescence** (identifiers) | The one thing Polter measures: how long a terminal's visible screen has gone unchanged. It is a duration, never a verdict — "quiet" does not mean "stuck".                                   | `src/poltergeist/Sampler.zig:1-12`, `src/poltergeist/Fingerprint.zig:1-9`        |
| 提醒                      | **notices**                                      | The batch of things the supervisor has not been shown yet — which screens went quiet and for how long, plus at most one line per group — delivered on one clock and never on a second one.   | `src/poltergeist/notes.zig:1-12`, `docs/tools.md`                                |
| 监督                      | **watch**                                        | To put a terminal under a supervisor: it gets the `watched` mark on the bus, and something starts sampling its screen.                                                                       | `src/poltergeist/Bus.zig:1-4`, `src/poltergeist/rpc.zig:3383-3396`               |
| 被监督（标记）            | **watched**                                      | The `role` a terminal has once somebody is minding it; the other two roles are `none` and `supervisor`.                                                                                      | `src/poltergeist/skills/operating-a-terminal.md:24`                              |
| 屏蔽                      | **shielded**                                     | A lock only the user can set: the terminal is out of reach of the tool surface entirely, refusing supervisors and plugins alike.                                                             | `src/poltergeist/skills/operating-a-terminal.md:25`, `README.md`                 |
| 按住 / 保持               | **held**                                         | The other lock only the user can set: the terminal may not be clocked off, so a supervisor asking for that is refused.                                                                       | `src/poltergeist/skills/operating-a-terminal.md:26`, `src/poltergeist/skill.zig` |
| 下班 / 上班               | **clock out / clock in**                         | Mark a terminal done for the day, so its going quiet stops being reported — refused for one the user is holding.                                                                             | `docs/tools.md:65`                                                               |
| 插件（原「常驻插件」）    | **plugin**                                       | A process, spawned once and kept running, fed live events on stdin: `spawn -> hello -> a line of events -> a line of acknowledgement`. Do not write "resident plugin" — every plugin is one. | `src/poltergeist/Resident.zig:1-13`                                              |
| 供给 / 注册               | **provisioning**                                 | Telling one agent CLI's runtime that Polter is here — registering the MCP endpoint and installing the skills — which is a plugin's job and not the core's.                                   | `src/poltergeist/provision.zig:1-19`                                             |
| 转录                      | **transcript**                                   | What actually ran in a terminal, written down by the terminal: the lines that have scrolled out of the active screen, one JSON object per line.                                              | `src/poltergeist/Transcript.zig:1-14`                                            |
| 终端                      | **terminal**                                     | One tab, as an agent and a supervisor see it: the thing that has a role, a token, a screen and a transcript. This is the word to use in Polter documents.                                    | `src/poltergeist/rpc.zig:1-14`                                                   |
| 表面（surface）           | **surface**                                      | Ghostty's internal name for the same object: the widget a terminal is drawn on, which may be a window, a tab or a split. Use it only when writing about the core.                            | `src/Surface.zig:1-11`, [`_conventions.md:63`](../_conventions.md)               |
| 工具面                    | **tool surface**                                 | The set of MCP tools an agent can reach. Always written with the qualifier, never as a bare "surface", because `Surface` above is a different thing.                                         | `src/poltergeist/rpc.zig:1-2`, `README.md`                                       |

### Two notes that are not one-liners

**"Watched" and "watching" are two facts, not one.** `rpc.zig:3386-3392` says
so in as many words: the bus entry says a terminal is _meant_ to be watched,
and `setWatching` makes something _actually look at it_. `me` returns both —
`role: watched` is the mark, `watching: true` is the sampler — and a terminal
that has the first without the second reports nothing and looks broken rather
than unwatched. Do not use one word for both in English prose.

**"Quiet" is a measurement and "stuck" is a judgement.** This is the one design
rule of the project ([`CONTRIBUTING.md`](../../CONTRIBUTING.md), "Polter
measures. It does not judge."), and it is a rule about wording as much as about
code: a sentence that says a terminal _is stuck_ has crossed the line that
`Sampler.zig:8-11` exists to hold. Say how long it has been still.

## Ghostty core terms used by the translated documents

These are the reverse of [`_conventions.md:60-79`](../_conventions.md). Where a
Chinese document writes the term one way and the code another, the code wins.

| Chinese                | English              | Note                                                                           |
| ---------------------- | -------------------- | ------------------------------------------------------------------------------ |
| 表面（surface）        | surface              | Never "window" or "view". The type is `Surface`.                               |
| 应用运行时（apprt）    | app runtime (apprt)  | Spell out once, then `apprt`.                                                  |
| 终端 IO（termio）      | terminal IO (termio) | Spell out once, then `termio`.                                                 |
| 渲染器                 | renderer             | The thread is named `renderer`.                                                |
| 渲染线程               | renderer thread      |                                                                                |
| IO 线程                | IO thread            | The writer thread in `src/termio/Thread.zig`, named `io`.                      |
| 读线程                 | read thread          | Named `io-reader`.                                                             |
| 主线程                 | main thread          | Also "the app thread"; the two mean the same thing here.                       |
| 消息信箱（mailbox）    | mailbox              | Then `mailbox`.                                                                |
| 滚动回溯（scrollback） | scrollback           | Then `scrollback`.                                                             |
| 页 / 页链表            | page / page list     | The types stay `Page` / `PageList`.                                            |
| 字形                   | glyph                |                                                                                |
| 整形器 / 文本整形      | shaper / shaping     |                                                                                |
| 图集（atlas）          | atlas                |                                                                                |
| 键绑定                 | keybinding           | Upstream writes it as one word; `keybind` is the config key.                   |
| pty                    | pty                  | Never expanded.                                                                |
| xcframework            | xcframework          | Lower case.                                                                    |
| 构建选项               | build option         | Of the form `-Demit-macos-app=false`.                                          |
| 未核实                 | not verified         | The marker for anything not read out of a file or run on a machine; see below. |

### The `（未核实）` marker

The Chinese documents mark every unverified claim with `（未核实）` and say in
the same paragraph why it is unverified and how to check it
([`_conventions.md`](../_conventions.md), the anti-hallucination section). The
English documents render this as **"not verified:"** followed by the same two
things. It is not a hedge and it is not decoration — a document with the marker
missing is claiming to have read something it did not read.

## What was settled, and what is still open

The instruction behind this file was: where the existing English text already
uses two names for one thing, do not pick one silently. Eleven such splits were
found. Six have since been ruled on and are recorded here as decisions; the
rest are still open. **No file outside `docs/en/` was changed to make any of
this true.**

### Settled

- **"Resident" is no longer a distinguishing word.** `Resident.zig:3-13` says
  there used to be three plugin shapes — a fork per notification, a resident
  stream, one run at startup — and there is one now, so every plugin is
  resident and the qualifier distinguishes nothing. **New English prose says
  "plugin".** The name survives where it names a thing rather than a kind:
  the file `Resident.zig`, and "the resident host" for the part that runs
  them. The Chinese 常驻 is stale by the same argument, and is not this
  file's to change.

  Worth flagging while applying this: `Plugin.zig:10-12` still carries the
  retired argument — "The rate makes it affordable: … so a fork per
  notification costs nothing that matters" — which `Resident.zig:36-44` says
  in as many words did _not_ survive the merge, because it argued for the
  one-shot lifetime rather than for the process boundary. Two files, one of
  them out of date.

- **The hold is called `held`.** Three names are in use in English: "hold it
  to its work" and the `held` field (`README.md`,
  `operating-a-terminal.md:26`); the command-palette label **Keep This
  Terminal Working**; and the thing it prevents, clocking off (`clock_out`).
  These are not three names for one thing but two layers: the field is the
  mechanism, the label is what a person reads. Use the field name as the term,
  and quote the label when the UI is what is being described.

- **The shield is called `shielded`**, on the same reasoning, with **Keep
  Agents Out of This Terminal** quoted when the menu is the subject. The menu
  labels deliberately do not reuse the vocabulary.

- **Quiet in prose, `quiescence` in identifiers.** `README.md` and the skills
  say "quiet" and "still"; the identifiers say `quiescence`
  (`poltergeist-quiescence-after`, `Bus.zig:5`, `Sampler.zig:1`). Write
  "quiet" in a sentence and `quiescence` only when naming the option or the
  code.

- **The batch is called `notices`.** English already had four names for it:
  `README.md` says "reports" arrive in batches, the tool is `notices`, the
  skill calls it "the same box", `Bus.zig` has `leaveNote` while `notes.zig`
  calls its output "the one line". Use **notices**, and "hand-over" only where
  `poltergeist-compact-after`'s own wording is being quoted.

- **A worker is not the same set as a watched terminal.** `README.md` uses
  "worker" freely and never defines it against `role: watched`, but a
  supervisor minding a second supervisor is watching something that is not a
  worker (`supervising.md:263`). Use **worker** for a terminal doing assigned
  work and **watched terminal** whenever the mark itself is the point.

### Still open

1. **Polter or Poltergeist?** `README.md` says "Polter" throughout and the
   binary is `polter`. The module comments say "Poltergeist"
   (`src/poltergeist/main.zig:1`, `Bus.zig:4`, `Fingerprint.zig:3`,
   `Server.zig:1`, `rpc.zig:1`), the directory is `src/poltergeist/`, the
   config prefix is `poltergeist-` and the keybinding actions are
   `poltergeist_*`. Two readings are possible — "Poltergeist is the layer,
   Polter is the product", or "Poltergeist is the old name" — and the code
   does not distinguish them. Naming a product is not a decision this file
   makes. Used here: **Polter** for the program in prose, "Poltergeist" for
   the capability layer (matching `main.zig:1`), and `poltergeist` untouched
   wherever it is an identifier.

2. **Group chat, or Terminal Conversations?** The menu item and `polter +chat`
   open what every other document calls the group chat (`README.md:243`). A
   reader looking for "group chat" in the menu will not find it. The English
   side is at least consistent with itself; the Chinese side of the same split
   is worse, and is somebody else's to resolve.

### Two Chinese-side splits, recorded here because they were found here

Neither has an English counterpart, and neither is this file's to fix. Both
were found against commit `f81dcadc8`; **both have since been acted on
elsewhere in the tree**, so the sentences below describe what was found, not
necessarily what is on disk now.

- **供给 vs 注册 for provisioning.** English is consistent
  ("provisioning plugin"). The Chinese was not: `README_CN.md` says 注册插件
  throughout, after `docs/readme-reviews/round-2.md:84-85` recorded that 供给
  was a literal translation nobody could parse and changed all four
  occurrences — while several `docs/poltergeist/` chapters still said 供给插件.
  That is a missed edit rather than two spellings coexisting, which is what
  makes it decidable. Note that the two occurrences in `round-2.md` itself
  must **not** be changed: they quote the old word, and rewriting them turns
  the record into "changed 注册插件 to 注册插件".

- **被监视 vs 被监督 for `watched`.** `README_CN.md` wrote 被监视 in two
  places; `docs/README.md` and the `poltergeist/` chapters write 被监督.
  `docs/windows/status.md` also contains 被监视, but about a watchdog thread
  and the main thread it watches — a different concept, and not part of this
  split.

## Further reading

- [`../_conventions.md`](../_conventions.md) — the writing rules these
  documents follow, including the anti-hallucination rule. Chinese.
- [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) — which half of the tree is
  this fork's, and the one design rule. English.
- [`../tools.md`](../tools.md) — every MCP tool, what it does and what it
  refuses. Already English; `tools_CN.md` beside it is the translation.
- [`../poltergeist/README.md`](../poltergeist/README.md) — the design the
  vocabulary comes from. Chinese.
