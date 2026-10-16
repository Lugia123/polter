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
# the entry; the one line it has no flag for, `env_vars`, is put into that
# entry's table by plain line editing and nowhere else (`Set-CodexEnvVars`).
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
function Get-HostMcpCurrent {
    $json = Get-PolterCliOutput 'codex' @('mcp', 'get', 'polter', '--json')
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
    Get-PolterCliOutput 'codex' @('mcp', 'get', 'polter')
}

# **What Codex lets through to the server** (#1645). Codex hands an MCP
# server it starts a fixed short list of variables plus what the entry's
# `env` sets; the two `+mcp` needs to find Polter are per terminal, so they
# cannot go in `env`. `env_vars` names variables to pass through from
# Codex's own environment, which is the terminal's. `+mcp` reads no others
# (src/cli/mcp.zig).
$script:PolterCodexEnvVars = 'env_vars = ["GHOSTTY_POLTER_SOCKET", "GHOSTTY_POLTER_TOKEN"]'

function Test-HostMcpComplete {
    param([string]$Current)
    $Current -match 'env_vars: .*GHOSTTY_POLTER_SOCKET' -and $Current -match 'env_vars: .*GHOSTTY_POLTER_TOKEN'
}

# Where Codex keeps it: `$env:CODEX_HOME`, else `%USERPROFILE%\.codex` --
# the same rule `codex mcp add` followed when it wrote the entry.
function Get-CodexConfig {
    $dir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $script:PolterHome '.codex' }
    Join-Path $dir 'config.toml'
}

# Put `env_vars` into the `[mcp_servers.polter]` table `codex mcp add` has
# just written; `codex mcp add` has no flag for it. **Inside that one table
# and nowhere else**: straight under its header, any `env_vars = ...` line
# already in it dropped first, every other line copied as it was. So
# `codex mcp remove polter`, which deletes the table, takes it away too.
# Written BOM-less through a temp file and replaced atomically, the way
# `Edit-PolterJson` does it. Throws on failure, as `Register-HostMcp` must.
function Set-CodexEnvVars {
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
            if ($inside) { $out.Add($script:PolterCodexEnvVars); $found = $true }
            continue
        }
        if ($inside -and $line -match '^\s*env_vars\s*=') { continue }
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
    Invoke-PolterCliQuietly 'codex' @('mcp', 'remove', 'polter')
    Invoke-PolterCli 'codex' @(
        'mcp', 'add', 'polter',
        '--env', "$VersionKey=$Version",
        '--', $Exe, '+mcp'
    )
    Set-CodexEnvVars
}

# Codex took the Agent Skills standard in January 2026 and looks in the same
# place the others do. It also reads an `openai.yaml` beside `SKILL.md` for UI
# metadata; we write none, and it is optional -- a skill without one loads.
function Get-HostSkillsDir {
    Join-Path $script:PolterHome '.codex\skills'
}

# The file this CLI reads on every turn. **User level, never a project
# file**: a project's AGENTS.md belongs to whoever owns the repository, and
# Polter being installed on this machine is not a fact about their
# repository.
function Get-HostRulesFile { Join-Path $script:PolterHome '.codex\AGENTS.md' }

Invoke-PolterProvisionMain
