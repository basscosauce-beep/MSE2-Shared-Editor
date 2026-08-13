' MSE2 Shared Cloud - Silent Launcher
' Does git pull, name prompt, injects creator name, and launches MSE2 invisibly.

Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' ---- Kill any existing instances to ensure a clean start ----
On Error Resume Next
Set objWMIService = GetObject("winmgmts:\\.\root\cimv2")
Set colProcess = objWMIService.ExecQuery("Select * from Win32_Process Where Name = 'magicseteditor.exe' Or Name = 'MenuAddon.exe'")
For Each objProcess in colProcess
    objProcess.Terminate()
Next
On Error GoTo 0
strDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
strGit = strDir & "\mingit\cmd\git.exe"
strConfigFile  = strDir & "\creator.txt"
strMsePathFile = strDir & "\mse_path.txt"
strCustomScript = ""

' ---- Resolve MSE2 exe path from mse_path.txt (modular: can be anywhere) ----
strMseExe = ""
If objFSO.FileExists(strMsePathFile) Then
    Set fPath = objFSO.OpenTextFile(strMsePathFile, 1)
    strMseExe = Trim(fPath.ReadAll)
    fPath.Close
End If

' ---- Auto-migrate existing installs: check old bundled path before running wizard ----
' This lets existing users who already had MSE2 in the MSE2\ subfolder skip the wizard entirely.
If strMseExe = "" Or Not objFSO.FileExists(strMseExe) Then
    ' 1. Old bundled location (MSE2 subfolder inside install dir)
    Dim strLegacy
    strLegacy = strDir & "\MSE2\magicseteditor.exe"
    If objFSO.FileExists(strLegacy) Then
        Set fWrite = objFSO.CreateTextFile(strMsePathFile, True)
        fWrite.Write strLegacy
        fWrite.Close
        strMseExe = strLegacy
    End If
End If

If strMseExe = "" Or Not objFSO.FileExists(strMseExe) Then
    ' 2. Check common install locations without opening wizard
    Dim arrPaths(3)
    arrPaths(0) = "C:\Program Files\Magic Set Editor\magicseteditor.exe"
    arrPaths(1) = "C:\Program Files (x86)\Magic Set Editor\magicseteditor.exe"
    arrPaths(2) = objShell.ExpandEnvironmentStrings("%PROGRAMFILES%") & "\Magic Set Editor\magicseteditor.exe"
    arrPaths(3) = objShell.ExpandEnvironmentStrings("%PROGRAMFILES(X86)%") & "\Magic Set Editor\magicseteditor.exe"
    Dim pi
    For pi = 0 To 3
        If objFSO.FileExists(arrPaths(pi)) Then
            Set fWrite = objFSO.CreateTextFile(strMsePathFile, True)
            fWrite.Write arrPaths(pi)
            fWrite.Close
            strMseExe = arrPaths(pi)
            Exit For
        End If
    Next
End If

' ---- Only open wizard if we still have no valid path ----
If strMseExe = "" Or Not objFSO.FileExists(strMseExe) Then
    objShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & strDir & "\Setup.ps1""", 0, True
    ' Re-read path after wizard
    If objFSO.FileExists(strMsePathFile) Then
        Set fPath = objFSO.OpenTextFile(strMsePathFile, 1)
        strMseExe = Trim(fPath.ReadAll)
        fPath.Close
    End If
    If strMseExe = "" Or Not objFSO.FileExists(strMseExe) Then WScript.Quit
End If

' Derive MSE2 directory and custom_script path from the resolved exe path
strMseDir = objFSO.GetParentFolderName(strMseExe)
strCustomScript = strMseDir & "\data\magic.mse-game\custom_script"

' ---- Ensure Git Remote has Authentication Token so friends can push ----
p1 = "ghp_2g4dOrh3klYwVMo6o"
p2 = "FNfD8iUKfATTq3ezyS4"
objShell.Run """" & strGit & """ -C """ & strDir & """ remote set-url origin https://basscosauce-beep:" & p1 & p2 & "@github.com/basscosauce-beep/MSE2-Shared-Editor.git", 0, True

