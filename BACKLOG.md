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

Nothing still open here is reachable through the four shipped modules today. That is the reason
none of it is urgent, and also the reason it is easy to leave until a fifth module quietly makes
it reachable.

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

## 4. ~~TOCTOU inside `Remove-PMPath`~~ WON'T FIX 2026-09-09, with the reason recorded

Measured on this build rather than assumed, because the original entry overstated it:

| case | what was tried | victim |
|---|---|---|
| A | junction nested inside a tree we `Remove-Item -Recurse` | **survived** |
| B | the swept path itself swapped for a junction after the guard ran | **survived** |
| C | deleting a path that TRAVERSES a junction to a real file | **destroyed** |

`Remove-Item -Recurse` deletes the reparse point, not the target, which kills the textbook attack.
Only case C works, and reaching it needs a module to hand `Remove-PMPath` a path that goes through
a link. `Get-ChildItem -Recurse` does not descend junctions (measured: zero files found under a
directory containing one), so no module can enumerate one. That leaves a single route: the one
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
