<#
.SYNOPSIS
    LLMKit 发布打包：把脚本引擎打进一个绿色包，或打成单文件自解压 .cmd

.DESCRIPTION
    产品只有一种形态：**浏览器版**。这个脚本负责把它打包成下面两种之一（都打开浏览器）：

      single        单文件自解压 .cmd（零工具链，双击即开浏览器）
      green         绿色包：一个文件夹 + LLMKit-web.cmd（零依赖，解压即用，脚本内容可查）
      green+single  两样都出（auto 的默认值）

    为什么不再出单文件 exe：桌面版（WinForms 向导）已经删掉 —— 浏览器版在真实机器上更好用，
    而 exe 那条路要依赖 Windows 自带的 csc.exe 或 Go 工具链，等于给打包加了两条会断的腿。
    iexpress 那条路也试过但不可用：它会把目录结构压平，解出来的包找不到引擎（已实测确认）。

.PARAMETER Tier
    auto（默认，等于 green+single）/ single / green / green+single
    注意：$Tier 带 ValidateSet 特性，内部给它赋新值也必须在集合内（PowerShell 的坑）。

.PARAMETER OutDir
    产物输出目录，默认 build\dist

.PARAMETER Zip
    额外再打一个 zip（方便发给别人）

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\build\Build-Release.ps1 -Tier green -Zip
#>

[CmdletBinding()]
param(
    [ValidateSet('auto', 'single', 'green', 'green+single')][string]$Tier = 'auto',
    [string]$OutDir,
    [switch]$Zip,
    [switch]$NoColor
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptDir
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $scriptDir 'dist' }
$version = (Get-Date -Format 'yyyyMMdd')

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    if ($NoColor) { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
}

Say ''
Say 'LLMKit 发布打包' 'White'
Say ('项目根：' + $projectRoot) 'DarkGray'
Say ('产物目录：' + $OutDir) 'DarkGray'
Say ('版本标记：' + $version) 'DarkGray'

# ---------------------------------------------------------------- 前置检查
$required = @(
    'src\ps\Setup-LLMKit.ps1', 'src\ps\LLMKit.Engine.psm1',
    'src\ps\LLMKit.psm1', 'src\ps\LLMKit.Install.psm1', 'src\ps\LLMKit.Tools.psm1',
    'src\ps\LLMKit.Config.psm1', 'src\ps\LLMKit.Diagnose.psm1',
    'src\ps\LLMKit.Service.psm1', 'src\ps\LLMKit.Web.psm1', 'src\ps\LLMKit.Hardware.psm1',
    'src\ps\Start-LLMKitWeb.ps1', 'web\index.html',
    'config\tools.json', 'config\dependencies.json', 'config\providers.json', 'config\errormap.json', 'config\models.json'
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $projectRoot $_)) })
if ($missing.Count -gt 0) {
    Say ''
    Say ('缺少必需文件，无法打包：' + ($missing -join '、')) 'Red'
    exit 2
}
Say ('前置检查：' + $required.Count + ' 个必需文件齐全') 'Green'

# 发布包里必须有网页版。少了它 exe 起来只能看到 404，而这种缺失不该等到用户手上才发现。
$payloadMustHave = @(
    'web/index.html', 'web/assets/app.js', 'web/assets/app.css',
    'src/ps/Start-LLMKitWeb.ps1', 'src/ps/LLMKit.Web.psm1',
    'src/ps/LLMKit.Service.psm1', 'src/ps/LLMKit.Engine.psm1', 'src/ps/LLMKit.Hardware.psm1', 'config/tools.json', 'config/models.json'
)

