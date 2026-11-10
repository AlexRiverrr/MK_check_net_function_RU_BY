@echo off
REM Проверка: доступен ли онлайн-API Mortal Kombat 1 с текущего подключения.
REM Ничего не меняет в системе, права администратора не нужны.
REM Код возврата: 0 - сервер ответил, 1 - блок по стране или нет связи.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mk1check.ps1"
