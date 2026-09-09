@{
    Id                = 'plex-bif-orphans'
    Name              = 'Plex preview .tmp orphans'
    Category          = 'maintenance'
    Version           = '1.0.0'
    RequiresUserSid   = $true
    AutoApply         = $true
    # ENFORCED, not decorative: the dispatcher expands these against the interactive user and
    # resolves reparse points, then Remove-PMPath requires every target to sit under one of them.
    # The junction to another volume is handled by that resolution, not by a placeholder here.
    Roots             = @('%LOCALAPPDATA%\Plex Media Server\Media')
    Entry             = 'module.ps1'
    Description       = 'Remove stale .tmp files left beside every generated Plex video preview (.bif). Measured 2026-09-02: exactly 6,935 .bif and 6,935 .tmp, so the leak recurs on every preview generated without exception.'
    Details           = @'
What it fixes
  Plex writes <name>.bif.tmp while generating a video preview thumbnail index and
  leaves it behind after renaming the finished .bif into place. The count matched
  one-for-one on this box, which makes the recurrence rate exactly 100%.

How it identifies one
  A file whose name ends .tmp, where the same path with .tmp stripped EXISTS as a
  real file. That pairing is the whole rule: an orphan whose base is missing is
  left alone, because it may be a generation still in progress.

What it never touches
  Only the Plex Media/Metadata cache tree, never a Plex library. The cache is
  regenerable by definition; the library is your media. The path guard in
  PMCommon enforces the module root independently of this file.

Why AutoApply is on
  Mechanical rule, no judgement, 100% recurrence, and the deleted artifact is
  reproducible by Plex on demand.
'@
}
