@echo off
setlocal
rem 切到 UTF-8 代码页，否则下面这些中文提示在默认的 OEM 代码页下会变成乱码。
rem 这一行必须是独立的命令，别让它跟到 rem 后面去（那样就永远不生效了）。
chcp 65001 >nul
rem 先切到本文件所在目录：这样双击、从别处调用、路径带空格都不会错。
cd /d "%~dp0"

set "WEB=%~dp0src\ps\Start-LLMKitWeb.ps1"

if not exist "%WEB%" goto :noentry

echo.
echo   LLMKit 网页版
echo   --------------------------------------------------------
echo   正在启动本地服务，起来之后会自动打开浏览器。
echo   服务只监听 127.0.0.1，不对外网开放。
echo   关掉这个窗口（或按 Ctrl+C）就会停止服务。
echo.

rem 有 pwsh 就用 pwsh，没有就退回系统自带的 Windows PowerShell
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
echo   启动失败（退出码 %RC%）。
echo   想看详细原因，跑这条命令：
echo     powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\ps\Start-LLMKitWeb.ps1" -SelfTest
echo.
if defined LLMKIT_NO_PAUSE exit /b %RC%
pause
exit /b %RC%

:noentry
echo.
echo   找不到网页版入口：
echo     %WEB%
echo.
echo   请把这个文件放在仓库根目录（也就是和 src 文件夹同一层），再双击。
echo.
if defined LLMKIT_NO_PAUSE exit /b 2
pause
exit /b 2