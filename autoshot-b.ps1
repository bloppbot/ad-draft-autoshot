param(
    [string]$OutPath = "",
    [string]$SteamApiKey = "",   # or put "SteamApiKey" into autoshot-b.config.json
    [switch]$Calibrate,          # capture the screen now, draw the card boxes into calibration.png, print the hero names read
    [string]$TestImage = "",     # with -Calibrate: use a saved screenshot instead of the live screen
    [string]$RosterBefore = "",  # with -Calibrate -TestImage: a saved GetRealtimeStats JSON (before swaps) ...
    [string]$RosterAfter = ""    # ... and one after swaps; runs the whole correction on the test image
)

# ============================================================================
#  AD Draft AutoShot  B  (swap correction via Steam Web API)
#
#  A: the moment Dota flips from drafting to STRATEGY TIME the screen is
#     captured into screenshot.png, exactly like the original AutoShot.
#     That capture is the clean board (once players start swapping, the
#     board on screen goes wrong, so it must be taken right away).
#  B: from that moment until the horn, the live roster of the match is
#     pulled from Valve's API every few seconds (which player has which
#     hero). When two players trade heroes, the two PLAYER NAMES are
#     exchanged inside screenshot.png. The overlay keeps showing the same
#     file, now correct.
#
#  Needs: a free Steam Web API key (https://steamcommunity.com/dev/apikey)
#  and the streamer's Steam profile with public "Game details" (that is how
#  the match's game server id is found). Pure Windows PowerShell otherwise.
# ============================================================================

$Port = 3211
$DelayMs = 500              # wait after the phase flip before capturing the board
$CooldownSec = 60           # ignore repeated STRATEGY_TIME flips for this long
$RosterPollSec = 5          # Steam API polling interval while swaps are possible
$MaxWatchSec = 900          # safety stop for the watcher
$SteamId64 = ""             # streamer's steam64; empty = taken from Dota's GSI "player" block automatically
$ExtraSteamIds = @()        # fallback steam64s of teammates with public game details, tried if the streamer's is private
$HudCenterOffset = 0        # px; only if the game UI is not centered on the primary monitor
$AssumeBoardOrderMatchesRoster = $false   # $true = skip OCR, trust that card order == team slot order (see README)
$DebugImages = $true        # write debug_board.png next to the screenshot

$Strategy = "DOTA_GAMERULES_STATE_STRATEGY_TIME"
$PreGame  = "DOTA_GAMERULES_STATE_PRE_GAME"
$InGame   = "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS"
$HeroSel  = "DOTA_GAMERULES_STATE_HERO_SELECTION"

# ---- board layout, in units of screen HEIGHT, x relative to the screen center --
# Measured on 16:9 captures. Dota scales its UI with the height and centers
# it, so the numbers hold for 1080p, 1440p and 4K. -Calibrate shows the boxes.
$L = @{
    RowTop0 = 0.1426; RowPitch = 0.1562           # first card top, card to card distance
    HeroNameY = -0.006; HeroNameH = 0.034         # hero name text, relative to card top
    RadHeroNameX0 = -0.700; RadHeroNameX1 = -0.470
    DireHeroNameX0 = 0.454; DireHeroNameX1 = 0.690
    NameY = 0.0213; NameH = 0.0259                # player name strip, relative to card top
    RadNameX0 = -0.664; RadNameX1 = -0.474
    DireNameX0 = 0.472; DireNameX1 = 0.663
}

if ($OutPath -eq "") { $OutPath = Join-Path $PSScriptRoot "screenshot.png" }
$BasePath = [System.IO.Path]::ChangeExtension($OutPath, ".base.png")
$ConfigPath = Join-Path $PSScriptRoot "autoshot-b.config.json"
$HeroListPath = Join-Path $PSScriptRoot "heroes.json"

