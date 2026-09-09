#Requires -Version 5.1
<#
    plex-bif-orphans - the .tmp Plex leaves beside every preview it generates.

    The Media directory is a junction to another volume on this box; Get-ChildItem follows it,
    so the module needs no knowledge of where it actually lands.
#>

function Get-PlexMediaRoot {
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context.UserProfile) {
        return (Join-Path $Context.UserProfile 'AppData\Local\Plex Media Server\Media')
    }
    return (Join-Path $env:LOCALAPPDATA 'Plex Media Server\Media')
}

function Get-PlexOrphanCandidates {
    param([Parameter(Mandatory)][hashtable]$Context)
    $root = Get-PlexMediaRoot -Context $Context
    if (-not (Test-PMPath -Path $root)) { return @() }
    $out = @()
    foreach ($f in (Get-PMChildFile -Path $root -Filter '*.tmp' -Recurse)) {
        # The pairing IS the rule. A .tmp whose finished sibling is absent may be a generation
        # still running, so it survives; only a temp file the real artifact has superseded goes.
        $base = $f.FullName.Substring(0, $f.FullName.Length - 4)
        if (-not (Test-PMPath -Path $base)) { continue }
        $out += [pscustomobject]@{ Path = $f.FullName; Bytes = [int64]$f.Length }
    }
    return $out
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
    $freed = [int64]0; $removed = 0; $refused = 0
    foreach ($i in $items) {
        $r = Remove-PMPath -Path $i.Path -Roots @($root) -WhatIfOnly:(-not $Context.Apply)
        if ($r.Removed) { $removed++; $freed += [int64]$r.Bytes }
        elseif ($r.Skipped) { $refused++ }
    }
    [pscustomobject]@{
        Changed = ($removed -gt 0)
        Ok      = $true
        Bytes   = $freed
        Detail  = ('removed {0} of {1}; {2} locked or refused' -f $removed, @($items).Count, $refused)
    }
}
