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
    param([Parameter(Mandatory)][hashtable]$Context, [hashtable]$KnownSizes)
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
            Path = $d.FullName; Bytes = (Get-PMKnownOrMeasuredSize -Path $d.FullName -Known $KnownSizes)
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
        # Handed to Repair via the context so it does not re-measure what was just
        # measured. In memory only - uncapped by design, and never serialized, which is
        # why the dispatcher copies it to $ctx and not to the run row.
        Sizes  = (ConvertTo-PMSizeMap -Items $items)
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
    $items = @(Get-StaleAppCandidates -Context $Context -KnownSizes $Context.KnownSizes)
    $freed = [int64]0; $removed = 0; $vetoed = 0; $locked = 0; $gone = 0
    foreach ($i in $items) {
        # KnownBytes saves the walk inside Remove-PMPath, and the size itself now comes from
        # Test via $Context.KnownSizes rather than being measured again here. Re-deriving the
        # candidate LIST is still deliberate - it re-applies every selection rule at delete
        # time, which is what spares a path that became active in between - but re-measuring
        # it was pure waste. A candidate that appeared since Test is absent from the map and
        # gets measured normally.
        $r = Remove-PMPath -Path $i.Path -Roots @($root) -DeclaredRoots @($Context.DeclaredRoots) `
                           -KnownBytes ([int64]$i.Bytes)
        # Credited BEFORE the success test, and outside it. Remove-Item -Recurse can delete most
        # of a tree and then throw, and Remove-PMPath re-measures precisely so it can report
        # what it did free - "the one thing the audit trail must never get wrong", says the
        # comment there. All four modules then discarded that number, because this guard only
        # credited a full success: a partial delete recorded 0 B in the record that stands in
        # for a backup. Measured on 2026-09-10 against THIS module with one locked file: 6,000
        # of 6,050 B really gone, logged as nothing. Bytes is 0 on every other outcome, so this
        # is unconditional.
        $freed += [int64]$r.Bytes
        if ($r.Removed) { $removed++; continue }
        # One shared mapping in PMCommon, not a copy per module. The copies drifted: three of
        # the four never gained an arm for 'no declared roots supplied', so a guard refusal was
        # counted as 'locked' and Ok = ($vetoed -eq 0) stayed TRUE.
        switch (Get-PMRemovalBucket -Reason $r.Reason) {
            'vetoed' { $vetoed++ }
            'gone'   { $gone++ }
            default  { $locked++ }
        }
    }
    # Counters, not a verdict. Ok = ($vetoed -eq 0) used to travel from here, and it answered
    # "did the guard refuse anything?" while the dispatcher read it as "did the cleanup work?" -
    # BACKLOG 7h. The dispatcher now decides from these numbers with the same shared function,
    # for the reason the declared roots are its and not the module's: a module's own verdict on
    # its own run is self-certification.
    $outcome = Get-PMRepairOutcome -Attempted @($items).Count -Removed $removed `
                                   -Vetoed $vetoed -Locked $locked -Gone $gone
    [pscustomobject]@{
        Attempted = @($items).Count
        Removed   = $removed
        Vetoed    = $vetoed
        Locked    = $locked
        Gone      = $gone
        Bytes     = $freed
        Detail    = $outcome.Detail
    }
}
