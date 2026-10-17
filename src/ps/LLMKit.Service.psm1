#Requires -Version 5.1
<#
    LLMKit 服务层（W1）
    ------------------------------------------------------------------
    网页版与 WinForms 版共用的"动作层"。界面只跟这一层打交道：

      读：Get-LLMKitOverview          首页要的全部状态
          Get-LLMKitToolDetail        单个工具页要的全部信息
          Get-LLMKitActionCatalog     动作清单（界面据此渲染按钮，不用硬编码）
          Get-LLMKitProviderList      渠道页
          Get-LLMKitSessionList       历史页

      写：Get-LLMKitActionCommandLine  动作 → 要跑的完整命令行

    为什么"写"只产出命令行、而不是直接执行：
      长任务的进度流已经有一条验证过的路径 —— 起 powershell.exe、把输出重定向到文件、
      增量读文件（事件回调会崩进程、跨线程读管道会阻塞，这两条都踩过）。
      所以所有动作都走 Setup-LLMKit.ps1 这一个入口，界面只负责跑它、读它的输出。
      好处是：CLI、WinForms、网页版三条路执行的是完全同一段逻辑，不会走偏，
      而且每个动作都会在界面上显示成一条"你可以自己复制到终端重跑"的命令。

    安全默认在这里统一兜底：任何 actions 里 destructive 的动作，
    生成命令行时**只有显式 apply 才追加 -Apply**。
#>

Set-StrictMode -Off

$script:ServiceVersion = '0.1.0'

function Get-LLMKitServiceVersion { $script:ServiceVersion }

function Assert-ServicePrerequisites {
    $missing = New-Object System.Collections.ArrayList
    foreach ($fn in @(
            'Get-ObjectProp', 'Read-TextFileUtf8', 'Resolve-ExecutablePath', 'Invoke-Process',
            'Get-ToolCatalog', 'Get-ToolStatus', 'Find-InstallArtifacts', 'Get-ArtifactOwnerToolId',
            'Get-DefaultArtifactRoots', 'Get-ConfigTargets', 'Get-ProviderCatalog',
            'Get-UserPathInfo', 'Get-PathEntryList', 'Get-NormalizedPathEntry', 'ConvertTo-CsvList',
            'Test-IsElevated', 'Protect-SensitiveText'
        )) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) { [void]$missing.Add($fn) }
    }
    if ($missing.Count -gt 0) {
        throw ('服务层缺少前置函数：' + ($missing -join '、') +
            '。请先导入 LLMKit.psm1 / LLMKit.Install.psm1 / LLMKit.Tools.psm1 / LLMKit.Config.psm1。')
    }
}

function Resolve-ServiceConfigRoot {
    param([string]$ConfigRoot)
    if (-not [string]::IsNullOrEmpty($ConfigRoot)) { return $ConfigRoot }
    $here = $PSScriptRoot
    if ([string]::IsNullOrEmpty($here)) { $here = (Get-Location).Path }
    return (Split-Path -Parent (Split-Path -Parent $here))
}

# ======================================================================
#  动作清单
# ======================================================================

function Get-LLMKitActionCatalog {
    <#
        界面据此渲染按钮，不硬编码。scope 决定它出现在哪：
          global  首页/全局
          tool    工具页（需要 TargetId）
          session 历史页（需要 TargetId = 日志路径）
        destructive=true 的动作必须二次确认，且只有显式 apply 才会真正动手。
    #>
    return @(
        [pscustomobject]([ordered]@{
                id = 'tool-install'; label = '安装 / 重装'; scope = 'tool'; destructive = $true
                desc = '按配置里的层顺序安装；已装过则先备份旧目录'
                options = @('cleanArtifacts', 'tierId')
            })
        [pscustomobject]([ordered]@{
                id = 'tool-uninstall'; label = '卸载'; scope = 'tool'; destructive = $true
                desc = '把安装本体、残留与它加进 PATH 的条目挪到备份区（不删除，可还原）'
                options = @('removeUserConfig')
            })
        [pscustomobject]([ordered]@{
                id = 'tool-verify'; label = '验证可用性'; scope = 'tool'; destructive = $false
                desc = '只读：逐层验证这个工具能不能真的跑起来'
            })
        [pscustomobject]([ordered]@{
                id = 'tool-artifacts'; label = '清理安装残留'; scope = 'tool'; destructive = $true
                desc = '只清理，不安装。把上次安装/升级中断留下的残渣挪到备份区；组内有能跑的程序时会自动跳过'
            })
        [pscustomobject]([ordered]@{
                id = 'tool-resolve-conflicts'; label = '合并多份副本'; scope = 'tool'; destructive = $true
                desc = '同一个工具装了多份、互相顶掉时：保留 PATH 实际命中的那份，其余挪到备份区（不删除，可还原）'
            })
        [pscustomobject]([ordered]@{
                id = 'config-write'; label = '写入配置'; scope = 'global'; destructive = $true
                desc = '把选定渠道的 base_url / key / 模型写进各工具配置，只改受管字段'
                options = @('provider', 'authTokenEnvVar', 'skipOnboarding', 'toolIds', 'model')
            })
        [pscustomobject]([ordered]@{
                id = 'diagnose'; label = '生成诊断报告'; scope = 'global'; destructive = $false
                desc = '只读：汇总环境与安装情况，自动脱敏后复制到剪贴板'
            })
        [pscustomobject]([ordered]@{
                id = 'restore'; label = '还原这次改动'; scope = 'session'; destructive = $true
                desc = '按会话日志把改动还原（PATH、安装目录、配置文件）'
            })
    )
}

function Get-LLMKitAction {
    param([Parameter(Mandatory = $true)][string]$ActionId)
    $hit = @(Get-LLMKitActionCatalog | Where-Object { $_.id -eq $ActionId })
    if ($hit.Count -eq 0) { throw ('未知动作：' + $ActionId) }
    return $hit[0]
}

