@echo off
REM Launches the Thetis vs Zeus verification, bypassing the PowerShell execution
REM policy for this one process only (does not change any system settings).

cd /d "%~dp0"

where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Compare-ThetisZeus.ps1" %*
) else (
    echo PowerShell 7 ^(pwsh^) not found - falling back to Windows PowerShell.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Compare-ThetisZeus.ps1" %*
)

echo.
pause
