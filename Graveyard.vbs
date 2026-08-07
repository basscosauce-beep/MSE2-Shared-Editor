' Graveyard.vbs - Launch the Graveyard card recovery window

Set objShell = CreateObject("WScript.Shell")
Set objFSO   = CreateObject("Scripting.FileSystemObject")

strDir   = objFSO.GetParentFolderName(WScript.ScriptFullName)
psScript = strDir & "\Graveyard.ps1"

objShell.Run "powershell.exe -ExecutionPolicy Bypass -File """ & psScript & """", 1, False
