# Generates csharp/Lang.Generated.cs from lang/*.json.
#
# The executable must stay a single self-contained file - exe and config.json in
# one folder, nothing else - so it cannot read lang/*.json at runtime. The tables
# are therefore compiled in, and this script is the one place that turns the JSON
# contract into C# source. scripts/build-exe.ps1 runs it before every compile, so
# the generated file can never drift from the language files; the result is
# committed as well, so a checkout can be compiled without running this script.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/gen-lang.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/gen-lang.ps1 -OutputPath C:\Temp\Lang.Generated.cs
#
# The file is written as UTF-8 *with a BOM* on purpose: csc reads a BOM-less
# source using the system ANSI codepage, which would turn every Chinese and
# Italian string into mojibake.

param(
  [string]$LangDir = "",
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if (-not $LangDir) { $LangDir = Join-Path $root "lang" }
if (-not $OutputPath) { $OutputPath = Join-Path $root "csharp\Lang.Generated.cs" }

if (-not (Test-Path $LangDir)) { throw "language directory not found: $LangDir" }

# English first: it is the fallback every other table is compared against.
$files = Get-ChildItem -Path $LangDir -Filter *.json | Sort-Object Name
if (-not $files) { throw "no language files in $LangDir" }

<#
  Flatten one table into `section.key` -> text pairs.

  The nesting is presentation only: the runtime looks a flat key up in a single
  dictionary, and the dotted names are exactly the keys the Node implementation
  uses, so the two cannot disagree about what a key is.
#>
function Add-Leaves {
  param($Node, [string]$Prefix, $Target)
  foreach ($property in $Node.PSObject.Properties) {
    $value = $property.Value
    $key = $Prefix + $property.Name
    if ($null -eq $value) { $Target[$key] = ""; continue }
    if ($value -is [string]) { $Target[$key] = $value; continue }
    if ($value -is [System.Management.Automation.PSCustomObject]) {
      Add-Leaves -Node $value -Prefix ($key + ".") -Target $Target
      continue
    }
    # Arrays and scalars: a language table holds only text, anything else is a
    # mistake worth seeing in the generated file rather than silently dropped.
    if ($value -is [System.Collections.IEnumerable]) {
      Write-Warning "$key is a list; language tables hold text only, skipping it"
      continue
    }
    $Target[$key] = [string]$value
  }
}

<# A C# string literal body: quotes, backslashes and control characters escaped. #>
function ConvertTo-CSharpLiteral {
  param([string]$Value)
  $builder = New-Object System.Text.StringBuilder
  foreach ($character in $Value.ToCharArray()) {
    switch ($character) {
      '"' { [void]$builder.Append('\"'); continue }
      '\' { [void]$builder.Append('\\'); continue }
      "`n" { [void]$builder.Append('\n'); continue }
      "`r" { [void]$builder.Append('\r'); continue }
      "`t" { [void]$builder.Append('\t'); continue }
      default {
        if ([int]$character -lt 32) {
          [void]$builder.Append('\u' + ([int]$character).ToString("x4"))
        } else {
          [void]$builder.Append($character)
        }
      }
    }
  }
  $builder.ToString()
}

<# A C# identifier for the field that carries one table. #>
function Get-FieldName {
  param([string]$Code)
  $name = ""
  foreach ($character in $Code.ToCharArray()) {
    if ([char]::IsLetterOrDigit($character)) { $name += $character } else { $name += "_" }
  }
  if ($name.Length -eq 0) { $name = "Table" }
  if ([char]::IsDigit($name[0])) { $name = "L" + $name }
  return $name.Substring(0, 1).ToUpperInvariant() + $name.Substring(1)
}

$tables = New-Object System.Collections.Specialized.OrderedDictionary
foreach ($file in $files) {
  $code = [IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant()
  try {
    $parsed = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
  } catch {
    throw "$($file.Name) is not valid JSON: $($_.Exception.Message)"
  }
  if (-not $parsed) { throw "$($file.Name) is empty" }
  $flat = New-Object System.Collections.Specialized.OrderedDictionary
  Add-Leaves -Node $parsed -Prefix "" -Target $flat
  if ($flat.Count -eq 0) { throw "$($file.Name) holds no strings" }
  $tables[$code] = @{ File = $file; Leaves = $flat }
}

$codes = @($tables.Keys)

# Coverage warning, mirroring what test/i18n.test.mjs asserts: a key the fallback
# table has and a translation does not is exactly what a raw `panel.tokens` in the
# interface looks like, so it is worth saying out loud during a build.
$referenceCode = if ($tables.Contains("en")) { "en" } else { $codes[0] }
$referenceKeys = @($tables[$referenceCode].Leaves.Keys)
foreach ($code in $codes) {
  if ($code -eq $referenceCode) { continue }
  $keys = @($tables[$code].Leaves.Keys)
  $missing = @($referenceKeys | Where-Object { $keys -notcontains $_ })
  $extra = @($keys | Where-Object { $referenceKeys -notcontains $_ })
  if ($missing.Count -gt 0) { Write-Warning "$code is missing $($missing.Count) key(s): $($missing -join ', ')" }
  if ($extra.Count -gt 0) { Write-Warning "$code has $($extra.Count) key(s) $referenceCode lacks: $($extra -join ', ')" }
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("// <auto-generated>")
$lines.Add("//   Generated by scripts/gen-lang.ps1 from lang/*.json - do not edit by hand.")
$lines.Add("//")
$lines.Add("//   The tables are compiled into the executable on purpose: CommandCodeMonitor.exe")
$lines.Add("//   ships as a single self-contained file with no companion data files, so")
$lines.Add("//   lang/*.json are a build-time input and are never read at runtime.")
$lines.Add("//")
$lines.Add("//   This file is UTF-8 with a BOM: csc reads a BOM-less source using the system")
$lines.Add("//   ANSI codepage, which would mangle the Chinese and Italian text.")
$lines.Add("// </auto-generated>")
$lines.Add("")
$lines.Add("using System.Collections.Generic;")
$lines.Add("")
$lines.Add("namespace CommandCodeMonitor")
$lines.Add("{")
$lines.Add("    /// <summary>Every language table, flattened to section.key and compiled in.</summary>")
$lines.Add("    internal static class LangTables")
$lines.Add("    {")

$lines.Add("        /// <summary>Languages shipped with this executable, in selector order.</summary>")
$lines.Add("        public static readonly string[] Codes = { " + (($codes | ForEach-Object { '"' + $_ + '"' }) -join ", ") + " };")
$lines.Add("")

foreach ($code in $codes) {
  $field = Get-FieldName -Code $code
  $leaves = $tables[$code].Leaves
  $keys = @($leaves.Keys | Sort-Object)
  $lines.Add("        /// <summary>The $code table.</summary>")
  $lines.Add("        public static readonly Dictionary<string, string> $field =")
  $lines.Add("            new Dictionary<string, string>(System.StringComparer.Ordinal)")
  $lines.Add("            {")
  foreach ($key in $keys) {
    $literal = ConvertTo-CSharpLiteral -Value ([string]$leaves[$key])
    $lines.Add("                { """ + (ConvertTo-CSharpLiteral -Value $key) + """, """ + $literal + """ },")
  }
  $lines.Add("            };")
  $lines.Add("")
}

$lines.Add("        /// <summary>The table for a language code, or null when it is not compiled in.</summary>")
$lines.Add("        public static Dictionary<string, string> For(string code)")
$lines.Add("        {")
$lines.Add("            switch (code)")
$lines.Add("            {")
foreach ($code in $codes) {
  $lines.Add("                case """ + $code + """: return " + (Get-FieldName -Code $code) + ";")
}
$lines.Add("                default: return null;")
$lines.Add("            }")
$lines.Add("        }")
$lines.Add("    }")
$lines.Add("}")

$directory = Split-Path -Parent $OutputPath
if ($directory -and -not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

$text = ($lines -join "`r`n") + "`r`n"
# With a BOM, and never through Set-Content/Out-File: their default encoding is
# the ANSI codepage on Windows PowerShell 5.1.
[IO.File]::WriteAllText($OutputPath, $text, (New-Object System.Text.UTF8Encoding($true)))

$total = 0
foreach ($code in $codes) { $total += $tables[$code].Leaves.Count }
Write-Output ("lang: {0} table(s) from {1} -> {2} ({3} strings)" -f $codes.Count, $LangDir, $OutputPath, $total)
