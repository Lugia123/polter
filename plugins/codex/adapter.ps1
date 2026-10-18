# The Codex adapter, for Windows: what a role can pick from, how to start it,
# and who it is.
#
# **A port of `adapter.py` beside it, item for item, and not a second design.**
# Windows will not run a `.py`, and Polter on Windows has no Python to lean on,
# so the manifest names this file as `adapter_windows`. Everything
# `adapter.py`'s header says -- what was measured against codex 0.163, which
# `-c` override switches off which kind of thing, the three things it never
# does (write a file, read a value out of an `env` table, run `codex`) -- is
# true of this file too, and is not repeated here.
#
#     adapter.ps1 inventory '<request>'
#     adapter.ps1 launch '<request>'
#     adapter.ps1 identify '<request>'
#
# **The two outputs are compared byte for byte** by
# `test/codex-adapter/compare.py`, which feeds both the same requests over the
# same files. What Windows makes different:
#
#   * **Encoding, JSON in, JSON out**: the same as the Claude Code adapter's
#     `adapter.ps1`, whose helpers are copied below unchanged (from
#     `Set-StrictMode` to `Get-SortedNames`) so that the two ports cannot
#     drift apart on how they read and write. That file's header says why
#     each one is the way it is.
#   * **`codex` is a `.cmd`.** npm installs `codex.cmd`, a batch shim around
#     `node ...\@openai\codex\bin\codex.js`, and a role's instructions -- quotes,
#     newlines, `&` -- must not be re-read by `cmd.exe`. So `argv[0..1]` is
#     `node.exe` and that script, found through the shim (`Resolve-CodexCommand`),
#     and `launch` refuses with the reason when nothing runnable is behind it.
#   * **`identify` on Windows has no process to read.** Polter does not send
#     a sidecar's parent there yet (`pid` is null), so the session is only
#     ever found by directory and by when the sidecar started -- its own pid,
#     which Polter sends there since task 1749 (`Get-ByDirectory`,
#     `by_directory` in adapter.py), with the same rule and the same refusal
#     to guess.
#   * **No `HOME`.** `USERPROFILE`, as roles.md 11.8 records.
#
# **ASCII only**, for the reason the Claude Code adapter gives: Windows
# PowerShell reads a script without a byte-order mark in the system code page.
# The `>`-like mark Codex draws is built from its code point, never typed.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ContractVersion = 1
# The server Polter registers for itself. A role that took it away would be a
# terminal that cannot report back.
$PolterServer = 'polter'
# Largest file this will read: `config.toml`. The same as `adapter.py`.
$MaxBytes = 4 * 1024 * 1024
$TextLimit = 256 * 1024

$script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
$script:Desktop = $PSVersionTable.PSEdition -eq 'Desktop'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Ordinal = [System.StringComparison]::Ordinal
# A middle dot between spaces, as `adapter.py` writes it. **Built, not typed**: this
# file is ASCII so that Windows PowerShell, which reads a script without a
# byte-order mark in the system code page, reads it the same everywhere. A
# double-byte code page can take a stray UTF-8 byte and the newline after it
# together, and the next line of code quietly becomes part of a comment.
$script:Dot = ' ' + [char]0x00B7 + ' '

# Both directions, as the test machine needed. A console that is not there to
# be told is not an error.
$OutputEncoding = $script:Utf8
try { [Console]::OutputEncoding = $script:Utf8 } catch { }
try { [Console]::InputEncoding = $script:Utf8 } catch { }

if ($script:Desktop) {
    Add-Type -AssemblyName System.Web.Extensions
} else {
    try { Add-Type -AssemblyName System.Text.Json } catch { }
}

# --- small things Python has and PowerShell spells differently -------------

function New-Map { New-Object System.Collections.Specialized.OrderedDictionary }
function New-List { ,(New-Object System.Collections.Generic.List[object]) }

function Write-Err([string]$Text) {
    $bytes = $script:Utf8.GetBytes($Text + "`n")
    $err = [Console]::OpenStandardError()
    $err.Write($bytes, 0, $bytes.Length)
    $err.Flush()
}

# **Case-sensitive everywhere, on purpose.** PowerShell's `-eq`,
# `-contains`, `-replace`, `@{}` and `Sort-Object` all ignore case; Python's
# equivalents do not. Every comparison below is ordinal, and a hashtable
# literal never appears.

function Join-PyPath([string]$A, [string]$B) {
    [System.IO.Path]::Combine($A, $B)
}

# --- JSON in -----------------------------------------------------------------
#
# A parsed value stays in whichever shape its reader produced; these few
# functions are the only ones that look inside it.

function Read-JsonText([string]$Text) {
    if ($script:Desktop) {
        $s = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $s.MaxJsonLength = [int]::MaxValue
        $s.RecursionLimit = 1000
        return , $s.DeserializeObject($Text)
    }
    $opts = New-Object System.Text.Json.JsonDocumentOptions
    $opts.MaxDepth = 1000
    return , ([System.Text.Json.JsonDocument]::Parse($Text, $opts).RootElement)
}

function Test-Element($v) {
    (-not $script:Desktop) -and ($null -ne $v) -and ($v -is [System.Text.Json.JsonElement])
}

# A JSON value as a plain .NET value: objects and arrays stay as they are.
function Get-JValue($v) {
    if (Test-Element $v) {
        switch ($v.ValueKind.ToString()) {
            'String' { return $v.GetString() }
            'True' { return $true }
            'False' { return $false }
            'Number' {
                $n = 0L
                if ($v.TryGetInt64([ref]$n)) { return $n }
                return $v.GetDouble()
            }
            'Object' { return , $v }
            'Array' { return , $v }
            default { return $null }
        }
    }
    return , $v
}

function Test-JDict($v) {
    if ($null -eq $v) { return $false }
    if (Test-Element $v) { return $v.ValueKind.ToString() -eq 'Object' }
    return $v -is [System.Collections.IDictionary]
}

function Test-JList($v) {
    if ($null -eq $v -or $v -is [string]) { return $false }
    if (Test-Element $v) { return $v.ValueKind.ToString() -eq 'Array' }
    return ($v -is [System.Collections.IList]) -and -not ($v -is [System.Collections.IDictionary])
}

# The keys, in the file's order, each once.
function Get-JKeys($d) {
    $out = New-List
    if (Test-Element $d) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($p in $d.EnumerateObject()) {
            if ($seen.Add($p.Name)) { $out.Add($p.Name) }
        }
    } elseif ($null -ne $d) {
        foreach ($k in $d.Keys) { $out.Add([string]$k) }
    }
    return , $out
}

function Test-JHas($d, [string]$Key) {
    if (-not (Test-JDict $d)) { return $false }
    if (Test-Element $d) {
        foreach ($p in $d.EnumerateObject()) { if ($p.Name -ceq $Key) { return $true } }
        return $false
    }
    return Test-DictKey $d $Key
}

# `OrderedDictionary` answers `Contains`; the desktop reader's
# `Dictionary<string, object>` only `ContainsKey`.
function Test-DictKey($d, [string]$Key) {
    if ($d -is [System.Collections.Specialized.OrderedDictionary]) { return $d.Contains($Key) }
    return $d.ContainsKey($Key)
}

# `d.get(key)`. A key given twice is the last one, as Python reads it.
function Get-J($d, [string]$Key) {
    if (-not (Test-JDict $d)) { return $null }
    if (Test-Element $d) {
        $found = $null
        $has = $false
        foreach ($p in $d.EnumerateObject()) {
            if ($p.Name -ceq $Key) { $found = $p.Value; $has = $true }
        }
        if (-not $has) { return $null }
        return , (Get-JValue $found)
    }
    if (-not (Test-DictKey $d $Key)) { return $null }
    return , (Get-JValue $d[$Key])
}

