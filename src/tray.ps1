# CommandCode Monitor - tray icon + live limits popup.
#
# Lives in the notification area next to the Windows clock, drawing its own
# icon (a ring for the 5-hour window plus a dot for the weekly window). Clicking
# it opens a bubble that re-reads the limits from Command Code while it opens
# and keeps repainting in place as fresh numbers arrive.
#
# Run with:  powershell -Sta -NoProfile -ExecutionPolicy Bypass -File src\tray.ps1
#
# All limits logic (parsing, credential resolution, formatting) lives in the
# shared Node module; this file only transports and draws.

param(
  [string]$ConfigPath = "",
  [switch]$NoSession,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

# --- paths and constants ---------------------------------------------------

# Assemblies load before the palette below references System.Drawing types.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $ProjectRoot "config.json" }
$CacheDir = Join-Path $ProjectRoot ".cache"
$SessionFile = Join-Path $CacheDir "session.json"
$LogFile = Join-Path $CacheDir "tray-error.log"
# The account chosen from the tray menu is runtime state: the monitor never
# rewrites config.json, so the choice lives in the cache instead.
$ActiveProfileFile = Join-Path $CacheDir "active-profile.json"

# The translator is loaded before anything else can write a message, so even an
# early failure is reported in the configured language. Absent means English.
. (Join-Path $PSScriptRoot "lang.ps1")
try {
  $earlyConfig = $null
  if (Test-Path $ConfigPath) {
    $earlyJson = [System.IO.File]::ReadAllText($ConfigPath)
    if ($earlyJson -and $earlyJson.Trim()) { $earlyConfig = $earlyJson | ConvertFrom-Json }
  }
  Select-CcLanguage $(if ($earlyConfig) { [string]$earlyConfig.language } else { "" }) | Out-Null
} catch {
  Select-CcLanguage "" | Out-Null
}

$script:RefreshIntervalMs = 120000
$script:PhaseWarn = 60
$script:PhaseCritical = 85
$script:Monochrome = $false
$script:ShowTooltip = $true
# Which window the ring tracks; weekly stays on the corner dot either way.
$script:IconMetric = 'fiveHour'
# The account the icon follows: from the payload when the session knows several,
# otherwise the account recorded in the cache or named by config.json.
$script:ConfiguredProfile = ""
$script:CachedProfile = ""

# Palette: readable on both light and dark taskbars.
$script:ColorOk = [System.Drawing.Color]::FromArgb(46, 160, 67)
$script:ColorWarn = [System.Drawing.Color]::FromArgb(210, 153, 34)
$script:ColorCritical = [System.Drawing.Color]::FromArgb(209, 36, 47)
$script:ColorIdle = [System.Drawing.Color]::FromArgb(140, 143, 150)
$script:ColorTrack = [System.Drawing.Color]::FromArgb(70, 128, 128, 128)
$script:ColorText = [System.Drawing.Color]::FromArgb(235, 235, 235)
$script:ColorTextDim = [System.Drawing.Color]::FromArgb(160, 163, 168)
$script:ColorPanel = [System.Drawing.Color]::FromArgb(32, 33, 36)
$script:ColorPanelEdge = [System.Drawing.Color]::FromArgb(70, 70, 76)

$PanelWidth = 320
$PanelCloseSize = 16

# The bubble is 306px for the single account it has always shown. With two or
# more accounts an "Accounts" section is added below the figures and the panel
# grows with it: the window, the popup's minimum size and the mouse-hook
# geometry all read $PanelHeight, so one number keeps them in step.
$PanelBaseHeight = 306
$PanelAccountsTitleHeight = 26
$PanelAccountRowHeight = 18

function Get-PanelHeight {
  param([int]$AccountCount = 0)
  if ($AccountCount -lt 2) { return $PanelBaseHeight }
  return $PanelBaseHeight + $PanelAccountsTitleHeight + ($AccountCount * $PanelAccountRowHeight)
}

$PanelHeight = $PanelBaseHeight

function Write-TrayError {
  param([string]$Message)
  try {
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    # The log keeps the invariant timestamp format on purpose: a translated
    # locale would change the field order and break any grep over past runs.
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
  } catch { }
}

# Reading a file a child process just wrote can lose a race with the handle
# still closing, so reads retry briefly instead of surfacing a phantom error.
function Read-TextWithRetry {
  param([string]$Path, [int]$Attempts = 10, [int]$DelayMs = 40)
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
    } catch {
      if ($attempt -eq $Attempts) {
        Write-TrayError (Get-CcText "log.readingFailed" @{ path = $Path; message = $_.Exception.Message })
        return $null
      }
      Start-Sleep -Milliseconds $DelayMs
    }
  }
  return $null
}

# --- WinForms bootstrap ----------------------------------------------------

# Per-monitor DPI awareness must be set before any window or icon exists, or
# the tray icon comes out blurry on scaled displays.
try {
  Add-Type -Namespace CcMonitor -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")]
public static extern bool DestroyIcon(System.IntPtr hIcon);
'@
  [void][CcMonitor.Native]::SetProcessDPIAware()
} catch {
  Write-TrayError (Get-CcText "log.dpiUnavailable" @{ message = $_.Exception.Message })
}

# A ToolStripDropDown never takes mouse capture, so it cannot notice a click that
# lands outside it. A WH_MOUSE_LL hook is the only reliable way to dismiss the
# bubble when the user clicks elsewhere; without it the bubble stays on top.
try {
  Add-Type -Namespace CcMonitor -Name MouseHook -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }
[StructLayout(LayoutKind.Sequential)]
public struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo; }
public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll", SetLastError = true)]
public static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool UnhookWindowsHookEx(IntPtr hhk);
[DllImport("user32.dll")]
public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr GetModuleHandle(string lpModuleName);
'@
} catch {
  Write-TrayError (Get-CcText "log.mouseHookUnavailable" @{ message = $_.Exception.Message })
}

# Escape must be caught through a message filter: the dropdown never takes focus
# and ToolStripItem exposes no key events, so there is no KeyDown to hook. A
# message filter needs a real IMessageFilter implementation, which PowerShell
# cannot declare, hence the small C# type.
try {
  Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Windows.Forms;

public class PopupKeyFilter : IMessageFilter
{
    public const int WM_KEYDOWN = 0x0100;
    public Control Owner;
    public Func<bool> CloseBubble;

    public bool PreFilterMessage(ref Message m)
    {
        if (m.Msg != WM_KEYDOWN) return false;
        if ((int)m.WParam != (int)Keys.Escape) return false;
        if (Owner == null || !Owner.Visible) return false;
        if (CloseBubble == null) return false;
        CloseBubble();
        return true;
    }
}
'@
} catch {
  Write-TrayError (Get-CcText "log.keyboardFilterUnavailable" @{ message = $_.Exception.Message })
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# --- configuration + session bootstrap ------------------------------------

function Get-NodePath {
  if ($script:NodePath -ne $null) { return $script:NodePath }
  $command = Get-Command node -ErrorAction SilentlyContinue
  if ($command) { $script:NodePath = $command.Source } else { $script:NodePath = "" }
  return $script:NodePath
}

function Import-MonitorConfig {
  if (-not (Test-Path $ConfigPath)) { return }
  try {
    $raw = Get-Content $ConfigPath -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) { return }
    $config = $raw | ConvertFrom-Json
    if ($config.refreshSeconds -and [int]$config.refreshSeconds -ge 15) {
      $script:RefreshIntervalMs = [int]$config.refreshSeconds * 1000
    }
    if ($config.thresholds) {
      if ($config.thresholds.warn -ne $null) { $script:PhaseWarn = [double]$config.thresholds.warn }
      if ($config.thresholds.critical -ne $null) { $script:PhaseCritical = [double]$config.thresholds.critical }
    }
    if ($config.activeProfile) { $script:ConfiguredProfile = ([string]$config.activeProfile).Trim().ToLowerInvariant() }
    if ($config.ui) {
      $script:Monochrome = [bool]$config.ui.monochrome
      if ($config.ui.showTooltip -ne $null) { $script:ShowTooltip = [bool]$config.ui.showTooltip }
      $metric = [string]$config.ui.iconMetric
      if ($metric -eq 'fiveHour' -or $metric -eq 'weekly' -or $metric -eq 'monthly') {
        $script:IconMetric = $metric
      }
    }
  } catch {
    Write-TrayError (Get-CcText "log.configUnreadable" @{ message = $_.Exception.Message })
  }
}

