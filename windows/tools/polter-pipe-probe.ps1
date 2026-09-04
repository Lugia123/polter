<#
.SYNOPSIS
  Does the Poltergeist endpoint exist and serve on Windows?

.DESCRIPTION
  The third link of task 131, taken as a reading rather than an assumption.

  **This is not a unix socket on Windows.** `src/poltergeist/transport.zig`
  chooses a named pipe for this platform on purpose -- the file says why at
  length (Zig 0.16's Windows AF_UNIX accept path has `.CANCELLED =>
  unreachable`, so closing a listening handle to stop a server panics). The
  endpoint is `\\.\pipe\polter-<8 hex bytes>`, built by
  `transport_windows.defaultName`, and it is handed to clients through
  `GHOSTTY_POLTER_SOCKET`.

  So the question this answers is not "do unix sockets work here". It is the
  narrower one: **does the server bind, does it accept, and does it serve** --
  and if not, which of those three.

  Nothing here uses our client code. It speaks the protocol with .NET's own
  named-pipe client, one line of JSON, exactly as `cli/chat.zig` and
  `cli/mcp.zig` would. A probe built on our client would fail in the same
  place our client does, and prove nothing about the pipe.

.PARAMETER Token
  The value of `GHOSTTY_POLTER_TOKEN` from inside a Polter terminal. Get it
  by running `echo %GHOSTTY_POLTER_TOKEN%` in one. Without it this script can
  still answer the first two questions but not the third.

.PARAMETER Pipe
  A specific pipe name. Default: discover it (see -Mode discover).

.NOTES
  Run under Windows PowerShell 5.1 or PowerShell 7; both have
  System.IO.Pipes.

  **What this does not answer**: whether the chat TUI works. That is a
  separate defect and it is already located -- see the report on task 131.
#>

[CmdletBinding()]
param(
    [string]$Token = $env:GHOSTTY_POLTER_TOKEN,
    [string]$Pipe = '',
    [int]$TimeoutMs = 3000
)

$ErrorActionPreference = 'Stop'

function Get-PolterPipes {
    # Named pipes live in a kernel namespace, and this is the documented way
    # to enumerate it from .NET. It leaves nothing on disk, so `dir` on a
    # state directory would find nothing and would read as "no server".
    $all = [System.IO.Directory]::GetFiles('\\.\pipe\')
    return @($all | Where-Object { $_ -match 'polter-' })
}

function Connect-Pipe {
    param([string]$Name, [int]$Timeout)
    # `NamedPipeClientStream` wants the pipe's bare name, not the
    # `\\.\pipe\` path. Passing the full path names a pipe nobody is
    # listening on, and the failure looks exactly like "the server never
    # started" -- the same trap `transport_windows.zig`'s own test pins.
    $bare = $Name -replace '^\\\\\.\\pipe\\', ''
    $c = New-Object System.IO.Pipes.NamedPipeClientStream(
        '.', $bare, [System.IO.Pipes.PipeDirection]::InOut)
    $c.Connect($Timeout)
    return $c
}

function Invoke-Auth {
    param($Client, [string]$TokenValue)
    $w = New-Object System.IO.StreamWriter($Client)
    $w.AutoFlush = $true
    $r = New-Object System.IO.StreamReader($Client)
    # The exact first line `cli/chat.zig` sends. Copied from that file rather
    # than remembered: a probe whose handshake is subtly wrong reports a dead
    # server, and a false negative here is indistinguishable from the real
    # defect it is looking for.
    $line = '{"method":"auth","params":{"token":"' + $TokenValue + '"}}'
    $w.WriteLine($line)
    return $r.ReadLine()
}

Write-Host '--- 1. did the server bind? ---'
$pipes = if ($Pipe) { @($Pipe) } else { Get-PolterPipes }

if ($pipes.Count -eq 0) {
    Write-Host 'NO PIPE. The server did not bind, or is not running.'
    Write-Host ''
    Write-Host 'This is the first of the three causes, and it is not about sockets:'
    Write-Host '  - `poltergeist-mcp` may be off in the config (App.syncPoltergeistServer'
    Write-Host '    only binds when it is on);'
    Write-Host '  - or the bind failed, in which case the host log has the error.'
    Write-Host 'Check the log for a poltergeist line before concluding anything about'
    Write-Host 'the transport. A pipe that was never asked for and a pipe that failed'
    Write-Host 'to open look identical from out here.'
    exit 1
}

Write-Host "found $($pipes.Count) pipe(s):"
$pipes | ForEach-Object { Write-Host "  $_" }

$target = $pipes[0]
Write-Host ''
Write-Host "--- 2. does it accept? (target: $target) ---"

$client = $null
try {
    $client = Connect-Pipe -Name $target -Timeout $TimeoutMs
    Write-Host 'CONNECTED. The listener exists and accepted a connection.'
} catch {
    Write-Host "CONNECT FAILED: $($_.Exception.Message)"
    Write-Host ''
    Write-Host 'The pipe is named but would not accept. This is the second cause:'
    Write-Host 'the access control on the pipe, or the syscall surface underneath.'
    Write-Host '`transport_windows.zig` creates the pipe with a DACL naming the owning'
    Write-Host 'user and nobody else -- so running this probe as a different user is a'
    Write-Host 'refusal by design, not a defect. Check who owns the polter process'
    Write-Host 'before reading this as broken.'
    exit 1
}

Write-Host ''
Write-Host '--- 3. does it serve? ---'

if (-not $Token) {
    Write-Host 'SKIPPED: no token. Run `echo %GHOSTTY_POLTER_TOKEN%` inside a Polter'
    Write-Host '         terminal and pass it with -Token.'
    Write-Host ''
    Write-Host 'Reading so far: the endpoint exists and accepts. Whether it answers is'
    Write-Host 'UNTESTED -- which is not the same as working. Do not record this run as'
    Write-Host 'a pass.'
    $client.Dispose()
    exit 2
}

# The negative control, FIRST. A probe that only ever sends the right token
# cannot tell "the server accepted my token" from "the server says ok to
# anything" or from "my reader returns something that merely looks like a
# reply". The wrong token must be refused, and it must be refused in a way
# this script can see.
Write-Host 'negative control: a deliberately wrong token'
$bad = $null
try {
    $badClient = Connect-Pipe -Name $target -Timeout $TimeoutMs
    $bad = Invoke-Auth -Client $badClient -TokenValue 'not-a-real-token-0000'
    $badClient.Dispose()
} catch {
    $bad = "<error: $($_.Exception.Message)>"
}
Write-Host "  reply: $bad"

if ($bad -match '"ok"\s*:\s*true') {
    Write-Host ''
    Write-Host 'FLOOR FAILED: a wrong token was accepted. Every result below is'
    Write-Host '              meaningless until this is understood -- the check cannot'
    Write-Host '              distinguish an accepted token from an accepted anything.'
    $client.Dispose()
    exit 1
}
Write-Host '  floor OK: the wrong token was not accepted, so a later `ok:true` means'
Write-Host '            something.'

Write-Host ''
Write-Host 'real token:'
$reply = Invoke-Auth -Client $client -TokenValue $Token
Write-Host "  reply: $reply"
$client.Dispose()

if ($reply -match '"ok"\s*:\s*true') {
    Write-Host ''
    Write-Host 'SERVES OK. Bind, accept and handshake all work on this platform.'
    Write-Host ''
    Write-Host 'Which means the transport is NOT the reason the chat window fails.'
    Write-Host 'The remaining cause is on the client side; see the task 131 report.'
    exit 0
} else {
    Write-Host ''
    Write-Host 'HANDSHAKE REFUSED with a real token. The endpoint serves but did not'
    Write-Host 'accept this terminal. Most likely the token came from a different'
    Write-Host 'polter process than the pipe -- check that the terminal you read'
    Write-Host 'GHOSTTY_POLTER_SOCKET/TOKEN from is the one still running, and that'
    Write-Host 'the socket name it carries matches the pipe above.'
    exit 1
}
