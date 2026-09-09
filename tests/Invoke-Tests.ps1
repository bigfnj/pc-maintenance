#Requires -Version 5.1
<#
    Non-destructive test runner for pc-maintenance. No Pester dependency, in the same spirit as
    the runner in the project this borrows its framework from.

    Nothing here deletes anything: the guard tests assert on Test-PMPathSafe directly, and the
    removal tests run against a throwaway tree under the caller's TEMP with -WhatIfOnly.

    Run under Windows PowerShell 5.1 as well as 7, because the scheduled task runs 5.1:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$script:RepoRoot = $root
$libDir = Join-Path $root 'lib'
foreach ($f in 'PMCommon.ps1', 'PMManifest.ps1', 'PMModule.ps1', 'PMReport.ps1') { . (Join-Path $libDir $f) }

function New-PMFixtureRoot {
    <#
        A dispatcher fixture has to look like a real install, because the dispatcher refuses to
        run PRIVILEGED out of a directory a non-admin can write to. Under elevation these tests
        are themselves privileged, so an un-hardened fixture in the user's TEMP is correctly
        rejected and the suite would behave differently elevated than not. Hardening the fixture
        makes the two agree, and exercises Set-PMPayloadAcl on the way past.
    #>
    param([string]$Prefix)
    $fx = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $fx -Force | Out-Null
    if (Test-PMElevated) { Set-PMPayloadAcl -Path $fx }
    return $fx
}
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function It {
    <#
        A body returns $true, $false, or the string 'SKIP' when a precondition this machine cannot
        meet makes the check verify nothing. A skip is COUNTED AND PRINTED, never folded into the
        pass total: a check that quietly reports success while doing nothing is the exact failure
        this suite exists to catch, and the suite must not commit it itself.

        `if ($r)` is deliberately not used for the truthy test - a body that leaks a value plus
        $false forms a 2-element array, which PowerShell treats as true.
    #>
    param([string]$Name, [scriptblock]$Body)
    try {
        $r = @(& $Body)
        $v = if ($r.Count) { $r[-1] } else { $null }
        if ($v -is [string] -and $v -eq 'SKIP') {
            $script:Skip++; Write-Host "  SKIP $Name" -ForegroundColor Yellow
        } elseif ($v -eq $true) {
            $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green
        } else {
            $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red
        }
    } catch {
        $script:Fail++; Write-Host "  FAIL $Name -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Host "`n*** RUNNING UNDER PowerShell $($PSVersionTable.PSVersion). The scheduled task runs" -ForegroundColor Yellow
    Write-Host "*** Windows PowerShell 5.1, where ?? / ?. / ternary are PARSE ERRORS. The parse" -ForegroundColor Yellow
    Write-Host "*** checks below prove nothing about 5.1 from here. Re-run with powershell.exe." -ForegroundColor Yellow
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
It 'there are modules to check at all' {
    # Six tests below are `foreach (...) { ... }; return $true`, which pass on zero iterations.
    # Without this, deleting the modules directory left the whole suite green.
    return (@($modDirs).Count -ge 4)
}
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
        $r = Remove-PMPath -Path $victim -Roots @($sandbox) -DeclaredRoots @($sandbox) -WhatIfOnly
        return ((-not $r.Removed) -and $r.Reason -eq 'report-only' -and (Test-Path $victim))
    }
    It 'refuses an unsafe path without touching it' {
        $r = Remove-PMPath -Path 'C:\Windows\System32' -Roots @('C:\Windows') -DeclaredRoots @('C:\Windows')
        return ((-not $r.Removed) -and $r.Skipped -and $r.Reason -eq 'refused by path guard' -and (Test-Path 'C:\Windows\System32'))
    }
    It 'removes a safe target when asked for real' {
        $r = Remove-PMPath -Path $victim -Roots @($sandbox) -DeclaredRoots @($sandbox)
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
    $iClean = $src.IndexOf("`n            if (`$t.Clean) {")
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
        if (-not (Test-Path -LiteralPath $link)) {
            return 'SKIP'   # junctions unavailable here   # a skip that reports success is how a guard rots unnoticed
        }
        return ((Resolve-PMReparsePoint -Path $link) -eq $real)
    } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'end to end: a module that cannot read is reported unverified, not clean' {
    $fx = New-PMFixtureRoot -Prefix "pm-fx-"
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

Write-Host "`n== the deletion gates, wired end to end ==" -ForegroundColor Cyan
function New-PMGateFixture {
    <#
        A dispatcher fixture whose Repair drops a marker file. Testing the gates through the REAL
        dispatcher is the point: Test-PMApplyAllowed's truth table was already covered, but nothing
        asserted the dispatcher HONOURED it, so hardcoding $mayApply = $true left the suite green
        while a report-only run deleted.
    #>
    param([bool]$AutoApply)
    $fx = New-PMFixtureRoot -Prefix "pm-gate-"
    $md = Join-Path $fx 'modules\gatemod'
    New-Item -ItemType Directory -Path $md -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'lib') -Destination (Join-Path $fx 'lib') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Invoke-PcMaintenance.ps1') -Destination $fx -Force
    $auto = if ($AutoApply) { 'true' } else { 'false' }
    $psd1 = @(
        '@{'
        "    Id = 'gatemod'; Name = 'Gate'; Category = 'maintenance'; Version = '1.0.0'"
        '    RequiresUserSid = $false'
        "    AutoApply = `$$auto"
        "    Roots = @('$fx')"
        "    Entry = 'module.ps1'; Description = 'fixture'"
        '}'
    )
    $psd1 | Set-Content -LiteralPath (Join-Path $md 'module.psd1') -Encoding UTF8
    $marker = Join-Path $fx 'REPAIR-RAN.txt'
    $body = @(
        'function Test-PMModule {'
        '    param($Context)'
        "    [pscustomobject]@{ Clean = `$false; Count = 1; Detail = 'one thing'; Bytes = [int64]1; Items = @() }"
        '}'
        'function Repair-PMModule {'
        '    param($Context)'
        "    Set-Content -LiteralPath '$marker' -Value 'yes' -Encoding UTF8"
        "    [pscustomobject]@{ Ok = `$true; Bytes = [int64]0; Detail = 'fixture' }"
        '}'
    )
    $body | Set-Content -LiteralPath (Join-Path $md 'module.ps1') -Encoding UTF8
    '{ "schemaVersion":1, "allowedCategories":["maintenance"], "modules":[{"id":"gatemod","enabled":true,"order":10}] }' |
        Set-Content -LiteralPath (Join-Path $fx 'pcmaintenance.manifest.json') -Encoding UTF8
    return $fx
}
function Invoke-PMGateFixture {
    param([string]$Fixture, [bool]$Apply)
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Fixture 'Invoke-PcMaintenance.ps1'), '-NoReport')
    if ($Apply) { $a += '-Apply' }
    $null = & powershell.exe @a 2>&1
    return (Test-Path -LiteralPath (Join-Path $Fixture 'REPAIR-RAN.txt'))
}
foreach ($cell in @(
    @{ Auto = $true;  Apply = $true;  Expect = $true;  Name = 'AutoApply + -Apply    -> Repair RUNS' }
    @{ Auto = $true;  Apply = $false; Expect = $false; Name = 'AutoApply, no -Apply  -> Repair does not run' }
    @{ Auto = $false; Apply = $true;  Expect = $false; Name = 'no AutoApply, -Apply  -> Repair does not run' }
    @{ Auto = $false; Apply = $false; Expect = $false; Name = 'neither               -> Repair does not run' })) {
    $c = $cell
    It $c.Name {
        $fx = New-PMGateFixture -AutoApply $c.Auto
        try { return ((Invoke-PMGateFixture -Fixture $fx -Apply $c.Apply) -eq $c.Expect) }
        finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
It 'the PROCESS exit code reports failure, not just the JSON field' {
    # Task Scheduler only ever sees the process exit code. Asserting the JSON field alone meant
    # `exit $exitCode` could be changed to `exit 0` with the suite still green.
    $fx = New-PMFixtureRoot -Prefix "pm-exit-"
    $md = Join-Path $fx 'modules\blind2'
    New-Item -ItemType Directory -Path $md -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'lib') -Destination (Join-Path $fx 'lib') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Invoke-PcMaintenance.ps1') -Destination $fx -Force
    @(
        '@{'
        "    Id = 'blind2'; Name = 'B'; Category = 'maintenance'; Version = '1.0.0'"
        '    RequiresUserSid = $false'
        '    AutoApply = $false'
        "    Roots = @('C:\nowhere')"
        "    Entry = 'module.ps1'; Description = 'fixture'"
        '}'
    ) | Set-Content -LiteralPath (Join-Path $md 'module.psd1') -Encoding UTF8
    @(
        'function Test-PMModule {'
        '    param($Context)'
        "    try { Get-ChildItem -LiteralPath 'C:\__nope__\__nope__' -ErrorAction Stop } catch { Add-PMReadError -Errors `$_ -Critical }"
        "    [pscustomobject]@{ Clean = `$true; Detail = 'looks clean'; Bytes = [int64]0; Items = @() }"
        '}'
        'function Repair-PMModule { param($Context) [pscustomobject]@{ Ok = $true; Bytes = [int64]0; Detail = @() } }'
    ) | Set-Content -LiteralPath (Join-Path $md 'module.ps1') -Encoding UTF8
    '{ "schemaVersion":1, "allowedCategories":["maintenance"], "modules":[{"id":"blind2","enabled":true,"order":10}] }' |
        Set-Content -LiteralPath (Join-Path $fx 'pcmaintenance.manifest.json') -Encoding UTF8
    try {
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fx 'Invoke-PcMaintenance.ps1') -NoReport 2>&1
        return ($LASTEXITCODE -eq 1)
    } finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== declared Roots are enforced, not self-certified ==" -ForegroundColor Cyan
It 'Remove-PMPath fails CLOSED when no declared roots are supplied' {
    # Treating an empty list as "no restriction" would delete the independent half of the guard
    # exactly when a caller forgot to pass it.
    $r = Remove-PMPath -Path 'C:\Users\Someone\AppData\Local\Temp\x' -Roots @('C:\Users\Someone\AppData\Local\Temp')
    return ((-not $r.Removed) -and $r.Skipped -and ($r.Reason -match 'no declared roots'))
}
It 'Remove-PMPath refuses a target outside the module-declared roots' {
    # The module supplies -Roots itself, so on its own that is self-certification. -DeclaredRoots
    # comes from module.psd1 via the dispatcher, and the module cannot influence it.
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) ("pm-dr-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $inside = Join-Path $sandbox 'declared\thing'
    $outside = Join-Path $sandbox 'elsewhere\thing'
    New-Item -ItemType Directory -Path $inside -Force | Out-Null
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    try {
        $declared = @(Join-Path $sandbox 'declared')
        $r = Remove-PMPath -Path $outside -Roots @($sandbox) -DeclaredRoots $declared
        $blocked = ((-not $r.Removed) -and ($r.Reason -match 'declares') -and (Test-Path $outside))
        $r2 = Remove-PMPath -Path $inside -Roots @($sandbox) -DeclaredRoots $declared
        return ($blocked -and $r2.Removed)
    } finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'every shipped module declares Roots that actually resolve' {
    # plex-bif-orphans shipped a literal placeholder here and nothing noticed, because nothing
    # read the value. It is enforced now, so an unresolvable root disables removal entirely.
    foreach ($d in $modDirs) {
        $info = Import-PMModuleInfo -ModuleDir $d.FullName
        $rs = Get-PMDeclaredRoots -ModuleInfo $info -UserProfile $env:USERPROFILE
        if (-not @($rs).Count) { return $false }
        foreach ($r in $rs) { if ($r -match '[<>]') { return $false } }
    }
    return $true
}
It 'a root with an unresolvable token yields nothing rather than a guess' {
    return (-not (Expand-PMRoot -Root '%NO_SUCH_VAR_XYZ%\sub' -UserProfile $env:USERPROFILE))
}
It 'Expand-PMRoot expands against the INTERACTIVE user, not the process' {
    # Under SYSTEM the process LOCALAPPDATA points at the systemprofile, so expanding with
    # ExpandEnvironmentVariables alone would silently miss every declared root.
    $e = Expand-PMRoot -Root '%LOCALAPPDATA%\Temp' -UserProfile 'C:\Users\Someone'
    return ($e -eq 'C:\Users\Someone\AppData\Local\Temp')
}

Write-Host "`n== each forbidden pattern is pinned ==" -ForegroundColor Cyan
foreach ($case in @(
    @{ P = 'C:\Users\Someone\AppData\Local\Temp\wsl\ext4';          N = 'wsl' }
    @{ P = 'C:\Users\Someone\AppData\Local\Temp\x\site-packages\y'; N = 'site-packages' }
    @{ P = 'C:\Users\Someone\Desktop\thing';                        N = 'Desktop' }
    @{ P = 'C:\Users\Someone\Pictures\thing';                       N = 'Pictures' }
    @{ P = 'C:\Users\Someone\Videos\thing';                         N = 'Videos' }
    @{ P = 'C:\Users\Someone\Music\thing';                          N = 'Music' }
    @{ P = 'C:\Users\Someone\Downloads\thing';                      N = 'Downloads (where this tool writes its reports)' }
    @{ P = 'C:\Program Files (x86)\App\sub';                        N = 'Program Files (x86)' })) {
    $k = $case
    It "refuses $($k.N)" { -not (Test-PMPathSafe -Path $k.P -Roots @('C:\Users\Someone', 'C:\Program Files (x86)')) }
}
It 'refuses a sibling whose name merely starts with the root name' {
    # The prefix check and the root-itself check used to cover for each other, so breaking either
    # one alone left the suite green while C:\...\TempEvil became deletable.
    -not (Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\TempEvil\x' -Roots @('C:\Users\Someone\AppData\Local\Temp'))
}

Write-Host "`n== Get-PMPathSize ==" -ForegroundColor Cyan
It 'a missing path is an answer, not an error' {
    Clear-PMReadErrors
    $n = Get-PMPathSize -Path 'C:\__nope__\__nope__'
    return ((Get-PMReadErrorCount) -eq 0 -and $n -eq 0)
}
It 'agrees with a known tree' {
    $sb = Join-Path ([IO.Path]::GetTempPath()) ("pm-sz-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path (Join-Path $sb 'a\b') -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $sb 'a\one.txt') -Value ('x' * 100) -Encoding Ascii -NoNewline
        Set-Content -LiteralPath (Join-Path $sb 'a\b\two.txt') -Value ('y' * 50) -Encoding Ascii -NoNewline
        return ((Get-PMPathSize -Path $sb) -eq 150)
    } finally { Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== acting only for a confirmed user ==" -ForegroundColor Cyan
It 'a module needing a user will not act when that user was only inferred' {
    -not (Test-PMActingUserConfirmed -RequiresUserSid $true -LoggedIn $false)
}
It 'a module needing a user acts when the user is confirmed logged on' {
    Test-PMActingUserConfirmed -RequiresUserSid $true -LoggedIn $true
}
It 'a module needing no user is unaffected either way' {
    (Test-PMActingUserConfirmed -RequiresUserSid $false -LoggedIn $false) -and
    (Test-PMActingUserConfirmed -RequiresUserSid $false -LoggedIn $true)
}

Write-Host "`n== the payload must not be writable by a non-admin ==" -ForegroundColor Cyan
It 'a user-writable directory is reported as insecure' {
    # The dispatcher dot-sources every .ps1 under lib\, so a directory a standard user can write
    # to is code execution as whoever runs the task. A directory under the user's own TEMP is
    # writable by that user by construction, which makes it the natural fixture.
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-acl-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    try { return (@(Test-PMPayloadSecure -Path $d).Count -gt 0) }
    finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a hardened directory passes the same check' {
    # Proves Set-PMPayloadAcl actually satisfies Test-PMPayloadSecure. If these two ever drift,
    # the installer would "succeed" and the dispatcher would refuse to run forever after.
    if (-not (Test-PMElevated)) {
        return 'SKIP'   # needs elevation to set an ACL
    }
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-acl2-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    try {
        Set-PMPayloadAcl -Path $d
        return (@(Test-PMPayloadSecure -Path $d).Count -eq 0)
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'the deployed payload is not writable by a non-admin' {
    # The live install, not a fixture. Skips cleanly when nothing is deployed.
    $deployed = 'C:\ProgramData\PcMaintenance'
    if (-not (Test-Path -LiteralPath $deployed)) { return $true }
    return (@(Test-PMPayloadSecure -Path $deployed).Count -eq 0)
}

Write-Host "`n== a module result that is not one object ==" -ForegroundColor Cyan
It 'the dispatcher refuses a null Test result instead of deleting' {
    # $null made `if ($t.Clean)` falsy, so control fell through to the DELETING phase. Absence of
    # an answer must be the strongest refusal available, not consent.
    $src = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Invoke-PcMaintenance.ps1') -Raw
    $iShape = $src.IndexOf('$null -eq $t -or $t -is [array]')
    $iFound = $src.IndexOf('$summary.found++')
    return ($iShape -gt 0 -and $iFound -gt 0 -and $iShape -lt $iFound)
}
It 'a module leaking extra output does not silently rewrite its Count' {
    # An Object[] result makes $t.Count resolve to the ARRAY length rather than the module's
    # field, so a module reporting 940 was recorded as 2.
    $fx = New-PMFixtureRoot -Prefix "pm-shape-"
    $md = Join-Path $fx 'modules\noisy'
    New-Item -ItemType Directory -Path $md -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'lib') -Destination (Join-Path $fx 'lib') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Invoke-PcMaintenance.ps1') -Destination $fx -Force
    @(
        '@{'
        "    Id = 'noisy'; Name = 'N'; Category = 'maintenance'; Version = '1.0.0'"
        '    RequiresUserSid = $false'
        '    AutoApply = $false'
        "    Roots = @('C:\nowhere')"
        "    Entry = 'module.ps1'; Description = 'fixture'"
        '}'
    ) | Set-Content -LiteralPath (Join-Path $md 'module.psd1') -Encoding UTF8
    @(
        'function Test-PMModule {'
        '    param($Context)'
        "    'stray output that should not be here'"
        "    [pscustomobject]@{ Clean = `$false; Count = 940; Detail = 'many'; Bytes = [int64]1; Items = @() }"
        '}'
        'function Repair-PMModule { param($Context) [pscustomobject]@{ Ok = $true; Bytes = [int64]0; Detail = "" } }'
    ) | Set-Content -LiteralPath (Join-Path $md 'module.ps1') -Encoding UTF8
    '{ "schemaVersion":1, "allowedCategories":["maintenance"], "modules":[{"id":"noisy","enabled":true,"order":10}] }' |
        Set-Content -LiteralPath (Join-Path $fx 'pcmaintenance.manifest.json') -Encoding UTF8
    try {
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fx 'Invoke-PcMaintenance.ps1') -NoReport 2>&1
        $j = Get-Content -LiteralPath (Join-Path $fx 'logs\latest.json') -Raw | ConvertFrom-Json
        # Either it refuses the shape outright, or it reports the module's real number. What it
        # must never do is quietly record the array length as the finding count.
        return ($j.modules[0].status -eq 'error' -or $j.modules[0].count -eq 940)
    } finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== size measures what deletion will actually free ==" -ForegroundColor Cyan
It 'Get-PMPathSize does not follow a junction' {
    # DirectoryInfo.EnumerateFiles(AllDirectories) DOES traverse reparse points while
    # Get-ChildItem -Recurse and Remove-Item -Recurse do not, so counting through one inflates
    # both the report headline and the "removed N GB" line by a tree nobody deletes.
    $base = Join-Path ([IO.Path]::GetTempPath()) ("pm-jz-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $real = Join-Path $base 'real'
    $host_ = Join-Path $base 'host'
    New-Item -ItemType Directory -Path $real -Force | Out-Null
    New-Item -ItemType Directory -Path $host_ -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $real 'big.bin') -Value ('z' * 20000) -Encoding Ascii -NoNewline
        $null = cmd /c mklink /J "$(Join-Path $host_ 'link')" "$real" 2>&1
        if (-not (Test-Path -LiteralPath (Join-Path $host_ 'link'))) {
            return 'SKIP'   # junctions unavailable here
        }
        return ((Get-PMPathSize -Path $host_) -eq 0)
    } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'Get-PMPathSize returns a real size for a single file' {
    # plex hands it individual .tmp files; DirectoryInfo on a file used to throw, report 0 bytes
    # AND log a bogus read error that would flip a -Critical module to unverified.
    $f = Join-Path ([IO.Path]::GetTempPath()) ("pm-f-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".txt")
    Set-Content -LiteralPath $f -Value ('q' * 5000) -Encoding Ascii -NoNewline
    try {
        Clear-PMReadErrors
        return ((Get-PMPathSize -Path $f) -eq 5000 -and (Get-PMReadErrorCount) -eq 0)
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
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

$tail = if ($script:Skip) { " ({0} SKIPPED - those verified nothing)" -f $script:Skip } else { '' }
Write-Host ("`n{0} passed, {1} failed{2}`n" -f $script:Pass, $script:Fail, $tail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
