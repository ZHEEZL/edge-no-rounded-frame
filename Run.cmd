@echo off
setlocal
rem Convenience wrapper: double-click to apply, or use "Run.cmd -Undo" to revert.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EdgeNoRoundedFrame.ps1" %*
echo.
pause
