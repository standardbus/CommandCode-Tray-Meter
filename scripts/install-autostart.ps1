# Adds (or refreshes) the CommandCode Monitor shortcut in the user's Startup
# folder, so the tray icon appears next to the clock at every sign-in.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-autostart.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-autostart.ps1 -DryRun
#
# -DryRun resolves and reports everything without touching the filesystem, which
# is also how this script is verified in environments that deny writes outside
# the project directory.

param(
  [switch]$Quiet,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root "src\launch-hidden.vbs"

# wscript.exe runs the .vbs, which in turn starts PowerShell hidden: pointing the
# shortcut at powershell.exe directly would flash a console window at logon.
$targetPath = Join-Path $env:SystemRoot "System32\wscript.exe"
$arguments = "`"$launcher`""
$description = "CommandCode Monitor - 5-hour and weekly limits"

function Get-StartupLinkPath {
  return (Join-Path ([Environment]::GetFolderPath("Startup")) "CommandCodeMonitor.lnk")
}

$linkPath = Get-StartupLinkPath

if (-not (Test-Path -LiteralPath $launcher)) {
  throw "Launcher not found: $launcher"
}

if ($DryRun) {
  Write-Output "Dry run (nothing is changed). These values would be used:"
  Write-Output "  collegamento   : $linkPath"
  Write-Output "  executable     : $targetPath"
  Write-Output "  argomenti      : $arguments"
  Write-Output "  working folder : $root"
  Write-Output "  descrizione    : $description"
  Write-Output "  launcher esiste: $(Test-Path -LiteralPath $launcher)"
  exit 0
}

try {
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($linkPath)
  $shortcut.TargetPath = $targetPath
  $shortcut.Arguments = $arguments
  $shortcut.WorkingDirectory = $root
  $shortcut.Description = $description
  $shortcut.WindowStyle = 7
  $shortcut.Save()
} catch {
  Write-Error @"
Impossibile scrivere in "$linkPath".
$($_.Exception.Message)

The startup folder is outside the paths this process may write to
Run the script from a normal user PowerShell window (not from an
environment with filesystem restrictions) and try again.
"@
  exit 1
}

if (-not (Test-Path -LiteralPath $linkPath)) {
  Write-Error "The shortcut was not created: $linkPath"
  exit 1
}

if (-not $Quiet) {
  Write-Output "Start-at-login enabled:"
  Write-Output "  collegamento : $linkPath"
  Write-Output "  launcher     : $launcher"
  Write-Output ""
  Write-Output "Turn it off with scripts\uninstall-autostart.ps1, or from the"
  Write-Output "'Start with Windows' entry in the icon menu."
}
