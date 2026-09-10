#Requires -Version 5.1
<#
    PMReport.ps1 - renders a run into a self-contained HTML dashboard.

    Self-contained is a requirement, not a preference: the file lands in a user's Downloads and
    may be opened offline, months later, on a machine with no network. So no CDN, no webfont, no
    JS library. Everything is inline; the only script is a few lines for the theme toggle.

    Colours, surfaces and the status palette come from the dataviz reference palette. Status is
    never carried by colour alone - every state ships an icon and a word, because the light-surface
    warning and serious steps are deliberately sub-3:1 and the icon+label pairing is the mitigation.
#>

function Get-PMDownloadsPath {
    <#
        The real Downloads folder for the interactive user, not SYSTEM's.

        Reads the user's own shell-folder registration first, because Downloads is commonly
        redirected (OneDrive, or a different volume) and <profile>\Downloads would then write a
        report into a folder the user never opens. Under SYSTEM with the user logged on, HKU\<sid>
        is already mounted. Falls back to the profile path, then to TEMP, so this can degrade but
        never fail the run - a report is the point of the run, but a missing report must not look
        like a failed sweep.
    #>
    param([string]$UserSid, [string]$UserProfile)
    $guid = '{374DE290-123F-4565-9164-39C4925E467B}'   # FOLDERID_Downloads
    if ($UserSid) {
        $key = "Registry::HKEY_USERS\$UserSid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        try {
            $raw = (Get-ItemProperty -LiteralPath $key -Name $guid -ErrorAction Stop).$guid
            if ($raw) {
                $expanded = [Environment]::ExpandEnvironmentVariables($raw)
                # The stored value uses %USERPROFILE%, which under SYSTEM expands to SYSTEM's
                # profile. Re-point it at the real user before trusting it.
                if ($UserProfile -and $expanded -match '^[A-Za-z]:\\Windows\\system32') {
                    $expanded = Join-Path $UserProfile 'Downloads'
                }
                if ($expanded -and (Test-Path -LiteralPath $expanded)) { return $expanded }
            }
        } catch {}
    }
    if ($UserProfile) {
        $p = Join-Path $UserProfile 'Downloads'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $env:TEMP
}

$script:PMReportNamePattern = '^PC-Maintenance Report - (\d{4}-\d{2}-\d{2}) (\d{6})\.html$'

function Get-PMReportFileName {
    param([Parameter(Mandatory)][datetime]$When)
    'PC-Maintenance Report - ' + $When.ToString('yyyy-MM-dd HHmmss') + '.html'
}

function Remove-PMOldReports {
    <#
        Keep only the newest N reports, so Downloads holds the current sweep and the one before it
        and you can read the delta without a pile of stale files.

        This deliberately does NOT go through Remove-PMPath. Downloads is on the forbidden-path
        list precisely so no module can ever reach it, and widening that guard to let this through
        would trade a narrow convenience for the broadest hole in the tool. Instead this is its own
        much stricter rule, and it can only ever match files THIS tool wrote:

          - the name must match the exact generated pattern, timestamp and all
          - it must be a file, not a directory and not a reparse point
          - it must sit directly in the given directory; nothing recurses
          - ordering comes from the TIMESTAMP IN THE NAME, not mtime, because a file that gets
            touched or copied must not be able to promote itself past a newer report

        Returns the paths removed.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [int]$Keep = 2
    )
    if ($Keep -lt 1) { $Keep = 1 }
    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory)) { return @() }

    $reports = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($f.Name, $script:PMReportNamePattern)
        if (-not $m.Success) { continue }
        if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        # Sort key straight from the name: '2026-09-09' + '135713' sorts correctly as text.
        $reports += [pscustomobject]@{ Path = $f.FullName; Key = ($m.Groups[1].Value + $m.Groups[2].Value) }
    }
    if ($reports.Count -le $Keep) { return @() }

    $removed = @()
    foreach ($r in (@($reports | Sort-Object Key -Descending) | Select-Object -Skip $Keep)) {
        try {
            Remove-Item -LiteralPath $r.Path -Force -ErrorAction Stop
            $removed += $r.Path
        } catch { }
    }
    return $removed
}

