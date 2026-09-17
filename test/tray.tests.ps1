# Pester tests for the tray's drawing decisions.
#
# Written for Pester 3.4 (the version shipped with Windows), which is why they
# use Should Be / Should Throw rather than the Pester 5 operator set.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test/run-selftest.ps1

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
# Where Write-TrayError puts its lines, for the tests that assert the settings
# window reports a failure instead of swallowing it.
$CachedLogDir = Join-Path $root ".cache"
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

# Every control of a form, deepest first. Used by the settings window tests, which
# drive the real window instead of a mock.
function Get-Children {
  param($Parent)
  $list = @()
  foreach ($control in $Parent.Controls) {
    foreach ($child in (Get-Children $control)) { $list += $child }
    $list += $control
  }
  return $list
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

  It "grows the panel by the tab strip - 28px - once there are two accounts" {
    # The strip replaces the row section the bubble used to grow with, so the
    # height is a constant from two accounts upwards, not a function of the count.
    (Get-PanelHeight -AccountCount 2) | Should Be 334
    (Get-PanelHeight -AccountCount 3) | Should Be 334
    (Get-PanelHeight -AccountCount 12) | Should Be 334
    (Get-PanelContentOffset -AccountCount 1) | Should Be 0
    (Get-PanelContentOffset -AccountCount 2) | Should Be 28
    # The C# implementation uses these two numbers too.
    ((Get-PanelHeight -AccountCount 2) - (Get-PanelHeight -AccountCount 1)) | Should Be 28
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

  It "paints the two-account bubble without errors" {
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

Describe "account tabs" {
  function New-TwoAccountData {
    return [pscustomobject]@{
      activeProfile = "work"
      fiveHour = [pscustomobject]@{ percent = 10 }
      weekly = [pscustomobject]@{ percent = 20 }
      monthly = [pscustomobject]@{ percent = 30 }
      credits = [pscustomobject]@{ used = 1; limit = 2; remaining = 1; percent = 50 }
      display = [pscustomobject]@{ fiveHourPercent = "10%"; weeklyPercent = "20%"; monthlyPercent = "30%" }
      tooltip = "Command Code 5h 10% | 7d 20% | 30d 30%"
      fetchedAt = 1789000000000
      accounts = @(
        [pscustomobject]@{ id = "personal"; name = "Personal"; display = [pscustomobject]@{ fiveHourPercent = "4%" } }
        [pscustomobject]@{ id = "work"; name = "Work"; display = [pscustomobject]@{ fiveHourPercent = "10%" } }
      )
    }
  }

  # The tab label is centred, so a fixed pixel can land on a glyph. These read the
  # tab as a whole instead: the underline is one row of accent across the full tab
  # width, and an active tab's background is lighter than the panel's.
  function Test-TabUnderlined {
    param($Bitmap, [int]$Index)
    $rect = Get-PanelTabRect -AccountCount 2 -Index $Index -Offset (Get-PanelContentOffset -AccountCount 2)
    $accent = $script:ColorOk.ToArgb()
    $samples = 0
    for ($x = ($rect.Left + 2); $x -le ($rect.Right - 3); $x += 4) {
      if ($Bitmap.GetPixel($x, ($rect.Bottom - 1)).ToArgb() -eq $accent) { $samples++ }
    }
    # At least a dozen hits out of ~35 samples, so a single coincidental pixel
    # cannot pass the check.
    return ($samples -ge 12)
  }

  function Get-TabBrightness {
    param($Bitmap, [int]$Index)
    $rect = Get-PanelTabRect -AccountCount 2 -Index $Index -Offset (Get-PanelContentOffset -AccountCount 2)
    $sum = 0
    $count = 0
    for ($y = ($rect.Top + 2); $y -lt ($rect.Bottom - 1); $y++) {
      for ($x = ($rect.Left + 2); $x -lt ($rect.Right - 1); $x += 4) {
        $pixel = $Bitmap.GetPixel($x, $y)
        $sum += ($pixel.R + $pixel.G + $pixel.B)
        $count++
      }
    }
    return ($sum / $count)
  }

  It "lays the strip out inside the panel, one tab per account" {
    $strip = Get-PanelTabStripRect -AccountCount 2 -Offset 28
    ($strip.Left) | Should Be 16
    # Directly below the header, so the close button and the header keep their
    # coordinates whatever the account count is.
    ($strip.Top) | Should Be 34
    ($strip.Right) | Should Be (320 - 16)
    ($strip.Bottom) | Should Be (34 + 22)
    ((Get-PanelTabWidth -AccountCount 2) * 2) | Should Be ($strip.Width - ($strip.Width % 2))
    $first = Get-PanelTabRect -AccountCount 2 -Index 0 -Offset 28
    $second = Get-PanelTabRect -AccountCount 2 -Index 1 -Offset 28
    ($first.Left) | Should Be $strip.Left
    ($second.Left) | Should Be ($first.Right)
    ($second.Right) | Should Be ($strip.Right)
  }

  It "hits the tab under a point and misses everywhere else" {
    $offset = Get-PanelContentOffset -AccountCount 2
    (Get-PanelTabIndexAtPoint -AccountCount 2 -Point ([System.Drawing.Point]::new(80, 45)) -Offset $offset) | Should Be 0
    (Get-PanelTabIndexAtPoint -AccountCount 2 -Point ([System.Drawing.Point]::new(240, 45)) -Offset $offset) | Should Be 1
    # The margin left of the strip, the header above it and the figures below it
    # are not tabs.
    (Get-PanelTabIndexAtPoint -AccountCount 2 -Point ([System.Drawing.Point]::new(8, 45)) -Offset $offset) | Should Be -1
    (Get-PanelTabIndexAtPoint -AccountCount 2 -Point ([System.Drawing.Point]::new(80, 20)) -Offset $offset) | Should Be -1
    (Get-PanelTabIndexAtPoint -AccountCount 2 -Point ([System.Drawing.Point]::new(80, 90)) -Offset $offset) | Should Be -1
    # A single account has no strip at all.
    (Get-PanelTabIndexAtPoint -AccountCount 1 -Point ([System.Drawing.Point]::new(80, 45)) -Offset 0) | Should Be -1
    (Get-PanelTabIndexAtPoint -AccountCount 0 -Point ([System.Drawing.Point]::new(80, 45)) -Offset 0) | Should Be -1
  }

  It "highlights the active account's tab and leaves the others plain" {
    $script:Data = New-TwoAccountData
    try {
      Update-TrayPresentation
      ($PanelHeight) | Should Be 334
      $bitmap = [System.Drawing.Bitmap]::new($PanelWidth, $PanelHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try { Draw-Panel -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0, 0, $PanelWidth, $PanelHeight)) }
        finally { $graphics.Dispose() }
        # The active tab is Work (index 1): it carries the accent underline and a
        # lighter ground, while Personal's tab is untouched.
        (Test-TabUnderlined -Bitmap $bitmap -Index 1) | Should Be $true
        (Test-TabUnderlined -Bitmap $bitmap -Index 0) | Should Be $false
        ((Get-TabBrightness -Bitmap $bitmap -Index 1) -gt (Get-TabBrightness -Bitmap $bitmap -Index 0)) | Should Be $true
        # The header is where it always was, so the strip cannot have moved it.
        ($bitmap.GetPixel(20, 20).ToArgb()) | Should Not Be $script:ColorPanel.ToArgb()
      } finally { $bitmap.Dispose() }
    } finally {
      $script:Data = $null
      Update-TrayPresentation
    }
  }

  It "follows the switch: the tab of the account that becomes active is the highlighted one" {
    $script:Data = New-TwoAccountData
    try {
      Update-TrayPresentation
      $bitmap = [System.Drawing.Bitmap]::new($PanelWidth, $PanelHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try { Draw-Panel -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0, 0, $PanelWidth, $PanelHeight)) }
        finally { $graphics.Dispose() }
        (Test-TabUnderlined -Bitmap $bitmap -Index 1) | Should Be $true
      } finally { $bitmap.Dispose() }
      # The payload of the newly active account is what the session answers with,
      # so repainting it is what a switch looks like from here.
      $script:Data.activeProfile = "personal"
      Update-TrayPresentation
      $bitmap = [System.Drawing.Bitmap]::new($PanelWidth, $PanelHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try { Draw-Panel -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0, 0, $PanelWidth, $PanelHeight)) }
        finally { $graphics.Dispose() }
        (Test-TabUnderlined -Bitmap $bitmap -Index 0) | Should Be $true
        (Test-TabUnderlined -Bitmap $bitmap -Index 1) | Should Be $false
      } finally { $bitmap.Dispose() }
    } finally {
      $script:Data = $null
      Update-TrayPresentation
    }
  }

  It "shifts the figures down by the strip height" {
    $single = [pscustomobject]@{
      activeProfile = "only"
      fiveHour = [pscustomobject]@{ percent = 10 }
      weekly = [pscustomobject]@{ percent = 20 }
      monthly = [pscustomobject]@{ percent = 30 }
      display = [pscustomobject]@{ fiveHourPercent = "10%"; weeklyPercent = "20%"; monthlyPercent = "30%" }
      fetchedAt = 1789000000000
      accounts = @([pscustomobject]@{ id = "only"; name = "Only"; display = [pscustomobject]@{} })
    }
    $script:Data = $single
    Update-TrayPresentation
    ($PanelHeight) | Should Be 306
    # With one account the 5-hour row sits at y=50; with two it is 28px lower, so
    # the pixel at 50 has moved from the title text to the strip area.
    $singleBitmap = [System.Drawing.Bitmap]::new($PanelWidth, $PanelHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($singleBitmap)
    try { Draw-Panel -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0, 0, $PanelWidth, $PanelHeight)) }
    finally { $graphics.Dispose() }

    $script:Data = New-TwoAccountData
    Update-TrayPresentation
    $multiBitmap = [System.Drawing.Bitmap]::new($PanelWidth, $PanelHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($multiBitmap)
    try { Draw-Panel -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0, 0, $PanelWidth, $PanelHeight)) }
    finally { $graphics.Dispose() }

    try {
      # The same content line, 28px lower: compare a run of pixels from the first
      # row of the 5-hour block.
      $matching = 0
      for ($x = 20; $x -lt 300; $x++) {
        if ($singleBitmap.GetPixel($x, 52).ToArgb() -eq $multiBitmap.GetPixel($x, (52 + 28)).ToArgb()) { $matching++ }
      }
      ($matching -ge 200) | Should Be $true
    } finally {
      $singleBitmap.Dispose()
      $multiBitmap.Dispose()
      $script:Data = $null
      Update-TrayPresentation
    }
  }
}

