@echo off
rem Copies ALL inspection logs of THIS PC to this flash disk, into
rem logs\<computer name>\ next to this file. Use it on a PC where the flash
rem disk was removed before the inspection finished.
setlocal
set "SRC=%ProgramData%\PC-Inspection\logs"
if not exist "%SRC%" goto :nologs
robocopy "%SRC%" "%~dp0logs\%COMPUTERNAME%" /E /XO /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
echo Logs of this PC copied to: %~dp0logs\%COMPUTERNAME%
pause
exit /b 0
:nologs
echo No inspection logs found on this PC (%SRC%).
pause
exit /b 1