function Get-JItems($l) {
    $out = New-List
    if (Test-Element $l) {
        foreach ($e in $l.EnumerateArray()) { $out.Add((Get-JValue $e)) }
    } elseif ($null -ne $l) {
        foreach ($e in $l) { $out.Add($e) }
    }
    return , $out
}

# Python's truthiness, for the `a or b` the original is written in.
function Test-Truthy($v) {
    if ($null -eq $v) { return $false }
    if ($v -is [bool]) { return $v }
    if ($v -is [string]) { return $v.Length -gt 0 }
    if (Test-JDict $v) { return (Get-JKeys $v).Count -gt 0 }
    if (Test-JList $v) { return (Get-JItems $v).Count -gt 0 }
    if ($v -is [System.ValueType]) { return [double]$v -ne 0 }
    return $true
}

# --- JSON out, exactly as `json.dumps(x, ensure_ascii=False)` writes it -----

function ConvertTo-PyString([string]$S) {
    $e = [regex]::Replace($S, '[\x00-\x1f"\\]', {
        param($m)
        switch ([int][char]$m.Value) {
            0x22 { return '\"' }
            0x5c { return '\\' }
            0x0a { return '\n' }
            0x0d { return '\r' }
            0x09 { return '\t' }
            0x08 { return '\b' }
            0x0c { return '\f' }
            default { return '\u{0:x4}' -f [int][char]$m.Value }
        }
    })
    return '"' + $e + '"'
}

function ConvertTo-PyJson($v) {
    $sb = New-Object System.Text.StringBuilder
    Write-PyJson $sb $v
    return $sb.ToString()
}

function Write-PyJson([System.Text.StringBuilder]$Sb, $v) {
    if ($null -eq $v) { [void]$Sb.Append('null'); return }
    if (Test-Element $v) {
        switch ($v.ValueKind.ToString()) {
            # A number is written as its source spelled it. Integers come out
            # as Python writes them; a float such as `1e5` would not (Python
            # writes `100000.0`), which the alignment fixtures state.
            'Number' { [void]$Sb.Append($v.GetRawText()); return }
            'Object' { }
            'Array' { }
            default { Write-PyJson $Sb (Get-JValue $v); return }
        }
    }
    if ($v -is [bool]) { [void]$Sb.Append($(if ($v) { 'true' } else { 'false' })); return }
    if ($v -is [string]) { [void]$Sb.Append((ConvertTo-PyString $v)); return }
    if (Test-JDict $v) {
        [void]$Sb.Append('{')
        $first = $true
        foreach ($k in (Get-JKeys $v)) {
            if (-not $first) { [void]$Sb.Append(', ') }
            $first = $false
            [void]$Sb.Append((ConvertTo-PyString $k)).Append(': ')
            Write-PyJson $Sb (Get-J $v $k)
        }
        [void]$Sb.Append('}')
        return
    }
    if (Test-JList $v) {
        [void]$Sb.Append('[')
        $first = $true
        foreach ($e in (Get-JItems $v)) {
            if (-not $first) { [void]$Sb.Append(', ') }
            $first = $false
            Write-PyJson $Sb $e
        }
        [void]$Sb.Append(']')
        return
    }
    if ($v -is [System.ValueType]) {
        [void]$Sb.Append(([System.IFormattable]$v).ToString($null, [System.Globalization.CultureInfo]::InvariantCulture))
        return
    }
    [void]$Sb.Append((ConvertTo-PyString ([string]$v)))
}

# --- files ------------------------------------------------------------------

# `(value, error)`. A missing file is `(null, null)`: nothing to say.
function Read-JsonFile([string]$Path) {
    try {
        if ([System.IO.Directory]::Exists($Path)) { return @($null, 'Is a directory') }
        if (-not [System.IO.File]::Exists($Path)) { return @($null, $null) }
        if ((New-Object System.IO.FileInfo($Path)).Length -gt $MaxBytes) {
            return @($null, 'too large to read')
        }
        $text = $script:Utf8Strict.GetString([System.IO.File]::ReadAllBytes($Path))
        return @((Read-JsonText $text), $null)
    } catch {
        return @($null, $_.Exception.Message)
    }
}

# Text as Python's text mode reads it: invalid bytes replaced, every line
# ending made `\n`, at most `$TextLimit` characters. `$null` when there is no
# file to read.
function Read-TextFile([string]$Path) {
    try {
        if (-not [System.IO.File]::Exists($Path)) { return $null }
        # Sharing writing, like every other read here (`Open-SharedRead`).
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $n = [int][Math]::Min($fs.Length, [long]($TextLimit * 8))
            $buf = New-Object byte[] $n
            $got = 0
            while ($got -lt $n) {
                $r = $fs.Read($buf, $got, $n - $got)
                if ($r -le 0) { break }
                $got += $r
            }
        } finally { $fs.Dispose() }
        $text = $script:Utf8.GetString($buf, 0, $got).Replace("`r`n", "`n").Replace("`r", "`n")
        if ($text.Length -gt $TextLimit) { $text = $text.Substring(0, $TextLimit) }
        return $text
    } catch {
        return $null
    }
}

# --- skills -----------------------------------------------------------------

# The `name` and `description` from a SKILL.md's frontmatter. See
# `adapter.py`'s `frontmatter` for what it reads and what it does not.
function Read-Frontmatter([string]$Text) {
    $out = New-Map
    if ($null -eq $Text -or -not $Text.StartsWith('---', $script:Ordinal)) { return , $out }
    $end = $Text.IndexOf("`n---", 3, $script:Ordinal)
    if ($end -lt 0) { return , $out }
    $lines = $Text.Substring(3, $end - 3).Split("`n")
    $i = 0
    while ($i -lt $lines.Length) {
        $m = [regex]::Match($lines[$i], '^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')
        $i += 1
        if (-not $m.Success) { continue }
        $key = $m.Groups[1].Value
        $value = $m.Groups[2].Value.Trim()
        if (@('>', '|', '>-', '|-', '>+', '|+') -ccontains $value) {
            $block = New-List
            while ($i -lt $lines.Length -and ($lines[$i].StartsWith(' ', $script:Ordinal) -or $lines[$i].Trim() -ceq '')) {
                $block.Add($lines[$i].Trim())
                $i += 1
            }
            $joiner = $(if ($value.StartsWith('|', $script:Ordinal)) { "`n" } else { ' ' })
            $value = ([string]::Join($joiner, $block.ToArray())).Trim()
        } elseif ($value.Length -ge 2 -and $value[0] -ceq $value[$value.Length - 1] -and (@('"', "'") -ccontains [string]$value[0])) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $out[$key] = $value
    }
    return , $out
}

