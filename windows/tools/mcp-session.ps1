# Call several Polter MCP tools ONE AFTER ANOTHER ON ONE CONNECTION and print
# each answer beside the call it was the answer to.
#
#   & <pkg>\tools\mcp-session.ps1 -CallsJson '[{"tool":"me"},{"tool":"screenshot_info","args":{"latest":true}},{"tool":"me"}]'
#
# Why this exists beside mcp-call.ps1: that one starts `polter-cli.exe +mcp`
# afresh for every call, and `+mcp` holds one connection to Polter for as long
# as it lives. A defect in which one answer shifts every LATER answer on the
# same connection (#1095) cannot be seen one call per process. This script
# starts `+mcp` once and sends every call through it, in order, each after
# the answer to the one before.
#
# RUN IT INSIDE A POLTER PANE, with `& <path> ...` (not `powershell -File`,
# which eats the double quotes in -CallsJson).
#
# One line per call:
#   #<n> <tool> -> OK after <ms> ms: <the tool's text>
#   #<n> <tool> -> TOOL ERROR after <ms> ms: <text>
#   #<n> <tool> -> NO ANSWER within <s> s        (and nothing after it is sent)
# then `calls=<N> answered=<A>`.
#
# Exit codes:
#   0  every call was answered (an answer that is a tool error still counts:
#      whether the answers are the RIGHT ones is for the reader of the lines)
#   3  the command line is wrong (USAGE ERROR)
#   4  +mcp did not start, or a call got no answer in time (ERROR)
#
# ENCODINGS: read and written as UTF-8, explicitly -- see mcp-call.ps1, which
# had the defect first and says what it looked like. ASCII on purpose.
#
# What was run: under PowerShell 7 on a Mac, against a stand-in server whose
# answers carry Chinese text and which reports the bytes it was sent -- once
# as written here, once with the output decoded as code page 936 (the text
# comes back as other characters). This file as it is here was NOT run under
# Windows PowerShell 5.1 or against polter-cli.exe; a copy with the same three
# changes (the array, the two encodings, the bytes written to stdin) was, on
# the test machine, and answered 7 of 7 (#1097, Q1).
param(
    [string]$CallsJson,
    [string]$Cli,
    [int]$TimeoutSec = 30,
    # For the stand-in server used to test this script; not for the test machine.
    [string]$CliArgs = '+mcp'
)
$ErrorActionPreference = 'Stop'
if (-not $CallsJson) { Write-Output 'USAGE ERROR: -CallsJson <json array of {"tool":..,"args":{..}}> is required'; exit 3 }
# The inner pipeline is what takes the array apart: under Windows PowerShell
# 5.1 `@($json | ConvertFrom-Json)` is one element holding the whole array, and
# every call then failed the check below (measured on the test machine, #1097).
try { $calls = @(($CallsJson | ConvertFrom-Json) | ForEach-Object { $_ }) } catch { Write-Output "USAGE ERROR: -CallsJson is not JSON: $CallsJson"; exit 3 }
if ($calls.Count -eq 0) { Write-Output 'USAGE ERROR: -CallsJson has no calls in it'; exit 3 }
foreach ($c in $calls) {
    if (-not ($c.PSObject.Properties.Name -contains 'tool') -or -not $c.tool) { Write-Output 'USAGE ERROR: every call needs a "tool"'; exit 3 }
}
if (-not $Cli) { $Cli = Join-Path (Split-Path -Parent $PSScriptRoot) 'polter-cli.exe' }
if (-not (Test-Path -LiteralPath $Cli)) { Write-Output "USAGE ERROR: no such program: $Cli"; exit 3 }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Cli
$psi.Arguments = $CliArgs
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
# +mcp speaks UTF-8 whatever the console's code page is. Left unset, Windows
# PowerShell 5.1 decodes the child's output in the console's code page (936 on
# a Chinese machine), and an answer with a Chinese window title in it stops
# being JSON -- see the note on encodings at the top.
$utf8 = New-Object System.Text.UTF8Encoding($false)
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8
try { $p = [System.Diagnostics.Process]::Start($psi) } catch { Write-Output "ERROR: could not start $Cli : $($_.Exception.Message)"; exit 4 }
$errTask = $p.StandardError.ReadToEndAsync()

