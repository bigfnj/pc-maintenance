# Design

This documents what pc-maintenance changed about preference-guard's framework and why. The parts
it did **not** change (module contract shape, the `& {}` isolation seam, manifest load and
validation, run-scoped JSON logs with retention, the lock file) are documented in
preference-guard's own `docs/design.md` and are not repeated here.

## Why a sibling and not a preference-guard module

The module contract fitted. The host did not, on four counts.

**Cadence is global.** preference-guard's `task_template.xml` carries one `<Triggers>` block for
the whole task: logon plus five minutes, `PT1H30M`, and Group Policy events 1085/5016/5117/8004.
Its manifest has a single `task` object, and module entries carry only `id`, `enabled`, `order`.
A cleanup module would inherit a 90-minute sweep of 13,000 directories fired by a policy refresh
that has no causal relationship to temp files accumulating.

**Repair is assumed reversible.** Backups there are central and registry-shaped: `BackupPath`
takes `HKLM\…` keys or a `secedit:USER_RIGHTS` sentinel, snapshotted before Repair and replayable
via `Uninstall-PreferenceGuard -RestoreBackups`. A module whose Repair deletes 67 GB cannot honour
that. Nothing would crash; a guarantee the tool advertises would just quietly stop being true.

**No filesystem seam.** Modules there must read state only through `lib` readers so tests can fake
them, and `PGCommon` provides registry and user-rights readers only.

**The charter is the safety feature.** preference-guard's README opens with a governance boundary:
a stopgap for benign dev-enablement preferences that Intune reverts, a bridge until IT fixes the
root policy. Its forbidden-category gate exists specifically to stop scope creep by mislabelling.
Disk hygiene is not policy drift, and filing it there would cost the tool its one-sentence answer
to "what is this?" at exactly the moment it started deleting things.

## What changed

### The default is inverted

preference-guard repairs by default and takes `-DryRun`. This takes `-Apply` and reports
otherwise. The failure modes are asymmetric: an unrepaired preference is visible and recoverable,
a wrongly deleted file is neither.

### Deletion needs three independent agreements

`-Apply` on the dispatcher, `AutoApply = $true` in the module's own manifest, and the path guard.
`Test-PMApplyAllowed` treats an absent `AutoApply` as false, so a module that forgets to declare
it is report-only rather than trusted. This is what lets a class sit observational for months
while a proven one acts, which is the reason this is a framework rather than one script: the
per-class trust decision is the product.

### Forbidden categories became forbidden paths

Same idea, moved to where the damage is. `Test-PMPathSafe` requires both:

1. the target is under one of the module's declared `Roots`, and
2. it matches no forbidden pattern and is at least `MinDepth` (3) segments deep.

(1) alone would let a module with a broad root reach a Docker volume inside it. (2) alone would
let a module delete anywhere nobody had thought to forbid. Neither list is manifest-configurable;
a module cannot vote itself an exemption. `Roots` is a required key in `module.psd1`, enforced at
load, because a module with no roots can delete nothing and that must be loud rather than a silent
no-op at run time.

### The audit trail replaces the backup

Nothing can snapshot 67 GB of scratch, so every run records the full list of paths considered with
sizes and the reason each was kept or removed. `Remove-PMPath` takes `-WhatIfOnly` rather than the
module carrying a second code path for report mode, because two paths that must agree is exactly
the shape that drifts.

## Gotchas found building this

- **`[CmdletBinding()]` makes `$PSScriptRoot` empty inside a param default block under Windows
  PowerShell 5.1**, while the same variable is correct one line later in the body. Verified both
  ways: remove `[CmdletBinding()]` and the default populates. The failure is silent and cascading
  (every `Join-Path` binds an empty string), so `Invoke-PcMaintenance.ps1` resolves `$PayloadRoot`
  in its body and `tests/Invoke-Tests.ps1` pins that it keeps doing so.
- **Report the true count, not the capped one.** Two modules cap `Items` so a 6,935-orphan run
  does not bloat the run json. The dispatcher first logged `@($t.Items).Count`, which printed the
  cap (25) beside a Detail string saying 28. Modules now return an explicit `Count`.
- `??`, `?.` and ternaries are PowerShell 7 only and are parse errors under 5.1, which is what the
  scheduled task runs. The test suite parses every script under 5.1 for exactly this reason.

## Not built yet

The installer and the scheduled task. The manifest already describes the intended shape (`task`:
weekly, Sunday 03:00, run-if-missed), and the deployment pattern to copy is preference-guard's
`Install-PreferenceGuard.ps1`: build a self-contained payload under `C:\ProgramData\` (AppLocker
trusts it, the user profile may not) and register a SYSTEM task, elevating only to register.

Open question worth deciding before that lands: where the weekly report surfaces. A file under
`logs/` is simplest and will not be read. The alternative is to speak only when something crosses
a threshold, which keeps a weekly job from becoming background noise.
