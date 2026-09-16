# Live-update harness for the limits bubble.
#
# Verifies the two properties the bubble must have:
#   1. it opens immediately, without waiting on the network;
#   2. it picks up fresh numbers while it stays open.
#
# A stub session process stands in for `src/session.mjs`, so the tray exercises
# the same loopback path it uses in production, and the stub's values grow on
# every refresh, which is what makes property 2 observable.
#
#   powershell -Sta -NoProfile -ExecutionPolicy Bypass -File test/live-update.ps1

param(
  [int]$WaitMs = 9000
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$sessionFile = Join-Path $root ".cache\session.json"

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
  Write-Output "RESULT: FAIL - node not found in PATH"
  exit 1
}

# Start the stub session and wait for its session file.
Remove-Item $sessionFile -Force -ErrorAction SilentlyContinue
$stub = Start-Process -FilePath $node `
  -ArgumentList @((Join-Path $PSScriptRoot "session-stub.mjs")) `
  -WorkingDirectory $root -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput (Join-Path $env:TEMP "cc-stub.log") `
  -RedirectStandardError (Join-Path $env:TEMP "cc-stub-err.log")

$ready = $false
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline -and -not $ready) {
  Start-Sleep -Milliseconds 150
  if (Test-Path $sessionFile) {
    try {
      $info = Get-Content $sessionFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($info.port -and $info.sessionToken) { $ready = $true }
    } catch { }
  }
}
if (-not $ready) {
  Write-Output "RESULT: FAIL - the stub session did not start"
  if ($stub -and -not $stub.HasExited) { Stop-Process -Id $stub.Id -Force }
  exit 1
}

$exitCode = 1

# The check itself. Driven by polling DoEvents with a hard deadline rather than
# Application.Run: a stuck message loop would otherwise hang the whole run with
# no output, which is exactly what a test must never do.
function Invoke-LiveUpdateCheck {
  param([int]$WaitMs = 9000)

  $script:RefreshIntervalMs = 1500
  $script:RefreshTimer.Interval = 1500
  $shots = Join-Path $root "screenshots"
  New-Item -ItemType Directory -Path $shots -Force | Out-Null

  $panelW = 320
  $panelH = $PanelHeight

  $savePanel = {
    param([string]$Name)
    $bitmap = [System.Drawing.Bitmap]::new($panelW, $panelH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    Draw-Panel -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0, 0, $panelW, $panelH))
    $graphics.Dispose()
    $bitmap.Save((Join-Path $shots $Name), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
  }

  $pump = {
    param([int]$Milliseconds)
    $until = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $until) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 20
    }
  }

  $script:TickTimer.Start()
  $script:RefreshTimer.Start()
  Start-LimitsUpdate
  Start-InitialWatchdog

  # Let the session answer at least once, so "before" is a real snapshot.
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 20
    if ($script:Data -and $script:Data.fiveHour) { break }
  }

  $openWatch = [System.Diagnostics.Stopwatch]::StartNew()
  Show-LimitsPopup
  $openWatch.Stop()
  $openMs = $openWatch.ElapsedMilliseconds
  $opened = $script:Popup.Visible
  $first = $script:Data
  $startRevision = Get-Value $first "revision"
  & $savePanel "popup-live-before.png"

  # Keep the pointer away from the bubble's corner so the outside-click hook is
  # not tripped by ambient pointer movement during the observation window.
  [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new(200, 200)

  & $pump $WaitMs

  $second = $script:Data
  $endRevision = Get-Value $second "revision"
  $stillOpen = $script:Popup.Visible
  & $savePanel "popup-live-after.png"
  $script:Popup.Close()
  $script:TickTimer.Stop()
  $script:RefreshTimer.Stop()
  if ($script:Watchdog) { $script:Watchdog.Stop() }

  $fields = @("fiveHour", "weekly", "monthly")
  $beforeText = ($fields | ForEach-Object { if ($first.$_) { $first.display."$_`Percent" } else { "--" } }) -join " / "
  $afterText = ($fields | ForEach-Object { if ($second.$_) { $second.display."$_`Percent" } else { "--" } }) -join " / "

  Write-Output "bubble opening        : $openMs ms (does not wait for the network)"
  Write-Output "windows before        : $beforeText"
  Write-Output "windows after         : $afterText"
  Write-Output "revision              : $startRevision -> $endRevision"
  Write-Output "bubble still open     : $stillOpen"

  $openOk = $opened -and $openMs -ge 0 -and $openMs -lt 1000
  $changed = $startRevision -ne $endRevision
  $dataOk = $null -ne $first -and $null -ne $first.fiveHour

  if ($openOk -and $changed -and $dataOk) {
    Write-Output "RESULT: PASS - immediate opening ($openMs ms) and values updated while the bubble stays open."
    $script:LiveUpdateResult = 0
    return
  }
  Write-Output "RESULT: FAIL - openOk=$openOk (${openMs}ms) changed=$changed dataOk=$dataOk stillOpen=$stillOpen"
  $script:LiveUpdateResult = 1
}

# Entry point, after the function so PowerShell can resolve it. The stub session
# is torn down whatever the outcome.
$script:LiveUpdateResult = 1
try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  . (Join-Path $root "src\tray.ps1") -ConfigPath (Join-Path $root "config.json") -NoSession -SelfTest
  Invoke-LiveUpdateCheck -WaitMs $WaitMs
  Write-Output "esito: $($script:LiveUpdateResult)"
} catch {
  Write-Output "RESULT: FAIL - eccezione: $($_.Exception.Message)"
  $script:LiveUpdateResult = 1
} finally {
  if ($stub -and -not $stub.HasExited) { Stop-Process -Id $stub.Id -Force -ErrorAction SilentlyContinue }
}

exit $script:LiveUpdateResult
