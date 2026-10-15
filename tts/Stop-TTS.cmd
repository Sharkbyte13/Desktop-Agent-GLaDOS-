@echo off
title GLaDOS TTS - Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter \"Name='python.exe' OR Name='pythonw.exe'\" | Where-Object { $_.CommandLine -like '*daemon.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ('stopped pid ' + $_.ProcessId) }"
timeout /t 3 >nul
