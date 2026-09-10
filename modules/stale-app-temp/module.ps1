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
    # List, not +=. The other three modules made this change after measuring it at 13,341
    # appends: 6,733 ms for += versus 248 ms here, because += reallocates the whole array every
    # time. This module's allowlist keeps the count small today; the cost of leaving it is that
    # it is the copy the next module gets cloned from.
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in (Get-PMChildDirectory -Path $root -Critical)) {
        $named    = $script:StaleAppNames -contains $d.Name
        $prefixed = @($script:StaleAppPrefixes | Where-Object { $d.Name.StartsWith($_, 'OrdinalIgnoreCase') }).Count -gt 0
        if (-not ($named -or $prefixed)) { continue }
        if ($d.LastWriteTime -ge $cut) { continue }
        $out.Add([pscustomobject]@{
            Path = $d.FullName; Bytes = (Get-PMPathSize -Path $d.FullName)
            AgeDays = [int]((Get-Date) - $d.LastWriteTime).TotalDays
        })
    }
    return $out.ToArray()
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
        # Capped like the other three. This was the ONE uncapped Items in the run JSON, and the
        # combination that makes that dangerous is specific to this module: its 7zO* and
        # pip-unpack-* prefixes recur without limit, and AutoApply = $false means it never
        # deletes them, so its match set only grows. The JSON is written twice per run and kept
        # 50 runs deep. The true number still travels in Count, and sorting by size descending
        # means the 25 shown are the 25 worth acting on.
        Items  = @($items | Sort-Object Bytes -Descending | Select-Object -First 25 | ForEach-Object {
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
    $freed = [int64]0; $removed = 0; $vetoed = 0; $locked = 0; $gone = 0
    foreach ($i in $items) {
        # KnownBytes saves the walk inside Remove-PMPath. It does NOT carry a size over from
        # Test: Repair re-derives candidates above, and that measures Bytes inline, so the
        # number here is microseconds old rather than a phase old. The comment used to claim
        # the saving was against Test, which was never true. Re-deriving is deliberate - it
        # re-applies every selection rule at delete time - so only the sizing is waste.
        $r = Remove-PMPath -Path $i.Path -Roots @($root) -DeclaredRoots @($Context.DeclaredRoots) `
                           -KnownBytes ([int64]$i.Bytes)
        if ($r.Removed) { $removed++; $freed += [int64]$r.Bytes; continue }
        # One shared mapping in PMCommon, not a copy per module. The copies drifted: three of
        # the four never gained an arm for 'no declared roots supplied', so a guard refusal was
        # counted as 'locked' and Ok = ($vetoed -eq 0) stayed TRUE.
        switch (Get-PMRemovalBucket -Reason $r.Reason) {
            'vetoed' { $vetoed++ }
            'gone'   { $gone++ }
            default  { $locked++ }
        }
    }
    # Ok reflects what actually happened. Returning $true unconditionally meant a run in which the
    # guard refused every single target still rendered a green "Cleaned" badge.
    $ok = ($vetoed -eq 0)
    [pscustomobject]@{
        Ok     = $ok
        Bytes  = $freed
        Detail = ('removed {0} of {1}; {2} vetoed by the path guard, {3} locked, {4} already gone' -f
                    $removed, @($items).Count, $vetoed, $locked, $gone)
    }
}
