@echo off
title GLaDOS Voice - Restart
cd /d "%~dp0"
echo Stopping any running listeners...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter \"Name='python.exe' OR Name='pythonw.exe'\" | Where-Object { $_.CommandLine -like '*listener.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ('  stopped pid ' + $_.ProcessId) }"
if exist "%~dp0listener.pid" del /q "%~dp0listener.pid"
timeout /t 2 >nul
echo Starting one listener...
wscript.exe "%~dp0start-voice.vbs"
timeout /t 6 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=@(Get-CimInstance Win32_Process -Filter \"Name='python.exe' OR Name='pythonw.exe'\" | Where-Object { $_.CommandLine -like '*listener.py*' }); Write-Host ('  listeners running: ' + $p.Count); if (Test-Path '%~dp0state.json') { Write-Host ('  state: ' + ((Get-Content '%~dp0state.json' -Raw | ConvertFrom-Json).state)) }"
timeout /t 8 >nul
