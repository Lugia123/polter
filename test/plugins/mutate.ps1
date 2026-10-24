# Measure the floor under the suite. Each injection is a mistake that leaves
# the file looking correct; after each one, run the suite and record which
# assertions went red, then put the file back. The final run is pristine and
# is the closing criterion.

param(
    [string]$Sdk = 'C:\app\provsrc\_sdk\provision.ps1',
    [string]$Suite = 'C:\app\provtest.ps1',

    # Run only the injections whose name starts with one of these, e.g.
    # `-Only M7`. The baseline and the closing pristine run always happen --
    # without them a single-injection run cannot tell "this went red" from
    # "everything is red today".
    [string[]]$Only = @(),

    # Print what each entry's dispatch key actually is and run nothing.
    # **Type and bytes, not the value**: "it prints as claude", "it is a
    # one-element array holding claude" and "it has an invisible character on
    # the end" look identical on screen and behave differently in `-eq`.
    [switch]$Probe
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

# **Each injection names the file it goes into.** The first six land in the
# SDK, because that is where the shared behaviour lives. The 6b ones land in
# a host plugin, because what they attack is that plugin's own command line.
# Keeping one hard-coded target is why the 6b assertions had no floor at all.
#
# **`claude-code` since task 2207.** It was `qwen-code`, the host whose
# `mcp add` first showed the ordering bug; that plugin is gone, and of the
# four that stay this is the only one whose registration goes through a CLI
# with a `--`, which is the whole subject of the 6b injections. The rule the
# assertions hold changed with it (see `$M7To` below), and so did three of
# the five injections: `--` used to be the fault, and now it is required.
$HostPlugin = Join-Path (Split-Path -Parent (Split-Path -Parent $Sdk)) 'claude-code\provision.ps1'

$Original = @{}
foreach ($f in @($Sdk, $HostPlugin)) { $Original[$f] = [System.IO.File]::ReadAllText($f, $Utf8) }

# **M7's two strings live here, not inline in the table.** A here-string whose
# closing `'@` has anything after it on the line -- `'@ }) },` -- does not
# behave. The anchor itself was never wrong: a probe on the machine confirmed
# this exact text matches the file byte for byte (`file contains = True`).
# What was wrong twice running was the container, and both times the offline
# pre-check checked the string rather than the thing that delivers it.
#
# Every terminator below is alone on its line. That is the whole fix.
$M7From = @'
        '-e', "$VersionKey=$Version",
        '--', $Exe, '+mcp'
'@

# The marker moves to the served side of the terminator. The CLI then reads
# it as an argument of the command it is being asked to serve rather than as
# one of its own, which is the same defect the original bug was one end of.
$M7To = @'
        '--', $Exe, '+mcp',
        '-e', "$VersionKey=$Version"
'@

# M10 / M11 -- the two 6b assertions that still had no floor. Same rule as
# above: terminators alone on their lines, and the trailing comma of every
# array element stays on that element's own last line.
$M10From = @'
        '--', $Exe, '+mcp'
    )
'@

$M10To = @'
        '--', $Exe, '+mcp'
    )
    Invoke-PolterCli 'claude' @('mcp', 'add', '--scope', 'user', 'polter', $Exe, '+mcp', '-e', "$VersionKey=$Version")
'@

