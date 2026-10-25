@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions

set "SCRIPT=%~dp0Set-DisplayCertification.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo  [ERROR] Set-DisplayCertification.ps1 not found:
    echo          %SCRIPT%
    echo.
    pause
    exit /b 1
)

rem ---- Check administrator (High Mandatory Level SID) ----
whoami /groups 2>nul | find "S-1-16-12288" >nul 2>&1
if errorlevel 1 (
    echo.
    echo  Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" 2>nul
    if errorlevel 1 (
        echo.
        echo  [ERROR] Elevation was cancelled or failed.
        echo          Please right-click this file and choose "Run as administrator".
        echo.
        pause
    )
    exit /b
)

rem ---- Prefer PowerShell 7, fall back to Windows PowerShell 5.1 ----
set "PS=powershell"
where pwsh >nul 2>&1
if not errorlevel 1 set "PS=pwsh"

title Display HDR Level Tool

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Menu

echo.
if errorlevel 1 (
    echo  [INFO] Exit code: %errorlevel%
    echo.
)
pause
endlocal
