@echo off
setlocal
echo ==================================================
echo   MTG Card Editor - Cloud Installer
echo ==================================================
echo.
echo Downloading from GitHub... (this may take a few minutes)
echo.

set "TEMP_DIR=%TEMP%\MSE2_Install_%RANDOM%"
set "ZIP_FILE=%TEMP_DIR%\mse2.zip"
set "REPO_URL=https://github.com/basscosauce-beep/MSE2-Shared-Editor/archive/refs/heads/main.zip"

:: Create temp directory
mkdir "%TEMP_DIR%"

:: Download the zip from GitHub
powershell -Command "& { $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri '%REPO_URL%' -OutFile '%ZIP_FILE%' }"

if not exist "%ZIP_FILE%" (
    echo ERROR: Download failed. Check your internet connection and try again.
    pause
    exit /b 1
)

echo Download complete! Installing...
echo.

:: Extract the zip
powershell -Command "Expand-Archive -Path '%ZIP_FILE%' -DestinationPath '%TEMP_DIR%' -Force"

:: Run the installer from the extracted folder
set "INSTALL_SRC=%TEMP_DIR%\MSE2-Shared-Editor-main"
cd /d "%INSTALL_SRC%"
call "Mtg Card edditer.bat"

:: Clean up temp files
cd /d "%TEMP%"
rmdir /s /q "%TEMP_DIR%" >nul 2>&1

exit
