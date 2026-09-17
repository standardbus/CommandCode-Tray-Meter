# Settings window for the tray.
#
# Until this file existed neither implementation ever wrote the user's
# configuration: the account was chosen from the tray menu and recorded in the
# cache, and everything else had to be edited by hand in config.json. This module
# adds the one place where that file is written, and it is written carefully:
#
#   * every key that is not managed here survives a save untouched, the `$comment*`
#     documentation included;
#   * the write is atomic (temporary file in the same directory, then moved over
#     the real one), so a crash cannot leave a half-written configuration behind;
#   * the file is UTF-8 *without* a BOM, which `Set-Content -Encoding UTF8` would
#     add under Windows PowerShell 5.1.
#
# Reading uses JavaScriptSerializer rather than ConvertFrom-Json on purpose:
# ConvertFrom-Json unwraps a one-element JSON array into the element itself, so a
# round trip would silently rewrite `"creditFiles": ["only"]` as a string. The
# reader keeps objects (in order) and arrays (one element included) as the file
# has them.
#
# Dot-sourced by src/tray.ps1, which supplies $ConfigPath and $ProjectRoot.

Set-StrictMode -Off

# Geometry of the settings form, shared by the builder and the row layout so a
# control cannot drift from the row that positions it.
$script:CcFormWidth = 580
$script:CcFormContentWidth = 540
$script:CcFormRowHeight = 62
$script:CcFormHeaderHeight = 86
$script:CcFormAccountsHeaderHeight = 54
$script:CcFormAddRowHeight = 34
$script:CcFormFooterHeight = 52

# The languages the selector offers, in order: the code stored in config.json and
# the key naming its label.
$script:CcSettingsLanguages = @(
  @{ Code = "auto"; Key = "settings.langAuto" },
  @{ Code = "en"; Key = "settings.langEn" },
  @{ Code = "it"; Key = "settings.langIt" },
  @{ Code = "zh"; Key = "settings.langZh" }
)

# The ranges of the three spinners. One place each, so the Minimum/Maximum on the
# control and the clamp applied to the configured value cannot drift apart.
$script:CcRefreshSecondsRange = @{ Min = 15; Max = 86400; Default = 120 }
$script:CcThresholdRange = @{ Min = 0; Max = 100; WarnDefault = 60; CriticalDefault = 85 }

# Set by a caller that is not a person (the Pester suite) so the last-resort
# message box is skipped: an automated run must never block on a window nobody
# will click. The log entry is written either way. The setter exists because
# `$script:` inside a test resolves to the test's own scope, not to the scope the
# window's functions were defined in.
$script:CcSettingsSuppressPopup = $false

function Set-CcSettingsPopupSuppressed {
  param([bool]$Suppressed)
  $script:CcSettingsSuppressPopup = $Suppressed
  return $script:CcSettingsSuppressPopup
}

function Test-CcSettingsPopupSuppressed {
  return [bool]$script:CcSettingsSuppressPopup
}

# --- reading and writing config.json ---------------------------------------

function ConvertFrom-CcConfigText {
  # Raw JSON text -> an ordered object graph, or $null when the text is not JSON
  # at all. Objects keep their file order and arrays keep their length.
  param([string]$Text)
  if (-not $Text -or -not $Text.Trim()) { return $null }
  try {
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    # The default cap is 2MB; a real configuration is a few KB, but the
    # documentation comments are long and a generous cap costs nothing.
    $serializer.MaxJsonLength = 8MB
    return $serializer.DeserializeObject($Text)
  } catch {
    try {
      # Still better than refusing to open: ConvertFrom-Json reads the same
      # documents, it only loses the shape of one-element arrays.
      return ($Text | ConvertFrom-Json)
    } catch {
      return $null
    }
  }
}

function Read-CcConfigDocument {
  # The configuration exactly as the file holds it, or $null when it is absent. A
  # file that exists but does not parse is reported rather than silently
  # replaced, so a save never destroys a configuration the user is halfway
  # through editing.
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
  $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if (-not $text -or -not $text.Trim()) { return $null }
  return (ConvertFrom-CcConfigText $text)
}

function Test-CcDocumentKey {
  # Whether a dictionary-shaped document has a key. Written without `Contains`:
  # resolved dynamically, that call binds to no overload, and indexing a missing
  # key would add it on some dictionary types.
  param($Document, [string]$Key)
  foreach ($existing in $Document.Keys) {
    if ([string]$existing -eq $Key) { return $true }
  }
  return $false
}

function Get-CcDocumentValue {
  # One field of a document that may be a Dictionary (the JavaScriptSerializer
  # shape) or a PSCustomObject (the ConvertFrom-Json fallback shape).
  param($Document, [string]$Key)
  if ($null -eq $Document) { return $null }
  if ($Document -is [System.Collections.IDictionary]) {
    if (Test-CcDocumentKey -Document $Document -Key $Key) { return $Document[$Key] }
    return $null
  }
  $property = $Document.PSObject.Properties[$Key]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Set-CcDocumentValue {
  # In-place update. A Dictionary keeps the order it was read in, so replacing the
  # value (rather than rebuilding the object) is what keeps the file's key order
  # stable across a save: the resulting diff shows the settings that changed and
  # nothing else.
  param($Document, [string]$Key, $Value)
  if ($Document -is [System.Collections.IDictionary]) {
    if (Test-CcDocumentKey -Document $Document -Key $Key) { $Document[$Key] = $Value }
    else { $Document.Add($Key, $Value) }
    return
  }
  if ($null -ne $Document.PSObject.Properties[$Key]) { $Document.$Key = $Value }
  else { $Document | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force }
}

function Get-CcNumber {
  # A numeric field that may arrive as a number or as a numeric string, with a
  # floor. Anything unusable falls back to the caller's default.
  #
  # Parsed with the invariant culture, never the machine's: JSON numbers are
  # dot-decimal, and on an Italian machine `[double]::TryParse("42.6")` reads the
  # dot as a thousands separator and answers 426. The writer emits plain integers,
  # but a hand-edited config.json does not have to.
  param($Value, [double]$Minimum, [double]$Default)
  if ($null -eq $Value) { return $Default }
  $parsed = 0.0
  $style = [System.Globalization.NumberStyles]::Float
  $parsedOk = [double]::TryParse([string]$Value, $style, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)
  if (-not $parsedOk) { return $Default }
  if ($parsed -lt $Minimum) { return $Default }
  return $parsed
}

function Get-CcSpinnerValue {
  # The value a NumericUpDown can be given for a setting. Windows Forms throws
  # "'0' is not a valid value for 'Value'. 'Value' should be between 'Minimum' and
  # 'Maximum'" when a value outside the range is assigned, and an exception raised
  # while the window is being built reaches the unhandled-exception dialog rather
  # than the status line - so no configured value may ever be assigned unclamped.
  #
  # Anything that is not a finite number, and anything below the minimum, falls
  # back to the default; anything above the maximum is capped at it. Both ends are
  # clamped whatever the file says, so `refreshSeconds: 0`, a negative threshold or
  # a hand-edited 100000 can never take the tray down.
  param($Value, [int]$Minimum, [int]$Maximum, [int]$Default)
  $number = Get-CcNumber $Value $Minimum $Default
  try {
    $rounded = [int][Math]::Round([double]$number)
  } catch {
    return $Default
  }
  if ($rounded -lt $Minimum) { return $Minimum }
  if ($rounded -gt $Maximum) { return $Maximum }
  return $rounded
}

function Write-CcConfigFile {
  # Serialize and write atomically, as UTF-8 without a BOM.
  param([string]$Path, $Document)
  # Depth 10: Windows PowerShell 5.1 defaults to 2 and would silently truncate the
  # nested objects (`endpoints`, `ui`) the file has to keep.
  $json = $Document | ConvertTo-Json -Depth 10
  $directory = Split-Path -Parent $Path
  if ($directory -and -not (Test-Path -LiteralPath $directory)) {
    [void](New-Item -ItemType Directory -Path $directory -Force)
  }
  # The temporary file sits in the same directory: Move-Item is only atomic when
  # the source and the destination are on the same volume.
  $temp = Join-Path $directory ("{0}.{1}.tmp" -f (Split-Path -Leaf $Path), ([Guid]::NewGuid().ToString("N").Substring(0, 8)))
  try {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $json, $encoding)
    # -Force, because Move-Item refuses to overwrite an existing destination.
    Move-Item -LiteralPath $temp -Destination $Path -Force
  } catch {
    # Leave no debris behind, then let the caller report the failure.
    try { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } } catch { }
    throw
  }
}