# The account the tray follows. The session already puts the active account's
# fields at the top level of every payload, so the id only has to name it for
# the menu checkmark. Precedence matches the session's: cache, config, first.
function Get-ActiveProfileId {
  $payloadId = [string](Get-Value $script:Data "activeProfile")
  if ($payloadId) { return $payloadId.ToLowerInvariant() }
  if ($script:CachedProfile) { return $script:CachedProfile }
  if ($script:ConfiguredProfile) { return $script:ConfiguredProfile }
  $accounts = Get-AccountList
  if ($accounts.Count -gt 0) { return ([string](Get-Value $accounts[0] "id")).ToLowerInvariant() }
  return ""
}

function Get-AccountList {
  $accounts = Get-Value $script:Data "accounts"
  if ($null -eq $accounts) { return @() }
  # A single-element JSON array arrives as one object, not as a list.
  return @($accounts)
}

# The choice made in the menu is read back on startup, so the account the user
# picked is still the one on screen after the tray restarts.
function Get-CachedProfileId {
  try {
    if (-not (Test-Path $ActiveProfileFile)) { return "" }
    $raw = Read-TextWithRetry -Path $ActiveProfileFile -Attempts 3 -DelayMs 20
    if (-not $raw) { return "" }
    return ([string](($raw | ConvertFrom-Json).id)).Trim().ToLowerInvariant()
  } catch {
    return ""
  }
}

