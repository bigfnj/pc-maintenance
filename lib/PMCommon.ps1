#Requires -Version 5.1
<#
    PMCommon.ps1 - pc-maintenance shared helpers.

    Dot-source only; no side effects on load, so it is safe to re-dot-source inside each
    module's isolated child scope. Borrowed in shape from the framework this project is based on,
    with one deliberate difference: this framework DELETES, so the readers modules are required to
    go through are filesystem readers, and every removal passes a hard path guard first.
#>

function Write-PMLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','CHANGE','SKIP','WARN','ERROR')][string]$Level = 'INFO'
    )
    $prefix = @{ INFO = '[ ]'; OK = '[+]'; CHANGE = '[~]'; SKIP = '[-]'; WARN = '[*]'; ERROR = '[!]' }[$Level]
    $color  = @{ INFO = 'Gray'; OK = 'Green'; CHANGE = 'Green'; SKIP = 'DarkGray'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    $line = '{0} {1} {2}' -f (Get-Date -Format 'HH:mm:ss'), $prefix, $Message
    try { Write-Host $line -ForegroundColor $color } catch { Write-Output $line }
}

function New-PMRunId { (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6)) }

function Test-PMElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-PMSidToProfile {
    param([Parameter(Mandatory)][string]$Sid)
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    if (Test-Path -LiteralPath $key) {
        return (Get-ItemProperty -LiteralPath $key -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
    }
    return $null
}

function Get-PMInteractiveUserSid {
    # Resolve the interactive (console) user; works when the dispatcher runs as SYSTEM, which is
    # how it reaches C:\Users\<user>\AppData\Local\Temp. Returns Sid/Profile/LoggedIn/Inferred.
    #
    # Three sources, in descending confidence. The first two OBSERVE a session that is really
    # there and set LoggedIn. The third GUESSES: it takes the first plausible profile out of the
    # registry in whatever order the keys happen to enumerate, which on a multi-profile machine
    # with nobody signed in can be a stranger. That fallback is kept deliberately, because
    # reporting the wrong profile's numbers is visible and harmless, and it is MARKED
    # deliberately - Inferred is $true, LoggedIn is $false, and Test-PMActingUserConfirmed
    # refuses to let anything DELETE for a user resolved this way.
    #
    # (This comment used to claim no user is ever guessed. It was wrong for as long as the third
    # fallback has existed. The deletion gate was right; the description of it was not.)
    #
    # Sid may still be $null at the logon screen with no profiles at all, in which case every
    # per-user module is skipped rather than guessed.
    $sid = $null; $loggedIn = $false; $account = $null
    try { $account = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
    if ($account) {
        try {
            $sid = (New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            $loggedIn = $true
        } catch {}
    }
    if (-not $sid) {
        try {
            $exp = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
            if ($exp) {
                $o = Invoke-CimMethod -InputObject $exp -MethodName GetOwnerSid -ErrorAction Stop
                if ($o.Sid) { $sid = $o.Sid; $loggedIn = $true }
            }
        } catch {}
    }
    if (-not $sid) {
        $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $cand = Get-ChildItem $pl -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^(S-1-12-1-|S-1-5-21-)' } |
            ForEach-Object {
                $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                [pscustomobject]@{ Sid = $_.PSChildName; Path = $p.ProfileImagePath }
            } | Where-Object { $_.Path -match '\\Users\\' } | Select-Object -First 1
        if ($cand) { $sid = $cand.Sid }
    }
    $prof = if ($sid) { Resolve-PMSidToProfile -Sid $sid } else { $null }
    # Inferred means: there is a SID, but nothing observed a session for it. Only the
    # registry fallback can produce that combination.
    [pscustomobject]@{ Sid = $sid; Profile = $prof; LoggedIn = $loggedIn
                       Inferred = [bool]($sid -and -not $loggedIn) }
}

# --- the path guard -------------------------------------------------------------------
#
# The framework this borrows from is kept safe by a hard-coded FORBIDDEN CATEGORY set that wins
# even if a module mislabels itself. The equivalent here is a hard-coded FORBIDDEN PATH set, because the
# damage this framework can do is measured in deleted bytes, not in policy. Both gates are
# deliberately not configurable from the manifest: a module cannot vote itself the right to
# delete somewhere dangerous.
#
# Docker is named explicitly because a volume root looks exactly like disposable scratch from
# the outside while holding an application's only copy of its data. Guessing wrong there is not
# recoverable, so it is refused by name rather than left to a heuristic.

$script:PMForbiddenPathPatterns = @(
    '^[A-Za-z]:\\?$'                                # a drive root
    '^[A-Za-z]:\\Windows($|\\)'
    '^[A-Za-z]:\\Program Files( \(x86\))?($|\\)'
    '^[A-Za-z]:\\Users\\[^\\]+\\(Documents|Desktop|Pictures|Videos|Music|Downloads)($|\\)'
    # The profile root ITSELF, and the AppData roots, as targets. Nothing enumerates these, but
    # -PayloadRoot is operator input and MinDepth 2 accepts C:\Users\Admin quite happily, so
    # without these an uninstall pointed at a profile would recursively delete it. Anchored with
    # $ so only the container matches - every module still sweeps freely BELOW them.
    '^[A-Za-z]:\\Users\\?$'
    '^[A-Za-z]:\\Users\\[^\\]+\\?$'
    '^[A-Za-z]:\\Users\\[^\\]+\\AppData(\\(Local|LocalLow|Roaming))?\\?$'
    # Known Folder Move is the Windows 11 default, so the REAL Documents/Desktop/Pictures for
    # most people live under OneDrive and the pattern above never sees them. Measured before
    # this line existed: C:\Users\X\OneDrive\Documents\tax returned safe.
    '^[A-Za-z]:\\Users\\[^\\]+\\OneDrive[^\\]*($|\\)'
    # Anything a credential or a key lives in. AppData\Roaming was uncovered entirely.
    '\\AppData\\Roaming\\(\.ssh|\.aws|\.azure|\.kube|\.gnupg|Microsoft\\Crypto|Microsoft\\Protect)($|\\)'
    '\\\.ssh($|\\)'
    '\\\.aws($|\\)'
    # Anything beginning \\, which is three separate dangers at once:
    #   * UNC shares. Forbidden outright rather than by adjusting MinDepth: this is a
    #     local-machine housekeeping tool, no module has business on a share, and a future
    #     one that did would have to remove this line deliberately. MinDepth is a poor
    #     defence there anyway - \\server\share\folder already counts as three segments.
    #   * the \\?\ long-path prefix, which otherwise defeats every ^[A-Za-z]:\\-anchored
    #     pattern above AT ONCE, silently switching most of this list off.
    #   * the \\.\ device prefix, same reasoning.
    # These were briefly two patterns. The second could never fire: every path it matched
    # already began \\ and was caught here first, so it was a guard no input could reach.
    '^\\\\'
    '\\DockerDesktop($|\\)'
    '\\docker\\volumes($|\\)'
    # A local mount point literally named "wsl". The real WSL shares are UNC and are covered by
    # the ^\\\\ rule above. This was '\\wsl\\', which required a TRAILING backslash and so
    # protected everything under the directory while leaving the directory ITSELF deletable -
    # the one target whose removal destroys all of it. Every other container rule here uses the
    # ($|\\) form; this was the only one that did not.
    '\\wsl($|\\)'
    '\\\.git($|\\)'
    '\\site-packages($|\\)'
    '\\node_modules($|\\)'
)

function Get-PMForbiddenPathPatterns { $script:PMForbiddenPathPatterns }

function Test-PMPathSafe {
    <#
        Two independent conditions, both required:
          1. the target sits UNDER one of the roots the module declared, and
          2. it matches no forbidden pattern, and is at least MinDepth DIRECTORIES deep.

        MinDepth counts directory segments with the DRIVE EXCLUDED, because 'C:' is not a
        directory and counting it made the parameter read one level deeper than it was. That
        was not academic: Uninstall-PcMaintenance.ps1 asked for MinDepth 2 meaning "below a
        top-level directory" and got "drive plus one directory", so -PayloadRoot C:\ProgramData
        passed the guard and a -RemoveFiles run would have taken all of ProgramData with it.
        The default moved 3 -> 2 at the same time, which leaves every module caller counting
        exactly the same segments as before; only the uninstaller gets stricter.

        (1) alone is not enough: a module with a broad root would still be able to reach a
        Docker volume inside it. (2) alone is not enough either: it would let a module delete
        anywhere nobody thought to forbid. Returns $true only if both hold.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Roots,
        [int]$MinDepth = 2
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = try { [IO.Path]::GetFullPath($Path) } catch { return $false }
    $full = $full.TrimEnd('\')
    # Depth is counted from the segments below the drive letter. Written with String.Split and
    # an offset rather than the pipeline, because this is the hottest line in the guard and the
    # guard runs TWICE per deletion - 13,870 calls for a single 6,935-file sweep.
    #
    # Measured over 14,000 candidates: `.Where({...})` cost 523 ms and
    # `@($segments | Select-Object -Skip 1)` cost 1,021 ms, against 29 ms for the GetFullPath
    # that does the real work. Both replaced: 34 ms, ~40% off the whole function.
    #
    # Deliberately NOT changed on the same pass: the 18-pattern loop below looks like it should
    # thrash the 15-entry regex cache, and measuring said otherwise - pre-compiling to a Regex[]
    # was SLOWER (481 ms vs 377 ms) and raising [regex]::CacheSize changed nothing. Left alone.
    $segments = $full.Split([char]'\', [StringSplitOptions]::RemoveEmptyEntries)
    $first = 0
    if ($segments.Length -and $segments[0].Length -eq 2 -and $segments[0][1] -eq ':' -and
        [char]::IsLetter($segments[0][0])) { $first = 1 }
    if (($segments.Length - $first) -lt $MinDepth) { return $false }
    foreach ($pat in $script:PMForbiddenPathPatterns) { if ($full -match $pat) { return $false } }
    foreach ($r in $Roots) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $root = try { [IO.Path]::GetFullPath($r).TrimEnd('\') } catch { continue }
        if ($full.Equals($root, 'OrdinalIgnoreCase')) { return $false }   # never the root itself
        if ($full.StartsWith($root + '\', 'OrdinalIgnoreCase')) { return $true }
    }
    return $false
}

function Test-PMPathTraversesLink {
    <#
        Does this path REACH its target through a junction or symlink?

        Test-PMPathSafe compares strings. A string can look perfectly contained inside a declared
        root while resolving into another volume entirely, and that is not a hypothetical:
        agent-scratchpads enumerates in two non-recursive passes, so a junction at the
        project-slug level under Temp\claude let it hand Remove-PMPath a path of the form
        <root>\<junction>\<session-guid>. That path passed BOTH halves of the guard, and
        Remove-Item -Recurse then followed the link and destroyed the real tree while the
        junction itself survived. Reproduced end to end before this function existed.

        BACKLOG item 4 had closed that case as unreachable, reasoning that "Get-ChildItem
        -Recurse does not descend junctions, so no module can enumerate one". The measurement
        was sound and the conclusion did not follow: this module never uses -Recurse.

        Only the INTERMEDIATE directories are checked, never the target itself. Remove-Item
        -Recurse on a reparse point deletes the LINK and leaves the target alone (item 4's own
        cases A and B, both measured "survived"), so a stale junction stays cleanable.

        Fails closed: a directory we cannot inspect is treated as a link.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    $rootFull = try { [IO.Path]::GetFullPath($Root).TrimEnd('\') } catch { return $true }
    $cur      = try { [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $true }
    $cur = Split-Path -Parent $cur      # start above the target; the target itself may be a link
    while ($cur -and $cur.Length -gt $rootFull.Length -and
           $cur.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        try {
            $i = Get-Item -LiteralPath $cur -Force -ErrorAction Stop
            if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
        } catch { return $true }
        $next = Split-Path -Parent $cur
        if ($next -eq $cur) { break }   # cannot ascend further; stop rather than spin
        $cur = $next
    }
    return $false
}

function Test-PMPayloadSecure {
    <#
        Refuse to run from a directory a non-admin can write to.

        This is not defence in depth, it is load-bearing. PMModule.ps1 dot-sources EVERY .ps1 in
        lib\ into the phase scope, and this dispatcher runs as SYSTEM. C:\ProgramData inherits
        BUILTIN\Users:(CI)(WD,AD) - create-file and create-subdirectory - so on a DEFAULT install
        any standard user could drop lib\zz.ps1 and have SYSTEM execute it on the next weekly run.
        They never need to touch a file that already exists, so a hash or signature check on the
        shipped files would not have caught it either.

        The installer hardens the ACL, but an install that skipped it, a hand-copied payload, or a
        later ACL change must not silently re-open the hole, so the runtime refuses rather than
        trusting the installer.

        Returns the offending identities; an empty result means safe.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $bad = @()
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    } catch {
        return @("cannot read the ACL: $($_.Exception.Message)")
    }
    # Anything that can introduce or alter a file here can run code as us.
    $R = [System.Security.AccessControl.FileSystemRights]
    # ONLY the write-ish bits. Modify and FullControl are composite values whose bit patterns
    # INCLUDE the read rights, so folding them into a -band mask made plain ReadAndExecute match
    # and every correctly hardened install was reported insecure. Note CreateFiles and WriteData
    # are the same bit (2), as are CreateDirectories and AppendData (4), so both are covered.
    $dangerous = $R::WriteData -bor $R::AppendData -bor $R::WriteAttributes -bor
                 $R::WriteExtendedAttributes -bor $R::Delete -bor
                 $R::DeleteSubdirectoriesAndFiles -bor $R::ChangePermissions -bor $R::TakeOwnership
    # Principals already privileged enough that writing here grants them nothing new.
    #
    # LOCAL SERVICE (S-1-5-19) and NETWORK SERVICE (S-1-5-20) were in this list and should not
    # have been. They are RESTRICTED service accounts, strictly BELOW SystemLocal: a write ACE
    # for NETWORK SERVICE on a directory the dispatcher dot-sources as SYSTEM is a real
    # escalation path for a compromised network-facing service, and this check would have
    # approved it. The comment above was true of SYSTEM and Administrators and was extended to
    # them by assumption.
    #
    # CREATOR OWNER (S-1-3-0) stays: it is a placeholder that only grants rights to whoever
    # creates a new object, and the owner check below covers the risk it represents.
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-549', 'S-1-3-0')
    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        if (-not ($ace.FileSystemRights -band $dangerous)) { continue }
        $sid = $null
        try {
            $sid = if ($ace.IdentityReference -is [System.Security.Principal.SecurityIdentifier]) {
                $ace.IdentityReference.Value
            } else {
                $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
        } catch { $sid = [string]$ace.IdentityReference }
        if ($trusted -contains $sid) { continue }
        $bad += ('{0} ({1})' -f $ace.IdentityReference, $ace.FileSystemRights)
    }

    # THE OWNER, which the DACL does not show. An object's owner always holds implicit
    # WRITE_DAC - they can rewrite the very ACL this function just approved - so a payload
    # directory owned by a standard user passes every check above while remaining completely
    # under their control. Not reachable on the default install, where an elevated New-Item
    # leaves it owned by Administrators or SYSTEM, but reachable for exactly the hand-copied
    # payload this function's docstring says it exists to catch.
    try {
        $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($trusted -notcontains $ownerSid) {
            $ownerName = try { $acl.GetOwner([System.Security.Principal.NTAccount]).Value } catch { $ownerSid }
            $bad += ('owned by {0} - an owner can rewrite this ACL at will' -f $ownerName)
        }
    } catch {
        $bad += "cannot read the owner: $($_.Exception.Message)"
    }
    return $bad
}

function Test-PMPayloadTreeSecure {
    <#
        The payload root AND the directories whose contents get executed.

        Test-PMPayloadSecure inspects one directory. That was enough while every ACE was
        inherited from the root, and not enough in general: the dispatcher dot-sources every
        .ps1 in lib\ at startup and Invoke-PMModulePhase dot-sources them again inside each
        phase, so a permissive ACE placed directly on lib\ with inheritance disabled is
        invisible to a root-only check while being the most valuable place to put one.

        modules\ is included for the same reason - Import-PMModuleInfo reads module.psd1 and
        the phase runner dot-sources module.ps1.

        Missing subdirectories are not an error here; the caller is asking "is what exists
        safe", and a payload with no lib\ fails for louder reasons elsewhere.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $bad = @(Test-PMPayloadSecure -Path $Path)
    foreach ($sub in @('lib', 'modules')) {
        $p = Join-Path $Path $sub
        if (-not [IO.Directory]::Exists($p)) { continue }
        foreach ($b in @(Test-PMPayloadSecure -Path $p)) { $bad += ('{0}\: {1}' -f $sub, $b) }
    }
    return $bad
}

function Set-PMPayloadAcl {
    <#
        Lock the payload down: inheritance OFF, SYSTEM and Administrators full, Users read+execute
        only. Called by the installer while elevated. Kept beside the check it satisfies so the two
        cannot drift apart.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)   # protect from inheritance, drop inherited ACEs
    foreach ($r in @($acl.Access)) { $null = $acl.RemoveAccessRule($r) }
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $R = [System.Security.AccessControl.FileSystemRights]
    foreach ($grant in @(
        @{ Sid = 'S-1-5-18';     Rights = $R::FullControl },
        @{ Sid = 'S-1-5-32-544'; Rights = $R::FullControl },
        @{ Sid = 'S-1-5-32-545'; Rights = $R::ReadAndExecute })) {
        $id = New-Object System.Security.Principal.SecurityIdentifier($grant.Sid)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $id, $grant.Rights, $inherit, $none, $allow)))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# --- filesystem readers (the test seam) -----------------------------------------------
# Modules read state ONLY through these, so tests can fake a tree without touching a disk.
#
# The readers RECORD what they could not read instead of silently returning less. That
# distinction is the whole point: a reader that swallows an access error turns "I could not
# look" into "there is nothing there", and the module then reports Clean while blind. It
# happened on the first SYSTEM run of this tool: SYSTEM refuses to traverse a cross-volume
# junction created by a less-privileged user ("the path cannot be traversed because it
# contains an untrusted mount point"), and plex-bif-orphans cheerfully reported a clean
# machine while 28 orphans sat on the other side of it.
#
# The counter lives in the module's own child scope, so Invoke-PMModulePhase reads it back
# out and the dispatcher decides what to do. Modules do not have to remember anything.

# Retained SAMPLES, not every error. The COUNTS are separate integers, so capping what is kept
# does not change a single number the dispatcher reports.
#
# It used to keep every ErrorRecord in a plain array grown with +=, which is two problems at
# once. += reallocates the whole array per append, so a tree where every read fails is O(n^2) -
# at the documented 13,341 directories that is ~89 million element copies, the same shape
# measured at 6,733 ms elsewhere in this project. And each ErrorRecord drags an Exception, a
# TargetObject and an InvocationInfo (script text and position) behind it, roughly 1-3 KB, so
# 100k of them is 100-300 MB held inside a SYSTEM process.
#
# Nothing ever consumed the retained records. Everything downstream reads a count, one sample
# message, or at most ten deduplicated messages - so beyond the cap they were pure weight.
$script:PMReadErrors = New-Object 'System.Collections.Generic.List[object]'
$script:PMCriticalReadErrors = New-Object 'System.Collections.Generic.List[object]'
$script:PMReadErrorCount = 0            # every error seen, whether or not it was kept
$script:PMCriticalReadErrorCount = 0
$script:PMReadErrorSampleCap = 200      # far more than the 10 anything actually displays

function Clear-PMReadErrors {
    $script:PMReadErrors = New-Object 'System.Collections.Generic.List[object]'
    $script:PMCriticalReadErrors = New-Object 'System.Collections.Generic.List[object]'
    $script:PMReadErrorCount = 0
    $script:PMCriticalReadErrorCount = 0
}
# The counter, NOT the list length. That distinction is the whole point of the cap: a module
# that failed 50,000 reads must still report 50,000, or capping memory would quietly become
# under-reporting blindness - which is the one thing this file exists to prevent.
function Get-PMReadErrorCount { $script:PMReadErrorCount }
function Get-PMCriticalReadErrorCount { $script:PMCriticalReadErrorCount }
# Critical first, then incidental, and NEITHER wrapped in @().
#
# `@($emptyGenericList)` throws "Argument types do not match" - measured, not theorised. That is
# harmless while these are plain arrays and fatal the moment they become List[object], which
# capping the accumulator required. It broke eight tests at once, every one of them a caller
# that merely wanted to read an error message. Indexing the lists directly avoids the construct
# entirely and reads better anyway.
function Get-PMReadErrorSample {
    if ($script:PMCriticalReadErrors.Count -gt 0) { return [string]$script:PMCriticalReadErrors[0].Exception.Message }
    if ($script:PMReadErrors.Count -gt 0) { return [string]$script:PMReadErrors[0].Exception.Message }
    return ''
}

# -Critical marks a read whose FAILURE INVALIDATES THE ANSWER: the module's own root, the one
# place it must be able to see to say "clean" and mean it. Incidental probes leave it off.
#
# The distinction is not pedantry, it is what keeps the control believable. The first SYSTEM run
# after error-tracking went in flagged vs-installer-scratch as unverified because one PyInstaller
# _MEI directory was locked by a running app - a permanent, benign, weekly red. A check that
# reddens for a benign reason trains you to ignore red, which costs more than the check gains.
# Non-critical failures are still counted and still shown, as partial coverage.

function Get-PMReadErrorMessages {
    # Every distinct thing we could not read, capped. The count alone told a reader a number and
    # nothing they could act on: "Unreadable: 1" is not a fact anyone can do anything with.
    param([int]$Max = 10)
    $seen = New-Object 'System.Collections.Generic.List[string]'
    # Two explicit passes rather than one over a concatenation: see Get-PMReadErrorSample for
    # why @() must not touch these lists. Critical first, so the ten shown favour the failures
    # that invalidated an answer over the ones that merely narrowed coverage.
    foreach ($src in @($script:PMCriticalReadErrors, $script:PMReadErrors)) {
        foreach ($e in $src) {
            if ($seen.Count -ge $Max) { break }
            $m = [string]$e.Exception.Message
            if ($m -and -not $seen.Contains($m)) { $seen.Add($m) }
        }
        if ($seen.Count -ge $Max) { break }
    }
    return $seen.ToArray()
}

function Add-PMReadError {
    param($Errors, [switch]$Critical)
    if (-not $Errors) { return }
    # Count everything, keep the first $PMReadErrorSampleCap. List.Add is amortised O(1); the
    # += this replaced reallocated the whole array on every single append.
    foreach ($e in @($Errors)) {
        $script:PMReadErrorCount++
        if ($script:PMReadErrors.Count -lt $script:PMReadErrorSampleCap) { $script:PMReadErrors.Add($e) }
        if ($Critical) {
            $script:PMCriticalReadErrorCount++
            if ($script:PMCriticalReadErrors.Count -lt $script:PMReadErrorSampleCap) { $script:PMCriticalReadErrors.Add($e) }
        }
    }
}

# The existence guard on both readers uses the native call, not Test-Path. It is the same
# check - "absent, so return @() quietly" as distinct from "present but unlistable, so record a
# read error" - and that distinction is the whole reason the guard exists. Only the cost
# changes: measured over 6,405 paths, Test-Path -LiteralPath took 3,398 ms against 280 ms for
# [IO.Directory]::Exists. It is 12x because Test-Path is a cmdlet with provider resolution and
# parameter binding per call, and these run once per candidate.
#
# Get-PMChildFile keeps a File::Exists arm so a file path stays truthy exactly as Test-Path
# made it, rather than quietly becoming a narrower function.

function Get-PMChildDirectory {
    param([Parameter(Mandatory)][string]$Path, [switch]$Critical)
    if (-not [IO.Directory]::Exists($Path)) { return @() }
    $ev = $null
    $r = @(Get-ChildItem -LiteralPath $Path -Force -Directory -ErrorAction SilentlyContinue -ErrorVariable ev)
    Add-PMReadError -Errors $ev -Critical:$Critical
    return $r
}

function Get-PMChildFile {
    # No -Filter. It had no caller, and the one that existed dropped it deliberately: the
    # Win32 filter matches on the 8.3 name too, so -Filter '*.tmp' also returns .tmpx -
    # exactly the bug BACKLOG item 1 mutation-tested out of plex-bif-orphans. Leaving the
    # parameter exposed invited a future module to walk back into it. Filter in the caller.
    param([Parameter(Mandatory)][string]$Path, [switch]$Recurse, [switch]$Critical)
    if (-not ([IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path))) { return @() }
    $ev = $null
    $r = @(Get-ChildItem -LiteralPath $Path -Force -File -Recurse:$Recurse -ErrorAction SilentlyContinue -ErrorVariable ev)
    Add-PMReadError -Errors $ev -Critical:$Critical
    return $r
}

function Resolve-PMReparsePoint {
    <#
        Follow a junction/symlink to its real target, once.

        Needed because this tool runs as SYSTEM, and SYSTEM will NOT traverse a cross-volume
        junction created by a less-privileged user - Windows blocks it as a symlink-attack
        defence. Scanning the resolved target instead sidesteps the block without weakening
        anything: the path guard still applies, and the module declares the resolved root.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    try {
        $i = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $t = $i.Target
            if ($t -is [array]) { $t = $t[0] }
            if ($t -and (Test-Path -LiteralPath $t)) { return [string]$t }
        }
    } catch {}
    return $Path
}

function Test-PMPath { param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    Test-Path -LiteralPath $Path
}

function ConvertTo-PMSizeMap {
    <#
        Build the path -> bytes map a module's Test phase hands forward to its Repair phase.

        Repair re-derives its candidate list rather than trusting Test's, and that MUST stay:
        re-running every selection rule at delete time is what spares a directory that became
        active in between, and BACKLOG item 4's threat model assumes the window exists. What
        does not need repeating is the MEASURING - Get-PMPathSize walks the whole tree again for
        a number taken seconds earlier.

        Uncapped on purpose, and in memory only. Items is capped at 25 per module so a
        6,935-orphan run does not bloat the run JSON; this map would break that rule if it ever
        reached disk, so the dispatcher moves it onto the context and never into the row. A test
        pins that it stays out of the JSON.
    #>
    param($Items)
    $h = @{}
    foreach ($i in @($Items)) {
        if ($null -ne $i -and $i.Path) { $h[[string]$i.Path] = [int64]$i.Bytes }
    }
    return $h
}

function Get-PMKnownOrMeasuredSize {
    <#
        The size from Test if we have it, otherwise measure it now.

        A path absent from the map is one that appeared BETWEEN the phases, so it was never
        measured and must be. Falling back rather than defaulting to zero matters: zero would
        under-report what the run freed, and the run JSON is this project's substitute for a
        backup.
    #>
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Known)
    if ($Known -and $Known.ContainsKey($Path)) { return [int64]$Known[$Path] }
    return (Get-PMPathSize -Path $Path)
}

function Get-PMTreeStat {
    <#
        ONE traversal that answers both questions a module asks about a directory: how big is it
        and when was anything in it last written.

        These were two functions with byte-for-byte identical walks - same Stack[string], same
        EnumerateFiles/EnumerateDirectories, same reparse-point skip. agent-scratchpads called
        both on every candidate, and because a candidate only becomes a candidate by being IDLE,
        the age walk never took its early exit for exactly the paths whose size was then wanted.
        So every selected candidate was walked twice, in full, for data one pass already had.

        Deliberately returns FACTS, not decisions. The root policies of the two readers genuinely
        differ - Get-PMPathSize returns 0 for a reparse-point root because deletion frees nothing
        there, while the age reader wants the LINK's own stamp rather than the target's tree
        (BACKLOG 6g) - so folding either policy in here would silently change the other.
        Get-PMPathSize and Resolve-PMTreeAge each keep their own.

        Reads .Length off the enumeration's own WIN32_FIND_DATA rather than re-stat'ing every
        file: measured 25 ms against 78 ms for Get-ChildItem -Recurse | Measure-Object on a real
        868-file directory.

        Walks directories ITSELF instead of using AllDirectories, for a correctness reason that
        cost a regression to learn: DirectoryInfo.EnumerateFiles(AllDirectories) FOLLOWS reparse
        points, while Get-ChildItem -Recurse and Remove-Item -Recurse do not. Size must measure
        the same bytes deletion will actually free.

        -NewerThanUtc stops the walk the moment anything beats the cutoff. That is what keeps the
        age question cheap - an active directory exits after one file - but it leaves Bytes
        PARTIAL, so Complete comes back false and callers must not read Bytes when it is.

        Returns @{ Bytes; NewestUtc; Blind; Complete; RootKind; RootLength }
          Blind    - at least one read failed, so neither number covers the whole tree
          Complete - the walk finished; false means it early-exited and Bytes is meaningless
          RootKind - 'file' | 'reparse' | 'dir' | 'missing' | 'unreadable'
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [datetime]$NewerThanUtc = [datetime]::MinValue,
        [switch]$Critical
    )
    $r = @{ Bytes = [int64]0; NewestUtc = [datetime]::MinValue; Blind = $false
            Complete = $true; RootKind = 'dir'; RootLength = [int64]0 }

    if (-not [IO.Directory]::Exists($Path)) {
        if ([IO.File]::Exists($Path)) {
            # A file is a legitimate thing to ask about - plex hands us individual .tmp files.
            try {
                $fi = New-Object System.IO.FileInfo($Path)
                $r.RootKind = 'file'; $r.RootLength = [int64]$fi.Length
                $r.Bytes = [int64]$fi.Length; $r.NewestUtc = $fi.LastWriteTimeUtc
            } catch {
                Add-PMReadError -Errors $_ -Critical:$Critical
                $r.RootKind = 'unreadable'; $r.Blind = $true
            }
            return $r
        }
        $r.RootKind = 'missing'
        return $r
    }

    try {
        $rootInfo = New-Object System.IO.DirectoryInfo($Path)
        if ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            # A reparse-point ROOT is not descended, and both numbers describe the LINK.
            #
            # This is BACKLOG 6g. Get-PMPathSize always returned 0 here, because deleting a
            # junction removes the link and frees nothing - but the age walk pushed the root
            # unconditionally and read the age of the TARGET's whole tree. So the two readers
            # described different things for the same path: 0 bytes, and an age belonging to a
            # tree that deletion would not touch. An idle link over an active target read as
            # deletable; an active link over an idle target read as in use.
            #
            # The invariant, now held by construction: size and age must both describe what a
            # deletion would actually act on. For a link, that is the link.
            $r.RootKind = 'reparse'
            $r.NewestUtc = $rootInfo.LastWriteTimeUtc
            return $r
        }
    } catch {
        Add-PMReadError -Errors $_ -Critical:$Critical
        $r.RootKind = 'unreadable'; $r.Blind = $true
        return $r
    }

    $canExitEarly = ($NewerThanUtc -gt [datetime]::MinValue)
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo($dir)
            foreach ($f in $di.EnumerateFiles()) {
                $r.Bytes += [int64]$f.Length
                if ($f.LastWriteTimeUtc -gt $r.NewestUtc) { $r.NewestUtc = $f.LastWriteTimeUtc }
                # Safe to leave without consulting Blind: something in here is newer than the
                # cutoff, so the answer is "active", which is the sparing answer either way.
                if ($canExitEarly -and $r.NewestUtc -gt $NewerThanUtc) { $r.Complete = $false; return $r }
            }
            foreach ($sub in $di.EnumerateDirectories()) {
                # Do not descend a junction or symlink: neither will the deletion.
                if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($sub.FullName)
            }
        } catch {
            # One unreadable subtree must not abandon the rest, and must not pass silently
            # either. Continue so the numbers are as complete as they can be, and flag Blind so
            # the caller learns they are incomplete.
            Add-PMReadError -Errors $_ -Critical:$Critical
            $r.Blind = $true
        }
    }
    return $r
}

function Get-PMPathSize {
    <#
        Total bytes under $Path, measuring what a deletion would actually free.

        A reparse-point root frees nothing when removed - Remove-Item deletes the link, not the
        target - so it returns 0 rather than the target's size. Getting that wrong once inflated
        both the report headline and the "removed N GB" line by a tree that was never enumerated
        and never deleted.

        Errors are RECORDED, not swallowed. This used to be the one reader that hid access
        failures, which is the exact "silence looks like emptiness" failure the rest of this file
        exists to prevent.
    #>
    param([Parameter(Mandatory)][string]$Path, [switch]$Critical)
    $st = Get-PMTreeStat -Path $Path -Critical:$Critical
    switch ($st.RootKind) {
        'file'       { return [int64]$st.RootLength }
        'reparse'    { return [int64]0 }
        'missing'    { return [int64]0 }
        'unreadable' { return [int64]0 }
    }
    return [int64]$st.Bytes
}

function Resolve-PMTreeAge {
    <#
        Turn a Get-PMTreeStat result into the age answer, with the two not-knowing cases kept
        distinct. Shared so a caller that already has a Stat does not have to re-derive - and
        cannot get it subtly different.

        WHAT "AGE" MEANS HERE, and why it is not the obvious thing. This prose moved in from
        Get-PMNewestWriteUtc, a wrapper deleted for having zero production callers; the wrapper
        was expendable, the measurement is not.

        The age of a tree is the newest LastWriteTimeUtc of any FILE anywhere under it, never the
        directory's own stamp. A directory's mtime is not the age of its contents: Windows updates
        it only when entries are added to or removed from THAT directory, not when a file deeper
        in the tree is written. Measured on a live agent session directory - the root said 06:01
        while the newest file inside said 14:29, an 8.5 hour lag on a session that was actively
        running.

        Any rule that deletes "directories older than N days" by directory mtime will therefore
        eventually delete something that is still in use. That is survivable while a module only
        reports, and not survivable once it acts - and agent-scratchpads acts.

        There is exactly ONE place below where the directory's own stamp is used, and it is the
        empty-tree case: nothing failed, there is simply no file to date it. That is the exception
        the rule leaves room for, not a relapse into it.
    #>
    param([Parameter(Mandatory)][hashtable]$Stat, [Parameter(Mandatory)][string]$Path)

    if ($Stat.Blind) {
        # We could not read all of it, so we do not KNOW its age, and the two ways of not knowing
        # must not get the same answer as each other or as an empty directory.
        #
        # The directory's own stamp is effectively its creation time - that is the entire reason
        # this function exists - so using it for a tree we could not read reports a session
        # written seconds ago as months idle. Measured: a live session behind a Deny ACE reported
        # 200.0 idle days, sailed past the 14-day floor, and became a delete candidate in the one
        # module that has AutoApply, while reporting 0 bytes freed.
        #
        # A partial read is the same hazard in slower motion: files we could see are older than
        # files we could not, so any answer built from them is an over-estimate of idleness.
        #
        # Unknown age therefore reads as JUST TOUCHED. An age floor can then only ever spare it,
        # never select it, and the read error is still recorded so the run reports the gap
        # instead of quietly narrowing its own coverage.
        return (Get-Date).ToUniversalTime()
    }
    # An EMPTY directory is a different thing entirely: nothing failed, there is simply no file to
    # date it, and its own timestamp is the best evidence available.
    if ($Stat.NewestUtc -eq [datetime]::MinValue) {
        try { return (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).LastWriteTimeUtc } catch { }
    }
    return $Stat.NewestUtc
}

function Expand-PMRoot {
    <#
        Expand a declared root from module.psd1 into a real path for THIS run.

        Two steps, both necessary. %LOCALAPPDATA% and friends are expanded against the
        INTERACTIVE user, not the running process - under SYSTEM the process variables point at
        C:\Windows\system32\config\systemprofile and every declared root would silently miss.
        Then reparse points are resolved, so a module whose directory is a junction to another
        volume still matches the root it declared rather than failing the check it should pass.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Root, [string]$UserProfile)
    if ([string]::IsNullOrWhiteSpace($Root)) { return '' }
    $r = $Root
    if ($UserProfile) {
        # A .NET replacement string only treats $ specially. Escaping backslashes here and
        # then stripping them turned a profile path into a drive-relative one.
        #
        # The escape now covers ALL THREE branches. It used to guard only %USERPROFILE% while
        # the other two concatenated $UserProfile raw, so `$&`, `` $` ``, `$'` and `$1`-`$9` in
        # a profile path - all legal NTFS characters - were read as substitution tokens. It
        # failed closed (the result became a nonexistent root, and the %...% residue check
        # below then refused it), but silently: every module would have dropped to report-only
        # for that user with no indication why.
        $safeProfile = ($UserProfile -replace '\$', '$$$$')
        $r = $r -replace '(?i)%USERPROFILE%', $safeProfile
        $r = $r -replace '(?i)%LOCALAPPDATA%', ($safeProfile + '\AppData\Local')
        $r = $r -replace '(?i)%APPDATA%', ($safeProfile + '\AppData\Roaming')
    }
    $r = [Environment]::ExpandEnvironmentVariables($r)
    # %[^%]+% rather than %[A-Za-z_]+%: the old class missed %FOO2% and %MY_VAR1%, which
    # were returned literally instead of refused. Still fails closed either way - a
    # nonexistent root matches nothing - but 'refuse rather than guess' was only half true.
    if ($r -match '%[^%]+%') { return '' }   # unresolved token: refuse rather than guess
    return (Resolve-PMReparsePoint -Path $r)
}

function Get-PMDeclaredRoots {
    param([Parameter(Mandatory)][hashtable]$ModuleInfo, [string]$UserProfile)
    $out = @()
    foreach ($r in @($ModuleInfo['Roots'])) {
        $e = Expand-PMRoot -Root ([string]$r) -UserProfile $UserProfile
        if ($e) { $out += $e }
    }
    return $out
}

function Remove-PMPath {
    <#
        The only sanctioned deletion. Refuses anything Test-PMPathSafe rejects, and honours
        -WhatIfOnly so a module's Repair can compute the full intent in report-only mode
        without a second code path that could drift from the real one.

        Returns @{ Removed; Skipped; Reason; Bytes }.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Roots,
        [AllowEmptyCollection()][string[]]$DeclaredRoots = @(),
        [int64]$KnownBytes = -1,
        [switch]$WhatIfOnly,
        [int]$MinDepth = 2   # DIRECTORIES below the drive; see Test-PMPathSafe
    )
    # Resolve 8.3 SHORT NAMES before any guard looks at the path.
    #
    # Every pattern in the forbidden list matches on NAME, and a short name defeats all of them
    # at once. Measured: Test-PMPathSafe allows C:\PROGRA~1\x while refusing C:\Program Files\x,
    # under 5.1 as well as 7. Inside a declared root the same trick reaches DOCKER~1 past a rule
    # written for DockerDesktop.
    #
    # Not reachable through the four shipped modules, which hand over enumerated .FullName and
    # therefore always long form - but -PayloadRoot is operator input, and the first module to
    # take a path from config or an environment variable would be exposed with nothing to catch
    # it. Done HERE rather than in Test-PMPathSafe because it costs a filesystem call (~0.4 ms)
    # and Test-PMPathSafe runs per candidate, while this runs per deletion.
    #
    # Only an existing path can be expanded, which is exactly the case that matters: nothing
    # else can be deleted.
    $long = $Path
    try {
        if ([IO.Directory]::Exists($Path))  { $long = (New-Object System.IO.DirectoryInfo($Path)).FullName }
        elseif ([IO.File]::Exists($Path))   { $long = (New-Object System.IO.FileInfo($Path)).FullName }
    } catch { }
    if ($long -ne $Path) { $Path = $long }

    if (-not (Test-PMPathSafe -Path $Path -Roots $Roots -MinDepth $MinDepth)) {
        return @{ Removed = $false; Skipped = $true; Reason = 'refused by path guard'; Bytes = [int64]0 }
    }
    # Gates 1-3, enforced HERE and not only in the dispatcher.
    #
    # Remove-PMPath used to know nothing about -Apply or which phase it was in, so the README's
    # first three conditions existed entirely in the dispatcher's control flow. Nothing stopped a
    # module calling this from Test-PMModule, before any of them had been evaluated.
    #
    # Only enforced when the phase actually stamped these - Remove-PMPath is called directly by
    # the suite too, and a guard that fires outside a module phase would break every one of
    # those without adding safety.
    if ($null -ne $script:PMPhaseName -and -not $WhatIfOnly) {
        if ($script:PMPhaseName -eq 'Test') {
            return @{ Removed = $false; Skipped = $true; Bytes = [int64]0
                      Reason = 'refused: deletion attempted from the Test phase' }
        }
        if (-not $script:PMPhaseApply) {
            return @{ Removed = $false; Skipped = $true; Bytes = [int64]0
                      Reason = 'refused: this run did not grant apply' }
        }
    }

    # The SECOND, independent condition. $Roots above is supplied by the module at run time, so on
    # its own it is self-certification: a module that computes the wrong root gets to delete there.
    # $DeclaredRoots comes from module.psd1 via the dispatcher.
    #
    # And when the phase stamped the authoritative set, THAT is what is used - the caller's
    # argument is ignored rather than trusted. Previously the dispatcher put the roots on the
    # context, the module read them off and passed them back in, so a module could widen them
    # to @('C:\') just by passing something else, and $Context is a hashtable shared by
    # reference across both phases so Test could even mutate them for Repair.
    # Fail CLOSED. Reading this as "no declared roots means no restriction" would make the
    # independent half of the guard vanish exactly when a caller forgot to supply it.
    if ($null -ne $script:PMPhaseRoots -and @($script:PMPhaseRoots).Count) {
        $DeclaredRoots = @($script:PMPhaseRoots)
    }
    if (-not @($DeclaredRoots).Count) {
        return @{ Removed = $false; Skipped = $true; Reason = 'no declared roots supplied'; Bytes = [int64]0 }
    }
    if (-not (Test-PMPathSafe -Path $Path -Roots $DeclaredRoots -MinDepth $MinDepth)) {
        return @{ Removed = $false; Skipped = $true; Reason = 'outside the roots this module declares'; Bytes = [int64]0 }
    }
    # Both checks above are LEXICAL. This one asks the filesystem, because a path can satisfy
    # every string test and still resolve somewhere else entirely. Checked here rather than just
    # before Remove-Item so report mode refuses it too - a path we would not delete must not be
    # counted as reclaimable.
    foreach ($dr in $DeclaredRoots) {
        if ([string]::IsNullOrWhiteSpace($dr)) { continue }
        $drFull = try { [IO.Path]::GetFullPath($dr).TrimEnd('\') } catch { continue }
        $pFull  = try { [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { continue }
        if (-not $pFull.StartsWith($drFull + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (Test-PMPathTraversesLink -Path $Path -Root $drFull) {
            return @{ Removed = $false; Skipped = $true; Bytes = [int64]0
                      Reason = 'refused: the path reaches its target through a junction' }
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Removed = $false; Skipped = $true; Reason = 'gone'; Bytes = [int64]0 }
    }
    $bytes = if ($KnownBytes -ge 0) { $KnownBytes } else { Get-PMPathSize -Path $Path }
    if ($WhatIfOnly) {
        return @{ Removed = $false; Skipped = $false; Reason = 'report-only'; Bytes = $bytes }
    }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return @{ Removed = $true; Skipped = $false; Reason = ''; Bytes = $bytes }
    } catch {
        # Remove-Item -Recurse can delete most of a tree and then throw. Recording that as
        # untouched is the one thing the audit trail must never get wrong, so re-measure.
        $left = Get-PMPathSize -Path $Path
        $partial = if (Test-Path -LiteralPath $Path) { $bytes - $left } else { $bytes }
        if ($partial -lt 0) { $partial = [int64]0 }
        return @{ Removed = $false; Skipped = $true; Bytes = $partial
                  Reason = "partially removed then failed: $($_.Exception.GetType().Name)" }
    }
}

function Test-PMPayloadItemCurrent {
    <#
        Is the deployed copy of one payload item IDENTICAL to the source?

        Exists because "the destination exists" is not the same claim as "the current version is
        deployed", and using the first as a post-condition silently broke the installer: with
        Invoke-PMChange's before-check in front of the copy, every item reported "already done"
        and nothing was copied at all. lib\ went stale on a live machine within a minute of the
        change - the exact failure the deployment smoke test was written for, reintroduced by
        the fix for a different instance of the same family.

        The lesson is narrow and worth keeping: a post-condition has to express what the change
        MEANS, not merely that something is present afterwards. Existence is the weakest possible
        reading of "deployed".

        Hashes rather than timestamps: mtime survives a copy, differs harmlessly after a
        checkout, and is settable by anything. Compares the full relative-path SET too, so an
        extra file at the destination - the lib\lib\ nesting case - counts as not-current.
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Dest)
    if (-not (Test-Path -LiteralPath $Dest)) { return $false }
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $Dest -PathType Leaf)) { return $false }
        try { return ((Get-FileHash -LiteralPath $Source).Hash -eq (Get-FileHash -LiteralPath $Dest).Hash) }
        catch { return $false }
    }
    try {
        $rel = {
            param($root)
            @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop |
                ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\') })
        }
        $a = @(& $rel $Source | Sort-Object)
        $b = @(& $rel $Dest   | Sort-Object)
        if (($a -join '|') -ne ($b -join '|')) { return $false }
        foreach ($r in $a) {
            if ((Get-FileHash -LiteralPath (Join-Path $Source $r)).Hash -ne
                (Get-FileHash -LiteralPath (Join-Path $Dest $r)).Hash) { return $false }
        }
        return $true
    } catch { return $false }
}

function Invoke-PMChange {
    <#
        Make a change, then PROVE it, and report from the proof.

        Six times in one audit round this codebase emitted a confident sentence about something
        it never checked:

          * Remove-PMPayloadFiles set Removed = $true unconditionally while the deletes ran under
            -ErrorAction SilentlyContinue, so a locked file reported a removed payload.
          * install-deletion-forensics exited 1 on a completely successful install, because
            Sysmon writes its banner to stderr and $ErrorActionPreference was Stop.
          * Its -Uninstall printed "USN journal returned to 32 MB" while the journal sat at
            2,048 MB, because createjournal cannot shrink and silently does nothing.
          * -Verify reported "no weekly report task" about a task registered seconds earlier,
            because a SYSTEM task is admin-only to VIEW.

        Every one of them has the same shape: the CLAIM and the EVIDENCE are separate statements,
        and nothing in the language couples them. `Write-PMLog "removed X" 'CHANGE'` is exactly
        as easy to write whether or not X was removed.

        This couples them. Success is computed from -Verify and NEVER from -Action, so:

          * an error swallowed inside -Action cannot read as success
          * noise on stderr, or a non-zero exit from a native tool that actually worked, cannot
            read as failure
          * a no-op that changes nothing fails its own post-condition

        -Verify is MANDATORY. That is the point of the helper; an optional post-condition is a
        post-condition nobody writes. Evaluated BEFORE as well as after, so a change that was
        already in place is reported honestly as "already" rather than as work done.

        WHAT THIS IS NOT. The predicate can itself be wrong, and some things cannot be verified
        at all - "the scheduled task ran" is not observable at the moment you start it. This
        relocates the trust into one small reviewable expression per change instead of spreading
        it across scattered log lines. Where a thing genuinely cannot be checked, say "requested"
        rather than "done" and do not pretend otherwise.

        Returns @{ Ok; Changed; AlreadyDone; Detail; Error }.
    #>
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][scriptblock]$Verify,
        [switch]$DryRun,
        # Report a failed post-condition as a warning rather than an error. For deliveries whose
        # loss must not fail the run - the report step is the standing example.
        [switch]$SoftFail
    )
    $r = [ordered]@{ Ok = $false; Changed = $false; AlreadyDone = $false; Detail = ''; Error = $null }

    $before = $false
    try { $before = [bool](& $Verify) } catch { $before = $false }
    if ($before) {
        $r.Ok = $true; $r.AlreadyDone = $true
        $r.Detail = "$What - already done"
        Write-PMLog $r.Detail 'SKIP'
        return $r
    }

    if ($DryRun) {
        $r.Ok = $true
        $r.Detail = "[DRY-RUN] $What"
        Write-PMLog $r.Detail 'INFO'
        return $r
    }

    # The action's own failure mode is deliberately NOT the verdict. It is captured for the
    # message, because "it threw X and the post-condition is still false" is far more useful
    # than either half alone - but the verdict below comes from the post-condition.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & $Action 2>&1 } catch { $r.Error = $_ } finally { $ErrorActionPreference = $prev }

    $after = $false
    try { $after = [bool](& $Verify) } catch { $r.Error = $_; $after = $false }

    if ($after) {
        $r.Ok = $true; $r.Changed = $true
        $r.Detail = $What
        Write-PMLog $r.Detail 'CHANGE'
    } else {
        $r.Ok = $false
        $r.Detail = if ($r.Error) { "$What - FAILED: $($r.Error.Exception.Message)" }
                    else { "$What - did not take effect" }
        Write-PMLog $r.Detail $(if ($SoftFail) { 'WARN' } else { 'ERROR' })
    }
    return $r
}

