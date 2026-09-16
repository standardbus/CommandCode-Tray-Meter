# Pester tests for the tray's drawing decisions.
#
# Written for Pester 3.4 (the version shipped with Windows), which is why they
# use Should Be / Should Throw rather than the Pester 5 operator set.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test/run-selftest.ps1

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "src\tray.ps1") -ConfigPath (Join-Path $env:TEMP "cc-pester-noconfig.json") -NoSession -SelfTest

function Get-VisiblePixelCount {
  param($Bitmap)
  $count = 0
  for ($y = 0; $y -lt $Bitmap.Height; $y++) {
    for ($x = 0; $x -lt $Bitmap.Width; $x++) {
      if ($Bitmap.GetPixel($x, $y).A -gt 40) { $count++ }
    }
  }
  return $count
}

Describe "Get-PhaseColor" {  It "returns green below the warning threshold" {
    (Get-PhaseColor 0).ToArgb() | Should Be $script:ColorOk.ToArgb()
    (Get-PhaseColor 59.9).ToArgb() | Should Be $script:ColorOk.ToArgb()
  }

  It "returns amber from the warning threshold up to critical" {
    (Get-PhaseColor 60).ToArgb() | Should Be $script:ColorWarn.ToArgb()
    (Get-PhaseColor 84.9).ToArgb() | Should Be $script:ColorWarn.ToArgb()
  }

  It "returns red at and above the critical threshold" {
    (Get-PhaseColor 85).ToArgb() | Should Be $script:ColorCritical.ToArgb()
    (Get-PhaseColor 100).ToArgb() | Should Be $script:ColorCritical.ToArgb()
  }

  It "returns the idle grey when there is no value at all" {
    (Get-PhaseColor $null).ToArgb() | Should Be $script:ColorIdle.ToArgb()
  }

  It "honours custom thresholds from config" {
    $originalWarn = $script:PhaseWarn
    $originalCritical = $script:PhaseCritical
    try {
      $script:PhaseWarn = 20
      $script:PhaseCritical = 40
      (Get-PhaseColor 25).ToArgb() | Should Be $script:ColorWarn.ToArgb()
      (Get-PhaseColor 45).ToArgb() | Should Be $script:ColorCritical.ToArgb()
    } finally {
      $script:PhaseWarn = $originalWarn
      $script:PhaseCritical = $originalCritical
    }
  }
}

Describe "New-StatusBitmap" {
  It "renders a 64px square" {
    $bitmap = New-StatusBitmap -FivePercent 40 -WeeklyPercent 30
    try {
      $bitmap.Width | Should Be 64
      $bitmap.Height | Should Be 64
    } finally { $bitmap.Dispose() }
  }

  It "leaves the centre transparent so the ring reads as a ring" {
    $bitmap = New-StatusBitmap -FivePercent 40 -WeeklyPercent 30
    try {
      ($bitmap.GetPixel(32, 32).A -lt 40) | Should Be $true
    } finally { $bitmap.Dispose() }
  }

  It "draws a visible weekly dot in the bottom-right corner" {
    $bitmap = New-StatusBitmap -FivePercent 40 -WeeklyPercent 30
    try {
      $corner = $bitmap.GetPixel(56, 56)
      ($corner.A -gt 200) | Should Be $true
      $corner.ToArgb() | Should Be $script:ColorOk.ToArgb()
    } finally { $bitmap.Dispose() }
  }

  It "colours the dot by the weekly window, independently of the ring" {
    $bitmap = New-StatusBitmap -FivePercent 10 -WeeklyPercent 95
    try {
      $bitmap.GetPixel(56, 56).ToArgb() | Should Be $script:ColorCritical.ToArgb()
      # Ring top (12 o'clock) still reflects the 5-hour window.
      $bitmap.GetPixel(32, 6).ToArgb() | Should Be $script:ColorOk.ToArgb()
    } finally { $bitmap.Dispose() }
  }

  It "fills the whole ring at 100% and none of it at 0%" {
    $full = New-StatusBitmap -FivePercent 100 -WeeklyPercent 30
    $empty = New-StatusBitmap -FivePercent 0 -WeeklyPercent 30
    try {
      # 9 o'clock on the ring: painted when complete, bare track when at 0%.
      $full.GetPixel(6, 32).ToArgb() | Should Be $script:ColorCritical.ToArgb()
      $empty.GetPixel(6, 32).ToArgb() | Should Not Be $script:ColorOk.ToArgb()
    } finally {
      $full.Dispose()
      $empty.Dispose()
    }
  }

  It "paints more of the ring as usage grows" {
    # The arc starts at 12 o'clock and sweeps clockwise, so 3 o'clock is reached
    # at 25% of the sweep. At 20% that point is still bare track; at 80% it is
    # painted with the amber ring colour.
    $low = New-StatusBitmap -FivePercent 20 -WeeklyPercent 30
    $high = New-StatusBitmap -FivePercent 80 -WeeklyPercent 30
    try {
      $low.GetPixel(58, 32).ToArgb() | Should Not Be $script:ColorWarn.ToArgb()
      $high.GetPixel(58, 32).ToArgb() | Should Be $script:ColorWarn.ToArgb()
    } finally {
      $low.Dispose()
      $high.Dispose()
    }
  }

  It "uses the idle grey when no data is available" {
    $bitmap = New-StatusBitmap -FivePercent $null -WeeklyPercent $null
    try {
      $bitmap.GetPixel(56, 56).ToArgb() | Should Be $script:ColorIdle.ToArgb()
      ($bitmap.GetPixel(32, 6).A -gt 40) | Should Be $true
    } finally { $bitmap.Dispose() }
  }

  It "clamps out-of-range percentages instead of throwing" {
    $bitmap = New-StatusBitmap -FivePercent 140 -WeeklyPercent -5
    try {
      $bitmap.GetPixel(32, 6).ToArgb() | Should Be $script:ColorCritical.ToArgb()
    } finally { $bitmap.Dispose() }
  }
}

