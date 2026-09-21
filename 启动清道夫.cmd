@echo off
rem Prefer the Wails GUI shell when it is present; otherwise fall back to the
rem original PowerShell/WinForms launcher. Both ship in the same package.
setlocal
if exist "%~dp0QingDaoFu.exe" (
    start "" "%~dp0QingDaoFu.exe"
) else (
    start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app\Start-QingDaoFu.ps1"
)
endlocal
