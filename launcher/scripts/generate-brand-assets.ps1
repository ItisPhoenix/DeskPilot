$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets'
New-Item -ItemType Directory -Force -Path $root | Out-Null
function New-DpPngBytes([int]$Size) {
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $g.Clear([System.Drawing.Color]::Transparent)
  $radius = [single]($Size * 0.22)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $radius * 2
  $path.AddArc(1,1,$d,$d,180,90)
  $path.AddArc(($Size-$d-1),1,$d,$d,270,90)
  $path.AddArc(($Size-$d-1),($Size-$d-1),$d,$d,0,90)
  $path.AddArc(1,($Size-$d-1),$d,$d,90,90)
  $path.CloseFigure()
  $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,13,19,24))
  $edge = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,54,68,76),[single][Math]::Max(0.8,$Size/180.0))
  $g.FillPath($bg,$path)
  $g.DrawPath($edge,$path)
  $fontSize = [single]($Size * 0.57)
  $font = New-Object System.Drawing.Font('Segoe UI',$fontSize,([System.Drawing.FontStyle]::Bold -bor [System.Drawing.FontStyle]::Italic),[System.Drawing.GraphicsUnit]::Pixel)
  $fmt = New-Object System.Drawing.StringFormat([System.Drawing.StringFormat]::GenericTypographic)
  $fmt.FormatFlags = $fmt.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoClip
  $dSize = $g.MeasureString('D',$font,1000,$fmt)
  $pSize = $g.MeasureString('P',$font,1000,$fmt)
  $overlap = [single]($Size * 0.045)
  $total = $dSize.Width + $pSize.Width - $overlap
  $x = [single](($Size - $total) / 2 - $Size * 0.005)
  $y = [single]($Size * 0.155)
  $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,248,250,247))
  $lime = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,194,244,99))
  $g.DrawString('D',$font,$white,$x,$y,$fmt)
  $g.DrawString('P',$font,$lime,($x + $dSize.Width - $overlap),$y,$fmt)
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms,[System.Drawing.Imaging.ImageFormat]::Png)
  $bytes = $ms.ToArray()
  $ms.Dispose(); $white.Dispose(); $lime.Dispose(); $font.Dispose(); $fmt.Dispose(); $edge.Dispose(); $bg.Dispose(); $path.Dispose(); $g.Dispose(); $bmp.Dispose()
  return ,$bytes
}
$png = New-DpPngBytes 256
[System.IO.File]::WriteAllBytes((Join-Path $root 'icon.png'),$png)
$sizes = @(16,24,32,48,64,128,256)
$frames = @()
foreach($size in $sizes) { $frames += ,(New-DpPngBytes $size) }
$icoPath = Join-Path $root 'deskpilot.ico'
$stream = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($stream)
$writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]$sizes.Count)
$offset = 6 + (16 * $sizes.Count)
for($i=0;$i -lt $sizes.Count;$i++) {
  $size = $sizes[$i]; $frame = $frames[$i]
  $dimension = if($size -eq 256){[byte]0}else{[byte]$size}
  $writer.Write($dimension); $writer.Write($dimension); $writer.Write([byte]0); $writer.Write([byte]0)
  $writer.Write([UInt16]1); $writer.Write([UInt16]32); $writer.Write([UInt32]$frame.Length); $writer.Write([UInt32]$offset)
  $offset += $frame.Length
}
foreach($frame in $frames){$writer.Write($frame)}
$writer.Flush()
[System.IO.File]::WriteAllBytes($icoPath,$stream.ToArray())
$writer.Dispose(); $stream.Dispose()
"Generated $icoPath (7 sizes) and icon.png (256x256)"
