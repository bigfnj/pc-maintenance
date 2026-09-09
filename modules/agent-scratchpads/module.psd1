@{
    Id                = 'agent-scratchpads'
    Name              = 'Coding-agent scratchpads'
    Category          = 'maintenance'
    Version           = '1.0.0'
    RequiresUserSid   = $true
    AutoApply         = $true
    Roots             = @('%LOCALAPPDATA%\Temp\claude')
    Entry             = 'module.ps1'
    Description       = 'Remove per-session coding-agent scratch under %LOCALAPPDATA%\Temp\claude that has been idle more than 14 days. Measured 2026-09-09: 1,187 session directories totalling 6.87 GB, of which ~940 were idle past the floor and held ~3.75 GB.'
    Details           = @'
What it removes
  Whole session directories under %LOCALAPPDATA%\Temp\claude whose newest file
  is more than 14 days old.

Why this is safe to do automatically
  A scratchpad is disposable by definition: intermediate results and throwaway
  scripts. The durable record of a session - its transcript, and any large tool
  output that was persisted - lives under ~\.claude\projects\ and is never
  touched here. The worst case on resuming a very old session is regenerating a
  script, not losing anything.

Two rules that are doing the real work
  1. A candidate's NAME must be a session GUID. The same tree holds
     bundled-skills, which a running session loads skill payloads from, and
     cache-break-state files. "Anything old under Temp\claude" would break them.
  2. Age is taken from the NEWEST FILE INSIDE, never the directory's own mtime.
     Windows updates a directory timestamp only when its own entries change, so
     a session root's mtime is effectively its creation time. Measured on a live
     session: root 06:01, newest file inside 14:29. An mtime rule would delete
     in-flight work from any session that had outlived the floor.

Why 14 days and not 30
  Because the space is not where the age is. Measured across 1,187 directories:
  30+ days is 643 directories but only 0.84 GB, while the 7-30 day band holds
  4.01 GB. The large scratchpads - git clones, build archives, screen
  recordings - are 15 to 28 days old. 14 days reclaims roughly four times more
  than 30 and is still far beyond any plausible resume.
'@
}
