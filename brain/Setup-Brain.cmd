@echo off
title GLaDOS Brain - Setup
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_brain.ps1"
