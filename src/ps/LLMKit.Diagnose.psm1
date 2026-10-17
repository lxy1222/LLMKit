#Requires -Version 5.1
<#
    LLMKit 诊断层（M4）
    ------------------------------------------------------------------
    三件事：
      1. 统一错误翻译表 —— 规则放在 config/errormap.json，可远程更新。
         之前这些提示散落在三个模块里各写一份，迟早走偏；现在只有一个来源。
      2. 验证闭环 —— 装完之后到底能不能用，用一次完整复检说话，
         而不是靠"命令装上了"这种中间信号。
      3. 脱敏诊断报告 —— 新手最需要的东西：一份可以直接复制给朋友或客服的文本，
         里面该有的信息都有，不该有的（用户名、路径、密钥）一个都不出现。

    脱敏是硬要求：这份报告一定会被粘进聊天窗口/工单/论坛。
    宁可多脱一点，也不能漏一个 key 出去。
#>

Set-StrictMode -Off

$script:DiagnoseVersion = '0.1.0'
$script:ErrorMapCache = $null
$script:ErrorMapCacheRoot = ''

function Get-LLMKitDiagnoseVersion { $script:DiagnoseVersion }

function Assert-DiagnosePrerequisites {
    $missing = New-Object System.Collections.ArrayList
    foreach ($fn in @('Read-TextFileUtf8', 'Write-JsonFile', 'Get-ObjectProp', 'Get-ShortErrorText',
            'Resolve-ExecutablePath', 'Invoke-Process', 'Get-ConfigTargets', 'New-ConfigFileContent',
            'Get-MaskedConfigValue', 'Test-ProviderEndpoint', 'Find-InstallArtifacts', 'Get-UserPathInfo',
            'Get-PathEntryList', 'Get-NormalizedPathEntry')) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) { [void]$missing.Add($fn) }
    }
    if ($missing.Count -gt 0) {
        throw ('缺少前置模块函数：' + ($missing -join '、') + '。请先导入 LLMKit.psm1 / LLMKit.Install.psm1 / LLMKit.Config.psm1。')
    }
}

# ======================================================================
#  统一错误翻译表
# ======================================================================

function Get-ErrorMap {
    <# 读并缓存规则表。可远程更新：文件换了内容不用重新发版。 #>
    param([string]$ConfigRoot)
    if ([string]::IsNullOrEmpty($ConfigRoot)) {
        $here = $PSScriptRoot
        $ConfigRoot = Split-Path -Parent (Split-Path -Parent $here)
    }
    if ($script:ErrorMapCache -and $script:ErrorMapCacheRoot -eq $ConfigRoot) { return $script:ErrorMapCache }
    $path = Join-Path $ConfigRoot 'config\errormap.json'
    if (-not (Test-Path -LiteralPath $path)) { throw ('找不到错误翻译表：' + $path) }
    $doc = Read-TextFileUtf8 -Path $path | ConvertFrom-Json
    $rules = @($doc.rules | Sort-Object -Property @{ Expression = { [int](Get-ObjectProp -Object $_ -Name 'priority') }; Descending = $true })
    $script:ErrorMapCache = $rules
    $script:ErrorMapCacheRoot = $ConfigRoot
    return $rules
}

function Test-ErrorRuleMatch {
    <#
        match 里给的维度全部要满足（AND）；同一维度内是 OR。
        没给的维度不参与判定 —— 所以"只知道是 npm 失败"也能命中 ctx=npm 的兜底规则。
    #>
    param($Rule, [string]$Text, $HttpStatus, [string]$NetKind, $ExitCode, [string]$Context, [switch]$IgnoreContext)
    $m = Get-ObjectProp -Object $Rule -Name 'match'
    if (-not $m) { return $false }

    $hs = Get-ObjectProp -Object $m -Name 'httpStatus'
    if ($hs) {
        if ($null -eq $HttpStatus) { return $false }
        if (@($hs) -notcontains [int]$HttpStatus) { return $false }
    }
    $nk = Get-ObjectProp -Object $m -Name 'netKind'
    if ($nk) {
        if ([string]::IsNullOrEmpty($NetKind)) { return $false }
        if (@($nk) -notcontains $NetKind) { return $false }
    }
    $ec = Get-ObjectProp -Object $m -Name 'exitCode'
    if ($ec) {
        if ($null -eq $ExitCode) { return $false }
        if (@($ec) -notcontains [int]$ExitCode) { return $false }
    }
    $ctx = Get-ObjectProp -Object $m -Name 'context'
    if ($ctx -and -not $IgnoreContext) {
        if ([string]::IsNullOrEmpty($Context)) { return $false }
        if (@($ctx) -notcontains $Context) { return $false }
    }
    $tp = Get-ObjectProp -Object $m -Name 'textPattern'
    if ($tp) {
        if ([string]::IsNullOrEmpty($Text)) { return $false }
        $ok = $false
        foreach ($pat in @($tp)) {
            if ([string]::IsNullOrEmpty($pat)) { continue }
            try { if ($Text -match ('(?i)' + $pat)) { $ok = $true; break } } catch { }
        }
        if (-not $ok) { return $false }
    }
    return $true
}

function Test-ErrorRuleHasSpecificMatcher {
    <#
        规则是否带有"非 context"的判据。
        纯 context 规则（例如 npm-generic 只管"是 npm 失败"）只能在调用方明确
        给出 context 时参与，否则它会通吃任何文本，把精确规则全压下去。
    #>
    param($Rule)
    $m = Get-ObjectProp -Object $Rule -Name 'match'
    if (-not $m) { return $false }
    foreach ($k in @('textPattern', 'httpStatus', 'netKind', 'exitCode')) {
        if (Get-ObjectProp -Object $m -Name $k) { return $true }
    }
    return $false
}