function Get-PyBaseName([string]$Path) {
    if ($script:OnWindows) {
        if ($Path.Length -ge 2 -and $Path[1] -ceq ':') { $Path = $Path.Substring(2) }
        $i = $Path.LastIndexOfAny([char[]]@('/', '\'))
    } else {
        $i = $Path.LastIndexOf('/')
    }
    return $Path.Substring($i + 1)
}

# --- Codex's own --------------------------------------------------------------

# What the provision puts into the polter entry's `env`.
$script:AgentMarker = 'POLTER_AGENT_CLI'
$script:SessionPattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
$script:SessionWords = @('resume', 'fork', '--last')
$script:Mark = [string][char]0x203A
$script:PluginsNote = 'Codex plugins and apps are not listed: a role cannot switch them off from the command line.'

function Get-HomeDir($Req) {
    $h = Get-J $Req 'home'
    if (Test-Truthy $h) { return [string]$h }
    if ($script:OnWindows) { return [string]$env:USERPROFILE }
    return [string]$env:HOME
}

# `$CODEX_HOME`, else `<home>/.codex`.
function Get-CodexHome([string]$HomeDir) {
    if ($env:CODEX_HOME) { return [string]$env:CODEX_HOME }
    return Join-PyPath $HomeDir '.codex'
}

function Get-SortedNames([string]$Dir) {
    try {
        if (-not [System.IO.Directory]::Exists($Dir)) { return , @() }
        $names = @([System.IO.Directory]::GetFileSystemEntries($Dir) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    } catch { return , @() }
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return , $names
}

# Items that still carry their file as `_path`, taken off before printing.
function Get-SkillsIn([string]$Dir, [string]$Source) {
    $items = New-List
    foreach ($entry in (Get-SortedNames $Dir)) {
        if ($entry.StartsWith('.', $script:Ordinal)) { continue }
        $path = Join-PyPath (Join-PyPath $Dir $entry) 'SKILL.md'
        $text = Read-TextFile $path
        if ($null -eq $text) { continue }
        $fm = Read-Frontmatter $text
        $name = $(if ($fm.Contains('name') -and $fm['name'].Length -gt 0) { $fm['name'] } else { $entry })
        $item = New-Map
        $item['kind'] = 'skill'
        $item['id'] = 'skill:' + $name
        $item['name'] = $name
        $item['description'] = $(if ($fm.Contains('description')) { $fm['description'] } else { '' })
        $item['source'] = $Source
        $item['_path'] = $path
        $items.Add($item)
    }
    return , $items
}

# --- config.toml (see `read_config` in adapter.py) -----------------------------

# A TOML basic string: JSON's escapes, plus DEL.
function ConvertTo-TomlString([string]$S) {
    return (ConvertTo-PyString $S).Replace([string][char]0x7F, '\u007f')
}

# `[ok, value]`: a string, a boolean, or nothing.
function Read-TomlScalar([string]$Text) {
    $t = $Text.Trim()
    if ($t.StartsWith('"""', $script:Ordinal) -or $t.StartsWith("'''", $script:Ordinal)) { return , @($null) }
    if ($t.StartsWith('"', $script:Ordinal)) {
        $m = [regex]::Match($t, '\A"((?:[^"\\]|\\.)*)"')
        if (-not $m.Success) { return , @($null) }
        try { return , @((Get-JValue (Read-JsonText ('"' + $m.Groups[1].Value + '"')))) } catch { return , @($m.Groups[1].Value) }
    }
    if ($t.StartsWith("'", $script:Ordinal)) {
        $end = $t.IndexOf("'", 1, $script:Ordinal)
        if ($end -gt 0) { return , @($t.Substring(1, $end - 1)) }
        return , @($null)
    }
    $w = [regex]::Match($t, '\A([A-Za-z]+)')
    if ($w.Success -and ($w.Groups[1].Value -ceq 'true')) { return , @($true) }
    if ($w.Success -and ($w.Groups[1].Value -ceq 'false')) { return , @($false) }
    return , @($null)
}

# `mcp_servers."a b"` -> the list of its parts, or `$null`.
function Read-HeaderPath([string]$Inner) {
    $parts = New-List
    $rest = $Inner.Trim()
    while ($rest.Length -gt 0) {
        if ($rest[0] -ceq '"') {
            $m = [regex]::Match($rest, '\A"((?:[^"\\]|\\.)*)"')
            if (-not $m.Success) { return $null }
            $parts.Add($m.Groups[1].Value)
            $rest = $rest.Substring($m.Length)
        } elseif ($rest[0] -ceq "'") {
            $end = $rest.IndexOf("'", 1, $script:Ordinal)
            if ($end -lt 0) { return $null }
            $parts.Add($rest.Substring(1, $end - 1))
            $rest = $rest.Substring($end + 1)
        } else {
            $m = [regex]::Match($rest, '\A[A-Za-z0-9_-]+')
            if (-not $m.Success) { return $null }
            $parts.Add($m.Value)
            $rest = $rest.Substring($m.Length)
        }
        $rest = $rest.TrimStart()
        if ($rest.StartsWith('.', $script:Ordinal)) {
            $rest = $rest.Substring(1).TrimStart()
        } elseif ($rest.Length -gt 0) {
            return $null
        }
    }
    return , $parts
}

function Read-CodexConfig([string]$Path, $Notes, [string]$Label) {
    $out = New-Map
    $servers = New-Map
    $top = New-Map
    $out['servers'] = $servers
    $out['top'] = $top
    $text = $null
    try {
        if (-not [System.IO.File]::Exists($Path)) { return , $out }
        if ((New-Object System.IO.FileInfo($Path)).Length -gt $MaxBytes) {
            $Notes.Add("Could not read ${Label}: too large to read")
            return , $out
        }
        $text = $script:Utf8.GetString([System.IO.File]::ReadAllBytes($Path)).Replace("`r`n", "`n").Replace("`r", "`n")
    } catch {
        $Notes.Add("Could not read ${Label}: " + $_.Exception.Message)
        return , $out
    }

    $table = New-List
    $unread = 0
    foreach ($raw in $text.Split("`n")) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#', $script:Ordinal)) { continue }
        if ($line.StartsWith('[[', $script:Ordinal)) { $table = $null; continue }
        if ($line.StartsWith('[', $script:Ordinal)) {
            $close = $line.LastIndexOf(']')
            $parts = $(if ($close -gt 0) { Read-HeaderPath $line.Substring(1, $close - 1) } else { $null })
            if ($null -eq $parts) { $unread += 1; $table = $null } else { $table = $parts }
            continue
        }
        if ($null -eq $table) { continue }
        $m = [regex]::Match($line, '\A((?:[A-Za-z0-9_-]+|"[^"]*")(?:\s*\.\s*(?:[A-Za-z0-9_-]+|"[^"]*"))*)\s*=\s*(.*)\z')
        if (-not $m.Success) { continue }
        $keyPath = New-List
        foreach ($p in $table) { $keyPath.Add($p) }
        $keyParts = Read-HeaderPath $m.Groups[1].Value
        if ($null -ne $keyParts) { foreach ($p in $keyParts) { $keyPath.Add($p) } }
        $value = (Read-TomlScalar $m.Groups[2].Value)[0]
        if ($keyPath.Count -eq 1) {
            $top[[string]$keyPath[0]] = $value
        } elseif ($keyPath.Count -eq 3 -and ([string]$keyPath[0] -ceq 'mcp_servers') -and (@('command', 'url', 'enabled') -ccontains [string]$keyPath[2])) {
            if (-not $servers.Contains([string]$keyPath[1])) { $servers[[string]$keyPath[1]] = New-Map }
            $servers[[string]$keyPath[1]][[string]$keyPath[2]] = $value
        } elseif ($keyPath.Count -ge 2 -and ([string]$keyPath[0] -ceq 'mcp_servers')) {
            if (-not $servers.Contains([string]$keyPath[1])) { $servers[[string]$keyPath[1]] = New-Map }
        }
    }
    if ($unread -gt 0) { $Notes.Add("${Label}: $unread table header(s) could not be read and were skipped.") }
    return , $out
}

function Get-ServerDetail($Spec) {
    $url = $(if ($Spec.Contains('url')) { $Spec['url'] } else { $null })
    if ($url -is [string] -and $url.Length -gt 0) {
        $m = [regex]::Match($url, '\A[a-z]+://([^/?#]+)')
        $hostPart = $(if ($m.Success) { $m.Groups[1].Value } else { $url })
        $at = $hostPart.Split('@')
        return 'http' + $script:Dot + $at[$at.Length - 1]
    }
    $command = $(if ($Spec.Contains('command')) { $Spec['command'] } else { $null })
    if ($command -is [string] -and $command.Length -gt 0) {
        return 'stdio' + $script:Dot + (Get-PyBaseName $command)
    }
    return ''
}

function Get-ServersFrom($Config, [string]$Source) {
    $items = New-List
    $servers = $Config['servers']
    $names = @($servers.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($name in $names) {
        $spec = $servers[$name]
        if ($spec.Contains('enabled') -and ($spec['enabled'] -is [bool]) -and -not $spec['enabled']) { continue }
        $item = New-Map
        $item['kind'] = 'mcp'
        $item['id'] = 'mcp:' + $name
        $item['name'] = $name
        $item['description'] = ''
        $item['detail'] = Get-ServerDetail $spec
        $item['source'] = $Source
        $item['locked'] = $name -ceq $PolterServer
        $items.Add($item)
    }
    return , $items
}

# --- finding codex --------------------------------------------------------------

# What to put in front of the arguments to start Codex, or `$null`. POSIX:
# `codex`, as `adapter.py` answers. Windows: never the batch shim -- a
# `codex.exe` on PATH, else `node.exe` and the script npm's `codex.cmd` runs.
function Resolve-CodexCommand {
    if (-not $script:OnWindows) {
        foreach ($d in ([string]$env:PATH).Split([System.IO.Path]::PathSeparator)) {
            if ($d.Length -gt 0 -and (Test-PosixExecutable (Join-PyPath $d 'codex'))) { return , @('codex') }
        }
        $h = [string]$env:HOME
        foreach ($c in @('/opt/homebrew/bin/codex', '/usr/local/bin/codex', "$h/.local/bin/codex")) {
            if (Test-PosixExecutable $c) { return , @('codex') }
        }
        return $null
    }
    $script:ShimFound = $null
    $found = @(Get-Command -Name 'codex' -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($c in $found) {
        $p = [string]$c.Path
        if ($p.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { return , @($p) }
    }
    $shims = New-List
    foreach ($c in $found) {
        $p = [string]$c.Path
        if ($p.EndsWith('.cmd', [System.StringComparison]::OrdinalIgnoreCase) -or $p.EndsWith('.bat', [System.StringComparison]::OrdinalIgnoreCase)) { $shims.Add($p) }
    }
    if ($env:APPDATA) { $shims.Add((Join-PyPath (Join-PyPath ([string]$env:APPDATA) 'npm') 'codex.cmd')) }
    foreach ($shim in $shims) {
        if (-not [System.IO.File]::Exists($shim)) { continue }
        $behind = Resolve-CodexShim $shim
        if ($null -ne $behind) { return , $behind }
        if ($null -eq $script:ShimFound) { $script:ShimFound = $shim }
    }
    return $null
}

function Test-PosixExecutable([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return $false }
    try {
        $mode = [int][System.IO.File]::GetUnixFileMode($Path)
        return ($mode -band 0x49) -ne 0
    } catch {
        return $true
    }
}

# `node.exe` and the script a `codex.cmd` starts, or `$null`. The shim's own
# text is read for the path; npm's layout is tried after it.
function Resolve-CodexShim([string]$Shim) {
    $dir = [System.IO.Path]::GetDirectoryName($Shim)
    $targets = New-List
    $text = Read-TextFile $Shim
    if ($null -ne $text) {
        foreach ($m in [regex]::Matches($text, '%~?dp0%?\\([^"%\r\n]+?\.js)', 'IgnoreCase')) {
            $targets.Add((Join-PyPath $dir $m.Groups[1].Value))
        }
    }
    $targets.Add((Join-PyPath $dir 'node_modules\@openai\codex\bin\codex.js'))
    foreach ($t in $targets) {
        if (-not [System.IO.File]::Exists($t)) { continue }
        $node = Join-PyPath $dir 'node.exe'
        if (-not [System.IO.File]::Exists($node)) {
            $node = $null
            foreach ($n in @(Get-Command -Name 'node' -CommandType Application -All -ErrorAction SilentlyContinue)) {
                if (([string]$n.Path).EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { $node = [string]$n.Path; break }
            }
        }
        if ($null -ne $node) { return , @($node, $t) }
    }
    return $null
}

# --- the three questions --------------------------------------------------------

# Every item, skills still carrying `_path`; the notes; the config.
function Get-Gathered($Req) {
    $homeDir = Get-HomeDir $Req
    $c = Get-J $Req 'cwd'
    $cwd = $(if (Test-Truthy $c) { [string]$c } else { $null })
    $chome = Get-CodexHome $homeDir
    $notes = New-List
    $items = New-List
    foreach ($i in (Get-SkillsIn (Join-PyPath $chome 'skills') 'user')) { $items.Add($i) }
    foreach ($i in (Get-SkillsIn (Join-PyPath (Join-PyPath $homeDir '.agents') 'skills') 'user')) { $items.Add($i) }
    foreach ($i in (Get-SkillsIn (Join-PyPath (Join-PyPath $chome 'skills') '.system') 'codex')) { $items.Add($i) }
    if ($null -ne $cwd) {
        foreach ($i in (Get-SkillsIn (Join-PyPath (Join-PyPath $cwd '.agents') 'skills') 'project')) { $items.Add($i) }
        foreach ($i in (Get-SkillsIn (Join-PyPath (Join-PyPath $cwd '.codex') 'skills') 'project')) { $items.Add($i) }
    }
    $config = Read-CodexConfig (Join-PyPath $chome 'config.toml') $notes 'config.toml'
    foreach ($i in (Get-ServersFrom $config 'user')) { $items.Add($i) }
    if ($null -ne $cwd) {
        $project = Read-CodexConfig (Join-PyPath (Join-PyPath $cwd '.codex') 'config.toml') $notes '.codex/config.toml'
        foreach ($i in (Get-ServersFrom $project 'project')) { $items.Add($i) }
    }
    return @($items, $notes, $config)
}

function Get-Public($Item) {
    $out = New-Map
    foreach ($k in $Item.Keys) {
        if (-not ([string]$k).StartsWith('_', $script:Ordinal)) { $out[$k] = $Item[$k] }
    }
    return , $out
}

function Get-Inventory($Req) {
    $g = Get-Gathered $Req
    $items = $g[0]; $notes = $g[1]
    $at = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $unique = New-List
    foreach ($item in $items) {
        $id = [string]$item['id']
        if (-not $at.ContainsKey($id)) {
            $at[$id] = $unique.Count
            $unique.Add($item)
        } elseif (([string]$item['source'] -ceq 'project') -and -not ([string]$unique[$at[$id]]['source'] -ceq 'project')) {
            $unique[$at[$id]] = $item
        }
    }
    $notes.Add($script:PluginsNote)
    $public = New-List
    foreach ($item in $unique) { $public.Add((Get-Public $item)) }
    $answer = New-Map
    $answer['version'] = $ContractVersion
    $answer['installed'] = $null -ne (Resolve-CodexCommand)
    $answer['resume'] = $true
    $answer['options'] = Get-LaunchOptions (Get-CodexHelp)
    $answer['items'] = $public
    $answer['notes'] = $notes
    return , $answer
}

# (key, label, flag): see OPTION_FLAGS in adapter.py.
$script:OptionFlags = @(@('approval', 'Approval', '--ask-for-approval'), @('sandbox', 'Sandbox', '--sandbox'))

# One argument as a Windows program reads its command line back into argv
# (the MSVC runtime's rules, which `CommandLineToArgvW` shares): quoted when
# it is empty or holds whitespace or a quote; a quote is escaped with a
# backslash, and a run of backslashes is doubled only where it ends up
# before a quote.
function ConvertTo-WindowsArgument([string]$S) {
    if ($S.Length -gt 0 -and $S.IndexOfAny([char[]]@([char]32, [char]9, [char]10, [char]11, [char]34)) -lt 0) { return $S }
    $b = New-Object System.Text.StringBuilder
    [void]$b.Append([char]34)
    $slashes = 0
    foreach ($ch in $S.ToCharArray()) {
        if ($ch -eq [char]92) { $slashes++; continue }
        if ($ch -eq [char]34) {
            [void]$b.Append([char]92, 2 * $slashes + 1)
            [void]$b.Append([char]34)
        } else {
            [void]$b.Append([char]92, $slashes)
            [void]$b.Append($ch)
        }
        $slashes = 0
    }
    [void]$b.Append([char]92, 2 * $slashes)
    [void]$b.Append([char]34)
    return $b.ToString()
}

# Put `$Argv` on a ProcessStartInfo as separate arguments.
#
# **Windows PowerShell 5.1 has no `ArgumentList`** (#888). It is .NET
# Framework's ProcessStartInfo, which only takes one `Arguments` string; the
# property is not there at all, and under `Set-StrictMode -Version 2.0`
# reading it throws rather than giving `$null`. That throw was caught as
# "could not run claude --version", and on the test machine no hook was ever
# configured. So the property is looked for, not read: where it exists it is
# used, and otherwise the string is built with the quoting a Windows program
# undoes.
function Set-StartArguments($Psi, $Argv) {
    $list = $Psi.PSObject.Properties['ArgumentList']
    if ($null -ne $list -and $null -ne $list.Value) {
        foreach ($a in $Argv) { $list.Value.Add([string]$a) }
        return
    }
    $Psi.Arguments = (@($Argv | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' ')
}

# --- launch options (see `launch_options` in adapter.py, task 1677) -------------

$script:HelpTimeoutMs = 10000

# Python's `str.splitlines()`: no empty line after a last line ending.
function Split-PyLines([string]$Text) {
    $out = New-List
    if ($Text.Length -eq 0) { return , $out }
    $parts = [regex]::Split($Text, "\r\n|[\n\r\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029]")
    $n = $parts.Count
    if ($parts[$n - 1].Length -eq 0) { $n -= 1 }
    for ($k = 0; $k -lt $n; $k++) { $out.Add($parts[$k]) }
    return , $out
}

# `on_path(binary) or binary`, as `help_text` runs it.
function Get-HelpExe {
    if ($script:OnWindows) {
        $start = Resolve-CodexCommand
        if ($null -eq $start) { return , @('codex') }
        return , $start
    }
    foreach ($d in ([string]$env:PATH).Split([System.IO.Path]::PathSeparator)) {
        if ($d.Length -gt 0) {
            $c = Join-PyPath $d 'codex'
            if (Test-PosixExecutable $c) { return , @($c) }
        }
    }
    if (Test-PosixExecutable '/opt/homebrew/bin/codex') { return , @('/opt/homebrew/bin/codex') }
    if (Test-PosixExecutable '/usr/local/bin/codex') { return , @('/usr/local/bin/codex') }
    if (Test-PosixExecutable "$([string]$env:HOME)/.local/bin/codex") { return , @("$([string]$env:HOME)/.local/bin/codex") }
    return , @('codex')
}

# `<binary> --help`, or `$null`. Reads a usage text; starts no session.
function Get-HelpText {
    $start = Get-HelpExe
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = [string]$start[0]
        $argv = New-List
        for ($k = 1; $k -lt $start.Count; $k++) { $argv.Add([string]$start[$k]) }
        $argv.Add('--help')
        Set-StartArguments $psi $argv
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $null = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($script:HelpTimeoutMs)) {
            try { $p.Kill() } catch { }
            return $null
        }
        $out = [string]$outTask.Result
        if ($p.ExitCode -eq 0 -and $out.Length -gt 0) { return $out }
        return $null
    } catch {
        return $null
    }
}

# `Get-HelpText`, read once per request (see `codex_help` in adapter.py).
$script:HelpRead = $false
$script:HelpCache = $null
function Get-CodexHelp {
    if (-not $script:HelpRead) {
        $script:HelpCache = Get-HelpText
        $script:HelpRead = $true
    }
    return $script:HelpCache
}

# Whether `--help` lists `$Flag` as an option of its own (see `takes_flag`).
function Test-TakesFlag([string]$Text, [string]$Flag) {
    if ($null -eq $Text) { return $false }
    $f = [regex]::Escape($Flag)
    return [regex]::IsMatch($Text, "(?m)^\s*(-\w, )?$f\b")
}

# The values `--help` lists for `$Flag`, in its order; none when it lists none.
function Get-FlagValues([string]$Text, [string]$Flag) {
    $out = New-List
    $lines = Split-PyLines $Text
    $f = [regex]::Escape($Flag)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ([regex]::IsMatch($lines[$i], "\A\s*(-\w, )?$f\b")) { $start = $i; break }
    }
    if ($start -lt 0) { return , $out }
    $block = New-List
    $block.Add($lines[$start])
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([regex]::IsMatch($line, '\A\s*-{1,2}[A-Za-z]') -and -not [regex]::IsMatch($line, '\A\s*- [\w-]+:')) { break }
        $block.Add($line)
    }
    $joined = [string]::Join(' ', $block.ToArray())
    $m = [regex]::Match($joined, 'choices:\s*((?:"[^"]+"\s*,?\s*)+)')
    if ($m.Success) {
        foreach ($v in [regex]::Matches($m.Groups[1].Value, '"([^"]+)"')) { $out.Add($v.Groups[1].Value) }
        return , $out
    }
    $m = [regex]::Match($joined, '\[possible values:\s*([^\]]+)\]')
    if ($m.Success) {
        foreach ($v in $m.Groups[1].Value.Split(',')) {
            $t = $v.Trim()
            if ($t.Length -gt 0) { $out.Add($t) }
        }
        return , $out
    }
    foreach ($line in $block) {
        $m = [regex]::Match($line, '\A\s*- ([\w-]+):')
        if ($m.Success) { $out.Add($m.Groups[1].Value) }
    }
    return , $out
}

# The short spellings `--help` gives `$Flag` (`-s, --sandbox`).
function Get-FlagAliases([string]$Text, [string]$Flag) {
    $out = New-List
    $f = [regex]::Escape($Flag)
    foreach ($line in (Split-PyLines $Text)) {
        $m = [regex]::Match($line, "\A\s*((?:-\w, )+)$f\b")
        if ($m.Success) {
            foreach ($a in $m.Groups[1].Value.Split(',')) {
                $t = $a.Trim()
                if ($t.Length -gt 0) { $out.Add($t) }
            }
            return , $out
        }
    }
    return , $out
}

# The `options` an inventory offers, from a `--help` text (`$null` is none).
function Get-LaunchOptions($Text) {
    $t = $(if ($null -eq $Text) { '' } else { [string]$Text })
    $out = New-List
    foreach ($o in $script:OptionFlags) {
        $values = Get-FlagValues $t $o[2]
        if ($values.Count -eq 0) { continue }
        $vs = New-List
        foreach ($v in $values) {
            $one = New-Map
            $one['value'] = $v
            $one['args'] = New-List
            $one['args'].Add($o[2])
            $one['args'].Add($v)
            $vs.Add($one)
        }
        $entry = New-Map
        $entry['key'] = $o[0]
        $entry['label'] = $o[1]
        $entry['flag'] = $o[2]
        $entry['aliases'] = Get-FlagAliases $t $o[2]
        $entry['values'] = $vs
        $out.Add($entry)
    }
    return , $out
}

# Whether the extra arguments already give one of `$Spellings`, alone or as
# `--flag=value`.
function Test-GivesFlag($Extra, $Spellings) {
    foreach ($a in $Extra) {
        foreach ($f in $Spellings) {
            if (($a -ceq $f) -or ([string]$a).StartsWith($f + '=', $script:Ordinal)) { return $true }
        }
    }
    return $false
}

# What Python's `'%s' % v` writes of a JSON value.
function Get-PyPercentS($v) {
    if ($null -eq $v) { return 'None' }
    if ($v -is [bool]) { return $(if ($v) { 'True' } else { 'False' }) }
    if ($v -is [string]) { return $v }
    if (($v -is [long]) -or ($v -is [int])) { return [string]$v }
    return ConvertTo-PyJson $v
}

# The flags the role's `cli.options` stand for (see `apply_options`).
function Get-AppliedOptions($Cli, $Extra, $Notes) {
    $args0 = New-List
    $picked = Get-J $Cli 'options'
    if (-not (Test-Truthy $picked)) { return , $args0 }
    if (-not (Test-JDict $picked)) { return , $args0 }
    $offered = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($o in (Get-LaunchOptions (Get-CodexHelp))) { $offered[[string]$o['key']] = $o }
    foreach ($key in (Get-JKeys $picked)) {
        $value = Get-J $picked $key
        if (-not $offered.ContainsKey($key)) {
            $Notes.Add('Launch option "' + $key + '" is not one this version offers; left out.')
            continue
        }
        $o = $offered[$key]
        $spellings = New-List
        $spellings.Add([string]$o['flag'])
        foreach ($a in $o['aliases']) { $spellings.Add([string]$a) }
        if (Test-GivesFlag $Extra $spellings) {
            $Notes.Add('Launch option "' + $key + '" left out: the extra arguments already give ' + [string]$o['flag'] + '.')
            continue
        }
        $hit = $null
        foreach ($v in $o['values']) {
            if (($value -is [string]) -and ([string]$v['value'] -ceq $value)) { $hit = $v; break }
        }
        if ($null -eq $hit) {
            $Notes.Add('Launch option ' + $key + '="' + (Get-PyPercentS $value) + '" is not a value this version takes; left out.')
            continue
        }
        foreach ($a in $hit['args']) { $args0.Add($a) }
    }
    return , $args0
}

# Whether a role leaves this item on: its default, flipped by `except`.
function Test-Enabled($Selection, [string]$Id) {
    $default = -not ((Test-JHas $Selection 'default') -and ((Get-J $Selection 'default') -is [bool]) -and -not (Get-J $Selection 'default'))
    $except = Get-J $Selection 'except'
    $listed = $false
    if (Test-JList $except) {
        foreach ($e in (Get-JItems $except)) { if ($e -is [string] -and $e -ceq $Id) { $listed = $true } }
    } elseif (Test-JDict $except) {
        $listed = Test-JHas $except $Id
    }
    return $default -ne $listed
}

function Find-Rollout([string]$CodexHome, [string]$Session) {
    $root = Join-PyPath $CodexHome 'sessions'
    if (-not [System.IO.Directory]::Exists($root)) { return $null }
    $suffix = '-' + $Session + '.jsonl'
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)) {
            $name = [System.IO.Path]::GetFileName($f)
            if ($name.StartsWith('rollout-', $script:Ordinal) -and $name.EndsWith($suffix, $script:Ordinal)) { return $f }
        }
    } catch { }
    return $null
}

