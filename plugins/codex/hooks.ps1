# Codex's hooks, as `-c` arguments for the command line that starts it.
#
# Task 1668. The PowerShell twin of hooks.py, which says why each piece is
# what it is; read that first. The adapter dot-sources this file and puts
# what `Get-CodexHookArgs` returns on the Codex command line.
#
# The JSON that is hashed is written out by hand rather than with
# ConvertTo-Json: the hash is of keys in sorted order and compact form, and
# ConvertTo-Json promises neither.

$script:CodexHookEvents = @(
    @('SessionStart', 'session_start'),
    @('UserPromptSubmit', 'user_prompt_submit'),
    @('Stop', 'stop'),
    @('Interrupt', 'interrupt'),
    @('PermissionRequest', 'permission_request'),
    @('PreToolUse', 'pre_tool_use'),
    @('PostToolUse', 'post_tool_use')
)

$script:CodexHookTimeout = 3

# A JSON string, escaped the way serde_json escapes one: the quote, the
# backslash, and control characters; everything else as it is.
function ConvertTo-CodexJsonString([string]$s) {
    $sb = [System.Text.StringBuilder]::new('"')
    foreach ($c in $s.ToCharArray()) {
        switch ([int]$c) {
            0x22 { [void]$sb.Append('\"') }
            0x5C { [void]$sb.Append('\\') }
            0x08 { [void]$sb.Append('\b') }
            0x0C { [void]$sb.Append('\f') }
            0x0A { [void]$sb.Append('\n') }
            0x0D { [void]$sb.Append('\r') }
            0x09 { [void]$sb.Append('\t') }
            default {
                if ([int]$c -lt 0x20) { [void]$sb.AppendFormat('\u{0:x4}', [int]$c) }
                else { [void]$sb.Append($c) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-CodexHookCommand([string]$Polter, [string]$Hook, [bool]$Windows) {
    if ($Windows) { return ('"{0}" +hook --cli codex {1}' -f $Polter, $Hook) }
    return ("'{0}' +hook --cli codex {1}" -f $Polter.Replace("'", "'\''"), $Hook)
}

function Get-CodexHookTrustedHash([string]$Label, [string]$Command) {
    $json = '{"event_name":' + (ConvertTo-CodexJsonString $Label) +
        ',"hooks":[{"async":false,"command":' + (ConvertTo-CodexJsonString $Command) +
        ',"timeout":' + $script:CodexHookTimeout + ',"type":"command"}]}'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return 'sha256:' + (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
}

# The `-c` arguments that add Polter's hooks to one Codex, trusted.
# `-Windows` is where Codex will run: it decides the shell the command is
# written for and the start of the trust key (`C:\<session-flags>\config.toml`,
# which is reasoned from Codex's source and not yet measured on Windows).
function Get-CodexHookArgs([string]$Polter, [bool]$Windows = $IsWindowsPlatform) {
    $source = if ($Windows) { 'C:\<session-flags>\config.toml' } else { '/<session-flags>/config.toml' }
    $out = [System.Collections.Generic.List[string]]::new()
    $state = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $script:CodexHookEvents) {
        $hook = $e[0]; $label = $e[1]
        $command = Get-CodexHookCommand $Polter $hook $Windows
        $out.Add('-c')
        $out.Add(('hooks.{0}=[{{hooks=[{{type="command",command={1},timeout={2}}}]}}]' -f
                $hook, (ConvertTo-CodexJsonString $command), $script:CodexHookTimeout))
        $key = '{0}:{1}:0:0' -f $source, $label
        $state.Add(('{0}={{trusted_hash={1}}}' -f (ConvertTo-CodexJsonString $key),
                (ConvertTo-CodexJsonString (Get-CodexHookTrustedHash $label $command))))
    }
    $out.Add('-c')
    $out.Add('hooks.state={' + ($state -join ',') + '}')
    return , $out.ToArray()
}

$IsWindowsPlatform = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
