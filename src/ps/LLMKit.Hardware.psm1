#Requires -Version 5.1
<#
.SYNOPSIS
    LLMKit 本地模型：硬件探测 + 模型适配判定

.DESCRIPTION
    只读模块。回答一个问题："这台机器跑得动多大参数的本地模型？"

    为什么单独一个模块：判定必须是**纯函数**（硬件数据 + 模型数据 → 结论），
    否则单测只能靠"本机刚好有什么"，换台机器就失效。

    实测踩到的三个坑，都写进实现里了：
      · Win32_VideoController.AdapterRAM 是 32 位字段，超过 4 GB 一律报 4095 MB。
        真实显存要读注册表 HardwareInformation.qwMemorySize（REG_QWORD）。
      · Get-CimInstance 在受限环境下可能直接"拒绝访问"（本机实测如此），
        所以内存探测必须允许失败并如实标注"读不到"，不能瞎填 0 当结论。
      · 模型目录不一定是 %USERPROFILE%\.ollama —— 用户可能设了 OLLAMA_MODELS
        （本机就设在 E: 盘）。磁盘余量要按它所在的盘算。
#>

# Ollama 的默认端口。这是**产品协议常量**，不是本机信息（每台机器都一样）。
# 只在这里写一次：要改就改这一处，别在十几处 URL 里各写一遍。
$script:OllamaPort = 11434
# 默认上下文：Ollama 自己的默认只有 4096，且超出会静默截断，所以我们统一抬到 32K。
# 真正生效的值优先从 config/models.json 的 contextHint 读，这里只是兜底。
$script:DefaultContextLength = 32768
$script:DisplayClassPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'

function Get-LLMKitOllamaModelRoot {
    <#
        模型目录：优先 OLLAMA_MODELS（用户可能改到别的盘），否则默认目录。
        只做路径推断，不创建、不读内容。
    #>
    $root = $env:OLLAMA_MODELS
    if ([string]::IsNullOrWhiteSpace($root)) { $root = Join-Path $env:USERPROFILE '.ollama\models' }
    return $root
}

function Get-LLMKitDiskFreeGB {
    <#
        某路径所在磁盘的剩余空间。用 DriveInfo 而不是 CIM/WMI ——
        WMI 在受限环境里可能被拒，DriveInfo 只读卷信息，稳。
        路径不存在时回退到系统盘。
    #>
    param([string]$Path)

    $target = $Path
    if ([string]::IsNullOrWhiteSpace($target)) { $target = $env:SystemDrive + '\' }
    try {
        $full = [System.IO.Path]::GetFullPath($target)
        $root = [System.IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrEmpty($root)) { $root = $env:SystemDrive + '\' }
        $di = New-Object System.IO.DriveInfo($root)
        if ($di.IsReady) { return [math]::Round($di.AvailableFreeSpace / 1GB, 1) }
    } catch { }
    return 0
}

function Get-LLMKitGpuInfo {
    <#
        显卡与显存。真显存读注册表 qwMemorySize；读不到才退回 AdapterRAM，
        并且把"读数可疑"如实标出来 —— 4 GB 的卡和 24 GB 的卡不该被判成一样。
    #>
    $gpus = @()
    $keys = @(Get-ChildItem -LiteralPath $script:DisplayClassPath -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' })
    foreach ($k in $keys) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $desc = [string]$p.DriverDesc
        if ([string]::IsNullOrWhiteSpace($desc)) { continue }
        # 基础显示适配器 / 远程桌面适配器不是真显卡，别拿它算显存
        if ($desc -match 'Basic Display|Remote Display|Remote Desktop|Virtual') { continue }

        $vramGB = 0
        $source = 'none'
        $suspicious = $false
        $qw = $p.'HardwareInformation.qwMemorySize'
        $ms = $p.'HardwareInformation.MemorySize'
        if ($qw -and [double]$qw -gt 0) {
            $vramGB = [math]::Round([double]$qw / 1GB, 1)
            $source = 'registry-qw'
        } elseif ($ms -and [double]$ms -gt 0) {
            $vramGB = [math]::Round([double]$ms / 1GB, 1)
            $source = 'registry'
        } elseif ($p.AdapterRAM -and [double]$p.AdapterRAM -gt 0) {
            $vramGB = [math]::Round([double]$p.AdapterRAM / 1GB, 1)
            $source = 'adapterram'
            # 4095 MB 是 32 位字段的上限，见到它基本可以确定真实显存更大
            if ([double]$p.AdapterRAM -ge 4290772992) { $suspicious = $true }
        }
        $gpus += [pscustomobject]@{
            name       = $desc
            vramGB     = $vramGB
            source     = $source
            suspicious = $suspicious
        }
    }
    return @($gpus)
}

function Get-LLMKitHardware {
    <#
        汇总本机硬件。所有探测都允许失败：失败就如实标"读不到"，
        绝不把未知当 0 导致后面误判"你跑不动"。
    #>
    $gpus = @(Get-LLMKitGpuInfo)
    $maxVram = 0
    foreach ($g in $gpus) { if ($g.vramGB -gt $maxVram) { $maxVram = $g.vramGB } }
    $vramSuspicious = @($gpus | Where-Object { $_.suspicious }).Count -gt 0

    $ramGB = 0
    $ramSource = 'unavailable'
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os -and $os.TotalVisibleMemorySize -gt 0) {
            $ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            $ramSource = 'cim'
        }
    } catch { }

    $cpuName = ''
    $cpuCores = 0
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu) { $cpuName = [string]$cpu.Name; $cpuCores = [int]$cpu.NumberOfCores }
    } catch { }

    $modelRoot = Get-LLMKitOllamaModelRoot
    $diskFreeGB = Get-LLMKitDiskFreeGB -Path $modelRoot

    return [pscustomobject]@{
        gpus            = $gpus
        maxVramGB       = $maxVram
        vramSource      = if ($gpus.Count -gt 0) { $gpus[0].source } else { 'none' }
        vramSuspicious  = $vramSuspicious
        ramGB           = $ramGB
        ramSource       = $ramSource
        cpuName         = $cpuName
        cpuCores        = $cpuCores
        modelRoot       = $modelRoot
        diskFreeGB      = $diskFreeGB
    }
}

