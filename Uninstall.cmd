@echo off
title GLaDOS - Uninstall
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
