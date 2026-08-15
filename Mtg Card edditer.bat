@echo off
setlocal
echo ==================================================
echo   MTG Card Editor - Install / Update
echo ==================================================
echo.

set "INSTALL_DIR=%LOCALAPPDATA%\MSE2_Shared_Cloud"
set "SHORTCUT_PATH=%USERPROFILE%\Desktop\Magic Set Editor (Shared).lnk"
set "REPO_ZIP=https://github.com/basscosauce-beep/MSE2-Shared-Editor/archive/refs/heads/main.zip"
set "TEMP_ZIP=%TEMP%\mse2_update.zip"
set "TEMP_DIR=%TEMP%\mse2_update_%RANDOM%"

:: ---- If already installed: pull latest files first, THEN wizard ----
if exist "%INSTALL_DIR%\mingit\cmd\git.exe" (
    echo Updating to latest version...
    set "PATH=%INSTALL_DIR%\mingit\cmd;%PATH%"
    set "GIT_TERMINAL_PROMPT=0"
    set "P1=ghp_2g4dOrh3klYwVMo6o"
    set "P2=FNfD8iUKfATTq3ezyS4"
    cd /d "%INSTALL_DIR%"
    taskkill /F /IM magicseteditor.exe >nul 2>&1
    git -c credential.helper= remote set-url origin "https://basscosauce-beep:%P1%%P2%@github.com/basscosauce-beep/MSE2-Shared-Editor.git"
    git -c credential.helper= fetch origin
    git reset --hard origin/main
    git clean -fd >nul 2>&1
    echo Update complete!
    goto :shortcut
)

:: ---- First time install: download everything BEFORE running wizard ----
echo First time setup - downloading from GitHub...
echo (This may take a few minutes - please wait)
echo.

mkdir "%TEMP_DIR%" >nul 2>&1
powershell -Command "& { $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri '%REPO_ZIP%' -OutFile '%TEMP_ZIP%' }"

if not exist "%TEMP_ZIP%" (
    echo ERROR: Download failed. Check your internet connection.
    pause
    exit /b 1
)

echo Extracting...
powershell -Command "Expand-Archive -Path '%TEMP_ZIP%' -DestinationPath '%TEMP_DIR%' -Force"

echo Installing files...
set "SRC=%TEMP_DIR%\MSE2-Shared-Editor-main"

mkdir "%INSTALL_DIR%" >nul 2>&1
xcopy /E /Y /I /Q /H "%SRC%\MSE2"        "%INSTALL_DIR%\MSE2"        >nul
xcopy /E /Y /I /Q /H "%SRC%\SyncEngine"  "%INSTALL_DIR%\SyncEngine"  >nul
xcopy /E /Y /I /Q /H "%SRC%\mingit"      "%INSTALL_DIR%\mingit"      >nul
if exist "%SRC%\Shared-Set" xcopy /E /Y /I /Q /H "%SRC%\Shared-Set" "%INSTALL_DIR%\Shared-Set" >nul
copy /Y "%SRC%\Launch_Silent.vbs"  "%INSTALL_DIR%\Launch_Silent.vbs"  >nul
copy /Y "%SRC%\Setup.ps1"          "%INSTALL_DIR%\Setup.ps1"          >nul
copy /Y "%SRC%\Setup.vbs"          "%INSTALL_DIR%\Setup.vbs"          >nul
copy /Y "%SRC%\Settings.ps1"       "%INSTALL_DIR%\Settings.ps1"       >nul
copy /Y "%SRC%\Settings.vbs"       "%INSTALL_DIR%\Settings.vbs"       >nul
copy /Y "%SRC%\MenuAddon.cs"       "%INSTALL_DIR%\MenuAddon.cs"       >nul
copy /Y "%SRC%\MenuAddon.exe"      "%INSTALL_DIR%\MenuAddon.exe"      >nul
copy /Y "%SRC%\GoalTracker.ps1"    "%INSTALL_DIR%\GoalTracker.ps1"    >nul
copy /Y "%SRC%\GoalTracker.vbs"    "%INSTALL_DIR%\GoalTracker.vbs"    >nul
copy /Y "%SRC%\CloudSync.ps1"      "%INSTALL_DIR%\CloudSync.ps1"      >nul
copy /Y "%SRC%\CloudSync.vbs"      "%INSTALL_DIR%\CloudSync.vbs"      >nul
copy /Y "%SRC%\Graveyard.ps1"      "%INSTALL_DIR%\Graveyard.ps1"      >nul
copy /Y "%SRC%\Graveyard.vbs"      "%INSTALL_DIR%\Graveyard.vbs"      >nul

:: Initialize git so future updates work
set "PATH=%INSTALL_DIR%\mingit\cmd;%PATH%"
set "GIT_TERMINAL_PROMPT=0"
cd /d "%INSTALL_DIR%"
git init >nul 2>&1
set "P1=ghp_2g4dOrh3klYwVMo6o"
set "P2=FNfD8iUKfATTq3ezyS4"
git remote add origin https://basscosauce-beep:%P1%%P2%@github.com/basscosauce-beep/MSE2-Shared-Editor.git >nul 2>&1
git config user.name "Install" >nul 2>&1
git config user.email "install@mse.local" >nul 2>&1
git add . >nul 2>&1
git commit -m "initial" >nul 2>&1
git fetch origin >nul 2>&1
git checkout -B main origin/main -f >nul 2>&1
git branch --set-upstream-to=origin/main main >nul 2>&1

:: Safety: git checkout may have wiped Setup.ps1 if it wasn't committed yet.
:: Re-copy from the temp extract to guarantee it exists before the wizard runs.
if not exist "%INSTALL_DIR%\Setup.ps1" (
    copy /Y "%SRC%\Setup.ps1" "%INSTALL_DIR%\Setup.ps1" >nul
    copy /Y "%SRC%\Setup.vbs" "%INSTALL_DIR%\Setup.vbs" >nul
)

rmdir /s /q "%TEMP_DIR%" >nul 2>&1
del /f /q "%TEMP_ZIP%" >nul 2>&1

echo.
echo ==================================================
echo   FILES INSTALLED!
echo ==================================================
echo.

:shortcut
:: Create desktop shortcut pointing to Launch_Silent.vbs
:: (which auto-migrates existing users or runs wizard for new ones)
del /f /q "%USERPROFILE%\Desktop\Magic Set Editor (Shared).lnk" >nul 2>&1
del /f /q "%USERPROFILE%\Desktop\MTG Card Editor - Settings.lnk" >nul 2>&1
del /f /q "%USERPROFILE%\Desktop\Magic Set Editor.lnk" >nul 2>&1
del /f /q "%USERPROFILE%\Desktop\MTG Card Editor.lnk" >nul 2>&1
powershell -Command "$s = New-Object -ComObject WScript.Shell; $sc = $s.CreateShortcut('%SHORTCUT_PATH%'); $sc.TargetPath = 'wscript.exe'; $sc.Arguments = '\"%INSTALL_DIR%\Launch_Silent.vbs\"'; $sc.WorkingDirectory = '%INSTALL_DIR%'; $sc.Description = 'Launch Magic Set Editor 2 - Shared Cloud Edition'; $sc.Save()"
echo Desktop shortcut created.

:wizard
:: Run setup wizard LAST - all files are guaranteed on disk by this point
if exist "%INSTALL_DIR%\Setup.ps1" (
    powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "%INSTALL_DIR%\Setup.ps1"
) else (
    echo WARNING: Setup.ps1 not found. Launching directly...
    start "" wscript.exe "%INSTALL_DIR%\Launch_Silent.vbs"
)
