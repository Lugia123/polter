<#
.SYNOPSIS
  Read this window's accessibility tree from outside the process.

.DESCRIPTION
  The criterion for the UIA provider (`windows/host/src/uia.rs`), and it is
  deliberately built out of nothing we wrote: it goes through the operating
  system's own UI Automation client, starting from the desktop root, and finds
  the host by process id. Nothing here calls into `polter-host`; if the tree
  is not reachable this way, then no screen reader can reach it either, which
  is the failure this whole exercise exists to catch. "The tree was built but
  no tool can see it" and "the tree was never built" look identical from the
  inside, and only from out here do they come apart.

  Run under **Windows PowerShell 5.1** (`powershell.exe`). PowerShell 7
  (`pwsh`) does not ship the WPF assemblies these types live in, and the
  failure is `Add-Type` not finding `UIAutomationClient` -- which reads like a
  missing feature rather than the wrong shell.

.PARAMETER Mode
  floor       Take the reading BEFORE the provider exists. Expected: the
              window is found, and it has no TabItem and no Document under it.
              **This is the most important run in the file.** Without it, a
              broken script's empty output is indistinguishable from a
              provider that was never asked for -- so its output is a
              measurement, not a formality, and should be kept.
  tree        One window. Names, control types, runtime ids, rectangles.
  windows     Two or more windows. Checks each window lists only its own tabs
              and that no runtime id appears under two windows.
  concurrent  Dump repeatedly while a pane is producing output, then check
              against the host log how many reads actually reached
              libghostty.
  events      Subscribe to StructureChanged and PropertyChanged, then wait
              while the operator adds, closes, switches and renames tabs.
              **The only mode that exercises the provider with a client
              attached**, and therefore the only one that can reach the
              call-back path described in `docs/windows/uia.md`.

.PARAMETER LogPath
  The host's log, for the `concurrent` mode's counting. Defaults to the
  newest `polter-host-*.log` beside the exe.

.NOTES
  What this cannot tell you is in `docs/windows/uia.md`. The short version,
  because it is the one people forget: **a UIA client reaching the tree is not
  a screen reader reading it aloud.** This script proves the first and says
  nothing at all about the second.

  # This script deliberately does not locate anything by AutomationId --
  # and it did not start out deliberate

  It reads ControlType, Name, BoundingRectangle, RuntimeId and, for the
  document, ValuePattern. It never matches on AutomationId. **That was an
  accident when it was written**, and it is being made deliberate here,
  because the accident already nearly cost something:

  The window element's AutomationId is `w<n>`, and that `n` used to be the
  window's *position* in a registry, so closing one window renamed the rest.
  A script that had keyed on `"w1"` would have gone on finding an element --
  a real one, correctly formed, belonging to a different window -- and would
  have reported nothing wrong. The numbering was fixed in `081bc0546`, so
  that particular trap is gone; two reasons not to key on it remain, and
  neither is fixed by that commit:

    1. **The id is per process.** After Polter restarts, `w1` is the first
       window of the *new* run. A script that remembers an id across runs
       finds a window that exists and looks entirely normal, and is not the
       one it meant. Nothing errors.
    2. **Its range is now unbounded.** The number is a counter that only goes
       up, so a long session reaches `w17`, `w200`. Anything that assumed a
       small or fixed-width value is wrong, quietly.

  So: locate by structure (ControlType, tree position) and by content (Name,
  the document's text), which is what the modes below do. If you are about to
  add a lookup by AutomationId, this paragraph is the reason not to.
#>

[CmdletBinding()]
param(
    [ValidateSet('floor', 'tree', 'windows', 'concurrent', 'events')]
    [string]$Mode = 'tree',
    [string]$ProcessName = 'polter-host',
    [string]$LogPath = '',
    [int]$Iterations = 60,
    # Must stay ABOVE the provider's text TTL, which the host logs once as
    # `[uia] text cache ttl = Nms`. Below it, the dump loop is answered by the
    # cache and the concurrency check measures the cache instead of the
    # terminal -- it goes green and means nothing. The check below refuses to
    # run rather than let that happen quietly.
    [int]$IntervalMs = 600,
    # `events` only: how long to sit and listen after the subscription proves
    # itself. Long enough for a person to open, close, switch and rename.
    [int]$ListenSeconds = 120
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$AE   = [System.Windows.Automation.AutomationElement]
$Walk = [System.Windows.Automation.TreeWalker]::ControlViewWalker

function Get-HostProcesses {
    $p = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($p.Count -eq 0) { throw "no $ProcessName process is running" }
    return $p
}

function Get-HostWindows {
    param([int[]]$Pids)
    $found = @()
    foreach ($procId in $Pids) {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            $AE::ProcessIdProperty, $procId)
        # Children of the desktop only: a top-level window is a child of the
        # root, and searching Descendants here would walk every window on the
        # machine.
        $els = $AE::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children, $cond)
        foreach ($e in $els) { $found += $e }
    }
    return $found
}