# ---------------------------------------------------------------- 选路
# 自动选择：绿色包 + 单文件 .cmd，两样都打开浏览器版。
# 桌面版（WinForms 向导、单文件 exe、Go 外壳）已经删掉 —— 理由见 README「已知限制」。
if ($Tier -eq 'auto') {
    $Tier = 'green+single'
    Say ''
    Say ('自动选择：' + $Tier) 'Cyan'
}
Say ('  绿色包 + 单文件 .cmd ：始终可用（零依赖、零编译）') 'Green'
# ---------------------------------------------------------------- 公共：收集要分发的文件
function Copy-Payload {
    param([string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $Destination -Force)
    # web 也要一起打包：网页版的界面就是它，漏了的话 exe 起来只能看到 404
    foreach ($d in @('src', 'config', 'web')) {
        $src = Join-Path $projectRoot $d
        if (-not (Test-Path -LiteralPath $src)) { throw ('载荷缺少目录：' + $src) }
        Copy-Item -LiteralPath $src -Destination $Destination -Recurse -Force
    }
    # 开发用的东西不进发布包
    foreach ($junk in @('*.tmp', '*.bak')) {
        Get-ChildItem -LiteralPath $Destination -Recurse -Filter $junk -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    return $Destination
}

# 把 stage 打成 zip 写进给定的流。
# 刻意手写条目而不用 ZipFile.CreateFromDirectory：.NET Framework 那套实现会把条目名写成
# "web\index.html" 这种反斜杠形式，不符合 zip 规范，严格的解压器会解出一个名字里带反斜杠
# 的怪文件。这里统一成正斜杠。
# 打完立刻自证：关键文件不在包里就抛错 —— 宁可打不出包，也不要出一个没有界面的包。
function New-PayloadZip {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][System.IO.Stream]$Target,
        [string[]]$MustHave = @()
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # 变量名不能叫 $zip：脚本参数 -Zip 是 SwitchParameter，PowerShell 变量名不区分大小写，
    # 两者是同一个变量，赋值会报 "Cannot convert ... to type SwitchParameter"（实测踩到）。
    $level = [System.IO.Compression.CompressionLevel]::Optimal
    $mode = [System.IO.Compression.ZipArchiveMode]::Create
    $arch = New-Object System.IO.Compression.ZipArchive -ArgumentList @($Target, $mode, $true)
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $Stage -Recurse -File)) {
            $rel = $f.FullName.Substring($Stage.Length).TrimStart('\', '/').Replace('\', '/')
            $entry = $arch.CreateEntry($rel, $level)
            $es = $entry.Open()
            try {
                $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
                $es.Write($bytes, 0, $bytes.Length)
            } finally { $es.Close() }
        }
    } finally { $arch.Dispose() }

    # 回读自证。leaveOpen 让流留在调用方手里，调用方决定什么时候关。
    $Target.Flush()
    $Target.Position = 0
    $readMode = [System.IO.Compression.ZipArchiveMode]::Read
    $probe = New-Object System.IO.Compression.ZipArchive -ArgumentList @($Target, $readMode, $true)
    $names = @()
    try { $names = @($probe.Entries | ForEach-Object { $_.FullName }) } finally { $probe.Dispose() }
    $absent = @($MustHave | Where-Object { $names -notcontains $_ })
    if ($absent.Count -gt 0) { throw ('载荷自检失败，缺少：' + ($absent -join '、')) }
    return $names
}

function New-WebLauncherCmd {
    <#
        网页版入口。这是**唯一**的界面入口 —— 桌面版（WinForms 向导）已经删掉，
        浏览器版在真实机器上更好用，也不用依赖系统里的 WinForms 组件。
    #>
    param([string]$Path)
    $lines = @(
        '@echo off',
        'setlocal',
        'rem 切到 UTF-8 代码页，否则下面那些中文提示在默认的 OEM 代码页下会变成乱码',
        'chcp 65001 >nul',
        'cd /d "%~dp0"',
        'set "WEB=%~dp0src\ps\Start-LLMKitWeb.ps1"',
        'echo LLMKit 网页版：正在启动本地服务，稍后会自动打开浏览器。',
        'echo 关掉这个窗口（或按 Ctrl+C）就会停止服务。',
        'echo.',
        'where pwsh >nul 2>nul',
        'if %ERRORLEVEL%==0 (',
        '  pwsh -NoProfile -ExecutionPolicy Bypass -File "%WEB%" %*',
        ') else (',
        '  powershell -NoProfile -ExecutionPolicy Bypass -File "%WEB%" %*',
        ')',
        'if %ERRORLEVEL% NEQ 0 (',
        '  echo.',
        '  echo 启动失败^(退出码 %ERRORLEVEL%^)。可以试试命令行排查：',
        '  echo   powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\ps\Start-LLMKitWeb.ps1" -SelfTest',
        '  pause',
        ')'
    )
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($lines -join "`r`n") + "`r`n", $enc)
}

