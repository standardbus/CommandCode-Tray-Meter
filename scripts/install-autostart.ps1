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
$description = "CommandCode Monitor - limiti 5 ore e settimanali"

function Get-StartupLinkPath {
  return (Join-Path ([Environment]::GetFolderPath("Startup")) "CommandCodeMonitor.lnk")
}

$linkPath = Get-StartupLinkPath

if (-not (Test-Path -LiteralPath $launcher)) {
  throw "Launcher non trovato: $launcher"
}

if ($DryRun) {
  Write-Output "Prova a vuoto (nessuna modifica). Verrebbero usati:"
  Write-Output "  collegamento   : $linkPath"
  Write-Output "  eseguibile     : $targetPath"
  Write-Output "  argomenti      : $arguments"
  Write-Output "  cartella lavoro: $root"
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

La cartella di avvio automatico e fuori dai percorsi scrivibili da questo
processo. Avvia lo script da una normale finestra PowerShell dell'utente
(non da un ambiente con restrizioni di filesystem) e riprova.
"@
  exit 1
}

if (-not (Test-Path -LiteralPath $linkPath)) {
  Write-Error "Il collegamento non risulta creato: $linkPath"
  exit 1
}

if (-not $Quiet) {
  Write-Output "Avvio automatico attivato:"
  Write-Output "  collegamento : $linkPath"
  Write-Output "  launcher     : $launcher"
  Write-Output ""
  Write-Output "Disattivalo con scripts\uninstall-autostart.ps1, oppure dalla voce"
  Write-Output "'Avvia con Windows' nel menu dell'icona."
}