function Format-RuntimeId {
    param($Element)
    try { return ($Element.GetRuntimeId() -join '.') } catch { return '<none>' }
}

function Write-Subtree {
    param($Element, [int]$Depth = 0, [System.Collections.ArrayList]$Sink = $null)

    $pad  = ' ' * ($Depth * 2)
    # AutomationId is deliberately absent from what is read here. See the
    # note at the top of the file -- the short version is that `w<n>` is only
    # unique within one run of the process.
    $type = $Element.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
    $name = $Element.Current.Name
    $rid  = Format-RuntimeId $Element
    $r    = $Element.Current.BoundingRectangle
    $rect = '{0},{1} {2}x{3}' -f [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height

    Write-Host ('{0}{1,-12} "{2}"  rid={3}  rect={4}' -f $pad, $type, $name, $rid, $rect)

    if ($null -ne $Sink) {
        [void]$Sink.Add([pscustomobject]@{
            Depth = $Depth; Type = $type; Name = $name; RuntimeId = $rid
        })
    }

    $child = $Walk.GetFirstChild($Element)
    while ($null -ne $child) {
        Write-Subtree -Element $child -Depth ($Depth + 1) -Sink $Sink
        $child = $Walk.GetNextSibling($child)
    }
}

function Get-DocumentText {
    param($WindowElement)
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)
    $docs = $WindowElement.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants, $cond)
    $out = @()
    foreach ($d in $docs) {
        $pattern = $null
        # ValuePattern, not TextPattern: the provider implements the first and
        # not the second, on purpose and at a cost written down in
        # `docs/windows/uia.md`. A script asking for TextPattern here would
        # fail for a reason that is scope, not a defect.
        if ($d.TryGetCurrentPattern(
                [System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            $out += [pscustomobject]@{
                Name = $d.Current.Name
                Text = $pattern.Current.Value
            }
        } else {
            $out += [pscustomobject]@{ Name = $d.Current.Name; Text = $null }
        }
    }
    return $out
}

function Resolve-LogPath {
    if ($LogPath) { return $LogPath }
    $proc = (Get-HostProcesses)[0]
    $dir  = Split-Path -Parent $proc.Path
    $cand = Get-ChildItem -Path $dir -Filter 'polter-host-*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $cand) { throw "no polter-host-*.log found in $dir; pass -LogPath" }
    return $cand.FullName
}

function Count-RealReads {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    return @(Select-String -Path $Path -SimpleMatch '[uia] read_text #').Count
}

function Get-LoggedTtlMs {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $m = Select-String -Path $Path -Pattern '\[uia\] text cache ttl = (\d+)ms' |
         Select-Object -Last 1
    if (-not $m) { return $null }
    return [int]$m.Matches[0].Groups[1].Value
}

# ------------------------------------------------------------------- modes

$procs = Get-HostProcesses
$procIds = @($procs | ForEach-Object { $_.Id })
Write-Host "host pid(s): $($procIds -join ', ')"

$windows = Get-HostWindows -Pids $procIds
Write-Host "top-level windows found: $($windows.Count)"
if ($windows.Count -eq 0) { throw 'the process is running but has no top-level UIA window' }

switch ($Mode) {

    'floor' {
        # The reading taken before the provider exists. Keep the output.
        $rows = New-Object System.Collections.ArrayList
        foreach ($w in $windows) { Write-Subtree -Element $w -Sink $rows }

        $tabs = @($rows | Where-Object { $_.Type -eq 'TabItem' })
        $docs = @($rows | Where-Object { $_.Type -eq 'Document' })
        Write-Host ''
        Write-Host "FLOOR: TabItem=$($tabs.Count) Document=$($docs.Count)"
        if ($tabs.Count -eq 0 -and $docs.Count -eq 0) {
            Write-Host 'FLOOR OK: the window is visible and carries neither, which is what'
            Write-Host '          makes a later non-empty reading mean something.'
        } else {
            Write-Host 'FLOOR UNEXPECTED: something already provides these. Either the patch is'
            Write-Host '                  present after all, or another provider is answering --'
            Write-Host '                  find out which before reading any later run.'
        }
    }

    'tree' {
        foreach ($w in $windows) {
            Write-Subtree -Element $w
            Write-Host ''
            foreach ($d in Get-DocumentText -WindowElement $w) {
                $preview = if ($null -eq $d.Text) { '<no ValuePattern>' }
                           else { ($d.Text -split "`n" | Where-Object { $_.Trim() } |
                                   Select-Object -Last 3) -join ' / ' }
                Write-Host ("  {0}: {1}" -f $d.Name, $preview)
            }
        }
    }

    'windows' {
        if ($windows.Count -lt 2) {
            throw "this mode needs at least two windows open; found $($windows.Count)"
        }
        $perWindow = @()
        foreach ($w in $windows) {
            $rows = New-Object System.Collections.ArrayList
            Write-Subtree -Element $w -Sink $rows
            Write-Host ''
            $perWindow += ,@($rows | Where-Object { $_.Type -eq 'TabItem' })
        }

        $ok = $true
        for ($i = 0; $i -lt $perWindow.Count; $i++) {
            for ($j = $i + 1; $j -lt $perWindow.Count; $j++) {
                $shared = @($perWindow[$i].RuntimeId | Where-Object { $perWindow[$j].RuntimeId -contains $_ })
                if ($shared.Count -gt 0) {
                    $ok = $false
                    Write-Host "FAIL: windows $i and $j share runtime id(s): $($shared -join ', ')"
                }
                $sameName = @($perWindow[$i].Name | Where-Object { $perWindow[$j].Name -contains $_ })
                if ($sameName.Count -gt 0) {
                    # Not a failure on its own -- two windows may legitimately
                    # have a tab called `cmd.exe`. Said out loud so a reader
                    # does not take matching names as evidence of the bug the
                    # runtime ids above actually test for.
                    Write-Host "note: windows $i and $j both have a tab named: $($sameName -join ', ')"
                }
            }
        }
        Write-Host ''
        Write-Host ("per-window tab counts: " + (($perWindow | ForEach-Object { $_.Count }) -join ', '))
        if ($ok) { Write-Host 'WINDOWS OK: no element is claimed by two windows.' }
    }

    'events' {
        # ------------------------------------------------------------------
        # The subscription has to prove itself BEFORE anything is concluded
        # from silence.
        #
        # "No events arrived" and "the subscription was never established"
        # print the same thing -- an empty list -- and this session has met
        # that shape five times tonight in five different disguises. So the
        # first thing this mode does is subscribe to something the operating
        # system raises on its own, and refuse to continue if it hears
        # nothing.
        #
        # **The self-test deliberately does not use our own events.** Using
        # the thing under test to prove the instrument means a host that
        # raises nothing fails both at once, with no way to tell which broke.
        # Focus changes are raised by UIA itself for any window the operator
        # clicks, including ones that are not ours.
        # ------------------------------------------------------------------
        $script:heard = New-Object System.Collections.ArrayList
        $script:focusSeen = $false

        $focusHandler = [System.Windows.Automation.AutomationFocusChangedEventHandler]{
            param($sender, $e)
            $script:focusSeen = $true
        }
        [System.Windows.Automation.Automation]::AddAutomationFocusChangedEventHandler($focusHandler)

        Write-Host 'instrument check: click any window (ours or not), twice.'
        Write-Host 'waiting up to 20s for a focus change from the system...'
        $deadline = (Get-Date).AddSeconds(20)
        while (-not $script:focusSeen -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
        [System.Windows.Automation.Automation]::RemoveAutomationFocusChangedEventHandler($focusHandler)

        if (-not $script:focusSeen) {
            Write-Host ''
            Write-Host 'INSTRUMENT FAILED: no focus change arrived from the system in 20s.'
            Write-Host '  This says nothing about Polter. It says this session cannot receive'
            Write-Host '  UIA events at all -- wrong shell, blocked by policy, or nothing was'
            Write-Host '  clicked. **Do not run the rest of this mode and do not record a'
            Write-Host '  zero**: a zero from here is indistinguishable from the defect.'
            exit 1
        }
        Write-Host 'instrument OK: this session can receive UIA events.'
        Write-Host ''

        # Now the real subscriptions, scoped to our windows' subtrees.
        $structHandler = [System.Windows.Automation.StructureChangedEventHandler]{
            param($sender, $e)
            [void]$script:heard.Add([pscustomobject]@{
                At   = (Get-Date).ToString('HH:mm:ss.fff')
                Kind = 'Structure/' + $e.StructureChangeType
                Name = $sender.Current.Name
                Type = $sender.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            })
        }
        $propHandler = [System.Windows.Automation.AutomationPropertyChangedEventHandler]{
            param($sender, $e)
            [void]$script:heard.Add([pscustomobject]@{
                At   = (Get-Date).ToString('HH:mm:ss.fff')
                Kind = 'Property/' + $e.Property.ProgrammaticName
                Name = $sender.Current.Name
                Type = $sender.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            })
        }

        foreach ($w in $windows) {
            [System.Windows.Automation.Automation]::AddStructureChangedEventHandler(
                $w, [System.Windows.Automation.TreeScope]::Subtree, $structHandler)
            [System.Windows.Automation.Automation]::AddAutomationPropertyChangedEventHandler(
                $w, [System.Windows.Automation.TreeScope]::Subtree, $propHandler,
                @([System.Windows.Automation.AutomationElement]::NameProperty,
                  [System.Windows.Automation.AutomationElement]::HasKeyboardFocusProperty))
        }

        Write-Host "subscribed to $($windows.Count) window(s). Now, in Polter:"
        Write-Host '  1. open a tab      2. switch tabs     3. rename a tab     4. close a tab'
        Write-Host "listening for $ListenSeconds seconds..."
        Start-Sleep -Seconds $ListenSeconds

        [System.Windows.Automation.Automation]::RemoveAllEventHandlers()

        Write-Host ''
        if ($script:heard.Count -eq 0) {
            Write-Host 'NO EVENTS. The instrument was proven working above, so this is a'
            Write-Host 'reading about Polter and not about the session: nothing was announced.'
            Write-Host 'That is exactly what the pre-patch build does -- keep this output if'
            Write-Host 'this is the floor run.'
            exit 1
        }
        $script:heard | ForEach-Object {
            Write-Host ("  {0}  {1,-42} {2,-10} `"{3}`"" -f $_.At, $_.Kind, $_.Type, $_.Name)
        }
        Write-Host ''
        Write-Host "total: $($script:heard.Count) event(s)"
        Write-Host 'Check against the table in docs/windows/uia.md. In particular: switching'
        Write-Host 'tabs must produce a HasKeyboardFocus PropertyChanged and NOT a'
        Write-Host 'StructureChanged -- a structure event there would be announcing something'
        Write-Host 'that did not happen.'
    }

    'concurrent' {
        $log = Resolve-LogPath
        Write-Host "log: $log"

        $ttl = Get-LoggedTtlMs -Path $log
        if ($null -eq $ttl) {
            Write-Host 'note: the host has not logged its text TTL yet (nothing has read the'
            Write-Host '      terminal). Open the tree once, then run this again.'
        } elseif ($IntervalMs -le $ttl) {
            throw ("interval ${IntervalMs}ms is not above the host's text cache TTL ${ttl}ms. " +
                   'Every dump after the first would be answered by the cache, and this check ' +
                   'would pass without reading the terminal even once. Raise -IntervalMs.')
        } else {
            Write-Host "host text cache ttl = ${ttl}ms; interval = ${IntervalMs}ms (above it)"
        }

        $before = Count-RealReads -Path $log
        Write-Host "read_text lines before: $before"

        $texts = @()
        for ($i = 0; $i -lt $Iterations; $i++) {
            foreach ($w in $windows) {
                foreach ($d in Get-DocumentText -WindowElement $w) { $texts += $d.Text }
            }
            Start-Sleep -Milliseconds $IntervalMs
        }

        $after = Count-RealReads -Path $log
        $real  = $after - $before
        Write-Host "read_text lines after:  $after  (delta $real)"

        $null_or_empty = @($texts | Where-Object { [string]::IsNullOrEmpty($_) }).Count
        Write-Host "document reads: $($texts.Count); empty or null: $null_or_empty"

        if ($real -lt $Iterations) {
            Write-Host ''
            Write-Host "FAIL: $Iterations dumps produced only $real real reads. The rest were the"
            Write-Host '      cache, so this run did not exercise the concurrent path it claims to.'
            Write-Host '      Raise -IntervalMs above the TTL, or find out why reads are being'
            Write-Host '      skipped. A green here without this line would have been meaningless.'
        } elseif ($null_or_empty -gt 0) {
            Write-Host ''
            Write-Host "FAIL: $null_or_empty read(s) came back empty while the pane was producing"
            Write-Host '      output. That is the torn or racing read this check exists to catch.'
        } else {
            Write-Host ''
            Write-Host "CONCURRENT OK: $real real reads, none empty, process still alive."
        }
    }
}
