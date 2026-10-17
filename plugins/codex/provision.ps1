# Tell OpenAI's Codex CLI that Polter is here. The Windows half.
#
# The implementation is in `_sdk/provision.ps1`; this file is the answers.
# See dev-docs/poltergeist/provisioning.md and dev-docs/windows/development.md 5.3.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_sdk\provision.ps1')

$PolterHostKey = 'codex'
$PolterHostLabel = 'Codex CLI'
$PolterHostBin = 'codex'

# **Codex is the one that does not look like the others.** Its config is TOML
# at `%USERPROFILE%\.codex\config.toml` and its table is `mcp_servers`, with
# an underscore, where every other host in this directory uses JSON and
# `mcpServers`. That difference bites harder here than on the `sh` side:
# PowerShell has JSON in the language and no TOML at all. `codex mcp` writes
# the entry; the two lines it has no flags for -- `env_vars` and the approval
# mode -- go into that entry's table by plain line editing and nowhere else
# (`Set-CodexTable`).
#
# **`--json`, because the plain form hides the one thing asked of it**
# (#1645). `codex mcp get` prints every env value as `*****`, so the version
# marker was never found and every start removed and re-added the entry,
# rewriting config.toml. The JSON is parsed, not searched: its paths have
# their backslashes doubled, and the `mine` test looks for the path as Polter
# spells it. What comes back is plain lines -- the command, each env pair,
# the env_vars -- so the SDK's substring tests read them as they read the
# other hosts'. A Codex too old for `--json` gets the plain form, which is
# the old behaviour and no worse. Kept in step with `provision.sh`.
# **Every `codex` this file runs is bounded** (task 1667): see the same note
# in `provision.sh`. A call that does not answer within the limit is stopped
# with everything it started and throws `TimeoutException`; after one, nothing
# more is asked of Codex in this batch.
$script:PolterCodexSeconds = 8
$script:PolterCodexStuck = $false

function Invoke-CodexCall {
    param([string[]]$Arguments)
    if ($script:PolterCodexStuck) {
        throw (New-Object System.TimeoutException('codex did not answer earlier in this batch; not asked again'))
    }
    try {
        return Invoke-PolterBounded 'codex' $Arguments $script:PolterCodexSeconds
    } catch [System.TimeoutException] {
        $script:PolterCodexStuck = $true
        throw (New-Object System.TimeoutException("$($_.Exception.Message); nothing more is asked of codex this time"))
    }
}

function Get-HostMcpCurrent {
    $script:PolterCodexStuck = $false
    $r = Invoke-CodexCall @('mcp', 'get', 'polter', '--json')
    $json = $(if ($r.ExitCode -eq 0) { $r.Out } else { '' })
    if (-not [string]::IsNullOrWhiteSpace($json)) {
        try {
            $j = ConvertFrom-Json $json
            $t = $j.transport
            $lines = @("command: $($t.command)")
            if ($t.env) {
                foreach ($p in $t.env.PSObject.Properties) { $lines += "env: $($p.Name)=$($p.Value)" }
            }
            $lines += "env_vars: $((@($t.env_vars) | Where-Object { $_ }) -join ',')"
            return ($lines -join "`n")
        } catch {
            # Not JSON after all: an older Codex. The plain form below.
        }
    }
    $r = Invoke-CodexCall @('mcp', 'get', 'polter')
    if ($r.ExitCode -eq 0) { return $r.Out }
    return ''
}

# **What Codex lets through to the server** (#1645). Codex hands an MCP
# server it starts a fixed short list of variables plus what the entry's
# `env` sets; the two `+mcp` needs to find Polter are per terminal, so they
# cannot go in `env`. `env_vars` names variables to pass through from
# Codex's own environment, which is the terminal's. `+mcp` reads no others
# (src/cli/mcp.zig).
$script:PolterCodexEnvVars = 'env_vars = ["GHOSTTY_POLTER_SOCKET", "GHOSTTY_POLTER_TOKEN"]'

# **Polter's own tools are not asked about one by one** (#1653). Codex's
# default for an MCP server's tools is `auto`, which asks before every call to
# a tool not annotated read-only -- and none of Polter's is -- so a worker
# stopped at "Allow the polter MCP server to run tool "me"?" before its first
# report. `approve` is Codex's "never ask". Set on the `polter` table only;
# `approve_tools=no` takes the line back out. Kept in step with `provision.sh`.
$script:PolterCodexApprove = 'default_tools_approval_mode = "approve"'

