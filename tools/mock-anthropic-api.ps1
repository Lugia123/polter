<#
.SYNOPSIS
A local stand-in for the Anthropic Messages API, for driving a real Claude
Code on a test machine without a network or a key.

.DESCRIPTION
Written for Windows PowerShell 5.1 (the test machine has no python and no
node) and runs unchanged under PowerShell 7 (`pwsh`), which is how it was
checked on a Mac against claude 2.1.283.

Start it, then point Claude Code at it:

    powershell -NoProfile -ExecutionPolicy Bypass -File tools\mock-anthropic-api.ps1
    $env:ANTHROPIC_BASE_URL   = 'http://localhost:8787'
    $env:ANTHROPIC_AUTH_TOKEN = 'mock'      # a bearer token: no approval prompt
    $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
    claude

Use `localhost`, not `127.0.0.1`, in the URL: on Windows the listener is
registered for `localhost` (a non-administrator may not register the other),
and http.sys matches on the Host header -- a request for 127.0.0.1 would be
refused before this script ever sees it. See the start-up line, which says
which prefixes it got.

What it answers:

  POST /v1/messages               the reply the current mode says (below),
                                  streamed as SSE when the request has
                                  "stream": true, one JSON message otherwise
  POST /v1/messages/count_tokens  {"input_tokens": <about a quarter of the body>}
  GET  /v1/models[/<id>]          one model, the one asked for
  HEAD|GET /  and  /api/hello     200: Claude Code sends HEAD /api/hello first,
                                  to see the host is there
  anything else                   404 with an Anthropic-shaped error, and the
                                  path logged with "unimplemented": true

Modes -- -Mode at start, or changed while it runs (see Control); a mode stays
until it is changed:

  text   one answer carrying -Marker. When any user message says
         `echo back: <word>`, the answer also carries that word **reversed**
         -- `echo: <reversed>` -- so a test can tell the answer came from
         this reply and could not have come from the prompt on the screen.
  tool   a tool_use: PowerShell `New-Item` when the request offers a tool
         called PowerShell (Windows without Git Bash), Bash `touch` when it
         offers Bash; -ToolName forces one. It puts a permission box up. The
         request that comes back with a tool_result -- run, refused or failed
         -- is answered as text, so a turn always ends.
  429    HTTP 429 rate_limit_error   -> StopFailure "rate_limit"   (measured)
  500    HTTP 500 api_error
  529    HTTP 529 overloaded_error   -> StopFailure "server_error" (measured)
  The errors carry `x-should-retry: false` unless allow-retry is on, so the
  client gives up at once instead of retrying (it retries 10 times by
  default), and `retry-after: <s>` when retry-after is set.

Slow streaming, for testing an interrupt: with delay=<ms> the text is sent a
word at a time with that pause between words, and -SlowWords filler words
are added so the stream lasts long enough to interrupt. A client that goes
away mid-stream is logged as "aborted": true.

Control, without restarting -- body is space-separated words:

  POST /__mock/config   e.g. "tool", "429 retry-after=5", "text delay=300",
                        "allow-retry=1", "retry-after=", "delay=0"
  GET  /__mock/config   the current settings, as JSON
  POST /__mock/mode     the same as /__mock/config (kept for old callers)

Every request is one JSON line in -LogPath: time, method, path, status, mode,
model, whether it streamed, the body's size, the tool names the request
offered, which tool a tool_use used, the echo word it found, whether the
last user message carried a tool_result, and whether the client went away.
Credentials are never written: `x-api-key` and `authorization` are logged
as present or absent.

.PARAMETER Port
Where to listen. 8787 by default.

.PARAMETER Mode
text (default), tool, 429, 500 or 529.

.PARAMETER Marker
Put in every text reply, so a test can tell this answer from any other.

.PARAMETER ToolName
auto (default: PowerShell if offered, else Bash), PowerShell or Bash.

.PARAMETER PowerShellCommand
What a PowerShell tool_use runs.

