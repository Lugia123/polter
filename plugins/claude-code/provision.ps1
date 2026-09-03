# Tell Claude Code that Polter is here. The Windows half.
#
# **The counterpart of `provision.sh` beside it, not a replacement.** Windows
# cannot execute a `.sh`, and which systems a plugin runs on is the plugin's
# own business to state rather than the host's to guess -- see
# `docs/windows/development.md` 5.3. Everything else about this file is the
# same claim the `sh` one makes: the implementation is in
# `_sdk/provision.ps1` and this file is the answers.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_sdk\provision.ps1')

$PolterHostKey = 'claude-code'
$PolterHostLabel = 'Claude Code'
$PolterHostBin = 'claude'

# Registration goes through `claude mcp`, not through the file. The
# user-scoped config is `%USERPROFILE%\.claude.json`, which holds that user's
# entire Claude Code setup; parsing and re-serialising it to add one key would
# reformat the whole thing and reorder every key in it.
#
# **This survives PowerShell having `ConvertFrom-Json` built in, and the
# temptation is worth naming.** `Edit-PolterJson` is right there and would
# work. It would also rewrite a file whose owner is running, and hand back a
# reordered version of somebody's entire configuration. The tool that owns the
# file knows how to edit it, so it is asked to -- on both platforms, for the
# same reason, and not because `sh` made it awkward to do otherwise.
function Get-HostMcpCurrent {
    Get-PolterCliOutput 'claude' @('mcp', 'get', 'polter')
}

# `add` refuses a name that is already there, so a stale entry goes first.
#
# `--` separates our arguments from the served command's, so a future flag on
# the served side cannot be read as one of ours.
function Register-HostMcp {
    param($Version, $VersionKey, $Exe, $Scope)

    Invoke-PolterCliQuietly 'claude' @('mcp', 'remove', '--scope', $Scope, 'polter')
    Invoke-PolterCli 'claude' @(
        'mcp', 'add', '--scope', $Scope, 'polter',
        '-e', "$VersionKey=$Version",
        '--', $Exe, '+mcp'
    )
}

function Get-HostSkillsDir {
    Join-Path $script:PolterHome '.claude\skills'
}

# The file this CLI reads on every turn. **User level, never a project
# file**: a project's CLAUDE.md belongs to whoever owns the repository, and
# Polter being installed on this machine is not a fact about their
# repository.
function Get-HostRulesFile { Join-Path $script:PolterHome '.claude\CLAUDE.md' }

Invoke-PolterProvisionMain
