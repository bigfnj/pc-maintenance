#Requires -Version 5.1
<#
.SYNOPSIS
    pc-maintenance dispatcher. Walks enabled modules, reports what has accumulated, and
    removes only what is both permitted and proven.

.DESCRIPTION
    Borrowed from a sibling project's dispatcher, with the default inverted. That one repairs by
    default and takes -DryRun to hold back; this tool REPORTS by default and takes
    -Apply to act, because the failure modes are not symmetric. A preference left unrepaired is
    an inconvenience you notice; a file deleted wrongly is gone.

    Deletion needs BOTH -Apply here AND AutoApply=$true in the module's own manifest, and every
    path additionally passes the hard-coded guard in PMCommon before it can be removed.

    There is no backup phase. The original snapshots a registry key before writing it and
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
# Only CONTENTION is a benign exit. An UnauthorizedAccessException here means the payload root is
# read-only or ACL-denied, and treating that as "another run holds the lock" would make a weekly
# job that can no longer write to its own directory report success forever.
try { $lockStream = [System.IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None') }
catch [System.IO.IOException] {
    Write-PMLog "Another pc-maintenance run holds $lockFile; exiting." 'WARN'
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}
catch {
    Write-PMLog "cannot open the run lock at $lockFile - $($_.Exception.GetType().Name): $($_.Exception.Message)" 'ERROR'
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

# Before anything else. We dot-source every .ps1 under lib\ and the scheduled task runs as
# SYSTEM, so a payload directory a standard user can write to is arbitrary code execution as us.
#
# Scoped to a PRIVILEGED run on purpose. The risk is elevation: a low-privileged user planting a
# file that a high-privileged process then executes. A normal user running this by hand out of a
# directory that same user owns gains nothing they did not already have, and refusing there would
# only push people toward a bypass switch - which would then be the hole.
$insecure = if (Test-PMElevated) { @(Test-PMPayloadSecure -Path $PayloadRoot) } else { @() }
if ($insecure.Count) {
    Write-PMLog "REFUSING TO RUN: $PayloadRoot is writable by a non-administrator." 'ERROR'
    foreach ($b in $insecure) { Write-PMLog "  $b" 'ERROR' }
    Write-PMLog "Re-run Install-PcMaintenance.ps1 to harden it, or fix the ACL by hand." 'ERROR'
    if ($lockStream) { try { $lockStream.Dispose() } catch {} }
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

$results = @()
$summary = [ordered]@{ total = 0; clean = 0; found = 0; applied = 0; skipped = 0; unverified = 0; partial = 0; errors = 0; bytes = [int64]0 }

$fatal = $null
try {
    $mode = if ($Apply) { 'APPLY' } else { 'REPORT-ONLY' }
    Write-PMLog "=== pc-maintenance $DispatcherVersion (run $runId, $mode) ===" 'INFO'

    $manifest = Get-PMManifest -Path $ManifestPath
    $enabled  = Get-PMEnabledModules -Manifest $manifest
    if ($Only) {
        # A name that matches nothing is a typo, and it must not read as a clean machine.
        # `-Only plex-bif-orphan` (singular) used to log total=0 clean=0 found=0, write a run
        # JSON with an empty modules array, ADVANCE latest.json and emit a "Reclaimable now: 0 B"
        # report, exit 0 - indistinguishable from a sweep that genuinely found nothing.
        # Throwing here lands in the fatal handler, which deliberately does not touch latest.json.
        $known = @($enabled | ForEach-Object { [string]$_.id })
        $unknown = @($Only | Where-Object { $known -notcontains $_ })
        if ($unknown.Count) {
            throw ("-Only names no enabled module: {0}. Enabled: {1}" -f ($unknown -join ', '), ($known -join ', '))
        }
        $enabled = @($enabled | Where-Object { $Only -contains $_.id })
    }

    $user = Get-PMInteractiveUserSid
    $sidLabel = if ($user.Sid) { $user.Sid } else { '<none>' }
    Write-PMLog ("interactive user: {0} (loggedIn={1}, inferred={2})" -f $sidLabel, $user.LoggedIn, $user.Inferred)
    if ($user.Inferred) {
        # Every per-user number in this run describes whichever profile the registry happened to
        # yield first. Deletion is already blocked for it; the READING has to say so too, or the
        # report looks identical to one built on a confirmed session.
        Write-PMLog 'that profile was INFERRED from the registry, not observed - per-user figures may describe the wrong user' 'WARN'
    }

    foreach ($mod in $enabled) {
        $modId  = [string]$mod.id
        $modDir = Join-Path $modulesDir $modId
        $summary.total++
        $row = [ordered]@{ id = $modId; status = 'unknown'; detail = ''; bytes = [int64]0; count = 0
                           readErrors = 0; readErrorMessages = @(); items = @() }
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
            $holdBack = $null

            # A GUESSED user must never be deleted for. Get-PMInteractiveUserSid's last resort
            # picks the first plausible profile out of the registry with no ordering guarantee and
            # reports LoggedIn=$false. That is fine for reporting - a wrong number is visible and
            # harmless - and not fine for removal, which on a multi-profile machine with nobody
            # signed in would delete inside a stranger's Temp.
            if ($mayApply -and -not (Test-PMActingUserConfirmed -RequiresUserSid ([bool]$info['RequiresUserSid']) -LoggedIn ([bool]$user.LoggedIn))) {
                $mayApply = $false
                $holdBack = 'the interactive user was inferred, not confirmed logged on'
                Write-PMLog "$modId will report only - interactive user was inferred, not confirmed" 'SKIP'
            }

            # Declared roots, expanded against the INTERACTIVE user and junction-resolved. The
            # module cannot influence these, which is what makes them an independent condition
            # rather than the self-certification the run-time root alone provides.
            $declaredRoots = Get-PMDeclaredRoots -ModuleInfo $info -UserProfile $user.Profile
            if ($mayApply -and -not @($declaredRoots).Count) {
                $mayApply = $false
                $holdBack = 'the module declares no resolvable Roots'
                Write-PMLog "$modId will report only - no resolvable declared Roots" 'WARN'
            }

            $ctx = @{
                UserSid = $user.Sid; UserProfile = $user.Profile
                PayloadRoot = $PayloadRoot; ModuleRoot = $modDir; LibDir = $libDir
                RunId = $runId; Apply = $mayApply
                DeclaredRoots = $declaredRoots
                IsInteractiveUserLoggedIn = $user.LoggedIn
            }

            $tw = Invoke-PMModulePhase -ModuleDir $modDir -Phase Test -Context $ctx -LibDir $libDir -Entry $info.Entry
            $t = $tw.Result

            # A module that returned NOTHING, or leaked extra output so the result is an array,
            # must not be interpreted. Two distinct failures made this necessary:
            #   $null    -> the clean branch below is falsy, so control fell through to found and
            #               then to the DELETING phase: absence of an answer read as consent.
            #   Object[] -> `$t.Count` silently resolves to the ARRAY's length instead of the
            #               module's field, so a module reporting 940 was recorded as 2.
            if ($null -eq $t -or $t -is [array] -or $null -eq $t.PSObject.Properties['Clean']) {
                $shape = if ($null -eq $t) { 'nothing' } elseif ($t -is [array]) { "$(@($t).Count) objects" } else { 'no Clean field' }
                $row.status = 'error'
                $row.detail = "Test returned $shape; a module must return exactly one result object"
                Write-PMLog "$modId ERROR - $($row.detail)" 'ERROR'
                $summary.errors++; $results += $row; continue
            }
            $row.readErrors = [int]$tw.ReadErrors
            $row.readErrorMessages = @($tw.ReadErrorMessages)
            $row.bytes = if ($null -ne $t.Bytes) { [int64]$t.Bytes } else { [int64]0 }
            $row.items = @($t.Items)
            # Count is the TRUE number found. Items is capped by every module so a 6,935-orphan
            # run does not bloat every run json, so logging @($t.Items).Count would report the
            # cap and quietly disagree with the module's own Detail string.
            #
            # Tested for PRESENCE, the same way Clean is above, not with `$null -ne $t.Count`.
            # That test is version-dependent: under 5.1 a pscustomobject with no Count member
            # yields $null and the fallback runs, but under PowerShell 7 the scalar-as-collection
            # adapter supplies Count = 1, so the condition is ALWAYS true and the fallback is
            # unreachable. A future module returning Items without Count would then have a
            # 6,000-item finding recorded as 1 - in the record that stands in for a backup.
            $row.count = if ($t.PSObject.Properties['Count']) { [int]$t.Count } else { @($t.Items).Count }
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
                $summary.partial += [int]$tw.ReadErrors
                $row.detail += " [partial coverage: $($tw.ReadErrors) location(s) unreadable, e.g. $($tw.ReadErrorSample)]"
                Write-PMLog "$modId partial coverage - $($tw.ReadErrors) unreadable, e.g. $($tw.ReadErrorSample)" 'SKIP'
            }

            if ($t.Clean) {
                $row.status = 'clean'
                Write-PMLog "$modId clean - $($t.Detail)" 'OK'; $summary.clean++; $results += $row; continue
            }

            $summary.found++
            Write-PMLog ("{0} found {1} in {2} item(s) - {3}" -f $modId, (Format-PMBytes $row.bytes), $row.count, $t.Detail) 'WARN'

            if (-not $mayApply) {
                # $holdBack is set where the decision was actually made. Recomputing it here always
                # said "does not declare AutoApply", even when the real reason was an inferred user
                # or an unresolvable declared root - and the run JSON is the audit trail.
                $reason = if ($holdBack) { $holdBack }
                          elseif (-not $Apply) { 'report-only run' }
                          else { 'module does not declare AutoApply' }
                $row.status = 'reported'; $row.detail += " [not removed: $reason]"
                Write-PMLog "$modId not removed - $reason" 'SKIP'; $results += $row; continue
            }

            # Hand Test's measurements to Repair. The phases run in separate & {} child
            # scopes, so $ctx is the only channel between them; without this Repair walks
            # every selected tree again for a number taken seconds earlier.
            #
            # Onto the CONTEXT, never onto $row. The map is uncapped - that is the point -
            # and $row becomes the run JSON, where Items is capped at 25 per module
            # precisely to stop an unbounded field being written twice a run and kept 50
            # runs deep. A test pins that sizes never appears in the JSON.
            if ($t.PSObject.Properties['Sizes'] -and $t.Sizes -is [hashtable]) { $ctx.KnownSizes = $t.Sizes }

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
} catch {
    # A throw before the module loop (missing manifest, malformed JSON) used to land in finally
    # with errors = 0, exit 0, AND overwrite latest.json - so a job that could not read its own
    # config was indistinguishable from a perfect run, and destroyed the last real record doing it.
    $fatal = $_
    Write-PMLog "FATAL: $($_.Exception.Message)" 'ERROR'
} finally {
    # unverified is a real failure of the sweep's purpose, so it earns a non-zero exit too:
    # a weekly job that cannot see must not report success.
    $exitCode = if ($fatal -or $summary.errors -gt 0 -or $summary.unverified -gt 0) { 1 } else { 0 }
    $runObj = [ordered]@{
        runId = $runId; startedUtc = $startedUtc; finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
        version = $DispatcherVersion; mode = $(if ($Apply) { 'apply' } else { 'report' })
        # The run record has to carry HOW the user was resolved, not just which one. A report
        # built on a guessed profile is not wrong so much as unattributed, and it is
        # indistinguishable from a confirmed one without this.
        interactiveUser = [ordered]@{
            sid      = $(if ($user) { $user.Sid } else { $null })
            profile  = $(if ($user) { $user.Profile } else { $null })
            loggedIn = [bool]($user -and $user.LoggedIn)
            inferred = [bool]($user -and $user.Inferred)
        }
        modules = $results; summary = $summary; exitCode = $exitCode
        fatal = if ($fatal) { [string]$fatal.Exception.Message } else { $null }
    }
    try {
        $json = $runObj | ConvertTo-Json -Depth 8
        $json | Set-Content -LiteralPath (Join-Path $logsDir "run-$runId.json") -Encoding UTF8
        # latest.json is only advanced by a run that actually got as far as the module loop.
        # A config failure must not erase the last real record on its way out.
        if (-not $fatal) { $json | Set-Content -LiteralPath (Join-Path $logsDir 'latest.json') -Encoding UTF8 }
    } catch { Write-PMLog "could not write run json: $($_.Exception.Message)" 'ERROR' }

    # The human-facing artifact, dropped where the owner will actually see it. Wrapped so a
    # report failure can never turn a clean sweep into a failed run: the sweep is the work, the
    # report is the delivery, and losing the delivery is worth a WARN, not an exit code.
    if (-not $NoReport) {
        $reportsToKeep = 2
        if ($manifest -and $manifest.PSObject.Properties['reportsToKeep']) {
            $reportsToKeep = [int]$manifest.reportsToKeep
        }
        try {
            $dl = Get-PMDownloadsPath -UserSid $user.Sid -UserProfile $user.Profile
            $reportPath = Join-Path $dl (Get-PMReportFileName -When (Get-Date))
            $null = New-PMHtmlReport -Run $runObj -OutPath $reportPath
            Write-PMLog "report: $reportPath" 'OK'
            # Keep this run and the one before it, so the delta is readable without Downloads
            # filling up. Strictly name-matched; see Remove-PMOldReports for why this does not
            # and must not go through the path guard.
            $pruned = @(Remove-PMOldReports -Directory $dl -Keep $reportsToKeep)
            if ($pruned.Count) { Write-PMLog "removed $($pruned.Count) older report(s)" 'CHANGE' }
        } catch {
            Write-PMLog "could not write the HTML report: $($_.Exception.Message)" 'WARN'
        }
    }

    Write-PMLog ('=== SUMMARY total={0} clean={1} found={2} applied={3} skipped={4} unverified={5} errors={6} freed={7} (exit {8}) ===' -f `
            $summary.total, $summary.clean, $summary.found, $summary.applied, $summary.skipped,
            $summary.unverified, $summary.errors, (Format-PMBytes $summary.bytes), $exitCode) $(if ($exitCode) { 'ERROR' } else { 'OK' })

    try {
        $maxRuns = 50; $maxAge = 30   # only used if the manifest omits logRetention
        if ($manifest -and $manifest.PSObject.Properties['logRetention']) {
            if ($manifest.logRetention.maxRuns)    { $maxRuns = [int]$manifest.logRetention.maxRuns }
            if ($manifest.logRetention.maxAgeDays) { $maxAge  = [int]$manifest.logRetention.maxAgeDays }
        }
        # Was three inline pipelines, none of them -File and the last with no name filter at all,
        # so a directory under logs\ matched and Remove-Item -Force without -Recurse then failed
        # silently. Now one fenced function with tests behind it; see Remove-PMOldLogs.
        $null = Remove-PMOldLogs -Directory $logsDir -MaxRuns $maxRuns -MaxAgeDays $maxAge
    } catch {}

    # Dispose alone is enough, and it is wrapped: a throw here would skip Stop-Transcript below.
    if ($lockStream) { try { $lockStream.Dispose() } catch {} }
    try { Stop-Transcript | Out-Null } catch {}
    exit $exitCode
}