function Get-PMRemovalBucket {
    <#
        Map a Remove-PMPath result Reason to the bucket a module's Repair counts it in:
        'vetoed' (the guard refused), 'gone' (it vanished between Test and Repair), or
        'locked' (anything else, e.g. a partial delete that then threw).

        Here rather than copied into each module because the copies DRIFTED. Three of the four
        shipped modules never gained an arm for 'no declared roots supplied', so that refusal
        fell through to their default bucket - locked - and because Ok was then computed as
        ($vetoed -eq 0), a run in which the guard refused every single target would still have
        returned Ok = $true and rendered a green "Cleaned" badge. That is the exact failure the
        comment above each of those switches claims was already fixed.

        That Ok expression is gone; see Get-PMRepairOutcome below, which is where the buckets
        this function returns are turned into an outcome. Mis-bucketing still matters just as
        much, because 'vetoed' is the arm that fails a run outright.

        Unreachable today only because the dispatcher pre-empts a module with no resolvable
        declared roots before Repair ever runs. "Unreachable by one caller's current control
        flow" is not the same as safe, and it is the shape this project has been bitten by
        before: a guard no input can reach reads like coverage in review.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Reason)
    switch -Wildcard ($Reason) {
        '*refused*'  { return 'vetoed' }
        '*outside*'  { return 'vetoed' }
        '*declared*' { return 'vetoed' }
        'gone'       { return 'gone' }
        default      { return 'locked' }
    }
}

