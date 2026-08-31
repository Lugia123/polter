# Provisioning on Windows, minus the part that differs per agent CLI.
#
# **The counterpart of `provision.sh`, not a translation of it.** Same split,
# same three states, same protocol: this file is the implementation and each
# host plugin beside it is a declaration. What changes is only what a language
# gives you -- PowerShell has JSON, so the hand-rolled parsing in the `sh`
# version is gone, and it has an automatic `$HOME` and a `WriteLine` that
# emits CRLF, so two things that were free in `sh` are deliberate here.
#
#   Set-StrictMode -Version 2.0
#   . (Join-Path $PSScriptRoot '..\_sdk\provision.ps1')
#
#   $PolterHostKey   = 'codex'
#   $PolterHostLabel = 'Codex CLI'
#   $PolterHostBin   = 'codex'
#
#   function Get-HostMcpCurrent { Get-PolterCliOutput 'codex' @('mcp','get','polter') }
#   function Register-HostMcp {
#     param($Version, $VersionKey, $Exe, $Scope)
#     Invoke-PolterCli 'codex' @('mcp','add','polter','--env',"$VersionKey=$Version",'--',$Exe,'+mcp')
#   }
#   function Get-HostSkillsDir { Join-Path $script:PolterHome '.codex\skills' }
#
#   Invoke-PolterProvisionMain
#
# **Why a second file at all, rather than teaching the host to pick an
# interpreter for `.sh`.** Because whether a plugin can run on this system is
# a property of the plugin, not something for the host to infer. See
# `docs/windows/development.md` 5.3.
#
# **The host still has to invoke this correctly**, and that is the one thing
# a plugin cannot do for itself: Windows will not execute a `.ps1` any more
# than it will a `.sh`, and the default execution policy refuses script files
# outright. The host spawns
#
#   powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <path>
#
# `-NoProfile` matters as much as the policy: a user's profile prints things,
# and anything on this process's standard output that is not an
# acknowledgement is judged misconduct and gets the plugin killed.

# --- what a host must define ------------------------------------------------
#
#   $PolterHostKey        short name, used as the log prefix
#   $PolterHostLabel      what a person calls it, used in notifications
#   $PolterHostBin        the binary whose presence means "this host is here"
#
#   Get-HostMcpCurrent    prints the current registration, empty if none.
#                         Only ever tested for substrings, so any format does.
#   Register-HostMcp      -Version -VersionKey -Exe -Scope
#                         Registers. **Throws on failure**, where the `sh`
#                         version returns non-zero; that is the whole of the
#                         difference, and `Invoke-PolterCli` does the throwing
#                         for the hosts that shell out.
#   Get-HostSkillsDir     returns the user-level skills directory, built from
#                         `$script:PolterHome`.
#                         **Returning nothing means this host has no skills**,
#                         which is a degradation and not a failure: the tools
#                         still arrive, and the tool-family map in `initialize`
#                         arrives with them. See docs/poltergeist/provisioning.md.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- the three streams, bound by hand ---------------------------------------
#
# **None of this is ceremony; every line of it is a bug that happened to
# somebody.**
#
# `[Console]::In` and `Write-Output` decode and encode with the console's code
# page, which on a Chinese-locale machine is 936 and not UTF-8. The batch line
# carries a home directory and skill paths, and a user called
# `C:\Users\张三` turns into mojibake on the way in and a path that does not
# exist on the way out. So both ends are opened as raw streams with an
# explicit UTF-8 encoding, and the `$false` argument is the one that matters:
# it means "no byte-order mark", and a BOM on the first acknowledgement is a
# line the host cannot parse.
#
# `WriteLine` writes `Environment.NewLine`, which here is CRLF. The protocol
# is one JSON object per `\n`, so every line this file writes ends in an
# explicit "`n" and nothing calls `WriteLine`.
$script:PolterUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:PolterIn = New-Object System.IO.StreamReader(
    [Console]::OpenStandardInput(), $script:PolterUtf8)
$script:PolterOut = New-Object System.IO.StreamWriter(
    [Console]::OpenStandardOutput(), $script:PolterUtf8)
$script:PolterErr = New-Object System.IO.StreamWriter(
    [Console]::OpenStandardError(), $script:PolterUtf8)

# `sh` flushes after every builtin, so a line written there is a line the host
# can read. Nothing here does that by itself: a plugin that buffers its
# acknowledgement is a plugin the host times out, kills and restarts, which
# from the plugin's side looks exactly like idling.
$script:PolterOut.AutoFlush = $true
$script:PolterErr.AutoFlush = $true

