@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0harness.ps1" %*
exit /b %errorlevel%
