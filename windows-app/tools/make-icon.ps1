<#
.SYNOPSIS
    Regenerates src/AmbientDisplay.App/Assets/AmbientDisplay.ico (16-256 px, PNG-compressed entries).
.DESCRIPTION
    Draws the app icon: an ember-orange display glyph on a near-black rounded tile, echoing the
    night countdown palette (#D95926 on black). Run from any directory:
        pwsh windows-app/tools/make-icon.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$out = Join-Path $PSScriptRoot '..\src\AmbientDisplay.App\Assets\AmbientDisplay.ico'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null

$fonts = New-Object System.Drawing.Text.InstalledFontCollection
$glyphFont = if ($fonts.Families.Name -contains 'Segoe Fluent Icons') { 'Segoe Fluent Icons' } else { 'Segoe MDL2 Assets' }
$monitor = [string][char]0xE7F4

function New-IconPng([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)

    # Rounded near-black tile with a faint ember glow at the bottom.
    $radius = [math]::Max(2, [int]($size * 0.22))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($size - $d - 1, 0, $d, $d, 270, 90)
    $path.AddArc($size - $d - 1, $size - $d - 1, $d, $d, 0, 90)
    $path.AddArc(0, $size - $d - 1, $d, $d, 90, 90)
    $path.CloseFigure()
    $tile = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.Point]::new(0, 0)), ([System.Drawing.Point]::new(0, $size)), ([System.Drawing.Color]::FromArgb(255, 0x1A, 0x1C, 0x24)), ([System.Drawing.Color]::FromArgb(255, 0x2A, 0x14, 0x0C))
    $g.FillPath($tile, $path)

    # Ember display glyph.
    $font = New-Object System.Drawing.Font $glyphFont, ([single]($size * 0.62)), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 0xF0, 0x7A, 0x3A))
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
    $g.DrawString($monitor, $font, $brush, (New-Object System.Drawing.RectangleF 0, ([single]($size * 0.02)), $size, $size), $format)

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose(); $font.Dispose(); $brush.Dispose(); $tile.Dispose(); $path.Dispose()
    return ,$ms.ToArray()
}

# ICO container: ICONDIR + ICONDIRENTRY[n] + PNG payloads (Windows Vista+ reads PNG entries).
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = $sizes | ForEach-Object { ,(New-IconPng $_) }
$stream = [System.IO.File]::Create($out)
$writer = New-Object System.IO.BinaryWriter $stream
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $data = $images[$i]
    $writer.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
    $writer.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
    $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$data.Length); $writer.Write([uint32]$offset)
    $offset += $data.Length
}
foreach ($data in $images) { $writer.Write($data) }
$writer.Dispose()
"Wrote $out ($((Get-Item $out).Length) bytes, sizes: $($sizes -join ', '))"
