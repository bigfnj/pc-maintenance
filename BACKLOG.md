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

### 6i. Guarantees the README states more strongly than the code provides

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

### 6e-6k closed 2026-09-10, except 6i

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

**Still open: 6i** - three guarantees the README states more strongly than the code provides
(gate 3 is opt-in via `RequiresUserSid`; `DeclaredRoots` is module-*mediated*; `Remove-PMPath`
enforces only gate 4). All three are unreachable through the four shipped modules. Left alone
deliberately: closing them means either tightening the code or softening the prose, and that is
a design call rather than a defect to fix.

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