# Set by `Invoke-PolterProvision`, read by the host's own functions.
#
# **Not `$home`.** That is an automatic variable in PowerShell, and assigning
# to it either fails or silently changes what every other cmdlet in this
# process thinks the home directory is. The `sh` version calls it `$home`
# because there it is an ordinary shell variable.
$script:PolterHome = ''
$script:PolterWrote = $false
$script:PolterNote = ''

function Write-PolterLog {
    param([string]$Message)
    $script:PolterErr.Write("${script:PolterHostKey}: $Message`n")
}

# One property, or a default, without StrictMode turning a missing optional
# field into a terminating error.
function Get-PolterProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# **Three states, and they used to be two.**
#
#   absent       the binary is not on PATH. Not a problem, say so once.
#   provisioned  something was actually written. Silent when nothing changed.
#   failed       the binary is here and a step did not work. The user is told.
#
# `failed` is the only one that reaches a person unprompted, and it goes out
# on standard output, which means it must be written before the batch is
# acknowledged. See `_sdk/polter.sh`.
#
# The escaping is `ConvertTo-Json`'s, which is the first place PowerShell is
# simply better: the `sh` version escapes backslashes and quotes with `sed`
# and strips control characters with `tr`, and that is three utilities doing
# by hand what one call does correctly. Control characters are still stripped
# first, because the host clamps and strips them anyway and a `\u0007` that
# survives to a person's screen is a beep.
function Write-PolterTell {
    param([string]$Text)
    $clean = [regex]::Replace($Text, '[\x00-\x1f]', '')
    $script:PolterOut.Write((ConvertTo-Json @{ tell = $clean } -Compress) + "`n")
}

function Write-PolterFailure {
    param([string]$Step, [string]$Reason)
    Write-PolterLog "status=failed step=$Step -- $Reason"
    Write-PolterTell "${script:PolterHostLabel}: $Reason. Polter's tools will not appear in it until this is fixed."
}

# --- shelling out to a CLI --------------------------------------------------
#
# **stdout is discarded; stderr is not.** A CLI's chatter on success is noise,
# but the sentence explaining a failure is the only useful thing in the whole
# exchange. `| Out-Null` takes the success stream, which is where a native
# command's standard output lands; its standard error goes straight to this
# process's, which is this plugin's log.
function Invoke-PolterCli {
    param([string]$File, [string[]]$Arguments)

    & $File @Arguments | Out-Null

    # A native command's exit code does not raise anything in Windows
    # PowerShell no matter what `$ErrorActionPreference` says, so the check is
    # by hand. Throwing is what `Register-HostMcp` promises its caller.
    if ($LASTEXITCODE -ne 0) {
        throw "``$File $($Arguments -join ' ')`` exited $LASTEXITCODE"
    }
}

# Best effort, both streams discarded, exit code ignored. This is the `sh`
# version's `>/dev/null 2>&1 || true`, and it exists for exactly one caller:
# every `mcp add` here refuses a name that is already registered, so a stale
# entry is removed first and the common case is that there was nothing to
# remove. That failure is expected and must not reach the log.
function Invoke-PolterCliQuietly {
    param([string]$File, [string[]]$Arguments)

    try { & $File @Arguments 2>&1 | Out-Null } catch { }
    $global:LASTEXITCODE = 0
}

# The reading half: whatever the CLI printed, as one string, and an empty
# string for every way it can fail. Used only for substring tests.
function Get-PolterCliOutput {
    param([string]$File, [string[]]$Arguments)

    try {
        $out = & $File @Arguments 2>$null
    } catch {
        return ''
    }
    if ($null -eq $out) { return '' }
    return ($out | Out-String)
}

# --- editing a config file, for the hosts with no `mcp add` -----------------
#
# **This is the other kind of host, and it is not the same job wearing a
# different hat.** A CLI with an `mcp add` subcommand owns its own file: its
# format, its locking, its migrations are its problem. A host without one
# makes them ours. opencode and DeepSeek-TUI are in that position.
#
# The three properties that make it survivable are the `sh` version's, word
# for word:
#
#   1. **A file that does not parse is never written.** Overwriting somebody's
#      config because we could not read it is the one outcome worth refusing
#      outright -- it is unrecoverable and it is our fault.
#   2. **The write is atomic.** Temp file beside the target, then replace.
#   3. **A missing file is an empty object, not an error.**
#
# What is gone is `python3`. The `sh` version needs an interpreter on PATH to
# touch JSON at all and fails loudly when there is none; here `ConvertFrom-Json`
# is in the language, so that whole failure mode does not exist on Windows.
# **That is the single largest simplification in this file** and it is why the
# Windows manifests need not want `python3`.

