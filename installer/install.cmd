@echo off
rem Runs after the self-extracting package has unpacked the files.
rem %~dp0 is the folder the files were extracted to.
setlocal
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul && set "PS=pwsh.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -InstallDir "%~dp0." %*
if errorlevel 1 (
  echo.
  echo The installation step reported a problem. Read the messages above.
  pause
)
endlocal
