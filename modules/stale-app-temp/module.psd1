@{
    Id                = 'stale-app-temp'
    Name              = 'Stale application temp folders'
    Category          = 'maintenance'
    Version           = '1.0.0'
    RequiresUserSid   = $true
    RequiresElevation = $false
    AutoApply         = $false
    Roots             = @('%LOCALAPPDATA%\Temp')
    Entry             = 'module.ps1'
    Description       = 'REPORT-ONLY. Named application scratch folders under the user TEMP that have not been written to in a long time (Adobe, CreativeCloud, OCCT, WinGet, 7-Zip extractions, pip unpack dirs). Adobe alone held 12.9 GB untouched for two months on 2026-09-09.'
    Details           = @'
What it reports
  Well-known application scratch directories under %LOCALAPPDATA%\Temp that are
  older than the staleness floor (default 30 days).

Why AutoApply is deliberately OFF
  Unlike the VS and Plex modules, "stale" here is a judgement call per application
  rather than a mechanical rule. Adobe at two months idle is obviously disposable;
  a WinGet cache the day before you reinstall something is not. The recurrence is
  also irregular, so there is no pattern to trust the way the other two have one.

  This module exists to keep the number visible every week. Promote an individual
  entry to a module of its own with AutoApply once its behaviour has been watched
  long enough to state a mechanical rule for it. Flipping THIS module to AutoApply
  would be trusting the whole list at once, which is the thing to avoid.
'@
}
