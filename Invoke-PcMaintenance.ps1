#Requires -Version 5.1
<#
.SYNOPSIS
    pc-maintenance dispatcher. Walks enabled modules, reports what has accumulated, and
    removes only what is both permitted and proven.

.DESCRIPTION
    Borrowed from preference-guard's dispatcher, with the default inverted. preference-guard
    repairs by default and takes -DryRun to hold back; this tool REPORTS by default and takes
    -Apply to act, because the failure modes are not symmetric. A preference left unrepaired is
    an inconvenience you notice; a file deleted wrongly is gone.

    Deletion needs BOTH -Apply here AND AutoApply=$true in the module's own manifest, and every
    path additionally passes the hard-coded guard in PMCommon before it can be removed.

    There is no backup phase. preference-guard snapshots a registry key before writing it and
    can replay it on uninstall; nothing can snapshot 67 GB of scratch. The audit trail replaces
    it: every run records the full list of paths considered, with sizes and the reason each was
    kept or removed, in logs/run-<id>.json.

.EXAMPLE
    .\Invoke-PcMaintenance.ps1
    Report only. Changes nothing, whatever the modules say.

.EXAMPLE
    .\Invoke-PcMaintenance.ps1 -Apply
    Act, but only for modules that declare AutoApply.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$PayloadRoot,
    [string]$ManifestPath,
    [string[]]$Only,
    [switch]$NoReport
)

# $PayloadRoot is resolved HERE, not as a param default. Under Windows PowerShell 5.1 --- which
# is what the scheduled task runs --- `[CmdletBinding()]` makes $PSScriptRoot evaluate to EMPTY
# inside a param default block, while the same variable is correct one line later in the body.
# Verified both ways on this box: drop [CmdletBinding()] and the default populates. The failure
# is silent and cascading (every Join-Path below binds an empty string), so it is worth the
# three lines to be explicit. tests/Invoke-Tests.ps1 pins this.
if (-not $PayloadRoot) { $PayloadRoot = $PSScriptRoot }
if (-not $PayloadRoot) { $PayloadRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $PayloadRoot) { throw 'cannot resolve PayloadRoot; pass -PayloadRoot explicitly' }

$ErrorActionPreference = 'Continue'
$DispatcherVersion = '0.1.0'
$startedUtc = (Get-Date).ToUniversalTime().ToString('o')

$libDir      = Join-Path $PayloadRoot 'lib'
$modulesDir  = Join-Path $PayloadRoot 'modules'
$logsDir     = Join-Path $PayloadRoot 'logs'
if (-not $ManifestPath) { $ManifestPath = Join-Path $PayloadRoot 'pcmaintenance.manifest.json' }

foreach ($f in 'PMCommon.ps1', 'PMManifest.ps1', 'PMModule.ps1', 'PMReport.ps1') { . (Join-Path $libDir $f) }

$runId = New-PMRunId
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
$transcript = Join-Path $logsDir "transcript-$runId.log"
try { Start-Transcript -Path $transcript | Out-Null } catch {}

