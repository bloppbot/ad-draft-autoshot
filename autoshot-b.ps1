param(
    [string]$OutPath = "",
    [switch]$Calibrate,          # capture the screen right now, draw all detection boxes into calibration.png, print what is recognized
    [string]$TestImage = "",     # use a PNG/JPG instead of the live screen (with -Calibrate), for checking geometry on a saved screenshot
    [string]$TestBoard = "",     # with -TestImage: also treat the image as the draft board and run the name reading on it
    [switch]$SwapDemo            # with -Calibrate -TestImage: exchange the name strips of Radiant cards 1 and 3 and save swap_demo.png
)

# ============================================================================
#  AD Draft AutoShot  B  (swap-aware)
#
#  A: the moment Dota flips from drafting to STRATEGY TIME the screen is
#     captured into screenshot.png (same as the original AutoShot).
#  B: hero swaps that happen after that (strategy time, pre-game, up to the
#     horn) are detected from the hero portraits in the top bar and the
#     PLAYER NAMES in screenshot.png are exchanged accordingly, so the board
#     your overlay shows stays correct. No API key, no internet during the
#     game (hero portraits are downloaded once from Valve's CDN), pure
#     Windows PowerShell.
#
#  How the correction works:
#    1. Draft board capture (strategy time) -> screenshot.png + screenshot.base.png
#       The board is read once: hero name per card (Windows OCR, English UI).
#    2. From PRE-GAME on, every few seconds the ten top-bar portraits are
#       matched against the hero art. The first reading is the baseline.
#    3. If two portraits of the same team trade places, the two players swapped.
#       The name strips of those two cards are exchanged in screenshot.png.
#    4. One last reading at the horn, then it stops until the next draft.
# ============================================================================

$Port = 3211
$DelayMs = 500              # wait after the phase flip before capturing the board
$CooldownSec = 60           # ignore repeated STRATEGY_TIME flips for this long
$PollSec = 3                # top-bar reading interval during pre-game
$MaxWatchSec = 900          # safety stop for the watcher
$HudCenterOffset = 0        # px; only if your HUD is not centered on the primary monitor
$AssumeBoardOrderMatchesTopBar = $false   # $true = skip OCR, trust that card order == top-bar order (see README)
$MinSlotScore = 0.45        # portrait match acceptance
$MinSlotMargin = 0.04       # best minus second best
$DebugImages = $true        # write debug_topbar.png / debug_board.png next to the screenshot

$Strategy = "DOTA_GAMERULES_STATE_STRATEGY_TIME"
$PreGame  = "DOTA_GAMERULES_STATE_PRE_GAME"
$InGame   = "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS"
$HeroSel  = "DOTA_GAMERULES_STATE_HERO_SELECTION"

