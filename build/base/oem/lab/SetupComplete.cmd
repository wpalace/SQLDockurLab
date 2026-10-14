@echo off
rem Runs once as SYSTEM after the sysprep'd clone finishes OOBE.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Lab\FirstBoot.ps1 >> C:\Lab\logs\firstboot.log 2>&1
