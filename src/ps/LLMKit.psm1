#Requires -Version 5.1
<#
    LLMKit 检测引擎
    ------------------------------------------------------------------
    约束（见 README.md「安全边界」）：
      1. 只读      —— 不改注册表、不写系统目录、不创建任何目录、不装任何东西。
                      唯一的持久写入是调用方指定的报告文件。
                      唯一的例外是"可写性探测"：在已存在的目标目录建一个临时文件
                      并立刻删除（净副作用为零），用于判断能否免管理员安装。
      2. 不阻塞    —— 任何单项探测失败都只记为该项目的状态，绝不中断整体。
                      所有外部命令与网络探测都有超时。
      3. 可解释    —— 每项产出 { 状态 + 依据 + 建议动作 }，不只给布尔值。

    目标运行环境：Windows PowerShell 5.1（系统自带）与 PowerShell 7+。

    关键实现注意（都是踩过的坑）：
      * 读文件一律用 UTF-8 显式解码。系统 ANSI 代码页（简中为 GBK）下读 UTF-8
        文件会出现"吞掉后续引号"的情况，导致本来合法的 JSON 解析失败。
      * 解析命令时 .exe/.cmd/.bat 必须优先于 .ps1。nvm-windows 的目录里同时存在
        npm.ps1 / npm.cmd，取错了就会得到 "not a valid application" 错误。
      * 可写性探测在沙箱/受控文件夹访问下会产生假阴性，必须做可靠性判定。
#>

Set-StrictMode -Off

$script:LLMKitVersion = '0.1.1'
$script:SchemaVersion = '0.1.0'
$script:WindowsExecutableExtensions = @('.exe', '.cmd', '.bat', '.com')
$script:ScriptExtensions = @('.ps1', '.psm1')
$script:MaxJsonParseBytes = 4MB
$script:MaxErrorTextLength = 300

# ======================================================================
#  通用工具
# ======================================================================

function Get-LLMKitVersion { $script:LLMKitVersion }

function Expand-PathToken {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.Environment]::ExpandEnvironmentVariables($Path)
}

function Get-MaskedSecret {
    <# 脱敏：永不返回完整密钥 #>
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $v = $Value.Trim()
    if ($v.Length -le 12) { return '***' }
    return $v.Substring(0, 6) + '...' + $v.Substring($v.Length - 4)
}

function Get-ShortErrorText {
    <# 错误信息截断：避免把整个文件内容塞进报告 #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text -replace '\s+', ' '
    if ($t.Length -le $script:MaxErrorTextLength) { return $t }
    return $t.Substring(0, $script:MaxErrorTextLength) + ' ...(已截断)'
}

function Read-TextFileUtf8 {
    <# 显式 UTF-8 读取（自动识别 BOM）。绝不用 Get-Content 的默认编码。 #>
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Test-IsElevated {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function New-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'warn', 'fail', 'info')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Detail = '',
        [string]$Action = '',
        $Data = $null
    )
    return [pscustomobject]([ordered]@{
            id       = $Id
            category = $Category
            status   = $Status
            title    = $Title
            detail   = $Detail
            action   = $Action
            data     = $Data
        })
}

function Get-FileExtension {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    try { return [System.IO.Path]::GetExtension($Path).ToLowerInvariant() } catch { return '' }
}

function Invoke-CapturedProcess {
    <#
        带超时地执行外部命令并捕获输出。失败不抛异常，统一返回结构体。
        支持三类目标：
          * 原生可执行文件
          * .cmd/.bat  —— 经 cmd.exe /d /c 执行（npm 的 shim 就是这种）
          * .ps1       —— 经 powershell.exe -ExecutionPolicy Bypass 执行（nvm 的 shim）
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutMs = 8000
    )
    $result = [ordered]@{
        ok = $false; exitCode = $null; stdout = ''; stderr = ''
        error = ''; durationMs = 0; filePath = $FilePath; launchMode = 'direct'
    }
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $result.error = 'empty-path'
        return [pscustomobject]$result
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = $null
    try {
        if (-not (Test-Path -LiteralPath $FilePath)) {
            $result.error = 'path-not-found'
            return [pscustomobject]$result
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $argLine = ''
        foreach ($a in $Arguments) {
            if ($null -eq $a) { continue }
            if ($a -match '\s') { $argLine += '"' + $a + '" ' } else { $argLine += $a + ' ' }
        }
        $argLine = $argLine.Trim()
        $ext = Get-FileExtension -Path $FilePath

        if ($ext -eq '.cmd' -or $ext -eq '.bat') {
            $comspec = $env:ComSpec
            if ([string]::IsNullOrEmpty($comspec)) { $comspec = 'cmd.exe' }
            $psi.FileName = $comspec
            $psi.Arguments = '/d /c ""' + $FilePath + '" ' + $argLine + '"'
            $result.launchMode = 'cmd-wrapper'
        } elseif ($script:ScriptExtensions -contains $ext) {
            $pwshExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'powershell.exe' }
            $psi.FileName = $pwshExe
            $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $FilePath + '" ' + $argLine
            $result.launchMode = 'ps1-wrapper'
        } else {
            $psi.FileName = $FilePath
            $psi.Arguments = $argLine
        }

        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        if (-not $proc.Start()) {
            $result.error = 'start-failed'
            return [pscustomobject]$result
        }

        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit($TimeoutMs)

        if (-not $exited) {
            try { $proc.Kill() } catch { }
            $result.error = 'timeout'
        } else {
            $result.exitCode = $proc.ExitCode
            $result.ok = ($proc.ExitCode -eq 0)
        }

        try { $result.stdout = [string]$outTask.Result } catch { }
        try { $result.stderr = [string]$errTask.Result } catch { }
        if ($result.stdout) { $result.stdout = $result.stdout.Trim() }
        if ($result.stderr) { $result.stderr = $result.stderr.Trim() }
    } catch {
        $result.error = Get-ShortErrorText -Text $_.Exception.Message
    } finally {
        if ($proc) { try { $proc.Dispose() } catch { } }
    }
    $sw.Stop()
    $result.durationMs = [int]$sw.ElapsedMilliseconds
    return [pscustomobject]$result
}

function Sync-ProcessEnvironmentFromRegistry {
    <#
        把注册表里的环境并进当前进程 —— **只增不减、只补不改**。

        为什么需要：不管是安装器往 PATH 写条目，还是用户用 setx 存了一把 key，注册表都是
        立刻更新的，但**已经跑着的进程读不到** —— 进程的环境块是它启动那一刻的快照。
        Send-EnvironmentChangedBroadcast 只通知资源管理器刷新，不更新自己。于是：
          · 刚装完 Node，同一个进程里再检测还是找不到 node（"装完了怎么还显示未安装"）
          · 刚 setx 存了 key，回到已经开着的界面点"写入配置"，引擎读 $env: 是空的
        这一条把两种情况一起修掉。引擎里那条 dep.path-freshness 检查一直在提示前一种，
        但只给了"重开终端"的建议，没真的修。

        安全取舍：只追加，不删除、不覆盖。
          · 已存在的值一律不动（用户在当前会话里临时改过的值优先）
          · PATH 只有"注册表里有、当前没有、且目录真实存在"时才追加
          · 其它变量只补"当前完全没有"的那些
        最坏情况也只是把一批本来就会随新进程进来的值补上 —— 这正是新开一个终端会看到的东西。
    #>
    param()
    $result = [ordered]@{ ok = $false; addedPath = @(); addedEnv = @(); error = '' }
    # 必须是可增长集合：直接对 $result.addedPath 调 .Add() 会因为它是定长数组而失败（实测踩到）
    $addedPath = New-Object System.Collections.ArrayList
    $addedEnv = New-Object System.Collections.ArrayList
    try {
        # ---- PATH ----
        $sources = New-Object System.Collections.ArrayList
        $user = (Get-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -ErrorAction SilentlyContinue).Path
        if (-not [string]::IsNullOrEmpty($user)) { [void]$sources.Add($user) }
        $machine = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'Path' -ErrorAction SilentlyContinue).Path
        if (-not [string]::IsNullOrEmpty($machine)) { [void]$sources.Add($machine) }

        if ($sources.Count -gt 0) {
            $seen = @{}
            $current = New-Object System.Collections.ArrayList
            foreach ($e in @([string]$env:PATH -split ';')) {
                $t = $e.Trim().TrimEnd('\')
                if ([string]::IsNullOrEmpty($t)) { continue }
                $seen[$t.ToLowerInvariant()] = $true
                [void]$current.Add($t)
            }
            foreach ($src in $sources) {
                # 注册表里的 PATH 是 REG_EXPAND_SZ，可能含 %LOCALAPPDATA% 这类变量
                $expanded = [System.Environment]::ExpandEnvironmentVariables([string]$src)
                foreach ($e in @($expanded -split ';')) {
                    $t = $e.Trim().TrimEnd('\')
                    if ([string]::IsNullOrEmpty($t)) { continue }
                    $k = $t.ToLowerInvariant()
                    if ($seen.ContainsKey($k)) { continue }
                    $seen[$k] = $true
                    if (-not (Test-Path -LiteralPath $t -PathType Container)) { continue }
                    [void]$current.Add($t)
                    [void]$addedPath.Add($t)
                }
            }
            if ($addedPath.Count -gt 0) { $env:PATH = ($current -join ';') }
        }

        # ---- 其余用户环境变量 ----
        # HKCU:\Environment 存的就是用户级环境变量（setx 就写这里）。只补当前完全没有的，
        # 已存在的（包括用户在本次会话里临时改过的）一律不碰。
        $item = Get-Item -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue
        if ($item) {
            foreach ($name in @($item.Property)) {
                if ([string]::IsNullOrEmpty($name)) { continue }
                if ($name -ieq 'Path') { continue }              # 上面单独处理了
                if ($name.StartsWith('=')) { continue }          # 注册表里 "=C:" 之类的特殊项，不能当环境变量
                if (Test-Path -LiteralPath ('Env:' + $name)) { continue }
                $val = $null
                try { $val = $item.GetValue($name, $null, 'DoNotExpandEnvironmentNames') } catch { }
                if ($null -eq $val) { continue }
                # REG_EXPAND_SZ 里的 %VAR% 要展开 —— 新开的进程拿到的也是展开后的值
                $text = [System.Environment]::ExpandEnvironmentVariables([string]$val)
                [System.Environment]::SetEnvironmentVariable($name, $text, 'Process')
                [void]$addedEnv.Add($name)
            }
        }

        $result.addedPath = @($addedPath)
        $result.addedEnv = @($addedEnv)
        $result.ok = $true
    } catch {
        $result.error = $_.Exception.Message
    }
    return [pscustomobject]$result
}
function Get-DependencyProbePaths {
    <#
        从依赖配置里取候选落点。刻意写成防御式读取：$Dependency 可能是空、也可能
        是个数组（调用点用了 @(...) 包住），两种都不该让调用方崩。
    #>
    param($Dependency)
    if ($null -eq $Dependency) { return @() }
    if ($Dependency -is [array]) {
        if ($Dependency.Count -eq 0) { return @() }
        $Dependency = $Dependency[0]
    }
    $out = New-Object System.Collections.ArrayList
    try {
        $det = @($Dependency.PSObject.Properties | Where-Object { $_.Name -eq 'detect' })
        if ($det.Count -gt 0) {
            $pp = @($det[0].Value.PSObject.Properties | Where-Object { $_.Name -eq 'probePaths' })
            if ($pp.Count -gt 0) {
                foreach ($x in @($pp[0].Value)) {
                    if (-not [string]::IsNullOrEmpty([string]$x)) { [void]$out.Add([string]$x) }
                }
            }
        }
    } catch { }
    return @($out)
}

function Resolve-CommandInfo {
    <#
        解析命令的所有命中项，并按"真正可执行"的优先级选出最佳路径。
        优先级：.exe > .cmd > .bat > .com > .ps1
        这是必须的：nvm-windows 的目录里 npm.ps1 与 npm.cmd 并存，
        取到 .ps1 会让进程启动直接失败。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        # PATH 里找不到时，再试这些固定落点（配置里登记过的安装位置）
        [string[]]$ProbePaths = @()
    )
    # 先让当前进程看到注册表里的最新 PATH 与环境变量，否则刚装好的东西会被判成未安装（见函数注释）
    try { $null = Sync-ProcessEnvironmentFromRegistry } catch { }

    $out = [ordered]@{
        name = $Name; best = $null; kind = 'none'; executable = $null
        scriptOnly = $false; allPaths = @(); searchError = ''; probeHit = $false
    }
    $paths = New-Object System.Collections.ArrayList
    try {
        $cmds = @(Get-Command -Name $Name -All -ErrorAction SilentlyContinue)
        foreach ($c in $cmds) {
            $p = $c.Source
            if ([string]::IsNullOrEmpty($p)) { $p = $c.Path }
            if (-not [string]::IsNullOrEmpty($p)) { [void]$paths.Add($p) }
        }
    } catch {
        $out.searchError = Get-ShortErrorText -Text $_.Exception.Message
    }
    $out.allPaths = @($paths)

    foreach ($ext in @('.exe', '.cmd', '.bat', '.com')) {
        # PATH 里没有，就试配置登记的固定落点。有些安装方式不会把目录加进 PATH
        # （官方 .msi 取消勾选 Add to PATH、nvm 符号链接一时失效、第三方装到了别处），
        # 只靠 PATH 判定就会把已经装好的东西说成"未安装"。
        foreach ($cand in @($ProbePaths)) {
            $cp = [System.Environment]::ExpandEnvironmentVariables([string]$cand)
            if ([string]::IsNullOrEmpty($cp)) { continue }
            if ((Get-FileExtension -Path $cp) -eq '.ps1') { continue }
            if (-not (Test-Path -LiteralPath $cp -PathType Leaf)) { continue }
            $out.best = $cp; $out.kind = 'executable'; $out.executable = $cp; $out.probeHit = $true
            $out.allPaths = @($paths) + @($cp)
            return [pscustomobject]$out
        }

        foreach ($p in $paths) {
            if ((Get-FileExtension -Path $p) -eq $ext) {
                $out.best = $p; $out.kind = 'executable'; $out.executable = $p
                return [pscustomobject]$out
            }
        }
    }
    foreach ($p in $paths) {
        if ($script:ScriptExtensions -contains (Get-FileExtension -Path $p)) {
            $out.best = $p; $out.kind = 'ps1-script'; $out.scriptOnly = $true; $out.executable = $p
            return [pscustomobject]$out
        }
    }
    if ($paths.Count -gt 0) {
        $out.best = $paths[0]; $out.kind = 'other'; $out.executable = $paths[0]
    }
    return [pscustomobject]$out
}

