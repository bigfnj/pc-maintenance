#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy pc-maintenance to ProgramData and register the weekly SYSTEM task.

.DESCRIPTION
    Two steps, both idempotent:

      1. copy a self-contained payload to C:\ProgramData\PcMaintenance
      2. register the SYSTEM scheduled task "PcMaintenance" from task_template.xml

    ProgramData rather than the user profile because AppLocker trusts it and may not trust a
    profile. SYSTEM rather than the user because the task must run whether or not anyone is
    logged in; the interactive user is resolved at run time so the report still lands in THEIR
    Downloads.

    The registered task passes -Apply. That is not the same as "delete everything": -Apply only
    unlocks modules whose own manifest declares AutoApply, and each of those had to earn it with
    a mechanical rule and a measured recurrence. Everything else keeps reporting. Both gates are
    what make an unattended weekly run reasonable at all. (This paragraph used to name a count,
    which was stale the day a third module was enabled; the suite pins the count, so this does
    not need to.)

    Elevation is needed only to REGISTER a SYSTEM task; the task itself then runs as SYSTEM.

.EXAMPLE
    .\Install-PcMaintenance.ps1 -RunNow
#>
[CmdletBinding()]
param(
    [string]$PayloadRoot = 'C:\ProgramData\PcMaintenance',
    [switch]$RunNow,
    [switch]$ReportOnlySchedule
)

$SourceRoot = $PSScriptRoot
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $SourceRoot 'lib\PMCommon.ps1')

$TaskName = 'PcMaintenance'

if (-not (Test-PMElevated)) {
    Write-PMLog 'Elevation is required to register a SYSTEM task. Relaunching...' 'WARN'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-PayloadRoot', "`"$PayloadRoot`"")
    if ($RunNow) { $argList += '-RunNow' }
    if ($ReportOnlySchedule) { $argList += '-ReportOnlySchedule' }
    try {
        $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -PassThru -Wait
        exit $p.ExitCode
    } catch {
        Write-PMLog "could not elevate: $($_.Exception.Message)" 'ERROR'
        exit 1
    }
}

Write-PMLog "=== installing pc-maintenance to $PayloadRoot ===" 'INFO'

# --- 1. payload -----------------------------------------------------------------------
# Each target is REMOVED before copying: Copy-Item -Recurse nests into an existing directory
# instead of overwriting it, so a redeploy would otherwise build lib\lib\PMCommon.ps1. Same trap
# the project this borrows from hit and fixed.
# One list, shared with the uninstaller's -KeepLogs, so the two cannot drift apart.
$items = @(Get-PMPayloadItems)
New-Item -ItemType Directory -Path $PayloadRoot -Force | Out-Null
foreach ($i in $items) {
    $src = Join-Path $SourceRoot $i
    $dst = Join-Path $PayloadRoot $i
    if (-not (Test-Path -LiteralPath $src)) { Write-PMLog "missing source: $i" 'ERROR'; exit 1 }
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    Write-PMLog "deployed $i" 'CHANGE'
}
New-Item -ItemType Directory -Path (Join-Path $PayloadRoot 'logs') -Force | Out-Null

# Harden the ACL. C:\ProgramData inherits BUILTIN\Users:(CI)(WD,AD) - create-file and
# create-subdirectory - and the dispatcher dot-sources every .ps1 under lib\ as SYSTEM. Without
# this, any standard user could drop lib\zz.ps1 and have SYSTEM execute it on the next weekly
# sweep, without ever touching a file that already exists.
#
# The dispatcher independently refuses to run from a writable payload, so this and that check must
# agree; they live in the same lib file for exactly that reason.
try {
    Set-PMPayloadAcl -Path $PayloadRoot
    Write-PMLog 'locked the payload ACL (SYSTEM + Administrators full, Users read-only)' 'OK'
} catch {
    Write-PMLog "could not harden the payload ACL: $($_.Exception.Message)" 'ERROR'
    Write-PMLog 'the dispatcher will refuse to run until this is fixed' 'ERROR'
    exit 1
}
$stillOpen = @(Test-PMPayloadSecure -Path $PayloadRoot)
if ($stillOpen.Count) {
    Write-PMLog 'ACL hardening did not take effect:' 'ERROR'
    foreach ($b in $stillOpen) { Write-PMLog "  $b" 'ERROR' }
    exit 1
}

# --- 2. scheduled task ----------------------------------------------------------------
$xmlPath = Join-Path $SourceRoot 'task_template.xml'
if (-not (Test-Path -LiteralPath $xmlPath)) { Write-PMLog 'task_template.xml missing' 'ERROR'; exit 1 }
$xml = Get-Content -LiteralPath $xmlPath -Raw
$xml = $xml.Replace('{PAYLOAD}', $PayloadRoot)
if ($ReportOnlySchedule) {
    $xml = $xml.Replace('Invoke-PcMaintenance.ps1" -Apply', 'Invoke-PcMaintenance.ps1"')
    Write-PMLog 'schedule will run REPORT-ONLY (no module may act)' 'WARN'
}

try {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-PMLog 'removed the previous task registration' 'CHANGE'
    }
    # Register-ScheduledTask -Xml <string>, not schtasks.exe /xml: the XML is passed in memory, so
    # there is no temp file and no encoding pitfall, and a failure comes back as a real error.
    $null = Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force -ErrorAction Stop
    Write-PMLog "registered scheduled task '$TaskName' (weekly, Sunday 03:00, SYSTEM)" 'OK'
} catch {
    Write-PMLog "task registration failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

if ($RunNow) {
    Write-PMLog 'starting the task now...' 'INFO'
    try {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-PMLog 'started; see the run json under the payload logs directory' 'OK'
    } catch { Write-PMLog "could not start: $($_.Exception.Message)" 'WARN' }
}

Write-PMLog '=== install complete ===' 'OK'
exit 0
