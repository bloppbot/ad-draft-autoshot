@echo off
cd /d "%~dp0"
echo AD Draft AutoShot - leave this window open (minimize is fine)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0autoshot.ps1"
pause
