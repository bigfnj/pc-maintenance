@{
    Id                = 'vs-installer-scratch'
    Name              = 'Visual Studio Installer scratch'
    Category          = 'maintenance'
    Version           = '1.0.0'
    RequiresUserSid   = $true
    RequiresElevation = $false
    AutoApply         = $true
    Roots             = @('%LOCALAPPDATA%\Temp')
    Entry             = 'module.ps1'
    Description       = 'Remove Visual Studio Installer self-extractions and its downloaded payload cache from the user TEMP folder. Measured on this box 2026-09-09: 13,341 extraction directories totalling 48 GB, accumulating since 2026-03-16, plus a 4.17 GB payload cache.'
    Details           = @'
What it fixes
  The Visual Studio Installer unpacks itself into a fresh randomly-named directory
  under %LOCALAPPDATA%\Temp on every update check and never cleans up. Six months
  of that reached 48 GB with nothing watching.

How it identifies one
  Three conditions together, so an unrelated directory that merely has a random
  name is never touched:
    - the name matches ^[a-z0-9]{8}\.[a-z0-9]{3}$
    - it contains setup.exe AND a resources\app\ServiceHub subtree
    - it was last written more than 24 hours ago
  Plus the installer payload cache, identified by name and by containing the
  .vsix / .msi files it has already applied.

Why AutoApply is on
  The rule is mechanical rather than a judgement call, and recurrence is
  effectively 100%: one directory per update check, every time, since March.
  The 24-hour floor is what keeps it clear of an extraction in flight.
'@
}
