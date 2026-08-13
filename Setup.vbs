Set objShell = CreateObject("WScript.Shell")
strDir = objShell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\MSE2_Shared_Cloud"
objShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & strDir & "\Setup.ps1""", 0, True
