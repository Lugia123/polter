# Roadmap: what it used to say, and where it was wrong

Moved out of `ROADMAP.md` on 2026-10-10, word for word, when the roadmap was
rewritten to look forward. These passages were kept in the roadmap on purpose
by the author: each records a line that was true when written and went on
being read after it stopped being true. They are kept here for the same
reason, so the roadmap does not look as though it had never been wrong.

The numbers and versions below are those of the time (0.5.x, September 2026)
and are not maintained.

---


**macOS — the platform this is developed on.** Used daily by its author with
Claude Code. Every part of the supervising side is exercised there: groups,
the task panel, the transcript, the statistics view, the MCP surface, the
provisioning plugins.

**Windows — first shipped in 0.5.447; 0.5.497 is the current release.**
`windows/host/` is a Rust shell that drives the same Zig core through
libghostty's C API. What has a reading behind it: the window opens, tabs work,
a shell starts, CJK text renders, IME composition produces Chinese characters
in a real terminal, the menu and its accelerators work, the resources directory
is found and the provisioning plugins start. Splits, shell integration and the
group chat view each got a reading on a real machine after that first release.

**0.5.447's Windows zip was missing `polter-cli.exe`**, so the group chat tab
could not open on that release at all. The fault was in the packing list rather
than in the program, which is worth saying because it presented as a broken
feature and nothing in the code was wrong. 0.5.497 ships the binary, and the
chat view was opened on the Windows machine to confirm it.

What is known to be missing is below.


---

## Next

### Close the Windows gaps

These are specific and each one has a place in the code.

- **Action parity, in three numbers rather than one.** Of the core's 72
  keybinding actions the host **implements 63**, **refuses 7 by name**, and
  **still owes 2** (2026-09-08). The refusals are arms like any other: they
  exist so that a GTK inspector or a tab overview answers with a sentence
  saying this platform has no such thing, rather than falling through to a
  bare tag number in a log nobody sees. Counting arms would call that 72
  implemented, which is why the number is published as three; every one of the
  72 now gets a named answer and none falls through to a bare tag number. Both numbers are measured rather than
  remembered, and the commands are in
  [`dev-docs/windows/status.md`](dev-docs/windows/status.md) — **an earlier version of
  this line said 24, from a command anchored to line numbers that had moved.**
- **The `archive` plugin's Windows script — done, and left here for the way
  this line was wrong.** It said the plugin shipped only `archive.py` and was
  refused at load because nothing on Windows runs a `.py` directly. It ships an
  `archive.ps1` beside it now (`50e0b1fd5`) and names it with `exec_windows`
  (`plugins/archive/plugin.json:8`), so the refusal it described does not
  happen any more.

  The reading behind *Done* is the host's log on the Windows machine, seen
  while cutting 0.5.497:

      plugin archive: started …archive.ps1 as pid 13400

  **That is a reading that it starts, and not that its whole job was watched.**
  Nothing has checked that what it writes there is complete, or that the files
  can be read back.

  **The argument outlives the item, so it stays.** Plugins can already say what
  to run per system, and the seven agent-CLI plugins do. An `os` field — "do
  not load me here at all" — was considered and **decided against**
  (`dev-docs/poltergeist/provisioning.md` §9.5), because `exec_<os>` expresses
  today's only real case. What was ever missing was the script, never a way to
  say it — which is why the fix was one file and no schema change.

  **Why it is written out rather than deleted.** This line was true when it was
  written and went on being read for a while after it stopped being true. The
  same fact changed in two documents at once and only one of them kept up;
  `README.md` has its own account of the row that went this way. A roadmap that
  distinguishes *Done* from *Built* is the wrong file to quietly drop the
  evidence of a claim that expired — deleting it would leave the file looking
  like it had never been wrong.

### Make the supervising side easier to get right

- **Done, and left here for the way it was wrong.** Splits, shell integration
  and the group chat TUI were all listed as missing above until each was
  measured on a real machine and found working — the first two after they had
  been fixed, the third after the fix that broke it was understood.

  The chat line was wrong three times, in three different ways, and that is
  worth leaving in view. First it said "read-only", inherited from a note
  written before `src/cli/chat.zig` had a compose line. Then it said "expected
  to work", reasoned from the view being shared code. Then it said the tab
  "stays blank" — which was measured, and still misleading: the process died
  146 ms after the tab appeared, so nothing was loading. **"Never finished
  loading" and "failed immediately" are different faults in different halves
  of the program, and the first wording had people looking in the wrong one.**

  The cause was the host being a GUI-subsystem binary: a tab is a ConPTY
  pseudoconsole, and such a process does not attach to one, so the TUI got no
  console handles at all. There are two binaries now, one per subsystem.
- **Compaction** now reminds a supervisor when a group's conversation passes a
  size, and `group_history` can be searched by substring and time range. What
  is still missing is a visible divider in the chat view at the point where a
  compaction happened.

### Agent coverage

Seven CLIs have provisioning plugins (Claude Code, Codex, Gemini, Qwen,
opencode, Kimi, DeepSeek). Only Claude Code on macOS is used daily by the
author; the others are built and lightly tested. Reports from people using the
other six are the fastest way to move this.

`archive` makes eight plugins in the directory and is not one of these. It is
not a CLI and provisions nothing: it is handed chat events and keeps a copy of
them, which is why its `wants.events` is `["chat"]` where every provisioning
plugin's is `["provision"]`.
