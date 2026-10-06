# Check that every mosaic in a screenshot is one colour per block.
#
#   powershell -File verify-mosaic.ps1 -Png <shot.png> [-Json <shot.json>]
#   powershell -File verify-mosaic.ps1 -Png <any.png> -Rect 10,20,300,200 -Block 12 -Scale 1.5
#
# Exit codes, so that a wrong command line cannot pass for a failed check:
#   0  every block of every mosaic is one colour
#   1  at least one block is not (or a mosaic lies outside the image)
#   2  nothing was checked: no mosaic annotation in the .json
#   3  the command line is wrong (said on a line starting USAGE ERROR)
#   4  the script itself failed (a file that cannot be read, ...) -- ERROR
#
# -Rect is taken as text and split here. Declared as [int[]], `-File ...
# -Rect 5,25,200,100` handed PowerShell the one string "5,25,200,100", which
# it read as a single number with thousands separators; the script then
# refused it and exited 1 -- the same code as a mosaic that failed, on a
# command that had checked nothing (task 1090).
#
# With -Json (default: the .json beside the .png) it reads each annotation of
# type "mosaic" -- its rect and its block step -- and the shot's scale. With
# -Rect/-Block it checks that rectangle as if it were a mosaic: use it on a
# part of a picture that is NOT a mosaic to see this script say so (the
# negative control; without it "nonuniform=0" could mean the script looks at
# nothing).
#
# The block edge and the way a side is cut are the rules of
# dev-docs/poltergeist/screenshot.md 9.5 and 9.7, restated here:
#   edge  = max(round(step * scale), ceil(short side / k)),  k by step: 8->12 12->10 16->8 24->6 32->4
#   a side: whole blocks; a remainder under half a block joins the last block,
#           half or more is a block of its own; shorter than a block is one block.
#
# What was and was not run before this was packed: the two functions below
# (Get-Spans, Get-BlockPx) were run under PowerShell 7 on a Mac and agree with
# the product's own tests; everything that touches System.Drawing was not --
# it does not load there. If it throws, report the error text.
#
# One case it does not model: a mosaic that ran off the edge of the *monitor*
# (not just of the selection). The product anchors the blocks at the part on
# the monitor; this anchors them at the rectangle in the .json.
param(
    [Parameter(Mandatory = $true)][string]$Png,
    [string]$Json,
    [string]$Rect,
    [int]$Block = 12,
    [double]$Scale = 0
)
$ErrorActionPreference = 'Stop'
trap { "ERROR (the script failed; this is not a check result): $_"; exit 4 }

$rectParts = $null
if ($Rect) {
    $rectParts = @($Rect -split '[,\s]+' | Where-Object { $_ -ne '' })
    $bad = @($rectParts | Where-Object { $_ -notmatch '^-?\d+$' })
    if ($rectParts.Count -ne 4 -or $bad.Count -gt 0) {
        "USAGE ERROR: -Rect takes four whole numbers x,y,w,h; got '$Rect' ($($rectParts.Count) part(s))"
        exit 3
    }
    $rectParts = @($rectParts | ForEach-Object { [int]$_ })
    if ($rectParts[2] -le 0 -or $rectParts[3] -le 0) {
        "USAGE ERROR: -Rect width and height must be positive; got '$Rect'"
        exit 3
    }
    if (@(8, 12, 16, 24, 32) -notcontains $Block) {
        "USAGE ERROR: -Block must be one of 8, 12, 16, 24, 32; got $Block"
        exit 3
    }
}
Add-Type -AssemblyName System.Drawing

function Get-Spans([int]$len, [int]$block) {
    if ($len -le 0) { return @() }
    if ($len -le $block) { return ,@(,@(0, $len)) }
    $whole = [math]::Floor($len / $block); $rest = $len % $block
    $out = @()
    for ($i = 0; $i -lt $whole; $i++) { $out += ,@(($i * $block), $block) }
    if ($rest * 2 -ge $block) { $out += ,@(($whole * $block), $rest) }
    elseif ($rest -gt 0) { $last = $out[$out.Count - 1]; $out[$out.Count - 1] = @($last[0], ($last[1] + $rest)) }
    # The comma keeps a one-block result from being unrolled into two numbers.
    return ,$out
}