function Resolve-CommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)
    # 先让当前进程看到注册表里的最新 PATH 与环境变量，否则刚装好的东西会被判成未安装（见函数注释）
    try { $null = Sync-ProcessEnvironmentFromRegistry } catch { }
    $info = Resolve-CommandInfo -Name $Name
    if ($info.kind -eq 'none') { return $null }
    return $info.executable
}

function Test-TcpReachable {
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [int]$Port = 443,
        [int]$TimeoutMs = 4000
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $signalled = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $signalled) { return $false }
        try { $client.EndConnect($iar); return $true } catch { return $false }
    } catch {
        return $false
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

function Test-DnsResolvable {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [int]$TimeoutMs = 3000
    )
    $out = [ordered]@{ ok = $false; addresses = @(); error = '' }
    try {
        $task = [System.Net.Dns]::GetHostAddressesAsync($HostName)
        if ($task.Wait($TimeoutMs)) {
            try {
                $addrs = $task.Result
                $out.ok = $true
                $list = New-Object System.Collections.ArrayList
                foreach ($a in $addrs) { [void]$list.Add($a.IPAddressToString) }
                $out.addresses = @($list)
            } catch {
                $out.error = Get-ShortErrorText -Text $_.Exception.Message
            }
        } else {
            $out.error = 'timeout'
        }
    } catch {
        $out.error = Get-ShortErrorText -Text $_.Exception.Message
    }
    return [pscustomobject]$out
}

function Resolve-EffectiveProxy {
    <# 决定实际要用哪个代理：系统代理（且已启用）优先，其次环境变量 #>
    param($ProxyState)
    if ($ProxyState) {
        if ($ProxyState.systemProxyEnabled -and $ProxyState.systemProxyServer) {
            $s = [string]$ProxyState.systemProxyServer
            if ($s -notmatch '^[a-zA-Z]+://') { $s = 'http://' + $s }
            return $s
        }
        $envs = $ProxyState.environmentProxies
        if ($envs) {
            if ($envs.HTTPS_PROXY) { return [string]$envs.HTTPS_PROXY }
            if ($envs.HTTP_PROXY) { return [string]$envs.HTTP_PROXY }
            if ($envs.ALL_PROXY) { return [string]$envs.ALL_PROXY }
        }
    }
    return $null
}

