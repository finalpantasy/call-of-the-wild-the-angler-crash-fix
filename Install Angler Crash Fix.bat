@echo off
title Angler Crash Fix - Install
echo Call of the Wild: The Angler - Crash Fix
echo Installing. Make sure the game is closed.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0AnglerCrashFix.ps1" -Apply
if errorlevel 1 (
  echo.
  echo The fix was NOT installed. See the message above.
  echo If it says access is denied, right-click this file and choose "Run as administrator".
)
echo.
pause