function ConvertTo-PMHtml {
    # Paths are user data and can contain & < > " - escape before interpolating, or a directory
    # named with an angle bracket silently breaks the document.
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()]$Text)
    if ($null -eq $Text) { return '' }
    ([string]$Text).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-PMStatusPresentation {
    # status -> (palette role, icon, word). Icon + word is what carries meaning; the colour only
    # reinforces it.
    param([Parameter(Mandatory)][string]$Status)
    switch ($Status) {
        'clean'    { @{ Role = 'good';     Icon = 'OK';   Word = 'Clean' } }
        'reported' { @{ Role = 'warning';  Icon = '!';    Word = 'Found' } }
        'applied'  { @{ Role = 'good';     Icon = 'OK';   Word = 'Cleaned' } }
        'skipped'  { @{ Role = 'muted';    Icon = '--';   Word = 'Skipped' } }
        'unverified' { @{ Role = 'serious'; Icon = '/!'; Word = 'Could not check' } }
        'error'    { @{ Role = 'critical'; Icon = 'X';    Word = 'Error' } }
        default    { @{ Role = 'muted';    Icon = '?';    Word = $Status } }
    }
}

function Get-PMTileRows {
    <#
        Turn a summary tile into the actual rows behind it.

        A number nobody can expand is a number nobody can act on: "Unreadable: 1" told a reader
        there was one of something, without saying what, where, or whether it mattered. Each tile
        now carries the rows it counted, so the count and the evidence can never disagree - the
        tile value IS the row count, not a separately-maintained number.
    #>
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)]$Modules)
    $rows = @()
    foreach ($m in @($Modules)) {
        $bytes = if ($m.bytes) { [int64]$m.bytes } else { [int64]0 }
        switch ($Kind) {
            'total' {
                $rows += @{ K = $m.id; V = (Get-PMStatusPresentation -Status ([string]$m.status)).Word; D = [string]$m.detail }
            }
            'clean'      { if ($m.status -eq 'clean')      { $rows += @{ K = $m.id; V = 'nothing to do'; D = [string]$m.detail } } }
            'found'      { if ($m.status -eq 'reported')   { $rows += @{ K = $m.id; V = (Format-PMBytes $bytes); D = [string]$m.detail } } }
            'applied'    { if ($m.status -eq 'applied')    { $rows += @{ K = $m.id; V = (Format-PMBytes $bytes) + ' freed'; D = [string]$m.detail } } }
            'skipped'    { if ($m.status -eq 'skipped')    { $rows += @{ K = $m.id; V = 'not run'; D = [string]$m.detail } } }
            'unverified' { if ($m.status -eq 'unverified') { $rows += @{ K = $m.id; V = 'could not check'; D = [string]$m.detail } } }
            'errors'     { if ($m.status -eq 'error')      { $rows += @{ K = $m.id; V = 'failed'; D = [string]$m.detail } } }
            'partial' {
                foreach ($msg in @($m.readErrorMessages)) { $rows += @{ K = $m.id; V = ''; D = [string]$msg } }
            }
        }
    }
    return $rows
}

$script:PMTileSpec = @(
    @{ Kind = 'total';      Label = 'Modules run';    Blurb = 'Every module in the manifest, and how each one finished.' }
    @{ Kind = 'clean';      Label = 'Clean';          Blurb = 'Looked, found nothing to remove.' }
    @{ Kind = 'found';      Label = 'Found';          Blurb = 'Found something and left it alone, because this run or this module is not allowed to act.' }
    @{ Kind = 'applied';    Label = 'Cleaned up';     Blurb = 'Actually deleted something.' }
    @{ Kind = 'skipped';    Label = 'Skipped';        Blurb = 'Did not run at all: the category is not permitted, or it needs a logged-on user and there was none.' }
    @{ Kind = 'unverified'; Label = 'Could not check'; Blurb = 'Could not read the place it is responsible for, so "clean" would have been a guess. This is why the run reports failure.' }
    @{ Kind = 'partial';    Label = "Couldn't read";  Blurb = 'Individual spots that were locked or access-denied while scanning. The rest of the sweep is still valid; these are simply not covered.' }
    @{ Kind = 'errors';     Label = 'Errors';         Blurb = 'A module threw, or its removal was refused by the path guard.' }
)

