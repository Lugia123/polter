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

**Windows — new in 0.5.447, and this is its first release.** `windows/host/` is
a Rust shell that drives the same Zig core through libghostty's C API. What has
a reading behind it: the window opens, tabs work, a shell starts, CJK text
renders, IME composition produces Chinese characters in a real terminal, the
menu and its accelerators work, the resources directory is found and the
provisioning plugins start. What is known to be missing is below.

**Linux — builds, unverified.** The GTK app compiles. Nobody has run a
supervised session on it, so there is no release binary; build from source if
you want it. Making this a supported platform needs someone who uses Linux
daily, and that is the honest blocker.

---

## Next

### Close the Windows gaps

These are specific and each one has a place in the code.

- **Splits.** The layout algorithm is already ported — `windows/split-tree/` is
  a zero-dependency crate with 42 tests that runs on any machine. It is not
  wired to the window tree yet. On Windows a split has to be several child
  windows, because a libghostty surface is bound to its `HWND` for life.
- **Action parity.** Of the 72 keybinding actions, 54 are required for parity
  and the host implements 24.
- **Plugins should declare which systems they run on.** Today the host guesses
  from the file extension, so `archive.py` is installed, enabled, and never
  started on Windows — with a log line and nothing else. Whether a plugin can
  run on a system is the plugin's own property, and it needs a field to say so.
- **Shell integration.** Not injected on Windows; the shell is not detected.

### Make the supervising side easier to get right

- **The group chat TUI on Windows** is read-only for now.
- **Compaction** now reminds a supervisor when a group's conversation passes a
  size, and `group_history` can be searched by substring and time range. What
  is still missing is a visible divider in the chat view at the point where a
  compaction happened.

### Agent coverage

Eight CLIs have provisioning plugins (Claude Code, Codex, Gemini, Qwen,
opencode, Kimi, DeepSeek, plus the archive one). Only Claude Code on macOS is
used daily by the author; the others are built and lightly tested. Reports from
people using the other seven are the fastest way to move this.

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
