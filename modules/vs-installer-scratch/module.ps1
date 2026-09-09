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
    $out = @()

    foreach ($d in (Get-PMChildDirectory -Path $root)) {
        if ($d.Name -notmatch '^[a-z0-9]{8}\.[a-z0-9]{3}$') { continue }
        if ($d.LastWriteTime -ge $cut) { continue }
        # A random name alone is not evidence. Require the installer's own fingerprint, so a
        # directory that merely looks like scratch survives.
        if (-not (Test-PMPath -Path (Join-Path $d.FullName 'setup.exe'))) { continue }
        if (-not (Test-PMPath -Path (Join-Path $d.FullName 'resources\app\ServiceHub'))) { continue }
        $out += [pscustomobject]@{ Path = $d.FullName; Kind = 'extraction'; Bytes = (Get-PMPathSize -Path $d.FullName) }
    }

    # The payload cache: one directory of already-applied .vsix / .msi downloads. Identified by
    # content rather than by its (random, stable) name, so this keeps working when it changes.
    foreach ($d in (Get-PMChildDirectory -Path $root)) {
        if ($d.Name -match '^[a-z0-9]{8}\.[a-z0-9]{3}$') { continue }
        if ($d.LastWriteTime -ge $cut) { continue }
        $vsix = @(Get-PMChildFile -Path $d.FullName -Filter '*.vsix' -Recurse | Select-Object -First 1)
        if (-not $vsix) { continue }
        $manifests = @(Get-PMChildDirectory -Path $d.FullName | Where-Object { $_.Name -match '\.Manifest-|Microsoft\.VisualStudio\.' } | Select-Object -First 1)
        if (-not $manifests) { continue }
        $out += [pscustomobject]@{ Path = $d.FullName; Kind = 'payload-cache'; Bytes = (Get-PMPathSize -Path $d.FullName) }
    }
    return $out
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
        Items  = @($items | ForEach-Object { @{ path = $_.Path; kind = $_.Kind; bytes = $_.Bytes } })
    }
}

function Repair-PMModule {
    param([Parameter(Mandatory)][hashtable]$Context)
    $root  = Get-VsScratchRoot -Context $Context
    $items = @(Get-VsScratchCandidates -Context $Context)
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