function Get-LLMKitModelVerdict {
    <#
        纯函数：硬件 + 一个模型 → 结论。不探测、不 IO，便于单测。

        结论三档：
          ok    显存够（模型全量进显存，速度正常）
          slow  显存不够但内存够（会退到 CPU/混合，能跑但慢）
          no    装不下（显存与内存都不够，或磁盘空间不足）
          unknown 关键读数读不到（内存读不到时无法断言"跑不动"）

        磁盘优先判：空间不够就一定是 no，不管显存多大。
    #>
    param(
        [Parameter(Mandatory = $true)]$Hardware,
        [Parameter(Mandatory = $true)]$Model
    )

    $sizeGB = [double]$Model.sizeGB
    $needVram = [double]$Model.minVramGB
    $needRam = if ($null -ne $Model.minRamGB) { [double]$Model.minRamGB } else { 0 }
    $diskFree = if ($null -ne $Hardware.diskFreeGB) { [double]$Hardware.diskFreeGB } else { 0 }
    $vram = if ($null -ne $Hardware.maxVramGB) { [double]$Hardware.maxVramGB } else { 0 }
    $ram = if ($null -ne $Hardware.ramGB) { [double]$Hardware.ramGB } else { 0 }

    # 磁盘：模型 + 临时空间，按 1.5 倍预检
    $needDisk = [math]::Round($sizeGB * 1.5, 1)
    if ($diskFree -gt 0 -and $diskFree -lt $needDisk) {
        return [pscustomobject]@{
            verdict = 'no'
            reason  = ('磁盘不够：需要约 ' + $needDisk + ' GB，' + $Hardware.modelRoot + ' 所在盘只剩 ' + $diskFree + ' GB')
        }
    }

    if ($vram -gt 0 -and $vram -ge $needVram) {
        $extra = ''
        if ($Hardware.vramSuspicious) { $extra = '（显存读数是 4 GB 上限的截断值，实际可能更大）' }
        return [pscustomobject]@{
            verdict = 'ok'
            reason  = ('显存 ' + $vram + ' GB ≥ 需要的 ' + $needVram + ' GB，可以全量放进显卡' + $extra)
        }
    }

    if ($ram -gt 0 -and $ram -ge $needRam) {
        return [pscustomobject]@{
            verdict = 'slow'
            reason  = ('显存 ' + $vram + ' GB 不够（要 ' + $needVram + ' GB），但内存够，会退到 CPU/混合推理 —— 能跑，速度明显变慢')
        }
    }

    if ($ram -le 0) {
        return [pscustomobject]@{
            verdict = 'unknown'
            reason  = ('显存 ' + $vram + ' GB 不够（要 ' + $needVram + ' GB），内存读数又拿不到，无法断定能不能跑')
        }
    }

    return [pscustomobject]@{
        verdict = 'no'
        reason  = ('显存 ' + $vram + ' GB（要 ' + $needVram + ' GB）、内存 ' + $ram + ' GB（要 ' + $needRam + ' GB）都不够')
    }
}

function Get-LLMKitModelCatalog {
    <#
        读 config/models.json。文件缺失或结构不对时抛错（宁可报错，也不静默少几个模型）。
    #>
    param([Parameter(Mandatory = $true)][string]$ConfigRoot)

    $path = Join-Path $ConfigRoot 'config\models.json'
    if (-not (Test-Path -LiteralPath $path)) { throw ('找不到模型目录配置：' + $path) }
    $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($data.models)
}

function Get-LLMKitModelGroupCatalog {
    <#
        读 config/models.json 的 groups 段。文件里没有 groups 时返回空数组，
        调用方按"全部归到未分组"处理 —— 旧配置不该让整页炸掉。
    #>
    param([Parameter(Mandatory = $true)][string]$ConfigRoot)

    $path = Join-Path $ConfigRoot 'config\models.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $data.PSObject.Properties['groups']) { return @() }
        return @($data.groups)
    } catch { return @() }
}
function Get-LLMKitOllamaStatus {
    <#
        运行时状态：装了没、什么版本、服务在不在跑、装了什么模型。
        全部只读；任何一步失败都降级成"未知"而不是抛错 —— 这个页面必须能打开。
    #>
    $exe = ''
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path $env:ProgramFiles 'Ollama\ollama.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { $exe = $c; break } }
    if ([string]::IsNullOrEmpty($exe)) {
        $cmd = Get-Command ollama -ErrorAction SilentlyContinue
        if ($cmd) { $exe = $cmd.Source }
    }

    $installed = -not [string]::IsNullOrEmpty($exe)
    $version = ''
    if ($installed) {
        try {
            $out = & $exe --version 2>&1 | Out-String
            $m = [regex]::Match($out, '(\d+\.\d+\.\d+)')
            if ($m.Success) { $version = $m.Groups[1].Value }
        } catch { }
    }

    $running = $false
    $serverVersion = ''
    try {
        $v = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $script:OllamaPort + '/api/version') -TimeoutSec 2 -ErrorAction Stop
        $running = $true
        $serverVersion = [string]$v.version
    } catch { }

    $models = @()
    if ($running) {
        try {
            $ps = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $script:OllamaPort + '/api/tags') -TimeoutSec 4 -ErrorAction Stop
            foreach ($m in @($ps.models)) {
                $sizeGB = 0
                if ($null -ne $m.size) { $sizeGB = [math]::Round([double]$m.size / 1GB, 2) }
                $models += [pscustomobject]@{
                    name     = [string]$m.name
                    sizeGB   = $sizeGB
                    modified = [string]$m.modified_at
                }
            }
        } catch { }
    }

    return [pscustomobject]@{
        installed        = $installed
        exePath          = $exe
        version          = $version
        running          = $running
        serverVersion    = $serverVersion
        baseUrl          = ('http://127.0.0.1:' + $script:OllamaPort + '/v1')
        modelRoot        = Get-LLMKitOllamaModelRoot
        models           = @($models)
    }
}