# `ConvertFrom-Json` hands back `PSCustomObject`, which cannot have a property
# added by name without `Add-Member` and cannot be indexed. Ordered hashtables
# can do both and serialise back in the same order they were read, so the
# object is converted once on the way in and edited like the Python dict the
# `sh` version edits.
function ConvertTo-PolterMap {
    param($Value)

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) {
            $map[$p.Name] = ConvertTo-PolterMap $p.Value
        }
        return $map
    }

    if ($Value -is [System.Collections.IList]) {
        # `,` keeps a one-element result an array instead of unrolling it.
        return ,@($Value | ForEach-Object { ConvertTo-PolterMap $_ })
    }

    return $Value
}

# $Path   the file to edit
# $Edit   a scriptblock handed the parsed object as `$args[0]`; whatever it
#         returns is written back. Mirrors the `sh` version's `d`.
function Edit-PolterJson {
    param([string]$Path, [scriptblock]$Edit)

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $d = [ordered]@{}
    if (Test-Path -LiteralPath $Path) {
        $raw = [System.IO.File]::ReadAllText($Path, $script:PolterUtf8)
        if ($raw.Trim()) {
            try {
                $parsed = ConvertFrom-Json $raw
            } catch {
                # Refused, not repaired. See property 1 above.
                throw "cannot parse $Path ($($_.Exception.Message)); refusing to overwrite it"
            }
            if ($parsed -isnot [System.Management.Automation.PSCustomObject]) {
                throw "$Path is not a JSON object; refusing to overwrite it"
            }
            $d = ConvertTo-PolterMap $parsed
        }
    }

    $d = & $Edit $d

    # **`-Depth 100` is not optional.** Windows PowerShell defaults to 2 and
    # silently renders anything deeper as the string `System.Object[]`, so a
    # config with one more level of nesting than we expected comes out
    # corrupted with no error anywhere. This is the sharpest edge in the file.
    $text = (ConvertTo-Json $d -Depth 100) + "`n"

    # `Set-Content -Encoding UTF8` writes a byte-order mark in Windows
    # PowerShell, and a BOM in front of a config file is a parse error in most
    # of the runtimes that read one. Written through .NET with the same
    # BOM-less encoding everything else here uses.
    $tmp = "$Path.polter-tmp"
    [System.IO.File]::WriteAllText($tmp, $text, $script:PolterUtf8)
    try {
        if (Test-Path -LiteralPath $Path) {
            # Atomic on NTFS, and the reason for the dance: .NET Framework has
            # no overwriting `File.Move`, so replacing an existing file and
            # creating a new one are two different calls.
            #
            # **The backup path is named rather than passed as `$null`.**
            # `File.Replace` accepts a null backup, but `$null` does not
            # survive PowerShell's parameter binding into a `string`: it
            # arrives as `""`, and the call comes back "The path is not of a
            # legal form". That fires only when the target already exists,
            # which is to say only on the second write to a machine -- so a
            # suite that creates a config and checks it passes, and every user
            # whose config already existed fails. Found by injection, not by
            # any assertion; see the note in docs/windows/development.md 5.3.
            #
            # Naming it costs one file for the length of a rename and buys
            # back the old contents if this process dies mid-write.
            $bak = "$Path.polter-bak"
            [System.IO.File]::Replace($tmp, $Path, $bak)
            Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        throw
    }
}

# Read one value back out, for the staleness test. Returns an empty string
# when the file is missing or unreadable, which reads as "not registered" --
# the safe direction, because it costs one redundant write and never a missed
# one.
function Read-PolterJson {
    param([string]$Path, [scriptblock]$Read)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, $script:PolterUtf8)
        if (-not $raw.Trim()) { return '' }
        $d = ConvertTo-PolterMap (ConvertFrom-Json $raw)
        $out = & $Read $d
        if ($null -eq $out) { return '' }
        return ($out | Out-String)
    } catch {
        return ''
    }
}

