#Requires -Version 5.1
<#
    LLMKit 引擎调用层（网页版在用）
    ------------------------------------------------------------------
    这一层只做一件事：**起一个 Setup-LLMKit.ps1 子进程，并把它的输出增量读出来**。
    网页版靠它把引擎的长输出边跑边显示，而不是等整步结束才一次性给出。

    为什么不放在别的模块里：
      * LLMKit.psm1 是检测引擎（纯函数，零副作用），不该有"起进程"；
      * LLMKit.Web.psm1 是 HTTP 服务，管道细节塞进去会让它变厚；
      * 以前这些东西和 WinForms 向导放在同一份 LLMKit.Ui.psm1 里。桌面版删掉之后，
        它们被单独留在这里 —— 因为它们和界面无关，网页版离不开。

    为什么用"重定向到文件 + 增量读"而不是事件/管道（实测结论，别改回去）：
      * add_OutputDataReceived 的回调在 .NET 线程池线程上触发，PowerShell 要在那个
        线程上临时挂运行空间，实测会直接把 powershell.exe -File 起的进程打崩（0xE0434352）；
      * [powershell]::Create() 开运行空间去 ReadLine()，主线程之外读管道会永久阻塞
        （实测子进程 10 秒都不结束，而主线程读同一个进程只要 384ms）。
    重定向到文件只用到"起进程"和"读文件"两个最普通的原语，稳定，而且顺带留下一份
    完整的步骤日志给用户看。
#>

Set-StrictMode -Off

$script:EngineVersion = '0.1.0'

function Get-LLMKitStepStatusFromOutput {
    <#
        从累积输出里判断这一步的结果。
        优先看引擎自己的结论行，而不是靠关键字猜。
    #>
    param([string[]]$Lines)
    $status = 'unknown'
    foreach ($l in @($Lines)) {
        # 这里的每一句都必须对齐引擎真正会打印的文案。
        # 之前只写了"基本可用/存在问题"（那是复检 Format-LLMKitVerification 的措辞），
        # 而 M0 体检 Format-LLMKitReport 说的是"存在可自动处理的警告/存在阻断项"，
        # 结果真实运行时一律被判成 unknown —— 单元测试没发现，是因为用例是我自己编的字符串。
        # 现在两种措辞都认，并且有一条用真实格式化函数产出来测的用例守着。
        if ($l -match '结论：一切正常') { $status = 'ok'; continue }
        if ($l -match '结论：基本可用') { $status = 'warn'; continue }
        if ($l -match '结论：存在可自动处理的警告') { $status = 'warn'; continue }
        if ($l -match '结论：存在阻断项') { $status = 'fail'; continue }
        if ($l -match '结论：存在问题') { $status = 'fail'; continue }
        if ($l -match '演练结束') { if ($status -eq 'unknown') { $status = 'dryrun' } }
    }
    return $status
}

function Start-LLMKitEngineStep {
    <#
        启动 Setup-LLMKit.ps1，并把它的输出重定向到文件，供界面增量读取。

        为什么不用另外两种看起来更"正统"的做法：
          * add_OutputDataReceived 事件：回调在 .NET 线程池线程上触发，PowerShell
            需要在那个线程上临时挂运行空间；实测在 powershell.exe -File 启动的脚本里
            会直接让进程崩溃（未处理异常，退出码 0xE0434352）。
          * [powershell]::Create() 开运行空间去 ReadLine()：运行空间确实起来了，
            但主线程之外读管道会永久阻塞（实测子进程 10 秒都不结束，而主线程读同一个
            进程只要 384ms）。这类环境差异不该赌。
        重定向到文件 + 增量读，只用到"起进程"和"读文件"两个最普通的原语，
        行为稳定，而且顺带留下了一份完整的步骤日志给用户看。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SetupPath,
        [string[]]$ArgumentList = @(),
        [string]$LogDirectory
    )
    if (-not (Test-Path -LiteralPath $SetupPath -PathType Leaf)) {
        throw ('找不到安装脚本：' + $SetupPath)
    }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

    if ([string]::IsNullOrEmpty($LogDirectory)) { $LogDirectory = Join-Path $env:TEMP 'llmkit-ui' }
    if (-not (Test-Path -LiteralPath $LogDirectory)) { [void](New-Item -ItemType Directory -Path $LogDirectory -Force) }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $outFile = Join-Path $LogDirectory ('step-' + $stamp + '.out.log')
    $errFile = Join-Path $LogDirectory ('step-' + $stamp + '.err.log')

    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $SetupPath + '"'
    foreach ($a in @($ArgumentList)) {
        if ([string]::IsNullOrEmpty($a)) { continue }
        if ($a -match '\s') { $argLine += ' "' + $a + '"' } else { $argLine += ' ' + $a }
    }

    $proc = Start-Process -FilePath $psExe -ArgumentList $argLine -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if (-not $proc) { throw '无法启动安装脚本进程。' }

    return [pscustomobject]([ordered]@{
            process     = $proc
            outputFile  = $outFile
            errorFile   = $errFile
            outPosition = 0
            errPosition = 0
            decoder     = (New-Object System.Text.UTF8Encoding($false)).GetDecoder()
            leftover    = ''
            commandLine = ('powershell ' + $argLine)
            startedAt   = (Get-Date)
        })
}

