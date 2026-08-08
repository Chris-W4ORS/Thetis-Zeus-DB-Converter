@echo off
REM Launches the Thetis -> Zeus converter, bypassing the PowerShell execution
REM policy for this one process only (does not change any system settings).
REM Finds the .ps1 whether it's in a scripts\ subfolder or right next to this .bat.

cd /d "%~dp0"

set "PS1=%~dp0scripts\Convert-ThetisToZeus.ps1"
if not exist "%PS1%" set "PS1=%~dp0Convert-ThetisToZeus.ps1"
if not exist "%PS1%" (
    echo ERROR: Could not find Convert-ThetisToZeus.ps1 next to this launcher
    echo or in a scripts\ subfolder. Keep the files together as downloaded.
    echo.
    pause
    exit /b 1
)

where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
) else (
    echo PowerShell 7 ^(pwsh^) not found - falling back to Windows PowerShell.
    echo For best results install PowerShell 7: https://aka.ms/powershell
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
)

echo.
pause