.PARAMETER BashCommand
What a Bash tool_use runs.

.PARAMETER RetryAfter
Seconds for a `retry-after` header on the error modes; -1 (default) sends none.

.PARAMETER AllowRetry
Leave `x-should-retry: false` off the error replies.

.PARAMETER DelayMs
Pause between streamed words. 0 (default) streams the answer at once.

.PARAMETER SlowWords
Filler words added to a streamed answer when DelayMs is above 0.

.PARAMETER LogPath
One JSON line per request. mock-anthropic-api.log beside this script by
default.
#>
param(
    [int]$Port = 8787,
    [ValidateSet('text', 'tool', '429', '500', '529')]
    [string]$Mode = 'text',
    [string]$Marker = 'MOCK-REPLY-OK',
    [ValidateSet('auto', 'PowerShell', 'Bash')]
    [string]$ToolName = 'auto',
    [string]$PowerShellCommand = 'New-Item -ItemType File -Path marker-X -Force',
    [string]$BashCommand = 'touch marker-X',
    [int]$RetryAfter = -1,
    [switch]$AllowRetry,
    [int]$DelayMs = 0,
    [int]$SlowWords = 40,
    [string]$LogPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($LogPath -eq '') {
    $LogPath = Join-Path $PSScriptRoot 'mock-anthropic-api.log'
}
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Seq = 0
$script:Method = ''
$script:Cfg = @{
    mode = $Mode
    retry_after = $RetryAfter
    allow_retry = [bool]$AllowRetry
    delay_ms = $DelayMs
    tool = $ToolName
}
$script:Modes = @('text', 'tool', '429', '500', '529')

function Write-Log($Fields) {
    $Fields['t'] = (Get-Date).ToUniversalTime().ToString('o')
    $line = ConvertTo-Json -InputObject $Fields -Compress -Depth 5
    [System.IO.File]::AppendAllText($LogPath, $line + "`n", $script:Utf8)
}

# JSON text for a string, escaped the way JSON needs and nothing more.
function ConvertTo-JsonString([string]$S) {
    return (ConvertTo-Json -InputObject $S -Compress)
}

function Get-CfgJson {
    $ra = 'null'
    if ($script:Cfg.retry_after -ge 0) { $ra = [string]$script:Cfg.retry_after }
    return '{"mode":"' + $script:Cfg.mode + '","retry_after":' + $ra +
        ',"allow_retry":' + ([string]$script:Cfg.allow_retry).ToLower() +
        ',"delay_ms":' + $script:Cfg.delay_ms + ',"tool":"' + $script:Cfg.tool + '"}'
}

# "429 retry-after=5 delay=300": a mode word and/or key=value words. Answers
# null when every word was understood, otherwise the word that was not.
function Set-Cfg([string]$Words) {
    foreach ($w in ($Words.Trim() -split '\s+')) {
        if ($w -eq '') { continue }
        if ($script:Modes -contains $w) { $script:Cfg.mode = $w; continue }
        $kv = $w -split '=', 2
        if ($kv.Count -ne 2) { return $w }
        switch ($kv[0]) {
            'mode' { if ($script:Modes -contains $kv[1]) { $script:Cfg.mode = $kv[1] } else { return $w } }
            'retry-after' { if ($kv[1] -eq '') { $script:Cfg.retry_after = -1 } else { $script:Cfg.retry_after = [int]$kv[1] } }
            'allow-retry' { $script:Cfg.allow_retry = ($kv[1] -eq '1' -or $kv[1] -eq 'true') }
            'delay' { $script:Cfg.delay_ms = [int]$kv[1] }
            'tool' { if (@('auto', 'PowerShell', 'Bash') -contains $kv[1]) { $script:Cfg.tool = $kv[1] } else { return $w } }
            default { return $w }
        }
    }
    return $null
}

function New-Id([string]$Prefix) {
    $script:Seq += 1
    return '{0}_mock{1:D6}{2}' -f $Prefix, $script:Seq, ([guid]::NewGuid().ToString('N').Substring(0, 12))
}

function Send-Bytes($Response, [int]$Status, [string]$ContentType, [string]$Body, $Headers) {
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    if ($null -ne $Headers) {
        foreach ($k in $Headers.Keys) { $Response.Headers.Add($k, $Headers[$k]) }
    }
    $bytes = $script:Utf8.GetBytes($Body)
    $Response.ContentLength64 = $bytes.Length
    # A HEAD is answered with the length and no body.
    if ($script:Method -ne 'HEAD') { $Response.OutputStream.Write($bytes, 0, $bytes.Length) }
    $Response.OutputStream.Close()
}

function Send-Json($Response, [int]$Status, [string]$Json, $Headers) {
    Send-Bytes $Response $Status 'application/json' $Json $Headers
}

function Send-Error($Response, [int]$Status, [string]$Type, [string]$Message) {
    $headers = @{ 'request-id' = (New-Id 'req') }
    if (-not $script:Cfg.allow_retry) { $headers['x-should-retry'] = 'false' }
    if ($script:Cfg.retry_after -ge 0) { $headers['retry-after'] = [string]$script:Cfg.retry_after }
    $json = '{"type":"error","error":{"type":' + (ConvertTo-JsonString $Type) +
        ',"message":' + (ConvertTo-JsonString $Message) + '}}'
    Send-Json $Response $Status $json $headers
}

function Get-Reversed([string]$S) {
    $chars = $S.ToCharArray()
    [array]::Reverse($chars)
    return (-join $chars)
}

# The text a user message says, whether its content is a string or blocks.
function Get-UserText($Message) {
    if (-not $Message.PSObject.Properties['content']) { return '' }
    $c = $Message.content
    if ($c -is [string]) { return $c }
    $parts = @()
    foreach ($block in @($c)) {
        if ($block.PSObject.Properties['type'] -and $block.type -eq 'text' -and $block.PSObject.Properties['text']) {
            $parts += [string]$block.text
        }
    }
    return ($parts -join "`n")
}

# What the request is, read tolerantly: a body the parser will not take is
# still answered, from what a regular expression can see in it.
function Read-Request([string]$Body) {
    $info = @{
        model = 'claude-mock'; stream = $false; tool_result = $false; parsed = $false
        tools = @(); tool_props = @{}; echo = $null
    }
    $echoRe = '(?i)echo back:\s*(\S+)'
    $obj = $null
    try { $obj = ConvertFrom-Json -InputObject $Body } catch { $obj = $null }
    if ($null -ne $obj) {
        $info.parsed = $true
        if ($obj.PSObject.Properties['model']) { $info.model = [string]$obj.model }
        if ($obj.PSObject.Properties['stream']) { $info.stream = [bool]$obj.stream }
        if ($obj.PSObject.Properties['tools'] -and $null -ne $obj.tools) {
            foreach ($t in @($obj.tools)) {
                if (-not $t.PSObject.Properties['name']) { continue }
                $info.tools += [string]$t.name
                $props = @()
                if ($t.PSObject.Properties['input_schema'] -and $t.input_schema.PSObject.Properties['properties']) {
                    $props = @($t.input_schema.properties.PSObject.Properties | ForEach-Object { $_.Name })
                }
                $info.tool_props[[string]$t.name] = $props
            }
        }
        if ($obj.PSObject.Properties['messages'] -and $null -ne $obj.messages) {
            $msgs = @($obj.messages)
            foreach ($m in $msgs) {
                if ($m.PSObject.Properties['role'] -and $m.role -eq 'user') {
                    $found = [regex]::Matches((Get-UserText $m), $echoRe)
                    if ($found.Count -gt 0) { $info.echo = $found[$found.Count - 1].Groups[1].Value }
                }
            }
            if ($msgs.Count -gt 0) {
                $last = $msgs[$msgs.Count - 1]
                if ($last.PSObject.Properties['content'] -and -not ($last.content -is [string])) {
                    foreach ($block in @($last.content)) {
                        if ($block.PSObject.Properties['type'] -and $block.type -eq 'tool_result') {
                            $info.tool_result = $true
                        }
                    }
                }
            }
        }
    } else {
        $m = [regex]::Match($Body, '"model"\s*:\s*"([^"]+)"')
        if ($m.Success) { $info.model = $m.Groups[1].Value }
        $info.stream = [regex]::IsMatch($Body, '"stream"\s*:\s*true')
        $info.tool_result = [regex]::IsMatch($Body, '"type"\s*:\s*"tool_result"')
        $found = [regex]::Matches($Body, $echoRe)
        if ($found.Count -gt 0) { $info.echo = ($found[$found.Count - 1].Groups[1].Value -replace '\\n.*$', '') }
        foreach ($name in @('PowerShell', 'Bash')) {
            if ([regex]::IsMatch($Body, '"name"\s*:\s*"' + $name + '"')) { $info.tools += $name }
        }
    }
    return $info
}

function Get-ToolChoice($Info) {
    $want = $script:Cfg.tool
    if ($want -eq 'auto') {
        if ($Info.tools -contains 'PowerShell') { $want = 'PowerShell' } else { $want = 'Bash' }
    }
    if ($want -eq 'PowerShell') { return @{ name = 'PowerShell'; command = $PowerShellCommand } }
    return @{ name = 'Bash'; command = $BashCommand }
}

# The content block and stop reason for this request, as a small plan the
# two writers below turn into JSON or SSE.
function Get-Plan($Info) {
    if ($script:Cfg.mode -eq 'tool' -and -not $Info.tool_result) {
        $tool = Get-ToolChoice $Info
        return @{
            kind = 'tool'
            id = (New-Id 'toolu')
            name = $tool.name
            input = '{"command":' + (ConvertTo-JsonString $tool.command) + ',"description":"Mock tool call"}'
            stop = 'tool_use'
        }
    }
    $text = "$Marker -- a fixed answer from mock-anthropic-api.ps1."
    if ($Info.tool_result) { $text = "$Marker -- the tool result came back." }
    if ($null -ne $Info.echo) { $text += ' echo: ' + (Get-Reversed $Info.echo) }
    return @{ kind = 'text'; text = $text; stop = 'end_turn' }
}

function Get-Usage { return '{"input_tokens":10,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}' }

function Send-Message($Response, $Info, $Log) {
    $plan = Get-Plan $Info
    if ($plan.kind -eq 'tool') {
        $content = '[{"type":"tool_use","id":"' + $plan.id + '","name":"' + $plan.name + '","input":' + $plan.input + '}]'
        $Log.tool_name = $plan.name
    } else {
        $content = '[{"type":"text","text":' + (ConvertTo-JsonString $plan.text) + '}]'
    }
    $json = '{"id":"' + (New-Id 'msg') + '","type":"message","role":"assistant","model":' +
        (ConvertTo-JsonString $Info.model) + ',"content":' + $content +
        ',"stop_reason":"' + $plan.stop + '","stop_sequence":null,"usage":' + (Get-Usage) + '}'
    Send-Json $Response 200 $json @{ 'request-id' = (New-Id 'req') }
    return $plan.kind
}

function Write-Event($Stream, [string]$Name, [string]$Data) {
    $bytes = $script:Utf8.GetBytes("event: $Name`ndata: $Data`n`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Send-Stream($Response, $Info, $Log) {
    $plan = Get-Plan $Info
    $Response.StatusCode = 200
    $Response.ContentType = 'text/event-stream'
    $Response.SendChunked = $true
    $Response.Headers.Add('Cache-Control', 'no-cache')
    $Response.Headers.Add('request-id', (New-Id 'req'))
    $s = $Response.OutputStream
    $delay = [int]$script:Cfg.delay_ms
    try {
        Write-Event $s 'message_start' ('{"type":"message_start","message":{"id":"' + (New-Id 'msg') +
            '","type":"message","role":"assistant","model":' + (ConvertTo-JsonString $Info.model) +
            ',"content":[],"stop_reason":null,"stop_sequence":null,"usage":' + (Get-Usage) + '}}')
        if ($plan.kind -eq 'tool') {
            $Log.tool_name = $plan.name
            Write-Event $s 'content_block_start' ('{"type":"content_block_start","index":0,"content_block":' +
                '{"type":"tool_use","id":"' + $plan.id + '","name":"' + $plan.name + '","input":{}}}')
            Write-Event $s 'content_block_delta' ('{"type":"content_block_delta","index":0,"delta":' +
                '{"type":"input_json_delta","partial_json":' + (ConvertTo-JsonString $plan.input) + '}}')
        } else {
            Write-Event $s 'content_block_start' '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'
            $words = @($plan.text -split ' ')
            if ($delay -gt 0) {
                for ($i = 1; $i -le $SlowWords; $i++) { $words += "slow-$i" }
            } else {
                $words = @($plan.text)
            }
            for ($i = 0; $i -lt $words.Count; $i++) {
                $piece = $words[$i]
                if ($i -lt $words.Count - 1 -and $delay -gt 0) { $piece += ' ' }
                Write-Event $s 'content_block_delta' ('{"type":"content_block_delta","index":0,"delta":' +
                    '{"type":"text_delta","text":' + (ConvertTo-JsonString $piece) + '}}')
                if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
            }
        }
        Write-Event $s 'content_block_stop' '{"type":"content_block_stop","index":0}'
        Write-Event $s 'message_delta' ('{"type":"message_delta","delta":{"stop_reason":"' + $plan.stop +
            '","stop_sequence":null},"usage":{"output_tokens":10}}')
        Write-Event $s 'message_stop' '{"type":"message_stop"}'
        $s.Close()
    } catch {
        # The client went away -- an interrupt, most likely. Said, not thrown:
        # the listener carries on for the next request.
        $Log.aborted = $true
        $Log.abort_error = $_.Exception.Message
        try { $Response.Abort() } catch { }
    }
    return $plan.kind
}

function Invoke-Request($Context) {
    $req = $Context.Request
    $res = $Context.Response
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod
    $script:Method = $method
    $body = ''
    if ($req.HasEntityBody) {
        $reader = New-Object System.IO.StreamReader($req.InputStream, $script:Utf8)
        $body = $reader.ReadToEnd()
        $reader.Close()
    }
    $log = [ordered]@{
        method = $method
        path = $path
        query = $req.Url.Query
        host = $req.Headers['host']
        body_bytes = $script:Utf8.GetByteCount($body)
        mode = $script:Cfg.mode
        x_api_key = ($null -ne $req.Headers['x-api-key'])
        authorization = ($null -ne $req.Headers['authorization'])
        anthropic_version = $req.Headers['anthropic-version']
        anthropic_beta = $req.Headers['anthropic-beta']
        user_agent = $req.Headers['user-agent']
    }

    if ($path -eq '/__mock/config' -or $path -eq '/__mock/mode') {
        if ($method -eq 'POST') {
            $bad = Set-Cfg $body
            if ($null -eq $bad) {
                Send-Json $res 200 (Get-CfgJson) $null
                $log.status = 200
            } else {
                Send-Json $res 400 ('{"error":' + (ConvertTo-JsonString "not understood: $bad") + ',"config":' + (Get-CfgJson) + '}') $null
                $log.status = 400
            }
        } else {
            Send-Json $res 200 (Get-CfgJson) $null
            $log.status = 200
        }
        $log.config = Get-CfgJson
        Write-Log $log
        return
    }

    if ($path -eq '/v1/messages' -and $method -eq 'POST') {
        $info = Read-Request $body
        $log.model = $info.model
        $log.stream = $info.stream
        $log.tool_result = $info.tool_result
        $log.parsed = $info.parsed
        $log.tools = $info.tools
        $log.echo = $info.echo
        switch ($script:Cfg.mode) {
            '429' { Send-Error $res 429 'rate_limit_error' 'mock-anthropic-api: rate limited on purpose'; $log.status = 429 }
            '500' { Send-Error $res 500 'api_error' 'mock-anthropic-api: internal error on purpose'; $log.status = 500 }
            '529' { Send-Error $res 529 'overloaded_error' 'mock-anthropic-api: overloaded on purpose'; $log.status = 529 }
            default {
                if ($info.stream) { $log.reply = Send-Stream $res $info $log } else { $log.reply = Send-Message $res $info $log }
                $log.status = 200
            }
        }
        if ($log.Contains('tool_name') -and $info.tool_props.ContainsKey($log.tool_name)) {
            $log.tool_input_schema = $info.tool_props[$log.tool_name]
        }
        Write-Log $log
        return
    }

    if ($path -eq '/v1/messages/count_tokens' -and $method -eq 'POST') {
        $n = [int][Math]::Max(1, $body.Length / 4)
        Send-Json $res 200 ('{"input_tokens":' + $n + '}') $null
        $log.status = 200
        Write-Log $log
        return
    }

    if ($path -like '/v1/models*' -and $method -eq 'GET') {
        $id = 'claude-mock'
        if ($path -match '^/v1/models/(.+)$') { $id = $Matches[1] }
        $model = '{"type":"model","id":' + (ConvertTo-JsonString $id) +
            ',"display_name":"Mock","created_at":"2026-01-01T00:00:00Z"}'
        if ($path -eq '/v1/models') {
            $json = '{"data":[' + $model + '],"has_more":false,"first_id":' + (ConvertTo-JsonString $id) +
                ',"last_id":' + (ConvertTo-JsonString $id) + '}'
        } else {
            $json = $model
        }
        Send-Json $res 200 $json $null
        $log.status = 200
        Write-Log $log
        return
    }

    # `/api/hello` is Claude Code's own "is the host there" check, sent as a
    # HEAD before anything else (measured, 2.1.283).
    if (($path -eq '/' -or $path -eq '/api/hello') -and ($method -eq 'GET' -or $method -eq 'HEAD')) {
        Send-Json $res 200 '{"ok":true}' $null
        $log.status = 200
        Write-Log $log
        return
    }

    # Not implemented: answered as the API answers an unknown route, and
    # logged so the next person can see what Claude Code asked for.
    Send-Error $res 404 'not_found_error' "mock-anthropic-api does not implement $method $path"
    $log.status = 404
    $log.unimplemented = $true
    Write-Log $log
}

# `localhost` always; `127.0.0.1` as well where this account may register it
# (a Windows non-administrator usually may not, and the whole start would
# fail with it in the list).
function Start-Listener {
    foreach ($try in @(@('localhost', '127.0.0.1'), @('localhost'))) {
        $l = New-Object System.Net.HttpListener
        foreach ($h in $try) { $l.Prefixes.Add("http://${h}:$Port/") }
        try {
            $l.Start()
            return $l
        } catch {
            $l.Close()
            Write-Host "could not listen on $($try -join ' and '): $($_.Exception.Message)"
        }
    }
    throw "could not listen on port $Port"
}

$listener = Start-Listener
$prefixes = @($listener.Prefixes) -join ' '
Write-Host "mock-anthropic-api listening on $prefixes config=$(Get-CfgJson) log=$LogPath"
Write-Log ([ordered]@{ event = 'start'; prefixes = $prefixes; config = (Get-CfgJson); marker = $Marker; powershell_command = $PowerShellCommand; bash_command = $BashCommand })
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            Invoke-Request $context
        } catch {
            Write-Log ([ordered]@{ event = 'handler_error'; path = $context.Request.Url.AbsolutePath; error = $_.Exception.Message })
            try { $context.Response.Abort() } catch { }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