function Set-CachedProfileId {
  param([string]$Id)
  try {
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    # Written even when no session is running: the choice must survive a restart
    # and a network that is down right now.
    $entry = [pscustomobject]@{ id = $Id; at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    Set-Content -LiteralPath $ActiveProfileFile -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
  } catch {
    Write-TrayError "Set-CachedProfileId: $($_.Exception.Message)"
  }
}

function Get-SessionInfo {
  try {
    if (-not (Test-Path $SessionFile)) { return $null }
    $raw = Read-TextWithRetry -Path $SessionFile -Attempts 4 -DelayMs 30
    if (-not $raw) { return $null }
    $info = $raw | ConvertFrom-Json
    if (-not $info.port -or -not $info.sessionToken) { return $null }
    if (-not (Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue)) { return $null }
    return $info
  } catch {
    return $null
  }
}

function Start-LimitsSession {
  $node = Get-NodePath
  if (-not $node) {
    Write-TrayError (Get-CcText "log.nodeMissing")
    return $false
  }
  if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
  $outLog = Join-Path $CacheDir "session.log"
  $errLog = Join-Path $CacheDir "session-error.log"
  foreach ($path in @($outLog, $errLog)) {
    try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } } catch { }
  }
  # The session watches stdin so it dies with this tray. A detached child cannot
  # inherit our handle, so it is only used for the persistent session when
  # Start-Process is available.
  $arguments = @((Join-Path $PSScriptRoot "session.mjs"))
  if ($ConfigPath) { $arguments += @("--config", $ConfigPath) }
  try {
    $process = Start-Process -FilePath $node -ArgumentList $arguments `
      -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $script:SessionProcess = $process
    Write-TrayError (Get-CcText "log.sessionStarted" @{ pid = $process.Id })
    return $true
  } catch {
    Write-TrayError (Get-CcText "log.sessionUnavailable" @{ message = $_.Exception.Message })
    return $false
  }
}

function Invoke-SessionRequest {
  param([string]$Path, [string]$Method = "GET", [string]$Body = "")
  $info = Get-SessionInfo
  if (-not $info) { return $null }
  try {
    $headers = @{ "x-session-token" = $info.sessionToken }
    $arguments = @{
      Uri = "http://127.0.0.1:{0}{1}" -f [int]$info.port, $Path
      Method = $Method
      Headers = $headers
      TimeoutSec = 10
      UseBasicParsing = $true
    }
    if ($Body) {
      $arguments["Body"] = $Body
      $arguments["ContentType"] = "application/json"
    }
    return Invoke-RestMethod @arguments
  } catch {
    Write-TrayError (Get-CcText "log.sessionRequestFailed" @{ path = $Path; message = $_.Exception.Message })
    return $null
  }
}

# Native fallback: used when the persistent session is unavailable. This is the
# only path in which the tray itself asks for the limits.
function Invoke-NativeFetch {
  $node = Get-NodePath
  if (-not $node) { return $null }
  try {
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    $stdout = Join-Path $CacheDir "fetch-out.json"
    $stderr = Join-Path $CacheDir "fetch-err.log"
    $outFile = Join-Path $CacheDir "fetch-result.json"
    # Best effort only: a previous run's redirect handle can still be closing,
    # and a failed delete must never abort the fetch.
    foreach ($path in @($stdout, $stderr, $outFile)) {
      try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } } catch { }
    }
    # Node writes the result file itself, so no caller holds a lock on it when we
    # read it back straight after the process exits.
    $arguments = @((Join-Path $PSScriptRoot "fetch.mjs"), "--out", $outFile)
    if ($ConfigPath) { $arguments += @("--config", $ConfigPath) }

    # Preferred: a fully detached child. Some locked-down environments deny
    # Start-Process for another interpreter, so fall back to the call operator
    # with the same output contract.
    $launched = $false
    try {
      [void](Start-Process -FilePath $node -ArgumentList $arguments `
        -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru -Wait `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr)
      $launched = $true
    } catch {
      Write-TrayError (Get-CcText "log.startProcessUnavailable" @{ message = $_.Exception.Message })
    }
    if (-not $launched) {
      # No output redirection on this path: reusing those same files as the
      # child's stdout/stderr leaves Windows holding a sharing lock on them,
      # which then makes Test-Path and Remove-Item fail. Node writes the result
      # file itself, so its stdout is not needed here.
      $previousPreference = $ErrorActionPreference
      $ErrorActionPreference = "Continue"
      try {
        & $node @arguments | Out-Null
      } finally {
        $ErrorActionPreference = $previousPreference
      }
    }

    $text = $null
    if (Test-Path -LiteralPath $outFile) { $text = Read-TextWithRetry -Path $outFile }
    if (-not $text -or -not $text.Trim()) {
      Write-TrayError (Get-CcText "log.fetchEmpty" @{ code = $LASTEXITCODE })
      return $null
    }
    return ($text.Trim() | ConvertFrom-Json)
  } catch {
    Write-TrayError (Get-CcText "log.nativeFetchFailed" @{ message = $_.Exception.Message })
    return $null
  }
}

function Invoke-LimitsRequest {
  param([switch]$Force)
  $payload = $null
  if ($Force -and (Get-SessionInfo)) {
    # The session now answers /refresh immediately (202) and does the work in the
    # background, so this never blocks the UI thread.
    $payload = Invoke-SessionRequest -Path "/refresh" -Method "POST"
  }
  if (-not $payload) {
    $payload = Invoke-SessionRequest -Path "/state"
  }
  if (-not $payload) {
    # No session available: this is the only path that must block, because there
    # is nothing else to ask.
    $payload = Invoke-NativeFetch
  }
  return $payload
}

# --- async state polling ---------------------------------------------------
#
# Opening the bubble must never wait on the network. The bubble is drawn from the
# cached snapshot straight away, and the fresh numbers are collected off the UI
# thread and folded in as they arrive.

$script:PendingState = $null

function Request-StateAsync {
  if (-not $script:HttpClient) { return }
  $info = Get-SessionInfo
  if (-not $info) { return }
  try {
    $request = [System.Net.Http.HttpRequestMessage]::new(
      [System.Net.Http.HttpMethod]::Get,
      "http://127.0.0.1:$([int]$info.port)/state")
    [void]$request.Headers.Add("x-session-token", $info.sessionToken)
    # The Task is what gets stored: the request itself has no IsCompleted, so
    # keeping the request here would leave the completion check always false.
    $script:PendingState = @{
      Task = $script:HttpClient.SendAsync($request)
      Request = $request
    }
  } catch {
    Write-TrayError "Request-StateAsync: $($_.Exception.Message)"
  }
}

function Complete-PendingState {
  $pending = $script:PendingState
  if (-not $pending) { return $false }
  $task = $pending.Task
  if ($null -eq $task -or -not $task.IsCompleted) { return $false }
  $script:PendingState = $null
  try {
    $response = $task.Result
    if (-not $response) { return $false }
    if (-not $response.IsSuccessStatusCode) { return $false }
    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $text) { return $false }
    $payload = $text | ConvertFrom-Json
    if (-not $payload) { return $false }
    $previous = Get-Value $script:Data "revision"
    $fresh = Get-Value $payload "revision"
    if ($fresh -eq $previous -and $null -ne $previous) { return $false }
    $script:Data = $payload
    Update-TrayPresentation
    if ($script:Popup.Visible) { $script:OwnerDrawItem.Invalidate() }
    return $true
  } catch {
    Write-TrayError "Complete-PendingState: $($_.Exception.Message)"
    return $false
  } finally {
    try { $response.Dispose() } catch { }
    try { $pending.Request.Dispose() } catch { }
  }
}

# --- presentation helpers --------------------------------------------------

function Get-PhaseColor {
  param($Percent)
  if ($null -eq $Percent) { return $script:ColorIdle }
  if ($script:Monochrome) { return $script:ColorIdle }
  $value = [double]$Percent
  if ($value -ge $script:PhaseCritical) { return $script:ColorCritical }
  if ($value -ge $script:PhaseWarn) { return $script:ColorWarn }
  return $script:ColorOk
}

# The close affordance sits at the right of the header row.
function Get-CloseButtonRect {
  return [System.Drawing.Rectangle]::new(($PanelWidth - 16 - $PanelCloseSize), 9, $PanelCloseSize, $PanelCloseSize)
}

function Get-CloseButtonHit {
  param([System.Drawing.Point]$Point)
  return (Get-CloseButtonRect).Contains($Point)
}

# Setter rather than direct field writes: $script: resolves to the caller's
# scope, so hovering must be toggled from inside this module to take effect.
function Set-CloseHover {
  param([bool]$Hover)
  if ($script:CloseHover -eq $Hover) { return }
  $script:CloseHover = $Hover
  if ($script:OwnerDrawItem) { $script:OwnerDrawItem.Invalidate() }
}

# Windows 11 sizes the notification area from the taskbar edge, so the bubble is
# anchored to the working-area corner instead of the cursor: that is where the
# icons actually are, and it stops the bubble from covering the tray icon.
function Get-TrayAnchor {
  $working = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $margin = 8
  $roomBelow = $bounds.Bottom - $working.Bottom
  $roomAbove = $working.Top - $bounds.Top
  $x = $working.Right - $PanelWidth - $margin
  if ($x -lt $working.Left) { $x = $working.Left }
  if ($roomBelow -ge $roomAbove) {
    # Taskbar at the bottom: sit just above it.
    $y = $working.Bottom - $PanelHeight - $margin
  } else {
    # Taskbar at the top: sit just below it.
    $y = $working.Top + $margin
  }
  if ($y -lt $working.Top) { $y = $working.Top }
  if ($y + $PanelHeight -gt $working.Bottom) { $y = $working.Bottom - $PanelHeight }
  return [System.Drawing.Point]::new([int]$x, [int]$y)
}

# Renders the tray icon bitmap: a ring for the 5-hour window and a dot for the
# weekly one. Split out from New-StatusIcon so tests can inspect pixels without
# going through a native icon handle.
function New-StatusBitmap {
  param($FivePercent, $WeeklyPercent)
  # Drawn at 64px and resampled to the real tray size: a 16px master has too few
  # pixels to keep the ring's stroke and centre hole distinct.
  $size = 64
  $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $ringColor = if ($null -ne $FivePercent) { Get-PhaseColor $FivePercent } else { $script:ColorIdle }
    # Leave room bottom-right for the weekly dot.
    $inset = 6
    $diameter = $size - 2 * $inset
    $ringWidth = 10

    $trackPen = [System.Drawing.Pen]::new($script:ColorTrack, [float]$ringWidth)
    $graphics.DrawEllipse($trackPen, $inset, $inset, $diameter, $diameter)
    $trackPen.Dispose()

    if ($null -ne $FivePercent) {
      $sweep = [Math]::Max(0.0, [Math]::Min(100.0, [double]$FivePercent)) * 3.6
      if ($sweep -gt 0) {
        # Draw a 360-degree arc as a full circle: a single-arc sweep that wide
        # renders as a zero-length line in GDI+.
        $pen = [System.Drawing.Pen]::new($ringColor, [float]$ringWidth)
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        if ($sweep -ge 359.9) {
          $graphics.DrawEllipse($pen, $inset, $inset, $diameter, $diameter)
        } else {
          $graphics.DrawArc($pen, $inset, $inset, $diameter, $diameter, -90, [float]$sweep)
        }
        $pen.Dispose()
      }
    }

    # Weekly indicator in the bottom-right corner.
    $dotSize = 22
    $dotX = $size - $dotSize
    $dotY = $size - $dotSize
    $dotColor = if ($null -ne $WeeklyPercent) { Get-PhaseColor $WeeklyPercent } else { $script:ColorIdle }
    $dotBrush = [System.Drawing.SolidBrush]::new($dotColor)
    $outline = [System.Drawing.Pen]::new($script:ColorPanel, [float]4)
    $graphics.FillEllipse($dotBrush, $dotX, $dotY, $dotSize, $dotSize)
    $graphics.DrawEllipse($outline, $dotX, $dotY, $dotSize, $dotSize)
    $dotBrush.Dispose()
    $outline.Dispose()
  } catch {
    $graphics.Dispose()
    $bitmap.Dispose()
    throw
  }
  $graphics.Dispose()
  return $bitmap
}

function New-StatusIcon {
  param($FivePercent, $WeeklyPercent)
  $bitmap = New-StatusBitmap -FivePercent $FivePercent -WeeklyPercent $WeeklyPercent
  try {
    $handle = $bitmap.GetHicon()
    try {
      $icon = [System.Drawing.Icon]::FromHandle($handle)
      # An explicit 16x16 size makes GDI+ resample the 64px master down with
      # averaging; handing Windows the raw 64px frame instead would drop most of
      # the ring's pixels and leave a jagged, hole-less blob.
      return ([System.Drawing.Icon]::new($icon, 16, 16))
    } finally {
      try { [void][CcMonitor.Native]::DestroyIcon($handle) } catch { }
    }
  } finally {
    $bitmap.Dispose()
  }
}
# --- popup rendering -------------------------------------------------------

function New-SolidBrush {
  param([System.Drawing.Color]$Color)
  return [System.Drawing.SolidBrush]::new($Color)
}

function Draw-ProgressBar {
  param(
    [System.Drawing.Graphics]$Graphics,
    [int]$X, [int]$Y, [int]$Width, [int]$Height,
    $Percent, [System.Drawing.Color]$Color
  )
  $radius = 3
  $trackPath = New-Object System.Drawing.Drawing2D.GraphicsPath
  $trackPath.AddArc($X, $Y, $radius * 2, $radius * 2, 180, 90)
  $trackPath.AddArc($X + $Width - $radius * 2 - 1, $Y, $radius * 2, $radius * 2, 270, 90)
  $trackPath.AddArc($X + $Width - $radius * 2 - 1, $Y + $Height - $radius * 2 - 1, $radius * 2, $radius * 2, 0, 90)
  $trackPath.AddArc($X, $Y + $Height - $radius * 2 - 1, $radius * 2, $radius * 2, 90, 90)
  $trackPath.CloseFigure()
  $trackBrush = New-SolidBrush $script:ColorTrack
  $Graphics.FillPath($trackBrush, $trackPath)
  $trackBrush.Dispose()

  if ($null -ne $Percent) {
    $value = [Math]::Max(0.0, [Math]::Min(100.0, [double]$Percent))
    $fillWidth = [int][Math]::Round(($Width * $value) / 100.0)
    if ($fillWidth -lt 2 -and $value -gt 0) { $fillWidth = 2 }
    if ($fillWidth -gt 0) {
      # Clip to the rounded track so the fill inherits the same shape.
      $previousClip = $Graphics.Clip
      $Graphics.SetClip($trackPath)
      $fillBrush = New-SolidBrush $Color
      $Graphics.FillRectangle($fillBrush, $X, $Y, $fillWidth, $Height)
      $fillBrush.Dispose()
      $Graphics.Clip = $previousClip
    }
  }
  $trackPath.Dispose()
}

function Draw-LimitRow {
  param(
    [System.Drawing.Graphics]$Graphics,
    [int]$Y,
    [string]$Title,
    $Window,
    [string]$ResetIn,
    [string]$ResetAt,
    [string]$Usage
  )
  $left = 16
  $valueRight = $PanelWidth - 16
  $titleFont = $script:FontLabel
  $smallFont = $script:FontSmall

  $percentText = if ($null -eq $Window) { "--" } else { "{0}%" -f [Math]::Round([double]$Window.percent) }
  $percentSize = $Graphics.MeasureString($percentText, $titleFont)
  $Graphics.DrawString($Title, $titleFont, $script:BrushText, [float]$left, [float]$Y)
  $Graphics.DrawString($percentText, $titleFont, $script:BrushText, [float]($valueRight - $percentSize.Width), [float]$Y)

  if ($null -eq $Window) {
    $Graphics.DrawString((Get-CcText "panel.notOpen"), $smallFont, $script:BrushDim, [float]$left, [float]($Y + 18))
    return
  }

  $barY = $Y + 20
  Draw-ProgressBar -Graphics $Graphics -X $left -Y $barY -Width ($PanelWidth - 32) -Height 7 `
    -Percent $Window.percent -Color (Get-PhaseColor $Window.percent)

  # Usage comes pre-formatted from the shared module: the raw API values carry
  # nine decimals and would render as noise.
  $detail = Get-CcText "panel.used" @{ usage = $Usage }
  if ($ResetIn) { $detail += Get-CcText "panel.resetIn" @{ in = $ResetIn; at = $ResetAt } }
  $Graphics.DrawString($detail, $smallFont, $script:BrushDim, [float]$left, [float]($barY + 11))
}

