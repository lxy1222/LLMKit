#Requires -Version 5.1
<#
.SYNOPSIS
    LLMKit 本地网页版入口

.DESCRIPTION
    起一个只监听 127.0.0.1 的最小 HTTP 服务，然后打开系统默认浏览器。
    这是"双版本"里的网页版；图形界面版（WinForms）仍然保留：
      · 网页版：首页 + 每个工具一个页面，适合逐个安装、日常使用
      · WinForms 版：不依赖浏览器，适合受限桌面或浏览器被策略禁掉的环境
    两者共用同一套引擎与服务层，不会出现"两个版本行为不一致"。

.PARAMETER SelfTest
    无界面自检：在独立运行空间里真的把服务起起来，然后用真实 HTTP 请求
    打一遍所有接口（含目录穿越防护与任务轮询），最后打印结果。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\src\ps\Start-LLMKitWeb.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\src\ps\Start-LLMKitWeb.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string]$ConfigRoot,
    [string]$WebDir,
    [int]$Port = 17800,
    [switch]$NoBrowser,
    [switch]$SelfTest,
    [string]$StateDir
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrEmpty($ConfigRoot)) { $ConfigRoot = Split-Path -Parent (Split-Path -Parent $scriptDir) }
if ([string]::IsNullOrEmpty($WebDir)) { $WebDir = Join-Path $ConfigRoot 'web' }
if ([string]::IsNullOrEmpty($StateDir)) { $StateDir = Join-Path $ConfigRoot 'out\state' }

# 模块导入顺序有依赖：引擎 → 服务层 → 界面工具 → Web
foreach ($m in @('LLMKit', 'LLMKit.Install', 'LLMKit.Tools', 'LLMKit.Config', 'LLMKit.Diagnose', 'LLMKit.Engine', 'LLMKit.Service', 'LLMKit.Web')) {
    Import-Module (Join-Path $scriptDir ($m + '.psm1')) -Force -DisableNameChecking
}
Assert-WebPrerequisites

function Write-Line2 {
    param([string]$Text, [string]$Color = 'Gray')
    try { Write-Host $Text -ForegroundColor $Color } catch { Write-Host $Text }
}

