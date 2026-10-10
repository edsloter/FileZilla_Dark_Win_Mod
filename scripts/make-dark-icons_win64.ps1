# ---------------------------------------------------------------------------
# Generates the dark-background variants of the FileZilla "default" icon theme.
#
# Why
# ---
# A theme may ship "<name>_light.png" next to "<name>.png", and
# CTheme::LoadBitmap picks the former whenever the system appearance is dark.
# The suffix names the polarity of the artwork, not of the theme - upstream
# already uses it that way for the tree item buttons and the transfer queue
# sort tabs.
#
# Measured against the default theme, 7 of the 38 plain icons are effectively
# invisible on a dark background (close, upload and dropdown are 100% dark
# pixels; cancel 85%, uploadadd 64%, help 62%, server 42%) and 6 more are
# borderline (synctransfer, auto, leds, processqueue, speedlimits, disconnect).
# Only those get a variant; the rest read acceptably on both backgrounds and
# generating artwork for them would be churn.
#
# Transform
# ---------
# Alpha is left untouched so the silhouette is identical to the original - the
# same thing upstream does, its existing _light/_dark pairs differ only in
# colour. For each opaque pixel the luminance L is lifted towards white by
#
#     t = (1 - L)^2 * 0.85
#     c' = c + (255 - c) * t
#
# so pure black becomes 85% white, mid grey 128 becomes about 155, and an
# already light pixel is left alone. Hue and relative colour differences are
# preserved, which matters because several of these icons are colour coded
# (upload green, cancel red, help blue).
#
# The quadratic keeps coloured glyphs recognisable: a dark saturated colour has
# a low L and so gets lifted a lot, while the bright half of the same colour
# barely moves, which keeps the shading that makes the shape readable.
# ---------------------------------------------------------------------------
[CmdletBinding()]
  param(
      # Left empty so it can be derived from versions.ps1 below; param defaults run
      # before a dot-source, so the versioned path cannot be built here.
      [string]$ThemeDir,
      # Regenerate icons that already exist. Without this the script would skip
      # them, which is the safe default: the variants are also carried in the
      # patch series, and overwriting them is only ever wanted when checking that
      # the generator still reproduces what the series ships.
      [switch]$Force
  )

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

if (-not $ThemeDir) {
    $ThemeDir = "C:\fzdark\work\filezilla-$($FzVersion)\src\interface\resources\default"
}

# Icons whose plain artwork does not read on a dark background, worst first.
$icons = @(
    'close', 'upload', 'dropdown', 'cancel', 'uploadadd', 'help', 'server',
    'synctransfer', 'auto', 'leds', 'processqueue', 'speedlimits', 'disconnect'
)

$strength = 0.85

function Convert-ToDarkVariant {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    $src = [System.Drawing.Bitmap]::new($SourcePath)

    # Force a known 32bpp ARGB layout so the byte offsets below are fixed and
    # the alpha channel survives untouched.
    $bmp = [System.Drawing.Bitmap]::new($src.Width, $src.Height,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    $graphics.DrawImage($src, 0, 0)
    $graphics.Dispose()
    $src.Dispose()

    $rect = [System.Drawing.Rectangle]::new(0, 0, $bmp.Width, $bmp.Height)
    $locked = $bmp.LockBits($rect,
        [System.Drawing.Imaging.ImageLockMode]::ReadWrite,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $bytes = [byte[]]::new($locked.Stride * $locked.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($locked.Scan0, $bytes, 0, $bytes.Length)

        for ($i = 0; $i -lt $bytes.Length; $i += 4) {
            $blue = $bytes[$i]
            $green = $bytes[$i + 1]
            $red = $bytes[$i + 2]

            $luma = (0.299 * $red + 0.587 * $green + 0.114 * $blue) / 255.0
            $t = (1.0 - $luma) * (1.0 - $luma) * $strength
            if ($t -le 0.0) { continue }

            $bytes[$i] = [byte]($blue + (255 - $blue) * $t)
            $bytes[$i + 1] = [byte]($green + (255 - $green) * $t)
            $bytes[$i + 2] = [byte]($red + (255 - $red) * $t)
        }

        [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $locked.Scan0, $bytes.Length)
    }
    finally {
        $bmp.UnlockBits($locked)
    }

    $bmp.Save($TargetPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$sizeDirs = Get-ChildItem -LiteralPath $ThemeDir -Directory
if (-not $sizeDirs) { throw "No size directories under $ThemeDir" }

$written = @()

foreach ($sizeDir in $sizeDirs) {
    foreach ($icon in $icons) {
        $source = Join-Path $sizeDir.FullName "$icon.png"
        if (-not (Test-Path -LiteralPath $source)) {
            Write-Warning "$icon is missing from $($sizeDir.Name), skipping"
            continue
        }

        $target = Join-Path $sizeDir.FullName "${icon}_light.png"
        if ((Test-Path -LiteralPath $target) -and -not $Force) {
            Write-Host "  exists  $($sizeDir.Name)/${icon}_light.png"
            $written += "${icon}_light"
            continue
        }

        Convert-ToDarkVariant -SourcePath $source -TargetPath $target
        Write-Host "  wrote   $($sizeDir.Name)/${icon}_light.png"
        $written += "${icon}_light"
    }
}

Write-Host ''
Write-Host "Generated $($written.Count) variant(s)."
Write-Host "Register them in $ThemeDir\Makefile.am, which lists every file explicitly."