# Text-only line, for the figures the dashboard shows that are not windows.
function Draw-TextRow {
  param(
    [System.Drawing.Graphics]$Graphics,
    [int]$Y,
    [string]$Label,
    [string]$Value
  )
  $Graphics.DrawString($Label, $script:FontSmall, $script:BrushDim, [float]16, [float]($Y + 2))
  $size = $Graphics.MeasureString($Value, $script:FontLabel)
  $Graphics.DrawString($Value, $script:FontLabel, $script:BrushText, [float]($PanelWidth - 16 - $size.Width), [float]$Y)
}

# One account of the Accounts section: the name on the left, the three windows on
# the right. The layout comes from `panel.accountRow`, so a translation decides
# the order of the figures and the separators between them.
function Draw-AccountRow {
  param(
    [System.Drawing.Graphics]$Graphics,
    [int]$Y,
    $Account,
    [bool]$Active
  )
  $name = [string](Get-Value $Account "name")
  if (-not $name) { $name = [string](Get-Value $Account "id") }
  $display = Get-Value $Account "display"
  $percentOf = {
    param($Key)
    $value = [string](Get-Value $display "$($Key)Percent")
    if ($value) { return $value }
    return "--"
  }
  $text = Get-CcText "panel.accountRow" @{
    name = $name
    five = (& $percentOf "fiveHour")
    weekly = (& $percentOf "weekly")
    monthly = (& $percentOf "monthly")
  }
  $font = if ($Active) { $script:FontLabel } else { $script:FontSmall }
  $brush = if ($Active) { $script:BrushText } else { $script:BrushDim }
  # The active account gets a marker in the left margin, so the row that matches
  # the figures above is identifiable without reading the names.
  if ($Active) {
    $marker = New-SolidBrush $script:ColorOk
    $Graphics.FillEllipse($marker, 6, ($Y + 7), 4, 4)
    $marker.Dispose()
  }
  $Graphics.DrawString($text, $font, $brush, [float]16, [float]$Y)
}

function Draw-CreditsRow {
  param([System.Drawing.Graphics]$Graphics, [int]$Y, $Credits, [string]$Text)
  $left = 16
  if ($null -eq $Credits) { return }
  if (-not $Text) { $Text = Get-CcText "panel.noCredits" }
  $Graphics.DrawString($Text, $script:FontSmall, $script:BrushDim, [float]$left, [float]$Y)
}

