@echo off
setlocal
rem Windows PowerShell 5.1 is what Windows ships, so it is the only host needed.
rem Preferred over pwsh when both are present so a run behaves identically
rem wherever it happens.
set "SELF=%~dp0install-dark-overlay_win64.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SELF%" %*
endlocal & (
    exit /b %ERRORLEVEL%
)
