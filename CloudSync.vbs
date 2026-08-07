Set objShell = CreateObject("WScript.Shell")
strDir = objShell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\MSE2_Shared_Cloud"
objShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strDir & "\CloudSync.ps1""", 0, False
