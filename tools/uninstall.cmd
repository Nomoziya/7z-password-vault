@echo off
rem Double-click entry point for uninstall.ps1: the execution policy may block a
rem .ps1 that is started directly, so it is called with -ExecutionPolicy Bypass.
rem All arguments are passed through, e.g.:
rem   uninstall.cmd -KeepVault
rem   uninstall.cmd -AllUsers
rem   uninstall.cmd -WhatIf
setlocal
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul && set "PS=pwsh.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
if errorlevel 1 (
  echo.
  echo The uninstaller reported a problem. Read the messages above.
  rem An unattended run (-Yes) must not wait for a keypress: it has no console to press.
  echo %* | findstr /i /c:"-Yes" >nul || pause
)
endlocal