function Get-ErrorInterpretation {
    <#
        把一段原始报错翻译成人话 + 该做什么。
        没给 NetKind 时会自己推断一次，这样调用方只要能拿到错误文本就够了。
    #>
    [CmdletBinding()]
    param(
        [string]$Text,
        $HttpStatus,
        [string]$NetKind,
        $ExitCode,
        [string]$Context,
        [string]$ConfigRoot
    )
    if ([string]::IsNullOrEmpty($NetKind) -and -not [string]::IsNullOrEmpty($Text)) {
        $kf = Get-Command -Name 'Get-NetworkErrorKind' -ErrorAction SilentlyContinue
        if ($kf) { $NetKind = [string](& $kf -Message $Text) }
    }

    $rules = Get-ErrorMap -ConfigRoot $ConfigRoot
    # 两遍匹配。原因很实际：像 Get-InstallErrorHint 这种通用入口并不知道自己面对的是
    # npm 失败还是下载失败，如果把 context 当硬性门槛，npm 的规则永远命中不了，
    # 最后只能给出"未知的网络错误"这种没用的话。
    # 所以 context 只用来消歧与提优先级，不作为门槛；第二遍忽略 context，
    # 但只允许带具体判据（文本/状态码/错误种类）的规则参与。
    for ($pass = 0; $pass -lt 2; $pass++) {
        $ignoreContext = ($pass -eq 1)
        foreach ($r in $rules) {
            if ($ignoreContext -and -not (Test-ErrorRuleHasSpecificMatcher -Rule $r)) { continue }
            if (Test-ErrorRuleMatch -Rule $r -Text $Text -HttpStatus $HttpStatus -NetKind $NetKind -ExitCode $ExitCode -Context $Context -IgnoreContext:$ignoreContext) {
                return [pscustomobject]([ordered]@{
                    matched = $true
                    ruleId  = [string]$r.id
                    category = [string]$r.category
                    severity = [string]$r.severity
                    title   = [string]$r.title
                    explanation = [string]$r.explanation
                    actions = @((Get-ObjectProp -Object $r -Name 'actions') | Where-Object { $_ })
                    netKind = $NetKind
                    httpStatus = $HttpStatus
                    })
            }
        }
    }
    return [pscustomobject]([ordered]@{
            matched = $false
            ruleId  = 'generic-unknown'
            category = '未知'
            severity = 'warn'
            title   = '没能自动识别这个错误'
            explanation = '错误信息不在已知的规则表里。'
            actions = @(
                '把完整原始报错连同诊断报告一起反馈，好把它补进规则表',
                '先看上面「体检摘要」里网络与依赖这两块是否正常'
            )
            netKind = $NetKind
            httpStatus = $HttpStatus
        })
}

function Get-ErrorHintText {
    <#
        给老代码用的单行提示（原来那两个 Get-*ErrorHint 会转发到这里）。
        刻意只有一个来源：两处各写一份迟早走偏。
    #>
    param([string]$Text, $HttpStatus, [string]$NetKind, $ExitCode, [string]$Context, [string]$ConfigRoot)
    try {
        $i = Get-ErrorInterpretation -Text $Text -HttpStatus $HttpStatus -NetKind $NetKind -ExitCode $ExitCode -Context $Context -ConfigRoot $ConfigRoot
        if (-not $i.matched) { return '' }
        $t = [string]$i.title
        if ($i.explanation) { $t = $t + '。' + [string]$i.explanation }
        return $t
    } catch {
        return ''
    }
}

function Format-ErrorInterpretation {
    <# 控制台/报告里统一的中文错误块 #>
    param([Parameter(Mandatory = $true)]$Interpretation, [switch]$NoColor, [int]$MaxActions = 4)
    $say = {
        param($text, $color)
        if (-not $NoColor) { try { Write-Host $text -ForegroundColor $color; return } catch { } }
        Write-Output $text
    }
    $color = 'Yellow'
    if ($Interpretation.severity -eq 'fail') { $color = 'Red' }
    elseif ($Interpretation.severity -eq 'info') { $color = 'DarkGray' }
    $head = '[' + $Interpretation.category + '] ' + $Interpretation.title
    if (-not $NoColor) { & $say $head $color } else { Write-Output $head }
    if ($Interpretation.explanation) { & $say ('  ' + $Interpretation.explanation) 'DarkGray' }
    $n = 0
    foreach ($a in @($Interpretation.actions)) {
        if ($n -ge $MaxActions) { break }
        $n++
        & $say ('  ' + $n + '. ' + $a) 'Cyan'
    }
}

# ======================================================================
#  脱敏
# ======================================================================

function Protect-SensitiveText {
    <#
        脱敏。这段文本一定会被粘进聊天窗口/工单/论坛，所以宁可多脱。
        顺序很重要：先替换更长的路径（含用户名），再处理用户名本身。
    #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text

    # 1) 用户目录整段替换（它本身就把用户名藏在里面）
    if ($env:USERPROFILE) { $t = $t -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%' }
    if ($env:LOCALAPPDATA) { $t = $t -replace [regex]::Escape($env:LOCALAPPDATA), '%LOCALAPPDATA%' }
    if ($env:APPDATA) { $t = $t -replace [regex]::Escape($env:APPDATA), '%APPDATA%' }
    if ($env:TEMP) { $t = $t -replace [regex]::Escape($env:TEMP), '%TEMP%' }

    # 2) 机器名 / 用户名 / 域（太短的词不换，否则会把正常文字也吃掉）
    foreach ($v in @($env:COMPUTERNAME, $env:USERNAME, $env:USERDOMAIN)) {
        if ([string]::IsNullOrEmpty($v) -or $v.Length -lt 4) { continue }
        $t = $t -replace ('(?i)\b' + [regex]::Escape($v) + '\b'), '%已隐去%'
    }

    # 3) 密钥形态：常见前缀 + 足够长的串
    $t = $t -replace '(?i)\b(sk|pk|api|apikey|key|token|bearer|ghp|gho|xoxb|xoxp)[-_ ]?[A-Za-z0-9_\-]{16,}', '<已脱敏-密钥>'
    $t = $t -replace '(?i)(authorization|x-api-key|api[-_]?key|auth[-_]?token|access[-_]?token)\s*[:=]\s*\S+', '$1: <已脱敏>'
    # 4) 长十六进制串（userID / machineID / 哈希）
    $t = $t -replace '\b[A-Fa-f0-9]{32,}\b', '<已脱敏-长标识>'
    # 5) 邮箱
    $t = $t -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<已脱敏-邮箱>'
    return $t
}

# ======================================================================
#  验证闭环
# ======================================================================

function New-VerifyItem {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'warn', 'fail', 'info')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Detail = '',
        [string[]]$Actions = @()
    )
    return [pscustomobject]([ordered]@{
            id = $Id; category = $Category; status = $Status
            title = $Title; detail = $Detail; actions = @($Actions)
        })
}

