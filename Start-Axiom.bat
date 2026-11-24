@echo off
rem Double-click this file to install (first time) and start Axiom RAG.
rem Options are passed through, e.g.:  Start-Axiom.bat -Mode cpu
title Axiom RAG
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
echo.
pause