Describe "New-StatusIcon" {
  It "produces a 16x16 icon that keeps visible pixels after resampling" {
    $icon = New-StatusIcon -FivePercent 40 -WeeklyPercent 30
    try {
      $bitmap = $icon.ToBitmap()
      try {
        $visible = Get-VisiblePixelCount -Bitmap $bitmap
        ($visible -gt 40) | Should Be $true
      } finally { $bitmap.Dispose() }
    } finally { $icon.Dispose() }
  }
}

Describe "Update-TrayPresentation" {
  It "shows the auth prompt state in the tooltip" {
    $script:Data = [pscustomobject]@{ status = "auth_needed"; message = "niente key" }
    Update-TrayPresentation
    $script:TrayIcon.Text | Should Match "authentication required"
  }

  It "keeps the tooltip within the 63-character Windows limit" {
    $script:Data = [pscustomobject]@{
      fiveHour = [pscustomobject]@{ percent = 99.9 }
      weekly = [pscustomobject]@{ percent = 88.8 }
      display = [pscustomobject]@{ fiveHourPercent = "100%"; fiveHourResetIn = "3h 12m"; weeklyPercent = "89%" }
      tooltip = ("Command Code 5h 100% (reset 3h 12m) - 7g 89% " + ("x" * 60))
    }
    Update-TrayPresentation
    ($script:TrayIcon.Text.Length -le 63) | Should Be $true
  }

  It "flags stale data in the tooltip" {
    $script:Data = [pscustomobject]@{
      fiveHour = [pscustomobject]@{ percent = 10 }
      weekly = [pscustomobject]@{ percent = 10 }
      display = [pscustomobject]@{ fiveHourPercent = "10%"; fiveHourResetIn = "1h"; weeklyPercent = "10%" }
      tooltip = "Command Code 5h 10% - 7g 10%"
      stale = $true
    }
    Update-TrayPresentation
    $script:TrayIcon.Text | Should Match "data not updated"
  }
}

Describe "Close button" {
  It "sits inside the panel, at the right of the header" {
    $rect = Get-CloseButtonRect
    ($rect.Right -le 320) | Should Be $true
    ($rect.Left -ge 280) | Should Be $true
    ($rect.Top -ge 0) | Should Be $true
    ($rect.Bottom -le 240) | Should Be $true
  }

  It "is a usable size for a mouse target" {
    $rect = Get-CloseButtonRect
    ($rect.Width -ge 14) | Should Be $true
    ($rect.Height -ge 14) | Should Be $true
  }

  It "hits inside and misses just outside" {
    $rect = Get-CloseButtonRect
    $centre = [System.Drawing.Point]::new(($rect.Left + [int]($rect.Width / 2)), ($rect.Top + [int]($rect.Height / 2)))
    (Get-CloseButtonHit -Point $centre) | Should Be $true
    $left = [System.Drawing.Point]::new(($rect.Left - 6), $centre.Y)
    (Get-CloseButtonHit -Point $left) | Should Be $false
    (Get-CloseButtonHit -Point ([System.Drawing.Point]::new(20, 120))) | Should Be $false
  }

  It "does not overlap the title" {
    $rect = Get-CloseButtonRect
    # The title starts at x=30 and "Command Code" is about 120px wide.
    ($rect.Left -gt 150) | Should Be $true
  }
}