function Test-LLMKitInstallation {
    <#
        验证闭环：装完之后到底能不能用。
        刻意不看"命令装上了没有"这种中间信号，而是逐层验证：
        依赖能跑 → 工具能跑 → 配置已生效 → PATH 真的可用 → 端点真的通。
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigRoot,
        [string]$ReportPath,
        [string[]]$OnlyTools = @(),
        [string[]]$OnlyDeps = @(),
        [string]$ProviderId,
        [AllowEmptyString()][string]$ApiKey,
        [switch]$SkipLiveCheck,
        [string]$Proxy,
        [int]$TimeoutMs = 30000,
        [string]$StateDir
    )
    Assert-DiagnosePrerequisites
    if ([string]::IsNullOrEmpty($ConfigRoot)) {
        $here = $PSScriptRoot
        $ConfigRoot = Split-Path -Parent (Split-Path -Parent $here)
    }
    $items = New-Object System.Collections.ArrayList
    $onlyTools = @($OnlyTools | Where-Object { $_ })
    $onlyDeps = @($OnlyDeps | Where-Object { $_ })

    # ---------- 1) 运行时依赖 ----------
    $depPath = Join-Path $ConfigRoot 'config\dependencies.json'
    $deps = @()
    if (Test-Path -LiteralPath $depPath) {
        try { $deps = @((Read-TextFileUtf8 -Path $depPath | ConvertFrom-Json).dependencies) } catch { $deps = @() }
    }
    foreach ($dep in $deps) {
        if ($onlyDeps.Count -gt 0 -and ($onlyDeps -notcontains $dep.id)) { continue }
        $cmdName = [string](Get-ObjectProp -Object $dep.detect -Name 'command')
        $minMajor = Get-ObjectProp -Object $dep.detect -Name 'minMajor'
        $exe = Resolve-ExecutablePath -Name $cmdName
        if (-not $exe) {
            [void]$items.Add((New-VerifyItem -Id ('dep.' + $dep.id) -Category '依赖' -Status 'warn' `
                        -Title ($dep.name + '：未安装') -Detail ('命令 ' + $cmdName + ' 不在 PATH 上') `
                        -Actions @('跑一次 Setup-LLMKit.ps1 的依赖阶段即可自动安装', '如果已经装了，关掉终端重开一次再复检')))
            continue
        }
        $r = Invoke-Process -FilePath $exe -Arguments @('--version') -TimeoutMs 15000
        $ver = ($r.stdout -split "`n")[0].Trim()
        if (-not $ver) { $ver = ($r.stderr -split "`n")[0].Trim() }
        $major = $null
        $mm = [regex]::Match($ver, '(\d+)\.')
        if ($mm.Success) { $major = [int]$mm.Groups[1].Value }
        if (-not $ver) {
            $hint = Get-ErrorHintText -Text ([string]$r.error) -Context 'install' -ConfigRoot $ConfigRoot
            [void]$items.Add((New-VerifyItem -Id ('dep.' + $dep.id) -Category '依赖' -Status 'fail' `
                        -Title ($dep.name + '：命令存在但跑不起来') -Detail (($exe + ' / ' + [string]$r.error).TrimEnd(' ', '/')) `
                        -Actions @($(if ($hint) { $hint } else { '把这条连同诊断报告一起反馈' }), '尝试用 -Force 重新安装该依赖')))
            continue
        }
        if ($null -ne $minMajor -and $null -ne $major -and $major -lt [int]$minMajor) {
            [void]$items.Add((New-VerifyItem -Id ('dep.' + $dep.id) -Category '依赖' -Status 'fail' `
                        -Title ($dep.name + '：版本过低 ' + $ver) -Detail ('要求 v' + $minMajor + ' 以上') `
                        -Actions @('用 -Force 重新安装该依赖（会走免管理员的便携版路线）')))
            continue
        }
        [void]$items.Add((New-VerifyItem -Id ('dep.' + $dep.id) -Category '依赖' -Status 'ok' `
                    -Title ($dep.name + '：' + $ver) -Detail $exe))
    }

    # ---------- 2) 目标工具 ----------
    $toolsPath = Join-Path $ConfigRoot 'config\tools.json'
    $toolsCfg = $null
    if (Test-Path -LiteralPath $toolsPath) { $toolsCfg = Read-TextFileUtf8 -Path $toolsPath | ConvertFrom-Json }
    $m0Tools = $null
    if (-not [string]::IsNullOrEmpty($ReportPath) -and (Test-Path -LiteralPath $ReportPath)) {
        try { $m0Tools = Get-ObjectProp -Object (Read-TextFileUtf8 -Path $ReportPath | ConvertFrom-Json) -Name 'tools' } catch { $m0Tools = $null }
    }

    foreach ($tool in @($toolsCfg.tools)) {
        if ($onlyTools.Count -gt 0 -and ($onlyTools -notcontains $tool.id)) { continue }
        $cmds = @($tool.commands)
        $exe = $null
        $exeSource = ''
        foreach ($c in $cmds) {
            $e = Resolve-ExecutablePath -Name $c
            if ($e) { $exe = $e; $exeSource = 'PATH'; break }
        }
        $st = Get-ObjectProp -Object $m0Tools -Name $tool.id
        $installCount = 0
        if ($st) { $installCount = [int](Get-ObjectProp -Object $st -Name 'installCount') }

        # 复检必须自己查出真相，不能只依赖可能过期的体检报告 ——
        # cc-switch 这类 GUI 应用只有 PATH 与固定候选路径都命中不了，
        # 它真正的安装位置要靠注册表卸载项才能找到（实测踩到过：明明装了却报"未安装"）。
        if (-not $exe) {
            $found = @()
            foreach ($p in @($tool.probePaths)) {
                $ep = [System.Environment]::ExpandEnvironmentVariables([string]$p)
                if (Test-Path -LiteralPath $ep -PathType Leaf) { $found += $ep }
            }
            if ($found.Count -gt 0) { $exe = $found[0]; $exeSource = '候选路径' }
        }
        if (-not $exe) {
            $regNames = @(Get-ObjectProp -Object $tool -Name 'uninstallRegistryNames')
            $regFn = Get-Command -Name 'Find-InstalledAppInRegistry' -ErrorAction SilentlyContinue
            if ($regNames.Count -gt 0 -and $regFn) {
                foreach ($h in @(& $regFn -DisplayNames $regNames)) {
                    $loc = [string]$h.installLocation
                    if ([string]::IsNullOrEmpty($loc) -or -not (Test-Path -LiteralPath $loc -PathType Container)) { continue }
                    $cand = @(Get-ChildItem -LiteralPath $loc -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
                    if ($cand.Count -gt 0) { $exe = $cand[0].FullName; $exeSource = '注册表卸载项'; break }
                }
            }
        }
        if (-not $exe -and $st) {
            foreach ($inst in @(Get-ObjectProp -Object $st -Name 'installations')) {
                $ip = [string](Get-ObjectProp -Object $inst -Name 'path')
                if ($ip -and (Test-Path -LiteralPath $ip -PathType Leaf)) { $exe = $ip; $exeSource = '体检报告'; break }
            }
        }

        if (-not $exe) {
            [void]$items.Add((New-VerifyItem -Id ('tool.' + $tool.id) -Category '工具' -Status 'info' `
                        -Title ($tool.name + '：未安装') -Detail 'PATH、候选路径、注册表卸载项里都没找到可执行文件' `
                        -Actions @('用 -IncludeTools 让工具阶段帮你装')))
            continue
        }
        # GUI 判定只认配置，不认「从哪儿找到的可执行文件」。以前只有「注册表卸载项」那一条路算 GUI，
        # 于是本工具自己装到 %LOCALAPPDATA%\Programs 的 cc-switch（kind=gui、pathEntries=[]、skipRun=true）
        # 被当成命令行程序：先报「找不到命令」（它本来就不需要 PATH），再真的跑一次 cc-switch.exe --version —
        # GUI 程序没有 stdout，于是判成「装上了但跑不起来」，复检结论变红、退出码 3。
        # 用户在界面上看到的就是「我刚装好的东西验证失败」，其实一切正常。
        $isGui = ([string](Get-ObjectProp -Object $tool -Name 'kind') -eq 'gui')
        if (-not $isGui) {
            foreach ($t in @(Get-ObjectProp -Object (Get-ObjectProp -Object $tool -Name 'install') -Name 'tiers')) {
                $v = Get-ObjectProp -Object (Get-ObjectProp -Object $t -Name 'verify') -Name 'skipRun'
                if ($true -eq $v) { $isGui = $true; break }
            }
        }
        if ($isGui) {
            # 图形界面程序本来就不需要在 PATH 上（靠开始菜单快捷方式启动），
            # 报 warn 会让用户去处理一个根本不存在的问题。
            [void]$items.Add((New-VerifyItem -Id ('tool.' + $tool.id + '.path') -Category 'PATH' -Status 'info' `
                        -Title ($tool.name + '：图形界面程序，不需要在 PATH 上') -Detail $exe))
        } elseif ($exeSource -ne 'PATH') {
            [void]$items.Add((New-VerifyItem -Id ('tool.' + $tool.id + '.path') -Category 'PATH' -Status 'warn' `
                        -Title ($tool.name + '：已安装但当前终端找不到命令') `
                        -Detail ('程序在 ' + $exe + '（来源：' + $exeSource + '），但它不在当前进程的 PATH 上') `
                        -Actions @('关掉终端窗口重新开一个，这是最常见的原因', '安装器的安装过程不受影响，它用的是绝对路径')))
        }

        # GUI 程序一律不试跑，两个原因都很实在：
        #   1) 它基本不支持 --version，跑出来的"版本"可能是乱码
        #      （实测 cc-switch 返回了一整行等号，标题直接变成一串 ====）
        #   2) 它可能真的弹出窗口，把新手吓一跳
        # 能定位到文件本体，对 GUI 应用来说就是"装好了"。
        # $isGui 已在上面按配置算好（见 PATH 分支之前）
        if ($isGui) {
            $guiActions = @()
            if ($installCount -gt 1) { $guiActions = @('检测到多份安装共存：加 -ResolveConflicts 处理') }
            [void]$items.Add((New-VerifyItem -Id ('tool.' + $tool.id) -Category '工具' -Status 'ok' `
                        -Title ($tool.name + '：已安装（图形界面程序，不试跑以免弹窗）') `
                        -Detail ($exe + ' / 来源：' + $exeSource + $(if ($installCount -gt 1) { '（共 ' + $installCount + ' 份安装）' } else { '' })) `
                        -Actions $guiActions))
            continue
        }
        $vr = Invoke-Process -FilePath $exe -Arguments @('--version') -TimeoutMs $TimeoutMs
        $vtext = ($vr.stdout -split "`n")[0].Trim()
        if (-not $vtext) { $vtext = ($vr.stderr -split "`n")[0].Trim() }
        if (-not $vtext) {
            $interp = Get-ErrorInterpretation -Text ([string]$vr.error) -Context 'install' -ConfigRoot $ConfigRoot
            [void]$items.Add((New-VerifyItem -Id ('tool.' + $tool.id) -Category '工具' -Status 'fail' `
                        -Title ($tool.name + '：装上了但跑不起来') -Detail ($exe + ' -> ' + [string]$vr.error) `
                        -Actions @($interp.actions) ))
            continue
        }
        $status = 'ok'
        $actions = @()
        if ($installCount -gt 1) {
            $status = 'warn'
            $actions = @('检测到多份安装共存：加 -ResolveConflicts 让安装器保留 PATH 命中的那份、其余挪到备份区')
        }
        [void]$items.Add((New-VerifyItem -Id ('tool.' + $tool.id) -Category '工具' -Status $status `
                    -Title ($tool.name + '：' + $vtext) `
                    -Detail ($exe + ' / 来源：' + $exeSource + $(if ($installCount -gt 1) { '（共 ' + $installCount + ' 份安装）' } else { '' })) -Actions $actions))
    }

    # ---------- 3) 配置是否已生效 ----------
    $provider = $null
    if (-not [string]::IsNullOrEmpty($ProviderId)) {
        $pp = Join-Path $ConfigRoot 'config\providers.json'
        if (Test-Path -LiteralPath $pp) {
            $catalog = Read-TextFileUtf8 -Path $pp | ConvertFrom-Json
            $hit = @($catalog.providers | Where-Object { $_.id -eq $ProviderId })
            if ($hit.Count -gt 0) { $provider = $hit[0] }
        }
    }
    $targets = @(Get-ConfigTargets -ConfigRoot $ConfigRoot -ToolIds $onlyTools)
    foreach ($t in $targets) {
        if ($t.kind -eq 'guidance') { continue }
        $path = [System.Environment]::ExpandEnvironmentVariables($t.path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$items.Add((New-VerifyItem -Id ('cfg.' + $t.id) -Category '配置' -Status 'info' `
                        -Title ($t.toolName + ' · ' + $t.label + '：尚未写入') -Detail $t.path `
                        -Actions @('用 -Configure <渠道> 让工具阶段帮你写')))
            continue
        }
        $parseOk = $true
        $parseErr = ''
        if ($t.kind -like 'json*') {
            try { $null = Read-TextFileUtf8 -Path $path | ConvertFrom-Json } catch { $parseOk = $false; $parseErr = Get-ShortErrorText -Text $_.Exception.Message }
        }
        # 占位符标记：没给 key 时写进去的是「<在这里粘贴你的 API Key>」。
        # 只看「字段齐全」会给出「已配置为目标渠道」的假绿灯 —— 它其实连不上。
        $pending = @()
        if ($t.kind -like 'json*') {
            try {
                $docObj = Read-TextFileUtf8 -Path $path | ConvertFrom-Json
                $scope = $docObj
                if ($t.objectPath) { $scope = Get-ObjectProp -Object $docObj -Name $t.objectPath }
                if ($scope) {
                    foreach ($e in @($t.entries)) {
                        $nm = [string](Get-ObjectProp -Object $e -Name 'name')
                        if (-not $nm) { continue }
                        $val = [string](Get-ObjectProp -Object $scope -Name $nm)
                        if ($val -match '^<.+>$') { $pending += $nm }
                    }
                }
            } catch { }
        }
        if ($pending.Count -gt 0) {
            [void]$items.Add((New-VerifyItem -Id ('cfg.' + $t.id + '.pending') -Category '配置' -Status 'warn' `
                        -Title ($t.toolName + ' · ' + $t.label + '：还有 ' + $pending.Count + ' 个占位符没填') `
                        -Detail ('待填：' + ($pending -join '、')) `
                        -Actions @('其他变量都已经写好，你只需把占位符换成真实值', ('文件：' + $t.path))))
        }
        if (-not $parseOk) {
            [void]$items.Add((New-VerifyItem -Id ('cfg.' + $t.id) -Category '配置' -Status 'fail' `
                        -Title ($t.toolName + ' · ' + $t.label + '：内容不是合法 JSON') -Detail $parseErr `
                        -Actions @('用 -Restore 还回到写入前的备份', '原始文件在备份区里，不会丢')))
            continue
        }
        if (-not $provider) {
            [void]$items.Add((New-VerifyItem -Id ('cfg.' + $t.id) -Category '配置' -Status 'ok' `
                        -Title ($t.toolName + ' · ' + $t.label + '：已存在且格式合法') -Detail $t.path))
            continue
        }
        $calc = New-ConfigFileContent -Target $t -Provider $provider -ApiKey $ApiKey
        if (-not $calc.ok) {
            [void]$items.Add((New-VerifyItem -Id ('cfg.' + $t.id) -Category '配置' -Status 'warn' `
                        -Title ($t.toolName + ' · ' + $t.label + '：无法比对') -Detail $calc.error))
            continue
        }
        # 占位符没填时不能再报「已配置为目标渠道」：那是自相矛盾的绿灯（同一条下面还挂着 warn）。
        if (@($calc.changes).Count -eq 0 -and $pending.Count -eq 0) {
            [void]$items.Add((New-VerifyItem -Id ('cfg.' + $t.id) -Category '配置' -Status 'ok' `
                        -Title ($t.toolName + ' · ' + $t.label + '：已配置为目标渠道') -Detail $t.path))
        } elseif (@($calc.changes).Count -eq 0) {
            # 字段都对、只是 key 还是占位符：上面那条 warn 已经说清楚了，这里不重复
        } else {
            $names = @($calc.changes | ForEach-Object { $_.name })
            [void]$items.Add((New-VerifyItem -Id ('cfg.' + $t.id) -Category '配置' -Status 'warn' `
                        -Title ($t.toolName + ' · ' + $t.label + '：与目标渠道不一致（' + @($calc.changes).Count + ' 项）') `
                        -Detail ('待写字段：' + ($names -join '、')) `
                        -Actions @(('用 -Configure ' + $ProviderId + ' -Apply 写入'), '写入前会自动做时间戳备份')))
        }
    }

    # ---------- 4) PATH 是否真的生效 ----------
    $userPath = @(Get-PathEntryList -PathValue (Get-UserPathInfo).value)
    $procPath = @(Get-PathEntryList -PathValue $env:PATH)
    $userNorm = @($userPath | ForEach-Object { Get-NormalizedPathEntry -Entry $_ })
    $procNorm = @($procPath | ForEach-Object { Get-NormalizedPathEntry -Entry $_ })
    foreach ($tool in @($toolsCfg.tools)) {
        if ($onlyTools.Count -gt 0 -and ($onlyTools -notcontains $tool.id)) { continue }
        foreach ($pe in @(Get-ObjectProp -Object (Get-ObjectProp -Object $tool -Name 'install') -Name 'tiers')) {
            foreach ($entry in @(Get-ObjectProp -Object $pe -Name 'pathEntries')) {
                if ([string]::IsNullOrEmpty($entry)) { continue }
                $norm = Get-NormalizedPathEntry -Entry ([System.Environment]::ExpandEnvironmentVariables([string]$entry))
                $inUser = ($userNorm -contains $norm)
                $inProc = ($procNorm -contains $norm)
                if ($inUser -and $inProc) {
                    [void]$items.Add((New-VerifyItem -Id ('path.' + $tool.id) -Category 'PATH' -Status 'ok' `
                                -Title ($tool.name + '：PATH 已生效') -Detail $entry))
                } elseif ($inUser -and -not $inProc) {
                    [void]$items.Add((New-VerifyItem -Id ('path.' + $tool.id) -Category 'PATH' -Status 'warn' `
                                -Title ($tool.name + '：PATH 已写入但当前终端还没生效') -Detail $entry `
                                -Actions @('关掉终端窗口重新开一个即可', '已经打开的窗口不会自动重新读取环境变量')))
                } else {
                    [void]$items.Add((New-VerifyItem -Id ('path.' + $tool.id) -Category 'PATH' -Status 'info' `
                                -Title ($tool.name + '：该目录不在用户 PATH 里') -Detail $entry `
                                -Actions @('安装时会自动加入；如果手动装的需要自己加')))
                }
            }
        }
    }

    # ---------- 5) 安装残留 ----------
    $roots = New-Object System.Collections.ArrayList
    if ($env:APPDATA) { [void]$roots.Add((Join-Path $env:APPDATA 'npm\node_modules')) }
    if ($env:USERPROFILE) { [void]$roots.Add((Join-Path $env:USERPROFILE '.local\bin')) }
    $scan = Find-InstallArtifacts -Roots @($roots) -MaxDepth 3
    if ($scan.artifacts.Count -gt 0) {
        [void]$items.Add((New-VerifyItem -Id 'artifacts' -Category '残留' -Status 'warn' `
                    -Title ('还有 ' + $scan.artifacts.Count + ' 个安装残留未清理（' + $scan.groups.Count + ' 组）') `
                    -Detail (@($scan.groups | ForEach-Object { $_.dir }) -join ' | ') `
                    -Actions @('加 -CleanArtifacts 让安装器把它们挪到备份区（不删除）后再装')))
    } else {
        [void]$items.Add((New-VerifyItem -Id 'artifacts' -Category '残留' -Status 'ok' -Title '没有未处理的安装残留'))
    }

    # ---------- 6) 真实可用性 ----------
    if (-not $SkipLiveCheck) {
        if ($provider) {
            $style = 'openai'; $baseUrl = ''
            if ($provider.anthropicBaseUrl) { $style = 'anthropic'; $baseUrl = [string]$provider.anthropicBaseUrl }
            elseif ($provider.openaiBaseUrl) { $style = 'openai'; $baseUrl = [string]$provider.openaiBaseUrl }
            $model = ''
            if ($provider.models) { $model = [string]@($provider.models)[0] }
            $live = Test-ProviderEndpoint -BaseUrl $baseUrl -ApiKey $ApiKey -Style $style -Model $model -TimeoutMs $TimeoutMs -Proxy $Proxy
            $interp = Get-ErrorInterpretation -HttpStatus $live.httpStatus -NetKind $live.kind -Text $live.responseSnippet -Context 'provider' -ConfigRoot $ConfigRoot
            $status = 'fail'
            if ($live.ok) { $status = 'ok' }
            elseif ($live.kind -eq 'not-configured') { $status = 'info' }
            $title = $provider.name + '：' + $(if ($live.ok) { '可以用（' + $live.elapsedMs + ' ms）' } else { $interp.title })
            [void]$items.Add((New-VerifyItem -Id 'live-endpoint' -Category '可用性' -Status $status `
                        -Title $title -Detail ('端点 ' + $live.endpoint + $(if ($null -ne $live.httpStatus) { ' / HTTP ' + $live.httpStatus } else { '' })) `
                        -Actions @($interp.actions)))
        } else {
            [void]$items.Add((New-VerifyItem -Id 'live-endpoint' -Category '可用性' -Status 'info' `
                        -Title '未做真实可用性验证' -Detail '没有指定渠道（-Configure <渠道id>）或没有提供 key'))
        }
    }

    # ---------- 汇总 ----------
    $counts = [ordered]@{ ok = 0; warn = 0; fail = 0; info = 0 }
    foreach ($i in $items) { if ($counts.Contains($i.status)) { $counts[$i.status] = $counts[$i.status] + 1 } }
    $verdict = 'ok'
    if ($counts.fail -gt 0) { $verdict = 'fail' }
    elseif ($counts.warn -gt 0) { $verdict = 'warn' }

    return [pscustomobject]([ordered]@{
            schemaVersion = '0.1.0'
            engine        = 'LLMKit.Diagnose/' + $script:DiagnoseVersion
            generatedAt   = (Get-Date).ToString('o')
            verdict       = $verdict
            counts        = $counts
            providerId    = $ProviderId
            items         = @($items)
        })
}

