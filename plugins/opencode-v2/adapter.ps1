# The opencode adapter, for Windows: what a role can pick from, how to start
# it, and who it is (task 1781).
#
# **A port of `adapter.py` beside it, item for item, and not a second design.**
# Windows will not run a `.py`, and Polter on Windows has no Python to lean on,
# so the manifest names this file as `adapter_windows`. Everything
# `adapter.py`'s header says -- how a role is applied through one
# `OPENCODE_CONFIG_CONTENT` on an opencode of its own (`--standalone`), what
# was measured on opencode 2.0.32 (task 1806), the three things it never
# does -- is true of this file too, and is not repeated here.
#
#     adapter.ps1 inventory '<request>'
#     adapter.ps1 launch '<request>'
#     adapter.ps1 identify '<request>'
#
# **The two outputs are compared byte for byte** by
# `test/opencode-adapter/compare.py`, which feeds both the same requests over
# the same files. What Windows makes different:
#
#   * **Encoding, JSON in, JSON out**: the Codex adapter's helpers, copied
#     below unchanged (from `Set-StrictMode` to `Get-PyBaseName`, and the
#     few after it), so that the ports cannot drift apart on how they read
#     and write. `plugins/codex/adapter.ps1` says why each is the way it is.
#   * **The database is read through `winsqlite3.dll`** (see the section
#     on it below): no PowerShell reads SQLite, and asking opencode itself
#     runs the person's plugins and rewrites their configuration.
#   * **`opencode` from npm is a `.cmd`.** A role's instructions go in as an
#     argument and must not be re-read by `cmd.exe`, so behind npm's
#     `opencode.cmd` this starts what it would (`Resolve-OpencodeCommand`):
#     2.0's `@opencode/cli\bin\opencode.exe` itself, or 1.x's `node.exe` and
#     the `opencode-ai\bin\opencode` script, which picks the right
#     `opencode.exe`. **2.0's layout is read off its `script/publish.ts`,
#     not off a Windows install.**
#   * **`identify` on Windows has no process to read** (`pid` is null), so
#     when this opencode started is when the Polter server it started did
#     (`sidecar_pid`), as `adapter.py` falls back to as well.
#   * **No `HOME`.** `USERPROFILE`.
#
# **ASCII only**, for the reason the Codex adapter gives: Windows PowerShell
# reads a script without a byte-order mark in the system code page.

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


function Get-HomeDir($Req) {
    $h = Get-J $Req 'home'
    if (Test-Truthy $h) { return [string]$h }
    if ($script:OnWindows) { return [string]$env:USERPROFILE }
    return [string]$env:HOME
}

