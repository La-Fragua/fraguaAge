@echo off
REM Doble-click para unirse al servidor LAN de AoE2 DE.
REM Pasa una IP como argumento para usar otro servidor, ej: connect-aoe2.bat 192.168.1.50
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect-aoe2.ps1" %*
echo.
pause
