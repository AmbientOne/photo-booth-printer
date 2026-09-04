@echo off
REM Photo Booth print server launcher.
REM
REM Started by the "PhotoBooth Print Server" scheduled task 30 seconds after
REM logon, and safe to double-click for a manual run. The loop means a crashed
REM server comes straight back without anyone noticing.
title Photo Booth Print Server
cd /d "%~dp0"

:loop
py app.py
echo.
echo Print server exited. Restarting in 5 seconds... (close this window to stop)
REM ping, not timeout: timeout needs a console input handle and fails when the
REM task scheduler runs this without one.
ping -n 6 127.0.0.1 >nul
goto loop