# --- account ids ------------------------------------------------------------

function ConvertTo-CcAccountId {
  # The schema is `^[a-z0-9][a-z0-9-]*$`, derived from the display name:
  # lower-cased, every run of characters outside `[a-z0-9]` collapsed into a
  # single hyphen, then leading and trailing hyphens trimmed. A name that leaves
  # nothing (punctuation only, or an empty box) becomes `account`.
  #
  # The same rule is implemented in the C# executable; the two must agree or the
  # same edit would produce two different files.
  param([string]$Name)
  $buffer = New-Object System.Text.StringBuilder
  $separatorPending = $false
  foreach ($character in ([string]$Name).ToLowerInvariant().ToCharArray()) {
    # A hyphen is a separator like any other: the schema allows one between two
    # alphanumeric runs, so `ACME -- Corp` and `ACME - Corp` must produce the same
    # id rather than one of them keeping the doubled hyphen.
    $isAlphaNumeric = ($character -ge [char]'a' -and $character -le [char]'z') -or
      ($character -ge [char]'0' -and $character -le [char]'9')
    if ($isAlphaNumeric) {
      # The separator is only emitted once per run, and never before the first
      # alphanumeric character, which is what drops a leading run.
      if ($separatorPending -and $buffer.Length -gt 0) { [void]$buffer.Append('-') }
      $separatorPending = $false
      [void]$buffer.Append($character)
    } else {
      $separatorPending = $true
    }
  }
  # Only a trailing separator can still be pending; it is simply never emitted.
  $id = $buffer.ToString()
  if (-not $id) { $id = "account" }
  return $id
}

function Get-CcUniqueAccountId {
  # `-2`, `-3`, ... until the id is free, matching the C# derivation.
  param([string]$Id, $Taken)
  $takenList = @()
  if ($Taken) { $takenList = @($Taken) }
  $candidate = $Id
  $suffix = 1
  while ($takenList -contains $candidate) {
    $suffix++
    $candidate = "{0}-{1}" -f $Id, $suffix
  }
  return $candidate
}

# --- the settings document --------------------------------------------------

function Get-CcSettingsDraft {
  # Everything the window edits, read from the file: the account rows (with the
  # id and the environment variable they started with, so an untouched row keeps
  # both), the language, and the numeric and UI settings.
  param([string]$Path)
  $document = Read-CcConfigDocument -Path $Path
  $rows = @()
  foreach ($entry in @(Get-CcDocumentValue $document "profiles")) {
    if ($null -eq $entry) { continue }
    $rows += @{
      Id      = ([string](Get-CcDocumentValue $entry "id")).Trim()
      Name    = [string](Get-CcDocumentValue $entry "name")
      ApiKey  = [string](Get-CcDocumentValue $entry "apiKey")
      Env     = ([string](Get-CcDocumentValue $entry "apiKeyEnv")).Trim()
    }
  }
  if ($rows.Count -eq 0) {
    # No account list: the implicit single account is the one the tray has always
    # monitored, and its key comes from the top-level `apiKey`. The row starts
    # without an id, so saving leaves `profiles` empty unless the user names it
    # (which is what keeps a single-account configuration single-account).
    $key = [string](Get-CcDocumentValue $document "apiKey")
    $env = ([string](Get-CcDocumentValue $document "apiKeyEnv")).Trim()
    if ($key -or $env) { $rows += @{ Id = ""; Name = ""; ApiKey = $key; Env = $env } }
  }
  if ($rows.Count -eq 0) { $rows = @(@{ Id = ""; Name = ""; ApiKey = ""; Env = "" }) }

  $language = ([string](Get-CcDocumentValue $document "language")).Trim().ToLowerInvariant()
  $refresh = Get-CcNumber (Get-CcDocumentValue $document "refreshSeconds") 15 120
  $thresholds = Get-CcDocumentValue $document "thresholds"
  $warn = Get-CcNumber (Get-CcDocumentValue $thresholds "warn") 0 60
  $critical = Get-CcNumber (Get-CcDocumentValue $thresholds "critical") 0 85
  $ui = Get-CcDocumentValue $document "ui"
  $metric = [string](Get-CcDocumentValue $ui "iconMetric")
  if ($metric -ne "fiveHour" -and $metric -ne "weekly" -and $metric -ne "monthly") { $metric = "fiveHour" }
  $monochrome = ((Get-CcDocumentValue $ui "monochrome") -eq $true)
  $tooltip = $true
  if ($null -ne (Get-CcDocumentValue $ui "showTooltip")) { $tooltip = ((Get-CcDocumentValue $ui "showTooltip") -ne $false) }
  return [pscustomobject]@{
    Accounts       = @($rows)
    Language       = $language
    RefreshSeconds = [int]$refresh
    Warn           = [int]$warn
    Critical       = [int]$critical
    IconMetric     = $metric
    Monochrome     = [bool]$monochrome
    ShowTooltip    = [bool]$tooltip
    ActiveProfile  = ([string](Get-CcDocumentValue $document "activeProfile")).Trim().ToLowerInvariant()
  }
}

