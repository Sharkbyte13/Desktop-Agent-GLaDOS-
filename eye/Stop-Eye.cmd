@echo off
title GLaDOS eye - Stop
rem Matches on eye.py specifically, not daemon.py, so this never touches the
rem TTS daemon and Stop-TTS never touches this one.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter \"Name='python.exe' OR Name='pythonw.exe'\" | Where-Object { $_.CommandLine -like '*eye.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ('stopped pid ' + $_.ProcessId) }"
timeout /t 2 >nul
