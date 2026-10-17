@echo off
setlocal
rem -------------------------------------------------------------------
rem This launcher is deliberately ASCII-only.
rem cmd.exe mis-parses batch files that combine a codepage switch (chcp)
rem with non-ASCII text: the parser re-reads buffered bytes under the old
rem codepage and turns half a line into a bogus command.
rem All Chinese messages are printed by Start-LLMKitWeb.ps1 instead.
rem -------------------------------------------------------------------
chcp 65001 >nul
cd /d "%~dp0"

set "WEB=%~dp0src\ps\Start-LLMKitWeb.ps1"

if not exist "%WEB%" goto :noentry

echo.
echo   LLMKit Web
echo   --------------------------------------------------------
echo   Starting the local service; the browser opens automatically.
echo   It listens on 127.0.0.1 only, never exposed to the network.
echo   Close this window (or press Ctrl+C) to stop the service.
echo.

rem Prefer pwsh if available, otherwise fall back to Windows PowerShell.
where pwsh >nul 2>nul
if errorlevel 1 goto :winps

pwsh -NoProfile -ExecutionPolicy Bypass -File "%WEB%" %*
goto :after

:winps
powershell -NoProfile -ExecutionPolicy Bypass -File "%WEB%" %*

:after
set RC=%ERRORLEVEL%
if "%RC%"=="0" exit /b 0

echo.
echo   Startup failed (exit code %RC%).
echo   For details, run:
echo     powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\ps\Start-LLMKitWeb.ps1" -SelfTest
echo.
if defined LLMKIT_NO_PAUSE exit /b %RC%
pause
exit /b %RC%

:noentry
echo.
echo   Entry script not found:
echo     %WEB%
echo.
echo   Put this file in the repository root (next to the src folder) and run it again.
echo.
if defined LLMKIT_NO_PAUSE exit /b 2
pause
exit /b 2