function Get-SessionToResume($Req, $Extra, $Notes) {
    $session = Get-J $Req 'session'
    if ($null -eq $session) { return $null }
    foreach ($a in $Extra) {
        if ($script:SessionWords -ccontains $a) {
            $Notes.Add("The role's own arguments choose a session; session $(Get-PyStr $session) was left out.")
            return $null
        }
    }
    if (-not ($session -is [string]) -or -not [regex]::IsMatch($session, '\A' + $script:SessionPattern + '\z')) {
        $Notes.Add("$(Get-PyStr $session) is not a Codex session id; starting a new session.")
        return $null
    }
    if ($null -eq (Find-Rollout (Get-CodexHome (Get-HomeDir $Req)) $session)) {
        $Notes.Add("Session $session is not on this machine any more; starting a new session.")
        return $null
    }
    return $session
}

function Get-PyStr($v) {
    if ($v -is [bool]) { return $(if ($v) { 'True' } else { 'False' }) }
    if ($v -is [string]) { return $v }
    return ConvertTo-PyJson $v
}

# `hooks.ps1`'s `Get-CodexHookArgs` (task 1668), or nothing: see `hook_args`
# in adapter.py. Anything wrong on that side is no hooks at all, never some.
function Get-HookArgs($Req, $Notes) {
    $polter = Get-J $Req 'polter'
    if (-not ($polter -is [string]) -or $polter.Length -eq 0) {
        $Notes.Add('No Polter path in the request, so no hooks.')
        return , @()
    }
    $file = Join-PyPath $PSScriptRoot 'hooks.ps1'
    if (-not [System.IO.File]::Exists($file)) { return , @() }
    try {
        . $file
        # It hands back one list; a pipeline would see that as one object.
        $raw = Get-CodexHookArgs -Polter $polter -Windows $script:OnWindows
        $got = New-List
        foreach ($a in @($raw)) {
            if (($a -is [System.Collections.IEnumerable]) -and -not ($a -is [string])) {
                foreach ($x in $a) { $got.Add($x) }
            } else {
                $got.Add($a)
            }
        }
    } catch {
        $Notes.Add('Hooks were left out: ' + $_.Exception.Message)
        return , @()
    }
    foreach ($a in $got) {
        if (-not ($a -is [string])) {
            $Notes.Add('Hooks were left out: hooks.ps1 did not answer a list of strings.')
            return , @()
        }
    }
    return , $got
}

