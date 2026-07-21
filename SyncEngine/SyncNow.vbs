' SyncNow.vbs - Manually force a sync

Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

strDir = objFSO.GetParentFolderName(objFSO.GetParentFolderName(WScript.ScriptFullName))
psScript = strDir & "\SyncEngine\SyncNow.ps1"

' Run the powershell script visibly so the user sees the progress
objShell.Run "powershell.exe -ExecutionPolicy Bypass -File """ & psScript & """", 1, False