function Read-LlmKitLogDelta {
    <# 从正在被写入的日志文件里取新增内容。用有状态解码器，避免多字节字符被行边界切断 #>
    param([string]$Path, [ref]$Position, $Decoder)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -le $Position.Value) { return '' }
        [void]$fs.Seek($Position.Value, [System.IO.SeekOrigin]::Begin)
        $count = [int]($fs.Length - $Position.Value)
        $buf = New-Object byte[] $count
        $read = $fs.Read($buf, 0, $count)
        $Position.Value = $Position.Value + $read
        if ($read -le 0) { return '' }
        $chars = New-Object char[] ($read + 8)
        $n = $Decoder.GetChars($buf, 0, $read, $chars, 0)
        return (-join $chars[0..($n - 1)])
    } catch {
        return ''
    } finally {
        if ($fs) { try { $fs.Close() } catch { } }
    }
}

function Receive-LLMKitEngineOutput {
    <#
        取这一步新产生的输出行给界面。done 表示进程已退出且日志已读干净，
        此时 exitCode 才可信。
    #>
    param(
        [Parameter(Mandatory = $true)]$Session,
        [int]$MaxLines = 400
    )
    $lines = New-Object System.Collections.ArrayList
    $pos = [ref]$Session.outPosition
    $text = $Session.leftover + (Read-LlmKitLogDelta -Path $Session.outputFile -Position $pos -Decoder $Session.decoder)
    $Session.outPosition = $pos.Value
    $Session.leftover = ''

    if ($text.Length -gt 0) {
        $split = $text -split "`n"
        # 最后一段可能是不完整的行，留到下次再处理
        $Session.leftover = [string]$split[$split.Count - 1]
        for ($i = 0; $i -lt $split.Count - 1; $i++) {
            if ($lines.Count -ge $MaxLines) { break }
            [void]$lines.Add(([string]$split[$i]).TrimEnd("`r"))
        }
    }
    $epos = [ref]$Session.errPosition
    $etext = Read-LlmKitLogDelta -Path $Session.errorFile -Position $epos -Decoder ((New-Object System.Text.UTF8Encoding($false)).GetDecoder())
    $Session.errPosition = $epos.Value
    if ($etext) {
        foreach ($ln in ($etext -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            [void]$lines.Add('[stderr] ' + $ln)
        }
    }

    $done = $false
    $exitCode = $null
    try {
        $proc = $Session.process
        if ($proc.HasExited) {
            # 进程退出后再读一次，把缓冲里剩下的收干净
            Start-Sleep -Milliseconds 120
            $pos2 = [ref]$Session.outPosition
            $tail = Read-LlmKitLogDelta -Path $Session.outputFile -Position $pos2 -Decoder $Session.decoder
            $Session.outPosition = $pos2.Value
            if ($tail) {
                foreach ($ln in (($Session.leftover + $tail) -split "`r?`n")) {
                    if ($ln -ne '') { [void]$lines.Add($ln) }
                }
                $Session.leftover = ''
            } elseif ($Session.leftover -ne '') {
                [void]$lines.Add($Session.leftover)
                $Session.leftover = ''
            }
            $exitCode = $proc.ExitCode
            $done = $true
        }
    } catch { }
    return [pscustomobject]@{ lines = @($lines); done = $done; exitCode = $exitCode }
}

function Stop-LLMKitEngineStep {
    param([Parameter(Mandatory = $true)]$Session)
    try { if ($Session.process -and -not $Session.process.HasExited) { $Session.process.Kill() } } catch { }
    try { if ($Session.process) { $Session.process.Dispose() } } catch { }
}

Export-ModuleMember -Function 'Start-LLMKitEngineStep', 'Receive-LLMKitEngineOutput', 'Stop-LLMKitEngineStep', 'Get-LLMKitStepStatusFromOutput'
