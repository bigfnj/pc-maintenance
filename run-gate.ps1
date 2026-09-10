#Requires -Version 5.1
<#
.SYNOPSIS
    Run every check this repository has, in one command, and give one answer.

.DESCRIPTION
    There was no single command. Verifying a change meant remembering several, running them in
    the right order and reading two different tallies - which is the shape of a process people
    half-do under time pressure, and half-doing it is indistinguishable from doing it until
    something breaks.

    THREE RULES, each earned from a real failure in these two repositories:

    1. A MISSING SUITE IS A FAILURE, never a warning. A gate that goes green because its tests
       vanished reports a safety it never checked. The sibling repo's smoke test warned
       "triage test suite not found" for a day - the path had a literal TAB where \tests
       belonged - and stayed green the whole time.

    2. A SUITE THAT PRINTS NO TALLY IS A FAILURE, even when it exits 0. A PowerShell script
       with no explicit exit inherits the exit code of the last native command it happened to
       run, so the exit code alone can be someone else's answer. The tally is independent
       evidence that the suite reached its own summary line.

    3. EVERY SUITE RUNS UNDER powershell.exe, NEVER pwsh - regardless of which host launched
       this script. The scheduled task runs Windows PowerShell 5.1. The 5.1-vs-7 divergences
       are silent: `&&`, `??` and ternary parse cleanly under 7 and are parse errors under 5.1,
       Get-WmiObject exists in one and not the other. A gate that checks whichever host the
       operator happened to use is a gate that stops checking the thing that matters.

.PARAMETER Only
    Run a single suite by name. Everything still has to exist - naming one suite does not
    excuse the others from being present.

.EXAMPLE
    .\run-gate.ps1
    .\run-gate.ps1 -Only unit
#>
[CmdletBinding()]
param(
    [ValidateSet('unit', 'deployment')]
    [string]$Only
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

# Rule 3. Resolved explicitly rather than trusting PATH, because a shim called powershell.exe
# would defeat the entire point of the rule.
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $ps51)) { Write-Host "FATAL: Windows PowerShell 5.1 not found at $ps51" -ForegroundColor Red; exit 2 }

$suites = @(
    @{ Name = 'unit'
       Path = 'tests\Invoke-Tests.ps1'
       What = 'library, guard, module and report behaviour' }
    @{ Name = 'deployment'
       Path = 'tests\Invoke-DeploymentSmoke.ps1'
       What = 'the LIVE installation under C:\ProgramData, not this checkout' }
)

$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ''
Write-Host "=== gate: pc-maintenance ===" -ForegroundColor Cyan
Write-Host ("host {0} -> suites under {1}" -f $PSVersionTable.PSVersion, (Split-Path $ps51 -Leaf)) -ForegroundColor DarkGray
if (-not $isAdmin) {
    # Stated, not hidden. Some checks genuinely cannot run unelevated, and a gate that quietly
    # skips them while printing a clean bill is the failure this file exists to prevent.
    Write-Host 'running UNELEVATED - the deployment suite will skip its scheduled-task and ACL checks' -ForegroundColor Yellow
}
Write-Host ''

$results = @()
$hardFail = $false

foreach ($s in $suites) {
    if ($Only -and $s.Name -ne $Only) { continue }

    $path = Join-Path $repoRoot $s.Path
    if (-not (Test-Path -LiteralPath $path)) {
        # Rule 1.
        Write-Host ("MISSING  {0,-11} {1}" -f $s.Name, $s.Path) -ForegroundColor Red
        $results += [pscustomobject]@{ Suite = $s.Name; Passed = 0; Failed = 0; Status = 'MISSING' }
        $hardFail = $true
        continue
    }

    Write-Host ("running  {0,-11} {1}" -f $s.Name, $s.What) -ForegroundColor DarkGray
    $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
    $code = $LASTEXITCODE

    # Rule 2. Both suites end with "<n> passed, <n> failed"; the smoke variant inserts a
    # warnings count between them, so the two numbers are matched independently.
    $passed = $null; $failed = $null
    $tally = ($out -split "`r?`n" | Where-Object { $_ -match '\d+\s+passed' } | Select-Object -Last 1)
    if ($tally -match '(\d+)\s+passed') { $passed = [int]$Matches[1] }
    if ($tally -match '(\d+)\s+failed') { $failed = [int]$Matches[1] }

    $status =
        if ($null -eq $passed -or $null -eq $failed) { 'NO TALLY' }
        elseif ($failed -gt 0)                       { 'FAILED' }
        elseif ($code -ne 0)                         { 'EXIT<>0' }
        else                                         { 'ok' }

    if ($status -ne 'ok') {
        $hardFail = $true
        Write-Host $out
    }
    $results += [pscustomobject]@{ Suite = $s.Name; Passed = $passed; Failed = $failed; Status = $status }
}

Write-Host ''
Write-Host '--- summary ---' -ForegroundColor Cyan
foreach ($r in $results) {
    $colour = if ($r.Status -eq 'ok') { 'Green' } else { 'Red' }
    Write-Host ("{0,-11} {1,5} passed {2,4} failed   {3}" -f $r.Suite, $r.Passed, $r.Failed, $r.Status) -ForegroundColor $colour
}
Write-Host ''

if ($hardFail) { Write-Host 'GATE FAILED' -ForegroundColor Red; exit 1 }
Write-Host 'gate passed' -ForegroundColor Green
exit 0
