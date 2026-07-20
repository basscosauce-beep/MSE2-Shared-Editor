@echo off
setlocal
echo ==================================================
echo      MAGIC SET EDITOR 2 - SHARED CLOUD EDITION
echo ==================================================
echo.

:: Set working directory to the folder this bat file is in
cd /d "%~dp0"

:: Add MinGit to path for this session
set "PATH=%~dp0mingit\cmd;%PATH%"
set "GIT_TERMINAL_PROMPT=0"

echo [1/3] Checking GitHub for updates to your card sets...
git pull origin main 2>&1
echo.

echo [2/3] Starting the background Auto-Sync Engine...

:: Find node.exe - check common locations
set "NODE_EXE="
if exist "%ProgramFiles%\nodejs\node.exe" set "NODE_EXE=%ProgramFiles%\nodejs\node.exe"
if exist "%ProgramFiles(x86)%\nodejs\node.exe" set "NODE_EXE=%ProgramFiles(x86)%\nodejs\node.exe"
if exist "%APPDATA%\nvm\current\node.exe" set "NODE_EXE=%APPDATA%\nvm\current\node.exe"

if "%NODE_EXE%"=="" (
    echo [WARNING] Node.js not found - auto-sync disabled. Cards must be synced manually.
    echo [WARNING] Install Node.js from https://nodejs.org to enable auto-sync.
) else (
    start "MSE2 Sync Engine" /B "%NODE_EXE%" "%~dp0SyncEngine\sync_engine.js"
    echo Auto-Sync Engine started! Your saved cards will push to the cloud automatically.
)

echo.
echo [3/3] Launching Magic Set Editor 2...
echo TIP: Save your set inside the "Shared-Set" folder to sync with the cloud!
echo.

:: Launch the editor and wait for it to close
start /wait "" "%~dp0MSE2\magicseteditor.exe"

echo.
echo MSE2 closed. Syncing any final changes...
if not "%NODE_EXE%"=="" (
    :: Final sync push on close
    git add "Shared-Set/"
    git commit -m "Auto-sync on close" 2>&1
    git push origin main 2>&1
    taskkill /F /IM node.exe >nul 2>&1
)
echo Done! Goodbye.
