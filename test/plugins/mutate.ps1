# Measure the floor under the suite. Each injection is a mistake that leaves
# the file looking correct; after each one, run the suite and record which
# assertions went red, then put the file back. The final run is pristine and
# is the closing criterion.

param(
    [string]$Sdk = 'C:\app\provsrc\_sdk\provision.ps1',
    [string]$Suite = 'C:\app\provtest.ps1'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Pristine = [System.IO.File]::ReadAllText($Sdk, $Utf8)

$mutations = @(
    @{ Name = 'M1 BOM: the JSON write goes through Out-File -Encoding UTF8'
       Pairs = @(@{ From = '    [System.IO.File]::WriteAllText($tmp, $text, $script:PolterUtf8)'
                    To   = '    $text | Out-File -LiteralPath $tmp -Encoding UTF8 -NoNewline' }) },

    @{ Name = 'M2a idempotence, MCP: the registration is always considered stale'
       Pairs = @(@{ From = '    $stale = -not ($current.Contains($exe) -and $current.Contains($version))'
                    To   = '    $stale = $true' }) },

    @{ Name = 'M2b idempotence, skills: the "only when it differs" test removed'
       Pairs = @(@{ From = '            if ($existing.TrimEnd("`r", "`n") -eq $rendered) { continue }'
                    To   = '            if ($false) { continue }' }) },

    @{ Name = 'M3 a config that does not parse is replaced instead of refused'
       Pairs = @(@{ From = '                throw "cannot parse $Path ($($_.Exception.Message)); refusing to overwrite it"'
                    To   = '                $parsed = New-Object PSObject' }) },

    @{ Name = 'M4 order: the batch is acknowledged before the user is told'
       Pairs = @(@{ From = @"
            Write-PolterFailure 'mcp' "could not register the MCP server: `$(`$_.Exception.Message)"
            return `$false
"@
                    To = @"
            Write-PolterAck `$false
            Write-PolterFailure 'mcp' "could not register the MCP server: `$(`$_.Exception.Message)"
            return `$false
"@ }) },

    @{ Name = 'M5 prune: both narrowing checks removed (one alone is masked by the other)'
       Pairs = @(
           @{ From = "            if (`$entries.Count -ne 1 -or `$entries[0].Name -ne 'SKILL.md') { continue }"
              To   = '            if ($false) { continue }' },
           @{ From = '            if ((Get-PolterSkillName $entries[0].FullName) -ne $d.Name) { continue }'
              To   = '            if ($false) { continue }' }) },

    @{ Name = 'M6 the atomic replace goes back to passing $null for the backup path'
       Pairs = @(
           @{ From = '            $bak = "$Path.polter-bak"
            [System.IO.File]::Replace($tmp, $Path, $bak)
            Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue'
              To   = '            [System.IO.File]::Replace($tmp, $Path, $null)' }) }
)

function Invoke-Suite {
    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Suite 2>&1
    $text = ($out | Out-String)
    $fails = @(($text -split "`n") | Where-Object { $_ -match '^FAIL ' } | ForEach-Object { $_.Trim() })
    $result = (($text -split "`n") | Where-Object { $_ -match '^RESULT ' } | Select-Object -First 1)
    return [pscustomobject]@{ Fails = $fails; Result = ($result -replace "`r", '') }
}

Write-Host "=== baseline, pristine ==="
$b = Invoke-Suite
Write-Host "  $($b.Result)"
$b.Fails | ForEach-Object { Write-Host "    red: $_" }

foreach ($m in $mutations) {
    Write-Host ""
    Write-Host "=== $($m.Name) ==="

    $t = $Pristine
    $missing = $false
    foreach ($pair in $m.Pairs) {
        if (-not $t.Contains($pair.From)) { Write-Host "  ANCHOR MISSING -- nothing injected"; $missing = $true; break }
        $t = $t.Replace($pair.From, $pair.To)
    }
    if ($missing) { continue }

    [System.IO.File]::WriteAllText($Sdk, $t, $Utf8)
    # "The mutation was never applied" and "the mutation killed nothing"
    # produce the same green, and only one of them means anything.
    Write-Host "  differs from the original on disk: $(([System.IO.File]::ReadAllText($Sdk, $Utf8)) -ne $Pristine)"

    $r = Invoke-Suite
    Write-Host "  $($r.Result)"
    if ($r.Fails.Count -eq 0) { Write-Host "  *** SURVIVED -- nothing caught this ***" }
    else { $r.Fails | ForEach-Object { Write-Host "    red: $_" } }

    [System.IO.File]::WriteAllText($Sdk, $Pristine, $Utf8)
}

Write-Host ""
Write-Host "=== restored, pristine again ==="
$f = Invoke-Suite
Write-Host "  $($f.Result)"
$f.Fails | ForEach-Object { Write-Host "    red: $_" }
Write-Host "  file matches the original: $(([System.IO.File]::ReadAllText($Sdk, $Utf8)) -eq $Pristine)"
