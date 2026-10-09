# Roadmap

Polter's aim, stated once so the rest can be measured against it: **a
cross-platform tool that orchestrates several AI coding agents on their own,
and a fast terminal.** Something that serves neither half does not belong
here, however popular it is elsewhere.

Two words are used strictly, because they mean different things to anyone
picking this up:

- **Done** — written, builds, and there is a reading from a run that supports it.
- **Built** — written and it compiles. Not yet shown to work.

What this file said before 2026-10-10, including the lines that were wrong and
were left standing as a record of it, is in
[`dev-docs/roadmap-history.md`](dev-docs/roadmap-history.md).

---

## Where it is now (0.9.x)

**macOS — the platform this is developed on.** Used daily by its author with
Claude Code. Groups, the task panel, transcripts, statistics, roles, projects,
hooks, the settings window and the MCP surface are all exercised there.

**Windows — shipped since 0.5, at parity on the supervising side.**
`windows/host/` is a Rust shell driving the same Zig core. Of the core's 78
keybinding actions the host implements **72**, refuses **4** by name, and still
owes **2** (measured 2026-10-10; the commands are in
[`dev-docs/windows/status.md`](dev-docs/windows/status.md)). The screenshot
tool that arrived in 0.9.1728 was gone through on real Windows machines before
that release; the macOS side of it in its final form was not.

**Linux — builds, unverified.** The GTK app compiles. Nobody has run a
supervised session on it, so there is no release binary; build from source if
you want it.

**Projects do not exist on GTK** -- saving a tab as a project, opening one, and
bringing back a pane's command history and scrollback. Not *Built*, not
started. Nothing in GTK stands in the way; it waits on the same thing as the
rest of Linux, which is a machine that runs the GTK app.
`tools/gtk-has-no-project-half.py` keeps half of it from arriving unannounced.

**Agent coverage.** Seven CLIs have provisioning plugins (Claude Code, Codex,
Gemini, Qwen, opencode, Kimi, DeepSeek). Only Claude Code is used daily by the
author, and only Claude Code reports the end of a turn through hooks; the other
six are watched by how long their screen has been still.

