@echo off
title Balatro Co-op
set "DIR=%LOCALAPPDATA%\BalatroCoop"
if not exist "%DIR%\BalatroCoop.ps1" (
  if not exist "%DIR%" mkdir "%DIR%"
  copy /Y "%~dp0BalatroCoop.ps1" "%DIR%\BalatroCoop.ps1" >nul
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\BalatroCoop.ps1"
