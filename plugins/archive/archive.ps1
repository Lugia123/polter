# Keep an extra copy of the chat, one file per day, all groups in one timeline.
#
# The Windows half of `archive.py`. Same protocol, same file names, and --
# this is the part that carries the weight -- **the same bytes**. See
# `Get-CanonicalJson` for why that is not a nicety.
#
# Windows cannot start a `.py`: `CreateProcess` does not read a shebang, so
# `launchKindFor` calls it `unsupported` and the host says so at load rather
# than failing at spawn (`Plugin.zig`). PowerShell ships with the operating
# system; Python does not. A plugin that depended on a Python install would
# trade "does not start" for "does not start on a machine without Python",
# which is the same failure with a longer sentence.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- the three streams, bound by hand ----------------------------------------
#
# **Copied from `_sdk/provision.ps1`, and every line of it is a bug that
# happened to somebody.** On Windows PowerShell 5.1 -- which is what ships,
# and what the test machine has -- none of these are defaults.
#
# `[Console]::In` and `Write-Output` use the console code page, which on a
# Chinese-locale machine is 936 and not UTF-8. This plugin's whole payload is
# chat text. The `$false` argument means "no byte-order mark", and a BOM on
# the first acknowledgement is a line the host cannot parse.
#
# `WriteLine` writes `Environment.NewLine`, which is CRLF here. The protocol
# is one JSON object per `\n`, so nothing below calls it.
#
# Without `AutoFlush` the acknowledgement sits in a buffer, the host's
# `timeout_ms` expires, and it kills and restarts us -- a loop that from this
# side looks exactly like idling.
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$In = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $Utf8)
$Out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $Utf8)
$Err = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), $Utf8)
$Out.AutoFlush = $true
$Err.AutoFlush = $true

function Write-Note {
    param([string]$Message)
    $Err.Write("archive: $Message`n")
}

# One property without StrictMode turning a missing optional field into a
# terminating error.
function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# An integer, or `$null` for anything that is not one. JSON numbers arrive as
# `Int32`, `Int64` or `Decimal`/`Double` depending on magnitude, and `at_ms`
# is past `Int32`. A float here would be a format change, and it must not
# quietly become a whole number on the way through.
function Get-Integer {
    param($Value)
    if ($Value -is [int] -or $Value -is [long]) { return [long]$Value }
    return $null
}