# The whole bubble is one owner-drawn menu item, which is what lets it repaint
# in place while a refresh is in flight instead of closing and reopening.
function Draw-Panel {
  param([System.Drawing.Graphics]$Graphics, [System.Drawing.Rectangle]$Bounds)
  $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

  $background = New-SolidBrush $script:ColorPanel
  $Graphics.FillRectangle($background, $Bounds)
  $background.Dispose()

  $data = $script:Data
  $hasError = ($data -ne $null) -and ($data.status -ne $null) -and ($data.status -ne "")
  $isStale = ($data -ne $null) -and ([bool]$data.stale)
  $noData = ($null -eq $data)

  # Header: title on the left, refresh state on the right. The accent dot tracks
  # the same window as the ring.
  $accent = if ($hasError -or $noData) {
    $script:ColorIdle
  } else {
    Get-PhaseColor (Get-Value (Get-Value $data $script:IconMetric) "percent")
  }
  $markerBrush = New-SolidBrush $accent
  $Graphics.FillEllipse($markerBrush, 16, 18, 10, 10)
  $markerBrush.Dispose()

  $Graphics.DrawString((Get-CcText "panel.title"), $script:FontTitle, $script:BrushText, [float]30, [float]13)
  # The plan label sits between the title and the close button, and is dropped
  # rather than overlapped when there is no room for it.
  $closeRect = Get-CloseButtonRect
  if ($data -and $data.plan -and $data.plan.id) {
    $planText = [string]$data.plan.id
    $planSize = $Graphics.MeasureString($planText, $script:FontSmall)
    $titleSize = $Graphics.MeasureString((Get-CcText "panel.title"), $script:FontTitle)
    $planX = $closeRect.Left - 10 - $planSize.Width
    if ($planX -gt (30 + $titleSize.Width + 8)) {
      $Graphics.DrawString($planText, $script:FontSmall, $script:BrushDim, [float]$planX, [float]18)
    }
  }

  # Close button: always drawn, including on the error card, so the bubble can
  # never be left on screen without a way out.
  if ($script:CloseHover) {
    $hoverGround = New-SolidBrush ([System.Drawing.Color]::FromArgb(58, 235, 235, 235))
    $Graphics.FillEllipse($hoverGround, $closeRect)
    $hoverGround.Dispose()
  }
  $crossPen = New-Object System.Drawing.Pen($(if ($script:CloseHover) { $script:BrushText.Color } else { $script:ColorTextDim }), 1.6)
  $crossInset = 5
  $Graphics.DrawLine($crossPen, ($closeRect.Left + $crossInset), ($closeRect.Top + $crossInset), ($closeRect.Right - $crossInset), ($closeRect.Bottom - $crossInset))
  $Graphics.DrawLine($crossPen, ($closeRect.Right - $crossInset), ($closeRect.Top + $crossInset), ($closeRect.Left + $crossInset), ($closeRect.Bottom - $crossInset))
  $crossPen.Dispose()

  if ($noData) {
    $Graphics.DrawString((Get-CcText "panel.waiting"), $script:FontLabel, $script:BrushDim, [float]16, [float]56)
    return
  }

  if ($hasError) {
    $message = if ($data.message) { [string]$data.message } else { Get-CcText "panel.noData" }
    # Direct constructors rather than New-Object: New-Object's argument binding
    # mis-parses an inline expression such as `$PanelWidth - 32` and fails with a
    # confusing "op_Subtraction" error instead of constructing the rectangle.
    $rect = [System.Drawing.RectangleF]::new(16, 54, [float]($PanelWidth - 32), 116)
    $Graphics.DrawString($message, $script:FontLabel, $script:BrushText, $rect)
    $hint = Get-CcText "panel.openConfig"
    $Graphics.DrawString($hint, $script:FontSmall, $script:BrushDim, [float]16, [float]176)
    return
  }

  Draw-LimitRow -Graphics $Graphics -Y 50 -Title (Get-CcText "panel.fiveHour") -Window $data.fiveHour `
    -ResetIn $data.display.fiveHourResetIn -ResetAt $data.display.fiveHourResetAt `
    -Usage $data.display.fiveHourUsage
  Draw-LimitRow -Graphics $Graphics -Y 106 -Title (Get-CcText "panel.weekly") -Window $data.weekly `
    -ResetIn $data.display.weeklyResetIn -ResetAt $data.display.weeklyResetAt `
    -Usage $data.display.weeklyUsage
  Draw-LimitRow -Graphics $Graphics -Y 162 -Title (Get-CcText "panel.monthly") -Window $data.monthly `
    -ResetIn $data.display.monthlyResetIn -ResetAt $data.display.monthlyResetAt `
    -Usage $data.display.monthlyUsage
  Draw-TextRow -Graphics $Graphics -Y 218 -Label (Get-CcText "panel.tokens") `
    -Value $(if ($data.tokens) { $data.display.tokensValue } else { Get-CcText "panel.notUpdated" })
  Draw-TextRow -Graphics $Graphics -Y 242 -Label (Get-CcText "panel.runs") `
    -Value $(if ($data.runs) { $data.display.runsValue } else { Get-CcText "panel.notUpdated" })
  Draw-CreditsRow -Graphics $Graphics -Y 266 -Credits $data.credits -Text $data.display.creditsText

  # Footer.
  $footerY = $PanelHeight - 18

  # Accounts: the section exists only when there is more than one, so the
  # single-account bubble keeps the exact layout it has always had.
  $accounts = Get-AccountList
  if ($accounts.Count -ge 2) {
    # One scale for the whole section: the title and the rows are laid out from
    # the footer upwards, so the growth in $PanelHeight is exactly what they use.
    $rowScale = 18
    $firstRowY = $footerY - 6 - ($accounts.Count * $rowScale)
    $Graphics.DrawString((Get-CcText "panel.accounts"), $script:FontSmall, $script:BrushDim, [float]16, [float]($firstRowY - 20))
    $activeId = Get-ActiveProfileId
    for ($index = 0; $index -lt $accounts.Count; $index++) {
      $account = $accounts[$index]
      $rowY = $firstRowY + ($index * $rowScale)
      $rowId = ([string](Get-Value $account "id")).ToLowerInvariant()
      Draw-AccountRow -Graphics $Graphics -Y $rowY -Account $account -Active ($rowId -eq $activeId)
    }
  }

  # The footer clock is derived from fetchedAt on every presentation pass rather
  # than carried in the payload, so a poll that updates the session state without
  # going through Submit-Refresh cannot leave a stale time on screen.
  $updated = "-"
  if ($data) {
    $stamp = Get-Value $data "fetchedAt"
    if ($stamp -and [double]$stamp -gt 0) {
      try {
        # The clock is formatted for the active language, so an Italian or
        # Chinese tray reads dates in its own convention.
        $updated = Get-CcDateTime ([DateTimeOffset]::FromUnixTimeMilliseconds([long][double]$stamp).ToLocalTime().DateTime)
      } catch {
        $updated = "-"
      }
    }
  }
  $Graphics.DrawString((Get-CcText "panel.updated" @{ time = $updated }), $script:FontSmall, $script:BrushDim, [float]16, [float]$footerY)

  $note = ""
  if ($script:Fetching) { $note = Get-CcText "panel.refreshing" }
  elseif ($isStale) { $note = Get-CcText "panel.notUpdated" }
  if ($note) {
    $noteColor = if ($isStale) { $script:ColorWarn } else { $script:ColorTextDim }
    $noteBrush = New-SolidBrush $noteColor
    $noteSize = $Graphics.MeasureString($note, $script:FontSmall)
    $Graphics.DrawString($note, $script:FontSmall, $noteBrush, [float]($PanelWidth - 16 - $noteSize.Width), [float]$footerY)
    $noteBrush.Dispose()
  }
}

# --- state application -----------------------------------------------------

