# The opencode adapter's Windows half, on Windows (task 1781).
#
# `compare.py` beside this file holds `adapter.ps1` to `adapter.py` on a Mac,
# where the database is read through the system's `libsqlite3`. What only a
# Windows machine can say is what this checks:
#
#   1. `winsqlite3.dll` loads, under the PowerShell Polter starts adapters with
#      (Windows PowerShell 5.1), and reads opencode's database read-only while
#      something else holds it open in WAL mode -- as opencode does while it
#      runs. A Python process makes the database and keeps it open; nothing
#      here writes to it.
#   2. `identify` names the session by the start of the process given as
#      `sidecar_pid`, which is all Windows has (no `pid`).
#   3. `launch` goes on with a session the database has (`-s`), and starts a
#      new one, with a note, for one it has not.
#   4. Behind npm's `opencode.cmd` it starts `node.exe` and the
#      `bin\opencode` script, never the batch file.
#
# Run on the test machine, from the repository's copy of the plugin:
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File windows-check.ps1 -Adapter <dir>\adapter.ps1 [-Python <python.exe>]
#
# Nothing of the person's is read or written: every file is under a fresh
# directory in %TEMP%, removed at the end, and the stand-in `opencode.cmd`
# and `node.exe` there are only looked at, never run for anything but
# `--version` (which fails, so no hooks -- that is expected, and said).
#
# Exit 0 when every check holds, 1 when one does not, 2 when it could not run.
#
# ASCII only: Windows PowerShell reads a script without a byte-order mark in
# the system code page.

param(
    [Parameter(Mandatory = $true)][string]$Adapter,
    [string]$Python = 'python'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $Utf8
$failures = 0

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Host "ok    $Name" } else { Write-Host "FAIL  $Name"; Write-Host "      $Detail"; $script:failures++ }
}

if (-not (Test-Path -LiteralPath $Adapter)) { Write-Host "no adapter at $Adapter"; exit 2 }
$Adapter = (Resolve-Path -LiteralPath $Adapter).Path

$base = Join-Path ([System.IO.Path]::GetTempPath()) ('oc1781 ' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$homeDir = Join-Path $base 'home'
$cwd = Join-Path $base 'proj'
$npm = Join-Path $base 'npm'
$null = New-Item -ItemType Directory -Force -Path $homeDir, $cwd, (Join-Path $npm 'node_modules\opencode-ai\bin')
$db = Join-Path $homeDir '.local\share\opencode\opencode.db'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $db)
$stop = Join-Path $base 'stop'
$ready = Join-Path $base 'ready'

