@echo off
title Balatro Co-op installer
echo Installing Balatro Co-op (downloads the launcher from GitHub, sets up Lovely + the mod, creates a desktop shortcut)...
set "DIR=%LOCALAPPDATA%\BalatroCoop"
if not exist "%DIR%" mkdir "%DIR%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-WebRequest -UseBasicParsing -Uri https://raw.githubusercontent.com/to31109-ctrl/BalatroMulti/main/launcher/BalatroCoop.ps1 -OutFile %DIR%\BalatroCoop.ps1"
if not exist "%DIR%\BalatroCoop.ps1" (
  echo Download failed. Using the copy next to this file instead.
  copy /Y "%~dp0BalatroCoop.ps1" "%DIR%\BalatroCoop.ps1" >nul
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\BalatroCoop.ps1" -Install -NoLaunch
pause
