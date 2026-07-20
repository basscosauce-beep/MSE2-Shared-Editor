@echo off
setlocal
echo ==================================================
echo      MAGIC SET EDITOR 2 - SHARED CLOUD INSTALLER
echo ==================================================
echo.

set "INSTALL_DIR=%LOCALAPPDATA%\MSE2_Shared_Cloud"
set "SHORTCUT_PATH=%USERPROFILE%\Desktop\Magic Set Editor (Shared).lnk"

echo Installing to: %INSTALL_DIR%
echo.

:: Create installation directory if it doesn't exist
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

:: Copy all files from the current directory (where the installer is) to the install dir
:: Exclude the installer itself so we don't copy it needlessly
echo Copying files...
xcopy /E /Y /I /Q ".\MSE2" "%INSTALL_DIR%\MSE2" >nul
xcopy /E /Y /I /Q ".\SyncEngine" "%INSTALL_DIR%\SyncEngine" >nul
if exist ".\Shared-Set" xcopy /E /Y /I /Q ".\Shared-Set" "%INSTALL_DIR%\Shared-Set" >nul
copy /Y ".\Launch_Shared_Editor.bat" "%INSTALL_DIR%\Launch_Shared_Editor.bat" >nul

echo.
echo Creating Desktop Shortcut...
:: Use PowerShell to create the shortcut
powershell -Command "$WshShell = New-Object -comObject WScript.Shell; $Shortcut = $WshShell.CreateShortcut('%SHORTCUT_PATH%'); $Shortcut.TargetPath = '%INSTALL_DIR%\Launch_Shared_Editor.bat'; $Shortcut.WorkingDirectory = '%INSTALL_DIR%'; $Shortcut.IconLocation = '%INSTALL_DIR%\MSE2\magicseteditor.exe'; $Shortcut.Save()"

echo.
echo ==================================================
echo   INSTALLATION COMPLETE!
echo ==================================================
echo A shortcut has been placed on your Desktop.
echo.
echo Launching Magic Set Editor now...
echo.

:: Launch it
cd /d "%INSTALL_DIR%"
start "" "Launch_Shared_Editor.bat"

:: Close the installer
exit
