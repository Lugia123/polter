# Provisioning plugin tests (Windows)

Manual tests for `plugins/*/provision.ps1` and `plugins/_sdk/provision.ps1`
— the PowerShell half of the provisioning plugins, added because Windows
cannot execute a `.sh` and refuses the plugins with `error.InvalidExe`. See
`docs/windows/development.md` 5.3 and `docs/poltergeist/provisioning.md`.

**These run on Windows only**, which is why they are here and not in the Zig
test suite: `zig build test` runs on a machine with no PowerShell on it, and
the one end-to-end test that does drive a shipped plugin
(`Resident.zig`, "an installed skill says which build wrote it") drives the
`.sh` version.

**They live under `test/` and not beside the plugins on purpose.**
`GhosttyResources.zig` installs each plugin directory wholesale and excludes
only `.md`, so anything dropped into `plugins/` ships to users.

## The files

| | |
| --- | --- |
| `provtest.ps1` | The suite. 42 assertions across the protocol, the two host families, skills, and the failure paths. |
| `mutate.ps1` | The floor under the suite: six injections, each run against `provtest.ps1`, each reverted afterwards. |
| `probe.ps1` | For when an injection survives — runs a plugin by hand and prints its raw stdout and stderr instead of an assertion's verdict. |

## Deploying

Nothing builds these; the plugin tree is copied to the Windows machine as it
stands in the repository:

```
plugins/_sdk/provision.ps1        ->  C:\app\provsrc\_sdk\provision.ps1
plugins/<key>/provision.ps1       ->  C:\app\provsrc\<key>\provision.ps1
test/plugins/*.ps1                ->  C:\app\
```

`C:\app\provsrc` and `C:\app\provtest` are the defaults; pass `-Source` and
`-Root` (and `-Sdk` / `-Suite` for the other two) to point somewhere else.

`_sdk` must sit **beside** the host directories, not above them: each plugin
finds its library by walking `..\_sdk` from its own directory.

## Running

```
powershell -NoProfile -ExecutionPolicy Bypass -File C:\app\provtest.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File C:\app\mutate.ps1
```

**`-File`, not `-Command`.** On the machine these were developed against,
`powershell -Command "…"` echoes the command instead of running it. This is
the same requirement the plugin host has to satisfy when it spawns a plugin,
and it is stated in the header of `plugins/_sdk/provision.ps1` for that
reason.

`-ExecutionPolicy Bypass` is needed because the default policy refuses script
files outright. `-NoProfile` is not decoration: a user profile that prints
anything puts it on the plugin's standard output, where the host judges
anything that is not an acknowledgement or a report to be misconduct and
kills the process.

Long runs want a log file rather than a console: `mutate.ps1` runs the suite
eight times and outlives most remote-execution timeouts.

```
powershell -NoProfile -ExecutionPolicy Bypass -File C:\app\mutate.ps1 > C:\app\mutate.log 2>&1
```

## What `-Real` does, and what it cannot show

Without it, `provtest.ps1` touches nothing outside its own root: the home
directories are fake, the agent CLIs are `.cmd` stubs on a PATH built for the
child process. One of the fake homes has a non-ASCII name, because
`%USERPROFILE%` containing one is ordinary on Windows and the console code
page is not UTF-8.

`-Real` runs the `qwen-code` plugin against the Qwen Code actually installed
on the machine and the user's real `%USERPROFILE%`. It copies
`.qwen\settings.json` to `.qwen\settings.json.polter-bak-<timestamp>` before
anything is written, prints the path, the original's size and its SHA-256,
**compares the copy to the original byte for byte, and aborts the run without
writing anything if they differ**.

That check is there rather than a rehearsal of the backup against a fake home,
and the difference is the point: the backup is the only thing between this run
and somebody's real configuration, and a rehearsal exercises a different path
than the one that matters. A backup that verifies itself on the path it
actually guards is worth more than one that was watched working elsewhere.

