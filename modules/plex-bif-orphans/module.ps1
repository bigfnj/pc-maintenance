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
