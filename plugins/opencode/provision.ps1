# Tell opencode that Polter is here. The Windows half.
#
# The implementation is in `_sdk/provision.ps1`; this file is the answers.
# See docs/poltergeist/provisioning.md and docs/windows/development.md 5.3.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_sdk\provision.ps1')

$PolterHostKey = 'opencode'
$PolterHostLabel = 'opencode'
$PolterHostBin = 'opencode'

# **opencode has no `mcp add`, so this one edits the user's file**, with all
# the care that requires -- see `Edit-PolterJson`. It is also the host whose
# shape is furthest from the rest: the key is `mcp`, not `mcpServers`, and an
# entry is an object with `type` and `command` as a list, not a `command`
# string with `args` beside it. Copying a sibling into this file produces a
# config opencode reads and silently ignores.
#
# **This is where the two platforms stop being the same length.** The `sh`
# version hands the edit to `python3` and fails outright when there is none;
# here the parser is in the language, so this host has one fewer dependency on
# Windows than it has anywhere else. `plugin.json` still declares `python3` in
# `wants.exec` because that list is one list for all platforms -- it is
# disclosure, not a requirement the host enforces per system.
#
# The path is `$HOME/.config/opencode/opencode.json` on every platform,
# carried over from the `sh` version unchanged. **That is inherited, not
# verified**: nobody has run opencode on Windows to see whether it looks under
# `%USERPROFILE%\.config` or somewhere Windows-shaped like `%APPDATA%`. It is
# the same claim the `sh` file already makes, so this file makes no new one.
function Get-PolterOpencodeConfig {
    Join-Path $script:PolterHome '.config\opencode\opencode.json'
}

function Get-HostMcpCurrent {
    Read-PolterJson (Get-PolterOpencodeConfig) {
        param($d)
        $entry = Get-PolterIn $d @('mcp', 'polter')
        $command = Get-PolterIn $entry @('command')
        $env = Get-PolterIn $entry @('environment', 'POLTER_REGISTERED')
        "$env " + (@($command) -join ' ')
    }
}

function Register-HostMcp {
    param($Version, $VersionKey, $Exe, $Scope)

    Edit-PolterJson (Get-PolterOpencodeConfig) {
        param($d)
        if (-not $d.Contains('mcp')) { $d['mcp'] = [ordered]@{} }
        $d['mcp']['polter'] = [ordered]@{
            type = 'local'
            command = @($Exe, '+mcp')
            enabled = $true
            environment = [ordered]@{ $VersionKey = $Version }
        }
        $d
    }
}

# **Unverified.** opencode is listed among the agents that took the Agent
# Skills standard, but its user-level directory was not confirmed. Nothing
# rather than a guess: MCP only is a degradation, files written into the wrong
# directory are litter on somebody's machine.
function Get-HostSkillsDir { '' }

Invoke-PolterProvisionMain