$script:PMReportCss = @'
:root {
  color-scheme: light;
  --plane:#f9f9f7; --surface:#fcfcfb;
  --ink:#0b0b0b; --ink-2:#52514e; --muted:#898781;
  --rule:#e1e0d9; --border:rgba(11,11,11,0.10);
  --good:#0ca30c; --warning:#fab219; --serious:#ec835a; --critical:#d03b3b;
  --bar:#2a78d6; --bar-track:#cde2fb;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --plane:#0d0d0d; --surface:#1a1a19;
    --ink:#ffffff; --ink-2:#c3c2b7; --muted:#898781;
    --rule:#2c2c2a; --border:rgba(255,255,255,0.10);
    --bar:#3987e5; --bar-track:#184f95;
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --plane:#0d0d0d; --surface:#1a1a19;
  --ink:#ffffff; --ink-2:#c3c2b7; --muted:#898781;
  --rule:#2c2c2a; --border:rgba(255,255,255,0.10);
  --bar:#3987e5; --bar-track:#184f95;
}
* { box-sizing:border-box; }
body {
  margin:0; padding:32px 24px 64px;
  background:var(--plane); color:var(--ink);
  font-family:system-ui,-apple-system,"Segoe UI",sans-serif;
  font-size:15px; line-height:1.5;
}
.wrap { max-width:1080px; margin:0 auto; }
header { display:flex; align-items:baseline; gap:16px; flex-wrap:wrap; margin-bottom:4px; }
h1 { font-size:22px; font-weight:600; margin:0; letter-spacing:-0.01em; }
.sub { color:var(--ink-2); font-size:14px; margin:0 0 28px; }
.mode {
  display:inline-block; padding:3px 10px; border-radius:999px;
  font-size:12px; font-weight:600; letter-spacing:0.02em;
  border:1px solid var(--border);
}
.mode-report { color:var(--ink-2); }
.mode-apply { color:#fff; background:var(--good); border-color:transparent; }
.toggle {
  margin-left:auto; font:inherit; font-size:13px; cursor:pointer;
  background:var(--surface); color:var(--ink-2);
  border:1px solid var(--border); border-radius:6px; padding:5px 12px;
}
.hero {
  background:var(--surface); border:1px solid var(--border); border-radius:12px;
  padding:24px 26px; margin-bottom:16px;
}
.hero .label { color:var(--ink-2); font-size:14px; margin:0 0 6px; }
.hero .value { font-size:52px; font-weight:600; line-height:1.05; letter-spacing:-0.02em; margin:0; }
.hero .note { color:var(--muted); font-size:13px; margin:8px 0 0; }
.hint { color:var(--muted); font-size:13px; margin:0 0 10px; }
.notice { display:flex; align-items:flex-start; gap:10px; flex-wrap:wrap;
          padding:12px 14px; margin:0 0 24px; border-radius:10px;
          border:1px solid var(--rule); background:var(--surface);
          color:var(--ink-2); font-size:13px; }
.notice .badge { flex:none; }
.tiles { display:grid; grid-template-columns:repeat(auto-fit,minmax(170px,1fr)); gap:12px; margin-bottom:28px;
         align-items:start; }
.tile {
  background:var(--surface); border:1px solid var(--border); border-radius:10px;
}
.tile > summary {
  list-style:none; cursor:pointer; padding:16px 18px; position:relative; border-radius:10px;
  display:block;
}
.tile > summary::-webkit-details-marker { display:none; }
.tile > summary::after {
  content:''; position:absolute; right:16px; top:22px;
  width:7px; height:7px; border-right:2px solid var(--muted); border-bottom:2px solid var(--muted);
  transform:rotate(45deg); transition:transform .12s ease;
}
.tile[open] > summary::after { transform:rotate(-135deg); }
/* An open tile takes the full row. In a plain grid it would stretch its row's height and leave
   the neighbours floating in dead space, and the paths inside need the width anyway. */
.tile[open] { grid-column:1 / -1; }
.tile[open] .rows li { display:grid; grid-template-columns:minmax(140px,auto) minmax(90px,auto) 1fr;
                       gap:12px; align-items:baseline; }
.tile[open] .rows .rd { display:inline; margin-top:0; }
.tile > summary:hover { background:rgba(127,127,127,0.06); }
.tile > summary:focus-visible { outline:2px solid var(--bar); outline-offset:2px; }
.tile .label { display:block; color:var(--ink-2); font-size:13px; margin:0 0 4px; }
.tile .value { display:block; font-size:26px; font-weight:600; margin:0; letter-spacing:-0.01em; }
.tile.empty .value { color:var(--muted); }
.drawer { padding:0 18px 16px; border-top:1px solid var(--rule); margin-top:2px; }
.blurb { color:var(--ink-2); font-size:13px; margin:12px 0 10px; }
.rows { list-style:none; margin:0; padding:0; }
.rows li { padding:7px 0; border-top:1px solid var(--rule); font-size:13px; }
.rows .rk { font-weight:600; }
.rows .rv { color:var(--ink-2); margin-left:8px; font-variant-numeric:tabular-nums; }
.rows .rd { display:block; color:var(--muted); font-size:12px; margin-top:2px; word-break:break-word; }
.rows-empty { color:var(--muted); font-size:13px; margin:12px 0 0; }
@media print { .tile > summary::after { display:none } .drawer { display:block !important } }
h2 { font-size:14px; font-weight:600; text-transform:uppercase; letter-spacing:0.06em;
     color:var(--ink-2); margin:0 0 12px; }
.card {
  background:var(--surface); border:1px solid var(--border); border-radius:10px;
  padding:18px 20px; margin-bottom:12px;
}
.card-head { display:flex; align-items:center; gap:12px; flex-wrap:wrap; }
.card-head .name { font-weight:600; font-size:16px; }
.badge {
  display:inline-flex; align-items:center; gap:6px;
  font-size:12px; font-weight:600; padding:2px 9px; border-radius:999px;
  border:1px solid var(--border); color:var(--ink-2);
}
.badge .dot { width:8px; height:8px; border-radius:50%; flex:none; }
.badge .ic { font-size:11px; font-weight:700; letter-spacing:0.02em; }
.d-good{background:var(--good)} .d-warning{background:var(--warning)}
.d-critical{background:var(--critical)} .d-muted{background:var(--muted)}
.d-serious{background:var(--serious)}
.card .size { margin-left:auto; font-weight:600; font-size:16px; }
.card .detail { color:var(--ink-2); font-size:14px; margin:8px 0 0; }
.meter { height:6px; border-radius:3px; background:var(--bar-track); margin-top:14px; overflow:hidden; }
.meter > i { display:block; height:100%; background:var(--bar); border-radius:3px; }
table { width:100%; border-collapse:collapse; margin-top:14px; font-size:13px; }
th { text-align:left; font-weight:600; color:var(--ink-2); font-size:12px;
     text-transform:uppercase; letter-spacing:0.04em; padding:6px 8px; border-bottom:1px solid var(--rule); }
td { padding:6px 8px; border-bottom:1px solid var(--rule); color:var(--ink-2);
     font-variant-numeric:tabular-nums; }
td.path { color:var(--ink); font-family:ui-monospace,Consolas,monospace; font-size:12px;
          word-break:break-all; font-variant-numeric:normal; }
td.num { text-align:right; white-space:nowrap; }
.more { color:var(--muted); font-size:12px; margin:8px 0 0; }
footer { color:var(--muted); font-size:12px; margin-top:32px; padding-top:16px;
         border-top:1px solid var(--rule); }
@media print { .toggle { display:none } body { background:#fff } }
'@

function New-PMHtmlReport {
    <#
        Renders the run object the dispatcher already builds. Takes the SAME object that goes to
        run-<id>.json rather than re-deriving anything, so the HTML can never disagree with the
        machine-readable record.
    #>
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$OutPath
    )

    $isApply   = ($Run.mode -eq 'apply')
    $modules   = @($Run.modules)
    $totalBytes = [int64]0
    foreach ($m in $modules) { if ($m.bytes) { $totalBytes += [int64]$m.bytes } }
    $maxBytes = 0
    foreach ($m in $modules) { if ($m.bytes -and [int64]$m.bytes -gt $maxBytes) { $maxBytes = [int64]$m.bytes } }

    $heroLabel = if ($isApply) { 'Reclaimed this run' } else { 'Reclaimable now' }
    $heroNote  = if ($isApply) {
        'Removed by modules permitted to act. Everything else is listed below and left alone.'
    } else {
        'Nothing was deleted. This run only looked. Re-run with -Apply to act on the permitted modules.'
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine('<title>PC Maintenance Report</title>')
    [void]$sb.AppendLine('<style>' + $script:PMReportCss + '</style></head><body><div class="wrap">')

    $modeClass = if ($isApply) { 'mode mode-apply' } else { 'mode mode-report' }
    $modeText  = if ($isApply) { 'APPLY' } else { 'REPORT ONLY' }
    [void]$sb.AppendLine('<header><h1>PC Maintenance</h1>')
    [void]$sb.AppendLine('<span class="' + $modeClass + '">' + $modeText + '</span>')
    [void]$sb.AppendLine('<button class="toggle" onclick="var r=document.documentElement;r.dataset.theme=r.dataset.theme===''dark''?''light'':''dark''">Theme</button>')
    [void]$sb.AppendLine('</header>')
    [void]$sb.AppendLine('<p class="sub">Run ' + (ConvertTo-PMHtml $Run.runId) + ' &middot; ' +
        (ConvertTo-PMHtml ([datetime]$Run.startedUtc).ToLocalTime().ToString('dddd d MMMM yyyy, HH:mm')) + '</p>')

    # A run built on a GUESSED profile has to say so on the artifact, not only in the transcript
    # nobody opens. Status wears an icon and a label as well as a colour, never colour alone.
    if ($Run.interactiveUser -and $Run.interactiveUser.inferred) {
        [void]$sb.AppendLine('<p class="notice"><span class="badge"><span class="dot d-warning"></span>' +
            '<span class="ic">INFERRED USER</span></span><span>Nobody was observed signed in, so the profile ' +
            'below was taken from the registry and may be the wrong one. Per-user figures describe ' +
            'whichever profile was picked, and nothing was deleted for it.</span></p>')
    }

    # Hero figure: exactly one per view, the number the report exists to deliver.
    [void]$sb.AppendLine('<div class="hero"><p class="label">' + $heroLabel + '</p>')
    [void]$sb.AppendLine('<p class="value">' + (ConvertTo-PMHtml (Format-PMBytes $totalBytes)) + '</p>')
    [void]$sb.AppendLine('<p class="note">' + $heroNote + '</p></div>')

    # Every tile is a <details>: click or keyboard to expand the rows behind the number. Chosen
    # over any JS because the file is opened offline from Downloads, and <details> also survives
    # printing and screen readers without a line of script.
    [void]$sb.AppendLine('<p class="hint">Every number below opens. Click one to see what it counted.</p>')
    [void]$sb.AppendLine('<div class="tiles">')
    foreach ($spec in $script:PMTileSpec) {
        $rows = @(Get-PMTileRows -Kind $spec.Kind -Modules $modules)
        $n = $rows.Count
        $cls = if ($n) { 'tile' } else { 'tile empty' }
        [void]$sb.AppendLine('<details class="' + $cls + '"><summary><span class="label">' +
            (ConvertTo-PMHtml $spec.Label) + '</span><span class="value">' + $n + '</span></summary>')
        [void]$sb.AppendLine('<div class="drawer"><p class="blurb">' + (ConvertTo-PMHtml $spec.Blurb) + '</p>')
        if ($n) {
            [void]$sb.AppendLine('<ul class="rows">')
            foreach ($r in $rows) {
                $v = if ($r.V) { '<span class="rv">' + (ConvertTo-PMHtml $r.V) + '</span>' } else { '' }
                [void]$sb.AppendLine('<li><span class="rk">' + (ConvertTo-PMHtml $r.K) + '</span>' + $v +
                    '<span class="rd">' + (ConvertTo-PMHtml $r.D) + '</span></li>')
            }
            [void]$sb.AppendLine('</ul>')
        } else {
            [void]$sb.AppendLine('<p class="rows-empty">None this run.</p>')
        }
        [void]$sb.AppendLine('</div></details>')
    }
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<h2>Modules</h2>')
    foreach ($m in $modules) {
        $p = Get-PMStatusPresentation -Status ([string]$m.status)
        $bytes = if ($m.bytes) { [int64]$m.bytes } else { [int64]0 }
        [void]$sb.AppendLine('<div class="card"><div class="card-head">')
        [void]$sb.AppendLine('<span class="name">' + (ConvertTo-PMHtml $m.id) + '</span>')
        [void]$sb.AppendLine('<span class="badge"><span class="dot d-' + $p.Role + '"></span><span class="ic">' +
            (ConvertTo-PMHtml $p.Icon) + '</span>' + (ConvertTo-PMHtml $p.Word) + '</span>')
        if ($bytes -gt 0) { [void]$sb.AppendLine('<span class="size">' + (ConvertTo-PMHtml (Format-PMBytes $bytes)) + '</span>') }
        [void]$sb.AppendLine('</div>')
        [void]$sb.AppendLine('<p class="detail">' + (ConvertTo-PMHtml $m.detail) + '</p>')

        if ($bytes -gt 0 -and $maxBytes -gt 0) {
            $pct = [int](100 * $bytes / $maxBytes)
            if ($pct -lt 2) { $pct = 2 }
            [void]$sb.AppendLine('<div class="meter"><i style="width:' + $pct + '%"></i></div>')
        }

        $items = @($m.items)
        if ($items.Count) {
            [void]$sb.AppendLine('<table><thead><tr><th>Path</th><th class="num">Size</th><th class="num">Age</th></tr></thead><tbody>')
            foreach ($i in ($items | Select-Object -First 15)) {
                $age = if ($null -ne $i.ageDays) { "$($i.ageDays)d" } elseif ($null -ne $i.idleDays) { "$($i.idleDays)d" } else { '' }
                $ib = if ($i.bytes) { Format-PMBytes ([int64]$i.bytes) } else { '' }
                [void]$sb.AppendLine('<tr><td class="path">' + (ConvertTo-PMHtml $i.path) + '</td><td class="num">' +
                    (ConvertTo-PMHtml $ib) + '</td><td class="num">' + (ConvertTo-PMHtml $age) + '</td></tr>')
            }
            [void]$sb.AppendLine('</tbody></table>')
            $shown = [Math]::Min(15, $items.Count)
            $trueCount = if ($null -ne $m.count) { [int]$m.count } else { $items.Count }
            if ($trueCount -gt $shown) {
                [void]$sb.AppendLine('<p class="more">Showing ' + $shown + ' of ' + $trueCount + '. The full list is in the run JSON beside this report.</p>')
            }
        }
        [void]$sb.AppendLine('</div>')
    }

    [void]$sb.AppendLine('<footer>Generated by pc-maintenance ' + (ConvertTo-PMHtml $Run.version) +
        '. Report only unless the header says APPLY. Machine-readable record: run-' +
        (ConvertTo-PMHtml $Run.runId) + '.json</footer>')
    [void]$sb.AppendLine('</div></body></html>')

    $dir = Split-Path -Parent $OutPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($OutPath, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
    return $OutPath
}
