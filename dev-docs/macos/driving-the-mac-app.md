# Driving the macOS app from a script

On Windows we have `argus`: it screenshots, it clicks, it reads the UI tree.
On macOS we had nothing, so the macOS interface had never been checked by a
machine. This is the equivalent channel, built out of what the system already
ships: `screencapture`, `osascript`, and the accessibility API behind System
Events.

The driver is `tools/mac-drive.sh`. It screenshots a target, reads its menu
structure, and clicks one of its menu items. Everything below was measured on
**macOS 26.5.1 (25F80)** on 2026-09-18; where something was *not* measured
this document says so rather than guessing.

```sh
tools/mac-drive.sh <pid> shot <out.png>
tools/mac-drive.sh <pid> tree [<menu-bar-item>]
tools/mac-drive.sh <pid> click <menu-bar-item> <menu-item>
tools/mac-drive.sh <pid> windows
```

## The rule that comes before the tool

**Drive only a build under test, started by you, and never the copy the person
is working in.** Two copies of this app share a bundle identifier, they look
alike in most of the places you would think to look, and a click that lands on
the wrong one types into somebody's live session.

The script enforces this by refusing any pid whose executable lives in
`/Applications`. That is a refusal with no override flag: if a future caller
genuinely needs to drive an installed copy, that is a new argument and a new
conversation, not a flag somebody can pass by accident.

Never `pkill`/`killall` anything here — the name matches the person's copy too.
Stop your own instance by pid, and check the pid's command line first.

**Do not decide "this is the new instance I just started" by looking for a menu
item you are about to test for.** That is circular. Use the pid, or the start
time.

---

## 1. The one that will bite you: `first process whose …` is a reference by name

```applescript
set p to first process whose unix id is 49549   -- ❌ never
```

That expression does **not** evaluate to the process it matched. It evaluates
to a reference *by name*. You can see it by forcing it to a string:

```
«class pcap» "polter" of application "System Events"
```

`process "polter"` — and this machine had **three** processes called `polter`.
Every later use of `p` re-resolves that name and hands you the first one.
Measured, inside a single script:

```applescript
set p to first process whose unix id is 49549
unix id of p                                       --> 22650   -- wrong
unix id of p                                       --> 22650   -- stably wrong
unix id of (first process whose unix id is 49549)  --> 49549   -- right
```

22650 was the person's own working session. **Nothing reports an error.** A
driver built on that spelling reads entirely plausible data off the wrong
window — the first thing this actually produced was the user's tab title,
`✳ 多角色能力体系设计调研`, read while believing it was the build under test —
and then types into it.

A one-shot expression is fine, because the reference is never stored. What
breaks it is `set`.

### The spelling that works

Walk the list and compare `unix id` **yourself**. List elements are a snapshot;
the error messages confirm the difference in reference form — `item 2 of every
process whose name = "polter"` (by index, into a snapshot) against `«class
pcap» "polter"` (by name):

```applescript
tell application "System Events"
  repeat with p in (every process whose name is "polter")
    if (unix id of p) is 49549 then
      -- act here, on p
    end if
  end repeat
end tell
```

Three consecutive dereferences plus a window read, all `49549`.

### `file of process` cannot be the identity check

System Events answers `/Applications/Polter.app` for **both** pids — the
installed copy and a build running out of a worktree — because they share a
bundle identifier. `ps` tells them apart; System Events does not. Use `unix id`
asked of the object itself. `position of window 1` also distinguishes them
(`-201,106` against `311,457`) and is the one a human can eyeball.

### The gate reads `ps`; the driver walks the accessibility API

Those are two different views of the machine, and a check in one does not
constrain the other. So `mac-drive.sh` re-derives the target **and asserts its
identity inside the same `osascript` invocation that acts on it** — not because
the lookup is known to be wrong, but because a lookup and a click in two
invocations have a gap where the answer can go stale.

That assertion reddened the first time it ran:

```
target moved: asked for pid 49549, got 22650
```

**That was not a constructed floor. It was the assertion catching a real
failure** — which means that before it existed, that code path really did lead
to the user's instance.

