#Requires -Version 5.1
<#
.SYNOPSIS
    LLMKit 主入口（阶段 0 体检 + 阶段 1 依赖安装）

.DESCRIPTION
    把 M0 环境体检与 M1 依赖安装串成一条命令。
    默认是 DryRun：只体检 + 打印安装计划，不做任何改动。
    加 -Apply 才真正下载安装。

.PARAMETER Apply
    真正执行安装。不加这个开关时只打印计划（演练模式）。

.PARAMETER Only
    只处理指定的依赖（如 -Only node,git）。

.PARAMETER Skip
    跳过指定的依赖。

.PARAMETER Restore
    回滚指定的安装会话日志（out\state\sessions\<id>.json）。

.PARAMETER NoVersionResolve
    计划阶段不去联网解析最新版本号（离线环境下用）。

.EXAMPLE
    # 演练：体检 + 看计划，什么都不改
    powershell -NoProfile -ExecutionPolicy Bypass -File .\src\ps\Setup-LLMKit.ps1

.EXAMPLE
    # 真正安装缺失的依赖
    powershell -NoProfile -ExecutionPolicy Bypass -File .\src\ps\Setup-LLMKit.ps1 -Apply

.EXAMPLE
    # 演练一次回滚
    .\src\ps\Setup-LLMKit.ps1 -Restore .\out\state\sessions\20260101-120000-abc123.json
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$SkipCheck,
    [switch]$SkipDeps,
    [string[]]$Only = @(),
    [string[]]$Skip = @(),
    [string[]]$OnlyTiers = @(),
    [string[]]$SkipTiers = @(),
    [switch]$Force,
    [string]$SandboxRoot,
    [switch]$IncludeTools,
    [string[]]$OnlyTools = @(),
    [string[]]$SkipTools = @(),
    [switch]$CleanArtifacts,
    [switch]$ResolveConflicts,
    [switch]$ShowProviders,
    [string[]]$Provider = @(),
    [switch]$OpenProvider,
    [string]$Configure,
    [string]$AuthToken,
    [string]$AuthTokenEnvVar,
    [string]$Model = '',
    [switch]$SkipOnboarding,
    [switch]$AllowUnverifiedTargets,
    [switch]$NoVerify,
    [switch]$VerifyOnly,
    [switch]$Verify,
    [switch]$Diagnose,
    [string]$DiagnosticFile,
    [switch]$CopyDiagnostic,
    [string]$Restore,
    [string]$Uninstall,
    [switch]$RemoveUserConfig,
    [switch]$CleanOnly,
    [string]$Proxy,
    [string]$StateDir,
    [string]$ReportPath,
    [string]$ConfigRoot,
    [switch]$NoVersionResolve,
    [switch]$KeepCache,
    [switch]$NoColor,
    [int]$NetworkTimeoutMs = 4000,
    [int]$CommandTimeoutMs = 8000
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if ([string]::IsNullOrEmpty($ConfigRoot)) { $ConfigRoot = $projectRoot }
if ([string]::IsNullOrEmpty($StateDir)) { $StateDir = Join-Path $projectRoot 'out\state' }
if ([string]::IsNullOrEmpty($ReportPath)) { $ReportPath = Join-Path $projectRoot 'out\env-report-latest.json' }

Import-Module (Join-Path $scriptDir 'LLMKit.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir 'LLMKit.Install.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir 'LLMKit.Tools.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir 'LLMKit.Config.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir 'LLMKit.Diagnose.psm1') -Force -DisableNameChecking

