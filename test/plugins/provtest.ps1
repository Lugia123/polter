# Drive the Windows provisioning plugins through the real protocol.
#
# One run, many assertions, because every run of this costs an approval.
# Nothing outside C:\app\provtest is touched unless -Real is passed.

param(
    # Where the plugin tree was deployed to on this machine. The defaults are
    # the paths every recorded run used; pass them only to test a checkout
    # somewhere else.
    [string]$Source = 'C:\app\provsrc',
    [string]$Root = 'C:\app\provtest',
    # How long any one plugin conversation may take before the harness gives
    # up on it. The stub-driven cases finish in under a second; only a real
    # CLI ever gets near this.
    [int]$TimeoutSec = 60,
    [switch]$Real
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Plugins = Join-Path $Root 'plugins'
$Bin = Join-Path $Root 'bin'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

$script:Pass = 0
$script:Fail = 0

function Check {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Host "PASS  $What" }
    else { $script:Fail++; Write-Host "FAIL  $What"; if ($Detail) { Write-Host "      $Detail" } }
}

# --- one conversation with one plugin ---------------------------------------
function Invoke-Plugin {
    param(
        [string]$Key,
        [string]$Hello,
        [string[]]$Batches,
        [string]$PathPrepend = $Bin,
        # When given, handed to the stub CLI so it can record the argv it was
        # called with. See group 6b.
        [string]$ArgvLog = ''
    )

    $script = Join-Path (Join-Path $Plugins $Key) 'provision.ps1'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $psi.WorkingDirectory = $Root
    $psi.EnvironmentVariables['PATH'] = "$PathPrepend;$env:SystemRoot\system32;$env:SystemRoot"
    if ($ArgvLog) { $psi.EnvironmentVariables['POLTER_TEST_ARGV'] = $ArgvLog }

    $p = [System.Diagnostics.Process]::Start($psi)

    # .NET Framework has no StandardInputEncoding, so the writer is built by
    # hand -- and with "`n", because the protocol is one object per newline
    # and a CRLF would leave a stray carriage return inside the line.
    $w = New-Object System.IO.StreamWriter($p.StandardInput.BaseStream, $Utf8)
    $w.AutoFlush = $true

    # **Everything is written, then everything is read.** Reading up to the
    # first `{"ok":` and stopping there is how a test stops being able to see
    # an acknowledgement that came too early -- it reads the extra one as the
    # answer and never looks at what followed. The whole stream is collected
    # and the assertions below name the sequence they expect.
    $w.Write($Hello + "`n")
    foreach ($b in $Batches) { $w.Write($b + "`n") }
    $w.Close()

    # **Read on background threads, and give the whole thing a deadline.**
    # `ReadToEnd()` on its own has no timeout: the first `-Real` run met a
    # a real CLI's `mcp list` that never returned, and the suite sat there
    # for eight minutes until it was killed by hand. A test harness that can hang
    # forever turns "the CLI is wedged" into "the run is still going", and
    # those need to look different.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) {
        # `/T` for the tree: what actually hangs is usually a grandchild --
        # a `.cmd` shim's node, not the shell we started.
        & taskkill /PID $p.Id /T /F 2>&1 | Out-Null
        $p.WaitForExit(5000) | Out-Null
    }

    $all = $outTask.Result
    $err = $errTask.Result

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($all -split "`n")) { if ($l.Trim()) { $out.Add($l.TrimEnd("`r")) } }
    if ($timedOut) { $out.Add("<TIMED OUT after $TimeoutSec s, process tree killed>") }

    return [pscustomobject]@{
        Stdout = $out
        Stderr = $err
        Exit = $p.ExitCode
    }
}

function New-Hello {
    param([string]$Key, [string]$Scope = 'user', [string]$Skills = 'yes')
    '{"hello":1,"plugin":"' + $Key + '","cursor":0,"events":["provision"],"groups":"","calls":[],"params":{"scope":"' + $Scope + '","skills":"' + $Skills + '"}}'
}