function Get-PMRepairOutcome {
    <#
        Did a Repair achieve what it set out to do? Returns the status the dispatcher records
        ('applied', 'incomplete' or 'error') and the one sentence that describes the same
        numbers, so the badge and the prose beside it can never disagree.

        This replaces Ok = ($vetoed -eq 0), which asked a much narrower question - "did the
        path guard refuse anything?" - while everything downstream read the answer as "did the
        cleanup work?". BACKLOG 7h, reproduced end to end on 2026-09-10 with one exclusively
        locked file: Remove-PMPath returned Removed=$false / "partially removed then failed:
        IOException", Get-PMRemovalBucket correctly called it 'locked', $vetoed stayed 0, and
        so a repair that freed nothing rendered Role 'good' / Icon 'OK' / Word 'Cleaned',
        counted itself in summary.applied and exited 0. Only the Detail string was honest.

        Here rather than copied into each module for the reason recorded on Get-PMRemovalBucket
        immediately above: the four copies of that Ok expression - and the four verbatim copies
        of the Detail format string below - are exactly what drifted last time.

        THE RULES, and why each is where it is:

          - vetoed > 0 is ALWAYS a hard failure, whatever else succeeded. The guard refusing a
            target means a module asked to delete something it may not touch; that is never
            routine, and averaging it away against 939 successes is how it would be ignored.
          - removed == attempted - gone is success. Something that vanished between Test and
            Repair is not work left undone - the tree is in the state the run wanted.
          - removed > 0 with anything still locked is 'incomplete': real work happened, and it
            did not finish. Green would over-claim it, red would cry wolf.
          - removed == 0 while there was genuinely something to remove is 'error'. This is the
            case the whole item is about.

        -ge rather than -eq on the success test is deliberate. If a module ever hands back
        counters that do not add up, over-counting removals must not fall through to the
        'incomplete' arm and read as a partial success; the caller-side shape check in the
        dispatcher is what catches an inconsistent module.
    #>
    param(
        [Parameter(Mandatory)][int]$Attempted,
        [Parameter(Mandatory)][int]$Removed,
        [Parameter(Mandatory)][int]$Vetoed,
        [Parameter(Mandatory)][int]$Locked,
        [Parameter(Mandatory)][int]$Gone
    )
    $expected = $Attempted - $Gone
    $status =
        if ($Vetoed -gt 0)              { 'error' }
        elseif ($Removed -ge $expected) { 'applied' }
        elseif ($Removed -gt 0)         { 'incomplete' }
        else                            { 'error' }
    [pscustomobject]@{
        Status = $status
        Detail = ('removed {0} of {1}; {2} vetoed by the path guard, {3} locked, {4} already gone' -f
                    $Removed, $Attempted, $Vetoed, $Locked, $Gone)
    }
}

