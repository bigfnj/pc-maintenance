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
    param([Parameter(Mandatory)][hashtable]$Context)
    $root = Get-AgentScratchRoot -Context $Context
    if (-not (Test-PMPath -Path $root)) { return @() }
    $cutUtc = (Get-Date).ToUniversalTime().AddDays(-$script:AgentIdleDays)
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in (Get-AgentSessionDirectory -Root $root)) {
        # Stops walking the moment it finds anything newer than the cutoff, so an active session
        # costs one file read and only genuinely idle ones are walked in full.
        $newest = Get-PMNewestWriteUtc -Path $s.FullName -NewerThanUtc $cutUtc
        if ($newest -gt $cutUtc) { continue }
        $out.Add([pscustomobject]@{
            Path     = $s.FullName
            Bytes    = (Get-PMPathSize -Path $s.FullName)
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
        Items  = @($items | Sort-Object Bytes -Descending | Select-Object -First 25 | ForEach-Object {
                    @{ path = $_.Path; bytes = $_.Bytes; idleDays = $_.IdleDays; project = $_.Project } })
    }
}

function Repair-PMModule {
    param([Parameter(Mandatory)][hashtable]$Context)
    $root  = Get-AgentScratchRoot -Context $Context
    $items = @(Get-AgentScratchCandidates -Context $Context)
    $freed = [int64]0; $removed = 0; $vetoed = 0; $locked = 0; $gone = 0
    foreach ($i in $items) {
        $r = Remove-PMPath -Path $i.Path -Roots @($root) -DeclaredRoots @($Context.DeclaredRoots) `
                           -KnownBytes ([int64]$i.Bytes)
        if ($r.Removed) { $removed++; $freed += [int64]$r.Bytes; continue }
        switch -Wildcard ($r.Reason) {
            '*refused*'  { $vetoed++ }
            '*outside*'  { $vetoed++ }
            '*declared*' { $vetoed++ }
            'gone'       { $gone++ }
            default      { $locked++ }
        }
    }
    [pscustomobject]@{
        Ok     = ($vetoed -eq 0)
        Bytes  = $freed
        Detail = ('removed {0} of {1}; {2} vetoed by the path guard, {3} locked, {4} already gone' -f
                    $removed, @($items).Count, $vetoed, $locked, $gone)
    }
}
