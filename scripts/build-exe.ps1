# Builds CommandCodeMonitor.exe.
#
# The executable is compiled with the C# compiler that ships with .NET Framework
# 4.8, which is present on every Windows 10 and 11 machine. The result is a
# single self-contained file: no Node, no PowerShell scripts, no installer, and
# nothing to unpack.
#
# The interface language tables are generated from lang/*.json before every
# compile, so the executable carries them and still ships alone.
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
$langDir = Join-Path $root "lang"
$configPath = Join-Path $root "config.json"
if (-not (Test-Path $configPath)) { $configPath = Join-Path $root "config.example.json" }
if (-not $OutputPath) { $OutputPath = Join-Path $root "CommandCodeMonitor.exe" }
# csc does not create directories, and a build into a fresh folder is the normal
# way to test a change while the running tray holds the repository's exe.
$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$csc = Join-Path $env:SystemRoot "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path $env:SystemRoot "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $csc)) {
  throw "csc.exe not found: .NET Framework 4.x is required and ships with Windows 10 and 11."
}

# Regenerated on every build so the compiled tables cannot drift from lang/*.json.
# The file is committed as well, so a checkout compiles without running this.
$generatedLang = Join-Path $sourceDir "Lang.Generated.cs"
Write-Output "Generating language tables..."
& (Join-Path $PSScriptRoot "gen-lang.ps1") -LangDir $langDir -OutputPath $generatedLang | ForEach-Object { "  $_" }

$sources = Get-ChildItem -Path $sourceDir -Filter *.cs | Sort-Object Name | ForEach-Object { $_.FullName }
if (-not $sources) { throw "no sources in $sourceDir" }

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
    return $(if ($text -match 'RESULT ok=\d+ failed=0') { 0 } else { 1 })
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
  "/codepage:65001",
  "/reference:System.dll",
  "/reference:System.Drawing.dll",
  "/reference:System.Windows.Forms.dll",
  "/reference:System.Net.Http.dll"
) + $sources

$output = & $csc @arguments 2>&1
$errors = $output | Where-Object { $_ -match 'error CS' }
if ($errors) {
  $errors | ForEach-Object { Write-Output "  $_" }
  throw "compilation failed"
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

  # The summary line binary-searchable on purpose: the human-readable one is
  # translated, so an Italian or Chinese interface would never match it.
  $summary = $report | Where-Object { $_ -match '^RESULT ok=\d+ failed=\d+' } | Select-Object -Last 1
  $checksPassed = -1
  $checksFailed = -1
  if ($summary -and $summary -match '^RESULT ok=(\d+) failed=(\d+)') {
    $checksPassed = [int]$Matches[1]
    $checksFailed = [int]$Matches[2]
  }

  if ($exitCode -ne 0 -or $checksFailed -ne 0) {
    Write-Output ""
    Write-Output "BUILD FAILED: the self-test did not pass."
    exit 1
  }
  Write-Output ""
  Write-Output ("Self-test passed: {0} checks." -f $checksPassed)
}

Write-Output ""
Write-Output "Done. Put CommandCodeMonitor.exe and config.json in the same folder and run it:"
Write-Output "  no Node, no PowerShell and no other files are needed."
