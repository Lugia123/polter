# Tell Google's Gemini CLI that Polter is here. The Windows half.
#
# The implementation is in `_sdk/provision.ps1`; this file is the answers.
# See docs/poltergeist/provisioning.md and docs/windows/development.md 5.3.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_sdk\provision.ps1')

$PolterHostKey = 'gemini'
$PolterHostLabel = 'Gemini CLI'
$PolterHostBin = 'gemini'

# `%USERPROFILE%\.gemini\settings.json`, key `mcpServers`. Written through the
# CLI rather than by hand for the reason every host here is: that file holds
# the user's whole setup, and re-serialising it to add one key reorders all of
# it.
function Get-HostMcpCurrent {
    Get-PolterCliOutput 'gemini' @('mcp', 'list')
}

function Register-HostMcp {
    param($Version, $VersionKey, $Exe, $Scope)

    Invoke-PolterCliQuietly 'gemini' @('mcp', 'remove', 'polter')
    Invoke-PolterCli 'gemini' @(
        'mcp', 'add', '--scope', 'user', 'polter',
        '-e', "$VersionKey=$Version",
        '--', $Exe, '+mcp'
    )
}

function Get-HostSkillsDir {
    Join-Path $script:PolterHome '.gemini\skills'
}

Invoke-PolterProvisionMain
