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
# -PayloadRoot is operator input, this script SELF-ELEVATES, and the loop below recursively
# force-deletes $PayloadRoot\lib, \modules and two files. The uninstaller has guarded its
# equivalent since an audit found -PayloadRoot C:\ProgramData would have taken all of
# ProgramData; the installer never got the same treatment, and 'lib' and 'modules' are very
# common source-tree names. Same guard, same MinDepth, checked before anything is removed.
$guardRoot = try { Split-Path -Parent $PayloadRoot } catch { $null }
if ([string]::IsNullOrWhiteSpace($guardRoot) -or
    -not (Test-PMPathSafe -Path $PayloadRoot -Roots @($guardRoot) -MinDepth 2)) {
    Write-PMLog "refusing to install into '$PayloadRoot' - the path guard rejects it" 'ERROR'
    exit 1
}

$items = @(Get-PMPayloadItems)
New-Item -ItemType Directory -Path $PayloadRoot -Force | Out-Null
foreach ($i in $items) {
    $src = Join-Path $SourceRoot $i
    $dst = Join-Path $PayloadRoot $i
    if (-not (Test-Path -LiteralPath $src)) { Write-PMLog "missing source: $i" 'ERROR'; exit 1 }
    # Test-PMPathSafe above compares STRINGS, and a string cannot reveal that $PayloadRoot is a
    # junction. Remove-Item -Recurse follows a link that is an ANCESTOR of its target - it only
    # declines to descend one it finds INSIDE the tree - so a junctioned payload root sends the
    # delete below straight through to the real lib\ and modules\, destroying them and leaving
    # the junction behind. That is the same HIGH-severity fault found and fixed in
    # agent-scratchpads; this site and the uninstaller's -KeepLogs were still calling only the
    # lexical half of the guard. Reproduced end to end before adding this.
    #
    # Guarded per item and only when $dst exists, because the check fails CLOSED on a directory
    # it cannot inspect: hoisting it above the loop would refuse every fresh install, where
    # $PayloadRoot legitimately does not exist yet.
    if ((Test-Path -LiteralPath $dst) -and (Test-PMPathTraversesLink -Path $dst -Root $guardRoot)) {
        Write-PMLog "refusing to deploy $i - '$dst' is reached through a junction or symlink, so removing it would delete the link target" 'ERROR'
        exit 1
    }
    # Both were unchecked, with $ErrorActionPreference at its default Continue. A held-open file
    # under lib\ made Remove-Item fail non-terminating, and Copy-Item -Recurse then nested the
    # new library at lib\lib\ leaving the OLD lib\*.ps1 in place - after which this script
    # hardened the ACL, registered the task and printed "install complete", exit 0, while the
    # weekly SYSTEM task ran stale code indefinitely. The ACL check cannot catch that: the ACL
    # is fine, the payload is wrong.
    # The post-condition is "the deployed copy is IDENTICAL to the source", which is what
    # "deployed" actually means. The first version of this asserted only that the destination
    # existed - and because Invoke-PMChange checks the post-condition BEFORE acting, every item
    # reported "already done" and nothing was copied. lib\ went stale on this machine within a
    # minute, reintroducing precisely the fault the deployment smoke test exists to catch.
    #
    # Hash comparison also subsumes the lib\lib\ nesting case for free: a nested copy changes
    # the destination's file set, so it is not identical.
    $deployed = Invoke-PMChange -What "deploy $i" `
        -Action {
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction Stop }
            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction Stop
        } `
        -Verify { Test-PMPayloadItemCurrent -Source $src -Dest $dst }
    if (-not $deployed.Ok) { exit 1 }
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
$stillOpen = @(Test-PMPayloadTreeSecure -Path $PayloadRoot)
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
        $gone = Invoke-PMChange -What 'remove the previous task registration' `
            -Action { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false } `
            -Verify { -not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) }
        if (-not $gone.Ok) { exit 1 }
    }
    # Register-ScheduledTask -Xml <string>, not schtasks.exe /xml: the XML is passed in memory, so
    # there is no temp file and no encoding pitfall, and a failure comes back as a real error.
    #
    # Verified by re-reading the registration rather than by the call not throwing: -ErrorAction
    # Stop catches an outright refusal, but "the cmdlet returned" and "a task named this now
    # exists and runs as SYSTEM" are different claims, and only the second is the one being made.
    $registered = Invoke-PMChange -What "register scheduled task '$TaskName' (weekly, Sunday 03:00, SYSTEM)" `
        -Action { $null = Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force -ErrorAction Stop } `
        -Verify {
            $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            $t -and $t.Principal.UserId -match '(?i)system'
        }
    if (-not $registered.Ok) { exit 1 }
} catch {
    Write-PMLog "task registration failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

if ($RunNow) {
    # REQUESTED, not "started". Whether the sweep then succeeds is not observable at the moment
    # the task is kicked off, and the previous wording ("started; see the run json") claimed a
    # run that may not have happened. Where a thing cannot be checked, the honest output says so
    # rather than borrowing confidence from the call returning.
    try {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-PMLog 'run requested; check the run json under the payload logs directory' 'INFO'
    } catch { Write-PMLog "could not start: $($_.Exception.Message)" 'WARN' }
}

Write-PMLog '=== install complete ===' 'OK'
exit 0
