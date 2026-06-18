@echo off
REM Volante launcher. Double-click for the GUI; pass args for headless mode.
REM Uses Windows PowerShell 5.1 in STA so WPF (the GUI) works reliably.
REM Examples:
REM   Volante.cmd
REM   Volante.cmd -Report
REM   Volante.cmd -Headless -Recommended
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Optimize.ps1" %*

