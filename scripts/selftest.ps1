# End-to-end environment self-test.
#
# Checks everything that can be verified without a credential or a network call:
# runtime detection, config readability, credential discovery, icon rendering and
# the popup open/close cycle.
#
#   powershell -Sta -NoProfile -ExecutionPolicy Bypass -File scripts/selftest.ps1

param(
  [string]$ConfigPath = "",
  [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $root "config.json" }

$script:Passed = 0
$script:Failed = 0
$script:Warnings = 0

function Test-Step {
  param([string]$Name, [scriptblock]$Body)
  try {
    $detail = & $Body
    $script:Passed++
    if (-not $Quiet) { Write-Output ("  [ok]   {0}{1}" -f $Name, $(if ($detail) { " - $detail" } else { "" })) }
  } catch {
    $script:Failed++
    Write-Output ("  [FAIL] {0} - {1}" -f $Name, $_.Exception.Message)
  }
}

function Write-Warn {
  param([string]$Message)
  $script:Warnings++
  Write-Output ("  [warn] {0}" -f $Message)
}

Write-Output "CommandCode Monitor - selftest"
Write-Output "  progetto : $root"
Write-Output "  config   : $ConfigPath"
Write-Output ""

Write-Output "Ambiente"

Test-Step "PowerShell 5.1 o superiore" {
  if ($PSVersionTable.PSVersion.Major -lt 5) { throw "serve PowerShell 5.1+" }
  "versione $($PSVersionTable.PSVersion)"
}

Test-Step "WinForms available" {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  "System.Windows.Forms caricato"
}

Test-Step "node.exe raggiungibile" {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { throw "node not found in PATH: the monitor would only run in reduced mode" }
  $version = (& $node.Source --version) 2>&1
  "$($node.Source) ($version)"
}

Test-Step "modalita STA (richiesta da WinForms)" {
  if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
    throw "esegui con: powershell -Sta -File scripts/selftest.ps1"
  }
  "STA"
}

Write-Output ""
Write-Output "Configuration and credentials"

Test-Step "config.json is readable" {
  if (-not (Test-Path $ConfigPath)) {
    throw "missing: copy config.example.json to config.json and paste your key"
  }
  $raw = Get-Content $ConfigPath -Raw -Encoding UTF8
  $null = $raw | ConvertFrom-Json
  "JSON valido"
}

Test-Step "credential source found" {
  $node = (Get-Command node).Source
  $fetch = Join-Path $root "src\fetch.mjs"
  $out = Join-Path $env:TEMP "cc-selftest-auth.json"
  & $node $fetch --auth-only --config $ConfigPath --out $out | Out-Null
  if (-not (Test-Path $out)) { throw "fetch.mjs --auth-only produced no output" }
  $report = (Get-Content $out -Raw -Encoding UTF8) | ConvertFrom-Json
  if (-not $report.hasToken) {
    throw "no credentials: $($report.message)"
  }
  "sorgente: $($report.source)"
}

Write-Output ""
Write-Output "Interface"

$script:Data = [pscustomobject]@{
  plan = [pscustomobject]@{ id = "selftest" }
  fiveHour = [pscustomobject]@{ used = 40; cap = 100; percent = 40; resetAt = (Get-Date).AddHours(3).ToString("o") }
  weekly = [pscustomobject]@{ used = 120; cap = 500; percent = 24; resetAt = (Get-Date).AddDays(2).ToString("o") }
  credits = [pscustomobject]@{ used = 15.4; limit = 36.4; remaining = 21; percent = 42 }
  display = [pscustomobject]@{
    fiveHourPercent = "40%"; fiveHourResetIn = "3h"; fiveHourResetAt = "12:00"
    weeklyPercent = "24%"; weeklyResetIn = "2g"; weeklyResetAt = "gio 13:00"
  }
  fetchedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  tooltip = "Command Code 5h 40% - 7g 24%"
}

. (Join-Path $root "src\tray.ps1") -ConfigPath $ConfigPath -NoSession -SelfTest

Test-Step "icon drawn at 16x16" {
  $icon = New-StatusIcon -FivePercent 40 -WeeklyPercent 24
  try {
    $bitmap = $icon.ToBitmap()
    try {
      if ($bitmap.Width -lt 16) { throw "bitmap troppo piccola: $($bitmap.Width)px" }
      $visible = 0
      for ($y = 0; $y -lt $bitmap.Height; $y++) {
        for ($x = 0; $x -lt $bitmap.Width; $x++) { if ($bitmap.GetPixel($x, $y).A -gt 40) { $visible++ } }
      }
      if ($visible -lt 40) { throw "icon nearly empty ($visible visible pixels)" }
      "$visible visible pixels"
    } finally { $bitmap.Dispose() }
  } finally { $icon.Dispose() }
}

Test-Step "tooltip within the Windows limit" {
  Update-TrayPresentation
  if ($script:TrayIcon.Text.Length -gt 63) { throw "tooltip is $($script:TrayIcon.Text.Length) characters" }
  "$($script:TrayIcon.Text.Length) characters"
}

Test-Step "bubble drawn without errors" {
  $bitmap = [System.Drawing.Bitmap]::new($PanelWidth, $PanelHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try { Draw-Panel -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0, 0, $PanelWidth, $PanelHeight)) }
    finally { $graphics.Dispose() }
    # The dark panel background must actually be there.
    $corner = $bitmap.GetPixel(4, 4)
    if ($corner.ToArgb() -ne $script:ColorPanel.ToArgb()) { throw "the bubble background was not drawn" }
    "${PanelWidth}x${PanelHeight} px"
  } finally { $bitmap.Dispose() }
}

Test-Step "bubble can be opened and closed" {
  $script:Popup.Show(([System.Drawing.Point]::new(200, 200)))
  $opened = $script:Popup.Visible
  $script:Popup.Close()
  if (-not $opened) { throw "the bubble did not open" }
  "opened and closed"
}

Write-Output ""
Write-Output ("Result: {0} ok, {1} failed, {2} warnings" -f $script:Passed, $script:Failed, $script:Warnings)

if ($script:Failed -gt 0) { exit 1 }
exit 0