The run also prints, before pruning can happen, which `polter-*` directories
already exist under `~/.qwen/skills` — those are the only ones pruning could
ever reach — and, at the end, exactly what it left behind and how to undo it.
It does not tidy up after itself: the registration is the point of the run,
and a cleanup that ran before anybody looked would take the evidence with it.

**It cannot show that the agent reaches Polter, and should not be reported as
though it does.** The registration names an executable that does not exist on
Windows yet — nothing there serves `+mcp`. What `-Real` establishes is the
four things that are the plugin's own job:

- `qwen mcp add` runs and exits zero
- `mcpServers.polter` appears in `~/.qwen/settings.json`
- `qwen mcp list` reports it back, from Qwen Code's own mouth
- the skill lands in `~/.qwen/skills/polter-*/SKILL.md`

The far end is somebody else's milestone.

## The `mcp add` argument order (group 6b)

`qwen mcp add` and `gemini mcp add` take `<name> <command> [args...]`, and
their `-e` is an *array* option: yargs makes it greedy, and `--` ends parsing,
so what follows is not counted as a positional either. With `-e` written in
the middle the parser saw one positional and refused the whole call —
`Not enough non-option arguments: got 1, need at least 2`.

That was wrong on every platform from the day the files were written, in both
the `.sh` and the `.ps1`, and every test passed. Group 6b puts a batch file on
`PATH` that records the argv it was handed and asserts the ordering rule; the
`.sh` side is pinned by a Zig test (`Resident.zig`, "the mcp add line keeps
`-e` after the positional arguments") which runs both `qwen-code` and `gemini`.

**What those tests prove is the argv this repository generates** — the part we
own and the part that was wrong. They do not prove the CLI accepts that shape;
no stub can speak for somebody else's parser. That half was measured against
qwen 0.15.11 on 2026-09-01: exit 0, with the entry it wrote read back and
checked rather than the exit code alone. Two claims, two kinds of evidence, and
the tests freeze a dated belief about what the CLI wants — if upstream changes,
they stay green while production breaks, which is why the version and date are
written into the test rather than left implicit.

## `qwenprobe.ps1`

Written after the first `-Real` run hung on `qwen mcp list` with no `node`
process alive and nothing written. Two causes with completely different next
steps -- **Qwen Code cannot run without a terminal on this machine**, or **the
way it is being called is wrong** -- and the hang itself cannot tell them
apart.

Four invocations, each read-only, each with a wall-clock deadline and a
process-tree kill when it expires, so the probe finishes even if every call
hangs:

1. `qwen --version` — does it start at all
2. `qwen --help` — does it parse arguments without a terminal
3. `qwen mcp list` — the exact call the plugin makes first
4. the same, run as `node <entry.js> mcp list`, **bypassing the `.cmd` shim**

(4) is the discriminator: if it answers while (1)-(3) hang, the problem is the
npm shim and `cmd.exe`, not Qwen Code, and the fix belongs in how a plugin is
spawned rather than in the acceptance path.

Standard input is redirected and closed immediately in every case, so a CLI
waiting for a person reads end-of-file and gives up; one that hangs anyway is
hanging on something else. The probe hashes `~/.qwen/settings.json` before and
after and prints both -- it is supposed to write nothing, and that is checked
rather than asserted.

## What this line of work keeps rediscovering

Written down here because this file outlives the conversation that produced
it. Every entry cost something to learn, several of them twice, and a few were
found by walking into them **after** writing the rule down.

Instances marked *(host)* come from the Windows host work rather than from
these plugins; they are kept because the same shape turning up in a different
language is most of the evidence that it is a shape and not a coincidence.

### 1. The observing tool corrupts what it observes — and it looks like a defect in the thing under test

Three instances so far, in three different languages, all within two days:

| Where | What it did |
| --- | --- |
| A `.cmd` stub recording argv one argument at a time | **`cmd` splits on `=`**, so `POLTER_REGISTERED=1.2.3` arrived as two arguments and an assertion failed about a call that was correct |
| A Zig multiline string holding a shell script | Zig multiline strings are **raw**, so `\n` reached `printf` as two characters and quietly corrupted the JSON the fixture wrote |
| A screenshot compared at 0.6 scale | produced a defect that was not in the product |

What makes this expensive is not that the tool is wrong — it is that **the
direction of the error points at the thing being tested**. All three times the
first instinct was to go and debug the product.

**Splitting, scaling, decoding and re-encoding are all interpretation.** Record
the rawest thing available: `%*` rather than `%1 %2 …`, the bytes rather than a
parse, the command line rather than the argument vector.

### 2. When something is inexplicable, print the intermediate product

Not the assertion's verdict — the artefact itself. Every one of the three above
was solved in one step by printing what was actually there:

- the recorded argv line, which showed `POLTER_REGISTERED 1.2.3` as two fields
- the config file, whose contents ended in a literal `\n`
- the plugin's own stderr, which said `The path is not of a legal form.`

A verdict tells you a test failed. The artefact tells you **who** is wrong, and
that is usually the question.

### 3. "What does it look like?" and "did it happen at all?" are different assertions

This is the one that keeps finding real bugs, because a suite can be thorough
about the first and completely silent about the second.

- The `mcp add` argument order was wrong on every platform for as long as the
  file existed. Every test asserted what the command line looked like once it
  was issued; **none asked whether it was issued**, and the stub said yes to
  everything.
- The staleness check was blind, so the plugin rewrote the user's config on
  **every launch**. The test that should have caught it compared the file
  before and after — and a plugin that rewrites the same values produces the
  same bytes, so it passed. It only went red once it asked the SDK's own
  `status=provisioned` instead.

**If a property is "this must not happen", do not assert on the state
afterwards.** Identical state is the expected outcome of both the right
behaviour and the wrong one. Count the calls, or read the report.

### 4. "No error" is not "it worked"

The gap between them is one specific step, and it is always the same step: an
absent complaint proves the call returned, not that the effect happened.

| Read as success | What it actually showed |
| --- | --- |
| No `error writing to quit pipe` in the log *(host)* | that `errno >= 0` — **not** that the bytes reached the pipe |
| `opencode.json` was written with the entry we intended | that **our** writer agreed with **our** reader; opencode had never been asked |
| `~/.claude.json` changed during the run | that *something* wrote it — two other Claude Code sessions were doing so throughout |

Each of these was one question away from being settled, and the question is
always of the same form: **ask the far side, or ask for the specific thing.**
`claude mcp get polter` rather than reading the file back. "Is my version
string in there" rather than "did the file change".

### 4b. Ask whether the check *could* fail, not whether it passed

The sister of entry 4, and the sharper of the two. Entry 4 is about
misreading a piece of evidence. This one is about **a check that is
structurally incapable of producing evidence at all** — and it presents as a
green test, so nothing ever prompts you to look.

The question that finds it, and it can be asked before the check is ever run:

> **If the thing under test were wrong, would this check see it?**

Six instances in one day, six different dimensions, and not one of them was
caught by looking at the check's result — because the result was always
"pass":

| The check | What it could not reach |
| --- | --- |
| The launch table's tests, with the target OS baked in | the other system's rows: "the `.ps1` row is wrong" was something no test on the build machine could go red for |
| A repaint assertion reading the centre pixel *(host)* | the defect — the old canvas covered that pixel either way |
| A global-hotkey check driven by a script running inside the app *(host)* | the failure mode, since running there guaranteed the app was foreground |
| A hand-written parser's own unit tests *(host)* | the other implementation; they proved only that it agreed with itself |
| The mutation runner, with its target file hard-coded | a whole group of assertions in a *different file* — those had no floor at all, and the reason looked like "not scheduled yet" |
| The offline pre-check for that runner's anchors | **the layer that produces the string.** It confirmed the text I wanted was in the file; what was wrong was the PowerShell escaping, so the anchor the script actually looked for was never the one I had checked |

**The mutation runner is the trap in miniature.** On a to-do list, "nobody has
run the floor for 6b yet" and "the floor cannot reach 6b" look identical — and
only one of them goes away by running it again.

**And the pre-check is this entry applied to itself.** It was written
*specifically* to stop a bad anchor from reaching the machine, and it reached
the file without reaching the escaping. Knowing the rule does not exempt the
thing you write to enforce it.

The fix is the same shape every time: **take the dimension the check cannot
reach and make it a parameter.** The OS becomes an argument
(`launchKindFor(tag, exec)`); the file becomes a field on each injection; the
anchor is extracted from the here-string that will actually be used rather
than retyped; the fixture comes from the other implementation rather than
from the same hand; the assertion point is computed from the before and after
rather than fixed at the centre *(host)*.

**And a corollary, because self-checks are the commonest form of this.** A
restore step that verifies against *the snapshot it took when it started*
reports success after faithfully restoring a file that was already wrong. Its
check is closed on itself. Verify against something outside the run — the
bytes in the repository, a hash taken elsewhere — or the check only tells you
the script is self-consistent.

### 5. A reading generalises only as far as the conditions it was taken under

Two readings from one log, on the same run, with opposite fates *(host)*:
writing to the quit pipe returned success, and that generalises, because it
does not depend on whether the read end was closed. `CancelIoEx` also returned
success, and that does **not** generalise, because its result depends on
whether a read was pending at that instant — and the fix under test changed
exactly that.

Before reusing a green reading, ask what was true when it was taken, and
whether the change you are making disturbs it. **The same file, the same
minute, can hold one number you may quote and one you may not.**

### 6. Same family is not the same product

Three instances, all inside one week, all in this directory:

- `qwen-code` and `gemini` are the same upstream and had **the same bug for
  different reasons** — `gemini` prints its server list on stderr *and* omits
  the environment; `qwen` prints on stdout and only omits the environment. A
  comment saying "the same hole is expected" was half wrong.
- `opencode` is in the config-editing family for a reason that expired: it
  **does** have `mcp add` now, and is still in that family because the one it
  has is an interactive wizard. Right conclusion, dead reason — and a dead
  reason is what sends the next person back down the same path.
- `~/.gemini/skills` **not existing** was read as "we are writing into a
  guessed directory". Measured, the path is what `gemini skills install`
  prints as its own destination; the directory was absent because nobody had
  installed a skill. **Absence had two causes and the reading did not
  distinguish them** — the same fault as entry 3, committed by someone who
  had just written entry 3 down.

That last one is worth the space: **knowing a rule does not stop you applying
its opposite.** What stopped it was reporting the suspicion separately instead
of acting on it, which cost one message and saved switching off a feature that
worked.

### 7. A criterion that happens to hold and one that was built to hold look identical on the day they both pass

So build the fixture to be hostile to the property, not merely consistent with
it. The skill that pruning must **not** delete carries the `polter-` prefix,
holds exactly one `SKILL.md`, and names itself correctly — **every guard says
yes to it**, and only the shipped list saves it. A candidate that failed some
other check would have proved nothing about the check under test.

Same for an injection that survives: it means the test has a hole, **or** that
a later check caught the mutation, **or** that the mutation tripped a latent
bug which hid it. Those are three different findings and only one of them is
"add an assertion". See "Reading `mutate.ps1`" below — all three happened.

## Handing this line on

Five of the seven host plugins have been confirmed by the CLI they target. What
follows is what a seventh confirmation needs, and what each of the six actually
established, because the two columns are not the same and were reported as one
for longer than they should have been.

### Confirming a host needs three things, and all three are checkable first

1. **That CLI installed on a machine you can drive.** `deepseek` and `kimi`
   are unconfirmed for this reason alone — not for any doubt about the code.
2. **It honours `$HOME`.** Four have been checked — `claude-code`, `codex`,
   `gemini`, `opencode` — and all four do, each checked separately rather than
   inferred from the last. It is what makes the whole exercise free: the run
   happens in a scratch home and the real configuration is never opened.

   **`qwen-code` is confirmed without this**, by the other route: its run was
   against the real home on the Windows machine, with the config copied first
   and the copy compared to the original byte for byte **before** anything was
   written, and the run set to abort if they differed. That route works and is
   the one to use when a scratch home is not available — but it is not
   evidence about `qwen`'s `$HOME` handling, which remains unknown.

   Either way, hash the real config before and after. And the question that
   settles it is not "did the file change" but "is the string I wrote in
   there": on a machine running Claude Code, `~/.claude.json` changes on its
   own every few minutes.
3. **A read-only subcommand that reports what it has.** `claude mcp get`,
   `codex mcp get`, `qwen mcp list`, `opencode mcp list`. Without one, the
   shape can only be confirmed by writing it and hoping — which is the state
   `deepseek` is in even if somebody installs it.

Two smaller notes that cost time: a CLI may refuse to run at all until it is
authenticated (`gemini` wants `GEMINI_API_KEY` set to *anything* before `mcp
add` will run), and macOS has no `timeout`, so bounding these runs needs a
helper.

### What is actually established, per host

**Registration** — does that CLI accept what we write?

| Host | Judged by | Version marker |
| --- | --- | --- |
| `claude-code` | `claude mcp get` prints every field | **value echoed** |
| `codex` | `codex mcp get` prints every field | key echoed, **value masked**; the value is confirmed by the TOML `codex mcp add` itself wrote |
| `qwen-code` | `qwen mcp list` (Windows, real machine) | not echoed — inferred |
| `gemini` | entry read back, plus a four-pass idempotence contract | read from the file, not echoed by the CLI |
| `opencode` | `opencode mcp list` finds it and tries to spawn it | not echoed — inferred |
| `deepseek`, `kimi` | — | not installed anywhere available |

**Skills** — does that CLI read the directory we install into? **A different
question with a different answer**, and combining the two columns is why this
one went unexamined for so long.

| Host | Directory | Evidence |
| --- | --- | --- |
| `claude-code` | `~/.claude/skills/` | **end to end.** The `polter-*` skills this plugin installed are loaded and listed by a running Claude Code — not "it says it sees them", it is using them |
| `gemini` | `~/.gemini/skills/` | path confirmed: `gemini skills install` prints it as its own destination. **Whether it loads what we put there is untested** |
| `codex` | `~/.codex/skills/` | the directory is codex's own (it holds a `.system/` created at codex's install). **Whether it loads what we put there is untested**, and codex has no read-only skills command to ask |
| the other four | — | `host_skills_dir` returns nothing on purpose. Writing into a guessed directory leaves litter on somebody's machine |

