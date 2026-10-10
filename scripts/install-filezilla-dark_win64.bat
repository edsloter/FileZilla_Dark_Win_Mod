@echo off
setlocal
set "SELF=%~dp0install-filezilla-dark_win64.ps1"
where pwsh.exe >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SELF%" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SELF%" %*
)
endlocal & (
    exit /b %ERRORLEVEL%
)
