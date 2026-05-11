@echo off
REM Self-elevating launcher: relaunches itself as admin if not already elevated.
REM Admin is required for the AWS CLI MSI install path.
REM CRITICAL: when UAC re-launches a process, its CWD becomes C:\Windows\System32.
REM We force CWD back to the .bat's own folder so terraform.tfvars and the other
REM wizard outputs land here, not in System32.

cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    REM Not elevated -- self-elevate, passing this folder as the working directory.
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
    exit /b
)

REM Already elevated. Run the GUI from this folder.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qlik_deploy_olh_gui.ps1"
pause