# One key out of a nested map, or an empty string. The `sh` version reaches
# into `d` with Python's `.get()` chains; this is the same thing without a
# second language in the file.
function Get-PolterIn {
    param($Map, [string[]]$Path)

    $cur = $Map
    foreach ($key in $Path) {
        if ($null -eq $cur) { return '' }
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($key)) { return '' }
            $cur = $cur[$key]
        } else {
            return ''
        }
    }
    if ($null -eq $cur) { return '' }
    return $cur
}

# --- the work ---------------------------------------------------------------

function Invoke-PolterProvision {
    param($Event)

    $exe = Get-PolterProp $Event 'exe' ''
    $version = Get-PolterProp $Event 'version' ''
    $versionKey = Get-PolterProp $Event 'version_key' ''
    $script:PolterHome = Get-PolterProp $Event 'home' ''

    if (-not $exe -or -not $script:PolterHome) {
        Write-PolterLog 'status=failed step=parse -- the line from Polter had no exe or home in it'
        return $false
    }

    # `-CommandType Application` so a function or alias somebody left in scope
    # cannot pass for an installed CLI. On Windows the thing found is usually
    # `qwen.cmd` or `claude.cmd` rather than an `.exe`; both are Applications.
    $found = Get-Command $script:PolterHostBin -CommandType Application -ErrorAction SilentlyContinue
    if (-not $found) {
        Write-PolterLog "status=absent -- no ``$script:PolterHostBin`` on PATH ($env:PATH). Nothing to do; not an error."
        return $true
    }

    $script:PolterWrote = $false
    $script:PolterNote = ''

    # --- the MCP server -------------------------------------------------------
    #
    # Read before writing. These files are rewritten by the CLI that owns them
    # while it runs, and rewriting one at every launch for no reason is asking
    # for the one race that eats somebody's settings.
    #
    # The path alone would catch a move or a reinstall elsewhere but not a
    # build whose arguments or protocol changed while living at the same path.
    # The version marker is what makes "written by a different build" visible,
    # and it is why `Register-HostMcp` is handed the key and the value rather
    # than being trusted to invent one.
    $current = ''
    try { $current = (Get-HostMcpCurrent | Out-String) } catch { $current = '' }

    $stale = -not ($current.Contains($exe) -and $current.Contains($version))

    if ($stale) {
        try {
            Register-HostMcp -Version $version -VersionKey $versionKey -Exe $exe -Scope $script:PolterScope
        } catch {
            Write-PolterFailure 'mcp' "could not register the MCP server: $($_.Exception.Message)"
            return $false
        }
        $script:PolterWrote = $true
    }

    if ($script:PolterWantSkills -ne 'yes') {
        Write-PolterProvisionDone
        return $true
    }

    $skillsDir = ''
    try { $skillsDir = ((Get-HostSkillsDir | Out-String).Trim()) } catch { $skillsDir = '' }
    if (-not $skillsDir) {
        # Not a failure: somebody reading this log should be able to tell
        # "this host has no skills" from "the skills step broke". Carried on
        # the note rather than said here, because a line printed at every
        # launch is a line nobody reads.
        $script:PolterNote = ' skills=unsupported -- MCP only; the tool map in `initialize` and `skill_read` cover it'
        Write-PolterProvisionDone
        return $true
    }

    # --- the skills -----------------------------------------------------------
    #
    # Polter's skills are reachable through `skill_read`, which an agent has to
    # think to call. A host's own skills are found by its runtime and matched
    # against what the user asked for. Two mechanisms sharing a word; only one
    # of them does any matching.
    #
    # Installed under `polter-`, so nothing the user wrote is overwritten and
    # `/polter-supervising` says where it came from.
    $skills = @(Get-PolterProp $Event 'skills' @())
    if ($skills.Count -eq 0) {
        Write-PolterProvisionDone
        return $true
    }

    foreach ($skill in $skills) {
        $name = Get-PolterProp $skill 'name' ''
        $path = Get-PolterProp $skill 'path' ''
        if (-not $name -or -not $path) { continue }

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-PolterLog "status=failed step=skills -- no readable source for skill $name at $path"
            Write-PolterTell "${script:PolterHostLabel}: Polter's skills could not be installed. The agent will still have the tools, but will be far less likely to reach for them."
            return $false
        }

        $dir = Join-Path $skillsDir "polter-$name"
        $rendered = Format-PolterSkill -Path $path -Build $version

        # Written only when it differs. This runs at every start, and
        # rewriting a file the runtime may be reading, for no reason, is
        # asking for the one race that makes a skill vanish mid-session.
        $target = Join-Path $dir 'SKILL.md'
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $existing = [System.IO.File]::ReadAllText($target, $script:PolterUtf8)
            if ($existing.TrimEnd("`r", "`n") -eq $rendered) { continue }
        }

        try {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        } catch {
            Write-PolterLog "status=failed step=skills -- could not make $dir"
            Write-PolterTell "${script:PolterHostLabel}: Polter's skills could not be installed. The agent will still have the tools, but will be far less likely to reach for them."
            return $false
        }

        try {
            # LF and no BOM, so the file this writes and the file
            # `provision.sh` writes on a Mac are the same bytes. A skill is
            # read by a runtime, not by Notepad, and a diff between the two
            # platforms' output is a question nobody should have to answer.
            [System.IO.File]::WriteAllText($target, $rendered + "`n", $script:PolterUtf8)
        } catch {
            Write-PolterLog "status=failed step=skills -- could not write the skill $name"
            Write-PolterTell "${script:PolterHostLabel}: Polter's skills could not be installed. The agent will still have the tools, but will be far less likely to reach for them."
            return $false
        }

        $script:PolterWrote = $true
    }

    # --- skills that are no longer shipped ------------------------------------
    #
    # Installing without removing is not synchronising. A skill deleted from
    # Polter went on living in every machine that had ever been given it.
    #
    # **The `polter-` prefix is treated as this plugin's namespace**, not
    # merely as a way of avoiding collisions. Three checks narrow the claim to
    # what this plugin actually writes: a directory holding anything besides a
    # single `SKILL.md`, or whose frontmatter names something other than
    # itself, is somebody else's and is left alone even under the prefix.
    #
    # Pruning only ever runs after a clean install pass, and only when the
    # event actually carried a list of skills: an empty list is far more
    # likely to be a parse that failed than a release that ships nothing, and
    # acting on it would delete every skill on the machine.
    $shipped = @($skills | ForEach-Object { 'polter-' + (Get-PolterProp $_ 'name' '') })

    if (Test-Path -LiteralPath $skillsDir) {
        foreach ($d in @(Get-ChildItem -LiteralPath $skillsDir -Directory -Filter 'polter-*' -ErrorAction SilentlyContinue)) {
            if ($shipped -contains $d.Name) { continue }

            # Exactly one entry, and it is the file this plugin writes. A
            # skill that grew a `references/` or a script is not one of ours.
            $entries = @(Get-ChildItem -LiteralPath $d.FullName -Force)
            if ($entries.Count -ne 1 -or $entries[0].Name -ne 'SKILL.md') { continue }

            # And it calls itself what its directory calls it, which is a
            # thing this plugin guarantees on the way in.
            if ((Get-PolterSkillName $entries[0].FullName) -ne $d.Name) { continue }

            # Failure is not fatal. A skill that could not be removed is
            # stale, which is what it already was; taking the user's whole
            # tool surface down over it would be the worse trade.
            try {
                Remove-Item -LiteralPath $d.FullName -Recurse -Force
                Write-PolterLog "removed $($d.Name), which Polter no longer ships"
                $script:PolterWrote = $true
            } catch {
                Write-PolterLog "could not remove the stale skill $($d.Name)"
            }
        }
    }

    Write-PolterProvisionDone
    return $true
}