function Get-LLMKitActionCommandLine {
    <#
        动作 → 完整命令行（字符串）+ 参数数组。
        界面把字符串显示出来给用户看（也是"你可以自己重跑"的证据），
        用参数数组去真正执行。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ActionId,
        [Parameter(Mandatory = $true)][string]$ConfigRoot,
        [string]$TargetId = '',
        [string]$TierId = '',
        [switch]$Apply,
        [switch]$CleanArtifacts,
        [switch]$RemoveUserConfig,
        [string]$ProviderId = '',
        [string]$AuthTokenEnvVar = '',
        [string[]]$ToolIds = @(),
        [string]$Model = '',
        [switch]$SkipOnboarding,
        [string]$Proxy = ''
    )
    Assert-ServicePrerequisites
    $action = Get-LLMKitAction -ActionId $ActionId
    if ($action.scope -ne 'global' -and [string]::IsNullOrEmpty($TargetId)) {
        throw ('动作 ' + $ActionId + ' 需要指定 TargetId。')
    }

    $a = New-Object System.Collections.ArrayList
    $add = { param($x) if (-not [string]::IsNullOrEmpty($x)) { [void]$a.Add($x) } }

    switch ($ActionId) {
        'tool-install' {
            & $add '-SkipCheck'; & $add '-SkipDeps'; & $add '-IncludeTools'
            & $add '-OnlyTools'; & $add $TargetId
            & $add '-Force'
            if ($TierId) {
                # 先校验层名真的存在。引擎收到一个不存在的 -OnlyTiers 会安静地什么都不装，
                # 用户只看到"成功了但没装上" —— 这比直接报错难查得多。
                $hitTool = @((Get-ToolCatalog -ConfigRoot $ConfigRoot).tools.tools | Where-Object { $_.id -eq $TargetId })
                if ($hitTool.Count -gt 0) {
                    $knownTiers = @($hitTool[0].install.tiers | ForEach-Object { [string]$_.id })
                    if ($knownTiers -notcontains $TierId) {
                        throw ('工具 ' + $TargetId + ' 没有叫 ' + $TierId + ' 的安装层。可用：' + ($knownTiers -join '、'))
                    }
                }
                & $add '-OnlyTiers'; & $add $TierId
            }
            if ($CleanArtifacts) { & $add '-CleanArtifacts' }
        }
        'tool-uninstall' {
            & $add '-Uninstall'; & $add $TargetId
            & $add '-SkipCheck'; & $add '-SkipDeps'
            if ($RemoveUserConfig) { & $add '-RemoveUserConfig' }
        }
        'tool-verify' {
            & $add '-SkipCheck'; & $add '-SkipDeps'; & $add '-Verify'
            & $add '-OnlyTools'; & $add $TargetId
        }
        'tool-artifacts' {
            # 只清理残留，不安装。之前用 -IncludeTools -CleanArtifacts -Force，
            # 那会顺带把工具重装一遍 —— 用户点"清理残留"并不等于要装它。
            & $add '-CleanOnly'
            & $add '-OnlyTools'; & $add $TargetId
        }
        'tool-resolve-conflicts' {
            # 只合并副本，不安装、不下载：-ResolveConflicts 保留 PATH 命中那份，其余挪到备份区。
            # 演练实测：不加 -Force 也能只做冲突处理，不加 -Apply 只打印计划。
            & $add '-SkipCheck'; & $add '-SkipDeps'; & $add '-IncludeTools'
            & $add '-OnlyTools'; & $add $TargetId
            & $add '-ResolveConflicts'
        }
        'config-write' {
            & $add '-SkipCheck'; & $add '-SkipDeps'
            & $add '-Configure'; & $add $ProviderId
            if ($AuthTokenEnvVar) { & $add '-AuthTokenEnvVar'; & $add $AuthTokenEnvVar }
            if ($ToolIds.Count -gt 0) { & $add '-OnlyTools'; & $add ($ToolIds -join ',') }
            if ($Model) { & $add '-Model'; & $add $Model }
            if ($SkipOnboarding) { & $add '-SkipOnboarding' }
        }
        'diagnose' {
            & $add '-SkipCheck'; & $add '-SkipDeps'; & $add '-Diagnose'; & $add '-CopyDiagnostic'
            if ($ProviderId) { & $add '-Configure'; & $add $ProviderId }
        }
        'restore' {
            & $add '-Restore'; & $add $TargetId
        }
        default { throw ('动作 ' + $ActionId + ' 还没接命令行。') }
    }

    if ($Proxy) { & $add '-Proxy'; & $add $Proxy }
    # 安全默认：只有 destructive 的动作、且调用方明确 apply 了，才追加 -Apply
    if ($Apply -and $action.destructive) { & $add '-Apply' }
    & $add '-NoColor'

    # 去重（-SkipCheck / -SkipDeps 可能在多处被加）
    $seen = @{}
    $final = New-Object System.Collections.ArrayList
    foreach ($x in $a) {
        if ($seen.ContainsKey($x)) { continue }
        $seen[$x] = $true
        [void]$final.Add($x)
    }
    $args = @($final)
    $setup = Join-Path (Resolve-ServiceConfigRoot -ConfigRoot $ConfigRoot) 'src\ps\Setup-LLMKit.ps1'
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $setup + '" ' + ($args -join ' ')
    return [pscustomobject]([ordered]@{
            actionId = $ActionId; targetId = $TargetId
            setupPath = $setup; arguments = $args
            commandLine = $cmd.Trim()
            destructive = [bool]$action.destructive
            willApply = ($Apply -and $action.destructive)
        })
}

