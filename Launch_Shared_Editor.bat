@echo off
echo ==================================================
echo      MAGIC SET EDITOR 2 - SHARED CLOUD EDITION
echo ==================================================
echo.

:: Add MinGit to path temporarily for this session
set "PATH=%~dp0mingit\cmd;%PATH%"

echo Checking GitHub for updates to the Editor and Cards...
git pull origin main

echo.
echo Starting the Cloud Sync Engine...

REM Start the sync engine in the background
start /B node SyncEngine\sync_engine.js

echo.
echo Launching Magic Set Editor 2...
echo NOTE: Please ensure you use "File > Save as Directory" and select the "Shared-Set" folder!
echo.

REM Launch the official Magic Set Editor 2 app
start /wait "" MSE2\magicseteditor.exe
echo Close this window when you are done to stop the sync engine.

REM Keep the window open so the background script can run
pause

echo Shutting down Sync Engine...
taskkill /F /IM node.exe >nul 2>&1
echo Done!