$mutations = @(
    @{ Name = 'M1 BOM: the JSON write goes through Out-File -Encoding UTF8'
       Pairs = @(@{ From = '    [System.IO.File]::WriteAllText($tmp, $text, $script:PolterUtf8)'
                    To   = '    $text | Out-File -LiteralPath $tmp -Encoding UTF8 -NoNewline' }) },

    # **The anchor was stale on HEAD, and it fails loudly** (`ANCHOR MISSING`),
    # which is why it went unnoticed: the SDK dropped the `$exe` half of this
    # test and nothing repointed the two copies of the anchor (`probe.ps1` had
    # the same one). Repointed 2026-10-25, while task 2207 was in here anyway.
    @{ Name = 'M2a idempotence, MCP: the registration is always considered stale'
       Pairs = @(@{ From = '                $stale = -not $current.Contains($version)'
                    To   = '                $stale = $true' }) },

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
              To   = '            [System.IO.File]::Replace($tmp, $Path, $null)' }) },

    # --- 6b: the `mcp add` command line ------------------------------------
    #
    # **These exist because 6b had no floor at all.** It was the one place in
    # this round with a new implementation, a new set of assertions, and
    # nothing measuring whether the second could catch the first being wrong
    # -- which is the combination the whole exercise is for. Each injection is
    # a form somebody could plausibly write. The first was the shape the real
    # CLI this was found on refused outright (`Not enough non-option
    # arguments`); the rest are the two ends of the same rule, which the host
    # that replaced it states as a pair -- an option before the terminator,
    # the served command's positionals after.

    # WARNING: **Keep each element's trailing comma on the element's own last line.**
    # An earlier edit left the comma from the entry above stranded on a line by
    # itself. A newline ends a statement in PowerShell, so a leading comma is
    # no longer a separator -- it is the unary array operator, and it wrapped
    # the entry below it in an `Object[]`.
    #
    # Nothing errored. The wrapper answers `.Name` and `.Keys` by member
    # enumeration through the single hashtable inside it, so every diagnostic
    # that asked those questions said the entry was fine; only `$m['File']`
    # went null, the dispatch fell through to the SDK, and the run reported
    # ANCHOR MISSING -- which is exactly what a wrong anchor looks like.
    #
    # Five machine windows. What finally showed it was printing
    # `$m.GetType().FullName` with a working entry beside it in the same
    # output: `System.Object[]` against `System.Collections.Hashtable`.
    @{ Name = 'M7 6b: `-e` moves past the terminator, onto the served side'
       File = 'host'
       Pairs = @(@{ From = $M7From; To = $M7To }) },

    @{ Name = 'M8 6b: the `--` terminator is dropped'
       File = 'host'
       Pairs = @(@{ From = "        '-e', `"`$VersionKey=`$Version`",`n        '--', `$Exe, '+mcp'`n"
                    To   = "        '-e', `"`$VersionKey=`$Version`",`n        `$Exe, '+mcp'`n" }) },

    @{ Name = 'M9 6b: the marker is split into two arguments'
       File = 'host'
       Pairs = @(@{ From = "        '-e', `"`$VersionKey=`$Version`""
                    To   = "        '-e', `$VersionKey, `$Version" }) },

    # **The two that guard what actually broke once.** "Called exactly once"
    # is the assertion that would have caught the staleness bug -- the one
    # that rewrote a user's config on every launch for as long as the file
    # had existed. An assertion guarding a bug that really happened, with no
    # floor under it, is worse than one guarding a hypothetical.
    @{ Name = 'M10 6b: mcp add is issued twice'
       File = 'host'
       Pairs = @(@{ From = $M10From; To = $M10To }) },

    @{ Name = 'M11 6b: the served +mcp argument is dropped'
       File = 'host'
       Pairs = @(@{ From = "        '--', `$Exe, '+mcp'"
                    To   = "        '--', `$Exe" }) }
)

function Invoke-Suite {
    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Suite 2>&1
    $text = ($out | Out-String)
    $fails = @(($text -split "`n") | Where-Object { $_ -match '^FAIL ' } | ForEach-Object { $_.Trim() })
    $result = (($text -split "`n") | Where-Object { $_ -match '^RESULT ' } | Select-Object -First 1)
    return [pscustomobject]@{ Fails = $fails; Result = ($result -replace "`r", '') }
}

if ($Probe) {
    # **Print the keys themselves, not just the values.** The first version of
    # this probe crashed on `$m['Name'].Substring(...)` because `$m['Name']`
    # was null on the very entry under investigation -- while `$m.Name` on the
    # same object printed fine one line earlier. An object where property
    # access and string indexing disagree is not the Hashtable it looks like,
    # and no amount of printing the *value* would have said so.
    foreach ($m in $mutations) {
        Write-Host "---- entry ----"
        Write-Host ("  object type : " + $m.GetType().FullName)
        foreach ($k in $m.Keys) {
            $kt = $k.GetType().FullName
            $kb = (([int[]][char[]][string]$k) -join ',')
            Write-Host ("  key [$k] type=$kt bytes=[$kb]")
        }
        $byProp = $m.Name
        $byIdx = $m['Name']
        Write-Host ("  Name by property : " + $(if ($null -eq $byProp) { '<null>' } else { $byProp.Substring(0, [Math]::Min(6, $byProp.Length)) }))
        Write-Host ("  Name by indexer  : " + $(if ($null -eq $byIdx) { '<null>' } else { $byIdx.Substring(0, [Math]::Min(6, $byIdx.Length)) }))
        $v = $m['File']
        Write-Host ("  File by indexer  : " + $(if ($null -eq $v) { '<null>' } else { "[$v] type=" + $v.GetType().FullName + " count=" + @($v).Count + " bytes=[" + (([int[]][char[]][string]$v) -join ',') + "] eq-host=" + ($v -eq 'host') }))
    }
    exit 0
}

Write-Host "=== baseline, pristine ==="
$b = Invoke-Suite
Write-Host "  $($b.Result)"
$b.Fails | ForEach-Object { Write-Host "    red: $_" }

foreach ($m in $mutations) {
    if ($Only.Count -gt 0) {
        $wanted = $false
        foreach ($pfx in $Only) { if ($m.Name.StartsWith($pfx)) { $wanted = $true } }
        if (-not $wanted) { continue }
    }

    Write-Host ""
    Write-Host "=== $($m.Name) ==="

    # Indexer, not property access, and no `-and` to get the precedence
    # wrong in. Printed every time: which file an injection went into is the
    # first thing to check when it reports ANCHOR MISSING, and it was the one
    # thing the earlier diagnostics assumed instead of showing.
    $target = $Sdk
    if ($m['File'] -eq 'host') { $target = $HostPlugin }
    Write-Host "  target: $target"

    $t = $Original[$target]
    $missing = $false
    foreach ($pair in $m.Pairs) {
        if (-not $t.Contains($pair.From)) {
            # **Say which anchor and how long it is.** "ANCHOR MISSING" on its
            # own cannot tell "the file changed" from "the string this script
            # built is not the string I wrote" -- and the second one cost two
            # machine windows before anybody printed the length.
            Write-Host "  ANCHOR MISSING -- nothing injected"
            Write-Host "    target       : $target"
            Write-Host "    entry keys   : $($m.Keys -join ', ')"
            Write-Host "    target length: $($t.Length)"
            Write-Host "    anchor length: $($pair.From.Length)"
            Write-Host "    first line of anchor present: $($t.Contains(($pair.From -split "`n")[0]))"
            Write-Host "    last line of anchor present : $($t.Contains(($pair.From -split "`n")[-1]))"
            $missing = $true
            break
        }
        $t = $t.Replace($pair.From, $pair.To)
    }
    if ($missing) { continue }

    [System.IO.File]::WriteAllText($target, $t, $Utf8)
    # "The mutation was never applied" and "the mutation killed nothing"
    # produce the same green, and only one of them means anything.
    Write-Host "  differs from the original on disk: $(([System.IO.File]::ReadAllText($target, $Utf8)) -ne $Original[$target])"

    $r = Invoke-Suite
    Write-Host "  $($r.Result)"
    if ($r.Fails.Count -eq 0) { Write-Host "  *** SURVIVED -- nothing caught this ***" }
    else { $r.Fails | ForEach-Object { Write-Host "    red: $_" } }

    [System.IO.File]::WriteAllText($target, $Original[$target], $Utf8)
}

Write-Host ""
Write-Host "=== restored, pristine again ==="
$f = Invoke-Suite
Write-Host "  $($f.Result)"
$f.Fails | ForEach-Object { Write-Host "    red: $_" }
foreach ($f in @($Sdk, $HostPlugin)) {
    $ok = ([System.IO.File]::ReadAllText($f, $Utf8)) -eq $Original[$f]
    Write-Host "  $(Split-Path -Leaf (Split-Path -Parent $f))/$(Split-Path -Leaf $f) matches the original: $ok"
}