# Exclusive lock so a manual run and the weekly trigger never overlap on the same tree.
$lockFile = Join-Path $PayloadRoot '.pm.lock'
$lockStream = $null
try { $lockStream = [System.IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None') }
catch {
    Write-PMLog "Another pc-maintenance run holds $lockFile; exiting." 'WARN'
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

$results = @()
$summary = [ordered]@{ total = 0; clean = 0; found = 0; applied = 0; skipped = 0; unverified = 0; partial = 0; errors = 0; bytes = [int64]0 }

try {
    $mode = if ($Apply) { 'APPLY' } else { 'REPORT-ONLY' }
    Write-PMLog "=== pc-maintenance $DispatcherVersion (run $runId, $mode) ===" 'INFO'

    $manifest = Get-PMManifest -Path $ManifestPath
    $enabled  = Get-PMEnabledModules -Manifest $manifest
    if ($Only) { $enabled = @($enabled | Where-Object { $Only -contains $_.id }) }

    $user = Get-PMInteractiveUserSid
    $sidLabel = if ($user.Sid) { $user.Sid } else { '<none>' }
    Write-PMLog ("interactive user: {0} (loggedIn={1})" -f $sidLabel, $user.LoggedIn)

    foreach ($mod in $enabled) {
        $modId  = [string]$mod.id
        $modDir = Join-Path $modulesDir $modId
        $summary.total++
        $row = [ordered]@{ id = $modId; status = 'unknown'; detail = ''; bytes = [int64]0; count = 0; readErrors = 0; partial = 0; items = @() }
        try {
            $info = Import-PMModuleInfo -ModuleDir $modDir

            if (-not (Test-PMCategoryAllowed -Category $info.Category -Manifest $manifest)) {
                $row.status = 'skipped'; $row.detail = "category '$($info.Category)' not permitted"
                Write-PMLog "$modId SKIP - $($row.detail)" 'SKIP'; $summary.skipped++; $results += $row; continue
            }
            if ($info['RequiresUserSid'] -and -not $user.Sid) {
                $row.status = 'skipped'; $row.detail = 'needs an interactive user; none resolved'
                Write-PMLog "$modId SKIP - $($row.detail)" 'SKIP'; $summary.skipped++; $results += $row; continue
            }

            # The second gate. A module is report-only unless BOTH sides agree.
            $mayApply = Test-PMApplyAllowed -Apply ([bool]$Apply) -ModuleInfo $info

            $ctx = @{
                UserSid = $user.Sid; UserProfile = $user.Profile
                PayloadRoot = $PayloadRoot; ModuleRoot = $modDir; LibDir = $libDir
                RunId = $runId; Apply = $mayApply
                IsInteractiveUserLoggedIn = $user.LoggedIn
            }

            $tw = Invoke-PMModulePhase -ModuleDir $modDir -Phase Test -Context $ctx -LibDir $libDir -Entry $info.Entry
            $t = $tw.Result
            $row.readErrors = [int]$tw.ReadErrors
            $row.bytes = if ($null -ne $t.Bytes) { [int64]$t.Bytes } else { [int64]0 }
            $row.items = @($t.Items)
            # Count is the TRUE number found. Items is capped by some modules so a 6,935-orphan
            # run does not bloat every run json, so logging @($t.Items).Count would report the
            # cap and quietly disagree with the module's own Detail string.
            $row.count = if ($null -ne $t.Count) { [int]$t.Count } else { @($t.Items).Count }
            $row.detail = [string]$t.Detail

            # A module that could not READ must never pass as clean. Silence and emptiness look
            # identical from the outside, and the whole value of a weekly report is that "clean"
            # means something. Found on the first SYSTEM run: it refused to traverse a
            # cross-volume junction and the module reported a clean machine over 28 real orphans.
            if ($tw.CriticalReadErrors -gt 0) {
                $row.status = 'unverified'
                $row.detail = "could not read $($tw.CriticalReadErrors) required location(s): $($tw.ReadErrorSample)"
                Write-PMLog "$modId UNVERIFIED - $($row.detail)" 'WARN'
                $summary.unverified++; $results += $row; continue
            }
            # Incidental unreadable spots (a locked _MEI dir, a file that vanished mid-scan) are
            # PARTIAL coverage, not blindness. Recorded and shown, but they do not redden the run:
            # a permanent benign red is how a control gets ignored.
            if ($tw.ReadErrors -gt 0) {
                $row.partial = [int]$tw.ReadErrors
                $summary.partial += [int]$tw.ReadErrors
                Write-PMLog "$modId partial coverage - $($tw.ReadErrors) location(s) unreadable" 'SKIP'
            }

            if ($t.Clean) {
                $row.status = 'clean'
                Write-PMLog "$modId clean - $($t.Detail)" 'OK'; $summary.clean++; $results += $row; continue
            }

            $summary.found++
            Write-PMLog ("{0} found {1} in {2} item(s) - {3}" -f $modId, (Format-PMBytes $row.bytes), $row.count, $t.Detail) 'WARN'

            if (-not $mayApply) {
                $reason = if (-not $Apply) { 'report-only run' } else { "module does not declare AutoApply" }
                $row.status = 'reported'; $row.detail += " [not removed: $reason]"
                Write-PMLog "$modId not removed - $reason" 'SKIP'; $results += $row; continue
            }

            $rw = Invoke-PMModulePhase -ModuleDir $modDir -Phase Repair -Context $ctx -LibDir $libDir -Entry $info.Entry
            $r = $rw.Result
            $row.status = if ($r.Ok) { 'applied' } else { 'error' }
            $row.detail = [string]$r.Detail
            $row.bytes  = if ($null -ne $r.Bytes) { [int64]$r.Bytes } else { [int64]0 }
            if ($r.Ok) {
                $summary.applied++; $summary.bytes += $row.bytes
                Write-PMLog ("{0} removed {1} - {2}" -f $modId, (Format-PMBytes $row.bytes), $r.Detail) 'CHANGE'
            } else {
                $summary.errors++
                Write-PMLog "$modId FAILED - $($r.Detail)" 'ERROR'
            }
        } catch {
            $row.status = 'error'; $row.detail = $_.Exception.Message
            $summary.errors++
            Write-PMLog "$modId ERROR - $($_.Exception.Message)" 'ERROR'
        }
        $results += $row
    }
} finally {
    # unverified is a real failure of the sweep's purpose, so it earns a non-zero exit too:
    # a weekly job that cannot see must not report success.
    $exitCode = if ($summary.errors -gt 0 -or $summary.unverified -gt 0) { 1 } else { 0 }
    $runObj = [ordered]@{
        runId = $runId; startedUtc = $startedUtc; finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
        version = $DispatcherVersion; mode = $(if ($Apply) { 'apply' } else { 'report' })
        modules = $results; summary = $summary; exitCode = $exitCode
    }
    try {
        $json = $runObj | ConvertTo-Json -Depth 8
        $json | Set-Content -LiteralPath (Join-Path $logsDir "run-$runId.json") -Encoding UTF8
        $json | Set-Content -LiteralPath (Join-Path $logsDir 'latest.json') -Encoding UTF8
    } catch { Write-PMLog "could not write run json: $($_.Exception.Message)" 'ERROR' }

    # The human-facing artifact, dropped where the owner will actually see it. Wrapped so a
    # report failure can never turn a clean sweep into a failed run: the sweep is the work, the
    # report is the delivery, and losing the delivery is worth a WARN, not an exit code.
    if (-not $NoReport) {
        try {
            $dl = Get-PMDownloadsPath -UserSid $user.Sid -UserProfile $user.Profile
            $stamp = (Get-Date -Format 'yyyy-MM-dd HHmmss')
            $reportPath = Join-Path $dl ("PC-Maintenance Report - $stamp.html")
            $null = New-PMHtmlReport -Run $runObj -OutPath $reportPath
            Write-PMLog "report: $reportPath" 'OK'
        } catch {
            Write-PMLog "could not write the HTML report: $($_.Exception.Message)" 'WARN'
        }
    }

    Write-PMLog ('=== SUMMARY total={0} clean={1} found={2} applied={3} skipped={4} unverified={5} errors={6} freed={7} (exit {8}) ===' -f `
            $summary.total, $summary.clean, $summary.found, $summary.applied, $summary.skipped,
            $summary.unverified, $summary.errors, (Format-PMBytes $summary.bytes), $exitCode) $(if ($exitCode) { 'ERROR' } else { 'OK' })

    try {
        $ret = $runObj.summary  # retention below is manifest-driven, read defensively
        $maxRuns = 50; $maxAge = 30
        if ($manifest -and $manifest.PSObject.Properties['logRetention']) {
            if ($manifest.logRetention.maxRuns)    { $maxRuns = [int]$manifest.logRetention.maxRuns }
            if ($manifest.logRetention.maxAgeDays) { $maxAge  = [int]$manifest.logRetention.maxAgeDays }
        }
        $cut = (Get-Date).AddDays(-$maxAge)
        Get-ChildItem $logsDir -Filter 'run-*.json' -EA SilentlyContinue | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $maxRuns | Remove-Item -Force -EA SilentlyContinue
        Get-ChildItem $logsDir -Filter 'transcript-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $maxRuns | Remove-Item -Force -EA SilentlyContinue
        Get-ChildItem $logsDir -EA SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut -and $_.Name -ne 'latest.json' } |
            Remove-Item -Force -EA SilentlyContinue
    } catch {}

    if ($lockStream) { $lockStream.Close(); $lockStream.Dispose() }
    try { Stop-Transcript | Out-Null } catch {}
    exit $exitCode
}
