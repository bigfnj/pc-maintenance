#Requires -Version 5.1
<#
    agent-scratchpads - per-session scratch left by coding agents under %LOCALAPPDATA%\Temp\claude.

    Everything here is regenerable by construction: a scratchpad holds intermediate results and
    throwaway scripts. The durable record of a session (its transcript, and any large tool output
    that was persisted) lives under ~\.claude\projects\ and is never touched by this module, so a
    resumed session loses nothing but the convenience of a script it would rewrite.

    Two things make this safe enough to act on, and both are easy to get wrong:

    1. ONLY session directories. The same tree holds `bundled-skills` - shared skill payloads a
       running session loads from - and `cache-break-state-*.json`. A rule matching "anything old
       under Temp\claude" would break skills. So a candidate's NAME must be a session GUID.

    2. Age comes from the NEWEST FILE INSIDE, never the directory's own mtime. Windows bumps a
       directory's timestamp only when its own entries change, so a session root's mtime is
       effectively its creation time. Measured on a live session: root 06:01, newest file inside
       14:29. Trusting the directory would delete an in-flight session that had been running
       longer than the idle floor.
#>

$script:AgentIdleDays = 14
# Both shapes the tree uses: <project-slug>\<session-guid>\ and a bare <session-guid>\ at the top.
$script:AgentSessionGuid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
# Shared infrastructure living in the same tree that must never be considered.
$script:AgentNeverTouch = @('bundled-skills', 'auto-mode-classifier-errors')

function Get-AgentScratchRoot {
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context.UserProfile) { return (Join-Path $Context.UserProfile 'AppData\Local\Temp\claude') }
    return (Join-Path $env:TEMP 'claude')
}

function Get-AgentSessionDirectory {
    # Every directory whose NAME is a session GUID, at either of the two depths in use.
    param([Parameter(Mandatory)][string]$Root)
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($top in (Get-PMChildDirectory -Path $Root -Critical)) {
        if ($top.Name -match $script:AgentSessionGuid) { $out.Add($top); continue }
        if ($script:AgentNeverTouch -contains $top.Name) { continue }
        foreach ($sub in (Get-PMChildDirectory -Path $top.FullName)) {
            if ($sub.Name -match $script:AgentSessionGuid) { $out.Add($sub) }
        }
    }
    return $out.ToArray()
}

function Get-AgentScratchCandidates {
    param([Parameter(Mandatory)][hashtable]$Context, [hashtable]$KnownSizes)
    $root = Get-AgentScratchRoot -Context $Context
    if (-not (Test-PMPath -Path $root)) { return @() }
    $cutUtc = (Get-Date).ToUniversalTime().AddDays(-$script:AgentIdleDays)
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in (Get-AgentSessionDirectory -Root $root)) {
        # ONE walk for both answers. Stops the moment it finds anything newer than the cutoff, so
        # an active session costs one file read and only genuinely idle ones are walked in full.
        #
        # This used to be two calls - a separate age walk, then Get-PMPathSize - running the same
        # traversal twice, and because a session only becomes a candidate by being IDLE, the age
        # walk never took its early exit for exactly the paths whose size was then wanted. Every
        # selected candidate was therefore walked twice, in full. At the measured peak of 933
        # idle sessions over 3.2 GB that is a whole redundant pass over the selected set.
        $stat = Get-PMTreeStat -Path $s.FullName -NewerThanUtc $cutUtc
        $newest = Resolve-PMTreeAge -Stat $stat -Path $s.FullName
        if ($newest -gt $cutUtc) { continue }
        # Complete is true here by construction: an early exit means it beat the cutoff, and that
        # path just took the `continue` above. Asserted rather than assumed, because reading a
        # partial Bytes would under-report what a deletion frees.
        $bytes = if ($KnownSizes -and $KnownSizes.ContainsKey($s.FullName)) { [int64]$KnownSizes[$s.FullName] }
                 elseif ($stat.Complete -and $stat.RootKind -eq 'dir') { [int64]$stat.Bytes }
                 else { Get-PMPathSize -Path $s.FullName }
        $out.Add([pscustomobject]@{
            Path     = $s.FullName
            Bytes    = $bytes
            Project  = (Split-Path (Split-Path $s.FullName -Parent) -Leaf)
            IdleDays = [int]((Get-Date).ToUniversalTime() - $newest).TotalDays
        })
    }
    return $out.ToArray()
}

function Test-PMModule {
    param([Parameter(Mandatory)][hashtable]$Context)
    $root = Get-AgentScratchRoot -Context $Context
    if (-not (Test-PMPath -Path $root)) {
        return [pscustomobject]@{ Clean = $true; Detail = 'no agent scratch root'; Bytes = [int64]0; Items = @() }
    }
    $items = @(Get-AgentScratchCandidates -Context $Context)
    $bytes = [int64](@($items | Measure-Object Bytes -Sum).Sum)
    if (-not $items) {
        return [pscustomobject]@{ Clean = $true; Detail = "no session idle more than $($script:AgentIdleDays)d"; Bytes = [int64]0; Items = @() }
    }
    [pscustomobject]@{
        Clean  = $false
        Count  = @($items).Count
        Detail = ('{0} session(s) idle >{1}d across {2} project(s)' -f
                    @($items).Count, $script:AgentIdleDays, @($items | Select-Object -ExpandProperty Project -Unique).Count)
        Bytes  = $bytes
        # Handed to Repair via the context so it does not re-measure what was just
        # measured. In memory only - uncapped by design, and never serialized, which is
        # why the dispatcher copies it to $ctx and not to the run row.
        Sizes  = (ConvertTo-PMSizeMap -Items $items)
        Items  = @($items | Sort-Object Bytes -Descending | Select-Object -First 25 | ForEach-Object {
                    @{ path = $_.Path; bytes = $_.Bytes; idleDays = $_.IdleDays; project = $_.Project } })
    }
}

function Repair-PMModule {
    param([Parameter(Mandatory)][hashtable]$Context)
    $root  = Get-AgentScratchRoot -Context $Context
    $items = @(Get-AgentScratchCandidates -Context $Context -KnownSizes $Context.KnownSizes)
    $freed = [int64]0; $removed = 0; $vetoed = 0; $locked = 0; $gone = 0
    foreach ($i in $items) {
        $r = Remove-PMPath -Path $i.Path -Roots @($root) -DeclaredRoots @($Context.DeclaredRoots) `
                           -KnownBytes ([int64]$i.Bytes)
        if ($r.Removed) { $removed++; $freed += [int64]$r.Bytes; continue }
        # One shared mapping in PMCommon, not a copy per module. This module was the only one
        # that had the '*declared*' arm; the other three counted that refusal as 'locked', which
        # left Ok = ($vetoed -eq 0) TRUE over a run the guard had refused outright.
        switch (Get-PMRemovalBucket -Reason $r.Reason) {
            'vetoed' { $vetoed++ }
            'gone'   { $gone++ }
            default  { $locked++ }
        }
    }
    [pscustomobject]@{
        Ok     = ($vetoed -eq 0)
        Bytes  = $freed
        Detail = ('removed {0} of {1}; {2} vetoed by the path guard, {3} locked, {4} already gone' -f
                    $removed, @($items).Count, $vetoed, $locked, $gone)
    }
}