function New-Readme {
    param([string]$Path)
    $text = @"
LLMKit · 大模型工具引导式一键安装器
================================================================

怎么用（只有一套界面：浏览器）
  双击 LLMKit-web.cmd   → 起本地服务并自动打开浏览器；关掉那个黑窗口就停止服务。

  界面是"首页 + 每个工具一页"：想装哪个就进哪个工具的页面。
  安装 / 重装 / 验证 / 清理残留 / 卸载 / 配渠道和模型 都在那一页里，
  日志在页面底部实时滚动；每个智能体的"照着做"步骤也在它自己的页面上。

  默认只演练，不会改动任何东西；想真的装，勾上「真的执行」。
  服务只监听 127.0.0.1，不对外网开放。

  不需要管理员权限。本工具只装到用户目录，也不会删除你的文件。
  卸载同样是只搬不删：本体、残留和它加过的 PATH 条目都挪到备份区，可以还原。
  网页右上角有「关闭服务」，点一下就能停。

装了什么
  Claude Code / cc-switch / Codex / OpenCode / Gemini CLI / DeepSeek Harness
  以及它们需要的 Node.js 与 Git（缺什么装什么，优先用免管理员的便携版）

关于 API Key
  本工具不内置、代发或代充任何 API Key。
  只提供各渠道的注册与创建 Key 的入口链接，key 始终由你自己创建和保管。

装完怎么还原
  界面左下角「还原上一次改动…」，或命令行：
    powershell -NoProfile -ExecutionPolicy Bypass -File src\ps\Setup-LLMKit.ps1 -Restore <日志文件> -Apply

卡住了怎么办
  界面里走一步「生成诊断报告」，它会把报告复制到剪贴板。
  报告已自动脱敏，不含 key、用户名与邮箱，可以直接粘贴给别人看。

命令行版本
  不想用界面也行，直接跑：
    powershell -NoProfile -ExecutionPolicy Bypass -File src\ps\Setup-LLMKit.ps1
  它会先体检，再打印完整的安装计划，仍然不改动任何东西。
"@
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($true)))
}

# ---------------------------------------------------------------- 各路径
$results = New-Object System.Collections.ArrayList
if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }

