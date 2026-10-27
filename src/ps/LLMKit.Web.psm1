#Requires -Version 5.1
<#
    LLMKit 本地 Web 服务（W2）
    ------------------------------------------------------------------
    给网页版用的最小 HTTP/1.1 服务。刻意不用 System.Net.HttpListener：
    Windows 上非管理员使用它需要 URL ACL（netsh http add urlacl），
    给新手工具塞一个需要提权的环节是自相矛盾的。TcpListener 没有这个问题。

    ---- 为什么是轮询而不是 SSE ----
    单线程的顺序 accept 循环没法在"持住一个长连接"的同时服务其它请求；
    而"每个连接开一个运行空间"要重复导入模块（每次 100~300ms），本地工具完全不划算。
    所以：每个请求立刻返回并关连接，进度靠客户端每 300ms 拉一次增量。
    服务端因此**永不阻塞**，也不需要线程 —— 这是能想到的最少部件的方案。
    浏览器端体验等价：都是"几百毫秒内看到新日志"。

    ---- 为什么任务里不需要线程 ----
    动作本身就是"起一个 powershell.exe 子进程 + 把输出重定向到文件"
    （这条路径在 WinForms 版里已经验证过：事件回调会崩进程、跨线程读管道会阻塞，
    只有"重定向到文件 + 增量读文件"是稳的）。服务端只要在每次轮询时读一下那个文件。

    安全边界：
      · 只绑 127.0.0.1，不做局域网访问
      · 静态文件只从 web\ 目录取，且拒绝任何含 .. 的路径（防目录穿越）
      · 同一时刻只允许一个任务在跑 —— 多个安装同时动同一批文件是自找麻烦
      · 所有会改动系统的动作，只有请求体里显式 apply=true 才会追加 -Apply
#>

Set-StrictMode -Off

$script:WebVersion = '0.1.0'
$script:JobStore = @{}
$script:CurrentJobId = ''
$script:ServerRoot = ''
$script:WebDir = ''

function Get-LLMKitWebVersion { $script:WebVersion }

function Assert-WebPrerequisites {
    $missing = New-Object System.Collections.ArrayList
    foreach ($fn in @('Get-LLMKitOverview', 'Get-LLMKitToolDetail', 'Get-LLMKitProviderList',
            'Get-LLMKitSessionList', 'Get-LLMKitActionCatalog', 'Get-LLMKitActionCommandLine',
            'Start-LLMKitEngineStep', 'Receive-LLMKitEngineOutput', 'Stop-LLMKitEngineStep', 'Get-LLMKitStepStatusFromOutput',
            'Read-TextFileUtf8', 'Resolve-ServiceConfigRoot')) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) { [void]$missing.Add($fn) }
    }
    if ($missing.Count -gt 0) {
        throw ('Web 层缺少前置函数：' + ($missing -join '、') + '。请先导入 Service / Ui / 各引擎模块。')
    }
}

# ======================================================================
#  HTTP 解析与序列化（纯函数，可单测）
#  注意：这几个入口参数都带 AllowEmptyString —— 畸形请求应当返回 400，
#  而不是因为"Mandatory 拒收空串"把处理函数打崩。这类坑在本项目里踩过多次。
# ======================================================================

function ConvertFrom-HttpRequestLine {
    <# "GET /a/b?c=d HTTP/1.1" → method / path / query / version #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)
    $out = [ordered]@{ ok = $false; method = ''; path = ''; query = ''; version = ''; error = '' }
    $t = $Line.Trim()
    if ([string]::IsNullOrEmpty($t)) { $out.error = 'empty-request-line'; return [pscustomobject]$out }
    $parts = @($t -split '\s+')
    if ($parts.Count -lt 3) { $out.error = 'malformed-request-line'; return [pscustomobject]$out }
    $target = $parts[1]
    $q = $target.IndexOf('?')
    if ($q -ge 0) {
        $out.path = $target.Substring(0, $q)
        $out.query = $target.Substring($q + 1)
    } else {
        $out.path = $target
    }
    # 去掉查询里的 #fragment（浏览器一般不会发，但手工敲可能带上）
    $h = $out.path.IndexOf('#')
    if ($h -ge 0) { $out.path = $out.path.Substring(0, $h) }
    $out.method = $parts[0].ToUpperInvariant()
    $out.version = $parts[2]
    try { $out.path = [System.Uri]::UnescapeDataString($out.path) } catch { }
    $out.ok = $true
    return [pscustomobject]$out
}

