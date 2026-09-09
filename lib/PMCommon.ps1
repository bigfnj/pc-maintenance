#Requires -Version 5.1
<#
    PMCommon.ps1 - pc-maintenance shared helpers.

    Dot-source only; no side effects on load, so it is safe to re-dot-source inside each
    module's isolated child scope. Borrowed in shape from preference-guard's PGCommon, with
    one deliberate difference: this framework DELETES, so the readers modules are required to
    go through are filesystem readers, and every removal passes a hard path guard first.
#>

function Write-PMLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','CHANGE','SKIP','WARN','ERROR')][string]$Level = 'INFO'
    )
    $prefix = @{ INFO = '[ ]'; OK = '[+]'; CHANGE = '[~]'; SKIP = '[-]'; WARN = '[*]'; ERROR = '[!]' }[$Level]
    $color  = @{ INFO = 'Gray'; OK = 'Green'; CHANGE = 'Green'; SKIP = 'DarkGray'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    $line = '{0} {1} {2}' -f (Get-Date -Format 'HH:mm:ss'), $prefix, $Message
    try { Write-Host $line -ForegroundColor $color } catch { Write-Output $line }
}

function New-PMRunId { (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6)) }

function Test-PMElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-PMSidToProfile {
    param([Parameter(Mandatory)][string]$Sid)
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    if (Test-Path -LiteralPath $key) {
        return (Get-ItemProperty -LiteralPath $key -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
    }
    return $null
}

function Get-PMInteractiveUserSid {
    # Resolve the interactive (console) user; works when the dispatcher runs as SYSTEM, which is
    # how it reaches C:\Users\<user>\AppData\Local\Temp. Returns Sid/Profile/LoggedIn; Sid may be
    # $null at the logon screen, in which case every per-user module is skipped rather than guessed.
    $sid = $null; $loggedIn = $false; $account = $null
    try { $account = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
    if ($account) {
        try {
            $sid = (New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            $loggedIn = $true
        } catch {}
    }
    if (-not $sid) {
        try {
            $exp = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
            if ($exp) {
                $o = Invoke-CimMethod -InputObject $exp -MethodName GetOwnerSid -ErrorAction Stop
                if ($o.Sid) { $sid = $o.Sid; $loggedIn = $true }
            }
        } catch {}
    }
    if (-not $sid) {
        $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $cand = Get-ChildItem $pl -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^(S-1-12-1-|S-1-5-21-)' } |
            ForEach-Object {
                $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                [pscustomobject]@{ Sid = $_.PSChildName; Path = $p.ProfileImagePath }
            } | Where-Object { $_.Path -match '\\Users\\' } | Select-Object -First 1
        if ($cand) { $sid = $cand.Sid }
    }
    $prof = if ($sid) { Resolve-PMSidToProfile -Sid $sid } else { $null }
    [pscustomobject]@{ Sid = $sid; Profile = $prof; LoggedIn = $loggedIn }
}

# --- the path guard -------------------------------------------------------------------
#
# preference-guard's safety keystone is a hard-coded FORBIDDEN CATEGORY set that wins even if a
# module mislabels itself. The equivalent here is a hard-coded FORBIDDEN PATH set, because the
# damage this framework can do is measured in deleted bytes, not in policy. Both gates are
# deliberately not configurable from the manifest: a module cannot vote itself the right to
# delete somewhere dangerous.
#
# Docker is named because 22 volumes on this box hold finance records and student IEP data, and
# a Docker volume root looks exactly like disposable scratch from the outside.

$script:PMForbiddenPathPatterns = @(
    '^[A-Za-z]:\\?$'                                # a drive root
    '^[A-Za-z]:\\Windows($|\\)'
    '^[A-Za-z]:\\Program Files( \(x86\))?($|\\)'
    '^[A-Za-z]:\\Users\\[^\\]+\\(Documents|Desktop|Pictures|Videos|Music|Downloads)($|\\)'
    '\\DockerDesktop($|\\)'
    '\\docker\\volumes($|\\)'
    '\\wsl\\'
    '\\\.git($|\\)'
    '\\site-packages($|\\)'
    '\\node_modules($|\\)'
)

function Get-PMForbiddenPathPatterns { $script:PMForbiddenPathPatterns }

function Test-PMPathSafe {
    <#
        Two independent conditions, both required:
          1. the target sits UNDER one of the roots the module declared, and
          2. it matches no forbidden pattern, and is at least MinDepth segments deep.

        (1) alone is not enough: a module with a broad root would still be able to reach a
        Docker volume inside it. (2) alone is not enough either: it would let a module delete
        anywhere nobody thought to forbid. Returns $true only if both hold.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Roots,
        [int]$MinDepth = 3
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = try { [IO.Path]::GetFullPath($Path) } catch { return $false }
    $full = $full.TrimEnd('\')
    if (($full -split '\\').Where({ $_ }).Count -lt $MinDepth) { return $false }
    foreach ($pat in $script:PMForbiddenPathPatterns) { if ($full -match $pat) { return $false } }
    foreach ($r in $Roots) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $root = try { [IO.Path]::GetFullPath($r).TrimEnd('\') } catch { continue }
        if ($full.Equals($root, 'OrdinalIgnoreCase')) { return $false }   # never the root itself
        if ($full.StartsWith($root + '\', 'OrdinalIgnoreCase')) { return $true }
    }
    return $false
}

# --- filesystem readers (the test seam) -----------------------------------------------
# Modules read state ONLY through these, so tests can fake a tree without touching a disk.

function Get-PMChildDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-ChildItem -LiteralPath $Path -Force -Directory -ErrorAction SilentlyContinue)
}

function Get-PMChildFile {
    param([Parameter(Mandatory)][string]$Path, [string]$Filter = '*', [switch]$Recurse)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-ChildItem -LiteralPath $Path -Force -File -Filter $Filter -Recurse:$Recurse -ErrorAction SilentlyContinue)
}

function Test-PMPath { param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    Test-Path -LiteralPath $Path
}

function Get-PMPathSize {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
    if ($null -eq $s) { return [int64]0 }
    return [int64]$s
}

function Remove-PMPath {
    <#
        The only sanctioned deletion. Refuses anything Test-PMPathSafe rejects, and honours
        -WhatIfOnly so a module's Repair can compute the full intent in report-only mode
        without a second code path that could drift from the real one.

        Returns @{ Removed; Skipped; Reason; Bytes }.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Roots,
        [switch]$WhatIfOnly,
        [int]$MinDepth = 3
    )
    if (-not (Test-PMPathSafe -Path $Path -Roots $Roots -MinDepth $MinDepth)) {
        return @{ Removed = $false; Skipped = $true; Reason = 'refused by path guard'; Bytes = [int64]0 }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Removed = $false; Skipped = $true; Reason = 'gone'; Bytes = [int64]0 }
    }
    $bytes = Get-PMPathSize -Path $Path
    if ($WhatIfOnly) {
        return @{ Removed = $false; Skipped = $false; Reason = 'report-only'; Bytes = $bytes }
    }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return @{ Removed = $true; Skipped = $false; Reason = ''; Bytes = $bytes }
    } catch {
        return @{ Removed = $false; Skipped = $true; Reason = "locked or in use: $($_.Exception.GetType().Name)"; Bytes = [int64]0 }
    }
}

function Format-PMBytes {
    param([Parameter(Mandatory)][AllowNull()][int64]$Bytes)
    if (-not $Bytes) { return '0 B' }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}