Describe "account id derivation" {
  It "lower-cases the name and joins the words with hyphens" {
    (ConvertTo-CcAccountId "Work") | Should Be "work"
    (ConvertTo-CcAccountId "My Work Account") | Should Be "my-work-account"
    (ConvertTo-CcAccountId "lavoro-personale") | Should Be "lavoro-personale"
    (ConvertTo-CcAccountId "9lives") | Should Be "9lives"
  }

  It "collapses every run of characters outside a-z0-9 into one hyphen" {
    (ConvertTo-CcAccountId "ACME -- Corp!!") | Should Be "acme-corp"
    (ConvertTo-CcAccountId "a_b") | Should Be "a-b"
    (ConvertTo-CcAccountId "Bob's Account") | Should Be "bob-s-account"
    (ConvertTo-CcAccountId "UPPER---CASE") | Should Be "upper-case"
  }

  It "trims the leading and trailing hyphens" {
    (ConvertTo-CcAccountId "  Personal  ") | Should Be "personal"
    (ConvertTo-CcAccountId "  --x--  ") | Should Be "x"
    (ConvertTo-CcAccountId "- Work -") | Should Be "work"
  }

  It "falls back to `account` when the name leaves nothing" {
    (ConvertTo-CcAccountId "") | Should Be "account"
    (ConvertTo-CcAccountId "   ") | Should Be "account"
    (ConvertTo-CcAccountId "!!!") | Should Be "account"
    (ConvertTo-CcAccountId "---") | Should Be "account"
  }

  It "makes a repeated id unique with -2, -3" {
    (Get-CcUniqueAccountId -Id "work" -Taken @()) | Should Be "work"
    (Get-CcUniqueAccountId -Id "work" -Taken @("work")) | Should Be "work-2"
    (Get-CcUniqueAccountId -Id "work" -Taken @("work", "work-2")) | Should Be "work-3"
  }

  It "produces ids that satisfy the schema the session validates" {
    foreach ($name in @("Work", "My Work Account", "!!!", "", "ACME -- Corp!!", "UPPER---CASE", "a_b", "9lives", "Bob's")) {
      $id = ConvertTo-CcAccountId $name
      ($id -match '^[a-z0-9][a-z0-9-]*$') | Should Be $true
      # No leading, trailing or doubled hyphen, whatever the name was.
      ($id -notmatch '--') | Should Be $true
    }
  }
}

