@echo off
REM Self-elevating launcher: relaunches itself as admin if not already elevated.
REM Admin is required for the AWS CLI MSI install path.

net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qlik_deploy_olh_gui.ps1"
pause