# **Which CLI started the server** (#1667). Codex gives an MCP server nothing
# that says Codex, so the entry's own `env` carries it for `identify`
# (plugins/codex/adapter.ps1). Kept in step with `provision.sh`.
$script:PolterCodexMarker = 'POLTER_AGENT_CLI'

function Test-CodexWantApprove { (Get-PolterParam 'approve_tools' 'yes') -eq 'yes' }

# The lines of the `[mcp_servers.polter]` table, header excluded, straight
# from the file: `codex mcp get --json` does not carry the approval mode
# (0.163.0, measured), and the plain form hides the env values.
function Get-CodexPolterTable {
    $path = Get-CodexConfig
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $inside = $false
    $lines = @()
    foreach ($line in ([System.IO.File]::ReadAllText($path, $script:PolterUtf8) -split "`r?`n")) {
        if ($line -match '^\s*\[') { $inside = $line -match '^\s*\[\s*mcp_servers\.polter\s*\]\s*$'; continue }
        if ($inside) { $lines += $line }
    }
    return $lines
}

function Test-HostMcpComplete {
    param([string]$Current)
    if (-not ($Current -match 'env_vars: .*GHOSTTY_POLTER_SOCKET' -and $Current -match 'env_vars: .*GHOSTTY_POLTER_TOKEN')) { return $false }
    if (-not $Current.Contains($script:PolterCodexMarker)) { return $false }
    $approves = @(Get-CodexPolterTable | Where-Object { $_ -match "^\s*default_tools_approval_mode\s*=\s*[`"']approve[`"']" }).Count -gt 0
    return ($approves -eq (Test-CodexWantApprove))
}

# Where Codex keeps everything of the person's: `$env:CODEX_HOME`, else
# `%USERPROFILE%\.codex` -- the same rule `codex mcp add` followed when it
# wrote the entry, and the one Codex reads skills and AGENTS.md by. **Every
# path below is built from this**: a skills directory or rules file under
# `%USERPROFILE%\.codex` while `CODEX_HOME` points elsewhere is written into
# the person's own directory and never read by the Codex that runs (task
# 1707).
function Get-CodexHome {
    if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $script:PolterHome '.codex' }
}

function Get-CodexConfig {
    Join-Path (Get-CodexHome) 'config.toml'
}

# Put `env_vars`, and the approval mode when `approve_tools` is yes, into the
# `[mcp_servers.polter]` table `codex mcp add` has just written; `codex mcp
# add` has a flag for neither. **Inside that one table
# and nowhere else**: straight under its header, any `env_vars = ...` line
# already in it dropped first, every other line copied as it was. So
# `codex mcp remove polter`, which deletes the table, takes it away too.
# Written BOM-less through a temp file and replaced atomically, the way
# `Edit-PolterJson` does it. Throws on failure, as `Register-HostMcp` must.
function Set-CodexTable {
    $path = Get-CodexConfig
    if (-not (Test-Path -LiteralPath $path)) { throw "no $path after codex mcp add" }
    $raw = [System.IO.File]::ReadAllText($path, $script:PolterUtf8)
    $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $out = New-Object System.Collections.Generic.List[string]
    $inside = $false
    $found = $false
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s*\[') {
            $inside = $line -match '^\s*\[\s*mcp_servers\.polter\s*\]\s*$'
            $out.Add($line)
            if ($inside) {
                $out.Add($script:PolterCodexEnvVars)
                if (Test-CodexWantApprove) { $out.Add($script:PolterCodexApprove) }
                $found = $true
            }
            continue
        }
        if ($inside -and $line -match '^\s*(env_vars|default_tools_approval_mode)\s*=') { continue }
        $out.Add($line)
    }
    if (-not $found) { throw "no [mcp_servers.polter] table in $path to put env_vars in" }
    $tmp = "$path.polter-tmp"
    [System.IO.File]::WriteAllText($tmp, ($out -join $eol), $script:PolterUtf8)
    try {
        $bak = "$path.polter-bak"
        [System.IO.File]::Replace($tmp, $path, $bak)
        Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        throw
    }
}

function Register-HostMcp {
    param($Version, $VersionKey, $Exe, $Scope)

    # `$Scope` is not passed on: Codex has no user/local split to pass it to.
    # Its user config is the only one `codex mcp add` writes, which is the
    # scope this plugin wants anyway.
    # Nothing to remove is the common case, and fine; not answering is not.
    $null = Invoke-CodexCall @('mcp', 'remove', 'polter')
    $r = Invoke-CodexCall @(
        'mcp', 'add', 'polter',
        '--env', "$VersionKey=$Version",
        '--env', "$($script:PolterCodexMarker)=codex",
        '--', $Exe, '+mcp'
    )
    if ($r.ExitCode -ne 0) {
        if ($r.Err) { Write-PolterLog (ConvertTo-PolterOneLine $r.Err) }
        throw "``codex mcp add polter`` exited $($r.ExitCode)"
    }
    Set-CodexTable
}

