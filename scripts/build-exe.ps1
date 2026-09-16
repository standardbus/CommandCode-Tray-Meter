# Builds CommandCodeMonitor.exe.
#
# The executable is compiled with the C# compiler that ships with .NET Framework
# 4.8, which is present on every Windows 10 and 11 machine. The result is a
# single self-contained file: no Node, no PowerShell scripts, no installer, and
# nothing to unpack.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-exe.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-exe.ps1 -SkipSelfTest

param(
  [switch]$SkipSelfTest,
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $root "csharp"
$configPath = Join-Path $root "config.json"
if (-not (Test-Path $configPath)) { $configPath = Join-Path $root "config.example.json" }
if (-not $OutputPath) { $OutputPath = Join-Path $root "CommandCodeMonitor.exe" }

$csc = Join-Path $env:SystemRoot "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path $env:SystemRoot "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $csc)) {
  throw "csc.exe not found: .NET Framework 4.x is required and ships with Windows 10 and 11."
}

$sources = Get-ChildItem -Path $sourceDir -Filter *.cs | Sort-Object Name | ForEach-Object { $_.FullName }
if (-not $sources) { throw "Nessun sorgente in $sourceDir" }

# A GUI executable has no console, so its output goes to a file. Start-Process is
# preferred, but some locked-down environments refuse to launch another
# interpreter; in that case the call operator is used, which captures nothing and
# simply lets the redirected output be read back.
function Invoke-SelfTest {
  param([string]$Exe, [string]$ConfigPath, [string]$LogPath)
  # A distinct temporary file avoids any handle left by an earlier attempt, and a
  # fresh name per run avoids a stale file being mistaken for this run's output.
  $runLog = Join-Path $env:TEMP ("ccm-selftest-" + [Guid]::NewGuid().ToString("N") + ".log")
  try {
    $process = Start-Process -FilePath $Exe -ArgumentList @("--selftest", "--config", $ConfigPath) `
      -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput $runLog `
      -RedirectStandardError (Join-Path $env:TEMP "ccm-selftest-err.log")
    if (Test-Path $runLog) { Copy-Item $runLog $LogPath -Force }
    return $process.ExitCode
  } catch {
    # Some locked-down environments refuse Start-Process for another executable;
    # the call operator still runs it and its output is captured from the stream.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $text = ""
    try { $text = (& $Exe --selftest --config $ConfigPath 2>&1 | Out-String) }
    finally { $ErrorActionPreference = $previous }
    Set-Content -Path $LogPath -Value $text -Encoding UTF8
    return $(if ($text -match '0 failed') { 0 } else { 1 })
  }
}

Write-Output "CommandCode Monitor - build"
Write-Output "  sources    : $sourceDir ($($sources.Count) files)"
Write-Output "  output     : $OutputPath"
Write-Output "  compiler   : $csc"
Write-Output ""

# The icon is generated from source, so the repository carries no binary asset
# that nobody can regenerate.
$iconPath = Join-Path $sourceDir "app.ico"
if (-not (Test-Path $iconPath)) {
  Write-Output "Generating icon..."
  & (Join-Path $PSScriptRoot "make-icon.ps1") -OutputPath $iconPath | ForEach-Object { "  $_" }
}

Write-Output "Compiling..."
$arguments = @(
  "/nologo",
  "/target:winexe",
  "/optimize+",
  "/platform:anycpu",
  "/out:$OutputPath",
  "/win32icon:$iconPath",
  "/reference:System.dll",
  "/reference:System.Drawing.dll",
  "/reference:System.Windows.Forms.dll",
  "/reference:System.Net.Http.dll"
) + $sources

$output = & $csc @arguments 2>&1
$errors = $output | Where-Object { $_ -match 'error CS' }
if ($errors) {
  $errors | ForEach-Object { Write-Output "  $_" }
  throw "compilazione fallita"
}
$output | Where-Object { $_ -match 'warning CS' } | ForEach-Object { "  $_" }

$exe = Get-Item $OutputPath
Write-Output ("Created: {0} ({1:N0} KB)" -f $exe.FullName, ($exe.Length / 1KB))
Write-Output ""

if (-not $SkipSelfTest) {
  Write-Output "Executable self-test:"
  $testLog = Join-Path $env:TEMP "ccm-selftest.log"
  $exitCode = Invoke-SelfTest -Exe $OutputPath -ConfigPath $configPath -LogPath $testLog
  $report = if (Test-Path $testLog) { Get-Content $testLog -ErrorAction SilentlyContinue } else { @() }
  $report | ForEach-Object { "  $_" }
  if ($exitCode -ne 0 -or -not ($report -match '0 failed')) {
    Write-Output ""
    Write-Output "BUILD FAILED: the self-test did not pass."
    exit 1
  }
}

Write-Output ""
Write-Output "Done. Put CommandCodeMonitor.exe and config.json in the same folder and run it:"
Write-Output "  no Node, no PowerShell and no other files are needed."
