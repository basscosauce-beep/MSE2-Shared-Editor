' Silent launcher for Magic Set Editor 2 - Shared Cloud Edition
Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

strDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
strConfigFile = strDir & "\creator.txt"

' --- First launch: ask for user's name/initials ---
If Not objFSO.FileExists(strConfigFile) Then
    strName = InputBox("Welcome to MTG Card Editor - Shared Cloud!" & vbCrLf & vbCrLf & _
                       "What are your initials or name?" & vbCrLf & _
                       "(This will appear in the 'By' column on every card you make.)", _
                       "First Time Setup", "")
    If strName = "" Then strName = "Unknown"
    Set objFile = objFSO.CreateTextFile(strConfigFile, True)
    objFile.Write strName
    objFile.Close
End If

' --- Read the creator name ---
Set objFile = objFSO.OpenTextFile(strConfigFile, 1)
strCreator = objFile.ReadAll
objFile.Close

' --- Set an environment variable so the batch can use it ---
objShell.Environment("PROCESS")("MSE_CREATOR") = strCreator

' --- Launch the batch file silently ---
objShell.Run "cmd.exe /c """ & strDir & "\Launch_Shared_Editor.bat""", 0, False
