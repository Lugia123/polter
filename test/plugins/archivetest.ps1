# Batches of every length for `plugins/archive/archive.ps1`.
#
# **The one that matters is the batch of one.** A PowerShell function's
# output goes through the pipeline, and the pipeline unrolls a one-element
# array into its element -- so `return $p.Value` handed the batch loop a
# single object, `-isnot [array]` called that "no events", and the batch was
# acknowledged whole with nothing written. The host moved its cursor past a
# message that is in no file. That is not a PowerShell 5.1 quirk:
# `ConvertFrom-Json` keeps the one-element array on 7.6 too, and the function
# boundary drops it on both.
#
# Runs anywhere PowerShell does, macOS included: each case starts the plugin
# under the same executable that is running this file, so `pwsh` tests 7 and
# `powershell.exe` tests 5.1.
#
#   pwsh -NoProfile -File test/plugins/archivetest.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\plugins\archivetest.ps1
#
# Exit 0 when every assertion holds, 1 otherwise. `-Plugin` points at another
# copy of the script, which is how a mutant is run against this suite.

param(
    [string]$Plugin = (Join-Path $PSScriptRoot '..\..\plugins\archive\archive.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Plugin = [System.IO.Path]::GetFullPath($Plugin)
$Shell = (Get-Process -Id $PID).Path
$Root = Join-Path ([System.IO.Path]::GetTempPath()) ('polter-archivetest-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($Root)
$Utf8 = New-Object System.Text.UTF8Encoding($false)

$script:Failed = 0
$script:Passed = 0

function Check {
    param([string]$Name, $Got, $Want)
    if ("$Got" -ceq "$Want") {
        $script:Passed++
        Write-Host "ok    $Name"
    } else {
        $script:Failed++
        Write-Host "FAIL  $Name"
        Write-Host "  want $Want"
        Write-Host "  got  $Got"
    }
}

function Message {
    param([long]$N)
    return '{"n":' + $N + ',"kind":"chat","seq":' + ($N * 10) +
        ',"at_ms":1786819271275,"group":"build","author":"worker-core","text":"hello"}'
}

# Runs the plugin over a handshake and the given lines, in a directory of its
# own, and hands back its acknowledgements and how many records it stored.
function Invoke-Plugin {
    param([string]$Case, [string[]]$Lines)
    $dir = Join-Path $Root $Case
    $hello = '{"hello":1,"plugin":"archive","cursor":0,"events":["chat"],"groups":["*"],"calls":[],"params":{"dir":' +
        (ConvertTo-Json $dir -Compress) + '}}'
    $feed = Join-Path $Root "$Case.in"
    [System.IO.File]::WriteAllText($feed, (@($hello) + $Lines | ForEach-Object { "$_`n" }) -join '', $Utf8)

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Shell
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Plugin + '"'
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $process.StandardInput.Write([System.IO.File]::ReadAllText($feed, $Utf8))
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($stderr.Trim()) { Write-Host "  [$Case stderr] $($stderr.Trim())" }

    $stored = 0
    if (Test-Path -LiteralPath $dir) {
        foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.jsonl') {
            foreach ($line in [System.IO.File]::ReadAllLines($file.FullName, $Utf8)) {
                if ($line.Trim()) { $stored++ }
            }
        }
    }
    $acks = @($stdout -split "`n" | Where-Object { $_ })
    return [pscustomobject]@{ Acks = ($acks -join ' '); Stored = $stored; Exit = $process.ExitCode }
}

try {
    $r = Invoke-Plugin 'one' @('{"cursor":0,"through":1,"events":[' + (Message 1) + ']}')
    Check 'a batch of one is acknowledged' $r.Acks '{"ok":true} {"ok":true}'
    Check 'and its one message is in the file' $r.Stored 1

    $r = Invoke-Plugin 'two' @('{"cursor":0,"through":3,"events":[' + (Message 2) + ',' + (Message 3) + ']}')
    Check 'a batch of two is acknowledged' $r.Acks '{"ok":true} {"ok":true}'
    Check 'and both messages are in the file' $r.Stored 2

    # One after another in one session: the batch of one is not a first-line
    # special case.
    $r = Invoke-Plugin 'one-then-one' @(
        ('{"cursor":0,"through":1,"events":[' + (Message 1) + ']}'),
        ('{"cursor":1,"through":2,"events":[' + (Message 2) + ']}'))
    Check 'two batches of one are both acknowledged' $r.Acks '{"ok":true} {"ok":true} {"ok":true}'
    Check 'and both messages are in the file' $r.Stored 2

    $r = Invoke-Plugin 'empty' @('{"cursor":0,"through":5,"events":[]}')
    Check 'an empty batch is acknowledged' $r.Acks '{"ok":true} {"ok":true}'
    Check 'and writes nothing' $r.Stored 0

    $r = Invoke-Plugin 'null' @('{"cursor":0,"through":5,"events":null}')
    Check 'a batch whose events are null is acknowledged' $r.Acks '{"ok":true} {"ok":true}'
    Check 'and writes nothing' $r.Stored 0

    $r = Invoke-Plugin 'missing' @('{"cursor":0,"through":5}')
    Check 'a batch with no events is acknowledged' $r.Acks '{"ok":true} {"ok":true}'
    Check 'and writes nothing' $r.Stored 0

    # `archive.py` takes anything that is not a list as no events. A bare
    # object is not a list of one, and the two halves have to agree.
    $r = Invoke-Plugin 'object' @('{"cursor":0,"through":5,"events":' + (Message 1) + '}')
    Check 'events that are an object and not a list are acknowledged' $r.Acks '{"ok":true} {"ok":true}'
    Check 'and are not read as a list of one, as archive.py does not' $r.Stored 0
} finally {
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$($script:Passed) passed, $($script:Failed) failed ($($PSVersionTable.PSVersion))"
if ($script:Failed) { exit 1 }
exit 0
