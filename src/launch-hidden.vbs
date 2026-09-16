' CommandCode Monitor - console-less launcher.
'
' The Startup shortcut points at this file: going through wscript avoids the
' console flash you would see when launching the tray script directly.
' powershell.exe. -Sta e' obbligatorio per WinForms.

Option Explicit

Dim shell, fileSystem, scriptDir, trayScript, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDir = fileSystem.GetParentFolderName(WScript.ScriptFullName)
trayScript = scriptDir & "\tray.ps1"

If Not fileSystem.FileExists(trayScript) Then
  MsgBox "File not found: " & trayScript, 16, "CommandCode Monitor"
  WScript.Quit 1
End If

command = "powershell.exe -Sta -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & trayScript & """"

' 0 = hidden window, False = do not wait for the process to finish.
shell.Run command, 0, False
