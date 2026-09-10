#Requires -Version 5.1
<#
    plex-bif-orphans - the .tmp Plex leaves beside every preview it generates.

    The Media directory is a junction to another volume on this box. Get-PlexMediaRoot resolves
    that ONE link up front, so the module needs no knowledge of where it actually lands - and
    the walk below then descends no junction it meets inside, exactly as the deletion will not.
    Those are two different rules about the same kind of object; do not collapse them.
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
    # ONE STREAMING walk. Two rules survive from the version this replaced:
    #
    # 1. -Filter '*.tmp' is not the same as "ends in .tmp". The Win32 filter also matches longer
    #    extensions (the 8.3 legacy), so 'index.bif.tmpx' would have matched and the blind
    #    Substring(len - 4) would then have tested the wrong base path. EndsWith is the rule
    #    that was meant.
    # 2. Testing each candidate's partner with Test-PMPath cost one stat per orphan - 6,935 of
    #    them at the documented peak. A HashSet built during the same walk answers in O(1).
    #
    # What changed, and why, is MEMORY. `@(Get-PMChildFile -Recurse)` materialised a FileInfo
    # for every file in the tree and held the whole array alive alongside the set that was built
    # from it. Only the full paths and the .tmp entries are ever read again. Measured 2026-09-10
    # on the real tree - see the reported numbers in BACKLOG 7k. Do NOT expect a time win: this
    # tree averages barely more than one file per directory, so the directory opens dominate and
    # the FileInfo materialisation this removes is a small slice of the total. The 2x originally
    # recorded does not reproduce.
    #
    # Critical: this scan IS the module's answer. If it fails the module knows nothing, which is
    # a different thing from knowing there is nothing. That makes the two traps below fatal
    # rather than untidy - each turns "went blind" into "found nothing", silently.
    #
    # Stack + per-directory enumeration, NOT EnumerateFiles(AllDirectories), copying the shape
    # Get-PMTreeStat already uses in PMCommon for exactly these two reasons:
    #
    #   a. AllDirectories FOLLOWS reparse points, while Get-ChildItem -Recurse and Remove-Item
    #      -Recurse do not (re-verified under 5.1). Descending a junction would report, and then
    #      DELETE, files outside the tree this module scanned and declared.
    #   b. AllDirectories ABORTS the entire enumeration at the first directory it cannot read.
    #      Get-ChildItem -Recurse -ErrorVariable recorded one error per unreadable LOCATION and
    #      carried on, so the per-directory try/catch below is what preserves that accounting.
    #      Every unreadable subtree is -Critical here because the scan is the answer.
    #
    # The root is pushed unconditionally, matching the old reader: Get-ChildItem enumerated the
    # CONTENTS of a reparse-point root and only declined to descend reparse points found within
    # it. (Get-PlexMediaRoot has already resolved the Media junction by this point anyway.)
    $present = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $temps   = New-Object 'System.Collections.Generic.List[object]'
    $stack   = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo($dir)
            foreach ($f in $di.EnumerateFiles()) {
                $null = $present.Add($f.FullName)
                # Collected, NOT judged. See the second pass below.
                if ($f.Name.EndsWith('.tmp', [StringComparison]::OrdinalIgnoreCase)) {
                    # .Length comes off the enumeration's own WIN32_FIND_DATA, so this keeps the
                    # size without keeping the FileInfo - which is the whole saving.
                    $temps.Add([pscustomobject]@{ Path = $f.FullName; Bytes = [int64]$f.Length })
                }
            }
            foreach ($sub in $di.EnumerateDirectories()) {
                # Do not descend a junction or symlink: neither will the deletion.
                if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($sub.FullName)
            }
        } catch {
            # One unreadable directory must not abandon the rest of the tree, and must not pass
            # silently either. One error per location, which is what -ErrorVariable gave.
            Add-PMReadError -Errors $_ -Critical
        }
    }
    # SECOND PASS, and it has to be. A .tmp can be enumerated before the finished file that
    # supersedes it - directory order is not defined and the partner may live in a directory
    # still on the stack - so judging during the walk would spare real orphans depending on
    # nothing but enumeration order, differently on each run.
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in $temps) {
        # The pairing IS the rule. A .tmp whose finished sibling is absent may be a generation
        # still running, so it survives; only a temp file the real artifact has superseded goes.
        $base = $t.Path.Substring(0, $t.Path.Length - 4)
        if (-not $present.Contains($base)) { continue }
        $out.Add($t)
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