function ConvertFrom-HttpQueryString {
    param([string]$Query)
    $out = @{}
    if ([string]::IsNullOrEmpty($Query)) { return $out }
    foreach ($pair in ($Query -split '&')) {
        if ([string]::IsNullOrEmpty($pair)) { continue }
        $kv = $pair -split '=', 2
        $k = $kv[0]
        $v = ''
        if ($kv.Count -gt 1) { $v = $kv[1] }
        try { $k = [System.Uri]::UnescapeDataString($k.Replace('+', ' ')) } catch { }
        try { $v = [System.Uri]::UnescapeDataString($v.Replace('+', ' ')) } catch { }
        if (-not [string]::IsNullOrEmpty($k)) { $out[$k] = $v }
    }
    return $out
}

function Get-HttpStatusText {
    param([int]$Code)
    switch ($Code) {
        200 { return 'OK' }
        204 { return 'No Content' }
        400 { return 'Bad Request' }
        403 { return 'Forbidden' }
        404 { return 'Not Found' }
        405 { return 'Method Not Allowed' }
        409 { return 'Conflict' }
        500 { return 'Internal Server Error' }
        default { return 'OK' }
    }
}

function New-HttpResponseBytes {
    <#
        组装响应字节。一律 Connection: close —— 不做 keep-alive 就不用解析分块与管线化，
        浏览器会自己开新连接，本地场景完全够用。
    #>
    param(
        [int]$StatusCode = 200,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [byte[]]$BodyBytes,
        [hashtable]$ExtraHeaders
    )
    if ($null -eq $BodyBytes) { $BodyBytes = New-Object byte[] 0 }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('HTTP/1.1 ' + $StatusCode + ' ' + (Get-HttpStatusText -Code $StatusCode) + "`r`n")
    [void]$sb.Append('Content-Type: ' + $ContentType + "`r`n")
    [void]$sb.Append('Content-Length: ' + $BodyBytes.Length + "`r`n")
    [void]$sb.Append("Connection: close`r`n")
    # 本地工具，不做缓存，省得改完前端还要教用户按 Ctrl+F5
    [void]$sb.Append("Cache-Control: no-store`r`n")
    [void]$sb.Append("X-Content-Type-Options: nosniff`r`n")
    if ($ExtraHeaders) {
        foreach ($k in $ExtraHeaders.Keys) { [void]$sb.Append($k + ': ' + $ExtraHeaders[$k] + "`r`n") }
    }
    [void]$sb.Append("`r`n")
    $head = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $out = New-Object byte[] ($head.Length + $BodyBytes.Length)
    [System.Buffer]::BlockCopy($head, 0, $out, 0, $head.Length)
    [System.Buffer]::BlockCopy($BodyBytes, 0, $out, $head.Length, $BodyBytes.Length)
    return $out
}

function New-JsonResponseBytes {
    param($Object, [int]$StatusCode = 200)
    $json = ''
    if ($null -eq $Object) { $json = 'null' }
    else { $json = $Object | ConvertTo-Json -Depth 12 }
    return (New-HttpResponseBytes -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' `
            -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes($json)))
}

