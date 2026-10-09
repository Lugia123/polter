# Security

Polter is a terminal emulator that lets one agent read another terminal's
screen, type into it, and open new ones. That is the product, so the security
question is not "can this be done" but "who may do it, to which terminal, and
what is written down along the way". This document answers those from the code,
with a file and a line for each mechanical claim, and says plainly where the
answer is "nothing does that".

**If this document and the code disagree, the code is right.** Line numbers are
against the commit this file was written on and drift; the surrounding function
names do not.

**Revised 2026-10-10** for three things that had changed underneath it: a
supervisor may now answer permission prompts in some terminals, agents may
take screenshots, and the roadmap no longer promises that Polter will never
use a network. The sections on those were rewritten against the code. **The
line numbers everywhere else were not re-checked** on that pass and are older
than several releases; go by the function names.

[中文版](SECURITY_CN.md)

---

## Scope

This covers the Polter layer — the agent socket, the reachability rules, the
credential references, and what lands on disk. Polter is a fork of
[Ghostty](https://github.com/ghostty-org/ghostty) and inherits its terminal
emulator wholesale; a vulnerability in VT parsing, font shaping or the
renderer is Ghostty's and should go to Ghostty.

---

## Threat model

### What is defended against

- **Another process on this machine driving your terminals.** Reaching the
  agent socket is not enough; a caller must hold a token this process minted
  (`src/poltergeist/Server.zig:684`, `:457`).
- **An agent claiming to be a different terminal.** Identity is derived from
  the token, never from anything the caller says. There is no field in the
  protocol for a caller to name itself (`src/poltergeist/Server.zig:450-456`).
- **A plugin reaching past what it declared.** A plugin's own `wants.calls`
  list is checked before anything else and can only subtract
  (`src/poltergeist/rpc.zig:1066-1074`, `:1210`).
- **An injected line promoting a worker.** A watched terminal is refused
  `become_supervisor` in code (`src/poltergeist/rpc.zig:4489`), so text
  arriving on a worker's screen cannot rearrange who may reach whom.
- **On Windows, the pipe being reachable off the machine.** A named pipe is
  served over SMB to anyone the machine will authenticate
  (`src/poltergeist/transport.zig:36-45`), so it is created with a protected
  DACL naming this user's SID alone (`src/os/windows.zig:389-416`,
  `src/poltergeist/transport_windows.zig:88`, `:260`). If that DACL cannot be
  built, the server **refuses to listen** rather than opening an unprotected
  pipe (`src/poltergeist/transport_windows.zig:260-273`).

### What is not defended against

- **Anything running as you.** A process with your uid can read your
  environment and therefore your token, or read the state directory directly.
  There is no boundary here between Polter and the rest of your session, and
  none is claimed.