---

## 2. The system tools' exit codes cannot be judged on their own

Two separate measurements, same shape:

**`screencapture` exits 0 when it could not write the file.**
```
$ screencapture -x /nope/x.png
screencapture: cannot write file to intended destination, /nope/x.png
$ echo $?
0
```
So the check that catches it is `[ -s "$out" ]`, not the exit code.

**`open` exits 0 for a System Settings pane that does not exist.**
```
$ open "x-apple.systempreferences:com.apple.NOSUCHPANE.bogus?Privacy_Nonsense"
$ echo $?
0
```
Deliberate nonsense is indistinguishable from the four correct URLs if you go
by exit code. A criterion built on it is green forever.

Unauthorised `screencapture` is different again, and worth knowing because it
is *not* a black image:
```
could not create image from display
exit=1, and no file is produced
```
(Note: **no `screencapture: ` prefix on that one**, unlike the unwritable-file
message above it. Both were copied from the terminal as they appeared.)

---

## 3. Permissions: which switch, on which row, and what actually prompts

### Only one switch needs turning on

**System Settings → Privacy & Security → Accessibility**, and the row reads
**`Polter`** (`CFBundleName` and `CFBundleDisplayName` are both `Polter`,
bundle id `com.lugia.polter`). The row is already in the list; it is the toggle
that is off. Nothing needs adding with `+`.

Screen Recording was already granted on this machine, and the same single
Accessibility toggle covered the Apple-Events axis too — see the table below.

### Everything is attributed to the *responsible* process, which is the app that owns your terminal

`tccd`'s own log names it. Three **different** accessing processes, one subject:

| accessing | service | `AUTHREQ_SUBJECT` |
|---|---|---|
| a bare binary I compiled | `kTCCServiceAccessibility` | `com.lugia.polter` |
| `/usr/sbin/screencapture` | `kTCCServiceScreenCapture` | `com.lugia.polter` |
| `/usr/bin/osascript` | `kTCCServiceListenEvent` | `com.lugia.polter` |

```
AUTHREQ_ATTRIBUTION: msgID=46327.1, attribution={
  responsible={identifier=com.lugia.polter, pid=22650,
               responsible_path=/Applications/Polter.app/Contents/MacOS/polter},
  accessing ={identifier=tcc, pid=46327, binary_path=…/scratchpad/probe/tcc}}
AUTHREQ_SUBJECT: msgID=46327.1, subject=com.lugia.polter,
```
(`auid`/`euid` dropped from the attribution line and it was wrapped to fit;
everything else is as logged.)

**Who is *accessing* does not affect attribution.** The answer is not
"osascript", not "Terminal" — it is the app hosting the terminal you are in.

Read it yourself with:
```sh
/usr/bin/log stream --predicate 'process == "tccd"' --style compact
# `log` is a zsh builtin — you must spell out /usr/bin/log
```
and the recorded values with:
```sh
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service,client,auth_value from access where client='com.lugia.polter';"
# auth_value: 0 = denied, 2 = allowed. Accessibility and Screen Recording live
# in this system database, not the per-user one.
```

### Turning the switch on does not need a restart — **but read the next section**

Measured, with nothing restarted, on a process chain that all predated the
change:

```
before:  osascript … get name of every window of process "Finder"
           → “System Events”遇到一个错误：“osascript”不允许辅助访问。 (-25211)
after:   → 桌面                                        exit=0
         osascript … get name of every menu bar item of menu bar 1 of process "Finder"
           → Apple, 访达, 文件, 编辑, 显示, 前往, 窗口, 帮助   exit=0
tccd:    authValue 0 → 2  (authReason 5 → 4), same request shape
TCC.db:  kTCCServiceAccessibility | com.lugia.polter | 2
```

`kTCCServiceListenEvent` went to `2` at the same time, from the same single
toggle — **the person does not also need to grant Automation.**

### ⚠️ You tested new processes, not that long-lived one

This is the collar on the paragraph above, and it is the reason it is written
down: **the next person's three-step criterion will be green exactly like mine
was.**