# The `awk` program from `provision.sh`, line for line.
#
# The whole file, frontmatter and all -- a skill without frontmatter is not
# one any of these runtimes will load. The name inside the frontmatter has to
# match the directory, or the runtime lists it under a name the user cannot
# type; rewritten in the frontmatter only, because a `name:` line in the prose
# is prose.
#
# **And it is stamped with the build that wrote it.** That closes its own
# loop: the stamp is part of the contents, so a new build changes the
# contents, so the "written only when it differs" test fires by itself.
#
# Only the installed copy is stamped. The file under `src/poltergeist/skills/`
# and the one in the bundle stay byte for byte identical, because a diff
# between them is how anybody checks what a release actually shipped.
function Format-PolterSkill {
    param([string]$Path, [string]$Build)

    $text = [System.IO.File]::ReadAllText($Path, $script:PolterUtf8)
    $lines = $text -split "`n" | ForEach-Object { $_.TrimEnd("`r") }

    $out = New-Object System.Collections.Generic.List[string]
    $fm = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($i -eq 0 -and $line -eq '---') { $fm = $true; $out.Add($line); continue }

        if ($fm -and $line -eq '---') {
            if ($Build) { $out.Add("polter-build: $Build") }
            $fm = $false
            $out.Add($line)
            continue
        }

        if ($fm -and $line.StartsWith('polter-build: ')) { continue }
        if ($fm -and $line.StartsWith('name: ')) {
            $out.Add('name: polter-' + $line.Substring(6))
            continue
        }

        $out.Add($line)
    }

    # `awk` prints each line with one `\n` and the caller adds none; the
    # trailing newline is put back at the write, so what is compared here and
    # what is compared in `provision.sh` are the same string.
    return ($out -join "`n").TrimEnd("`r", "`n")
}

