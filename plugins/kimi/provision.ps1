# Tell Moonshot's Kimi CLI that Polter is here. The Windows half.
#
# The implementation is in `_sdk/provision.ps1`; this file is the answers.
# See docs/poltergeist/provisioning.md and docs/windows/development.md 5.3.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_sdk\provision.ps1')

$PolterHostKey = 'kimi'
$PolterHostLabel = 'Kimi CLI'
$PolterHostBin = 'kimi'

# Kimi keeps TOML config and has a `kimi mcp` subcommand group. The exact
# flags below come from its documentation and have not been run against a real
# install; the failure they would produce is loud (`status=failed step=mcp`
# plus a notification), which is the point of it being loud.
function Get-HostMcpCurrent {
    Get-PolterCliOutput 'kimi' @('mcp', 'list')
}

function Register-HostMcp {
    param($Version, $VersionKey, $Exe, $Scope)

    Invoke-PolterCliQuietly 'kimi' @('mcp', 'remove', 'polter')
    Invoke-PolterCli 'kimi' @(
        'mcp', 'add', 'polter',
        '--env', "$VersionKey=$Version",
        '--', $Exe, '+mcp'
    )
}

# **Unverified**, so nothing rather than a guess. See `qwen-code/provision.sh`
# for what "verified" costs and what it buys.
function Get-HostSkillsDir { '' }

# **Nothing, on purpose.** Which rules file this CLI reads is a convention
# nobody here has checked, and writing into the wrong file in somebody's
# home directory is worse than not writing. The sentence it would have
# carried stays reachable through `skill_read`.
function Get-HostRulesFile { '' }

Invoke-PolterProvisionMain
