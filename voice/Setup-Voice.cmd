@echo off
title GLaDOS Voice - Setup
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_voice.ps1"