Everything in this channel is a **freshly forked process** — `screencapture`
and `osascript` are new pids every call, and they ask `tccd` at startup, so
they get the new value immediately. Measured:

```
accessing pid = 22650 (the long-lived app), across four tccd captures:  0 rows
responsible pid = 22650, same captures:                                21 rows
com.apple.osascript appeared as five different pids: 43653 46328 63076 63078 63108
```

22650 appears **only** as `responsible`, **never** as `accessing`. So the grant
inside the long-lived app's own process was **never tested here — that is not a
negative result, it is an experiment nobody ran.** The system itself said as
much when the person ticked Screen Recording: it told them to reopen the app.

So state it narrowly:

> Ticking the switch takes effect immediately for processes **forked after**
> the change. For the **long-lived process itself**, this document has no
> reading.

It could not be measured from outside: the app has no screenshot feature and no
in-process `CGWindowListCreateImage` / `ScreenCaptureKit` path reachable
without changing its code. Whoever does "let the app screenshot itself" will
land on exactly this, and their criterion will pass while the thing is broken.

(One earlier `screencapture` failure, at 02:04, looks like a case of this. It
fell **before** the log capture started, so there is no `tccd` record covering
it, and it is **not** counted as evidence. Its cause is left blank.)

`System Events` *is* long-lived, and it is the real executor of the `osascript`
path — but there is a direct positive reading for it (the menu-bar read above),
so nothing needs to be assumed about what it cached.

### What does *not* prompt

`AXIsProcessTrustedWithOptions(prompt: true)` returned false and **showed no
window**. The criterion is not "I didn't see one" (nothing could be seen — AX
was not granted yet); it is the log: two requests **7 ms apart**, no prompting
line between them, `authValue=0` straight back. There is no window in which a
person could have answered.

Two candidate causes, **neither isolated**: the record was already an explicit
`denied(0)` and TCC does not re-prompt a subject it has ruled on; or the
responsible app is **ad-hoc signed** (`codesign -dv` →
`flags=0x10002(adhoc,runtime)`, `TeamIdentifier=not set`) and does not qualify
to prompt. Isolating them means deleting that denied row, which needs SIP off
and would alter the person's real authorisation state.

`CGRequestScreenCaptureAccess()` was **not run**: Screen Recording was already
`2`, so it would return true without prompting. **"It does not prompt when
already granted" proves nothing about whether it prompts when not granted.**
That cell is untested.

### ⚠️ Ad-hoc signing will take the grant away again

The app is ad-hoc signed. TCC pins an ad-hoc record by cdhash, and **rebuilding
the app changes the cdhash**. The signing facts are measured; **"a reinstall
will invalidate the grant" is an inference that was not verified** — verifying
it means actually replacing `/Applications/Polter.app`. Expect the next release
to surface it, and expect it to look like broken code rather than a lost
permission.

---

## 4. Deep links: send the person straight to the right pane

Both spellings work, and the old one is not dead — the system maps it to the
new extension. Measured from the unified log:

```
x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility
```
```
[com.apple.extensionkit:launch] Launching process with config:
    bundleID: com.apple.settings.PrivacySecurity.extension
… hostViewController(_:didBeginHosting:) com.apple.settings.PrivacySecurity.extension
```
(the launch line continues `instance ID: nil`; the timestamp/pid prefixes and
the `SettingsExtensionHostView.swift:NNN` path on the second line are dropped)

### The anchor works, and the criterion is the window title

| URL anchor | System Settings `name of window 1` |
|---|---|
| `Privacy_Accessibility` | **`辅助功能`** |
| `Privacy_ScreenCapture` | **`录屏与系统录音`** |
| `Privacy_NonsenseBogus` (floor) | `隐私与安全性` — stops at the parent pane |
| bogus pane id (floor) | `隐私与安全性` — stops at the parent pane |

Identical for both the old and the new pane spelling. Read it with:

```sh
osascript -e 'tell application "System Events" to tell process "System Settings" \
  to return name of window 1'
```

A wrong anchor **does not fail** — it lands on the parent pane. So the title is
the criterion; `open`'s exit code is 0 in all four rows above.

