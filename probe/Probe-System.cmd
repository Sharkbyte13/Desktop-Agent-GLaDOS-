@echo off
title GLaDOS - system probe
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0probe.ps1"
