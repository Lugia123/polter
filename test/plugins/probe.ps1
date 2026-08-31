param(
    [string]$Sdk = 'C:\app\provsrc\_sdk\provision.ps1',
    [string]$Suite = 'C:\app\provtest.ps1'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Pristine = [System.IO.File]::ReadAllText($Sdk, $Utf8)

$mutations = @(
    @{
        Name = 'M2a idempotence, MCP: always considered stale'
        Pairs = @(
            @{ From = '    $stale = -not ($current.Contains($exe) -and $current.Contains($version))'
               To   = '    $stale = $true' }
        )
    },
    @{
        Name = 'M5 prune: BOTH remaining narrowing checks removed'
        Pairs = @(
            @{ From = "            if (`$entries.Count -ne 1 -or `$entries[0].Name -ne 'SKILL.md') { continue }"
               To   = '            if ($false) { continue }' },
            @{ From = '            if ((Get-PolterSkillName $entries[0].FullName) -ne $d.Name) { continue }'
               To   = '            if ($false) { continue }' }
        )
    }
)

foreach ($m in $mutations) {
    Write-Host ""
    Write-Host "########## $($m.Name) ##########"
    $t = $Pristine
    foreach ($pair in $m.Pairs) {
        if (-not $t.Contains($pair.From)) { Write-Host "  ANCHOR MISSING: $($pair.From)"; continue }
        $t = $t.Replace($pair.From, $pair.To)
    }
    [System.IO.File]::WriteAllText($Sdk, $t, $Utf8)
    Write-Host "  changed on disk: $(([System.IO.File]::ReadAllText($Sdk,$Utf8)) -ne $Pristine)"

    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Suite 2>&1
    ($out | Out-String) -split "`n" | Where-Object { $_ -match '^(PASS|FAIL|RESULT|==|--)' } | ForEach-Object { Write-Host "  $($_.TrimEnd())" }

    [System.IO.File]::WriteAllText($Sdk, $Pristine, $Utf8)
}

# And, for M2a, look straight at what the plugin says on the second run
# instead of inferring it from an assertion.
Write-Host ""
Write-Host "########## M2a, the plugin's own log on a second run ##########"
$t = $Pristine.Replace('    $stale = -not ($current.Contains($exe) -and $current.Contains($version))', '    $stale = $true')
[System.IO.File]::WriteAllText($Sdk, $t, $Utf8)

$root = 'C:\app\probe'
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root\bin" -Force | Out-Null
New-Item -ItemType Directory -Path "$root\plugins" -Force | Out-Null
New-Item -ItemType Directory -Path "$root\home" -Force | Out-Null
Copy-Item (Join-Path (Split-Path -Parent (Split-Path -Parent $Sdk)) '*') "$root\plugins" -Recurse -Force
[System.IO.File]::WriteAllText("$root\bin\opencode.cmd", "@echo off`r`nexit /b 0`r`n", $Utf8)

$hello = '{"hello":1,"plugin":"opencode","cursor":0,"events":["provision"],"groups":"","calls":[],"params":{"scope":"user","skills":"yes"}}'
$h = "$root\home" -replace '\\', '\\'
$batch = '{"cursor":0,"through":1,"events":[{"n":1,"kind":"provision","at_ms":1,"exe":"C:\\app\\polter.exe","version":"1.0.0","version_key":"POLTER_REGISTERED","home":"' + $h + '","skills":[]}]}'

foreach ($pass in 1, 2) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$root\plugins\opencode\provision.ps1`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $psi.EnvironmentVariables['PATH'] = "$root\bin;$env:SystemRoot\system32"
    $p = [System.Diagnostics.Process]::Start($psi)
    $w = New-Object System.IO.StreamWriter($p.StandardInput.BaseStream, $Utf8)
    $w.AutoFlush = $true
    $w.Write($hello + "`n"); $w.Write($batch + "`n"); $w.Close()
    $so = $p.StandardOutput.ReadToEnd(); $se = $p.StandardError.ReadToEnd()
    $p.WaitForExit(30000) | Out-Null
    Write-Host "  pass $pass  stdout: $($so -replace "`r?`n", ' ')"
    Write-Host "  pass $pass  stderr: [$($se -replace "`r?`n", ' ')]"
}

[System.IO.File]::WriteAllText($Sdk, $Pristine, $Utf8)
Write-Host ""
Write-Host "restored: $(([System.IO.File]::ReadAllText($Sdk,$Utf8)) -eq $Pristine)"
