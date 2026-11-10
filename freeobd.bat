@echo off
rem FreeOBD launcher. Starts the GUI detached and hidden-console, so your prompt
rem comes right back and no blank blue PowerShell window shows up - just the app.
start "FreeOBD" /MIN powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0obd2gui.ps1"