function Format-LLMKitVerification {
    param([Parameter(Mandatory = $true)]$Verification, [switch]$NoColor)
    $useColor = -not $NoColor
    $say = {
        param($text, $color)
        if ($useColor) { try { Write-Host $text -ForegroundColor $color; return } catch { } }
        try { Write-Host $text } catch { [Console]::Out.WriteLine([string]$text) }
    }
    & $say '' 'Gray'
    & $say '=========== 安装有效性复检 ===========' 'White'
    foreach ($i in $Verification.items) {
        $mark = ' .. '; $color = 'Gray'
        switch ($i.status) {
            'ok' { $mark = ' OK '; $color = 'Green' }
            'warn' { $mark = ' !! '; $color = 'Yellow' }
            'fail' { $mark = ' XX '; $color = 'Red' }
            'info' { $mark = ' .. '; $color = 'DarkGray' }
        }
        & $say ('[' + $mark + '] [' + $i.category + '] ' + $i.title) $color
        if ($i.detail) { & $say ('         ' + $i.detail) 'DarkGray' }
        foreach ($a in @($i.actions)) { & $say ('         -> ' + $a) 'Cyan' }
    }
    $c = $Verification.counts
    $vt = '一切正常'
    if ($Verification.verdict -eq 'warn') { $vt = '基本可用，有需要留意的项' }
    elseif ($Verification.verdict -eq 'fail') { $vt = '存在问题，需要处理' }
    & $say '' 'Gray'
    & $say ('结论：' + $vt + '（OK ' + $c.ok + ' / 警告 ' + $c.warn + ' / 失败 ' + $c.fail + ' / 信息 ' + $c.info + '）') 'White'
    & $say '=====================================' 'White'
    & $say '' 'Gray'
}

