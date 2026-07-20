' MSE2 Shared Cloud - Silent Launcher
' Does git pull, name prompt, sync engine, and MSE2 - all invisibly.

Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

strDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
strGit = strDir & "\mingit\cmd\git.exe"
strNode = ""
strConfigFile = strDir & "\creator.txt"

' ---- Find Node.js ----
Dim nodePaths(2)
nodePaths(0) = "C:\Program Files\nodejs\node.exe"
nodePaths(1) = "C:\Program Files (x86)\nodejs\node.exe"
nodePaths(2) = objShell.ExpandEnvironmentStrings("%APPDATA%") & "\nvm\current\node.exe"
Dim i
For i = 0 To 2
    If objFSO.FileExists(nodePaths(i)) Then
        strNode = nodePaths(i)
        Exit For
    End If
Next

' ---- Git pull (silent, force no-rebase to avoid divergence errors) ----
objShell.Environment("PROCESS")("GIT_TERMINAL_PROMPT") = "0"
objShell.Run """" & strGit & """ -C """ & strDir & """ config pull.rebase false", 0, True
objShell.Run """" & strGit & """ -C """ & strDir & """ pull origin main", 0, True

' ---- First launch: ask for name/initials ----
If Not objFSO.FileExists(strConfigFile) Then
    strName = InputBox("Welcome to MTG Card Editor - Shared Cloud!" & vbCrLf & vbCrLf & _
                       "Enter your initials or name." & vbCrLf & _
                       "This will appear in the 'By' column on your cards.", _
                       "Who are you?", "")
    If Trim(strName) = "" Then strName = "?"
    Set f = objFSO.CreateTextFile(strConfigFile, True)
    f.Write Trim(strName)
    f.Close
End If

' ---- Start Sync Engine silently (if node exists) ----
If strNode <> "" Then
    objShell.Run """" & strNode & """ """ & strDir & "\SyncEngine\sync_engine.js""", 0, False
End If

' ---- Launch MSE2 ----
objShell.Run """" & strDir & "\MSE2\magicseteditor.exe""", 1, False
