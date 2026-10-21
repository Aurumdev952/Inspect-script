"""Builds PC-Inspection.bat: a single self-contained launcher with the
PowerShell scripts embedded after the batch header. Usage:
    python3 build/make-bat.py <version> <output.bat>
"""
import pathlib, sys

version, out = sys.argv[1], sys.argv[2]
root = pathlib.Path(__file__).resolve().parent.parent

header = r"""@echo off
rem PC Inspection %VERSION% - same as PC-Inspection.exe, in one .bat file.
rem Keep it next to config.json and the drivers folder on the flash disk.
setlocal
title PC Inspection
net session >nul 2>&1
if errorlevel 1 (
    echo Asking for administrator rights - click Yes...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
set "BATFILE=%~f0"
set "PCI_TMP=%TEMP%\pc-inspection-%RANDOM%%RANDOM%"
mkdir "%PCI_TMP%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:BATFILE); $p=[regex]::Split($t,'(?m)^#==FILE:(.+?)==\r?$'); for($i=1;$i -lt $p.Count;$i+=2){[IO.File]::WriteAllText((Join-Path $env:PCI_TMP $p[$i].Trim()),$p[$i+1],(New-Object Text.UTF8Encoding $true))}"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PCI_TMP%\Inspect-PC.ps1" -FlashRoot "%~dp0." %*
set "RC=%ERRORLEVEL%"
rmdir /s /q "%PCI_TMP%" >nul 2>&1
echo.
pause
exit /b %RC%
""".replace("%VERSION%", version)

parts = [header]
for name in ("Inspect-PC.ps1", "Setup-Network.ps1"):
    body = (root / "scripts" / name).read_text(encoding="utf-8-sig")
    parts.append(f"#==FILE:{name}==\n{body}\n")

text = "".join(parts).replace("\r\n", "\n").replace("\n", "\r\n")
pathlib.Path(out).write_bytes(text.encode("utf-8"))