# ======================================================================
#  自检：真的起服务、真的发 HTTP 请求
# ======================================================================
if ($SelfTest) {
    Write-Line2 ''
    Write-Line2 'LLMKit 网页版 · 无界面自检' 'White'
    Write-Line2 ('-' * 66) 'DarkGray'

    $pass = 0; $fail = 0
    function Check {
        param([string]$Name, $Ok, [string]$Detail = '')
        if ($Ok) { Write-Line2 ('  [PASS] ' + $Name) 'Green'; $script:pass++ }
        else { Write-Line2 ('  [FAIL] ' + $Name + $(if ($Detail) { ' —— ' + $Detail } else { '' })) 'Red'; $script:fail++ }
    }
    $script:pass = 0; $script:fail = 0

    # 纯函数先测一遍（不依赖网络栈）
    Write-Line2 '请求解析与路由' 'Cyan'
    $rl = ConvertFrom-HttpRequestLine -Line 'GET /api/tool/opencode?x=1&y=%E4%B8%AD HTTP/1.1'
    Check '请求行解析' ($rl.ok -and $rl.method -eq 'GET' -and $rl.path -eq '/api/tool/opencode' -and $rl.query -eq 'x=1&y=%E4%B8%AD')
    $q = ConvertFrom-HttpQueryString -Query 'a=1&b=%E4%B8%AD%E6%96%87&c=&d'
    Check '查询串解析（含 URL 解码）' ($q['a'] -eq '1' -and $q['b'] -eq '中文' -and $q['d'] -eq '')
    Check '坏请求行不崩' (-not (ConvertFrom-HttpRequestLine -Line 'garbage').ok)
    Check '空请求行不崩' (-not (ConvertFrom-HttpRequestLine -Line '').ok)

    Check '路由：首页' ((Resolve-WebRoute -Method GET -Path '/').handler -eq 'static')
    Check '路由：工具接口带参数' ((Resolve-WebRoute -Method GET -Path '/api/tool/codex').params['toolId'] -eq 'codex')
    Check '路由：任务接口带参数' ((Resolve-WebRoute -Method GET -Path '/api/job/abc-1').params['jobId'] -eq 'abc-1')
    Check '路由：未知路径 404' ((Resolve-WebRoute -Method GET -Path '/nope').handler -eq 'not-found')
    Check '路由：错误方法 405' ((Resolve-WebRoute -Method DELETE -Path '/api/overview').handler -eq 'method-not-allowed')

    Check '目录穿越被挡住（..）' (-not (Resolve-StaticPath -WebDir $WebDir -Relative '..\..\config\tools.json').ok)
    Check '目录穿越被挡住（绝对路径）' (-not (Resolve-StaticPath -WebDir $WebDir -Relative 'C:\Windows\win.ini').ok)
    Check '目录穿越被挡住（冒号）' (-not (Resolve-StaticPath -WebDir $WebDir -Relative 'a:b').ok)
    Check '正常静态路径放行' ((Resolve-StaticPath -WebDir $WebDir -Relative 'index.html').ok)
    Check 'MIME：html' ((Get-MimeType -Path 'a.html') -like 'text/html*')
    Check 'MIME：js' ((Get-MimeType -Path 'a.js') -like 'application/javascript*')

    $resp = New-HttpResponseBytes -StatusCode 200 -ContentType 'text/plain; charset=utf-8' -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('中'))
    $headText = [System.Text.Encoding]::ASCII.GetString($resp[0..200])
    Check '响应带 Content-Length' ($headText -match 'Content-Length: 3')
    Check '响应带 Connection: close' ($headText -match 'Connection: close')

    # 真起服务
    Write-Line2 ''
    Write-Line2 '真实 HTTP 往返' 'Cyan'
    $probePort = $Port
    $rs = [powershell]::Create()
    [void]$rs.AddScript({
            param($ScriptDir, $CfgRoot, $Web, $StDir, $P)
            $ErrorActionPreference = 'Stop'
            foreach ($m in @('LLMKit', 'LLMKit.Install', 'LLMKit.Tools', 'LLMKit.Config', 'LLMKit.Diagnose', 'LLMKit.Engine', 'LLMKit.Service', 'LLMKit.Web')) {
                Import-Module (Join-Path $ScriptDir ($m + '.psm1')) -Force -DisableNameChecking
            }
            $srv = New-WebServer -ConfigRoot $CfgRoot -WebDir $Web -Port $P
            # 刚解压出来的目录里可能压根没有 out\ —— 用户第一次运行就是这样。不先建目录的话
            # WriteAllText 会抛 DirectoryNotFoundException，就绪标记永远不出现，自检会卡到超时。
            $urlFile = Join-Path $CfgRoot 'out\web-selftest-url.txt'
            $urlDir = Split-Path -Parent $urlFile
            if (-not (Test-Path -LiteralPath $urlDir)) { [void](New-Item -ItemType Directory -Path $urlDir -Force) }
            [System.IO.File]::WriteAllText($urlFile, $srv.url)
            Invoke-WebServerLoop -Server $srv -PollMs 60
        })
    foreach ($a in @($scriptDir, $ConfigRoot, $WebDir, $StateDir, $probePort)) { [void]$rs.AddArgument($a) }
    $handle = $rs.BeginInvoke()

    $urlFile = Join-Path $ConfigRoot 'out\web-selftest-url.txt'
    if (Test-Path $urlFile) { Remove-Item $urlFile -Force }
    $waited = 0
    # 上限 60 秒：冷启动时首次导入 8 个模块叠加杀软实时扫描，30 秒实测偏紧。
    while (-not (Test-Path $urlFile) -and $waited -lt 240) { Start-Sleep -Milliseconds 250; $waited++ }    $url = ''
    if (Test-Path $urlFile) { $url = ([System.IO.File]::ReadAllText($urlFile)).Trim() }
    $waitDetail = '等待 ' + [int]($waited * 0.25) + ' 秒'
    if ($url -eq '') {
        # BeginInvoke 抛出的终止性错误不进 Streams.Error —— 实测这里曾报"错误：无"，
        # 而真因是 out\ 不存在导致写文件失败。真实异常只能从 EndInvoke 或运行空间状态取。
        $why = '原因未知'
        try {
            if ($handle -and $handle.IsCompleted) { [void]$rs.EndInvoke($handle) }
            if ($rs.Streams.Error.Count -gt 0) { $why = $rs.Streams.Error[0].Exception.Message }
            elseif ($rs.Runspace -and $rs.Runspace.RunspaceStateInfo.State -eq [System.Management.Automation.RunspaceState]::Broken) { $why = '运行空间已损坏（脚本内有终止性错误）' }
            elseif ($rs.HadErrors) { $why = '有错误但未记录到错误流' }
            else { $why = '运行空间仍在运行，可能只是太慢' }
        } catch { $why = $_.Exception.Message }
        $waitDetail = $waitDetail + '；原因：' + $why
    }
    Check '服务成功监听' ($url -ne '') $waitDetail
    if ($url) {
        Write-Line2 ('  监听地址：' + $url) 'DarkGray'
        $base = $url.TrimEnd('/')

        function HttpGet {
            param([string]$Path, [int]$TimeoutSec = 20)
            try {
                $r = Invoke-WebRequest -Uri ($script:base + $Path) -UseBasicParsing -TimeoutSec $TimeoutSec
                $ct = ''
                try { $ct = [string]$r.Headers['Content-Type'] } catch { }
                return [pscustomobject]@{ ok = $true; status = [int]$r.StatusCode; text = [string]$r.Content; contentType = $ct; error = '' }
            } catch {
                $code = $null
                try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
                $body = ''
                $ct2 = ''
                try {
                    if ($_.Exception.Response) {
                        try { $ct2 = [string]$_.Exception.Response.ContentType } catch { }
                        $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
                        $body = $sr.ReadToEnd()
                    }
                } catch { }
                return [pscustomobject]@{ ok = $false; status = $code; text = $body; contentType = $ct2; error = $_.Exception.Message }
            }
        }
        $script:base = $base

        $h = HttpGet '/api/health'
        Check 'GET /api/health 返回 200' ($h.status -eq 200) $h.error
        Check 'health 是合法 JSON' ($h.ok -and (($h.text | ConvertFrom-Json).ok -eq $true))

        $ov = HttpGet '/api/overview'
        $ovObj = $null
        try { $ovObj = $ov.text | ConvertFrom-Json } catch { }
        Check 'GET /api/overview 返回 200' ($ov.status -eq 200) $ov.error
        Check 'overview 含工具（依赖已并成工具）' ($ovObj -and @($ovObj.tools).Count -ge 10)

        # 顺序：智能体在前、配套工具在后（组内按 priority）——
        # 顶栏和首页都直接照这个数组渲染，所以顺序必须由服务端定死，不能靠 tools.json 的书写顺序。
        $ovRoles = @(@($ovObj.tools) | ForEach-Object { [string]$_.role })
        # 配套工具现在有两种（provider-manager 管渠道 / companion 备环境），所以按"是不是 agent"分
        $pmIdx = @(0..($ovRoles.Count - 1) | Where-Object { $ovRoles[$_] -ne 'agent' })
        $agIdx = @(0..($ovRoles.Count - 1) | Where-Object { $ovRoles[$_] -eq 'agent' })
        Check 'overview 里智能体全排在配套工具之前' ($pmIdx.Count -ge 1 -and $agIdx.Count -ge 1 -and ($agIdx | Measure-Object -Maximum).Maximum -lt ($pmIdx | Measure-Object -Minimum).Minimum) ('角色顺序 ' + ($ovRoles -join ','))
        $ovAgPrio = @(@($ovObj.tools) | Where-Object { [string]$_.role -ne 'provider-manager' } | ForEach-Object { [int]$_.priority })
        $ovAgSorted = @($ovAgPrio | Sort-Object)
        Check '智能体之间按 priority 递增' (($ovAgPrio -join ',') -eq ($ovAgSorted -join ',')) ('实际 ' + ($ovAgPrio -join ','))
        Check 'overview 把 priority 透出来了' (@(@($ovObj.tools) | Where-Object { $null -eq $_.priority }).Count -eq 0)
        Check '配套工具排在最后一位' ([string](@($ovObj.tools)[@($ovObj.tools).Count - 1]).role -ne 'agent')

        $ac = HttpGet '/api/actions'
        $acObj = $null
        try { $acObj = $ac.text | ConvertFrom-Json } catch { }
        Check 'GET /api/actions 返回动作清单' ($acObj -and @($acObj.actions).Count -ge 7)
        $actionIds = @(@($acObj.actions) | ForEach-Object { [string]$_.id })
        Check '不再有「一起补齐」的 install-deps 动作' ($actionIds -notcontains 'install-deps') ('动作：' + ($actionIds -join ','))
        Check 'Node / Git 是工具，有自己的页面' (@($ovObj.tools).Count -ge 10 -and @(@($ovObj.tools) | Where-Object { $_.id -in @('node', 'git') }).Count -eq 2)

        $dt = HttpGet '/api/tool/opencode'
        $dtObj = $null
        try { $dtObj = $dt.text | ConvertFrom-Json } catch { }
        Check 'GET /api/tool/opencode 返回该工具详情' ($dtObj -and $dtObj.id -eq 'opencode' -and @($dtObj.tiers).Count -ge 1)

        $bad = HttpGet '/api/tool/no-such-tool'
        Check '未知工具返回 500 而不是崩掉服务' ($bad.status -eq 500) ('实际 ' + $bad.status)

        # ---------------- W4：配置总览与诊断报告 ----------------
        $cf = HttpGet '/api/config'
        $cfObj = $null
        try { $cfObj = $cf.text | ConvertFrom-Json } catch { }
        Check 'GET /api/config 返回配置总览' ($cf.status -eq 200 -and $cfObj.targetTotal -ge 1) $cf.error
        Check '配置总览按工具分组' ($cfObj -and @($cfObj.tools).Count -ge 5) ('实际 ' + @($cfObj.tools).Count)
        $withKeys = @(@($cfObj.tools) | ForEach-Object { $_.targets } | Where-Object { @($_.managedKeys).Count -gt 0 })
        Check '配置目标带受管字段清单' ($withKeys.Count -ge 1) ('实际 ' + $withKeys.Count)

        $dg = HttpGet '/api/diagnostic'
        $dgObj = $null
        try { $dgObj = $dg.text | ConvertFrom-Json } catch { }
        Check 'GET /api/diagnostic 返回 200' ($dg.status -eq 200) $dg.error
        Check '诊断接口如实报告有没有报告' ($dgObj -and ($dgObj.PSObject.Properties.Name -contains 'exists'))
        if ($dgObj -and $dgObj.exists) {
            $dgText = [string]$dgObj.text
            Check '诊断正文非空' ($dgText.Length -gt 100) ('实际 ' + $dgText.Length)
            Check '诊断正文不含本机用户名' (-not $dgText.Contains($env:USERNAME))
        } else {
            Check '（本机还没有诊断报告，跳过正文断言）' $true
        }
        # ---------------- W3：前端资源与 /api/preview ----------------
        $js = HttpGet '/assets/app.js'
        Check 'GET /assets/app.js 返回 200' ($js.status -eq 200) $js.error
        Check 'app.js 的 MIME 是 javascript' ($js.ok -and $js.contentType -match 'javascript') ('实际 ' + $js.contentType)
        $css = HttpGet '/assets/app.css'
        Check 'GET /assets/app.css 返回 200' ($css.status -eq 200) $css.error
        Check 'app.css 的 MIME 是 text/css' ($css.ok -and $css.contentType -match 'text/css') ('实际 ' + $css.contentType)
        Check 'app.js 不含外链 CDN' ($js.ok -and -not ($js.text -match 'src\s*=\s*["'']https?://'))
        Check 'app.js 通过预览接口取真实命令行' ($js.ok -and $js.text -match '/api/preview')

        function HttpPostJson {
            param([string]$Path, [string]$Json)
            try {
                $r = Invoke-WebRequest -Uri ($script:base + $Path) -Method POST -UseBasicParsing -TimeoutSec 25 `
                    -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($Json))
                return [pscustomobject]@{ ok = $true; status = [int]$r.StatusCode; text = [string]$r.Content }
            } catch {
                $code = $null; $body = ''
                try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
                try {
                    if ($_.Exception.Response) {
                        $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
                        $body = $sr.ReadToEnd()
                    }
                } catch { }
                return [pscustomobject]@{ ok = $false; status = $code; text = $body }
            }
        }

        $pv = HttpPostJson '/api/preview' '{"actionId":"tool-install","targetId":"opencode","tierId":"npm-global","apply":true}'
        $pvObj = $null
        try { $pvObj = $pv.text | ConvertFrom-Json } catch { }
        Check 'POST /api/preview 返回真实命令行' ($pv.status -eq 200 -and $pvObj.commandLine -match 'Setup-LLMKit\.ps1') $pv.text
        Check 'preview 如实标明会真的执行' ($pvObj -and $pvObj.willApply -eq $true -and $pvObj.destructive -eq $true)
        Check 'preview 的命令里带上选中的安装层' ($pvObj -and $pvObj.commandLine -match '-OnlyTiers\s+npm-global')

        $pvDry = HttpPostJson '/api/preview' '{"actionId":"tool-uninstall","targetId":"opencode","apply":false}'
        $pvDryObj = $null
        try { $pvDryObj = $pvDry.text | ConvertFrom-Json } catch { }
        Check 'preview 在演练模式下 willApply=false' ($pvDryObj -and $pvDryObj.willApply -eq $false)

        $pvBadTier = HttpPostJson '/api/preview' '{"actionId":"tool-install","targetId":"opencode","tierId":"no-such-tier"}'
        Check '不存在的安装层被挡住（400）' ($pvBadTier.status -eq 400) ('实际 ' + $pvBadTier.status + '：' + $pvBadTier.text)

        $pvNoAction = HttpPostJson '/api/preview' '{"targetId":"opencode"}'
        Check '缺少 actionId 返回 400' ($pvNoAction.status -eq 400) ('实际 ' + $pvNoAction.status)

        $pvBadJson = HttpPostJson '/api/preview' 'not-json'
        Check '非法 JSON 返回 400' ($pvBadJson.status -eq 400) ('实际 ' + $pvBadJson.status)
        # ---------------- W5：启动接口 ----------------
        # 全是 dryRun：只算要跑什么、不起进程 —— 自检不该在跑它的机器上弹窗口出来。
        $lz = HttpPostJson '/api/launch' '{"toolId":"opencode","mode":"interactive","dryRun":true}'
        $lzObj = $null
        try { $lzObj = $lz.text | ConvertFrom-Json } catch { }
        Check 'POST /api/launch(dryRun) 返回要跑的命令' ($lz.status -eq 200 -and $lzObj.ok -and $lzObj.commandLine) $lz.text
        Check 'dryRun 明确了这是演练' ($lzObj -and $lzObj.dryRun -eq $true)
        Check 'CLI 的启动命令用 cmd /k 开窗口' ($lzObj -and $lzObj.commandLine -match 'cmd\.exe /k') $lzObj.commandLine

        $lzSmoke = HttpPostJson '/api/launch' '{"toolId":"opencode","mode":"smoke","dryRun":true}'
        $lzSmokeObj = $null
        try { $lzSmokeObj = $lzSmoke.text | ConvertFrom-Json } catch { }
        Check '冒烟模式返回配置里那条冒烟命令' ($lzSmoke.status -eq 200 -and $lzSmokeObj.commandLine -match 'opencode run') $lzSmoke.text

        $lzUnknown = HttpPostJson '/api/launch' '{"toolId":"no-such-tool","mode":"interactive","dryRun":true}'
        Check '未知工具启动被拒（400）' ($lzUnknown.status -eq 400) ('实际 ' + $lzUnknown.status)
        $lzBadMode = HttpPostJson '/api/launch' '{"toolId":"opencode","mode":"whatever"}'
        Check '非法 mode 被拒（400）' ($lzBadMode.status -eq 400) ('实际 ' + $lzBadMode.status)
        $lzNoId = HttpPostJson '/api/launch' '{"mode":"interactive"}'
        Check '缺少 toolId 被拒（400）' ($lzNoId.status -eq 400) ('实际 ' + $lzNoId.status)
        # 这条不能写死某个工具名：机器上装没装是可变的（claude-code 装好之后它就误报了）。
        # 做法：先向 /api/tool 问一遍，挑一个确实没装的工具来验 409。
        $notInstalledId = '' 
        foreach ($tid in @('claude-code', 'codex', 'gemini-cli', 'opencode', 'dsh')) {
            $t = HttpGet ('/api/tool/' + $tid)
            if ($t.status -eq 200 -and $t.text -match '"installed"\s*:\s*false') { $notInstalledId = $tid; break }
        }
        if ([string]::IsNullOrEmpty($notInstalledId)) {
            Write-Host '  （全部工具都装着，跳过"没装的工具被拒"这条）' -ForegroundColor DarkYellow
        } else {
            $lzNotInstalled = HttpPostJson '/api/launch' ('{"toolId":"' + $notInstalledId + '","mode":"interactive","dryRun":true}' )
            Check ('没装的工具被拒（409）· ' + $notInstalledId) ($lzNotInstalled.status -eq 409) ('实际 ' + $lzNotInstalled.status)
        }

        $idx = HttpGet '/'
        Check 'GET / 返回页面' ($idx.status -eq 200 -and $idx.text -match 'LLMKit' -and $idx.text -match '大模型工具引导式一键安装器')
        Check '页面内不含任何外链 CDN（离线可用）' ($idx.text -notmatch 'https?://(?!127\.0\.0\.1)[^"'']+\.(js|css)')

        $trav = HttpGet '/assets/..%5C..%5Cconfig%5Ctools.json'
        Check '目录穿越请求被拒（403/404）' ($trav.status -eq 403 -or $trav.status -eq 404) ('实际 ' + $trav.status)

        # 起一个真任务（只读的体检），并轮询它的输出
        $runBody = '{"actionId":"tool-verify","targetId":"opencode","apply":false}'
        $run = $null
        try {
            $run = Invoke-WebRequest -Uri ($base + '/api/run') -Method POST -UseBasicParsing -TimeoutSec 30 `
                -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($runBody))
        } catch { }
        $runObj = $null
        if ($run) { try { $runObj = $run.Content | ConvertFrom-Json } catch { } }
        Check 'POST /api/run 起了任务' ($runObj -and $runObj.jobId) $(if ($runObj) { $runObj.error } else { '请求失败' })
        Check '返回的命令行可复制' ($runObj -and $runObj.commandLine -match 'Setup-LLMKit\.ps1')
        # preview 不该占住任务槽 —— 上面这次 run 能起来就是证据（否则会拿到 409）
        Check 'preview 没有占住任务槽（紧接着的 run 仍能起来）' ($runObj -and $runObj.jobId)
        Check '启动动作也没有占住任务槽' ($runObj -and $runObj.jobId)

        if ($runObj -and $runObj.jobId) {
            # 任务在跑，此时再起一个应该被拒（同一时刻只允许一个）
            $again = $null
            try {
                $again = Invoke-WebRequest -Uri ($base + '/api/run') -Method POST -UseBasicParsing -TimeoutSec 20 `
                    -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($runBody)) -ErrorAction Stop
            } catch {
                try { if ($_.Exception.Response) { $again = [pscustomobject]@{ StatusCode = [int]$_.Exception.Response.StatusCode } } } catch { }
            }
            $againStatus = 0
            if ($again) { $againStatus = [int]$again.StatusCode }
            Check '同一时刻只允许一个任务（第二个被拒 409）' ($againStatus -eq 409) ('实际 ' + $againStatus)

            # 轮询到结束
            $since = 0; $all = New-Object System.Collections.ArrayList
            $deadline = (Get-Date).AddSeconds(180)
            $done = $false; $polls = 0
            while (-not $done -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 300
                $polls++
                $j = HttpGet ('/api/job/' + $runObj.jobId + '?since=' + $since)
                if (-not $j.ok) { break }
                $jo = $null
                try { $jo = $j.text | ConvertFrom-Json } catch { }
                if (-not $jo) { break }
                foreach ($l in @($jo.lines)) { [void]$all.Add($l) }
                $since = $jo.total
                if ($jo.finished) { $done = $true }
            }
            Check '任务在时限内结束' $done ('轮询 ' + $polls + ' 次')
            Check '轮询收到了引擎输出（>5 行）' ($all.Count -gt 5) ('收到 ' + $all.Count + ' 行')
            Check '输出内容是引擎真实输出' ((($all -join '') -match 'LLMKit') -and (($all -join '') -match '环境体检|阶段|结论'))
            Check '增量语义正确（since 之后的才是新行）' ($since -eq $all.Count) ('since=' + $since + ' 累计=' + $all.Count)
            Check '轮询过程中服务端没有阻塞（多次成功轮询）' ($polls -ge 2) ('轮询 ' + $polls + ' 次')

            $jf = HttpGet ('/api/job/' + $runObj.jobId + '?since=0')
            $jfo = $null
            try { $jfo = $jf.text | ConvertFrom-Json } catch { }
            Check '任务结束后状态为 done' ($jfo -and $jfo.state -eq 'done') $(if ($jfo) { $jfo.state } else { '' })
            # 退出码在受限环境里可能读不到（本机就是），所以断言"结论"这一项 ——
            # 它来自引擎自己的输出，比退出码更权威也更具体
            Check '任务给出了明确结论（不是 unknown）' ($jfo -and $jfo.verdict -ne 'unknown') $(if ($jfo) { 'verdict=' + $jfo.verdict } else { '' })
            Check '退出码可读性被如实记录' ($jfo -and $null -ne $jfo.PSObject.Properties['exitCodeAvailable'])
        }

        $nf = HttpGet '/api/job/nonexistent'
        Check '未知任务返回 404' ($nf.status -eq 404) ('实际 ' + $nf.status)

        $sd = $null
        try {
            $sd = Invoke-WebRequest -Uri ($base + '/api/shutdown') -Method POST -UseBasicParsing -TimeoutSec 15 `
                -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes('{}'))
        } catch { }
        Check 'POST /api/shutdown 能关服务' ($null -ne $sd)
        Start-Sleep -Seconds 2
    }

    try { $rs.Stop() } catch { }
    try { $rs.Dispose() } catch { }

    Write-Line2 ''
    Write-Line2 ('-' * 66) 'DarkGray'
    if ($script:fail -eq 0) {
        Write-Line2 ('自检全部通过：' + $script:pass + ' 项') 'Green'
        exit 0
    } else {
        Write-Line2 ('通过 ' + $script:pass + ' 项，失败 ' + $script:fail + ' 项') 'Red'
        exit 1
    }
}

# ======================================================================
#  正常启动
# ======================================================================
$server = New-WebServer -ConfigRoot $ConfigRoot -WebDir $WebDir -Port $Port
Write-Line2 ''
Write-Line2 'LLMKit · 本地网页界面' 'White'
Write-Line2 ('地址：' + $server.url) 'Green'
Write-Line2 '按 Ctrl+C 结束（或点界面里的关闭按钮）。' 'DarkGray'
Write-Line2 '本工具不内置、代发或代充任何 API Key；服务只监听 127.0.0.1，不对外网开放。' 'DarkGray'
Write-Line2 ''

if (-not $NoBrowser) {
    try {
        Start-Process $server.url | Out-Null
        Write-Line2 '已尝试打开默认浏览器。' 'DarkGray'
    } catch {
        Write-Line2 ('打开浏览器失败，请手动访问上面的地址：' + $_.Exception.Message) 'Yellow'
    }
}

try {
    Invoke-WebServerLoop -Server $server
} finally {
    Stop-WebServer -Server $server
    Write-Line2 ''
    Write-Line2 ('服务已停止（共处理 ' + $server.served + ' 个请求）') 'DarkGray'
}
