@echo off
title GLaDOS eye - Setup
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_eye.ps1"
