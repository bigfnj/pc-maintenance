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
        'error'    { @{ Role = 'critical'; Icon = 'X';    Word = 'Error' } }
        default    { @{ Role = 'muted';    Icon = '?';    Word = $Status } }
    }
}

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
.tiles { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-bottom:28px; }
.tile {
  background:var(--surface); border:1px solid var(--border); border-radius:10px; padding:16px 18px;
}
.tile .label { color:var(--ink-2); font-size:13px; margin:0 0 4px; }
.tile .value { font-size:26px; font-weight:600; margin:0; letter-spacing:-0.01em; }
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

    # Hero figure: exactly one per view, the number the report exists to deliver.
    [void]$sb.AppendLine('<div class="hero"><p class="label">' + $heroLabel + '</p>')
    [void]$sb.AppendLine('<p class="value">' + (ConvertTo-PMHtml (Format-PMBytes $totalBytes)) + '</p>')
    [void]$sb.AppendLine('<p class="note">' + $heroNote + '</p></div>')

    $s = $Run.summary
    [void]$sb.AppendLine('<div class="tiles">')
    foreach ($t in @(
        @{ L = 'Modules run'; V = $s.total },
        @{ L = 'Clean';       V = $s.clean },
        @{ L = 'Found';       V = $s.found },
        @{ L = 'Acted on';    V = $s.applied },
        @{ L = 'Skipped';     V = $s.skipped },
        @{ L = 'Errors';      V = $s.errors })) {
        [void]$sb.AppendLine('<div class="tile"><p class="label">' + $t.L + '</p><p class="value">' + $t.V + '</p></div>')
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
