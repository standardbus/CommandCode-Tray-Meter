# Loads Pester (if present) and runs the tray drawing tests.
#
# Windows ships Pester 3.4, so these tests use its operator set. When Pester is
# missing the runner says so and exits successfully rather than failing the
# suite: the Node tests already cover the limits logic, and this file only adds
# assertions about colours and geometry.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test/run-selftest.ps1

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$tests = Join-Path $PSScriptRoot "tray.tests.ps1"

$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
  Write-Output "Pester non installato: salto i test di disegno (test/tray.tests.ps1)."
  Write-Output "Installalo con:  Install-Module Pester -Scope CurrentUser -Force"
  exit 0
}

Write-Output ("Pester {0} - eseguo {1}" -f $pester.Version, (Split-Path -Leaf $tests))
Import-Module Pester -MinimumVersion $pester.Version -Force
$result = Invoke-Pester -Path $tests -PassThru

Write-Output ("`n{0} test, {1} superati, {2} falliti, {3} saltati" -f `
  $result.TotalCount, $result.PassedCount, $result.FailedCount, $result.SkippedCount)

if ($result.FailedCount -gt 0) { exit 1 }
exit 0