### Where the far end still is not

None of this shows an agent *reaching* Polter. The registration names an
executable that does not serve `+mcp` on Windows yet. That is a different
milestone, and no amount of work on these plugins moves it.

## Reading `mutate.ps1`

An injection that survives has three possible causes and they are not the
same finding:

1. **The suite has a hole.** Add the assertion.
2. **The injection was neutralised by a later check.** The prune path has
   three narrowing checks; removing the second leaves the third catching it,
   because `Get-ChildItem` sorts `notes.md` ahead of `SKILL.md` and the name
   read out of the wrong file matches nothing. Remove both and it goes red —
   which is what M5 does, and why it names two anchors.
3. **The injection tripped a latent bug that hid it.** M2a forces the MCP
   registration to be considered stale on every run, which made
   `Edit-PolterJson` write on the second pass for the first time ever — and
   the write failed, so the file did not change and the log said
   `status=failed` rather than `status=provisioned`, and both of the
   assertions watching that turned green for the wrong reason. The bug was
   `File.Replace($tmp, $Path, $null)`: `$null` does not survive PowerShell's
   binding into a `string` parameter, arrives as `""`, and only ever fires
   when the target already exists. `probe.ps1` exists because no assertion
   could have told you that; the plugin's own stderr did.

`mutate.ps1` prints whether each injection actually changed the file on disk.
"The mutation was never applied" and "the mutation killed nothing" produce
the same green, and only one of them means anything.
