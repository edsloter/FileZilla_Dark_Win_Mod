@echo off
setlocal
rem Windows PowerShell 5.1 is what Windows ships, so it is the only host needed.
rem Chosen over any newer PowerShell when one is also installed, so a run
rem behaves identically wherever it happens.
set "SELF=%~dp0bootstrap_win64.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SELF%" %*
endlocal & (
    exit /b %ERRORLEVEL%
)
