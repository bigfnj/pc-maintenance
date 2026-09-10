#Requires -Version 5.1
<#
    vs-installer-scratch - Visual Studio Installer leftovers in the user TEMP folder.

    Reads state only through the PMCommon filesystem readers so tests can fake a tree.
#>

function Get-VsScratchRoot {
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context.UserProfile) { return (Join-Path $Context.UserProfile 'AppData\Local\Temp') }
    return $env:TEMP
}

function Get-VsScratchCandidates {
    <#
        Split out from Test so Repair reuses the identical selection instead of re-deriving it.
        Two paths that must agree is exactly the shape that drifts.
    #>
    param([Parameter(Mandatory)][hashtable]$Context, [hashtable]$KnownSizes)
    $root = Get-VsScratchRoot -Context $Context
    $cut = (Get-Date).AddHours(-24)
    # List, not +=. Measured under 5.1 at 13,341 appends: 6,733 ms for += versus 248 ms here,
    # because += reallocates the whole array every time.
    $out = New-Object 'System.Collections.Generic.List[object]'

    # ONE enumeration of the TEMP root, branched by name, where there used to be two.
    #
    # The old shape walked the root twice - once for extractions, once for payload caches -
    # partitioning the same 11,599 directories by the same regex, at ~335 ms a pass. Worse, the
    # second pass was NOT marked -Critical, so failing to list the root was recorded as mere
    # partial coverage in one loop and as blindness in the other, for the same failure. One read,
    # marked Critical once, is both faster and more honest.
    foreach ($d in (Get-PMChildDirectory -Path $root -Critical)) {
        $isScratchName = $d.Name -match '^[a-z0-9]{8}\.[a-z0-9]{3}$'
        if ($d.LastWriteTime -ge $cut) { continue }

        if ($isScratchName) {
            # A random name alone is not evidence. Require the installer's own fingerprint, so a
            # directory that merely looks like scratch survives.
            if (-not (Test-PMPath -Path (Join-Path $d.FullName 'setup.exe'))) { continue }
            if (-not (Test-PMPath -Path (Join-Path $d.FullName 'resources\app\ServiceHub'))) { continue }
            $out.Add([pscustomobject]@{ Path = $d.FullName; Kind = 'extraction'; Bytes = (Get-PMKnownOrMeasuredSize -Path $d.FullName -Known $KnownSizes) })
            continue
        }

        # The payload cache: one directory of already-applied .vsix / .msi downloads. Identified
        # by content rather than by its (random, stable) name, so this keeps working when it
        # changes.
        #
        # Native streaming enumeration, breaking on the first match. This probe runs once per
        # non-scratch directory older than 24h - 6,405 of them here - and it was the single
        # largest measured cost in the tool: 12,137 ms, twice per apply run, finding nothing.
        # Get-PMChildDirectory materialises EVERY subdirectory into FileInfo objects before the
        # pipeline filters them, so the work is proportional to the whole tree rather than to
        # the first hit. Measured on the same 6,405: 12,137 ms -> 458 ms, same result.
        #
        # An mtime horizon was measured first and rejected: 100% of the probe set was written
        # within a year and 90% within 180 days, so no cutoff short of a dangerous one helps.
        # A persisted cache of the discovered path was the other option, and is now unnecessary.
        $hasManifest = $false
        try {
            foreach ($sub in [IO.Directory]::EnumerateDirectories($d.FullName)) {
                if ([IO.Path]::GetFileName($sub) -match '\.Manifest-|Microsoft\.VisualStudio\.') { $hasManifest = $true; break }
            }
        } catch { Add-PMReadError -Errors $_ }
        if (-not $hasManifest) { continue }
        # Streaming, and it really does stop at the first hit. `@(... | Select-Object -First 1)`
        # did NOT: the @() forces the whole enumeration to finish before the pipeline sees anything.
        $hasVsix = $false
        $en = $null
        try {
            $en = (New-Object System.IO.DirectoryInfo($d.FullName)).EnumerateFiles('*.vsix', [System.IO.SearchOption]::AllDirectories).GetEnumerator()
            if ($en.MoveNext()) { $hasVsix = $true }
        } catch { Add-PMReadError -Errors $_ }
        finally {
            # Calling GetEnumerator() by hand opts out of whatever disposal foreach would have
            # done, and this is the only place in the repo that does. Without this the find
            # handle stays open on $d.FullName - the very directory Repair then hands to
            # Remove-Item -Recurse, where an open handle turns a delete into a delete-pending
            # and gets miscounted as 'locked'.
            if ($en -is [IDisposable]) { $en.Dispose() }
        }
        if (-not $hasVsix) { continue }
        $out.Add([pscustomobject]@{ Path = $d.FullName; Kind = 'payload-cache'; Bytes = (Get-PMKnownOrMeasuredSize -Path $d.FullName -Known $KnownSizes) })
    }
    return $out.ToArray()
}

function Test-PMModule {
    param([Parameter(Mandatory)][hashtable]$Context)
    $items = @(Get-VsScratchCandidates -Context $Context)
    $bytes = [int64](@($items | Measure-Object Bytes -Sum).Sum)
    if (-not $items) {
        return [pscustomobject]@{ Clean = $true; Detail = 'no Visual Studio Installer scratch older than 24h'; Bytes = [int64]0; Items = @() }
    }
    [pscustomobject]@{
        Clean  = $false
        Count  = @($items).Count
        Detail = ('{0} extraction(s), {1} payload cache(s)' -f
                    @($items | Where-Object Kind -eq 'extraction').Count,
                    @($items | Where-Object Kind -eq 'payload-cache').Count)
        Bytes  = $bytes
        # Handed to Repair via the context so it does not re-measure what was just
        # measured. In memory only - uncapped by design, and never serialized, which is
        # why the dispatcher copies it to $ctx and not to the run row.
        Sizes  = (ConvertTo-PMSizeMap -Items $items)
        # Capped like the other modules: 13,341 uncapped items produced a 4 MB run JSON, written
        # twice and retained 50 times over. The true number travels in Count.
        Items  = @($items | Sort-Object Bytes -Descending | Select-Object -First 25 | ForEach-Object { @{ path = $_.Path; kind = $_.Kind; bytes = $_.Bytes } })
    }
}

function Repair-PMModule {
    param([Parameter(Mandatory)][hashtable]$Context)
    $root  = Get-VsScratchRoot -Context $Context
    $items = @(Get-VsScratchCandidates -Context $Context -KnownSizes $Context.KnownSizes)
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