function Get-LLMKitOverview {
    <#
        首页数据：一次扫描把"所有工具 + 依赖 + 残留"都拿到。
        刻意只扫一遍残留目录再按归属分组 —— 否则每个工具各扫一遍，纯属浪费。
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigRoot,
        [switch]$WithTools = $true
    )
    Assert-ServicePrerequisites
    $ConfigRoot = Resolve-ServiceConfigRoot -ConfigRoot $ConfigRoot
    $cat = Get-ToolCatalog -ConfigRoot $ConfigRoot

    # 残留：扫一次，按归属分组
    $byOwner = @{}
    $unassigned = New-Object System.Collections.ArrayList
    $scan = $null
    try {
        $scan = Find-InstallArtifacts -Roots @(Get-DefaultArtifactRoots) -MaxDepth 3
        foreach ($g in @($scan.groups)) {
            $owner = Get-ArtifactOwnerToolId -Group $g
            if ([string]::IsNullOrEmpty($owner)) { [void]$unassigned.Add($g); continue }
            if (-not $byOwner.ContainsKey($owner)) { $byOwner[$owner] = New-Object System.Collections.ArrayList }
            [void]$byOwner[$owner].Add($g)
        }
    } catch { }


    $tools = New-Object System.Collections.ArrayList
    if ($WithTools) {
        # npm 的 prefix 现问一次，供 npm shim 探测使用
        $prefix = ''
        $npmExe = Resolve-ExecutablePath -Name 'npm'
        if ($npmExe) {
            $nr = Invoke-Process -FilePath $npmExe -Arguments @('prefix', '-g') -TimeoutMs 20000
            if ($nr.stdout) {
                $pl = @($nr.stdout -split "`n" | Where-Object { $_.Trim() })
                if ($pl.Count -gt 0) { $prefix = $pl[$pl.Count - 1].Trim() }
            }
        }
        $minState = [pscustomobject]@{ npmPrefix = [pscustomobject]@{ path = $prefix } }

        foreach ($tool in @($cat.tools.tools)) {
            $st = $null
            try { $st = Get-ToolStatus -Tool $tool -State $minState } catch { $st = $null }
            $arts = @()
            if ($byOwner.ContainsKey($tool.id)) { $arts = @($byOwner[$tool.id]) }
            $issues = New-Object System.Collections.ArrayList
            if ($st -and $st.conflict) { [void]$issues.Add('多份安装共存') }
            if ($arts.Count -gt 0) { [void]$issues.Add($arts.Count.ToString() + ' 组安装残留') }
            if (-not ($st -and $st.installed)) { [void]$issues.Add('未安装') }
            [void]$tools.Add([pscustomobject]([ordered]@{
                        id = $tool.id; name = $tool.name; vendor = $tool.vendor; kind = $tool.kind
                        # 全是 manual 层的工具（Python / PyCharm）没有"安装器替你装"这回事，首页按钮据此改叫「手动安装」
                        canAutoInstall = (@(@(Get-ObjectProp -Object (Get-ObjectProp -Object $tool -Name 'install') -Name 'tiers') | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'type') -ne 'manual' }).Count -gt 0)
                        # 角色：agent = 你要用它干活；provider-manager = 帮你管渠道的配套工具。
                        # 界面据此分组，不再把 cc-switch 和五个智能体并排混在一起。
                        role = [string](Get-ObjectProp -Object $tool -Name 'role')
                        # 优先级：只在配置里有意义，透出来是为了让"顺序"这件事可断言。
                        # 真正的排序在下面做，不靠 tools.json 的书写顺序。
                        priority = [int](Get-ObjectProp -Object $tool -Name 'priority')
                        manages = @(Get-ObjectProp -Object $tool -Name 'manages' | Where-Object { $_ })
                        homeUrl = $tool.homeUrl; notes = (Get-ObjectProp -Object $tool -Name 'notes')
                        installed = [bool]($st -and $st.installed)
                        version = [string]$(if ($st) { $st.version } else { '' })
                        executable = [string]$(if ($st) { $st.executable } else { '' })
                        installCount = [int]$(if ($st) { $st.installCount } else { 0 })
                        conflict = [bool]($st -and $st.conflict)
                        installations = @($(if ($st) { $st.installations } else { @() }))
                        artifactGroups = @($arts | ForEach-Object { $_.dir })
                        artifactCount = $arts.Count
                        issues = @($issues)
                        clean = (@($issues).Count -eq 0)
                    }))
        }
    }

    # 顺序：**智能体在前、配套工具在后，组内按 priority**。
    # 这件事以前没人做 —— 顶栏照着 tools.json 的书写顺序渲染，于是 cc-switch（写在第二位）
    # 跑到了四个智能体前面，中间那句"下面是配套工具"的分隔线后面跟着一堆智能体，等于在骗人。
    # 现在把顺序定死在 role + priority 上：任何人往 JSON 中间插一个工具，界面顺序都不会跟着乱。
    $tools = @($tools | Sort-Object `
            @{ Expression = { if ([string]$_.role -eq 'agent') { 0 } else { 1 } } }, `
            @{ Expression = { [int]$_.priority } }, `
            @{ Expression = { [string]$_.id } })

    $installedCount = @($tools | Where-Object { $_.installed }).Count
    return [pscustomobject]([ordered]@{
            schemaVersion = '0.1.0'
            engine        = 'LLMKit.Service/' + $script:ServiceVersion
            generatedAt   = (Get-Date).ToString('o')
            configRoot    = $ConfigRoot
            # 这里原来写死的 $false。界面把它当"这次要不要管理员"的依据，
            # 在管理员账号下报出 false 就是在骗人 —— 改成真判定。
            admin         = (Test-IsElevated)
            tools         = @($tools)
            unassignedArtifacts = @($unassigned | ForEach-Object { $_.dir })
            summary       = [ordered]@{
                toolTotal      = @($tools).Count
                toolInstalled  = $installedCount
                toolMissing    = (@($tools).Count - $installedCount)
                toolWithIssues = @($tools | Where-Object { -not $_.clean -and $_.installed }).Count
                depMissing     = @($deps | Where-Object { -not $_.installed }).Count
            }
        })
}

function Get-LLMKitPackageStatus {
    <#
        检查一组 Python 包装没装、是什么版本。
        只读：跑**一次** python，一个包一行输出（name=version），不联网、不装包、不改任何文件。
        刻意不用 `pip list` —— 实测本机 pip list 超过 3 分钟没返回（解释器一多更糟），
        而 importlib 这条路 12 个包 160 ms 就完了。
    #>
    param(
        [Parameter(Mandatory = $true)]$Packages,
        [string]$PythonPath = ''
    )
    $out = New-Object System.Collections.ArrayList
    $exe = $PythonPath
    if ([string]::IsNullOrEmpty($exe)) { $exe = Resolve-ExecutablePath -Name 'python' }
    foreach ($pkg in @($Packages)) {
        [void]$out.Add([pscustomobject]([ordered]@{
                    name      = [string](Get-ObjectProp -Object $pkg -Name 'name')
                    module    = [string](Get-ObjectProp -Object $pkg -Name 'module')
                    why       = [string](Get-ObjectProp -Object $pkg -Name 'why')
                    installed = $false
                    version   = ''
                    unknown   = $true
                }))
    }
    if ([string]::IsNullOrEmpty($exe) -or $out.Count -eq 0) { return @($out) }

    # 名字只允许字母数字和 . _ -（清单是我们自己的，但仍然校验一遍，别把奇怪的东西喂给解释器）
    $safe = @($out | Where-Object { $_.name -match '^[A-Za-z0-9._-]+$' -and ($_.module -eq '' -or $_.module -match '^[A-Za-z0-9._]+$') })
    if ($safe.Count -eq 0) { return @($out) }

    $pairs = ($safe | ForEach-Object { $_.name + '|' + $(if ($_.module) { $_.module } else { $_.name }) }) -join ','
    # 为什么写临时文件而不是 python -c：PowerShell 5.1 把参数交给原生程序时会把双引号吃掉，
    # 拼出来的 python 代码会静默变形（实测 SyntaxError: unterminated string literal）。
    # 写成 .py 文件再执行，就没有这一层引号问题，也能一眼看懂实际跑的是什么。
    $tpl = @'
import importlib.util as u, importlib.metadata as m
for pair in __PAYLOAD__.split(','):
    dist, mod = pair.split('|')
    ok = False
    try:
        ok = u.find_spec(mod) is not None
    except Exception:
        ok = False
    ver = ''
    if ok:
        try:
            ver = m.version(dist)
        except Exception:
            ver = '?'
    print(dist + '=' + ver)
'@
    $code = $tpl.Replace('__PAYLOAD__', ('"' + $pairs + '"'))
    $probeFile = Join-Path ([System.IO.Path]::GetTempPath()) ('llmkit-pkgprobe-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.py')
    try {
        [System.IO.File]::WriteAllText($probeFile, $code, (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-Process -FilePath $exe -Arguments @($probeFile) -TimeoutMs 15000
    } finally {
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
    }
    $text = [string]$r.stdout
    if ([string]::IsNullOrWhiteSpace($text)) { return @($out) }
    $map = @{}
    foreach ($line in ($text -split "`n")) {
        $s = $line.Trim()
        if (-not $s) { continue }
        $eq = $s.IndexOf('=')
        if ($eq -le 0) { continue }
        $map[$s.Substring(0, $eq)] = $s.Substring($eq + 1)
    }
    for ($i = 0; $i -lt $out.Count; $i++) {
        $nm = $out[$i].name
        if (-not $map.ContainsKey($nm)) { continue }
        $ver = [string]$map[$nm]
        $out[$i] = [pscustomobject]([ordered]@{
                name = $nm; module = $out[$i].module; why = $out[$i].why
                installed = ($ver -ne ''); version = $ver; unknown = $false
            })
    }
    return @($out)
}
function Get-LLMKitConfiguredModel {
    <#
        从**已经写好的配置文件**里读出当前的模型名，界面上好显示"现在的模型是哪个"。
        只认 kind=json-object-patch 且登记了模型字段的目标。guidance 目标（OpenCode 的嵌套
        provider、cc-switch 的 SQLite、dsh 的私有凭据）一律返回空串 —— 与其猜一种读法，
        不如如实说"读不出来，你自己在它界面里看"。
    #>
    param([Parameter(Mandatory = $true)][string]$ToolId, [string]$ConfigRoot)
    foreach ($c in @(Get-ConfigTargets -ConfigRoot $ConfigRoot -ToolIds @($ToolId))) {
        if ($c.kind -ne 'json-object-patch') { continue }
        $names = @(@($c.entries) | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'name') })
        $modelNames = @($names | Where-Object { $_ -match 'MODEL|模型' })
        if ($modelNames.Count -eq 0) { continue }
        $file = [System.Environment]::ExpandEnvironmentVariables([string]$c.path)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try {
            $obj = (Read-TextFileUtf8 -Path $file) | ConvertFrom-Json
            $node = $obj
            if ($c.objectPath) {
                foreach ($seg in @(([string]$c.objectPath) -split '\.')) {
                    if ($null -eq $node) { break }
                    $node = Get-ObjectProp -Object $node -Name $seg
                }
            }
            foreach ($nm in $modelNames) {
                $v = Get-ObjectProp -Object $node -Name $nm
                if ($v) { return [string]$v }
            }
        } catch { }
    }
    return ''
}

