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

### Deletion needs three independent agreements

`-Apply` on the dispatcher, `AutoApply = $true` in the module's own manifest, and the path guard.
`Test-PMApplyAllowed` treats an absent `AutoApply` as false, so a module that forgets to declare it
is report-only rather than trusted. This is what lets a class sit observational for months while a
proven one acts, and that per-class trust decision is the reason this is a framework rather than
one script.

### Forbidden categories became forbidden paths

Same idea, moved to where the damage is. `Test-PMPathSafe` requires both:

1. the target is under one of the module's declared `Roots`, and
2. it matches no forbidden pattern and is at least `MinDepth` (3) segments deep.

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

### The audit trail replaces the backup

Nothing can snapshot tens of gigabytes of scratch, so every run records the paths considered with
sizes and the reason each was kept or removed. `Remove-PMPath` takes `-WhatIfOnly` rather than the
module carrying a second code path for report mode, because two paths that must agree is exactly
the shape that drifts.

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

## Backlog

- A liveness check for `agent-scratchpads`, so it could be promoted to `AutoApply`. An open handle
  on the session directory or a pid file the agent maintains; not a longer timeout.
- Promote individual entries out of `stale-app-temp` into their own modules once one has been
  watched long enough to state a mechanical rule for it. Flipping the whole list to `AutoApply`
  would be trusting every entry at once.
- Decide what the weekly report should do when nothing is found. Today it always writes; always
  speaking is how a weekly job becomes background noise.
