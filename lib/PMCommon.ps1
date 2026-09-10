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
    $segments = @(($full -split '\\').Where({ $_ }))
    if ($segments.Count -and $segments[0] -match '^[A-Za-z]:$') { $segments = @($segments | Select-Object -Skip 1) }
    if ($segments.Count -lt $MinDepth) { return $false }
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
    $trusted = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20', 'S-1-5-32-544', 'S-1-5-32-549', 'S-1-3-0')
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

$script:PMReadErrors = @()          # anything unreadable: partial coverage
$script:PMCriticalReadErrors = @()  # a read the module said its ANSWER depends on

function Clear-PMReadErrors { $script:PMReadErrors = @(); $script:PMCriticalReadErrors = @() }
function Get-PMReadErrorCount { @($script:PMReadErrors).Count }
function Get-PMCriticalReadErrorCount { @($script:PMCriticalReadErrors).Count }
function Get-PMReadErrorSample {
    $e = @($script:PMCriticalReadErrors) + @($script:PMReadErrors)
    if (-not $e.Count) { return '' }
    return [string]$e[0].Exception.Message
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
    foreach ($e in @($script:PMCriticalReadErrors) + @($script:PMReadErrors)) {
        $m = [string]$e.Exception.Message
        if ($m -and -not $seen.Contains($m)) { $seen.Add($m) }
        if ($seen.Count -ge $Max) { break }
    }
    return $seen.ToArray()
}

function Add-PMReadError {
    param($Errors, [switch]$Critical)
    if (-not $Errors) { return }
    $script:PMReadErrors += @($Errors)
    if ($Critical) { $script:PMCriticalReadErrors += @($Errors) }
}

function Get-PMChildDirectory {
    param([Parameter(Mandatory)][string]$Path, [switch]$Critical)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $ev = $null
    $r = @(Get-ChildItem -LiteralPath $Path -Force -Directory -ErrorAction SilentlyContinue -ErrorVariable ev)
    Add-PMReadError -Errors $ev -Critical:$Critical
    return $r
}

function Get-PMChildFile {
    param([Parameter(Mandatory)][string]$Path, [string]$Filter = '*', [switch]$Recurse, [switch]$Critical)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $ev = $null
    $r = @(Get-ChildItem -LiteralPath $Path -Force -File -Filter $Filter -Recurse:$Recurse -ErrorAction SilentlyContinue -ErrorVariable ev)
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

function Get-PMPathSize {
    <#
        Reads .Length off the enumeration's own WIN32_FIND_DATA rather than re-stat'ing every
        file: measured 25 ms against 78 ms for Get-ChildItem -Recurse | Measure-Object on a real
        868-file directory. At 13,341 directories that is ~6 minutes instead of ~17.

        It walks directories ITSELF instead of using AllDirectories, for a correctness reason that
        cost a regression to learn: DirectoryInfo.EnumerateFiles(AllDirectories) FOLLOWS reparse
        points, while Get-ChildItem -Recurse and Remove-Item -Recurse do not. Using it meant a
        junction in TEMP had its target's whole tree counted, so the report's headline figure and
        the "removed N GB" line were inflated by a tree that was never enumerated and never
        deleted. Size must measure the same bytes deletion will actually free.

        It also RECORDS what it could not read. It used to be the one reader that swallowed access
        errors, which is the exact "silence looks like emptiness" failure the rest of this file
        exists to prevent.
    #>
    param([Parameter(Mandatory)][string]$Path, [switch]$Critical)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }

    # A file is a legitimate thing to ask the size of - plex hands us individual .tmp files.
    # DirectoryInfo on a file used to throw into the catch and report 0 bytes plus a bogus read
    # error, which on a -Critical path would flip the whole module to unverified.
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not ($item.Attributes -band [IO.FileAttributes]::Directory)) { return [int64]$item.Length }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return [int64]0 }
    } catch {
        Add-PMReadError -Errors $_ -Critical:$Critical
        return [int64]0
    }

    $total = [int64]0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo($dir)
            foreach ($f in $di.EnumerateFiles()) { $total += [int64]$f.Length }
            foreach ($sub in $di.EnumerateDirectories()) {
                # Do not descend a junction or symlink: neither will the deletion.
                if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($sub.FullName)
            }
        } catch {
            # One unreadable subtree must not abandon the rest of the count, and must not pass
            # silently either. Continue rather than break, so the number is as complete as it can
            # be and the caller still learns it is incomplete.
            Add-PMReadError -Errors $_ -Critical:$Critical
        }
    }
    return $total
}

