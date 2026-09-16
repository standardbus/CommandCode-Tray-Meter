# Writes csharp/app.ico, the icon embedded in CommandCodeMonitor.exe.
#
# Drawn here with GDI+ rather than by compiling a throwaway probe program: the
# build already depends on PowerShell, and a second compile step plus a child
# process was one more thing to go wrong for no benefit.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/make-icon.ps1

param(
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) { $OutputPath = Join-Path $root "csharp\app.ico" }

Add-Type -AssemblyName System.Drawing

# Same palette as the tray icon, so the executable and the icon agree.
$panel = [System.Drawing.Color]::FromArgb(32, 33, 36)
$ring = [System.Drawing.Color]::FromArgb(46, 160, 67)
$dot = [System.Drawing.Color]::FromArgb(209, 36, 47)

function New-IconBitmap {
  param([int]$Size)
  $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear($panel)

    $inset = $Size * 0.16
    $ringWidth = $Size * 0.12
    $diameter = $Size - 2 * $inset
    $pen = [System.Drawing.Pen]::new($ring, $ringWidth)
    try {
      $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
      $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
      # A three-quarter arc reads as a gauge at every size.
      $graphics.DrawArc($pen, $inset, $inset, $diameter, $diameter, -90, 250)
    } finally { $pen.Dispose() }

    $dotSize = $Size * 0.3
    $offset = $Size - $dotSize - $inset * 0.4
    $brush = [System.Drawing.SolidBrush]::new($dot)
    try { $graphics.FillEllipse($brush, $offset, $offset, $dotSize, $dotSize) }
    finally { $brush.Dispose() }
  } finally { $graphics.Dispose() }
  return $bitmap
}

# Windows Vista and later read PNG-compressed frames inside a .ico, which keeps
# the 256px frame small.
$sizes = @(16, 32, 48, 64, 128, 256)
$frames = @()
foreach ($size in $sizes) {
  $bitmap = New-IconBitmap -Size $size
  $stream = [System.IO.MemoryStream]::new()
  $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
  $frames += , $stream.ToArray()
  $stream.Dispose()
}

$directory = Split-Path -Parent $OutputPath
if ($directory -and -not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

$file = [System.IO.File]::Create($OutputPath)
$writer = [System.IO.BinaryWriter]::new($file)
try {
  $writer.Write([uint16]0)              # reserved
  $writer.Write([uint16]1)              # type: icon
  $writer.Write([uint16]$sizes.Count)   # image count

  $offset = 6 + 16 * $sizes.Count
  for ($i = 0; $i -lt $sizes.Count; $i++) {
    $size = $sizes[$i]
    $dimension = if ($size -ge 256) { 0 } else { $size }   # 0 means 256
    $writer.Write([byte]$dimension)     # width
    $writer.Write([byte]$dimension)     # height
    $writer.Write([byte]0)              # palette colours
    $writer.Write([byte]0)              # reserved
    $writer.Write([uint16]1)            # colour planes
    $writer.Write([uint16]32)           # bits per pixel
    $writer.Write([uint32]$frames[$i].Length)
    $writer.Write([uint32]$offset)
    $offset += $frames[$i].Length
  }
  foreach ($frame in $frames) { $writer.Write($frame) }
} finally {
  $writer.Dispose()
  $file.Dispose()
}

$icon = Get-Item $OutputPath
Write-Output ("Icon created: {0} ({1:N0} bytes, {2} sizes)" -f $icon.FullName, $icon.Length, $sizes.Count)