- **The content on the screens.** See [Prompt injection](#prompt-injection).
- **A malicious plugin.** Plugins are programs you install and Polter runs
  them; the `wants.calls` gate narrows which RPCs a plugin may make, not what
  the program may do to your machine.
- **Anything over a network.** Polter opens no network port. The only outbound
  request it ever makes is to GitHub's releases API, and only when you choose
  Check for Updates -- there is no background or scheduled check. It is an
  anonymous HTTPS GET: GitHub sees your IP address and a User-Agent naming the
  program (on macOS the system default, which includes the OS version), and
  no account or local data. The socket is local.

  **That is true of every release so far and is no longer a promise about
  later ones.** `ROADMAP.md` ("Across machines") plans direct links between
  machines a person has paired, off until switched on. None of it exists in
  any release. When it does, it gets a threat model of its own in this file
  before it ships, and this paragraph is rewritten rather than left standing.

---

## The local socket

**POSIX:** a unix domain socket in your state directory, at a path carrying
eight random bytes rather than the pid (`src/poltergeist/transport_posix.zig`,
`defaultName`; the reasoning is at `src/poltergeist/Server.zig:809-814`).

**Windows:** a named pipe, `\\.\pipe\polter-<random>`, for a standard-library
reason spelled out at `src/poltergeist/transport.zig:9-34` — not a preference.

**There is deliberately no `chmod` on the socket file, and file permissions are
not the boundary.** `src/poltergeist/Server.zig:220-224` says so in as many
words: socket permissions are not enforced uniformly across the systems this
runs on, so relying on them would be false comfort.

### How a caller is identified

1. Each terminal is minted its own token as it starts: 32 bytes rendered as
   64 hex characters (`src/poltergeist/Server.zig:74-76`, `:405-417`). The
   bytes come from `randomSecure`; **if that fails the code falls back to the
   process-local `io.random` rather than refusing to start**
   (`src/poltergeist/Server.zig:410-415`) — still a cryptographic generator,
   seeded earlier. The fallback is logged at `warn`.
2. It is placed in that terminal's child environment as
   `GHOSTTY_POLTER_TOKEN`, alongside `GHOSTTY_POLTER_SOCKET`
   (`src/Surface.zig:717-718`).
3. The first line on a connection must be an `auth` request or the connection
   is refused (`src/poltergeist/Server.zig:684-706`).
4. The token is matched against every issued token using
   `std.crypto.timing_safe.eql` (`src/poltergeist/Server.zig:457-478`).
5. Tokens are revoked when their terminal goes away
   (`src/poltergeist/Server.zig:430-448`).

Concurrent connections are capped at 16 (`src/poltergeist/Server.zig:42`),
so a caller that can reach the socket cannot spawn threads until the process
runs out.

**Observation, not a defect claim:** the comparison of each candidate is
constant-time, but the loop runs once per *issued* token, so the time taken
varies with how many terminals are open. That leaks the number of live
terminals to something that can already reach the socket and time it. It does
not vary with the token's contents.

---

## Reachability: the three marks

Every rule below is in one function, `authorize`
(`src/poltergeist/rpc.zig:1059`), and they are applied in this order.

| The target's mark | Who may reach it |
| --- | --- |
| **shielded** | Nobody, including a supervisor (`src/poltergeist/rpc.zig:1137`) |
| **watched** or **supervisor** | Only a supervisor (`src/poltergeist/rpc.zig:1167`) |
| **no mark** | Anyone holding a token |

Three things about this are easy to get backwards:

- **Reach is decided by the target, not by the relationship**
  (`src/poltergeist/rpc.zig:1139-1160`). There are no peers: one watched
  terminal cannot touch another, not because they are equals but because the
  other one carries a mark.
- **An unmarked terminal is the open case.** Polter cannot tell whether an
  agent is working in there or a person is reading their mail, and does not
  guess. A mark means somebody arranged something, and rearranging another
  party's arrangement is not a stranger's to do.
- **The shield is asked of everyone before the caller's standing is
  considered**, because `become_supervisor` would otherwise let any unmarked
  terminal promote itself and walk straight through it
  (`src/poltergeist/rpc.zig:1126-1137`).

Separately, methods that change the supervision arrangement require the
supervisor role (`src/poltergeist/rpc.zig:656`, `:1085`), and a call aimed at
the caller's own terminal is refused unless it is on a short safe list
(`src/poltergeist/rpc.zig:955`, `:1124`).

### Opening the socket grants almost nothing on its own

Until you make some terminal the supervisor, an agent holding a token can ask
about itself, read a skill, and list the groups it is in — which is none.
Reading another terminal's screen, typing into one, and making groups all
require the supervisor role, and only the user hands that out
(`src/config/Config.zig:1289-1294`).

**One exception, and it is not small: screenshots.** The screenshot tools are
open to any agent holding a token, supervisor or not, for as long as
`screenshot-agent-access` allows it — and it allows it by default. See
[Screenshots](#screenshots).

### Typing into a terminal

`terminal_send` goes through `Surface.typePoltergeistText`
(`src/Surface.zig:3724`), which refuses two things outright: text carrying an
end-of-paste sequence, whatever the target is doing (`src/Surface.zig:3733-3737`),
and multi-line text when the target does not have bracketed paste on
(`src/Surface.zig:3770-3773`). It is otherwise the ordinary paste path, framed
the way a paste is framed.

### Answering another agent's permission prompt

**Until 2026-09-08 this file said there was no tool for this and never would
be. There is one now**, `terminal_answer_prompt`, and the argument that was
made against it is the reason for its shape (`authorize` in
`src/poltergeist/rpc.zig` keeps both halves in its comment).

- It is a supervisor's tool, and it works only on a terminal whose switch is
  on (`Bus.Entry.may_authorise`). Otherwise it answers `AuthoriseOff`, and the
  keys that answer a box — return, the arrows, tab — are refused at that
  terminal too.
- **In a terminal you started yourself the switch is off** until you turn it
  on from that terminal's own menu (`Agents → Let a Supervisor Answer Prompts
  Here`). No tool can turn it on; `setMayAuthorise` refuses everybody but the
  user.
- **In a tab or a split a supervisor opened, it is on from the start**
  (`Bus.markOpenedByAgent`, since 0.9.1684), and you can switch it off there.
  A terminal a plain worker opened carries no grant.
- A plugin cannot call the tool at all, and nobody may answer their *own*
  prompt through it (`selfPermitted`).

**What that default opens, said plainly:** a supervisor can open a terminal in
a directory and take "Yes, and don't ask again" there, which is a standing
permission for every agent that runs in that directory afterwards. There is no
setting that turns the default off; the per-terminal switch is the way back.

`terminal_send` is not behind the switch. It types text and cannot press
return, and it is an ordinary logged call rather than a way round anything —
but it is a published route, not an absent one.

Text from a plugin that is printed onto a screen or into a log is stripped of
every byte below `0x20`, `DEL`, and the C1 range first
(`src/poltergeist/scrub.zig`, `clean` at `:55`) — a terminal is an interpreter,
and a plugin's line is a paste by another name.

---

## Credentials

A plugin's parameters may be **references**, resolved at the moment the plugin
is called rather than stored (`src/poltergeist/secret.zig`, `resolve` at `:75`):

| Reference | Resolved from |
| --- | --- |
| `env:NAME` | an environment variable |
| `file:~/path` | the first line of a file |
| `keychain:service/account` | the system keychain |
| `cmd:...` | whatever the command prints |

- **Nothing is cached** (`src/poltergeist/secret.zig:46-47`). A vault that has
  locked must fail; a cache would hide that it locked.
- **A reference that cannot be resolved fails; it never falls back to itself**
  (`src/poltergeist/secret.zig:69-74`). Sending `cmd:op read …` to a webhook as
  though it were the key would put the shape of your vault in somebody's chat
  log.
- **`cmd:` runs through the system's command interpreter** — `/bin/sh -c` on
  Unix, `cmd.exe /C` on Windows (`src/poltergeist/secret.zig:29-38`). What you
  may write there follows whichever of those will read it. A resolver is given
  30 seconds, because unlocking a vault can prompt
  (`src/poltergeist/secret.zig:60`).
- **`keychain:` has no resolver on Windows** and says so
  (`src/poltergeist/secret.zig:39-44`, `:218-222`).

Plugin settings files are written owner-only, applied to the empty file before
any secret is in it — `0o600` on POSIX, a protected DACL on Windows
(`src/poltergeist/Plugin.zig:1051-1058`). A failure to restrict on Windows is
logged at `warn` and not fatal (`src/poltergeist/Plugin.zig:1074-1080`), which
is the opposite of the trade the socket makes and is deliberate on both sides.

---

## What is written to disk

Everything lives under `$XDG_STATE_HOME/polter` (`LOCALAPPDATA` on Windows).

| What | Path | Rotation |
| --- | --- | --- |
| Chat stream (machine) | `chat/chat.jsonl` (+`.1`) | 8MB, two generations |
| Chat record (people) | `chat/<group>/<date>.jsonl` | **none** |
| Terminal transcript | `terminals/<id>-<title>/<date>.jsonl` | **none** |
| Task panel events | `tasks/<group>/<date>.jsonl` | **none** |
| Hourly statistics | `stats/<group>/<date>.jsonl` | **none** |
| Screenshots and pasted images | `shots/<timestamp>.png` and a `.json` beside each | **removed after 7 days**, at startup |
| Saved projects, the last session's arrangement | `projects/`, `session.json` | overwritten in place |

- **There is no retention period and nothing prunes the records.** Screenshots
  are the one exception, below. The day-file records are never rotated and
  never trimmed; a day past 8MB
  continues in a `.partN` file beside itself rather than moving anything aside
  (`src/config/Config.zig:1500-1503`, `:1544-1545`;
  `dev-docs/poltergeist/storage.md`).
- **Nothing is redacted.** Terminal output contains API keys, tokens and paths.
  A scrubber that caught nine keys in ten would be worse than none, because it
  would make the file feel safe to send somewhere
  (`src/config/Config.zig:1539-1543`). Treat these files the way you treat your
  shell history.
- Both records are created `0o600` on POSIX (`src/poltergeist/daylog.zig:49-56`).
- **Screenshots** are written `0o600` in a `0o700` directory on POSIX. Files in
  that directory older than seven days are deleted when the app starts, and
  only files whose names match the pattern Polter itself writes — so pointing
  `screenshot-directory` at a folder of your own does not put your files at
  risk (`dev-docs/poltergeist/screenshot.md` §5). A mosaic is applied before
  anything is written: the unblurred picture is never on disk or on the
  clipboard. What the `.json` beside a screenshot holds is every annotation's
  text and position, which display and window it was of, and who took it.
- Both can be turned off: `poltergeist-chat-log` and `poltergeist-terminal-log`,
  each defaulting to on (`src/config/Config.zig:1511`, `:1548`).
- Screen sampling is off unless asked for: `poltergeist-watch` defaults to
  `false` (`src/config/Config.zig:1332`).
- **No telemetry, ever.** Nothing about you or your terminals is sent
  anywhere; Polter has no account, no cloud service and no relay (`ROADMAP.md`,
  "What this will not become"). The one outbound request -- Check for
  Updates, when you choose it -- is described under "Anything over a network"
  above.

The non-redaction and the absent retention period are stated as known
limitations in
[issue #7, item 2](https://github.com/Lugia123/polter/issues/7).

**Not verified:** on Windows these log files are created with
`.default_file` rather than a restricting DACL
(`src/poltergeist/daylog.zig:52-56`) — the `restrict` helper that
`Plugin.zig` uses is not applied to them. What permissions they end up with in
practice therefore depends on what the state directory hands down, and that has
not been measured on a Windows machine.

---

## Screenshots

Since 0.9.1728 Polter takes screenshots, and agents can ask for them.

- **Any agent with a token may capture, not only a supervisor.** The tools
  that list what is on screen, capture a display, a window or a region, take a
  long screenshot, and draw on an existing one are refused on the user's
  setting and not on standing (`requiresSupervisor` in
  `src/poltergeist/rpc.zig` answers `false` for all of them). The setting is
  `screenshot-agent-access`, and **it defaults to `allow`**
  (`src/config/Config.zig`). Set it to `deny`, or use Settings → General →
  Screenshot, and every one of them is refused with a sentence saying why.
- **What can be captured is whatever is on your screen**, not only Polter's
  own windows: another application's window, a password manager left open, a
  message that happened to be visible. A capture made by an agent appears with
  no interface on screen. Each one is recorded with who took it (`by` in the
  `.json`), and that record is a file, not a notification — nothing tells you
  at the moment it happens.
- **A picture is content like any other.** What is in a screenshot goes into
  the model that asked for it, so text on your screen is one more way for
  text to reach an agent. See [Prompt injection](#prompt-injection).
- **Two global triggers for the person.** A hotkey, and a held pair of
  modifier keys with a click, both system-wide. On Windows the click is
  swallowed; on macOS it also reaches the application under the pointer.
  `screenshot-mouse-trigger` changes or disables the second.
- **macOS permissions.** Screen Recording, without which nothing can be
  captured, and Accessibility, which automatic scrolling for a long
  screenshot uses (`ShotSession` and `ShotAgentHost` both ask
  `AXIsProcessTrusted`). Windows asks for none.

**Not verified:** the file permissions and the seven-day removal on Windows
are stated from the specification and have not been read back on a machine.

---

## Prompt injection

**A supervisor reads other terminals' screens, and what it reads goes into its
context. Anything that can put text on one of those screens can put text in
front of the supervising model** — a file being `cat`ed, a dependency's build
output, a web page a worker fetched, a commit message. Two newer routes carry
the same risk: what a hooked agent CLI says at the end of a turn is passed to
its supervisor as text, and a screenshot puts whatever was on the screen in
front of the agent that asked for it.

Polter does not sanitise this and cannot: the content is the product. This is
stated as a known limitation in
[issue #7, item 4](https://github.com/Lugia123/polter/issues/7), and the design
gap behind it is written up at `dev-docs/poltergeist/gaps.md:476-495`.

What exists is structural rather than filtering:

- `become_supervisor` is refused to a watched terminal
  (`src/poltergeist/rpc.zig:4489`), so an injected "promote yourself" cannot
  change the permission structure.
- A watched terminal cannot reach another marked terminal
  (`src/poltergeist/rpc.zig:1167`), so one compromised worker cannot cascade
  into the others by typing into them.

**That closes those paths and not the general one.** Text arriving from a
worker — `group_post` bodies, `terminal_read` output, terminal titles — reaches
the supervisor's context verbatim and carries no marker distinguishing "this is
what a worker said" from "this is an instruction". Today nothing but the
supervising model's own judgement stands between a line of injected text and a
supervisor acting on it. **Where the risk lands: on whoever is running the
session.** If a worker is reading untrusted content, treat what it reports the
way you would treat that content.

---

## Reporting a vulnerability

Please report privately rather than opening a public issue.

Use **[GitHub Security Advisories](https://github.com/Lugia123/polter/security/advisories/new)**
— the "Report a vulnerability" button under the repository's Security tab.

If that form is not available to you, open an ordinary issue saying only that
you have found a security problem and asking for a way to send the details.
**Do not put the details in a public issue.**

Include what you would want to receive: what an attacker can do, the smallest
sequence that shows it, and which commit you saw it on. There is no bounty
programme and no response-time commitment — this is a project with one author.

---

## What has not been done

Stated because the absence of a claim is easy to read as a claim:

- **No security audit or penetration test has been carried out**, by anyone.
  Everything above is a reading of the code, not a finding from an adversarial
  exercise.
- **No fuzzing of the RPC surface.** The protocol is line-delimited JSON parsed
  by the standard library; it has not been fuzzed as a boundary.
- **The reachability rules have unit tests but no adversarial testing.**
  `src/poltergeist/rpc.zig` carries tests for each refusal; nobody has gone
  looking for a way around the set of them.
- **The line numbers in this file have not been re-checked** since it was
  first written, apart from the sections revised on 2026-10-10, which cite
  functions instead.
- **Nobody has gone looking for what an agent can learn from screenshots it
  is allowed to take by default.** The setting exists; the consequences of its
  default have been reasoned about, not tested.
- **Linux is unverified.** The GTK app builds and nobody has run a supervised
  session on it (`ROADMAP.md`), so none of the above has been exercised there.
- **The Windows behaviour above is read from the code**, and only the pipe DACL
  path has a reasoned argument behind it rather than a measurement; effective
  permissions on Windows have not been checked on a machine.