function Format-PMBytes {
    # This string IS the report, so both missing tiers were readability bugs rather than rounding
    # ones. Without a bytes tier anything under 512 B printed '0 KB', which reads as "nothing
    # found" for a real finding; without a TB tier a 2 TB sweep printed '2,048.00 GB'.
    param([Parameter(Mandatory)][AllowNull()][int64]$Bytes)
    if (-not $Bytes) { return '0 B' }
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}


# --- the deletions that deliberately do NOT go through the path guard ------------------
#
# There are exactly two, and both delete inside directories the guard forbids outright: logs\
# sits under the payload root, and reports land in Downloads. Widening the guard so they could
# pass would trade a narrow convenience for the broadest hole in the tool, so each is instead its
# own much stricter rule that can only ever match files THIS tool wrote. Remove-PMOldReports is
# the other one; it lives in PMReport.ps1, next to the writer whose output it prunes.

function Remove-PMOldLogs {
    <#
        Retention for the run history under logs\.

          - a FILE, never a directory. Without -File a directory under logs\ matched, and
            Remove-Item -Force without -Recurse then failed silently under -EA SilentlyContinue:
            a no-op that read, in the transcript, exactly like retention working.
          - the name must be one this tool writes. The age sweep previously had no filter at all,
            so anything older than the cut went with it, including a file another tool left here.
          - -like, not -Filter. -Filter is a Win32 pattern and matches more than it appears to;
            this is the same trap plex-bif-orphans' EndsWith fix exists for.
          - never a reparse point.
          - latest.json survives because it matches neither name, not by a special case.

        Returns the paths removed.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [int]$MaxRuns = 50,
        [int]$MaxAgeDays = 30
    )
    if ($MaxRuns -lt 1) { $MaxRuns = 1 }   # a bad manifest value must not wipe the history
    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory)) { return @() }

    $ours = @(Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'run-*.json' -or $_.Name -like 'transcript-*.log' } |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
    if (-not $ours.Count) { return @() }

    $doomed = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($pattern in @('run-*.json', 'transcript-*.log')) {
        # Counted PER KIND, so MaxRuns 50 keeps 50 of each rather than 50 files between them.
        foreach ($f in @($ours | Where-Object { $_.Name -like $pattern } |
                         Sort-Object LastWriteTime -Descending | Select-Object -Skip $MaxRuns)) {
            $null = $doomed.Add($f.FullName)
        }
    }
    # A non-positive age means NO age sweep. Flooring it at 1 instead would read as safety and
    # behave as "delete everything older than yesterday", which is the opposite.
    if ($MaxAgeDays -ge 1) {
        $cut = (Get-Date).AddDays(-$MaxAgeDays)
        foreach ($f in @($ours | Where-Object { $_.LastWriteTime -lt $cut })) { $null = $doomed.Add($f.FullName) }
    }

    $removed = @()
    foreach ($path in $doomed) {
        try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop; $removed += $path } catch { }
    }
    return $removed
}

