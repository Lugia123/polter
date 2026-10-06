# Call one Polter MCP tool from a Polter terminal and print its answer.
#
#   powershell -File mcp-call.ps1 -Tool screenshot_windows
#   powershell -File mcp-call.ps1 -Tool screenshot_capture -ArgsJson '{"target":"display","display":0}'
#   powershell -File mcp-call.ps1 -Tool screenshot_long -ArgsJson '{"window_id":123,"pages":2}' -TimeoutSec 90
#
# RUN IT INSIDE A POLTER PANE: `polter-cli.exe +mcp` finds the running Polter
# through GHOSTTY_POLTER_SOCKET and GHOSTTY_POLTER_TOKEN, which only a shell
# started by Polter has. Outside one this prints what +mcp said and exits 4.
#
# It starts `polter-cli.exe +mcp` itself and writes to its stdin line by line.
# It does not use a PowerShell pipeline: `'...' | polter-cli +mcp` hands over
# every line at once and then closes stdin, which for a slow tool (a long
# screenshot) is before the answer exists.
#
# Exit codes:
#   0  the tool answered and did not say it was an error
#   1  the tool answered with an error (isError, or a JSON-RPC error) -- a
#      refusal such as NotPermitted is this; the text is printed
#   3  the command line is wrong (USAGE ERROR)
#   4  no answer: +mcp did not start, exited, or did not answer in time (ERROR)
#
# ENCODINGS (task 1100). The child's stdout and stderr are read as UTF-8 and
# its stdin is written as UTF-8 bytes, explicitly. The first version left all
# three to the defaults, which under Windows PowerShell 5.1 are the console's
# code page: on a code page 936 machine `screenshot_windows` answered with a
# Chinese window title, the line was decoded as 936, was no longer JSON, was
# skipped without a word, and the script reported "no answer within 20 s"
# (exit 4) for an answer Polter had given. PowerShell 7 on a Mac defaults to
# UTF-8 everywhere, which is why the test that was run could not see it.
# This file is ASCII on purpose: 5.1 reads a script with no BOM in the
# system code page.
#
# What was run: under PowerShell 7 on a Mac, against a stand-in server whose
# answers carry Chinese text and which reports the bytes it was sent -- once
# as written here (the text and the bytes both right), once with the output
# decoded as code page 936 (the text comes back as other characters; on the
# Mac it stays JSON, so it is not the exit 4 the machine saw), once with the
# input encoded as 936 (the argument arrives as other bytes). NOT run under
# Windows PowerShell 5.1 and NOT against polter-cli.exe.
param(
    [string]$Tool,
    [string]$ArgsJson = '{}',
    [string]$Cli,
    [int]$TimeoutSec = 30,
    # For the stand-in server used to test this script; not for the test machine.
    [string]$CliArgs = '+mcp'
)
$ErrorActionPreference = 'Stop'
if (-not $Tool) { Write-Output 'USAGE ERROR: -Tool <name> is required'; exit 3 }
try { $null = $ArgsJson | ConvertFrom-Json } catch { Write-Output "USAGE ERROR: -ArgsJson is not JSON: $ArgsJson"; exit 3 }
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
function Give-Up([string]$why) {
    Write-Output "ERROR: $why"
    try { if (-not $p.HasExited) { $p.Kill() } } catch {}
    try { if ($errTask.Wait(2000) -and $errTask.Result) { Write-Output "stderr: $($errTask.Result.Trim())" } } catch {}
    exit 4
}

$started = Get-Date
Send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-call.ps1","version":"1"}}}'
$init = Await 1 15
if ($null -eq $init) { Give-Up ('no answer to initialize within 15 s (is this a Polter pane? exit code and stderr follow if any)' + (Skipped-Note)) }
Send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
$call = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":' + ($Tool | ConvertTo-Json) + ',"arguments":' + $ArgsJson + '}}'
Send $call
$r = Await 2 $TimeoutSec
if ($null -eq $r) { Give-Up ("no answer to $Tool within $TimeoutSec s" + (Skipped-Note)) }
$ms = [int]((Get-Date) - $started).TotalMilliseconds
try { $p.StandardInput.Close(); if (-not $p.WaitForExit(3000)) { $p.Kill() } } catch {}

$names = $r.PSObject.Properties.Name
if ($names -contains 'error') {
    Write-Output "TOOL ERROR (JSON-RPC) after $ms ms: $($r.error | ConvertTo-Json -Compress -Depth 8)"
    exit 1
}
$isError = ($r.result.PSObject.Properties.Name -contains 'isError') -and $r.result.isError
$text = ($r.result.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
if ($isError) { Write-Output "TOOL ERROR after $ms ms: $text"; exit 1 }
Write-Output "OK after $ms ms: $text"
exit 0