function Get-Value {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

# --- profiles --------------------------------------------------------------
#
# The session fetches every configured account in one pass and returns the list
# of accounts plus the one that is active, with the active account's fields at
# the top level. Only switching the active account is the tray's job, and the
# choice is recorded in the cache: config.json is never written.

function Switch-ActiveProfile {
  param([string]$Id)
  $wanted = ([string]$Id).Trim().ToLowerInvariant()
  if (-not $wanted) { return }
  # Written first, so the choice survives even if no session is listening.
  [void](Set-CachedProfileId $wanted)
  $body = @{ id = $wanted } | ConvertTo-Json -Compress
  # The session answers with the payload of the newly active account, so the
  # bubble repaints from this response instead of waiting for the next poll.
  $payload = Invoke-SessionRequest -Path "/profile" -Method "POST" -Body $body
  if ($payload) { $script:Data = $payload }
  Update-TrayPresentation
  if ($script:Popup.Visible) { $script:OwnerDrawItem.Invalidate() }
}

function Update-TrayPresentation {
  $data = $script:Data
  $ringPercent = $null
  $weeklyPercent = $null
  $tooltip = Get-CcText "status.starting"

  if ($data -and -not (Get-Value $data "status")) {
    # The ring follows the configured window; the weekly dot is independent.
    $ringPercent = Get-Value (Get-Value $data $script:IconMetric) "percent"
    $weeklyPercent = Get-Value (Get-Value $data "weekly") "percent"
    $tooltip = [string](Get-Value $data "tooltip")
    if ([bool](Get-Value $data "stale")) { $tooltip += (Get-CcText "panel.stale") }
    # With several accounts the tooltip has to say which one it is reporting,
    # since only the active account is shown. The payload already carries the
    # finished "Command Code ..." line, so the name is prefixed to it rather
    # than the line being wrapped a second time.
    $accounts = Get-AccountList
    if ($accounts.Count -ge 2) {
      $activeId = Get-ActiveProfileId
      foreach ($account in $accounts) {
        if (([string](Get-Value $account "id")).ToLowerInvariant() -eq $activeId) {
          $tooltip = "$([string](Get-Value $account 'name')) $tooltip"
          break
        }
      }
    }
  } elseif ($data) {
    $status = [string](Get-Value $data "status")
    if ($status -eq "auth_needed") { $tooltip = Get-CcText "status.authNeeded" }
    else { $tooltip = Get-CcText "status.unavailable" }
  }

  # The bubble, the popup and the tray icon all follow the active account, so a
  # change in the account list resizes them here rather than at draw time.
  $accountCount = (Get-AccountList).Count
  $wantedHeight = Get-PanelHeight -AccountCount $accountCount
  if ($wantedHeight -ne $PanelHeight) { Set-PanelHeight -Height $wantedHeight }

  Update-AccountMenu
  # Repaint the icon only when a value actually changed.
  $statusKey = [string](Get-Value $data "status")
  $signature = "{0}|{1}|{2}|{3}|{4}|{5}" -f $ringPercent, $weeklyPercent, $script:IconMetric, $script:Monochrome, $statusKey, (Get-ActiveProfileId)
  if ($signature -ne $script:IconSignature) {
    $script:IconSignature = $signature
    $newIcon = New-StatusIcon -FivePercent $ringPercent -WeeklyPercent $weeklyPercent
    $oldIcon = $script:TrayIcon.Icon
    $script:TrayIcon.Icon = $newIcon
    if ($oldIcon) { try { $oldIcon.Dispose() } catch { } }
  }

  if ($script:ShowTooltip) {
    # Windows caps a tray tooltip at 63 characters.
    if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 60) + "..." }
    $script:TrayIcon.Text = $tooltip
  }
}

# $PanelHeight is read by the window, the popup's minimum size and the mouse-hook
# geometry, so resizing it can never leave one of them stale. The `$script:`
# prefix is required here: a bare assignment would only shadow it locally.
function Set-PanelHeight {
  param([int]$Height)
  $script:PanelHeight = $Height
  if ($script:Popup) { $script:Popup.MinimumSize = [System.Drawing.Size]::new([int]$PanelWidth, [int]$Height) }
  if ($script:OwnerDrawItem) { $script:OwnerDrawItem.Size = [System.Drawing.Size]::new([int]$PanelWidth, [int]$Height) }
}

function Submit-Refresh {
  param([switch]$Force)
  if ($script:Fetching) { return }
  $script:Fetching = $true
  if ($script:Popup.Visible) { $script:OwnerDrawItem.Invalidate() }
  try {
    $payload = Invoke-LimitsRequest -Force:$Force
    if ($payload) {
      $script:Data = $payload
    } elseif ($null -eq $script:Data) {
      $script:Data = [pscustomobject]@{
        status = "network_error"
        message = Get-CcText "log.noSession"
      }
    }
  } catch {
    Write-TrayError "Submit-Refresh: $($_.Exception.Message)"
  } finally {
    $script:Fetching = $false
    Update-TrayPresentation
    if ($script:Popup.Visible) { $script:OwnerDrawItem.Invalidate() }
  }
}

function Show-LimitsPopup {
  if ($script:Popup.Visible) { return }
  $script:CloseRequested = $false
  # Open first, fetch after: the bubble paints from the cached snapshot
  # immediately and the fresh numbers arrive while it is already on screen.
  $script:LastAnchor = Get-TrayAnchor
  $script:Popup.Show($script:LastAnchor)
  Start-LimitsUpdate
}

# Ask for fresh numbers without ever blocking the UI thread.
function Start-LimitsUpdate {
  if ($script:Fetching) { return }
  $info = Get-SessionInfo
  if ($info) {
    $script:Fetching = $true
    try {
      # 202 immediately; the session does the slow work in the background.
      $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        "http://127.0.0.1:$([int]$info.port)/refresh")
      [void]$request.Headers.Add("x-session-token", $info.sessionToken)
      $request.Content = [System.Net.Http.StringContent]::new("")
      $script:PendingRefresh = @{
        Task = $script:HttpClient.SendAsync($request)
        Request = $request
      }
    } catch {
      Write-TrayError "Start-LimitsUpdate: $($_.Exception.Message)"
      $script:Fetching = $false
    }
    Request-StateAsync
    return
  }
  # No session yet: the one-shot probe is the only option and it blocks. It must
  # not leave Fetching set, or the startup watchdog could never retry.
  Submit-Refresh -Force
}

# The session answers /refresh with 202 as soon as it accepts the work; its
# completion is what clears the "refreshing..." note.
function Complete-PendingRefresh {
  $pending = $script:PendingRefresh
  if (-not $pending) { return $false }
  $task = $pending.Task
  if ($null -eq $task -or -not $task.IsCompleted) { return $false }
  $script:PendingRefresh = $null
  try {
    # The session answers 202 as soon as it accepts the work, so reaching here
    # only means "the request was accepted", not "the fetch is done".
    $script:Fetching = $false
    Request-StateAsync
    if ($script:Popup.Visible) { $script:OwnerDrawItem.Invalidate() }
    return $true
  } catch {
    Write-TrayError "Complete-PendingRefresh: $($_.Exception.Message)"
    return $false
  } finally {
    try { $pending.Task.Result.Dispose() } catch { }
    try { $pending.Request.Dispose() } catch { }
  }
}

# At startup the helper session needs a moment to bind, and its very first
# /state can answer before the first upstream fetch has produced anything. Both
# gaps are covered by retrying here, instead of leaving the tray blank until the
# next scheduled poll minutes later.
function Test-DataUsable {
  $data = $script:Data
  if (-not $data) { return $false }
  if (Get-Value $data "status") { return $true }
  if ((Get-Value $data "fiveHour") -or (Get-Value $data "weekly")) { return $true }
  return $false
}

function Start-InitialWatchdog {
  if ($script:Watchdog) { return }
  $script:Watchdog = New-Object System.Windows.Forms.Timer
  $script:Watchdog.Interval = 1000
  $script:Watchdog.Add_Tick({
    if (Test-DataUsable) { $script:Watchdog.Stop(); return }
    if ($script:PendingState -or $script:PendingRefresh) { return }
    # No session yet: try to start one. Its first fetch also covers the cold case.
    if (-not $NoSession -and -not (Get-SessionInfo)) { [void](Start-LimitsSession) }
    $script:Fetching = $false
    Start-LimitsUpdate
  })
  $script:Watchdog.Start()
}

# --- dismissal -------------------------------------------------------------

# Rooted delegate + handle: both must outlive the call that creates them.
$script:MouseHookProc = $null
$script:MouseHookHandle = [IntPtr]::Zero

# Pure predicate for "this screen point is outside the bubble". Kept separate
# from the hook so it can be tested without real mouse input, which cannot be
# synthesised from inside a single process.
function Test-PointOutsidePopup {
  param([int]$X, [int]$Y)
  if (-not $script:Popup) { return $false }
  $slack = 6
  $bounds = $script:Popup.Bounds
  $hit = [System.Drawing.Rectangle]::new(
    ($bounds.Left - $slack),
    ($bounds.Top - $slack),
    ($bounds.Width + 2 * $slack),
    ($bounds.Height + 2 * $slack))
  return -not $hit.Contains([System.Drawing.Point]::new($X, $Y))
}

