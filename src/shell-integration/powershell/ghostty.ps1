# Polter/Ghostty shell integration for PowerShell.
#
# Works on Windows PowerShell 5.1 (`powershell.exe`) and PowerShell 7+
# (`pwsh.exe`). It reports **the working directory (OSC 7) and the window
# title (OSC 2), and nothing else.** Prompt marking -- OSC 133 A/B/C/D -- is
# not here, and there is a section below saying why, because "just add
# OSC 133" is the first thing anyone reading this will want to do.
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
# ## Do not "just add OSC 133" here
#
# **There is no non-invasive way to do it, and that is a fact about
# PowerShell, not a gap in this file.**
#
# What makes the code below clean is that PowerShell has a purpose-built
# event for the thing being reported. **Prompt marking has no such event.**
# The only hooks are two functions that belong to somebody else:
#
#   * `prompt` -- a function, and oh-my-posh and starship each replace it
#     outright. Neither chains to what was there before, so wrapping it works
#     only while nothing installs after us. If a user's profile sets up one
#     of those later, our wrapper is gone and A/B/D stop, with no error
#     anywhere.
#   * `PSConsoleHostReadLine` -- the function **PSReadLine** defines. Without
#     PSReadLine there is nowhere to emit C from at all, and re-importing
#     PSReadLine redefines the function, dropping any wrapper silently. C
#     stops while A, B and D keep going, which is the worst of the states to
#     diagnose.
#
# So OSC 133 means replacing two functions the user's own tools also replace.
# It is doable -- Microsoft ships it in VS Code's `shellIntegration.ps1`,
# saving each original and invoking it -- but it is a different kind of change
# from this file, and **getting it wrong makes somebody's prompt disappear.**
# It is tracked separately, as L2.
#
# ## And when you write that: the exit code in `D` is not obtainable
#
# PowerShell offers no real exit code at prompt time. `$?` is a boolean, and
# `$LASTEXITCODE` is meaningful only for native executables and is stale
# after a failing cmdlet. Microsoft's own shipping implementation writes
#
#     $FakeCode = [int]!$global:?
#
# -- **the variable is named `FakeCode` in the original** -- so every failure
# is reported as `1`. A terminal receiving that shows "exit code 1" when the
# real one was 127.
#
# **Do not emit 0/1 in its place.** OSC 133 permits `D` with no exit code,
# and Microsoft itself sends the bare form when it cannot tell what happened.
# An honest "the command finished" beats a precise-looking number that is
# wrong.
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
