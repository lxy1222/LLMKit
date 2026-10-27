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
        $v = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 2 -ErrorAction Stop
        $running = $true
        $serverVersion = [string]$v.version
    } catch { }

    $models = @()
    if ($running) {
        try {
            $ps = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 4 -ErrorAction Stop
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
        baseUrl          = 'http://127.0.0.1:11434/v1'
        modelRoot        = Get-LLMKitOllamaModelRoot
        models           = @($models)
    }
}

Export-ModuleMember -Function `
    'Get-LLMKitHardware', 'Get-LLMKitModelVerdict', 'Get-LLMKitModelCatalog', `
    'Get-LLMKitOllamaStatus', 'Get-LLMKitOllamaModelRoot', 'Get-LLMKitDiskFreeGB'
