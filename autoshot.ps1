param([string]$OutPath = "")

# AD Draft AutoShot - takes the draft screenshot automatically when the game
# switches from drafting to STRATEGY TIME. Needs nothing but Windows.

$Port = 3211
$DelayMs = 500        # wait after the phase flip before capturing
$CooldownSec = 60     # ignore re-triggers for this long
$Strategy = "DOTA_GAMERULES_STATE_STRATEGY_TIME"

if ($OutPath -eq "") { $OutPath = Join-Path $PSScriptRoot "screenshot.png" }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System.Runtime.InteropServices;
public static class DpiFix {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[DpiFix]::SetProcessDPIAware() | Out-Null

function Log($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $msg) }

function Take-Screenshot {
    Start-Sleep -Milliseconds $DelayMs
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $tmp = "$OutPath.tmp"
    $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Move-Item -Force $tmp $OutPath
    Log "screenshot saved -> $OutPath ($($b.Width)x$($b.Height))"
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Log "autoshot listening on localhost:$Port, target: $OutPath"
Log "waiting for Dota... (this window logs every phase change)"

$prevState = $null
$lastShot = [DateTime]::MinValue

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream, $ctx.Request.ContentEncoding)).ReadToEnd()
    $ctx.Response.StatusCode = 200
    $ctx.Response.Close()

    try { $data = $body | ConvertFrom-Json } catch { continue }
    $state = $null
    if ($data -and $data.map) { $state = $data.map.game_state }
    if ($null -eq $state) { continue }

    if ($state -ne $prevState) {
        if ($state -eq $Strategy) {
            if (((Get-Date) - $lastShot).TotalSeconds -lt $CooldownSec) {
                Log "strategy time again within cooldown, ignoring"
            } else {
                Log "$prevState -> $state : capturing in $($DelayMs)ms"
                Take-Screenshot
                $lastShot = Get-Date
            }
        } else {
            Log "game_state: $state"
        }
        $prevState = $state
    }
}
