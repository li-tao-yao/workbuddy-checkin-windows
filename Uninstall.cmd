@echo off
setlocal
set "WB_CHECKIN_PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%WB_CHECKIN_PS%" set "WB_CHECKIN_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%WB_CHECKIN_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1"
set "WB_CHECKIN_RESULT=%ERRORLEVEL%"
if not "%WB_CHECKIN_RESULT%"=="0" echo Uninstall failed. Please read the message above.
echo.
pause
exit /b %WB_CHECKIN_RESULT%
