@echo off
REM Launches the Thetis vs Zeus verification, bypassing the PowerShell execution
REM policy for this one process only (does not change any system settings).
REM Finds the .ps1 whether it's in a scripts\ subfolder or right next to this .bat.

cd /d "%~dp0"

set "PS1=%~dp0scripts\Compare-ThetisZeus.ps1"
if not exist "%PS1%" set "PS1=%~dp0Compare-ThetisZeus.ps1"
if not exist "%PS1%" (
    echo ERROR: Could not find Compare-ThetisZeus.ps1 next to this launcher
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
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
)

echo.
pause
