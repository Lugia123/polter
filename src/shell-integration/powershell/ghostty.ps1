# Polter/Ghostty shell integration for PowerShell.
#
# Works on Windows PowerShell 5.1 (`powershell.exe`) and PowerShell 7+
# (`pwsh.exe`). This is the L3 half: the working directory (OSC 7) and the
# window title (OSC 2). Prompt marking (OSC 133) is deliberately not here --
# it requires wrapping the user's `prompt` function, and getting that wrong
# makes somebody's prompt disappear.
#
# ## Why this hooks LocationChangedAction and not `prompt`
#
# `$ExecutionContext.SessionState.InvokeCommand.LocationChangedAction` is
# PowerShell's own event for "the current location changed" -- exactly the
# thing OSC 7 reports. bash and zsh have to hang this off their prompt
# machinery because they have no such event; PowerShell does, and using it
# means this file never touches the user's `prompt`. Someone running
# oh-my-posh or starship gets their prompt back untouched.
#
# The previous handler is called first, not replaced. It is a single-slot
# property: assigning to it is how you both install and uninstall, so an
# assignment that did not chain would silently disable whatever was there.
#
# ## The URI is `kitty-shell-cwd://`, and the leading slash is ours to add
#
# Two measured facts shape the string below:
#
#   * `file:///C:/...` is refused by the terminal. `std.Uri` parses a
#     three-slash `file:` URI with a *null* host, and the OSC 7 handler
#     requires a hostname (it is what tells a local cwd from one an SSH
#     session claimed). So the host has to be there.
#   * bash and zsh build their URI by concatenating the hostname and `$PWD`,
#     which works because a POSIX `$PWD` begins with `/`. **A Windows path
#     begins `C:\`** and donates no separator, so pasting the two together
#     would give `...://MYPCC:\Users\x` -- host and path fused. The `/`
#     between them below is that missing separator.
#
# The terminal accepts the backslashes as they are; `kitty-shell-cwd://` is
# passed through unescaped and the path converter takes either separator.

if ($env:GHOSTTY_POWERSHELL_LOADED) { return }
$env:GHOSTTY_POWERSHELL_LOADED = '1'

# `isLocal` on the terminal side short-circuits on the literal `localhost`
# and otherwise compares bytes against `GetComputerNameA`. The real name is
# the better answer -- it is what makes a cwd reported from an SSH session on
# another machine get rejected -- and `localhost` is the fallback for the
# rare environment where COMPUTERNAME is not set.
$global:GhosttyHost = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'localhost' }

# The last path reported, so an unchanged location is not re-sent on every
# command. bash keeps the same guard (`_ghostty_last_reported_cwd`).
$global:GhosttyLastCwd = $null

function global:__GhosttyReport {
    # Never let a reporting failure break the user's shell. There is nothing
    # this function can do that is worth an error at the prompt.
    try {
        $loc = Get-Location

        # **Only the filesystem provider.** `cd HKLM:\` moves the current
        # location into the registry, and `Get-Location` will happily hand
        # that back. Reporting it as a working directory would give the
        # terminal a path no file API can open -- and it would then be used
        # for the next tab's starting directory.
        if ($loc.Provider.Name -ne 'FileSystem') { return }

        # `ProviderPath`, not `Path`: for a PSDrive (`New-PSDrive X -Root
        # C:\work`) `Path` is `X:\...`, which exists only inside this
        # PowerShell session. `ProviderPath` is the real one.
        $p = $loc.ProviderPath
        if ([string]::IsNullOrEmpty($p)) { return }
        if ($p -eq $global:GhosttyLastCwd) { return }
        $global:GhosttyLastCwd = $p

        $esc = [char]27
        $bel = [char]7

        [Console]::Write("$esc]7;kitty-shell-cwd://$($global:GhosttyHost)/$p$bel")

        # The title is feature-gated the way bash gates it, so
        # `shell-integration-features = no-title` turns it off here too.
        if ($env:GHOSTTY_SHELL_FEATURES) {
            if (($env:GHOSTTY_SHELL_FEATURES -split ',') -contains 'title') {
                [Console]::Write("$esc]2;$p$bel")
            }
        }
    } catch {
    }
}

$global:GhosttyPrevLocationAction =
    $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction

$ExecutionContext.SessionState.InvokeCommand.LocationChangedAction = {
    param($source, $eventArgs)
    if ($global:GhosttyPrevLocationAction) {
        try { & $global:GhosttyPrevLocationAction $source $eventArgs } catch { }
    }
    __GhosttyReport
}

# The starting directory, which no change event will ever announce.
__GhosttyReport