function Get-LLMKitToolDetail {
    <#
        单个工具页要的全部信息：状态、全部安装位置、可用安装层、专属配置目标、残留、可用动作。
        刻意把"这个工具能做什么"一起返回 —— 页面不用自己判断该显示哪些按钮。
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigRoot,
        [Parameter(Mandatory = $true)][string]$ToolId
    )
    Assert-ServicePrerequisites
    $ConfigRoot = Resolve-ServiceConfigRoot -ConfigRoot $ConfigRoot
    $cat = Get-ToolCatalog -ConfigRoot $ConfigRoot
    $hit = @($cat.tools.tools | Where-Object { $_.id -eq $ToolId })
    if ($hit.Count -eq 0) {
        throw ('未知工具：' + $ToolId + '。可用：' + (($cat.tools.tools | ForEach-Object { $_.id }) -join '、'))
    }
    $tool = $hit[0]

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
    $artifacts = @(Get-LLMKitToolArtifacts -ToolId $ToolId)

    # 可用安装层：界面上要逐层展示"会怎么装、要不要管理员、来源是什么"
    $tiers = New-Object System.Collections.ArrayList
    foreach ($t in @($tool.install.tiers)) {
        [void]$tiers.Add([pscustomobject]([ordered]@{
                    id = [string]$t.id; label = [string]$t.label; detail = [string]$t.detail
                    type = [string]$t.type; needsAdmin = [bool]$t.needsAdmin
                    verified = [bool](Get-ObjectProp -Object $t -Name 'verified')
                    installRoot = [string](Get-ObjectProp -Object $t -Name 'installRoot')
                    pathEntries = @(Get-ObjectProp -Object $t -Name 'pathEntries')
                    scriptUrl = [string](Get-ObjectProp -Object $t -Name 'scriptUrl')
                    package = [string](Get-ObjectProp -Object $t -Name 'package')
                    manualUrl = [string](Get-ObjectProp -Object $t -Name 'manualUrl')
                    isManual = ([string]$t.type -eq 'manual')
                    isPreferred = ([string]$t.id -eq [string]$tool.install.preferred)
                }))
    }

    # 有没有「安装器能真的替你装」的层？全是 manual 时（Python / PyCharm 就是这样），
    # 点「安装 / 重装」什么都不会发生 —— 那种工具只该给下载页，不该给安装按钮。
    $canAutoInstall = (@($tiers | Where-Object { -not $_.isManual }).Count -gt 0)
    $manualUrl = ''
    foreach ($t in @(Get-ObjectProp -Object (Get-ObjectProp -Object $tool -Name 'install') -Name 'tiers')) {
        $u = [string](Get-ObjectProp -Object $t -Name 'manualUrl')
        if (-not [string]::IsNullOrEmpty($u)) { $manualUrl = $u; break }
    }

    $cfgTargets = New-Object System.Collections.ArrayList
    foreach ($c in @(Get-ConfigTargets -ConfigRoot $ConfigRoot -ToolIds @($ToolId))) {
        $p = [System.Environment]::ExpandEnvironmentVariables($c.path)
        $exists = Test-Path -LiteralPath $p -PathType Leaf
        # 占位符检测：没拿到 key 时写进去的是「<在这里粘贴你的 API Key>」这种值。
        # 界面要据此直接告诉用户「改哪个文件的哪一行」，所以把命中项一起发出去，
        # 免得前端去解析文件、也多一次请求。
        # 注意：path 一律用模版写法（%USERPROFILE%\...），绝不发绝对路径 —— 界面不显示本机用户名。
        $pending = @()
        $filled = 0
        if ($exists -and $c.kind -like 'json*') {
            try {
                $docX = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
                $scope = $docX
                if ($c.objectPath) { $scope = Get-ObjectProp -Object $docX -Name $c.objectPath }
                if ($scope) {
                    foreach ($e in @($c.entries)) {
                        $nm = [string](Get-ObjectProp -Object $e -Name 'name')
                        if ([string]::IsNullOrEmpty($nm)) { continue }
                        $val = [string](Get-ObjectProp -Object $scope -Name $nm)
                        if ($val -match '^<.+>$') { $pending += [pscustomobject]@{ name = $nm; placeholder = $val } }
                        elseif (-not [string]::IsNullOrWhiteSpace($val)) { $filled++ }
                    }
                }
            } catch { }
        }
        [void]$cfgTargets.Add([pscustomobject]([ordered]@{
                    id = $c.id; label = $c.label; path = $c.path; kind = $c.kind
                    verified = $c.verified; notes = $c.notes
                    exists = $exists
                    managedKeys = @($c.entries | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'name') })
                    pending = @($pending)
                    filled = $filled
                }))
    }

    # 官方安装器装出来的工具（当前是 python）不在我们管理的目录里：卸载按钮不给，
    # 只把原因说清楚 —— 给了按钮却搬不动（或搬到一半）比不给更糟。
    $uninstallCfg = Get-ObjectProp -Object $tool -Name 'uninstall'
    $uninstallOk = $true
    $uninstallReason = ''
    if ($uninstallCfg) {
        $supp = Get-ObjectProp -Object $uninstallCfg -Name 'supported'
        if ($null -ne $supp -and -not [bool]$supp) {
            $uninstallOk = $false
            $uninstallReason = [string](Get-ObjectProp -Object $uninstallCfg -Name 'reason')
        }
    }
    # 这个工具可用的动作
    $actions = New-Object System.Collections.ArrayList
    foreach ($a in @(Get-LLMKitActionCatalog | Where-Object { $_.scope -eq 'tool' })) {
        if ($a.id -eq 'tool-install' -and -not $canAutoInstall) { continue }
        if ($a.id -eq 'tool-artifacts' -and $artifacts.Count -eq 0) { continue }
        if ($a.id -eq 'tool-uninstall' -and -not $uninstallOk) { continue }
        if ($a.id -eq 'tool-resolve-conflicts' -and -not $st.conflict) { continue }
        [void]$actions.Add($a.id)
    }
    # 刻意不因为"已装"就拿掉 tool-install：这个动作叫"安装 / 重装"，
    # 而装坏了（残留文件、半截升级）恰恰是最需要重装的时候。

      # 模型：能不能直接写、写在哪、cc-switch 管不管得着、以及现在实际是哪个。
      # "能不能写"来自配置（tools.json 的 models.writable），不是界面自己猜的。
      $modelMeta = Get-ObjectProp -Object $tool -Name 'models'
      $modelInfo = [ordered]@{ writable = $false; field = ''; note = ''; alsoViaCcSwitch = $false; current = '' }
      if ($modelMeta) {
          $modelInfo.writable = [bool](Get-ObjectProp -Object $modelMeta -Name 'writable')
          $modelInfo.field = [string](Get-ObjectProp -Object $modelMeta -Name 'field')
          $modelInfo.note = [string](Get-ObjectProp -Object $modelMeta -Name 'note')
          $modelInfo.alsoViaCcSwitch = [bool](Get-ObjectProp -Object $modelMeta -Name 'alsoViaCcSwitch')
      }
      $modelInfo.current = Get-LLMKitConfiguredModel -ToolId $ToolId -ConfigRoot $ConfigRoot

      # 冲突时界面要说清"保留哪份、挪哪几份"。保留规则与引擎完全一致：PATH 实际命中的那份。
      $conflictKeep = ''
      $conflictMove = @()
      $onlyLauncher = [bool]$st.onlyLauncher
      if ($st.conflict) {
          $execInstalls = @(@($st.installations) | Where-Object { $_.kind -eq 'path' -or $_.kind -eq 'file' })
          $conflictKeep = [string]$st.executable
          $conflictMove = @($execInstalls | Where-Object { [string]$_.path -ne $conflictKeep } | ForEach-Object { [string]$_.path })
      }

      # 常用第三方库：只有登记了 packages 的工具（目前是 python）才检测。
      # 只读、一次性调用解释器，不装包、不联网；没装解释器时返回空。
      $pkgMeta = @(Get-ObjectProp -Object $tool -Name 'packages' | Where-Object { $_ })
      $pkgInfo = @()
      if ($pkgMeta.Count -gt 0) {
          $pyExe = ''
          if ($st.installed -and $st.executable) { $pyExe = [string]$st.executable }
          $pkgInfo = @(Get-LLMKitPackageStatus -Packages $pkgMeta -PythonPath $pyExe)
      }

    return [pscustomobject]([ordered]@{
            schemaVersion = '0.1.0'
            engine        = 'LLMKit.Service/' + $script:ServiceVersion
            generatedAt   = (Get-Date).ToString('o')
            id = $tool.id; name = $tool.name; vendor = $tool.vendor; kind = $tool.kind
            # 角色：agent = 你要用它干活；provider-manager = 帮你管渠道（cc-switch）；
            # companion = 帮你备环境（python 这类运行时）。后两种都算"配套工具"，排在智能体之后。
            role = [string](Get-ObjectProp -Object $tool -Name 'role')
            manages = @(Get-ObjectProp -Object $tool -Name 'manages' | Where-Object { $_ })
            # 卸载不可用时给出原因（界面据此把按钮换成一句说明，而不是让人点了才知道不行）
            uninstallReason = $uninstallReason
            models = [pscustomobject]$modelInfo
            # 配置那一节怎么呈现：tutorial = 只给官方教程，不给写入按钮（例如 claude-code）
            configureMode = [string](Get-ObjectProp -Object $tool -Name 'configureMode')
            # 操作步骤：写在 tools.json 里（每个工具不一样），界面只按顺序渲染，不拼文案
            guide = (Get-ObjectProp -Object $tool -Name 'guide')
            # 这一步要做的事在别的工具界面里（例如 cc-switch）→ 给"在那边怎么点"的步骤。
            # 界面照它渲染；本工具仍然一个字节都不写那些工具的配置。
            inApp = (Get-ObjectProp -Object $tool -Name 'inApp')
            homeUrl = $tool.homeUrl; notes = (Get-ObjectProp -Object $tool -Name 'notes')
            installed = $st.installed; version = $st.version; executable = $st.executable
            # 多副本冲突：保留哪份、会挪走哪几份（界面拿它去写确认框）
            conflictKeep = $conflictKeep
            # 版本低于要求（例如 Node 需要 v18+）：界面据此提示，别等别的工具装不上才发现
            minMajor = $st.minMajor
            belowMinVersion = [bool]$st.belowMinVersion
            conflictMove = @($conflictMove)
            # 只找到 py 启动器、没有 python.exe —— 多半是安装时没勾 Add python.exe to PATH
            onlyLauncher = $onlyLauncher
            # 常用第三方库的检测结果（只读）；没登记 packages 时是空数组
            packages = @($pkgInfo)
            installCount = $st.installCount; conflict = $st.conflict
            installations = @($st.installations)
            tiers = @($tiers)
            preferredTier = [string]$tool.install.preferred
            canAutoInstall = $canAutoInstall
            manualUrl = $manualUrl
            configTargets = @($cfgTargets)
            artifacts = @($artifacts | ForEach-Object { [pscustomobject]@{ dir = $_.dir; members = @($_.members) } })
            actions = @($actions)
            # 工具页要在一次 GET 里就拿到「怎么启动」：不发 POST、不缓存、也不起进程
            launch = (Get-LLMKitToolLaunchSummary -ConfigRoot $ConfigRoot -ToolId $ToolId)
        })
}

