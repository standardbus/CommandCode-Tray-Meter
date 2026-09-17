# Language tables for the PowerShell surfaces.
#
# The tray and scripts/selftest.ps1 translate through this file, and it reads the
# same `lang/*.json` the Node side uses, so a label cannot drift between the two
# implementations. The semantics mirror `src/i18n.mjs` exactly: a key missing
# from the active table falls back to English and, failing that, to the key
# itself, because a visible `panel.tokens` in the interface is a bug report
# rather than a crash.
#
# Dot-sourced by both callers instead of being duplicated, so there is one place
# where a language is chosen.

Set-StrictMode -Off

$script:CcLangDir = Join-Path (Split-Path -Parent $PSScriptRoot) "lang"

# Language used when nothing is configured, or when a lookup fails.
$script:CcDefaultLanguage = "en"

# Market locale each language formats numbers and dates with.
$script:CcLocales = @{ en = "en-US"; it = "it-IT"; zh = "zh-CN" }

# A CJK-capable family: "Segoe UI" carries no CJK glyphs, so Chinese labels
# would render as boxes. The fallback list is applied through FontFamily, which
# resolves the first installed name.
$script:CcFontFamilies = @{ en = "Segoe UI"; it = "Segoe UI"; zh = "Microsoft YaHei UI" }

$script:CcLangTables = @{}
$script:CcLanguage = $script:CcDefaultLanguage

function Get-CcLanguageTable {
  param([string]$Code)
  if ($script:CcLangTables.ContainsKey($Code)) { return $script:CcLangTables[$Code] }
  $table = $null
  $path = Join-Path $script:CcLangDir "$Code.json"
  if (Test-Path -LiteralPath $path) {
    try {
      # ConvertFrom-Json reads the file as single-byte text, which mangles the
      # non-ASCII strings in it.json and zh.json, so the bytes are decoded as
      # UTF-8 first.
      $bytes = [System.IO.File]::ReadAllBytes($path)
      $json = [System.Text.Encoding]::UTF8.GetString($bytes)
      $json = $json.TrimStart([char]0xFEFF)
      $table = $json | ConvertFrom-Json
    } catch {
      $table = $null
    }
  }
  $script:CcLangTables[$Code] = $table
  return $table
}

function Test-CcLanguage {
  param([string]$Code)
  return ($null -ne (Get-CcLanguageTable $Code))
}

function Get-CcSystemLanguage {
  # The Windows UI locale reports Italian as `it-IT` and Simplified Chinese as
  # `zh-Hans-CN`; only the primary subtag identifies the shipped table.
  try {
    $culture = [System.Globalization.CultureInfo]::CurrentUICulture
    $base = $culture.TwoLetterISOLanguageName
    if ($base -eq "it") { return "it" }
    if ($base -eq "zh") { return "zh" }
  } catch { }
  return $script:CcDefaultLanguage
}

function Select-CcLanguage {
  param([string]$Language = "")
  $wanted = ([string]$Language).Trim().ToLowerInvariant()
  if (-not $wanted -or $wanted -eq $script:CcDefaultLanguage) { $wanted = $script:CcDefaultLanguage }
  elseif ($wanted -eq "auto") { $wanted = Get-CcSystemLanguage }
  if ($wanted -ne "en" -and $wanted -ne "it" -and $wanted -ne "zh") { $wanted = $script:CcDefaultLanguage }
  if (-not (Test-CcLanguage $wanted)) { $wanted = $script:CcDefaultLanguage }
  $script:CcLanguage = $wanted
  return $script:CcLanguage
}

function Get-CcLanguage {
  return $script:CcLanguage
}

function Get-CcLocale {
  param([string]$Language = "")
  if (-not $Language) { $Language = $script:CcLanguage }
  $locale = $script:CcLocales[$Language]
  if (-not $locale) { $locale = $script:CcLocales[$script:CcDefaultLanguage] }
  return $locale
}

function Get-CcFontFamily {
  # A CJK family must be requested explicitly: Windows does not substitute one
  # for a font that simply lacks the glyphs.
  $name = $script:CcFontFamilies[$script:CcLanguage]
  if (-not $name) { $name = $script:CcFontFamilies[$script:CcDefaultLanguage] }
  return $name
}

function Get-CcDateTime {
  param([datetime]$Date, [string]$Format = "HH:mm:ss")
  $culture = [System.Globalization.CultureInfo]::GetCultureInfo((Get-CcLocale))
  return $Date.ToString($Format, $culture)
}

function Get-CcText {
  param([string]$Key, [hashtable]$Params = $null)
  $value = $null
  $table = Get-CcLanguageTable $script:CcLanguage
  if ($table) {
    $value = $table
    foreach ($part in $Key.Split(".")) {
      if ($null -eq $value) { break }
      $property = $value.PSObject.Properties[$part]
      if ($null -eq $property) { $value = $null } else { $value = $property.Value }
    }
  }
  if ($value -isnot [string] -and $script:CcLanguage -ne $script:CcDefaultLanguage) {
    # The English table is the fallback for a key the active language is missing.
    $fallback = Get-CcLanguageTable $script:CcDefaultLanguage
    $value = $fallback
    foreach ($part in $Key.Split(".")) {
      if ($null -eq $value) { break }
      $property = $value.PSObject.Properties[$part]
      if ($null -eq $property) { $value = $null } else { $value = $property.Value }
    }
  }
  if ($value -isnot [string]) { return $Key }
  if (-not $Params) { return $value }
  return [regex]::Replace($value, "\{([a-zA-Z]+)\}", {
    param($match)
    $name = $match.Groups[1].Value
    if ($Params.ContainsKey($name)) { return [string]$Params[$name] }
    return $match.Value
  })
}
