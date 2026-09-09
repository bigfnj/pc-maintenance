@{
    Id                = 'agent-scratchpads'
    Name              = 'Coding-agent scratchpads'
    Category          = 'maintenance'
    Version           = '1.0.0'
    RequiresUserSid   = $true
    AutoApply         = $false
    Roots             = @('%LOCALAPPDATA%\Temp\claude')
    Entry             = 'module.ps1'
    Description       = 'REPORT-ONLY. Per-session scratch directories left by coding agents under %LOCALAPPDATA%\Temp\claude. 6.51 GB on 2026-09-09, growing every session.'
    Details           = @'
What it reports
  Session directories under Temp\claude older than the age floor (default 14
  days), with their sizes.

Why AutoApply is deliberately OFF, and what would have to change
  Deleting a LIVE session's scratch breaks a running agent mid-task, and this
  machine routinely has concurrent sessions. Directory mtime is not a reliable
  liveness signal: a session can sit idle for hours between turns and then resume,
  so an age floor alone can still delete something in use.

  Before this could ever be promoted to AutoApply it needs a real liveness check
  (an open handle on the session directory, or a pid file the agent maintains),
  not a longer timeout. A longer timeout only makes the failure rarer and harder
  to attribute, which is worse than a failure you can see.

  Until then this is a number on the weekly report and a manual decision.
'@
}
