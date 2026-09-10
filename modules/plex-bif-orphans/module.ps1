#Requires -Version 5.1
<#
    plex-bif-orphans - the .tmp Plex leaves beside every preview it generates.

    The Media directory is a junction to another volume on this box; Get-ChildItem follows it,
    so the module needs no knowledge of where it actually lands.
#>

function Get-PlexMediaRoot {
    <#
        Resolves the junction. Plex's Media directory is very commonly moved to another volume
        and left behind as a junction, which is what happened on the box this was written for.

        That matters because this runs as SYSTEM, and Windows will NOT let a privileged process
        traverse a cross-volume junction created by a less-privileged user: the read fails with
        "the path cannot be traversed because it contains an untrusted mount point". Scanning the
        resolved target instead sidesteps the block without weakening anything, since the path
        guard still applies against whatever root this returns.
    #>
    param([Parameter(Mandatory)][hashtable]$Context)
    $p = if ($Context.UserProfile) {
        Join-Path $Context.UserProfile 'AppData\Local\Plex Media Server\Media'
    } else {
        Join-Path $env:LOCALAPPDATA 'Plex Media Server\Media'
    }
    return (Resolve-PMReparsePoint -Path $p)
}

function Get-PlexOrphanCandidates {
    # No -KnownSizes here, unlike the other three modules - do not re-add it when cloning this
    # file. Their candidates are DIRECTORIES, so Get-PMKnownOrMeasuredSize earns its keep by
    # avoiding a measuring walk on a cache miss. These candidates are FILES: $f.Length below is
    # already free off the enumeration's own WIN32_FIND_DATA, so a size map would only ever be
    # a slower way of reading a number the walk has in hand.
    param([Parameter(Mandatory)][hashtable]$Context)
    $root = Get-PlexMediaRoot -Context $Context
    if (-not (Test-PMPath -Path $root)) { return @() }
    # ONE walk, unfiltered, into a set. Two reasons beyond speed:
    #
    # 1. -Filter '*.tmp' is not the same as "ends in .tmp". The Win32 filter also matches longer
    #    extensions (the 8.3 legacy), so 'index.bif.tmpx' would have matched and the blind
    #    Substring(len - 4) would then have tested the wrong base path. EndsWith is the rule
    #    that was meant.
    # 2. Testing each candidate's partner with Test-PMPath cost one stat per orphan - 6,935 of
    #    them at the documented peak. A HashSet built during the same walk answers in O(1).
    #
    # Critical: this scan IS the module's answer. If it fails the module knows nothing, which is
    # a different thing from knowing there is nothing.
    $all = @(Get-PMChildFile -Path $root -Recurse -Critical)
    $present = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $all) { $null = $present.Add($f.FullName) }
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in $all) {
        if (-not $f.Name.EndsWith('.tmp', [StringComparison]::OrdinalIgnoreCase)) { continue }
        # The pairing IS the rule. A .tmp whose finished sibling is absent may be a generation
        # still running, so it survives; only a temp file the real artifact has superseded goes.
        $base = $f.FullName.Substring(0, $f.FullName.Length - 4)
        if (-not $present.Contains($base)) { continue }
        $out.Add([pscustomobject]@{ Path = $f.FullName; Bytes = [int64]$f.Length })
    }
    return $out.ToArray()
}

function Test-PMModule {
    param([Parameter(Mandatory)][hashtable]$Context)
    $root = Get-PlexMediaRoot -Context $Context
    if (-not (Test-PMPath -Path $root)) {
        return [pscustomobject]@{ Clean = $true; Detail = "no Plex media cache at $root"; Bytes = [int64]0; Items = @() }
    }
    $items = @(Get-PlexOrphanCandidates -Context $Context)
    $bytes = [int64](@($items | Measure-Object Bytes -Sum).Sum)
    if (-not $items) {
        return [pscustomobject]@{ Clean = $true; Detail = 'no superseded .tmp previews'; Bytes = [int64]0; Items = @() }
    }
    [pscustomobject]@{
        Clean  = $false
        Count  = @($items).Count
        Detail = ('{0} .tmp file(s) whose finished preview already exists' -f @($items).Count)
        Bytes  = $bytes
        # Handed to Repair via the context so it does not re-measure what was just
        # measured. In memory only - uncapped by design, and never serialized, which is
        # why the dispatcher copies it to $ctx and not to the run row.
        Sizes  = (ConvertTo-PMSizeMap -Items $items)
        # Item paths are capped: 6,935 of them would bloat every run json for no added insight.
        Items  = @($items | Select-Object -First 25 | ForEach-Object { @{ path = $_.Path; bytes = $_.Bytes } })
    }
}

function Repair-PMModule {
    param([Parameter(Mandatory)][hashtable]$Context)
    $root  = Get-PlexMediaRoot -Context $Context
    $items = @(Get-PlexOrphanCandidates -Context $Context)
    $freed = [int64]0; $removed = 0; $vetoed = 0; $locked = 0; $gone = 0
    foreach ($i in $items) {
        # KnownBytes saves the walk inside Remove-PMPath, and the size itself rides along on the
        # candidate as $f.Length rather than being measured again here. Re-deriving the
        # candidate LIST is still deliberate - it re-applies every selection rule at delete
        # time, which is what spares a path that became active in between - but re-measuring
        # it was pure waste.
        $r = Remove-PMPath -Path $i.Path -Roots @($root) -DeclaredRoots @($Context.DeclaredRoots) `
                           -KnownBytes ([int64]$i.Bytes)
        # Credited BEFORE the success test, and outside it. Remove-Item -Recurse can delete most
        # of a tree and then throw, and Remove-PMPath re-measures precisely so it can report
        # what it did free - "the one thing the audit trail must never get wrong", says the
        # comment there. All four modules then discarded that number, because this guard only
        # credited a full success: a partial delete recorded 0 B in the record that stands in
        # for a backup. Measured on 2026-09-10 with one locked file: 6,000 of 6,050 B really
        # gone, logged as nothing. Bytes is 0 on every other outcome, so this is unconditional.
        # (This module's candidates are single files, so it can only ever be all or nothing -
        # written the same way as the other three so the four tails stay one shape.)
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
