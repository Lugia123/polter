# Can Qwen Code run non-interactively on this machine at all?
#
# `-Real` hung with no `node` process alive and not one byte written. That has
# two causes with completely different next steps -- **this CLI cannot run
# without a terminal here**, or **we are calling it wrong** -- and the run
# itself cannot tell them apart. This probe is built to.
#
# Everything here is read-only. Nothing calls `mcp add` or `mcp remove`, and
# the user's `settings.json` is hashed before and after so the claim is
# checked rather than asserted.
#
# Bounded by construction: every invocation has a wall-clock deadline and its
# process tree is killed when it expires, so the whole probe finishes even if
# every single call hangs.

param(
    [int]$TimeoutSec = 45,
    [string]$Log = 'C:\app\qwenprobe.log'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Utf8 = New-Object System.Text.UTF8Encoding($false)
$cfg = Join-Path $env:USERPROFILE '.qwen\settings.json'

function Hash-Cfg {
    if (-not (Test-Path -LiteralPath $cfg)) { return 'MISSING' }
    $i = Get-Item -LiteralPath $cfg
    "$($i.Length) bytes, $($i.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')), $((Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash)"
}

Write-Host "settings.json BEFORE: $(Hash-Cfg)"
Write-Host ""

# One invocation, with a deadline.
#
# **stdin is redirected and closed immediately.** A CLI waiting for a person
# then reads end-of-file and should give up; one that hangs anyway is hanging
# on something other than a prompt. This is the single most informative knob
# in the probe, so it is not left to chance.
function Try-Cmd {
    param([string]$Label, [string]$File, [string[]]$Arguments)

    Write-Host "== $Label =="
    Write-Host "   $File $($Arguments -join ' ')"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $psi.WorkingDirectory = $env:USERPROFILE

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()

    # Read on background threads so a full pipe buffer cannot masquerade as a
    # hang -- that would be a third cause, and it would look exactly like the
    # other two.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    $exited = $p.WaitForExit($TimeoutSec * 1000)
    $sw.Stop()

    # Was anything actually running underneath? This is the discriminator the
    # first hang was diagnosed with, so the probe records it rather than
    # leaving it to be checked by hand afterwards.
    $nodes = @(Get-Process -Name node -ErrorAction SilentlyContinue)
    $cmds = @(Get-Process -Name cmd -ErrorAction SilentlyContinue)

    if (-not $exited) {
        Write-Host "   RESULT   *** TIMED OUT after $TimeoutSec s ***"
        Write-Host "   node processes alive at timeout: $($nodes.Count)"
        Write-Host "   cmd  processes alive at timeout: $($cmds.Count)"
        # /T for the tree: `qwen` is a `.cmd` shim, so the thing that matters
        # is usually the grandchild.
        & taskkill /PID $p.Id /T /F 2>&1 | ForEach-Object { Write-Host "   kill: $_" }
        Write-Host ""
        return
    }

    $out = $outTask.Result
    $err = $errTask.Result
    Write-Host "   RESULT   exit=$($p.ExitCode)  elapsed=$([math]::Round($sw.Elapsed.TotalSeconds,1))s"
    Write-Host "   node alive after exit: $($nodes.Count)"
    if ($out) { Write-Host "   stdout: $(($out -replace "`r?`n", ' | ').Substring(0, [Math]::Min(600, $out.Length)))" }
    else { Write-Host "   stdout: (empty)" }
    if ($err) { Write-Host "   stderr: $(($err -replace "`r?`n", ' | ').Substring(0, [Math]::Min(600, $err.Length)))" }
    else { Write-Host "   stderr: (empty)" }
    Write-Host ""
}

# --- what the shim actually is ----------------------------------------------
#
# `qwen` on Windows is an npm `.cmd` shim around a JavaScript entry point.
# Which of the two hangs is the whole question, so the shim is read and the
# entry point is called directly further down.
$shim = Join-Path $env:APPDATA 'npm\qwen.cmd'
Write-Host "== the shim =="
if (Test-Path -LiteralPath $shim) {
    Write-Host "   $shim"
    Get-Content -LiteralPath $shim | ForEach-Object { Write-Host "   | $_" }
} else {
    Write-Host "   NOT FOUND at $shim"
}
Write-Host ""

# Resolve the JS entry the shim points at, so it can be run without cmd.exe
# in the middle.
$entry = ''
foreach ($c in @(
    (Join-Path $env:APPDATA 'npm\node_modules\@qwen-code\qwen-code\bundle\gemini.js'),
    (Join-Path $env:APPDATA 'npm\node_modules\@qwen-code\qwen-code\dist\index.js'),
    (Join-Path $env:APPDATA 'npm\node_modules\@qwen-code\qwen-code\bin\qwen.js')
)) {
    if (Test-Path -LiteralPath $c) { $entry = $c; break }
}
if (-not $entry) {
    $found = @(Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'npm\node_modules') -Recurse -Filter '*.js' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'qwen' -and ($_.Name -match '^(gemini|index|qwen|cli)\.js$') } |
        Select-Object -First 5)
    Write-Host "== entry point candidates =="
    if ($found.Count) { $found | ForEach-Object { Write-Host "   $($_.FullName)" }; $entry = $found[0].FullName }
    else { Write-Host "   none found" }
    Write-Host ""
}
Write-Host "== entry point chosen: $(if ($entry) { $entry } else { '(none)' }) =="
Write-Host ""

# --- the four questions -----------------------------------------------------
#
# In this order on purpose: the cheapest and least stateful first, so a hang
# on the first one already answers the question and the rest is detail.

Try-Cmd '1. does it start at all'            'qwen.cmd' @('--version')
Try-Cmd '2. does it parse args without a TTY' 'qwen.cmd' @('--help')
Try-Cmd '3. the exact call the plugin makes first (read-only)' 'qwen.cmd' @('mcp', 'list')

if ($entry) {
    # **The discriminator.** If this works and the three above hang, the
    # problem is the `.cmd` shim and cmd.exe, not Qwen Code -- and the fix is
    # in how the host spawns, not in the acceptance path.
    Try-Cmd '4. same thing, bypassing the .cmd shim' 'node' @("`"$entry`"", 'mcp', 'list')
} else {
    Write-Host "== 4. skipped: no JS entry point found =="
    Write-Host ""
}

Write-Host "settings.json AFTER:  $(Hash-Cfg)"
Write-Host ""
Write-Host "(If BEFORE and AFTER differ, say so loudly -- this probe is supposed to write nothing.)"