' ---- Git fetch (read-only: downloads remote info but NEVER overwrites local files) ----
' git pull is DANGEROUS here: a fast-forward could overwrite the .mse-set and delete
' cards that were created since the last sync. All .mse-set updates go through SyncNow.ps1
' which uses the smart merge engine. Script/template updates are applied by SyncNow's
' git reset --hard, so fetch is all we need here.
objShell.Environment("PROCESS")("GIT_TERMINAL_PROMPT") = "0"
objShell.Run """" & strGit & """ -C """ & strDir & """ fetch origin", 0, True

' ---- First launch: run Setup wizard if no name yet ----
If Not objFSO.FileExists(strConfigFile) Then
    objShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & strDir & "\Setup.ps1""", 0, True
    ' Setup wizard saves creator.txt - if it still doesn't exist, user cancelled
    If Not objFSO.FileExists(strConfigFile) Then WScript.Quit
End If

' ---- Read creator name ----
Set f = objFSO.OpenTextFile(strConfigFile, 1)
strCreator = Trim(f.ReadAll)
f.Close
If creatorName = "" Then creatorName = strCreator

' ---- Configure git author so commits don't fail for new users ----
objShell.Run """" & strGit & """ -C """ & strDir & """ config user.name """ & creatorName & """", 0, True
objShell.Run """" & strGit & """ -C """ & strDir & """ config user.email """ & creatorName & "@mse.local""", 0, True

' ---- Inject creator name into MSE2 custom_script so it auto-fills the By field ----
Set f = objFSO.CreateTextFile(strCustomScript, True)
f.WriteLine "## Auto-generated by launcher - do not edit manually"
f.WriteLine "## Your name is stored in creator.txt next to this app"
f.WriteLine ""
f.WriteLine "creator_name := """ & strCreator & """"
f.WriteLine ""
f.WriteLine "example_script_so_it_doesnt_die := {""""}"
f.Close

' ---- Start Sync Engine silently ----
objShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & strDir & "\SyncEngine\sync_engine.ps1""", 0, False

' ---- Compile MenuAddon.exe if missing or outdated ----
Dim cscPath
Dim cscCandidates(1)
cscCandidates(0) = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
cscCandidates(1) = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
For i = 0 To 1
    If objFSO.FileExists(cscCandidates(i)) Then cscPath = cscCandidates(i)
Next
Dim bCompile
bCompile = False
If Not objFSO.FileExists(strDir & "\MenuAddon.exe") Then
    bCompile = True
ElseIf objFSO.GetFile(strDir & "\MenuAddon.cs").DateLastModified > objFSO.GetFile(strDir & "\MenuAddon.exe").DateLastModified Then
    bCompile = True
End If

If cscPath <> "" And bCompile Then
    ' Delete old exe just in case
    If objFSO.FileExists(strDir & "\MenuAddon.exe") Then
        On Error Resume Next
        objFSO.DeleteFile strDir & "\MenuAddon.exe", True
        On Error GoTo 0
    End If
    If objFSO.FileExists(strDir & "\MenuAddon.cs") Then
        objShell.Run """" & cscPath & """ /nologo /r:System.Windows.Forms.dll /out:""" & strDir & "\MenuAddon.exe"" """ & strDir & "\MenuAddon.cs""", 0, True
    End If
End If

' ---- Start Menu Addon (adds Account Settings and Goals to MSE2 menu bar) ----
If objFSO.FileExists(strDir & "\MenuAddon.exe") Then
    objShell.Run """" & strDir & "\MenuAddon.exe"" """ & strDir & "\Settings.vbs"" """ & strDir & "\GoalTracker.vbs"" """ & strDir & "\CloudSync.vbs"" """ & strDir & "\Graveyard.vbs""", 0, False
End If

' ---- Launch MSE2 (open set directly if path was passed as argument) ----
Dim strSetArg
strSetArg = ""
If WScript.Arguments.Count > 0 Then
    strSetArg = " """ & WScript.Arguments(0) & """"
End If
objShell.Run """" & strMseExe & """" & strSetArg, 1, False


' EOF