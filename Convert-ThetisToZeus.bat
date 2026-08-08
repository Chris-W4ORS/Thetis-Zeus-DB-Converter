@echo off
REM Launches the Thetis -> Zeus converter, bypassing the PowerShell execution
REM policy for this one process only (does not change any system settings).
REM Prefers PowerShell 7 (pwsh) and falls back to Windows PowerShell if needed.

cd /d "%~dp0"

where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Convert-ThetisToZeus.ps1" %*
) else (
    echo PowerShell 7 ^(pwsh^) not found - falling back to Windows PowerShell.
    echo For best results install PowerShell 7: https://aka.ms/powershell
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Convert-ThetisToZeus.ps1" %*
)

echo.
pause