function Get-PMNewestWriteUtc {
    <#
        The newest LastWriteTimeUtc of any file anywhere under $Path.

        A directory's own mtime is not the age of its contents. Windows updates it only when
        entries are added to or removed from THAT directory, not when a file deeper in the tree is
        written. Measured on a live agent session directory: the root said 06:01 while the newest
        file inside said 14:29, an 8.5 hour lag on a session that was actively running.

        Any rule that deletes "directories older than N days" by directory mtime will therefore
        eventually delete something that is still in use. That is survivable while a module only
        reports, and not survivable once it acts.

        -NewerThanUtc lets the caller stop the walk the moment it finds anything newer, which is
        what keeps this cheap: an active directory exits after one file, and only genuinely idle
        directories are walked in full.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [datetime]$NewerThanUtc = [datetime]::MinValue,
        [switch]$Critical
    )
    $newest = [datetime]::MinValue
    $blind  = $false        # did ANY read fail? see the end of the function for why it decides the answer
    # The early exit below only means anything when the caller gave us a cutoff to beat. With the
    # default MinValue EVERY file beats it, so this returned after the first file it happened to
    # enumerate - not the newest, which is the one thing the function is named for. Production
    # always passes a cutoff, so only callers that omitted it were getting the wrong answer.
    $canExitEarly = ($NewerThanUtc -gt [datetime]::MinValue)
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo($dir)
            foreach ($f in $di.EnumerateFiles()) {
                if ($f.LastWriteTimeUtc -gt $newest) { $newest = $f.LastWriteTimeUtc }
                # Safe to leave without the $blind check: we already know something in here is
                # newer than the cutoff, so the answer is "active", which is the sparing answer.
                if ($canExitEarly -and $newest -gt $NewerThanUtc) { return $newest }
            }
            foreach ($sub in $di.EnumerateDirectories()) {
                if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($sub.FullName)
            }
        } catch {
            Add-PMReadError -Errors $_ -Critical:$Critical
            $blind = $true
        }
    }
    if ($blind) {
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
    if ($newest -eq [datetime]::MinValue) {
        try { $newest = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).LastWriteTimeUtc } catch {}
    }
    return $newest
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
        $r = $r -replace '(?i)%USERPROFILE%', ($UserProfile -replace '\$', '$$$$')
        $r = $r -replace '(?i)%LOCALAPPDATA%', ($UserProfile + '\AppData\Local')
        $r = $r -replace '(?i)%APPDATA%', ($UserProfile + '\AppData\Roaming')
    }
    $r = [Environment]::ExpandEnvironmentVariables($r)
    if ($r -match '%[A-Za-z_]+%') { return '' }   # unresolved token: refuse rather than guess
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
    if (-not (Test-PMPathSafe -Path $Path -Roots $Roots -MinDepth $MinDepth)) {
        return @{ Removed = $false; Skipped = $true; Reason = 'refused by path guard'; Bytes = [int64]0 }
    }
    # The SECOND, independent condition. $Roots above is supplied by the module at run time, so on
    # its own it is self-certification: a module that computes the wrong root gets to delete there.
    # $DeclaredRoots comes from module.psd1 via the dispatcher and the module cannot influence it.
    # Fail CLOSED. Reading this as "no declared roots means no restriction" would make the
    # independent half of the guard vanish exactly when a caller forgot to supply it.
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

function Get-PMRemovalBucket {
    <#
        Map a Remove-PMPath result Reason to the bucket a module's Repair counts it in:
        'vetoed' (the guard refused), 'gone' (it vanished between Test and Repair), or
        'locked' (anything else, e.g. a partial delete that then threw).

        Here rather than copied into each module because the copies DRIFTED. Three of the four
        shipped modules never gained an arm for 'no declared roots supplied', so that refusal
        fell through to their default bucket - locked - and since Ok is computed as
        ($vetoed -eq 0), a run in which the guard refused every single target would still have
        returned Ok = $true and rendered a green "Cleaned" badge. That is the exact failure the
        comment above each of those switches claims was already fixed.

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