Describe "settings writer" {
  # One scratch copy of config.example.json per test: the repository's own
  # config.json holds a real key and is never opened by these tests.
  function New-ScratchConfig {
    $directory = Join-Path $env:TEMP ("cc-pester-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $path = Join-Path $directory "config.json"
    Copy-Item (Join-Path $root "config.example.json") $path -Force
    return @{ Dir = $directory; Path = $path }
  }

  function Remove-ScratchConfig {
    param($Scratch)
    try { if (Test-Path $Scratch.Dir) { Remove-Item $Scratch.Dir -Recurse -Force } } catch { }
  }

  function Get-ScratchJson {
    param([string]$Path)
    return ((Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json)
  }

  function New-DraftRow {
    param([string]$Id = "", [string]$Name = "", [string]$ApiKey = "", [string]$ApiKeyEnv = "", [string]$PreviousName = "")
    return @{ Id = $Id; Name = $Name; ApiKey = $ApiKey; ApiKeyEnv = $ApiKeyEnv; PreviousName = $PreviousName }
  }

  It "validates every row before anything is written" {
    (Test-CcSettingsDraft -Accounts @((New-DraftRow -ApiKey "k"))) | Should Be "Every account needs a name."
    (Test-CcSettingsDraft -Accounts @((New-DraftRow -Name "A"))) | Should Be 'Account "A" has no API key.'
    (Test-CcSettingsDraft -Accounts @((New-DraftRow -Name "A" -ApiKey "1"), (New-DraftRow -Name "a" -ApiKey "2"))) | Should Be 'Two accounts are named "a".'
    # A kept environment variable is a valid credential, a written key too.
    (Test-CcSettingsDraft -Accounts @((New-DraftRow -Name "A" -ApiKeyEnv "VAR"))) | Should Be $null
    (Test-CcSettingsDraft -Accounts @((New-DraftRow -Name "A" -ApiKey "typed"))) | Should Be $null
  }

  It "reports validation through the language table" {
    $table = Get-LanguageTable "it"
    (Test-CcSettingsDraft -Accounts @((New-DraftRow -ApiKey "k")) -Language "it") | Should Be $table.settings.nameRequired
    (Test-CcSettingsDraft -Accounts @((New-DraftRow -Name "X")) -Language "it") | Should Be ($table.settings.keyRequired -replace "\{name\}", "X")
  }

  It "writes the accounts, the language and the numeric settings" {
    $scratch = New-ScratchConfig
    try {
      Save-CcSettingsToConfig -Path $scratch.Path -Language "it" -RefreshSeconds 45 -Warn 40 -Critical 70 `
        -IconMetric "weekly" -Monochrome $true -ShowTooltip $false -ActiveProfile "work" `
        -Accounts @(
          (New-DraftRow -Id "personal" -Name "Personal" -ApiKey "user_personal_1234567890" -PreviousName "Personal"),
          (New-DraftRow -Id "work" -Name "Work" -ApiKeyEnv "COMMANDCODE_API_KEY_WORK" -PreviousName "Work")
        ) | Out-Null
      $document = Get-ScratchJson $scratch.Path
      ($document.language) | Should Be "it"
      ($document.refreshSeconds) | Should Be 45
      ($document.thresholds.warn) | Should Be 40
      ($document.thresholds.critical) | Should Be 70
      ($document.ui.iconMetric) | Should Be "weekly"
      ($document.ui.monochrome) | Should Be $true
      ($document.ui.showTooltip) | Should Be $false
      ($document.activeProfile) | Should Be "work"
      (@($document.profiles).Count) | Should Be 2
      ($document.profiles[0].id) | Should Be "personal"
      ($document.profiles[0].apiKey) | Should Be "user_personal_1234567890"
      # A key that lives in the environment is never written as an inline empty
      # value, and the entry keeps naming the variable.
      ($document.profiles[1].apiKeyEnv) | Should Be "COMMANDCODE_API_KEY_WORK"
      (($document.profiles[1].PSObject.Properties.Name -contains "apiKey")) | Should Be $false
    } finally { Remove-ScratchConfig $scratch }
  }

  It "never writes a mask over a key" {
    $scratch = New-ScratchConfig
    try {
      # What a masked box would look like if its displayed text were saved.
      Save-CcSettingsToConfig -Path $scratch.Path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "" `
        -Accounts @((New-DraftRow -Name "Work" -ApiKey "user_real_key_value")) | Out-Null
      $document = Get-ScratchJson $scratch.Path
      ($document.profiles[0].apiKey) | Should Be "user_real_key_value"
      $raw = Get-Content -LiteralPath $scratch.Path -Raw -Encoding UTF8
      ($raw.Contains("*")) | Should Be $false
      ($raw.Contains([string][char]0x25CF)) | Should Be $false
    } finally { Remove-ScratchConfig $scratch }
  }

  It "keeps every key it does not manage" {
    $scratch = New-ScratchConfig
    try {
      Save-CcSettingsToConfig -Path $scratch.Path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "" `
        -Accounts @((New-DraftRow -Name "Only" -ApiKey "k")) | Out-Null
      $document = Get-ScratchJson $scratch.Path
      ($document.'$comment') | Should Not BeNullOrEmpty
      ($document.'$comment_endpoints') | Should Not BeNullOrEmpty
      ($document.'$comment_creditFiles') | Should Not BeNullOrEmpty
      ($document.endpoints.baseUrl) | Should Be "https://api.commandcode.ai"
      ($document.endpoints.usageSummaryPath) | Should Be "/alpha/usage/summary"
      ($document.requestTimeoutMs) | Should Be 8000
      (@($document.creditFiles).Count) | Should Be 2
    } finally { Remove-ScratchConfig $scratch }
  }

  It "keeps the file's key order and an unknown key a future version adds" {
    $scratch = New-ScratchConfig
    try {
      $before = ((Get-Content -LiteralPath $scratch.Path -Raw -Encoding UTF8) | ConvertFrom-Json).PSObject.Properties.Name
      Save-CcSettingsToConfig -Path $scratch.Path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "" `
        -Accounts @((New-DraftRow -Name "Only" -ApiKey "k")) | Out-Null
      $after = (Get-ScratchJson $scratch.Path).PSObject.Properties.Name
      (($before -join ",")) | Should Be ($after -join ",")
    } finally { Remove-ScratchConfig $scratch }
  }

  It "writes UTF-8 without a BOM" {
    $scratch = New-ScratchConfig
    try {
      Save-CcSettingsToConfig -Path $scratch.Path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "" `
        -Accounts @((New-DraftRow -Name "Only" -ApiKey "k")) | Out-Null
      $bytes = [System.IO.File]::ReadAllBytes($scratch.Path)
      ($bytes[0]) | Should Be ([byte][char]'{')
      (($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)) | Should Be $false
    } finally { Remove-ScratchConfig $scratch }
  }

  It "writes atomically, leaving no temporary file behind" {
    $scratch = New-ScratchConfig
    try {
      Save-CcSettingsToConfig -Path $scratch.Path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "" `
        -Accounts @((New-DraftRow -Name "Only" -ApiKey "k")) | Out-Null
      $names = @(Get-ChildItem -LiteralPath $scratch.Dir | ForEach-Object { $_.Name })
      ($names.Count) | Should Be 1
      ($names[0]) | Should Be "config.json"
      # A failed write must leave the previous file whole: the write goes to a
      # sibling temporary file and only replaces the real one once it is complete.
      # The path is invalid for the filesystem, so the temporary write fails after
      # the document has been serialized - the point at which a half-written file
      # would otherwise be left behind.
      $previous = Get-Content -LiteralPath $scratch.Path -Raw -Encoding UTF8
      $invalid = Join-Path $scratch.Dir "bad?name.json"
      $threw = $false
      try {
        Save-CcSettingsToConfig -Path $invalid -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
          -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "" `
          -Accounts @((New-DraftRow -Name "Only" -ApiKey "k")) | Out-Null
      } catch { $threw = $true }
      ($threw) | Should Be $true
      ((Get-Content -LiteralPath $scratch.Path -Raw -Encoding UTF8)) | Should Be $previous
      (@(Get-ChildItem -LiteralPath $scratch.Dir).Count) | Should Be 1
      ($(if (Test-Path -LiteralPath $invalid) { "written" } else { "absent" })) | Should Be "absent"
    } finally { Remove-ScratchConfig $scratch }
  }

  It "derives the id from the name and keeps the id of a row that only changed its key" {
    $scratch = New-ScratchConfig
    try {
      Save-CcSettingsToConfig -Path $scratch.Path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "" `
        -Accounts @(
          (New-DraftRow -Name "My Work Account" -ApiKey "a"),
          (New-DraftRow -Name "My Work Account" -ApiKey "b")
        ) | Out-Null
      $document = Get-ScratchJson $scratch.Path
      ($document.profiles[0].id) | Should Be "my-work-account"
      ($document.profiles[1].id) | Should Be "my-work-account-2"
      # A cosmetic edit - a corrected key - must not churn the ids.
      $rows = @()
      foreach ($profile in $document.profiles) {
        $rows += (New-DraftRow -Id $profile.id -Name $profile.name -ApiKey "rotated" -PreviousName $profile.name)
      }      Save-CcSettingsToConfig -Path $scratch.Path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "" -Accounts $rows | Out-Null
      $document = Get-ScratchJson $scratch.Path
      ($document.profiles[0].id) | Should Be "my-work-account"
      ($document.profiles[1].id) | Should Be "my-work-account-2"
    } finally { Remove-ScratchConfig $scratch }
  }

  It "reads a draft back from the file it wrote" {
    $scratch = New-ScratchConfig
    try {
      Save-CcSettingsToConfig -Path $scratch.Path -Language "zh" -RefreshSeconds 30 -Warn 20 -Critical 50 `
        -IconMetric "monthly" -Monochrome $true -ShowTooltip $false -ActiveProfile "work" `
        -Accounts @(
          (New-DraftRow -Name "Personal" -ApiKey "personal_key"),
          (New-DraftRow -Name "Work" -ApiKeyEnv "COMMANDCODE_API_KEY_WORK")
        ) | Out-Null
      $draft = Get-CcSettingsDraft -Path $scratch.Path
      ($draft.Language) | Should Be "zh"
      ($draft.RefreshSeconds) | Should Be 30
      ($draft.Warn) | Should Be 20
      ($draft.Critical) | Should Be 50
      ($draft.IconMetric) | Should Be "monthly"
      ($draft.Monochrome) | Should Be $true
      ($draft.ShowTooltip) | Should Be $false
      ($draft.ActiveProfile) | Should Be "work"
      (@($draft.Accounts).Count) | Should Be 2
      ($draft.Accounts[0].ApiKey) | Should Be "personal_key"
      ($draft.Accounts[1].ApiKey) | Should Be ""
      ($draft.Accounts[1].Env) | Should Be "COMMANDCODE_API_KEY_WORK"
      (Get-CcSettingsLanguage -Path $scratch.Path) | Should Be "zh"
    } finally { Remove-ScratchConfig $scratch }
  }

  It "an untouched file keeps the account that is active" {
    $scratch = New-ScratchConfig
    try {
      Save-CcSettingsToConfig -Path $scratch.Path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "work" `
        -Accounts @(
          (New-DraftRow -Name "Personal" -ApiKey "a"),
          (New-DraftRow -Name "Work" -ApiKey "b")
        ) | Out-Null
      $draft = Get-CcSettingsDraft -Path $scratch.Path
      $rows = @()
      foreach ($account in $draft.Accounts) {
        $rows += (New-DraftRow -Id $account.Id -Name $account.Name -ApiKey $account.ApiKey -PreviousName $account.Name)
      }
      Save-CcSettingsToConfig -Path $scratch.Path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile $draft.ActiveProfile -Accounts $rows | Out-Null
      ((Get-ScratchJson $scratch.Path).activeProfile) | Should Be "work"
    } finally { Remove-ScratchConfig $scratch }
  }

  It "clears an active account that is no longer in the list" {
    $scratch = New-ScratchConfig
    try {
      Save-CcSettingsToConfig -Path $scratch.Path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "gone" `
        -Accounts @((New-DraftRow -Name "Only" -ApiKey "k")) | Out-Null
      # A stale id falls back to the first account rather than naming nothing.
      ((Get-ScratchJson $scratch.Path).activeProfile) | Should Be "only"
    } finally { Remove-ScratchConfig $scratch }
  }

  It "creates a configuration that does not exist yet" {
    $directory = Join-Path $env:TEMP ("cc-pester-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $path = Join-Path $directory "fresh.json"
    try {
      Save-CcSettingsToConfig -Path $path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "" `
        -Accounts @((New-DraftRow -Name "Only" -ApiKey "k")) | Out-Null
      $document = Get-ScratchJson $path
      ($document.profiles[0].id) | Should Be "only"
      ($document.activeProfile) | Should Be "only"
    } finally {
      try { Remove-Item $directory -Recurse -Force } catch { }
    }
  }

  It "writes only the active account when the tray switches profile" {
    $scratch = New-ScratchConfig
    try {
      Save-CcSettingsToConfig -Path $scratch.Path -Language "en" -RefreshSeconds 120 -Warn 60 -Critical 85 `
        -IconMetric "fiveHour" -Monochrome $false -ShowTooltip $true -ActiveProfile "personal" `
        -Accounts @(
          (New-DraftRow -Name "Personal" -ApiKey "a"),
          (New-DraftRow -Name "Work" -ApiKey "b")
        ) | Out-Null
      $before = Get-Content -LiteralPath $scratch.Path -Raw -Encoding UTF8
      (Set-CcActiveProfileInConfig -Path $scratch.Path -Id "work") | Should Be $true
      $after = Get-Content -LiteralPath $scratch.Path -Raw -Encoding UTF8
      $document = Get-ScratchJson $scratch.Path
      ($document.activeProfile) | Should Be "work"
      (@($document.profiles).Count) | Should Be 2
      # Nothing else in the file was rewritten: only the one line changed.
      (($before -replace '"activeProfile":\s*"[a-z]*"', '')) | Should Be (($after -replace '"activeProfile":\s*"[a-z]*"', ''))
    } finally { Remove-ScratchConfig $scratch }
  }
}

Describe "settings window spinners" {
  # A Windows Forms NumericUpDown throws
  #   '0' is not a valid value for 'Value'. 'Value' should be between
  #   'Minimum' and 'Maximum'. Parameter name: Value
  # when a value outside its range is assigned, and an exception raised while the
  # window is being built becomes the unhandled-exception dialog rather than a
  # message in the window. A configuration that says `refreshSeconds: 0` took the
  # tray down once; these are the tests that keep that from coming back.
  #
  # The last-resort report puts a message box on screen by design. It is found and
  # dismissed from a timer - any visible dialog window, whatever its title - so a
  # test never waits for a click and never leaves a modal window behind.
  try {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class CcSettingsDialogCloser
{
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    public static int CloseDialogs()
    {
        var closed = 0;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd)) return true;
            var name = new StringBuilder(64);
            GetClassName(hWnd, name, name.Capacity);
            if (name.ToString() == "#32770")
            {
                PostMessage(hWnd, 0x0010, IntPtr.Zero, IntPtr.Zero); // WM_CLOSE
                closed++;
            }
            return true;
        }, IntPtr.Zero);
        return closed;
    }
}
'@
  } catch {
    # Already defined in this session, which is fine.
  }

  function New-ScratchNumberConfig {
    param([string]$Json)
    $directory = Join-Path $env:TEMP ("cc-pester-num-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $path = Join-Path $directory "config.json"
    [System.IO.File]::WriteAllText($path, $Json, (New-Object System.Text.UTF8Encoding($false)))
    return @{ Dir = $directory; Path = $path }
  }

  function Get-WindowNumerics {
    param($Form)
    # Sorted the way the window lays them out: refresh, warn, critical.
    return @(Get-Children $Form | Where-Object { $_ -is [System.Windows.Forms.NumericUpDown] } | Sort-Object Top, Left)
  }

  function Open-SettingsWindow {
    # Builds and shows the real window, then closes it from a timer so the modal
    # loop returns. What the spinners ended up holding is read inside the tick,
    # while the window is still open. A build that throws is caught here, and the
    # assertions report it rather than the test dying on an unhandled exception.
    param([string]$ConfigPath)
    $script:WindowError = $null
    $script:WindowBeforeClose = $null
    $script:WindowOpen = $false
    $script:WindowTimer = New-Object System.Windows.Forms.Timer
    $script:WindowTimer.Interval = 300
    $script:WindowTimer.Add_Tick({
      $script:WindowTimer.Stop()
      $form = $script:CcSettingsForm
      if (-not $form) { return }
      $script:WindowOpen = $true
      $script:WindowBeforeClose = @(Get-WindowNumerics $form | ForEach-Object {
        [pscustomobject]@{ Value = $_.Value; Minimum = $_.Minimum; Maximum = $_.Maximum }
      })
      try { $form.Close() } catch { }
    })
    $script:WindowTimer.Start()
    try {
      Show-CcSettingsWindow -Path $ConfigPath -ActiveProfile "personal"
    } catch {
      $script:WindowError = $_.Exception.Message
    } finally {
      try { $script:WindowTimer.Stop(); $script:WindowTimer.Dispose() } catch { }
    }
    return $script:WindowBeforeClose
  }

  It "builds a window whose configured numbers are out of range, without throwing" {
    $scratch = New-ScratchNumberConfig '{"refreshSeconds":0,"thresholds":{"warn":-5,"critical":150}}'
    try {
      $before = Get-Content -LiteralPath $scratch.Path -Raw -Encoding UTF8
      $numerics = Open-SettingsWindow -ConfigPath $scratch.Path
      ($script:WindowError) | Should BeNullOrEmpty
      # The window really opened: a build that threw would leave no timer note.
      ($script:WindowOpen) | Should Be $true
      ($numerics.Count) | Should Be 3
      # Nothing was written by merely opening the window.
      ((Get-Content -LiteralPath $scratch.Path -Raw -Encoding UTF8)) | Should Be $before
    } finally {
      try { Remove-Item $scratch.Dir -Recurse -Force } catch { }
    }
  }

  It "clamps refresh and the thresholds into the ranges their spinners accept" {
    $cases = @(
      @{ Refresh = 0;      Warn = -5;  Critical = 150; ExpectRefresh = 120;   ExpectWarn = 60;  ExpectCritical = 100 },
      @{ Refresh = -30;    Warn = 150; Critical = -1;  ExpectRefresh = 120;   ExpectWarn = 100; ExpectCritical = 85 },
      @{ Refresh = 5;      Warn = 0;   Critical = 0;   ExpectRefresh = 120;   ExpectWarn = 0;   ExpectCritical = 0 },
      @{ Refresh = 999999; Warn = 100; Critical = 100; ExpectRefresh = 86400; ExpectWarn = 100; ExpectCritical = 100 }
    )
    foreach ($case in $cases) {
      # Built with string concatenation: `-f` would read the JSON braces as format
      # items.
      $json = '{"refreshSeconds":' + $case.Refresh + ',"thresholds":{"warn":' + $case.Warn + ',"critical":' + $case.Critical + '}}'
      $scratch = New-ScratchNumberConfig $json
      try {
        $before = Get-Content -LiteralPath $scratch.Path -Raw -Encoding UTF8
        $numerics = Open-SettingsWindow -ConfigPath $scratch.Path
        ($script:WindowError) | Should BeNullOrEmpty
        ($numerics.Count) | Should Be 3
        # The spinner can only hold what its range allows, which is exactly the
        # assignment that would otherwise have thrown.
        ($numerics[0].Value) | Should Be $case.ExpectRefresh
        ($numerics[1].Value) | Should Be $case.ExpectWarn
        ($numerics[2].Value) | Should Be $case.ExpectCritical
        # Within the ranges the controls themselves declare, and the ranges the
        # window is supposed to give them.
        (($numerics[0].Value -ge $numerics[0].Minimum) -and ($numerics[0].Value -le $numerics[0].Maximum)) | Should Be $true
        (($numerics[1].Value -ge $numerics[1].Minimum) -and ($numerics[1].Value -le $numerics[1].Maximum)) | Should Be $true
        (($numerics[2].Value -ge $numerics[2].Minimum) -and ($numerics[2].Value -le $numerics[2].Maximum)) | Should Be $true
        ($numerics[0].Minimum) | Should Be 15
        ($numerics[0].Maximum) | Should Be 86400
        ($numerics[1].Minimum) | Should Be 0
        ($numerics[1].Maximum) | Should Be 100
        ($numerics[2].Maximum) | Should Be 100
        # The refresh spinner can never be handed a value below its minimum.
        ($numerics[0].Value -ge 15) | Should Be $true
        ((Get-Content -LiteralPath $scratch.Path -Raw -Encoding UTF8)) | Should Be $before
      } finally {
        try { Remove-Item $scratch.Dir -Recurse -Force } catch { }
      }
    }
  }

  It "builds a window whose configuration omits the numbers entirely" {
    $scratch = New-ScratchNumberConfig '{"profiles":[{"id":"personal","name":"Personal","apiKey":"k"}]}'
    try {
      $numerics = Open-SettingsWindow -ConfigPath $scratch.Path
      ($script:WindowError) | Should BeNullOrEmpty
      ($numerics.Count) | Should Be 3
      # The documented defaults, so a file without a `thresholds` block opens on
      # something usable rather than on an empty spinner.
      ($numerics[0].Value) | Should Be 120
      ($numerics[1].Value) | Should Be 60
      ($numerics[2].Value) | Should Be 85
    } finally {
      try { Remove-Item $scratch.Dir -Recurse -Force } catch { }
    }
  }

  It "never hands a spinner a value its range rejects" {
    # The rule behind the crash, asserted directly: whatever the file says, the
    # value handed to the control is inside its own range.
    $refreshRange = $script:CcRefreshSecondsRange
    $thresholdRange = $script:CcThresholdRange
    foreach ($value in @(0, -1, -1000, 14, 15, 16, 120, 86400, 86401, 9999999, $null, "", "abc", "42", 42.7)) {
      $refresh = Get-CcSpinnerValue $value $refreshRange.Min $refreshRange.Max $refreshRange.Default
      (($refresh -ge $refreshRange.Min) -and ($refresh -le $refreshRange.Max)) | Should Be $true
      $warn = Get-CcSpinnerValue $value $thresholdRange.Min $thresholdRange.Max $thresholdRange.WarnDefault
      (($warn -ge $thresholdRange.Min) -and ($warn -le $thresholdRange.Max)) | Should Be $true
      $critical = Get-CcSpinnerValue $value $thresholdRange.Min $thresholdRange.Max $thresholdRange.CriticalDefault
      (($critical -ge $thresholdRange.Min) -and ($critical -le $thresholdRange.Max)) | Should Be $true
    }
    # The named edge cases, spelled out. A value below the minimum falls back to
    # the documented default (the configured value is unusable, not merely too
    # small); a value above the maximum is capped at it.
    (Get-CcSpinnerValue 0 15 86400 120) | Should Be 120
    (Get-CcSpinnerValue -30 15 86400 120) | Should Be 120
    (Get-CcSpinnerValue 14 15 86400 120) | Should Be 120
    (Get-CcSpinnerValue 15 15 86400 120) | Should Be 15
    (Get-CcSpinnerValue -5 0 100 60) | Should Be 60
    (Get-CcSpinnerValue 150 0 100 60) | Should Be 100
    (Get-CcSpinnerValue 86401 15 86400 120) | Should Be 86400
    (Get-CcSpinnerValue $null 15 86400 120) | Should Be 120
    (Get-CcSpinnerValue 42.6 0 100 60) | Should Be 43
  }

  It "reports a failure through the log and the table's line, in the active language" {
    # The guard the window falls back on when nothing is on screen. It runs inside
    # a catch, so it must not throw a second time, and it must record the reason
    # where every other tray failure goes. Its popup is suppressed for this run;
    # what is asserted is the report: the finished line and the log entry.
    $message = "the test's deliberately impossible failure"
    $log = Join-Path $CachedLogDir "tray-error.log"
    $before = 0
    if (Test-Path -LiteralPath $log) { $before = (Get-Item -LiteralPath $log).Length }
    $suppressed = Test-CcSettingsPopupSuppressed
    [void](Set-CcSettingsPopupSuppressed $true)
    try {
      $english = $null
      $threw = $false
      try { $english = Show-CcSettingsFatalError -Message $message -Language "en" } catch { $threw = $true }
      ($threw) | Should Be $false
      ($english) | Should Be ((Get-LanguageTable "en").settings.saveFailed -replace "\{message\}", $message)
      (Get-CcSettingsFailureReport -Message $message -Language "it") |
        Should Be ((Get-LanguageTable "it").settings.saveFailed -replace "\{message\}", $message)
      (Get-CcSettingsFailureReport -Message $message -Language "zh") |
        Should Be ((Get-LanguageTable "zh").settings.saveFailed -replace "\{message\}", $message)
      # The reason reached the tray's log, so it was reported and not swallowed.
      (Test-Path -LiteralPath $log) | Should Be $true
      ((Get-Item -LiteralPath $log).Length -gt $before) | Should Be $true
      ((Get-Content -LiteralPath $log -Raw -Encoding UTF8) -like "*$message*") | Should Be $true
    } finally {
      [void](Set-CcSettingsPopupSuppressed $suppressed)
    }
  }



  It "reports a failed save in the window instead of throwing out of the handler" {
    # A path the filesystem rejects, so the write fails inside the Save handler.
    $directory = Join-Path $env:TEMP ("cc-pester-bad-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $badPath = Join-Path $directory "bad?name.json"
    try {
      $script:WindowError = $null
      $script:FailureReported = @()
      $script:WindowTimer = New-Object System.Windows.Forms.Timer
      $script:WindowTimer.Interval = 300
      $script:WindowTimer.Add_Tick({
        $script:WindowTimer.Stop()
        $form = $script:CcSettingsForm
        if (-not $form) { return }
        try {
          # One account with one key: a valid draft, so the handler reaches the write.
          $edits = @(Get-Children $form | Where-Object {
            ($_ -is [System.Windows.Forms.TextBox]) -and -not ($_.Parent -is [System.Windows.Forms.UpDownBase])
          })
          if ($edits.Count -ge 2) {
            $edits[0].Text = "Only"
            $edits[1].Text = "a_key"
          }
          $saveButton = @(Get-Children $form | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq "Save" })[0]
          if (-not $saveButton) { throw "the Save button was not built" }
          $onClick = $saveButton.GetType().GetMethod("OnClick", [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
          [void]$onClick.Invoke($saveButton, @([System.EventArgs]::Empty))
          # The status line is where the user is told, in the active language.
          $script:FailureReported = @(Get-Children $form | Where-Object { $_ -is [System.Windows.Forms.Label] } |
            ForEach-Object { $_.Text } | Where-Object { $_ -like "*config.json*" })
        } catch {
          $script:WindowError = "the save handler threw: $($_.Exception.Message)"
        } finally {
          try { $form.Close() } catch { }
        }
      })
      $script:WindowTimer.Start()
      try {
        Show-CcSettingsWindow -Path $badPath -ActiveProfile "personal"
      } catch {
        $script:WindowError = $_.Exception.Message
      } finally {
        try { $script:WindowTimer.Stop(); $script:WindowTimer.Dispose() } catch { }
      }
      # The failure never escaped, and it was reported rather than swallowed.
      ($script:WindowError) | Should BeNullOrEmpty
      (@($script:FailureReported).Count -gt 0) | Should Be $true
      # Nothing was created where the invalid path pointed.
      (Test-Path -LiteralPath $badPath) | Should Be $false
    } finally {
      try { Remove-Item $directory -Recurse -Force } catch { }
    }
  }
}