# **Keeping a Codex typed by hand out of the shared daemon** (task 1674): see
# the same note in `provision.sh`. One marked line, and a marked `[features]`
# header when this made the table; turning the parameter off takes out the
# marked lines, and the header only when the table is left empty. A
# `daemon_auto_start` the person wrote is left as it is.
$script:PolterCodexDaemonMark = '# set by Polter: hand-started Codex stays out of the shared app-server daemon'

function Test-CodexWantNoDaemon { (Get-PolterParam 'manual_out_of_daemon' 'no') -eq 'yes' }

function Set-HostSettings {
    $path = Get-CodexConfig
    $mark = $script:PolterCodexDaemonMark
    $want = Test-CodexWantNoDaemon
    $lines = @()
    if (Test-Path -LiteralPath $path) {
        $lines = @([System.IO.File]::ReadAllText($path, $script:PolterUtf8) -split "`r?`n")
        # Not `0..(Count - 2)`: with one line that range is `0, -1`, two lines.
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
            $lines = @($lines | Select-Object -First ($lines.Count - 1))
        }
    }
    $have = @($lines | Where-Object { $_.Contains($mark) -and $_ -notmatch '^\s*\[' }).Count -gt 0
    $theirs = @($lines | Where-Object { -not $_.Contains($mark) -and $_ -match '(^|[.\s])daemon_auto_start\s*=' }).Count -gt 0
    if ($want -eq $have) { return }
    if ($want -and $theirs) {
        Write-PolterLog "daemon_auto_start: left alone, $path already sets it"
        return
    }
    $line = "daemon_auto_start = false $mark"
    $out = New-Object System.Collections.Generic.List[string]
    $done = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        $isHeader = $l -match '^\s*\['
        if ($l.Contains($mark) -and -not $isHeader) { continue }
        if ($l.Contains($mark) -and $isHeader) {
            if ($want) { $out.Add($l); $out.Add($line); $done = $true; continue }
            $other = $false
            for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -notmatch '^\s*\['; $j++) {
                if ($lines[$j] -notmatch '^\s*(#.*)?$' -and -not $lines[$j].Contains($mark)) { $other = $true }
            }
            if ($other) {
                $out.Add($l)
            } elseif ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') {
                # Gone with it: the one blank line put in front of it when it
                # was made, so taking it back gives the file back byte for byte.
                $out.RemoveAt($out.Count - 1)
            }
            continue
        }
        if ($l -match '^\s*\[\s*features\s*\]\s*(#.*)?$') {
            $out.Add($l)
            if ($want) { $out.Add($line); $done = $true }
            continue
        }
        $out.Add($l)
    }
    if ($want -and -not $done) { $out.Add(''); $out.Add("[features] $mark"); $out.Add($line) }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $tmp = "$path.polter-tmp"
    $text = $(if ($out.Count -gt 0) { ($out -join "`n") + "`n" } else { '' })
    [System.IO.File]::WriteAllText($tmp, $text, $script:PolterUtf8)
    Move-Item -LiteralPath $tmp -Destination $path -Force
    $script:PolterWrote = $true
    # The person's daemon is not stopped: see provision.sh.
    if ($want) {
        Write-PolterLog 'daemon_auto_start: set to false; an app-server daemon already running is not stopped and keeps its sessions, so this takes effect once it has exited (or after signing in again or a restart)'
    } else {
        Write-PolterLog 'daemon_auto_start: taken back out'
    }
}

# Codex took the Agent Skills standard in January 2026 and looks in the same
# place the others do. It also reads an `openai.yaml` beside `SKILL.md` for UI
# metadata; we write none, and it is optional -- a skill without one loads.
function Get-HostSkillsDir {
    Join-Path (Get-CodexHome) 'skills'
}

# The file this CLI reads on every turn. **User level, never a project
# file**: a project's AGENTS.md belongs to whoever owns the repository, and
# Polter being installed on this machine is not a fact about their
# repository.
function Get-HostRulesFile { Join-Path (Get-CodexHome) 'AGENTS.md' }


# A test that only wants the functions above sets this
# (`test/codex-adapter/provision-settings.py`).
if ($env:POLTER_PROVISION_FUNCTIONS_ONLY -ne '1') { Invoke-PolterProvisionMain }
