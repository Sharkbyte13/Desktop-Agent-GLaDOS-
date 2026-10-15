@echo off
title GLaDOS TTS - Setup
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_tts.ps1"
