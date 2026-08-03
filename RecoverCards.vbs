Option Explicit
Dim objShell, strDir
Set objShell = CreateObject("WScript.Shell")
strDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & strDir & "SyncEngine\RecoverSet.ps1""", 1, True
