# 单文件 .cmd 起服务后能正常开着并关闭。
#
# 验三件事：起得来、首页引用前端脚本、POST /api/shutdown 之后进程自己退出。
# 用 -NoBrowser，免得在 CI 里真去开浏览器。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $root
try {
    $tempBase = $env:RUNNER_TEMP
    if (-not $tempBase) { $tempBase = [System.IO.Path]::GetTempPath() }
    $env:LLMKIT_HOME = Join-Path $tempBase 'llmkit-single-web'
    $env:LLMKIT_NO_PAUSE = '1'
    $single = @(Get-ChildItem 'build\dist\LLMKit-web-single-*.cmd' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($single.Count -eq 0) { throw 'build\dist 里没有单文件 .cmd' }
    $port = 18471
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $single[0].FullName, '-NoBrowser', '-Port', $port -PassThru
    $base = 'http://127.0.0.1:' + $port
    $ready = $false
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 500
        try { Invoke-WebRequest -Uri ($base + '/api/health') -UseBasicParsing -TimeoutSec 3 | Out-Null; $ready = $true; break } catch { }
    }
    if (-not $ready) { $p.Kill(); throw '单文件 .cmd 没能把服务起起来' }
    $page = Invoke-WebRequest -Uri $base -UseBasicParsing -TimeoutSec 10
    if ($page.Content -notmatch '/assets/app\.js') { $p.Kill(); throw '首页没有引用前端脚本' }
    $dest = @(Get-ChildItem (Join-Path $env:LLMKIT_HOME 'portable') -Directory)
    if ($dest.Count -eq 0) { $p.Kill(); throw '单文件没有释放出 portable 目录' }
    node .\tests\web-dom-smoke.js $base (Join-Path $dest[0].FullName 'web\assets\app.js')
    if ($LASTEXITCODE -ne 0) { $p.Kill(); throw '单文件 .cmd 的冒烟测试失败' }
    Invoke-WebRequest -Uri ($base + '/api/shutdown') -Method POST -UseBasicParsing -TimeoutSec 5 | Out-Null
    if (-not $p.WaitForExit(60000)) { $p.Kill(); throw '关闭服务后单文件进程没有自行退出' }
    Write-Host ('进程已自行退出，退出码 ' + $p.ExitCode)
}
finally {
    Pop-Location
}
