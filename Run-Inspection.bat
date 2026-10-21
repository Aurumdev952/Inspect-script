@echo off
rem Backup launcher - use this only if PC-Inspection.exe is blocked.
rem It asks for admin rights, then runs the same PowerShell script.
title PC Inspection
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Asking for administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Inspect-PC.ps1" -FlashRoot "%~dp0."
echo.
pause