if (Test-Path $ConfigPath) {
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($p in $cfg.PSObject.Properties) {
            if ($p.Name -eq "Layout") { foreach ($q in $p.Value.PSObject.Properties) { $L[$q.Name] = [double]$q.Value } }
            elseif ($p.Name -eq "SteamApiKey") { if ($SteamApiKey -eq "") { $SteamApiKey = [string]$p.Value } }
            elseif (Get-Variable -Name $p.Name -Scope Script -ErrorAction SilentlyContinue) { Set-Variable -Name $p.Name -Value $p.Value -Scope Script }
        }
    } catch { Write-Host "config file ignored: $($_.Exception.Message)" }
}
$ExtraSteamIds = @($ExtraSteamIds | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "" })

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = "SilentlyContinue"

Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -ErrorAction Stop @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class AdShot {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static Bitmap Capture() {
        var b = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
        var bmp = new Bitmap(b.Width, b.Height, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(b.Location, Point.Empty, b.Size);
        return bmp;
    }
    public static Bitmap CropScale(Image src, Rectangle r, int scale) {
        var o = new Bitmap(r.Width * scale, r.Height * scale, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(o)) {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.DrawImage(src, new Rectangle(0, 0, o.Width, o.Height), r, GraphicsUnit.Pixel);
        }
        return o;
    }
    public static Bitmap Contrast(Bitmap src) {   // grayscale, stretched, inverted: helps OCR on stylized text
        var o = new Bitmap(src.Width, src.Height, PixelFormat.Format24bppRgb);
        int lo = 255, hi = 0;
        for (int y = 0; y < src.Height; y++) for (int x = 0; x < src.Width; x++) { var c = src.GetPixel(x, y); int v = Math.Max(c.R, Math.Max(c.G, c.B)); if (v < lo) lo = v; if (v > hi) hi = v; }
        if (hi - lo < 10) hi = lo + 10;
        for (int y = 0; y < src.Height; y++) for (int x = 0; x < src.Width; x++) { var c = src.GetPixel(x, y); int v = Math.Max(c.R, Math.Max(c.G, c.B)); v = (int)Math.Round(255.0 * (v - lo) / (hi - lo)); v = 255 - Math.Max(0, Math.Min(255, v)); o.SetPixel(x, y, Color.FromArgb(v, v, v)); }
        return o;
    }
    public static void SwapRects(Bitmap img, Rectangle a, Rectangle b) {
        using (var ca = img.Clone(a, img.PixelFormat)) using (var cb = img.Clone(b, img.PixelFormat)) using (var g = Graphics.FromImage(img)) {
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImage(cb, a); g.DrawImage(ca, b);
        }
    }
    public static void DrawRect(Bitmap img, Rectangle r, Color c, string label) {
        using (var g = Graphics.FromImage(img)) using (var p = new Pen(c, 2)) using (var f = new Font("Arial", 10, FontStyle.Bold)) using (var br = new SolidBrush(c)) {
            g.DrawRectangle(p, r); if (!string.IsNullOrEmpty(label)) g.DrawString(label, f, br, r.X, r.Y + r.Height);
        }
    }
    public static int Lev(string a, string b) {
        var d = new int[a.Length + 1, b.Length + 1];
        for (int i = 0; i <= a.Length; i++) d[i, 0] = i; for (int j = 0; j <= b.Length; j++) d[0, j] = j;
        for (int i = 1; i <= a.Length; i++) for (int j = 1; j <= b.Length; j++) {
            int c = a[i - 1] == b[j - 1] ? 0 : 1;
            d[i, j] = Math.Min(Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1), d[i - 1, j - 1] + c);
        }
        return d[a.Length, b.Length];
    }
}
"@
[AdShot]::SetProcessDPIAware() | Out-Null

function Log($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $msg) }

# ---- hero list -------------------------------------------------------------------
$Heroes = Get-Content $HeroListPath -Raw -Encoding UTF8 | ConvertFrom-Json
function Norm($s) { return (($s.ToUpperInvariant()) -replace "[^A-Z]", "") }
$HeroKeys = @{}; $HeroById = @{}
foreach ($h in $Heroes) { $HeroKeys[$h.name] = Norm $h.localized_name; $HeroById[[int]$h.id] = $h.name }
function Hero-Name($id) { if ($HeroById.ContainsKey([int]$id)) { return $HeroById[[int]$id] }; return "hero$id" }

