#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke-test the DEPLOYED installation, as opposed to the code.

.DESCRIPTION
    Invoke-Tests.ps1 verifies the code in this repository. Nothing verified that what is actually
    installed matches it, and the gap is not academic: the payload under ProgramData is a COPY,
    made at install time, and it is the copy the weekly SYSTEM task runs. A repository whose
    suite is green tells you nothing about a payload that was deployed three commits ago.

    That is a real failure this project has already had. A batch of safety fixes sat committed and
    green while the deployed copy still carried the bug they fixed - including one that let an
    unreadable tree read as ancient in the single module that has AutoApply.

    Report-only by design. This never passes -Apply: proving that deletion works is the unit
    suite's job and the audit trail's job, and a smoke test that deletes is one people stop
    running.

    Checks that need elevation are SKIPPED LOUDLY rather than passed quietly, on the same
    principle the unit suite uses - a check that reports success while verifying nothing is the
    exact failure this project exists to catch.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-DeploymentSmoke.ps1

.EXAMPLE
    .\tests\Invoke-DeploymentSmoke.ps1 -Elevate
    Prompts once for UAC and runs the deployed dispatcher and the task query as well.
#>
[CmdletBinding()]
param(
    [string]$PayloadRoot = 'C:\ProgramData\PcMaintenance',
    [switch]$Elevate
)

# Resolved in the body, not a param default: under 5.1 [CmdletBinding()] makes $PSScriptRoot
# empty inside a param default block. Same trap the dispatcher documents and pins.
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }

# All four, in the dispatcher's own order. Sourcing only PMCommon left Get-PMDownloadsPath and
# Get-PMManifest undefined, and the checks that needed them SKIPPED rather than failed - honest,
# but skipping for a reason that had nothing to do with the thing under test.
foreach ($f in 'PMCommon.ps1', 'PMManifest.ps1', 'PMModule.ps1', 'PMReport.ps1') {
    . (Join-Path $repoRoot (Join-Path 'lib' $f))
}

