# Tell DeepSeek-TUI that Polter is here. The Windows half.
#
# The implementation is in `_sdk/provision.ps1`; this file is the answers.
# See docs/poltergeist/provisioning.md and docs/windows/development.md 5.3.
#
# **DeepSeek ships no CLI of its own.** V4-Pro is a model; the terminal agents
# for it are third-party, and this one targets DeepSeek-TUI, which is the one
# with a documented config path (`~/.deepseek/mcp.json`, the `deepseek`
# command). That makes this file different in kind from its siblings: every
# other host here is a vendor maintaining its own interface, and a third-party
# project can change its config shape without telling anybody. When it does,
# the breakage will look to a user exactly like Polter breaking. So this one
# is written to fail loudly and to say whose file it was reading.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_sdk\provision.ps1')

$PolterHostKey = 'deepseek'
$PolterHostLabel = 'DeepSeek-TUI'
$PolterHostBin = 'deepseek'

# `$HOME/.deepseek/mcp.json` on every platform, carried over from the `sh`
# version. Inherited, not verified on Windows -- see the same note in
# `opencode/provision.ps1`.
function Get-PolterDeepseekConfig {
    Join-Path $script:PolterHome '.deepseek\mcp.json'
}

function Get-HostMcpCurrent {
    Read-PolterJson (Get-PolterDeepseekConfig) {
        param($d)
        $entry = Get-PolterIn $d @('mcpServers', 'polter')
        $command = Get-PolterIn $entry @('command')
        $env = Get-PolterIn $entry @('env', 'POLTER_REGISTERED')
        "$command $env"
    }
}

function Register-HostMcp {
    param($Version, $VersionKey, $Exe, $Scope)

    Edit-PolterJson (Get-PolterDeepseekConfig) {
        param($d)
        if (-not $d.Contains('mcpServers')) { $d['mcpServers'] = [ordered]@{} }
        $d['mcpServers']['polter'] = [ordered]@{
            command = $Exe
            args = @('+mcp')
            env = [ordered]@{ $VersionKey = $Version }
        }
        $d
    }
}

# DeepSeek-TUI documents no skills mechanism. MCP only, which the tool-family
# map in `initialize` and `skill_read` between them make workable.
function Get-HostSkillsDir { '' }

Invoke-PolterProvisionMain
