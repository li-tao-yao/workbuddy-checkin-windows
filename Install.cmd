@echo off
setlocal
set "WB_CHECKIN_PS="
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "WB_CHECKIN_PS=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined WB_CHECKIN_PS if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "WB_CHECKIN_PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined WB_CHECKIN_PS set "WB_CHECKIN_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%WB_CHECKIN_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
set "WB_CHECKIN_RESULT=%ERRORLEVEL%"
if not "%WB_CHECKIN_RESULT%"=="0" echo Setup failed. Please read the message above.
echo.
pause
exit /b %WB_CHECKIN_RESULT%