function ConvertTo-ActionSpecArgs {
    <#
        请求体 → Get-LLMKitActionCommandLine 的参数表。
        /api/run 与 /api/preview 共用这一份映射。分开写的话，迟早会出现
        "预览框显示的"和"真正执行的"不是同一条命令 —— 那比没有预览更糟。
    #>
    param([AllowNull()]$Body, [Parameter(Mandatory = $true)][string]$ConfigRoot)
    if ($null -eq $Body) { return [pscustomobject]@{ ok = $false; error = '请求体不是合法 JSON'; args = @{} } }
    $actionId = [string]$Body.actionId
    if ([string]::IsNullOrEmpty($actionId)) {
        return [pscustomobject]@{ ok = $false; error = '缺少 actionId'; args = @{} }
    }
    $targetId = ''
    if ($Body.PSObject.Properties.Name -contains 'targetId') { $targetId = [string]$Body.targetId }
    $specArgs = @{
        ActionId = $actionId; ConfigRoot = $ConfigRoot; TargetId = $targetId
        Apply = [bool]$Body.apply
    }
    foreach ($opt in @('cleanArtifacts', 'removeUserConfig', 'skipOnboarding')) {
        if ($Body.PSObject.Properties.Name -contains $opt) { $specArgs[$opt] = [bool]$Body.$opt }
    }
    foreach ($opt in @('tierId', 'providerId', 'authTokenEnvVar', 'proxy', 'model')) {
    # 工具范围：数组，不是字符串，所以单独处理
    if ($Body.PSObject.Properties.Name -contains 'toolIds') {
        $ids = @($Body.toolIds | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($ids.Count -gt 0) { $specArgs['ToolIds'] = $ids }
    }
        if ($Body.PSObject.Properties.Name -contains $opt) { $specArgs[$opt] = [string]$Body.$opt }
    }
    return [pscustomobject]@{ ok = $true; error = ''; args = $specArgs }
}
function Resolve-WebRoute {
    <#
        method + path → 处理函数名 + 路径参数。
        单独抽出来是为了能单测路由，不用真起服务。
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Method, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    $p = $Path.TrimEnd('/')
    if ([string]::IsNullOrEmpty($p)) { $p = '/' }
    $m = $Method.ToUpperInvariant()

    if ($m -eq 'GET') {
        if ($p -eq '/' -or $p -eq '/index.html') { return [pscustomobject]@{ handler = 'static'; file = 'index.html'; params = @{} } }
        if ($p -like '/assets/*') { return [pscustomobject]@{ handler = 'static'; file = $p.Substring(1); params = @{} } }
        if ($p -eq '/api/overview') { return [pscustomobject]@{ handler = 'api-overview'; file = ''; params = @{} } }
        if ($p -eq '/api/actions') { return [pscustomobject]@{ handler = 'api-actions'; file = ''; params = @{} } }
        if ($p -eq '/api/providers') { return [pscustomobject]@{ handler = 'api-providers'; file = ''; params = @{} } }
        if ($p -eq '/api/sessions') { return [pscustomobject]@{ handler = 'api-sessions'; file = ''; params = @{} } }
        if ($p -eq '/api/config') { return [pscustomobject]@{ handler = 'api-config'; file = ''; params = @{} } }
        if ($p -eq '/api/local') { return [pscustomobject]@{ handler = 'api-local'; file = ''; params = @{} } }
        if ($p -eq '/api/diagnostic') { return [pscustomobject]@{ handler = 'api-diagnostic'; file = ''; params = @{} } }
        if ($p -eq '/api/health') { return [pscustomobject]@{ handler = 'api-health'; file = ''; params = @{} } }
        $mm = [regex]::Match($p, '^/api/tool/([A-Za-z0-9_\-]+)$')
        if ($mm.Success) { return [pscustomobject]@{ handler = 'api-tool'; file = ''; params = @{ toolId = $mm.Groups[1].Value } } }
        $mj = [regex]::Match($p, '^/api/job/([A-Za-z0-9_\-]+)$')
        if ($mj.Success) { return [pscustomobject]@{ handler = 'api-job'; file = ''; params = @{ jobId = $mj.Groups[1].Value } } }
        return [pscustomobject]@{ handler = 'not-found'; file = ''; params = @{} }
    }
    if ($m -eq 'POST') {
        if ($p -eq '/api/run') { return [pscustomobject]@{ handler = 'api-run'; file = ''; params = @{} } }
        if ($p -eq '/api/preview') { return [pscustomobject]@{ handler = 'api-preview'; file = ''; params = @{} } }
        if ($p -eq '/api/launch') { return [pscustomobject]@{ handler = 'api-launch'; file = ''; params = @{} } }
        if ($p -eq '/api/shutdown') { return [pscustomobject]@{ handler = 'api-shutdown'; file = ''; params = @{} } }
        return [pscustomobject]@{ handler = 'not-found'; file = ''; params = @{} }
    }
    return [pscustomobject]@{ handler = 'method-not-allowed'; file = ''; params = @{} }
}

function Resolve-StaticPath {
    <# 静态文件路径解析，并挡住目录穿越 #>
    param([Parameter(Mandatory = $true)][string]$WebDir, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Relative)
    $bad = [pscustomobject]@{ ok = $false; full = ''; error = 'invalid' }
    if ([string]::IsNullOrWhiteSpace($Relative)) { return $bad }
    $rel = $Relative -replace '/', '\'
    if ($rel -match '\.\.') { return $bad }
    if ($rel -match '^\\') { $rel = $rel.TrimStart('\') }
    if ($rel -match '^[A-Za-z]:') { return $bad }
    if ($rel -match ':') { return $bad }
    $full = Join-Path $WebDir $rel
    try {
        $resolved = [System.IO.Path]::GetFullPath($full)
        $rootFull = [System.IO.Path]::GetFullPath($WebDir)
        if (-not $resolved.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $bad }
    } catch { return $bad }
    return [pscustomobject]@{ ok = $true; full = $full; error = '' }
}

function Get-MimeType {
    param([string]$Path)
    $ext = ''
    try { $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant() } catch { }
    switch ($ext) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.js' { return 'application/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg' { return 'image/svg+xml' }
        '.png' { return 'image/png' }
        '.ico' { return 'image/x-icon' }
        default { return 'application/octet-stream' }
    }
}

# ======================================================================
#  任务管理（子进程 + 输出重定向到文件；轮询读增量）
# ======================================================================

function Start-WebJob {
    <#
        起一个引擎动作。同一时刻只允许一个 —— 多个安装同时改同一批文件是自找麻烦，
        而且用户也看不懂两份日志交错的输出。
    #>
    param(
        [Parameter(Mandatory = $true)]$CommandSpec,
        [Parameter(Mandatory = $true)][string]$LogDirectory,
        [string]$Title = ''
    )
    if (-not [string]::IsNullOrEmpty($script:CurrentJobId)) {
        $cur = $script:JobStore[$script:CurrentJobId]
        if ($cur -and -not $cur.finished) {
            return [pscustomobject]@{ ok = $false; error = 'busy'; jobId = $script:CurrentJobId }
        }
    }
    $jobId = 'j' + (Get-Date -Format 'HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $session = Start-LLMKitEngineStep -SetupPath $CommandSpec.setupPath -ArgumentList $CommandSpec.arguments -LogDirectory $LogDirectory
    $job = [pscustomobject]([ordered]@{
            id          = $jobId
            title       = $Title
            actionId    = $CommandSpec.actionId
            targetId    = $CommandSpec.targetId
            commandLine = $CommandSpec.commandLine
            destructive = $CommandSpec.destructive
            willApply   = $CommandSpec.willApply
            startedAt   = (Get-Date).ToString('o')
            session     = $session
            lines       = (New-Object System.Collections.ArrayList)
            state       = 'running'
            exitCode    = $null
            finished    = $false
            finishedAt  = ''
        })
    $script:JobStore[$jobId] = $job
    $script:CurrentJobId = $jobId
    return [pscustomobject]@{ ok = $true; error = ''; jobId = $jobId }
}

function Update-WebJob {
    <# 每次轮询时把子进程的新输出收进来；进程退出则标记完成 #>
    param([Parameter(Mandatory = $true)][string]$JobId)
    if (-not $script:JobStore.ContainsKey($JobId)) { return $null }
    $job = $script:JobStore[$JobId]
    if ($job.finished) { return $job }
    try {
        $r = Receive-LLMKitEngineOutput -Session $job.session
        foreach ($line in @($r.lines)) { [void]$job.lines.Add($line) }
        if ($r.done) {
            $job.finished = $true
            $job.state = 'done'
            $job.exitCode = $r.exitCode
            $job.finishedAt = (Get-Date).ToString('o')
            Stop-LLMKitEngineStep -Session $job.session
            if ($script:CurrentJobId -eq $JobId) { $script:CurrentJobId = '' }
        }
    } catch {
        $job.finished = $true
        $job.state = 'failed'
        $job.finishedAt = (Get-Date).ToString('o')
        [void]$job.lines.Add('[服务端读取输出出错] ' + $_.Exception.Message)
        if ($script:CurrentJobId -eq $JobId) { $script:CurrentJobId = '' }
    }
    return $job
}

function Get-WebJobView {
    <# 给前端的任务视图：只返回 since 之后的新行，避免每次把整份日志传一遍 #>
    param(
        [Parameter(Mandatory = $true)][string]$JobId,
        [int]$Since = 0
    )
    $job = Update-WebJob -JobId $JobId
    if (-not $job) { return $null }
    $all = @($job.lines)
    if ($Since -lt 0) { $Since = 0 }
    if ($Since -gt $all.Count) { $Since = $all.Count }
    $new = @()
    if ($all.Count -gt $Since) { $new = @($all[$Since..($all.Count - 1)]) }

    # 结论以引擎自己输出的那一行为准，而不是退出码：
    #   1) 退出码在某些受限环境里读不到（实测本机 Process.ExitCode 恒为 null）
    #   2) 引擎的结论行信息量更大：能区分"一切正常 / 基本可用 / 存在问题 / 仅是演练"
    $verdict = 'unknown'
    try {
        if ($all.Count -gt 0) { $verdict = [string](Get-LLMKitStepStatusFromOutput -Lines @($all)) }
    } catch { $verdict = 'unknown' }

    return [pscustomobject]([ordered]@{
            id = $job.id; title = $job.title; actionId = $job.actionId; targetId = $job.targetId
            state = $job.state; finished = $job.finished; verdict = $verdict
            exitCode = $job.exitCode; exitCodeAvailable = ($null -ne $job.exitCode)
            startedAt = $job.startedAt; finishedAt = $job.finishedAt
            willApply = $job.willApply; destructive = $job.destructive; commandLine = $job.commandLine
            total = $all.Count; since = $Since; lines = $new
        })
}

function Read-JsonBody {
    <# POST 请求体 → 对象。解析失败不抛异常，交给调用方报 400 #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

# ======================================================================
#  请求处理
# ======================================================================

function Invoke-WebRequestHandler {
    <#
        处理一个已解析的请求，返回响应字节。所有异常都在这里兜住，
        不然一次坏请求就能把整个服务循环带走。
    #>
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)]$Server
    )
    try {
        $route = Resolve-WebRoute -Method $Request.method -Path $Request.path
        $query = ConvertFrom-HttpQueryString -Query $Request.query
        $cfgRoot = $Server.configRoot
        $stateDir = $Server.stateDir

        switch ($route.handler) {
            'api-health' {
                return (New-JsonResponseBytes -Object ([ordered]@{ ok = $true; version = $script:WebVersion; pid = $PID }))
            }
            'api-overview' {
                return (New-JsonResponseBytes -Object (Get-LLMKitOverview -ConfigRoot $cfgRoot))
            }
            'api-actions' {
                return (New-JsonResponseBytes -Object ([ordered]@{
                            actions = @(Get-LLMKitActionCatalog)
                            currentJob = $script:CurrentJobId
                        }))
            }
            'api-providers' {
                return (New-JsonResponseBytes -Object ([ordered]@{ providers = @(Get-LLMKitProviderList -ConfigRoot $cfgRoot) }))
            }
            'api-sessions' {
                return (New-JsonResponseBytes -Object ([ordered]@{ sessions = @(Get-LLMKitSessionList -StateDir $stateDir) }))
            }
            'api-config' {
                return (New-JsonResponseBytes -Object (Get-LLMKitConfigOverview -ConfigRoot $cfgRoot))
            }
            'api-local' {
                # 本地模型页：硬件判定 + 运行时状态。**只读** —— 不下载、不改配置、不启动进程。
                # 判定在服务层用纯函数算（Get-LLMKitModelVerdict），界面只负责展示结论和原因。
                return (New-JsonResponseBytes -Object (Get-LLMKitLocalReport -ConfigRoot $cfgRoot))
            }            'api-diagnostic' {
                # out 目录是 state 目录的上一级。诊断报告是给人看的、本来就已经脱敏，
                # 读出来时服务层还会再脱敏一遍 —— 不建立在'它当初是干净的'这个假设上。
                return (New-JsonResponseBytes -Object (Get-LLMKitDiagnosticReport -OutDir (Split-Path -Parent $stateDir)))
            }
            'api-tool' {
                return (New-JsonResponseBytes -Object (Get-LLMKitToolDetail -ConfigRoot $cfgRoot -ToolId $route.params.toolId))
            }
            'api-job' {
                $since = 0
                if ($query.ContainsKey('since')) { [void][int]::TryParse([string]$query['since'], [ref]$since) }
                $view = Get-WebJobView -JobId $route.params.jobId -Since $since
                if (-not $view) { return (New-JsonResponseBytes -Object ([ordered]@{ error = 'job not found' }) -StatusCode 404) }
                return (New-JsonResponseBytes -Object $view)
            }
            'api-launch' {
                # 启动一个工具。刻意**不走任务队列**：交互式 CLI 会一直占着窗口，走队列就等于把
                # 唯一任务槽锁死。这里是分离起进程、立即返回 —— 关掉那个窗口也不影响本服务。
                #
                # 安全边界：请求体只认 toolId 与 mode，两者都要过白名单；可执行文件和参数全部
                # 来自服务端配置与检测，外面给不了任何路径、命令或参数。
                $body = Read-JsonBody -Text $Request.body
                if (-not $body) { return (New-JsonResponseBytes -Object ([ordered]@{ error = '请求体不是合法 JSON' }) -StatusCode 400) }
                $toolId = '';
                if ($body.PSObject.Properties.Name -contains 'toolId') { $toolId = [string]$body.toolId }
                $mode = 'interactive'
                if ($body.PSObject.Properties.Name -contains 'mode') { $mode = [string]$body.mode }
                if ([string]::IsNullOrEmpty($toolId)) { return (New-JsonResponseBytes -Object ([ordered]@{ error = '缺少 toolId' }) -StatusCode 400) }
                if (@('interactive', 'smoke') -notcontains $mode) { return (New-JsonResponseBytes -Object ([ordered]@{ error = 'mode 只能是 interactive 或 smoke' }) -StatusCode 400) }
                $spec = $null
                try { $spec = Get-LLMKitLaunchSpec -ConfigRoot $cfgRoot -ToolId $toolId -Mode $mode } catch {
                    return (New-JsonResponseBytes -Object ([ordered]@{ error = $_.Exception.Message }) -StatusCode 400)
                }
                # dryRun：只算要跑什么、不起进程。界面拿它填确认框（和 /api/preview 一个思路），
                # 自检也拿它验整条链路，不用真弹一个窗口出来。
                $dryRun = $false
                if ($body.PSObject.Properties.Name -contains 'dryRun') { $dryRun = [bool]$body.dryRun }

                if (-not $spec.ok) {
                    # 区分两类拒绝：工具名不认识是客户端错误（400）；
                    # 名字对但当前状态下起不来（没装、路径没了）是状态冲突（409）。原因照实给出。
                    $status = 409
                    if ($spec.code -eq 'unknown-tool') { $status = 400 }
                    return (New-JsonResponseBytes -Object ([ordered]@{
                                error = $spec.reason; code = $spec.code; toolId = $toolId; mode = $mode
                            }) -StatusCode $status)
                }
                if ($dryRun) {
                    return (New-JsonResponseBytes -Object ([ordered]@{
                                ok = $true; dryRun = $true; toolId = $spec.toolId; mode = $mode
                                commandLine = $spec.commandLine; executable = $spec.executable
                                filePath = $spec.filePath; workingDir = $spec.workingDir
                                howTo = @($spec.howTo); uiHint = $spec.uiHint
                            }))
                }

                try {
                    $sp = @{ FilePath = $spec.filePath }
                    if (@($spec.arguments).Count -gt 0) { $sp['ArgumentList'] = @($spec.arguments) }
                    if (-not [string]::IsNullOrEmpty($spec.workingDir)) { $sp['WorkingDirectory'] = $spec.workingDir }
                    Start-Process @sp | Out-Null
                } catch {
                    return (New-JsonResponseBytes -Object ([ordered]@{ error = ('启动失败：' + $_.Exception.Message) }) -StatusCode 500)
                }
                return (New-JsonResponseBytes -Object ([ordered]@{
                            ok = $true; toolId = $spec.toolId; mode = $mode
                            commandLine = $spec.commandLine; executable = $spec.executable
                            howTo = @($spec.howTo); uiHint = $spec.uiHint
                        }))
            }
            'api-preview' {
                # 只算命令行，不起任务、不碰系统。确认框要能把"究竟会跑什么"原样摆给用户看。
                $map = ConvertTo-ActionSpecArgs -Body (Read-JsonBody -Text $Request.body) -ConfigRoot $cfgRoot
                if (-not $map.ok) { return (New-JsonResponseBytes -Object ([ordered]@{ error = $map.error }) -StatusCode 400) }
                $specArgs = $map.args
                try { $spec = Get-LLMKitActionCommandLine @specArgs } catch {
                    return (New-JsonResponseBytes -Object ([ordered]@{ error = $_.Exception.Message }) -StatusCode 400)
                }
                return (New-JsonResponseBytes -Object ([ordered]@{
                            commandLine = $spec.commandLine; destructive = $spec.destructive; willApply = $spec.willApply
                        }))
            }
            'api-run' {
                $map = ConvertTo-ActionSpecArgs -Body (Read-JsonBody -Text $Request.body) -ConfigRoot $cfgRoot
                if (-not $map.ok) { return (New-JsonResponseBytes -Object ([ordered]@{ error = $map.error }) -StatusCode 400) }
                $specArgs = $map.args
                $actionId = [string]$specArgs['ActionId']
                $targetId = [string]$specArgs['TargetId']

                $spec = $null
                try { $spec = Get-LLMKitActionCommandLine @specArgs } catch {
                    return (New-JsonResponseBytes -Object ([ordered]@{ error = $_.Exception.Message }) -StatusCode 400)
                }
                $title = $actionId
                try { $title = (Get-LLMKitAction -ActionId $actionId).label } catch { }
                if ($targetId) { $title = $title + ' · ' + $targetId }
                $r = Start-WebJob -CommandSpec $spec -LogDirectory (Join-Path $stateDir 'web-jobs') -Title $title
                if (-not $r.ok) {
                    return (New-JsonResponseBytes -Object ([ordered]@{
                                error = '已有任务在运行，请等它结束'
                                runningJobId = $r.jobId
                            }) -StatusCode 409)
                }
                return (New-JsonResponseBytes -Object ([ordered]@{
                            jobId = $r.jobId; commandLine = $spec.commandLine
                            destructive = $spec.destructive; willApply = $spec.willApply
                        }))
            }
            'api-shutdown' {
                $Server.stopping = $true
                return (New-JsonResponseBytes -Object ([ordered]@{ ok = $true; message = '服务正在关闭' }))
            }
            'static' {
                $resolved = Resolve-StaticPath -WebDir $Server.webDir -Relative $route.file
                if (-not $resolved.ok) {
                    return (New-HttpResponseBytes -StatusCode 403 -ContentType 'text/plain; charset=utf-8' `
                            -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('路径不合法')))
                }
                if (-not (Test-Path -LiteralPath $resolved.full -PathType Leaf)) {
                    return (New-HttpResponseBytes -StatusCode 404 -ContentType 'text/plain; charset=utf-8' `
                            -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('找不到：' + $route.file)))
                }
                $bytes = [System.IO.File]::ReadAllBytes($resolved.full)
                return (New-HttpResponseBytes -StatusCode 200 -ContentType (Get-MimeType -Path $resolved.full) -BodyBytes $bytes)
            }
            'method-not-allowed' {
                return (New-JsonResponseBytes -Object ([ordered]@{ error = '不支持这个 HTTP 方法' }) -StatusCode 405)
            }
            default {
                return (New-JsonResponseBytes -Object ([ordered]@{ error = '没有这个接口：' + $Request.path }) -StatusCode 404)
            }
        }
    } catch {
        $msg = $_.Exception.Message
        try {
            return (New-JsonResponseBytes -Object ([ordered]@{ error = '服务端出错：' + $msg }) -StatusCode 500)
        } catch {
            return (New-HttpResponseBytes -StatusCode 500 -ContentType 'text/plain; charset=utf-8' `
                    -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('500')))
        }
    }
}

function Read-HttpRequest {
    <#
        从一个已连接的 socket 上读完一个请求。
        TcpListener 是 HTTP 之上的最小实现，所以这些都得自己干；
        代价是可控（约 40 行），换来的是不需要 URL ACL、不需要提权。
    #>
    param([Parameter(Mandatory = $true)]$Client, [int]$TimeoutMs = 10000)
    $out = [ordered]@{ ok = $false; method = ''; path = ''; query = ''; version = ''; headers = @{}; body = ''; error = '' }
    $stream = $null
    try {
        $Client.ReceiveTimeout = $TimeoutMs
        $Client.SendTimeout = $TimeoutMs
        $stream = $Client.GetStream()
        $buffer = New-Object byte[] 8192
        $sb = New-Object System.Text.StringBuilder
        $headerEnd = -1
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while ($headerEnd -lt 0) {
            if ((Get-Date) -gt $deadline) { $out.error = '读取请求头超时'; return [pscustomobject]$out }
            $n = $stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { $out.error = '连接被提前关闭'; return [pscustomobject]$out }
            [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buffer, 0, $n))
            $headerEnd = $sb.ToString().IndexOf("`r`n`r`n")
        }
        $raw = $sb.ToString()
        $headText = $raw.Substring(0, $headerEnd)
        $bodySoFar = $raw.Substring($headerEnd + 4)
        $lines = @($headText -split "`r`n")
        $reqLine = ConvertFrom-HttpRequestLine -Line $lines[0]
        if (-not $reqLine.ok) { $out.error = $reqLine.error; return [pscustomobject]$out }
        $out.method = $reqLine.method
        $out.path = $reqLine.path
        $out.query = $reqLine.query
        $out.version = $reqLine.version
        $contentLength = 0
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $idx = $lines[$i].IndexOf(':')
            if ($idx -le 0) { continue }
            $k = $lines[$i].Substring(0, $idx).Trim().ToLowerInvariant()
            $v = $lines[$i].Substring($idx + 1).Trim()
            $out.headers[$k] = $v
            if ($k -eq 'content-length') { [void][int]::TryParse($v, [ref]$contentLength) }
        }
        if ($contentLength -gt 4MB) { $out.error = '请求体过大'; return [pscustomobject]$out }
        $bodyBytes = New-Object System.Collections.Generic.List[byte]
        if ($bodySoFar.Length -gt 0) {
            $bb = [System.Text.Encoding]::UTF8.GetBytes($bodySoFar)
            foreach ($x in $bb) { [void]$bodyBytes.Add($x) }
        }
        while ($bodyBytes.Count -lt $contentLength) {
            if ((Get-Date) -gt $deadline) { $out.error = '读取请求体超时'; return [pscustomobject]$out }
            $n = $stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { break }
            for ($i = 0; $i -lt $n; $i++) { [void]$bodyBytes.Add($buffer[$i]) }
        }
        if ($contentLength -gt 0) {
            $take = [Math]::Min($contentLength, $bodyBytes.Count)
            $arr = New-Object byte[] $take
            for ($i = 0; $i -lt $take; $i++) { $arr[$i] = $bodyBytes[$i] }
            $out.body = [System.Text.Encoding]::UTF8.GetString($arr)
        }
        $out.ok = $true
    } catch {
        $out.error = $_.Exception.Message
    } finally {
        # 这里**绝不能**释放 $stream：NetworkStream 被释放会连带关掉底层 socket，
        # 于是后面写响应就成了"对非连接的套接字执行操作"（实测踩到，表现是每个请求
        # 都被浏览器报"连接被意外关闭"）。流的所有权属于调用方，由它关连接时一并回收。
    }
    return [pscustomobject]$out
}

# ======================================================================
#  服务生命周期
# ======================================================================

function New-WebServer {
    param(
        [string]$ConfigRoot,
        [string]$WebDir,
        [int]$Port = 0,
        [int]$PortRange = 40
    )
    Assert-WebPrerequisites
    if ([string]::IsNullOrEmpty($ConfigRoot)) { $ConfigRoot = Resolve-ServiceConfigRoot }
    if ([string]::IsNullOrEmpty($WebDir)) { $WebDir = Join-Path $ConfigRoot 'web' }
    if (-not (Test-Path -LiteralPath $WebDir -PathType Container)) {
        throw ('找不到前端目录：' + $WebDir)
    }
    $listener = $null
    $usedPort = 0
    # 端口占用就顺延：固定端口在别人机器上大概率会撞，随机又不好记，
    # 折中是"从 17800 开始试，通了就用"，并把最终端口打在日志与界面上
    for ($i = 0; $i -lt $PortRange; $i++) {
        $tryPort = $Port + $i
        try {
            $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $tryPort)
            $l.Start()
            $listener = $l
            $usedPort = $tryPort
            break
        } catch { continue }
    }
    if (-not $listener) { throw ('在 ' + $Port + '~' + ($Port + $PortRange - 1) + ' 范围内找不到可用端口。') }

    return [pscustomobject]([ordered]@{
            listener   = $listener
            port       = $usedPort
            url        = ('http://127.0.0.1:' + $usedPort + '/')
            configRoot = $ConfigRoot
            webDir     = $WebDir
            stateDir   = (Join-Path $ConfigRoot 'out\state')
            stopping   = $false
            served     = 0
            startedAt  = (Get-Date).ToString('o')
            lastError  = ''
        })
}

function Invoke-WebServerLoop {
    <#
        顺序 accept 循环。每个请求处理完就关连接 —— 服务端因此永不阻塞。
        上限保护：单次 accept 等待用 poll 轮询，好让 stopping 标志能及时生效。
    #>
    param([Parameter(Mandatory = $true)]$Server, [int]$PollMs = 200)
    $listener = $Server.listener
    while (-not $Server.stopping) {
        $client = $null
        try {
            if (-not $listener.Pending()) {
                Start-Sleep -Milliseconds $PollMs
                continue
            }
            $client = $listener.AcceptTcpClient()
            $req = Read-HttpRequest -Client $client
            $bytes = $null
            if (-not $req.ok) {
                $bytes = New-HttpResponseBytes -StatusCode 400 -ContentType 'text/plain; charset=utf-8' `
                    -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('请求不合法：' + $req.error))
            } else {
                $bytes = Invoke-WebRequestHandler -Request $req -Server $Server
            }
            $stream = $client.GetStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $Server.served++
        } catch {
            $Server.lastError = $_.Exception.Message
        } finally {
            if ($client) { try { $client.Close() } catch { } }
        }
    }
    try { $listener.Stop() } catch { }
    return $Server
}

