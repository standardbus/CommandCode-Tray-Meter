' CommandCode Monitor - launcher senza finestra console.
'
' Il collegamento in "Esecuzione automatica" punta a questo file: passare da
' wscript evita il lampo di console che si vedrebbe avviando direttamente
' powershell.exe. -Sta e' obbligatorio per WinForms.

Option Explicit

Dim shell, fileSystem, scriptDir, trayScript, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDir = fileSystem.GetParentFolderName(WScript.ScriptFullName)
trayScript = scriptDir & "\tray.ps1"

If Not fileSystem.FileExists(trayScript) Then
  MsgBox "File non trovato: " & trayScript, 16, "CommandCode Monitor"
  WScript.Quit 1
End If

command = "powershell.exe -Sta -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & trayScript & """"

' 0 = finestra nascosta, False = non attendere la fine del processo.
shell.Run command, 0, False
