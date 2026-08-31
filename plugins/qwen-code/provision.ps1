# Tell Alibaba's Qwen Code that Polter is here. The Windows half.
#
# The implementation is in `_sdk/provision.ps1`; this file is the answers.
# See docs/poltergeist/provisioning.md and docs/windows/development.md 5.3.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_sdk\provision.ps1')

$PolterHostKey = 'qwen-code'
$PolterHostLabel = 'Qwen Code'
$PolterHostBin = 'qwen'

# **Qwen Code is a fork of gemini-cli**, so this file is nearly its sibling:
# `%USERPROFILE%\.qwen\settings.json`, key `mcpServers`, a `qwen mcp`
# subcommand of the same shape. That is not a coincidence to be pleased about
# -- it means an upstream change lands on Gemini CLI and Qwen Code at once,
# and both of these files break together. Whoever fixes one should check the
# other.
#
# On Windows what `Get-Command` finds is `qwen.cmd`, the npm shim, not an
# `.exe`. `Invoke-PolterCli` asks for `-CommandType Application`, which a
# `.cmd` satisfies; nothing else about the call changes.
function Get-HostMcpCurrent {
    Get-PolterCliOutput 'qwen' @('mcp', 'list')
}

function Register-HostMcp {
    param($Version, $VersionKey, $Exe, $Scope)

    Invoke-PolterCliQuietly 'qwen' @('mcp', 'remove', 'polter')
    Invoke-PolterCli 'qwen' @(
        'mcp', 'add', '--scope', 'user', 'polter',
        '-e', "$VersionKey=$Version",
        '--', $Exe, '+mcp'
    )
}

# **Confirmed on Windows, and only on Windows.** The `sh` version prints
# nothing here because on 2026-08-30 nobody had a machine with Qwen Code on
# it. This one has been read off an installed copy: Qwen Code 0.2.x creates
# `%USERPROFILE%\.qwen\skills\` at first run and reads user-level skills from
# it. The `sh` side is left alone rather than changed to match, because a
# directory verified on Windows is not a directory verified on macOS -- the
# two are the same relative path today, and "the same" is exactly the sort of
# thing this repository refuses to assume about somebody else's product.
function Get-HostSkillsDir {
    Join-Path $script:PolterHome '.qwen\skills'
}

Invoke-PolterProvisionMain