function Get-SortedNames([string]$Dir) {
    try {
        if (-not [System.IO.Directory]::Exists($Dir)) { return , @() }
        $names = @([System.IO.Directory]::GetFileSystemEntries($Dir) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    } catch { return , @() }
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return , $names
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

# --- opencode's own -------------------------------------------------------------

# What the provision puts into the polter entry's `environment`.
$script:AgentMarker = 'POLTER_AGENT_CLI'
$script:Me = 'opencode'
$script:HooksDir = 'polter-hooks'
$script:HooksEntry = 'index.js'
$script:MinVersion = @(2, 0, 0)
$script:VersionTimeoutMs = 10000
$script:SessionWords = @('-s', '--session', '-c', '--continue')
$script:ServerWords = @('--server', '--standalone')
# `session_v2` is 2.0's and the only one this plugin reads; `session` is
# 1.x's own, and 2.x copies its rows across the first time it opens the
# database. See `SESSION_TABLES` in adapter.py.
$script:SessionTables = @('session_v2')
$script:PromptWords = @('--prompt')
$script:StartedSlackMs = 5 * 1000

# `~/.config/opencode`: see `config_home` in adapter.py. On Windows too --
# opencode takes it from `xdg-basedir`, which is the home directory's
# `.config` on every system.
function Get-ConfigHome([string]$HomeDir) {
    return Join-PyPath (Join-PyPath $HomeDir '.config') 'opencode'
}

function Get-DataHome([string]$HomeDir) {
    return Join-PyPath (Join-PyPath (Join-PyPath $HomeDir '.local') 'share') 'opencode'
}

# --- skills (see `skills_in` in adapter.py) ----------------------------------------

# Every `<Dir>/**/SKILL.md`, at any depth, in the order Python's `os.walk`
# gives them with its directory names sorted: a directory before what is
# under it.
function Add-SkillsUnder([string]$Dir, [string]$Source, $Items) {
    $path = Join-PyPath $Dir 'SKILL.md'
    if ([System.IO.File]::Exists($path)) {
        $fm = Read-Frontmatter (Read-TextFile $path)
        $name = $(if ($fm.Contains('name')) { [string]$fm['name'] } else { '' })
        $description = $(if ($fm.Contains('description')) { [string]$fm['description'] } else { '' })
        if ($name.Length -gt 0 -and $description.Length -gt 0) {
            $item = New-Map
            $item['kind'] = 'skill'
            $item['id'] = 'skill:' + $name
            $item['name'] = $name
            $item['description'] = $description
            $item['source'] = $Source
            $Items.Add($item)
        }
    }
    foreach ($entry in (Get-SortedNames $Dir)) {
        $child = Join-PyPath $Dir $entry
        if ([System.IO.Directory]::Exists($child)) { Add-SkillsUnder $child $Source $Items }
    }
}

function Get-SkillDirs([string]$HomeDir, $Cwd) {
    $out = New-List
    $out.Add(@((Join-PyPath (Join-PyPath $HomeDir '.claude') 'skills'), 'user'))
    $out.Add(@((Join-PyPath (Join-PyPath $HomeDir '.agents') 'skills'), 'user'))
    if ($null -ne $Cwd) {
        $out.Add(@((Join-PyPath (Join-PyPath $Cwd '.claude') 'skills'), 'project'))
        $out.Add(@((Join-PyPath (Join-PyPath $Cwd '.agents') 'skills'), 'project'))
    }
    foreach ($sub in @('skill', 'skills')) { $out.Add(@((Join-PyPath (Get-ConfigHome $HomeDir) $sub), 'user')) }
    if ($null -ne $Cwd) {
        foreach ($sub in @('skill', 'skills')) { $out.Add(@((Join-PyPath (Join-PyPath $Cwd '.opencode') $sub), 'project')) }
    }
    return , $out
}

# --- opencode.json (see `read_json` and `servers_from` in adapter.py) -------------

function Read-ConfigObject([string]$Path, $Notes, [string]$Label) {
    $r = Read-JsonFile $Path
    if ($null -ne $r[1]) {
        $Notes.Add("Could not read ${Label}: $($r[1])")
        return , (New-Map)
    }
    if ($null -eq $r[0]) { return , (New-Map) }
    $v = Get-JValue $r[0]
    if (-not (Test-JDict $v)) {
        $Notes.Add("Could not read ${Label}: not a JSON object")
        return , (New-Map)
    }
    return , $v
}

function Get-ServerDetail($Spec) {
    $url = Get-J $Spec 'url'
    if (((Get-J $Spec 'type') -ceq 'remote') -and ($url -is [string]) -and $url.Length -gt 0) {
        $m = [regex]::Match($url, '\A[a-z]+://([^/?#]+)')
        $hostPart = $(if ($m.Success) { $m.Groups[1].Value } else { $url })
        $parts = $hostPart.Split('@')
        return 'http' + $script:Dot + $parts[$parts.Length - 1]
    }
    $command = Get-J $Spec 'command'
    if (Test-JList $command) {
        $first = (Get-JItems $command)
        if ($first.Count -gt 0 -and ($first[0] -is [string])) { return 'stdio' + $script:Dot + (Get-PyBaseName $first[0]) }
    }
    return ''
}

function Get-ServersFrom($Config, [string]$Source) {
    $items = New-List
    $servers = Get-J $Config 'mcp'
    if (-not (Test-JDict $servers)) { return , $items }
    $names = [string[]](Get-JKeys $servers).ToArray()
    [Array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($name in $names) {
        $spec = Get-J $servers $name
        if (-not (Test-JDict $spec)) { continue }
        if ((Get-J $spec 'enabled') -is [bool] -and -not (Get-J $spec 'enabled')) { continue }
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

# --- finding opencode ---------------------------------------------------------------

# What to put in front of the arguments to start opencode, or `$null`. POSIX:
# `opencode`, as `adapter.py` answers. Windows: never a batch shim -- an
# `opencode.exe` on PATH or where the install script puts it, else `node.exe`
# and the `bin/opencode` script npm's `opencode.cmd` runs, which starts the
# right `opencode.exe` itself. A role's instructions are an argument
# (`--prompt`), and `cmd.exe` would re-read their quotes and newlines.
function Resolve-OpencodeCommand {
    $script:ShimFound = $null
    if (-not $script:OnWindows) {
        foreach ($d in ([string]$env:PATH).Split([System.IO.Path]::PathSeparator)) {
            if ($d.Length -gt 0 -and (Test-PosixExecutable (Join-PyPath $d 'opencode'))) { return , @('opencode') }
        }
        $h = [string]$env:HOME
        foreach ($c in @('/opt/homebrew/bin/opencode', '/usr/local/bin/opencode', "$h/.opencode/bin/opencode")) {
            if (Test-PosixExecutable $c) { return , @('opencode') }
        }
        return $null
    }
    $found = @(Get-Command -Name 'opencode' -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($c in $found) {
        $p = [string]$c.Path
        if ($p.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { return , @($p) }
    }
    $installed = Join-PyPath (Join-PyPath (Join-PyPath ([string]$env:USERPROFILE) '.opencode') 'bin') 'opencode.exe'
    if ([System.IO.File]::Exists($installed)) { return , @($installed) }
    $shims = New-List
    foreach ($c in $found) {
        $p = [string]$c.Path
        if ($p.EndsWith('.cmd', [System.StringComparison]::OrdinalIgnoreCase) -or $p.EndsWith('.bat', [System.StringComparison]::OrdinalIgnoreCase)) { $shims.Add($p) }
    }
    if ($env:APPDATA) { $shims.Add((Join-PyPath (Join-PyPath ([string]$env:APPDATA) 'npm') 'opencode.cmd')) }
    foreach ($shim in $shims) {
        if (-not [System.IO.File]::Exists($shim)) { continue }
        $behind = Resolve-OpencodeShim $shim
        if ($null -ne $behind) { return , $behind }
        if ($null -eq $script:ShimFound) { $script:ShimFound = $shim }
    }
    return $null
}

# What an `opencode.cmd` starts, or `$null`: npm's layout beside the shim --
# 2.0's `node_modules\@opencode\cli\bin\opencode.exe`, which npm runs as it
# is, else 1.x's `node.exe` and `node_modules\opencode-ai\bin\opencode`.
function Resolve-OpencodeShim([string]$Shim) {
    $dir = [System.IO.Path]::GetDirectoryName($Shim)
    $exe = Join-PyPath $dir 'node_modules\@opencode\cli\bin\opencode.exe'
    if ([System.IO.File]::Exists($exe)) { return , @($exe) }
    $script = Join-PyPath $dir 'node_modules\opencode-ai\bin\opencode'
    if (-not [System.IO.File]::Exists($script)) { return $null }
    $node = Join-PyPath $dir 'node.exe'
    if (-not [System.IO.File]::Exists($node)) {
        $node = $null
        foreach ($n in @(Get-Command -Name 'node' -CommandType Application -All -ErrorAction SilentlyContinue)) {
            if (([string]$n.Path).EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { $node = [string]$n.Path; break }
        }
    }
    if ($null -eq $node) { return $null }
    return , @($node, $script)
}

# `opencode --version` as three numbers, or `$null`. With the models fetch
# off: see `version_of` in adapter.py (task 1781).
function Get-OpencodeVersion($Start) {
    if ($null -eq $Start) { return $null }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $first = [string]$Start[0]
        if (-not $script:OnWindows -and $first -ceq 'opencode') {
            foreach ($d in ([string]$env:PATH).Split([System.IO.Path]::PathSeparator)) {
                if ($d.Length -gt 0 -and (Test-PosixExecutable (Join-PyPath $d 'opencode'))) { $first = Join-PyPath $d 'opencode'; break }
            }
        }
        $psi.FileName = $first
        $rest = New-List
        for ($i = 1; $i -lt $Start.Count; $i++) { $rest.Add([string]$Start[$i]) }
        $rest.Add('--version')
        Set-StartArguments $psi $rest
        $psi.EnvironmentVariables['OPENCODE_DISABLE_MODELS_FETCH'] = '1'
        $psi.EnvironmentVariables['OPENCODE_DISABLE_AUTOUPDATE'] = '1'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $null = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($script:VersionTimeoutMs)) {
            try { $p.Kill() } catch { }
            return $null
        }
        if ($p.ExitCode -ne 0) { return $null }
        $m = [regex]::Match($outTask.Result, '(\d+)\.(\d+)\.(\d+)')
        if (-not $m.Success) { return $null }
        return , @([long]$m.Groups[1].Value, [long]$m.Groups[2].Value, [long]$m.Groups[3].Value)
    } catch {
        return $null
    }
}

function Test-OlderThan($Version, $Min) {
    for ($i = 0; $i -lt 3; $i++) {
        if ($Version[$i] -lt $Min[$i]) { return $true }
        if ($Version[$i] -gt $Min[$i]) { return $false }
    }
    return $false
}

# --- opencode's database, read-only ---------------------------------------------------
#
# **No PowerShell can read SQLite, and opencode keeps its sessions there**
# (`~/.local/share/opencode/opencode.db`). Asking opencode is no way round it:
# `opencode session list` loads opencode whole -- it runs the person's
# plugins, installs packages from npm and rewrites their configuration
# (measured, task 1781). So this reads the file itself, through the SQLite
# Windows ships as a system library, `winsqlite3.dll` (Windows 10 1607 and
# later), opened read-only. Off Windows the same code is handed the
# system's `libsqlite3`, so the port can be compared with `adapter.py` on a
# Mac. A library that is not there or will not open the file is no rows --
# no session named, none gone on with -- never a guess.

$script:SqliteSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class __CLASS__ {
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_close_v2(IntPtr db);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_bind_text(IntPtr stmt, int i, byte[] text, int n, IntPtr destructor);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_bind_int64(IntPtr stmt, int i, long v);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_column_type(IntPtr stmt, int i);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern long sqlite3_column_int64(IntPtr stmt, int i);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_column_bytes(IntPtr stmt, int i);
    [DllImport("__DLL__", CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_finalize(IntPtr stmt);

    static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

    // Rows, each an object[] of long, string or null; null when the file
    // cannot be opened read-only or the query cannot be run.
    public static List<object[]> Query(string path, string sql, object[] args) {
        IntPtr db;
        // SQLITE_OPEN_READONLY
        if (sqlite3_open_v2(Z(path), out db, 1, IntPtr.Zero) != 0) {
            if (db != IntPtr.Zero) sqlite3_close_v2(db);
            return null;
        }
        try {
            sqlite3_busy_timeout(db, 2000);
            IntPtr stmt;
            byte[] q = Z(sql);
            if (sqlite3_prepare_v2(db, q, q.Length, out stmt, IntPtr.Zero) != 0) return null;
            try {
                for (int i = 0; i < args.Length; i++) {
                    object a = args[i];
                    if (a is string) {
                        byte[] t = Encoding.UTF8.GetBytes((string)a);
                        // SQLITE_TRANSIENT: sqlite copies it.
                        sqlite3_bind_text(stmt, i + 1, t, t.Length, new IntPtr(-1));
                    } else {
                        sqlite3_bind_int64(stmt, i + 1, Convert.ToInt64(a));
                    }
                }
                List<object[]> rows = new List<object[]>();
                while (true) {
                    int rc = sqlite3_step(stmt);
                    // SQLITE_DONE
                    if (rc == 101) break;
                    // SQLITE_ROW
                    if (rc != 100) return null;
                    int n = sqlite3_column_count(stmt);
                    object[] row = new object[n];
                    for (int c = 0; c < n; c++) {
                        int type = sqlite3_column_type(stmt, c);
                        if (type == 1) {
                            row[c] = sqlite3_column_int64(stmt, c);
                        } else if (type == 5) {
                            row[c] = null;
                        } else {
                            IntPtr p = sqlite3_column_text(stmt, c);
                            int len = sqlite3_column_bytes(stmt, c);
                            byte[] buf = new byte[len];
                            if (len > 0) Marshal.Copy(p, buf, 0, len);
                            row[c] = Encoding.UTF8.GetString(buf);
                        }
                    }
                    rows.Add(row);
                }
                return rows;
            } finally {
                sqlite3_finalize(stmt);
            }
        } finally {
            sqlite3_close_v2(db);
        }
    }
}
'@

$script:SqliteClass = $null
$script:SqliteTried = $false

# The class that reads the database, or `$null` when this system's SQLite
# cannot be loaded. Compiled once.
function Get-Sqlite {
    if ($script:SqliteTried) { return $script:SqliteClass }
    $script:SqliteTried = $true
    if ($script:OnWindows) {
        $dll = 'winsqlite3'
    } elseif ([System.IO.File]::Exists('/proc/self/exe')) {
        $dll = 'libsqlite3.so.0'
    } else {
        $dll = '/usr/lib/libsqlite3.dylib'
    }
    $name = 'PolterOpencodeSqlite' + [Math]::Abs($dll.GetHashCode())
    try {
        $type = ($name -as [type])
        if ($null -eq $type) {
            Add-Type -TypeDefinition ($script:SqliteSource.Replace('__CLASS__', $name).Replace('__DLL__', $dll)) -Language CSharp
            $type = ($name -as [type])
        }
        $script:SqliteClass = $type
    } catch {
        $script:SqliteClass = $null
    }
    return $script:SqliteClass
}

# See `session_rows` in adapter.py: `{t}` in `$Sql` is the first of
# `SessionTables` the database has.
function Get-SessionRows([string]$HomeDir, [string]$Sql, $ArgList) {
    $path = Join-PyPath (Get-DataHome $HomeDir) 'opencode.db'
    if (-not [System.IO.File]::Exists($path)) { return $null }
    $type = Get-Sqlite
    if ($null -eq $type) { return $null }
    try {
        $have = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in $type::Query($path, "select name from sqlite_master where type = 'table'", [object[]]@())) { [void]$have.Add([string]$r[0]) }
        $table = $null
        foreach ($t in $script:SessionTables) { if ($have.Contains($t)) { $table = $t; break } }
        if ($null -eq $table) { return $null }
        $rows = $type::Query($path, $Sql.Replace('{t}', $table), [object[]]$ArgList)
    } catch {
        return $null
    }
    if ($null -eq $rows) { return $null }
    return , $rows
}

# --- the three questions --------------------------------------------------------

function Get-Gathered($Req) {
    $homeDir = Get-HomeDir $Req
    $c = Get-J $Req 'cwd'
    $cwd = $(if (Test-Truthy $c) { [string]$c } else { $null })
    $notes = New-List
    $items = New-List
    foreach ($d in (Get-SkillDirs $homeDir $cwd)) { Add-SkillsUnder $d[0] $d[1] $items }
    $files = New-List
    $files.Add(@((Join-PyPath (Get-ConfigHome $homeDir) 'opencode.json'), 'user', 'opencode.json'))
    if ($null -ne $cwd) { $files.Add(@((Join-PyPath $cwd 'opencode.json'), 'project', 'opencode.json (project)')) }
    foreach ($f in $files) {
        foreach ($i in (Get-ServersFrom (Read-ConfigObject $f[0] $notes $f[2]) $f[1])) { $items.Add($i) }
    }
    $jsoncs = New-List
    $jsoncs.Add((Join-PyPath (Get-ConfigHome $homeDir) 'opencode.jsonc'))
    if ($null -ne $cwd) { $jsoncs.Add((Join-PyPath $cwd 'opencode.jsonc')) }
    foreach ($j in $jsoncs) {
        if ([System.IO.File]::Exists($j)) {
            $notes.Add("$j is not read: its MCP servers are not listed, and a role cannot switch them off.")
        }
    }
    return @($items, $notes)
}

# See `unique_items` in adapter.py.
function Get-UniqueItems($Items) {
    $at = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $out = New-List
    foreach ($item in $Items) {
        $id = [string]$item['id']
        if (-not $at.ContainsKey($id)) {
            $at[$id] = $out.Count
            $out.Add($item)
        } elseif (([string]$item['kind'] -ceq 'skill') -or (([string]$item['source'] -ceq 'project') -and -not ([string]$out[$at[$id]]['source'] -ceq 'project'))) {
            $out[$at[$id]] = $item
        }
    }
    return , $out
}

# Whether the opencode on this machine is one this plugin starts: see
# `serves_here` in adapter.py. **`installed` and `serves` are two answers**:
# no program is `installed`'s to say, and a version that could not be read is
# not knowing rather than knowing it is wrong.
function Test-ServesHere($Start, $Version) {
    if ($null -eq $Start -or $null -eq $Version) { return $true }
    return -not (Test-OlderThan $Version $script:MinVersion)
}

function Get-Inventory($Req) {
    $g = Get-Gathered $Req
    $answer = New-Map
    $answer['version'] = $ContractVersion
    # WARNING: **This runs `opencode --version`**, which the inventory did not use
    # to -- the price of `serves`, and the same call `launch` makes:
    # autoupdate and the models fetch off, no session and no service started.
    $start = Resolve-OpencodeCommand
    $version = Get-OpencodeVersion $start
    $serves = Test-ServesHere $start $version
    if (($null -ne $start) -and (-not $serves)) {
        $g[1].Add("opencode $($version -join '.') is on this machine, and this plugin starts $($script:MinVersion -join '.') and later only. The plugin for the version that is here is the one that serves it.")
    }
    $answer['installed'] = $null -ne $start
    $answer['serves'] = $serves
    $answer['resume'] = $true
    $answer['options'] = New-List
    $answer['items'] = Get-UniqueItems $g[0]
    $answer['notes'] = $g[1]
    return , $answer
}

function Test-Enabled($Selection, [string]$Id) {
    $d = Get-J $Selection 'default'
    $default = -not (($d -is [bool]) -and -not $d)
    $except = Get-J $Selection 'except'
    $listed = $false
    if (Test-JList $except) { foreach ($e in (Get-JItems $except)) { if (($e -is [string]) -and $e -ceq $Id) { $listed = $true } } }
    return $default -ne $listed
}

function Get-ToolPrefix([string]$Server) {
    return [regex]::Replace($Server, '[^a-zA-Z0-9_-]', '_') + '_'
}

function Get-HooksPath {
    return Join-PyPath $PSScriptRoot $script:HooksDir
}

# A `file://` URL, written the way `adapter.py` writes it: `file://`, then
# the path with every byte but letters, digits, `_.-~` and `/` as `%XX` of
# its UTF-8 (Python's `urllib.parse.quote`). On Windows the path is first
# written with forward slashes and a leading one (`/C:/...`), which is how
# opencode's `import()` reads a Windows path in a URL.
function ConvertTo-FileUrl([string]$Path) {
    $p = $Path
    if ($script:OnWindows) { $p = '/' + $p.Replace('\', '/') }
    $b = New-Object System.Text.StringBuilder
    foreach ($byte in $script:Utf8.GetBytes($p)) {
        $ch = [char]$byte
        if (($byte -ge 0x30 -and $byte -le 0x39) -or ($byte -ge 0x41 -and $byte -le 0x5A) -or ($byte -ge 0x61 -and $byte -le 0x7A) -or
            ('_.-~/:'.IndexOf($ch) -ge 0 -and ($ch -ne ':' -or $script:OnWindows))) {
            [void]$b.Append($ch)
        } else {
            [void]$b.Append('%{0:X2}' -f $byte)
        }
    }
    return 'file://' + $b.ToString()
}

function Get-HooksReady($Polter, $Version, $Notes) {
    if (-not (($Polter -is [string]) -and $Polter.Length -gt 0)) {
        $Notes.Add('No Polter path in the request, so opencode is started without Polter''s hooks.')
        return $false
    }
    if (-not [System.IO.File]::Exists((Join-PyPath (Get-HooksPath) $script:HooksEntry))) {
        $Notes.Add("Polter's opencode plugin ($($script:HooksDir)) is missing, so opencode is started without its hooks.")
        return $false
    }
    if ($null -eq $Version) {
        $Notes.Add('Could not read opencode''s version, so it is started without Polter''s hooks.')
        return $false
    }
    if (Test-OlderThan $Version $script:MinVersion) {
        $Notes.Add("opencode $($Version -join '.') is older than $($script:MinVersion -join '.'), the first Polter's hooks were measured on; started without them.")
        return $false
    }
    return $true
}

function Get-SessionToResume($Req, $Extra, $Notes) {
    $session = Get-J $Req 'session'
    if ($null -eq $session) { return $null }
    foreach ($a in $Extra) {
        if (($script:SessionWords -ccontains $a) -or $a.StartsWith('--session=', $script:Ordinal)) {
            $Notes.Add("The role's own arguments choose a session; session $(Get-PyPercentS $session) was left out.")
            return $null
        }
    }
    if (-not (($session -is [string]) -and [regex]::IsMatch($session, '\Ases_[A-Za-z0-9]+\z'))) {
        $Notes.Add("$(Get-PyPercentS $session) is not an opencode session id; starting a new one.")
        return $null
    }
    $rows = Get-SessionRows (Get-HomeDir $Req) 'select id from {t} where id = ?' @($session)
    if ($null -eq $rows) {
        $Notes.Add("opencode's sessions could not be read; starting a new session instead of $session.")
        return $null
    }
    if ($rows.Count -eq 0) {
        $Notes.Add("Session $session is not on this machine any more; starting a new one.")
        return $null
    }
    return $session
}

# What Python's `"%s" % v` writes for a JSON value.
function Get-PyPercentS($v) {
    if ($null -eq $v) { return 'None' }
    if ($v -is [bool]) { return $(if ($v) { 'True' } else { 'False' }) }
    if ($v -is [string]) { return $v }
    return ConvertTo-PyJson $v
}

# `json.dumps(v, ensure_ascii=False, separators=(",", ":"))`.
function ConvertTo-CompactJson($v) {
    $sb = New-Object System.Text.StringBuilder
    Write-CompactJson $sb $v
    return $sb.ToString()
}

function Write-CompactJson([System.Text.StringBuilder]$Sb, $v) {
    if ($null -eq $v) { [void]$Sb.Append('null'); return }
    if ($v -is [bool]) { [void]$Sb.Append($(if ($v) { 'true' } else { 'false' })); return }
    if ($v -is [string]) { [void]$Sb.Append((ConvertTo-PyString $v)); return }
    if (Test-JDict $v) {
        [void]$Sb.Append('{')
        $first = $true
        foreach ($k in (Get-JKeys $v)) {
            if (-not $first) { [void]$Sb.Append(',') }
            $first = $false
            [void]$Sb.Append((ConvertTo-PyString $k)).Append(':')
            Write-CompactJson $Sb (Get-J $v $k)
        }
        [void]$Sb.Append('}')
        return
    }
    if (Test-JList $v) {
        [void]$Sb.Append('[')
        $first = $true
        foreach ($e in (Get-JItems $v)) {
            if (-not $first) { [void]$Sb.Append(',') }
            $first = $false
            Write-CompactJson $Sb $e
        }
        [void]$Sb.Append(']')
        return
    }
    [void]$Sb.Append((ConvertTo-PyString ([string]$v)))
}

function Get-Launch($Req) {
    $role = Get-J $Req 'role'
    if (-not (Test-Truthy $role)) { $role = New-Map }
    $cli = Get-J $Req 'cli'
    if (-not (Test-Truthy $cli)) { $cli = New-Map }
    $g = Get-Gathered $Req
    $items = $g[0]; $notes = $g[1]

    $projectIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $items) { if ([string]$item['source'] -ceq 'project') { [void]$projectIds.Add([string]$item['id']) } }
    $permission = New-Map
    $permission[(Get-ToolPrefix $PolterServer) + '*'] = 'allow'
    $skillsOff = New-Map
    $serversOff = 0
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in (Get-UniqueItems $items)) {
        $id = [string]$item['id']
        if (($item.Contains('locked') -and $item['locked']) -or $projectIds.Contains($id) -or $seen.Contains($id)) { continue }
        [void]$seen.Add($id)
        $kind = [string]$item['kind']
        $selection = Get-J $cli $(if ($kind -ceq 'skill') { 'skills' } else { 'mcp' })
        if (-not (Test-Truthy $selection)) { $selection = New-Map }
        if (Test-Enabled $selection $id) { continue }
        if ($kind -ceq 'skill') {
            $skillsOff[[string]$item['name']] = 'deny'
        } else {
            $permission[(Get-ToolPrefix ([string]$item['name'])) + '*'] = 'deny'
            $serversOff += 1
        }
    }
    if ($skillsOff.Count -gt 0) { $permission['skill'] = $skillsOff }

    $extra = New-List
    $args0 = Get-J $cli 'args'
    if (Test-JList $args0) { foreach ($a in (Get-JItems $args0)) { if ($a -is [string]) { $extra.Add($a) } } }

    $start = Resolve-OpencodeCommand
    if ($null -eq $start -and $script:OnWindows -and $null -ne $script:ShimFound) {
        throw "found $($script:ShimFound), but not the program it starts (no @opencode\cli\bin\opencode.exe, or opencode-ai\bin\opencode with a node.exe to run it, behind it). A batch file is not given a role's instructions: cmd.exe would re-read their quotes and newlines."
    }
    $version = Get-OpencodeVersion $start
    # See `launch` in adapter.py: one set of flags, and no version branch.
    # `--standalone` is 2.x's and the model goes in the configuration (2.0
    # has no `-m`). 1.x, the other plugin's, is what refuses `--standalone`
    # and takes `-m`; a machine running it is answered by the inventory's
    # `serves: false`, and `Get-HooksReady` is what a launch that got here
    # anyway is left with.

    $opts = New-List
    $names = $false
    foreach ($a in $extra) { if (($script:ServerWords -ccontains $a) -or $a.StartsWith('--server=', $script:Ordinal)) { $names = $true } }
    if ($names) {
        $notes.Add("The role's own arguments choose opencode's server; it is not started --standalone, so a shared server's configuration and hooks are that server's.")
    } else {
        $opts.Add('--standalone')
    }
    $model = Get-J $cli 'model'
    if (-not (Test-Truthy $model)) { $model = Get-J $role 'model' }
    $session = Get-SessionToResume $Req $extra $notes
    if ($null -ne $session) { $opts.Add('-s'); $opts.Add($session) }

    $instructions = Get-J $role 'instructions'
    if (($instructions -is [string]) -and $instructions.Trim().Length -gt 0) {
        $gives = $false
        foreach ($a in $extra) { if (($script:PromptWords -ccontains $a) -or $a.StartsWith('--prompt=', $script:Ordinal)) { $gives = $true } }
        if ($null -ne $session) {
            $notes.Add('Going on with a session: the role''s instructions are already in it, so they are not sent again.')
        } elseif ($gives) {
            $notes.Add('The role''s own arguments give a first prompt; the role''s instructions are not sent.')
        } else {
            $opts.Add('--prompt')
            $opts.Add($instructions)
        }
    }

    $polter = Get-J $Req 'polter'
    $hooks = Get-HooksReady $polter $version $notes

    $content = New-Map
    $content['$schema'] = 'https://opencode.ai/config.json'
    $content['permission'] = $permission
    if (Test-Truthy $model) { $content['model'] = $model }
    $envOut = New-Map
    $envOut['OPENCODE_DISABLE_AUTOUPDATE'] = '1'
    if ($hooks) {
        $content['plugin'] = @(ConvertTo-FileUrl (Get-HooksPath))
        $envOut['POLTER_HOOK_EXE'] = [string]$polter
    }
    $envOut['OPENCODE_CONFIG_CONTENT'] = ConvertTo-CompactJson $content

    $argv = New-List
    if ($null -eq $start) { $argv.Add('opencode') } else { foreach ($s in $start) { $argv.Add($s) } }
    foreach ($o in $opts) { $argv.Add($o) }
    foreach ($e in $extra) { $argv.Add($e) }

    $answer = New-Map
    $answer['version'] = $ContractVersion
    $answer['argv'] = $argv
    $answer['env'] = $envOut
    if ($skillsOff.Count -eq 0 -and $serversOff -eq 0) {
        $answer['summary'] = 'nothing switched off'
    } else {
        $answer['summary'] = "$($skillsOff.Count) skill(s) and $serversOff MCP server(s) switched off"
    }
    $answer['notes'] = $notes
    if ($hooks) {
        $answer['hooks'] = $true
        $answer['hooks_heard'] = 'first_turn'
    }
    return , $answer
}

# --- identify (see `identify` in adapter.py) -----------------------------------

function Test-IsOpencode($Path) {
    if ($null -eq $Path) { return $false }
    $name = (Get-PyBaseName ([string]$Path)).ToLowerInvariant()
    return ($name -ceq 'opencode') -or ($name -ceq 'opencode.exe')
}

# `@(session, updated, note)`: see `by_directory` in adapter.py.
function Get-ByDirectory([string]$HomeDir, [string]$Cwd, [long]$SinceMs) {
    $rows = Get-SessionRows $HomeDir 'select id, time_updated from {t} where directory = ? and parent_id is null and time_created >= ? order by time_created' @($Cwd, [long]($SinceMs - $script:StartedSlackMs))
    if ($null -eq $rows) { return @($null, $null, 'opencode''s sessions could not be read.') }
    if ($rows.Count -eq 0) {
        return @($null, $null, 'No opencode session in this directory began after this opencode started (a session is made with its first message, or this one goes on with an older one).')
    }
    if ($rows.Count -gt 1) {
        return @($null, $null, "$($rows.Count) opencode sessions in this directory began after this opencode started, so which is this one is not known.")
    }
    return @($rows[0][0], $rows[0][1], 'Named by directory and start.')
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

    $answer = New-Map
    $answer['version'] = 1
    $marker = Get-J $envIn $script:AgentMarker
    if ($null -ne $marker) {
        $me = $marker -ceq $script:Me
    } else {
        $me = ($null -ne $procId) -and (Test-IsOpencode (Get-ExeOf $procId))
    }
    $answer['me'] = [bool]$me
    $notes = New-List
    if (-not $me) {
        $answer['session'] = $null
        $answer['session_written_ms'] = $null
        $answer['quit'] = $null
        $answer['notes'] = $notes
        return $answer
    }
    $session = $null
    $written = $null
    if ($null -eq $procId -and $null -eq $sidecar) {
        $notes.Add('No process to look at, so its session is not known.')
    } elseif ($null -eq $cwd) {
        $notes.Add('No directory to look for its session in, so it is not known.')
    } else {
        $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $since = Get-StartedMs $(if ($null -ne $procId) { $procId } else { $sidecar }) $now
        if ($null -eq $since) {
            $notes.Add('When this opencode started could not be read, so its session is not named.')
        } else {
            $r = Get-ByDirectory (Get-HomeDir $Req) $cwd $since
            $session = $r[0]
            $written = $r[1]
            $notes.Add($r[2])
        }
    }
    $answer['session'] = $session
    $answer['session_written_ms'] = $written
    $answer['quit'] = $null
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
