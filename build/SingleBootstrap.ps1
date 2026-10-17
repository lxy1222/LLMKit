# LLMKit 单文件自解压引导脚本
# ------------------------------------------------------------------
# 这个文件不直接被用户运行。Build-Release.ps1 会把它读出来、转成
# UTF-16LE base64，用 powershell -EncodedCommand 塞进生成的 .cmd 里。
#
# 用 -EncodedCommand 而不是把代码直接写进 .cmd：
#   · 完全不用操心 .cmd 与 PowerShell 之间的引号与转义
#   · .cmd 的引导部分保持纯 ASCII，不会因为代码页问题变成乱码
#
# 依赖两个由 .cmd 设置好的环境变量：
#   LLMKIT_SELF  本 .cmd 的完整路径
#   LLMKIT_HASH  载荷指纹（用于决定释放目录，同一份载荷不重复释放）
#   LLMKIT_ARGS  命令行参数（透传给网页版入口）
$ErrorActionPreference = 'Stop'
# 压掉进度记录：首次导入模块时会冒出 "Preparing modules for first use."，
# 在控制台里是多余噪音，stderr 被重定向时还会变成一串 CLIXML。
$ProgressPreference = 'SilentlyContinue'
try {
    $self = $env:LLMKIT_SELF
    if ([string]::IsNullOrEmpty($self) -or -not (Test-Path -LiteralPath $self)) {
        throw '读不到自身路径（LLMKIT_SELF 未设置）。'
    }
    $hash = $env:LLMKIT_HASH
    if ([string]::IsNullOrEmpty($hash)) { $hash = 'default' }

    # 释放根目录可用 LLMKIT_HOME 覆盖：默认 %LOCALAPPDATA%\LLMKit，
    # 改成 U 盘或任意可写目录就能变成真正的便携模式（换台电脑插上就能用）。
    $home_ = $env:LLMKIT_HOME
    if ([string]::IsNullOrEmpty($home_)) { $home_ = Join-Path $env:LOCALAPPDATA 'LLMKit' }
    $dest = Join-Path $home_ ('portable\' + $hash)
    # 解压之后启动的是网页版入口 —— 桌面版已经删掉，只剩浏览器这一套界面。
    $entry = Join-Path $dest 'src\ps\Start-LLMKitWeb.ps1'

    if (-not (Test-Path -LiteralPath $entry)) {
        # 找载荷标记行，后面全是 base64
        $lines = [System.IO.File]::ReadAllLines($self, [System.Text.Encoding]::UTF8)
        $marker = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq ':LLMKIT-PAYLOAD') { $marker = $i; break }
        }
        if ($marker -lt 0) {
            throw '在文件里找不到载荷标记 :LLMKIT-PAYLOAD，文件可能被改坏了。'
        }
        $b64 = ($lines[($marker + 1)..($lines.Count - 1)] -join '').Trim()
        if ([string]::IsNullOrEmpty($b64)) { throw '载荷是空的。' }

        $bytes = [Convert]::FromBase64String($b64)
        $tmp = Join-Path $env:TEMP ('llmkit-payload-' + $hash + '.zip')
        [System.IO.File]::WriteAllBytes($tmp, $bytes)

        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        [void](New-Item -ItemType Directory -Path $dest -Force)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($tmp, $dest)
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-Host ('已释放到 ' + $dest) -ForegroundColor DarkGray
    }

    if (-not (Test-Path -LiteralPath $entry)) {
        throw ('释放完成，但没有找到网页版入口：' + $entry)
    }

    # 参数透传：让 -SelfTest 之类的开关也能用在这个单文件上
    # 必须整体套在 @() 里：只给一个参数时 "@(...) | Where-Object" 会把结果退化成字符串，
    # 之后 $extra[0] 取到的是字符 '-'，子进程会收到一个光秃秃的减号、PowerShell 参数绑定直接崩。
    # (单文件 -SelfTest 就是这么崩的：退出码 -532462766，报 name 无效。)
    $extra = @()
    if (-not [string]::IsNullOrEmpty($env:LLMKIT_ARGS)) {
        $extra = @(@($env:LLMKIT_ARGS -split '\s+') | Where-Object { $_ })
    }

    # --log <路径>：和单文件 exe 保持一致的写法。exe 是无控制台的 winexe，必须靠它留证据；
    # .cmd 有控制台，但两种启动器对外都发布，参数不该一个有一个没有 —— 用户照文档写
    # 却报 "找不到参数 -log"，那是我们自己的不一致。
    $logPath = ''
    $forward = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $extra.Count; $i++) {
        if ($extra[$i] -eq '--log' -or $extra[$i] -eq '-log') {
            if ($i + 1 -lt $extra.Count) { $logPath = $extra[$i + 1]; $i++ }
            continue
        }
        $forward.Add([string]$extra[$i])
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
    # -OutputFormat Text 是必要的：默认的 XML 序列化会把 stderr 包成 CLIXML，
    # 日志里就会混进一堆 <Objs> 标签。
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-OutputFormat', 'Text', '-File', $entry) + @($forward)
    # 直接用调用操作符而不是 Start-Process -Wait -PassThru：
    # 后者在本机取退出码时会抛 "Access is denied"，把成功的运行也报成失败（实测）。
    # 我们本来就在 .cmd 的控制台里，直接调用不会多弹窗口，输出也能实时透传。
    if ([string]::IsNullOrEmpty($logPath)) {
        & $psExe @argList
    } else {
        $logDir = Split-Path -Parent $logPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
        $captured = New-Object System.Collections.Generic.List[string]
        & $psExe @argList 2>&1 | ForEach-Object {
            $s = [string]$_
            $captured.Add($s)
            Write-Host $s
        }
        # 显式 UTF-8 带 BOM：日志里有中文，用默认编码存出来在记事本里会是乱码。
        [System.IO.File]::WriteAllLines($logPath, @($captured), (New-Object System.Text.UTF8Encoding($true)))
    }
    exit $LASTEXITCODE
} catch {
    Write-Host ''
    Write-Host ('启动失败：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    Write-Host '应急办法：把本文件复制一份、改名为 .zip，用解压软件打开，' -ForegroundColor Yellow
    Write-Host '取出里面的 src 与 config 目录，然后手动运行：' -ForegroundColor Yellow
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File src\ps\Start-LLMKitWeb.ps1' -ForegroundColor Yellow
    exit 1
}