function New-Batch {
    param([string]$HomeDir, [string]$Version, [string]$SkillPath, [string]$Exe = 'C:\app\polter.exe')
    $h = $HomeDir -replace '\\', '\\'
    $s = $SkillPath -replace '\\', '\\'
    $e = $Exe -replace '\\', '\\'
    '{"cursor":0,"through":1,"events":[{"n":1,"kind":"provision","at_ms":1786819271275,"exe":"' + $e + '","version":"' + $Version + '","version_key":"POLTER_REGISTERED","home":"' + $h + '","skills":[{"name":"mine","path":"' + $s + '"}]}]}'
}

function Assert-StdoutClean {
    param([string]$What, $Result)
    $bad = @($Result.Stdout | Where-Object { $_ -notmatch '^\{"(ok|tell)"' })
    Check "$What -- stdout carries only acknowledgements and reports" ($bad.Count -eq 0) ("stray: " + ($bad -join ' | '))
}

# --- fixture ----------------------------------------------------------------

if (Test-Path $Root) { Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $Bin -Force | Out-Null
New-Item -ItemType Directory -Path $Plugins -Force | Out-Null

# Laid out here the way the bundle lays them out, because each plugin finds
# its library by walking `..\_sdk` from its own directory; a flat directory
# resolves that to the parent of this one and the script fails on its first
# statement.
Copy-Item -Path (Join-Path $Source '*') -Destination $Plugins -Recurse -Force

$skillSrc = Join-Path $Root 'mine.md'
$skillText = "---`nname: mine`ndescription: a skill`nversion: 1`n---`n`nBody with a name: line in the prose.`n"
[System.IO.File]::WriteAllText($skillSrc, $skillText, $Utf8)

# A home directory with a non-ASCII name, because the console code page on
# this machine is not UTF-8 and that is the failure this proves absent.
$home1 = Join-Path $Root ([char]0x5F20 + [char]0x4E09 + '-home')
New-Item -ItemType Directory -Path $home1 -Force | Out-Null

# Stub CLIs.
#
# **`codex` is deliberately not among them**, so group 1 has a shipped host
# whose program is not on PATH. `claude` and `opencode` are here because
# groups 2, 4, 5 and 6b drive them.
$okCmd = "@echo off`r`necho stub ok`r`nexit /b 0`r`n"
$failCmd = "@echo off`r`necho something went wrong 1>&2`r`nexit /b 3`r`n"
[System.IO.File]::WriteAllText((Join-Path $Bin 'opencode.cmd'), $okCmd, $Utf8)
[System.IO.File]::WriteAllText((Join-Path $Bin 'claude.cmd'), $okCmd, $Utf8)

Write-Host "== 1. absent: a host whose CLI is not installed =="
# `codex` rather than the `kimi` this used to be: task 2207 took kimi's
# plugin out, and of the four that stay this is the one no stub is put on
# PATH for. What the group asserts is unchanged -- a shipped host whose
# program is absent says `status=absent` and is not an error.
$r = Invoke-Plugin -Key 'codex' -Hello (New-Hello 'codex') -Batches @((New-Batch $home1 '1.0.0' $skillSrc))
Check '1 absent -- both lines acknowledged true' (($r.Stdout -join ' ') -eq '{"ok":true} {"ok":true}') ($r.Stdout -join ' | ')
Check '1 absent -- the log says status=absent' ($r.Stderr -match 'status=absent') $r.Stderr
Assert-StdoutClean '1 absent' $r

Write-Host "== 2. json-merge host: opencode, no python anywhere =="
$cfg = Join-Path $home1 '.config\opencode\opencode.json'
$r = Invoke-Plugin -Key 'opencode' -Hello (New-Hello 'opencode') -Batches @((New-Batch $home1 '1.0.0' $skillSrc))
Check '2 opencode -- acknowledged true' (($r.Stdout -join ' ') -eq '{"ok":true} {"ok":true}') ($r.Stdout -join ' | ')
Check '2 opencode -- the config was created' (Test-Path $cfg) $cfg
if (Test-Path $cfg) {
    $bytes = [System.IO.File]::ReadAllBytes($cfg)
    Check '2 opencode -- no byte-order mark' (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) ("first bytes: " + ($bytes[0..2] -join ','))
    $d = ConvertFrom-Json ([System.IO.File]::ReadAllText($cfg, $Utf8))
    Check '2 opencode -- key is `mcp`, command is a list' (@($d.mcp.polter.command).Count -eq 2 -and $d.mcp.polter.type -eq 'local') (ConvertTo-Json $d -Depth 10 -Compress)
    Check '2 opencode -- the version marker is in `environment`' ($d.mcp.polter.environment.POLTER_REGISTERED -eq '1.0.0') ''
    $before = [System.IO.File]::ReadAllBytes($cfg)

    Write-Host "-- 2b. same version twice writes nothing"
    $r2 = Invoke-Plugin -Key 'opencode' -Hello (New-Hello 'opencode') -Batches @((New-Batch $home1 '1.0.0' $skillSrc))
    $after = [System.IO.File]::ReadAllBytes($cfg)
    Check '2b opencode -- second run is byte for byte identical' (@(Compare-Object $before $after -SyncWindow 0).Count -eq 0) ''
    # **It used to assert silence here, and silence was the defect (task 218).**
    # A run with nothing to do said nothing, and so did a run that fell over
    # before it could do anything -- the same absence for two situations a
    # reader has to tell apart. So the assertion is now the positive one: it
    # says which of the two happened, and it still must not claim it wrote.
    Check '2b opencode -- says it had nothing to do' ($r2.Stderr -match 'status=unchanged') $r2.Stderr
    Check '2b opencode -- and does not claim it wrote' (-not ($r2.Stderr -match 'status=provisioned')) $r2.Stderr

    # **The write that replaces an existing file, which nothing above does.**
    # Everything before this point either creates the config or declines to
    # touch it, so the atomic-replace branch had no coverage at all -- and it
    # was broken. This is the assertion that would have caught it.
    Write-Host "-- 2d. a new build rewrites a config that is already there"
    $r4 = Invoke-Plugin -Key 'opencode' -Hello (New-Hello 'opencode') -Batches @((New-Batch $home1 '3.0.0' $skillSrc))
    Check '2d opencode -- acknowledged true' (($r4.Stdout -join ' ') -eq '{"ok":true} {"ok":true}') ($r4.Stdout -join ' | ')
    $d4 = ConvertFrom-Json ([System.IO.File]::ReadAllText($cfg, $Utf8))
    Check '2d opencode -- the version marker followed the build' ($d4.mcp.polter.environment.POLTER_REGISTERED -eq '3.0.0') (ConvertTo-Json $d4 -Depth 10 -Compress)
    Check '2d opencode -- nothing was left beside it' ((-not (Test-Path "$cfg.polter-tmp")) -and (-not (Test-Path "$cfg.polter-bak"))) ''

    Write-Host "-- 2c. a config that does not parse is refused, not repaired"
    $broken = "{`nthis is not json`n"
    [System.IO.File]::WriteAllText($cfg, $broken, $Utf8)
    $r3 = Invoke-Plugin -Key 'opencode' -Hello (New-Hello 'opencode') -Batches @((New-Batch $home1 '2.0.0' $skillSrc))
    Check '2c opencode -- refused, acknowledged false' (($r3.Stdout | Select-Object -Last 1) -eq '{"ok":false}') ($r3.Stdout -join ' | ')
    Check '2c opencode -- exactly two acknowledgements, one per line written' ((@($r3.Stdout | Where-Object { $_ -match '^\{"ok"' })).Count -eq 2) ($r3.Stdout -join ' | ')
    Check '2c opencode -- the broken file is untouched' ([System.IO.File]::ReadAllText($cfg, $Utf8) -eq $broken) ''
    Check '2c opencode -- the log names the file and the parser complaint' ($r3.Stderr -match 'cannot parse' -and $r3.Stderr -match 'opencode.json') $r3.Stderr
    Check '2c opencode -- the user is told before the acknowledgement' (($r3.Stdout | Select-Object -Last 2)[0] -match '^\{"tell"') ($r3.Stdout -join ' | ')
    Assert-StdoutClean '2c opencode' $r3
    Remove-Item $cfg -Force
}

# --- group 3 is gone, and why ------------------------------------------------
#
# It was `deepseek`: "the other json host, different shape" -- a second
# Windows host whose entry is edited in a config file rather than through an
# `mcp add`, asserted on the shape of the entry it wrote.
#
# Task 2207 removed deepseek, and **the class it stood for has no second
# member on Windows any more**: `opencode` is the only host left whose
# `provision.ps1` edits a config file (`antigravity`, the other one, ships
# `provision.sh` only and is macOS-only). Group 2 already drives opencode
# over the same ground, entry shape included, so the row was folded into it
# rather than pointed at a host that would have made it a duplicate.
#
# What is lost, plainly: **a shape fragment that stops being distinctive now
# has one fewer neighbour to be caught by.** `Resident.zig`'s
# "the hosts that edit a config file" says the same thing about the `sh`
# side (task 2207).

Write-Host "== 4. skills: rendering, stamping, idempotence, pruning =="
# `opencode` rather than the `qwen-code` this used to be (task 2207): of the
# hosts left it is the one whose skills directory is a plain directory under
# the home, which is all this group needs. Its `Get-HostSkillsSharedDir`
# (`~/.claude/skills`) is not there in this fixture, so its own directory is
# the one used -- the shared branch has its own test (`skills-off.py`).
$skillsDir = Join-Path $home1 '.config\opencode\skills'
$mine = Join-Path $skillsDir 'polter-mine\SKILL.md'

# A stale one this plugin wrote, and one it did not.
New-Item -ItemType Directory -Path (Join-Path $skillsDir 'polter-gone') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $skillsDir 'polter-gone\SKILL.md'), "---`nname: polter-gone`n---`nold`n", $Utf8)
New-Item -ItemType Directory -Path (Join-Path $skillsDir 'polter-keep') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $skillsDir 'polter-keep\SKILL.md'), "---`nname: polter-keep`n---`nmine`n", $Utf8)
[System.IO.File]::WriteAllText((Join-Path $skillsDir 'polter-keep\notes.md'), "not ours`n", $Utf8)

