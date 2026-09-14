@echo off
rem Double-click entry point for uninstall.ps1: the execution policy may block a
rem .ps1 that is started directly, so it is called with -ExecutionPolicy Bypass.
rem All arguments are passed through, e.g.:
rem   uninstall.cmd -KeepVault
rem   uninstall.cmd -AllUsers
rem   uninstall.cmd -WhatIf
setlocal
rem Windows cannot remove a directory that is a process's current directory, and a
rem double-click starts this script with the program folder as the current directory.
rem Leaving it here is what lets the uninstaller delete the folder itself.
cd /d "%TEMP%" 2>nul
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul && set "PS=pwsh.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
if errorlevel 1 (
  echo.
  echo The uninstaller reported a problem. Read the messages above.
  rem An unattended run (-Yes) must not wait for a keypress: it has no console to press.
  set "UNATTENDED="
  for %%a in (%*) do if /i "%%~a"=="-Yes" set "UNATTENDED=1"
  if not defined UNATTENDED pause
)
endlocal