function Get-CcSettingsLanguage {
  # The code the settings window draws itself in: exactly what config.json says,
  # `auto` included, so the preview matches the language that will be active after
  # the save.
  param([string]$Path)
  $code = ([string](Get-CcDocumentValue (Read-CcConfigDocument -Path $Path) "language")).Trim().ToLowerInvariant()
  if ($code -eq "auto" -or $code -eq "en" -or $code -eq "it" -or $code -eq "zh") { return $code }
  return "en"
}

function Get-CcDraftAccountId {
  # The id a row will be written with. A row that keeps the name it was read with
  # keeps its id, so a cosmetic edit (a corrected key, a changed threshold) does
  # not churn the file; every other row gets an id derived from its name and made
  # unique against the ids already spoken for.
  param($Draft, $Taken)
  $takenList = @()
  if ($Taken) { $takenList = @($Taken) }
  $name = ([string]$Draft.Name).Trim()
  $existing = ([string]$Draft.Id).Trim().ToLowerInvariant()
  $previousName = ([string]$Draft.PreviousName).Trim()
  if ($existing -and $previousName -and $name -ceq $previousName) { return $existing }
  return (Get-CcUniqueAccountId (ConvertTo-CcAccountId $name) $takenList)
}

function Test-CcSettingsDraft {
  # Validation, in the order the user is most likely to hit it: a nameless row,
  # then a duplicate name, then a missing key. The result is the finished message
  # (a settings.* key, already translated), or $null when the draft is writable.
  param($Accounts, [string]$Language = "")
  $rows = @($Accounts)
  foreach ($row in $rows) {
    if (-not ([string]$row.Name).Trim()) {
      return (Get-CcText "settings.nameRequired" $null $Language)
    }
  }
  $seen = @{}
  foreach ($row in $rows) {
    $name = ([string]$row.Name).Trim()
    $folded = $name.ToLowerInvariant()
    if ($seen.ContainsKey($folded)) {
      return (Get-CcText "settings.duplicateName" @{ name = $name } $Language)
    }
    $seen[$folded] = $true
  }
  foreach ($row in $rows) {
    $name = ([string]$row.Name).Trim()
    if (-not ([string]$row.ApiKey).Trim() -and -not ([string]$row.ApiKeyEnv).Trim()) {
      return (Get-CcText "settings.keyRequired" @{ name = $name } $Language)
    }
  }
  return $null
}

function Save-CcSettingsToConfig {
  # Merge the edited values into the existing document and write it. Returns the
  # document that was written, so the caller can re-read and refresh from it.
  #
  # Only `profiles`, `activeProfile`, `language`, `refreshSeconds`, `thresholds`
  # and `ui` are touched. Every other key - `endpoints`, `creditFiles`,
  # `requestTimeoutMs`, the `$comment*` documentation and anything a future
  # version adds - is carried over exactly as it was read.
  param([string]$Path, $Accounts, [string]$Language, $RefreshSeconds, $Warn, $Critical,
        [string]$IconMetric, [bool]$Monochrome, [bool]$ShowTooltip, [string]$ActiveProfile = "")
  $document = Read-CcConfigDocument -Path $Path
  if ($null -eq $document) {
    # A file that is absent (or unreadable JSON) is replaced by a minimal valid
    # document: the window is the only way to configure the monitor from here on,
    # so it has to be able to create the file.
    $document = New-Object 'System.Collections.Generic.Dictionary[string,object]'
  }

  $profiles = New-Object System.Collections.ArrayList
  $assignedIds = @()
  foreach ($row in @($Accounts)) {
    $name = ([string]$row.Name).Trim()
    if (-not $name) { continue }
    $id = Get-CcDraftAccountId -Draft $row -Taken $assignedIds
    $assignedIds += $id
    $key = [string]$row.ApiKey
    $env = ([string]$row.ApiKeyEnv).Trim()
    # An ordered dictionary, so the entry serializes as id, name and then exactly
    # one credential field.
    $entry = [ordered]@{ id = $id; name = $name }
    if ($key.Trim()) { $entry["apiKey"] = $key }
    elseif ($env) { $entry["apiKeyEnv"] = $env }
    [void]$profiles.Add($entry)
  }

  Set-CcDocumentValue -Document $document -Key "profiles" -Value ($profiles.ToArray())
  # A stale `activeProfile` (one naming a row that was renamed away or removed) is
  # cleared rather than left pointing at nothing.
  $active = ([string]$ActiveProfile).Trim().ToLowerInvariant()
  if ($active -and ($assignedIds -notcontains $active)) { $active = "" }
  if (-not $active -and $assignedIds.Count -gt 0) { $active = [string]$assignedIds[0] }
  Set-CcDocumentValue -Document $document -Key "activeProfile" -Value $active

  $code = ([string]$Language).Trim().ToLowerInvariant()
  if ($code -ne "auto" -and $code -ne "en" -and $code -ne "it" -and $code -ne "zh") { $code = "en" }
  Set-CcDocumentValue -Document $document -Key "language" -Value $code

  $refresh = Get-CcNumber $RefreshSeconds 15 120
  Set-CcDocumentValue -Document $document -Key "refreshSeconds" -Value ([int]$refresh)

  $warnValue = Get-CcNumber $Warn 0 60
  $criticalValue = Get-CcNumber $Critical 0 85
  $thresholds = Get-CcDocumentValue $document "thresholds"
  if ($null -eq $thresholds) {
    $thresholds = [ordered]@{ warn = [int]$warnValue; critical = [int]$criticalValue }
    Set-CcDocumentValue -Document $document -Key "thresholds" -Value $thresholds
  } else {
    # Updated in place: anything else the block carries is left alone.
    Set-CcDocumentValue -Document $thresholds -Key "warn" -Value ([int]$warnValue)
    Set-CcDocumentValue -Document $thresholds -Key "critical" -Value ([int]$criticalValue)
  }

  $metric = [string]$IconMetric
  if ($metric -ne "fiveHour" -and $metric -ne "weekly" -and $metric -ne "monthly") { $metric = "fiveHour" }
  $ui = Get-CcDocumentValue $document "ui"
  if ($null -eq $ui) {
    $ui = [ordered]@{ iconMetric = $metric; monochrome = [bool]$Monochrome; showTooltip = [bool]$ShowTooltip }
    Set-CcDocumentValue -Document $document -Key "ui" -Value $ui
  } else {
    Set-CcDocumentValue -Document $ui -Key "iconMetric" -Value $metric
    Set-CcDocumentValue -Document $ui -Key "monochrome" -Value ([bool]$Monochrome)
    Set-CcDocumentValue -Document $ui -Key "showTooltip" -Value ([bool]$ShowTooltip)
  }

  Write-CcConfigFile -Path $Path -Document $document
  return $document
}