function Get-Launch($Req) {
    $role = Get-J $Req 'role'
    if (-not (Test-Truthy $role)) { $role = New-Map }
    $cli = Get-J $Req 'cli'
    if (-not (Test-Truthy $cli)) { $cli = New-Map }
    $g = Get-Gathered $Req
    $items = $g[0]; $notes = $g[1]; $config = $g[2]
    $notes.Add($script:PluginsNote)

    $projectIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $items) { if ([string]$item['source'] -ceq 'project') { [void]$projectIds.Add([string]$item['id']) } }
    $offPaths = New-List
    $offServers = New-List
    $offSkill = 0
    $offMcp = 0
    $counted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $items) {
        if (($item.Contains('locked') -and $item['locked']) -or ([string]$item['source'] -ceq 'project')) { continue }
        $kind = [string]$item['kind']
        $selection = Get-J $cli $(if ($kind -ceq 'skill') { 'skills' } else { 'mcp' })
        if (-not (Test-Truthy $selection)) { $selection = New-Map }
        if (Test-Enabled $selection ([string]$item['id'])) { continue }
        if ($kind -ceq 'skill') {
            if ($projectIds.Contains([string]$item['id'])) { continue }
            $offPaths.Add([string]$item['_path'])
        } else {
            if (-not [regex]::IsMatch([string]$item['name'], '\A[A-Za-z0-9_-]+\z')) {
                $notes.Add("MCP server `"$($item['name'])`" has a name a -c path cannot carry; it was left on.")
                continue
            }
            $offServers.Add([string]$item['name'])
        }
        if ($counted.Add([string]$item['id'])) {
            if ($kind -ceq 'skill') { $offSkill += 1 } else { $offMcp += 1 }
        }
    }

    $extra = New-List
    $args0 = Get-J $cli 'args'
    if (Test-JList $args0) { foreach ($a in (Get-JItems $args0)) { if ($a -is [string]) { $extra.Add($a) } } }

    $opts = New-List
    if ($offPaths.Count -gt 0) {
        $entries = New-List
        foreach ($p in $offPaths) { $entries.Add('{path=' + (ConvertTo-TomlString $p) + ',enabled=false}') }
        $opts.Add('-c')
        $opts.Add('skills.config=[' + [string]::Join(',', $entries.ToArray()) + ']')
    }
    foreach ($name in $offServers) {
        $opts.Add('-c')
        $opts.Add("mcp_servers.$name.enabled=false")
    }
    $model = Get-J $cli 'model'
    if (-not (Test-Truthy $model)) { $model = Get-J $role 'model' }
    if (Test-Truthy $model) { $opts.Add('-m'); $opts.Add($model) }
    $instructions = Get-J $role 'instructions'
    if (Test-Truthy $instructions) {
        $top = $config['top']
        if ($top.Contains('developer_instructions') -and ($top['developer_instructions'] -is [string])) {
            $notes.Add('The role''s instructions stand in for the developer_instructions in config.toml for this session.')
        }
        $opts.Add('-c')
        $opts.Add('developer_instructions=' + (ConvertTo-TomlString $instructions))
    }
    $hooks = Get-HookArgs $Req $notes
    foreach ($h in $hooks) { $opts.Add($h) }
    foreach ($o in (Get-AppliedOptions $cli $extra $notes)) { $opts.Add($o) }

    $session = Get-SessionToResume $Req $extra $notes

    $start = Resolve-CodexCommand
    if ($null -eq $start) {
        if ($script:OnWindows -and $null -ne $script:ShimFound) {
            throw "found $($script:ShimFound), but not the program it starts (no codex.js behind it with a node.exe to run it). A batch file is not given a role's instructions: cmd.exe would re-read their quotes and newlines."
        }
        $start = @('codex')
    }
    $argv = New-List
    foreach ($s in $start) { $argv.Add($s) }
    if ($null -ne $session) { $argv.Add('resume'); $argv.Add($session) }
    # Always in its own process, when this Codex takes the flag: see `launch`
    # in adapter.py (tasks 1667, 1712).
    $text = Get-CodexHelp
    if (Test-TakesFlag $text '--no-daemon') {
        $argv.Add('--no-daemon')
    } elseif ($null -eq $text) {
        $notes.Add('Could not read codex --help, so --no-daemon was left out; signed in to a ChatGPT account, this session may run in Codex''s shared background server.')
    } else {
        $notes.Add('This Codex does not take --no-daemon (its --help does not list it), so it was left out.')
    }
    foreach ($o in $opts) { $argv.Add($o) }
    foreach ($e in $extra) { $argv.Add($e) }

    $answer = New-Map
    $answer['version'] = $ContractVersion
    $answer['argv'] = $argv
    $answer['env'] = New-Map
    $answer['summary'] = "$offSkill skill(s) and $offMcp MCP server(s) switched off"
    $answer['notes'] = $notes
    if ($hooks.Count -gt 0) {
        $answer['hooks'] = $true
        $answer['hooks_heard'] = 'first_turn'
    }
    return , $answer
}

# --- identify (see `identify` in adapter.py) -----------------------------------

function Get-Quit {
    $ready = New-Map
    $ready['line'] = @(($script:Mark + ' Ask Codex to do anything'), ($script:Mark + ' Ask a follow-up question'), $script:Mark)
    $ready['none_of'] = @('esc to interrupt', 'esc to cancel', 'Allow the ',
        ($script:Mark + ' 1.'), ($script:Mark + ' 2.'), ($script:Mark + ' 3.'), ($script:Mark + ' 4.'))
    $quit = New-Map
    $quit['text'] = '/exit'
    $quit['ready'] = $ready
    return $quit
}

function Invoke-Quiet([string]$Exe, $ArgList) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        foreach ($a in $ArgList) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        return $out
    } catch {
        return $null
    }
}

# The executable of process `$Id`, or `$null`. Only POSIX: Polter does not
# send a pid on Windows.
function Get-ExeOf([long]$Id) {
    if ($script:OnWindows) { return $null }
    if ([System.IO.Directory]::Exists("/proc/$Id")) {
        try { return [System.IO.File]::ResolveLinkTarget("/proc/$Id/exe", $false).FullName } catch { return $null }
    }
    $out = Invoke-Quiet 'ps' @('-o', 'comm=', '-p', [string]$Id)
    if ($null -eq $out) { return $null }
    $v = $out.Trim()
    if ($v.Length -eq 0) { return $null }
    return $v
}

function Get-OpenFiles([long]$Id) {
    $list = New-List
    if ([System.IO.Directory]::Exists("/proc/$Id/fd")) {
        foreach ($fd in (Get-SortedNames "/proc/$Id/fd")) {
            try { $list.Add([System.IO.File]::ResolveLinkTarget("/proc/$Id/fd/$fd", $false).FullName) } catch { }
        }
        return , $list
    }
    $out = Invoke-Quiet 'lsof' @('-a', '-p', [string]$Id, '-Fn')
    if ($null -eq $out) { return $null }
    foreach ($line in $out.Split("`n")) {
        if ($line.StartsWith('n', $script:Ordinal)) { $list.Add($line.Substring(1)) }
    }
    return , $list
}

function Test-IsCodex($Path) {
    if ($null -eq $Path) { return $false }
    $name = (Get-PyBaseName ([string]$Path)).ToLowerInvariant()
    return ($name -ceq 'codex') -or ($name -ceq 'codex.exe')
}

# See `by_directory` in adapter.py for why, and how far it can be trusted.
$script:ByDirectoryDays = 1
$script:StartedTogetherMs = 30 * 1000

function Get-WrittenMs([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    return [long]([System.DateTimeOffset]::new([System.IO.File]::GetLastWriteTimeUtc($Path)).ToUnixTimeMilliseconds())
}

# `2026-10-16T19:37:54.058Z` as Unix milliseconds, or $null.
function ConvertFrom-IsoMs($Value) {
    if (-not ($Value -is [string])) { return $null }
    $m = [regex]::Match($Value, '\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?Z\z')
    if (-not $m.Success) { return $null }
    $t = New-Object System.DateTimeOffset([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value,
        [int]$m.Groups[4].Value, [int]$m.Groups[5].Value, [int]$m.Groups[6].Value, [System.TimeSpan]::Zero)
    $frac = $(if ($m.Groups[7].Success) { $m.Groups[7].Value } else { '0' })
    if ($frac.Length -gt 3) { $frac = $frac.Substring(0, 3) }
    $frac = $frac.PadRight(3, '0')
    return [long]($t.ToUnixTimeSeconds() * 1000 + [long]$frac)
}

# The milliseconds a UUIDv7 carries, or $null.
function Get-UuidMs([string]$Session) {
    $hex = $Session.Replace('-', '')
    if ($hex.Length -ne 32 -or $hex[12] -cne '7') { return $null }
    return [long][System.Convert]::ToInt64($hex.Substring(0, 12), 16)
}

# A rollout opened for reading **while Codex may be writing it** (task 1749).
# A running Codex keeps its own rollout open for writing, and on Windows a
# reader that does not share writing is refused: `StreamReader($Path)` threw
# "being used by another process" for the very session a take-over is for,
# the catch below swallowed it, and every live Codex read as "its session
# was not found" (measured on codex 0.154). So: read access, sharing read
# and write -- what `Get-Content` does. Every read of a rollout goes through
# here (`test/codex-adapter/shared-read.py` holds that).
function Open-SharedRead([string]$Path) {
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    return New-Object System.IO.StreamReader($fs, $script:Utf8)
}

# `@(cwd, started_ms)` from a rollout's first line.
function Get-SessionMeta([string]$Path) {
    try {
        $reader = Open-SharedRead $Path
        try { $first = $reader.ReadLine() } finally { $reader.Dispose() }
        if ($null -eq $first) { return @($null, $null) }
        $meta = Get-JValue (Read-JsonText $first)
        $payload = Get-J $meta 'payload'
        if (-not (Test-JDict $payload)) { return @($null, $null) }
        $cwd = Get-J $payload 'cwd'
        if (-not ($cwd -is [string])) { $cwd = $null }
        return @($cwd, (ConvertFrom-IsoMs (Get-J $payload 'timestamp')))
    } catch { }
    return @($null, $null)
}

# `os.path.realpath`, near enough: symbolic links resolved on POSIX (macOS's
# /tmp is /private/tmp), the full path elsewhere.
function Get-RealPath([string]$Path) {
    if (-not $script:OnWindows) {
        $out = Invoke-Quiet 'realpath' @($Path)
        if ($null -ne $out -and $out.Trim().Length -gt 0) { return $out.Trim() }
    }
    try { return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return $Path }
}

function Test-SameDir([string]$A, [string]$B) {
    $ra = Get-RealPath $A
    $rb = Get-RealPath $B
    if ($script:OnWindows) { return [string]::Equals($ra, $rb, [System.StringComparison]::OrdinalIgnoreCase) }
    return $ra -ceq $rb
}

# When process `$Id` started, Unix milliseconds to the second, or $null.
function Get-StartedMs([long]$Id, [long]$NowMs) {
    if ($script:OnWindows) {
        try {
            $p = Get-Process -Id $Id -ErrorAction Stop
            return [long]([System.DateTimeOffset]::new($p.StartTime.ToUniversalTime()).ToUnixTimeSeconds() * 1000)
        } catch { return $null }
    }
    $out = Invoke-Quiet 'ps' @('-o', 'etime=', '-p', [string]$Id)
    if ($null -eq $out) { return $null }
    $m = [regex]::Match($out.Trim(), '\A(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)\z')
    if (-not $m.Success) { return $null }
    $parts = @(1, 2, 3, 4) | ForEach-Object { if ($m.Groups[$_].Success) { [long]$m.Groups[$_].Value } else { 0L } }
    return [long]($NowMs - ((($parts[0] * 24 + $parts[1]) * 3600 + $parts[2] * 60 + $parts[3]) * 1000))
}

function Test-IsDaemon([long]$Id) {
    if ($script:OnWindows) { return $false }
    $out = Invoke-Quiet 'ps' @('-o', 'command=', '-p', [string]$Id)
    if ($null -eq $out) { return $false }
    return (' ' + $out).Contains(' app-server')
}

# `@(session, written, note)`.
function Get-ByDirectory([string]$CodexHome, [string]$Cwd, $SidecarStarted, [long]$NowMs) {
    $root = Join-PyPath $CodexHome 'sessions'
    $cutoff = $NowMs - $script:ByDirectoryDays * 24 * 3600 * 1000
    $found = New-List
    if ([System.IO.Directory]::Exists($root)) {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)) {
            $m = [regex]::Match([System.IO.Path]::GetFileName($f), '\Arollout-.*-(' + $script:SessionPattern + ')\.jsonl\z')
            if (-not $m.Success) { continue }
            $w = Get-WrittenMs $f
            if ($null -eq $w -or $w -lt $cutoff) { continue }
            $meta = Get-SessionMeta $f
            if ($null -ne $meta[0] -and (Test-SameDir $meta[0] $Cwd)) {
                $started = $(if ($null -ne $meta[1]) { $meta[1] } else { Get-UuidMs $m.Groups[1].Value })
                $found.Add(@($w, $m.Groups[1].Value, $started))
            }
        }
    }
    if ($found.Count -eq 0) {
        return @($null, $null, 'No Codex session record in this directory was written in the last day.')
    }
    # Without a time for the sidecar, none (task 1749): see `by_directory`.
    if ($null -eq $SidecarStarted) {
        return @($null, $null, "$($found.Count) Codex session record(s) in this directory and no start of this Codex's Polter server to match one to, so none is named.")
    }
    $near = New-List
    foreach ($f in $found) {
        if ($null -ne $f[2] -and [Math]::Abs([long]$f[2] - [long]$SidecarStarted) -le $script:StartedTogetherMs) { $near.Add($f) }
    }
    if ($near.Count -eq 1) {
        return @($near[0][1], $near[0][0], "Named by directory and start: the Codex session here that started when this Codex started Polter's server.")
    }
    if ($near.Count -eq 0) {
        return @($null, $null, "No Codex session in this directory started when this Codex started Polter's server (it may be going on with an older one), so none is named.")
    }
    return @($null, $null, "$($near.Count) Codex sessions in this directory started within $([int]($script:StartedTogetherMs / 1000))s of this one, so which is this one is not known.")
}

function Get-Identify($Req) {
    $envIn = Get-J $Req 'env'
    if (-not (Test-JDict $envIn)) { $envIn = New-Map }
    $pidIn = Get-J $Req 'pid'
    $procId = $null
    if (($pidIn -is [long] -or $pidIn -is [int]) -and $pidIn -gt 0) { $procId = [long]$pidIn }
    $sidecarIn = Get-J $Req 'sidecar_pid'
    $sidecar = $null
    if (($sidecarIn -is [long] -or $sidecarIn -is [int]) -and $sidecarIn -gt 0) { $sidecar = [long]$sidecarIn }
    $cwdIn = Get-J $Req 'cwd'
    $cwd = $(if ($cwdIn -is [string] -and $cwdIn.Length -gt 0) { $cwdIn } else { $null })
    $notes = New-List

    $marked = (Get-J $envIn $script:AgentMarker) -ceq 'codex'
    $parent = $(if ($null -ne $procId) { Get-ExeOf $procId } else { $null })
    $me = $marked -or (Test-IsCodex $parent)
    $answer = New-Map
    $answer['version'] = 1
    $answer['me'] = [bool]$me
    if (-not $me) {
        $answer['session'] = $null
        $answer['session_written_ms'] = $null
        $answer['quit'] = $null
        $answer['notes'] = $notes
        return $answer
    }

    $session = $null
    $written = $null
    if ($null -eq $procId) {
        $notes.Add('No process to look at.')
    } elseif (-not (Test-IsCodex $parent)) {
        $notes.Add("The program that started Polter's server is not Codex itself.")
    } elseif (Test-IsDaemon $procId) {
        $notes.Add('Codex runs this session in its app-server daemon.')
    } else {
        $files = Get-OpenFiles $procId
        $found = New-List
        if ($null -ne $files) {
            foreach ($f in $files) {
                $m = [regex]::Match((Get-PyBaseName $f), '\Arollout-.*-(' + $script:SessionPattern + ')\.jsonl\z')
                if ($m.Success) { $found.Add(@($f, $m.Groups[1].Value)) }
            }
        }
        if ($null -eq $files) {
            $notes.Add('Could not read which files Codex has open.')
        } elseif ($found.Count -eq 0) {
            $notes.Add('Codex has no session record open.')
        } elseif ($found.Count -gt 1) {
            $notes.Add("Codex has $($found.Count) session records open, so which is this one is not known.")
        } else {
            $written = Get-WrittenMs $found[0][0]
            $session = $found[0][1]
        }
    }
    if ($null -eq $session) {
        if ($null -eq $cwd) {
            $notes.Add('No directory to look for its session in, so it is not known.')
        } else {
            $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $sidecarStarted = $(if ($null -ne $sidecar) { Get-StartedMs $sidecar $now } else { $null })
            $r = Get-ByDirectory (Get-CodexHome (Get-HomeDir $Req)) $cwd $sidecarStarted $now
            $session = $r[0]
            $written = $r[1]
            $notes.Add($r[2])
        }
    }
    $answer['session'] = $session
    $answer['session_written_ms'] = $written
    $answer['quit'] = Get-Quit
    $answer['notes'] = $notes
    return $answer
}

# --- main -------------------------------------------------------------------

function Invoke-Main($Argv) {
    if (($Argv.Count -ne 1 -and $Argv.Count -ne 2) -or -not (@('inventory', 'launch', 'identify') -ccontains [string]$Argv[0])) {
        Write-Err "usage: adapter.ps1 inventory|launch|identify '<request json>'"
        return 2
    }
    if ($Argv.Count -eq 2) {
        $raw = [string]$Argv[1]
    } else {
        $raw = (New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $script:Utf8)).ReadToEnd()
    }
    $req = $null
    if ($raw.Trim().Length -eq 0) {
        $req = New-Map
    } else {
        try { $req = Get-JValue (Read-JsonText $raw) } catch {
            Write-Err ('the request is not JSON: ' + $_.Exception.Message)
            return 2
        }
    }
    if (-not (Test-JDict $req)) {
        Write-Err 'the request is not a JSON object'
        return 2
    }
    try {
        $answer = $(switch -CaseSensitive ([string]$Argv[0]) {
                'inventory' { Get-Inventory $req }
                'launch' { Get-Launch $req }
                default { Get-Identify $req }
            })
    } catch {
        Write-Err $_.Exception.Message
        return 1
    }
    $bytes = $script:Utf8.GetBytes((ConvertTo-PyJson $answer) + "`n")
    $out = [Console]::OpenStandardOutput()
    $out.Write($bytes, 0, $bytes.Length)
    $out.Flush()
    return 0
}

exit (Invoke-Main $args)
