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
