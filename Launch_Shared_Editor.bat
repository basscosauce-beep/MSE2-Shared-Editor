@echo off
setlocal
set "INSTALL_DIR=%LOCALAPPDATA%\MSE2_Shared_Cloud"
set "GIT=%INSTALL_DIR%\mingit\cmd\git.exe"
set "GIT_TERMINAL_PROMPT=0"
set "P1=ghp_2g4dOrh3klYwVMo6o"
set "P2=FNfD8iUKfATTq3ezyS4"

:: Set credentials BEFORE fetch so it never fails on a fresh machine
"%GIT%" -C "%INSTALL_DIR%" -c credential.helper= remote set-url origin "https://basscosauce-beep:%P1%%P2%@github.com/basscosauce-beep/MSE2-Shared-Editor.git" >nul 2>&1

:: Fetch latest from GitHub
"%GIT%" -C "%INSTALL_DIR%" -c credential.helper= fetch origin >nul 2>&1
if errorlevel 1 (
    powershell -Command "& { Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show('Could not reach GitHub to check for updates. Launching with current version.','MSE2 Update','OK','Warning') }" >nul 2>&1
    goto :launch
)

:: Update ONLY script files - never touches the .mse-set card data
"%GIT%" -C "%INSTALL_DIR%" -c credential.helper= checkout origin/main -- ^
    SyncEngine/SyncNow.ps1 ^
    SyncEngine/DedupManager.ps1 ^
    SyncEngine/DedupPreview.ps1 ^
    SyncEngine/MergeSetFile.ps1 ^
    SyncEngine/SyncPreview.ps1 ^
    SyncEngine/sync_engine.ps1 ^
    SyncEngine/FillCreators.ps1 ^
    SyncEngine/RecoverSet.ps1 ^
    CloudSync.ps1 ^
    GoalTracker.ps1 ^
    Settings.ps1 ^
    Graveyard.ps1 ^
    Setup.ps1 ^
    Launch_Silent.vbs ^
    Launch_Shared_Editor.bat ^
    CloudSync.vbs ^
    GoalTracker.vbs ^
    Graveyard.vbs ^
    Settings.vbs ^
    RecoverCards.vbs ^
    MenuAddon.cs ^
    MSE2/data/magic.mse-game/custom_addons ^
    MSE2/data/magic.mse-game/shared_tools_stats >nul 2>&1

:launch
:: Launch MSE2 via the VBS launcher
wscript.exe "%INSTALL_DIR%\Launch_Silent.vbs"