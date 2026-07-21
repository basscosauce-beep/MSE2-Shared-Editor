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

:: ---- If already installed, just update the app files and launch ----
if exist "%INSTALL_DIR%\MSE2\magicseteditor.exe" (
    echo Forcing synchronization with cloud...
    set "PATH=%INSTALL_DIR%\mingit\cmd;%PATH%"
    set "GIT_TERMINAL_PROMPT=0"
    cd /d "%INSTALL_DIR%"
    
    :: Kill MSE if it's open so we can overwrite files safely
    taskkill /F /IM magicseteditor.exe >nul 2>&1
    
    git fetch origin >nul 2>&1
    git reset --hard origin/main >nul 2>&1
    git clean -fd >nul 2>&1
    echo Done! Launching...
    goto :launch
)

:: ---- First time install: download full package from GitHub ----
echo First time setup - downloading from GitHub...
echo (This will take a few minutes - please wait)
echo.

mkdir "%TEMP_DIR%" >nul 2>&1
powershell -Command "& { $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri '%REPO_ZIP%' -OutFile '%TEMP_ZIP%' }"

if not exist "%TEMP_ZIP%" (
    echo ERROR: Download failed. Check your internet connection.
    pause
    exit /b 1
)

echo Extracting files...
powershell -Command "Expand-Archive -Path '%TEMP_ZIP%' -DestinationPath '%TEMP_DIR%' -Force"

echo Installing...
set "SRC=%TEMP_DIR%\MSE2-Shared-Editor-main"

mkdir "%INSTALL_DIR%" >nul 2>&1
xcopy /E /Y /I /Q /H "%SRC%\MSE2"         "%INSTALL_DIR%\MSE2"        >nul
xcopy /E /Y /I /Q /H "%SRC%\SyncEngine"   "%INSTALL_DIR%\SyncEngine"  >nul
xcopy /E /Y /I /Q /H "%SRC%\mingit"       "%INSTALL_DIR%\mingit"      >nul
if exist "%SRC%\Shared-Set" xcopy /E /Y /I /Q /H "%SRC%\Shared-Set" "%INSTALL_DIR%\Shared-Set" >nul
copy /Y "%SRC%\Launch_Shared_Editor.bat"  "%INSTALL_DIR%\Launch_Shared_Editor.bat" >nul
copy /Y "%SRC%\Launch_Silent.vbs"         "%INSTALL_DIR%\Launch_Silent.vbs" >nul
copy /Y "%SRC%\Settings.ps1"              "%INSTALL_DIR%\Settings.ps1" >nul
copy /Y "%SRC%\Settings.vbs"              "%INSTALL_DIR%\Settings.vbs" >nul
copy /Y "%SRC%\MenuAddon.cs"              "%INSTALL_DIR%\MenuAddon.cs" >nul
copy /Y "%SRC%\MenuAddon.exe"             "%INSTALL_DIR%\MenuAddon.exe" >nul
copy /Y "%SRC%\GoalTracker.ps1"           "%INSTALL_DIR%\GoalTracker.ps1" >nul
copy /Y "%SRC%\GoalTracker.vbs"           "%INSTALL_DIR%\GoalTracker.vbs" >nul

:: Initialize git in the install dir so future pulls work
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
git commit -m "temp" >nul 2>&1
git fetch origin >nul 2>&1
git checkout -B main origin/main >nul 2>&1
git branch --set-upstream-to=origin/main main >nul 2>&1

:: Clean up temp files
rmdir /s /q "%TEMP_DIR%" >nul 2>&1
del /f /q "%TEMP_ZIP%" >nul 2>&1

:: Create Desktop shortcut
echo Creating Desktop Shortcut...
powershell -Command "$WshShell = New-Object -comObject WScript.Shell; $Shortcut = $WshShell.CreateShortcut('%SHORTCUT_PATH%'); $Shortcut.TargetPath = '%INSTALL_DIR%\Launch_Silent.vbs'; $Shortcut.WorkingDirectory = '%INSTALL_DIR%'; $Shortcut.IconLocation = '%INSTALL_DIR%\MSE2\magicseteditor.exe'; $Shortcut.Description = 'Launch Magic Set Editor 2 - Shared Cloud Edition'; $Shortcut.Save()"
powershell -Command "$WshShell = New-Object -comObject WScript.Shell; $Shortcut = $WshShell.CreateShortcut('%USERPROFILE%\Desktop\MTG Card Editor - Settings.lnk'); $Shortcut.TargetPath = '%INSTALL_DIR%\Settings.vbs'; $Shortcut.WorkingDirectory = '%INSTALL_DIR%'; $Shortcut.IconLocation = '%INSTALL_DIR%\MSE2\magicseteditor.exe, 0'; $Shortcut.Description = 'Change your name and initials for MTG Card Editor'; $Shortcut.Save()"

echo.
echo ==================================================
echo   INSTALLATION COMPLETE!
echo ==================================================
echo A shortcut has been placed on your Desktop.
echo From now on, use that shortcut to launch the editor.
echo.

:launch
:: Launch silently via the VBS wrapper (no console window)
start "" wscript.exe "%INSTALL_DIR%\Launch_Silent.vbs"
exit

