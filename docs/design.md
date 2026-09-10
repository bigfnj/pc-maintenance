# Design

This records what pc-maintenance changed about the framework it borrows, and why. The parts it did
**not** change (the module contract shape, the `& {}` isolation seam, manifest load and validation,
run-scoped JSON logs with retention, the lock file) came across intact and are not re-explained
here.

The framework comes from a private sibling project of ours: a SYSTEM scheduled task that
re-asserts benign dev-enablement preferences after Intune or Group Policy reverts them.

## Why a sibling project and not a module of that one

The module contract fitted. The host did not, on four counts.

**Cadence is global there.** One `<Triggers>` block covers the whole task: logon plus five
minutes, a 90-minute interval, and Group Policy events. Its manifest has a single `task` object
and module entries carry only `id`, `enabled`, `order`, so there is no per-module schedule. A
cleanup module would inherit a 90-minute sweep of thousands of directories, fired by a policy
refresh that has no causal relationship to temp files accumulating.

**Repair is assumed reversible there.** Backups are central and registry-shaped: a module declares
registry paths, the dispatcher snapshots them before Repair, and uninstall can replay them. A
module whose Repair deletes tens of gigabytes cannot honour that. Nothing would crash; a guarantee
the tool advertises would just quietly stop being true.

**No filesystem seam.** Modules there read state only through shared readers so tests can fake
them, and those readers cover the registry and user rights, not files.

**The charter is the safety feature.** That project opens with a governance boundary: a stopgap
for benign preference drift on a managed device, a bridge until IT fixes the root policy. Its
forbidden-category gate exists specifically to stop scope creep by mislabelling. Disk hygiene is
not policy drift, and filing it there would cost the tool its one-sentence answer to "what is
this?" at exactly the moment it started deleting things.

## What changed

### The default is inverted

The original repairs by default and takes `-DryRun`. This reports by default and takes `-Apply`.
The failure modes are asymmetric: an unrepaired preference is visible and recoverable, a wrongly
deleted file is neither.

### Deletion needs four independent agreements

`-Apply` on the dispatcher, `AutoApply = $true` in the module's own manifest, an interactive user
confirmed logged on rather than inferred from the registry, and the path guard.
`Test-PMApplyAllowed` treats an absent `AutoApply` as false, so a module that forgets to declare it
is report-only rather than trusted. This is what lets a class sit observational for months while a
proven one acts, and that per-class trust decision is the reason this is a framework rather than
one script.

### Forbidden categories became forbidden paths

Same idea, moved to where the damage is. `Test-PMPathSafe` requires both:

1. the target is under one of the module's declared `Roots`, and
2. it matches no forbidden pattern and is at least `MinDepth` (2) DIRECTORIES deep, the drive
   excluded. It counted the drive letter until an audit found that made the uninstaller read one
   level shallower than it asked for; see BACKLOG item 5.

(1) alone would let a module with a broad root reach a Docker volume inside it. (2) alone would let
a module delete anywhere nobody had thought to forbid. Neither list is manifest-configurable.
`Roots` is a required key in `module.psd1`, enforced at load, because a module with no roots can
delete nothing and that must be loud rather than a silent no-op at run time.

### Blind is not clean

Added after the first real SYSTEM run, which is the only reason it exists.