# The deployed payload, named in ONE place. The installer copies these and the uninstaller's
# -KeepLogs removes exactly these, so a fifth item added to one list and not the other would
# strand a stale file on every keep-logs uninstall.
$script:PMPayloadItems = @('Invoke-PcMaintenance.ps1', 'pcmaintenance.manifest.json', 'lib', 'modules')

function Get-PMPayloadItems { $script:PMPayloadItems }

function Remove-PMPayloadFiles {
    <#
        The uninstaller's file removal, here rather than inline in the script so it can be tested
        against a fixture without elevating and without touching the real scheduled task.

        -Root is operator input and this is a recursive force delete, so it goes through the same
        guard every module does. Without it, -PayloadRoot C:\ deleted the drive root.

        -KeepLogs removes the deployed items and leaves logs\ alone. It used to fall through to
        the full delete whenever logs\ did not exist, so asking to keep a history you did not
        have deleted the root and logged the same line as never asking. The two cases are
        separate now, and both say which one happened.

        MinDepth 2 here means two directories below the drive, so the shallowest root this will
        accept is C:\Something\PcMaintenance. C:\ProgramData on its own is refused.

        Returns Blocked / Removed / KeptLogs / Detail.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$KeepLogs
    )
    $r = [pscustomobject]@{ Blocked = $false; Removed = $false; KeptLogs = $false; Detail = '' }

    # Split-Path returns '' for 'C:\' and THROWS for 'C:'. Test-PMPathSafe's [string[]]$Roots then
    # rejects the empty element at BIND time, which is a statement-terminating error, not $false -
    # it unwound past this function entirely, so the caller's Blocked check never ran and
    # Uninstall-PcMaintenance.ps1 printed "uninstall complete" and exited 0 without refusing
    # anything. Handle it here, where refusing is what we mean.
    $guardRoot = try { Split-Path -Parent $Root } catch { $null }
    if ([string]::IsNullOrWhiteSpace($guardRoot)) {
        $r.Blocked = $true
        $r.Detail  = "refusing to delete '$Root' - it has no parent, so it is a drive root or malformed"
        return $r
    }
    if (-not (Test-PMPathSafe -Path $Root -Roots @($guardRoot) -MinDepth 2)) {
        $r.Blocked = $true
        $r.Detail  = "refusing to delete '$Root' - the path guard rejects it"
        return $r
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        $r.Detail = "nothing to remove at $Root"
        return $r
    }

    if ($KeepLogs) {
        # This branch deletes the CHILDREN of $Root, which is what makes it different from the
        # whole-tree removal below. Remove-Item -Recurse deletes a reparse point itself when the
        # reparse point IS the target (measured - item 4 cases A and B both survived), but it
        # follows one that is an ANCESTOR of the target. So a junctioned $Root is harmless to
        # the branch below and destructive here: the real lib\ and modules\ go, the junction
        # stays. Test-PMPathSafe cannot see this - it compares strings. Same fault and same fix
        # as agent-scratchpads.
        #
        # $Root is known to exist by this point, so the check cannot fail closed on absence.
        foreach ($i in (Get-PMPayloadItems)) {
            if (Test-PMPathTraversesLink -Path (Join-Path $Root $i) -Root $guardRoot) {
                $r.Blocked = $true
                $r.Detail  = "refusing to remove the payload under '$Root' - it is reached through a junction or symlink, so deleting its contents would destroy the link target"
                return $r
            }
        }
        $logsDir = Join-Path $Root 'logs'
        $hadLogs = Test-Path -LiteralPath $logsDir
        # Removed used to be the constant $true here, while the deletes ran under
        # -ErrorAction SilentlyContinue. A locked or ACL-denied file under lib\ therefore produced
        # "removed the payload, kept ...\logs" at CHANGE level, exit 0, with a SYSTEM-executed
        # script tree still on disk. Measure it instead of asserting it.
        $survived = @()
        foreach ($i in (Get-PMPayloadItems)) {
            $item = Join-Path $Root $i
            if (-not (Test-Path -LiteralPath $item)) { continue }
            Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $item) { $survived += $i }
        }
        $r.Removed  = ($survived.Count -eq 0)
        $r.KeptLogs = $hadLogs
        $r.Detail   = if ($survived.Count) { "could not remove: $($survived -join ', ')" }
                      elseif ($hadLogs)    { "removed the payload, kept $logsDir" }
                      else                 { 'removed the payload; there was no logs directory to keep' }
        return $r
    }

    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    $r.Removed = -not (Test-Path -LiteralPath $Root)
    $r.Detail  = if ($r.Removed) { "removed $Root (run history included)" }
                 else { "could not fully remove $Root" }
    return $r
}
