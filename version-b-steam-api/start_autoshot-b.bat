@echo off
cd /d "%~dp0"
echo AD Draft AutoShot B (swap-aware) - leave this window open (minimize is fine)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0autoshot-b.ps1"
pause