# ---- geometry ----------------------------------------------------------------------
function Geo($W, $H) {
    $cx = [double]$W / 2 + $HudCenterOffset
    $g = @{ W = $W; H = $H; Rows = @() }
    for ($t = 0; $t -lt 2; $t++) {
        for ($r = 0; $r -lt 5; $r++) {
            $top = ($L.RowTop0 + $r * $L.RowPitch) * $H
            if ($t -eq 0) { $hx0 = $L.RadHeroNameX0; $hx1 = $L.RadHeroNameX1; $nx0 = $L.RadNameX0; $nx1 = $L.RadNameX1 }
            else          { $hx0 = $L.DireHeroNameX0; $hx1 = $L.DireHeroNameX1; $nx0 = $L.DireNameX0; $nx1 = $L.DireNameX1 }
            $g.Rows += @{
                Team = $t; Index = $r
                HeroRect = New-Object System.Drawing.Rectangle([int]($cx + $hx0 * $H), [int]($top + $L.HeroNameY * $H), [int](($hx1 - $hx0) * $H), [int]($L.HeroNameH * $H))
                NameRect = New-Object System.Drawing.Rectangle([int]($cx + $nx0 * $H), [int]($top + $L.NameY * $H), [int](($nx1 - $nx0) * $H), [int]($L.NameH * $H))
            }
        }
    }
    return $g
}