if ($Tier -eq 'green') {
    Say ''
    Say '--- 打包：绿色包 ---' 'Cyan'
    $bundle = Join-Path $OutDir 'LLMKit'
    [void](Copy-Payload -Destination $bundle)
    New-WebLauncherCmd -Path (Join-Path $bundle 'LLMKit-web.cmd')
    New-Readme -Path (Join-Path $bundle '使用说明.txt')
    $size = (Get-ChildItem -LiteralPath $bundle -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Say ('  产物：' + $bundle) 'Green'
    Say ('  大小：' + [math]::Round($size / 1MB, 2) + ' MB') 'DarkGray'
    Say '  启动：双击 LLMKit-web.cmd（会起本地服务并打开浏览器）' 'DarkGray'
    [void]$results.Add([pscustomobject]@{ tier = 'green'; path = $bundle; kind = 'folder'; bytes = $size })

    if ($Zip) {
        $zipPath = Join-Path $OutDir ('LLMKit-green-' + $version + '.zip')
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zipPath -Force
        Say ('  zip：' + $zipPath + '（' + [math]::Round((Get-Item $zipPath).Length / 1MB, 2) + ' MB）') 'Green'
        [void]$results.Add([pscustomobject]@{ tier = 'green-zip'; path = $zipPath; kind = 'zip'; bytes = (Get-Item $zipPath).Length })
    }
} elseif ($Tier -eq 'single' -or $Tier -eq 'green+single') {
    Say ''
    Say '--- 打包：单文件自解压 .cmd ---' 'Cyan'

    $stage = Join-Path $OutDir 'single-stage'
    [void](Copy-Payload -Destination $stage)
    New-WebLauncherCmd -Path (Join-Path $stage 'LLMKit-web.cmd')
    New-Readme -Path (Join-Path $stage '使用说明.txt')

    Say '  1) 压缩载荷到内存' 'DarkGray'
    # ZipArchive / ZipArchiveMode 在 System.IO.Compression 里，
    # 而 ZipFile.ExtractToDirectory 在 System.IO.Compression.FileSystem 里 —— 两个都要加载。
    # 两者都由 New-PayloadZip 负责，这里只管把内存流交给它。
    $mem = New-Object System.IO.MemoryStream
    $payloadNames = @(New-PayloadZip -Stage $stage -Target $mem -MustHave $payloadMustHave)
    Say ('     载荷自检：' + $payloadNames.Count + ' 个文件') 'DarkGray'
    $zipBytes = $mem.ToArray()
    $mem.Dispose()
    $payloadB64 = [Convert]::ToBase64String($zipBytes)
    # 用 .NET 直接算指纹，避免依赖 Get-FileHash 的流参数在各版本上的差异
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash($zipBytes)
    $sha.Dispose()
    $hash8 = -join ($hashBytes[0..3] | ForEach-Object { $_.ToString('x2') })
    Say ('     zip ' + [math]::Round($zipBytes.Length / 1KB, 1) + ' KB → base64 ' + [math]::Round($payloadB64.Length / 1KB, 1) + ' KB，指纹 ' + $hash8) 'DarkGray'

    Say '  2) 引导脚本转 -EncodedCommand（避免所有引号与转义问题）' 'DarkGray'
    $bootstrapPath = Join-Path $scriptDir 'SingleBootstrap.ps1'
    if (-not (Test-Path -LiteralPath $bootstrapPath)) {
        Say ('  找不到引导脚本：' + $bootstrapPath) 'Red'
        exit 5
    }
    $bootstrapText = [System.IO.File]::ReadAllText($bootstrapPath, [System.Text.Encoding]::UTF8)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($bootstrapText))

    Say '  3) 拼接单文件' 'DarkGray'
    $singlePath = Join-Path $OutDir ('LLMKit-web-single-' + $version + '.cmd')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('@echo off')
    [void]$sb.AppendLine('setlocal')
    [void]$sb.AppendLine('chcp 65001 >nul')
    [void]$sb.AppendLine('set "LLMKIT_SELF=%~f0"')
    [void]$sb.AppendLine('if not defined LLMKIT_HOME set "LLMKIT_HOME=%LOCALAPPDATA%\LLMKit"')
    [void]$sb.AppendLine('set "LLMKIT_HASH=' + $hash8 + '"')
    [void]$sb.AppendLine('set "LLMKIT_ARGS=%*"')
    [void]$sb.AppendLine('where pwsh >nul 2>nul')
    [void]$sb.AppendLine('if %ERRORLEVEL%==0 (')
    [void]$sb.AppendLine('  pwsh -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand ' + $encoded)
    [void]$sb.AppendLine(') else (')
    [void]$sb.AppendLine('  powershell -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand ' + $encoded)
    [void]$sb.AppendLine(')')
    [void]$sb.AppendLine('set RC=%ERRORLEVEL%')
    # 双击运行时留住窗口，让用户看清报错；但 pause 在非交互终端里会一直等下去，
    # 所以给自动化场景（CI、自检）留一个开关跳过它。
    [void]$sb.AppendLine('if %RC% NEQ 0 if not defined LLMKIT_NO_PAUSE pause')
    [void]$sb.AppendLine('exit /b %RC%')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(':LLMKIT-PAYLOAD')
    for ($i = 0; $i -lt $payloadB64.Length; $i += 200) {
        $len = [Math]::Min(200, $payloadB64.Length - $i)
        [void]$sb.AppendLine($payloadB64.Substring($i, $len))
    }
    [System.IO.File]::WriteAllText($singlePath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    $size = (Get-Item -LiteralPath $singlePath).Length
    Say ('  产物：' + $singlePath) 'Green'
    Say ('  大小：' + [math]::Round($size / 1KB, 1) + ' KB（单文件，内嵌全部引擎与配置）') 'DarkGray'
    [void]$results.Add([pscustomobject]@{ tier = 'single'; path = $singlePath; kind = 'cmd'; bytes = $size })

    if ($Tier -eq 'green+single') {
        $bundle = Join-Path $OutDir 'LLMKit'
        if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
        [void](Copy-Payload -Destination $bundle)
        New-WebLauncherCmd -Path (Join-Path $bundle 'LLMKit-web.cmd')
        New-Readme -Path (Join-Path $bundle '使用说明.txt')
        $b2 = (Get-ChildItem -LiteralPath $bundle -Recurse -File | Measure-Object -Property Length -Sum).Sum
        Say ('  另附绿色包：' + $bundle + '（' + [math]::Round($b2 / 1KB, 1) + ' KB）') 'Green'
        [void]$results.Add([pscustomobject]@{ tier = 'green'; path = $bundle; kind = 'folder'; bytes = $b2 })
    }
}   # 注：这里原本是 iexpress 分支，实测不可用已移除（它会把目录结构压平，解出来的包找不到引擎）

# ---------------------------------------------------------------- 汇总
Say ''
Say ('=' * 62) 'DarkGray'
Say '打包完成' 'White'
foreach ($r in $results) {
    Say ('  [' + $r.tier + '] ' + $r.path + '  (' + [math]::Round($r.bytes / 1MB, 2) + ' MB)') 'Green'
}
Say ''
Say '发布前建议手动确认（这些无法自动验证）：' 'Yellow'
Say '  1) 在一台没装过任何工具的干净 Windows 上双击，确认向导能起来' 'DarkGray'
Say '  2) 确认不需要管理员权限（用普通用户账号试）' 'DarkGray'
Say '  3) 走一遍「环境体检」，确认只读步骤确实没改动系统' 'DarkGray'
Say ('=' * 62) 'DarkGray'
Say ''
