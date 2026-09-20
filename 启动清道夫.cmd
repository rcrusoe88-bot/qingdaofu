@echo off
setlocal
set "QDF_START=%~dp0app\Start-QingDaoFu.ps1"
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%QDF_START%"
endlocal
