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

    # `remove` leaves a `"mcpServers": {}` behind in a file that had no such
    # key. Harmless, and left alone: the tool owns the file, and owning it
    # does not promise putting everything back.
    Invoke-PolterCliQuietly 'qwen' @('mcp', 'remove', 'polter')

    # **`-e` goes last, after the positional arguments.** `qwen mcp add`
    # takes `<name> <command> [args...]` and `-e` is an array option, which
    # yargs makes greedy; `--` ends parsing, so what follows it is not counted
    # as a positional either. Written with `-e` in the middle the parser sees
    # one positional and refuses the call outright:
    #
    #     Not enough non-option arguments: got 1, need at least 2
    #
    # **This is not a Windows problem.** The `.sh` beside this file had the
    # same line and the same bug from the day it was written; the full
    # reasoning, the cost of dropping `--`, and what was measured are in its
    # comment. Both files must stay in agreement.
    Invoke-PolterCli 'qwen' @(
        'mcp', 'add', '--scope', 'user', 'polter',
        $Exe, '+mcp',
        '-e', "$VersionKey=$Version"
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
