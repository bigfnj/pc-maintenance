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
    unlocks modules whose own manifest declares AutoApply, which today is the two with a
    mechanical rule and ~100% recurrence. Everything else keeps reporting. Both gates are what
    make an unattended weekly run reasonable at all.

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
$items = @('Invoke-PcMaintenance.ps1', 'pcmaintenance.manifest.json', 'lib', 'modules')
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
