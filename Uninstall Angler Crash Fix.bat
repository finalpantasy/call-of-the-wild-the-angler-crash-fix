@echo off
title Angler Crash Fix - Uninstall
echo Call of the Wild: The Angler - Crash Fix
echo Restoring the original game file. Make sure the game is closed.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0AnglerCrashFix.ps1" -Revert
if errorlevel 1 (
  echo.
  echo Nothing was changed. See the message above.
  echo You can also restore the game with Steam: right-click the game, Properties,
  echo Installed Files, "Verify integrity of game files".
)
echo.
pause
