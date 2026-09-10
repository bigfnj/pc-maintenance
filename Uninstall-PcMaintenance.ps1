#Requires -Version 5.1
<#
.SYNOPSIS
    Remove the pc-maintenance scheduled task, and optionally its payload.

.DESCRIPTION
    The task goes by default; the payload stays unless you ask, because the payload carries the
    run history and the reports are the only record of what was deleted and when. There is no
    -RestoreBackups here (the project this borrows from has one) for the reason the whole design turns on:
    nothing backs up a deletion. The run JSON is the record.

.PARAMETER PayloadRoot
    Where the payload was installed. This is operator input feeding a recursive force delete, so
    it goes through the same path guard every module does.

.PARAMETER RemoveFiles
    Also delete the payload. Without it only the scheduled task goes.

.PARAMETER KeepLogs
    With -RemoveFiles, remove the deployed files but leave logs\ and its run history in place.
    Has no effect on its own, and now says so rather than being a silent no-op.

.EXAMPLE
    .\Uninstall-PcMaintenance.ps1 -RemoveFiles

.EXAMPLE
    .\Uninstall-PcMaintenance.ps1 -RemoveFiles -KeepLogs
#>
[CmdletBinding()]
param(
    [string]$PayloadRoot = 'C:\ProgramData\PcMaintenance',
    [switch]$RemoveFiles,
    [switch]$KeepLogs
)

$SourceRoot = $PSScriptRoot
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $SourceRoot 'lib\PMCommon.ps1')

$TaskName = 'PcMaintenance'

if (-not (Test-PMElevated)) {
    Write-PMLog 'Elevation is required to remove a SYSTEM task. Relaunching...' 'WARN'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-PayloadRoot', "`"$PayloadRoot`"")
    if ($RemoveFiles) { $argList += '-RemoveFiles' }
    if ($KeepLogs) { $argList += '-KeepLogs' }
    try { $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -PassThru -Wait; exit $p.ExitCode }
    catch { Write-PMLog "could not elevate: $($_.Exception.Message)" 'ERROR'; exit 1 }
}

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-PMLog "removed scheduled task '$TaskName'" 'CHANGE'
} else {
    Write-PMLog "no scheduled task '$TaskName' registered" 'SKIP'
}

if ($RemoveFiles) {
    # The guard, the -KeepLogs split and the delete itself all live in Remove-PMPayloadFiles, so
    # they can be tested against a fixture without elevating and without unregistering the real
    # task. This script keeps the parts that genuinely need to be here: elevation and exit codes.
    $outcome = Remove-PMPayloadFiles -Root $PayloadRoot -KeepLogs:$KeepLogs
    if ($outcome.Blocked) { Write-PMLog $outcome.Detail 'ERROR'; exit 1 }
    Write-PMLog $outcome.Detail $(if ($outcome.Removed) { 'CHANGE' } else { 'SKIP' })
} else {
    # -KeepLogs alone used to do nothing and say nothing. Nothing is being deleted, so there is
    # nothing to keep; a switch that silently does not apply is worse than one that objects.
    if ($KeepLogs) {
        Write-PMLog '-KeepLogs does nothing without -RemoveFiles: no files are being deleted' 'WARN'
    }
    Write-PMLog "payload left at $PayloadRoot (pass -RemoveFiles to delete it)" 'INFO'
}

Write-PMLog '=== uninstall complete ===' 'OK'
exit 0