# powershell.exe -File 不会按逗号拆数组参数：-Only node,git 会原样变成单个字符串 "node,git"。
# 用 cmd / powershell 调用脚本是最常见的用法，必须自己拆开，
# 否则会静默匹配不到任何依赖——用户以为装了，实际什么都没做。
$Only = @(ConvertTo-CsvList -Values $Only | Where-Object { $_ })
$Skip = @(ConvertTo-CsvList -Values $Skip | Where-Object { $_ })
$OnlyTiers = @(ConvertTo-CsvList -Values $OnlyTiers | Where-Object { $_ })
$SkipTiers = @(ConvertTo-CsvList -Values $SkipTiers | Where-Object { $_ })
$OnlyTools = @(ConvertTo-CsvList -Values $OnlyTools | Where-Object { $_ })
$SkipTools = @(ConvertTo-CsvList -Values $SkipTools | Where-Object { $_ })
$Provider = @(ConvertTo-CsvList -Values $Provider | Where-Object { $_ })
# 提到这里初始化：阶段 3 与阶段 4 都要用它，而阶段 3 只在 -Configure 时才会赋值
$token = $AuthToken

function Write-Line {
    param([string]$Text, [string]$Color = 'Gray')
    # 显式 flush：输出被重定向到文件/管道时 .NET 默认是块缓冲的，
    # 图形界面就只能在整步结束后才看到内容。每行冲一次才谈得上"实时进度"。
    try { [Console]::Out.Flush() } catch { }
    # 一律走 Host：这些提示若走输出流，会被 $setup = ... 这类赋值吃掉，
    # 症状是"明明跑了却什么都没显示"。需要机器可读结果请用 -Json 或报告文件。
    if ($NoColor) { try { Write-Host $Text } catch { [Console]::Out.WriteLine($Text) } }
    else { try { Write-Host $Text -ForegroundColor $Color } catch { [Console]::Out.WriteLine($Text) } }
}

# ---------------------------------------------------------------- 回滚分支
if (-not [string]::IsNullOrEmpty($Restore)) {
    $rp = $Restore
    if (-not [System.IO.Path]::IsPathRooted($rp)) { $rp = Join-Path (Get-Location).Path $rp }
    Write-Line ''
    Write-Line 'LLMKit · 回滚安装会话' 'White'
    [void](Restore-LLMKitSession -JournalPath $rp -Apply:$Apply -NoColor:$NoColor)
    if (-not $Apply) { Write-Line '以上是演练结果。确认后加 -Apply 真正回滚。' 'Yellow' }
    exit 0
}

# ---------------------------------------------------------------- 只清理残留分支
if ($CleanOnly) {
    Write-Line ''
    Write-Line 'LLMKit · 清理安装残留' 'White'
    Write-Line ('模式：' + $(if ($Apply) { '执行（-Apply）' } else { '演练（DryRun，不会改动系统）' })) $(if ($Apply) { 'Yellow' } else { 'Green' })
    Write-Line ('-' * 72) 'DarkGray'
    Write-Line '只清理，不安装 —— 和「安装时顺带清理」是两件事，分开做才不会把用户没打算装的东西装上。' 'DarkGray'

    # 刻意不依赖体检报告：清理残留只需要扫目录，不需要工具状态
    $cat = Get-ToolCatalog -ConfigRoot $ConfigRoot
    $session = New-InstallSession -StateDir $StateDir -DryRun:(-not $Apply)
    $totalGroups = 0
    $totalSkipped = 0
    $anyTarget = $false
    foreach ($tool in @($cat.tools.tools)) {
        if ($OnlyTools.Count -gt 0 -and ($OnlyTools -notcontains $tool.id)) { continue }
        $anyTarget = $true
        $groups = @(Get-LLMKitToolArtifacts -ToolId $tool.id)
        if ($groups.Count -eq 0) {
            Write-Line ('  ' + $tool.name + '：没有残留') 'DarkGray'
            continue
        }
        Write-Line ('  ' + $tool.name + '：' + $groups.Count + ' 组残留') 'Cyan'
        foreach ($g in $groups) { Write-Line ('    · ' + $g.dir) 'DarkGray' }
        $moved = @(Move-ArtifactsToBackup -Groups $groups -Session $session -ProtectedNames @($tool.commands) -Apply:$Apply)
        foreach ($m in $moved) {
            if ($m.skipped) {
                $totalSkipped++
                Write-Line ('    → 跳过：组内有疑似可用的程序（' + ($m.protectedNames -join '、') + '），判定为不是残渣') 'Yellow'
            } else {
                $totalGroups++
                Write-Line ('    → ' + $(if ($m.moved) { '已搬到 ' + $m.destination } else { '（演练，未搬动）' })) 'Green'
            }
        }
    }
    if (-not $anyTarget) {
        Write-Line ('没有匹配的工具：' + ($OnlyTools -join '、')) 'Yellow'
        Write-Line ('可用：' + (($cat.tools.tools | ForEach-Object { $_.id }) -join '、')) 'DarkGray'
        exit 2
    }
    $journalPath = Save-InstallJournal -Session $session
    Write-Line ''
    Write-Line ('清理结束：处理 ' + $totalGroups + ' 组，跳过 ' + $totalSkipped + ' 组') $(if ($Apply) { 'Green' } else { 'Yellow' })
    if (-not $Apply) { Write-Line '以上是演练结果。确认无误后加 -Apply 真正执行。' 'Yellow' }
    if ($Apply -and $journalPath) { Write-Line ('还原命令：Setup-LLMKit.ps1 -Restore ' + $journalPath + ' -Apply') 'DarkGray' }
    exit 0
}