function Get-LLMKitProviderList {
    param([string]$ConfigRoot)
    Assert-ServicePrerequisites
    $ConfigRoot = Resolve-ServiceConfigRoot -ConfigRoot $ConfigRoot
    $out = New-Object System.Collections.ArrayList
    foreach ($p in @(Get-ProviderCatalog -ConfigRoot $ConfigRoot)) {
        [void]$out.Add([pscustomobject]([ordered]@{
                    id = $p.id; name = $p.name; region = $p.region; tags = @($p.tags)
                    registerUrl = $p.registerUrl; keyUrl = $p.keyUrl; docsUrl = $p.docsUrl
                    anthropicBaseUrl = $p.anthropicBaseUrl; openaiBaseUrl = $p.openaiBaseUrl
                    models = @($p.models); freeQuota = $p.freeQuota
                    needsRealName = [bool]$p.needsRealName; needsCreditCard = [bool]$p.needsCreditCard
                    # 官方接入说明按渠道存（例如 DeepSeek 给 Claude Code 的 9 个环境变量），原样透传给前端
                    integrations = (Get-ObjectProp -Object $p -Name 'integrations')
                    verified = [bool](Get-ObjectProp -Object $p -Name 'verified')
                }))
    }
    return @($out)
}

function Get-LLMKitSessionList {
    <# 历史页：列出安装会话，供还原 #>
    param([string]$StateDir, [int]$Limit = 30)
    Assert-ServicePrerequisites
    if ([string]::IsNullOrEmpty($StateDir)) { throw '必须指定 StateDir。' }
    $sessionsDir = Join-Path $StateDir 'sessions'
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $sessionsDir)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $sessionsDir -Filter *.json -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First $Limit)
    foreach ($f in $files) {
        try {
            $doc = Read-TextFileUtf8 -Path $f.FullName | ConvertFrom-Json
            [void]$out.Add([pscustomobject]([ordered]@{
                        path = $f.FullName; sessionId = $doc.sessionId; startedAt = $doc.startedAt
                        dryRun = [bool]$doc.dryRun; host = $doc.host
                        succeeded = [int](Get-ObjectProp -Object $doc.summary -Name 'succeeded')
                        failed = [int](Get-ObjectProp -Object $doc.summary -Name 'failed')
                        planned = [int](Get-ObjectProp -Object $doc.summary -Name 'planned')
                        entryCount = @($doc.entries).Count
                        kinds = @(@($doc.entries) | ForEach-Object { ([string]$_.action -split '\.')[0] } | Sort-Object -Unique)
                    }))
        } catch { }
    }
    return @($out)
}

