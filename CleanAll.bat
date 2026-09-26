@echo off
:: Runs Clean-All.ps1; arguments are passed through (e.g. CleanAll.bat -Steps 3,4,5)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Clean-All.ps1" %*
