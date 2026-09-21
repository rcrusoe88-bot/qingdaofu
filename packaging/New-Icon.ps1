# Turns a source PNG into the app icon assets Wails expects:
#   gui/build/appicon.png        (1024x1024 master)
#   gui/build/windows/icon.ico   (multi-size, PNG-compressed entries)
#
# The source is produced by the image pipeline; regenerate the mark with:
#   python ~/.claude/scripts/gen_image.py -p "<prompt>" -o design/assets/icon/qdf-icon-bleed.png --aspect 1:1
# then re-run this script. Keeping the two steps separate means the artwork can
# be redrawn without touching the packaging code.

param(
    [string]$Source
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $Source) {
    $Source = Join-Path $projectRoot 'design\assets\icon\qdf-icon-bleed.png'
}
if (-not (Test-Path -LiteralPath $Source)) {
    throw "icon source not found: $Source"
}

$pngOut = Join-Path $projectRoot 'gui\build\appicon.png'
$icoOut = Join-Path $projectRoot 'gui\build\windows\icon.ico'
$master = 1024
$icoSizes = 16, 24, 32, 48, 64, 128, 256

# Downscaling 1024 -> 16 in one step loses the shape. Halve repeatedly instead,
# which keeps edges clean at the sizes the taskbar and Alt-Tab actually use.
function Resize-Image {
    param([System.Drawing.Image]$Image, [int]$Target)
    $cur = $Image
    while ($cur.Width -gt $Target * 2) {
        $half = [int]($cur.Width / 2)
        $next = New-Object System.Drawing.Bitmap($half, $half, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($next)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($cur, 0, 0, $half, $half)
        $g.Dispose()
        if ($cur -ne $Image) { $cur.Dispose() }
        $cur = $next
    }
    $final = New-Object System.Drawing.Bitmap($Target, $Target, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($final)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($cur, 0, 0, $Target, $Target)
    $g.Dispose()
    if ($cur -ne $Image) { $cur.Dispose() }
    return $final
}

$src = [System.Drawing.Image]::FromFile($Source)
try {
    if ($src.Width -ne $src.Height) {
        throw "icon source must be square, got $($src.Width)x$($src.Height)"
    }

    # --- master PNG ---
    $masterBmp = Resize-Image -Image $src -Target $master
    $pngDir = Split-Path -Parent $pngOut
    if (-not (Test-Path -LiteralPath $pngDir)) { New-Item -ItemType Directory -Path $pngDir -Force | Out-Null }
    $masterBmp.Save($pngOut, [System.Drawing.Imaging.ImageFormat]::Png)
    $masterBmp.Dispose()
    Write-Output "wrote $pngOut"

    # --- multi-size ICO, PNG-compressed entries (Vista+ format) ---
    $blobs = @()
    foreach ($s in $icoSizes) {
        $bmp = Resize-Image -Image $src -Target $s
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $blobs += , @{ Size = $s; Bytes = $ms.ToArray() }
        $ms.Dispose(); $bmp.Dispose()
    }
}
finally {
    $src.Dispose()
}

$icoDir = Split-Path -Parent $icoOut
if (-not (Test-Path -LiteralPath $icoDir)) { New-Item -ItemType Directory -Path $icoDir -Force | Out-Null }

$fs = [System.IO.File]::Create($icoOut)
$bw = New-Object System.IO.BinaryWriter($fs)

$bw.Write([uint16]0)              # reserved
$bw.Write([uint16]1)              # type: icon
$bw.Write([uint16]$blobs.Count)   # image count

$offset = 6 + (16 * $blobs.Count)
foreach ($b in $blobs) {
    $dim = if ($b.Size -ge 256) { 0 } else { $b.Size }   # 0 means 256 in the ICO header
    $bw.Write([byte]$dim)          # width
    $bw.Write([byte]$dim)          # height
    $bw.Write([byte]0)             # palette count
    $bw.Write([byte]0)             # reserved
    $bw.Write([uint16]1)           # colour planes
    $bw.Write([uint16]32)          # bits per pixel
    $bw.Write([uint32]$b.Bytes.Length)
    $bw.Write([uint32]$offset)
    $offset += $b.Bytes.Length
}
foreach ($b in $blobs) { $bw.Write($b.Bytes) }

$bw.Flush(); $bw.Dispose(); $fs.Dispose()
Write-Output "wrote $icoOut ($($blobs.Count) sizes: $($icoSizes -join ', '))"