# ---------------------------------------------------------------- 卸载分支
if (-not [string]::IsNullOrEmpty($Uninstall)) {
    Write-Line ''
    Write-Line ('LLMKit · 卸载工具：' + $Uninstall) 'White'
    Write-Line ('模式：' + $(if ($Apply) { '执行（-Apply）' } else { '演练（DryRun，不会改动系统）' })) $(if ($Apply) { 'Yellow' } else { 'Green' })
    Write-Line ('-' * 72) 'DarkGray'

    $catalog = Get-ToolCatalog -ConfigRoot $ConfigRoot
    $hit = @($catalog.tools.tools | Where-Object { $_.id -eq $Uninstall })
    if ($hit.Count -eq 0) {
        Write-Line ('未知工具：' + $Uninstall) 'Red'
        Write-Line ('可用：' + (($catalog.tools.tools | ForEach-Object { $_.id }) -join '、')) 'Yellow'
        exit 2
    }
    $tool = $hit[0]

    # 状态优先复用体检报告（快），报告里没有就现查一次
    $st = $null
    if (Test-Path -LiteralPath $ReportPath) {
        try {
            $rep = Read-TextFileUtf8 -Path $ReportPath | ConvertFrom-Json
            $st = Get-ObjectProp -Object (Get-ObjectProp -Object $rep -Name 'tools') -Name $tool.id
        } catch { $st = $null }
    }
    if (-not $st) {
        # npm 的 prefix 随 nvm / 自定义配置变化，这里现问一次，否则 npm 装的 shim 会漏掉
        $prefix = ''
        $npmExe = Resolve-ExecutablePath -Name 'npm'
        if ($npmExe) {
            $nr = Invoke-Process -FilePath $npmExe -Arguments @('prefix', '-g') -TimeoutMs 20000
            if ($nr.stdout) {
                $pl = @($nr.stdout -split "`n" | Where-Object { $_.Trim() })
                if ($pl.Count -gt 0) { $prefix = $pl[$pl.Count - 1].Trim() }
            }
        }
        $st = Get-ToolStatus -Tool $tool -State ([pscustomobject]@{ npmPrefix = [pscustomobject]@{ path = $prefix } })
    }

    $artifacts = @(Get-LLMKitToolArtifacts -ToolId $tool.id)

    Write-Line ''
    Write-Line ('工具：' + $tool.name) 'White'
    if ($st -and $st.installations) {
        Write-Line '检测到的安装位置：' 'DarkGray'
        foreach ($inst in @($st.installations)) { Write-Line ('  · [' + $inst.kind + '] ' + $inst.path) 'DarkGray' }
    } else {
        Write-Line '没有检测到已安装的实例（可能已经被卸载或从未装过）' 'Yellow'
    }
    if ($artifacts.Count -gt 0) {
        Write-Line ('安装残留：' + $artifacts.Count + ' 组') 'Yellow'
        foreach ($g in $artifacts) { Write-Line ('  · ' + $g.dir) 'DarkGray' }
    }
    Write-Line ''
    Write-Line '会做的事：把安装本体、残留、以及它加进 PATH 的条目挪到备份区（不删除）' 'Cyan'
    Write-Line ('用户配置：' + $(if ($RemoveUserConfig) { '一并挪走（你启用了 -RemoveUserConfig）' } else { '保留不动（含你的 API 设置）' })) 'Cyan'
    Write-Line ''

    $session = New-InstallSession -StateDir $StateDir -DryRun:(-not $Apply)
    $r = Uninstall-LLMKitTool -Tool $tool -ToolStatus $st -ArtifactGroups $artifacts -Session $session -RemoveUserConfig:$RemoveUserConfig -Apply:$Apply
    foreach ($s in @($r.steps)) { Write-Line ('  · ' + $s) 'DarkGray' }
    $journalPath = Save-InstallJournal -Session $session
    Write-Line ''
    if ($r.ok) {
        Write-Line ('卸载完成：本体 ' + $r.movedInstalls + ' 项 / PATH ' + $r.pathRemoved + ' 条 / 残留 ' + $r.artifactsMoved + ' 组 / 配置 ' + $r.configMoved + ' 个') $(if ($Apply) { 'Green' } else { 'Yellow' })
        if (-not $Apply) { Write-Line '以上是演练结果。确认无误后加 -Apply 真正执行。' 'Yellow' }
        if ($Apply -and $journalPath) { Write-Line ('还原命令：Setup-LLMKit.ps1 -Restore ' + $journalPath + ' -Apply') 'DarkGray' }
        exit 0
    } else {
        Write-Line ('卸载失败：' + $r.error) 'Red'
        exit 1
    }
}

