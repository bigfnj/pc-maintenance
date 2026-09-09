#Requires -Version 5.1
<#
    Non-destructive test runner for pc-maintenance. No Pester dependency, same spirit as
    preference-guard's tests/Invoke-Tests.ps1.

    Nothing here deletes anything: the guard tests assert on Test-PMPathSafe directly, and the
    removal tests run against a throwaway tree under the caller's TEMP with -WhatIfOnly.

    Run under Windows PowerShell 5.1 as well as 7, because the scheduled task runs 5.1:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$libDir = Join-Path $root 'lib'
foreach ($f in 'PMCommon.ps1', 'PMManifest.ps1', 'PMModule.ps1', 'PMReport.ps1') { . (Join-Path $libDir $f) }

$script:Pass = 0; $script:Fail = 0
function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        $r = & $Body
        if ($r) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
        else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
    } catch {
        $script:Fail++; Write-Host "  FAIL $Name -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n== parses under $($PSVersionTable.PSVersion) ==" -ForegroundColor Cyan
foreach ($f in (Get-ChildItem $root -Recurse -Filter *.ps1 -File)) {
    It "parses: $($f.Name)" {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        return (-not $errs -or $errs.Count -eq 0)
    }
}

Write-Host "`n== dispatcher bootstrap ==" -ForegroundColor Cyan
It 'the dispatcher does not take PSScriptRoot as a param default' {
    # Under PS 5.1, [CmdletBinding()] makes $PSScriptRoot EMPTY inside a param default block.
    # It cost a full debugging cycle once; this pins it so nobody "tidies" the body-resolution
    # back into the param block, where it fails silently and cascades into every Join-Path.
    $src = Get-Content -LiteralPath (Join-Path $root 'Invoke-PcMaintenance.ps1') -Raw
    $paramBlock = [regex]::Match($src, '(?s)\[CmdletBinding\(\)\]\s*param\((.*?)\n\)').Groups[1].Value
    return ($paramBlock -notmatch 'PSScriptRoot')
}
It 'the dispatcher resolves PayloadRoot in its body' {
    $src = Get-Content -LiteralPath (Join-Path $root 'Invoke-PcMaintenance.ps1') -Raw
    return ($src -match '(?m)^\s*if \(-not \$PayloadRoot\) \{ \$PayloadRoot = \$PSScriptRoot \}')
}

Write-Host "`n== path guard ==" -ForegroundColor Cyan
$roots = @('C:\Users\Someone\AppData\Local\Temp')
It 'accepts a normal target under a declared root' { Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\Temp\abcd1234.xyz' -Roots $roots }
It 'refuses the declared root itself'              { -not (Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\Temp' -Roots $roots) }
It 'refuses a path outside every declared root'    { -not (Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\Other\x' -Roots $roots) }
It 'refuses a drive root'                          { -not (Test-PMPathSafe -Path 'C:\' -Roots @('C:\')) }
It 'refuses Windows even if declared as a root'    { -not (Test-PMPathSafe -Path 'C:\Windows\System32' -Roots @('C:\Windows')) }
It 'refuses Program Files even if declared'        { -not (Test-PMPathSafe -Path 'C:\Program Files\Thing\sub' -Roots @('C:\Program Files')) }
It 'refuses user Documents even if declared'       { -not (Test-PMPathSafe -Path 'C:\Users\Someone\Documents\book' -Roots @('C:\Users\Someone')) }
It 'refuses a Docker volume tree'                  { -not (Test-PMPathSafe -Path 'C:\ProgramData\docker\volumes\finance_data\_data' -Roots @('C:\ProgramData\docker')) }
It 'refuses DockerDesktop scratch'                 { -not (Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\Temp\DockerDesktop\x' -Roots $roots) }
It 'refuses anything under a .git directory'       { -not (Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\Temp\repo\.git\objects' -Roots $roots) }
It 'refuses node_modules'                          { -not (Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\Temp\p\node_modules\x' -Roots $roots) }
It 'refuses a path shallower than MinDepth'        { -not (Test-PMPathSafe -Path 'C:\Temp' -Roots @('C:\')) }
It 'refuses an empty path'                         { -not (Test-PMPathSafe -Path '' -Roots $roots) }
It 'refuses when the module declared no roots'     { -not (Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\Temp\x' -Roots @()) }
It 'is not fooled by a traversal back out'         { -not (Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\Temp\..\..\..\Documents\x' -Roots $roots) }

Write-Host "`n== apply gate (both sides must agree) ==" -ForegroundColor Cyan
It 'report-only run never applies, even for AutoApply' { -not (Test-PMApplyAllowed -Apply $false -ModuleInfo @{ AutoApply = $true }) }
It 'apply run does not apply without AutoApply'        { -not (Test-PMApplyAllowed -Apply $true  -ModuleInfo @{}) }
It 'apply run does not apply when AutoApply is false'  { -not (Test-PMApplyAllowed -Apply $true  -ModuleInfo @{ AutoApply = $false }) }
It 'apply run applies only when both agree'            {      (Test-PMApplyAllowed -Apply $true  -ModuleInfo @{ AutoApply = $true }) }

Write-Host "`n== category governance ==" -ForegroundColor Cyan
$mf = [pscustomobject]@{ allowedCategories = @('maintenance', 'hygiene') }
It 'allows a listed category'                    { Test-PMCategoryAllowed -Category 'maintenance' -Manifest $mf }
It 'refuses an unlisted category'                { -not (Test-PMCategoryAllowed -Category 'dev-enablement' -Manifest $mf) }
It 'refuses an empty category'                   { -not (Test-PMCategoryAllowed -Category '' -Manifest $mf) }
$mfBad = [pscustomobject]@{ allowedCategories = @('maintenance', 'firewall') }
It 'forbidden set beats a mislabelled allowlist' { -not (Test-PMCategoryAllowed -Category 'firewall' -Manifest $mfBad) }

Write-Host "`n== shipped modules ==" -ForegroundColor Cyan
$modDirs = Get-ChildItem (Join-Path $root 'modules') -Directory
It 'every module loads and declares the required keys' {
    foreach ($d in $modDirs) { $null = Import-PMModuleInfo -ModuleDir $d.FullName }
    return $true
}
It 'every module id matches its directory name' {
    foreach ($d in $modDirs) { if ((Import-PMModuleInfo -ModuleDir $d.FullName).Id -ne $d.Name) { return $false } }
    return $true
}
It 'every module category is permitted by the shipped manifest' {
    $m = Get-PMManifest -Path (Join-Path $root 'pcmaintenance.manifest.json')
    foreach ($d in $modDirs) {
        if (-not (Test-PMCategoryAllowed -Category (Import-PMModuleInfo -ModuleDir $d.FullName).Category -Manifest $m)) { return $false }
    }
    return $true
}
It 'exactly the two proven-mechanical modules declare AutoApply' {
    $auto = @($modDirs | Where-Object { [bool](Import-PMModuleInfo -ModuleDir $_.FullName)['AutoApply'] } | ForEach-Object { $_.Name } | Sort-Object)
    return (($auto -join ',') -eq 'plex-bif-orphans,vs-installer-scratch')
}
It 'every module reports a true Count alongside a possibly-capped Items' {
    # Two modules cap Items so a 6,935-orphan run does not bloat the run json. Without a
    # separate Count the dispatcher would log the CAP and disagree with the module's own
    # Detail string, which is the "two numbers, one of them decorative" trap.
    foreach ($d in $modDirs) {
        $src = Get-Content -LiteralPath (Join-Path $d.FullName 'module.ps1') -Raw
        if ($src -notmatch 'Clean\s+=\s+\$false') { return $false }
        if ($src -notmatch 'Count\s+=\s+@\(\$items\)\.Count') { return $false }
    }
    return $true
}
It 'every module in the manifest exists on disk' {
    $m = Get-PMManifest -Path (Join-Path $root 'pcmaintenance.manifest.json')
    foreach ($e in $m.modules) { if (-not (Test-Path (Join-Path $root "modules\$($e.id)"))) { return $false } }
    return $true
}

Write-Host "`n== Remove-PMPath ==" -ForegroundColor Cyan
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("pm-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$victim = Join-Path $sandbox 'deep\target'
New-Item -ItemType Directory -Path $victim -Force | Out-Null
Set-Content -LiteralPath (Join-Path $victim 'f.txt') -Value 'x' -Encoding UTF8
try {
    It 'report-only computes size and removes nothing' {
        $r = Remove-PMPath -Path $victim -Roots @($sandbox) -WhatIfOnly
        return ((-not $r.Removed) -and $r.Reason -eq 'report-only' -and (Test-Path $victim))
    }
    It 'refuses an unsafe path without touching it' {
        $r = Remove-PMPath -Path 'C:\Windows\System32' -Roots @('C:\Windows')
        return ((-not $r.Removed) -and $r.Skipped -and $r.Reason -eq 'refused by path guard' -and (Test-Path 'C:\Windows\System32'))
    }
    It 'removes a safe target when asked for real' {
        $r = Remove-PMPath -Path $victim -Roots @($sandbox)
        return ($r.Removed -and -not (Test-Path $victim))
    }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n== blind is not clean ==" -ForegroundColor Cyan
It 'the read-error collector records instead of swallowing' {
    Clear-PMReadErrors
    $null = Get-PMChildDirectory -Path (Join-Path ([IO.Path]::GetTempPath()) 'pm-does-not-exist-xyz')
    $before = Get-PMReadErrorCount           # a missing path is not an error, it is an answer
    try { Get-ChildItem -LiteralPath 'C:\__nope__\__nope__' -ErrorAction Stop } catch { Add-PMReadError -Errors $_ }
    return ($before -eq 0 -and (Get-PMReadErrorCount) -eq 1 -and (Get-PMCriticalReadErrorCount) -eq 0 -and (Get-PMReadErrorSample))
}
It 'only a CRITICAL read failure invalidates the answer' {
    Clear-PMReadErrors
    try { Get-ChildItem -LiteralPath 'C:\__nope__' -ErrorAction Stop } catch { Add-PMReadError -Errors $_ }
    try { Get-ChildItem -LiteralPath 'C:\__nope__' -ErrorAction Stop } catch { Add-PMReadError -Errors $_ -Critical }
    return ((Get-PMReadErrorCount) -eq 2 -and (Get-PMCriticalReadErrorCount) -eq 1)
}
It 'every shipped module marks its load-bearing read Critical' {
    # A module whose root read is not Critical can report clean while blind, which is the whole
    # bug. Cheap to forget, so it is pinned rather than trusted.
    foreach ($d in (Get-ChildItem (Join-Path $root 'modules') -Directory)) {
        $src = Get-Content -LiteralPath (Join-Path $d.FullName 'module.ps1') -Raw
        if ($src -notmatch '-Critical') { return $false }
    }
    return $true
}
It 'the dispatcher checks unverified BEFORE it checks clean' {
    # Order is the whole guarantee. If the clean branch ran first, a module that could not read
    # would return Clean=$true and continue out before anything noticed. Asserting only that the
    # unverified block EXISTS would still pass with the branches swapped.
    $src = Get-Content -LiteralPath (Join-Path $root 'Invoke-PcMaintenance.ps1') -Raw
    $iUnver = $src.IndexOf('$tw.CriticalReadErrors -gt 0')
    $iClean = $src.IndexOf('if ($t.Clean)')
    return ($iUnver -gt 0 -and $iClean -gt 0 -and $iUnver -lt $iClean)
}
It 'an unverified module makes the run exit non-zero' {
    $src = Get-Content -LiteralPath (Join-Path $root 'Invoke-PcMaintenance.ps1') -Raw
    return ($src -match '\$summary\.errors -gt 0 -or \$summary\.unverified -gt 0')
}
It 'Resolve-PMReparsePoint returns a plain path unchanged' {
    $p = [IO.Path]::GetTempPath().TrimEnd('\')
    return ((Resolve-PMReparsePoint -Path $p) -eq $p)
}
It 'Resolve-PMReparsePoint follows a junction to its target' {
    $base = Join-Path ([IO.Path]::GetTempPath()) ("pm-j-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $real = Join-Path $base 'real'; $link = Join-Path $base 'link'
    New-Item -ItemType Directory -Path $real -Force | Out-Null
    try {
        $null = cmd /c mklink /J "`"$link`"" "`"$real`"" 2>&1
        if (-not (Test-Path -LiteralPath $link)) { return $true }   # no junction support: not a failure
        return ((Resolve-PMReparsePoint -Path $link) -eq $real)
    } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'end to end: a module that cannot read is reported unverified, not clean' {
    $fx = Join-Path ([IO.Path]::GetTempPath()) ("pm-fx-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $md = Join-Path $fx 'modules\blindmod'
    New-Item -ItemType Directory -Path $md -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'lib') -Destination (Join-Path $fx 'lib') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'Invoke-PcMaintenance.ps1') -Destination $fx -Force
    @'
@{ Id='blindmod'; Name='Blind'; Category='maintenance'; Version='1.0.0'; RequiresUserSid=$false
   AutoApply=$false; Roots=@('C:\nowhere'); Entry='module.ps1'; Description='fixture' }
'@ | Set-Content -LiteralPath (Join-Path $md 'module.psd1') -Encoding UTF8
    @'
function Test-PMModule {
    param($Context)
    try { Get-ChildItem -LiteralPath 'C:\__nope__\__nope__' -ErrorAction Stop } catch { Add-PMReadError -Errors $_ -Critical }
    # Claims clean while blind - exactly the bug this guard exists for.
    [pscustomobject]@{ Clean = $true; Detail = 'looks clean to me'; Bytes = [int64]0; Items = @() }
}
function Repair-PMModule { param($Context) [pscustomobject]@{ Changed=$false; Ok=$true; Bytes=[int64]0; Detail='' } }
'@ | Set-Content -LiteralPath (Join-Path $md 'module.ps1') -Encoding UTF8
    '{ "schemaVersion":1, "allowedCategories":["maintenance"], "modules":[{"id":"blindmod","enabled":true,"order":10}] }' |
        Set-Content -LiteralPath (Join-Path $fx 'pcmaintenance.manifest.json') -Encoding UTF8
    try {
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fx 'Invoke-PcMaintenance.ps1') -NoReport 2>&1
        $j = Get-Content -LiteralPath (Join-Path $fx 'logs\latest.json') -Raw | ConvertFrom-Json
        return ($j.modules[0].status -eq 'unverified' -and $j.summary.unverified -eq 1 -and $j.exitCode -eq 1)
    } finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== HTML report ==" -ForegroundColor Cyan
$fakeRun = [ordered]@{
    runId = 'test-run'; startedUtc = (Get-Date).ToUniversalTime().ToString('o')
    version = '0.0.0'; mode = 'report'
    modules = @(
        [ordered]@{ id = 'mod-clean'; status = 'clean'; detail = 'nothing found'; bytes = [int64]0; count = 0; items = @() },
        [ordered]@{ id = 'mod-found'; status = 'reported'; detail = 'two things'; bytes = [int64]2048; count = 2
                    items = @(@{ path = 'C:\t\a & <b>"q"'; bytes = 1024; ageDays = 5 }, @{ path = 'C:\t\b'; bytes = 1024 }) }
    )
    summary = [ordered]@{ total = 2; clean = 1; found = 1; applied = 0; skipped = 0; unverified = 0; partial = 0; errors = 0; bytes = [int64]0 }
    exitCode = 0
}
$reportOut = Join-Path ([IO.Path]::GetTempPath()) ("pm-report-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".html")
try {
    $null = New-PMHtmlReport -Run $fakeRun -OutPath $reportOut
    $html = Get-Content -LiteralPath $reportOut -Raw

    It 'writes a file'                    { Test-Path -LiteralPath $reportOut }
    It 'is a complete html document'      { $html -match '(?i)^<!doctype html>' -and $html -match '(?i)</html>\s*$' }
    It 'renders one card per module'      { ([regex]::Matches($html, '<div class="card">')).Count -eq 2 }
    It 'leads with exactly one hero'      { ([regex]::Matches($html, 'class="hero"')).Count -eq 1 }
    It 'escapes html metacharacters in paths' {
        # A path containing & < > " must not reach the document raw, or one oddly-named
        # directory silently breaks every card after it.
        ($html -match 'a &amp; &lt;b&gt;&quot;q&quot;') -and ($html -notmatch 'a & <b>"q"')
    }
    It 'is self-contained: no external fetch' {
        # The report is opened offline, from Downloads, possibly months later. Any CDN,
        # webfont or remote image would render it broken exactly when it is needed.
        return ($html -notmatch '(?i)(src|href)\s*=\s*"\s*https?:') -and ($html -notmatch '(?i)@import') -and
               ($html -notmatch '(?i)url\(\s*[''"]?https?:')
    }
    It 'declares dark under BOTH the media query and the theme scope' {
        ($html -match 'prefers-color-scheme:\s*dark') -and ($html -match ':root\[data-theme="dark"\]')
    }
    It 'states the mode so a report run is never mistaken for a cleanup' { $html -match 'REPORT ONLY' }
    It 'says how many it showed when the list is capped' {
        $many = [ordered]@{
            runId='r'; startedUtc=(Get-Date).ToUniversalTime().ToString('o'); version='0'; mode='report'
            modules=@([ordered]@{ id='m'; status='reported'; detail='d'; bytes=[int64]100; count=940
                                  items=@(1..20 | ForEach-Object { @{ path="C:\t\$_"; bytes=5 } }) })
            summary=[ordered]@{ total=1;clean=0;found=1;applied=0;skipped=0;unverified=0;partial=0;errors=0;bytes=[int64]0 }; exitCode=0
        }
        $o2 = Join-Path ([IO.Path]::GetTempPath()) ("pm-report2-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".html")
        try { $null = New-PMHtmlReport -Run $many -OutPath $o2; return ((Get-Content $o2 -Raw) -match 'Showing 15 of 940') }
        finally { Remove-Item -LiteralPath $o2 -Force -ErrorAction SilentlyContinue }
    }
} finally { Remove-Item -LiteralPath $reportOut -Force -ErrorAction SilentlyContinue }

It 'Downloads resolution never returns empty' {
    # Degrades profile -> TEMP rather than failing: a missing report must not look like a
    # failed sweep, and an empty path would throw inside Join-Path.
    $p = Get-PMDownloadsPath -UserSid 'S-1-5-21-nonexistent' -UserProfile 'C:\Nope\NoSuchUser'
    return (-not [string]::IsNullOrWhiteSpace($p))
}

Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