$r = Invoke-Plugin -Key 'opencode' -Hello (New-Hello 'opencode') -Batches @((New-Batch $home1 '1.0.0' $skillSrc))
Check '4 skills -- acknowledged true' (($r.Stdout -join ' ') -eq '{"ok":true} {"ok":true}') ($r.Stdout -join ' | ')
Check '4 skills -- the skill was installed' (Test-Path $mine) $mine
if (Test-Path $mine) {
    $raw = [System.IO.File]::ReadAllText($mine, $Utf8)
    Check '4 skills -- the frontmatter name matches the directory' ($raw -match "(?m)^name: polter-mine$") $raw
    Check '4 skills -- stamped with the build that wrote it' ($raw -match "(?m)^polter-build: 1\.0\.0$") $raw
    Check '4 skills -- the `name:` in the prose is left alone' ($raw -match 'a name: line in the prose') ''
    Check '4 skills -- LF only, no CRLF' (-not $raw.Contains("`r")) ''
    $b = [System.IO.File]::ReadAllBytes($mine)
    Check '4 skills -- no byte-order mark' (-not ($b[0] -eq 0xEF)) ''
    $stamp = (Get-Item $mine).LastWriteTimeUtc

    Write-Host "-- 4b. same build again writes nothing"
    Start-Sleep -Milliseconds 1200
    $r2 = Invoke-Plugin -Key 'opencode' -Hello (New-Hello 'opencode') -Batches @((New-Batch $home1 '1.0.0' $skillSrc))
    Check '4b skills -- not rewritten' ((Get-Item $mine).LastWriteTimeUtc -eq $stamp) ''

    Write-Host "-- 4c. a different build rewrites it and the stamp follows"
    $r3 = Invoke-Plugin -Key 'opencode' -Hello (New-Hello 'opencode') -Batches @((New-Batch $home1 '9.9.9' $skillSrc))
    $raw3 = [System.IO.File]::ReadAllText($mine, $Utf8)
    Check '4c skills -- the stamp is the new build' ($raw3 -match "(?m)^polter-build: 9\.9\.9$") $raw3
    Check '4c skills -- exactly one stamp' ((([regex]::Matches($raw3, '(?m)^polter-build: ')).Count) -eq 1) $raw3
}
Check '4d prune -- a skill no longer shipped is removed' (-not (Test-Path (Join-Path $skillsDir 'polter-gone'))) ''
Check '4d prune -- one with a second file is left alone' (Test-Path (Join-Path $skillsDir 'polter-keep\notes.md')) ''