### Two criteria that look like they work and do not

- **`open`'s exit code.** Covered above: 0 for deliberate nonsense.
- **"the pane's extension process appeared."** `SecurityPrivacyExtension.appex`
  stays resident after the first deep link, so every later URL — including the
  bogus one — produces a **byte-identical** process list. It can tell you the
  privacy pane was opened once, and nothing after that.

---

## 5. Smaller things that cost time

**Do not assume the language of a name; read it first.** On this machine the
menu bar items come back in English (`File`, `View`, `Window`) while the items
inside them are in Chinese (`关于 Polter`, `最小化`).

**`{name, unix id} of every process whose unix id is N` is not a shortcut.**
AppleScript builds the property list over *all* processes and then tries to
filter the result; the error is a two-screen dump of every process on the
machine.

**Zero windows is a legal state.** Reading `position of window 1` turns it into
`无效的索引 (-1719)`. The app-level menu bar is still readable with no windows
at all, so the driving channel keeps working.

**A `\n` inside a double-quoted shell string is a literal backslash-n**, and
`osascript` then fails at *compile* time (`syntax error … (-2741)`). That is the
good failure mode: not one statement ran, so nothing was clicked.

**Starting a second instance rewrote the user's `~/.claude.json`.** The
provisioning plugin pointed the user-level `polter` MCP registration at the
temporary worktree, which breaks their MCP the moment that worktree is removed.
`open -n --env HOME=<isolated dir>` **does not prevent this**: the plugin's home
does not come from `$HOME`, it comes from a field the host passes in
(`polter/plugins/_sdk/provision.sh`, `home=$(field home)`). Check
`~/.claude.json` after starting an instance, and put it back.

---

## Reproducing the three things

```sh
# the target must be your own build, started with:
#   open -n -a <your worktree>/zig-out/Polter.app
# then find it by pid — never by name, three processes are called polter:
ps -Ao pid,lstart,command | grep 'MacOS/polter' | grep -v '+mcp'

tools/mac-drive.sh <pid> shot /tmp/shot.png     # → PNG 3600x2338, 2.08 MB
tools/mac-drive.sh <pid> tree                   # → Apple, Polter, File, Edit, View,
                                                #   Agents, Project, Window, Help
tools/mac-drive.sh <pid> windows                # → 49549, 1, ~/…/ghostty, 311, 457
tools/mac-drive.sh <pid> click Polter "关于 Polter"
tools/mac-drive.sh <pid> windows                # → 49549, 2, , ~/…/ghostty, 750, 279
```

The click's criterion is the target's own state changing — window count 1 → 2 —
not the script printing that it acted.

**And that distinction is not theoretical.** Later in the same session, with
the target sitting at zero windows, the identical command came back clean and
changed nothing:

```
$ tools/mac-drive.sh 49549 click Polter "关于 Polter"
clicked Polter > 关于 Polter          ← exit 0
$ tools/mac-drive.sh 49549 windows
49549, 0                              ← unchanged; no About window appeared
```

`click` succeeding means the accessibility API delivered the click. It does
**not** mean the menu item did anything. Why it did nothing that time is not
established here — the target had reached zero windows by then, for reasons
this document also does not establish — and the point stands without it: **read
the target's state, or you will report a click that never had an effect.**

### The floor, and where each cell reddens

A driving channel that cannot fail is worse than none. Change the clicked
object to one that does not exist and the script must redden; these are the six
cells and the line each one lands on. All exit 1.

| cell | message |
|---|---|
| menu item missing | `no menu item '关于 NoSuchItem' under 'Polter' on pid 49549` · `(-1728)` |
| menu bar item missing | `no menu bar item 'NoSuchMenu' on pid 49549` · `(-1728)` |
| pid missing | `no process with pid 999999` |
| **installed copy** | `refusing to drive 22650: /Applications/Polter.app/… is an installed copy, not a build under test` |
| `tree` on missing menu | `could not read menu 'NoSuchMenu' of pid 49549` · `(-1728)` |
| screenshot unwritable | `screencapture exited 0 but produced no file at /nope/x.png` |