function Get-BlockPx([int]$step, [double]$scale, [int]$short) {
    $k = @{ 8 = 12; 12 = 10; 16 = 8; 24 = 6; 32 = 4 }[$step]
    if (-not $k) { throw "block step $step is not one of 8, 12, 16, 24, 32" }
    $byStep = [math]::Max(1, [int][math]::Round($step * $scale, [MidpointRounding]::AwayFromZero))
    $bySide = [int][math]::Ceiling($short / $k)
    return [math]::Max($byStep, $bySide)
}

$bmp = New-Object System.Drawing.Bitmap((Resolve-Path -LiteralPath $Png).Path)
"image $($bmp.Width) x $($bmp.Height)  $Png"

$targets = @()
if ($rectParts) {
    if ($Scale -le 0) { $Scale = 1.0 }
    $targets += ,@($rectParts[0], $rectParts[1], $rectParts[2], $rectParts[3], $Block)
} else {
    if (-not $Json) { $Json = [IO.Path]::ChangeExtension((Resolve-Path -LiteralPath $Png).Path, '.json') }
    $doc = Get-Content -LiteralPath $Json -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Scale -le 0) { $Scale = [double]$doc.scale }
    foreach ($a in $doc.annotations) {
        if ($a.type -eq 'mosaic') {
            $extra = @($a.PSObject.Properties.Name | Where-Object { $_ -notin 'type', 'rect', 'block' })
            "json mosaic entry keys: $(@($a.PSObject.Properties.Name) -join ',')  extra=$($extra.Count)"
            $targets += ,@([int]$a.rect[0], [int]$a.rect[1], [int]$a.rect[2], [int]$a.rect[3], [int]$a.block)
        }
    }
}
"mosaics to check: $($targets.Count)  scale=$Scale"
if ($targets.Count -eq 0) { 'NOTHING CHECKED: no mosaic annotation found. This is not a pass.'; exit 2 }

$bad = 0
foreach ($t in $targets) {
    $x0, $y0, $w, $h, $step = $t
    $edge = Get-BlockPx $step $Scale ([math]::Min($w, $h))
    $nonuniform = 0; $blocks = 0; $pixels = 0; $colours = @{}
    foreach ($sy in (Get-Spans $h $edge)) {
        foreach ($sx in (Get-Spans $w $edge)) {
            $blocks++
            $first = $null; $mixed = $false
            for ($y = $sy[0]; $y -lt $sy[0] + $sy[1]; $y++) {
                $py = $y0 + $y; if ($py -lt 0 -or $py -ge $bmp.Height) { continue }
                for ($x = $sx[0]; $x -lt $sx[0] + $sx[1]; $x++) {
                    $px = $x0 + $x; if ($px -lt 0 -or $px -ge $bmp.Width) { continue }
                    $c = $bmp.GetPixel($px, $py).ToArgb(); $pixels++
                    if ($null -eq $first) { $first = $c } elseif ($c -ne $first) { $mixed = $true }
                }
            }
            if ($mixed) { $nonuniform++ }
            if ($null -ne $first) { $colours[$first] = 1 }
        }
    }
    "mosaic rect=$x0,$y0,$w,$h step=$step edge=${edge}px blocks=$blocks pixels_read=$pixels distinct_block_colours=$($colours.Count) nonuniform=$nonuniform"
    if ($pixels -eq 0) { '  NOTHING READ for this one (the rectangle is outside the image). Not a pass.'; $bad++ }
    $bad += $nonuniform
}
$bmp.Dispose()
if ($bad -eq 0) { 'RESULT: every block of every mosaic is one colour' } else { "RESULT: $bad problem(s)"; exit 1 }
