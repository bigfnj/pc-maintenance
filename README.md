# pc-maintenance

Ongoing Windows housekeeping as pluggable **modules**: each one knows how to recognise a single
class of accumulated junk, reports what it found, and removes it only once the class has earned
that trust. A weekly SYSTEM scheduled task runs the dispatcher.

It borrows its framework wholesale from **[preference-guard](https://github.com/bigfnj/preference-guard)**
(module contract, isolation seam, governance gate, JSON run log) and is a sibling rather than a
module of it, for reasons written down in [docs/design.md](docs/design.md). The short version:
preference-guard exists to undo what Intune reverted, on a 90-minute-plus-GPO-event cadence, with
a backup it can replay. None of those three things is true of disk hygiene.

## Report-only by default

The single most important difference from preference-guard, which repairs by default and takes
`-DryRun` to hold back. Here it is inverted, because the failure modes are not symmetric: a
preference left unrepaired is an inconvenience you notice, a file deleted wrongly is gone.

```powershell
.\Invoke-PcMaintenance.ps1              # report only. changes nothing, whatever the modules say
.\Invoke-PcMaintenance.ps1 -Apply       # act, but only for modules that declare AutoApply
.\Invoke-PcMaintenance.ps1 -Only plex-bif-orphans -Apply
Get-Content .\logs\latest.json
```

**Deletion needs three independent things to agree**, and any one of them alone blocks it:

1. the operator passed `-Apply`;
2. the module's own `module.psd1` sets `AutoApply = $true` (absent means false, so a module that
   forgets to declare it is report-only rather than trusted);
3. the target survives the hard-coded path guard in `lib/PMCommon.ps1`, which is not configurable
   from any manifest.

## Modules

| id | what it removes | AutoApply | evidence |
|----|-----------------|-----------|----------|
| `vs-installer-scratch` | VS Installer self-extractions + its applied payload cache, older than 24h | **yes** | 13,341 dirs / 48 GB accumulated since 2026-03-16, one per update check |
| `plex-bif-orphans` | `.tmp` beside a `.bif` preview that already exists | **yes** | 6,935 `.tmp` for 6,935 `.bif` measured 2026-09-02, so recurrence is exactly 100% |
| `stale-app-temp` | named app scratch (Adobe, CreativeCloud, OCCT, WinGet, 7-Zip, pip) idle >30d | no | Adobe held 12.9 GB idle for two months |
| `agent-scratchpads` | per-session coding-agent scratch idle >14d | no | 6.51 GB, 941 idle sessions across 11 projects |

The two `AutoApply` modules share a property the other two lack: a **mechanical** rule with no
judgement in it, and a recurrence rate near 100%. `stale-app-temp` stays observational because
"stale" is a per-application judgement. `agent-scratchpads` stays observational for a harder
reason: directory mtime is not a liveness signal, and deleting a running agent's working
directory would break it mid-task. That one needs a real liveness check, not a longer timeout.

## The path guard

preference-guard's safety keystone is a hard-coded forbidden **category** set that wins even when
a module mislabels itself. The equivalent here is a hard-coded forbidden **path** set, because
what this framework can do wrong is measured in deleted bytes. `Test-PMPathSafe` requires two
independent conditions: the target sits under a root the module declared, **and** it matches no
forbidden pattern and is at least three segments deep. Neither alone is sufficient, and a module
cannot vote itself an exemption from either.

Docker is named explicitly in that list. Twenty-two volumes on this machine hold financial records
and student IEP data, and from the outside a Docker volume root looks exactly like disposable
scratch.

## Tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
```

Non-destructive: the guard tests assert on `Test-PMPathSafe` directly and the removal tests use a
throwaway tree. Run it under **Windows PowerShell 5.1**, not just 7, because that is what the
scheduled task will run. 43 tests as of 2026-09-09.

## Status

Framework, four modules and tests are done and verified against this machine. **The installer and
the scheduled task are not built yet** — today you run the dispatcher by hand. That is the next
piece of work, along with deciding where the weekly report should surface.

## Layout

```
Invoke-PcMaintenance.ps1       dispatcher (report-only unless -Apply)
pcmaintenance.manifest.json    modules, order, allowedCategories, weekly task shape, retention
lib/PMCommon.ps1               logging, user resolution, filesystem readers, THE PATH GUARD
lib/PMManifest.ps1             manifest load + the category and apply gates
lib/PMModule.ps1               module metadata import + isolated phase invocation
modules/<id>/module.psd1       declarative metadata: Category, Roots, AutoApply, Description
modules/<id>/module.ps1        Test-PMModule / Repair-PMModule
tests/Invoke-Tests.ps1         non-destructive runner, no Pester dependency
```
