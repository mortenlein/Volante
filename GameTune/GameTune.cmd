@echo off
REM GameTune launcher. Double-click for the GUI; pass args for headless mode.
REM Uses Windows PowerShell 5.1 in STA so WPF (the GUI) works reliably.
REM Examples:
REM   GameTune.cmd
REM   GameTune.cmd -Report
REM   GameTune.cmd -Headless -Recommended
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Optimize.ps1" %*