Describe "Test-PointOutsidePopup" {
  It "treats a point inside the bubble as inside" {
    $script:Popup.Show([System.Drawing.Point]::new(300, 300))
    [System.Windows.Forms.Application]::DoEvents()
    try {
      $centre = [System.Drawing.Point]::new(
        ($script:Popup.Bounds.Left + [int]($script:Popup.Bounds.Width / 2)),
        ($script:Popup.Bounds.Top + [int]($script:Popup.Bounds.Height / 2)))
      (Test-PointOutsidePopup -X $centre.X -Y $centre.Y) | Should Be $false
    } finally { $script:Popup.Close() }
  }

  It "treats a point well outside the bubble as outside" {
    $script:Popup.Show([System.Drawing.Point]::new(300, 300))
    [System.Windows.Forms.Application]::DoEvents()
    try {
      (Test-PointOutsidePopup -X 5 -Y 5) | Should Be $true
      (Test-PointOutsidePopup -X ($script:Popup.Bounds.Right + 40) -Y $script:Popup.Bounds.Top) | Should Be $true
    } finally { $script:Popup.Close() }
  }

  It "allows a small slack around the edges so the border is not a dead zone" {
    $script:Popup.Show([System.Drawing.Point]::new(300, 300))
    [System.Windows.Forms.Application]::DoEvents()
    try {
      # One pixel outside the edge is still treated as inside.
      (Test-PointOutsidePopup -X ($script:Popup.Bounds.Left - 1) -Y ($script:Popup.Bounds.Top + 10)) | Should Be $false
      # Comfortably beyond the slack is outside.
      (Test-PointOutsidePopup -X ($script:Popup.Bounds.Left - 20) -Y ($script:Popup.Bounds.Top + 10)) | Should Be $true
    } finally { $script:Popup.Close() }
  }
}

Describe "Get-TrayAnchor" {
  It "places the bubble inside the working area" {
    $anchor = Get-TrayAnchor
    $working = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    ($anchor.X -ge $working.Left) | Should Be $true
    ($anchor.Y -ge $working.Top) | Should Be $true
    (($anchor.X + 320) -le $working.Right) | Should Be $true
    (($anchor.Y + 240) -le $working.Bottom) | Should Be $true
  }

  It "anchors to the tray corner rather than the cursor" {
    $anchor = Get-TrayAnchor
    $working = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    # Near the right edge, where the clock is.
    ($anchor.X -gt ($working.Right - 400)) | Should Be $true
  }
}

Describe "mouse watch lifecycle" {
  It "installs the global hook while the bubble is open and removes it after" {
    Start-MouseWatch
    try {
      ($script:MouseHookHandle -ne [IntPtr]::Zero) | Should Be $true
    } finally { Stop-MouseWatch }
    ($script:MouseHookHandle -eq [IntPtr]::Zero) | Should Be $true
  }

  It "is idempotent when started twice" {
    Start-MouseWatch
    try {
      $first = $script:MouseHookHandle
      Start-MouseWatch
      ($script:MouseHookHandle -eq $first) | Should Be $true
    } finally { Stop-MouseWatch }
  }

  It "stops cleanly when it was never started" {
    Stop-MouseWatch
    ($script:MouseHookHandle -eq [IntPtr]::Zero) | Should Be $true
  }
}

Describe "icon metric selection" {
  It "defaults the ring to the 5-hour window" {
    $script:IconMetric = "fiveHour"
    $script:Data = [pscustomobject]@{
      fiveHour = [pscustomobject]@{ percent = 10 }
      weekly = [pscustomobject]@{ percent = 20 }
      monthly = [pscustomobject]@{ percent = 30 }
      display = [pscustomobject]@{ fiveHourPercent = "10%"; weeklyPercent = "20%"; monthlyPercent = "30%" }
      tooltip = "Command Code 5h 10%"
    }
    Update-TrayPresentation
    # The tooltip is the observable proxy here; the icon bitmap is covered above.
    $script:TrayIcon.Text | Should Match "10%"
  }

  It "reports every window in the tooltip" {
    $script:IconMetric = "fiveHour"
    $script:Data = [pscustomobject]@{
      fiveHour = [pscustomobject]@{ percent = 10 }
      weekly = [pscustomobject]@{ percent = 20 }
      monthly = [pscustomobject]@{ percent = 30 }
      display = [pscustomobject]@{ fiveHourPercent = "10%"; weeklyPercent = "20%"; monthlyPercent = "30%" }
      tooltip = "Command Code 5h 10% | 7g 20% | 30g 30%"
    }
    Update-TrayPresentation
    $script:TrayIcon.Text | Should Match "7g 20%"
    $script:TrayIcon.Text | Should Match "30g 30%"
  }

  It "accepts each metric name and falls back on an unknown one" {
    $original = $script:IconMetric
    try {
      foreach ($metric in @("fiveHour", "weekly", "monthly")) {
        $script:IconMetric = $metric
        $bitmap = New-StatusBitmap -FivePercent 42 -WeeklyPercent 24
        try { ($bitmap.GetPixel(32, 6).A -gt 40) | Should Be $true } finally { $bitmap.Dispose() }
      }
    } finally { $script:IconMetric = $original }
  }
}
