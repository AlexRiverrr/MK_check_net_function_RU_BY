@echo off
REM Диагностика сети. Ничего не меняет, права администратора не нужны.
REM Запускайте при ВЫКЛЮЧЕННОМ VPN, затем при включённом — и сравните.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0netcheck.ps1"
if errorlevel 1 pause
