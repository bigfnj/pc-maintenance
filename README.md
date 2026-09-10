# pc-maintenance

Ongoing Windows housekeeping as pluggable **modules**. Each module recognises one class of
accumulated junk, reports what it found, and is allowed to delete it only once that class has
earned the trust. A weekly SYSTEM scheduled task runs the dispatcher and drops an HTML report in
your Downloads folder.

The framework is borrowed from a private sibling project of ours that re-asserts dev-enablement
preferences after policy pushes revert them. The module contract, the isolation seam, the
governance gate and the JSON run log come straight from it; the reasoning for building a sibling
rather than adding a module to it is in [docs/design.md](docs/design.md).

## Report-only by default

The most important inversion. The tool it borrows from repairs by default and takes `-DryRun` to
hold back. Here that is reversed, because the failure modes are not symmetric: an unrepaired
preference is an inconvenience you notice, a wrongly deleted file is gone.

```powershell
.\Invoke-PcMaintenance.ps1                    # report only. changes nothing, whatever a module says
.\Invoke-PcMaintenance.ps1 -Apply             # act, but only for modules that declare AutoApply
.\Invoke-PcMaintenance.ps1 -Only plex-bif-orphans
Get-Content .\logs\latest.json
```

**Deletion needs four independent things to agree.** Any one of them alone blocks it:

1. the operator passed `-Apply`;
2. the module's own `module.psd1` sets `AutoApply = $true` (absent reads as false, so a module
   that forgets to declare it is report-only rather than trusted);
3. the interactive user was confirmed logged on, not merely inferred from the registry;
4. the target survives the path guard: under the module's *declared* roots, and matching no
   hard-coded forbidden pattern.

`pcmaintenance.manifest.json` is not one of them. Nothing a module or a manifest says can widen
what may be deleted.

## Install

```powershell
.\Install-PcMaintenance.ps1 -RunNow           # payload to ProgramData + weekly SYSTEM task
.\Install-PcMaintenance.ps1 -ReportOnlySchedule   # same, but the schedule never acts
.\Uninstall-PcMaintenance.ps1 -RemoveFiles
```

The payload goes to `C:\ProgramData\PcMaintenance` because AppLocker trusts ProgramData and may
not trust a user profile. The task runs as SYSTEM so it does not need anyone logged in, and
resolves the interactive user at run time so the report still lands in *their* Downloads. Weekly,
Sunday 03:00, `StartWhenAvailable` so a machine that was off still gets its sweep.

Elevation is required only to *register* the task. Note that a SYSTEM-registered task is
admin-only to view: a non-elevated `Get-ScheduledTask PcMaintenance` returning nothing means it
exists and you cannot see it, not that it is missing.

## Modules

| id | what it removes | AutoApply | evidence |
|----|-----------------|-----------|----------|
| `vs-installer-scratch` | VS Installer self-extractions + its applied payload cache, older than 24h | **yes** | 13,341 directories / 48 GB accumulated over six months, one per update check |
| `plex-bif-orphans` | `.tmp` beside a `.bif` preview that already exists | **yes** | 6,935 `.tmp` for 6,935 `.bif`, so recurrence is exactly 100% |
| `stale-app-temp` | named app scratch (Adobe, CreativeCloud, OCCT, WinGet, 7-Zip, pip) idle >30d | no | one app held 12.9 GB idle for two months |
| `agent-scratchpads` | whole session directories under `Temp\claude` idle >14d | **yes** | 933 sessions / 3.22 GB, measured across 1,187 session dirs totalling 6.87 GB |

The three that may act share a property `stale-app-temp` lacks: a **mechanical** rule with no
judgement in it. `stale-app-temp` stays observational because "stale" is a per-application call.

`agent-scratchpads` is worth reading before you trust it, because two rules are doing all the
work. It matches **only directories whose name is a session GUID**, since the same tree holds
`bundled-skills`, which a *running* session loads skill payloads from. And it takes age from the
**newest file inside**, never the directory's own mtime: Windows bumps a directory timestamp only
when its own entries change, so a session root's stamp is effectively its creation time. Measured
on a live session, the root said 06:01 while the newest file inside said 14:29. An mtime rule
would delete in-flight work from any session outliving the floor.

## Three things that keep the output honest

**The path guard.** The framework this borrows from is kept safe by a hard-coded forbidden
*category* set that wins even when a module mislabels itself. The equivalent here is a hard-coded
forbidden *path* set, because what this tool can get wrong is measured in deleted bytes.

Two conditions, and the second one is the point: the target must sit under a root **declared in
the module's own `module.psd1`**, which the dispatcher expands and hands to `Remove-PMPath` so the
module cannot influence it, **and** it must match no forbidden pattern at three or more segments
deep. A module supplying its own root would be self-certification, which is what this was until an
audit noticed the declared roots were never actually read. It fails closed: no resolvable declared
roots means no deletion at all. Docker volume roots are refused by name, because from the outside
one looks exactly like disposable scratch while holding an application's only copy of its data.

