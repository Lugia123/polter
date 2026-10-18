# Helper for hook-command-parses.py (task 1748). ASCII only.
# Reads a JSON file of {path, event} cases; for each, writes what
# hooks.ps1 makes of it on Windows, and what PowerShell's own parser makes
# of a line: the errors, the call operator, the command's name and its
# arguments.
param([string]$Hooks, [string]$Cases)
. $Hooks
$out = [System.Collections.Generic.List[object]]::new()
foreach ($c in (Get-Content -Raw -Encoding UTF8 $Cases | ConvertFrom-Json)) {
    $line = if ($null -ne $c.line) { [string]$c.line } else { Get-CodexHookCommand $c.path $c.event $true }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$errors)
    $cmd = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Select-Object -First 1
    $name = $null; $op = $null; $rest = @()
    if ($null -ne $cmd) {
        $op = [string]$cmd.InvocationOperator
        $first = $cmd.CommandElements[0]
        if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $name = $first.Value }
        $rest = @($cmd.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text })
    }
    $hash = if ($null -ne $c.line) { $null } else { Get-CodexHookTrustedHash $c.label $line }
    $out.Add([ordered]@{ line = $line; errors = @($errors).Count; op = $op; name = $name; args = $rest; hash = $hash })
}
ConvertTo-Json -InputObject $out.ToArray() -Depth 5 -Compress