function Get-LLMKitConfigOverview {
    <#
        配置页要的全部信息：每个工具登记了哪些配置文件目标、每个目标有哪些受管字段、
        文件在不在。刻意由服务端给整份清单，而不是让界面自己一个个工具去问 ——
        界面拼出来的清单和引擎真正会写的那份很容易走偏。
    #>
    param([string]$ConfigRoot)
    Assert-ServicePrerequisites
    $ConfigRoot = Resolve-ServiceConfigRoot -ConfigRoot $ConfigRoot
    $cat = Get-ToolCatalog -ConfigRoot $ConfigRoot
    $tools = New-Object System.Collections.ArrayList
    $targetTotal = 0
    $existingTotal = 0
    foreach ($tool in @($cat.tools.tools)) {
        $targets = New-Object System.Collections.ArrayList
        foreach ($c in @(Get-ConfigTargets -ConfigRoot $ConfigRoot -ToolIds @([string]$tool.id))) {
            $p = [System.Environment]::ExpandEnvironmentVariables([string]$c.path)
            $exists = (Test-Path -LiteralPath $p -PathType Leaf)
            $targetTotal++
            if ($exists) { $existingTotal++ }
            [void]$targets.Add([pscustomobject]([ordered]@{
                        id = $c.id; label = $c.label; path = $c.path; kind = $c.kind
                        verified = [bool]$c.verified
                        notes = [string](Get-ObjectProp -Object $c -Name 'notes')
                        exists = $exists
                        managedKeys = @($c.entries | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'name') })
                    }))
        }
        [void]$tools.Add([pscustomobject]([ordered]@{
                    id = $tool.id; name = $tool.name; targets = @($targets)
                }))
    }
    return [pscustomobject]([ordered]@{
            schemaVersion = '0.1.0'
            engine        = 'LLMKit.Service/' + $script:ServiceVersion
            generatedAt   = (Get-Date).ToString('o')
            tools         = @($tools)
            targetTotal   = $targetTotal
            existingTotal = $existingTotal
        })
}

