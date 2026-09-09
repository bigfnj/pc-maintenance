#Requires -Version 5.1
<#
    PMManifest.ps1 - manifest load/validation and the two governance gates.

    Category governance is inherited from preference-guard unchanged in shape: a per-manifest
    allowlist PLUS a hard-coded forbidden set that wins even when a module mislabels itself.

    This framework adds a SECOND gate that preference-guard does not need, because this one
    deletes: a module may only remove things when the operator passed -Apply AND the module's
    own manifest sets AutoApply = $true. Either gate alone leaves it report-only. That is what
    lets a class stay observational for months while a proven-mechanical one is allowed to act,
    which is the whole reason the framework is worth having rather than one big script.
#>

$script:PMForbiddenCategories = @(
    'security', 'defender', 'antivirus', 'av', 'wdac', 'device-guard', 'hvci',
    'applocker', 'bitlocker', 'firewall', 'credential-guard', 'smartscreen-enforcement'
)

function Get-PMManifest {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Manifest not found: $Path" }
    $m = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $m.PSObject.Properties['schemaVersion']) { throw "Manifest missing schemaVersion: $Path" }
    if ([int]$m.schemaVersion -ne 1) { throw "Unsupported manifest schemaVersion $($m.schemaVersion) (expected 1)" }
    if (-not $m.PSObject.Properties['modules']) { throw 'Manifest has no modules array' }
    if (-not $m.PSObject.Properties['allowedCategories']) { throw 'Manifest has no allowedCategories' }
    return $m
}

function Get-PMEnabledModules {
    param([Parameter(Mandatory)]$Manifest)
    @($Manifest.modules | Where-Object { $_.enabled } | Sort-Object { [int]$_.order })
}

function Get-PMForbiddenCategories { $script:PMForbiddenCategories }

function Test-PMCategoryAllowed {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Category, [Parameter(Mandatory)]$Manifest)
    if ([string]::IsNullOrWhiteSpace($Category)) { return $false }
    $cat = $Category.Trim().ToLowerInvariant()
    if ($script:PMForbiddenCategories -contains $cat) { return $false }
    $allowed = @($Manifest.allowedCategories | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    return ($allowed -contains $cat)
}

function Test-PMApplyAllowed {
    <#
        Should this module actually delete on this run?

        $Apply     - the operator passed -Apply to the dispatcher
        $ModuleInfo - the module.psd1 hashtable; AutoApply defaults to FALSE when absent, so a
                      module that forgets to declare it is report-only rather than trusted.
    #>
    param([Parameter(Mandatory)][bool]$Apply, [Parameter(Mandatory)][hashtable]$ModuleInfo)
    if (-not $Apply) { return $false }
    if (-not $ModuleInfo.ContainsKey('AutoApply')) { return $false }
    return [bool]$ModuleInfo['AutoApply']
}
