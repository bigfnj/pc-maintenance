#Requires -Version 5.1
<#
    PMModule.ps1 - module metadata import + isolated phase invocation.

    Unchanged in shape from the framework this borrows: every module defines functions named
    Test-PMModule / Repair-PMModule, so each phase runs inside a `& {}` child scope that
    dot-sources the shared lib and the one module and is then discarded. Same-named functions
    can never collide across modules, and a module that throws is contained to its own phase.
#>

function Import-PMModuleInfo {
    param([Parameter(Mandatory)][string]$ModuleDir)
    $psd1 = Join-Path $ModuleDir 'module.psd1'
    if (-not (Test-Path $psd1)) { throw "module.psd1 not found in $ModuleDir" }
    $info = Import-PowerShellDataFile -Path $psd1
    foreach ($k in 'Id', 'Name', 'Category', 'Entry') {
        if (-not $info.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$info[$k])) {
            throw "module.psd1 missing required key '$k' in $ModuleDir"
        }
    }
    # Roots is required here where the original has no equivalent: it is half of the path
    # guard, and a module with no declared roots can delete nothing, so an omission must be
    # loud at load rather than a silent no-op at run time.
    if (-not $info.ContainsKey('Roots')) { throw "module.psd1 missing required key 'Roots' in $ModuleDir" }
    return $info
}

function Invoke-PMModulePhase {
    param(
        [Parameter(Mandatory)][string]$ModuleDir,
        [Parameter(Mandatory)][ValidateSet('Test', 'Repair')][string]$Phase,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$LibDir,
        [Parameter(Mandatory)][string]$Entry
    )
    $entryPath = Join-Path $ModuleDir $Entry
    if (-not (Test-Path $entryPath)) { throw "module entry not found: $entryPath" }
    # Returns the phase result AND how many reads failed while producing it. The read counter
    # lives in this child scope and dies with it, so it has to be carried back out here; doing
    # it centrally means no module can forget to report that it was reading blind.
    & {
        param($libDir, $entry, $ctx, $phase)
        Get-ChildItem $libDir -Filter *.ps1 -ErrorAction Stop | ForEach-Object { . $_.FullName }
        . $entry
        Clear-PMReadErrors
        $result = switch ($phase) {
            'Test' { Test-PMModule -Context $ctx }
            'Repair' { Repair-PMModule -Context $ctx }
        }
        [pscustomobject]@{
            Result            = $result
            ReadErrors        = (Get-PMReadErrorCount)
            CriticalReadErrors = (Get-PMCriticalReadErrorCount)
            ReadErrorSample   = (Get-PMReadErrorSample)
        }
    } $LibDir $entryPath $Context $Phase
}
