<#
.SYNOPSIS
    起一个本地服务，用 Node 的最小 DOM 桩把真正的前端跑一遍，然后关掉服务。

.DESCRIPTION
    这一步验的是"用户在浏览器里看到的东西到底对不对"：路由、页面渲染内容、
    按钮是否登记、请求体是否正确、以及"会改动系统的动作是否一定先过
    /api/preview 再弹确认框"。

    为什么要有这个脚本：这里开不了真浏览器，如果只跑 node --check，
    那是"语法对、逻辑全错也照样通过"。这里做的是把真正的 web/assets/app.js
    跑在真正在跑的服务上。

    它验不到真实浏览器里的布局与事件冒泡 —— 这一点是已知的，别把它当浏览器测试。

.PARAMETER WebRoot
    要测哪一份前端。默认仓库根目录；传解压出来的发布目录即可验打包产物。

.PARAMETER Port
    服务端口。默认自动挑一个没被占用的。

.EXAMPLE
    .\tests\Invoke-WebSmoke.ps1

.EXAMPLE
    # 验打包产物（exe 释放出来的目录）
    .\tests\Invoke-WebSmoke.ps1 -WebRoot "$env:LOCALAPPDATA\LLMKit\portable\<指纹>"
#>
[CmdletBinding()]
param(
    [string]$WebRoot = '',
    [int]$Port = 0,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($WebRoot)) { $WebRoot = $repoRoot }
$WebRoot = (Resolve-Path -LiteralPath $WebRoot).Path

$smoke = Join-Path $PSScriptRoot 'web-dom-smoke.js'
$entry = Join-Path $WebRoot 'src\ps\Start-LLMKitWeb.ps1'
$appJs = Join-Path $WebRoot 'web\assets\app.js'

foreach ($need in @(@{ p = $smoke; n = '冒烟测试脚本' }, @{ p = $entry; n = '网页版入口' }, @{ p = $appJs; n = '前端 app.js' })) {
    if (-not (Test-Path -LiteralPath $need.p)) {
        Say ('缺少' + $need.n + '：' + $need.p) 'Red'
        exit 2
    }
}

$node = Get-Command -Name 'node' -ErrorAction SilentlyContinue
if (-not $node) {
    Say '找不到 node。前端冒烟测试需要 Node.js（只用来跑测试，不是运行工具的必要条件）。' 'Red'
    exit 2
}

# 端口：默认随便挑一个空着的，避免和已经在跑的实例撞上
if ($Port -le 0) {
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $Port = $probe.LocalEndpoint.Port
    $probe.Stop()
}

Say ('被测前端：' + $WebRoot) 'DarkGray'
Say ('服务端口：' + $Port) 'DarkGray'
Say ''

$outLog = Join-Path ([System.IO.Path]::GetTempPath()) ('llmkit-smoke-' + $Port + '.out.log')
$errLog = Join-Path ([System.IO.Path]::GetTempPath()) ('llmkit-smoke-' + $Port + '.err.log')
foreach ($f in @($outLog, $errLog)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

$server = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entry, '-Port', $Port) `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -NoNewWindow

$base = 'http://127.0.0.1:' + $Port
$ready = $false
try {
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            Invoke-WebRequest -Uri ($base + '/api/health') -UseBasicParsing -TimeoutSec 3 | Out-Null
            $ready = $true
            break
        } catch { }
    }
    if (-not $ready) {
        Say '服务没能起来。服务端输出：' 'Red'
        @(Get-Content -LiteralPath $errLog -ErrorAction SilentlyContinue) | Select-Object -Last 10 | ForEach-Object { Say ('  ' + $_) 'Red' }
        exit 3
    }

    $nodeArgs = @($smoke, $base, $appJs)
    $nodeOut = & $node.Source @nodeArgs 2>&1
    $code = $LASTEXITCODE
    if (-not $Quiet) { @($nodeOut) | ForEach-Object { Write-Host ('  ' + $_) } }
    exit $code
} finally {
    # 关服务；用 POST —— GET 走不到关闭分支（这是 HTTP 方法，不是路径）
    try { Invoke-WebRequest -Uri ($base + '/api/shutdown') -Method POST -UseBasicParsing -TimeoutSec 5 | Out-Null } catch { }
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $server.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    if (-not $server.HasExited) { try { $server.Kill() } catch { } }
}
