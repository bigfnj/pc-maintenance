# Backlog

Open work, in the order I would do it, with the reasoning for that order rather than just a list.
Everything here came out of the 2026-09-09 audit round unless noted.

## How to work this list

**Coverage before change, latent-safety before capability, design decisions last.**

Items 1 through 4 are closed, and the order held. The module tests (1) had to come first because
every other change touched code that nothing verified behaviourally, and writing them found two
real traps on their own. The path-pattern gaps (2) were then a single batch in a single file with
one test shape, closed before a new module made them reachable rather than after. 3 shipped; 4
was closed as won't-fix once the threat model was pinned down.

Round 1 ended by saying nothing still open was reachable through the four shipped modules. Round 2
(item 6) found that this was false: a junction at the project-slug level made `agent-scratchpads`
delete outside its declared root, and item 4 had closed that very case as unreachable. The claim
is worth keeping visible precisely because it was wrong - "not reachable today" is a statement
about the paths someone thought to check.

---

## 1. ~~Three of the four modules have no behavioural tests~~ DONE 2026-09-09

Shipped. Each of the three now runs against a real fixture tree in TEMP with controlled
timestamps, and the tests assert exactly which paths come back AND which do not. Both
source-text greps are retired: the `Count` / capped-`Items` grep became a 30-orphan fixture
asserting `Count` 30 with `Items` capped at 25, and the `-Critical` grep became four tests that
point each module at a directory which exists but cannot be listed and assert
`Get-PMCriticalReadErrorCount` is non-zero. The old grep was satisfied by the literal string
appearing anywhere in the file, including inside a comment.

Ten selection conditions mutation-tested individually. 111 tests -> 137.

Two traps found while writing them, both worth keeping:

- **`fl` is the built-in alias for `Format-List`, and PowerShell resolves aliases BEFORE
  functions.** A fixture helper named `Fl` silently formatted a string instead of creating a
  file: no error, no file, and the formatter's output leaked into the fixture's return value.
  Renamed to `Add-FixtureDir` / `Add-FixtureFile` with the reason in a comment.
- **A test that could not fail.** The first `.tmpx` case survived mutating `EndsWith('.tmp')` to
  a loose match, because `weird.bif.tmpx` strips to `weird.bif.` with a trailing dot and the
  pairing rule rejects it anyway. The case that actually discriminates is `chunk.tmp.bif` beside
  a real `chunk.tmp`: a loose rule strips four characters, finds the partner present, and deletes
  a finished preview. Mutation testing is what told the difference. Reading the test did not.

Cleanup also needs care: a Deny ACE is how you make a directory that EXISTS but cannot be LISTED,
and removing it again must go through `icacls /reset`, not `Set-Acl`, which wants
SeSecurityPrivilege and strands an undeletable directory behind it.

## 2. ~~The path guard reads broader than it is~~ DONE 2026-09-09

All four gaps closed, each pattern mutation-tested individually, plus five positive controls so
an over-broad pattern cannot pass by forbidding everything while the tool silently stops deleting.
Verified end to end with a real `Uninstall -RemoveFiles` then `Install`, because the uninstaller
is the only caller whose `-Path` is operator input rather than an enumerated `.FullName`, and a
new pattern catching `C:\ProgramData\...` would not break a module, it would make uninstall
refuse to run.

**The `MinDepth` weakness on shares is now unreachable rather than fixed.**
`\\server\share\folder` already counts as three segments, so `MinDepth = 3` never protected a
share root. Forbidding UNC outright means nothing can reach that path. If a future module ever
needs to sweep a share it has to delete the UNC pattern deliberately, and **that** is the moment
to fix the segment counting, not before.