Write-Host "== 5. skills=no is a parameter that does something =="
$home2 = Join-Path $Root 'home-noskills'
New-Item -ItemType Directory -Path $home2 -Force | Out-Null
$r = Invoke-Plugin -Key 'opencode' -Hello (New-Hello 'opencode' 'user' 'no') -Batches @((New-Batch $home2 '1.0.0' $skillSrc))
Check '5 skills=no -- nothing was installed' (-not (Test-Path (Join-Path $home2 '.config\opencode\skills'))) ''

Write-Host "== 6. a registration that fails is loud =="
[System.IO.File]::WriteAllText((Join-Path $Bin 'claude.cmd'), $failCmd, $Utf8)
$home3 = Join-Path $Root 'home-fail'
New-Item -ItemType Directory -Path $home3 -Force | Out-Null
$r = Invoke-Plugin -Key 'claude-code' -Hello (New-Hello 'claude-code') -Batches @((New-Batch $home3 '1.0.0' $skillSrc))
Check '6 failed -- acknowledged false' (($r.Stdout | Select-Object -Last 1) -eq '{"ok":false}') ($r.Stdout -join ' | ')
# The exact sequence, not "a tell somewhere before the last ok". An
# acknowledgement written too early is still followed by a tell and another
# ok, and the loose form reads that as correct.
$seq = @($r.Stdout | ForEach-Object { if ($_ -match '^\{"ok":true') { 'ok+' } elseif ($_ -match '^\{"ok":false') { 'ok-' } elseif ($_ -match '^\{"tell"') { 'tell' } else { '?' } }) -join ','
Check '6 failed -- the sequence is exactly greeting-ack, report, refusal' ($seq -eq 'ok+,tell,ok-') "sequence: $seq" 
Check '6 failed -- the log says status=failed step=mcp' ($r.Stderr -match 'status=failed step=mcp') $r.Stderr
Check '6 failed -- the CLI own complaint survived to the log' ($r.Stderr -match 'something went wrong') $r.Stderr
Assert-StdoutClean '6 failed' $r
[System.IO.File]::WriteAllText((Join-Path $Bin 'claude.cmd'), $okCmd, $Utf8)