function Stop-WebServer {
    param([Parameter(Mandatory = $true)]$Server)
    $Server.stopping = $true
    # 有任务在跑就先把它停掉，别留一个孤儿进程
    if (-not [string]::IsNullOrEmpty($script:CurrentJobId)) {
        $job = $script:JobStore[$script:CurrentJobId]
        if ($job -and -not $job.finished) {
            try { Stop-LLMKitEngineStep -Session $job.session } catch { }
            $job.finished = $true
            $job.state = 'stopped'
        }
    }
    try { $Server.listener.Stop() } catch { }
}

function Get-WebServerJob {
    param([string]$JobId)
    if ([string]::IsNullOrEmpty($JobId)) { return $null }
    return (Update-WebJob -JobId $JobId)
}

Export-ModuleMember -Function `
    'Get-LLMKitWebVersion', 'Assert-WebPrerequisites', `
    'ConvertFrom-HttpRequestLine', 'ConvertFrom-HttpQueryString', 'Get-HttpStatusText', `
    'New-HttpResponseBytes', 'New-JsonResponseBytes', 'Resolve-WebRoute', 'Resolve-StaticPath', 'Get-MimeType', `
    'Read-HttpRequest', 'Read-JsonBody', `
    'New-WebServer', 'Invoke-WebServerLoop', 'Stop-WebServer', `
    'Start-WebJob', 'Update-WebJob', 'Get-WebJobView', 'Get-WebServerJob', 'Invoke-WebRequestHandler'
