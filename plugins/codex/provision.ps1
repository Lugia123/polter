# Tell OpenAI's Codex CLI that Polter is here. The Windows half.
#
# The implementation is in `_sdk/provision.ps1`; this file is the answers.
# See docs/poltergeist/provisioning.md and docs/windows/development.md 5.3.

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
# PowerShell has JSON in the language and no TOML at all, so the one host this
# file could not have edited by hand is also the one that never needs to be.
# `codex mcp` owns that file.
function Get-HostMcpCurrent {
    Get-PolterCliOutput 'codex' @('mcp', 'get', 'polter')
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
}

# Codex took the Agent Skills standard in January 2026 and looks in the same
# place the others do. It also reads an `openai.yaml` beside `SKILL.md` for UI
# metadata; we write none, and it is optional -- a skill without one loads.
function Get-HostSkillsDir {
    Join-Path $script:PolterHome '.codex\skills'
}

Invoke-PolterProvisionMain
