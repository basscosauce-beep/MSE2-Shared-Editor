' MTG Card Editor - Silent Updater & Launcher
' Double-click this file to update from GitHub and launch the editor with no console window.

Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

strInstallDir = objShell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\MSE2_Shared_Cloud"
strConfigFile = strInstallDir & "\creator.txt"
strVBS = strInstallDir & "\Launch_Silent.vbs"

' ---- If not installed yet, run the bat installer visibly so user sees progress ----
If Not objFSO.FileExists(strInstallDir & "\MSE2\magicseteditor.exe") Then
    strBat = objFSO.GetParentFolderName(WScript.ScriptFullName) & "\Mtg Card edditer.bat"
    objShell.Run "cmd.exe /c """ & strBat & """", 1, True
    WScript.Quit
End If

' ---- Already installed: silently git pull then launch ----
strGit = strInstallDir & "\mingit\cmd\git.exe"
objShell.Environment("PROCESS")("GIT_TERMINAL_PROMPT") = "0"
objShell.Run """" & strGit & """ -C """ & strInstallDir & """ pull origin main", 0, True

' ---- Check for creator name - prompt if missing ----
If Not objFSO.FileExists(strConfigFile) Then
    strName = InputBox("Welcome to MTG Card Editor!" & vbCrLf & vbCrLf & _
                       "What are your initials or name?" & vbCrLf & _
                       "(This shows in the 'By' column on your cards.)", _
                       "First Time Setup", "")
    If strName = "" Then strName = "?"
    Set f = objFSO.CreateTextFile(strConfigFile, True)
    f.Write strName
    f.Close
End If

' ---- Launch MSE2 silently ----
objShell.Run """" & strInstallDir & "\MSE2\magicseteditor.exe""", 1, False
