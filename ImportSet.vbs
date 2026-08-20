Dim objShell, strDir
Set objShell = CreateObject("WScript.Shell")
strDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\") - 1)
objShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File """ & strDir & "\ImportSet.ps1""", 1, False
Set objShell = Nothing