# The holder: makes the database in WAL mode, the rows, and keeps it open
# until told to stop.
$holder = Join-Path $base 'holder.py'
[System.IO.File]::WriteAllText($holder, @'
import os, sqlite3, sys, time
db, cwd, ready, stop = sys.argv[1:5]
now = int(time.time() * 1000)
con = sqlite3.connect(db)
con.execute("pragma journal_mode=wal")
con.execute("create table session (id text primary key, project_id text, parent_id text, slug text, directory text, title text, version text, time_created integer, time_updated integer)")
con.executemany("insert into session (id, project_id, parent_id, directory, time_created, time_updated) values (?, 'p', ?, ?, ?, ?)",
                [("ses_old", None, cwd, now - 86400000, now - 86000000), ("ses_new", None, cwd, now, now + 5),
                 ("ses_child", "ses_new", cwd, now, now), ("ses_elsewhere", None, "C:\\else", now, now)])
con.commit()
open(ready, "w").write(str(os.getpid()))
while not os.path.exists(stop):
    time.sleep(0.2)
con.close()
'@, $Utf8)

$p = $null
try {
    try {
        $p = Start-Process -FilePath $Python -ArgumentList @("`"$holder`"", "`"$db`"", "`"$cwd`"", "`"$ready`"", "`"$stop`"") -PassThru -WindowStyle Hidden
    } catch {
        Write-Host "could not start $Python to hold the database: $($_.Exception.Message)"
        exit 2
    }
    $until = (Get-Date).AddSeconds(30)
    while (-not (Test-Path -LiteralPath $ready) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path -LiteralPath $ready)) { Write-Host 'the database holder did not start'; exit 2 }
    Check 'the database is in WAL mode and held open' ((Test-Path -LiteralPath ($db + '-wal')) -and (Test-Path -LiteralPath ($db + '-shm'))) 'no -wal / -shm beside it'
    $holderPid = [int](Get-Content -LiteralPath $ready -Raw)

    # A stand-in npm: `opencode.cmd` and what it runs, and a `node.exe` that
    # is only looked at. Ahead of anything else on PATH, so a real opencode
    # on this machine is not the one found.
    [System.IO.File]::WriteAllText((Join-Path $npm 'opencode.cmd'), "@echo off`r`nexit /b 1`r`n", $Utf8)
    [System.IO.File]::WriteAllText((Join-Path $npm 'node_modules\opencode-ai\bin\opencode'), "#!/usr/bin/env node`n", $Utf8)
    Copy-Item -LiteralPath (Join-Path $env:windir 'System32\where.exe') -Destination (Join-Path $npm 'node.exe')
    $env:PATH = $npm + ';' + $env:PATH

    function Ask([string]$Question, $Req) {
        $json = ($Req | ConvertTo-Json -Compress -Depth 10)
        $out = $json | & powershell -NoProfile -ExecutionPolicy Bypass -File $Adapter $Question
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($out | Out-String | ConvertFrom-Json)
    }

    $me = @{ POLTER_AGENT_CLI = 'opencode' }
    $id = Ask 'identify' @{ version = 1; home = $homeDir; cwd = $cwd; pid = $null; sidecar_pid = $holderPid; env = $me }
    Check 'identify names the session by the sidecar''s start, through winsqlite3' ($null -ne $id -and $id.session -eq 'ses_new') ("got: " + ($id | ConvertTo-Json -Compress))
    $other = Ask 'identify' @{ version = 1; home = $homeDir; cwd = $cwd; pid = $null; sidecar_pid = $holderPid; env = @{ POLTER_AGENT_CLI = 'codex' } }
    Check 'another CLI''s marker is a no' ($null -ne $other -and -not $other.me) ("got: " + ($other | ConvertTo-Json -Compress))

    $on = Ask 'launch' @{ version = 1; home = $homeDir; cwd = $cwd; polter = 'C:\polter\polter.exe'; session = 'ses_new'; role = @{}; cli = @{} }
    $argv = @($on.argv)
    Check 'a session in the database is gone on with' ($argv.Count -ge 4 -and $argv[-2] -eq '-s' -and $argv[-1] -eq 'ses_new') ("argv: " + ($argv -join ' | '))
    Check 'behind opencode.cmd it starts node.exe and bin\opencode' ($argv.Count -ge 2 -and $argv[0] -like '*\node.exe' -and $argv[1] -like '*\opencode-ai\bin\opencode') ("argv: " + ($argv -join ' | '))
    Check 'a --version that fails is no hooks, and said' (-not ($on.PSObject.Properties.Name -contains 'hooks') -and (@($on.notes) -join ' ') -like '*version*') ("notes: " + (@($on.notes) -join ' / '))
    $gone = Ask 'launch' @{ version = 1; home = $homeDir; cwd = $cwd; polter = 'C:\polter\polter.exe'; session = 'ses_notHere'; role = @{}; cli = @{} }
    Check 'a session not in it starts a new one, with a note' ((@($gone.argv) -notcontains '-s') -and (@($gone.notes) -join ' ') -like '*not on this machine*') ("argv: " + (@($gone.argv) -join ' | ') + " notes: " + (@($gone.notes) -join ' / '))
} finally {
    [System.IO.File]::WriteAllText($stop, '', $Utf8)
    if ($null -ne $p) { try { $p.WaitForExit(10000) | Out-Null } catch { } }
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -eq 0) { Write-Host 'all hold'; exit 0 }
Write-Host "$failures DO NOT HOLD"
exit 1
