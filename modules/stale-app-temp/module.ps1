#Requires -Version 5.1
<#
    stale-app-temp - named application scratch under the user TEMP. Report-only.

    Deliberately a NAMED list rather than "everything in TEMP older than N days": an allowlist
    of things somebody has actually looked at, so a directory nobody has classified is reported
    by its absence from the list rather than deleted by a rule that happened to match it.
#>

$script:StaleAppNames = @(
    'Adobe', 'CreativeCloud', 'OCCT', 'WinGet', 'Diagnostics', 'DiagOutputDir'
)
$script:StaleAppPrefixes = @('7zO', 'pip-unpack-')
$script:StaleDays = 30

function Get-StaleTempRoot {
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context.UserProfile) { return (Join-Path $Context.UserProfile 'AppData\Local\Temp') }
    return $env:TEMP
}

function Get-StaleAppCandidates {
    param([Parameter(Mandatory)][hashtable]$Context)
    $root = Get-StaleTempRoot -Context $Context
    $cut  = (Get-Date).AddDays(-$script:StaleDays)
    $out  = @()
    foreach ($d in (Get-PMChildDirectory -Path $root)) {
        $named    = $script:StaleAppNames -contains $d.Name
        $prefixed = @($script:StaleAppPrefixes | Where-Object { $d.Name.StartsWith($_, 'OrdinalIgnoreCase') }).Count -gt 0
        if (-not ($named -or $prefixed)) { continue }
        if ($d.LastWriteTime -ge $cut) { continue }
        $out += [pscustomobject]@{
            Path = $d.FullName; Bytes = (Get-PMPathSize -Path $d.FullName)
            AgeDays = [int]((Get-Date) - $d.LastWriteTime).TotalDays
        }
    }
    return $out
}

function Test-PMModule {
    param([Parameter(Mandatory)][hashtable]$Context)
    $items = @(Get-StaleAppCandidates -Context $Context)
    $bytes = [int64](@($items | Measure-Object Bytes -Sum).Sum)
    if (-not $items) {
        return [pscustomobject]@{ Clean = $true; Detail = "no known app scratch older than $($script:StaleDays)d"; Bytes = [int64]0; Items = @() }
    }
    [pscustomobject]@{
        Clean  = $false
        Count  = @($items).Count
        Detail = ('{0} stale app folder(s), oldest {1}d' -f @($items).Count, (@($items | Measure-Object AgeDays -Maximum).Maximum))
        Bytes  = $bytes
        Items  = @($items | Sort-Object Bytes -Descending | ForEach-Object {
                    @{ path = $_.Path; bytes = $_.Bytes; ageDays = $_.AgeDays } })
    }
}

function Repair-PMModule {
    param([Parameter(Mandatory)][hashtable]$Context)
    # Reachable only if someone sets AutoApply on this module, which its own psd1 argues
    # against. Written correctly anyway rather than left to throw: a Repair that exists but is
    # wrong is worse than one that is never called.
    $root  = Get-StaleTempRoot -Context $Context
    $items = @(Get-StaleAppCandidates -Context $Context)
    $freed = [int64]0; $removed = 0; $refused = 0
    foreach ($i in $items) {
        $r = Remove-PMPath -Path $i.Path -Roots @($root) -WhatIfOnly:(-not $Context.Apply)
        if ($r.Removed) { $removed++; $freed += [int64]$r.Bytes }
        elseif ($r.Skipped) { $refused++ }
    }
    [pscustomobject]@{
        Changed = ($removed -gt 0); Ok = $true; Bytes = $freed
        Detail  = ('removed {0} of {1}; {2} locked or refused' -f $removed, @($items).Count, $refused)
    }
}
