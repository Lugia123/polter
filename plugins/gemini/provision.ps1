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

    # `remove` leaves a `"mcpServers": {}` behind in a file that had no such
    # key. Harmless, and left alone: the tool owns the file, and owning it
    # does not promise putting everything back.
    Invoke-PolterCliQuietly 'gemini' @('mcp', 'remove', 'polter')

    # **`-e` goes last, after the positional arguments.** `gemini mcp add`
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
    Invoke-PolterCli 'gemini' @(
        'mcp', 'add', '--scope', 'user', 'polter',
        $Exe, '+mcp',
        '-e', "$VersionKey=$Version"
    )
}

function Get-HostSkillsDir {
    Join-Path $script:PolterHome '.gemini\skills'
}

Invoke-PolterProvisionMain
