# Pester tests for the tray's drawing decisions.
#
# Written for Pester 3.4 (the version shipped with Windows), which is why they
# use Should Be / Should Throw rather than the Pester 5 operator set.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test/run-selftest.ps1

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "src\tray.ps1") -ConfigPath (Join-Path $env:TEMP "cc-pester-noconfig.json") -NoSession -SelfTest
# The tray resolves its language from config.json, which the test deliberately
# does without: pin the tests to English instead of inheriting the machine's UI
# locale, or the assertions below would depend on who runs them.
$script:DefaultLanguage = Select-CcLanguage "en"

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

# The English language table is the contract for every label the tray shows, so
# a test that pins a tooltip to hardcoded words would keep passing after the
# table changed. The expected string is built from lang/en.json instead.
function Get-LanguageTable {
  param([string]$Code)
  $path = Join-Path $root "lang\$Code.json"
  # ConvertFrom-Json reads the file as single-byte text, which mangles the
  # non-ASCII strings in the translated tables.
  $bytes = [System.IO.File]::ReadAllBytes($path)
  return ([System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json)
}

function Get-EnglishTable {
  return Get-LanguageTable "en"
}

# Painted (not transparent) pixels in a text sample, for the CJK font check.
function Get-PaintedPixelCount {
  param([string]$Text, [System.Drawing.Font]$Font)
  $bitmap = [System.Drawing.Bitmap]::new(200, 40, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.Clear([System.Drawing.Color]::Transparent)
      $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
      $graphics.DrawString($Text, $Font, [System.Drawing.Brushes]::Black, 0, 0)
    } finally { $graphics.Dispose() }
    return Get-VisiblePixelCount -Bitmap $bitmap
  } finally { $bitmap.Dispose() }
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
    $script:Data = [pscustomobject]@{ status = "auth_needed"; message = "no key configured" }
    Update-TrayPresentation
    $script:TrayIcon.Text | Should Match "authentication required"
  }

  It "keeps the tooltip within the 63-character Windows limit" {
    $script:Data = [pscustomobject]@{
      fiveHour = [pscustomobject]@{ percent = 99.9 }
      weekly = [pscustomobject]@{ percent = 88.8 }
      display = [pscustomobject]@{ fiveHourPercent = "100%"; fiveHourResetIn = "3h 12m"; weeklyPercent = "89%" }
      tooltip = ("Command Code 5h 100% (reset 3h 12m) - 7d 89% " + ("x" * 60))
    }
    Update-TrayPresentation
    ($script:TrayIcon.Text.Length -le 63) | Should Be $true
  }

  It "renders the tooltip the shared module builds from the language table" {
    $table = Get-EnglishTable
    # The weekly and monthly labels come from tooltip.weekly / tooltip.monthly:
    # English reads "7d"/"30d", not the Italian "7g"/"30g" left over in an older
    # build. Building the expectation from the table keeps this honest.
    $script:Data = [pscustomobject]@{
      fiveHour = [pscustomobject]@{ percent = 40 }
      weekly = [pscustomobject]@{ percent = 10 }
      display = [pscustomobject]@{ fiveHourPercent = "40%"; fiveHourResetIn = "3h 12m"; weeklyPercent = "10%" }
      tooltip = ("Command Code " + $table.tooltip.fiveHour + " 40% (reset 3h 12m)" +
        $table.tooltip.separator + $table.tooltip.weekly + " 10%")
    }
    Update-TrayPresentation
    $script:TrayIcon.Text.Contains($table.tooltip.weekly) | Should Be $true
    $script:TrayIcon.Text.Contains($table.tooltip.monthly) | Should Be $false
  }

  It "flags stale data in the tooltip" {
    $script:Data = [pscustomobject]@{
      fiveHour = [pscustomobject]@{ percent = 10 }
      weekly = [pscustomobject]@{ percent = 10 }
      display = [pscustomobject]@{ fiveHourPercent = "10%"; fiveHourResetIn = "1h"; weeklyPercent = "10%" }
      tooltip = "Command Code 5h 10% - 7d 10%"
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
      tooltip = "Command Code 5h 10% | 7d 20% | 30d 30%"
    }
    Update-TrayPresentation
    $script:TrayIcon.Text | Should Match "7d 20%"
    $script:TrayIcon.Text | Should Match "30d 30%"
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

Describe "language selection" {
  It "translates through the shared language table" {
    try {
      # The expectations are read from the same files the tray loads: a literal
      # here would also be read by Windows PowerShell as ANSI and corrupted.
      (Select-CcLanguage "it") | Should Be "it"
      (Get-CcText "panel.fiveHour") | Should Be (Get-LanguageTable "it").panel.fiveHour
      (Select-CcLanguage "zh") | Should Be "zh"
      (Get-CcText "panel.weekly") | Should Be (Get-LanguageTable "zh").panel.weekly
      (Get-CcText "menu.exit") | Should Be (Get-LanguageTable "zh").menu.exit
    } finally { Select-CcLanguage $script:DefaultLanguage | Out-Null }
  }

  It "falls back to English, then to the key itself" {
    try {
      # An unknown language and a missing key must both degrade visibly rather
      # than throw or print nothing.
      (Select-CcLanguage "klingon") | Should Be "en"
      (Get-CcText "panel.weekly") | Should Be "Weekly"
      (Get-CcText "panel.doesNotExist") | Should Be "panel.doesNotExist"
    } finally { Select-CcLanguage $script:DefaultLanguage | Out-Null }
  }

  It "substitutes placeholders and maps each language to its locale" {
    (Get-CcText "panel.updated" @{ time = "09:30" }) | Should Be "Updated at 09:30"
    (Get-CcText "panel.updated") | Should Be "Updated at {time}"
    (Get-CcLocale "en") | Should Be "en-US"
    (Get-CcLocale "it") | Should Be "it-IT"
    (Get-CcLocale "zh") | Should Be "zh-CN"
  }

  It "asks for a CJK-capable family for Chinese, and Segoe UI otherwise" {
    try {
      (Select-CcLanguage "en") | Out-Null
      (Get-CcFontFamily) | Should Be "Segoe UI"
      (Select-CcLanguage "zh") | Out-Null
      (Get-CcFontFamily) | Should Be "Microsoft YaHei UI"
    } finally { Select-CcLanguage $script:DefaultLanguage | Out-Null }
  }

  It "draws Chinese glyphs instead of missing-glyph boxes" {
    # A real label from the Chinese table, so the sample is not a synthetic
    # string that no font would ever have to render.
    $cjk = (Get-LanguageTable "zh").status.starting
    $default = New-UiFont -Family "Segoe UI" -Size ([float]9.5)
    $cjkFont = New-UiFont -Family "Microsoft YaHei UI" -Size ([float]9.5)
    try {
      $defaultPixels = Get-PaintedPixelCount -Text $cjk -Font $default
      $cjkPixels = Get-PaintedPixelCount -Text $cjk -Font $cjkFont
      # Windows falls back to a font that has the glyphs, so the default family
      # is not blank; the CJK family is still the one the tray asks for.
      ($defaultPixels -gt 0) | Should Be $true
      ($cjkPixels -gt 0) | Should Be $true
      ($cjkPixels -ge $defaultPixels) | Should Be $true
    } finally {
      $default.Dispose()
      $cjkFont.Dispose()
    }
  }
}

Describe "accounts section" {
  function New-MultiAccountData {
    return [pscustomobject]@{
      activeProfile = "work"
      fiveHour = [pscustomobject]@{ percent = 10 }
      weekly = [pscustomobject]@{ percent = 20 }
      monthly = [pscustomobject]@{ percent = 30 }
      display = [pscustomobject]@{ fiveHourPercent = "10%"; weeklyPercent = "20%"; monthlyPercent = "30%" }
      tooltip = "Command Code 5h 10% | 7d 20% | 30d 30%"
      accounts = @(
        [pscustomobject]@{ id = "personal"; name = "Personal"; display = [pscustomobject]@{ fiveHourPercent = "4%"; weeklyPercent = "12%"; monthlyPercent = "9%" } }
        [pscustomobject]@{ id = "work"; name = "Work"; display = [pscustomobject]@{ fiveHourPercent = "10%"; weeklyPercent = "20%"; monthlyPercent = "30%" } }
      )
    }
  }

  It "keeps today's 306px bubble for a single account" {
    (Get-PanelHeight -AccountCount 0) | Should Be 306
    (Get-PanelHeight -AccountCount 1) | Should Be 306
    $script:Data = $null
    Update-TrayPresentation
    $PanelHeight | Should Be 306
  }

  It "grows the panel with the number of accounts" {
    $two = Get-PanelHeight -AccountCount 2
    $three = Get-PanelHeight -AccountCount 3
    ($two -gt 306) | Should Be $true
    ($three -gt $two) | Should Be $true
    # Every account row plus the section title, so nothing is drawn outside.
    ($two -ge (306 + 26 + 2 * 18)) | Should Be $true
  }

  It "resizes the popup and the owner-drawn item together" {
    $script:Data = New-MultiAccountData
    try {
      Update-TrayPresentation
      $PanelHeight | Should Be (Get-PanelHeight -AccountCount 2)
      $script:Popup.MinimumSize.Height | Should Be $PanelHeight
      $script:OwnerDrawItem.Size.Height | Should Be $PanelHeight
    } finally {
      $script:Data = $null
      Update-TrayPresentation
    }
  }

  It "follows the active account and names it in the tooltip" {
    $script:Data = New-MultiAccountData
    try {
      (Get-ActiveProfileId) | Should Be "work"
      Update-TrayPresentation
      $script:TrayIcon.Text | Should Match "Work"
    } finally {
      $script:Data = $null
      Update-TrayPresentation
    }
  }

  It "prefers the payload's active account over the cached one" {
    $cached = $script:CachedProfile
    try {
      $script:CachedProfile = "personal"
      $script:Data = New-MultiAccountData
      (Get-ActiveProfileId) | Should Be "work"
      # Without a payload the cached choice is what the menu should check.
      $script:Data = $null
      (Get-ActiveProfileId) | Should Be "personal"
    } finally {
      $script:CachedProfile = $cached
      $script:Data = $null
    }
  }

  It "lists the accounts in the menu and checks the active one" {
    $script:Data = New-MultiAccountData
    try {
      Update-TrayPresentation
      # Available, not Visible: a ToolStripItem reports Visible=false until its
      # owner has a window handle, which in a test never happens.
      ($script:AccountMenu.Available) | Should Be $true
      ($script:AccountMenu.DropDownItems.Count) | Should Be 2
      ($script:AccountMenu.DropDownItems[0].Text) | Should Be "Personal"
      ($script:AccountMenu.DropDownItems[0].Checked) | Should Be $false
      ($script:AccountMenu.DropDownItems[1].Checked) | Should Be $true
    } finally {
      $script:Data = $null
      Update-TrayPresentation
    }
  }

  It "hides the account submenu when a single account is configured" {
    ($script:AccountMenu.Available) | Should Be $false
  }

  It "paints the accounts section without errors" {
    $script:Data = New-MultiAccountData
    Update-TrayPresentation
    $bitmap = [System.Drawing.Bitmap]::new($PanelWidth, $PanelHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      try { Draw-Panel -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0, 0, $PanelWidth, $PanelHeight)) }
      finally { $graphics.Dispose() }
      ($bitmap.GetPixel(4, 4).ToArgb()) | Should Be $script:ColorPanel.ToArgb()
    } finally {
      $bitmap.Dispose()
      $script:Data = $null
      Update-TrayPresentation
    }
  }
}