# --- the bytes ---------------------------------------------------------------
#
# **The one function in this file that has to agree with another program.**
#
# `archive.py` signs and writes `json.dumps(record, sort_keys=True,
# separators=(",", ":"), ensure_ascii=False)`. A verifier reads a line, drops
# `hmac`, renders the rest the same way and compares -- so a line written here
# whose canonical form differs from Python's by one byte does not verify, and
# nothing says so at the time it is written. It says so on the day somebody
# checks the archive, which is the one day it matters.
#
# `ConvertTo-Json` cannot be used for this. It escapes non-ASCII as `\uXXXX`
# where `ensure_ascii=False` emits it literally, and the chat this archives is
# largely not ASCII -- so that is not an edge case, it is every line.
#
# What Python's serialiser does, and this reproduces:
#   * keys sorted by code point (ordinal, *not* the culture-aware comparison
#     `Sort-Object` uses by default)
#   * `,` and `:` with no spaces
#   * `"` and `\` backslash-escaped; `\b \t \n \f \r` by name; other
#     characters below 0x20 as `\u00xx` lowercase hex
#   * everything else, including every non-ASCII character, literal
#
# Anything that is not a string, integer, boolean or null throws rather than
# being guessed at: an unexpected type means the record shape changed, and
# rendering it as something plausible would hide that until verification time.
function Get-CanonicalJson {
    param($Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long]) {
        return ([long]$Value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) { return (ConvertTo-CanonicalString $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        # **Ordinal, because Python sorts by code point.** `Sort-Object` is
        # culture-aware by default, and a culture-aware order puts the same
        # keys in a different sequence -- which is a different line, which is
        # a signature that does not verify.
        $keys = @($Value.Keys)
        [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $parts = @()
        foreach ($key in $keys) {
            $parts += (ConvertTo-CanonicalString ([string]$key)) + ':' + (Get-CanonicalJson $Value[$key])
        }
        return '{' + ($parts -join ',') + '}'
    }
    throw "archive: cannot render a $($Value.GetType().FullName) canonically"
}

function ConvertTo-CanonicalString {
    param([string]$Value)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        switch ($ch) {
            '"'  { [void]$sb.Append('\"'); continue }
            '\'  { [void]$sb.Append('\\'); continue }
            "`b" { [void]$sb.Append('\b'); continue }
            "`t" { [void]$sb.Append('\t'); continue }
            "`n" { [void]$sb.Append('\n'); continue }
            "`f" { [void]$sb.Append('\f'); continue }
            "`r" { [void]$sb.Append('\r'); continue }
            default {
                if ($code -lt 0x20) {
                    [void]$sb.Append('\u' + $code.ToString('x4', [System.Globalization.CultureInfo]::InvariantCulture))
                } else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# --- the disk ----------------------------------------------------------------

# The fields of a chat event, in the order `archive.py` lists them. The order
# does not reach the file -- canonical form sorts -- but keeping the same list
# in the same order is what makes the two files diffable by eye.
#
# `n` is deliberately absent: it is this event's place in the host's one
# stream, valid for one run of Polter, and a column of those in an archive is
# a foreign key to nothing. `seq` is the identity the core stamped on the
# message, and that still means the same thing tomorrow.
$Fields = @('seq', 'at_ms', 'group', 'author', 'text')

$Handles = @{}
$SignKeyBytes = $null
$Directory = $null

# `<dir>/YYYY-MM-DD.jsonl`, by the **local** day.
#
# Local rather than UTC because the core's own record is by local day
# (`daylog.zig`), and two records of the same evening that disagree about
# which evening it was are worse than either.
#
# `InvariantCulture` is not decoration: a culture whose default calendar is
# not Gregorian would render a different year for the same instant.
function Get-PathFor {
    param([long]$AtMs)
    $epoch = New-Object System.DateTime(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $day = $epoch.AddMilliseconds($AtMs).ToLocalTime().ToString(
        'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    return [System.IO.Path]::Combine($Directory, "$day.jsonl")
}

function Get-HandleFor {
    param([string]$Path)
    if ($Handles.ContainsKey($Path)) { return $Handles[$Path] }
    # Opened as a raw stream and written as bytes: nothing between the
    # canonical form and the file that could re-encode it or translate a
    # newline.
    $fs = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read)
    $Handles[$Path] = $fs
    return $fs
}

function Get-LineFor {
    param($Message)
    $record = New-Object 'System.Collections.Specialized.OrderedDictionary'
    foreach ($name in $Fields) {
        $p = $Message.PSObject.Properties[$name]
        if ($null -ne $p) { $record[$name] = $p.Value }
    }
    $summary = Get-Prop $Message 'summary'
    if ($summary) { $record['summary'] = $true }

    if ($null -ne $SignKeyBytes) {
        $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $SignKeyBytes)
        $mac = $hmac.ComputeHash($Utf8.GetBytes((Get-CanonicalJson $record)))
        $hmac.Dispose()
        # Lowercase hex, the same as Python's `hexdigest()`.
        $hex = New-Object System.Text.StringBuilder
        foreach ($b in $mac) {
            [void]$hex.Append($b.ToString('x2', [System.Globalization.CultureInfo]::InvariantCulture))
        }
        $record['hmac'] = $hex.ToString()
    }

    return (Get-CanonicalJson $record)
}

function Write-Message {
    param($Message)
    $at = Get-Integer (Get-Prop $Message 'at_ms')
    if ($null -eq $at) {
        $epoch = New-Object System.DateTime(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        $at = [long]([System.DateTime]::UtcNow - $epoch).TotalMilliseconds
    }
    $fs = Get-HandleFor (Get-PathFor $at)
    $bytes = $Utf8.GetBytes((Get-LineFor $Message) + "`n")
    $fs.Write($bytes, 0, $bytes.Length)
}

# Make the batch durable before it is acknowledged.
#
# **`Flush($true)`, not `Flush()`.** The argument is the whole point: it asks
# the operating system to put the bytes on the device, which is what
# `os.fsync` does on the other side. An acknowledgement is a promise, and a
# promise about bytes sitting in a buffer is one this process can break by
# exiting.
function Invoke-Commit {
    foreach ($fs in $Handles.Values) { $fs.Flush($true) }
}

# --- where the copy goes -----------------------------------------------------

# **`%LOCALAPPDATA%\polter\archive`, and that is the core's own rule rather
# than a preference.** `archive.py` uses `$XDG_STATE_HOME/polter/archive`
# falling back to `~/.local/state/polter/archive`; `src/os/xdg.zig`'s `state()`
# maps exactly that to `LOCALAPPDATA` on Windows. Writing `.local/state` into
# a Windows profile would be the Unix answer spelled out on a machine that
# does not use it.
#
# **Permissions.** `archive.py` creates the directory `0700` and its files
# `0600`; Windows has no equivalent to hand, and this does not set an ACL --
# ACL code is the kind that is wrong quietly. The effect is close because
# `%LOCALAPPDATA%` is per-user: its ACL was read on the test machine and
# carries only `SYSTEM`, `Administrators` and the owner, all inherited from
# the user profile, with no `Users` or `Everyone` entry. **That is the
# evidence, not just the conclusion** -- on a machine whose profile ACL has
# been changed it does not hold, and a reader with the evidence can check.
#
# ⚠️ **Half of it is still unverified**: what was read is `%LOCALAPPDATA%`
# itself. The `polter\archive` directory this creates did not exist yet, so
# "it really does inherit" has not been observed. Do not read the paragraph
# above as covering the subdirectory.
function Get-DirectoryFrom {
    param($Params)
    $configured = Get-Prop $Params 'dir'
    if ($configured -is [string] -and $configured.Trim()) {
        return [System.IO.Path]::GetFullPath(
            [System.Environment]::ExpandEnvironmentVariables($configured.Trim()))
    }
    $local = [System.Environment]::GetFolderPath('LocalApplicationData')
    if (-not $local) { throw 'no LOCALAPPDATA to write under' }
    return [System.IO.Path]::Combine($local, 'polter', 'archive')
}

# --- the protocol ------------------------------------------------------------

$Acked = [long]0

# Read the handshake and answer it.
#
# **The greeting is answered like everything else.** The host is holding a
# deadline open while it waits for this line; saying nothing is not "still
# starting up", it is a hung plugin, and it is killed and restarted for as
# long as it keeps doing it.
#
# `$false` is the honest answer when there is nowhere to write: the host reads
# it as "not ready, try later" and backs off rather than calling it
# misconduct. What must never happen is answering yes and then not storing
# anything.
function Invoke-Greet {
    param([string]$Line)
    try { $hello = ConvertFrom-Json $Line } catch {
        Write-Note "handshake is not JSON: $($_.Exception.Message)"
        return $false
    }
    if ($null -eq (Get-Prop $hello 'hello')) {
        Write-Note 'first line was not a handshake'
        return $false
    }

    $params = Get-Prop $hello 'params'
    $key = Get-Prop $params 'sign_key'
    if ($key -is [string] -and $key.Length -gt 0) {
        $script:SignKeyBytes = $Utf8.GetBytes($key)
    }

    try {
        $script:Directory = Get-DirectoryFrom $params
        [void][System.IO.Directory]::CreateDirectory($script:Directory)
    } catch {
        Write-Note "cannot use $($script:Directory): $($_.Exception.Message)"
        return $false
    }

    $cursor = Get-Integer (Get-Prop $hello 'cursor')
    if ($null -ne $cursor) { $script:Acked = $cursor }
    return $true
}

# One acknowledgement, and nothing else ever goes to standard output.
function Write-Ack {
    param([bool]$Ok, $Cursor = $null)
    $reply = if ($Ok -and $null -ne $Cursor) {
        '{"ok":true,"cursor":' + ([long]$Cursor).ToString([System.Globalization.CultureInfo]::InvariantCulture) + '}'
    } elseif ($Ok) { '{"ok":true}' } else { '{"ok":false}' }
    $Out.Write($reply + "`n")
}

function Invoke-Handle {
    param([string]$Line)

    try { $batch = ConvertFrom-Json $Line } catch {
        Write-Note "batch is not JSON: $($_.Exception.Message)"
        Write-Ack $false; return
    }
    if ($batch -isnot [System.Management.Automation.PSCustomObject]) {
        Write-Note 'batch is not an object'
        Write-Ack $false; return
    }

    $through = Get-Integer (Get-Prop $batch 'through')
    if ($null -eq $through) { $through = $script:Acked }
    $events = Get-Prop $batch 'events'
    if ($events -isnot [array]) { $events = @() }

    $written = $null
    try {
        foreach ($event in $events) {
            if ($event -isnot [System.Management.Automation.PSCustomObject]) { continue }
            # Everything on this stream carries its kind, and a plugin that
            # assumes otherwise is one that breaks the day its subscription
            # grows.
            if ((Get-Prop $event 'kind') -ne 'chat') { continue }
            # `n`, not `seq`. The cursor counts in the host's stream order,
            # which is the only order that spans kinds; `seq` is the chat
            # log's own identity and is what gets stored.
            $n = Get-Integer (Get-Prop $event 'n')
            if ($null -eq $n) { continue }
            # Seen already. The host resends a batch it never heard an
            # acknowledgement for, and this is the whole of the defence
            # against that arriving twice in the file.
            if ($n -le $script:Acked) { continue }
            Write-Message $event
            $written = $n
        }
        Invoke-Commit
    } catch {
        Write-Note "could not write: $($_.Exception.Message)"
        if ($null -eq $written) { Write-Ack $false; return }
        # Some of it landed. Say how far, and never further: the only numbers
        # in reach came out of this batch, and one above `through` would be
        # claiming to have stored something never sent.
        if ($written -gt $through) {
            Write-Note 'refusing to claim past the batch'
            Write-Ack $false; return
        }
        # What is being acknowledged has to be on disk before it is
        # acknowledged, and the write that failed left the rest of the batch
        # in a buffer.
        try { Invoke-Commit } catch {
            Write-Note "could not commit: $($_.Exception.Message)"
            Write-Ack $false; return
        }
        $script:Acked = $written
        Write-Ack $true $written
        return
    }

    # The whole batch, so there is nothing to say beyond yes -- the host takes
    # that as everything through `through`, which is what happened.
    if ($through -gt $script:Acked) { $script:Acked = $through }
    Write-Ack $true
}

$first = $In.ReadLine()
if ($null -eq $first) {
    # The host closed before saying anything. Nothing was promised, so this is
    # not a failure.
    exit 0
}

$ok = Invoke-Greet $first
Write-Ack $ok
if (-not $ok) { exit 2 }

while ($null -ne ($line = $In.ReadLine())) {
    if (-not $line.Trim()) { continue }
    Invoke-Handle $line
}
exit 0
