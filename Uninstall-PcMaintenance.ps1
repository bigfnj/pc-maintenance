#Requires -Version 5.1
<#
.SYNOPSIS
    Remove the pc-maintenance scheduled task, and optionally its payload.

.DESCRIPTION
    The task goes by default; the payload stays unless you ask, because the payload carries the
    run history and the reports are the only record of what was deleted and when. There is no
    -RestoreBackups here (the project this borrows from has one) for the reason the whole design turns on:
    nothing backs up a deletion. The run JSON is the record.

.EXAMPLE
    .\Uninstall-PcMaintenance.ps1 -RemoveFiles
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
    if ($KeepLogs -and (Test-Path -LiteralPath (Join-Path $PayloadRoot 'logs'))) {
        foreach ($i in @('Invoke-PcMaintenance.ps1', 'pcmaintenance.manifest.json', 'lib', 'modules')) {
            $p = Join-Path $PayloadRoot $i
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        Write-PMLog "removed the payload, kept $PayloadRoot\logs" 'CHANGE'
    } elseif (Test-Path -LiteralPath $PayloadRoot) {
        Remove-Item -LiteralPath $PayloadRoot -Recurse -Force
        Write-PMLog "removed $PayloadRoot (run history included)" 'CHANGE'
    }
} else {
    Write-PMLog "payload left at $PayloadRoot (pass -RemoveFiles to delete it)" 'INFO'
}

Write-PMLog '=== uninstall complete ===' 'OK'
exit 0
