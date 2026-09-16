# Removes the CommandCode Monitor shortcut from the user's Startup folder.
# Safe to run when the shortcut is absent.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/uninstall-autostart.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/uninstall-autostart.ps1 -DryRun

param(
  [switch]$Quiet,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$linkPath = Join-Path ([Environment]::GetFolderPath("Startup")) "CommandCodeMonitor.lnk"

if ($DryRun) {
  Write-Output "Dry run (nothing is changed). This would be removed:"
  Write-Output "  $linkPath  (esiste: $(Test-Path -LiteralPath $linkPath))"
  exit 0
}

if (Test-Path -LiteralPath $linkPath) {
  try {
    Remove-Item -LiteralPath $linkPath -Force
  } catch {
    Write-Error @"
Impossibile rimuovere "$linkPath".
$($_.Exception.Message)

Run the script from a normal user PowerShell window and try again.
"@
    exit 1
  }
  if (-not $Quiet) { Write-Output "Start-at-login disabled: removed $linkPath" }
} elseif (-not $Quiet) {
  Write-Output "There is no start-at-login shortcut to remove."
}
