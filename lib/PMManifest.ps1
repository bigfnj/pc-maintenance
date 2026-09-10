#Requires -Version 5.1
<#
    PMManifest.ps1 - manifest load/validation and the two governance gates.

    Category governance is inherited unchanged in shape from the framework this borrows from: a
    per-manifest allowlist PLUS a hard-coded forbidden set that wins even when a module mislabels
    itself.

    This framework adds a SECOND gate the original does not need, because this one
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

function Test-PMActingUserConfirmed {
    <#
        May we DELETE on behalf of this user?

        Get-PMInteractiveUserSid's last resort picks the first plausible profile out of the
        registry in arbitrary order and reports LoggedIn = $false. That is fine for reporting - a
        wrong number is visible and harmless - and not fine for removal, which on a multi-profile
        machine with nobody signed in would delete inside a stranger's Temp.

        A module that needs no user at all is unaffected.
    #>
    param([Parameter(Mandatory)][bool]$RequiresUserSid, [Parameter(Mandatory)][bool]$LoggedIn)
    if (-not $RequiresUserSid) { return $true }
    return $LoggedIn
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
    # Must be a REAL boolean. This was [bool]$ModuleInfo['AutoApply'], which fails OPEN on a type
    # mistake: Import-PowerShellDataFile preserves the string type, and every non-empty string
    # casts to $true - so AutoApply = 'false', "False" or "0", written by someone with JSON
    # habits, silently promoted a module to DELETING. Measured under 5.1: [bool]'false' is True.
    # `$true -eq $v` is no better, since it coerces the right operand the same way.
    # An unexpected type reads as false, matching the absent case: a module that does not clearly
    # say yes has not said yes.
    $v = $ModuleInfo['AutoApply']
    if ($v -isnot [bool]) { return $false }
    return $v
}
