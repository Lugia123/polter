# Roadmap

Polter is young — the first commit of its own is from August 2026 — so this is
short on purpose. It says where the work actually is, not where it would be
nice for it to be.

Two words are used strictly, because they mean different things to anyone
picking this up:

- **Done** — written, builds, and there is a reading from a run that supports it.
- **Built** — written and it compiles. Not yet shown to work.

---

## Where it is now (0.5.x)

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

**Linux — builds, unverified.** The GTK app compiles. Nobody has run a
supervised session on it, so there is no release binary; build from source if
you want it. Making this a supported platform needs someone who uses Linux
daily, and that is the honest blocker.

---

## Next

### Close the Windows gaps

These are specific and each one has a place in the code.

- **Action parity.** The host handles **46 of the core's 72** keybinding
  actions. The remaining 26 are a difference, not a to-do list: some are GTK-
  or macOS-specific and should never exist here, and which of the rest matter
  on Windows has not been worked out. Both numbers are measured rather than
  remembered, and the commands are in
  [`docs/windows/status.md`](docs/windows/status.md) — **an earlier version of
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
  (`docs/poltergeist/provisioning.md` §9.5), because `exec_<os>` expresses
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

---

## Further out

- **A supervisor that survives its own context running out.** The task panel
  and the group log already outlive a restart, and `session_recall` gets a
  supervisor back to a group it left. The remaining hard part is the handover
  itself — what a fresh supervisor needs to read to be useful in one minute.
- **Statistics worth acting on.** The view exists and measures real things
  (task lifetimes, who spoke, how long terminals sat still). What it does not
  yet do is make any of that comparable across nights.

---

## What this will not become

Worth stating on a roadmap, because these are the features most often asked for
and the answer will not change:

- **No judgement.** Polter reports how long a screen has been unchanged. It
  will not decide that this means "stuck" — a still screen is also thinking,
  building, or waiting for a person, and being wrong about that is worse than
  saying nothing. That call belongs to whoever is reading.
- **No account, no service, no network of its own.** A unix socket in your own
  runtime directory. It never talks to a model; the thinking is done by the
  agent CLI you already installed.
- **No telemetry.** There is no number here about how anyone uses this, and
  there will not be one.

---

## Governance

Polter is one person's project today, with no other contributors yet. Being
honest about that is more useful than describing a structure that does not
exist. What is in place:

- MIT, the same licence as upstream, with upstream's copyright kept alongside
  this fork's — see [LICENSE](LICENSE).
- Upstream Ghostty is merged in as it moves, so this does not drift into a
  stale copy.
- [CONTRIBUTING.md](CONTRIBUTING.md) says which half of the tree is this
  fork's and which half belongs upstream, so a patch does not get written
  against the wrong project.
- Issue and pull request templates ask for the two things that make a report
  actionable: what was expected, and what was actually run.

The next step here is having someone other than the author land a change.
