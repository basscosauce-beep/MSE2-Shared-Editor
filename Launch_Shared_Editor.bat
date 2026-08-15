@echo off
setlocal
set "INSTALL_DIR=%LOCALAPPDATA%\MSE2_Shared_Cloud"
set "GIT=%INSTALL_DIR%\mingit\cmd\git.exe"
set "GIT_TERMINAL_PROMPT=0"

:: Update all scripts from GitHub (safe - never touches the .mse-set card data)
"%GIT%" -C "%INSTALL_DIR%" -c credential.helper= fetch origin >nul 2>&1
"%GIT%" -C "%INSTALL_DIR%" -c credential.helper= checkout origin/main -- ^
    SyncEngine/SyncNow.ps1 ^
    SyncEngine/DedupManager.ps1 ^
    SyncEngine/DedupPreview.ps1 ^
    SyncEngine/MergeSetFile.ps1 ^
    SyncEngine/SyncPreview.ps1 ^
    SyncEngine/sync_engine.ps1 ^
    CloudSync.ps1 ^
    GoalTracker.ps1 ^
    Settings.ps1 ^
    Graveyard.ps1 ^
    Setup.ps1 ^
    Launch_Silent.vbs ^
    Launch_Shared_Editor.bat ^
    MSE2/data/magic.mse-game/custom_addons ^
    MSE2/data/magic.mse-game/shared_tools_stats ^
    >nul 2>&1

:: Now launch normally via the VBS launcher
wscript.exe "%INSTALL_DIR%\Launch_Silent.vbs"