# Bytes, not `StandardInput.WriteLine`: that writer encodes in the console's
# input code page and .NET Framework has no setting to change it.
function Send([string]$line) {
    $bytes = $utf8.GetBytes($line + "`n")
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.BaseStream.Flush()
}
# Lines from +mcp that were not JSON. They are skipped, and counted: a script
# that skips them silently reports "no answer" for an answer it threw away.
$script:notJson = 0
function Skipped-Note {
    if ($script:notJson -gt 0) { return " ($($script:notJson) line(s) from the program were not JSON and were skipped)" }
    return ''
}
# The answer with this id, or $null when the time ran out or the program ended.
function Await([int]$id, [int]$seconds) {
    $until = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $until) {
        $t = $p.StandardOutput.ReadLineAsync()
        $left = [int][math]::Max(1, ($until - (Get-Date)).TotalMilliseconds)
        if (-not $t.Wait($left)) { return $null }
        $line = $t.Result
        if ($null -eq $line) { return $null }
        if ($line.Trim() -eq '') { continue }
        try { $m = $line | ConvertFrom-Json } catch { $script:notJson++; continue }
        if ($m.PSObject.Properties.Name -contains 'id' -and $m.id -eq $id) { return $m }
    }
    return $null
}
function Stop-Cli {
    try { if (-not $p.HasExited) { $p.Kill() } } catch {}
    try { if ($errTask.Wait(2000) -and $errTask.Result) { Write-Output "stderr: $($errTask.Result.Trim())" } } catch {}
}

Send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-session.ps1","version":"1"}}}'
if ($null -eq (Await 1 15)) {
    Write-Output ('ERROR: no answer to initialize within 15 s (is this a Polter pane? stderr follows if any)' + (Skipped-Note))
    Stop-Cli
    exit 4
}
Send '{"jsonrpc":"2.0","method":"notifications/initialized"}'

$n = 0
$answered = 0
foreach ($c in $calls) {
    $n++
    $id = $n + 1
    $arguments = '{}'
    if (($c.PSObject.Properties.Name -contains 'args') -and ($null -ne $c.args)) { $arguments = $c.args | ConvertTo-Json -Compress -Depth 16 }
    $started = Get-Date
    Send ('{"jsonrpc":"2.0","id":' + $id + ',"method":"tools/call","params":{"name":' + ($c.tool | ConvertTo-Json) + ',"arguments":' + $arguments + '}}')
    $r = Await $id $TimeoutSec
    if ($null -eq $r) {
        Write-Output ("#$n $($c.tool) -> NO ANSWER within $TimeoutSec s" + (Skipped-Note))
        Write-Output "calls=$($calls.Count) answered=$answered"
        Stop-Cli
        exit 4
    }
    $answered++
    $ms = [int]((Get-Date) - $started).TotalMilliseconds
    if ($r.PSObject.Properties.Name -contains 'error') {
        Write-Output "#$n $($c.tool) -> TOOL ERROR (JSON-RPC) after $ms ms: $($r.error | ConvertTo-Json -Compress -Depth 8)"
        continue
    }
    $isError = ($r.result.PSObject.Properties.Name -contains 'isError') -and $r.result.isError
    $text = ($r.result.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
    if ($isError) { Write-Output "#$n $($c.tool) -> TOOL ERROR after $ms ms: $text" } else { Write-Output "#$n $($c.tool) -> OK after $ms ms: $text" }
}
try { $p.StandardInput.Close(); if (-not $p.WaitForExit(3000)) { $p.Kill() } } catch {}
Write-Output "calls=$($calls.Count) answered=$answered"
exit 0
