# 单文件 .cmd 释放后自检 + 冒烟。
#
# 单文件 .cmd 现在是「唯一」的便携形态：解压到临时目录、传 -SelfTest 给网页版入口。
# 用 cmd 启动（而不是 Start-Process 直接跑 .cmd），这样 %ERRORLEVEL% 才是真退出码。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $root
try {
    $base = $env:RUNNER_TEMP
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    $env:LLMKIT_HOME = Join-Path $base 'llmkit-single'
    $env:LLMKIT_NO_PAUSE = '1'
    $single = @(Get-ChildItem 'build\dist\LLMKit-web-single-*.cmd' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($single.Count -eq 0) { throw 'build\dist 里没有单文件 .cmd' }
    Write-Host ('用 ' + $single[0].Name + ' 跑自检')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $single[0].FullName, '-SelfTest' -PassThru
    if (-not $p.WaitForExit(300000)) { $p.Kill(); throw '单文件自检超时' }
    if ($p.ExitCode -ne 0) { throw ('单文件自检失败，退出码 ' + $p.ExitCode) }
    Write-Host ('自检通过，用时 ' + [int]$sw.Elapsed.TotalSeconds + 's')
    $dest = @(Get-ChildItem (Join-Path $env:LLMKIT_HOME 'portable') -Directory)
    if ($dest.Count -eq 0) { throw '单文件没有释放出 portable 目录' }
    Write-Host ('释放到 ' + $dest[0].FullName)
    # 冒烟脚本内部用 exit 结束，所以放到子进程里跑，好拿到真实退出码
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Invoke-WebSmoke.ps1') -WebRoot $dest[0].FullName
    if ($LASTEXITCODE -ne 0) { throw ('释放后的网页冒烟失败，退出码 ' + $LASTEXITCODE) }
}
finally {
    Pop-Location
}
