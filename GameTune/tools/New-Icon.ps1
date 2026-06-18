<#
    Generates assets\gametune.ico - a simple, clean app icon (gradient rounded
    square with a bold "G"). Produces a 256x256 PNG-backed .ico (crisp on Vista+).
    Replace assets\gametune.ico with a designed icon any time; the build picks up
    whatever is there.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root   = Split-Path $PSScriptRoot -Parent
$assets = Join-Path $root 'assets'
if (-not (Test-Path $assets)) { New-Item -ItemType Directory -Path $assets -Force | Out-Null }
$icoPath = Join-Path $assets 'gametune.ico'

$size = 256
$bmp  = New-Object System.Drawing.Bitmap $size, $size
$g    = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear([System.Drawing.Color]::Transparent)

# Rounded-rectangle background with a diagonal blue gradient.
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$x = 10; $y = 10; $w = $size - 20; $h = $size - 20; $r = 52; $d = $r * 2
$path.AddArc($x,            $y,            $d, $d, 180, 90)
$path.AddArc($x + $w - $d,  $y,            $d, $d, 270, 90)
$path.AddArc($x + $w - $d,  $y + $h - $d,  $d, $d,   0, 90)
$path.AddArc($x,            $y + $h - $d,  $d, $d,  90, 90)
$path.CloseFigure()

$rect  = New-Object System.Drawing.Rectangle 0, 0, $size, $size
$c1    = [System.Drawing.Color]::FromArgb(62, 123, 250)   # #3E7BFA
$c2    = [System.Drawing.Color]::FromArgb(26, 30, 41)     # #1A1E29
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, $c1, $c2, ([System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal)
$g.FillPath($brush, $path)

# Bold "G".
$font = New-Object System.Drawing.Font 'Segoe UI', 150, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$sf   = New-Object System.Drawing.StringFormat
$sf.Alignment     = [System.Drawing.StringAlignment]::Center
$sf.LineAlignment = [System.Drawing.StringAlignment]::Center
$g.DrawString('G', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 4, $size, $size), $sf)
$g.Dispose()

# Encode the bitmap as PNG and wrap it in a single-entry ICO (PNG-in-ICO).
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$png = $ms.ToArray()
$ms.Dispose(); $bmp.Dispose()

$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([uint16]0)              # reserved
$bw.Write([uint16]1)              # type = icon
$bw.Write([uint16]1)              # image count
$bw.Write([byte]0)                # width  (0 = 256)
$bw.Write([byte]0)                # height (0 = 256)
$bw.Write([byte]0)                # palette
$bw.Write([byte]0)                # reserved
$bw.Write([uint16]1)              # color planes
$bw.Write([uint16]32)             # bits per pixel
$bw.Write([uint32]$png.Length)    # image size
$bw.Write([uint32]22)             # offset (6 + 16)
$bw.Write($png)
$bw.Flush(); $bw.Dispose(); $fs.Dispose()

Write-Host "Icon written: $icoPath ($([math]::Round((Get-Item $icoPath).Length/1kb,1)) KB)"