function Set-CcActiveProfileInConfig {
  # The account the tray follows, written into config.json so the choice survives
  # a run without the cache. Only `activeProfile` is touched: the account list is
  # left exactly as the user configured it.
  param([string]$Path, [string]$Id)
  $wanted = ([string]$Id).Trim().ToLowerInvariant()
  if (-not $wanted -or -not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
  try {
    $document = Read-CcConfigDocument -Path $Path
    if ($null -eq $document) { return $false }
    Set-CcDocumentValue -Document $document -Key "activeProfile" -Value $wanted
    Write-CcConfigFile -Path $Path -Document $document
    return $true
  } catch {
    return $false
  }
}

# --- placeholder support ----------------------------------------------------

# A TextBox with placeholder text. The key of an account that comes from an
# environment variable is deliberately kept out of the text box - the box holds
# the real key or nothing at all, so a save can never write a mask (or a hint)
# over a credential - which leaves that box empty and needing an explanation.
try {
  Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;

public class CcPlaceholderTextBox : TextBox
{
    private const int EM_SETCUEBANNER = 0x1501;
    private string hint = "";
    private Color hintColor = Color.FromArgb(150, 150, 150);

    public string PlaceholderText
    {
        get { return hint; }
        set
        {
            hint = value == null ? "" : value;
            if (IsHandleCreated) SendMessage(Handle, EM_SETCUEBANNER, (IntPtr)1, hint);
        }
    }

    public Color PlaceholderForeColor
    {
        get { return hintColor; }
        set { hintColor = value; }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (hint.Length > 0) SendMessage(Handle, EM_SETCUEBANNER, (IntPtr)1, hint);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
}
'@
} catch {
  # Without the type the window still works: the hint is simply not shown.
  Write-TrayError "CcPlaceholderTextBox unavailable: $($_.Exception.Message)"
}

# --- small UI helpers -------------------------------------------------------

function Format-CcConfigPath {
  # A long path is shortened from the left: the file name and the last folders are
  # the part that identifies it.
  param([string]$Path, [int]$Max = 64)
  $text = [string]$Path
  if ($text.Length -le $Max) { return $text }
  return "..." + $text.Substring($text.Length - ($Max - 3))
}

function New-CcSettingsLabel {
  param([string]$Text, [int]$X, [int]$Y, [int]$Width = 0, [int]$Height = 18, [System.Drawing.Font]$Font = $null, [bool]$Dim = $false)
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = [System.Drawing.Point]::new($X, $Y)
  if ($Width -gt 0) { $label.Size = [System.Drawing.Size]::new($Width, $Height) } else { $label.AutoSize = $true }
  if ($Font) { $label.Font = $Font }
  if ($Dim) { $label.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 116) }
  $label.BackColor = [System.Drawing.Color]::Transparent
  return $label
}

function New-CcUiFont {
  param([string]$Family, [float]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
  try {
    return [System.Drawing.Font]::new($Family, $Size, $Style)
  } catch {
    return [System.Drawing.Font]::new("Segoe UI", $Size, $Style)
  }
}

function Get-CcSettingsFailureReport {
  # The report a settings-window failure leaves behind: the finished line in the
  # active language, and the same reason in the tray's own log, which is where
  # every other failure of the monitor is recorded. Split out from the popup so it
  # can be asserted without a window to click.
  param([string]$Message, [string]$Language = "")
  $line = Get-CcText "settings.saveFailed" @{ message = $Message } $Language
  try { Write-TrayError ("settings window: {0}" -f $Message) } catch { }
  return $line
}

function Show-CcSettingsFatalError {
  # The user-facing half of the report: the line from Get-CcSettingsFailureReport,
  # shown where they are looking. This is the last resort, so it never throws -
  # it is called from a catch, where a second exception would be the end of the
  # tray - and it survives having no message loop to draw in.
  #
  # `$script:CcSettingsSuppressPopup` skips the box for callers that are not a
  # person: an automated run must not block on a window nobody will click. The log
  # entry is written either way.
  param([string]$Message, [string]$Language = "")
  $line = Get-CcSettingsFailureReport -Message $Message -Language $Language
  if ($script:CcSettingsSuppressPopup) { return $line }
  try {
    [void][System.Windows.Forms.MessageBox]::Show(
      $line,
      (Get-CcText "settings.title" $null $Language),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error)
  } catch {
    # No message loop to draw in: the log entry above is the report.
  }
  return $line
}

# --- the window -------------------------------------------------------------

function Show-CcSettingsWindow {
  # Builds and shows the settings window, modal so the tray menu is not left
  # interactive behind it. `OnSaved` is invoked after a successful write (the tray
  # passes a scriptblock that re-reads the configuration and repaints itself).
  #
  # Every nested scriptblock runs in this function's scope - that is where the
  # controls, the rows and the fonts live - so all of them are defined here rather
  # than passed around.
  param([string]$Path, [string]$ActiveProfile = "", [scriptblock]$OnSaved = $null)

  # Anything that goes wrong while the window is being built is reported instead
  # of reaching the WinForms unhandled-exception dialog: the log first, then the
  # user. Nothing the window does may take the tray down with it.
  #
  # `$language` is defaulted before the guarded block: a failure raised while
  # reading the configuration must still be reportable afterwards.
  $failure = $null
  $language = ""
  try {
    $rows = New-Object System.Collections.ArrayList
    $editing = $true
    $language = Get-CcSettingsLanguage -Path $Path

  $text = {
    # One lookup, always in the language currently on disk, so a re-draw can
    # switch language without rebuilding these closures.
    param([string]$Key, [hashtable]$Params = $null)
    return (Get-CcText $Key $Params $language)
  }
  $setStatus = {
    param([string]$Message, [bool]$IsError = $false)
    $statusLabel.Text = $Message
    if ($IsError) { $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 70, 70) }
    else { $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 64) }
    $statusTimer.Stop()
    if (-not $IsError -and $Message) { $statusTimer.Start() }
  }
  $newRow = {
    param([string]$Id = "", [string]$Name = "", [string]$ApiKey = "", [string]$Env = "")
    return @{
      Id           = $Id
      Name         = $Name
      ApiKey       = $ApiKey
      Env          = $Env
      PreviousName = $Name
      Visible      = $false
    }
  }
  $buildRow = {
    # One account row: name, key, and the two buttons that act on it.
    #
    # The controls are built here but the handlers are registered once, in the
    # function scope below. A handler added from inside a scriptblock invocation
    # does not capture that invocation's locals - $row and $Index would be empty by
    # the time the click arrived - so each control carries its row index in `Tag`
    # and the handlers look the row and its controls up in `$rows` /
    # `$script:CcRowCells`, both of which are in scope.
    param([int]$Index)
    $row = $rows[$Index]
    $rowY = $script:CcFormHeaderHeight + $script:CcFormAccountsHeaderHeight + ($Index * $script:CcFormRowHeight)
    $controls = @()

    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.Text = [string]$row.Name
    $nameBox.Location = [System.Drawing.Point]::new(16, $rowY)
    $nameBox.Size = [System.Drawing.Size]::new(150, 24)
    $nameBox.Tag = $Index
    $controls += $nameBox

    $keyBox = $null
    if ("CcPlaceholderTextBox" -as [type]) { $keyBox = New-Object CcPlaceholderTextBox }
    else { $keyBox = New-Object System.Windows.Forms.TextBox }
    # The box holds the real key, never a mask: saving reads Text verbatim, so a
    # reveal/hide toggle can never leak into the file.
    $keyBox.Text = [string]$row.ApiKey
    $keyBox.UseSystemPasswordChar = -not $row.Visible
    $keyBox.Tag = [string]$row.Env
    $keyBox.Location = [System.Drawing.Point]::new(176, $rowY)
    $keyBox.Size = [System.Drawing.Size]::new(230, 24)
    $controls += $keyBox

    $hint = New-CcSettingsLabel -X 176 -Y ($rowY + 26) -Width 330 -Height 14 -Font $hintFont -Dim $true
    $controls += $hint

    $showButton = New-Object System.Windows.Forms.Button
    $showButton.Text = $(if ($row.Visible) { & $text "settings.hide" } else { & $text "settings.show" })
    $showButton.Location = [System.Drawing.Point]::new(410, ($rowY - 1))
    $showButton.Size = [System.Drawing.Size]::new(62, 26)
    $showButton.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $showButton.Tag = $Index
    $controls += $showButton

    $removeButton = New-Object System.Windows.Forms.Button
    $removeButton.Text = (& $text "settings.remove")
    $removeButton.Location = [System.Drawing.Point]::new(478, ($rowY - 1))
    $removeButton.Size = [System.Drawing.Size]::new(28, 26)
    $removeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $removeButton.Tag = $Index
    $controls += $removeButton

    $script:CcRowCells[$Index] = @{ Name = $nameBox; Key = $keyBox; Hint = $hint; Show = $showButton; Remove = $removeButton }
    # The placeholder and the missing-key hint are painted from the values the row
    # starts with, so an account that keeps an environment variable already
    # explains itself before anything is typed.
    & $updateRowCell $Index
    return $controls
  }

  $updateRowCell = {
    # Repaint one row: the kept-environment-variable placeholder, and the
    # missing-key hint the save would otherwise only report. The name comes from
    # the box, which is the value the user sees and the one that will be written.
    param([int]$Index)
    $cells = $script:CcRowCells[$Index]
    if (-not $cells) { return }
    $row = $rows[$Index]
    if (-not $row) { return }
    $cells.Key.Tag = [string]$row.Env
    if ($cells.Key.Text.Length -gt 0 -or -not ([string]$cells.Key.Tag)) { $cells.Key.PlaceholderText = "" }
    else { $cells.Key.PlaceholderText = (& $text "settings.keyKept" @{ env = [string]$cells.Key.Tag }) }
    if (-not $cells.Key.Text.Trim() -and -not ([string]$row.Env).Trim()) {
      $cells.Hint.Text = (& $text "settings.keyRequired" @{ name = $cells.Name.Text.Trim() })
      $cells.Hint.ForeColor = [System.Drawing.Color]::FromArgb(190, 70, 70)
    } else {
      $cells.Hint.Text = ""
    }
  }

  $captureRows = {
    # Copy what is in the boxes into the row objects. A rebuild recreates the boxes
    # from the rows, so this runs before anything rebuilds them; the id, the
    # environment variable and the previously-seen name are not editable and stay
    # as they were read.
    for ($index = 0; $index -lt $rows.Count; $index++) {
      $cells = $script:CcRowCells[$index]
      $row = $rows[$index]
      if (-not $cells -or -not $row) { continue }
      $row.Name = $cells.Name.Text
      $row.ApiKey = $cells.Key.Text
    }
  }

  $nameChanged = {
    # The hint under the row follows what is being typed. The value itself is read
    # from the box when it is needed, so a missed notification cannot lose an edit.
    $position = [int]$sender.Tag
    & $updateRowCell $position
  }
  $keyChanged = {
    $position = [int]$sender.Tag
    & $updateRowCell $position
  }
  $showToggled = {
    $position = [int]$sender.Tag
    $cells = $script:CcRowCells[$position]
    if (-not $cells) { return }
    $row = $rows[$position]
    $row.Visible = -not $row.Visible
    # Only the mask toggles: UseSystemPasswordChar changes what is displayed,
    # Text keeps the real key throughout.
    $cells.Key.UseSystemPasswordChar = -not $row.Visible
    $cells.Show.Text = $(if ($row.Visible) { & $text "settings.hide" } else { & $text "settings.show" })
    & $updateRowCell $position
  }
  $rowRemoved = {
    $position = [int]$sender.Tag
    # What the other rows show is captured first: the rebuild would otherwise
    # restore them from values the boxes have since moved past.
    & $captureRows
    # One row always stays: removing the last one clears it instead, so the window
    # is never left with no account to edit.
    if ($rows.Count -le 1) {
      $rows[0].Id = ""
      $rows[0].Name = ""
      $rows[0].ApiKey = ""
      $rows[0].Env = ""
      $rows[0].PreviousName = ""
      $rows[0].Visible = $false
    } else {
      $rows.RemoveAt($position)
    }
    & $build | Out-Null
  }

  $prepare = {
    # The values the boxes should show, re-read from the file. A re-draw after a
    # save uses what was just written; the global fields are only (re)created on
    # open and on a language change, so their current values are kept.
    param([bool]$ReplaceGlobals = $true)
    $draft = Get-CcSettingsDraft -Path $Path
    if ($script:CcBoxes -and -not $ReplaceGlobals) {
      return [pscustomobject]@{ Draft = $draft; Boxes = $script:CcBoxes }
    }
    $languageBox = New-Object System.Windows.Forms.ComboBox
    $languageBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    foreach ($entry in $script:CcSettingsLanguages) { [void]$languageBox.Items.Add((& $text $entry.Key)) }
    $languageBox.SelectedIndex = 0
    for ($index = 0; $index -lt $script:CcSettingsLanguages.Count; $index++) {
      if ($script:CcSettingsLanguages[$index].Code -eq $language) { $languageBox.SelectedIndex = $index }
    }

    $metricBox = New-Object System.Windows.Forms.ComboBox
    $metricBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$metricBox.Items.Add((& $text "panel.fiveHour"))
    [void]$metricBox.Items.Add((& $text "panel.weekly"))
    [void]$metricBox.Items.Add((& $text "panel.monthly"))
    $metricIndex = 0
    if ($draft.IconMetric -eq "weekly") { $metricIndex = 1 }
    if ($draft.IconMetric -eq "monthly") { $metricIndex = 2 }
    $metricBox.SelectedIndex = $metricIndex

    $refreshRange = $script:CcRefreshSecondsRange
    $refreshBox = New-Object System.Windows.Forms.NumericUpDown
    $refreshBox.Minimum = $refreshRange.Min
    $refreshBox.Maximum = $refreshRange.Max
    # Never the configured value straight into `Value`: assigning a number outside
    # the range throws, and that throw would reach the unhandled-exception dialog.
    $refreshBox.Value = [decimal](Get-CcSpinnerValue $draft.RefreshSeconds $refreshRange.Min $refreshRange.Max $refreshRange.Default)
    $thresholdRange = $script:CcThresholdRange
    $warnBox = New-Object System.Windows.Forms.NumericUpDown
    $warnBox.Minimum = $thresholdRange.Min
    $warnBox.Maximum = $thresholdRange.Max
    $warnBox.Value = [decimal](Get-CcSpinnerValue $draft.Warn $thresholdRange.Min $thresholdRange.Max $thresholdRange.WarnDefault)
    $criticalBox = New-Object System.Windows.Forms.NumericUpDown
    $criticalBox.Minimum = $thresholdRange.Min
    $criticalBox.Maximum = $thresholdRange.Max
    $criticalBox.Value = [decimal](Get-CcSpinnerValue $draft.Critical $thresholdRange.Min $thresholdRange.Max $thresholdRange.CriticalDefault)

    $monochromeBox = New-Object System.Windows.Forms.CheckBox
    $monochromeBox.Text = (& $text "settings.monochrome")
    $monochromeBox.Checked = [bool]$draft.Monochrome
    $monochromeBox.AutoSize = $true
    $tooltipBox = New-Object System.Windows.Forms.CheckBox
    $tooltipBox.Text = (& $text "settings.tooltip")
    $tooltipBox.Checked = [bool]$draft.ShowTooltip
    $tooltipBox.AutoSize = $true

    $script:CcBoxes = [pscustomobject]@{
      Language   = $languageBox
      Refresh    = $refreshBox
      Warn       = $warnBox
      Critical   = $criticalBox
      Metric     = $metricBox
      Monochrome = $monochromeBox
      Tooltip    = $tooltipBox
      # The live selections, kept here so a rebuild can put them back: a control
      # that is detached and re-added loses what a combo box or a spinner showed.
      LanguageIndex     = $languageBox.SelectedIndex
      MetricIndex       = $metricBox.SelectedIndex
      RefreshValue      = $refreshBox.Value
      WarnValue         = $warnBox.Value
      CriticalValue     = $criticalBox.Value
      MonochromeChecked = $monochromeBox.Checked
      TooltipChecked    = $tooltipBox.Checked
    }
    return [pscustomobject]@{ Draft = $draft; Boxes = $script:CcBoxes }
  }

  $placeGlobals = {
    param($boxes)
    $content.Controls.Add((New-CcSettingsLabel -Text (& $text "settings.language") -X 16 -Y 56 -Width 220 -Height 16 -Font $hintFont))
    $boxes.Language.Location = [System.Drawing.Point]::new(16, 74)
    $boxes.Language.Size = [System.Drawing.Size]::new(220, 24)
    $content.Controls.Add($boxes.Language)

    $content.Controls.Add((New-CcSettingsLabel -Text (& $text "settings.ringShows") -X 300 -Y 56 -Width 240 -Height 16 -Font $hintFont))
    $boxes.Metric.Location = [System.Drawing.Point]::new(300, 74)
    $boxes.Metric.Size = [System.Drawing.Size]::new(220, 24)
    $content.Controls.Add($boxes.Metric)

    $content.Controls.Add((New-CcSettingsLabel -Text (& $text "settings.refresh") -X 16 -Y 104 -Width 220 -Height 16 -Font $hintFont))
    $boxes.Refresh.Location = [System.Drawing.Point]::new(16, 122)
    $boxes.Refresh.Size = [System.Drawing.Size]::new(110, 24)
    $content.Controls.Add($boxes.Refresh)

    $content.Controls.Add((New-CcSettingsLabel -Text (& $text "settings.warn") -X 300 -Y 104 -Width 240 -Height 16 -Font $hintFont))
    $boxes.Warn.Location = [System.Drawing.Point]::new(300, 122)
    $boxes.Warn.Size = [System.Drawing.Size]::new(110, 24)
    $content.Controls.Add($boxes.Warn)

    $content.Controls.Add((New-CcSettingsLabel -Text (& $text "settings.critical") -X 16 -Y 152 -Width 240 -Height 16 -Font $hintFont))
    $boxes.Critical.Location = [System.Drawing.Point]::new(16, 170)
    $boxes.Critical.Size = [System.Drawing.Size]::new(110, 24)
    $content.Controls.Add($boxes.Critical)

    $boxes.Monochrome.Location = [System.Drawing.Point]::new(300, 170)
    $content.Controls.Add($boxes.Monochrome)
    $boxes.Tooltip.Location = [System.Drawing.Point]::new(300, 194)
    $content.Controls.Add($boxes.Tooltip)
  }

  $build = {
    # (Re)create the controls. Called on open, after a row is added or removed,
    # and whenever the language on disk changes.
    param([bool]$ReplaceGlobals = $true)
    $state = & $prepare $ReplaceGlobals
    $draft = $state.Draft
    $boxes = $state.Boxes
    # The previous controls are taken out of the panel. The global ones are reused
    # (they are only replaced when the language changes), so they are simply
    # detached; everything else - the labels and the account rows - is disposed,
    # because a control that is only unparented keeps the handlers registered on
    # it and a later change to it would run them against rows and cells that are
    # no longer on screen.
    $reused = @($boxes.Language, $boxes.Refresh, $boxes.Warn, $boxes.Critical, $boxes.Metric, $boxes.Monochrome, $boxes.Tooltip)
    foreach ($control in @($content.Controls)) {
      if ($reused -contains $control) { $content.Controls.Remove($control) }
      else { $control.Dispose() }
    }
    $content.Controls.Clear()

    $rowsY = $script:CcFormHeaderHeight + $script:CcFormAccountsHeaderHeight
    $contentHeight = $rowsY + ($rows.Count * $script:CcFormRowHeight) + $script:CcFormAddRowHeight + 16
    $wantedHeight = $contentHeight + $script:CcFormFooterHeight
    $screen = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    if ($wantedHeight -gt ($screen.Height - 40)) { $wantedHeight = $screen.Height - 40 }
    $form.ClientSize = [System.Drawing.Size]::new($script:CcFormWidth, $wantedHeight)
    $content.Size = [System.Drawing.Size]::new(($script:CcFormWidth - 4), ($wantedHeight - $script:CcFormFooterHeight))

    $content.Controls.Add((New-CcSettingsLabel -Text (& $text "settings.accountsHint") -X 16 -Y 12 -Width $script:CcFormContentWidth -Font $hintFont -Dim $true))
    $content.Controls.Add((New-CcSettingsLabel -Text (& $text "settings.file" @{ path = (Format-CcConfigPath $Path) }) -X 16 -Y 34 -Width $script:CcFormContentWidth -Font $hintFont -Dim $true))
    & $placeGlobals $boxes

    # Accounts: a heading, the two column labels, then one row per account.
    $content.Controls.Add((New-CcSettingsLabel -Text (& $text "settings.accounts") -X 16 -Y $script:CcFormHeaderHeight -Width 300 -Height 18 -Font $headingFont))
    $content.Controls.Add((New-CcSettingsLabel -Text (& $text "settings.name") -X 16 -Y ($script:CcFormHeaderHeight + 26) -Width 140 -Height 14 -Font $hintFont -Dim $true))
    $content.Controls.Add((New-CcSettingsLabel -Text (& $text "settings.apiKey") -X 176 -Y ($script:CcFormHeaderHeight + 26) -Width 200 -Height 14 -Font $hintFont -Dim $true))
    # The cell table is rebuilt with the rows, so a handler can never act on the
    # controls of a row that no longer exists.
    $script:CcRowCells = @{}
    for ($index = 0; $index -lt $rows.Count; $index++) {
      foreach ($control in (& $buildRow $index)) { $content.Controls.Add($control) }
      $cells = $script:CcRowCells[$index]
      $cells.Name.Add_TextChanged($nameChanged)
      $cells.Key.Add_TextChanged($keyChanged)
      $cells.Show.Add_Click($showToggled)
      $cells.Remove.Add_Click($rowRemoved)
    }

    if ($editing) {
      $addButton = New-Object System.Windows.Forms.Button
      $addButton.Text = (& $text "settings.add")
      $addButton.Location = [System.Drawing.Point]::new(16, ($rowsY + ($rows.Count * $script:CcFormRowHeight) + 4))
      $addButton.Size = [System.Drawing.Size]::new(34, 26)
      $toolTip = New-Object System.Windows.Forms.ToolTip
      $toolTip.SetToolTip($addButton, (& $text "settings.addTip"))
      $addButton.Add_Click({
        # "+" appends one empty row; the window grows to fit it. What the other
        # rows and the global controls show is captured first, or the rebuild would
        # restore them from the values they had when the window opened.
        & $captureRows
        & $captureState $script:CcBoxes
        [void]$rows.Add((& $newRow))
        & $build $false | Out-Null
      })
      $content.Controls.Add($addButton)
    }

    # The footer follows the window, not the scrolled content.
    $footerY = $form.ClientSize.Height - 44
    $statusLabel.Location = [System.Drawing.Point]::new(16, ($footerY + 6))
    $statusLabel.Size = [System.Drawing.Size]::new(($script:CcFormWidth - 16 - 3 * 104 - 16), 18)
    $closeButton.Location = [System.Drawing.Point]::new(($script:CcFormWidth - 16 - 96), $footerY)
    $cancelButton.Location = [System.Drawing.Point]::new(($script:CcFormWidth - 16 - 96 - 8 - 96), $footerY)
    $saveButton.Location = [System.Drawing.Point]::new(($script:CcFormWidth - 16 - 96 - 8 - 96 - 8 - 96), $footerY)
    # The footer buttons are drawn in the language the window is showing, so they
    # follow a save that changed it.
    $saveButton.Text = (& $text "settings.save")
    $cancelButton.Text = (& $text "settings.cancel")
    $closeButton.Text = (& $text "settings.close")
    $saveButton.Visible = $editing
    $cancelButton.Visible = $editing
    $closeButton.Visible = -not $editing
    $form.Text = (& $text "settings.title")
    # A control that was detached and re-added loses what a combo box or a spinner
    # was showing, so the selections are put back from the box object.
    $boxes.Language.SelectedIndex = [int]$boxes.LanguageIndex
    $boxes.Metric.SelectedIndex = [int]$boxes.MetricIndex
    $boxes.Refresh.Value = [decimal]$boxes.RefreshValue
    $boxes.Warn.Value = [decimal]$boxes.WarnValue
    $boxes.Critical.Value = [decimal]$boxes.CriticalValue
    $boxes.Monochrome.Checked = [bool]$boxes.MonochromeChecked
    $boxes.Tooltip.Checked = [bool]$boxes.TooltipChecked
    return $boxes
  }

  $captureState = {
    # The live selections, kept on the box object so a rebuild can put them back.
    param($boxes)
    $boxes.LanguageIndex = $boxes.Language.SelectedIndex
    $boxes.MetricIndex = $boxes.Metric.SelectedIndex
    $boxes.RefreshValue = $boxes.Refresh.Value
    $boxes.WarnValue = $boxes.Warn.Value
    $boxes.CriticalValue = $boxes.Critical.Value
    $boxes.MonochromeChecked = $boxes.Monochrome.Checked
    $boxes.TooltipChecked = $boxes.Tooltip.Checked
  }

  $collect = {
    # The rows as they are edited, in the shape the validator and the writer want.
    # The name and the key are read from the boxes themselves: they are what the
    # user actually typed, and nothing about validation or writing depends on a
    # change notification having been delivered first.
    param($boxes)
    $accounts = @()
    for ($index = 0; $index -lt $rows.Count; $index++) {
      $row = $rows[$index]
      $cells = $script:CcRowCells[$index]
      $name = [string]$row.Name
      $apiKey = [string]$row.ApiKey
      if ($cells) {
        $name = $cells.Name.Text
        $apiKey = $cells.Key.Text
      }
      $accounts += @{
        Id           = [string]$row.Id
        Name         = $name
        ApiKey       = $apiKey
        ApiKeyEnv    = [string]$row.Env
        PreviousName = [string]$row.PreviousName
      }
    }
    return @{
      Accounts       = $accounts
      Language       = $script:CcSettingsLanguages[$boxes.Language.SelectedIndex].Code
      RefreshSeconds = [int]$boxes.Refresh.Value
      Warn           = [int]$boxes.Warn.Value
      Critical       = [int]$boxes.Critical.Value
      IconMetric     = @("fiveHour", "weekly", "monthly")[$boxes.Metric.SelectedIndex]
      Monochrome     = [bool]$boxes.Monochrome.Checked
      ShowTooltip    = [bool]$boxes.Tooltip.Checked
    }
  }

  $save = {
    param($boxes)
    $values = & $collect $boxes
    # Every hint is repainted from what is actually in the boxes, so the row the
    # save refuses names the account the user is looking at.
    for ($index = 0; $index -lt $rows.Count; $index++) { & $updateRowCell $index }
    $invalid = Test-CcSettingsDraft -Accounts $values.Accounts -Language $language
    if ($invalid) {
      & $setStatus $invalid.Message $true
      return
    }
    # The active account is the one the tray is following right now: kept when the
    # row it names still exists, and the first row otherwise.
    $active = ([string]$ActiveProfile).Trim().ToLowerInvariant()
    $ids = @()
    foreach ($account in $values.Accounts) {
      $ids += (Get-CcDraftAccountId -Draft $account -Taken $ids)
    }
    if ($ids -notcontains $active) { $active = [string]($ids | Select-Object -First 1) }
    try {
      [void](Save-CcSettingsToConfig -Path $Path -Accounts $values.Accounts -Language $values.Language `
        -RefreshSeconds $values.RefreshSeconds -Warn $values.Warn -Critical $values.Critical `
        -IconMetric $values.IconMetric -Monochrome $values.Monochrome -ShowTooltip $values.ShowTooltip `
        -ActiveProfile $active)
      $editing = $false
      $language = Get-CcSettingsLanguage -Path $Path
      # Re-read through the caller and repaint the tray, so the icon, the tooltip
      # and the bubble follow the save without a restart.
      if ($OnSaved) { & $OnSaved }
      & $build $true | Out-Null
      & $setStatus (& $text "settings.saved")
    } catch {
      # The file was not touched (the write is atomic), so the window stays
      # editable and the reason is on screen.
      & $setStatus (& $text "settings.saveFailed" @{ message = $_.Exception.Message }) $true
    }
  }

  # --- form and footer -------------------------------------------------------

  $fontFamily = Get-CcFontFamily
  if (-not $fontFamily) { $fontFamily = "Segoe UI" }
  $formFont = New-CcUiFont -Family $fontFamily -Size ([float]9.5)
  $headingFont = New-CcUiFont -Family $fontFamily -Size ([float]9.5) -Style ([System.Drawing.FontStyle]::Bold)
  $hintFont = New-CcUiFont -Family $fontFamily -Size ([float]8.5)

  $form = New-Object System.Windows.Forms.Form
  $form.Text = (& $text "settings.title")
  $form.Font = $formFont
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.ShowIcon = $false
  $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $form.ClientSize = [System.Drawing.Size]::new($script:CcFormWidth, 520)
  # Published while the window is open, and cleared when it closes: it is what the
  # self-test drives instead of real mouse input, and what lets the caller see that
  # the window is the one it opened.
  $script:CcSettingsForm = $form

  # The editor lives in a scrollable panel, so a configuration with a dozen
  # accounts stays reachable on a laptop screen; the footer is a direct child of
  # the form and therefore sits outside the scrolling area.
  $content = New-Object System.Windows.Forms.Panel
  $content.Location = [System.Drawing.Point]::new(0, 0)
  $content.AutoScroll = $true
  $form.Controls.Add($content)

  $statusLabel = New-CcSettingsLabel -Text "" -X 16 -Y 0 -Width 340 -Height 18 -Font $hintFont
  $saveButton = New-Object System.Windows.Forms.Button
  $saveButton.Text = (& $text "settings.save")
  $saveButton.Size = [System.Drawing.Size]::new(96, 28)
  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Text = (& $text "settings.cancel")
  $cancelButton.Size = [System.Drawing.Size]::new(96, 28)
  $closeButton = New-Object System.Windows.Forms.Button
  $closeButton.Text = (& $text "settings.close")
  $closeButton.Size = [System.Drawing.Size]::new(96, 28)
  $closeButton.Visible = $false
  $form.Controls.Add($statusLabel)
  $form.Controls.Add($saveButton)
  $form.Controls.Add($cancelButton)
  $form.Controls.Add($closeButton)

  $statusTimer = New-Object System.Windows.Forms.Timer
  $statusTimer.Interval = 4000
  $statusTimer.Add_Tick({
    $statusTimer.Stop()
    & $setStatus ""
  })

  $script:CcBoxes = $null
  $saveButton.Add_Click({
    # The live controls are reused (the footer is clicked, never rebuilt), so the
    # values read here are exactly what is on screen.
    #
    # An event handler that throws has nowhere to go: WinForms raises it on the UI
    # thread and the process shows the unhandled-exception dialog. `$save` reports
    # a write failure itself, and this is the net under everything else it does.
    try {
      if (-not $script:CcBoxes) { [void](& $build $false) }
      & $save $script:CcBoxes
    } catch {
      & $setStatus ((& $text "settings.saveFailed" @{ message = $_.Exception.Message })) $true
      try { Write-TrayError ("settings save: {0}" -f $_.Exception.Message) } catch { }
    }
  })
  $cancelButton.Add_Click({
    try {
      # Nothing was written, so this only restores the boxes from the file.
      $fresh = Get-CcSettingsDraft -Path $Path
      $rows.Clear()
      foreach ($account in $fresh.Accounts) { [void]$rows.Add((& $newRow $account.Id $account.Name $account.ApiKey $account.Env)) }
      $editing = $true
      [void](& $build $true)
      & $setStatus ""
    } catch {
      & $setStatus ((& $text "settings.saveFailed" @{ message = $_.Exception.Message })) $true
      try { Write-TrayError ("settings cancel: {0}" -f $_.Exception.Message) } catch { }
    }
  })
  $closeButton.Add_Click({ $form.Close() })

  $form.Add_Shown({
    # The very first build runs here, inside the modal loop: a throw that escaped
    # would be exactly the unhandled-exception dialog this guard exists to stop.
    try {
      $draft = Get-CcSettingsDraft -Path $Path
      $rows.Clear()
      foreach ($account in $draft.Accounts) { [void]$rows.Add((& $newRow $account.Id $account.Name $account.ApiKey $account.Env)) }
      if ($rows.Count -eq 0) { [void]$rows.Add((& $newRow)) }
      [void](& $build $true)
      & $setStatus ""
    } catch {
      & $setStatus ((& $text "settings.saveFailed" @{ message = $_.Exception.Message })) $true
      try { Write-TrayError ("settings window build: {0}" -f $_.Exception.Message) } catch { }
    }
  })

  try {
    [void]$form.ShowDialog()
  } catch {
    # ShowDialog surfaced a failure from the message loop or from a handler that
    # did not catch its own. Report it; the caller still gets control back.
    $failure = $_.Exception.Message
  } finally {
    $script:CcSettingsForm = $null
    try { $statusTimer.Stop(); $statusTimer.Dispose() } catch { }
    foreach ($resource in @($formFont, $headingFont, $hintFont)) {
      try { if ($resource) { $resource.Dispose() } } catch { }
    }
    try { $form.Dispose() } catch { }
  }

  } catch {
    # The guard opened at the top of the function: something went wrong before or
    # while the window was being assembled. No window is on screen, so the report
    # is a message of its own plus the log entry.
    $failure = $_.Exception.Message
  }
  if ($failure) { Show-CcSettingsFatalError -Message $failure -Language $language }
}
