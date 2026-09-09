#Requires -Version 5.1
<#
    agent-scratchpads - per-session coding-agent scratch. Report-only by design; see module.psd1
    for why an age floor is not a liveness check.
#>

$script:AgentIdleDays = 14

function Get-AgentScratchRoot {
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context.UserProfile) { return (Join-Path $Context.UserProfile 'AppData\Local\Temp\claude') }
    return (Join-Path $env:TEMP 'claude')
}

function Get-AgentScratchCandidates {
    param([Parameter(Mandatory)][hashtable]$Context)
    $root = Get-AgentScratchRoot -Context $Context
    if (-not (Test-PMPath -Path $root)) { return @() }
    $cut = (Get-Date).AddDays(-$script:AgentIdleDays)
    $out = @()
    # Layout is <root>\<project-slug>\<session-guid>\..., so the session directory is one level
    # down. Reporting per session rather than per project keeps a busy project from masking one
    # abandoned session, and vice versa.
    foreach ($proj in (Get-PMChildDirectory -Path $root)) {
        foreach ($sess in (Get-PMChildDirectory -Path $proj.FullName)) {
            if ($sess.LastWriteTime -ge $cut) { continue }
            $out += [pscustomobject]@{
                Path = $sess.FullName; Bytes = (Get-PMPathSize -Path $sess.FullName)
                Project = $proj.Name
                IdleDays = [int]((Get-Date) - $sess.LastWriteTime).TotalDays
            }
        }
    }
    return $out
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
    # Intentionally refuses even when called. AutoApply is off in the manifest, so the dispatcher
    # never reaches this; if someone flips that without adding the liveness check the psd1 asks
    # for, failing loudly here is better than deleting a running session's working directory.
    [pscustomobject]@{
        Changed = $false
        Ok      = $false
        Bytes   = [int64]0
        Detail  = 'refused: this module needs a session-liveness check before it may delete. See module.psd1.'
    }
}