function Start-MouseWatch {
  if ($script:MouseHookHandle -ne [IntPtr]::Zero) { return }
  if (-not ("CcMonitor.MouseHook" -as [type])) { return }
  try {
    $script:MouseHookProc = [CcMonitor.MouseHook+HookProc]{
      param($nCode, $wParam, $lParam)
      # A negative nCode means "pass this straight on" and must not be inspected.
      if ($nCode -ge 0 -and $script:Popup -and $script:Popup.Visible) {
        $message = [int64]$wParam
        # Button downs and wheel share one dismissal rule, but the button set is
        # tracked separately: a button down inside the bubble is handled by the
        # item's own handlers, whereas a wheel event inside it reaches the hook
        # without passing through them and would otherwise dismiss the bubble
        # while the pointer is visibly on top of it.
        $isButtonDown = ($message -eq 513 -or $message -eq 516 -or $message -eq 519)
        $isWheel = ($message -eq 522 -or $message -eq 526)
        if ($isButtonDown -or $isWheel) {
          $isOutside = $false
          try {
            $info = [System.Runtime.InteropServices.Marshal]::PtrToStructure($lParam, [type][CcMonitor.MouseHook+MSLLHOOKSTRUCT])
            # A small margin keeps a click on the bubble's own border from
            # dismissing it while the pointer is still visually inside.
            $isOutside = Test-PointOutsidePopup -X $info.pt.X -Y $info.pt.Y
          } catch {
            $isOutside = $false
          }
          if ($isOutside -or $isButtonDown) {
            # A button down inside the bubble is the one case where an inside
            # point still means "not ours": MouseDown has already run and the
            # flag it sets is the authority.
            if ($script:InsideClick) {
              $script:InsideClick = $false
            } elseif ($script:CloseRequested) {
              # The close button owns this click; it already closed the bubble.
            } elseif ($isOutside) {
              $script:Popup.Close()
            }
          }
        }
      }
      return [CcMonitor.MouseHook]::CallNextHookEx([IntPtr]::Zero, $nCode, $wParam, $lParam)
    }
    $module = [CcMonitor.MouseHook]::GetModuleHandle($null)
    $script:MouseHookHandle = [CcMonitor.MouseHook]::SetWindowsHookEx(14, $script:MouseHookProc, $module, 0)
    if ($script:MouseHookHandle -eq [IntPtr]::Zero) {
      Write-TrayError (Get-CcText "log.hookFailed" @{ message = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() })
    }
  } catch {
    Write-TrayError "Start-MouseWatch: $($_.Exception.Message)"
  }
}

function Stop-MouseWatch {
  if ($script:MouseHookHandle -eq [IntPtr]::Zero) { return }
  try { [void][CcMonitor.MouseHook]::UnhookWindowsHookEx($script:MouseHookHandle) } catch { }
  $script:MouseHookHandle = [IntPtr]::Zero
  $script:MouseHookProc = $null
}
# --- assembly --------------------------------------------------------------

$script:Fetching = $false
$script:Data = $null
$script:IconSignature = ""
$script:NodePath = $null
$script:SessionProcess = $null
$script:CloseHover = $false
$script:InsideClick = $false
$script:CloseRequested = $false
$script:LastAnchor = $null
$script:PendingState = $null
$script:PendingRefresh = $null
$script:Watchdog = $null
$script:AccountMenu = $null

# One client for the loopback session: non-blocking SendAsync calls plus a
# generous timeout, since none of these requests ever wait on the network.
try {
  Add-Type -AssemblyName System.Net.Http
  $script:HttpClient = [System.Net.Http.HttpClient]::new()
  $script:HttpClient.Timeout = [TimeSpan]::FromSeconds(15)
} catch {
  $script:HttpClient = $null
  Write-TrayError (Get-CcText "log.httpClientUnavailable" @{ message = $_.Exception.Message })
}

Import-MonitorConfig
# Read once: the file is tiny, and the checkmark, the tooltip and the panel
# marker must all agree on the same answer.
$script:CachedProfile = Get-CachedProfileId

if (-not $NoSession) {
  if (-not (Get-SessionInfo)) { [void](Start-LimitsSession) }
}