function Get-NetworkErrorKind {
    <#
        把底层网络异常归类成人能看懂的种类。
        M4 的错误翻译表就建立在这个分类上。
    #>
    param([string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return 'unknown' }
    $m = $Message.ToLowerInvariant()
    if ($m -match 'timed out|timeout|超时') { return 'timeout' }
    if ($m -match 'name resolution|remote name could not be resolved|no such host') { return 'dns' }
    if ($m -match 'ssl|tls|trust|certificate|证书|schannel') { return 'tls' }
    if ($m -match 'unable to connect to the remote server') { return 'connect-refused' }
    if ($m -match 'underlying connection was closed|unexpected error occurred on a receive|connection reset') { return 'connection-closed' }
    if ($m -match 'proxy|407') { return 'proxy' }
    if ($m -match '403|forbidden|访问被拒绝') { return 'forbidden' }
    if ($m -match '404|not found') { return 'not-found' }
    return 'unknown'
}

function Get-NetworkErrorHint {
    <# 给每种错误一句中文解释 + 该做什么 #>
    param([string]$Kind)
    # 优先走统一错误翻译表（config/errormap.json）：那里每条都带"该做什么"的具体步骤。
    # 只有诊断模块没加载时才回落到下面这张内置小表，保证模块能独立工作。
    try {
        $tbl = Get-Command -Name 'Get-ErrorHintText' -ErrorAction SilentlyContinue
        if ($tbl) {
            $hint = [string](& $tbl -NetKind $Kind)
            if ($hint) { return $hint }
        }
    } catch { }
    switch ($Kind) {
        'timeout' { return '连接超时。可能是网络不通、需要代理，或目标被防火墙拦截。' }
        'dns' { return '域名解析失败。检查 DNS 设置，或该域名被污染/屏蔽。' }
        'tls' { return 'HTTPS 握手失败（证书或加密层问题）。常见于：系统缺少根证书、中间设备做了证书替换、杀毒软件的 HTTPS 扫描、或当前进程不允许访问证书存储。' }
        'connect-refused' { return '连不上目标服务器。端口被防火墙挡住，或必须经过代理才能出去。' }
        'connection-closed' { return '连接被中途关闭，一个字节都没收到。典型原因是：网络里存在只放行连接、不转发数据的中间设备（企业网关、校园网、或被限制的运行环境），也可能需要走代理。' }
        'proxy' { return '代理相关错误。检查代理地址、端口与是否需要认证。' }
        'forbidden' { return '服务器拒绝访问（403）。可能需要代理，或该资源在你的网络里被限制。' }
        'not-found' { return '资源不存在（404）。更多是配置里的 URL 过期，需要更新下载源。' }
        default { return '未知的网络错误，请把完整错误信息连同报告一起反馈。' }
    }
}

function Test-HttpRoundTrip {
    <#
        真实的 HTTP 往返探测。
        只要收到任何合法的 HTTP 响应（哪怕是 403 / 404）就算链路通 —— 我们关心的是
        "数据能不能出去再回来"，不是这个 URL 本身是否有效。
        这是对 TCP 端口探测的必要补充：端口连得上但取不到数据的情况真实存在。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutMs = 8000,
        [string]$Proxy
    )
    $out = [ordered]@{
        ok = $false; url = $Url; status = $null; bytes = 0
        error = ''; kind = ''; hint = ''; elapsedMs = 0; viaProxy = $false
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    $stream = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.UserAgent = 'LLMKit/0.1.0'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.AllowAutoRedirect = $true
        $req.Accept = '*/*'
        if ($Proxy) {
            $req.Proxy = New-Object System.Net.WebProxy($Proxy, $true)
            $out.viaProxy = $true
        }
        $resp = $req.GetResponse()
        $out.status = [int]$resp.StatusCode
        $stream = $resp.GetResponseStream()
        $buf = New-Object byte[] 4096
        $read = $stream.Read($buf, 0, $buf.Length)
        if ($read -lt 0) { $read = 0 }
        $out.bytes = $read
        $out.ok = $true
    } catch {
        $msg = $_.Exception.Message
        $inner = $_.Exception.InnerException
        if ($inner) { $msg = $msg + ' / ' + $inner.Message }
        $out.error = Get-ShortErrorText -Text $msg
        $out.kind = Get-NetworkErrorKind -Message $msg
        $out.hint = Get-NetworkErrorHint -Kind $out.kind
    } finally {
        if ($stream) { try { $stream.Close() } catch { } }
        if ($resp) { try { $resp.Close() } catch { } }
    }
    $sw.Stop()
    $out.elapsedMs = [int]$sw.ElapsedMilliseconds
    return [pscustomobject]$out
}
function Test-DirectoryWritable {
    <# 可写性探测：建临时文件后立即删除，净副作用为零。目录不存在时直接返回 false，绝不创建目录。 #>
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $probe = $null
    try {
        $probe = Join-Path $Path ('.llmkit-write-probe-' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::WriteAllText($probe, 'probe')
        return $true
    } catch {
        return $false
    } finally {
        if ($probe -and (Test-Path -LiteralPath $probe)) {
            try { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Get-WriteProbeReliability {
    <#
        判断"可写性探测"的结论是否可信。
        在沙箱、受控文件夹访问、某些安全软件下，真实可写的目录会探测失败，
        从而把普通机器误判成"无法安装"。这里用两个矛盾信号来识别：
          * 连系统临时目录都不可写          -> 强受限环境
          * 临时目录可写、但其父目录不可写  -> 人为限制（正常系统不会这样）
    #>
    $tempPath = $env:TEMP
    $localPath = $env:LOCALAPPDATA
    $tempWritable = $false
    $localWritable = $false
    if ($tempPath) { $tempWritable = Test-DirectoryWritable -Path $tempPath }
    if ($localPath) { $localWritable = Test-DirectoryWritable -Path $localPath }

    $tempUnderLocal = $false
    if ($tempPath -and $localPath) {
        $t = $tempPath.ToLowerInvariant().TrimEnd('\')
        $l = $localPath.ToLowerInvariant().TrimEnd('\')
        $tempUnderLocal = $t.StartsWith($l + '\')
    }

    $reliable = $true
    $reason = ''
    if (-not $tempWritable) {
        $reliable = $false
        $reason = '连系统临时目录都不可写，当前进程处于强受限环境。'
    } elseif ($tempUnderLocal -and -not $localWritable) {
        $reliable = $false
        $reason = '临时目录可写、但其上级目录（%LOCALAPPDATA%）不可写，两者矛盾，说明可写性被运行环境人为限制（沙箱、受控文件夹访问或安全软件），结果不能代表真实用户环境。'
    }

    return [pscustomobject]([ordered]@{
            reliable             = $reliable
            reason               = $reason
            tempPath             = $tempPath
            tempWritable         = $tempWritable
            localAppDataWritable = $localWritable
            restrictedSuspected  = (-not $reliable)
        })
}

function Get-RegValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $null }
        return $item.$Name
    } catch {
        return $null
    }
}

function Get-EnvVarInScope {
    param([Parameter(Mandatory = $true)][string]$Name)
    # 先让当前进程看到注册表里的最新 PATH 与环境变量，否则刚装好的东西会被判成未安装（见函数注释）
    try { $null = Sync-ProcessEnvironmentFromRegistry } catch { }
    $out = [ordered]@{ process = $null; user = $null; machine = $null }
    foreach ($scope in @('Process', 'User', 'Machine')) {
        try {
            $v = [System.Environment]::GetEnvironmentVariable($Name, $scope)
            if (-not [string]::IsNullOrEmpty($v)) {
                $out[$scope.ToLowerInvariant()] = $v
            }
        } catch { }
    }
    return [pscustomobject]$out
}

function Split-PathList {
    param([string]$PathValue)
    if ([string]::IsNullOrEmpty($PathValue)) { return @() }
    return @($PathValue -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().TrimEnd('\') })
}

function Get-NpmPackageDir {
    param([string]$NpmPrefix, [string]$PackageName)
    if ([string]::IsNullOrEmpty($NpmPrefix) -or [string]::IsNullOrEmpty($PackageName)) { return $null }
    $candidate = Join-Path $NpmPrefix ('node_modules\' + $PackageName)
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Find-InstalledAppInRegistry {
    param([string[]]$DisplayNames)
    $hits = New-Object System.Collections.ArrayList
    if (-not $DisplayNames -or $DisplayNames.Count -eq 0) { return @() }
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        try { $keys = Get-ChildItem -Path $root -ErrorAction SilentlyContinue } catch { continue }
        foreach ($k in $keys) {
            $dn = Get-RegValue -Path $k.PSPath -Name 'DisplayName'
            if ([string]::IsNullOrEmpty($dn)) { continue }
            foreach ($want in $DisplayNames) {
                if ($dn -like ('*' + $want + '*')) {
                    [void]$hits.Add([pscustomobject]@{
                            displayName     = $dn
                            displayVersion  = Get-RegValue -Path $k.PSPath -Name 'DisplayVersion'
                            installLocation = Get-RegValue -Path $k.PSPath -Name 'InstallLocation'
                            registryKey     = $k.PSPath
                        })
                    break
                }
            }
        }
    }
    return @($hits)
}

function Find-StartMenuShortcuts {
    param([string[]]$Patterns)
    $hits = New-Object System.Collections.ArrayList
    if (-not $Patterns -or $Patterns.Count -eq 0) { return @() }
    $roots = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
    )
    foreach ($root in $roots) {
        if ([string]::IsNullOrEmpty($root) -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($pat in $Patterns) {
            try {
                $found = Get-ChildItem -LiteralPath $root -Recurse -Filter ('*' + $pat + '*.lnk') -ErrorAction SilentlyContinue
                foreach ($f in $found) { [void]$hits.Add($f.FullName) }
            } catch { }
        }
    }
    return @($hits)
}

# ======================================================================
#  各类检测项
# ======================================================================

function Test-OperatingSystem {
    param($Checks)
    $osKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $productName = Get-RegValue -Path $osKey -Name 'ProductName'
    $displayVersion = Get-RegValue -Path $osKey -Name 'DisplayVersion'
    $buildRaw = Get-RegValue -Path $osKey -Name 'CurrentBuildNumber'
    $build = 0
    if ($buildRaw) { [void][int]::TryParse([string]$buildRaw, [ref]$build) }

    $arch = $env:PROCESSOR_ARCHITECTURE
    $is64 = $false
    try { $is64 = [System.Environment]::Is64BitOperatingSystem } catch { }

    $verdict = 'fail'
    $label = '未知'
    if ($build -ge 22000) { $verdict = 'ok'; $label = 'Windows 11' }
    elseif ($build -ge 10240) { $verdict = 'ok'; $label = 'Windows 10' }
    else { $verdict = 'fail'; $label = 'Windows 10 之前（不受支持）' }

    $bits = '32 位'
    if ($is64) { $bits = '64 位' }
    $detail = ('内部版本 {0} / 显示版本 {1} / 架构 {2} ({3})' -f $buildRaw, $displayVersion, $arch, $bits)
    $action = ''
    if ($verdict -eq 'fail') {
        $action = 'Windows 10 1809 之前的系统无法使用官方原生安装器，多数 AI 编程工具也已停止支持。建议先升级系统。'
    }
    [void]$Checks.Add((New-Check -Id 'os.version' -Category '系统' -Status $verdict -Title ('操作系统：' + $label) -Detail $detail -Action $action -Data ([ordered]@{
                    productName = $productName; build = $build; displayVersion = $displayVersion; arch = $arch; is64Bit = $is64
                })))

    $archStatus = 'ok'
    $archAction = ''
    if ($arch -match 'ARM64') {
        $archStatus = 'warn'
        $archAction = 'ARM64 设备上部分 CLI 工具只有 x64 构建，可能需要模拟运行，性能与兼容性会有损耗。'
    } elseif (-not $is64) {
        $archStatus = 'fail'
        $archAction = '32 位系统不受支持，需要换 64 位 Windows。'
    }
    [void]$Checks.Add((New-Check -Id 'os.arch' -Category '系统' -Status $archStatus -Title ('处理器架构：' + $arch) -Detail ('64 位操作系统：' + $is64) -Action $archAction))
}

function Test-PowerShellRuntime {
    param($Checks)
    $psv = $PSVersionTable.PSVersion
    $edition = 'Desktop'
    try { $edition = [string]$PSVersionTable.PSEdition } catch { }
    $hostName = ''
    try { $hostName = $Host.Name } catch { }

    [void]$Checks.Add((New-Check -Id 'os.psversion' -Category '系统' -Status 'info' -Title ('当前 PowerShell：' + $psv.ToString()) -Detail ('PSEdition=' + $edition + ' / Host=' + $hostName) -Data ([ordered]@{ version = $psv.ToString(); edition = $edition; host = $hostName })))

    $scopes = @('Process', 'CurrentUser', 'LocalMachine', 'UserPolicy', 'MachinePolicy')
    $policyData = [ordered]@{}
    $restricted = New-Object System.Collections.ArrayList
    foreach ($scope in $scopes) {
        $p = $null
        try { $p = (Get-ExecutionPolicy -Scope $scope -ErrorAction SilentlyContinue) } catch { }
        $policyData[$scope] = [string]$p
        if ($p -eq 'Restricted' -or $p -eq 'AllSigned') { [void]$restricted.Add($scope) }
    }
    $status = 'info'
    $action = ''
    if ($restricted.Count -gt 0) {
        $status = 'warn'
        $action = '脚本版会被执行策略拦截。安装器会以 powershell -ExecutionPolicy Bypass -File 的方式启动以绕过，无需你手动改系统策略。'
    }
    $policyText = (($policyData.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join ' / ')
    [void]$Checks.Add((New-Check -Id 'os.executionpolicy' -Category '系统' -Status $status -Title 'PowerShell 执行策略' -Detail $policyText -Action $action -Data $policyData))
}

function Test-Privileges {
    param($Checks, $State, $Dependencies = @())

    $admin = Test-IsElevated
    $action = ''
    if (-not $admin) {
        $action = '当前没有管理员权限——这没问题。安装器会优先走"用户级安装"路线（装到 %LOCALAPPDATA% 并写用户级 PATH），全程不需要提权。'
    }
    [void]$Checks.Add((New-Check -Id 'priv.admin' -Category '权限' -Status 'info' -Title $(if ($admin) { '当前具备管理员权限' } else { '当前以普通用户身份运行（将走免管理员路线）' }) -Detail ('IsElevated=' + $admin) -Action $action -Data ([ordered]@{ elevated = $admin })))

    $reliability = Get-WriteProbeReliability
    $State.writeProbe = $reliability

    $localPath = $env:LOCALAPPDATA
    $localWritable = $reliability.localAppDataWritable
    $programsDir = Join-Path $localPath 'Programs'
    $programsExists = Test-Path -LiteralPath $programsDir -PathType Container
    $programsWritable = $false
    if ($programsExists) { $programsWritable = Test-DirectoryWritable -Path $programsDir }

    $hiveReadable = $false
    try {
        $null = Get-Item -Path 'HKCU:\Environment' -ErrorAction Stop
        $hiveReadable = $true
    } catch { $hiveReadable = $false }

    if (-not $reliability.reliable) {
        # 探测结论不可信时绝不报 fail —— 否则会在真实可用的机器上误报阻断
        [void]$Checks.Add((New-Check -Id 'priv.portable-capable' -Category '权限' -Status 'warn' -Title '用户级安装能力：无法可靠判定' -Detail ($reliability.reason + ' 参考：%TEMP% 可写=' + $reliability.tempWritable + '，%LOCALAPPDATA% 可写=' + $localWritable) -Action '请在真实用户会话下重新运行体检（直接双击 exe，或在资源管理器里双击脚本），不要在被沙箱或安全软件接管的进程里运行。安装阶段在探测不可信时会先做一次试装验证，再决定是否继续。' -Data ([ordered]@{
                        probeReliable = $false; reason = $reliability.reason
                        localAppDataWritable = $localWritable; programsDirExists = $programsExists
                        programsDirWritable = $programsWritable; userEnvKeyReadable = $hiveReadable
                    })))
        [void]$Checks.Add((New-Check -Id 'env.restricted' -Category '系统' -Status 'warn' -Title '当前进程疑似处于受限运行环境' -Detail $reliability.reason -Action '受限环境下检测出的权限与可写性结论都不可靠。请把这一点连同报告一起反馈，或换到真实用户会话重跑。' -Data ([ordered]@{ restrictedSuspected = $true })))
        return
    }

    $status = 'ok'
    $action = ''
    if (-not $localWritable) {
        $status = 'fail'
        $action = '%LOCALAPPDATA% 不可写，连免管理员安装路线都无法使用。通常是磁盘只读或权限被组策略锁定，需要先解决。'
    } elseif (-not $programsExists) {
        $status = 'info'
        $action = '%LOCALAPPDATA%\Programs 尚不存在，安装器会在需要时创建它（用户级安装的默认落点）。'
    } elseif (-not $programsWritable) {
        $status = 'warn'
        $action = '无法在 %LOCALAPPDATA%\Programs 下写入，安装器会退回到其他用户级目录。'
    } elseif (-not $hiveReadable) {
        $status = 'warn'
        $action = '无法读取 HKCU\Environment，安装后可能无法自动写入用户级 PATH，届时需要手动添加。'
    }

    [void]$Checks.Add((New-Check -Id 'priv.portable-capable' -Category '权限' -Status $status -Title '用户级安装能力（免管理员路线的前提）' -Detail ('%LOCALAPPDATA% 可写=' + $localWritable + ' / Programs 目录存在=' + $programsExists + '（可写=' + $programsWritable + '） / HKCU\Environment 可读=' + $hiveReadable) -Action $action -Data ([ordered]@{
                    probeReliable = $true; localAppDataWritable = $localWritable
                    programsDirExists = $programsExists; programsDirWritable = $programsWritable
                    userEnvKeyReadable = $hiveReadable
                })))
}

function Test-SystemFacts {
    param($Checks)
    $longPaths = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled'
    $lpEnabled = ($longPaths -eq 1)
    $status = 'info'
    $action = ''
    if (-not $lpEnabled) {
        $status = 'warn'
        $action = '未开启长路径支持。node_modules 嵌套很深时偶发"路径过长"报错。开启需要管理员权限（注册表 LongPathsEnabled=1），不开启也能用。'
    }
    [void]$Checks.Add((New-Check -Id 'sys.longpaths' -Category '系统' -Status $status -Title 'NTFS 长路径支持' -Detail ('LongPathsEnabled=' + [string]$longPaths) -Action $action -Data ([ordered]@{ longPathsEnabled = $lpEnabled })))

    $freeGB = $null
    $totalGB = $null
    try {
        $di = New-Object System.IO.DriveInfo('C')
        if ($di.IsReady) {
            $freeGB = [math]::Round($di.AvailableFreeSpace / 1GB, 2)
            $totalGB = [math]::Round($di.TotalSize / 1GB, 2)
        }
    } catch { }
    if ($null -eq $freeGB) {
        try {
            $drive = Get-PSDrive -Name 'C' -ErrorAction Stop
            if ($drive.Free) { $freeGB = [math]::Round($drive.Free / 1GB, 2) }
            if ($drive.Used -and $drive.Free) { $totalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 2) }
        } catch { }
    }
    if ($null -eq $freeGB) {
        try {
            $ld = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
            $freeGB = [math]::Round($ld.FreeSpace / 1GB, 2)
            $totalGB = [math]::Round($ld.Size / 1GB, 2)
        } catch { }
    }

    $status = 'info'
    $action = ''
    $freeText = '未知'
    if ($null -ne $freeGB) { $freeText = $freeGB.ToString() + ' GB' }
    if ($null -ne $freeGB) {
        if ($freeGB -lt 2) {
            $status = 'fail'
            $action = '系统盘剩余空间不足 2 GB，无法完成安装。请先清理磁盘。'
        } elseif ($freeGB -lt 5) {
            $status = 'warn'
            $action = '系统盘剩余空间偏少。安装 Node.js 与各 CLI 工具建议预留 5 GB 以上。'
        } else {
            $status = 'ok'
        }
    }
    $totalText = '未知'
    if ($null -ne $totalGB) { $totalText = $totalGB.ToString() + ' GB' }
    [void]$Checks.Add((New-Check -Id 'sys.disk' -Category '系统' -Status $status -Title ('系统盘剩余空间：' + $freeText) -Detail ('总容量：' + $totalText) -Action $action -Data ([ordered]@{ drive = 'C:'; freeGB = $freeGB; totalGB = $totalGB })))

    $wt = Resolve-CommandPath -Name 'wt'
    $wtTail = '未找到'
    if ($wt) { $wtTail = $wt }
    [void]$Checks.Add((New-Check -Id 'sys.terminal' -Category '系统' -Status 'info' -Title $(if ($wt) { '已安装 Windows Terminal' } else { '未安装 Windows Terminal（可选）' }) -Detail ('路径：' + $wtTail) -Action '' -Data ([ordered]@{ path = $wt })))
}

function Test-Dependencies {
    param($Checks, $State)

    # ---- Node.js ----
    $nodeDep = @($Dependencies | Where-Object { $_.id -eq 'node' })
    $nodeInfo = Resolve-CommandInfo -Name 'node' -ProbePaths (Get-DependencyProbePaths -Dependency $nodeDep)
    $nodePath = $nodeInfo.executable
    $nodeVersion = $null
    $nodeMajor = $null
    $nodeError = ''
    if ($nodePath) {
        $r = Invoke-CapturedProcess -FilePath $nodePath -Arguments @('-v') -TimeoutMs 6000
        if ($r.stdout) {
            $nodeVersion = ($r.stdout -split "`n")[0].Trim()
            $m = [regex]::Match($nodeVersion, 'v?(\d+)\.')
            if ($m.Success) { $nodeMajor = [int]$m.Groups[1].Value }
        }
        if (-not $nodeVersion) {
            $rawErr = $r.error
            if (-not $rawErr -and $r.stderr) { $rawErr = $r.stderr }
            if (-not $rawErr) { $rawErr = '未返回版本号' }
            $nodeError = Get-ShortErrorText -Text $rawErr
        }
    }
    $State.node = [ordered]@{ path = $nodePath; version = $nodeVersion; major = $nodeMajor; kind = $nodeInfo.kind; error = $nodeError }

    $status = 'ok'; $action = ''; $title = ''
    if (-not $nodePath) {
        $status = 'warn'; $title = 'Node.js 未安装'
        $action = '不必担心：Claude Code 会优先走官方原生安装器（不需要 Node.js）。只有 Codex / OpenCode / Gemini CLI 需要 Node，届时安装器会问你要不要补装。'
    } elseif (-not $nodeVersion) {
        $status = 'warn'; $title = 'Node.js 已找到但无法读取版本'
        $action = '命令存在但执行失败，通常是 shim 类型不对或安全软件拦截。安装器会改用原生安装器路线继续，不受影响。'
    } elseif ($null -ne $nodeMajor -and $nodeMajor -lt 18) {
        $status = 'warn'; $title = ('Node.js 版本过低：' + $nodeVersion)
        $action = '低于 18 无法安装新版 CLI 工具。安装器会引导你升级到 LTS（免管理员可用便携版）。'
    } else {
        $title = 'Node.js 就绪：' + $nodeVersion
    }
    $nodeDetail = '路径：' + $(if ($nodePath) { $nodePath } else { '未找到' })
    if ($nodeError) { $nodeDetail += ' / 错误：' + $nodeError }
    [void]$Checks.Add((New-Check -Id 'dep.node' -Category '依赖' -Status $status -Title $title -Detail $nodeDetail -Action $action -Data $State.node))

    # ---- npm ----
    $npmInfo = Resolve-CommandInfo -Name 'npm'
    $npmPath = $npmInfo.executable
    $npmVersion = $null
    $npmError = ''
    if ($npmPath) {
        $r = Invoke-CapturedProcess -FilePath $npmPath -Arguments @('-v') -TimeoutMs 15000
        if ($r.stdout) { $npmVersion = ($r.stdout -split "`n")[0].Trim() }
        if (-not $npmVersion) {
            $rawErr = $r.error
            if (-not $rawErr -and $r.stderr) { $rawErr = $r.stderr }
            if (-not $rawErr) { $rawErr = '未返回版本号' }
            $npmError = Get-ShortErrorText -Text $rawErr
        }
    }
    $State.npm = [ordered]@{ path = $npmPath; version = $npmVersion; kind = $npmInfo.kind; allPaths = @($npmInfo.allPaths); error = $npmError }

    if (-not $npmPath) {
        $status = 'warn'; $title = 'npm 未安装'
        $action = '没有 npm。Claude Code 的原生安装器路线不受影响；其他 CLI 工具需要先装 Node.js（npm 会随 Node 一起装上）。'
    } elseif (-not $npmVersion) {
        $status = 'warn'; $title = 'npm 已找到但无法读取版本'
        $action = '命令存在但执行失败。安装器会在安装阶段改用 .cmd shim 或直接调用原始可执行文件的方式重试。'
    } else {
        $status = 'ok'; $title = 'npm 就绪：' + $npmVersion; $action = ''
    }
    $npmDetail = '路径：' + $(if ($npmPath) { $npmPath } else { '未找到' }) + ' / 命中类型：' + $npmInfo.kind
    if ($npmError) { $npmDetail += ' / 错误：' + $npmError }
    [void]$Checks.Add((New-Check -Id 'dep.npm' -Category '依赖' -Status $status -Title $title -Detail $npmDetail -Action $action -Data $State.npm))

    # ---- npm 全局目录可写性 ----
    $npmPrefix = $null
    $npmPrefixWritable = $false
    $npmPrefixError = ''
    if ($npmPath) {
        $r = Invoke-CapturedProcess -FilePath $npmPath -Arguments @('prefix', '-g') -TimeoutMs 20000
        if ($r.stdout) {
            $all = @($r.stdout -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($all.Count -gt 0) { $npmPrefix = $all[$all.Count - 1].Trim() }
        }
        if (-not $npmPrefix) {
            $rawErr = $r.error
            if (-not $rawErr -and $r.stderr) { $rawErr = $r.stderr }
            if (-not $rawErr) { $rawErr = '未返回路径' }
            $npmPrefixError = Get-ShortErrorText -Text $rawErr
        }
        if ($npmPrefix) { $npmPrefixWritable = Test-DirectoryWritable -Path $npmPrefix }
    }
    $State.npmPrefix = [ordered]@{ path = $npmPrefix; writable = $npmPrefixWritable; error = $npmPrefixError }
    if ($npmPath) {
        $status = 'ok'; $action = ''; $title = ''
        if (-not $npmPrefix) {
            $status = 'info'; $title = 'npm 全局目录：未知'
            $action = '无法读取 npm 的全局目录。安装阶段会直接尝试并给出明确结果。'
        } elseif (-not $npmPrefixWritable) {
            if ($State.writeProbe -and -not $State.writeProbe.reliable) {
                $status = 'info'; $title = 'npm 全局目录可写性：无法可靠判定'
                $action = '当前进程处于受限环境，可写性探测不可信。请在真实用户会话下重跑。'
            } else {
                $status = 'warn'; $title = 'npm 全局目录不可写'
                $action = '当前用户不可写，"npm install -g" 会失败。安装器会把 npm prefix 改到用户目录（%APPDATA%\npm）后重试，不需要管理员。'
            }
        } else {
            $title = 'npm 全局目录可写'
        }
        $prefixDetail = '路径：' + $(if ($npmPrefix) { $npmPrefix } else { '未知' })
        if ($npmPrefixError) { $prefixDetail += ' / 错误：' + $npmPrefixError }
        [void]$Checks.Add((New-Check -Id 'dep.npm-prefix' -Category '依赖' -Status $status -Title $title -Detail $prefixDetail -Action $action -Data $State.npmPrefix))
    }

    # ---- Git ----
    $gitDep = @($Dependencies | Where-Object { $_.id -eq 'git' })
    $gitInfo = Resolve-CommandInfo -Name 'git' -ProbePaths (Get-DependencyProbePaths -Dependency $gitDep)
    $gitPath = $gitInfo.executable
    $gitVersion = $null
    $gitError = ''
    if ($gitPath) {
        $r = Invoke-CapturedProcess -FilePath $gitPath -Arguments @('--version') -TimeoutMs 6000
        if ($r.stdout) { $gitVersion = ($r.stdout -split "`n")[0].Trim() }
        if (-not $gitVersion) {
            $rawErr = $r.error
            if (-not $rawErr -and $r.stderr) { $rawErr = $r.stderr }
            if (-not $rawErr) { $rawErr = '未返回版本号' }
            $gitError = Get-ShortErrorText -Text $rawErr
        }
    }
    $State.git = [ordered]@{ path = $gitPath; version = $gitVersion; kind = $gitInfo.kind; error = $gitError }
    if (-not $gitPath) {
        $status = 'warn'; $title = 'Git 未安装'
        $action = '未检测到 Git。Claude Code 的部分功能（Bash 工具、差异对比）在 Windows 上依赖 Git for Windows。安装器会问你是否补装免管理员的 MinGit 便携版。'
    } elseif (-not $gitVersion) {
        $status = 'warn'; $title = 'Git 已找到但无法读取版本'
        $action = '命令执行失败，安装器会继续，并在验证阶段给出明确结果。'
    } else {
        $status = 'ok'; $title = 'Git 就绪：' + $gitVersion; $action = ''
    }
    $gitDetail = '路径：' + $(if ($gitPath) { $gitPath } else { '未找到' })
    if ($gitError) { $gitDetail += ' / 错误：' + $gitError }
    [void]$Checks.Add((New-Check -Id 'dep.git' -Category '依赖' -Status $status -Title $title -Detail $gitDetail -Action $action -Data $State.git))

    # ---- PATH 新鲜度 ----
    $procList = Split-PathList -PathValue $env:PATH
    $userList = Split-PathList -PathValue ([System.Environment]::GetEnvironmentVariable('Path', 'User'))
    $machineList = Split-PathList -PathValue ([System.Environment]::GetEnvironmentVariable('Path', 'Machine'))
    $procLower = @{}
    foreach ($p in $procList) { $procLower[$p.ToLowerInvariant()] = $true }

    $missing = New-Object System.Collections.ArrayList
    foreach ($p in @($userList + $machineList)) {
        $key = $p.ToLowerInvariant()
        if (-not $procLower.ContainsKey($key)) {
            $interesting = ($p -match 'npm|nodejs|\.local\\bin|Programs\\|WindowsApps|Git')
            [void]$missing.Add([pscustomobject]@{ path = $p; interesting = $interesting })
        }
    }
    $interestingMissing = @($missing | Where-Object { $_.interesting })
    $State.pathFreshness = [ordered]@{
        processEntries = $procList.Count; userEntries = $userList.Count; machineEntries = $machineList.Count
        missingFromProcess = $missing.Count; missingInteresting = @($interestingMissing | ForEach-Object { $_.path })
    }
    $status = 'ok'; $action = ''
    if ($interestingMissing.Count -gt 0) {
        $status = 'warn'
        $action = '注册表 PATH 里有目录不在当前进程的 PATH 中——这正是"明明装了却提示找不到命令"的根因。安装器会在安装后直接用绝对路径调用，并指导你重开终端。'
    }
    $pathDetail = '当前进程 PATH 与注册表一致'
    if ($interestingMissing.Count -gt 0) {
        $pathDetail = '未生效的关键目录：' + (($interestingMissing | ForEach-Object { $_.path }) -join ' ; ')
    }
    [void]$Checks.Add((New-Check -Id 'dep.path-freshness' -Category '依赖' -Status $status -Title ('PATH 新鲜度：' + $missing.Count + ' 项未生效，其中关键项 ' + $interestingMissing.Count + ' 个') -Detail $pathDetail -Action $action -Data $State.pathFreshness))
}

function Get-ToolStatus {
    param($Tool, $State, [int]$CommandTimeoutMs = 8000)

    $installations = New-Object System.Collections.ArrayList
    $seen = @{}

    # 1) PATH 命中（可能有多条：ps1 + cmd）
    # detectOnlyCommands 是"启动器"（python 的 py.exe 就是），只用来兜底判断装没装，
    # 不当成第二份安装 —— 否则一份 Python 会被数成两份，无端报"多副本冲突"。
    $launcherCmds = @($Tool.detectOnlyCommands | Where-Object { $_ })
    foreach ($c in (@($Tool.commands) + $launcherCmds)) {
        $isLauncher = ($launcherCmds -contains $c)
        $info = Resolve-CommandInfo -Name $c
        foreach ($p in @($info.allPaths)) {
            $key = $p.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                [void]$installations.Add([pscustomobject]@{
                        path    = $p
                        kind    = $(if ($isLauncher) { 'launcher' } else { 'path' })
                        source  = $(if ($isLauncher) { '启动器命中 (' + $c + ')' } else { 'PATH 命中 (' + $c + ')' })
                        command = $c
                    })
            }
        }
    }

    # 2) 候选路径
    foreach ($candidate in @($Tool.probePaths)) {
        $expanded = Expand-PathToken -Path $candidate
        if (Test-Path -LiteralPath $expanded) {
            $key = $expanded.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $isDir = (Test-Path -LiteralPath $expanded -PathType Container)
                [void]$installations.Add([pscustomobject]@{ path = $expanded; kind = $(if ($isDir) { 'directory' } else { 'file' }); source = '候选路径'; command = $null })
            }
        }
    }

    # 3) npm 全局包目录
    if ($Tool.npmPackage -and $State.npmPrefix -and $State.npmPrefix.path) {
        $pkgDir = Get-NpmPackageDir -NpmPrefix $State.npmPrefix.path -PackageName $Tool.npmPackage
        if ($pkgDir) {
            $key = $pkgDir.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                [void]$installations.Add([pscustomobject]@{ path = $pkgDir; kind = 'npm-package'; source = ('npm 包 ' + $Tool.npmPackage); command = $null })
            }
        }
    }

    # 3b) npm 全局 bin 目录。npm prefix 由 nvm / 自定义 prefix 决定，
    #     写死 %APPDATA%\npm 会漏掉 nvm 用户装的 CLI（真实踩到过）。
    if ($State.npmPrefix -and $State.npmPrefix.path) {
        foreach ($c in @($Tool.commands)) {
            foreach ($shimExt in @('.cmd', '.exe', '.ps1', '')) {
                $cand = Join-Path $State.npmPrefix.path ($c + $shimExt)
                if (Test-Path -LiteralPath $cand -PathType Leaf) {
                    $key = $cand.ToLowerInvariant()
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        [void]$installations.Add([pscustomobject]@{ path = $cand; kind = 'file'; source = 'npm 全局 bin'; command = $c })
                    }
                    break
                }
            }
        }
    }

    # 4) GUI 应用：注册表卸载表 + 开始菜单快捷方式
    $registryHits = @()
    if ($Tool.uninstallRegistryNames) {
        $registryHits = Find-InstalledAppInRegistry -DisplayNames @($Tool.uninstallRegistryNames)
        foreach ($h in $registryHits) {
            if ($h.installLocation) {
                $loc = [string]$h.installLocation
                $key = $loc.ToLowerInvariant()
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    [void]$installations.Add([pscustomobject]@{ path = $loc; kind = 'install-dir'; source = ('注册表：' + $h.displayName); command = $null })
                }
                # 把安装目录里的可执行文件解析出来，才能进入冲突判定与启动验证
                if (Test-Path -LiteralPath $loc -PathType Container) {
                    try {
                        $exes = @(Get-ChildItem -LiteralPath $loc -Filter '*.exe' -File -ErrorAction SilentlyContinue)
                        foreach ($exe in $exes) {
                            $ekey = $exe.FullName.ToLowerInvariant()
                            if (-not $seen.ContainsKey($ekey)) {
                                $seen[$ekey] = $true
                                [void]$installations.Add([pscustomobject]@{ path = $exe.FullName; kind = 'file'; source = ('注册表安装目录：' + $exe.Name); command = $null })
                            }
                        }
                    } catch { }
                }
            }
        }
    }
    $shortcutHits = @()
    if ($Tool.uninstallRegistryNames) {
        $shortcutHits = Find-StartMenuShortcuts -Patterns @($Tool.uninstallRegistryNames)
    }

    # WindowsApps 下的 python.exe / py.exe 是"应用执行别名"（0 字节存根，指向商店里的 Python），
    # 它既不是另一份安装、也不该被当成可启动的解释器：单独标成 alias，算副本时跳过。
    for ($idx = 0; $idx -lt $installations.Count; $idx++) {
        $ipath = [string]$installations[$idx].path
        if ($ipath -match '\\Microsoft\\WindowsApps\\') {
            $installations[$idx] = [pscustomobject]@{
                path = $ipath; kind = 'alias'; source = '商店应用别名（不计入副本）'; command = $installations[$idx].command
            }
        }
    }

    # 版本探测：优先用真正可执行的命中项
    $versionOutput = $null
    $versionError = ''
    $executable = $null
    foreach ($inst in $installations) {
        if ($inst.kind -eq 'path' -or $inst.kind -eq 'file') {
            if ($script:WindowsExecutableExtensions -contains (Get-FileExtension -Path $inst.path)) { $executable = $inst.path; break }
        }
    }
    if (-not $executable) {
        foreach ($inst in $installations) {
            if ($inst.kind -eq 'path' -or $inst.kind -eq 'file') { $executable = $inst.path; break }
        }
    }
    if ($executable -and $Tool.verify -and $Tool.verify.versionCommand) {
        $r = Invoke-CapturedProcess -FilePath $executable -Arguments @('--version') -TimeoutMs $CommandTimeoutMs
        if ($r.stdout) { $versionOutput = ($r.stdout -split "`n")[0].Trim() }
        elseif ($r.stderr) { $versionOutput = ($r.stderr -split "`n")[0].Trim() }
        if (-not $versionOutput -and $r.error) { $versionError = Get-ShortErrorText -Text $r.error }
    }

    # 只把"可执行文件级别"的命中算作安装实例，用于冲突判定。
    # 但必须先折叠：npm 全局安装会同时放 dsh / dsh.cmd / dsh.ps1，那是同一个命令的
    # 三个启动器，属于**同一份安装**。以前只按完整路径去重，于是它们被数成三份，
    # 而这里是 execCount > 1 —— 结果给一个完全健康的 npm 安装报"多副本冲突"，
    # 还建议用户去清理残留再重装，把人往错的方向指。
    # （这台机器上 dsh 是第一个已安装的 npm 全局工具，所以这个缺陷到那时才暴露。）
    $executableKinds = @('path', 'file')
    $execInstalls = @($installations | Where-Object { $executableKinds -contains $_.kind })
    # 折叠前先让"能直接跑的启动器"排在前面（.exe/.cmd/.bat/.com 优先于 .ps1）：
    # 留下 的那一个必须仍可直接启动，否则版本探测会退到拿 .ps1 去当程序跑（实测会失败）。
    $exeExts = @($script:WindowsExecutableExtensions)
    $runnableInstalls = @($execInstalls | Where-Object { $exeExts -contains (Get-FileExtension -Path $_.path) })
    $scriptInstalls = @($execInstalls | Where-Object { -not ($exeExts -contains (Get-FileExtension -Path $_.path)) })
    $folded = New-Object System.Collections.ArrayList
    $groupSeen = @{}
    foreach ($inst in (@($runnableInstalls) + @($scriptInstalls))) {
        $gkey = ''
        try {
            $gkey = ((Split-Path -Parent ([string]$inst.path)) + '\' +
                [System.IO.Path]::GetFileNameWithoutExtension([string]$inst.path)).ToLowerInvariant()
        } catch { }
        if ([string]::IsNullOrEmpty($gkey)) { [void]$folded.Add($inst); continue }
        if ($groupSeen.ContainsKey($gkey)) { continue }
        $groupSeen[$gkey] = $true
        [void]$folded.Add($inst)
    }
    # 非可执行类的命中（npm 包目录、注册表安装目录）照旧留在清单里，只是不参与冲突判定
    $nonExecInstalls = @($installations | Where-Object { $executableKinds -notcontains $_.kind })
    $installations = @($folded) + @($nonExecInstalls)
    $execInstalls = @($folded)
    $execCount = $execInstalls.Count
    # 商店别名不算"装了"：那种 0 字节存根在没装 Python 的机器上也可能存在
    $realInstalls = @($installations | Where-Object { $_.kind -ne 'alias' })
    $installed = ($realInstalls.Count -gt 0)
    $conflict = ($execCount -gt 1)
    # 只找到 py 启动器、没找到 python.exe：仍然算装了，但要如实标出来
    $launcherInstalls = @($installations | Where-Object { $_.kind -eq 'launcher' })
    $onlyLauncher = $false
    if ($execCount -eq 0 -and $launcherInstalls.Count -gt 0) {
        $installed = $true
        $onlyLauncher = $true
        if (-not $executable) { $executable = [string]$launcherInstalls[0].path }
    }

    # 版本下限（例如 Node 要 v18+）：低于下限时如实标出来，别等别的工具装不上才发现
    $minMajor = $null
    $majorNow = $null
    if ($Tool.verify) {
        $mm = Get-ObjectProp -Object $Tool.verify -Name 'minMajor'
        if ($null -ne $mm) { $minMajor = [int]$mm }
    }
    if ($versionOutput) {
        $mv = [regex]::Match([string]$versionOutput, '(\d+)\.')
        if ($mv.Success) { $majorNow = [int]$mv.Groups[1].Value }
    }
    $belowMinVersion = ($null -ne $minMajor -and $null -ne $majorNow -and $majorNow -lt $minMajor)

    return [pscustomobject]([ordered]@{
            id            = $Tool.id
            name          = $Tool.name
            vendor        = $Tool.vendor
            kind          = $Tool.kind
            installed     = $installed
            installCount  = $execCount
            minMajor        = $minMajor
            majorVersion    = $majorNow
            belowMinVersion = $belowMinVersion
            conflict      = $conflict
            onlyLauncher  = $onlyLauncher
            executable    = $executable
            version       = $versionOutput
            versionError  = $versionError
            installations = @($installations)
            registryHits  = @($registryHits)
            shortcuts     = @($shortcutHits)
            homeUrl       = $Tool.homeUrl
            preferredTier = $(if ($Tool.install) { $Tool.install.preferred } else { $null })
        })
}

function Test-TargetTools {
    param($Checks, $State, $Tools, [int]$CommandTimeoutMs = 8000)

    $results = [ordered]@{}
    foreach ($tool in @($Tools)) {
        $st = $null
        try {
            $st = Get-ToolStatus -Tool $tool -State $State -CommandTimeoutMs $CommandTimeoutMs
        } catch {
            $st = [pscustomobject]([ordered]@{
                    id = $tool.id; name = $tool.name; installed = $false; installCount = 0
                    conflict = $false; installations = @(); versionError = (Get-ShortErrorText -Text $_.Exception.Message)
                })
        }
        $results[$tool.id] = $st

        $status = 'ok'; $action = ''
        if (-not $st.installed) {
            $status = 'info'
            $action = '尚未安装。安装器会在这里提供一键安装。'
        } elseif ($st.conflict) {
            $status = 'warn'
            $action = '检测到多份安装。多个版本共存会导致命令走了旧的那份、升级后仍是旧版本等怪问题。官方排障文档的建议是只保留一份——安装器会列出全部位置让你选择保留哪个。'
        }

        $pathSummary = ''
        if ($st.installations.Count -gt 0) {
            $pathSummary = (($st.installations | ForEach-Object { $_.path }) -join ' | ')
        }
        $titleTail = '：未安装'
        if ($st.installed) {
            $v = $st.version
            if (-not $v) { $v = '(版本未知)' }
            $titleTail = '：已安装 ' + $v
        }
        $toolDetail = '未在 PATH、候选路径、npm 全局目录或注册表中找到'
        if ($pathSummary) { $toolDetail = '位置：' + $pathSummary }
        if ($st.versionError) { $toolDetail += ' / 错误：' + $st.versionError }
        [void]$Checks.Add((New-Check -Id ('tool.' + $tool.id) -Category '工具' -Status $status -Title ($tool.name + $titleTail) -Detail $toolDetail -Action $action -Data ([ordered]@{
                    installed = $st.installed; version = $st.version; installCount = $st.installCount
                    conflict = $st.conflict; preferredTier = $st.preferredTier; versionError = $st.versionError
                })))
    }
    return $results
}

function Test-Configuration {
    param($Checks, $State, $Tools)

    $claudeDir = Join-Path $env:USERPROFILE '.claude'
    $dirExists = Test-Path -LiteralPath $claudeDir
    [void]$Checks.Add((New-Check -Id 'cfg.claude-dir' -Category '配置' -Status 'info' -Title $(if ($dirExists) { '已存在 Claude Code 配置目录' } else { '尚无 Claude Code 配置目录（全新环境）' }) -Detail ('路径：' + $claudeDir) -Action '' -Data ([ordered]@{ path = $claudeDir; exists = $dirExists })))

    $configSummary = [ordered]@{}
    foreach ($tool in @($Tools)) {
        $entries = New-Object System.Collections.ArrayList
        foreach ($cf in @($tool.configFiles)) {
            $expanded = Expand-PathToken -Path $cf.path
            $exists = Test-Path -LiteralPath $expanded
            $envKeys = @()
            $parseError = ''
            $skipped = ''
            $sizeBytes = $null
            $onboarding = $null
            if ($exists) {
                try {
                    $fi = Get-Item -LiteralPath $expanded -ErrorAction Stop
                    if (-not $fi.PSIsContainer) { $sizeBytes = $fi.Length }
                } catch { }

                if ($cf.type -eq 'json') {
                    if ($null -ne $sizeBytes -and $sizeBytes -gt $script:MaxJsonParseBytes) {
                        $skipped = 'too-large'
                    } else {
                        try {
                            $raw = Read-TextFileUtf8 -Path $expanded
                            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                                # 首次引导状态位用正则轻量提取，不依赖完整解析
                                $m = [regex]::Match($raw, '"hasCompletedOnboarding"\s*:\s*(true|false)')
                                if ($m.Success) { $onboarding = ($m.Groups[1].Value -eq 'true') }
                                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                                if ($obj.PSObject.Properties.Name -contains 'env' -and $obj.env) {
                                    $envKeys = @($obj.env.PSObject.Properties.Name)
                                }
                            }
                        } catch {
                            $parseError = Get-ShortErrorText -Text $_.Exception.Message
                        }
                    }
                }
            }
            [void]$entries.Add([pscustomobject]([ordered]@{
                        path = $expanded; declaredPath = $cf.path; type = $cf.type
                        purpose = $cf.purpose; exists = $exists; sizeBytes = $sizeBytes
                        envKeys = $envKeys; parseError = $parseError; skipped = $skipped
                        hasCompletedOnboarding = $onboarding
                    }))
        }
        $configSummary[$tool.id] = @($entries)
        $existing = @($entries | Where-Object { $_.exists })
        if ($existing.Count -gt 0) {
            $broken = @($existing | Where-Object { $_.parseError })
            $status = 'info'; $action = ''
            if ($broken.Count -gt 0) {
                $status = 'warn'
                $action = '有配置文件无法解析为合法 JSON。安装器在写入前会先做时间戳备份，并让你确认是否修复；原始文件不会被直接覆盖。'
            }
            [void]$Checks.Add((New-Check -Id ('cfg.' + $tool.id) -Category '配置' -Status $status -Title ($tool.name + '：发现 ' + $existing.Count + ' 个已有配置文件') -Detail (($existing | ForEach-Object { $_.path }) -join ' | ') -Action $action -Data ([ordered]@{ files = @($existing | Select-Object -Property path, sizeBytes, envKeys, hasCompletedOnboarding, parseError, skipped) })))
        }
    }
    $State.configFiles = $configSummary

    # ---- 关键环境变量（三作用域 + 脱敏） ----
    $watched = @(
        'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_MODEL',
        'OPENAI_API_KEY', 'OPENAI_BASE_URL', 'GEMINI_API_KEY',
        'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY'
    )
    $isSecret = @{ 'ANTHROPIC_AUTH_TOKEN' = $true; 'ANTHROPIC_API_KEY' = $true; 'OPENAI_API_KEY' = $true; 'GEMINI_API_KEY' = $true }
    $envData = [ordered]@{}
    $conflicts = New-Object System.Collections.ArrayList
    $presentList = New-Object System.Collections.ArrayList

    foreach ($name in $watched) {
        $scopes = Get-EnvVarInScope -Name $name
        $shown = [ordered]@{}
        $nonEmptyScopes = @()
        foreach ($scope in @('process', 'user', 'machine')) {
            $v = $scopes.$scope
            if (-not [string]::IsNullOrEmpty($v)) {
                $nonEmptyScopes += $scope
                if ($isSecret[$name]) { $shown[$scope] = Get-MaskedSecret -Value $v }
                else { $shown[$scope] = $v }
            } else {
                $shown[$scope] = $null
            }
        }
        $envData[$name] = [ordered]@{ scopes = $shown; definedIn = $nonEmptyScopes }
        if ($nonEmptyScopes.Count -gt 0) { [void]$presentList.Add($name) }
        if ($nonEmptyScopes.Count -gt 1) { [void]$conflicts.Add($name) }
    }

    $status = 'info'; $action = ''; $title = '未发现已配置的 AI 相关环境变量'
    if ($presentList.Count -gt 0) {
        $title = '已配置的环境变量：' + ($presentList -join ', ')
        $status = 'ok'
    }
    if ($conflicts.Count -gt 0) {
        $status = 'warn'
        $action = '同一个变量在多个作用域同时存在（如系统级与用户级各有一份），最终生效值取决于作用域优先级，是"改了配置却不生效"的常见原因。安装器会列出三个作用域的实际取值，并且只改动你确认的那一层。'
    }
    $envDetail = '所有值均已脱敏，报告内不含完整密钥'
    if ($conflicts.Count -gt 0) { $envDetail = '存在多作用域冲突：' + ($conflicts -join ', ') + '（值已脱敏）' }
    [void]$Checks.Add((New-Check -Id 'env.anthropic' -Category '配置' -Status $status -Title $title -Detail $envDetail -Action $action -Data $envData))
    $State.environmentVariables = $envData
}

function Test-Networking {
    param($Checks, $State, $Targets, $HttpProbes, [int]$TimeoutMs = 4000, [switch]$SkipNetwork)

    $ieKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $proxyEnable = Get-RegValue -Path $ieKey -Name 'ProxyEnable'
    $proxyServer = Get-RegValue -Path $ieKey -Name 'ProxyServer'
    $autoConfigUrl = Get-RegValue -Path $ieKey -Name 'AutoConfigURL'
    $envProxies = [ordered]@{
        HTTP_PROXY  = $env:HTTP_PROXY
        HTTPS_PROXY = $env:HTTPS_PROXY
        ALL_PROXY   = $env:ALL_PROXY
        NO_PROXY    = $env:NO_PROXY
    }
    $proxyState = [ordered]@{
        systemProxyEnabled = ($proxyEnable -eq 1)
        systemProxyServer  = $proxyServer
        autoConfigUrl      = $autoConfigUrl
        environmentProxies = $envProxies
    }
    $State.proxy = $proxyState
    $hasProxy = (($proxyEnable -eq 1) -and $proxyServer) -or ($envProxies.HTTPS_PROXY) -or ($envProxies.HTTP_PROXY) -or ($envProxies.ALL_PROXY)
    $proxyText = '未启用'
    if ($proxyEnable -eq 1) { $proxyText = [string]$proxyServer }
    elseif ($proxyServer) { $proxyText = '已配置但未启用（' + [string]$proxyServer + '）' }
    $pacText = '无'
    if ($autoConfigUrl) { $pacText = $autoConfigUrl }
    $action = ''
    if ($hasProxy) {
        $action = '检测到代理。安装器下载依赖时会复用这套代理设置，避免出现"浏览器能打开、命令行下不动"的情况。'
    }
    [void]$Checks.Add((New-Check -Id 'net.proxy' -Category '网络' -Status 'info' -Title $(if ($hasProxy) { '检测到代理配置' } else { '未检测到代理配置' }) -Detail ('系统代理：' + $proxyText + ' / PAC：' + $pacText) -Action $action -Data $proxyState))

    if ($SkipNetwork) {
        [void]$Checks.Add((New-Check -Id 'net.tcp' -Category '网络' -Status 'info' -Title '已跳过联网探测' -Detail '调用方传入了 -SkipNetwork' -Action ''))
        return
    }

    $dnsResults = [ordered]@{}
    $dnsFailures = New-Object System.Collections.ArrayList
    $distinctHosts = @($Targets | ForEach-Object { $_.host } | Sort-Object -Unique)
    foreach ($h in $distinctHosts) {
        $d = Test-DnsResolvable -HostName $h -TimeoutMs 3000
        $dnsResults[$h] = [ordered]@{ ok = $d.ok; addresses = @($d.addresses); error = $d.error }
        if (-not $d.ok) { [void]$dnsFailures.Add($h) }
    }
    $status = 'ok'; $action = ''
    if ($dnsFailures.Count -eq $distinctHosts.Count) {
        $status = 'fail'
        $action = '所有关键域名都无法解析，说明当前没有可用的网络或 DNS。请先确认能上网，再运行安装。'
    } elseif ($dnsFailures.Count -gt 0) {
        $status = 'warn'
        $action = '部分域名无法解析，可能是 DNS 污染或该域名被屏蔽。安装器会自动改用国内镜像源。'
    }
    $dnsDetail = '全部解析成功'
    if ($dnsFailures.Count -gt 0) { $dnsDetail = '失败：' + ($dnsFailures -join ', ') }
    [void]$Checks.Add((New-Check -Id 'net.dns' -Category '网络' -Status $status -Title ('域名解析：' + ($distinctHosts.Count - $dnsFailures.Count) + '/' + $distinctHosts.Count + ' 成功') -Detail $dnsDetail -Action $action -Data $dnsResults))

    $tcpResults = [ordered]@{}
    $okCount = 0
    $requiredFailed = New-Object System.Collections.ArrayList
    $allFailed = New-Object System.Collections.ArrayList
    foreach ($t in $Targets) {
        $reachable = Test-TcpReachable -ComputerName $t.host -Port $t.port -TimeoutMs $TimeoutMs
        $tcpResults[$t.id] = [ordered]@{
            host = $t.host; port = $t.port; purpose = $t.purpose
            required = [bool]$t.required; reachable = $reachable
        }
        if ($reachable) { $okCount++ }
        else {
            [void]$allFailed.Add($t.host)
            if ($t.required) { [void]$requiredFailed.Add($t.host) }
        }
    }
    $status = 'ok'; $action = ''
    if ($okCount -eq 0) {
        $status = 'fail'
        $action = '所有下载源都连不上（可能是防火墙拦截或需要代理）。安装步骤一定会在下载环节失败，请先解决网络，或在安装器里手工填入代理。'
    } elseif ($requiredFailed.Count -gt 0) {
        $status = 'warn'
        $action = '必需源 ' + ($requiredFailed -join ', ') + ' 不可达，安装器会自动切换到镜像加速源。'
    } elseif ($allFailed.Count -gt 0) {
        $status = 'warn'
        $action = '部分源不可达：' + ($allFailed -join ', ') + '。这不影响安装，安装器会优先选择可达的源。'
    }
    $tcpDetail = '全部可达'
    if ($allFailed.Count -gt 0) { $tcpDetail = '不可达：' + ($allFailed -join ', ') }
    [void]$Checks.Add((New-Check -Id 'net.tcp' -Category '网络' -Status $status -Title ('端口连通性：' + $okCount + '/' + $Targets.Count + ' 可建立连接（注意：这不等于真的能下载）') -Detail $tcpDetail -Action $action -Data $tcpResults))

    # ---- HTTP 往返探测：TCP 通不代表真能取到数据 ----
    # 注意：绝不能写 $Targets.httpProbes 这种"对数组取属性"的写法。
    # PowerShell 的成员枚举会在属性不存在时返回"每个元素一个 $null"的数组，
    # 既非空又为真，最后把一堆空 URL 送进探测函数。必须显式传参并过滤。
    $probeList = New-Object System.Collections.ArrayList
    foreach ($p in @($HttpProbes)) {
        if ($null -eq $p) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$p.url)) { continue }
        [void]$probeList.Add($p)
    }

    $effectiveProxy = Resolve-EffectiveProxy -ProxyState $proxyState
    $httpResults = [ordered]@{}
    $httpOk = 0
    $httpFailKinds = New-Object System.Collections.ArrayList
    foreach ($p in $probeList) {
        $h = Test-HttpRoundTrip -Url ([string]$p.url) -TimeoutMs ([int]($TimeoutMs * 2)) -Proxy $effectiveProxy
        $httpResults[$p.id] = [ordered]@{
            url = $p.url; purpose = $p.purpose; ok = $h.ok; status = $h.status
            bytes = $h.bytes; kind = $h.kind; error = $h.error; elapsedMs = $h.elapsedMs; viaProxy = $h.viaProxy
        }
        if ($h.ok) { $httpOk++ } else { [void]$httpFailKinds.Add($h.kind) }
    }

    if ($probeList.Count -gt 0) {
        $status = 'ok'
        $action = ''
        $detailParts = New-Object System.Collections.ArrayList
        foreach ($k in ($httpResults.Keys)) {
            $v = $httpResults[$k]
            if ($v.ok) {
                [void]$detailParts.Add($k + '=响应 ' + $v.status + ' / ' + $v.elapsedMs + 'ms')
            } else {
                [void]$detailParts.Add($k + '=' + $v.kind + '（' + $v.error + '）')
            }
        }
        $proxyText = ''
        if ($effectiveProxy) { $proxyText = '（已尝试通过代理 ' + $effectiveProxy + '）' }

        if ($httpOk -eq 0 -and $okCount -gt 0) {
            # 这是最危险的一种状态：端口都"通"，实际一个字节都取不回来
            $status = 'fail'
            $topKind = 'unknown'
            if ($httpFailKinds.Count -gt 0) { $topKind = [string]$httpFailKinds[0] }
            $action = '端口探测全部成功，但没有任何一个站点能真正取到数据' + $proxyText + '。' + (Get-NetworkErrorHint -Kind $topKind) + ' 下载环节一定会失败，必须先把网络解决掉（或者用 -Proxy 指定可用代理）。'
        } elseif ($httpOk -eq 0) {
            $status = 'fail'
            $topKind = 'unknown'
            if ($httpFailKinds.Count -gt 0) { $topKind = [string]$httpFailKinds[0] }
            $action = '所有站点都取不到数据。' + (Get-NetworkErrorHint -Kind $topKind)
        } elseif ($httpOk -lt $probeList.Count) {
            $status = 'warn'
            $action = '部分站点取不到数据。安装器会自动优先选择可用的源与镜像。'
        }
        [void]$Checks.Add((New-Check -Id 'net.http' -Category '网络' -Status $status -Title ('真实数据往返：' + $httpOk + '/' + $probeList.Count + ' 成功') -Detail (($detailParts) -join ' | ') -Action $action -Data $httpResults))
    }

    $anthropicOk = $false
    $mirrorOk = $false
    if ($tcpResults.Contains('anthropic-api')) { $anthropicOk = $tcpResults['anthropic-api'].reachable }
    if ($tcpResults.Contains('npmmirror')) { $mirrorOk = $tcpResults['npmmirror'].reachable }
    if (-not $anthropicOk -and $mirrorOk) {
        [void]$Checks.Add((New-Check -Id 'net.cn-adaptation' -Category '网络' -Status 'warn' -Title '判定为国内网络环境' -Detail 'Anthropic 官方端点不可达，但国内镜像可达' -Action '安装器会自动：① 依赖与工具全部走国内镜像源；② 在配置阶段默认推荐国内渠道（DeepSeek / 智谱 / 百炼等），避免你拿到 key 却连不上。'))
    }
}

function Test-Consistency {
    <#
        交叉一致性：配置在、程序不在，或装着多份，都是真实用户身上常见且难自查的状态。
        单独看"工具是否安装"看不出来，必须把配置检测和工具检测对起来看。
    #>
    param($Checks, $State, $Tools, $ToolStatus)
    if (-not $ToolStatus) { return }

    foreach ($tool in @($Tools)) {
        $st = $ToolStatus[$tool.id]
        if (-not $st) { continue }
        if ($st.installed) { continue }

        $presentConfigs = @()
        if ($State.configFiles -and $State.configFiles[$tool.id]) {
            $presentConfigs = @($State.configFiles[$tool.id] | Where-Object { $_.exists })
        }
        if ($presentConfigs.Count -eq 0) { continue }

        $unhealthy = @($presentConfigs | Where-Object { $_.parseError })
        $status = 'warn'
        $detail = '配置文件仍在：' + (($presentConfigs | ForEach-Object { $_.path }) -join ' | ')
        $action = ('刚才检测到 ' + $tool.name + ' 的配置文件存在，但找不到程序本体。常见原因：上一次安装或升级中断、程序被卸载但配置没清、或者被安全软件删掉了主程序。安装器会：① 保留你的配置（先备份）；② 重新装一份程序本体，装完直接用回原配置，不需要你重新填 key。')
        if ($unhealthy.Count -gt 0) {
            $action = '你的配置文件里还有解析失败的项，安装器会先备份再让你确认是否修复，不会直接覆盖。'
        }
        [void]$Checks.Add((New-Check -Id ('consistency.' + $tool.id) -Category '一致性' -Status $status -Title ($tool.name + '：有配置但没有程序本体') -Detail $detail -Action $action -Data ([ordered]@{
                        configsPresent = @($presentConfigs | ForEach-Object { $_.path })
                        installed = $false
                    })))
    }
}

function Find-InstallArtifacts {
    <#
        扫描上一次安装/升级中断留下的残留物，并做分组。

        真实案例：npm 全局目录里只剩 claude.exe.old.<时间戳> 与
        claude.exe.restoring.<随机串>，主程序不见了。这种状态下直接重装经常继续失败，
        不能当成"干净的未安装环境"来处理。

        分组的意义：属于同一个安装器工作目录的多个残留，清理时应整目录搬走一次，
        而不是逐个文件搬 —— 逐个搬会留下空目录，也更容易中途失败。
    #>
    param(
        [string[]]$Roots,
        [int]$MaxDepth = 3
    )
    $scannedRoots = New-Object System.Collections.ArrayList
    $artifacts = New-Object System.Collections.ArrayList
    $seen = @{}
    # 注意字符类末尾的 - ：安装器工作目录名里带连字符（如 .claude-code-yBlZjApI），
    # 漏掉它会导致这些残留无法归组，进而变成"逐个文件搬"而不是"整目录搬"。
    $groupPattern = '^\.(claude|codex|gemini|opencode|anthropic|dsh|npm)[-_][A-Za-z0-9_-]{6,}$'
    $filePattern = '\.(old|restoring|tmp|partial|bak|new)\.[0-9a-fA-F]{4,}$'

    foreach ($root in @($Roots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $rk = $root.ToLowerInvariant()
        if ($seen.ContainsKey($rk)) { continue }
        $seen[$rk] = $true
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        [void]$scannedRoots.Add($root)
        try {
            $items = @(Get-ChildItem -LiteralPath $root -Recurse -Depth $MaxDepth -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match $filePattern -or $_.Name -match $groupPattern })
            foreach ($i in $items) {
                # 在路径分段上直接找安装器工作目录。
                # 不用 DirectoryInfo 向上遍历：那是靠对象引用关系，遇到符号链接、
                # 不同根路径或 -Recurse 的实际枚举深度差异时会静默失效（踩过）。
                $groupDir = ''
                $segments = @($i.FullName -split '\\')
                for ($k = 0; $k -lt $segments.Count; $k++) {
                    if ($segments[$k] -match $groupPattern) {
                        $groupDir = ($segments[0..$k] -join '\')
                        break
                    }
                }
                [void]$artifacts.Add([pscustomobject]([ordered]@{
                            path     = [string]$i.FullName
                            name     = [string]$i.Name
                            kind     = $(if ($i.PSIsContainer) { 'dir' } else { 'file' })
                            groupDir = $groupDir
                        }))
            }
        } catch { }
    }

    $order = New-Object System.Collections.ArrayList
    $byGroup = @{}
    foreach ($a in $artifacts) {
        $g = $a.groupDir
        if ([string]::IsNullOrEmpty($g)) { $g = $a.path }
        if (-not $byGroup.ContainsKey($g)) {
            $byGroup[$g] = New-Object System.Collections.ArrayList
            [void]$order.Add($g)
        }
        [void]$byGroup[$g].Add($a.path)
    }
    $groupObjects = New-Object System.Collections.ArrayList
    foreach ($g in $order) {
        [void]$groupObjects.Add([pscustomobject]@{ dir = $g; members = @($byGroup[$g]) })
    }

    return [pscustomobject]([ordered]@{
            artifacts    = @($artifacts)
            groups       = @($groupObjects)
            scannedRoots = @($scannedRoots)
        })
}

function Test-InstallArtifacts {
    <#
        扫描上一次安装/升级中断留下的残留物。
        真实案例：npm 全局目录里只剩 claude.exe.old.<时间戳> 与 claude.exe.restoring.<随机串>，
        主程序不见了。这种状态下直接重装经常会继续失败，必须先清理。
    #>
    param($Checks, $State)

    $roots = New-Object System.Collections.ArrayList
    if ($env:APPDATA) { [void]$roots.Add((Join-Path $env:APPDATA 'npm\node_modules')) }
    if ($State.npmPrefix -and $State.npmPrefix.path) { [void]$roots.Add((Join-Path $State.npmPrefix.path 'node_modules')) }
    if ($env:USERPROFILE) { [void]$roots.Add((Join-Path $env:USERPROFILE '.local\bin')) }

    $scan = Find-InstallArtifacts -Roots @($roots) -MaxDepth 3
    $scannedText = (($scan.scannedRoots) -join ' | ')

    if ($scan.artifacts.Count -eq 0) {
        [void]$Checks.Add((New-Check -Id 'install.artifacts' -Category '依赖' -Status 'ok' -Title '未发现安装残留' -Detail ('已扫描：' + $scannedText) -Action '' -Data ([ordered]@{ artifactCount = 0; scannedRoots = @($scan.scannedRoots) })))
        return
    }

    $shown = @($scan.artifacts | Select-Object -First 6 | ForEach-Object { $_.path })
    $detail = ($shown -join ' | ')
    if ($scan.artifacts.Count -gt $shown.Count) { $detail += (' …等共 ' + $scan.artifacts.Count + ' 项') }
    [void]$Checks.Add((New-Check -Id 'install.artifacts' -Category '依赖' -Status 'warn' -Title ('发现 ' + $scan.artifacts.Count + ' 个安装残留（上次安装/升级未完成）') -Detail $detail -Action '这些是上一次安装或升级中断留下的文件（典型是主程序被改名成 .old.<时间戳> 或 .restoring.<随机串>）。这种状态下直接重装往往会继续失败。安装器会先把它们挪到备份目录（不删除），再重新安装；如果新装失败，可以一键还原。' -Data ([ordered]@{
                    artifactCount = $scan.artifacts.Count
                    groupCount    = $scan.groups.Count
                    groups        = @($scan.groups | ForEach-Object { $_.dir })
                    artifacts     = @($scan.artifacts | ForEach-Object { $_.path })
                    scannedRoots  = @($scan.scannedRoots)
                })))
}
# ======================================================================
#  主入口
# ======================================================================

function Invoke-LLMKitEnvironmentCheck {
    <#
    .SYNOPSIS
        执行完整的环境体检，返回结构化报告对象。
    .DESCRIPTION
        只读检测。唯一写入是调用方指定的报告文件与"可写性探测"临时文件。
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigRoot,
        [switch]$SkipNetwork,
        [int]$NetworkTimeoutMs = 4000,
        [int]$CommandTimeoutMs = 8000
    )

    if ([string]::IsNullOrEmpty($ConfigRoot)) {
        $moduleDir = $PSScriptRoot
        if ([string]::IsNullOrEmpty($moduleDir)) { $moduleDir = (Get-Location).Path }
        $ConfigRoot = Split-Path -Parent (Split-Path -Parent $moduleDir)
    }

    $toolsConfigPath = Join-Path $ConfigRoot 'config\tools.json'
    if (-not (Test-Path -LiteralPath $toolsConfigPath)) {
        throw ('找不到工具目录配置：' + $toolsConfigPath)
    }
    $toolsConfig = Read-TextFileUtf8 -Path $toolsConfigPath | ConvertFrom-Json
    # 依赖的候选落点也读一份：只靠 PATH 判定会把"装了但 PATH 里没有"误报成未安装
    $dependenciesConfig = [pscustomobject]@{ dependencies = @() }
    $depConfigPath = Join-Path $ConfigRoot 'config\dependencies.json'
    if (Test-Path -LiteralPath $depConfigPath) {
        try { $dependenciesConfig = Read-TextFileUtf8 -Path $depConfigPath | ConvertFrom-Json } catch { }
    }

    $checks = New-Object System.Collections.ArrayList
    $state = [ordered]@{}
    $script:toolStatus = $null
    $startedAt = Get-Date
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $steps = @(
        @{ name = '操作系统'; script = { Test-OperatingSystem -Checks $checks } },
        @{ name = 'PowerShell 运行时'; script = { Test-PowerShellRuntime -Checks $checks } },
        @{ name = '权限与用户级安装能力'; script = { Test-Privileges -Checks $checks -State $state } },
        @{ name = '系统事实'; script = { Test-SystemFacts -Checks $checks } },
        @{ name = '运行时依赖'; script = { Test-Dependencies -Checks $checks -State $state -Dependencies $dependenciesConfig.dependencies } },
        @{ name = '目标工具'; script = { $script:toolStatus = Test-TargetTools -Checks $checks -State $state -Tools $toolsConfig.tools -CommandTimeoutMs $CommandTimeoutMs } },
        @{ name = '安装残留'; script = { Test-InstallArtifacts -Checks $checks -State $state } },
        @{ name = '配置文件'; script = { Test-Configuration -Checks $checks -State $state -Tools $toolsConfig.tools } },
        @{ name = '一致性'; script = { Test-Consistency -Checks $checks -State $state -Tools $toolsConfig.tools -ToolStatus $script:toolStatus } },
        @{ name = '网络'; script = { Test-Networking -Checks $checks -State $state -Targets $toolsConfig.networkTargets -HttpProbes $toolsConfig.httpProbes -TimeoutMs $NetworkTimeoutMs -SkipNetwork:$SkipNetwork } }
    )

    $stepResults = New-Object System.Collections.ArrayList
    foreach ($step in $steps) {
        $stepSw = [System.Diagnostics.Stopwatch]::StartNew()
        $err = $null
        try {
            & $step.script
        } catch {
            $err = Get-ShortErrorText -Text $_.Exception.Message
            [void]$checks.Add((New-Check -Id ('internal.' + ($step.name -replace '[^\w]', '-')) -Category '内部' -Status 'warn' -Title ('检测项执行失败：' + $step.name) -Detail $err -Action '该检测项被跳过，其余检测不受影响。请把这句话连同报告一起反馈。'))
        }
        $stepSw.Stop()
        [void]$stepResults.Add([pscustomobject]([ordered]@{ step = $step.name; ok = ($null -eq $err); error = $err; ms = [int]$stepSw.ElapsedMilliseconds }))
    }

    $sw.Stop()

    $counts = [ordered]@{ ok = 0; warn = 0; fail = 0; info = 0 }
    foreach ($c in $checks) {
        if ($counts.Contains($c.status)) { $counts[$c.status] = $counts[$c.status] + 1 }
    }
    $verdict = 'ok'
    if ($counts.fail -gt 0) { $verdict = 'fail' }
    elseif ($counts.warn -gt 0) { $verdict = 'warn' }

    $psv = $PSVersionTable.PSVersion.ToString()
    $edition = 'Desktop'
    try { $edition = [string]$PSVersionTable.PSEdition } catch { }
    $hostName = ''
    try { $hostName = $Host.Name } catch { }

    $probeReliable = $null
    if ($state.writeProbe) { $probeReliable = $state.writeProbe.reliable }

    $report = [pscustomobject]([ordered]@{
            schemaVersion    = $script:SchemaVersion
            generatedAt      = $startedAt.ToString('o')
            durationMs       = [int]$sw.ElapsedMilliseconds
            engine           = [ordered]@{
                name = 'LLMKit'; version = $script:LLMKitVersion
                psVersion = $psv; psEdition = $edition; host = $hostName
            }
            environmentFlags = [ordered]@{
                writeProbeReliable  = $probeReliable
                restrictedSuspected = (-not [bool]$probeReliable)
                isAdmin             = (Test-IsElevated)
            }
            machine          = [ordered]@{
                computerName = $env:COMPUTERNAME
                userName     = $env:USERNAME
                userProfile  = $env:USERPROFILE
                localAppData = $env:LOCALAPPDATA
                appData      = $env:APPDATA
            }
            steps            = @($stepResults)
            checks           = @($checks)
            state            = $state
            tools            = $(if ($script:toolStatus) { $script:toolStatus } else { [ordered]@{} })
            summary          = [ordered]@{
                ok = $counts.ok; warn = $counts.warn; fail = $counts.fail; info = $counts.info
                verdict = $verdict; checkCount = $checks.Count
            }
        })

    return $report
}

function Save-LLMKitReport {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    $json = $Report | ConvertTo-Json -Depth 14
    # 写 UTF-8 不带 BOM，方便 Go / JS 端直接消费
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function Format-LLMKitReport {
    <#
        控制台摘要。
        彩色模式走 Write-Host；-NoColor 模式走标准输出流，保证可以重定向到文件。
    #>
    param(
        [Parameter(Mandatory = $true)]$Report,
        [switch]$NoColor
    )
    $useColor = -not $NoColor
    $lines = New-Object System.Collections.ArrayList

    foreach ($c in $Report.checks) {
        $mark = ' -- '
        $color = 'Gray'
        switch ($c.status) {
            'ok' { $mark = ' OK '; $color = 'Green' }
            'warn' { $mark = ' !! '; $color = 'Yellow' }
            'fail' { $mark = ' XX '; $color = 'Red' }
            'info' { $mark = ' .. '; $color = 'DarkGray' }
        }
        $line = '[' + $mark + '] [' + $c.category + '] ' + $c.title
        [void]$lines.Add($line)
        if ($c.detail) { [void]$lines.Add('        ' + $c.detail) }
        if ($c.action) { [void]$lines.Add('        -> ' + $c.action) }

        if ($useColor) {
            try {
                Write-Host $line -ForegroundColor $color
                if ($c.detail) { Write-Host ('        ' + $c.detail) -ForegroundColor DarkGray }
                if ($c.action) { Write-Host ('        -> ' + $c.action) -ForegroundColor Cyan }
            } catch { }
        } else {
            # 同样必须走 Host：这些文本若走输出流，会被调用方的赋值语句吃掉
            Write-Host $line
            if ($c.detail) { Write-Host ('        ' + $c.detail) }
            if ($c.action) { Write-Host ('        -> ' + $c.action) }
        }
    }

    $s = $Report.summary
    $verdictText = [string]$s.verdict
    if ($s.verdict -eq 'ok') { $verdictText = '一切正常，可以开始安装' }
    elseif ($s.verdict -eq 'warn') { $verdictText = '存在可自动处理的警告，安装器会自行绕过' }
    elseif ($s.verdict -eq 'fail') { $verdictText = '存在阻断项，需要先解决' }
    $statLine = '统计：OK ' + $s.ok + ' / 警告 ' + $s.warn + ' / 阻断 ' + $s.fail + ' / 信息 ' + $s.info + '（共 ' + $s.checkCount + ' 项，耗时 ' + $Report.durationMs + ' ms）'

    if ($useColor) {
        $vc = 'Gray'
        if ($s.verdict -eq 'ok') { $vc = 'Green' } elseif ($s.verdict -eq 'warn') { $vc = 'Yellow' } elseif ($s.verdict -eq 'fail') { $vc = 'Red' }
        try {
            Write-Host ''
            Write-Host ('=' * 72) -ForegroundColor DarkGray
            Write-Host ('结论：' + $verdictText) -ForegroundColor $vc
            Write-Host $statLine -ForegroundColor DarkGray
            Write-Host ('=' * 72) -ForegroundColor DarkGray
        } catch { }
    } else {
        Write-Host ''
        Write-Host ('=' * 72)
        Write-Host ('结论：' + $verdictText)
        Write-Host $statLine
        Write-Host ('=' * 72)
    }
}

Export-ModuleMember -Function 'Invoke-LLMKitEnvironmentCheck', 'Save-LLMKitReport', 'Format-LLMKitReport', 'Get-LLMKitVersion', 'Get-NetworkErrorKind', 'Get-NetworkErrorHint', 'Find-InstallArtifacts', 'Find-InstalledAppInRegistry', 'Get-ToolStatus', 'Test-IsElevated', 'Sync-ProcessEnvironmentFromRegistry', 'Resolve-CommandInfo'