Write-Line ''
Write-Line 'LLMKit · 大模型工具引导式一键安装器' 'White'
Write-Line ('引擎 ' + (Get-LLMKitVersion) + ' / 安装引擎 ' + (Get-LLMKitInstallVersion) + ' / 目标：' + $env:COMPUTERNAME) 'DarkGray'
$modeText = '演练（DryRun，不会改动系统）'
$modeColor = 'Green'
if (-not [string]::IsNullOrEmpty($SandboxRoot)) {
    $modeText = '沙箱安装（真的下载解压并验证，但不写注册表、不改 PATH）'
    $modeColor = 'Yellow'
} elseif ($Apply) {
    $modeText = '执行（-Apply，会改动系统）'
    $modeColor = 'Yellow'
}
Write-Line ('模式：' + $modeText) $modeColor
Write-Line ('-' * 72) 'DarkGray'

# ---------------------------------------------------------------- 阶段 0
$report = $null
if (-not $SkipCheck) {
    Write-Line ''
    Write-Line '【阶段 0】环境体检' 'White'
    try {
        $report = Invoke-LLMKitEnvironmentCheck -ConfigRoot $ConfigRoot -NetworkTimeoutMs $NetworkTimeoutMs -CommandTimeoutMs $CommandTimeoutMs
        [void](Save-LLMKitReport -Report $report -Path $ReportPath)
        Format-LLMKitReport -Report $report -NoColor:$NoColor
        Write-Line ('报告已写入：' + $ReportPath) 'DarkGray'
    } catch {
        Write-Line ('体检失败：' + $_.Exception.Message) 'Red'
        Write-Line '将跳过体检直接生成安装计划（计划质量会下降）。' 'Yellow'
    }
} elseif (Test-Path -LiteralPath $ReportPath) {
    try { $report = Read-TextFileUtf8 -Path $ReportPath | ConvertFrom-Json } catch { $report = $null }
}

