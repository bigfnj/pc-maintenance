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
# When this run began. The teardown at the bottom only sweeps fixtures created after this
# instant, which keeps it off anything left by an earlier run or another tool.
#
# It does NOT make two suites running at the same time safe - the later one would sweep the
# earlier one's live fixtures mid-test. Running two copies concurrently is not a thing anyone
# does, and the alternative (registering every fixture at ~20 creation sites) costs more than
# it buys. Noted so the next person hitting a bizarre concurrent failure knows where to look.
$script:SuiteStartUtc = (Get-Date).ToUniversalTime()
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
# The gate used to fail OPEN on a type mistake. Import-PowerShellDataFile preserves the string
# type and [bool]'false' is $true under 5.1, so a psd1 written with JSON habits promoted a module
# to deleting while its author had written the opposite. Every one of these must read as NO.
foreach ($bad in @('false', 'False', '0', 'no', '$false', 0, 1, 'true')) {
    $b = $bad
    It "a non-boolean AutoApply [$($b.GetType().Name) '$b'] does not grant apply" {
        -not (Test-PMApplyAllowed -Apply $true -ModuleInfo @{ AutoApply = $b })
    }
}

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
It 'exactly the three proven-mechanical modules declare AutoApply' {
    $auto = @($modDirs | Where-Object { [bool](Import-PMModuleInfo -ModuleDir $_.FullName)['AutoApply'] } | ForEach-Object { $_.Name } | Sort-Object)
    return (($auto -join ',') -eq 'agent-scratchpads,plex-bif-orphans,vs-installer-scratch')
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
# Each case carries its OWN roots. The table used to share a fixed pair that contained neither a
# UNC path nor a \\?\ path, so those rows would have passed with no pattern added at all - the
# root check would have rejected them and the test would have proved nothing.
foreach ($case in @(
    @{ P = 'C:\Users\Someone\AppData\Local\Temp\wsl\ext4';          N = 'a local wsl mount point';        R = @('C:\Users\Someone') }
    # The directory ITSELF, not just its contents. '\\wsl\\' needed a trailing backslash, so the
    # single target whose deletion destroys the whole mount was the one thing it did not refuse.
    @{ P = 'C:\Users\Someone\AppData\Local\Temp\wsl';               N = 'the wsl mount directory itself'; R = @('C:\Users\Someone') }
    @{ P = 'C:\Users\Someone\AppData\Local\Temp\x\site-packages\y'; N = 'site-packages';                  R = @('C:\Users\Someone') }
    @{ P = 'C:\Users\Someone\Desktop\thing';                        N = 'Desktop';                       R = @('C:\Users\Someone') }
    @{ P = 'C:\Users\Someone\Pictures\thing';                       N = 'Pictures';                      R = @('C:\Users\Someone') }
    @{ P = 'C:\Users\Someone\Videos\thing';                         N = 'Videos';                        R = @('C:\Users\Someone') }
    @{ P = 'C:\Users\Someone\Music\thing';                          N = 'Music';                         R = @('C:\Users\Someone') }
    @{ P = 'C:\Users\Someone\Downloads\thing';                      N = 'Downloads (where reports land)'; R = @('C:\Users\Someone') }
    @{ P = 'C:\Program Files (x86)\App\sub';                        N = 'Program Files (x86)';           R = @('C:\Program Files (x86)') }
    # OneDrive Known Folder Move: the Windows 11 default, so for most people these ARE the real
    # Documents and Desktop. Measured safe before the pattern existed.
    @{ P = 'C:\Users\Someone\OneDrive\Documents\tax';               N = 'OneDrive Documents (KFM)';      R = @('C:\Users\Someone') }
    @{ P = 'C:\Users\Someone\OneDrive - Contoso\Desktop\thing';     N = 'OneDrive for Business Desktop'; R = @('C:\Users\Someone') }
    # Credentials and keys. AppData\Roaming was uncovered entirely.
    @{ P = 'C:\Users\Someone\AppData\Roaming\.ssh\id_ed25519';      N = 'Roaming .ssh';                  R = @('C:\Users\Someone\AppData\Roaming') }
    @{ P = 'C:\Users\Someone\AppData\Roaming\.aws\credentials';     N = 'Roaming .aws';                  R = @('C:\Users\Someone\AppData\Roaming') }
    @{ P = 'C:\Users\Someone\AppData\Roaming\Microsoft\Crypto\RSA'; N = 'Roaming Microsoft\Crypto';      R = @('C:\Users\Someone\AppData\Roaming') }
    @{ P = 'C:\Users\Someone\.ssh\config';                          N = 'a profile-level .ssh';          R = @('C:\Users\Someone') }
    @{ P = 'C:\Users\Someone\.aws\credentials';                     N = 'a profile-level .aws';          R = @('C:\Users\Someone') }
    # UNC in every spelling. These need roots that CONTAIN them or the test is vacuous.
    @{ P = '\\wsl$\Ubuntu\home\me\stuff';                           N = 'the wsl$ UNC share';            R = @('\\wsl$\Ubuntu') }
    @{ P = '\\wsl.localhost\Ubuntu\home\me\s';                      N = 'the wsl.localhost UNC share';   R = @('\\wsl.localhost\Ubuntu') }
    @{ P = '\\fileserver\share\folder\thing';                       N = 'an ordinary UNC share';         R = @('\\fileserver\share') }
    # The long-path prefixes, which defeat every drive-anchored pattern at once.
    @{ P = '\\?\C:\Windows\System32\config';                        N = 'the long-path prefix (caught by the UNC rule)';     R = @('\\?\C:\Windows') }
    @{ P = '\\.\C:\Windows\System32';                               N = 'the device prefix (caught by the UNC rule)';        R = @('\\.\C:\Windows') })) {
    $k = $case
    It "refuses $($k.N)" { -not (Test-PMPathSafe -Path $k.P -Roots $k.R) }
}
It 'refuses a sibling whose name merely starts with the root name' {
    # The prefix check and the root-itself check used to cover for each other, so breaking either
    # one alone left the suite green while C:\...\TempEvil became deletable.
    -not (Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\TempEvil\x' -Roots @('C:\Users\Someone\AppData\Local\Temp'))
}

Write-Host "`n== and the paths the modules actually sweep are still SAFE ==" -ForegroundColor Cyan
# Positive controls. Without these, an over-broad new pattern would forbid everything and the
# whole suite above would still be green while the tool silently stopped deleting anything.
foreach ($ok in @(
    @{ P = 'C:\Users\Someone\AppData\Local\Temp\abcd1234.xyz';                  N = 'a VS installer extraction';    R = @('C:\Users\Someone\AppData\Local\Temp') }
    @{ P = 'C:\Users\Someone\AppData\Local\Temp\Adobe';                         N = 'stale app scratch';            R = @('C:\Users\Someone\AppData\Local\Temp') }
    @{ P = 'C:\Users\Someone\AppData\Local\Temp\claude\d---x\1111-2222';        N = 'an agent session directory';   R = @('C:\Users\Someone\AppData\Local\Temp\claude') }
    @{ P = 'E:\PlexMedia\Localhost\0\abc.bundle\Contents\Indexes\index-sd.bif.tmp'; N = 'a Plex preview temp';      R = @('E:\PlexMedia') })) {
    $g = $ok
    It "still allows $($g.N)" { Test-PMPathSafe -Path $g.P -Roots $g.R }
}
It 'still allows the uninstaller to delete its own payload root' {
    # Uninstall-PcMaintenance.ps1 is the ONLY caller passing operator input and the only one using
    # MinDepth 2. A new pattern that caught C:\ProgramData\... would not break a module, it would
    # make uninstall refuse to run - a far less obvious failure.
    Test-PMPathSafe -Path 'C:\ProgramData\PcMaintenance' -Roots @('C:\ProgramData') -MinDepth 2
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
It 'a module NOT needing a user is refused too, when the user was inferred' {
    # Inverted deliberately (BACKLOG 6i). This asserted the opposite: that omitting
    # RequiresUserSid made the gate return $true regardless. That made the README's fourth
    # condition opt-in, and worse, the dispatcher went on expanding that same module's declared
    # roots against the GUESSED profile - so forgetting the flag bought a stranger's profile
    # substituted into the roots, which then makes the path guard agree.
    #
    # Nobody deletes for a user who was guessed. The flag is still taken so the reason can be
    # reported accurately; it no longer decides the answer.
    -not (Test-PMActingUserConfirmed -RequiresUserSid $false -LoggedIn $false)
}
It 'and acts normally once that user is confirmed' {
    # The positive control. Without it, a gate that refused everything would pass the test above
    # while stopping the tool deleting anything at all.
    Test-PMActingUserConfirmed -RequiresUserSid $false -LoggedIn $true
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

Write-Host "`n== report retention (this deletes inside Downloads, so it is fenced hard) ==" -ForegroundColor Cyan
function New-PMReportDir {
    param([string[]]$Names)
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-rep-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    foreach ($n in $Names) { Set-Content -LiteralPath (Join-Path $d $n) -Value 'x' -Encoding UTF8 }
    return $d
}
It 'keeps the newest two and removes the rest' {
    $d = New-PMReportDir @(
        'PC-Maintenance Report - 2026-09-01 010101.html'
        'PC-Maintenance Report - 2026-09-08 020202.html'
        'PC-Maintenance Report - 2026-09-15 030303.html'
        'PC-Maintenance Report - 2026-09-22 040404.html')
    try {
        $removed = @(Remove-PMOldReports -Directory $d -Keep 2)
        $left = @(Get-ChildItem -LiteralPath $d -File | ForEach-Object { $_.Name } | Sort-Object)
        return ($removed.Count -eq 2 -and $left.Count -eq 2 -and
                $left[0] -eq 'PC-Maintenance Report - 2026-09-15 030303.html' -and
                $left[1] -eq 'PC-Maintenance Report - 2026-09-22 040404.html')
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'orders by the timestamp IN THE NAME, not by mtime' {
    # A report that gets touched, copied or restored must not be able to promote itself past a
    # genuinely newer one and get the newer one deleted instead.
    $d = New-PMReportDir @(
        'PC-Maintenance Report - 2026-01-01 010101.html'
        'PC-Maintenance Report - 2026-09-15 030303.html'
        'PC-Maintenance Report - 2026-09-22 040404.html')
    try {
        # make the OLDEST file the most recently written
        (Get-Item -LiteralPath (Join-Path $d 'PC-Maintenance Report - 2026-01-01 010101.html')).LastWriteTime = (Get-Date)
        $null = Remove-PMOldReports -Directory $d -Keep 2
        return (-not (Test-Path -LiteralPath (Join-Path $d 'PC-Maintenance Report - 2026-01-01 010101.html')) -and
                (Test-Path -LiteralPath (Join-Path $d 'PC-Maintenance Report - 2026-09-22 040404.html')))
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'touches nothing that is not one of our reports' {
    # This runs inside the user's Downloads, which is on the FORBIDDEN path list for every module.
    # The only thing standing between it and someone's files is the name pattern, so the pattern
    # is what gets tested hardest.
    $bystanders = @(
        'tax return 2026.pdf'
        'PC-Maintenance Report.html'                          # no timestamp
        'PC-Maintenance Report - 2026-09-01.html'             # date only
        'PC-Maintenance Report - 2026-09-01 010101.html.bak'  # wrong extension
        'my PC-Maintenance Report - 2026-09-01 010101.html'   # prefixed
        'PC-Maintenance Report - not-a-date 010101.html'
    )
    $d = New-PMReportDir ($bystanders + @(
        'PC-Maintenance Report - 2026-09-01 010101.html'
        'PC-Maintenance Report - 2026-09-08 020202.html'
        'PC-Maintenance Report - 2026-09-15 030303.html'))
    try {
        $null = Remove-PMOldReports -Directory $d -Keep 2
        foreach ($b in $bystanders) { if (-not (Test-Path -LiteralPath (Join-Path $d $b))) { return $false } }
        return $true
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'does nothing when there are not more than Keep' {
    $d = New-PMReportDir @('PC-Maintenance Report - 2026-09-15 030303.html')
    try { return ((@(Remove-PMOldReports -Directory $d -Keep 2)).Count -eq 0) }
    finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'never recurses into a subdirectory' {
    $d = New-PMReportDir @()
    $sub = Join-Path $d 'nested'
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    foreach ($n in @('PC-Maintenance Report - 2026-09-01 010101.html',
                     'PC-Maintenance Report - 2026-09-08 020202.html',
                     'PC-Maintenance Report - 2026-09-15 030303.html')) {
        Set-Content -LiteralPath (Join-Path $sub $n) -Value 'x' -Encoding UTF8
    }
    try {
        $null = Remove-PMOldReports -Directory $d -Keep 1
        return ((@(Get-ChildItem -LiteralPath $sub -File)).Count -eq 3)
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a directory named like a report is not deleted' {
    $d = New-PMReportDir @('PC-Maintenance Report - 2026-09-15 030303.html'
                           'PC-Maintenance Report - 2026-09-22 040404.html')
    $trap = Join-Path $d 'PC-Maintenance Report - 2026-09-01 010101.html'
    New-Item -ItemType Directory -Path $trap -Force | Out-Null
    try {
        $null = Remove-PMOldReports -Directory $d -Keep 1
        return (Test-Path -LiteralPath $trap)
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'Keep is floored at 1, so a bad value cannot wipe every report' {
    $d = New-PMReportDir @('PC-Maintenance Report - 2026-09-15 030303.html'
                           'PC-Maintenance Report - 2026-09-22 040404.html')
    try {
        $null = Remove-PMOldReports -Directory $d -Keep 0
        return ((@(Get-ChildItem -LiteralPath $d -File)).Count -eq 1)
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'the generated name matches the pattern the pruner looks for' {
    # If these two ever drift, the tool writes reports it can never clean up.
    $n = Get-PMReportFileName -When ([datetime]'2026-09-09T13:57:13')
    return ($n -eq 'PC-Maintenance Report - 2026-09-09 135713.html' -and
            $n -match $script:PMReportNamePattern)
}

Write-Host "`n== agent-scratchpads now deletes, so its two rules get tested hardest ==" -ForegroundColor Cyan
function New-PMAgentTree {
    <#
        A miniature Temp\claude: two session shapes, the shared infrastructure that must survive,
        and a session whose DIRECTORY looks ancient while a file inside is fresh.
    #>
    $root = Join-Path ([IO.Path]::GetTempPath()) ("pm-ag-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $old = (Get-Date).AddDays(-60)
    function Touch($p, $when) {
        New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
        Set-Content -LiteralPath $p -Value 'x' -Encoding UTF8
        (Get-Item -LiteralPath $p).LastWriteTime = $when
    }
    # 1. bare GUID at the top level, genuinely idle
    Touch (Join-Path $root '11111111-1111-1111-1111-111111111111\scratchpad\a.txt') $old
    # 2. GUID under a project slug, genuinely idle
    Touch (Join-Path $root 'proj-slug\22222222-2222-2222-2222-222222222222\scratchpad\b.txt') $old
    # 3. LIVE session: ancient directory timestamp, fresh file inside. The trap.
    Touch (Join-Path $root '33333333-3333-3333-3333-333333333333\scratchpad\c.txt') (Get-Date)
    # 4. shared infrastructure, old, must never be considered. bundled-skills really does nest
    #    hash-named directories on this box, so a GUID-shaped child is a realistic shape - and
    #    it is what makes the never-touch list reachable rather than a belt the GUID rule
    #    already covers on its own.
    Touch (Join-Path $root 'bundled-skills\dataviz\SKILL.md') $old
    Touch (Join-Path $root 'bundled-skills\44444444-4444-4444-4444-444444444444\dataviz\SKILL.md') $old
    Touch (Join-Path $root 'auto-mode-classifier-errors\err.log') $old
    # 5. a non-GUID project dir with a non-GUID child, old
    Touch (Join-Path $root 'proj-slug\not-a-session\x.txt') $old
    foreach ($d in @('11111111-1111-1111-1111-111111111111',
                     'proj-slug\22222222-2222-2222-2222-222222222222',
                     '33333333-3333-3333-3333-333333333333')) {
        (Get-Item -LiteralPath (Join-Path $root $d)).LastWriteTime = $old   # every root looks ancient
    }
    return $root
}
function Get-PMAgentPicks {
    param([string]$Root)
    $ctx = @{ UserProfile = $null }
    # point the module at the fixture by overriding its root resolver in this scope
    function Get-AgentScratchRoot { param($Context) $script:FixtureRoot }
    $script:FixtureRoot = $Root
    return @(Get-AgentScratchCandidates -Context $ctx | ForEach-Object { Split-Path $_.Path -Leaf })
}
. (Join-Path $script:RepoRoot 'modules\agent-scratchpads\module.ps1')

It 'picks up both session shapes' {
    $r = New-PMAgentTree
    try {
        $picks = Get-PMAgentPicks -Root $r
        return (($picks -contains '11111111-1111-1111-1111-111111111111') -and
                ($picks -contains '22222222-2222-2222-2222-222222222222'))
    } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'spares a live session whose DIRECTORY looks ancient' {
    # The whole reason age comes from the newest file inside. With directory mtime this session
    # is 60 days old and gets deleted while it is running.
    $r = New-PMAgentTree
    try { return ((Get-PMAgentPicks -Root $r) -notcontains '33333333-3333-3333-3333-333333333333') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'never considers bundled-skills or the classifier errors' {
    # bundled-skills is where a RUNNING session loads skill payloads from. Deleting it because it
    # is old would break skills for every session on the box.
    $r = New-PMAgentTree
    try {
        $picks = Get-PMAgentPicks -Root $r
        return (($picks -notcontains 'bundled-skills') -and ($picks -notcontains 'auto-mode-classifier-errors'))
    } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a GUID-shaped directory INSIDE bundled-skills is still protected' {
    # This is what the never-touch list is actually for. The GUID rule alone would happily match
    # bundled-skills\<guid>\ and delete a skill payload a running session loads from.
    $r = New-PMAgentTree
    try { return ((Get-PMAgentPicks -Root $r) -notcontains '44444444-4444-4444-4444-444444444444') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'ignores a directory whose name is not a session GUID' {
    $r = New-PMAgentTree
    try { return ((Get-PMAgentPicks -Root $r) -notcontains 'not-a-session') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'Get-PMNewestWriteUtc reports the newest file, not the directory stamp' {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-nw-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path (Join-Path $d 'deep') -Force | Out-Null
    try {
        $f = Join-Path $d 'deep\fresh.txt'
        Set-Content -LiteralPath $f -Value 'x' -Encoding UTF8
        (Get-Item -LiteralPath $d).LastWriteTime = (Get-Date).AddDays(-60)
        $newest = Get-PMNewestWriteUtc -Path $d
        return ($newest -gt (Get-Date).ToUniversalTime().AddDays(-1))
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'reports the NEWEST file even when an older one is enumerated first' {
    # Without a cutoff the early exit used to fire on the first file seen, so this returned
    # whichever file the filesystem handed over first. Production always passes -NewerThanUtc and
    # was unaffected; every caller that omitted it was quietly getting the wrong answer.
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-nw3-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    try {
        foreach ($n in @('a-old.txt', 'b-new.txt')) { Set-Content -LiteralPath (Join-Path $d $n) -Value 'x' -Encoding UTF8 }
        (Get-Item -LiteralPath (Join-Path $d 'a-old.txt')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-100)
        $want = (Get-Date).ToUniversalTime().AddDays(-2)
        (Get-Item -LiteralPath (Join-Path $d 'b-new.txt')).LastWriteTimeUtc = $want
        $got = Get-PMNewestWriteUtc -Path $d
        return ([math]::Abs(($got - $want).TotalSeconds) -lt 2)
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'and still stops early when the caller supplies a cutoff it has already beaten' {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-nw4-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $d 'fresh.txt') -Value 'x' -Encoding UTF8
        $cut = (Get-Date).ToUniversalTime().AddDays(-14)
        return ((Get-PMNewestWriteUtc -Path $d -NewerThanUtc $cut) -gt $cut)
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'an empty directory dates from itself rather than reading as ancient' {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-nw2-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    try { return ((Get-PMNewestWriteUtc -Path $d) -gt (Get-Date).ToUniversalTime().AddDays(-1)) }
    finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'agent-scratchpads is now one of three modules allowed to act' {
    $auto = @(Get-ChildItem (Join-Path $script:RepoRoot 'modules') -Directory |
        Where-Object { [bool](Import-PMModuleInfo -ModuleDir $_.FullName)['AutoApply'] } |
        ForEach-Object { $_.Name } | Sort-Object)
    return (($auto -join ',') -eq 'agent-scratchpads,plex-bif-orphans,vs-installer-scratch')
}

Write-Host "`n== module selection rules, against real fixture trees ==" -ForegroundColor Cyan

function Invoke-PMModuleTest {
    <#
        Run ONE module's Test-PMModule against a fixture root, isolated.

        All four modules define Test-PMModule and Repair-PMModule, and agent-scratchpads is already
        dot-sourced at script scope. Dot-sourcing a second at script scope would silently overwrite
        it, so each call gets its own & {} scope - the same isolation lib\PMModule.ps1 uses in
        production for the same reason.

        The root-resolver override is installed by NAME after the module is dot-sourced, so it wins
        the lookup. Returns the module's result plus the critical-read count, which is how the
        "blind is not clean" contract gets asserted behaviourally instead of by grepping for a flag.
    #>
    param([string]$ModuleId, [string]$RootResolver, [string]$FixtureRoot)
    & {
        param($libDir, $entry, $resolver, $fixture)
        Get-ChildItem $libDir -Filter *.ps1 | ForEach-Object { . $_.FullName }
        . $entry
        Set-Item -Path "function:$resolver" -Value ([scriptblock]::Create("param(`$Context) '$fixture'"))
        Clear-PMReadErrors
        $r = Test-PMModule -Context @{ UserProfile = $null }
        [pscustomobject]@{ Result = $r; CriticalReads = (Get-PMCriticalReadErrorCount) }
    } (Join-Path $script:RepoRoot 'lib') (Join-Path $script:RepoRoot "modules\$ModuleId\module.ps1") $RootResolver $FixtureRoot
}

function Get-PMPicks {
    # Leaf names of what a module selected, which is what makes -contains assertions readable.
    param([string]$ModuleId, [string]$RootResolver, [string]$FixtureRoot)
    $o = Invoke-PMModuleTest -ModuleId $ModuleId -RootResolver $RootResolver -FixtureRoot $FixtureRoot
    return @(@($o.Result.Items) | ForEach-Object { Split-Path $_.path -Leaf })
}

function New-PMUnreadableDir {
    <#
        A directory that EXISTS but cannot be LISTED. Needed because a module takes an early
        "no root" return on a missing path, so a missing directory proves nothing about the
        critical-read contract.

        Returns $null if the condition could not be produced, so the caller SKIPs loudly rather
        than passing vacuously. Cleanup goes through icacls /reset, NOT Set-Acl: removing a deny
        ACE via Set-Acl wants SeSecurityPrivilege and leaves an undeletable directory behind.
    #>
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-deny-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'inside.txt') -Value 'x' -Encoding UTF8
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = Get-Acl -LiteralPath $d
        $acl.SetAccessRuleProtection($true, $true)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $me, [Security.AccessControl.FileSystemRights]::ListDirectory,
            'ContainerInherit,ObjectInherit', 'None', 'Deny')))
        Set-Acl -LiteralPath $d -AclObject $acl -ErrorAction Stop
    } catch { Remove-PMUnreadableDir $d; return $null }
    # Verify the condition actually holds rather than assuming the ACL took.
    $ev = $null
    $null = @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue -ErrorVariable ev)
    if (-not $ev -or -not (Test-Path -LiteralPath $d)) { Remove-PMUnreadableDir $d; return $null }
    return $d
}
function Remove-PMUnreadableDir {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $null = icacls $Path /reset /T /C 2>&1
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

# --- vs-installer-scratch -------------------------------------------------------------
function New-PMVsTree {
    <#
        Directory timestamps are stamped LAST, after every file is written. Creating a file bumps
        its parent's LastWriteTime, and this module branches on the candidate directory's own
        mtime - so stamping first would silently make every candidate look brand new.
    #>
    $root = Join-Path ([IO.Path]::GetTempPath()) ("pm-vs-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $old = (Get-Date).AddDays(-3)
    # NOT named Mk/Fl: `fl` is the built-in alias for Format-List, and PowerShell resolves
    # aliases BEFORE functions, so `Fl $path` silently formatted a string instead of creating a
    # file - no error, no file, and the formatter's output leaked into the fixture's return value.
    function Add-FixtureDir($p) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    function Add-FixtureFile($p) { Add-FixtureDir (Split-Path $p -Parent); Set-Content -LiteralPath $p -Value 'x' -Encoding UTF8 }

    # the real thing: name shape + setup.exe + resources\app\ServiceHub + older than 24h
    Add-FixtureDir (Join-Path $root 'abcd1234.xyz\resources\app\ServiceHub'); Add-FixtureFile (Join-Path $root 'abcd1234.xyz\setup.exe')
    # near-miss: right name, setup.exe, NO ServiceHub
    Add-FixtureFile (Join-Path $root 'bbbb2222.yyy\setup.exe')
    # near-miss: right name, ServiceHub, NO setup.exe
    Add-FixtureDir (Join-Path $root 'cccc3333.zzz\resources\app\ServiceHub')
    # near-miss: full fingerprint but the name is not the installer's shape
    Add-FixtureDir (Join-Path $root 'notavsname\resources\app\ServiceHub'); Add-FixtureFile (Join-Path $root 'notavsname\setup.exe')
    # near-miss: correct in every way but too recent
    Add-FixtureDir (Join-Path $root 'dddd4444.www\resources\app\ServiceHub'); Add-FixtureFile (Join-Path $root 'dddd4444.www\setup.exe')
    # payload cache: a manifest SUBDIRECTORY (not a file) plus a real .vsix somewhere below
    Add-FixtureDir (Join-Path $root 'PayloadCache\Microsoft.VisualStudio.Thing')
    Add-FixtureFile (Join-Path $root 'PayloadCache\deep\pkg.vsix')
    # payload-cache near-miss: manifest subdirectory but no .vsix anywhere
    Add-FixtureDir (Join-Path $root 'NoVsixCache\Microsoft.VisualStudio.Thing')

    foreach ($d in @('abcd1234.xyz','bbbb2222.yyy','cccc3333.zzz','notavsname','PayloadCache','NoVsixCache')) {
        (Get-Item -LiteralPath (Join-Path $root $d)).LastWriteTime = $old
    }
    (Get-Item -LiteralPath (Join-Path $root 'dddd4444.www')).LastWriteTime = (Get-Date)
    return $root
}
$vsPick = { param($r) Get-PMPicks -ModuleId 'vs-installer-scratch' -RootResolver 'Get-VsScratchRoot' -FixtureRoot $r }

It 'vs: selects an extraction with the name shape, both fingerprint files, and age' {
    $r = New-PMVsTree
    try { return ((& $vsPick $r) -contains 'abcd1234.xyz') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'vs: rejects a right-named directory missing resources\app\ServiceHub' {
    $r = New-PMVsTree
    try { return ((& $vsPick $r) -notcontains 'bbbb2222.yyy') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'vs: rejects a right-named directory missing setup.exe' {
    $r = New-PMVsTree
    try { return ((& $vsPick $r) -notcontains 'cccc3333.zzz') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'vs: rejects the full fingerprint under a name that is not the installer shape' {
    $r = New-PMVsTree
    try { return ((& $vsPick $r) -notcontains 'notavsname') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'vs: rejects a correct extraction younger than the 24h floor' {
    # The floor is what keeps it clear of an extraction still in flight.
    $r = New-PMVsTree
    try { return ((& $vsPick $r) -notcontains 'dddd4444.www') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'vs: selects a payload cache with a manifest subdirectory and a real .vsix' {
    $r = New-PMVsTree
    try { return ((& $vsPick $r) -contains 'PayloadCache') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'vs: rejects a manifest subdirectory with no .vsix below it' {
    $r = New-PMVsTree
    try { return ((& $vsPick $r) -notcontains 'NoVsixCache') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'vs: selects exactly two things and nothing else' {
    # "assert exactly which paths come back" - a test that only checks the wanted ones would
    # still pass if the module also swept half of TEMP.
    $r = New-PMVsTree
    try {
        $p = @(& $vsPick $r) | Sort-Object
        return (($p -join ',') -eq 'abcd1234.xyz,PayloadCache')
    } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- plex-bif-orphans -----------------------------------------------------------------
function New-PMPlexTree {
    param([int]$Pairs = 1)
    $root = Join-Path ([IO.Path]::GetTempPath()) ("pm-plex-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path (Join-Path $root 'Localhost\0') -Force | Out-Null
    function Add-FixtureFile($p) { Set-Content -LiteralPath $p -Value 'x' -Encoding UTF8 }
    $d = Join-Path $root 'Localhost\0'
    for ($i = 1; $i -le $Pairs; $i++) {
        Add-FixtureFile (Join-Path $d "index$i.bif"); Add-FixtureFile (Join-Path $d "index$i.bif.tmp")   # superseded: a candidate
    }
    Add-FixtureFile (Join-Path $d 'orphan.bif.tmp')          # no finished partner: may be a generation in flight
    Add-FixtureFile (Join-Path $d 'weird.bif')
    Add-FixtureFile (Join-Path $d 'weird.bif.tmpx')          # -Filter '*.tmp' would match this; EndsWith must not
    # The discriminating trap. Under the correct EndsWith('.tmp') rule 'chunk.tmp.bif' is not a
    # temp file at all. Under a loose match it IS one, and Substring(len - 4) then strips '.bif'
    # to give 'chunk.tmp', which EXISTS - so a loose rule would pair them up and delete a
    # finished .bif. The .tmpx case above cannot show this, because its stripped base has a
    # trailing dot and never matches anything, so the pairing rule covers for the loose match.
    Add-FixtureFile (Join-Path $d 'chunk.tmp')
    Add-FixtureFile (Join-Path $d 'chunk.tmp.bif')
    Add-FixtureFile (Join-Path $d 'plain.bif')               # not a temp at all
    return $root
}
$plexPick = { param($r) Get-PMPicks -ModuleId 'plex-bif-orphans' -RootResolver 'Get-PlexMediaRoot' -FixtureRoot $r }

It 'plex: selects a .tmp whose finished preview already exists' {
    $r = New-PMPlexTree
    try { return ((& $plexPick $r) -contains 'index1.bif.tmp') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'plex: spares a .tmp with no finished partner' {
    # It may be a preview still being generated. The pairing IS the rule.
    $r = New-PMPlexTree
    try { return ((& $plexPick $r) -notcontains 'orphan.bif.tmp') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'plex: spares .tmpx, which the Win32 filter would have matched' {
    # -Filter '*.tmp' also matches longer extensions, and the blind Substring(len-4) would then
    # have tested the wrong base path. EndsWith is the rule that was meant.
    $r = New-PMPlexTree
    try { return ((& $plexPick $r) -notcontains 'weird.bif.tmpx') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'plex: a loose .tmp match would delete a finished .bif, and does not' {
    # This is the case that actually discriminates EndsWith from a contains-style match:
    # 'chunk.tmp.bif' is not a temp file, but a loose rule would treat it as one, strip four
    # characters to 'chunk.tmp', find that file present, and delete the .bif as an orphan.
    $r = New-PMPlexTree
    try { return ((& $plexPick $r) -notcontains 'chunk.tmp.bif') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'plex: selects exactly the superseded temps and nothing else' {
    $r = New-PMPlexTree -Pairs 2
    try {
        $p = @(& $plexPick $r) | Sort-Object
        return (($p -join ',') -eq 'index1.bif.tmp,index2.bif.tmp')
    } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- stale-app-temp -------------------------------------------------------------------
function New-PMStaleTree {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("pm-stale-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $old = (Get-Date).AddDays(-60)
    function Add-FixtureDir($p) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    function Add-FixtureFile($p) { Add-FixtureDir (Split-Path $p -Parent); Set-Content -LiteralPath $p -Value 'x' -Encoding UTF8 }
    Add-FixtureFile (Join-Path $root 'Adobe\a.txt')             # exact name, stale
    Add-FixtureFile (Join-Path $root 'occt\b.txt')              # exact name in the wrong case: -contains is case-insensitive
    Add-FixtureFile (Join-Path $root '7zO1234\c.txt')           # prefix match
    Add-FixtureFile (Join-Path $root 'WinGetSomething\d.txt')   # StartsWith a listed NAME but is not one: must be spared
    Add-FixtureFile (Join-Path $root 'RandomApp\e.txt')         # not listed at all
    Add-FixtureFile (Join-Path $root 'CreativeCloud\f.txt')     # exact name, but will be stamped recent
    foreach ($d in @('Adobe','occt','7zO1234','WinGetSomething','RandomApp')) {
        (Get-Item -LiteralPath (Join-Path $root $d)).LastWriteTime = $old
    }
    (Get-Item -LiteralPath (Join-Path $root 'CreativeCloud')).LastWriteTime = (Get-Date)
    return $root
}
$stalePick = { param($r) Get-PMPicks -ModuleId 'stale-app-temp' -RootResolver 'Get-StaleTempRoot' -FixtureRoot $r }

It 'stale: selects a listed application directory past the floor' {
    $r = New-PMStaleTree
    try { return ((& $stalePick $r) -contains 'Adobe') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'stale: the exact-name list is case-insensitive' {
    $r = New-PMStaleTree
    try { return ((& $stalePick $r) -contains 'occt') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'stale: selects a prefix match' {
    $r = New-PMStaleTree
    try { return ((& $stalePick $r) -contains '7zO1234') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'stale: spares a name that merely STARTS WITH a listed name' {
    # The discriminating pair: the names list is exact-match, only the prefixes list is StartsWith.
    # WinGetSomething must survive while 7zO1234 does not.
    $r = New-PMStaleTree
    try { return ((& $stalePick $r) -notcontains 'WinGetSomething') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'stale: spares an unlisted directory of the same age' {
    $r = New-PMStaleTree
    try { return ((& $stalePick $r) -notcontains 'RandomApp') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'stale: spares a listed directory that is younger than the floor' {
    $r = New-PMStaleTree
    try { return ((& $stalePick $r) -notcontains 'CreativeCloud') }
    finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'stale: selects exactly three things and nothing else' {
    $r = New-PMStaleTree
    try {
        $p = @(& $stalePick $r) | Sort-Object
        return (($p -join ',') -eq '7zO1234,Adobe,occt')
    } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== Count is the truth; Items may be capped ==" -ForegroundColor Cyan
It 'a module reporting more than the cap returns the TRUE Count with capped Items' {
    # Replaces a grep for the literal string "Count = @($items).Count", which passed whether or
    # not the field meant anything. 30 real orphans, Items capped at 25, Count must say 30.
    $r = New-PMPlexTree -Pairs 30
    try {
        $o = Invoke-PMModuleTest -ModuleId 'plex-bif-orphans' -RootResolver 'Get-PlexMediaRoot' -FixtureRoot $r
        return ($o.Result.Count -eq 30 -and @($o.Result.Items).Count -eq 25)
    } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a clean module reports Clean with no findings' {
    $r = New-PMPlexTree -Pairs 0
    try {
        # Pairs 0 leaves only the unpaired orphan, the .tmpx and two plain files: nothing to do.
        $o = Invoke-PMModuleTest -ModuleId 'plex-bif-orphans' -RootResolver 'Get-PlexMediaRoot' -FixtureRoot $r
        return ($o.Result.Clean -eq $true -and @($o.Result.Items).Count -eq 0)
    } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'stale-app-temp reports Count equal to its Items when under the cap' {
    $r = New-PMStaleTree
    try {
        $o = Invoke-PMModuleTest -ModuleId 'stale-app-temp' -RootResolver 'Get-StaleTempRoot' -FixtureRoot $r
        return ($o.Result.Count -eq 3 -and @($o.Result.Items).Count -eq 3)
    } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'and caps Items at 25 past it, while Count still carries the truth' {
    # This module was the ONE uncapped Items in the run JSON, and the old test - titled "the
    # uncapped module" - pinned that as intended using a 3-item fixture, so it could never have
    # noticed. Its 7zO* / pip-unpack-* prefixes recur without limit and AutoApply = $false means
    # it never deletes them, so its match set only ever grows.
    $r = Join-Path ([IO.Path]::GetTempPath()) ("pm-stalecap-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $old = (Get-Date).AddDays(-60)
    try {
        foreach ($n in 1..30) {
            $d = Join-Path $r ("7zO{0:D4}" -f $n)
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'f.txt') -Value ('x' * $n) -Encoding UTF8
            (Get-Item -LiteralPath $d).LastWriteTime = $old
        }
        $o = Invoke-PMModuleTest -ModuleId 'stale-app-temp' -RootResolver 'Get-StaleTempRoot' -FixtureRoot $r
        return ($o.Result.Count -eq 30 -and @($o.Result.Items).Count -eq 25)
    } finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== every module's load-bearing read is Critical ==" -ForegroundColor Cyan
foreach ($case in @(
    @{ Id = 'vs-installer-scratch'; R = 'Get-VsScratchRoot' }
    @{ Id = 'plex-bif-orphans';     R = 'Get-PlexMediaRoot' }
    @{ Id = 'stale-app-temp';       R = 'Get-StaleTempRoot' }
    @{ Id = 'agent-scratchpads';    R = 'Get-AgentScratchRoot' })) {
    $c = $case
    It "$($c.Id): an unreadable root is a CRITICAL read failure, not an empty result" {
        # Replaces a grep for the literal string "-Critical", which was satisfied by the flag
        # appearing anywhere in the file, including inside a comment. A module whose root read is
        # not Critical reports a clean machine while blind, which is the whole bug.
        $d = New-PMUnreadableDir
        if (-not $d) { return 'SKIP' }
        try {
            $o = Invoke-PMModuleTest -ModuleId $c.Id -RootResolver $c.R -FixtureRoot $d
            return ($o.CriticalReads -gt 0)
        } finally { Remove-PMUnreadableDir $d }
    }
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

Write-Host "`n== Format-PMBytes, which had no tests at all and two missing tiers ==" -ForegroundColor Cyan
foreach ($c in @(
    @{ B = [int64]0;        N = '0 B' }
    @{ B = [int64]1;        N = '1 B' }
    @{ B = [int64]512;      N = '512 B' }
    @{ B = [int64]1KB;      N = '1 KB' }
    @{ B = [int64]900KB;    N = '900 KB' }
    @{ B = [int64]1.5MB;    N = '1.5 MB' }
    @{ B = [int64]2.25GB;   N = '2.25 GB' }
    @{ B = [int64]2TB;      N = '2.00 TB' })) {
    $k = $c
    It "renders $($k.B) bytes as '$($k.N)'" { (Format-PMBytes $k.B) -eq $k.N }
}
It 'a real finding under 1 KB no longer reads as nothing found' {
    # The old tier list bottomed out at KB, so 512 B printed '0 KB' - indistinguishable in the
    # report from a module that found nothing.
    ((Format-PMBytes 512) -ne '0 KB') -and ((Format-PMBytes 1) -ne '0 KB')
}
It 'a terabyte is not four figures of GB' {
    (Format-PMBytes ([int64]2TB)) -ne '2,048.00 GB'
}

Write-Host "`n== log retention (deletes outside the path guard, so it is fenced just as hard) ==" -ForegroundColor Cyan
function New-PMAgedFile {
    param([string]$Path, [double]$AgeDays)
    Set-Content -LiteralPath $Path -Value 'x' -Encoding UTF8
    (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
}
$logFx = New-PMFixtureRoot 'pm-logs-'
try {
    # Ages descend so "newest" is unambiguous; MaxRuns is counted per kind.
    1..5 | ForEach-Object { New-PMAgedFile (Join-Path $logFx ("run-{0}.json" -f $_)) $_ }
    1..5 | ForEach-Object { New-PMAgedFile (Join-Path $logFx ("transcript-{0}.log" -f $_)) $_ }
    New-PMAgedFile (Join-Path $logFx 'latest.json') 400        # old, and must never be a candidate
    New-PMAgedFile (Join-Path $logFx 'notes.txt')   400        # not ours: the age sweep had no filter
    # An EMPTY directory named like a run file. Remove-Item -Force deletes an empty directory
    # happily, so without -File this is genuinely destroyed rather than silently skipped.
    New-Item -ItemType Directory -Path (Join-Path $logFx 'run-99.json') -Force | Out-Null

    $removed = @(Remove-PMOldLogs -Directory $logFx -MaxRuns 2 -MaxAgeDays 365)
    $left = @(Get-ChildItem -LiteralPath $logFx -Force | ForEach-Object { $_.Name })

    It 'keeps MaxRuns of EACH kind, not MaxRuns between them' {
        (@($left | Where-Object { $_ -like 'run-*.json' -and $_ -ne 'run-99.json' }).Count -eq 2) -and
        (@($left | Where-Object { $_ -like 'transcript-*.log' }).Count -eq 2)
    }
    It 'keeps the NEWEST of each kind' {
        ($left -contains 'run-1.json') -and ($left -contains 'run-2.json') -and
        (-not ($left -contains 'run-3.json'))
    }
    It 'never touches latest.json, however old it is' { $left -contains 'latest.json' }
    It 'never touches a file this tool did not write' { $left -contains 'notes.txt' }
    It 'never touches a directory, whatever it is named' { $left -contains 'run-99.json' }
    It 'reports exactly what it removed' {
        ($removed.Count -eq 6) -and (@($removed | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0)
    }
} finally { Remove-Item -LiteralPath $logFx -Recurse -Force -ErrorAction SilentlyContinue }

$logFx2 = New-PMFixtureRoot 'pm-logs2-'
try {
    New-PMAgedFile (Join-Path $logFx2 'run-old.json') 90
    New-PMAgedFile (Join-Path $logFx2 'run-new.json') 1
    It 'the age floor removes an old run even when it is inside MaxRuns' {
        $null = Remove-PMOldLogs -Directory $logFx2 -MaxRuns 50 -MaxAgeDays 30
        (-not (Test-Path -LiteralPath (Join-Path $logFx2 'run-old.json'))) -and
        (Test-Path -LiteralPath (Join-Path $logFx2 'run-new.json'))
    }
} finally { Remove-Item -LiteralPath $logFx2 -Recurse -Force -ErrorAction SilentlyContinue }

$logFx3 = New-PMFixtureRoot 'pm-logs3-'
try {
    1..3 | ForEach-Object { New-PMAgedFile (Join-Path $logFx3 ("run-{0}.json" -f $_)) $_ }
    It 'a manifest value of 0 keeps the newest instead of wiping the history' {
        # MaxRuns floors at 1, the same way Remove-PMOldReports floors Keep. MaxAgeDays 0 is the
        # more interesting one: flooring THAT at 1 would have read as safety while deleting
        # everything older than yesterday, so 0 disables the age sweep instead.
        $null = Remove-PMOldLogs -Directory $logFx3 -MaxRuns 0 -MaxAgeDays 0
        @(Get-ChildItem -LiteralPath $logFx3 -File).Count -eq 1
    }
} finally { Remove-Item -LiteralPath $logFx3 -Recurse -Force -ErrorAction SilentlyContinue }

It 'a missing logs directory is an answer, not an error' {
    @(Remove-PMOldLogs -Directory (Join-Path ([IO.Path]::GetTempPath()) 'pm-no-such-logs-dir')).Count -eq 0
}

Write-Host "`n== uninstall's file removal, and both cells of -KeepLogs ==" -ForegroundColor Cyan
function New-PMPayloadFixture {
    param([switch]$WithLogs)
    $fx = New-PMFixtureRoot 'pm-payload-'
    # Built from a list written out HERE rather than from Get-PMPayloadItems, so the pin below
    # compares two independent statements of what ships instead of the accessor with itself.
    Set-Content -LiteralPath (Join-Path $fx 'Invoke-PcMaintenance.ps1') -Value 'x' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $fx 'pcmaintenance.manifest.json') -Value 'x' -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $fx 'lib') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fx 'lib\PMCommon.ps1') -Value 'x' -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $fx 'modules\m') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fx 'modules\m\module.ps1') -Value 'x' -Encoding UTF8
    if ($WithLogs) {
        New-Item -ItemType Directory -Path (Join-Path $fx 'logs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $fx 'logs\run-1.json') -Value 'x' -Encoding UTF8
    }
    return $fx
}

$pf = New-PMPayloadFixture -WithLogs
try {
    $r = Remove-PMPayloadFiles -Root $pf -KeepLogs
    It '-KeepLogs removes the payload and leaves the history' {
        $r.Removed -and $r.KeptLogs -and (-not $r.Blocked) -and
        (Test-Path -LiteralPath (Join-Path $pf 'logs\run-1.json')) -and
        (-not (Test-Path -LiteralPath (Join-Path $pf 'lib'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $pf 'modules'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $pf 'Invoke-PcMaintenance.ps1'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $pf 'pcmaintenance.manifest.json')))
    }
} finally { Remove-Item -LiteralPath $pf -Recurse -Force -ErrorAction SilentlyContinue }

$pf2 = New-PMPayloadFixture
try {
    $r2 = Remove-PMPayloadFiles -Root $pf2 -KeepLogs
    It '-KeepLogs with no logs directory says so instead of silently deleting everything' {
        # This used to fall through to the full recursive delete of the root and log the same
        # line as an uninstall that was never asked to keep anything.
        $r2.Removed -and (-not $r2.KeptLogs) -and (Test-Path -LiteralPath $pf2) -and
        ($r2.Detail -like '*no logs directory*')
    }
} finally { Remove-Item -LiteralPath $pf2 -Recurse -Force -ErrorAction SilentlyContinue }

$pf3 = New-PMPayloadFixture -WithLogs
try {
    $r3 = Remove-PMPayloadFiles -Root $pf3
    It 'without -KeepLogs the whole root goes, history included' {
        $r3.Removed -and (-not $r3.KeptLogs) -and (-not (Test-Path -LiteralPath $pf3))
    }
} finally { Remove-Item -LiteralPath $pf3 -Recurse -Force -ErrorAction SilentlyContinue }

It 'the uninstaller cannot be pointed at a forbidden directory' {
    # -PayloadRoot is the only operator-supplied path in the project. This is refused before
    # anything is enumerated, and it does not exist, so a broken guard still destroys nothing.
    $a = Remove-PMPayloadFiles -Root 'C:\Users\Someone\Downloads'
    $a.Blocked -and (-not $a.Removed)
}
It 'the uninstaller cannot be pointed one level below the drive' {
    # This test is why MinDepth stopped counting the drive letter. It used to PASS the guard:
    # -PayloadRoot C:\ProgramData is two segments, MinDepth was 2, and -RemoveFiles would have
    # recursively deleted every application's data on the machine. Both names below are chosen
    # not to exist, so the test is safe even against the version of the code that was wrong.
    $a = Remove-PMPayloadFiles -Root 'C:\PmNoSuchTopLevelDirectory'
    $b = Remove-PMPayloadFiles -Root 'D:\PmNoSuchTopLevelDirectory'
    $a.Blocked -and (-not $a.Removed) -and $b.Blocked -and (-not $b.Removed)
}
It 'but its own real payload root is still deep enough' {
    Test-PMPathSafe -Path 'C:\ProgramData\PcMaintenance' -Roots @('C:\ProgramData') -MinDepth 2
}
It 'MinDepth counts directories, not the drive letter' {
    # Same MinDepth, one directory apart. Before the fix both of these were accepted.
    (Test-PMPathSafe -Path 'C:\aaa\bbb' -Roots @('C:\aaa') -MinDepth 2) -and
    (-not (Test-PMPathSafe -Path 'C:\aaa' -Roots @('C:\') -MinDepth 2))
}

Write-Host "`n== the two hard-coded lists are pinned, by the accessors that existed for it ==" -ForegroundColor Cyan
# Get-PMForbiddenPathPatterns and Get-PMForbiddenCategories had no call sites anywhere. They are
# exactly the accessors a test needs to notice a silent edit to either list, so their deadness
# marked a missing test rather than dead weight to delete. The per-pattern tests above catch a
# pattern that stops WORKING; these catch one that quietly stops EXISTING, and they compare the
# joined lists so ORDER is pinned too.
It 'the forbidden PATH pattern list is exactly what ships' {
    $expected = @(
        '^[A-Za-z]:\\?$'
        '^[A-Za-z]:\\Windows($|\\)'
        '^[A-Za-z]:\\Program Files( \(x86\))?($|\\)'
        '^[A-Za-z]:\\Users\\[^\\]+\\(Documents|Desktop|Pictures|Videos|Music|Downloads)($|\\)'
        '^[A-Za-z]:\\Users\\?$'
        '^[A-Za-z]:\\Users\\[^\\]+\\?$'
        '^[A-Za-z]:\\Users\\[^\\]+\\AppData(\\(Local|LocalLow|Roaming))?\\?$'
        '^[A-Za-z]:\\Users\\[^\\]+\\OneDrive[^\\]*($|\\)'
        '\\AppData\\Roaming\\(\.ssh|\.aws|\.azure|\.kube|\.gnupg|Microsoft\\Crypto|Microsoft\\Protect)($|\\)'
        '\\\.ssh($|\\)'
        '\\\.aws($|\\)'
        '^\\\\'
        '\\DockerDesktop($|\\)'
        '\\docker\\volumes($|\\)'
        '\\wsl($|\\)'
        '\\\.git($|\\)'
        '\\site-packages($|\\)'
        '\\node_modules($|\\)'
    )
    $actual = @(Get-PMForbiddenPathPatterns)
    if (($actual -join "`n") -ne ($expected -join "`n")) {
        Write-Host "    have $($actual.Count), pinned $($expected.Count)" -ForegroundColor DarkYellow
        foreach ($d in (Compare-Object $actual $expected)) {
            Write-Host ("    {0} {1}" -f $d.SideIndicator, $d.InputObject) -ForegroundColor DarkYellow
        }
        return $false
    }
    return $true
}
It 'the forbidden CATEGORY list is exactly what ships' {
    $expected = @(
        'security', 'defender', 'antivirus', 'av', 'wdac', 'device-guard', 'hvci',
        'applocker', 'bitlocker', 'firewall', 'credential-guard', 'smartscreen-enforcement'
    )
    $actual = @(Get-PMForbiddenCategories)
    ($actual -join '|') -eq ($expected -join '|')
}
It 'the deployed payload list is exactly what ships' {
    # Shared by the installer's copy loop and the uninstaller's -KeepLogs removal. Adding a fifth
    # item to one and not the other would strand it on every keep-logs uninstall, which is why
    # there is now one list and this pin over it.
    (@(Get-PMPayloadItems) -join '|') -eq 'Invoke-PcMaintenance.ps1|pcmaintenance.manifest.json|lib|modules'
}

Write-Host "`n== a guessed profile has to say it was guessed ==" -ForegroundColor Cyan
It 'a user resolved only from the registry is marked Inferred' {
    # Somebody IS signed in on the machine running this, so asserting the live value would only
    # ever exercise the confirmed branch. PowerShell resolves commands through the CALLER's scope
    # chain and puts functions ahead of cmdlets, so shadowing Get-CimInstance here forces
    # Get-PMInteractiveUserSid past both of its observation sources and down to the ProfileList
    # fallback - the only path that can produce Inferred.
    function Get-CimInstance { throw 'no CIM inside this test' }
    $u = Get-PMInteractiveUserSid
    if (-not $u.Sid) { return 'SKIP' }   # no local profiles at all; there is nothing to assert
    $u.Inferred -and (-not $u.LoggedIn) -and ($null -ne $u.Profile)
}
It 'and a user who was actually observed is not' {
    $u = Get-PMInteractiveUserSid
    if (-not $u.LoggedIn) { return 'SKIP' }   # nobody signed in; the confirmed branch is unreachable
    (-not $u.Inferred) -and ($null -ne $u.Sid)
}
foreach ($cell in @(@{ I = $true; Want = $true }, @{ I = $false; Want = $false })) {
    $c = $cell
    It "the report $(if ($c.Want) { 'warns' } else { 'stays quiet' }) when inferred=$($c.I)" {
        $run = [ordered]@{
            runId='r'; startedUtc=(Get-Date).ToUniversalTime().ToString('o')
            finishedUtc=(Get-Date).ToUniversalTime().ToString('o'); version='t'; mode='report'
            interactiveUser=[ordered]@{ sid='S-1-5-21-1'; profile='C:\Users\X'; loggedIn=(-not $c.I); inferred=$c.I }
            modules=@([ordered]@{ id='m'; status='clean'; detail='d'; bytes=[int64]0; count=0; items=@() })
            summary=[ordered]@{ total=1;clean=1;found=0;applied=0;skipped=0;unverified=0;partial=0;errors=0;bytes=[int64]0 }
            exitCode=0
        }
        $o = Join-Path ([IO.Path]::GetTempPath()) ("pm-inf-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".html")
        try {
            $null = New-PMHtmlReport -Run $run -OutPath $o
            return (((Get-Content $o -Raw) -match 'INFERRED USER') -eq $c.Want)
        } finally { Remove-Item -LiteralPath $o -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host "`n== unknown age must read as JUST TOUCHED, never as ancient ==" -ForegroundColor Cyan
# The bug this pins: an unreadable tree fell through to the directory's OWN timestamp, which is
# effectively its creation date. A live session behind a Deny ACE measured 200.0 idle days and
# became a delete candidate in the one module with AutoApply.
It 'a tree that cannot be read is dated as just touched, not by its own stamp' {
    $d = New-PMUnreadableDir
    if (-not $d) { return 'SKIP' }
    try {
        (Get-Item -LiteralPath $d).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-200)
        Clear-PMReadErrors
        $newest = Get-PMNewestWriteUtc -Path $d
        $idle = ((Get-Date).ToUniversalTime() - $newest).TotalDays
        # Under a 14-day floor this must be spared, and the failure must still be RECORDED -
        # sparing silently would just move the dishonesty somewhere else.
        ($idle -lt 1) -and ((Get-PMReadErrorCount) -gt 0)
    } finally { Remove-PMUnreadableDir $d }
}
It 'a PARTIAL read is treated the same way, because the unseen files may be the newer ones' {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-part-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $sub = Join-Path $d 'unreadable'
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'old.txt') -Value 'x' -Encoding UTF8
    (Get-Item -LiteralPath (Join-Path $d 'old.txt')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-200)
    $ok = $false
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = Get-Acl -LiteralPath $sub
        $acl.SetAccessRuleProtection($true, $true)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $me, [Security.AccessControl.FileSystemRights]::ListDirectory,
            'ContainerInherit,ObjectInherit', 'None', 'Deny')))
        Set-Acl -LiteralPath $sub -AclObject $acl -ErrorAction Stop
        $ok = $true
    } catch { }
    try {
        if (-not $ok) { return 'SKIP' }
        Clear-PMReadErrors
        $newest = Get-PMNewestWriteUtc -Path $d
        # The readable half says 200 days idle. The unreadable half could hold a file from a
        # second ago, so the honest answer is "do not know", which must resolve to recent.
        (((Get-Date).ToUniversalTime() - $newest).TotalDays -lt 1)
    } finally {
        $null = icacls $sub /reset /T /C 2>&1
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n== the uninstaller refuses without throwing past its own refusal ==" -ForegroundColor Cyan
foreach ($bad in @('C:\', 'C:', 'C:\Users\Admin', 'C:\Users\Admin\AppData', 'C:\Users\Admin\AppData\Local', 'C:\Users')) {
    $b = $bad
    It "refuses -PayloadRoot '$b' and returns a result object" {
        # Every one of these used to be a live hazard. 'C:\' and 'C:' threw out of the function
        # entirely - Split-Path returns '' for the first and throws for the second, and
        # [string[]]$Roots rejects an empty element at BIND time - so the caller's Blocked check
        # never ran and the uninstaller printed "uninstall complete" and exited 0. The profile
        # paths simply passed MinDepth 2 and would have been deleted recursively.
        $r = Remove-PMPayloadFiles -Root $b
        ($null -ne $r) -and $r.Blocked -and (-not $r.Removed)
    }
}
It 'and still accepts a real payload root' {
    $fx = New-PMFixtureRoot 'pm-ok-'
    try {
        $r = Remove-PMPayloadFiles -Root $fx
        (-not $r.Blocked)
    } finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'reports Removed = false when something survives the delete' {
    # Removed was the constant $true while the deletes ran under -EA SilentlyContinue, so a
    # locked file produced "removed the payload" at CHANGE level with the tree still on disk.
    $fx = New-PMFixtureRoot 'pm-locked-'
    New-Item -ItemType Directory -Path (Join-Path $fx 'lib') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fx 'logs') -Force | Out-Null
    $held = Join-Path $fx 'lib\PMCommon.ps1'
    Set-Content -LiteralPath $held -Value 'x' -Encoding UTF8
    $fs = [IO.File]::Open($held, 'Open', 'Read', 'None')
    try {
        $r = Remove-PMPayloadFiles -Root $fx -KeepLogs
        (-not $r.Removed) -and ($r.Detail -like '*could not remove*') -and (Test-Path -LiteralPath $held)
    } finally {
        $fs.Dispose()
        Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n== the new container patterns refuse the container, not what is under it ==" -ForegroundColor Cyan
foreach ($case in @(
    @{ P = 'C:\Users';                                  N = 'the Users directory';   R = @('C:\') }
    @{ P = 'C:\Users\Someone';                          N = 'a profile root';        R = @('C:\Users') }
    @{ P = 'C:\Users\Someone\AppData';                  N = 'AppData';               R = @('C:\Users\Someone') }
    @{ P = 'C:\Users\Someone\AppData\Local';            N = 'AppData\Local';         R = @('C:\Users\Someone') }
    @{ P = 'C:\Users\Someone\AppData\Roaming';          N = 'AppData\Roaming';       R = @('C:\Users\Someone') })) {
    $k = $case
    It "refuses $($k.N)" { -not (Test-PMPathSafe -Path $k.P -Roots $k.R) }
}
It 'but every module still sweeps freely below them' {
    # The whole point of anchoring those patterns with $. If this fails the tool has stopped
    # deleting anything while the suite above stays green.
    (Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\Temp\abcd1234.xyz' -Roots @('C:\Users\Someone\AppData\Local\Temp')) -and
    (Test-PMPathSafe -Path 'C:\Users\Someone\AppData\Local\Temp\claude\1111-2222' -Roots @('C:\Users\Someone\AppData\Local\Temp\claude'))
}

Write-Host "`n== a path may not reach its target THROUGH a junction ==" -ForegroundColor Cyan
# The lexical guard cannot see this. Reproduced end to end before the fix: a junction at the
# project-slug level under Temp\claude let agent-scratchpads (AutoApply = $true) hand
# Remove-PMPath a path that passed BOTH halves of the guard, and Remove-Item -Recurse then
# destroyed the real tree while the junction survived. BACKLOG item 4 had closed that case as
# unreachable because "-Recurse does not descend junctions"; this module never uses -Recurse.
function New-PMJunctionTree {
    # <base>\root\link  ->  <base>\target, with <base>\target\<guid>\canary.txt inside it.
    $base = Join-Path ([IO.Path]::GetTempPath()) ("pm-jt-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $root = Join-Path $base 'root'
    $target = Join-Path $base 'target'
    $guid = '11111111-2222-3333-4444-555555555555'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $target $guid) -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $target "$guid\canary.txt") -Value 'x' -Encoding UTF8
    $null = cmd /c mklink /J "`"$(Join-Path $root 'link')`"" "`"$target`"" 2>&1
    return @{ Base = $base; Root = $root; Target = $target
              Through = (Join-Path $root "link\$guid"); Canary = (Join-Path $target "$guid\canary.txt") }
}

It 'Remove-PMPath refuses a path that traverses a junction, and the target survives' {
    $t = New-PMJunctionTree
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $t.Root 'link'))) { return 'SKIP' }  # junctions unavailable
        $r = Remove-PMPath -Path $t.Through -Roots @($t.Root) -DeclaredRoots @($t.Root)
        # All three matter: refused, refused for the RIGHT reason, and the real data still there.
        (-not $r.Removed) -and ($r.Reason -like '*junction*') -and (Test-Path -LiteralPath $t.Canary)
    } finally { Remove-Item -LiteralPath $t.Base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'and that refusal is a path-guard VETO, not a "locked" miscount' {
    # Ok = ($vetoed -eq 0), so bucketing this as locked would let a fully-refused run go green.
    (Get-PMRemovalBucket -Reason 'refused: the path reaches its target through a junction') -eq 'vetoed'
}
It 'but an ordinary nested path under the same root is still removable' {
    # The positive control. Without it, a rule that refused EVERYTHING would pass the test above
    # while silently stopping the tool from deleting anything at all.
    $t = New-PMJunctionTree
    try {
        $plain = Join-Path $t.Root 'ordinary\22222222-3333-4444-5555-666666666666'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $plain 'f.txt') -Value 'x' -Encoding UTF8
        $r = Remove-PMPath -Path $plain -Roots @($t.Root) -DeclaredRoots @($t.Root)
        $r.Removed -and -not (Test-Path -LiteralPath $plain)
    } finally { Remove-Item -LiteralPath $t.Base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a junction that IS the target stays deletable, and only the link goes' {
    # Deleting a reparse point removes the link, not the tree behind it (BACKLOG item 4 cases A
    # and B, both measured "survived"), so stale junctions must remain cleanable.
    $t = New-PMJunctionTree
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $t.Root 'link'))) { return 'SKIP' }
        $r = Remove-PMPath -Path (Join-Path $t.Root 'link') -Roots @($t.Root) -DeclaredRoots @($t.Root)
        $r.Removed -and (Test-Path -LiteralPath $t.Canary)
    } finally { Remove-Item -LiteralPath $t.Base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'Test-PMPathTraversesLink fails closed on a directory it cannot inspect' {
    (Test-PMPathTraversesLink -Path 'Q:\nope\deeper\leaf' -Root 'Q:\nope')
}

Write-Host "`n== one fused walk must answer exactly what two walks did ==" -ForegroundColor Cyan
# Get-PMTreeStat replaced two byte-for-byte identical traversals. The risk in that refactor is
# not that it breaks loudly, it is that one of the four root cases drifts - so each is pinned
# against the value the wrappers are contractually required to return.
function New-PMStatTree {
    $b = Join-Path ([IO.Path]::GetTempPath()) ("pm-stat-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path (Join-Path $b 'sub\deeper') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $b 'a.txt') -Value ('x' * 100) -Encoding Ascii -NoNewline
    Set-Content -LiteralPath (Join-Path $b 'sub\b.txt') -Value ('x' * 200) -Encoding Ascii -NoNewline
    Set-Content -LiteralPath (Join-Path $b 'sub\deeper\c.txt') -Value ('x' * 300) -Encoding Ascii -NoNewline
    return $b
}

It 'Bytes sums the whole tree, and equals what Get-PMPathSize reports' {
    $t = New-PMStatTree
    try {
        $st = Get-PMTreeStat -Path $t
        ($st.Bytes -eq 600) -and ((Get-PMPathSize -Path $t) -eq 600) -and $st.Complete -and -not $st.Blind
    } finally { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'NewestUtc finds the deepest-written file, and equals Get-PMNewestWriteUtc' {
    $t = New-PMStatTree
    try {
        $want = (Get-Date).ToUniversalTime().AddDays(-3)
        (Get-Item -LiteralPath (Join-Path $t 'a.txt')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-99)
        (Get-Item -LiteralPath (Join-Path $t 'sub\b.txt')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-50)
        (Get-Item -LiteralPath (Join-Path $t 'sub\deeper\c.txt')).LastWriteTimeUtc = $want
        $st = Get-PMTreeStat -Path $t
        ([math]::Abs(($st.NewestUtc - $want).TotalSeconds) -lt 2) -and
        ([math]::Abs(((Get-PMNewestWriteUtc -Path $t) - $want).TotalSeconds) -lt 2)
    } finally { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'an early exit marks Complete false, so Bytes is never read as a total' {
    # The trap this guards: the age question stops at the first file past the cutoff, which
    # leaves Bytes partial. agent-scratchpads only reads Bytes when Complete is true.
    $t = New-PMStatTree
    try {
        $st = Get-PMTreeStat -Path $t -NewerThanUtc ((Get-Date).ToUniversalTime().AddDays(-1))
        (-not $st.Complete) -and ($st.Bytes -lt 600)
    } finally { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a file root reports its own length, as Get-PMPathSize always has' {
    $t = New-PMStatTree
    try {
        $f = Join-Path $t 'a.txt'
        $st = Get-PMTreeStat -Path $f
        ($st.RootKind -eq 'file') -and ($st.RootLength -eq 100) -and ((Get-PMPathSize -Path $f) -eq 100)
    } finally { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a missing root is 0 bytes and records no read error' {
    Clear-PMReadErrors
    $g = Join-Path ([IO.Path]::GetTempPath()) ("pm-absent-" + [guid]::NewGuid().ToString('N'))
    $st = Get-PMTreeStat -Path $g
    ($st.RootKind -eq 'missing') -and ((Get-PMPathSize -Path $g) -eq 0) -and ((Get-PMReadErrorCount) -eq 0)
}
It 'a reparse-point root still reports 0, because deleting the link frees nothing' {
    $base = Join-Path ([IO.Path]::GetTempPath()) ("pm-rp-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $real = Join-Path $base 'real'; $link = Join-Path $base 'link'
    New-Item -ItemType Directory -Path $real -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $real 'big.bin') -Value ('z' * 5000) -Encoding Ascii -NoNewline
    try {
        $null = cmd /c mklink /J "`"$link`"" "`"$real`"" 2>&1
        if (-not (Test-Path -LiteralPath $link)) { return 'SKIP' }   # junctions unavailable
        ((Get-PMTreeStat -Path $link).RootKind -eq 'reparse') -and ((Get-PMPathSize -Path $link) -eq 0)
    } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'an unreadable tree sets Blind, and the age still resolves to JUST TOUCHED' {
    $d = New-PMUnreadableDir
    if (-not $d) { return 'SKIP' }
    try {
        (Get-Item -LiteralPath $d).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-200)
        Clear-PMReadErrors
        $st = Get-PMTreeStat -Path $d
        $age = Resolve-PMTreeAge -Stat $st -Path $d
        $st.Blind -and (((Get-Date).ToUniversalTime() - $age).TotalDays -lt 1) -and ((Get-PMReadErrorCount) -gt 0)
    } finally { Remove-PMUnreadableDir $d }
}
It 'an EMPTY directory still dates from itself rather than reading as ancient' {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-empty2-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    try {
        $st = Get-PMTreeStat -Path $d
        (-not $st.Blind) -and (((Get-Date).ToUniversalTime() - (Resolve-PMTreeAge -Stat $st -Path $d)).TotalDays -lt 1)
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== Test measures once, Repair reuses it, and the map never reaches disk ==" -ForegroundColor Cyan

It 'ConvertTo-PMSizeMap keys every candidate by path' {
    $m = ConvertTo-PMSizeMap -Items @(
        [pscustomobject]@{ Path = 'C:\a'; Bytes = 10 },
        [pscustomobject]@{ Path = 'C:\b'; Bytes = 20 })
    ($m.Count -eq 2) -and ($m['C:\a'] -eq 10) -and ($m['C:\b'] -eq 20)
}
It 'and tolerates junk without inventing entries' {
    $m = ConvertTo-PMSizeMap -Items @($null, [pscustomobject]@{ Bytes = 5 }, [pscustomobject]@{ Path = 'C:\c'; Bytes = 7 })
    ($m.Count -eq 1) -and ($m['C:\c'] -eq 7)
}
It 'Get-PMKnownOrMeasuredSize prefers the cached size' {
    # Deliberately a wrong number: if it measured instead of trusting the map, this fails.
    (Get-PMKnownOrMeasuredSize -Path 'C:\Windows' -Known @{ 'C:\Windows' = 4242 }) -eq 4242
}
It 'and MEASURES a path the map does not know, rather than reporting zero' {
    # A candidate that appeared between the phases. Zero here would under-report what the run
    # freed, in the record this project uses instead of a backup.
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-km-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $d 'f.bin') -Value ('x' * 512) -Encoding Ascii -NoNewline
        (Get-PMKnownOrMeasuredSize -Path $d -Known @{ 'C:\somewhere\else' = 1 }) -eq 512
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a null map measures normally, so an un-wired caller is not silently zeroed' {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-km2-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $d 'f.bin') -Value ('x' * 256) -Encoding Ascii -NoNewline
        (Get-PMKnownOrMeasuredSize -Path $d -Known $null) -eq 256
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}

It 'end to end: the size map is handed to Repair and kept OUT of the run JSON' {
    # The map is uncapped on purpose, which is exactly why it must never be serialized: Items is
    # capped at 25 per module to stop an unbounded field being written twice a run and retained
    # 50 runs deep. This runs the real dispatcher and inspects the real JSON.
    $fx = New-PMFixtureRoot -Prefix "pm-sz-"
    $md = Join-Path $fx 'modules\sizemod'
    New-Item -ItemType Directory -Path $md -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'lib') -Destination (Join-Path $fx 'lib') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'Invoke-PcMaintenance.ps1') -Destination $fx -Force
    @'
@{ Id='sizemod'; Name='Sizes'; Category='maintenance'; Version='1.0.0'; RequiresUserSid=$false
   AutoApply=$false; Roots=@('C:\nowhere'); Entry='module.ps1'; Description='fixture' }
'@ | Set-Content -LiteralPath (Join-Path $md 'module.psd1') -Encoding UTF8
    @'
function Test-PMModule {
    param($Context)
    $items = @([pscustomobject]@{ Path = 'C:\fake\one'; Bytes = 111 },
               [pscustomobject]@{ Path = 'C:\fake\two'; Bytes = 222 })
    [pscustomobject]@{
        Clean = $false; Count = 2; Detail = 'two fake items'; Bytes = [int64]333
        Items = @($items | ForEach-Object { @{ path = $_.Path; bytes = $_.Bytes } })
        Sizes = (ConvertTo-PMSizeMap -Items $items)
    }
}
function Repair-PMModule { param($Context) [pscustomobject]@{ Ok=$true; Bytes=[int64]0; Detail='' } }
'@ | Set-Content -LiteralPath (Join-Path $md 'module.ps1') -Encoding UTF8
    '{ "schemaVersion":1, "allowedCategories":["maintenance"], "modules":[{"id":"sizemod","enabled":true,"order":10}] }' |
        Set-Content -LiteralPath (Join-Path $fx 'pcmaintenance.manifest.json') -Encoding UTF8
    try {
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fx 'Invoke-PcMaintenance.ps1') -NoReport 2>&1
        $raw = Get-Content -LiteralPath (Join-Path $fx 'logs\latest.json') -Raw
        $j = $raw | ConvertFrom-Json
        # The module still reports normally...
        $reported = ($j.modules[0].status -eq 'reported' -and $j.modules[0].count -eq 2)
        # ...and the map is nowhere in the serialized record, by field or by content.
        $noField = -not ($j.modules[0].PSObject.Properties.Name -contains 'sizes')
        $noLeak  = ($raw -notmatch '(?i)"sizes"')
        return ($reported -and $noField -and $noLeak)
    } finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== an APPLY run really deletes, and bills it from Test's measurement ==" -ForegroundColor Cyan
It 'apply removes the files and reports freed bytes from the size map' {
    # Nothing in this suite ran the dispatcher with -Apply before, which left the one path that
    # actually deletes covered only indirectly - and BACKLOG 6a changed how its byte total is
    # computed. So: a real fixture, a real -Apply run, real deletion.
    #
    # The map deliberately carries a WRONG size (1000 per item, against 300 real bytes). That is
    # the only way to prove Repair consulted it rather than re-measuring: if the plumbing were
    # broken it would silently fall back to measuring and report 600, which looks correct.
    $fx = New-PMFixtureRoot -Prefix "pm-apply-"
    $data = Join-Path $fx 'data'
    $md = Join-Path $fx 'modules\applymod'
    New-Item -ItemType Directory -Path $md -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $data 'one') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $data 'two') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $data 'one\f.bin') -Value ('x' * 300) -Encoding Ascii -NoNewline
    Set-Content -LiteralPath (Join-Path $data 'two\f.bin') -Value ('x' * 300) -Encoding Ascii -NoNewline
    Copy-Item -LiteralPath (Join-Path $root 'lib') -Destination (Join-Path $fx 'lib') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'Invoke-PcMaintenance.ps1') -Destination $fx -Force

    # Roots must be literal here: Expand-PMRoot only substitutes environment tokens.
    "@{ Id='applymod'; Name='Apply'; Category='maintenance'; Version='1.0.0'; RequiresUserSid=`$false
   AutoApply=`$true; Roots=@('$data'); Entry='module.ps1'; Description='fixture' }" |
        Set-Content -LiteralPath (Join-Path $md 'module.psd1') -Encoding UTF8

    "`$script:DataRoot = '$data'
function Get-Candidates {
    param(`$Context, [hashtable]`$KnownSizes)
    `$out = @()
    foreach (`$d in (Get-PMChildDirectory -Path `$script:DataRoot -Critical)) {
        `$out += [pscustomobject]@{ Path = `$d.FullName
                                   Bytes = (Get-PMKnownOrMeasuredSize -Path `$d.FullName -Known `$KnownSizes) }
    }
    return `$out
}
function Test-PMModule {
    param(`$Context)
    `$items = @(Get-Candidates -Context `$Context)
    # A wrong-on-purpose map: 1000 each, so a cache hit is distinguishable from a re-measure.
    `$map = @{}
    foreach (`$i in `$items) { `$map[`$i.Path] = [int64]1000 }
    [pscustomobject]@{ Clean = `$false; Count = @(`$items).Count; Detail = 'fixture'
                       Bytes = [int64]600; Items = @(); Sizes = `$map }
}
function Repair-PMModule {
    param(`$Context)
    `$items = @(Get-Candidates -Context `$Context -KnownSizes `$Context.KnownSizes)
    `$freed = [int64]0; `$removed = 0; `$vetoed = 0
    foreach (`$i in `$items) {
        `$r = Remove-PMPath -Path `$i.Path -Roots @(`$script:DataRoot) -DeclaredRoots @(`$Context.DeclaredRoots) -KnownBytes ([int64]`$i.Bytes)
        if (`$r.Removed) { `$removed++; `$freed += [int64]`$r.Bytes } else { `$vetoed++ }
    }
    [pscustomobject]@{ Ok = (`$vetoed -eq 0); Bytes = `$freed; Detail = ('removed {0}' -f `$removed) }
}" | Set-Content -LiteralPath (Join-Path $md 'module.ps1') -Encoding UTF8

    '{ "schemaVersion":1, "allowedCategories":["maintenance"], "modules":[{"id":"applymod","enabled":true,"order":10}] }' |
        Set-Content -LiteralPath (Join-Path $fx 'pcmaintenance.manifest.json') -Encoding UTF8
    try {
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fx 'Invoke-PcMaintenance.ps1') -Apply -NoReport 2>&1
        $j = Get-Content -LiteralPath (Join-Path $fx 'logs\latest.json') -Raw | ConvertFrom-Json
        $gone = -not (Test-Path -LiteralPath (Join-Path $data 'one')) -and -not (Test-Path -LiteralPath (Join-Path $data 'two'))
        # 2000, not 600: proof the cached size was used rather than re-measured.
        return ($j.mode -eq 'apply' -and $j.modules[0].status -eq 'applied' -and
                [int64]$j.summary.bytes -eq 2000 -and $gone)
    } finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== gates 1-3 are enforced at the deletion primitive, not only upstream (6i) ==" -ForegroundColor Cyan
# These run OUTSIDE a module phase, so they set the phase stamps by hand - which is exactly what
# Invoke-PMModulePhase does after dot-sourcing the module.
function Set-PMPhaseStamp { param($Name, $Apply, $Roots)
    $script:PMPhaseName = $Name; $script:PMPhaseApply = $Apply; $script:PMPhaseRoots = $Roots }
function Clear-PMPhaseStamp {
    $script:PMPhaseName = $null; $script:PMPhaseApply = $null; $script:PMPhaseRoots = $null }

function New-PMGateTree {
    $b = Join-Path ([IO.Path]::GetTempPath()) ("pm-6i-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $t = Join-Path $b 'victim'
    New-Item -ItemType Directory -Path $t -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $t 'f.txt') -Value 'x' -Encoding UTF8
    return @{ Base = $b; Target = $t }
}

It 'a delete attempted from the TEST phase is refused' {
    # Nothing stopped a module calling Remove-PMPath from Test-PMModule, where the dispatcher
    # has not yet decided -Apply, AutoApply or the user gate at all.
    $g = New-PMGateTree
    try {
        Set-PMPhaseStamp -Name 'Test' -Apply $true -Roots @($g.Base)
        $r = Remove-PMPath -Path $g.Target -Roots @($g.Base) -DeclaredRoots @($g.Base)
        (-not $r.Removed) -and ($r.Reason -like '*Test phase*') -and (Test-Path -LiteralPath $g.Target)
    } finally { Clear-PMPhaseStamp; Remove-Item -LiteralPath $g.Base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a delete in a run that did not grant apply is refused' {
    $g = New-PMGateTree
    try {
        Set-PMPhaseStamp -Name 'Repair' -Apply $false -Roots @($g.Base)
        $r = Remove-PMPath -Path $g.Target -Roots @($g.Base) -DeclaredRoots @($g.Base)
        (-not $r.Removed) -and ($r.Reason -like '*did not grant apply*') -and (Test-Path -LiteralPath $g.Target)
    } finally { Clear-PMPhaseStamp; Remove-Item -LiteralPath $g.Base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a module cannot WIDEN its declared roots by passing something else' {
    # The README claimed the dispatcher hands the roots to Remove-PMPath "so the module cannot
    # influence it". It handed them to the MODULE, which passed them back in - so a module
    # could substitute @('C:\') and both halves of the guard would be module-supplied. The
    # authoritative set now wins and the argument is ignored.
    $g = New-PMGateTree
    try {
        # Authoritative roots say somewhere else entirely; the caller claims the real parent.
        Set-PMPhaseStamp -Name 'Repair' -Apply $true -Roots @('C:\__pm_not_here__')
        $r = Remove-PMPath -Path $g.Target -Roots @($g.Base) -DeclaredRoots @($g.Base)
        (-not $r.Removed) -and ($r.Reason -like '*outside*') -and (Test-Path -LiteralPath $g.Target)
    } finally { Clear-PMPhaseStamp; Remove-Item -LiteralPath $g.Base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'and a legitimate Repair-phase delete still goes through' {
    # Positive control. Three refusals above prove nothing if the tool can no longer delete.
    $g = New-PMGateTree
    try {
        Set-PMPhaseStamp -Name 'Repair' -Apply $true -Roots @($g.Base)
        $r = Remove-PMPath -Path $g.Target -Roots @($g.Base) -DeclaredRoots @($g.Base)
        $r.Removed -and -not (Test-Path -LiteralPath $g.Target)
    } finally { Clear-PMPhaseStamp; Remove-Item -LiteralPath $g.Base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'and a caller outside any module phase is unaffected' {
    # Remove-PMPath is called directly by this suite and by the uninstaller. A gate that fired
    # when no phase had stamped anything would break both without adding any safety.
    $g = New-PMGateTree
    try {
        Clear-PMPhaseStamp
        $r = Remove-PMPath -Path $g.Target -Roots @($g.Base) -DeclaredRoots @($g.Base)
        $r.Removed
    } finally { Clear-PMPhaseStamp; Remove-Item -LiteralPath $g.Base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== 8.3 short names must not slip past the forbidden list (BACKLOG 6k) ==" -ForegroundColor Cyan
It 'the guard alone is fooled by a short name - the reason the resolve exists' {
    # Documents the hazard rather than the fix, so the next person can see WHY Remove-PMPath
    # resolves before it checks. Measured under both 5.1 and 7: identical directory, one name
    # refused and the other allowed.
    (Test-PMPathSafe -Path 'C:\PROGRA~1\x' -Roots @('C:\')) -and
    (-not (Test-PMPathSafe -Path 'C:\Program Files\x' -Roots @('C:\')))
}
It 'the resolve step turns a real short name into its long form' {
    # No fixture is possible: 8.3 generation is disabled for new files on this volume, so
    # `dir /x` returns no alias to test with. Legacy names like PROGRA~1 still exist, and the
    # resolve is exercised against one - WITHOUT ever pointing Remove-PMPath at a system
    # directory, which would risk deleting Program Files if the guard regressed.
    if (-not (Test-Path -LiteralPath 'C:\PROGRA~1')) { return 'SKIP' }
    (New-Object System.IO.DirectoryInfo('C:\PROGRA~1')).FullName -eq 'C:\Program Files'
}
It 'and GetFullPath alone cannot be relied on for it, which is why the resolve exists' {
    # The reason this is belt AND braces. .NET expands some short paths and not others, with no
    # obvious rule: measured on this box, C:\PROGRA~1\__nope__ comes back expanded while
    # C:\PROGRA~1\x does not. Both under 5.1 and 7. A guard that depends on which of those you
    # happen to be handed is not a guard.
    if (-not (Test-Path -LiteralPath 'C:\PROGRA~1')) { return 'SKIP' }
    ([IO.Path]::GetFullPath('C:\PROGRA~1\x') -eq 'C:\PROGRA~1\x') -and
    ([IO.Path]::GetFullPath('C:\PROGRA~1\__nope__') -eq 'C:\Program Files\__nope__')
}
It 'a short path that does not exist is refused or reported gone, never deleted' {
    # The remaining hole is closed by arithmetic rather than by the guard: a path that cannot
    # be resolved is a path that does not exist, and Remove-PMPath will not delete one.
    $r = Remove-PMPath -Path 'C:\PROGRA~1\__pm_does_not_exist__' -Roots @('C:\') -DeclaredRoots @('C:\')
    (-not $r.Removed) -and ($r.Skipped)
}
It 'and an ordinary long path is still removable after the resolve' {
    # Positive control: resolving must not break the normal case.
    $base = Join-Path ([IO.Path]::GetTempPath()) ("pm83b-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $t = Join-Path $base 'ordinary'
    New-Item -ItemType Directory -Path $t -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $t 'f.txt') -Value 'x' -Encoding UTF8
        $r = Remove-PMPath -Path $t -Roots @($base) -DeclaredRoots @($base)
        $r.Removed -and -not (Test-Path -LiteralPath $t)
    } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== the payload ACL check covers what it claims to (BACKLOG 6j) ==" -ForegroundColor Cyan
function New-PMAclProbe {
    param([string]$Sub)
    $d = Join-Path ([IO.Path]::GetTempPath()) ("pm-6j-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $target = if ($Sub) { Join-Path $d $Sub } else { $d }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    return @{ Root = $d; Target = $target }
}
function Add-PMWriteAce {
    # An explicit Allow-write ACE for a given SID. Granting on a directory you own needs no
    # elevation, which is what lets these run in a normal shell.
    param([string]$Path, [string]$Sid)
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($Sid)),
            [Security.AccessControl.FileSystemRights]::Write,
            'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        return $true
    } catch { return $false }
}

It 'NETWORK SERVICE with write access is refused, not trusted' {
    # S-1-5-20 and S-1-5-19 were on the trusted list under a comment saying they are "already
    # privileged enough that writing here grants them nothing new". True of SYSTEM; false of
    # these - they are RESTRICTED service accounts strictly below SYSTEM, so a write ACE here
    # is a genuine escalation path for a compromised network-facing service.
    $probe = New-PMAclProbe
    try {
        if (-not (Add-PMWriteAce -Path $probe.Target -Sid 'S-1-5-20')) { return 'SKIP' }
        @(Test-PMPayloadSecure -Path $probe.Target | Where-Object { $_ -match 'NETWORK SERVICE|S-1-5-20' }).Count -gt 0
    } finally { Remove-Item -LiteralPath $probe.Root -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'and SYSTEM with write access is still fine' {
    # The positive control. Without it, a check that refused everything would pass the test
    # above while making every correctly hardened install unrunnable.
    $probe = New-PMAclProbe
    try {
        $null = Add-PMWriteAce -Path $probe.Target -Sid 'S-1-5-18'
        @(Test-PMPayloadSecure -Path $probe.Target | Where-Object { $_ -match 'S-1-5-18|SYSTEM' }).Count -eq 0
    } finally { Remove-Item -LiteralPath $probe.Root -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'an owner outside the trusted set is reported, because an owner can rewrite the ACL' {
    # The DACL does not show this. An object's owner always holds implicit WRITE_DAC, so a
    # payload owned by a standard user passes every ACE check while staying entirely under
    # their control.
    $probe = New-PMAclProbe
    try {
        $owner = (Get-Acl -LiteralPath $probe.Target).GetOwner([Security.Principal.SecurityIdentifier]).Value
        # Elevated, New-Item leaves this owned by Administrators, which is legitimately trusted
        # and there is nothing to assert.
        if ($owner -in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-549', 'S-1-3-0')) { return 'SKIP' }
        @(Test-PMPayloadSecure -Path $probe.Target | Where-Object { $_ -like '*owned by*' }).Count -gt 0
    } finally { Remove-Item -LiteralPath $probe.Root -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'the tree check sees a permissive ACE on lib\ that a root-only check cannot' {
    # The gap that mattered most: the dispatcher dot-sources every .ps1 under lib\ at startup
    # and Invoke-PMModulePhase does it again per phase, so lib\ with inheritance disabled and
    # its own Allow-write ACE is the most valuable place to plant one - and was invisible.
    $probe = New-PMAclProbe -Sub 'lib'
    try {
        # BOTH changes in ONE Set-Acl. Splitting them - protect, write, then add the ACE and
        # write again - fails unelevated: the second write needs SeSecurityPrivilege. Same trap
        # this suite already documents for removing a Deny ACE, and it turned this test into a
        # permanent SKIP, which is the "verifies nothing" outcome the suite exists to avoid.
        $ok = $true
        try {
            $acl = Get-Acl -LiteralPath $probe.Target
            $acl.SetAccessRuleProtection($true, $true)   # stop inheriting, so the ACE is lib's own
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                (New-Object Security.Principal.SecurityIdentifier('S-1-5-20')),
                [Security.AccessControl.FileSystemRights]::Write,
                'ContainerInherit,ObjectInherit', 'None', 'Allow')))
            Set-Acl -LiteralPath $probe.Target -AclObject $acl -ErrorAction Stop
        } catch { $ok = $false }
        if (-not $ok) { return 'SKIP' }
        $tree = @(Test-PMPayloadTreeSecure -Path $probe.Root)
        $rootOnly = @(Test-PMPayloadSecure -Path $probe.Root)
        # Found by the tree walk, attributed to lib\, and NOT visible to the root-only check.
        (@($tree | Where-Object { $_ -like 'lib\*' -and $_ -match 'NETWORK SERVICE|S-1-5-20' }).Count -gt 0) -and
        (@($rootOnly | Where-Object { $_ -match 'NETWORK SERVICE|S-1-5-20' }).Count -eq 0)
    } finally {
        $null = icacls $probe.Target /reset /T /C 2>&1
        Remove-Item -LiteralPath $probe.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
It 'and the real deployed payload still passes, so this cannot lock us out' {
    # A hardening change that refuses the live install is an outage, not a fix.
    if (-not (Test-Path -LiteralPath 'C:\ProgramData\PcMaintenance')) { return 'SKIP' }
    @(Test-PMPayloadTreeSecure -Path 'C:\ProgramData\PcMaintenance').Count -eq 0
}

Write-Host "`n== size and age must describe the SAME thing a deletion would act on ==" -ForegroundColor Cyan
It 'a reparse-point root is dated from the LINK, not from the tree behind it' {
    # BACKLOG 6g. Get-PMPathSize always returned 0 for a junction, because deleting one removes
    # the link and frees nothing - but the age walk descended it and reported the TARGET's age.
    # Two readers, same path, different subjects: an idle link over an active target read as
    # deletable, and an active link over an idle target read as in use.
    $base = Join-Path ([IO.Path]::GetTempPath()) ("pm-6g-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $real = Join-Path $base 'real'; $link = Join-Path $base 'link'
    New-Item -ItemType Directory -Path $real -Force | Out-Null
    try {
        # Stamp the TARGET old and leave the LINK new, then assert the age comes back NEW.
        #
        # Deliberately no setter on the link. Under 5.1, which is what this suite runs and what
        # the scheduled task uses, `(Get-Item -LiteralPath $link -Force).LastWriteTimeUtc = $x`
        # writes THROUGH the junction and stamps the target; under PowerShell 7 the same line
        # stamps the link. Measured both ways. The production code is unaffected either way
        # because it reads DirectoryInfo, which always describes the link - but a test built on
        # that setter passes on 7 and fails on 5.1 for reasons that have nothing to do with the
        # behaviour under test.
        Set-Content -LiteralPath (Join-Path $real 'old.txt') -Value 'x' -Encoding UTF8
        (Get-Item -LiteralPath (Join-Path $real 'old.txt')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-90)
        $null = cmd /c mklink /J "`"$link`"" "`"$real`"" 2>&1
        if (-not (Test-Path -LiteralPath $link)) { return 'SKIP' }   # junctions unavailable

        $st = Get-PMTreeStat -Path $link
        $age = Resolve-PMTreeAge -Stat $st -Path $link
        # The link was made moments ago, so a correct answer is RECENT. Descending into the
        # target would report ~90 days and make an in-use link look abandoned.
        ($st.RootKind -eq 'reparse') -and ($st.Bytes -eq 0) -and
        (((Get-Date).ToUniversalTime() - $age).TotalDays -lt 1) -and
        ((Get-PMPathSize -Path $link) -eq 0)
    } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'and the target itself is still measured normally when asked directly' {
    # The guard is about the ROOT being a link, not about refusing to look at real trees.
    $base = Join-Path ([IO.Path]::GetTempPath()) ("pm-6g2-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $real = Join-Path $base 'real'
    New-Item -ItemType Directory -Path $real -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $real 'f.bin') -Value ('x' * 400) -Encoding Ascii -NoNewline
        $st = Get-PMTreeStat -Path $real
        ($st.RootKind -eq 'dir') -and ($st.Bytes -eq 400)
    } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== capping retained read errors must not cap the COUNT ==" -ForegroundColor Cyan
# The accumulator keeps at most 200 ErrorRecords now, because it used to keep every one in an
# array grown with += - O(n^2), and 1-3 KB of Exception/InvocationInfo apiece. The danger in
# that fix is obvious and worth pinning: if the reported count came from the capped list, a
# module that failed 50,000 reads would report 200, and capping memory would have quietly
# become under-reporting blindness.
function New-PMFakeError {
    param([string]$Message = 'simulated read failure')
    try { throw $Message } catch { return $_ }
}

It 'the count is every error seen, not the number retained' {
    Clear-PMReadErrors
    $e = New-PMFakeError
    foreach ($i in 1..500) { Add-PMReadError -Errors $e }
    (Get-PMReadErrorCount) -eq 500
}
It 'while retention stays bounded' {
    Clear-PMReadErrors
    $e = New-PMFakeError
    foreach ($i in 1..500) { Add-PMReadError -Errors $e }
    # PMCommon is DOT-SOURCED by this suite, so its $script: scope IS this script's scope and
    # the retained list is directly visible. That is the only way to observe the cap - it is an
    # implementation detail with no accessor, and a test that cannot see it asserts nothing.
    ($script:PMReadErrors.Count -le 200) -and ($script:PMReadErrors.Count -gt 0)
}
It 'critical errors count separately and are also capped' {
    Clear-PMReadErrors
    $e = New-PMFakeError
    foreach ($i in 1..300) { Add-PMReadError -Errors $e -Critical }
    ((Get-PMCriticalReadErrorCount) -eq 300) -and ((Get-PMReadErrorCount) -eq 300)
}
It 'a non-critical error does not inflate the critical count' {
    Clear-PMReadErrors
    Add-PMReadError -Errors (New-PMFakeError)
    Add-PMReadError -Errors (New-PMFakeError) -Critical
    ((Get-PMReadErrorCount) -eq 2) -and ((Get-PMCriticalReadErrorCount) -eq 1)
}
It 'Clear resets both the lists and both counters' {
    Add-PMReadError -Errors (New-PMFakeError) -Critical
    Clear-PMReadErrors
    ((Get-PMReadErrorCount) -eq 0) -and ((Get-PMCriticalReadErrorCount) -eq 0) -and ((Get-PMReadErrorSample) -eq '')
}
It 'a sample and messages still come back after the cap is exceeded' {
    # Bounding retention must not cost the human-readable half: the sample and the deduplicated
    # message list are what turn "Unreadable: 500" into something actionable.
    Clear-PMReadErrors
    foreach ($i in 1..400) { Add-PMReadError -Errors (New-PMFakeError -Message "cannot read thing $i") }
    $msgs = @(Get-PMReadErrorMessages -Max 10)
    ((Get-PMReadErrorSample) -match 'cannot read thing') -and ($msgs.Count -gt 0) -and ($msgs.Count -le 10)
}
It 'and 5,000 errors are recorded without quadratic blow-up' {
    # A wall-clock budget is the only cheap way to catch a regression to +=, but it is also the
    # only thing in this suite that can fail because the machine was busy - and it did once,
    # unreproducibly, at a 10s budget. Widened to 60s rather than deleted: the point is to catch
    # O(n^2), where the old array-append shape took minutes at this size, not to measure the
    # machine. Anything under a minute here is a pass, and a real regression is nowhere near.
    Clear-PMReadErrors
    $e = New-PMFakeError
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($i in 1..5000) { Add-PMReadError -Errors $e }
    $sw.Stop()
    ((Get-PMReadErrorCount) -eq 5000) -and ($sw.Elapsed.TotalSeconds -lt 60)
}

# -- fixture teardown ------------------------------------------------------------------------
# Every fixture helper here creates a pm-* directory under TEMP and every caller cleans up in a
# finally. This is the backstop for when that does not happen, and it REPORTS rather than
# sweeping silently - a quiet sweep would hide exactly the leak it exists to catch.
#
# Not hypothetical. Seven pm-vs-* trees were found stranded from a single run on 2026-09-09:
# vs-installer-scratch was leaking a find handle on the payload-cache directory, an open handle
# blocks Remove-Item, and -ErrorAction SilentlyContinue swallowed the failure. The handle leak
# is fixed; this catches the next one, whatever causes it.
#
# Worth the effort because of WHAT strands: New-PMFixtureRoot hardens the ACL when elevated
# (SYSTEM + Administrators full, Users read-only), so a stranded one is not deletable by the
# user afterwards, and its name matches nothing in stale-app-temp's allowlist, so this tool
# will never clean it up either.
$leaked = @()
try {
    $tempRoot = [IO.Path]::GetTempPath()
    foreach ($f in @(Get-ChildItem -LiteralPath $tempRoot -Filter 'pm-*' -Force -ErrorAction SilentlyContinue)) {
        if ($f.CreationTimeUtc -lt $script:SuiteStartUtc) { continue }   # not from this run
        # An ACL-hardened fixture needs icacls /reset, not Set-Acl: Set-Acl wants
        # SeSecurityPrivilege and strands an undeletable directory behind it.
        if ($f.PSIsContainer) { $null = icacls $f.FullName /reset /T /C 2>&1 }
        Remove-Item -LiteralPath $f.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $f.FullName) { $leaked += "$($f.Name) (could not remove)" }
        else { $leaked += $f.Name }
    }
} catch { }
if ($leaked.Count) {
    Write-Host ("`n{0} fixture(s) survived their own cleanup and were swept here:" -f $leaked.Count) -ForegroundColor Yellow
    $leaked | Select-Object -First 12 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host "  a fixture reaching this sweep means some test's finally did not run - worth finding out why" -ForegroundColor Yellow
}

$tail = if ($script:Skip) { " ({0} SKIPPED - those verified nothing)" -f $script:Skip } else { '' }
Write-Host ("`n{0} passed, {1} failed{2}`n" -f $script:Pass, $script:Fail, $tail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
