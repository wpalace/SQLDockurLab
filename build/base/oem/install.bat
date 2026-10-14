@echo off
rem sql-ag-lab base image, phase 1. Executed by dockur at the end of unattended setup.
rem Copies the lab payload and hands over to PowerShell (which reboots, then syspreps).
if not exist C:\Lab mkdir C:\Lab
xcopy /E /I /Y /Q C:\OEM\lab C:\Lab >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Lab\Prepare-Base.ps1 > C:\Lab\prepare-base.log 2>&1
