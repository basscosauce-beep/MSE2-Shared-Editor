' Silent launcher - runs Launch_Shared_Editor.bat with no visible window
Set objShell = CreateObject("WScript.Shell")
strDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
objShell.Run "cmd.exe /c """ & strDir & "\Launch_Shared_Editor.bat""", 0, False
