@echo off
setlocal
set "PET_DIR=%~dp0"
where pwsh.exe >nul 2>nul
if %errorlevel% equ 0 (
    start "" /min pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PET_DIR%Start-CodexUsagePet.ps1"
) else (
    start "" /min powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PET_DIR%Start-CodexUsagePet.ps1"
)
endlocal