if ($report -and $report.summary.verdict -eq 'fail') {
    if (-not $SkipCheck) {
        Write-Line ''
        Write-Line '体检结论里有阻断项。建议先解决这些再安装，否则安装大概率也会失败。' 'Red'
        Write-Line '如果你确信可以继续，加 -SkipCheck 跳过体检后重试。' 'Yellow'
        exit 2
    }
    # 传了 -SkipCheck 就是明确表示"我知道这份报告有阻断项，继续"。
    # 之前这里没区分，结果提示用户加一个他已经加过的参数，自相矛盾。
    Write-Line ''
    Write-Line ('注意：复用的报告（' + $ReportPath + '）里有阻断项。因为你传了 -SkipCheck，继续执行。') 'Yellow'
    Write-Line '若后续因网络或权限失败，属于预期之内，不算工具的缺陷。' 'Yellow'
}


  # ---------------------------------------------------------------- 阶段 1（已下线）
  # 依赖安装这条链在 Node.js / Git 升格成"工具"之后就没有数据可跑了：
  # 它们现在跟 Python / PyCharm 一样，各有页面、各自安装（见 config/tools.json）。
  # -SkipDeps 参数保留，是为了不打断已经在用的命令行；它现在只影响下面这句提示。
  $setup = $null
  if (-not $SkipDeps) {
      Write-Line ''
      Write-Line '【阶段 1】运行时依赖：已取消' 'White'
      Write-Line '  Node.js 与 Git 现在是普通工具，请在网页界面里逐个安装（或：Setup-LLMKit.ps1 -IncludeTools -OnlyTools node）。' 'DarkGray'
      Write-Line '  依赖安装流水线已删除，本阶段不做任何事。' 'DarkGray'
  }

# ---------------------------------------------------------------- 阶段 2（可选）
$toolSetup = $null
if ($IncludeTools) {
    Write-Line ''
    Write-Line '【阶段 2】目标工具' 'White'
    $toolPlan = $null
    try {
        $toolPlan = New-LLMKitToolPlan -ConfigRoot $ConfigRoot -ReportPath $ReportPath `
            -Only $OnlyTools -Skip $SkipTools -OnlyTiers $OnlyTiers -SkipTiers $SkipTiers `
            -Force:$Force -Proxy $Proxy -NoVersionResolve:$NoVersionResolve
    } catch {
        Write-Line ('生成工具安装计划失败：' + $_.Exception.Message) 'Red'
    }
    if ($toolPlan) {
        Format-LLMKitToolPlan -Plan $toolPlan -NoColor:$NoColor
        try {
            $toolSetup = Invoke-LLMKitToolSetup -Plan $toolPlan -Apply:$Apply -StateDir $StateDir -Proxy $Proxy `
                -CleanArtifacts:$CleanArtifacts -ResolveConflicts:$ResolveConflicts `
                -SandboxRoot $SandboxRoot -KeepCache:$KeepCache -NoColor:$NoColor
        } catch {
            Write-Line ('执行工具安装失败：' + $_.Exception.Message) 'Red'
            Write-Line $_.ScriptStackTrace 'DarkGray'
        }
    }
}

# ---------------------------------------------------------------- 阶段 3：配置写入（可选）
$configSetup = $null
if ($Configure) {
    Write-Line ''
    Write-Line '【阶段 3】配置写入' 'White'

    $token = $AuthToken
    if (-not $token -and $AuthTokenEnvVar) {
        $token = [System.Environment]::GetEnvironmentVariable($AuthTokenEnvVar, 'Process')
        if (-not $token) { $token = [System.Environment]::GetEnvironmentVariable($AuthTokenEnvVar, 'User') }
        if (-not $token) {
            Write-Line ('环境变量 ' + $AuthTokenEnvVar + ' 里没有读到值，将按"未提供 key"处理（只写 base_url 与模型名，key 留占位符）。') 'Yellow'
        } else {
            Write-Line ('已从环境变量 ' + $AuthTokenEnvVar + ' 读取到 API Key（不落盘、不进日志）。') 'Green'
        }
    }
    if ($AuthToken) {
        Write-Line '提示：用 -AuthToken 直接传 key 会留在命令历史里。更安全的做法是 -AuthTokenEnvVar <变量名>。' 'Yellow'
    }

if ($Model) { Write-Line ('模型：' + $Model + '（你指定的）') 'Cyan' }
else { Write-Line '模型：用渠道里的第一个（想换就在界面上选，或加 -Model）' 'DarkGray' }
    $configPlan = $null
    try {
        $configPlan = New-LLMKitConfigPlan -ConfigRoot $ConfigRoot -ProviderId $Configure -ApiKey $token `
            -OnlyTools $OnlyTools -SkipOnboarding:$SkipOnboarding `
            -AllowUnverifiedTargets:$AllowUnverifiedTargets -NoVerify:$NoVerify -Model $Model
    } catch {
        Write-Line ('生成配置写入计划失败：' + $_.Exception.Message) 'Red'
    }
    if ($configPlan) {
        Format-LLMKitConfigPlan -Plan $configPlan -NoColor:$NoColor
        if ($VerifyOnly) {
            Write-Line '（-VerifyOnly：只做真实可用性验证，不写任何配置文件）' 'DarkGray'
        } else {
            try {
                $configSetup = Invoke-LLMKitConfigSetup -Plan $configPlan -Apply:$Apply -StateDir $StateDir -NoColor:$NoColor
            } catch {
                Write-Line ('写入配置失败：' + $_.Exception.Message) 'Red'
                Write-Line $_.ScriptStackTrace 'DarkGray'
            }
        }
    }
}