# ======================================================================
#  脱敏诊断报告
# ======================================================================

function New-LLMKitDiagnosticReport {
    <#
        生成一份可以直接复制给别人的诊断报告。
        设计目标：该有的信息都有，不该有的一条都不出现。
        报告里永远不会出现：完整密钥、配置文件内容、邮箱、长标识串。
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigRoot,
        [string]$ReportPath,
        [string]$StateDir,
        [string[]]$OnlyTools = @(),
        [string]$ProviderId,
        [AllowEmptyString()][string]$ApiKey,
        [switch]$SkipLiveCheck,
        [string]$Proxy,
        [int]$TimeoutMs = 30000,
        [int]$JournalCount = 3,
        [string]$OutFile,
        [switch]$CopyToClipboard,
        [switch]$NoColor
    )
    Assert-DiagnosePrerequisites
    if ([string]::IsNullOrEmpty($ConfigRoot)) {
        $here = $PSScriptRoot
        $ConfigRoot = Split-Path -Parent (Split-Path -Parent $here)
    }
    if ([string]::IsNullOrEmpty($StateDir)) { $StateDir = Join-Path $ConfigRoot 'out\state' }

    $verify = Test-LLMKitInstallation -ConfigRoot $ConfigRoot -ReportPath $ReportPath -OnlyTools $OnlyTools `
        -ProviderId $ProviderId -ApiKey $ApiKey -SkipLiveCheck:$SkipLiveCheck -Proxy $Proxy -TimeoutMs $TimeoutMs

    $sb = New-Object System.Text.StringBuilder
    $add = { param($s) [void]$sb.AppendLine([string]$s) }
    # 报告是要给人复制粘贴的，单行几百字的异常堆栈必须截断，
    # 否则整篇变成一坨没法读的文本。
    $clip = {
        param($s)
        $x = [string]$s
        if ($x.Length -gt 240) { return $x.Substring(0, 240) + ' …(已截断)' }
        return $x
    }

    & $add '# LLMKit 诊断报告'
    & $add ''
    & $add '> 本报告已自动脱敏：不含 API Key、配置文件内容、邮箱与长标识串。'
    & $add '> 可以直接复制给别人看。'
    & $add ''
    & $add ('生成时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    & $add ('工具版本：LLMKit ' + $script:DiagnoseVersion + ' / 报告格式 0.1.0')
    & $add ''

    # --- 环境 ---
    & $add '## 环境'
    & $add ''
    $osKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = ''
    try { $build = (Get-ItemProperty -Path $osKey -Name CurrentBuildNumber -ErrorAction SilentlyContinue).CurrentBuildNumber } catch { }
    $disp = ''
    try { $disp = (Get-ItemProperty -Path $osKey -Name DisplayVersion -ErrorAction SilentlyContinue).DisplayVersion } catch { }
    & $add ('- Windows：内部版本 ' + $build + ' / 显示版本 ' + $disp + ' / 架构 ' + $env:PROCESSOR_ARCHITECTURE)
    & $add ('- PowerShell：' + $PSVersionTable.PSVersion.ToString())
    & $add ('- 是否管理员：' + (Test-IsElevated))
    & $add ('- 用户目录：%USERPROFILE%（已脱敏）')
    & $add ''

    # --- 体检摘要 ---
    if (-not [string]::IsNullOrEmpty($ReportPath) -and (Test-Path -LiteralPath $ReportPath)) {
        try {
            $r = Read-TextFileUtf8 -Path $ReportPath | ConvertFrom-Json
            & $add '## 体检摘要'
            & $add ''
            & $add ('- 生成时间：' + $r.generatedAt)
            & $add ('- 结论：' + $r.summary.verdict + '（OK ' + $r.summary.ok + ' / 警告 ' + $r.summary.warn + ' / 阻断 ' + $r.summary.fail + ' / 信息 ' + $r.summary.info + '）')
            & $add ('- 写探测可信：' + $r.environmentFlags.writeProbeReliable + ' / 疑似受限环境：' + $r.environmentFlags.restrictedSuspected)
            & $add ''
            $notable = @($r.checks | Where-Object { $_.status -eq 'fail' -or $_.status -eq 'warn' })
            if ($notable.Count -gt 0) {
                & $add '### 体检里需要留意的项'
                & $add ''
                foreach ($c in $notable) {
                    & $add ('- **[' + $c.status + '] ' + $c.title + '**')
                    if ($c.detail) { & $add ('  - ' + (& $clip $c.detail)) }
                }
                & $add ''
            }
        } catch { }
    }

    # --- 复检结果 ---
    & $add '## 安装有效性复检'
    & $add ''
    & $add ('结论：' + $verify.verdict + '（OK ' + $verify.counts.ok + ' / 警告 ' + $verify.counts.warn + ' / 失败 ' + $verify.counts.fail + ' / 信息 ' + $verify.counts.info + '）')
    & $add ''
    foreach ($i in $verify.items) {
        if ($i.status -eq 'ok' -and $i.category -eq 'PATH') { continue }   # 正常的 PATH 项太啰嗦，略过
        & $add ('### [' + $i.status.ToUpper() + '] [' + $i.category + '] ' + $i.title)
        if ($i.detail) { & $add ('- 依据：' + (& $clip $i.detail)) }
        foreach ($a in @($i.actions)) { & $add ('- 建议：' + $a) }
        & $add ''
    }

    # --- 配置状态（只列字段名，绝不列值） ---
    & $add '## 配置状态'
    & $add ''
    & $add '> 只列出文件路径与受管字段名，不包含任何字段值。'
    & $add ''
    try {
        foreach ($t in @(Get-ConfigTargets -ConfigRoot $ConfigRoot -ToolIds $OnlyTools)) {
            $p = [System.Environment]::ExpandEnvironmentVariables($t.path)
            $exists = Test-Path -LiteralPath $p -PathType Leaf
            $names = @($t.entries | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'name') })
            & $add ('- **' + $t.toolName + ' · ' + $t.label + '**：' + $(if ($exists) { '存在' } else { '不存在' }) + '（受管字段：' + ($names -join '、') + '）')
        }
    } catch { }
    & $add ''

    # --- 最近的安装会话 ---
    if ($JournalCount -gt 0) {
        $sessDir = Join-Path $StateDir 'sessions'
        if (Test-Path -LiteralPath $sessDir) {
            $files = @(Get-ChildItem -LiteralPath $sessDir -Filter *.json -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First $JournalCount)
            if ($files.Count -gt 0) {
                & $add ('## 最近 ' + $files.Count + ' 次安装会话')
                & $add ''
                foreach ($f in $files) {
                    try {
                        $doc = Read-TextFileUtf8 -Path $f.FullName | ConvertFrom-Json
                        & $add ('### 会话 ' + $doc.sessionId + '（' + $(if ($doc.dryRun) { '演练' } else { '实际执行' }) + '）')
                        & $add ('- 开始：' + $doc.startedAt)
                        if ($doc.summary) { & $add ('- 结果：成功 ' + $doc.summary.succeeded + ' / 失败 ' + $doc.summary.failed + ' / 计划 ' + $doc.summary.planned) }
                        foreach ($e in @($doc.entries)) {
                            if ([string]::IsNullOrEmpty([string]$e.action)) { continue }
                            & $add ('- [' + $e.status + '] ' + $e.action + $(if ($e.note) { ' —— ' + (& $clip $e.note) } else { '' }))
                        }
                        & $add ''
                    } catch { }
                }
            }
        }
    }

    # --- 下一步 ---
    $todo = New-Object System.Collections.ArrayList
    foreach ($i in $verify.items) {
        if ($i.status -ne 'fail' -and $i.status -ne 'warn') { continue }
        foreach ($a in @($i.actions)) { [void]$todo.Add('[' + $i.category + '] ' + $a) }
    }
    if ($todo.Count -gt 0) {
        & $add '## 建议的下一步'
        & $add ''
        $seen = @{}
        $k = 0
        foreach ($t in $todo) {
            if ($seen.ContainsKey($t)) { continue }
            $seen[$t] = $true
            $k++
            & $add ($k.ToString() + '. ' + $t)
        }
        & $add ''
    }

    & $add '---'
    & $add '本报告由 LLMKit 自动生成并脱敏。'

    $text = $sb.ToString()
    # 纵深防御：整篇再过一次脱敏，防止某个分支漏掉
    $text = Protect-SensitiveText -Text $text

    if ([string]::IsNullOrEmpty($OutFile)) {
        $outDir = Join-Path $ConfigRoot 'out'
        $OutFile = Join-Path $outDir ('diagnostic-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.md')
    }
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [System.IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false)))

    $copied = $false
    if ($CopyToClipboard) {
        try {
            $sc = Get-Command -Name 'Set-Clipboard' -ErrorAction SilentlyContinue
            if ($sc) { Set-Clipboard -Value $text; $copied = $true }
        } catch { $copied = $false }
    }

    $sayColor = 'Green'
    if ($verify.verdict -eq 'warn') { $sayColor = 'Yellow' }
    elseif ($verify.verdict -eq 'fail') { $sayColor = 'Red' }
    try { Write-Host '' } catch { }
    try { Write-Host ('诊断报告已写入：' + $OutFile) -ForegroundColor $sayColor } catch { }
    try { Write-Host ('复检结论：' + $verify.verdict + '（' + $verify.counts.ok + ' OK / ' + $verify.counts.warn + ' 警告 / ' + $verify.counts.fail + ' 失败）') -ForegroundColor $sayColor } catch { }
    if ($CopyToClipboard) {
        if ($copied) { try { Write-Host '已复制到剪贴板，可以直接粘贴给别人。' -ForegroundColor Green } catch { } }
        else { try { Write-Host '复制到剪贴板失败，请手动打开上面的文件复制。' -ForegroundColor Yellow } catch { } }
    }

    return [pscustomobject]([ordered]@{
            outFile = $OutFile; verification = $verify
            copiedToClipboard = $copied; reportText = $text
        })
}

Export-ModuleMember -Function `
    'Get-LLMKitDiagnoseVersion', 'Assert-DiagnosePrerequisites', `
    'Get-ErrorMap', 'Get-ErrorInterpretation', 'Get-ErrorHintText', `
    'Test-ErrorRuleMatch', 'Test-ErrorRuleHasSpecificMatcher', 'Format-ErrorInterpretation', `
    'Protect-SensitiveText', `
    'Test-LLMKitInstallation', 'Format-LLMKitVerification', `
    'New-LLMKitDiagnosticReport', 'New-VerifyItem'