The readers used `-ErrorAction SilentlyContinue`, so an access failure returned fewer results
rather than an error, and "I could not look" became "there is nothing there". `plex-bif-orphans`
reported a clean machine while 28 orphans sat on the other side of a junction. The cause is worth
knowing: **Windows refuses to let a privileged process traverse a cross-volume junction created by
a less-privileged user** ("the path cannot be traversed because it contains an untrusted mount
point"), which is a symlink-attack defence. Elevated Admin traverses it; SYSTEM does not.

Three changes came out of it. Readers record what they could not open. `Resolve-PMReparsePoint`
follows the junction so the module scans the real target, with the path guard still applying to
whatever root that returns. And the dispatcher marks a module `unverified` and exits non-zero
rather than letting it report clean, checked **before** the clean branch, with a test asserting
that ORDER rather than merely that the block exists.

The first version of that was too strict, and the second SYSTEM run showed it: one locked
PyInstaller `_MEI` directory made a module permanently unverified. A control that reddens for a
benign reason is one you learn to ignore, which costs more than the control gains. So reads now
carry a `-Critical` flag. Critical means the module's own root, where failure invalidates the
answer. Everything else is *partial coverage*: counted, displayed, and not a failure. Every shipped
module marks its load-bearing read `-Critical`, pinned by a test, because that is cheap to forget.

### Cleaned is not the same claim as "the guard did not veto"

The sibling project's module contract returns `Ok`, and a preference repair there really is
binary: the key holds the value or it does not. Deletion is not. This project inherited the
boolean, each module computed it as `Ok = ($vetoed -eq 0)`, and the dispatcher mapped it with
`if ($r.Ok) { 'applied' } else { 'error' }`.

Every hop in that chain was individually defensible and the composition was wrong. `Remove-PMPath`
returns `Removed = $false` with `Reason = "partially removed then failed: IOException"` when
`Remove-Item -Recurse` deletes most of a tree and throws; `Get-PMRemovalBucket` correctly calls
that **locked**; locked is not vetoed, so `Ok` stayed `$true`. Reproduced end to end on
2026-09-10 by holding one exclusive `FileStream`: status `applied`, badge `Role 'good' / Icon
'OK' / Word 'Cleaned'`, `summary.applied = 1`, `summary.bytes = 0`, exit 0. Only the Detail
string — *"removed 0 of 1; 0 vetoed by the path guard, 1 locked, 0 already gone"* — was honest.

`Get-PMRepairOutcome` now decides, from counters rather than a boolean, and it lives in
`PMCommon` beside `Get-PMRemovalBucket` for the reason recorded there: four copies of this
expression is what drifted last time. **The dispatcher calls it, not the module's answer to it.**
A module's verdict on its own run is self-certification, exactly like a module supplying its own
roots — the modules return what happened (attempted, removed, vetoed, locked, gone) and the
dispatcher decides what that means, then writes both the decision and the counters to the run
JSON. A Repair result missing those counters is an error, because 0 attempted / 0 removed is
legitimately "applied" and a module that answered nothing would otherwise have gone green.

The exit-code split is the part worth arguing about. A veto fails the run outright however much
else succeeded, because the guard refusing a target means a module asked for something it may not
have. A *locked* file does not: one open handle among 940 items is ordinary on a machine in use,
and a job that goes red every Sunday for a benign reason stops being read — the same judgement
already made for partial read coverage, one section up. So `incomplete` is amber and exits 0, and
only a repair that achieved nothing reddens the task.

The second defect lived in the same four lines. `Remove-PMPath` re-measures after a throw and
returns the bytes it *did* free, with a comment calling that "the one thing the audit trail must
never get wrong" — and all four modules discarded it, because the credit sat inside
`if ($r.Removed)`. So did the dispatcher, which only added to `summary.bytes` on success. Measured
on the same fixture: 6,000 of 6,050 bytes really gone, recorded as zero, twice over. There is no
backup here; the log is the whole record of what a run destroyed.

### The audit trail replaces the backup

Nothing can snapshot tens of gigabytes of scratch, so every run records the paths considered with
sizes and the reason each was kept or removed.

This paragraph used to go on to say that `Remove-PMPath` takes `-WhatIfOnly` "rather than the
module carrying a second code path for report mode". That stopped being true and the doc did not
notice. When the declared-roots fix landed, `-WhatIfOnly` was dropped from all four module call
sites, and the dispatcher never enters `Repair` in report mode at all — report figures come from
`Test`. The parameter still exists and is exercised only by a test. The current behaviour is at
least as safe (report mode cannot reach the removal path even by accident), but a reviewer who
believed the old sentence would think report mode exercises the real deletion path, and it does
not.

### The report is the product

The dispatcher writes an HTML dashboard to the interactive user's Downloads. It renders the same
object that goes to the run JSON, so the two cannot disagree. Downloads is resolved from the user's
own shell-folder registration, not `<profile>\Downloads`, which mattered on the first machine it
ran on. The whole report step is wrapped: losing the delivery is a warning, never a failed sweep.

## Gotchas found building this

- **`[CmdletBinding()]` makes `$PSScriptRoot` empty inside a param default block under Windows
  PowerShell 5.1**, while the same variable is correct one line later in the body. Verified both
  ways: remove `[CmdletBinding()]` and the default populates. The failure is silent and cascading
  (every `Join-Path` binds an empty string), so the dispatcher resolves `$PayloadRoot` in its body
  and a test pins that it keeps doing so.
- **Report the true count, not the capped one.** Two modules cap `Items` so a 6,935-orphan run does
  not bloat the run JSON. The dispatcher first logged the capped array length beside a Detail
  string carrying the real number, and the two disagreed on screen. Modules now return an explicit
  `Count`.
- **`??`, `?.` and ternaries are PowerShell 7 only** and are parse errors under 5.1, which is what
  the scheduled task runs. The suite parses every script under 5.1 for exactly this reason.
- **A SYSTEM-registered task is admin-only to view.** A non-elevated query returning nothing means
  it exists and you cannot see it, not that registration failed.
- **When re-testing a scheduled run, wait for the run id to CHANGE.** Waiting for a timestamp to
  look recent will happily read the previous run and report the old behaviour as the new one.
- **Setting a timestamp on a junction writes through it under 5.1 and to the link under 7.**
  `(Get-Item -LiteralPath $link -Force).LastWriteTimeUtc = $x` stamps the *target* on Windows
  PowerShell 5.1 and the *link* on PowerShell 7. Measured both ways. Production code is
  unaffected because it reads `DirectoryInfo`, which always describes the link — but a test
  built on that setter passes under 7 and fails under 5.1 for reasons unrelated to what it is
  testing. Construct such fixtures without stamping the link at all.
- **`@()` around an EMPTY generic `List` throws "Argument types do not match".** Harmless while
  a collection is a plain array, and fatal the moment it becomes `List[object]`. Capping the
  read-error accumulator turned two accessors that did `@($listA) + @($listB)` into eight
  simultaneous failures, every one of them a caller that only wanted to read an error message.
  Index the list directly instead.

## Backlog

Open work lives in [../BACKLOG.md](../BACKLOG.md), not here. This section used to carry its own
copy and it rotted: two of its three items were closed, and the third - a liveness check for
`agent-scratchpads` - was not merely done but **wrong**, since the real defect was the clock, not
liveness. A second list is a second thing to forget to update.