# ---- layout, in units of screen HEIGHT, x relative to the HUD center --------
# Measured on 16:9 captures. Dota scales its HUD with the screen height and
# centers it, so the same numbers hold for 1080p, 1440p and 4K. Run
# .\autoshot-b.ps1 -Calibrate during a game to verify on your machine.
$L = @{
    TopSlotW      = 0.0550;  TopSlotH = 0.0285;  TopPitch = 0.0578;  TopY = 0.0
    TopRadiantX   = -0.386;  TopDireX = 0.102
    ArtS = 0.90; ArtCX = 0.50; ArtCY = 0.60      # which part of the 256x144 hero art the top bar shows
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
$CacheDir = Join-Path $env:LOCALAPPDATA "ad-draft-autoshot\heroes"
$HeroListPath = Join-Path $PSScriptRoot "heroes.json"

# optional overrides from autoshot-b.config.json
if (Test-Path $ConfigPath) {
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($p in $cfg.PSObject.Properties) {
            if ($p.Name -eq "Layout") { foreach ($q in $p.Value.PSObject.Properties) { $L[$q.Name] = [double]$q.Value } }
            elseif (Get-Variable -Name $p.Name -Scope Script -ErrorAction SilentlyContinue) { Set-Variable -Name $p.Name -Value $p.Value -Scope Script }
        }
    } catch { Write-Host "config file ignored: $($_.Exception.Message)" }
}

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
    static Bitmap Resample(Image src, Rectangle r, int w, int h) {
        var o = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(o)) {
            g.InterpolationMode = InterpolationMode.HighQualityBilinear;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.DrawImage(src, new Rectangle(0, 0, w, h), r, GraphicsUnit.Pixel);
        }
        return o;
    }
    // zero-mean, unit-norm RGB vector of a region, bottom-left corner masked (level/icon overlays)
    public static float[] Feat(Image src, Rectangle r, int fw, int fh) {
        using (var s = Resample(src, r, fw, fh)) {
            var f = new float[fw * fh * 3]; int k = 0; double sum = 0; int n = 0;
            for (int y = 0; y < fh; y++) for (int x = 0; x < fw; x++) {
                bool masked = (y >= fh * 0.6 && x < fw * 0.3);
                var c = s.GetPixel(x, y);
                float[] v = { c.R, c.G, c.B };
                for (int i = 0; i < 3; i++) { f[k++] = masked ? float.NaN : v[i]; if (!masked) { sum += v[i]; n++; } }
            }
            double mean = n > 0 ? sum / n : 0; double ss = 0;
            for (int i = 0; i < f.Length; i++) { if (float.IsNaN(f[i])) f[i] = 0; else { f[i] -= (float)mean; ss += f[i] * f[i]; } }
            float norm = (float)Math.Sqrt(ss); if (norm < 1e-6f) norm = 1e-6f;
            for (int i = 0; i < f.Length; i++) f[i] /= norm;
            return f;
        }
    }
    // the same for a window of the hero art (s = fraction of art width shown, cx/cy = window center)
    public static float[] FeatFromArt(Image art, double s, double cx, double cy, double aspect, int fw, int fh) {
        double cw = art.Width * s, ch = cw / aspect;
        if (ch > art.Height) { ch = art.Height; cw = ch * aspect; }
        double l = cx * art.Width - cw / 2, t = cy * art.Height - ch / 2;
        l = Math.Max(0, Math.Min(art.Width - cw, l)); t = Math.Max(0, Math.Min(art.Height - ch, t));
        return Feat(art, new Rectangle((int)Math.Round(l), (int)Math.Round(t), (int)Math.Round(cw), (int)Math.Round(ch)), fw, fh);
    }
    public static double Dot(float[] a, float[] b) { double d = 0; for (int i = 0; i < a.Length; i++) d += a[i] * b[i]; return d; }
    // returns {bestIndex, bestScore, secondScore}
    public static double[] Best(float[] f, float[][] refs) {
        int bi = -1; double b1 = -2, b2 = -2;
        for (int i = 0; i < refs.Length; i++) { double d = Dot(f, refs[i]); if (d > b1) { b2 = b1; b1 = d; bi = i; } else if (d > b2) b2 = d; }
        return new double[] { bi, b1, b2 };
    }
    public static void SwapRects(Bitmap img, Rectangle a, Rectangle b) {
        using (var ca = img.Clone(a, img.PixelFormat)) using (var cb = img.Clone(b, img.PixelFormat)) using (var g = Graphics.FromImage(img)) {
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImage(cb, a); g.DrawImage(ca, b);
        }
    }
    public static Bitmap CropScale(Image src, Rectangle r, int scale) { return Resample(src, r, r.Width * scale, r.Height * scale); }
    public static Bitmap Contrast(Bitmap src) {   // grayscale, stretched, for OCR of stylized text
        var o = new Bitmap(src.Width, src.Height, PixelFormat.Format24bppRgb);
        int lo = 255, hi = 0;
        for (int y = 0; y < src.Height; y++) for (int x = 0; x < src.Width; x++) { var c = src.GetPixel(x, y); int v = Math.Max(c.R, Math.Max(c.G, c.B)); if (v < lo) lo = v; if (v > hi) hi = v; }
        if (hi - lo < 10) hi = lo + 10;
        for (int y = 0; y < src.Height; y++) for (int x = 0; x < src.Width; x++) { var c = src.GetPixel(x, y); int v = Math.Max(c.R, Math.Max(c.G, c.B)); v = (int)Math.Round(255.0 * (v - lo) / (hi - lo)); v = 255 - Math.Max(0, Math.Min(255, v)); o.SetPixel(x, y, Color.FromArgb(v, v, v)); }
        return o;
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

# ---- hero list + art cache --------------------------------------------------
$Heroes = Get-Content $HeroListPath -Raw -Encoding UTF8 | ConvertFrom-Json
function Norm($s) { return (($s.ToUpperInvariant()) -replace "[^A-Z]", "") }
$HeroKeys = @{}; foreach ($h in $Heroes) { $HeroKeys[$h.name] = Norm $h.localized_name }

function Ensure-HeroArt {
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
    $missing = @($Heroes | Where-Object { -not (Test-Path (Join-Path $CacheDir ($_.name + ".png"))) })
    if ($missing.Count -gt 0) {
        Log "downloading $($missing.Count) hero portraits from Valve's CDN (one time, ~8 MB)..."
        foreach ($h in $missing) {
            $url = "https://cdn.cloudflare.steamstatic.com/apps/dota2/images/dota_react/heroes/$($h.name).png"
            try { Invoke-WebRequest -Uri $url -OutFile (Join-Path $CacheDir ($h.name + ".png")) -UseBasicParsing -TimeoutSec 30 }
            catch { Log "  failed: $($h.name) ($($_.Exception.Message))" }
        }
    }
}

$FW = 24; $FH = 12
$RefNames = New-Object System.Collections.ArrayList
$RefFeats = New-Object System.Collections.ArrayList
function Build-Refs {
    $aspect = $L.TopSlotW / $L.TopSlotH
    foreach ($h in $Heroes) {
        $p = Join-Path $CacheDir ($h.name + ".png"); if (-not (Test-Path $p)) { continue }
        try {
            $img = [System.Drawing.Image]::FromFile($p)
            [void]$RefFeats.Add([AdShot]::FeatFromArt($img, $L.ArtS, $L.ArtCX, $L.ArtCY, $aspect, $FW, $FH)); [void]$RefNames.Add($h.name)
            $img.Dispose()
        } catch { Log "  bad art file $p ($($_.Exception.Message))" }
    }
    Log "hero portraits ready: $($RefNames.Count)"
    if ($RefNames.Count -lt 100) { throw "hero portraits missing or unreadable in $CacheDir (delete the folder to re-download)" }
}

# ---- geometry ---------------------------------------------------------------
function Geo($W, $H) {
    $cx = [double]$W / 2 + $HudCenterOffset
    $g = @{ W = $W; H = $H; Slots = @(); Rows = @() }
    for ($i = 0; $i -lt 10; $i++) {
        $team = 0; if ($i -ge 5) { $team = 1 }
        $x0 = $L.TopRadiantX; if ($team -eq 1) { $x0 = $L.TopDireX }
        $x = $cx + ($x0 + ($i % 5) * $L.TopPitch) * $H
        $g.Slots += New-Object System.Drawing.Rectangle([int][math]::Round($x), [int][math]::Round($L.TopY * $H), [int][math]::Round($L.TopSlotW * $H), [int][math]::Round($L.TopSlotH * $H))
    }
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

# ---- OCR (Windows built-in) -------------------------------------------------
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
    # returns @( @{Text; X; Y; W; H} ) in the bitmap's own pixels
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
    # a cut-off first word ("STORM" for STORM SPIRIT): accept a unique prefix of 5+ letters
    if ($n.Length -ge 5) {
        $pref = @($HeroKeys.Keys | Where-Object { $HeroKeys[$_].StartsWith($n) })
        if ($pref.Count -eq 1) { return $pref[0] }
    }
    return $null
}

# ---- board reading ------------------------------------------------------------
function Read-Board([System.Drawing.Bitmap]$img, $g) {
    # returns hashtable heroName -> row (Team, Index, NameRect)
    $map = @{}
    if ($AssumeBoardOrderMatchesTopBar) { Log "board: OCR skipped (AssumeBoardOrderMatchesTopBar)"; return $map }
    if (-not $OcrOk) { Log "board: Windows OCR not available, swap correction disabled"; return $map }
    $dbg = $null; if ($DebugImages) { $dbg = New-Object System.Drawing.Bitmap($img) }
    $found = @{}   # "team-index" -> hero
    $seen = @{}
    # pass 1: one OCR per team column, lines assigned to cards by their vertical position
    foreach ($t in 0, 1) {
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
    # pass 2: cards still unknown get their own 3x crop, plain and contrast-stretched
    foreach ($row in $g.Rows) {
        $key = "$($row.Team)-$($row.Index)"
        if ($found.ContainsKey($key)) { continue }
        foreach ($variant in 0, 1) {
            $crop = [AdShot]::CropScale($img, $row.HeroRect, 3)
            if ($variant -eq 1) { $c2 = [AdShot]::Contrast($crop); $crop.Dispose(); $crop = $c2 }
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

# ---- top bar reading ------------------------------------------------------------
function Read-TopBar([System.Drawing.Bitmap]$img, $g, [bool]$debug) {
    # returns array of 10 hashtables {Hero, Score, Second}
    $out = @()
    $refs = [float[][]]$RefFeats.ToArray()
    $px = [math]::Max(1, [int][math]::Round($g.H / 540.0))   # search step in px
    $dbg = $null; if ($debug) { $dbg = New-Object System.Drawing.Bitmap($img) }
    for ($i = 0; $i -lt 10; $i++) {
        $r = $g.Slots[$i]; $best = @(-1, -2, -2); $bestRect = $r
        foreach ($dx in @(-2, -1, 0, 1, 2)) { foreach ($dy in @(0, 1)) { foreach ($dw in @(0, 1)) {
            $rr = New-Object System.Drawing.Rectangle(($r.X + $dx * $px), ($r.Y + $dy * $px), ($r.Width + $dw * $px), $r.Height)
            if ($rr.X -lt 0 -or $rr.Y -lt 0 -or $rr.Right -gt $g.W -or $rr.Bottom -gt $g.H) { continue }
            $f = [AdShot]::Feat($img, $rr, $FW, $FH)
            $b = [AdShot]::Best($f, $refs)
            if ($b[1] -gt $best[1]) { $best = $b; $bestRect = $rr }
        } } }
        $hero = $null
        if ($best[0] -ge 0 -and $best[1] -ge $MinSlotScore -and ($best[1] - $best[2]) -ge $MinSlotMargin) { $hero = $RefNames[[int]$best[0]] }
        $out += @{ Hero = $hero; Score = [math]::Round($best[1], 2); Second = [math]::Round($best[2], 2); Cand = $RefNames[[int][math]::Max(0, $best[0])] }
        if ($dbg) { $lab = "?"; if ($hero) { $lab = $hero }; $col = [System.Drawing.Color]::Lime; if (-not $hero) { $col = [System.Drawing.Color]::Red }; [AdShot]::DrawRect($dbg, $bestRect, $col, ("{0} {1}" -f $lab, [math]::Round($best[1], 2))) }
    }
    if ($dbg) { $dbg.Save((Join-Path (Split-Path $OutPath) "debug_topbar.png"), [System.Drawing.Imaging.ImageFormat]::Png); $dbg.Dispose() }
    return $out
}
function Fmt-Slots($slots) {
    $a = @(); for ($i = 0; $i -lt 10; $i++) { $h = $slots[$i].Hero; if (-not $h) { $h = "?(" + $slots[$i].Cand + " " + $slots[$i].Score + ")" }; $a += $h }
    return ("R: " + ($a[0..4] -join ", ") + "  |  D: " + ($a[5..9] -join ", "))
}

# ---- screenshot + correction state --------------------------------------------
$script:Game = $null
function Save-Atomic([System.Drawing.Bitmap]$bmp, $path) {
    $tmp = "$path.tmp"; $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png); Move-Item -Force $tmp $path
}
function Take-Board {
    Start-Sleep -Milliseconds $DelayMs
    $bmp = [AdShot]::Capture()
    Save-Atomic $bmp $OutPath
    $bmp.Save($BasePath, [System.Drawing.Imaging.ImageFormat]::Png)
    Log "screenshot saved -> $OutPath ($($bmp.Width)x$($bmp.Height))"
    $g = Geo $bmp.Width $bmp.Height
    $rows = Read-Board $bmp $g
    $bmp.Dispose()
    $script:Game = @{ Geo = $g; Rows = $rows; Baseline = $null; Swaps = @(); Pending = $null; Polls = 0; Started = Get-Date; Done = $false; Watching = $false }
}
function Row-Of($hero, $slot) {
    if ($AssumeBoardOrderMatchesTopBar) { return $script:Game.Geo.Rows[$slot] }
    if ($hero -and $script:Game.Rows.ContainsKey($hero)) { return $script:Game.Rows[$hero] }
    return $null
}
function Apply-Swaps {
    # rebuild screenshot.png from the pristine board with every recorded swap applied
    $bmp = New-Object System.Drawing.Bitmap($BasePath)
    foreach ($s in $script:Game.Swaps) { [AdShot]::SwapRects($bmp, $s.A, $s.B) }
    Save-Atomic $bmp $OutPath; $bmp.Dispose()
    Log "screenshot.png rewritten with $($script:Game.Swaps.Count) name swap(s)"
}
function Poll-TopBar([bool]$final) {
    $G = $script:Game; if ($null -eq $G -or $G.Done) { return }
    $bmp = [AdShot]::Capture()
    $slots = Read-TopBar $bmp $G.Geo ($DebugImages -and $G.Polls -eq 0)
    $bmp.Dispose(); $G.Polls++
    $known = @($slots | Where-Object { $_.Hero }).Count
    if ($null -eq $G.Baseline) {
        $names = @($slots | Where-Object { $_.Hero } | ForEach-Object { $_.Hero })
        $distinct = ($names | Select-Object -Unique).Count
        if ($known -ge 8 -and $distinct -eq $names.Count) {
            $G.Baseline = @(); for ($i = 0; $i -lt 10; $i++) { $G.Baseline += $slots[$i].Hero }
            Log ("top bar baseline ({0}/10): {1}" -f $known, (Fmt-Slots $slots))
            for ($i = 0; $i -lt 10; $i++) { if ($slots[$i].Hero -and -not (Row-Of $slots[$i].Hero $i)) { Log "  note: $($slots[$i].Hero) not found on the board reading, a swap involving it cannot be corrected" } }
        } else { Log ("top bar not readable yet ({0}/10): {1}" -f $known, (Fmt-Slots $slots)) }
        return
    }
    # detect exchanged pairs within a team
    $pairs = @()
    for ($i = 0; $i -lt 10; $i++) {
        $ci = $slots[$i].Hero; $bi = $G.Baseline[$i]
        if (-not $ci -or -not $bi -or $ci -eq $bi) { continue }
        $t0 = 0; if ($i -ge 5) { $t0 = 5 }
        for ($j = $i + 1; $j -lt $t0 + 5; $j++) {
            if ($slots[$j].Hero -eq $bi -and $ci -eq $G.Baseline[$j]) { $pairs += ,@($i, $j) }
        }
    }
    if ($pairs.Count -eq 0) { $G.Pending = $null; if ($final) { Log ("final reading: no swap. " + (Fmt-Slots $slots)) }; return }
    $key = ($pairs | ForEach-Object { "$($_[0])-$($_[1])" }) -join ","
    if ($G.Pending -ne $key -and -not $final) { $G.Pending = $key; Log "possible swap seen ($key), confirming on next reading"; return }
    foreach ($p in $pairs) {
        $i = $p[0]; $j = $p[1]; $hi = $G.Baseline[$i]; $hj = $G.Baseline[$j]
        $ri = Row-Of $hi $i; $rj = Row-Of $hj $j
        if ($null -eq $ri -or $null -eq $rj) { Log "SWAP detected: $hi <-> $hj, but a board card is unknown, cannot correct"; }
        else {
            $G.Swaps += @{ A = $ri.NameRect; B = $rj.NameRect }
            Log "SWAP detected: the player who drafted $hi now plays $hj (and vice versa) -> names exchanged on the board"
        }
        $G.Baseline[$i] = $hj; $G.Baseline[$j] = $hi
    }
    $G.Pending = $null
    Apply-Swaps
}

# ---- calibration / test mode ------------------------------------------------------
if ($Calibrate) {
    Ensure-HeroArt; Build-Refs
    if ($TestImage -ne "") { $bmp = New-Object System.Drawing.Bitmap($TestImage); Log "test image $TestImage ($($bmp.Width)x$($bmp.Height))" }
    else { Start-Sleep -Seconds 3; $bmp = [AdShot]::Capture(); Log "captured the screen ($($bmp.Width)x$($bmp.Height))" }
    $g = Geo $bmp.Width $bmp.Height
    $dbg = New-Object System.Drawing.Bitmap($bmp)
    for ($i = 0; $i -lt 10; $i++) { [AdShot]::DrawRect($dbg, $g.Slots[$i], [System.Drawing.Color]::Lime, "slot $i") }
    foreach ($row in $g.Rows) { [AdShot]::DrawRect($dbg, $row.HeroRect, [System.Drawing.Color]::Yellow, "hero"); [AdShot]::DrawRect($dbg, $row.NameRect, [System.Drawing.Color]::Cyan, "name") }
    $calPath = Join-Path (Split-Path $OutPath) "calibration.png"; $dbg.Save($calPath, [System.Drawing.Imaging.ImageFormat]::Png); $dbg.Dispose()
    Log "boxes drawn -> $calPath (green = top-bar portraits, yellow = hero name read, cyan = name strip that gets swapped)"
    $slots = Read-TopBar $bmp $g $true
    Log ("top bar reading: " + (Fmt-Slots $slots))
    if ($TestImage -eq "" -or $TestBoard -ne "") {
        $rows = Read-Board $bmp $g
        Log ("board reading: {0} hero names recognized (OCR available: {1})" -f $rows.Count, $OcrOk)
    }
    if ($SwapDemo) {
        $demo = New-Object System.Drawing.Bitmap($bmp)
        [AdShot]::SwapRects($demo, $g.Rows[0].NameRect, $g.Rows[2].NameRect)
        $demoPath = Join-Path (Split-Path $OutPath) "swap_demo.png"; $demo.Save($demoPath, [System.Drawing.Imaging.ImageFormat]::Png); $demo.Dispose()
        Log "swap demo (Radiant card 1 <-> card 3 names) -> $demoPath"
    }
    $bmp.Dispose()
    exit 0
}

# ---- main loop ----------------------------------------------------------------------
Ensure-HeroArt; Build-Refs
if (-not $OcrOk -and -not $AssumeBoardOrderMatchesTopBar) { Log "WARNING: Windows OCR not available on this PC; screenshots still work, swap correction will not" }

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
        try { $data = $body | ConvertFrom-Json; if ($data -and $data.map) { $state = $data.map.game_state } } catch { $state = $null }
        if ($null -ne $state -and $state -ne $prevState) {
            if ($state -eq $Strategy) {
                if (((Get-Date) - $lastShot).TotalSeconds -lt $CooldownSec) { Log "strategy time again within cooldown, ignoring" }
                else { Log "$prevState -> $state : capturing in $($DelayMs)ms"; Take-Board; $lastShot = Get-Date }
            }
            elseif ($state -eq $PreGame -and $null -ne $script:Game -and -not $script:Game.Done) {
                Log "pre-game: watching the top bar for hero swaps every $PollSec s"; $script:Game.Watching = $true; $nextPoll = (Get-Date).AddSeconds(1.5)
            }
            elseif ($state -eq $InGame -and $null -ne $script:Game -and -not $script:Game.Done) {
                Log "horn: one final reading"; $finalDue = (Get-Date).AddSeconds(1.5); $nextPoll = [DateTime]::MaxValue
            }
            elseif ($state -eq $HeroSel) { $script:Game = $null; $nextPoll = [DateTime]::MaxValue; $finalDue = [DateTime]::MaxValue; Log "game_state: $state (new draft)" }
            else { Log "game_state: $state" }
            $prevState = $state
        }
    }
    $now = Get-Date
    if ($now -ge $nextPoll) {
        try { Poll-TopBar $false } catch { Log "top bar reading failed: $($_.Exception.Message)" }
        $nextPoll = $now.AddSeconds($PollSec)
        if ($null -ne $script:Game -and ($now - $script:Game.Started).TotalSeconds -gt $MaxWatchSec) { $script:Game.Done = $true; $nextPoll = [DateTime]::MaxValue; Log "watcher stopped (time limit)" }
    }
    if ($now -ge $finalDue) {
        try { Poll-TopBar $true } catch { Log "final reading failed: $($_.Exception.Message)" }
        $finalDue = [DateTime]::MaxValue
        if ($null -ne $script:Game) { $script:Game.Done = $true; Log "watcher done for this game ($($script:Game.Swaps.Count) swap(s) corrected)" }
    }
}