**Network.** Today Polter opens no network port: the MCP server is a socket in
your own runtime directory, and the one outbound request is Check for Updates,
made when you choose it and never on a schedule. *This describes today. It is
no longer a promise about the future* — see [Across machines](#across-machines).

---

## Next: 0.10

Written down in detail in
[`dev-docs/poltergeist/v0.10.md`](dev-docs/poltergeist/v0.10.md). In the order
they will be taken:

1. **Screenshots, third round — a screenshot tool built for AI.** What is
   captured stops being only pixels: the text of a Polter terminal that was in
   the shot, on-device text recognition, where the picture came from, the
   interface elements under the selection. Tools for an agent to check its own
   interface work: what changed between two captures, and distances and
   alignment as numbers. A warning before something that looks like a secret
   leaves the machine.
2. **One group's chat as a pane** of the tab you are working in.
3. **Stacked panes**, with a strip of sub-tabs that shows each terminal's state
   without your having to click through them, and a title area on every tiled
   pane from the same part. Dragging a tab into another tab.
4. **Git worktrees made and accounted for by Polter** when a terminal is
   opened: which tree is whose, which task it serves, whether it has been
   merged. When to use one stays the supervisor's judgement.
5. **A file pane** — a directory tree and previews, in the terminal. It browses
   and does not edit.
6. **Hooks for the other agent CLIs.** Listed and not yet researched.

Also carried into this round from the old roadmap:

- **The last two Windows actions**, both marked `// owed:` in the host.
- **A visible divider in the chat view** where a conversation was compacted.

---

## After that

Ordered by what the research below supports, not by how interesting each is.
Sizes are relative: S, M, L, XL.

### 1. A supervisor that survives its own context running out — M

The task panel and the group log already outlive a restart, and
`session_recall` gets a supervisor back to a group it left. What is missing is
the handover: what a fresh supervisor has to read to be useful within a
minute, and getting its standing back without the person doing it by hand.

*Why first:* losing instructions after compaction is among the most reported
problems with agent CLIs, and it is the one a terminal can blunt, because the
arrangement can live outside any one session. It is also independent of
everything else here.

### 2. Seeing what each agent changed — M

Review is the limit people hit first: agents work in parallel and a person
reads diffs one at a time. With worktrees accounted for (0.10) and a file
pane, the missing piece is a per-agent, per-task view of the changes, and a
way to send a comment on a line back to the agent that wrote it. Reading the
diff stays the person's job; finding it should not be.

*Depends on:* worktrees and the file pane.

### 3. Limits for a night nobody is watching — S to M

Reports of an unattended run filling a disk or spending far more than intended
are few and severe, and no tool offers a hard ceiling. A supervisor can be
given one to enforce: disk use, running time, and — where an agent CLI exposes
it — spend. Per-worker cost that a person can see belongs here too. *How much
of this each CLI makes possible is not yet known.*

### 4. Linux desktop — L

Make the GTK app a supported platform: run supervised sessions on it, bring
projects and the settings window across, and ship a binary. Upstream Ghostty's
GTK side is mature; what is Polter's own has to be built a third time.
Screenshots and input injection under Wayland go through portals that ask the
user each time and do not work on a locked session, so those parts will be
narrower than on the other two platforms and will say so.

*Blocker, unchanged:* a machine that runs it and somebody who uses it daily.

### 5. Headless Linux — M for the first step, XL for the whole

Sessions that die with an SSH connection, and agents that cannot log in on a
machine with no browser, are widely reported. Two steps:

- **A headless node (M).** Polter's core with no window: it keeps terminals
  alive and serves the MCP surface, and a person looks in over SSH with the
  chat TUI that already exists.
- **A daemon the interfaces attach to (XL).** The terminals and the
  orchestration state live in a background process; the macOS, Windows and GTK
  windows and a full TUI are all clients of it. This means moving state that
  lives in each host today down into the core. Prior art built on Ghostty's own
  VT library exists and is worth reading first.

*Why before the two below:* both of them are built on it.

### Across machines

Polter has so far promised that it has no network of its own. **That
restriction is lifted**, on purpose, for the two items below. What stays true:
no account, no cloud service, no relay server, and no telemetry. Nothing
listens on a network until you switch it on, and one machine reaches another
only after the two have been paired by a person. The link is direct, on your
own LAN or your own VPN.

### 6. Legion: Polter instances that talk to each other — L to XL

A supervisor on one host treats a supervisor on another as it would a local
one. Today a supervisor and its workers are a squad; squads get a leader, and
leaders can have a leader. Orders go down as tasks that can be asked about
later, not as a connection that has to stay open — a middle node that drops
must not lose the work.

Typing into another machine's terminal is remote code execution, so the design
starts from that: paired peers only, a stated set of terminals each peer may
reach, authority that can only narrow as it is passed down, an audit record at
every hop, and a person's confirmation on the machine being acted on for
anything dangerous. Text arriving from a peer is data, never instruction.

*Evidence of demand is thin* — a few scattered requests. It is here because it
is where the author wants this to go, and it is placed after the items people
are asking for today.

*Depends on:* the headless node.

### 7. Eyes and hands: computer use and browser debugging — M to XL

Two halves, and the first does not wait for the second.

- **On this machine.** Beyond the screenshot tools: an interface tree, input
  injection, window and process tools, and browser debugging over the Chrome
  DevTools Protocol. Windows first, because the hard-won detail for it already
  exists in a sibling project of the author's and can be carried over; macOS
  has to be written from nothing. Polter's own Windows window is drawn on the
  GPU and is not reachable through UI Automation, so Polter will expose its
  own state through MCP rather than pretend otherwise.
- **On another machine.** The same tools, called across a Legion link: a
  supervisor on a Mac drives a Windows machine to debug a program there,
  without a separate remote-operations service in between.

Polter runs in the user's session and will not ask for more than that. A
locked screen or an elevation prompt is reported as unavailable.

*Depends on:* Legion, for the second half.

### Smaller things worth taking from other tools

Each of these appears in more than one tool people already use, serves the
aim at the top of this file, and is small beside the items above.

- **Be the pane backend for Claude Code's agent teams.** Its split-pane mode
  supports tmux and iTerm2 and names Ghostty as unsupported. Polter already
  has the pane tools.
- **Bring a layout back after a restart with its agent sessions resumed**, not
  only the panes.
- **Ports and environment per worktree**, so several dev servers do not
  collide, and the files a fresh worktree needs are copied into it.
- **A gate before a task is closed**: a check that must pass, run by the
  supervisor, before the panel accepts "done".
- **Looking in from a phone** — to see who is waiting and answer. Only after
  the headless node, and only over the same paired link as everything else.
- **An optional sandbox** for a worker that runs with prompts switched off.

### Unplaced

- **Statistics comparable across nights.** The view measures real things. No
  evidence was found that anybody needs them compared, so this waits for
  somebody to ask.

---

## What this will not become

- **No judgement.** Polter reports how long a screen has been unchanged, and
  passes on what an agent CLI says about its own turns. It will not decide
  that a still screen means "stuck" — it is also thinking, building, or
  waiting for a person. That call belongs to whoever is reading.
- **No telemetry.** There is no number here about how anyone uses this, and
  there will not be one.
- **No account, no cloud, no relay.** Machines that talk to each other do so
  directly and because you paired them.
- **No agent of its own, and no model gateway.** The thinking is done by the
  agent CLI you already installed. Polter's worth is in orchestrating other
  people's agents; shipping one would make it their competitor.
- **Not an editor.** The file pane browses. Editing belongs to your editor.
- **Not a project-management system.** The panel holds who is on what and
  whether it is done.
- **Not an autonomous factory.** The direction is work a person can see and
  step into, not work that runs out of sight.

---

## What the order rests on

Four pieces of research on 2026-10-10: what other terminals and orchestration
tools offer, what people who run agent CLIs report as painful, prior art for
the four heavy items, and a reading of the author's own remote-operations
project. Much of it came from search summaries rather than from pages read in
full, Reddit and X could not be read directly at all, and sizes are estimates
by people who have not built the thing. Where a claim above rests on little,
it says so.

The findings that moved the order:

- "Which agent is waiting for me" is reported again and again and is what a
  terminal is best placed to answer. → stacked panes and pane titles in 0.10.
- Review is the first limit people hit. → item 2.
- Context lost to compaction is among the most reported problems. → item 1.
- Sessions lost over SSH and logins failing on headless machines are widely
  reported; coordinating agents across several machines is not. → headless
  before Legion.
- Comparable orchestration tools are almost all macOS-only. Windows stays a
  first-class platform here, and that is a reason people might choose this.
- A worktree per worker is close to universal elsewhere. → 0.10.

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
