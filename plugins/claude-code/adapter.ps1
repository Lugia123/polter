# The Claude Code adapter, for Windows: what a role can pick from, and how to
# start it.
#
# **A port of `adapter.py` beside it, item for item, and not a second design.**
# Windows will not run a `.py` (`Plugin.zig`'s `launchKindFor` says so at load),
# and Polter on Windows has no Python to lean on, so the manifest names this
# file as `adapter_windows`. Everything `adapter.py`'s header says -- the
# contract in `dev-docs/poltergeist/roles.md` part eleven, the three things it
# never does (write a file, read an `env` block, run `claude`), and which flag
# switches off which kind of thing -- is true of this file too, and is not
# repeated here. What is here is what Windows makes different.
#
#     adapter.ps1 inventory '<request>'
#     adapter.ps1 launch '<request>'
#
# **The two outputs are compared byte for byte.** `test/claude-code-adapter/`
# feeds both adapters the same requests over the same files and diffs the
# JSON; the few fields that are allowed to differ by platform are listed
# there, with the reason for each. A change to one adapter that is not made
# to the other shows up there, not in a role that behaves differently on one
# system.
#
# What Windows makes different, each one measured or reported from the test
# machine rather than assumed:
#
#   * **Encoding.** Windows PowerShell 5.1 talks to other programs in the OEM
#     code page unless told otherwise, so a Chinese role name or instruction
#     arrives or leaves as `?`. Both ends are raw streams with UTF-8 and no
#     byte-order mark -- the same fix `_sdk/provision.ps1` carries, for the
#     same reason.
#   * **`claude` is usually a `.cmd`.** npm installs `claude.cmd`, a batch
#     shim, and a batch file is not something to hand a command line full of
#     quotes, newlines and `&` to: `cmd.exe` would re-read every one of them.
#     So `argv[0]` is the real executable, found through the shim -- see
#     `Resolve-ClaudeCommand`. Where nothing runnable can be found behind it,
#     `launch` refuses with the reason rather than guessing.
#   * **No `HOME`.** A request without one falls back to `USERPROFILE`, as
#     roles.md 11.8 records.
#
# **JSON is read with .NET, not `ConvertFrom-Json`.** `ConvertFrom-Json` in
# 5.1 builds `PSCustomObject`s, which refuse two keys differing only in case
# and throw on the whole file; `~/.claude.json` is somebody's entire setup and
# a few megabytes, and one odd key must not make every MCP server vanish. The
# desktop edition's `JavaScriptSerializer` and the core edition's
# `System.Text.Json` both keep keys exactly, and both read megabytes without
# walking them in script. Written out by hand in `ConvertTo-PyJson`, because
# the answer has to be byte-identical to Python's `json.dumps`.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ContractVersion = 1
# The server Polter registers for itself. A role that took it away would be a
# terminal that cannot report back.
$PolterServer = 'polter'
# Largest file this will read. `~/.claude.json` is the big one.
$MaxBytes = 8 * 1024 * 1024
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
        $fs = [System.IO.File]::OpenRead($Path)
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

