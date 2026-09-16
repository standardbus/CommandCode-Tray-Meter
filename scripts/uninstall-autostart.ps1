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
  Write-Output "Prova a vuoto (nessuna modifica). Verrebbe rimosso:"
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

Avvia lo script da una normale finestra PowerShell dell'utente e riprova.
"@
    exit 1
  }
  if (-not $Quiet) { Write-Output "Avvio automatico disattivato: rimosso $linkPath" }
} elseif (-not $Quiet) {
  Write-Output "Nessun collegamento di avvio automatico da rimuovere."
}