# The `name:` an installed skill declares, for the pruning check.
function Get-PolterSkillName {
    param([string]$Path)

    try {
        $lines = [System.IO.File]::ReadAllText($Path, $script:PolterUtf8) -split "`n" |
            ForEach-Object { $_.TrimEnd("`r") }
    } catch {
        return ''
    }

    if ($lines.Count -eq 0 -or $lines[0] -ne '---') { return '' }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') { return '' }
        if ($lines[$i].StartsWith('name: ')) { return $lines[$i].Substring(6) }
    }
    return ''
}

# Said only when something was actually written. This runs at every launch,
# and a line per launch per host is eight lines of nothing in every log.
function Write-PolterProvisionDone {
    if (-not $script:PolterWrote) { return }
    Write-PolterLog "status=provisioned$script:PolterNote"
}

# --- the protocol -----------------------------------------------------------
#
# One acknowledgement per line the host writes, the greeting included. The
# host arms a deadline before each write and waits for a line back; a plugin
# that reads the greeting and then sits waiting for a batch is killed on
# `timeout_ms`, restarted, and killed again -- a restart loop that looks, from
# the plugin's side, exactly like idling.
#
# **Only acknowledgements and reports may go to stdout.** Anything else is
# judged misconduct and the process is killed. Diagnostics go to stderr, which
# is this plugin's log. In PowerShell that is a standing hazard rather than a
# rule you follow once: every uncaptured expression value lands on the success
# stream, so anything in this file that could return a value is either
# assigned or piped to `Out-Null`.
function Write-PolterAck {
    param([bool]$Ok)
    $script:PolterOut.Write('{"ok":' + $(if ($Ok) { 'true' } else { 'false' }) + "}`n")
}

function Invoke-PolterProvisionMain {
    $hello = $script:PolterIn.ReadLine()
    if ($null -eq $hello) { exit 0 }

    if ($hello -notmatch '"hello"') {
        Write-PolterLog 'the first line was not a handshake'
        Write-PolterAck $false
        exit 2
    }

    # **The parameters are in the greeting and nowhere else** -- "resolved
    # values, in plain text, exactly once in the whole conversation", as the
    # host puts it. Nothing repeats them per batch.
    $script:PolterScope = 'user'
    $script:PolterWantSkills = 'yes'
    try {
        $params = Get-PolterProp (ConvertFrom-Json $hello) 'params'
        $scope = Get-PolterProp $params 'scope' ''
        $skills = Get-PolterProp $params 'skills' ''
        if ($scope) { $script:PolterScope = $scope }
        if ($skills) { $script:PolterWantSkills = $skills }
    } catch {
        Write-PolterLog "could not read the parameters out of the greeting; using the defaults ($($_.Exception.Message))"
    }

    Write-PolterAck $true

    # `provision` is the only kind this subscribes to, so anything else is
    # passed over -- the host will not send one, and a plugin that trusts the
    # host to filter is a plugin that breaks the day its subscription grows.
    #
    # An empty batch is a heartbeat: it proves this process is still here, and
    # it gets the same yes as anything else.
    while ($null -ne ($batch = $script:PolterIn.ReadLine())) {
        if (-not $batch.Trim()) { continue }

        $ok = $true
        try {
            $events = @(Get-PolterProp (ConvertFrom-Json $batch) 'events' @())
        } catch {
            Write-PolterLog "the batch was not JSON: $($_.Exception.Message)"
            Write-PolterAck $false
            continue
        }

        foreach ($ev in $events) {
            if ((Get-PolterProp $ev 'kind' '') -ne 'provision') { continue }
            if (-not (Invoke-PolterProvision $ev)) { $ok = $false }
        }

        # "Not now", not misconduct. The host backs off and offers the same
        # event again, which is the whole thing being resident buys here: a
        # machine whose CLI was being upgraded at the moment Polter started
        # used to lose provisioning for the entire session.
        Write-PolterAck $ok
    }

    exit 0
}
