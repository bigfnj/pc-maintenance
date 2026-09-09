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
    param([Parameter(Mandatory)][hashtable]$Context)
    $root = Get-VsScratchRoot -Context $Context
    $cut = (Get-Date).AddHours(-24)
    # List, not +=. Measured under 5.1 at 13,341 appends: 6,733 ms for += versus 248 ms here,
    # because += reallocates the whole array every time.
    $out = New-Object 'System.Collections.Generic.List[object]'

    # Critical: enumerating TEMP is the answer. The per-candidate probes below are NOT - one
    # locked _MEI directory means that candidate is unknown, not that the sweep is blind.
    foreach ($d in (Get-PMChildDirectory -Path $root -Critical)) {
        if ($d.Name -notmatch '^[a-z0-9]{8}\.[a-z0-9]{3}$') { continue }
        if ($d.LastWriteTime -ge $cut) { continue }
        # A random name alone is not evidence. Require the installer's own fingerprint, so a
        # directory that merely looks like scratch survives.
        if (-not (Test-PMPath -Path (Join-Path $d.FullName 'setup.exe'))) { continue }
        if (-not (Test-PMPath -Path (Join-Path $d.FullName 'resources\app\ServiceHub'))) { continue }
        $out.Add([pscustomobject]@{ Path = $d.FullName; Kind = 'extraction'; Bytes = (Get-PMPathSize -Path $d.FullName) })
    }

    # The payload cache: one directory of already-applied .vsix / .msi downloads. Identified by
    # content rather than by its (random, stable) name, so this keeps working when it changes.
    foreach ($d in (Get-PMChildDirectory -Path $root)) {
        if ($d.Name -match '^[a-z0-9]{8}\.[a-z0-9]{3}$') { continue }
        if ($d.LastWriteTime -ge $cut) { continue }
        # Cheap check FIRST. The manifest probe is one non-recursive listing and eliminates almost
        # everything; the .vsix probe recurses, so running it first meant walking every unrelated
        # directory in TEMP (6,194 of them here) on every single run.
        $manifests = @(Get-PMChildDirectory -Path $d.FullName | Where-Object { $_.Name -match '\.Manifest-|Microsoft\.VisualStudio\.' } | Select-Object -First 1)
        if (-not $manifests) { continue }
        # Streaming, and it really does stop at the first hit. `@(... | Select-Object -First 1)`
        # did NOT: the @() forces the whole enumeration to finish before the pipeline sees anything.
        $hasVsix = $false
        try {
            $en = (New-Object System.IO.DirectoryInfo($d.FullName)).EnumerateFiles('*.vsix', [System.IO.SearchOption]::AllDirectories).GetEnumerator()
            if ($en.MoveNext()) { $hasVsix = $true }
        } catch { Add-PMReadError -Errors $_ }
        if (-not $hasVsix) { continue }
        $out.Add([pscustomobject]@{ Path = $d.FullName; Kind = 'payload-cache'; Bytes = (Get-PMPathSize -Path $d.FullName) })
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
        # Capped like the other modules: 13,341 uncapped items produced a 4 MB run JSON, written
        # twice and retained 50 times over. The true number travels in Count.
        Items  = @($items | Sort-Object Bytes -Descending | Select-Object -First 25 | ForEach-Object { @{ path = $_.Path; kind = $_.Kind; bytes = $_.Bytes } })
    }
}

function Repair-PMModule {
    param([Parameter(Mandatory)][hashtable]$Context)
    $root  = Get-VsScratchRoot -Context $Context
    $items = @(Get-VsScratchCandidates -Context $Context)
    $freed = [int64]0; $removed = 0; $vetoed = 0; $locked = 0; $gone = 0
    foreach ($i in $items) {
        # KnownBytes: the size was measured during Test, so re-walking the tree here would be a
        # second full pass for a number we already hold.
        $r = Remove-PMPath -Path $i.Path -Roots @($root) -DeclaredRoots @($Context.DeclaredRoots) `
                           -KnownBytes ([int64]$i.Bytes)
        if ($r.Removed) { $removed++; $freed += [int64]$r.Bytes; continue }
        # Reason matters: a path guard VETO is a governance event worth seeing, a file that
        # vanished between Test and Repair is routine, and a locked file is neither.
        switch -Wildcard ($r.Reason) {
            '*refused*' { $vetoed++ }
            '*outside*' { $vetoed++ }
            'gone'      { $gone++ }
            default     { $locked++ }
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