# ---------------------------------------------------------------- 阶段 4：有效性复检（可选）
$verification = $null
if ($Verify -or $Diagnose) {
    Write-Line ''
    Write-Line '【阶段 4】有效性复检' 'White'
    try {
        if ($Diagnose) {
            $diag = New-LLMKitDiagnosticReport -ConfigRoot $ConfigRoot -ReportPath $ReportPath -StateDir $StateDir `
                -OnlyTools $OnlyTools -ProviderId $Configure -ApiKey $token -Proxy $Proxy `
                -OutFile $DiagnosticFile -CopyToClipboard:$CopyDiagnostic -NoColor:$NoColor
            $verification = $diag.verification
            if ($verification -and $verification.verdict -ne 'ok') {
                Format-LLMKitVerification -Verification $verification -NoColor:$NoColor
            }
        } else {
            $verification = Test-LLMKitInstallation -ConfigRoot $ConfigRoot -ReportPath $ReportPath -OnlyTools $OnlyTools `
                -ProviderId $Configure -ApiKey $token -Proxy $Proxy -StateDir $StateDir
            Format-LLMKitVerification -Verification $verification -NoColor:$NoColor
        }
    } catch {
        Write-Line ('复检失败：' + $_.Exception.Message) 'Red'
        Write-Line $_.ScriptStackTrace 'DarkGray'
    }
}

# ---------------------------------------------------------------- 渠道引导（只给链接，不碰 key）
if ($ShowProviders) {
    Write-Line ''
    Write-Line '【渠道引导】注册与领取 API Key 的入口' 'White'
    Write-Line '本工具不会内置、代发或代充任何 API Key —— key 始终由你自己创建和保管。' 'DarkGray'
    try {
        [void](Show-ProviderGuidance -ConfigRoot $ConfigRoot -ProviderId $Provider -Open:$OpenProvider -NoColor:$NoColor)
    } catch {
        Write-Line ('读取渠道目录失败：' + $_.Exception.Message) 'Red'
    }
}

$failedCount = 0
if ($setup -and $setup.summary) { $failedCount += [int]$setup.summary.failed }
if ($toolSetup -and $toolSetup.summary) { $failedCount += [int]$toolSetup.summary.failed }
if ($configSetup -and $configSetup.summary) { $failedCount += [int]$configSetup.summary.failed }

if (-not $Apply -and [string]::IsNullOrEmpty($SandboxRoot)) {
    Write-Line ''
    Write-Line '以上是演练结果，系统没有任何改动。确认无误后加 -Apply 真正执行。' 'Yellow'
}

# 退出码约定：0 一切正常 / 1 有阶段失败 / 2 体检有阻断项 / 3 复检不通过
if ($failedCount -gt 0) { exit 1 }
if ($verification -and $verification.verdict -eq 'fail') { exit 3 }
exit 0