⚠ One of the four patterns could never fire, which is the finding worth keeping. `'^\\\\[\?\.]\\'`
was written to catch the `\\?\` long-path prefix, but every path it matched already began `\\`
and was caught by the UNC rule one line above. The suite was green with it present and green with
it removed; only the mutation run exposed it. A guard no input can reach is worse than no guard,
because it reads like coverage in review and nobody looks again. Folded into the UNC rule with
the reasoning in a comment.

## 3. ~~A liveness check so `agent-scratchpads` can act~~ DONE 2026-09-09

Shipped, and the entry that used to sit here was **wrong**, which is worth keeping rather than
deleting. It said the module "needs a real liveness check, not a longer timeout". Two things
changed that:

- **Nothing in a scratchpad is non-regenerable.** The durable session record (transcript, and any
  persisted large tool output) lives under `~\.claude\projects\`, not in Temp. The worst case on
  resuming a very old session is regenerating a throwaway script.
- **The real bug was never liveness, it was the clock.** Windows updates a directory's mtime only
  when *its own* entries change, so a session root's timestamp is effectively its creation time.
  Measured on a live session: root 06:01, newest file inside 14:29. An mtime rule really would
  have deleted in-flight work, but the fix is to take the age from the newest file inside, not to
  add a handle check.

Now `AutoApply = $true` with a 14-day floor, taking age from the newest file, matching only
session-GUID directories, and refusing `bundled-skills` outright. Currently identifies 933
sessions and 3.22 GB. Four rules mutation-tested.

⚠ The `bundled-skills` guard was **not provable at first**, and the reason is a trap worth
remembering: the fixture path went through a Python replacement string where a backslash-digit
sequence was eaten as an escape, so the directory the test claimed to create never existed and
the test passed no matter what. The patch script asserted its *anchor* matched; it did not
verify the *replacement* landed. Assert both.

## 4. ~~TOCTOU inside `Remove-PMPath`~~ WON'T FIX 2026-09-09 - **but case C was REOPENED and FIXED, see below**

> ⚠ **Read this before trusting anything in this item.** The analysis below concluded case C was
> unreachable because "no module can enumerate" a path through a junction. That is **false**, and
> a round-2 audit reproduced the deletion. `agent-scratchpads` enumerates in two NON-recursive
> passes, so the `-Recurse` measurement that the conclusion rests on never applied to it. A
> junction at the project-slug level under `Temp\claude` produced a candidate that passed both
> halves of the path guard, and `Remove-Item -Recurse` destroyed the junction's target while the
> link survived. Fixed by `Test-PMPathTraversesLink`, which is the same "cheap mitigation" this
> item describes at the bottom - it was right about the remedy and wrong about the urgency.
>
> The residual TOCTOU *race* (swapping a directory between the check and `Remove-Item`) is still
> WON'T FIX, and the reasoning below still holds for it. What changed is that the case no longer
> needs an attacker at all: an ordinary junction someone created for their own convenience was
> enough.

Measured on this build rather than assumed, because the original entry overstated it:

| case | what was tried | victim |
|---|---|---|
| A | junction nested inside a tree we `Remove-Item -Recurse` | **survived** |
| B | the swept path itself swapped for a junction after the guard ran | **survived** |
| C | deleting a path that TRAVERSES a junction to a real file | **destroyed** |

`Remove-Item -Recurse` deletes the reparse point, not the target, which kills the textbook attack.
Only case C works, and reaching it needs a module to hand `Remove-PMPath` a path that goes through
a link. `Get-ChildItem -Recurse` does not descend junctions (measured: zero files found under a
directory containing one), so no module can enumerate one. **-- This sentence is the error.**
The measurement was sound; the inference was not. `agent-scratchpads` never calls `-Recurse`:
it makes two separate non-recursive listings, and a non-recursive listing of a junction DOES
return the target's children, with the link path preserved as their `.FullName` prefix. That leaves a single route: the one
module that deletes individual FILES rather than directories, with an attacker swapping an
intermediate directory between Test and Repair.

**Closed because the deployment is a single-user workstation whose interactive user is the
administrator.** The distinction that decided it is worth keeping, because it is NOT the same
answer for every finding in this project:

- **The ProgramData ACL hole was worth fixing** even here. Non-elevated code running as the user
  (a compromised app, a malicious dependency) could write to a default-ACL ProgramData directory,
  and the dispatcher dot-sources every `.ps1` there as SYSTEM. That is arbitrary **code execution
  as SYSTEM**, which is strictly more than the user has without elevating.
- **This one is not.** The same attacker gets the deletion of *one file* whose leaf name matches a
  `.tmp` being swept. It grants no code execution, and non-elevated code can already delete
  anything the user can. The marginal gain is destroying a file only SYSTEM could delete, which is
  a denial-of-service primitive, not an escalation.

Spending twenty lines and a test to narrow a window that buys an attacker nothing they want is the
kind of risk-shaped work that looks diligent and is not.

**Reopen this if any of these become true:**

- the interactive user stops being an administrator, so SYSTEM becomes a boundary worth defending
- the machine gains a second, less-trusted user
- a module starts deleting individual files somewhere a *different* user can write
- it is deployed anywhere but this workstation

The cheap mitigation, if it ever is reopened: walk from the target up to the declared root
asserting nothing is a reparse point, immediately before `Remove-Item`. Narrows the window to
microseconds in about twenty lines of plain PowerShell without reaching for P/Invoke. It does not
close it; closing it properly means deleting by handle opened with `FILE_FLAG_OPEN_REPARSE_POINT`.

---

## 5. ~~The five smaller items~~ DONE 2026-09-09

All five shipped, each mutation-tested. Kept here rather than deleted because two of them turned
out to be worth more than their size suggested.

- **`Format-PMBytes`** gained a bytes tier and a TB tier. Under 512 B it printed `0 KB`, which in
  a report is indistinguishable from a module that found nothing, and 2 TB printed
  `2,048.00 GB`. It had no tests at all; it now has ten.
- **Log retention** became `Remove-PMOldLogs`, fenced the same way `Remove-PMOldReports` is,
  because both delete outside the path guard. The three inline pipelines omitted `-File`, so a
  directory under `logs\` matched and `Remove-Item -Force` without `-Recurse` then failed
  silently under `-EA SilentlyContinue` - a no-op that read, in the transcript, exactly like
  retention working. The age sweep had no name filter at all. `MaxAgeDays = 0` now means **no**
  age sweep rather than being floored to 1, because flooring it would read as safety and behave
  as "delete everything older than yesterday".
- **`Get-PMInteractiveUserSid`'s comment** now matches its code, the object carries `Inferred`,
  the run record carries `interactiveUser`, and the report prints an INFERRED USER notice. The
  deletion gate was always right; only the description was wrong. Testing this needed a trick
  worth keeping: PowerShell resolves commands through the **caller's** scope chain and puts
  functions ahead of cmdlets, so defining `function Get-CimInstance { throw }` inside the test
  body forces the resolver past both observation sources and down to the registry fallback.
  Without that, the confirmed branch is the only one a test on this machine could ever reach.
- **The two dead accessors** were not deleted, they were used. Both hard-coded lists are now
  pinned by joined comparison, so order is pinned too. The per-pattern tests catch a pattern that
  stops **working**; these catch one that quietly stops **existing**.
- **`-KeepLogs`** works and says what it did. The removal moved into `Remove-PMPayloadFiles` so it
  can be tested against a fixture without elevating or unregistering the real task, and the
  deployed-item list moved into one place shared with the installer.

⚠ **And the one that was not on the list.** Writing the test for the uninstaller's guard found a
real hole. `MinDepth` counted the DRIVE LETTER as a segment, so `MinDepth 2` meant "drive plus one
directory" and

```
Uninstall-PcMaintenance.ps1 -PayloadRoot C:\ProgramData -RemoveFiles
```

passed the guard. `-PayloadRoot` is the only operator-supplied path in the project and the only
caller not handed an enumerated `.FullName`, which is exactly why it carries a guard at all.
`MinDepth` now counts directories with the drive excluded and the default moved 3 -> 2 in the same
change, so every module caller counts the same segments it did before and only the uninstaller
gets stricter. This is the fifth time on this project that writing a test for something small
found something that was not small.

## 6. Four parallel audits, 2026-09-09 (round 2)

What shipped in that round is in the commit; this is what it deliberately left. The ordering
principle is unchanged - coverage before change, latent-safety before capability, design
decisions last - but round 2 added one: **a closed item is not evidence.** Item 4 below was
closed WON'T FIX on reasoning that turned out to be false, and it read as settled for exactly as
long as nobody re-derived it.

### 6a. ~~The re-enumeration between Test and Repair costs a second full sizing pass~~ DONE

**Measured, HIGH on cost, zero on safety.** Repair re-derives candidates, and the candidates
function measures `Bytes` inline, so every path is sized twice on an apply run. The comments
claiming otherwise are fixed; the cost is not. At the documented vs-installer peak (13,341
directories, ~6 min per sizing pass) that is roughly **+6 minutes per apply run**; at today's
state it is +13.2 s for vs and +2.4 s for agent-scratchpads.

**Keep the re-enumeration.** It re-applies every selection rule at delete time, which is a real
safety property - a directory that became active between phases is spared - and item 4's threat
model assumes that window exists. Only the *sizing* is waste. The fix is an in-memory path→bytes
map on `$ctx` for the Repair phase, never serialized, with Repair measuring only paths it newly
selected.

### 6b. ~~The vs payload-cache probe is the single largest measured cost, and finds nothing~~ DONE

**Measured 13,237 ms, twice per apply run, zero hits.** It calls `Get-PMChildDirectory` on every
non-8.3-named TEMP directory older than 24h - 6,402 of them on this box - and reached the `.vsix`
stage zero times. The payload cache is *one* directory with a stable random name: cache its
resolved path and re-probe only that, falling back to the full sweep when the cached path stops
qualifying.

### 6c. ~~Cheaper existence checks in the two shared readers~~ DONE

`Test-Path -LiteralPath` measured **3,398 ms** over 6,402 paths against **280 ms** for
`[IO.Directory]::Exists` - 12x, and it scales with every future per-item module. The guard itself
must stay: it is what separates "path absent, return empty quietly" from "path present but
unlistable, record a read error". The native call preserves that distinction exactly.

### 6d. ~~Two walks per candidate that could be one~~ DONE

`Get-PMNewestWriteUtc` and `Get-PMPathSize` are byte-for-byte the same traversal. An *idle*
candidate gets no early exit from the first, so both run in full - and with 6a that is four full
walks of the idle set per apply run where one per phase would do. A fused walk returning
`(NewestUtc, Bytes)` keeps the `-NewerThanUtc` early exit: bail as soon as something beats the
cutoff and discard the partial size, since that candidate is skipped anyway.

Also `plex-bif-orphans` materialises all 47,802 `FileInfo` plus a parallel HashSet (~35 MB), twice
per apply run. Keep the re-walk - it re-verifies the `.bif` partner at delete time, which is the
module's whole rule - and retain names rather than `FileInfo`.

### 6a-6d closed 2026-09-10: measured 26.9s -> 15.6s on a report-only run

Four items, one theme: the cost was never the filesystem, it was a cmdlet per candidate and a
walk repeated for data already in hand. Each was measured before and after rather than reasoned
about, and two designs the audit proposed were rejected on measurement.

| item | change | measured |
|---|---|---|
| 6c | `Test-Path` -> `[IO.Directory]::Exists` in the two shared readers | 3,398 ms -> 280 ms over 6,405 paths (12x) |
| 6b | native `EnumerateDirectories` + break, replacing a materialising `Get-PMChildDirectory` | 12,137 ms -> 458 ms (26x), same result |
| 6b | one branched enumeration of the TEMP root where there were two | ~335 ms a pass, and fixes a `-Critical` asymmetry |
| 6d | `Get-PMTreeStat` - one traversal for size AND age | removes a full second walk per selected candidate |
| 6a | Test's measurements handed to Repair via `$ctx.KnownSizes` | removes the re-measure of every candidate on an apply run |

**Two proposals were measured and rejected**, which is the part worth keeping:

- *An mtime horizon on the payload-cache probe.* Useless here: 100% of the probe set was written
  within a year and 90% within 180 days, so no cutoff short of a dangerous one helps.
- *A persisted cache of the discovered payload-cache path*, which the audit recommended. Made
  unnecessary by the native probe, and it would have bought a staleness window in which a newly
  created cache goes unseen, plus state to keep correct.

**What deliberately did NOT change.** Repair still re-derives its candidate list. Re-running every
selection rule at delete time is what spares a directory that became active between the phases,
and item 4's threat model assumes that window exists. Only the *measuring* was waste. Likewise
`Get-PMTreeStat` holds no root policy, because the two callers genuinely disagree there and 6g is
still open - a performance change is the wrong place to alter what gets selected.

**Tests 220 -> 235.** Eight differential cases pin the fused walker against the behaviour it
replaced (full sum, deepest-file age, early-exit incompleteness, and the four root kinds - file,
missing, reparse-point, unreadable), because that is where this kind of refactor drifts without
failing loudly. Six cover the size map, including an end-to-end run asserting it never reaches the
run JSON, where an uncapped field would defeat the reason `Items` is capped at 25.

And one gap the audit had not spotted: **nothing in the suite had ever run the dispatcher with
`-Apply`**. The one path that actually deletes was covered only indirectly, and 6a changed how its
byte total is computed. There is now a real fixture, a real apply run, and real deletion - with a
deliberately wrong size in the map, since that is the only way to distinguish a cache hit from a
silent fall-back to re-measuring.

### 6e. ~~The read-error accumulator is uncapped and quadratic~~ DONE

`Add-PMReadError` appends with `+=` inside per-directory walk loops and **nothing ever consumes
the retained `ErrorRecord` objects** - only the counts, one sample and ≤10 deduped messages are
read. On a tree where every read fails, 13,341 directories is ~89 M element copies (the same
shape measured at 6,733 ms), and each record carries an `InvocationInfo` at roughly 1-3 KB, so
100k of them is 100-300 MB held in a SYSTEM process. A cap of ~200 retained plus a monotonic
counter costs nothing. Normal runs are unaffected - current logs show `readErrors: 1`.

### 6f. ~~Test fixtures stranded on the throw path, and they are un-deletable~~ DONE

Eight sites create and populate a fixture *before* the `try` whose `finally` removes it, so
anything throwing in between strands it. Worse than an ordinary temp leak: `New-PMFixtureRoot`
calls `Set-PMPayloadAcl` when elevated, so the stranded directory grants Users read-only and
**the non-elevated user cannot delete it** - and its name matches nothing in `stale-app-temp`'s
allowlist, so this tool will never clean it up either. Move the construction inside the `try`.
Related: `icacls /reset` is invoked bare in a `finally`; if it throws, the Deny-ACE'd directory
survives.

### 6g. ~~`Get-PMNewestWriteUtc` does not reparse-guard its ROOT push~~ DONE

`Get-PMPathSize` checks the top-level attribute and returns 0 for a reparse-point root;
`Get-PMNewestWriteUtc` pushes `$Path` unconditionally and only checks *sub*directories. So for a
session directory that is itself a junction, age is measured across the target's whole tree while
size reports 0 and `Remove-Item` would delete only the link - three readers describing three
different things. Now that `Test-PMPathTraversesLink` blocks the dangerous case this is a
consistency defect rather than a hole, but the stated invariant is that measurement matches what
deletion frees.

### 6h. ~~Two numbers share a word and count different things~~ DONE

`summary.found` counts every module that found something (`reported` **and** `applied`); the HTML
"Found" tile counts only `reported`. On an apply run where all three permitted modules act, the
JSON says `found: 3` and the report says Found 0 / Cleaned 3. Same for `summary.partial` (total
read errors) versus the "Couldn't read" tile (distinct messages, capped at 10).

**The "every number opens" promise is intact** - the tile renders `$rows.Count`, so it always
expands to exactly what it counted. What is overstated is the README's "the two can never
disagree": both derive from one object, but they derive *different things* under one label. The
honest fix is naming, not logic, and it should not change the JSON schema.

### 6i. ~~Guarantees the README states more strongly than the code provides~~ DONE 2026-09-10

Three, all currently unreachable through the four shipped modules, all worth closing the gap
between prose and behaviour rather than softening the prose:

- **Gate 3 is opt-in.** README presents "the interactive user was confirmed logged on" as
  unconditional; `Test-PMActingUserConfirmed` returns `$true` immediately when a module omits
  `RequiresUserSid` - while the dispatcher still expands that module's roots against the
  *inferred* profile, which makes the path guard agree. All four shipped modules declare it.
- **`DeclaredRoots` is module-mediated.** README says the dispatcher "hands it to `Remove-PMPath`
  so the module cannot influence it". It hands it to the *module*, which passes it on; and
  `$Context` is a hashtable shared by reference across both phases, so `Test` can mutate it for
  `Repair`. The dispatcher genuinely owns the *value* (`$info` never enters `$ctx`, and
  `Import-PowerShellDataFile` cannot execute code) - it does not own the *channel*.
- **`Remove-PMPath` enforces only gate 4.** It knows nothing about `-Apply` or `AutoApply`, and
  nothing stops a module calling it from `Test-PMModule`. Gates 1-3 live entirely in the
  dispatcher.

### 6i closed by tightening the code, not the prose

All three were the same shape: a gate living in the dispatcher's control flow while the README
described it as a property of the deletion itself. Moved to the primitive.

- **Gate 3 is now unconditional.** `Test-PMActingUserConfirmed` returned `$true` immediately for
  a module that omitted `RequiresUserSid` - while the dispatcher went on expanding that same
  module's declared roots against the INFERRED profile. Forgetting the flag therefore bought a
  guessed stranger's profile substituted into the roots, which is what then makes the path guard
  agree. Nobody deletes for a guessed user now. It costs a module that genuinely needs no user
  its sweep at the logon screen; all four shipped modules declare the flag, so nothing changes
  today.
- **Declared roots belong to the dispatcher again.** `Invoke-PMModulePhase` stamps them onto the
  phase after dot-sourcing the module, and `Remove-PMPath` reads that stamp instead of its own
  argument - so passing `@('C:\')` widens nothing. Previously the dispatcher put them on a
  context hashtable, the module read them off and passed them back, so both halves of the guard
  arrived module-supplied - and `$Context` is shared by reference across phases, so `Test` could
  even mutate them for `Repair`.
- **`Remove-PMPath` refuses in the Test phase, and on a run without `-Apply`.** Nothing
  previously stopped a module deleting from `Test-PMModule`, before any gate had been evaluated.

**Honest about the boundary.** A dot-sourced child scope is not one, and a module determined to
subvert this can still assign to the same variables. What changed is that the safe path is the
DEFAULT: no module widens its roots or deletes in the wrong phase by accident, by copying a bad
example, or by getting a parameter wrong. Deliberate subversion is a different threat, already
answered by the payload ACL.

Five tests, two of them positive controls - three refusals prove nothing if the tool can no
longer delete, and a gate firing outside a module phase would break both this suite and the
uninstaller while adding no safety. One existing test had to be INVERTED, which is the honest
marker that this was a behaviour change and not a tidy-up.

### 6j. ~~`Test-PMPayloadSecure` has three gaps in the check the README calls load-bearing~~ DONE

It trusts `S-1-5-19`/`S-1-5-20` (LOCAL SERVICE / NETWORK SERVICE) as "already privileged enough",
which is untrue - they are restricted accounts strictly below SYSTEM, so a write ACE for
NETWORK SERVICE is a real escalation path it would approve. It reads `$acl.Access` only and never
checks the **owner**, who always holds implicit `WRITE_DAC` - so a hand-copied payload *owned* by
a standard user passes with a perfectly locked DACL. And it checks the payload root only, while
every `.ps1` under `lib\` is dot-sourced twice per run, so a permissive ACE placed directly on
`lib\` with inheritance disabled is invisible to it.

### 6k. ~~Smaller, each cheap~~ MOSTLY DONE

- **`Get-PMDownloadsPath` trusts a user-writable registry value.** Under SYSTEM that is a
  file-creation primitive into any existing directory. Bounded - the filename is fixed and
  `Remove-PMOldReports` can only match that same pattern, so no unintended deletion - and the
  existing `system32` re-point covers only one case, not `C:\Windows\Temp` or `C:\ProgramData`.
- **8.3 short names survive `[IO.Path]::GetFullPath`.** `C:\PROGRA~1\x` never matches the
  `Program Files` pattern. Unreachable today because every target comes from an enumerated
  `.FullName`; it bites the first time a module takes a path from config or an operator.
  Normalising via `(Get-Item -LiteralPath $Path).FullName` before the regex sweep closes it.
  Everything else adversarial was checked and is genuinely handled: trailing dots and spaces,
  interior dots, forward slashes, `..`, drive-relative `C:foo`, `\\?\`, and ADS (which throws and
  fails closed under 5.1 - note .NET Core would *not* throw).
- **`\??\` is not covered by the `^\\\\` rule**, whose comment claims the device prefix. Single
  leading backslash, so it passes the sweep and MinDepth. Harmless (it can match no declared root
  and Win32 refuses to open it) but the comment over-promises.
- **`Expand-PMRoot` escapes `$` in one of three branches.** `%LOCALAPPDATA%` and `%APPDATA%`
  concatenate raw, so `$&` in a profile path is a substitution token. Fails closed - the result
  can only become a nonexistent root - and the fix already exists one line above.
- **The unresolved-token check misses digits.** `'%[A-Za-z_]+%'` does not match `%FOO2%`, so it is
  returned literally instead of refused. Still fails closed; `%[^%]+%` is exact.
- **Two of seven `AppData\Roaming` credential alternatives are fully subsumed** by the `.ssh` and
  `.aws` rules below them, so the two tests naming them pass either way - coverage that
  discriminates nothing, which is the condition the last mutation run existed to catch.
- **Two tests are narrower than the claims they pin.** The "no external fetch" test would miss a
  protocol-relative `//cdn`, a relative `<link rel=stylesheet>`, or a non-http `@font-face`; the
  escaping test exercises only `items[].path`, while `detail`, `readErrorMessages` and `id` are
  escaped in code and pinned by nothing. Both claims are currently TRUE - verified exhaustively
  this round - so this is regression cover, not a live defect.
- **Six of nine context keys are never read** by anything, tests included: `UserSid`,
  `PayloadRoot`, `ModuleRoot`, `LibDir`, `RunId`, `IsInteractiveUserLoggedIn`. The last is the
  one to act on: it duplicates a fact the dispatcher has *already* acted on, so a module author
  could reasonably read it as an invitation to make the decision again, locally.
- **`-WhatIfOnly` is production-dead.** Only a test passes it. Either wire it or delete it; a
  parameter that exists to prevent drift, and has itself drifted out of use, is the worst of both.
- **`Get-PMChildFile -Filter` is unused and is the documented trap** (Win32 `-Filter` matches
  `.tmpx` via 8.3 legacy, the bug item 1 mutation-tested). Delete it or move the warning onto the
  parameter. Same shape: `Remove-PMPath -MinDepth` and `Get-PMReadErrorMessages -Max` are never
  passed by any caller, so three tuning knobs in the deletion path are only ever exercised at
  their defaults.

### 6e-6k closed 2026-09-10

Tests 235 -> 254. What each change actually was is in the commits; this records the parts that
are only obvious once you have been bitten.

**Every one of the three "fixes" below broke something on the way in**, which is the argument
for the differential tests rather than for cleverness:

- Capping the read-error accumulator (6e) took out **eight tests at once**. `@()` around an
  EMPTY generic `List` throws *"Argument types do not match"* - harmless while the collection
  was a plain array, fatal the moment it became `List[object]`, and it hit every accessor that
  merely wanted to read an error message.
- The 6g test was written with `(Get-Item $link -Force).LastWriteTimeUtc = $x`, which stamps
  the **target** under 5.1 and the **link** under 7. It passed under 7 and failed under 5.1 -
  the version the scheduled task runs. The production code was right the whole time.
- The 6j `lib\` test was a permanent SKIP because setting inheritance protection and adding an
  ACE in two separate `Set-Acl` calls needs `SeSecurityPrivilege` on the second. One `Set-Acl`
  doing both works. A skipping test is the "verifies nothing" outcome this suite exists to avoid.

**On 8.3 short names (6k).** The audit said `GetFullPath` does not expand them. Measured, it
expands *some*: `C:\PROGRA~1\__nope__` comes back long, `C:\PROGRA~1\x` does not, under both 5.1
and 7. A guard that depends on which one it is handed is not a guard, so `Remove-PMPath` now
resolves to the long form itself before any check sees the path. No fixture was possible - 8.3
generation is disabled for new files on this volume - so it is proven against a real legacy name
without ever pointing a delete at a system directory.

**Deliberately left, with reasons:**

- **`\??\` is still uncovered by the `^\\\\` rule.** It cannot match any declared root and Win32
  refuses to open it, so it fails closed twice over. Recorded rather than patched, because a
  rule no input can reach is the thing item 2 was about.
- **The two redundant `AppData\Roaming` credential alternatives stay.** The patterns are correct;
  what is weak is that the two tests naming them pass with the alternatives deleted. That is a
  test-coverage gap, not a guard gap.
- **The other five unused context keys stay** (`UserSid`, `PayloadRoot`, `ModuleRoot`, `LibDir`,
  `RunId`). Only `IsInteractiveUserLoggedIn` was removed, because it duplicated a gate the
  dispatcher had *already applied* and so invited a module to decide it again locally. The rest
  are plausible for a module that needs to write state, and cost nothing.
- **`-WhatIfOnly` stays** though no module passes it. design.md no longer claims it is
  load-bearing, which was the actual defect.

**6i is closed too** - see "6i closed by tightening the code, not the prose" above. This
paragraph used to say it was still open, describing three guarantees the README stated more
strongly than the code provided. It was already fixed by then: `Test-PMActingUserConfirmed`
ignores `RequiresUserSid`, `Invoke-PMModulePhase` stamps the roots, and `Remove-PMPath` enforces
gates 1-3. Left here rather than deleted because a backlog that quietly rewrites its own history
is worth less than one that says where it was wrong.

### 6l. The one that is a note, not a finding

`vs-installer-scratch` and `stale-app-temp` take age from the **directory's own `LastWriteTime`** -
precisely the measurement item 3 established is unreliable, and which `agent-scratchpads` was
rewritten to avoid. `stale-app-temp` is report-only so it can only mis-report. `vs-installer-scratch`
has `AutoApply = $true`, and its 24-hour floor plus the requirement for `setup.exe` **and**
`resources\app\ServiceHub` makes it safe in practice. Worth knowing before a fifth module copies
the pattern with a looser fingerprint.

---

## Decisions worth revisiting later, not bugs

- ~~**Should a weekly job speak when it finds nothing?**~~ **Closed 2026-09-09.** Moot in practice:
  `plex-bif-orphans` regenerates on every preview Plex builds, at a measured 100% recurrence, so a
  weekly report will essentially never be empty. The "always speaks becomes noise" failure needs a
  job that usually finds nothing, and this one does not.
- **Promoting entries out of `stale-app-temp`.** The right move is to graduate one application at
  a time into its own module once its behaviour has been watched long enough to state a mechanical
  rule for it. Flipping the whole allowlist to `AutoApply` would be trusting every entry at once,
  which is exactly what the two-tier design exists to prevent.
- **A third consumer of the module framework.** It is currently shared by copy with a sibling
  project. That is fine at two and starts costing at three; if a third appears, extracting the
  engine becomes worth doing rather than premature.

---

## 7. Four parallel audits, 2026-09-10 (round 3)

Same shape as round 2: four agents (dead code, non-operable code, leaks and performance,
cross-cutting and security) across this repo and scripts-utilities. Every item below reproduced
against the code. Items that did not reproduce were dropped rather than recorded.

Two were fixed the same day and are struck through. The rest are recorded with the measurement
that established them, so nobody has to re-derive it.

### 7a. ~~The junction guard was added to one delete site out of three~~ DONE 2026-09-10

`Test-PMPathTraversesLink` was wired into `Remove-PMPath` only. Two other recursive force-deletes
of operator-supplied paths - `Install-PcMaintenance.ps1:98` and `Remove-PMPayloadFiles -KeepLogs`
- called the LEXICAL half of the guard (`Test-PMPathSafe`) and never the filesystem half.
Reproduced end to end: with the payload root junctioned at a checkout, `Test-PMPathSafe` returned
`True`, the real `lib\` and `modules\` were destroyed, and the junction survived. Bit-for-bit
the agent-scratchpads signature, at two sites the original fix did not reach.

Both now guarded, with a regression test that was confirmed to FAIL without the fix (270 tests).
The installer checks per item and only when the destination exists, because the guard fails
CLOSED on a directory it cannot inspect - hoisting it above the loop would refuse every fresh
install.

**The lesson worth keeping:** the round-2 fix was correct and incomplete, and nothing detected
the gap for a day. When a guard is added to a call site, grep for the *other* call sites of the
dangerous operation, not for the callers of the guard.

### 7b. ~~`Test-PMPathSafe` spent 40% of its time on two convenience lines~~ DONE 2026-09-10

Measured over 14,000 candidates (whole function 3,834 ms): `.Where({...})` 523 ms and
`@($segments | Select-Object -Skip 1)` 1,021 ms, against 29 ms for the `GetFullPath` doing the
real work. Replaced with `String.Split` and an index: 34 ms. The guard runs twice per deletion,
so a 6,935-file sweep makes 13,870 calls. All 270 tests still pass.

### 7c. ~~A test that cannot fail~~ DONE 2026-09-10

`tests/Invoke-Tests.ps1:1661` - *"NewestUtc finds the deepest-written file, and equals
Get-PMNewestWriteUtc"*. The second conjunct cannot fail independently of the first:
`Get-PMNewestWriteUtc` is a two-line wrapper that calls the same `Get-PMTreeStat` the first
conjunct calls, and `Resolve-PMTreeAge` returns `$Stat.NewestUtc` verbatim for the tree the
fixture builds. The name promises agreement between two implementations; there is one.

### 7d. ~~`Get-PMNewestWriteUtc` is dead in production~~ DONE 2026-09-10

Zero production call sites; all 8 are in the test suite. Superseded by the fused
`Get-PMTreeStat` + `Resolve-PMTreeAge` under item 6d, and `agent-scratchpads/module.ps1:59` still
carries the comment "This used to call Get-PMNewestWriteUtc". It is now a test helper living in
shipped code that SYSTEM dot-sources. Interlocks with 7c: fixing that test removes the main
argument for keeping it. Either delete it and rewrite the 8 call sites against the two functions
it wraps, or move it into the test file.

### 7e. ~~`$RequiresUserSid` is mandatory, unused, and its docstring explains why it is kept~~ DONE 2026-09-10

`lib/PMManifest.ps1:63-72`. `Test-PMActingUserConfirmed` takes it `[Parameter(Mandatory)]` and
the entire body is `return $LoggedIn`. The docstring says it is "still taken so the reason can be
reported accurately" - but the only production caller sets a fixed `$holdBack` string that never
mentions it. The stated justification is not realised anywhere. Tests pin both values, so this is
a deliberate decision to re-take, not an oversight to patch.

### 7f. ~~Two tests report PASS where they mean SKIP~~ DONE 2026-09-10

`tests/Invoke-Tests.ps1:525-530` returns `$true` when its precondition is absent, counting as a
pass. The same file uses `return 'SKIP'` for the identical situation at `:2216`, and the `It`
docstring says *"a check that quietly reports success while doing nothing is the exact failure
this suite exists to catch, and the suite must not commit it itself."* Same shape at
`tests/Invoke-DeploymentSmoke.ps1:118-119`, where `catch { return $true }` passes "a real write
into lib\ is refused" on *any* exception, including a missing `lib\`.

### 7g. ~~Two tests assert the fail-open cast the production code was rewritten to avoid~~ DONE 2026-09-10

`tests/Invoke-Tests.ps1:162` and `:834` use `[bool](Import-PMModuleInfo ...)['AutoApply']`, which
is exactly what `Test-PMApplyAllowed` (`PMManifest.ps1:166-175`) was changed to stop doing. If a
psd1 ever said `AutoApply = 'false'`, `[bool]'false'` is `$true`: the test stays green while the
module has silently become report-only.

### 7h. ~~An all-locked repair renders a green "Cleaned" badge~~ DONE 2026-09-10

`modules/*/module.ps1` set `Ok = ($vetoed -eq 0)`. A Repair in which every delete was **locked**
rather than vetoed therefore returns `Ok = $true` -> status `applied` -> a green "Cleaned" badge
-> `summary.applied++` -> exit 0. Only the Detail string ("removed 0 of 940; 0 vetoed, 940
locked") is honest, and the comment directly above says *"Ok reflects what actually happened."*
Not demonstrated - exercising it needs `-Apply`, which the audit was not permitted to run - so
confirm before changing.

**Confirmed, then fixed.** Reproduced end to end with `-Apply` against a TEMP fixture, holding one
exclusive `FileStream` so `Remove-Item -Recurse` threw `IOException`: status `applied`, badge
`Role 'good' / Icon 'OK' / Word 'Cleaned'`, `summary.applied = 1`, `summary.bytes = 0`, process
exit **0**. Every hop in the chain the audit described was real.

`Get-PMRepairOutcome` (PMCommon, beside `Get-PMRemovalBucket` for the reason recorded there) now
maps counters to one of three outcomes, and **the dispatcher calls it** rather than trusting a
module-supplied boolean - a module's verdict on its own run is self-certification, the same
argument that made the declared roots the dispatcher's. Modules return `Attempted/Removed/Vetoed/
Locked/Gone`, which also land in the run JSON as `modules[].repair`. `applied` = everything it set
out to remove is gone (green, exit 0); `incomplete` = some went and something is still locked
(amber "Not fully cleaned", exit 0); `error` = it removed nothing, **or** the guard vetoed
anything at all (red, exit 1).

The name is `incomplete`, not `partial`: `summary.partial` already exists and counts unreadable
LOCATIONS, and `Get-PMTileRows` already has a `'partial'` kind for it. Two unrelated quantities
under one word, in a log format retained 50 runs deep and diffed week to week, would have been
worse than the bug. Checked for collisions across the run JSON, the report and the suite before
settling; `incomplete` appeared nowhere.

**A veto is a hard failure regardless of what else succeeded** - the guard refusing a target means
a module asked to delete something it may not touch. A locked file is not: one open handle among
940 items is ordinary on a machine in use, so it goes amber and the weekly SYSTEM task stays
green. A permanent benign red is how a control gets ignored, which is the judgement already
recorded for partial read coverage.

**Second defect in the same four lines, fixed with it.** `Remove-PMPath` re-measures after a throw
and returns the bytes it *did* free - "the one thing the audit trail must never get wrong" - and
all four modules discarded that number because the credit sat inside `if ($r.Removed)`. So did the
dispatcher, which only added to `summary.bytes` on success. Measured on the same fixture: 6,000 of
6,050 bytes really gone, recorded as 0 B twice over. There is no backup here; the run log is the
entire record of what was destroyed.

16 new tests, every one confirmed to FAIL first (274 -> 290, 0 failed): the outcome table, the
presentation and tile mapping, an AST check that all four shipped modules go through the shared
function, two dispatcher `-Apply` runs against a really locked file (all-locked -> `error` +
`summary.applied = 0` + `summary.bytes = 6000` + **process exit 1**; one-of-two locked ->
`incomplete` + exit **0** + 12,000 B credited), and one against the shipped `stale-app-temp`
Repair rather than a fixture module. The locked file is named `zz-locked.bin` on purpose: NTFS
returns entries in name order, and measured both ways - sorting LAST frees 6,000 B before the
throw, sorting FIRST aborts immediately and frees nothing, which would have made the
partial-bytes assertion a tautology.

### 7i. ~~Dead manifest keys, ~100 lines of them~~ DONE 2026-09-10

`Import-PMModuleInfo` reads only `Id, Name, Category, Entry, Roots`. Every `module.psd1` also
defines `Version`, `Description` and `Details` - the last being a here-string of roughly 25 lines
per module - and none of the three is read by any `.ps1`. `Description` and `Details` appear only
in test fixtures. Either render them in the report (they are good prose and the report has no
per-module explanation) or delete them; carrying documentation that nothing displays is the
worst of both.

**Resolved by RENDERING it, not deleting it.** The prose was the best writing in the repo and
it answered the one question the report could not: not what happened, but why the rule is what
it is. "What it never touches" matters most - this tool deletes as SYSTEM, and a reader
wondering whether their Plex library was ever at risk should not have to take the answer on
trust. It now appears per module card behind a closed `<details>`.

`Version` WAS deleted from all four psd1 files: `'1.0.0'` in every one, bumped by nothing. A
version number nobody maintains is worse than none.

The prose travels to the renderer as `-ModuleDoc`, deliberately NOT through the run object.
`New-PMHtmlReport`'s docstring says it renders the same object that goes to run-<id>.json so the
HTML can never disagree with the machine-readable record, and that still holds - everything
MEASURED comes from `$Run`. This is different in kind: a static description, identical every
run. Routing it through `$Run` would have added ~100 lines x 4 modules to a file written twice
per run and retained 50 runs deep, to say the same thing 400 times.

### 7j. ~~`$KnownSizes` is inert in `plex-bif-orphans`~~ DONE 2026-09-10

Declared on `Get-PlexOrphanCandidates` (`:30`), zero body references - it uses `$f.Length`
directly. The other three modules all use it, and this module's own callers are inconsistent
(`:87` passes it, `:57` does not). Defensible as a uniform module contract; genuinely inert here
because Plex candidates are files rather than trees. Decide which.

### 7k. Optimization, measured

Timed under 5.1, the version the scheduled task runs.

| Where | Re-measured 2026-09-10 | Fix | Status |
|---|---|---|---|
| `stale-app-temp/module.ps1:33` | **1,511 ms -> 33 ms** over 13,088 real Temp names | `foreach` + `break` with an explicit `[StringComparison]::OrdinalIgnoreCase`, instead of a `Where-Object` pipeline per directory | open - **45x**, the biggest confirmed win and the lowest risk. First recorded as 17x |
| `PMCommon.ps1:484` and `:497` | **565 ms -> 40 ms**, 27.0 MB -> 4.0 MB, over 13,088 dirs | `DirectoryInfo.EnumerateDirectories()`, returning the raw `DirectoryInfo` objects and `.ToArray()` not the `List` | open - **14x**, not the 6.4x first recorded. Wrapping each entry in a `pscustomobject` throws away 80% of the win; keep it NON-recursive or the one-error-per-location equivalence with `-ErrorVariable` dies |
| `plex-bif-orphans/module.ps1:44-46` | 10,442 ms -> 9,556 ms; **112.7 MB -> 11.8 MB** on a real 47,802-file tree | one streaming `Stack` + `EnumerateFiles` walk, per-directory `try/catch` feeding `Add-PMReadError -Critical`, skipping reparse points | open - the memory win is real and larger than recorded (**9.6x, ~101 MB**); **the 2x time claim does NOT reproduce** - measured ~8%. The tree is 1.28 files per directory, so 37,192 directory opens dominate and the FileInfo materialisation this removes is a small slice |
| `PMModule.ps1:43` | 27-55 ms x 8 phases | re-dot-sources all of `lib\` per phase; scope isolation is the point | open, low priority |
| ~~shared Temp listing between `stale-app-temp` and `vs-installer-scratch`~~ | 3 listings per apply run, not 4 (`stale-app-temp` has `AutoApply = $false`, so its Repair is unreachable); **1.0-1.7 s, not 2.26 s** | - | **CLOSED 2026-09-10, not implemented** - see below |

**Why the shared-listing item was closed rather than done.** Its own recorded remedy was wrong.
`$ctx` is constructed INSIDE the per-module loop, so caching a listing on it reaches the other
phase of the SAME module - precisely the Test-to-Repair reuse this project deliberately refuses,
because the tree changes in between - and cannot reach the other module at all. A cross-module
cache would have to be a dispatcher-level object, and even then the sharing window is wrong:
`vs-installer-scratch`'s Repair DELETES Temp directories between the two reads. Worse, the read
errors would not travel - `Clear-PMReadErrors` runs per phase and the accumulators are
`$script:`-scoped inside a scope that is then discarded, so a listing produced in one module's
scope arrives in another's with its failures erased. That is a partial listing that reads as a
complete one, in the one guarantee this repo calls load-bearing. With `PMCommon.ps1:484` fixed
each listing costs ~40 ms, so the whole item is worth under 80 ms. Not worth a hole in "blind is
not clean".

**A trap for whoever does the plex item.** `EnumerateFiles(AllDirectories)` FOLLOWS reparse
points - `Get-PMTreeStat`'s own comment records that regression - and it aborts the whole
enumeration on the first unreadable subdirectory instead of recording one error per location the
way `Get-ChildItem -ErrorVariable` does. Either mistake silently converts "this module went
blind" into "this module found nothing". Copy the `Stack` + per-directory `try/catch` shape that
`Get-PMTreeStat` already uses; do not reach for `AllDirectories`.

**Tests that must exist BEFORE those rewrites, because today none of them do.** The plex suite
has no unreadable-SUBDIRECTORY case and no junction-descent case, so a rewrite using
`AllDirectories` passes every existing test. `Get-PMChildDirectory` has nothing asserting hidden
or system directories are still returned, which is the `-Force` semantic an enumerator swap
silently changes. And `stale-app-temp`'s prefix match is never tested case-insensitively - the
fixture's `7zO1234` matches `7zO` in exact case and the second prefix `pip-unpack-` has no
fixture at all, so a rewrite that quietly became ordinal would pass the whole suite. That is the
degenerate-axis problem this project has already been bitten by once.

**Clean, and worth recording so nobody re-checks:** no undisposed resources in this repo - the
lock stream is disposed on all three exit paths, the one hand-rolled enumerator has a correct
try/finally, and there are no `Register-ObjectEvent`, runspaces, jobs or CIM sessions anywhere.
`+=` appears only over bounded collections. The 200-cap read-error accumulator is correct by
design. The deployed payload hash-matches the repo exactly.

### 7j-followup. `plex-bif-orphans` still BUILDS a size map nothing reads

Closing 7j removed the only consumer. `Test-PMModule` still returns
`Sizes = (ConvertTo-PMSizeMap -Items $items)` and the dispatcher still copies it into
`$ctx.KnownSizes`, so the comment claiming it is handed to Repair "so it does not re-measure" is
now false for this module alone. Costs one in-memory hashtable per run, not correctness. Left
deliberately: removing it touches the Test/Repair contract and interacts with the test pinning
"sizes never appears in the run JSON" - a wider change than the two lines 7j was.

### 7l. The one that is a note, not a finding

The 8.3 short-name handling in `Remove-PMPath` was independently re-verified under 5.1 and its
unusual comments are true: `DirectoryInfo('C:\PROGRA~1').FullName` expands, while
`[IO.Path]::GetFullPath('C:\PROGRA~1\x')` does not and `...\__nope__` does. The inconsistency
the fix exists for is real.