function Resolve-LLMKitOllamaExe {
    <#
        Ollama 可执行文件位置。官方安装器装在 %LOCALAPPDATA%\Programs\Ollama，不需要管理员。
    #>
    foreach ($c in @((Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'), (Join-Path $env:ProgramFiles 'Ollama\ollama.exe'))) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    $cmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ''
}

function Get-LLMKitDiskGate {
    <#
        纯计算：这么大的模型，这点磁盘余量够不够。不探测、不 IO，便于单测。
        按 1.5 倍算 —— 下载中的临时分片、换量化重下都会并存，
        按 1 倍算的话"刚好够"的用户一定会下到一半失败。
    #>
    param(
        [Parameter(Mandatory = $true)][double]$SizeGB,
        [Parameter(Mandatory = $true)][double]$DiskFreeGB,
        [string]$ModelRoot = ''
    )

    $needDiskGB = [math]::Round($SizeGB * 1.5, 1)
    $ok = $true
    $reason = ''
    if ($DiskFreeGB -gt 0 -and $DiskFreeGB -lt $needDiskGB) {
        $ok = $false
        $place = if ([string]::IsNullOrWhiteSpace($ModelRoot)) { '模型目录' } else { $ModelRoot }
        $reason = ('磁盘不够：需要约 ' + $needDiskGB + ' GB（含临时空间），' + $place + ' 所在盘只剩 ' + $DiskFreeGB + ' GB，还差 ' + [math]::Round($needDiskGB - $DiskFreeGB, 1) + ' GB')
    }
    return [pscustomobject]@{ ok = $ok; needDiskGB = $needDiskGB; reason = $reason }
}
function Get-LLMKitModelPullPlan {
    <#
        纯计算：这个模型要下多大、下到哪、磁盘够不够。不联网、不写盘。
        空间按 1.5 倍算 —— 下载过程中的临时分片、换个量化重下都会并存，
        按 1 倍算的话"刚好够"的用户一定会下一半失败。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ConfigRoot,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $catalog = @(Get-LLMKitModelCatalog -ConfigRoot $ConfigRoot)
    $hit = @($catalog | Where-Object { [string](Get-ObjectPropSafe $_ 'ollamaTag') -eq $Tag })
    if ($hit.Count -eq 0) { throw ('模型目录里没有这个模型：' + $Tag) }
    $m = $hit[0]

    $sizeGB = [double]$m.sizeGB
    $modelRoot = Get-LLMKitOllamaModelRoot
    $diskFreeGB = Get-LLMKitDiskFreeGB -Path $modelRoot
    $gate = Get-LLMKitDiskGate -SizeGB $sizeGB -DiskFreeGB $diskFreeGB -ModelRoot $modelRoot
    $needDiskGB = $gate.needDiskGB
    $ok = $gate.ok
    $reason = $gate.reason

    return [pscustomobject]@{
        tag         = $Tag
        name        = [string]$m.name
        sizeGB      = $sizeGB
        needDiskGB  = $needDiskGB
        diskFreeGB  = $diskFreeGB
        modelRoot   = $modelRoot
        ok          = $ok
        reason      = $reason
    }
}

function Get-ObjectPropSafe {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Test-LLMKitOllamaRunning {
    try {
        [void](Invoke-RestMethod -Uri ('http://127.0.0.1:' + $script:OllamaPort + '/api/version') -TimeoutSec 2 -ErrorAction Stop)
        return $true
    } catch { return $false }
}

function Invoke-LLMKitOllamaNdjson {
    <#
        调 Ollama 的流式接口（/api/pull 会一行一行吐进度），把每一行交给回调。
        为什么不用 ollama.exe pull：它把进度写成 \r 刷新的 ANSI 序列，
        重定向到文件后是一坨控制字符；HTTP 这边每行是干净的 JSON，进度能算准。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Body,
        [scriptblock]$OnLine
    )

    if (-not (Test-LLMKitOllamaRunning)) {
        throw 'Ollama 服务没在跑。先启动 Ollama（托盘图标），再来下载模型。'
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 6 -Compress))
    $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:' + $script:OllamaPort + $Path)
    $req.Method = 'POST'
    $req.ContentType = 'application/json'
    $req.ContentLength = $bytes.Length
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 60000
    $rs = $req.GetRequestStream()
    $rs.Write($bytes, 0, $bytes.Length)
    $rs.Dispose()

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $detail = ''
        try {
            $er = $_.Exception.Response
            if ($er) {
                $rd = New-Object System.IO.StreamReader($er.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $detail = $rd.ReadToEnd()
                $rd.Dispose()
            }
        } catch { }
        if ([string]::IsNullOrWhiteSpace($detail)) { throw $_.Exception.Message }
        try {
            $o = $detail | ConvertFrom-Json
            if ($o.error) { throw ('Ollama 报错：' + [string]$o.error) }
        } catch [System.Management.Automation.RuntimeException] {
            throw ('Ollama 报错：' + $detail)
        }
        throw ('Ollama 报错：' + $detail)
    }

    # 分块读 + 读超时，而不是 StreamReader.ReadLine：
    # 实测踩过 —— 下载到 100% 之后 Ollama 还要算 sha256、写 manifest（几分钟），
    # 那段期间它不发任何数据也不关连接，ReadLine 会一直阻塞，界面上看起来就"卡住了"。
    # 这里把"一段时间没数据"当成收尾信号，交给调用方去回查真实状态。
    $stream = $resp.GetResponseStream()
    try { $stream.ReadTimeout = 30000 } catch { }
    $buf = New-Object byte[] 16384
    $pending = New-Object System.Collections.Generic.List[byte]
    try {
        while ($true) {
            $read = 0
            try { $read = $stream.Read($buf, 0, $buf.Length) } catch { break }
            if ($read -le 0) { break }
            for ($i = 0; $i -lt $read; $i++) { $pending.Add($buf[$i]) }

            # 只处理"到换行为止"的完整行：这样按 UTF-8 解码不会切到半个汉字
            $lastNl = -1
            for ($i = $pending.Count - 1; $i -ge 0; $i--) { if ($pending[$i] -eq 10) { $lastNl = $i; break } }
            if ($lastNl -lt 0) { continue }
            $chunk = New-Object byte[] ($lastNl + 1)
            $pending.CopyTo(0, $chunk, 0, $lastNl + 1)
            $pending.RemoveRange(0, $lastNl + 1)
            $text = [System.Text.Encoding]::UTF8.GetString($chunk)
            foreach ($line in ($text -split "`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $obj = $null
                try { $obj = $line | ConvertFrom-Json } catch { continue }
                if ($obj.PSObject.Properties['error'] -and $obj.error) { throw ('Ollama 报错：' + [string]$obj.error) }
                if ($OnLine) { & $OnLine $obj }
            }
        }
    } finally {
        try { $stream.Dispose() } catch { }
        if ($resp) { $resp.Dispose() }
    }
}

function Invoke-LLMKitModelPull {
    <#
        下载一个模型。进度按 10% 报一行，最后再核对一次"目录里真的有它"。
        反正在下载前再做一次空间预检 —— 服务层那次是给界面看的，这次是给自己兜底：
        命令可以被用户手动复制去跑，中途换了盘也不该把磁盘撑爆。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ConfigRoot,
        [Parameter(Mandatory = $true)][string]$Tag,
        [scriptblock]$OnLine
    )

    $plan = Get-LLMKitModelPullPlan -ConfigRoot $ConfigRoot -Tag $Tag
    if (-not $plan.ok) { throw $plan.reason }
    if ($OnLine) {
        & $OnLine ('准备下载 ' + $plan.name + '（' + $plan.tag + '）：约 ' + $plan.sizeGB + ' GB，磁盘需要 ' + $plan.needDiskGB + ' GB，当前剩 ' + $plan.diskFreeGB + ' GB')
    }

    # 回调必须走 $script: —— PowerShell 的 scriptblock 是**动态作用域**：
    # 在外层函数里定义的 $OnLine，到了模块函数里执行时按调用方作用域找，找不到就静默变 $null，
    # 于是"下载在跑、进度一行不出"。第一次实现就踩了这个坑（Ollama 日志里在下载，界面上什么都没）。
    $script:pullEmit = $OnLine
    $cb = {
        param($o)
        $status = [string](Get-ObjectPropSafe $o 'status')
        $total = Get-ObjectPropSafe $o 'total'
        $completed = Get-ObjectPropSafe $o 'completed'
        if ($null -ne $total -and [double]$total -gt 0) {
            $pct = [int]([double]$completed * 100 / [double]$total)
            $bucket = [int]([math]::Floor($pct / 10) * 10)
            if ($bucket -ne $script:pullBucket) {
                $script:pullBucket = $bucket
                $gbDone = [math]::Round([double]$completed / 1GB, 2)
                $gbAll = [math]::Round([double]$total / 1GB, 2)
                if ($script:pullEmit) { & $script:pullEmit ('  ' + $status + '：' + $pct + '%（' + $gbDone + '/' + $gbAll + ' GB）') }
            }
        } elseif ($status) {
            if ($script:pullEmit) { & $script:pullEmit ('  ' + $status) }
        }
        if ($status -eq 'success') { $script:pullSuccess = $true }
    }

    $script:pullBucket = -100
    $script:pullSuccess = $false
    Invoke-LLMKitOllamaNdjson -Path '/api/pull' -Body @{ model = $Tag; stream = $true } -OnLine $cb

    # 不信任"接口说成功了"：回查已装列表。
    # 但要**轮询**等：Ollama 下完数据后还要算 sha256、写 manifest（实测要几分钟），
    # 这段时间里模型还不在列表里 —— 一次性回查会把它误判成下载失败。
    $present = $false
    $deadline = (Get-Date).AddSeconds(300)
    $waited = 0
    while ((Get-Date) -lt $deadline) {
        $status = Get-LLMKitOllamaStatus
        if (@($status.models | Where-Object { [string]$_.name -eq $Tag }).Count -gt 0) { $present = $true; break }
        if ($waited -eq 0 -and $script:pullEmit) { & $script:pullEmit '  下载数据已到齐，等 Ollama 算校验和写清单（可能要几分钟）' }
        $waited++
        Start-Sleep -Seconds 3
    }
    if (-not $present) { throw ('下载数据收完了，但 5 分钟内都没在已装列表里看到 ' + $Tag + '；请到 Ollama 里看一眼，或重试一次') }
    if ($OnLine) { & $OnLine ('已装好：' + $Tag) }
    return [pscustomobject]@{ tag = $Tag; sizeGB = $plan.sizeGB; verified = $true }
}

function Invoke-LLMKitModelRemove {
    <#
        删除一个本地模型。**这一步会真的删文件**（用户已确认过这条规则）：
        删除前把"删了什么、多大、怎么装回来"写进清单，删完再核对一次确实没了。

        为什么不像别的动作那样"只搬不删"：一个模型 3–18 GB，
        搬到备份区很可能直接把磁盘撑爆 —— 那不叫安全，叫另一种事故。
        所以这里的安全性来自"可重下 + 有账可查"，而不是"文件还在"。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [string]$StateDir = '',
        [scriptblock]$OnLine
    )

    if (-not (Test-LLMKitOllamaRunning)) { throw 'Ollama 服务没在跑，无法删除模型。先启动 Ollama。' }

    $before = Get-LLMKitOllamaStatus
    $hit = @($before.models | Where-Object { [string]$_.name -eq $Tag })
    if ($hit.Count -eq 0) { throw ('没有装这个模型：' + $Tag) }
    $sizeGB = [double]$hit[0].sizeGB

    if ($OnLine) { & $OnLine ('准备删除 ' + $Tag + '（' + $sizeGB + ' GB）；删完可以用 ollama pull ' + $Tag + ' 重新装回来') }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ model = $Tag } | ConvertTo-Json -Compress))
    try {
        [void](Invoke-WebRequest -Uri ('http://127.0.0.1:' + $script:OllamaPort + '/api/delete') -Method Delete -Body $bytes -ContentType 'application/json' -UseBasicParsing -TimeoutSec 120)
    } catch {
        throw ('删除失败：' + $_.Exception.Message)
    }

    $after = Get-LLMKitOllamaStatus
    $still = @($after.models | Where-Object { [string]$_.name -eq $Tag }).Count -gt 0
    if ($still) { throw ('删了但列表里还有 ' + $Tag + '，请到 Ollama 里手动确认') }

    # 记账：没有备份，但有据可查、可重下
    if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
        try {
            if (-not (Test-Path -LiteralPath $StateDir)) { [void](New-Item -ItemType Directory -Path $StateDir -Force) }
            $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + "  已删除模型 " + $Tag + "（" + $sizeGB + " GB）；恢复：ollama pull " + $Tag
            Add-Content -LiteralPath (Join-Path $StateDir 'model-removals.log') -Value $line -Encoding UTF8
        } catch { }
    }

    if ($OnLine) { & $OnLine ('已删除 ' + $Tag + '，释放约 ' + $sizeGB + ' GB') }
    return [pscustomobject]@{ tag = $Tag; sizeGB = $sizeGB; verified = $true }
}
function Test-LLMKitLocalEndpoint {
    <#
        工具调用自检：拿一个本地模型发一条**带 tools** 的请求，看它是不是真的
        返回结构化 tool_calls。

        为什么必须有这一条：模型卡上写着 tools 不代表它会用。实测 deepseek-r1:7b
        在同样请求下只把调用当普通文本吐出来，agent 于是原地打转、还不报错。
        这一项是"能不能拿去跑智能体"的唯一判据。

        只读：不下载、不改配置。服务没跑/没装模型时给结论，不抛异常（页面要能打开）。
    #>
    param(
        [string]$Tag = '',
        [int]$ContextLength = $script:DefaultContextLength
    )

    if (-not (Test-LLMKitOllamaRunning)) {
        return [pscustomobject]@{ ok = $false; verdict = 'no-service'; model = $Tag; toolName = ''; toolArgs = ''; detail = 'Ollama 服务没在跑。先启动 Ollama（托盘图标），再自检。' }
    }

    $status = Get-LLMKitOllamaStatus
    $models = @($status.models)
    if ($models.Count -eq 0) {
        return [pscustomobject]@{ ok = $false; verdict = 'no-model'; model = $Tag; toolName = ''; toolArgs = ''; detail = '一个本地模型都没装。先在「本地模型」页下载一档，再来自检。' }
    }

    $target = $Tag
    if ([string]::IsNullOrWhiteSpace($target)) { $target = [string]$models[0].name }
    $hit = @($models | Where-Object { [string]$_.name -eq $target })
    if ($hit.Count -eq 0) {
        return [pscustomobject]@{ ok = $false; verdict = 'no-model'; model = $target; toolName = ''; toolArgs = ''; detail = ('没装这个模型：' + $target + '。先下载它，或者换一个已装的再来。') }
    }

    $tools = @(@{
            type     = 'function'
            function = @{
                name        = 'get_weather'
                description = 'Get current weather for a city'
                parameters  = @{ type = 'object'; properties = @{ city = @{ type = 'string' } }; required = @('city') }
            }
        })
    $body = @{
        model    = $target
        messages = @(@{ role = 'user'; content = '北京现在天气怎么样？请调用 get_weather 工具查询。' })
        tools    = $tools
        stream   = $false
        options  = @{ num_ctx = $ContextLength; num_predict = 256 }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 10))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $script:OllamaPort + '/v1/chat/completions') -Method Post -Body $bytes `
            -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 600
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ ok = $false; verdict = 'error'; model = $target; toolName = ''; toolArgs = ''; detail = ('请求失败：' + $_.Exception.Message) }
    }
    $sw.Stop()

    $json = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    $msg = @($json.choices)[0].message
    $calls = @($msg.tool_calls | Where-Object { $_ })
    if ($calls.Count -gt 0) {
        $name = [string]$calls[0].function.name
        $argsText = [string]$calls[0].function.arguments
        return [pscustomobject]@{
            ok = $true; verdict = 'ok'; model = $target; toolName = $name; toolArgs = $argsText
            detail = ('它会用工具：返回了结构化 tool_calls（' + $name + '），用时 ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + ' 秒。可以拿去接智能体。')
        }
    }

    $text = [string]$msg.content
    if ($text.Length -gt 120) { $text = $text.Substring(0, 120) + '…' }
    return [pscustomobject]@{
        ok = $false; verdict = 'no-tool-calls'; model = $target; toolName = ''; toolArgs = ''
        detail = ('它把工具调用当成了普通文本，没有返回 tool_calls。别拿这个模型跑智能体。它回的是：' + $text)
    }
}
function Get-LLMKitOllamaRootInfo {
    <#
        模型目录到底在哪、为什么在那。
        用户的 OLLAMA_MODELS 可以指到任意盘（本机就指到了 E 盘），
        界面必须把这个位置标出来 —— 否则用户看到 "C 盘满了" 根本不知道模型在 E 盘。
    #>
    $envValue = $env:OLLAMA_MODELS
    if ([string]::IsNullOrWhiteSpace($envValue)) { $envValue = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User') }
    $source = 'default'
    if (-not [string]::IsNullOrWhiteSpace($envValue)) { $source = 'OLLAMA_MODELS' }
    $root = Get-LLMKitOllamaModelRoot
    $exe = Resolve-LLMKitOllamaExe
    $installDir = ''
    if (-not [string]::IsNullOrWhiteSpace($exe)) { $installDir = Split-Path -Parent $exe }
    return [pscustomobject]@{
        modelRoot    = $root
        modelRootEnv = [string]$envValue
        modelRootSource = $source
        isDefaultRoot = ($source -eq 'default')
        installDir   = $installDir
        exePath      = $exe
    }
}

function Get-LLMKitOllamaManifestInfo {
    <#
        从清单读某个模型的真实体积与分片。
        为什么不用 list / ps 的数字：实测 gemma4:26b 的 ollama ps 报 1.3 GB，
        清单里实际 17.33 GB —— 差一个数量级，拿去算磁盘会让用户白等。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ModelRoot,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $result = [pscustomobject]@{
        tag = $Tag; found = $false; sizeGB = 0; layerCount = 0
        manifestPath = ''; blobsDir = ''; missingBlobs = @(); verified = $false
    }
    try {
        $name = $Tag
        $sizeTag = 'latest'
        if ($Tag.Contains(':')) {
            $idx = $Tag.LastIndexOf(':')
            $name = $Tag.Substring(0, $idx)
            $sizeTag = $Tag.Substring($idx + 1)
        }
        # ollama 的清单目录：manifests/<registry>/<namespace>/<name>/<tag>
        $manifests = Join-Path $ModelRoot 'manifests'
        if (-not (Test-Path -LiteralPath $manifests)) { return $result }
        $hits = @(Get-ChildItem -LiteralPath $manifests -Recurse -File -Filter $sizeTag -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -eq $name })
        if ($hits.Count -eq 0) { return $result }
        $manifest = $hits[0]
        $json = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $blobDir = Join-Path $ModelRoot 'blobs'
        $total = 0
        $layers = 0
        $missing = New-Object System.Collections.ArrayList
        foreach ($layer in @($json.layers)) {
            $digest = [string](Get-ObjectPropSafe $layer 'digest')
            if ([string]::IsNullOrWhiteSpace($digest)) { continue }
            $file = Join-Path $blobDir ('sha256-' + $digest.Replace('sha256:', ''))
            if (Test-Path -LiteralPath $file) { $total += (Get-Item -LiteralPath $file).Length }
            else { [void]$missing.Add((Split-Path $file -Leaf)) }
            $layers++
        }
        return [pscustomobject]@{
            tag          = $Tag
            found        = $true
            sizeGB       = [math]::Round($total / 1GB, 2)
            layerCount   = $layers
            manifestPath = $manifest.FullName
            blobsDir     = $blobDir
            missingBlobs = @($missing)
            # 核实：清单在、分片齐，才算"这套文件真的在这个目录里"
            verified     = ($missing.Count -eq 0)
        }
    } catch {
        return $result
    }
}

function Get-LLMKitModelLocationRoots {
    <#
        模型可能落在哪些目录。Ollama 报的不一定对（用户可能改过 OLLAMA_MODELS、
        也可能改完没重启），所以定位要**按文件系统核实**，而不是只信环境变量。
        顺序：环境变量指向的 → 用户级注册表里的 → 默认目录。
    #>
    $roots = New-Object System.Collections.ArrayList
    foreach ($candidate in @(
            $env:OLLAMA_MODELS,
            [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User'),
            (Join-Path $env:USERPROFILE '.ollama\models')
        )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (-not $roots.Contains($candidate)) { [void]$roots.Add($candidate) }
    }
    return @($roots)
}

function Resolve-LLMKitModelLocation {
    <#
        找一个模型到底躺在哪：逐个候选目录去翻 manifests，找到清单就核对分片。
        返回的 root 是**实际找到清单的那个目录**，而不是"Ollama 说的那个"。
        这也是给用户看的"具体位置"：清单文件全路径 + 分片目录。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        # 候选目录可覆盖（单测用；默认按环境变量 → 用户注册表 → 默认目录的顺序找）
        [string[]]$Roots = @()
    )

    $candidates = $Roots
    if ($null -eq $candidates -or $candidates.Count -eq 0) { $candidates = @(Get-LLMKitModelLocationRoots) }
    foreach ($root in @($candidates)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $mi = Get-LLMKitOllamaManifestInfo -ModelRoot $root -Tag $Tag
        if ($mi.found) {
            return [pscustomobject]@{
                tag          = $Tag
                found        = $true
                root         = $root
                manifestPath = [string]$mi.manifestPath
                blobsDir     = [string]$mi.blobsDir
                sizeGB       = [double]$mi.sizeGB
                layerCount   = [int]$mi.layerCount
                missingBlobs = @($mi.missingBlobs)
                verified     = [bool]$mi.verified
            }
        }
    }
    return [pscustomobject]@{
        tag = $Tag; found = $false; root = ''; manifestPath = ''; blobsDir = ''
        sizeGB = 0; layerCount = 0; missingBlobs = @(); verified = $false
    }
}
function Get-LLMKitOllamaEndpointUrl {
    <#
        本地端点的完整 URL。端口只在上面的 $script:OllamaPort 里写一次，
        别的模块（LocalConfig、界面）都从这里取，别各自写 11434。
    #>
    return ('http://127.0.0.1:' + $script:OllamaPort + '/v1')
}
function Get-LLMKitLocalContextHint {
    <#
        期望的默认上下文：从 config/models.json 的 contextHint 读，读不到才用兜底值。
        放在这里是为了让"要设成多少"只有一个来源 —— 之前服务层的命令行、
        报告字段、界面文案各写了一个 32768，改一个就会不一致。
    #>
    param([string]$ConfigRoot)

    if (-not [string]::IsNullOrWhiteSpace($ConfigRoot)) {
        $path = Join-Path $ConfigRoot 'config\models.json'
        try {
            if (Test-Path -LiteralPath $path) {
                $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                $hint = Get-ObjectPropSafe $data 'contextHint'
                $val = 0
                if ($null -ne $hint -and [int]::TryParse([string]$hint, [ref]$val) -and $val -ge 4096) { return $val }
            }
        } catch { }
    }
    return $script:DefaultContextLength
}
function Get-LLMKitOllamaContextSetting {
    <#
        当前上下文设置：请求值（环境变量）+ 实际生效值（加载中的模型上读到的）。
        两个都要报：设了但没重启时，环境变量是 32768、实际生效还是 4096 ——
        只报一个就会让人以为已经好了。
    #>
    $requested = [Environment]::GetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', 'User')
    if ([string]::IsNullOrWhiteSpace($requested)) { $requested = $env:OLLAMA_CONTEXT_LENGTH }
    $requestedValue = 0
    if (-not [string]::IsNullOrWhiteSpace($requested)) { [void][int]::TryParse([string]$requested, [ref]$requestedValue) }

    $effective = 0
    $running = $false
    try {
        $v = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $script:OllamaPort + '/api/version') -TimeoutSec 2 -ErrorAction Stop
        $running = $true
        $ps = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $script:OllamaPort + '/api/ps') -TimeoutSec 4 -ErrorAction Stop
        foreach ($m in @($ps.models)) {
            if ([int]$m.context_length -gt $effective) { $effective = [int]$m.context_length }
        }
    } catch { }

    return [pscustomobject]@{
        requested      = $requestedValue
        requestedRaw   = [string]$requested
        effective      = $effective
        serverRunning  = $running
        applied        = ($requestedValue -ge $script:DefaultContextLength -and ($effective -eq 0 -or $effective -ge $script:DefaultContextLength))
    }
}

function Restart-LLMKitOllama {
    <#
        重启 Ollama 并让新的环境变量生效。

        为什么不用"杀掉服务等托盘拉起来"：托盘进程有它自己的环境（登录时那份），
        它拉起的新服务继承的是旧环境 —— 实测杀掉服务后托盘重启，上下文仍然是 4096。
        所以这里由我们自己带着变量启动（子进程继承我们的环境），优先拉托盘，
        没有托盘就直接 serve。

        返回：'tray' / 'serve' / ''（没起来）
    #>
    param([int]$TimeoutSec = 45)

    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'ollama*' } | ForEach-Object {
        try { $_.Kill() } catch { }
    }
    Start-Sleep -Seconds 3

    $tray = ''
    $exe = Resolve-LLMKitOllamaExe
    if ($exe) {
        $candidate = Join-Path (Split-Path -Parent $exe) 'ollama app.exe'
        if (Test-Path -LiteralPath $candidate) { $tray = $candidate }
    }
    $mode = ''
    try {
        if (-not [string]::IsNullOrWhiteSpace($tray)) {
            Start-Process -FilePath $tray -WindowStyle Hidden | Out-Null
            $mode = 'tray'
        } elseif (-not [string]::IsNullOrWhiteSpace($exe)) {
            Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
            $mode = 'serve'
        }
    } catch { $mode = '' }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            [void](Invoke-RestMethod -Uri ('http://127.0.0.1:' + $script:OllamaPort + '/api/version') -TimeoutSec 2 -ErrorAction Stop)
            return $mode
        } catch { Start-Sleep -Milliseconds 800 }
    }
    return ''
}

function Set-LLMKitOllamaContext {
    <#
        把 Ollama 的默认上下文设到 32K 并**验证真的生效**。

        为什么必须设这个：Ollama 默认只给 4096，超出部分**静默截断**（实测：9630 字符的
        输入只处理了 2050 个 token，不报任何错）。agent 于是半路失忆，还查不出原因。
        设 num_ctx 只能管我们自己发的请求 —— OpenCode / Codex / dsh 那些工具不会传，
        所以必须改服务端默认值。

        失败就回滚：旧值写回（或在原本没有时删掉），再重启一次，如实报失败。
    #>
    param(
        [int]$Value = $script:DefaultContextLength,
        [string]$StateDir = '',
        [scriptblock]$OnLine
    )

    $emit = { param($s) if ($OnLine) { & $OnLine $s } }
    $exe = Resolve-LLMKitOllamaExe
    if ([string]::IsNullOrWhiteSpace($exe)) {
        return [pscustomobject]@{ ok = $false; verdict = 'no-runtime'; detail = '没装 Ollama，先装运行时再设置上下文。'; previousValue = ''; mode = '' }
    }

    $before = Get-LLMKitOllamaContextSetting
    $oldRaw = [Environment]::GetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', 'User')
    & $emit ('原设置：环境变量 [' + $oldRaw + ']，实际生效 ' + $(if ($before.effective -gt 0) { $before.effective } else { '（没有模型在跑，读不到）' }))

    try {
        [Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', [string]$Value, 'User')
    } catch {
        return [pscustomobject]@{ ok = $false; verdict = 'set-failed'; detail = ('写用户环境变量失败：' + $_.Exception.Message); previousValue = $oldRaw; mode = '' }
    }
    # 同时设进当前进程，重启出来的子进程会继承
    $env:OLLAMA_CONTEXT_LENGTH = [string]$Value

    & $emit ('已把 OLLAMA_CONTEXT_LENGTH 设为 ' + $Value + '，正在重启 Ollama 让新值生效…')
    $mode = Restart-LLMKitOllama
    if ([string]::IsNullOrWhiteSpace($mode)) {
        & $emit '重启后服务没起来，回滚环境变量'
        try {
            if ([string]::IsNullOrWhiteSpace($oldRaw)) { [Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', $null, 'User') }
            else { [Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', $oldRaw, 'User') }
        } catch { }
        [void](Restart-LLMKitOllama)
        return [pscustomobject]@{ ok = $false; verdict = 'restart-failed'; detail = '重启 Ollama 后服务没起来（30 秒内没响应）。已把环境变量改回原样，请手动启动 Ollama 看一眼。'; previousValue = $oldRaw; mode = '' }
    }
    & $emit ('服务已起来（' + $mode + '），现在验证实际生效值…')

    # 验证：挑一个已装模型，故意不传 num_ctx，看服务端给多少
    $status = Get-LLMKitOllamaStatus
    $tag = ''
    if (@($status.models).Count -gt 0) { $tag = [string]@($status.models)[0].name }
    $effective = 0
    if (-not [string]::IsNullOrWhiteSpace($tag)) {
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ model = $tag; prompt = 'hi'; stream = $false; options = @{ num_predict = 1 } } | ConvertTo-Json -Depth 6))
            [void](Invoke-WebRequest -Uri ('http://127.0.0.1:' + $script:OllamaPort + '/api/generate') -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 300)
            $after = Get-LLMKitOllamaContextSetting
            $effective = [int]$after.effective
        } catch {
            & $emit ('验证请求失败：' + $_.Exception.Message)
        }
    }

    if ($effective -ge $Value) {
        if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
            try {
                if (-not (Test-Path -LiteralPath $StateDir)) { [void](New-Item -ItemType Directory -Path $StateDir -Force) }
                Add-Content -LiteralPath (Join-Path $StateDir 'context-changes.log') -Encoding UTF8 `
                    -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  OLLAMA_CONTEXT_LENGTH: [' + $oldRaw + '] → ' + $Value + '（用户级；验证生效 ' + $effective + '）')
            } catch { }
        }
        & $emit ('生效确认：加载中的模型上下文 = ' + $effective)
        return [pscustomobject]@{ ok = $true; verdict = 'ok'; detail = ('已设成 ' + $Value + '，实测生效值 ' + $effective + '（用模型 ' + $tag + ' 验证）。'); previousValue = $oldRaw; mode = $mode }
    }

    & $emit ('设了 ' + $Value + ' 但实测生效值是 ' + $effective + '，回滚')
    try {
        if ([string]::IsNullOrWhiteSpace($oldRaw)) { [Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', $null, 'User') }
        else { [Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', $oldRaw, 'User') }
    } catch { }
    [void](Restart-LLMKitOllama)
    return [pscustomobject]@{ ok = $false; verdict = 'not-applied'; detail = ('设成 ' + $Value + ' 之后实测仍是 ' + $effective + '，已回滚。多半是这个 Ollama 版本不认 OLLAMA_CONTEXT_LENGTH，或者还有另一个服务实例在跑。'); previousValue = $oldRaw; mode = $mode }
}
Export-ModuleMember -Function `
    'Get-LLMKitHardware', 'Get-LLMKitModelVerdict', 'Get-LLMKitModelCatalog', 'Get-LLMKitModelGroupCatalog', `
    'Get-LLMKitOllamaStatus', 'Get-LLMKitOllamaModelRoot', 'Get-LLMKitDiskFreeGB', 'Get-LLMKitModelPullPlan', 'Invoke-LLMKitModelPull', 'Invoke-LLMKitModelRemove', 'Resolve-LLMKitOllamaExe', 'Test-LLMKitOllamaRunning', 'Get-LLMKitDiskGate', 'Test-LLMKitLocalEndpoint', 'Get-LLMKitOllamaRootInfo', 'Get-LLMKitOllamaManifestInfo', 'Get-LLMKitModelLocationRoots', 'Resolve-LLMKitModelLocation', 'Get-LLMKitOllamaContextSetting', 'Get-LLMKitLocalContextHint', 'Get-LLMKitOllamaEndpointUrl', 'Set-LLMKitOllamaContext', 'Restart-LLMKitOllama'
