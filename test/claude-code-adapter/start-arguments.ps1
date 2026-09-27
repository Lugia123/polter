# Does `adapter.ps1` hand `claude --version` its arguments on Windows
# PowerShell 5.1? (#888)
#
#     pwsh -NoProfile -File test/claude-code-adapter/start-arguments.ps1
#     powershell -NoProfile -ExecutionPolicy Bypass -File test\claude-code-adapter\start-arguments.ps1
#
# 5.1 is .NET Framework, whose ProcessStartInfo has no `ArgumentList` -- the
# property is not there, and under the adapter's `Set-StrictMode -Version 2.0`
# reading it throws. The adapter caught that as "could not run claude
# --version" and configured no hooks on the test machine.
#
# This loads only `ConvertTo-WindowsArgument` and `Set-StartArguments` out of
# the adapter (by parsing it; the adapter's own `exit` never runs) and checks:
#
#   1. **A start-info shaped like 5.1's** -- an object with `FileName` and
#      `Arguments` and no `ArgumentList` at all, under StrictMode 2.0 -- gets
#      one `Arguments` string. Also with `ArgumentList` present but `$null`.
#   2. **The real ProcessStartInfo of whichever PowerShell runs this**: on
#      Core the list is used and `Arguments` left empty; on 5.1 (Desktop) the
#      string is used. Run under `powershell.exe` on Windows, this is the one
#      case that is not a stand-in.
#   3. **The quoting undoes**: a real process is started with the built
#      string and says back the argv it received. Off Windows the split is
#      .NET's own implementation of the Windows rules; on Windows it is the
#      child's C runtime reading a real command line. Needs Python as the
#      child; without one this case says SKIPPED, not passed.
#
# What it does not show: that `claude.exe` itself reads its command line with
# those rules (it is not started here), and anything about 5.1 when run
# under pwsh -- there, cases 1 and 3 are stand-ins for it.
#
# Exit: 0 when every case that ran agreed, 1 otherwise.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$adapter = Join-Path (Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'plugins') 'claude-code') 'adapter.ps1'

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($adapter, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { Write-Output "adapter.ps1 does not parse: $($errors[0])"; exit 1 }
foreach ($name in @('ConvertTo-WindowsArgument', 'Set-StartArguments')) {
    $def = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name }, $true)
    if (@($def).Count -ne 1) { Write-Output "adapter.ps1 has no single function $name"; exit 1 }
    . ([scriptblock]::Create(@($def)[0].Extent.Text))
}

$script:failures = 0
function Report([string]$Name, [bool]$Ok, [string]$Detail) {
    $status = $(if ($Ok) { 'ok       ' } else { 'FAILED   ' })
    Write-Output ($status + $Name + $(if ($Detail) { ' -- ' + $Detail } else { '' }))
    if (-not $Ok) { $script:failures++ }
}

$argv = @('C:\Program Files\nodejs\node_modules\@anthropic-ai\claude-code\cli.js', '--version')
$want = '"C:\Program Files\nodejs\node_modules\@anthropic-ai\claude-code\cli.js" --version'

# 1. Stand-ins for 5.1's ProcessStartInfo.
$absent = New-Object PSObject -Property ([ordered]@{ FileName = 'node.exe'; Arguments = '' })
try {
    Set-StartArguments $absent $argv
    Report '5.1 shape: no ArgumentList property' ($absent.Arguments -ceq $want) ("Arguments = <" + $absent.Arguments + ">")
} catch {
    Report '5.1 shape: no ArgumentList property' $false ('threw: ' + $_.Exception.Message)
}
$nullList = New-Object PSObject -Property ([ordered]@{ FileName = 'node.exe'; Arguments = ''; ArgumentList = $null })
try {
    Set-StartArguments $nullList $argv
    Report 'ArgumentList present but $null' ($nullList.Arguments -ceq $want) ("Arguments = <" + $nullList.Arguments + ">")
} catch {
    Report 'ArgumentList present but $null' $false ('threw: ' + $_.Exception.Message)
}

# 2. The real one.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'node.exe'
Set-StartArguments $psi $argv
$desktop = $PSVersionTable.PSEdition -eq 'Desktop'
if ($desktop) {
    Report ('real ProcessStartInfo, ' + $PSVersionTable.PSVersion + ' Desktop: Arguments string') ($psi.Arguments -ceq $want) ("Arguments = <" + $psi.Arguments + ">")
} else {
    $got = @($psi.ArgumentList)
    $ok = ($psi.Arguments -ceq '') -and ($got.Count -eq 2) -and ($got[0] -ceq $argv[0]) -and ($got[1] -ceq $argv[1])
    Report ('real ProcessStartInfo, ' + $PSVersionTable.PSVersion + ' Core: ArgumentList') $ok ("ArgumentList = " + ($got -join ' | '))
}

# 3. The quoting undoes, through a real process.
$py = $null
foreach ($n in @('python3', 'python')) {
    $c = Get-Command -Name $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $c) { $py = [string]$c.Path; break }
}
$hard = @('plain', 'with space', '', 'quote"inside', 'trailing\', 'C:\Program Files\x\', 'a\\"b', "tab`there", '\\server\share', '"')
if ($null -eq $py) {
    Write-Output 'SKIPPED  round trip through a real process: no python3 or python on PATH'
} else {
    $code = 'import sys,json; sys.stdout.write(json.dumps(sys.argv[1:]))'
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $py
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.Arguments = (@('-c', $code) + $hard | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
    $p = [System.Diagnostics.Process]::Start($start)
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $back = @()
    if ($desktop) {
        Add-Type -AssemblyName System.Web.Extensions
        $back = @((New-Object System.Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($out))
    } else {
        $back = @([System.Text.Json.JsonSerializer]::Deserialize($out, [string[]]))
    }
    $same = $back.Count -eq $hard.Count
    for ($k = 0; $same -and $k -lt $hard.Count; $k++) { if (-not ([string]$back[$k] -ceq $hard[$k])) { $same = $false } }
    Report ('round trip through a real process (' + $hard.Count + ' arguments)') $same ('child said ' + $out)
}

Write-Output ''
if ($script:failures -gt 0) { Write-Output "$($script:failures) case(s) failed"; exit 1 }
Write-Output 'all cases that ran agreed'
exit 0