# -Elevate relaunches the WHOLE script, not just the dispatcher run. Elevating only the sub-steps
# left the task checks skipping, because Test-PMElevated is still false in this process - the
# switch would have looked like it worked while four checks quietly verified nothing.
# The child writes a transcript we print here, since a RunAs window's output does not come back.
if ($Elevate -and -not (Test-PMElevated)) {
    $relay = Join-Path ([IO.Path]::GetTempPath()) ("pm-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".log")
    $inner = '$t=''{0}''; Start-Transcript -Path $t | Out-Null; & ''{1}'' -PayloadRoot ''{2}''; $c=$LASTEXITCODE; Stop-Transcript | Out-Null; exit $c' -f $relay, $PSCommandPath, $PayloadRoot
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    try {
        $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $b64)
        if (Test-Path -LiteralPath $relay) {
            Get-Content -LiteralPath $relay | Where-Object { $_ -notmatch '^\*{10,}|^(Windows PowerShell transcript|Start time|End time|Username|RunAs User|Configuration Name|Machine|Host Application|Process ID|PSVersion|PSEdition|PSCompatibleVersions|BuildVersion|CLRVersion|WSManStackVersion|PSRemotingProtocolVersion|SerializationVersion)' }
            Remove-Item -LiteralPath $relay -Force -ErrorAction SilentlyContinue
        }
        exit $p.ExitCode
    } catch {
        Write-Host "could not elevate: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0

function Check {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        $v = & $Body
        if ($v -is [string] -and $v -eq 'SKIP') {
            $script:Skip++; Write-Host "  SKIP $Name" -ForegroundColor Yellow; return
        }
        if ($v) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
        else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
    } catch {
        $script:Fail++; Write-Host "  FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n=== deployment smoke: $PayloadRoot ===" -ForegroundColor Cyan

# --- 1. the payload exists and MATCHES this working tree -------------------------------
# The whole reason this file exists. A drifted payload is invisible from the repo side.
Write-Host "`n== the deployed payload matches this repository ==" -ForegroundColor Cyan

Check 'the payload root exists' { Test-Path -LiteralPath $PayloadRoot }

foreach ($item in (Get-PMPayloadItems)) {
    $i = $item
    Check "deployed '$i' is identical to the repo copy" {
        $src = Join-Path $repoRoot $i
        $dst = Join-Path $PayloadRoot $i
        if (-not (Test-Path -LiteralPath $dst)) { return $false }
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            return ((Get-FileHash -LiteralPath $src).Hash -eq (Get-FileHash -LiteralPath $dst).Hash)
        }
        # A directory: compare the set of relative paths AND every file hash. Comparing only
        # names would miss the exact drift this test was written for.
        $rel = { param($root) Get-ChildItem -LiteralPath $root -Recurse -File |
                    ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\') } }
        $a = @(& $rel $src | Sort-Object)
        $b = @(& $rel $dst | Sort-Object)
        if (($a -join '|') -ne ($b -join '|')) { return $false }
        foreach ($r in $a) {
            if ((Get-FileHash -LiteralPath (Join-Path $src $r)).Hash -ne
                (Get-FileHash -LiteralPath (Join-Path $dst $r)).Hash) { return $false }
        }
        return $true
    }
}

# --- 2. the ACL that makes a SYSTEM task safe ------------------------------------------
# The dispatcher dot-sources every .ps1 under lib\ and the task runs as SYSTEM, so a payload a
# standard user can write to is arbitrary code execution as SYSTEM.
Write-Host "`n== the payload is not writable by a non-administrator ==" -ForegroundColor Cyan

Check 'Test-PMPayloadSecure reports no non-admin writers' {
    @(Test-PMPayloadSecure -Path $PayloadRoot).Count -eq 0
}
Check 'and a real write into lib\ is actually refused' {
    # Belt and braces: the ACL check reads the DACL, this proves the kernel agrees with it.
    # Only meaningful unelevated - an admin is supposed to be able to write here.
    if (Test-PMElevated) { return 'SKIP' }
    $probe = Join-Path $PayloadRoot 'lib\smoke-probe.tmp'
    try { Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop }
    catch { return $true }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    return $false
}

# --- 3. the scheduled task ---------------------------------------------------------------
# A SYSTEM-registered task is admin-only to VIEW. A non-elevated query returning nothing means
# it exists and you cannot see it, not that it is missing - so this must skip, never fail.
Write-Host "`n== the weekly task is registered and points at this payload ==" -ForegroundColor Cyan

$task = if (Test-PMElevated) { Get-ScheduledTask -TaskName 'PcMaintenance' -ErrorAction SilentlyContinue } else { $null }

Check 'the task exists' {
    if (-not (Test-PMElevated)) { return 'SKIP' }   # admin-only to view; absence here proves nothing
    $null -ne $task
}
Check 'it runs as SYSTEM' {
    if (-not (Test-PMElevated)) { return 'SKIP' }
    $task -and $task.Principal.UserId -match '(?i)system'
}
Check 'its action points at THIS payload root' {
    if (-not (Test-PMElevated)) { return 'SKIP' }
    $task -and $task.Actions[0].Arguments -like "*$PayloadRoot\Invoke-PcMaintenance.ps1*"
}
Check 'StartWhenAvailable is set, so a machine that was off still gets its sweep' {
    if (-not (Test-PMElevated)) { return 'SKIP' }
    $task -and $task.Settings.StartWhenAvailable
}

# --- 4. the deployed dispatcher actually runs -------------------------------------------
# Report-only. Asserts the run id CHANGED rather than that a timestamp looks recent, because
# design.md's gotcha list records that waiting for "recent" happily reads the previous run.
Write-Host "`n== the deployed dispatcher runs and writes an honest record ==" -ForegroundColor Cyan

$logs = Join-Path $PayloadRoot 'logs'
$latest = Join-Path $logs 'latest.json'
$before = if (Test-Path -LiteralPath $latest) {
    (Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json).runId
} else { '<none>' }

# No RunAs branch here. -Elevate relaunches the whole script above, so by this point we are
# either already elevated or the operator did not ask for it; a second elevation path would be
# unreachable code in a file whose job is to catch exactly that.
$ranIt = $false
if (Test-PMElevated) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PayloadRoot 'Invoke-PcMaintenance.ps1') | Out-Null
    $ranIt = $true
}

Check 'a fresh run was produced (run id CHANGED, not merely recent)' {
    if (-not $ranIt) { return 'SKIP' }   # pass -Elevate to exercise this
    (Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json).runId -ne $before
}
Check 'that run was report-only and applied nothing' {
    if (-not $ranIt) { return 'SKIP' }
    $r = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
    ($r.mode -eq 'report') -and ([int]$r.summary.applied -eq 0) -and ([int]$r.summary.bytes -eq 0)
}
Check 'every enabled module reported a status, none left unknown' {
    if (-not $ranIt) { return 'SKIP' }
    $r = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
    $enabled = @(Get-PMEnabledModules -Manifest (Get-PMManifest -Path (Join-Path $PayloadRoot 'pcmaintenance.manifest.json')))
    (@($r.modules).Count -eq $enabled.Count) -and -not (@($r.modules) | Where-Object { $_.status -eq 'unknown' })
}

# --- 5. the delivered artifact ------------------------------------------------------------
# The report is the product. A sweep nobody can read is a sweep that did not happen.
Write-Host "`n== the HTML report is delivered, self-contained and escaped ==" -ForegroundColor Cyan

# Resolved the way the dispatcher resolves it. Calling Get-PMDownloadsPath with no user falls
# all the way through to $env:TEMP, which exists and holds no reports - so the check failed
# while pointing at a folder the tool never writes to.
$dl = try {
    $u = Get-PMInteractiveUserSid
    Get-PMDownloadsPath -UserSid $u.Sid -UserProfile $u.Profile
} catch { $null }
$reports = if ($dl -and (Test-Path -LiteralPath $dl)) {
    @(Get-ChildItem -LiteralPath $dl -Filter 'PC-Maintenance Report - *.html' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
} else { @() }

Check 'at least one report exists in the resolved Downloads folder' {
    if (-not $dl) { return 'SKIP' }   # could not resolve Downloads for this user
    $reports.Count -gt 0
}
Check 'retention kept no more than the manifest allows' {
    if (-not $reports.Count) { return 'SKIP' }
    $m = Get-PMManifest -Path (Join-Path $repoRoot 'pcmaintenance.manifest.json')
    $keep = if ($m.PSObject.Properties['reportsToKeep']) { [int]$m.reportsToKeep } else { 2 }
    $reports.Count -le $keep
}
Check 'the newest report fetches nothing from the network' {
    if (-not $reports.Count) { return 'SKIP' }
    $t = Get-Content -LiteralPath $reports[0].FullName -Raw
    -not ($t -match '(?i)https?://|@import|<script|<link\s|integrity=|srcset=')
}
Check 'and its interpolated values are HTML-escaped' {
    if (-not $reports.Count) { return 'SKIP' }
    $t = Get-Content -LiteralPath $reports[0].FullName -Raw
    # A bare & that does not begin a valid entity is the signature of an unescaped interpolation.
    -not ($t -match '&(?!(?:[a-zA-Z][a-zA-Z0-9]{1,10}|#\d{1,6}|#x[0-9a-fA-F]{1,6});)')
}

$tail = if ($script:Skip) { " ({0} SKIPPED - those verified nothing)" -f $script:Skip } else { '' }
Write-Host ("`n{0} passed, {1} failed{2}`n" -f $script:Pass, $script:Fail, $tail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
# Keyed on actual privilege, not on the switch. The elevated relaunch does not forward -Elevate,
# so the child printed "re-run with -Elevate" while already running as admin - advice that could
# not help, attached to the one check that only ever runs UNelevated.
if ($script:Skip -and -not (Test-PMElevated)) {
    Write-Host "re-run with -Elevate (or from an elevated shell) to exercise the skipped checks`n" -ForegroundColor Yellow
}
exit $(if ($script:Fail) { 1 } else { 0 })