# Fonts and brushes are created once: creating them per paint would leak GDI
# handles for as long as the monitor runs. A CJK family is requested explicitly
# for Chinese, since "Segoe UI" has no CJK glyphs and would draw boxes.
function New-UiFont {
  param([string]$Family, [float]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
  try {
    return [System.Drawing.Font]::new($Family, $Size, $Style)
  } catch {
    return [System.Drawing.Font]::new("Segoe UI", $Size, $Style)
  }
}

$fontFamily = Get-CcFontFamily
if (-not $fontFamily) { $fontFamily = "Segoe UI" }
$script:FontTitle = New-UiFont -Family $fontFamily -Size ([float]11) -Style ([System.Drawing.FontStyle]::Bold)
$script:FontLabel = New-UiFont -Family $fontFamily -Size ([float]9.5)
$script:FontSmall = New-UiFont -Family $fontFamily -Size ([float]8)
$script:BrushText = New-SolidBrush $script:ColorText
$script:BrushDim = New-SolidBrush $script:ColorTextDim

$script:Popup = New-Object System.Windows.Forms.ContextMenuStrip
$script:Popup.ShowImageMargin = $false
$script:Popup.ShowCheckMargin = $false
$script:Popup.Padding = [System.Windows.Forms.Padding]::new(0)
# On, so the dropdown keeps its normal dismissal behaviour. Live repainting does
# not depend on it: that is driven by the tick timer and is unaffected by a click
# landing on the bubble.
$script:Popup.AutoClose = $true
$script:Popup.BackColor = $script:ColorPanel
# A ContextMenuStrip lays itself out from its items' *preferred* sizes, and an
# owner-drawn item reports a tiny one (42x22) no matter what Size is assigned.
# Without a minimum the bubble collapses to a narrow sliver and clips the panel.
$script:Popup.MinimumSize = [System.Drawing.Size]::new([int]$PanelWidth, [int]$PanelHeight)

$script:OwnerDrawItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:OwnerDrawItem.AutoSize = $false
$script:OwnerDrawItem.Size = [System.Drawing.Size]::new([int]$PanelWidth, [int]$PanelHeight)
$script:OwnerDrawItem.BackColor = $script:ColorPanel
$script:OwnerDrawItem.Add_Paint({
  param($sender, $eventArgs)
  Draw-Panel -Graphics $eventArgs.Graphics -Bounds $sender.Bounds
})
[void]$script:Popup.Items.Add($script:OwnerDrawItem)

# --- bubble interaction ----------------------------------------------------

# Hover feedback for the close button. Tracked on the item rather than with
# MouseLeave, which does not fire reliably on a ToolStripItem.
$script:OwnerDrawItem.Add_MouseMove({
  param($sender, $eventArgs)
  Set-CloseHover -Hover (Get-CloseButtonHit -Point $eventArgs.Location)
})

# An inside click must be recorded before the mouse hook sees it: MouseDown runs
# first, and that is what tells the hook the click was not "outside".
$script:OwnerDrawItem.Add_MouseDown({
  param($sender, $eventArgs)
  $script:InsideClick = $true
  if ($script:CloseHover) { $script:CloseRequested = $true }
})

$script:OwnerDrawItem.Add_MouseUp({
  param($sender, $eventArgs)
  if ($script:CloseHover) {
    $script:Popup.Close()
  }
})

# Escape is the keyboard equivalent of clicking away.
$script:PopupKeyFilter = $null
if ("PopupKeyFilter" -as [type]) {
  try {
    $script:PopupKeyFilter = New-Object PopupKeyFilter
    $script:PopupKeyFilter.Owner = $script:Popup
    $script:PopupKeyFilter.CloseBubble = [Func[bool]]{
      $script:CloseRequested = $true
      $script:Popup.Close()
      return $true
    }
    [System.Windows.Forms.Application]::AddMessageFilter($script:PopupKeyFilter)
  } catch {
    Write-TrayError (Get-CcText "log.messageFilterFailed" @{ message = $_.Exception.Message })
  }
}

$script:Popup.Add_Opened({
  $script:CloseHover = $false
  $script:InsideClick = $false
  $script:CloseRequested = $false
  Start-MouseWatch
})

# Single owner of the dismissal cleanup: however the bubble goes away (close
# button, outside click, Escape, tray action), the hook stops here.
$script:Popup.Add_Closed({
  Stop-MouseWatch
})

$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-MenuItem {
  param([string]$Text, [scriptblock]$OnClick)
  $item = New-Object System.Windows.Forms.ToolStripMenuItem
  $item.Text = $Text
  $item.Add_Click($OnClick)
  [void]$script:Menu.Items.Add($item)
  return $item
}

[void](Add-MenuItem -Text (Get-CcText "menu.show") -OnClick { Show-LimitsPopup })
[void](Add-MenuItem -Text (Get-CcText "menu.refresh") -OnClick {
  Start-LimitsUpdate
  if ($script:Popup.Visible) { $script:OwnerDrawItem.Invalidate() }
})
[void](Add-MenuItem -Text (Get-CcText "menu.openConfig" @{ file = (Split-Path -Leaf $ConfigPath) }) -OnClick {
  if (-not (Test-Path $ConfigPath)) {
    $example = Join-Path $ProjectRoot "config.example.json"
    if (Test-Path $example) { Copy-Item $example $ConfigPath -Force }
  }
  if (Test-Path $ConfigPath) { Start-Process notepad.exe $ConfigPath } else { Write-TrayError (Get-CcText "log.configUnreadable" @{ message = (Split-Path -Leaf $ConfigPath) }) }
})
[void](Add-MenuItem -Text (Get-CcText "menu.settings") -OnClick {
  Start-Process "https://commandcode.ai/settings/keys"
})

# The Account submenu lists the accounts the session reports and checks the one
# the tray is following. It stays hidden until there is more than one account,
# so a single-account installation sees the menu it always saw.
$script:AccountMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$script:AccountMenu.Text = Get-CcText "menu.account"
$script:AccountMenu.Visible = $false
[void]$script:Menu.Items.Add($script:AccountMenu)

function Update-AccountMenu {
  $accounts = Get-AccountList
  $script:AccountMenu.DropDownItems.Clear()
  if ($accounts.Count -lt 2) {
    $script:AccountMenu.Visible = $false
    return
  }
  $script:AccountMenu.Visible = $true
  $activeId = Get-ActiveProfileId
  foreach ($account in $accounts) {
    $id = ([string](Get-Value $account "id")).ToLowerInvariant()
    $name = [string](Get-Value $account "name")
    if (-not $name) { $name = $id }
    $entry = New-Object System.Windows.Forms.ToolStripMenuItem
    $entry.Text = $name
    $entry.Checked = ($id -eq $activeId)
    $entry.Tag = $id
    # A closure per account: the handler must carry its own id, not the last one
    # the loop happened to assign.
    $entry.Add_Click({ param($sender, $eventArgs) Switch-ActiveProfile -Id ([string]$sender.Tag) })
    [void]$script:AccountMenu.DropDownItems.Add($entry)
  }
}

$script:AutostartItem = Add-MenuItem -Text (Get-CcText "menu.autostart") -OnClick {
  $installer = Join-Path $ProjectRoot "scripts\install-autostart.ps1"
  $uninstaller = Join-Path $ProjectRoot "scripts\uninstall-autostart.ps1"
  try {
    $startup = [System.IO.Path]::Combine([Environment]::GetFolderPath("Startup"), "CommandCodeMonitor.lnk")
    if (Test-Path $startup) { & $uninstaller | Out-Null } else { & $installer | Out-Null }
    $script:AutostartItem.Checked = Test-Path $startup
  } catch {
    Write-TrayError (Get-CcText "log.autostartFailed" @{ message = $_.Exception.Message })
  }
}
$startupLink = [System.IO.Path]::Combine([Environment]::GetFolderPath("Startup"), "CommandCodeMonitor.lnk")
$script:AutostartItem.Checked = Test-Path $startupLink
[void](Add-MenuItem -Text (Get-CcText "menu.exit") -OnClick {
  $script:Running = $false
  # Single exit path for the whole app: leave the message loop in Run().
  [System.Windows.Forms.Application]::ExitThread()
})

$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon.Icon = New-StatusIcon -FivePercent $null -WeeklyPercent $null
$script:TrayIcon.Text = Get-CcText "status.starting"
$script:TrayIcon.ContextMenuStrip = $script:Menu
$script:TrayIcon.Visible = $true
$script:TrayIcon.Add_MouseClick({
  param($sender, $eventArgs)
  if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    Show-LimitsPopup
  }
})
$script:TrayIcon.Add_DoubleClick({ Show-LimitsPopup })

# --- timers ----------------------------------------------------------------

$script:Running = $true
$script:TickTimer = New-Object System.Windows.Forms.Timer
$script:TickTimer.Interval = 250
$script:TickTimer.Add_Tick({
  # Fold in a completed async read first; it is what carries the fresh numbers.
  [void](Complete-PendingState)
  [void](Complete-PendingRefresh)
  # While the bubble is open, keep asking for the newest snapshot so the values
  # move on their own without the user reopening it.
  if ($script:Popup.Visible) {
    if (-not $script:PendingState) { Request-StateAsync }
  }
})

$script:RefreshTimer = New-Object System.Windows.Forms.Timer
$script:RefreshTimer.Interval = $script:RefreshIntervalMs
$script:RefreshTimer.Add_Tick({
  # Skipped while the bubble is open: the tick timer is already polling there.
  if ($script:Popup.Visible) { return }
  Start-LimitsUpdate
})

$script:KeepAliveTimer = New-Object System.Windows.Forms.Timer
$script:KeepAliveTimer.Interval = 30000
$script:KeepAliveTimer.Add_Tick({
  # Windows does not restore notification icons after an Explorer restart; a
  # periodic re-assert is the standard remedy.
  try {
    $script:TrayIcon.Visible = $false
    $script:TrayIcon.Visible = $true
  } catch { }
  # Restart the helper session if it died underneath us.
  if (-not $NoSession -and -not (Get-SessionInfo)) {
    Write-TrayError (Get-CcText "log.sessionUnavailable" @{ message = "session missing: restarting" })
    [void](Start-LimitsSession)
  }
})

if (-not $SelfTest) {
  $context = New-Object System.Windows.Forms.ApplicationContext
  $script:TickTimer.Start()
  $script:RefreshTimer.Start()
  $script:KeepAliveTimer.Start()

  # First load in the background, so the very first click already has numbers to
  # draw instead of showing an empty bubble.
  Start-LimitsUpdate
  Start-InitialWatchdog

  try {
    [System.Windows.Forms.Application]::Run($context)
  } finally {
    $script:Running = $false
    foreach ($timer in @($script:TickTimer, $script:RefreshTimer, $script:KeepAliveTimer, $script:Watchdog)) {
      try { $timer.Stop(); $timer.Dispose() } catch { }
    }
    # The global hook must come out before the process exits, or it lingers in
    # whatever is left of the session.
    Stop-MouseWatch
    if ($script:HttpClient) { try { $script:HttpClient.Dispose() } catch { } }
    try { $script:Popup.Close() } catch { }
    try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch { }
    if ($script:SessionProcess -and -not $script:SessionProcess.HasExited) {
      try { Stop-Process -Id $script:SessionProcess.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    foreach ($resource in @($script:FontTitle, $script:FontLabel, $script:FontSmall, $script:BrushText, $script:BrushDim)) {
      try { if ($resource) { $resource.Dispose() } } catch { }
    }
  }
}
