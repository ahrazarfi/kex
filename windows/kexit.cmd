@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0kex.ps1" stop %*