**The payload must not be writable by a non-admin.** The dispatcher dot-sources every `.ps1` under
`lib/` and the task runs as SYSTEM, so a payload directory a standard user can write to is
arbitrary code execution as SYSTEM. `C:\ProgramData` inherits exactly that permission by default.
The installer hardens the ACL and verifies it took, and the dispatcher independently refuses to
run privileged from a writable payload, because an install that skipped the hardening must not
silently re-open the hole.

**Blind is not clean.** A module that could not *read* is never reported as clean. The readers
record what they failed to open instead of quietly returning less, and a failure on a module's own
root marks it `unverified` and exits non-zero. This is not hypothetical: the first SYSTEM run
reported a clean machine over 28 real orphans, because SYSTEM refuses to traverse a cross-volume
junction created by a less-privileged user and the error was being swallowed. Incidental
unreadable spots (a locked temp directory, a file that vanished mid-scan) are counted separately
as *partial coverage* and do not redden the run, because a control that goes red for a benign
reason is one you learn to ignore.

## The report

Every run writes `logs/run-<id>.json` plus a self-contained HTML dashboard named
`PC-Maintenance Report - <timestamp>.html` in the interactive user's Downloads folder, resolved
from that user's own shell-folder registration rather than assuming `<profile>\Downloads` (it is
commonly redirected). Self-contained means no CDN, no webfont and no JS library: the file is
opened offline, possibly months later, and a test asserts the output contains no external fetch.
It renders from the same object as the JSON, so neither can describe a run the other did not
see. That is not the same as every number matching, and two deliberately do not: the **Left
alone** tile counts what was found and *not* acted on, where the JSON's `summary.found` counts
everything found including what was then cleaned up, and **Couldn't read** lists distinct
messages capped at ten where `summary.partial` is the total. Both tiles say so. Each tile's
number is always exactly the number of rows it opens to - that promise is kept by construction,
since the count *is* the row count.

**Every number opens.** Each stat tile is a `<details>` element: click or tab to it and it expands
to the rows it counted, with a sentence explaining what that number means. A count nobody can
expand is a count nobody can act on. `<details>` rather than script keeps the file dependency-free
and keyboard-accessible, and it prints expanded.

**Only the two most recent reports are kept**, so Downloads holds the current sweep and the one
before it and the week-over-week delta stays readable. That deletion does *not* go through the
path guard, deliberately: Downloads is on the forbidden list precisely so no module can reach it,
and widening the guard would trade a convenience for the broadest hole in the tool. Instead
`Remove-PMOldReports` has a far stricter rule of its own - the exact generated filename pattern,
files only, no recursion, ordered by the timestamp in the name rather than mtime so a touched file
cannot promote itself past a newer one. Set `reportsToKeep` in the manifest to change it.

## Tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
```

Non-destructive, no Pester dependency. Run it under **Windows PowerShell 5.1**, not only 7,
because 5.1 is what the scheduled task runs; the suite parses every script under 5.1 for that
reason, and says so loudly if you run it under 7.

The suite prints its own totals and this paragraph deliberately does not repeat them. A count in
prose is stale the day a test is added - it had drifted by more than a hundred before anyone
noticed, and `Install-PcMaintenance.ps1` had already learned the same lesson about naming a module
count in its help. New `.ps1` files are picked up automatically: the parse check globs the tree, so
adding a script adds a test.

One check SKIPs without elevation, because it needs to set an ACL. A skip is counted and printed
separately rather than folded into the pass total: a check that reports success while verifying
nothing is the exact failure this project exists to catch, so the suite must not commit it either.

### Smoking the installation, not the code

```powershell
.\tests\Invoke-DeploymentSmoke.ps1            # what it can check unprivileged
.\tests\Invoke-DeploymentSmoke.ps1 -Elevate   # one UAC prompt, then everything
```

`Invoke-Tests.ps1` verifies this repository. The payload under `ProgramData` is a *copy* made at
install time, and it is the copy the weekly SYSTEM task runs - so a green suite says nothing about
what is actually deployed. This checks the other half: that every deployed file still hashes to
its repo original, that the payload ACL refuses a real non-admin write rather than merely looking
right, that the task is registered against *this* payload root, that the dispatcher runs and
advances its run id, and that the delivered HTML is self-contained and escaped.

That gap was not hypothetical. A batch of safety fixes sat committed and green while the deployed
copy still carried the bug they fixed, in the one module that has `AutoApply`.

Open work and the order I would do it in: [BACKLOG.md](BACKLOG.md).

## Layout

```
Invoke-PcMaintenance.ps1       dispatcher (report-only unless -Apply)
Install-/Uninstall-*.ps1       ProgramData payload + SYSTEM task register/remove
task_template.xml              weekly SYSTEM task, no policy triggers
pcmaintenance.manifest.json    modules, order, allowedCategories, task shape, retention
lib/PMCommon.ps1               logging, user resolution, filesystem readers, THE PATH GUARD,
                               and the payload-ACL check the installer must satisfy
lib/PMManifest.ps1             manifest load + the category and apply gates
lib/PMModule.ps1               module metadata import + isolated phase invocation
lib/PMReport.ps1               Downloads resolution + the HTML dashboard
modules/<id>/module.psd1       declarative: Category, Roots, AutoApply, Description
modules/<id>/module.ps1        Test-PMModule / Repair-PMModule
tests/Invoke-Tests.ps1         non-destructive runner
```
