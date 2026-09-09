# Backlog

Open work, in the order I would do it, with the reasoning for that order rather than just a list.
Everything here came out of the 2026-09-09 audit round unless noted.

## How to work this list

**Coverage before change, latent-safety before capability, design decisions last.**

The modules have no behavioural tests at all, so item 1 comes first: every other change on this
list touches code that nothing currently verifies, and doing them in the other order means fixing
guards while unable to tell whether a module still works. After that, the path-pattern gaps (2)
are a single batch in a single file with one test shape, and they are worth closing *before* a new
module makes them reachable rather than after. Item 3 is done. Item 4 needs a design decision and
has the lowest reachability, so it goes last.

Nothing still open here is reachable through the four shipped modules today. That is the reason
none of it is urgent, and also the reason it is easy to leave until a fifth module quietly makes
it reachable.

---

## 1. Three of the four modules have no behavioural tests

**Why first:** it is the thinnest coverage in the tree, and it gates honest work on everything
else. `vs-installer-scratch`'s three-condition identification rule decides whether tens
of gigabytes of somebody's TEMP get deleted, and it is currently checked only by a regex over its
own source text. The same goes for `plex-bif-orphans`' pairing rule and `stale-app-temp`'s
allowlist and age floor. `agent-scratchpads` got real fixture tests when it was enabled, so it is
the shape to copy for the other three.

**Shape:** a fixture tree per module, run `Test-PMModule` against it, assert exactly which paths
come back. That also retires the three source-text greps in the suite, which pass whether or not
the thing they describe still works.

**Watch for:** three of the four now delete, so a fixture test must assert exactly which paths
come back, not merely that some do.

## 2. The path guard reads broader than it is

Four gaps, all measured, none reachable today because every path handed to `Remove-PMPath` comes
from `Get-ChildItem`'s `.FullName`. Do them as one batch: same file, same test shape, one commit.

- **OneDrive Known Folder Move.** `'^[A-Za-z]:\\Users\\[^\\]+\\(Documents|Desktop|...)'` only
  matches a direct child of the profile. KFM is the Windows 11 default, so the real Documents,
  Desktop and Pictures sit under `...\OneDrive\...` and are unprotected. Measured:
  `C:\Users\Someone\OneDrive\Documents\tax` returns **safe**.
- **UNC forms.** `'\\wsl\\'` matches a directory literally named `wsl`, not `\\wsl$\Ubuntu\...`
  or `\\wsl.localhost\...`, both of which measure **safe**. `MinDepth = 3` is also much weaker on
  a share, where `\\server\share\folder` is already three segments.
- **The `\\?\` prefix** defeats every `^[A-Za-z]:\\`-anchored pattern at once, so the entire
  forbidden list would silently stop applying if long-path handling were ever added.
- **`AppData\Roaming` is uncovered entirely** (`.ssh`, `.aws`, browser profiles,
  `Microsoft\Crypto\RSA`).

**Add one test per pattern.** The suite already does this for the current entries; the gap is that
the entries themselves are incomplete, not that they are untested.

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

## 4. TOCTOU inside `Remove-PMPath`

Measured 2026-09-09 rather than assumed, because the original entry overstated it. Three cases,
all run on this build:

| case | what was tried | victim |
|---|---|---|
| A | junction nested inside a tree we `Remove-Item -Recurse` | **survived** |
| B | the swept path itself swapped for a junction after the guard ran | **survived** |
| C | deleting a path that TRAVERSES a junction to a real file | **destroyed** |

So `Remove-Item -Recurse` deletes the reparse point, not the target, which kills the textbook
attack. **Only case C works**, and reaching it needs a module to hand `Remove-PMPath` a path that
goes *through* a link. `Get-ChildItem -Recurse` does not descend junctions (measured: 0 files
found under a directory containing one), so no module can enumerate such a path.

That leaves one real route: a module that deletes individual FILES, where an attacker swaps an
intermediate directory for a junction between Test and Repair. Of the four, only
`plex-bif-orphans` deletes files rather than directories. The attack needs write access to the
Plex media cache, timing inside the Test-to-Repair window, and a victim file whose leaf name
matches the `.tmp` being removed.

**What it is worth depends entirely on the threat model.** On a single-user workstation where the
interactive user is an administrator, anyone who can create a junction in that tree can already
run code as themselves, and SYSTEM is not a boundary they need to cross. It matters only if the
interactive user is a standard user and SYSTEM is a privilege boundary worth defending.

**Options, cheapest first:**

1. **Re-check the ancestors immediately before deleting.** Walk from the target up to the declared
   root asserting nothing is a reparse point, right before `Remove-Item`. Narrows the window to
   microseconds, stays in plain PowerShell, maybe 20 lines. Does not close it.
2. **Delete files by handle.** Open with `FILE_FLAG_OPEN_REPARSE_POINT`, verify, then delete
   through that handle. Closes it properly for the file case, needs P/Invoke.
3. **Accept it and write down why.** Defensible on a single-admin box, and the honest option if
   the threat model does not include a hostile local user.

I would take (1) unless the threat model says otherwise: most of the benefit, none of the
complexity, and it keeps the tool auditable, which is a real part of its value.

---

## Smaller, and genuinely optional

- `Format-PMBytes` renders anything under 512 bytes as `0 KB` and has no TB tier, so a 2 TB sweep
  would print `2048.00 GB`.
- Log retention omits `-File`, so a subdirectory under `logs\` would match; `-Force` without
  `-Recurse` then fails silently. It also deletes outside the path guard.
- `Get-PMInteractiveUserSid`'s header comment says no user is guessed. Its third fallback does
  guess, in arbitrary registry order. Deletion is correctly blocked for an inferred user now, but
  **the comment is still wrong** and reporting does run against whichever profile it picked.
- `Get-PMForbiddenPathPatterns` and `Get-PMForbiddenCategories` are defined and never called. They
  are exactly the accessors a test would need to assert the two hard-coded lists have not been
  quietly edited, so their deadness marks a missing test rather than dead weight to remove.
- `-KeepLogs` on the uninstaller is a silent no-op unless `-RemoveFiles` is also passed.

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