Write-Host "== 6b. the mcp add line keeps ``-e`` after the positional arguments =="
#
# **A command line was wrong on every platform for as long as the file had
# existed, and every test passed anyway.**
#
# The host it was found on was `qwen-code`, whose `mcp add` took
# `<name> <command> [args...]` with an *array* `-e`: yargs makes an array
# option greedy and `--` ends parsing, so what followed the `--` was not
# counted as a positional either, and the call was refused with
# `Not enough non-option arguments: got 1, need at least 2`. That host's
# plugin is gone (task 2207). **The hazard did not go with it, and it has
# two ends**: `--` is what stops the served command from being read as one
# of the CLI's own options, and it is also what stops anything written after
# it from being read as an option at all.
#
# So the rule this group holds is the pair, and the two ways to get it wrong
# are opposite: **the version marker, an option, before the terminator; the
# served command and its argument, positionals of the served side, after
# it.** `claude-code` is the host it now runs against -- it is the one left
# in the tree whose registration goes through a CLI that has a `--`, which
# is the whole subject.
#
# What is asserted is the argv **this repository generates**, which is the
# part we own. It does **not** prove `claude` accepts that shape: that is
# somebody else's parser and no stub can speak for it. The same rule is
# pinned on the `.sh` side by a Zig test (`Resident.zig`, "the mcp add line
# keeps the option and the served command on their own sides of `` `--` ``"),
# so the two ports cannot drift apart.
$argvLog = Join-Path $Root 'argv.txt'
# A batch file rather than a PowerShell script, because that is what npm
# installs and what the plugin will actually find on PATH.
#
# **It records the raw command line and does not tokenise it.** The first
# version wrote one argument per line with `%~1` + `shift`, which looks
# obviously right and is wrong on Windows: **`cmd` treats `=` as an argument
# separator**, on a par with space, comma and semicolon. So
# `POLTER_REGISTERED=1.2.3` arrived at the assertion as two arguments and 6b
# failed -- while the real call was fine, as the real CLI run that found the
# bug proved by writing the whole value into its config.
#
# That is worth more than the bug it caused: **the observer was corrupting
# what it observed**, and it did so in the direction of looking like a defect
# in the thing under test. Splitting into arguments is already an
# interpretation; `%*` is the observation.
#
# `(echo %*)` is parenthesised on purpose. Written `echo %*>>file`, the last
# argument here ends in `3` and `cmd` would read `3>>` as a redirect of file
# handle 3 -- a second way for the recorder to eat its own evidence.
$recorder = (@'
@echo off
(echo %*)>>"%POLTER_TEST_ARGV%"
exit /b 0
'@) -replace "`n", "`r`n"
[System.IO.File]::WriteAllText((Join-Path $Bin 'claude.cmd'), $recorder, $Utf8)

$homeArgv = Join-Path $Root 'home-argv'
New-Item -ItemType Directory -Path $homeArgv -Force | Out-Null
$r = Invoke-Plugin -Key 'claude-code' -Hello (New-Hello 'claude-code') `
    -Batches @((New-Batch $homeArgv '1.2.3' $skillSrc)) -ArgvLog $argvLog

if (-not (Test-Path -LiteralPath $argvLog)) {
    Check '6b argv -- the stub recorded something' $false 'no argv.txt was written'
} else {
    # One line per invocation. The plugin calls `mcp remove` and `mcp get`
    # before `mcp add`, and asserting against the wrong one of those would
    # pass for the wrong reason.
    $lines = @([System.IO.File]::ReadAllText($argvLog, $Utf8) -split "`r?`n" | Where-Object { $_.Trim() })
    $add = @($lines | Where-Object { $_ -like 'mcp add *' })

    Check '6b argv -- the plugin called `mcp add` exactly once' ($add.Count -eq 1) "recorded: $($lines -join ' / ')"

    if ($add.Count -ge 1) {
        $line = $add[0]
        # The literal `New-Batch` puts on the line by default, not a
        # variable: there is no script-scope `$Exe` here, and `Set-StrictMode`
        # makes reading one an error rather than an empty string.
        $iExe = $line.IndexOf('C:\app\polter.exe')
        $iMcp = $line.IndexOf('+mcp')
        $iE = $line.IndexOf(' -e ')
        # Matched with spaces around it, so `--scope` is not mistaken for it.
        $iDash = $line.IndexOf(' -- ')

        Check '6b argv -- the served exe and +mcp are both on the line' (($iExe -ge 0) -and ($iMcp -ge 0)) $line
        # The rule, stated as the rule rather than as a literal command line:
        # a literal would break on any innocuous addition and teach nobody why.
        Check '6b argv -- the `--` terminator is on the line' ($iDash -ge 0) $line
        Check '6b argv -- `-e` comes before the terminator' (($iE -ge 0) -and ($iDash -ge 0) -and ($iE -lt $iDash)) $line
        Check '6b argv -- the served exe comes after the terminator' (($iExe -ge 0) -and ($iDash -ge 0) -and ($iExe -gt $iDash)) $line
        Check '6b argv -- +mcp comes after the terminator' (($iMcp -ge 0) -and ($iDash -ge 0) -and ($iMcp -gt $iDash)) $line
        # **`=` and all.** This is the assertion the tokenising recorder broke:
        # it saw two arguments where the CLI sees one. Kept as an exact
        # substring so that reverting the recorder goes red here again.
        Check '6b argv -- the version marker went with the flag, `=` intact' ($line -match ' -e POLTER_REGISTERED=1\.2\.3(\s|$)') $line
    }
}

[System.IO.File]::WriteAllText((Join-Path $Bin 'claude.cmd'), $okCmd, $Utf8)

Write-Host "== 7. a greeting that is not one =="
$r = Invoke-Plugin -Key 'claude-code' -Hello '{"nope":1}' -Batches @()
Check '7 bad greeting -- acknowledged false' (($r.Stdout -join ' ') -eq '{"ok":false}') ($r.Stdout -join ' | ')
Check '7 bad greeting -- exit 2' ($r.Exit -eq 2) "exit=$($r.Exit)"

Write-Host "== 8. an empty batch is a heartbeat =="
$r = Invoke-Plugin -Key 'claude-code' -Hello (New-Hello 'claude-code') -Batches @('{"cursor":0,"through":0,"events":[]}')
Check '8 heartbeat -- acknowledged true' (($r.Stdout -join ' ') -eq '{"ok":true} {"ok":true}') ($r.Stdout -join ' | ')

if ($Real) {
    Write-Host "== 9. the real opencode on this machine =="
    #
    # **`opencode`, because it is the only host left that can be confirmed
    # this way.** The route needs the CLI installed on the machine and one of
    # two things: it honours `$HOME` (a scratch home, the real config never
    # opened) or a config file that nothing else on the machine rewrites
    # while the run is happening. `claude-code` has neither -- every run of
    # it goes through `claude mcp add`, and `~/.claude.json` changes on its
    # own every few minutes on a machine running Claude Code, which is what
    # the byte-for-byte backup check below would trip over. `opencode` is
    # edited in a file of its own that nothing else writes.
    #
    # **This group used to be `qwen-code`** (task 2207). What it establishes
    # is unchanged and is still not "the agent reached Polter": it is the
    # four things that are the plugin's own job -- the call the plugin makes
    # runs and exits zero, the entry appears in the CLI's own config, the
    # CLI **itself** reports it back, and the skill lands in its skills
    # directory.
    $realHome = $env:USERPROFILE
    $exe = 'C:\app\polter-host.exe'
    $cfgPath = Join-Path $realHome '.config\opencode\opencode.json'
    $skillsOwn = Join-Path $realHome '.config\opencode\skills'
    # Where opencode reads Polter's skills instead, when they are already
    # there: its `provision.ps1` says `~/.claude/skills` is the one copy and
    # installs none of its own (`Get-HostSkillsSharedDir`, task 1806).
    $skillsShared = Join-Path $realHome '.claude\skills'

    # A copy taken before anything is written, named so it is obvious who
    # left it and easy to put back by hand.
    #
    # **And then checked, before a single byte is written, with the run
    # aborted if the check fails.** The backup is the only thing standing
    # between this and somebody's real configuration, and until this point it
    # had never run: rehearsing it against a fake home would have exercised a
    # different path than the one that matters. A backup that verifies itself
    # on the path it actually guards is worth more than one that was watched
    # working somewhere else.
    #
    # A config that is not there at all is the normal case for a fresh
    # machine, and then there is nothing to back up and nothing to lose.
    $bak = $null
    if (Test-Path -LiteralPath $cfgPath) {
        $bak = Join-Path $realHome ('.config\opencode\opencode.json.polter-bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Copy-Item -LiteralPath $cfgPath -Destination $bak -Force

        $srcBytes = [System.IO.File]::ReadAllBytes($cfgPath)
        $bakBytes = [System.IO.File]::ReadAllBytes($bak)
        $identical = ($srcBytes.Length -eq $bakBytes.Length) -and
                     (@(Compare-Object $srcBytes $bakBytes -SyncWindow 0).Count -eq 0)

        # Recorded in the log itself, so the log is a second copy of the
        # facts even if both files are later lost.
        $sha = (Get-FileHash -LiteralPath $cfgPath -Algorithm SHA256).Hash
        Write-Host "backup:   $bak"
        Write-Host "original: $($srcBytes.Length) bytes, sha256 $sha"

        Check '9a real opencode -- the backup is byte for byte the original' $identical "src=$($srcBytes.Length) bak=$($bakBytes.Length)"
        if (-not $identical) {
            Write-Host "ABORTING before any write: there is no usable backup."
            Write-Host ""
            Write-Host "RESULT passed=$script:Pass failed=$script:Fail"
            exit 1
        }
    } else {
        Write-Host "no $cfgPath yet -- nothing to back up"
        $sha = '(none)'
    }

    # What the prune step could reach in a real home, said before it runs.
    # Only `polter-*` directories are ever candidates, and only ones this
    # plugin would recognise as its own.
    $atRisk = @()
    foreach ($dir in @($skillsOwn, $skillsShared)) {
        if (Test-Path -LiteralPath $dir) {
            $atRisk += @(Get-ChildItem -LiteralPath $dir -Directory -Filter 'polter-*' -ErrorAction SilentlyContinue | ForEach-Object { "$dir\$($_.Name)" })
        }
    }
    Write-Host "existing polter-* skills that pruning could touch: $(if ($atRisk.Count) { $atRisk -join ', ' } else { '(none)' })"
    $r = Invoke-Plugin -Key 'opencode' -Hello (New-Hello 'opencode') `
        -Batches @((New-Batch $realHome '0.0.0-provtest' $skillSrc $exe)) `
        -PathPrepend $env:PATH
    Write-Host "stdout: $($r.Stdout -join ' | ')"
    Write-Host "stderr: $($r.Stderr)"

    if (($r.Stdout -join ' ') -match 'TIMED OUT') {
        Write-Host ""
        Write-Host "The plugin never finished talking to the real CLI. Nothing below"
        Write-Host "this line ran, and the backup above is still good. The CLI hung,"
        Write-Host "and the next step is a probe of that CLI, not of this plugin."
        Write-Host ""
        Write-Host "RESULT passed=$script:Pass failed=$script:Fail"
        exit 1
    }

    if (-not (Test-Path -LiteralPath $cfgPath)) {
        # Absent, not failed: the plugin says `status=absent` and writes
        # nothing when the CLI is not on PATH. Reported as that, because
        # "nothing was written" and "it wrote nothing it should have" look
        # the same on disk.
        Write-Host "no $cfgPath after the run -- is opencode installed on this machine?"
        Check '9 real opencode -- the CLI was on PATH' ($r.Stderr -notmatch 'status=absent') $r.Stderr
    } else {
        $d = ConvertFrom-Json ([System.IO.File]::ReadAllText($cfgPath, $Utf8))
        $has = $null -ne $d.PSObject.Properties['mcp'] -and $null -ne $d.mcp.PSObject.Properties['polter']
        Check '9 real opencode -- polter is registered in ~/.config/opencode/opencode.json' $has ''
        if ($has) { Write-Host ("      entry: " + (ConvertTo-Json $d.mcp.polter -Depth 10 -Compress)) }
    }

    # What opencode itself says it has, which is the only answer that counts:
    # a key in a file we wrote proves we can write files.
    $env:PATH = "$env:APPDATA\npm;$env:PATH"
    Write-Host "-- opencode mcp list --"
    & opencode mcp list 2>&1 | ForEach-Object { Write-Host "      $_" }
    $ownSkill = Test-Path (Join-Path $skillsOwn 'polter-mine\SKILL.md')
    $sharedSkill = Test-Path (Join-Path $skillsShared 'polter-mine\SKILL.md')
    Check '9 real opencode -- the skill landed, in one of the two places the plugin says' ($ownSkill -or $sharedSkill) "own=$ownSkill shared=$sharedSkill"
    # Only one of them, and which one is not this group's to assume: the
    # plugin picks, and says which in its own log.
    Check '9 real opencode -- and in exactly one of them' (-not ($ownSkill -and $sharedSkill)) "own=$ownSkill shared=$sharedSkill"
    if ($r.Stderr -match 'skills=shared') { Write-Host "      the plugin says: shared" }

    # Left in place rather than tidied away: the registration is the point of
    # this run, and a cleanup that ran before anybody looked would take the
    # evidence with it. Said out loud so nobody has to reconstruct it.
    Write-Host ""
    Write-Host "-- left on this machine, and how to undo it --"
    Write-Host '   ~/.config/opencode/opencode.json   mcp.polter -- undo with: opencode mcp remove polter'
    Write-Host '   the polter-mine skill              delete the directory it is in'
    if ($bak) { Write-Host "   $bak  the backup -- delete once you are happy" }
}

Write-Host ""
Write-Host "RESULT passed=$script:Pass failed=$script:Fail"