function Get-LLMKitDiagnosticReport {
    <#
        诊断页：取最近一次生成的报告。
        读出来还会再过一遍 Protect-SensitiveText —— 那个文件可能是旧版本写的、
        也可能被人手改过。给用户看的东西不该建立在"它当初是干净的"这个假设上。
    #>
    param([Parameter(Mandatory = $true)][string]$OutDir)
    Assert-ServicePrerequisites
    $result = [ordered]@{
        schemaVersion = '0.1.0'
        exists = $false
        fileName = ''
        path = ''
        generatedAt = ''
        bytes = 0
        text = ''
    }
    if (-not (Test-Path -LiteralPath $OutDir)) { return [pscustomobject]$result }
    $hit = @(Get-ChildItem -LiteralPath $OutDir -Filter 'diagnostic-*.md' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($hit.Count -eq 0) { return [pscustomobject]$result }
    $text = Read-TextFileUtf8 -Path $hit[0].FullName
    try { $text = Protect-SensitiveText -Text $text } catch { }
    $result.exists = $true
    $result.fileName = $hit[0].Name
    $result.path = $hit[0].FullName
    $result.generatedAt = $hit[0].LastWriteTime.ToString('o')
    $result.bytes = $hit[0].Length
    $result.text = $text
    return [pscustomobject]$result
}

function Get-LLMKitToolLaunchSummary {
    <#
        工具页要的启动信息汇总：一次拿全两种模式，界面不用发两次请求。
        只读 —— 起进程是 Web 层的事（见 Get-LLMKitLaunchSpec 的注释）。
    #>
    param([string]$ConfigRoot, [Parameter(Mandatory = $true)][string]$ToolId)
    $interactive = Get-LLMKitLaunchSpec -ConfigRoot $ConfigRoot -ToolId $ToolId -Mode 'interactive'
    $smoke = Get-LLMKitLaunchSpec -ConfigRoot $ConfigRoot -ToolId $ToolId -Mode 'smoke'
    return [pscustomobject]([ordered]@{
            ok                 = $interactive.ok
            code               = $interactive.code
            reason             = $interactive.reason
            kind               = $interactive.kind
            executable         = $interactive.executable
            interactiveCommand = $interactive.commandLine
            port               = $interactive.port
            howTo              = @($interactive.howTo)
            uiHint             = $interactive.uiHint
            smokeOk            = $smoke.ok
            smokeCode          = $smoke.code
            smokeReason        = $smoke.reason
            smokeCommand       = $smoke.commandLine
        })
}

function Test-TcpPortInUse {
    <#
        这个端口现在有没有人在听。只连一下试试，不占端口 —— 真正的绑定由被启动的那个工具做。
        连接失败（ConnectionRefused）就是没人听；300ms 内连上就是有人在听。
    #>
    param([Parameter(Mandatory = $true)][int]$Port)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $done = $iar.AsyncWaitHandle.WaitOne(300)
        if (-not $done) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

function Find-FreeTcpPort {
    <#
        从 StartPort 起往上找一个没人听的端口。找不到就退回 StartPort —— 宁可让工具自己报"占用"，
        也不要悄悄换到一个我们没确认过的端口上。
    #>
    param([int]$StartPort = 3080, [int]$MaxTries = 20)
    for ($i = 0; $i -lt $MaxTries; $i++) {
        $port = $StartPort + $i
        if ($port -gt 65535) { break }
        if (-not (Test-TcpPortInUse -Port $port)) { return $port }
    }
    return $StartPort
}


function Get-LLMKitLaunchSpec {
    <#
        启动一个工具需要的信息。**只读**：这个函数不起任何进程。

        为什么不在这里起进程：启动一个交互式 CLI 会一直占着窗口，如果走任务队列，
        就等于把唯一任务槽锁死（队列同一时刻只允许一个任务）。所以起进程由 Web 层
        用 Start-Process 分离执行，立即返回。

        安全边界：只接受 toolId + mode，且两者都要过白名单；可执行文件与命令全部来自
        服务端配置与检测，请求体里给不了任何路径、命令或参数。
    #>
    param(
        [string]$ConfigRoot,
        [Parameter(Mandatory = $true)][string]$ToolId,
        [ValidateSet('interactive', 'smoke')][string]$Mode = 'interactive'
    )
    Assert-ServicePrerequisites
    $ConfigRoot = Resolve-ServiceConfigRoot -ConfigRoot $ConfigRoot

    $result = [ordered]@{
        schemaVersion = '0.1.0'
        toolId = $ToolId; name = ''; kind = ''; mode = $Mode
        ok = $false; reason = ''
        executable = ''; via = ''
        commandLine = ''; filePath = ''; arguments = @(); workingDir = ''
        port = 0          # 服务型工具实际会用的端口（0 = 不是服务型工具）
        howTo = @(); uiHint = ''
    }

    $cat = Get-ToolCatalog -ConfigRoot $ConfigRoot
    $hit = @($cat.tools.tools | Where-Object { $_.id -eq $ToolId })
    if ($hit.Count -eq 0) {
        $result.code = 'unknown-tool'
        $result.reason = '未知工具：' + $ToolId + '。可用：' + (($cat.tools.tools | ForEach-Object { $_.id }) -join '、')
        return [pscustomobject]$result
    }
    $tool = $hit[0]
    $result.name = [string]$tool.name
    $result.kind = [string]$tool.kind

    $launchCfg = Get-ObjectProp -Object $tool -Name 'launch'
    # 必须过滤空值：@($null) 在 PowerShell 里是"1 个元素的数组"，会让 howTo 变成一条空步骤（实测踩到）
    $howTo = @(Get-ObjectProp -Object $launchCfg -Name 'howTo' | Where-Object { $_ })
    if ($howTo.Count -gt 0) { $result.howTo = @($howTo | ForEach-Object { [string]$_ }) }
    $result.uiHint = [string](Get-ObjectProp -Object $launchCfg -Name 'uiHint')

    # 可执行文件用与工具页完全相同的检测解析，不另起一套口径
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
    $exe = [string]$st.executable
    $result.executable = $exe

        # 有些工具压根没有可常驻的窗口（Git 就是）：配置里标 disabled 时如实返回，不给一个点了没用的按钮
        $launchDisabled = Get-ObjectProp -Object $launchCfg -Name 'disabled'
        if ($null -ne $launchDisabled -and [bool]$launchDisabled) {
            $result.code = 'disabled-by-config'
            $result.reason = [string](Get-ObjectProp -Object $launchCfg -Name 'disabledReason')
            if ([string]::IsNullOrEmpty($result.reason)) { $result.reason = '这个工具没有可启动的交互界面。' }
            return [pscustomobject]$result
        }

    if (-not $st.installed) {
        $result.code = 'not-installed'
        $result.reason = '这个工具还没装。先把它装好，再回来启动。'
        return [pscustomobject]$result
    }
    if ([string]::IsNullOrEmpty($exe)) {
        $result.code = 'no-executable'
        $result.reason = '已经装了，但没能解析出可执行文件 —— 刷新一下状态，或者用安装层重装一次。'
        return [pscustomobject]$result
    }
    if (-not (Test-Path -LiteralPath $exe)) {
        $result.code = 'path-missing'
        $result.reason = '按配置找到的路径不存在：' + $exe + '。可能被移动或删除了。'
        return [pscustomobject]$result
    }
    $result.workingDir = [System.Environment]::GetFolderPath('UserProfile')

    if ($Mode -eq 'smoke') {
        $verifyCfg = Get-ObjectProp -Object $tool -Name 'verify'
        $smoke = [string](Get-ObjectProp -Object $verifyCfg -Name 'smokeTest')
        if ([string]::IsNullOrEmpty($smoke)) {
            $result.code = 'no-smoke'
            $result.reason = '这个工具没有登记一次性冒烟命令（GUI 应用，或者要启动整套界面才算跑起来）。'
            return [pscustomobject]$result
        }
        # 冒烟命令是配置里写死的整条命令行，交给 cmd 解析最稳。
        # 字符串来自我们自己的配置，不是用户输入 —— 这是它能被安全执行的前提。
        # 用 /k 而不是 /c：跑完窗口留着，用户才能看到模型回了什么。
        # 用 /c 的话窗口一闪就没，"验证过了吗"这个问题反而更说不清。
        $result.filePath = 'cmd.exe'
        $result.arguments = @('/k', $smoke)
        $result.commandLine = 'cmd.exe /k ' + $smoke
        $result.ok = $true
        return [pscustomobject]$result
    }

    if ($result.kind -eq 'gui') {
        # GUI 应用直接起它就对了，外面不需要套一层终端
        $result.filePath = $exe
        $result.arguments = @()
        $result.commandLine = $exe
    } else {
        # 命令行工具：开一个新窗口并留住（/k）。不加 /k 的话，报错会一闪就没，用户根本看不到。
        #
        # 启动参数只来自我们自己的 tools.json（请求体里给不了任何参数）。
        # 以前这里固定只拼 exe、留不出参数位，结果 dsh 只能起来默认 profile，
        # 用户还得自己在窗口里敲 web —— 见配置里的 launch.args。
        $argList = @()
        foreach ($a in @(Get-ObjectProp -Object $launchCfg -Name 'args' | Where-Object { $_ })) {
            $s = [string]$a
            if ($s -match '\s') { $argList += ('"' + $s + '"') } else { $argList += $s }
        }
        
        # 服务型工具（例如 dsh web）要占一个端口。默认端口被占时自动往上找一个空的 ——
        # 否则用户已经开着一个同类服务时，点"启动"只会得到一句 EADDRINUSE，看着像按钮坏了。
        $serverCfg = Get-ObjectProp -Object $launchCfg -Name 'server'
        if ($serverCfg) {
            $portArg = [string](Get-ObjectProp -Object $serverCfg -Name 'portArg')
            $defaultPort = [int](Get-ObjectProp -Object $serverCfg -Name 'defaultPort')
            if ($defaultPort -le 0) { $defaultPort = 3080 }
            if ($portArg) {
                $result.port = Find-FreeTcpPort -StartPort $defaultPort
                $argList += @($portArg, [string]$result.port)
            }
        }
        
        $argLine = '"' + $exe + '"'
        foreach ($a in $argList) { $argLine += ' ' + $a }
        $result.filePath = 'cmd.exe'
        $result.arguments = @('/k', $argLine)
        $result.commandLine = 'cmd.exe /k ' + $argLine
    }
    $result.ok = $true
    return [pscustomobject]$result
}

Export-ModuleMember -Function `
    'Get-LLMKitServiceVersion', 'Assert-ServicePrerequisites', 'Resolve-ServiceConfigRoot', `
    'Get-LLMKitActionCatalog', 'Get-LLMKitAction', 'Get-LLMKitActionCommandLine', `
    'Get-LLMKitOverview', 'Get-LLMKitToolDetail', 'Get-LLMKitProviderList', 'Get-LLMKitSessionList', 'Get-LLMKitPackageStatus', `
    'Get-LLMKitConfigOverview', 'Get-LLMKitDiagnosticReport', 'Get-LLMKitLaunchSpec', 'Get-LLMKitToolLaunchSummary'