# ---- OCR (Windows built-in) ----------------------------------------------------------
$OcrOk = $false
try {
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    $script:AsTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($null -eq $script:OcrEngine) { $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language "en-US")) }
    if ($null -ne $script:OcrEngine) { $OcrOk = $true }
} catch { $OcrOk = $false }
function Await($op, $type) { $t = $script:AsTask.MakeGenericMethod($type).Invoke($null, @($op)); $t.Wait(); $t.Result }
function Ocr-Lines([System.Drawing.Bitmap]$bmp) {
    $tmp = Join-Path $env:TEMP ("adshot_ocr_" + [guid]::NewGuid().ToString("N") + ".png")
    $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
    $out = @()
    try {
        $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
        $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $sb = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $res = Await ($script:OcrEngine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
        $stream.Dispose()
        foreach ($line in $res.Lines) {
            $x0 = 1e9; $y0 = 1e9; $x1 = 0; $y1 = 0
            foreach ($w in $line.Words) { $r = $w.BoundingRect; if ($r.X -lt $x0) { $x0 = $r.X }; if ($r.Y -lt $y0) { $y0 = $r.Y }; if ($r.X + $r.Width -gt $x1) { $x1 = $r.X + $r.Width }; if ($r.Y + $r.Height -gt $y1) { $y1 = $r.Y + $r.Height } }
            $out += @{ Text = $line.Text; X = $x0; Y = $y0; W = ($x1 - $x0); H = ($y1 - $y0) }
        }
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    return $out
}
function Ocr-Text([System.Drawing.Bitmap]$bmp) { return ((Ocr-Lines $bmp) | ForEach-Object { $_.Text }) -join "`n" }
function Match-HeroName($text) {
    $n = Norm $text; if ($n.Length -lt 3) { return $null }
    $best = $null; $b1 = 99; $b2 = 99
    foreach ($k in $HeroKeys.Keys) {
        $d = [AdShot]::Lev($n, $HeroKeys[$k])
        if ($d -lt $b1) { $b2 = $b1; $b1 = $d; $best = $k } elseif ($d -lt $b2) { $b2 = $d }
    }
    $allow = [math]::Max(1, [math]::Floor($n.Length * 0.34))
    if ($b1 -le $allow -and $b2 -gt $b1) { return $best }
    if ($n.Length -ge 5) {   # a cut-off first word ("STORM" for STORM SPIRIT): accept a unique prefix
        $pref = @($HeroKeys.Keys | Where-Object { $HeroKeys[$_].StartsWith($n) })
        if ($pref.Count -eq 1) { return $pref[0] }
    }
    return $null
}

# ---- board reading: which hero is on which card ------------------------------------------
function Read-Board([System.Drawing.Bitmap]$img, $g) {
    $map = @{}   # heroName -> row
    if ($AssumeBoardOrderMatchesRoster) { Log "board: OCR skipped (AssumeBoardOrderMatchesRoster)"; return $map }
    if (-not $OcrOk) { Log "board: Windows OCR not available, swap correction disabled"; return $map }
    $dbg = $null; if ($DebugImages) { $dbg = New-Object System.Drawing.Bitmap($img) }
    $found = @{}; $seen = @{}
    foreach ($t in 0, 1) {   # pass 1: one OCR per team column, lines assigned to cards by vertical position
        $rows = @($g.Rows | Where-Object { $_.Team -eq $t })
        $first = $rows[0].HeroRect; $last = $rows[4].HeroRect
        $col = New-Object System.Drawing.Rectangle($first.X, [math]::Max(0, $first.Y - 4), $first.Width, ($last.Bottom + 4 - [math]::Max(0, $first.Y - 4)))
        $scale = 2
        foreach ($variant in 0, 1) {
            $crop = [AdShot]::CropScale($img, $col, $scale)
            if ($variant -eq 1) { $c2 = [AdShot]::Contrast($crop); $crop.Dispose(); $crop = $c2 }
            $lines = @(); try { $lines = Ocr-Lines $crop } catch { $lines = @() }
            $crop.Dispose()
            foreach ($ln in $lines) {
                $yc = $col.Y + ($ln.Y + $ln.H / 2) / $scale
                $best = -1; $bestD = 1e9
                for ($r = 0; $r -lt 5; $r++) { $d = [math]::Abs($yc - ($rows[$r].HeroRect.Y + $rows[$r].HeroRect.Height / 2)); if ($d -lt $bestD) { $bestD = $d; $best = $r } }
                if ($bestD -gt $rows[0].HeroRect.Height) { continue }
                $key = "$t-$best"; $seen[$key] += "|" + $ln.Text.Trim()
                if (-not $found.ContainsKey($key)) { $m = Match-HeroName $ln.Text; if ($m) { $found[$key] = $m } }
            }
            if (@($found.Keys | Where-Object { $_ -like "$t-*" }).Count -eq 5) { break }
        }
    }
    foreach ($row in $g.Rows) {   # pass 2: unknown cards get their own crops (3x, 3x contrast, 4x padded, 4x padded contrast)
        $key = "$($row.Team)-$($row.Index)"
        if ($found.ContainsKey($key)) { continue }
        $pad = [int]($g.H * 0.008)
        $padded = New-Object System.Drawing.Rectangle([math]::Max(0, $row.HeroRect.X - $pad), [math]::Max(0, $row.HeroRect.Y - $pad), ($row.HeroRect.Width + 2 * $pad), ($row.HeroRect.Height + 2 * $pad))
        foreach ($variant in 0, 1, 2, 3) {
            if ($variant -lt 2) { $crop = [AdShot]::CropScale($img, $row.HeroRect, 3) } else { $crop = [AdShot]::CropScale($img, $padded, 4) }
            if ($variant % 2 -eq 1) { $c2 = [AdShot]::Contrast($crop); $crop.Dispose(); $crop = $c2 }
            $txt = ""; try { $txt = Ocr-Text $crop } catch { $txt = "" }
            $crop.Dispose()
            foreach ($line in ($txt -split "[\r\n]+")) { if ($line.Trim() -ne "") { $seen[$key] += "|" + $line.Trim(); $m = Match-HeroName $line; if ($m) { $found[$key] = $m; break } } }
            if ($found.ContainsKey($key)) { break }
        }
    }
    foreach ($row in $g.Rows) {
        $key = "$($row.Team)-$($row.Index)"; $hero = $null; if ($found.ContainsKey($key)) { $hero = $found[$key] }
        $teamName = "Radiant"; if ($row.Team -eq 1) { $teamName = "Dire" }
        if ($hero -and $map.ContainsKey($hero)) { Log ("board: {0} card {1} reads as {2} twice, ignoring the duplicate" -f $teamName, ($row.Index + 1), $hero); $hero = $null }
        if ($hero) { $map[$hero] = $row; Log ("board: {0} card {1} = {2}" -f $teamName, ($row.Index + 1), $hero) }
        else { Log ("board: {0} card {1} = ? (read: {2})" -f $teamName, ($row.Index + 1), $seen[$key]) }
        if ($dbg) { $lab = "?"; if ($hero) { $lab = $hero }; [AdShot]::DrawRect($dbg, $row.HeroRect, [System.Drawing.Color]::Yellow, $lab); [AdShot]::DrawRect($dbg, $row.NameRect, [System.Drawing.Color]::Cyan, "") }
    }
    if ($dbg) { $dbg.Save((Join-Path (Split-Path $OutPath) "debug_board.png"), [System.Drawing.Imaging.ImageFormat]::Png); $dbg.Dispose() }
    return $map
}

# ---- Steam Web API ------------------------------------------------------------------------------
function Steam-Get($url) { return Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15 -UseBasicParsing }
function Get-ServerId {
    # game server steam id of the match one of the known players is in; needs public "Game details" on that profile
    $ids = @(); if ($script:LocalSteamId) { $ids += $script:LocalSteamId }; if ($SteamId64 -ne "") { $ids += $SteamId64 }; $ids += $ExtraSteamIds
    $ids = @($ids | Select-Object -Unique); if ($ids.Count -eq 0) { return $null }
    try {
        $r = Steam-Get ("https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key=$SteamApiKey&steamids=" + ($ids -join ","))
        foreach ($p in $r.response.players) {
            $sid = [string]$p.gameserversteamid
            if ($sid -and $sid -ne "0" -and [string]$p.gameid -eq "570") { return $sid }
        }
    } catch {
        $m = $_.Exception.Message; if ($m -match "403") { $m += " (403 = the Steam API key is wrong)" }
        Log "GetPlayerSummaries failed: $m"
    }
    return $null
}
function Parse-Roster($json) {
    # -> array of @{Account; Name; Team(0 radiant/1 dire); Hero(name); HeroId; Slot}, or $null if not a complete 10-player roster
    $players = @()
    foreach ($team in @($json.teams)) {
        $t = -1; if ([int]$team.team_number -eq 2) { $t = 0 } elseif ([int]$team.team_number -eq 3) { $t = 1 }
        if ($t -lt 0) { continue }
        $slot = 0
        foreach ($p in @($team.players)) {
            $hid = 0; try { $hid = [int]$p.heroid } catch { $hid = 0 }
            $players += @{ Account = [string]$p.accountid; Name = [string]$p.name; Team = $t; HeroId = $hid; Hero = (Hero-Name $hid); Slot = $slot }
            $slot++
        }
    }
    if ($players.Count -ne 10) { return $null }
    if (@($players | Where-Object { $_.HeroId -le 0 }).Count -gt 0) { return $null }
    return $players
}
function Get-Roster($serverId) {
    try {
        $r = Steam-Get "https://api.steampowered.com/IDOTA2MatchStats_570/GetRealtimeStats/v1/?key=$SteamApiKey&server_steam_id=$serverId"
        return (Parse-Roster $r)
    } catch { Log "GetRealtimeStats failed: $($_.Exception.Message)"; return $null }
}
function Fmt-Roster($ros) {
    $a = @($ros | Where-Object { $_.Team -eq 0 } | ForEach-Object { "$($_.Name)=$($_.Hero)" }); $b = @($ros | Where-Object { $_.Team -eq 1 } | ForEach-Object { "$($_.Name)=$($_.Hero)" })
    return ("R: " + ($a -join ", ") + "  |  D: " + ($b -join ", "))
}

# ---- correction ------------------------------------------------------------------------------------
$script:Game = $null
$script:LocalSteamId = ""
function Save-Atomic([System.Drawing.Bitmap]$bmp, $path) { $tmp = "$path.tmp"; $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png); Move-Item -Force $tmp $path }
function Capture-Board {
    Start-Sleep -Milliseconds $DelayMs
    $bmp = [AdShot]::Capture()
    Save-Atomic $bmp $OutPath
    $bmp.Save($BasePath, [System.Drawing.Imaging.ImageFormat]::Png)
    Log "screenshot saved -> $OutPath ($($bmp.Width)x$($bmp.Height))"
    $g = Geo $bmp.Width $bmp.Height
    $rows = Read-Board $bmp $g
    $bmp.Dispose()
    $script:Game = @{ Geo = $g; Rows = $rows; ServerId = $null; Baseline = $null; Swaps = @(); Polls = 0; Started = Get-Date; Done = $false }
}
function Row-Of($player) {
    # the board card that belongs to a roster entry (by its hero at draft time, or by slot order)
    if ($AssumeBoardOrderMatchesRoster) { return ($script:Game.Geo.Rows | Where-Object { $_.Team -eq $player.Team -and $_.Index -eq $player.Slot } | Select-Object -First 1) }
    if ($script:Game.Rows.ContainsKey($player.Hero)) { return $script:Game.Rows[$player.Hero] }
    return $null
}
function Apply-Swaps {
    $bmp = New-Object System.Drawing.Bitmap($BasePath)
    foreach ($s in $script:Game.Swaps) { [AdShot]::SwapRects($bmp, $s.A, $s.B) }
    Save-Atomic $bmp $OutPath; $bmp.Dispose()
    Log "screenshot.png rewritten with $($script:Game.Swaps.Count) name swap(s)"
}
function Process-Roster($ros, [bool]$final) {
    # compares the live roster with the draft-time baseline and exchanges names on the board for every traded pair
    $G = $script:Game
    if ($null -eq $G.Baseline) {
        $G.Baseline = @{}; foreach ($p in $ros) { $G.Baseline[$p.Account] = $p }
        Log ("roster baseline: " + (Fmt-Roster $ros))
        foreach ($p in $ros) { if (-not (Row-Of $p)) { Log "  note: no board card found for $($p.Name) ($($p.Hero)); a swap involving this player cannot be corrected" } }
        return
    }
    $changed = @($ros | Where-Object { $G.Baseline.ContainsKey($_.Account) -and $G.Baseline[$_.Account].HeroId -ne $_.HeroId })
    if ($changed.Count -eq 0) { if ($final) { Log "final roster check: no swap" }; return }
    $handled = @{}
    foreach ($p in $changed) {
        if ($handled.ContainsKey($p.Account)) { continue }
        $bp = $G.Baseline[$p.Account]
        $partner = $changed | Where-Object { $_.Account -ne $p.Account -and $_.Team -eq $p.Team -and $_.HeroId -eq $bp.HeroId -and $G.Baseline[$_.Account].HeroId -eq $p.HeroId } | Select-Object -First 1
        if ($null -eq $partner) { Log "$($p.Name) changed $($bp.Hero) -> $($p.Hero) but no matching partner yet, waiting"; continue }
        $bq = $G.Baseline[$partner.Account]
        $ra = Row-Of $bp; $rb = Row-Of $bq
        if ($null -eq $ra -or $null -eq $rb) { Log "SWAP: $($p.Name) <-> $($partner.Name) ($($bp.Hero) <-> $($bq.Hero)), but a board card is unknown, cannot correct" }
        else { $G.Swaps += @{ A = $ra.NameRect; B = $rb.NameRect }; Log "SWAP: $($p.Name) now plays $($p.Hero), $($partner.Name) now plays $($partner.Hero) -> names exchanged on the board" }
        # from now on these two are the baseline (so a swap back is detected too)
        $G.Baseline[$p.Account] = @{ Account = $p.Account; Name = $p.Name; Team = $p.Team; HeroId = $p.HeroId; Hero = $p.Hero; Slot = $bp.Slot }
        $G.Baseline[$partner.Account] = @{ Account = $partner.Account; Name = $partner.Name; Team = $partner.Team; HeroId = $partner.HeroId; Hero = $partner.Hero; Slot = $bq.Slot }
        $handled[$p.Account] = $true; $handled[$partner.Account] = $true
        Apply-Swaps
    }
}
function Poll-Roster([bool]$final) {
    $G = $script:Game; if ($null -eq $G -or $G.Done) { return }
    $G.Polls++
    if ($null -eq $G.ServerId) {
        $G.ServerId = Get-ServerId
        if ($null -eq $G.ServerId) { Log "match server not found yet (profile private, or Steam not reporting the game yet), retrying"; return }
        Log "match server id: $($G.ServerId)"
    }
    $ros = Get-Roster $G.ServerId
    if ($null -eq $ros) { Log "roster not complete yet, retrying"; return }
    Process-Roster $ros $final
}

# ---- calibration / test mode -------------------------------------------------------------------------
if ($Calibrate) {
    if ($TestImage -ne "") { $bmp = New-Object System.Drawing.Bitmap($TestImage); Log "test image $TestImage ($($bmp.Width)x$($bmp.Height))" }
    else { Start-Sleep -Seconds 3; $bmp = [AdShot]::Capture(); Log "captured the screen ($($bmp.Width)x$($bmp.Height))" }
    $g = Geo $bmp.Width $bmp.Height
    $dbg = New-Object System.Drawing.Bitmap($bmp)
    foreach ($row in $g.Rows) { [AdShot]::DrawRect($dbg, $row.HeroRect, [System.Drawing.Color]::Yellow, "hero"); [AdShot]::DrawRect($dbg, $row.NameRect, [System.Drawing.Color]::Cyan, "name") }
    $calPath = Join-Path (Split-Path $OutPath) "calibration.png"; $dbg.Save($calPath, [System.Drawing.Imaging.ImageFormat]::Png); $dbg.Dispose()
    Log "boxes drawn -> $calPath (yellow = hero name read, cyan = name strip that gets swapped)"
    $rows = Read-Board $bmp $g
    Log ("board reading: {0} hero names recognized (OCR available: {1})" -f $rows.Count, $OcrOk)
    if ($RosterBefore -ne "" -and $RosterAfter -ne "") {
        $bmp.Save($BasePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $script:Game = @{ Geo = $g; Rows = $rows; ServerId = "test"; Baseline = $null; Swaps = @(); Polls = 0; Started = Get-Date; Done = $false }
        $r1 = Parse-Roster (Get-Content $RosterBefore -Raw | ConvertFrom-Json); $r2 = Parse-Roster (Get-Content $RosterAfter -Raw | ConvertFrom-Json)
        if ($null -eq $r1 -or $null -eq $r2) { Log "test rosters not complete (10 players with heroid needed)" }
        else { Process-Roster $r1 $false; Process-Roster $r2 $true; Log "test result -> $OutPath" }
    }
    $bmp.Dispose()
    exit 0
}

# ---- main loop -----------------------------------------------------------------------------------------
if ($SteamApiKey -eq "") { Log "WARNING: no SteamApiKey (autoshot-b.config.json). Screenshots will work, swap correction will not." }
if (-not $OcrOk -and -not $AssumeBoardOrderMatchesRoster) { Log "WARNING: Windows OCR not available on this PC; screenshots still work, swap correction will not" }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Log "autoshot B listening on localhost:$Port, target: $OutPath"
Log "waiting for Dota... (this window logs every phase change)"

$prevState = $null; $lastShot = [DateTime]::MinValue; $nextPoll = [DateTime]::MaxValue; $finalDue = [DateTime]::MaxValue
$ctxTask = $listener.GetContextAsync()
while ($listener.IsListening) {
    if ($ctxTask.Wait(250)) {
        $ctx = $ctxTask.Result; $ctxTask = $listener.GetContextAsync()
        $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream, $ctx.Request.ContentEncoding)).ReadToEnd()
        $ctx.Response.StatusCode = 200; $ctx.Response.Close()
        $state = $null
        try {
            $data = $body | ConvertFrom-Json
            if ($data -and $data.map) { $state = $data.map.game_state }
            if ($data -and $data.player -and $data.player.steamid) { $script:LocalSteamId = [string]$data.player.steamid }
        } catch { $state = $null }
        if ($null -ne $state -and $state -ne $prevState) {
            if ($state -eq $Strategy) {
                if (((Get-Date) - $lastShot).TotalSeconds -lt $CooldownSec) { Log "strategy time again within cooldown, ignoring" }
                else {
                    Log "$prevState -> $state : capturing in $($DelayMs)ms"
                    try { Capture-Board } catch { Log "capture failed: $($_.Exception.Message)" }
                    $lastShot = Get-Date
                    if ($SteamApiKey -ne "" -and $null -ne $script:Game) { Log "watching the live roster every $RosterPollSec s until the horn"; $nextPoll = (Get-Date).AddSeconds(1) }
                }
            }
            elseif ($state -eq $InGame -and $null -ne $script:Game -and -not $script:Game.Done) {
                Log "horn: one final roster check"; $finalDue = (Get-Date).AddSeconds(4); $nextPoll = [DateTime]::MaxValue
            }
            elseif ($state -eq $HeroSel) { $script:Game = $null; $nextPoll = [DateTime]::MaxValue; $finalDue = [DateTime]::MaxValue; Log "game_state: $state (new draft)" }
            else { Log "game_state: $state" }
            $prevState = $state
        }
    }
    $now = Get-Date
    if ($now -ge $nextPoll) {
        try { Poll-Roster $false } catch { Log "roster check failed: $($_.Exception.Message)" }
        $nextPoll = $now.AddSeconds($RosterPollSec)
        if ($null -ne $script:Game -and ($now - $script:Game.Started).TotalSeconds -gt $MaxWatchSec) { $script:Game.Done = $true; $nextPoll = [DateTime]::MaxValue; Log "watcher stopped (time limit)" }
    }
    if ($now -ge $finalDue) {
        try { Poll-Roster $true } catch { Log "final roster check failed: $($_.Exception.Message)" }
        $finalDue = [DateTime]::MaxValue
        if ($null -ne $script:Game) { $script:Game.Done = $true; Log "watcher done for this game ($($script:Game.Swaps.Count) swap(s) corrected)" }
    }
}