function Get-SortedNames([string]$Dir) {
    try {
        if (-not [System.IO.Directory]::Exists($Dir)) { return , @() }
        $names = @([System.IO.Directory]::GetFileSystemEntries($Dir) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    } catch { return , @() }
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return , $names
}

function Get-SkillsIn([string]$Dir, [string]$Source, [string]$Prefix = '') {
    $items = New-List
    foreach ($entry in (Get-SortedNames $Dir)) {
        if ($entry.StartsWith('.', $script:Ordinal)) { continue }
        $text = Read-TextFile (Join-PyPath (Join-PyPath $Dir $entry) 'SKILL.md')
        if ($null -eq $text) { continue }
        $fm = Read-Frontmatter $text
        $own = $(if ($fm.Contains('name') -and $fm['name'].Length -gt 0) { $fm['name'] } else { $entry })
        $name = $Prefix + $own
        $item = New-Map
        $item['kind'] = 'skill'
        $item['id'] = 'skill:' + $name
        $item['name'] = $name
        $item['description'] = $(if ($fm.Contains('description')) { $fm['description'] } else { '' })
        $item['source'] = $Source
        $items.Add($item)
    }
    return , $items
}

# --- MCP servers --------------------------------------------------------------

# What Claude Code puts between `mcp__` and `__`. A character outside the
# ASCII set becomes one `_` -- one for a code point, so a surrogate pair is
# matched whole rather than as the two halves .NET would otherwise see.
function Get-ToolPrefixName([string]$Name) {
    [regex]::Replace($Name, '[\uD800-\uDBFF][\uDC00-\uDFFF]|[^A-Za-z0-9_-]', '_')
}

# `os.path.basename`, as the platform's Python has it: `/` alone on POSIX,
# `/`, `\` and a drive on Windows.
function Get-PyBaseName([string]$Path) {
    if ($script:OnWindows) {
        if ($Path.Length -ge 2 -and $Path[1] -ceq ':') { $Path = $Path.Substring(2) }
        $i = $Path.LastIndexOfAny([char[]]@('/', '\'))
    } else {
        $i = $Path.LastIndexOf('/')
    }
    return $Path.Substring($i + 1)
}

# Python's `str()` of a JSON scalar, for the one place a value is formatted
# with `%s`.
function Get-PyStr($v) {
    if ($v -is [bool]) { return $(if ($v) { 'True' } else { 'False' }) }
    if ($v -is [string]) { return $v }
    return ConvertTo-PyJson $v
}

# How a server is reached, in words, with nothing secret in them.
function Get-ServerDetail($Spec) {
    if (-not (Test-JDict $Spec)) { return '' }
    $url = Get-J $Spec 'url'
    if (-not (Test-Truthy $url)) { $url = Get-J $Spec 'httpUrl' }
    if ($url -is [string] -and $url.Length -gt 0) {
        $m = [regex]::Match($url, '^[a-z]+://([^/?#]+)')
        $h = $(if ($m.Success) { $m.Groups[1].Value } else { $url })
        $h = $h.Split('@')[-1]
        $type = Get-J $Spec 'type'
        $t = $(if (Test-Truthy $type) { Get-PyStr $type } else { 'http' })
        return $t + $script:Dot + $h
    }
    $command = Get-J $Spec 'command'
    if ($command -is [string] -and $command.Length -gt 0) {
        return 'stdio' + $script:Dot + (Get-PyBaseName $command)
    }
    return ''
}

function Get-ServersFrom($Block, [string]$Source, [string]$Prefix = '', [string]$Description = '') {
    $items = New-List
    if (-not (Test-JDict $Block)) { return , $items }
    $names = (Get-JKeys $Block).ToArray()
    [Array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($name in $names) {
        $wire = Get-ToolPrefixName ($Prefix + $name)
        $item = New-Map
        $item['kind'] = 'mcp'
        $item['id'] = 'mcp:' + $wire
        $item['name'] = $name
        $item['description'] = $Description
        $item['detail'] = Get-ServerDetail (Get-J $Block $name)
        $item['source'] = $Source
        $item['locked'] = $wire -ceq $PolterServer
        $items.Add($item)
    }
    return , $items
}

# --- plugins ------------------------------------------------------------------

# `name@marketplace` -> install path, for the plugins switched on.
function Get-EnabledPlugins([string]$HomeDir, $Cwd, $Notes) {
    $r = Read-JsonFile (Join-PyPath (Join-PyPath $HomeDir '.claude') 'settings.json')
    if ($null -ne $r[1]) { $Notes.Add('Could not read ~/.claude/settings.json: ' + $r[1]) }
    $enabled = New-Map
    $ep = Get-J $r[0] 'enabledPlugins'
    if (Test-JDict $ep) { foreach ($k in (Get-JKeys $ep)) { $enabled[$k] = Get-J $ep $k } }
    if ($null -ne $Cwd) {
        foreach ($local in @('settings.json', 'settings.local.json')) {
            $p = (Read-JsonFile (Join-PyPath (Join-PyPath $Cwd '.claude') $local))[0]
            $ep = Get-J $p 'enabledPlugins'
            if (Test-JDict $ep) { foreach ($k in (Get-JKeys $ep)) { $enabled[$k] = Get-J $ep $k } }
        }
    }

    $r = Read-JsonFile (Join-PyPath (Join-PyPath (Join-PyPath $HomeDir '.claude') 'plugins') 'installed_plugins.json')
    if ($null -ne $r[1]) { $Notes.Add('Could not read the installed plugin list: ' + $r[1]) }
    $out = New-Map
    $plugins = Get-J $r[0] 'plugins'
    if (-not (Test-JDict $plugins)) { return , $out }
    foreach ($key in (Get-JKeys $plugins)) {
        $entries = Get-J $plugins $key
        $on = $(if ($enabled.Contains($key)) { $enabled[$key] } else { $null })
        if (-not ($on -is [bool] -and $on) -or -not (Test-JList $entries)) { continue }
        # The user-scope entry, or the one for this project: the one this
        # session would load. The last that matches, as the original.
        $chosen = $null
        foreach ($e in (Get-JItems $entries)) {
            if (-not (Test-JDict $e)) { continue }
            $scope = Get-J $e 'scope'
            $pp = Get-J $e 'projectPath'
            if (($scope -is [string] -and $scope -ceq 'user') -or ($null -ne $Cwd -and $pp -is [string] -and $pp -ceq $Cwd)) {
                $chosen = $e
            }
        }
        if ($null -ne $chosen) {
            $ip = Get-J $chosen 'installPath'
            if ($ip -is [string]) { $out[$key] = $ip }
        }
    }
    return , $out
}

function Get-PluginItems([string]$Key, [string]$Path) {
    $name = $Key.Split([char[]]@('@'), 2)[0]
    $manifest = (Read-JsonFile (Join-PyPath (Join-PyPath $Path '.claude-plugin') 'plugin.json'))[0]
    if (-not (Test-JDict $manifest)) { $manifest = New-Map }
    $d = Get-J $manifest 'description'
    $about = $(if ($d -is [string]) { $d } else { '' })
    $source = 'plugin:' + $name

    $items = Get-SkillsIn (Join-PyPath $Path 'skills') $source ($name + ':')

    $servers = Get-J $manifest 'mcpServers'
    if ($servers -is [string]) { $servers = (Read-JsonFile (Join-PyPath $Path $servers))[0] }
    if (-not (Test-JDict $servers)) {
        $mcpJson = (Read-JsonFile (Join-PyPath $Path '.mcp.json'))[0]
        if (Test-JDict $mcpJson) {
            $servers = $(if (Test-JHas $mcpJson 'mcpServers') { Get-J $mcpJson 'mcpServers' } else { $mcpJson })
        }
    }
    foreach ($s in (Get-ServersFrom $servers $source ('plugin_' + $name + '_') $about)) { $items.Add($s) }

    foreach ($item in $items) {
        $item['group'] = $name
        $item['group_description'] = $about
    }
    return , $items
}

# --- finding claude -----------------------------------------------------------

# What to put in front of the arguments to start Claude Code, or `$null`.
#
# **POSIX: `claude`**, exactly as `adapter.py` answers, found the same way.
#
# **Windows: the real program, never the batch shim.** In order:
#
#   1. `claude.exe` on `PATH` (the native installer's).
#   2. `claude.cmd` / `claude.bat` on `PATH`, and what it runs. npm's shim
#      starts `node_modules\@anthropic-ai\claude-code\...` next to itself;
#      recent packages carry `bin\claude.exe` there, older ones a `cli.js` for
#      `node`. The shim's own text is read for the path rather than the
#      layout assumed, and the layout is tried after it.
#   3. The places those installers use when `PATH` does not have them.
#
# **A shim with nothing runnable behind it is not an answer.** Handing
# `cmd.exe` an instruction with a newline, a quote or an `&` in it would have
# it re-read as batch syntax, so `launch` says what it found and stops.
function Resolve-ClaudeCommand {
    if (-not $script:OnWindows) {
        foreach ($d in ([string]$env:PATH).Split([System.IO.Path]::PathSeparator)) {
            if ($d.Length -gt 0 -and (Test-PosixExecutable (Join-PyPath $d 'claude'))) { return , @('claude') }
        }
        $h = [string]$env:HOME
        foreach ($c in @("$h/.local/bin/claude", "$h/.claude/local/claude", '/opt/homebrew/bin/claude', '/usr/local/bin/claude')) {
            if (Test-PosixExecutable $c) { return , @('claude') }
        }
        return $null
    }

    $script:ShimFound = $null
    $found = @(Get-Command -Name 'claude' -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($c in $found) {
        $p = [string]$c.Path
        if ($p.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { return , @($p) }
    }
    foreach ($c in $found) {
        $p = [string]$c.Path
        if ($p.EndsWith('.cmd', [System.StringComparison]::OrdinalIgnoreCase) -or $p.EndsWith('.bat', [System.StringComparison]::OrdinalIgnoreCase)) {
            $behind = Resolve-Shim $p
            if ($null -ne $behind) { return , $behind }
            if ($null -eq $script:ShimFound) { $script:ShimFound = $p }
        }
    }
    $native = Join-PyPath (Join-PyPath (Join-PyPath ([string]$env:USERPROFILE) '.local') 'bin') 'claude.exe'
    if ([System.IO.File]::Exists($native)) { return , @($native) }
    if ($env:APPDATA) {
        $shim = Join-PyPath (Join-PyPath ([string]$env:APPDATA) 'npm') 'claude.cmd'
        if ([System.IO.File]::Exists($shim)) {
            $behind = Resolve-Shim $shim
            if ($null -ne $behind) { return , $behind }
            if ($null -eq $script:ShimFound) { $script:ShimFound = $shim }
        }
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

# The program a `claude.cmd` starts, as argv, or `$null`.
function Resolve-Shim([string]$Shim) {
    $dir = [System.IO.Path]::GetDirectoryName($Shim)
    $targets = New-List
    $text = Read-TextFile $Shim
    if ($null -ne $text) {
        foreach ($m in [regex]::Matches($text, '%~?dp0%?\\([^"%\r\n]+?\.(?:exe|js))', 'IgnoreCase')) {
            $targets.Add((Join-PyPath $dir $m.Groups[1].Value))
        }
    }
    $pkg = Join-PyPath (Join-PyPath (Join-PyPath $dir 'node_modules') '@anthropic-ai') 'claude-code'
    $targets.Add((Join-PyPath (Join-PyPath $pkg 'bin') 'claude.exe'))
    $targets.Add((Join-PyPath $pkg 'cli.js'))

    foreach ($t in $targets) {
        if ($t.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase) -and [System.IO.File]::Exists($t)) { return , @($t) }
    }
    foreach ($t in $targets) {
        if (-not $t.EndsWith('.js', [System.StringComparison]::OrdinalIgnoreCase) -or -not [System.IO.File]::Exists($t)) { continue }
        # A package that has no `claude.exe` of its own still carries one
        # beside its script in recent versions; failing that, `node`.
        $sibling = Join-PyPath (Join-PyPath ([System.IO.Path]::GetDirectoryName($t)) 'bin') 'claude.exe'
        if ([System.IO.File]::Exists($sibling)) { return , @($sibling) }
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

# --- the two questions --------------------------------------------------------

function Get-Inventory($Req) {
    $h = Get-J $Req 'home'
    if (-not (Test-Truthy $h)) {
        $h = $(if ($script:OnWindows) { [string]$env:USERPROFILE } else { [string]$env:HOME })
    }
    $homeDir = [string]$h
    $c = Get-J $Req 'cwd'
    $cwd = $(if (Test-Truthy $c) { [string]$c } else { $null })
    $notes = New-List
    $items = New-List

    foreach ($i in (Get-SkillsIn (Join-PyPath (Join-PyPath $homeDir '.claude') 'skills') 'user')) { $items.Add($i) }
    if ($null -ne $cwd) {
        foreach ($i in (Get-SkillsIn (Join-PyPath (Join-PyPath $cwd '.claude') 'skills') 'project')) { $items.Add($i) }
    }

    $r = Read-JsonFile (Join-PyPath $homeDir '.claude.json')
    if ($null -ne $r[1]) { $notes.Add('Could not read ~/.claude.json: ' + $r[1]) }
    $config = $r[0]
    if (Test-JDict $config) {
        foreach ($i in (Get-ServersFrom (Get-J $config 'mcpServers') 'user')) { $items.Add($i) }
        $projects = Get-J $config 'projects'
        if ($null -ne $cwd -and (Test-JDict $projects)) {
            $project = Get-J $projects $cwd
            if (Test-JDict $project) {
                foreach ($i in (Get-ServersFrom (Get-J $project 'mcpServers') 'local')) { $items.Add($i) }
            }
        }
    }
    if ($null -ne $cwd) {
        $shared = (Read-JsonFile (Join-PyPath $cwd '.mcp.json'))[0]
        if (Test-JDict $shared) {
            foreach ($i in (Get-ServersFrom (Get-J $shared 'mcpServers') 'project')) { $items.Add($i) }
        }
    }

    $plugins = Get-EnabledPlugins $homeDir $cwd $notes
    $keys = @($plugins.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    foreach ($k in $keys) {
        foreach ($i in (Get-PluginItems $k $plugins[$k])) { $items.Add($i) }
    }

    # The same id twice is one switch at launch, so it is one row here.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $unique = New-List
    foreach ($item in $items) {
        if ($seen.Add([string]$item['id'])) { $unique.Add($item) }
    }

    $notes.Add('Connectors added in claude.ai are not listed: they are not kept on this machine.')
    $answer = New-Map
    $answer['version'] = $ContractVersion
    $answer['installed'] = $null -ne (Resolve-ClaudeCommand)
    $answer['items'] = $unique
    $answer['notes'] = $notes
    return , $answer
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

# Take every `--settings <json>` out of `args`, merged into one object.
function Split-Settings($ArgList, $Notes) {
    $rest = New-List
    $settings = New-Map
    $i = 0
    while ($i -lt $ArgList.Count) {
        $a = [string]$ArgList[$i]
        $value = $null
        $step = 1
        if ($a -ceq '--settings' -and $i + 1 -lt $ArgList.Count) {
            $value = [string]$ArgList[$i + 1]; $step = 2
        } elseif ($a.StartsWith('--settings=', $script:Ordinal)) {
            $value = $a.Substring('--settings='.Length); $step = 1
        }
        if ($null -eq $value) {
            $rest.Add($a)
            $i += 1
            continue
        }
        $parsed = $null
        try { $parsed = Get-JValue (Read-JsonText $value) } catch { $parsed = $null }
        if (Test-JDict $parsed) {
            foreach ($k in (Get-JKeys $parsed)) { $settings[$k] = Get-J $parsed $k }
        } else {
            for ($j = $i; $j -lt [Math]::Min($i + $step, $ArgList.Count); $j++) { $rest.Add([string]$ArgList[$j]) }
            $Notes.Add("The extra --settings names a file, so it replaces the role's skill settings instead of adding to them. Put the JSON inline.")
        }
        $i += $step
    }
    return @($rest, $settings)
}

function Get-Launch($Req) {
    $role = Get-J $Req 'role'
    if (-not (Test-Truthy $role)) { $role = New-Map }
    $cli = Get-J $Req 'cli'
    if (-not (Test-Truthy $cli)) { $cli = New-Map }
    $inv = Get-Inventory $Req

    $overrides = New-Map
    $denied = New-List
    $offSkill = 0
    $offMcp = 0
    foreach ($item in $inv['items']) {
        if ($item.Contains('locked') -and $item['locked']) { continue }
        $kind = [string]$item['kind']
        $selection = Get-J $cli $(if ($kind -ceq 'skill') { 'skills' } else { 'mcp' })
        if (-not (Test-Truthy $selection)) { $selection = New-Map }
        if (Test-Enabled $selection ([string]$item['id'])) { continue }
        if ($kind -ceq 'mcp') {
            $offMcp += 1
            $denied.Add('mcp__' + ([string]$item['id']).Substring('mcp:'.Length))
        } else {
            $offSkill += 1
            if (([string]$item['source']).StartsWith('plugin:', $script:Ordinal)) {
                $denied.Add('Skill(' + $item['name'] + ')')
            } else {
                $overrides[[string]$item['name']] = 'off'
            }
        }
    }

    $notes = $inv['notes']
    $argList = New-List
    $rawArgs = Get-J $cli 'args'
    if (Test-JList $rawArgs) {
        foreach ($a in (Get-JItems $rawArgs)) { if ($a -is [string]) { $argList.Add($a) } }
    }
    $split = Split-Settings $argList $notes
    $extra = $split[0]
    $settings = $split[1]

    # **One `--settings`, never two** -- see `adapter.py`.
    if ($overrides.Count -gt 0) {
        $merged = New-Map
        $old = $(if ($settings.Contains('skillOverrides')) { $settings['skillOverrides'] } else { $null })
        if (Test-JDict $old) { foreach ($k in (Get-JKeys $old)) { $merged[$k] = Get-J $old $k } }
        foreach ($k in $overrides.Keys) { $merged[$k] = $overrides[$k] }
        $settings['skillOverrides'] = $merged
    }

    $start = Resolve-ClaudeCommand
    if ($null -eq $start) {
        if ($script:OnWindows -and $null -ne $script:ShimFound) {
            throw "found $($script:ShimFound), but not the program it starts (no claude.exe beside it, and no node.exe for its script). A batch file is not given a role's instructions: cmd.exe would re-read their quotes and newlines. Install Claude Code's native build, or put claude.exe on PATH."
        }
        # Not found at all: the command is still `claude`, as the original
        # answers, and starting it will say it is not there.
        $start = @('claude')
    }
    $argv = New-List
    foreach ($s in $start) { $argv.Add($s) }
    if ($settings.Count -gt 0) {
        $argv.Add('--settings')
        $argv.Add((ConvertTo-PyJson $settings))
    }
    if ($denied.Count -gt 0) {
        $argv.Add('--disallowedTools')
        foreach ($d in $denied) { $argv.Add($d) }
    }
    $model = Get-J $cli 'model'
    if (-not (Test-Truthy $model)) { $model = Get-J $role 'model' }
    if (Test-Truthy $model) {
        $argv.Add('--model')
        $argv.Add($model)
    }
    $instructions = Get-J $role 'instructions'
    if (Test-Truthy $instructions) {
        $argv.Add('--append-system-prompt')
        $argv.Add($instructions)
    }
    foreach ($e in $extra) { $argv.Add($e) }

    $answer = New-Map
    $answer['version'] = $ContractVersion
    $answer['argv'] = $argv
    $answer['env'] = New-Map
    $answer['summary'] = "$offSkill skill(s) and $offMcp MCP server(s) switched off"
    $answer['notes'] = $notes
    return , $answer
}

# --- main -------------------------------------------------------------------

function Invoke-Main($Argv) {
    if (($Argv.Count -ne 1 -and $Argv.Count -ne 2) -or -not (@('inventory', 'launch') -ccontains [string]$Argv[0])) {
        Write-Err "usage: adapter.ps1 inventory|launch '<request json>'"
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
        $answer = $(if ([string]$Argv[0] -ceq 'inventory') { Get-Inventory $req } else { Get-Launch $req })
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
