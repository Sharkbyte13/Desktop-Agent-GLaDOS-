@echo off
title GLaDOS Voice - Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter \"Name='python.exe' OR Name='pythonw.exe'\" | Where-Object { $_.CommandLine -like '*listener.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ('stopped pid ' + $_.ProcessId) }"
if exist "%~dp0listener.pid" del /q "%~dp0listener.pid"
timeout /t 3 >nul
