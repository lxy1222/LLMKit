#Requires -Version 5.1
<#
    LLMKit 安装引擎（M1：运行时依赖）
    ------------------------------------------------------------------
    设计原则：
      1. 计划与执行分离 —— 先产出"将要做什么"的完整计划，用户确认后才执行。
         执行入口默认就是 DryRun，必须显式 -Apply 才真正动手。
      2. 免管理员优先（决策 D4）—— tiers 按免管理员排序，needsAdmin 的层
         在未提权时自动跳过，绝不因为没权限而整段失败。
      3. 只增不删 —— 覆盖已有安装前，先把旧目录整体挪到备份区（不删除）。
         任何一步都写进 journal，可回溯、可还原。
      4. 一切下载必须可校验 —— 有官方校验和就比对；没有则在 journal 里记录
         实际 SHA256 与来源 URL，保证事后可审计。
      5. 先试后落 —— 解压到 staging 目录并验证可执行文件能跑起来，才搬到最终位置。
         避免"装到一半坏掉"，这正是 M0 在真机上扫到的那种残留的成因。
#>

Set-StrictMode -Off

$script:InstallVersion = '0.1.0'
$script:MaxErrorTextLength = 300

# PowerShell 5.1 默认可能不带 TLS 1.2，不显式设置会在下载时直接失败
try {
    $cur = [Net.ServicePointManager]::SecurityProtocol
    if (-not ($cur -band [Net.SecurityProtocolType]::Tls12)) {
        [Net.ServicePointManager]::SecurityProtocol = $cur -bor [Net.SecurityProtocolType]::Tls12
    }
} catch { }

# ======================================================================
#  基础工具
# ======================================================================

function Get-LLMKitInstallVersion { $script:InstallVersion }

function Get-ShortErrorText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text -replace '\s+', ' '
    if ($t.Length -le $script:MaxErrorTextLength) { return $t }
    return $t.Substring(0, $script:MaxErrorTextLength) + ' ...(已截断)'
}

function Get-ObjectProp {
    <#
        安全取属性。
        直接点号访问在 PSObject 上遇到不存在的属性会静默返回 $null，
        但遇到 $null 对象则会报错；统一走这里，行为可预期。
        放在共享原语层，是因为检测/安装/配置三个模块都要用，各写一份迟早走偏。
    #>
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Read-TextFileUtf8 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Get-InstallErrorHint {
    <#
        复用检测模块的网络错误分类器，把底层英文异常翻成中文动作建议。
        刻意不在这里重新实现一遍分类逻辑：两处各写一份迟早会走偏。
        检测模块没加载时返回空串，调用方按"没有额外提示"处理，功能不受影响。
    #>
    param([string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return '' }
    # 先问统一错误翻译表。它比下面的网络分类细得多：能区分 npm 的
    # EACCES / EBADENGINE / ERESOLVE，也能认"不是内部或外部命令""拒绝访问"
    # "文件正被占用"这类 Windows 上真正高频的坑。
    try {
        $tbl = Get-Command -Name 'Get-ErrorHintText' -ErrorAction SilentlyContinue
        if ($tbl) {
            $hint = [string](& $tbl -Text $Message -Context 'install')
            if ($hint) { return $hint }
        }
    } catch { }
    try {
        $hintFn = Get-Command -Name 'Get-NetworkErrorHint' -ErrorAction SilentlyContinue
        if (-not $hintFn) { return '' }
        $kind = 'unknown'
        $kindFn = Get-Command -Name 'Get-NetworkErrorKind' -ErrorAction SilentlyContinue
        if ($kindFn) { $kind = [string](& $kindFn -Message $Message) }
        return [string](& $hintFn -Kind $kind)
    } catch {
        return ''
    }
}

function Write-JsonFile {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $json = $Object | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Expand-PathToken {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.Environment]::ExpandEnvironmentVariables($Path)
}

function Format-ByteSize {
    param([long]$Bytes)
    if ($Bytes -le 0) { return '0 B' }
    if ($Bytes -lt 1KB) { return ($Bytes.ToString() + ' B') }
    if ($Bytes -lt 1MB) { return ([math]::Round($Bytes / 1KB, 1).ToString() + ' KB') }
    if ($Bytes -lt 1GB) { return ([math]::Round($Bytes / 1MB, 1).ToString() + ' MB') }
    return ([math]::Round($Bytes / 1GB, 2).ToString() + ' GB')
}

function Test-IsElevated {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Resolve-ExecutablePath {
    param([Parameter(Mandatory = $true)][string]$Name)
    # 先让当前进程看到注册表里的最新 PATH 与用户环境变量：否则刚装好的依赖会被判成
    # 未安装，刚 setx 存的 key 也读不到（原因见 Sync-ProcessEnvironmentFromRegistry 的注释）
    try { $null = Sync-ProcessEnvironmentFromRegistry } catch { }
    try {
        $cmds = @(Get-Command -Name $Name -All -ErrorAction SilentlyContinue)
        foreach ($ext in @('.exe', '.cmd', '.bat', '.com')) {
            foreach ($c in $cmds) {
                $p = $c.Source
                if ([string]::IsNullOrEmpty($p)) { $p = $c.Path }
                if ($p -and ([System.IO.Path]::GetExtension($p).ToLowerInvariant() -eq $ext)) { return $p }
            }
        }
    } catch { }
    return $null
}

function Invoke-Process {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutMs = 600000
    )
    $r = [ordered]@{ ok = $false; exitCode = $null; stdout = ''; stderr = ''; error = ''; durationMs = 0 }
    if (-not (Test-Path -LiteralPath $FilePath)) { $r.error = 'path-not-found'; return [pscustomobject]$r }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $argLine = ''
        foreach ($a in $Arguments) {
            if ($null -eq $a) { continue }
            if ($a -match '\s') { $argLine += '"' + $a + '" ' } else { $argLine += $a + ' ' }
        }
        $psi.FileName = $FilePath
        $psi.Arguments = $argLine.Trim()
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        if (-not $proc.Start()) { $r.error = 'start-failed'; return [pscustomobject]$r }
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch { }
            $r.error = 'timeout'
        } else {
            $r.exitCode = $proc.ExitCode
            $r.ok = ($proc.ExitCode -eq 0)
        }
        try { $r.stdout = ([string]$outTask.Result).Trim() } catch { }
        try { $r.stderr = ([string]$errTask.Result).Trim() } catch { }
    } catch {
        $r.error = Get-ShortErrorText -Text $_.Exception.Message
    } finally {
        if ($proc) { try { $proc.Dispose() } catch { } }
    }
    $sw.Stop()
    $r.durationMs = [int]$sw.ElapsedMilliseconds
    return [pscustomobject]$r
}

# ======================================================================
#  PATH 字符串处理（纯函数，可单测）
# ======================================================================

function Get-NormalizedPathEntry {
    <# 归一化：展开环境变量、去掉尾部反斜杠、转小写。用于比较而非存储。 #>
    param([string]$Entry)
    if ([string]::IsNullOrWhiteSpace($Entry)) { return '' }
    $e = [System.Environment]::ExpandEnvironmentVariables($Entry.Trim())
    $e = $e.Trim().TrimEnd('\')
    return $e.ToLowerInvariant()
}

function Get-PathEntryList {
    param([string]$PathValue)
    if ([string]::IsNullOrEmpty($PathValue)) { return @() }
    # 保留条目原始写法：我们只是要增删一项，没有理由顺手重写用户 PATH 里其它项的格式
    return @($PathValue -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Merge-PathEntry {
    <#
        把一个目录并进 PATH 字符串。
        纯函数：不碰注册表、不碰进程环境，便于单元测试。
        返回 { value; changed; alreadyPresent; added; removed }
    #>
    param([string]$CurrentPath, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Entry)
    $out = [ordered]@{ value = [string]$CurrentPath; changed = $false; alreadyPresent = $false; added = @(); removed = @() }
    $target = Get-NormalizedPathEntry -Entry $Entry
    if ([string]::IsNullOrEmpty($target)) { return [pscustomobject]$out }

    $entries = @(Get-PathEntryList -PathValue $CurrentPath)
    $kept = New-Object System.Collections.ArrayList
    $found = $false
    foreach ($e in $entries) {
        if ((Get-NormalizedPathEntry -Entry $e) -eq $target) {
            if (-not $found) {
                $found = $true
                # 已存在就原样保留：不改位置也不改写法。
                # 这样"已经有的项"永远不会因为大小写或尾斜杠差异触发一次无意义的注册表重写。
                [void]$kept.Add($e)
            } else {
                $out.removed += $e               # 去掉重复项
            }
        } else {
            [void]$kept.Add($e)
        }
    }

    if ($found) {
        $out.alreadyPresent = $true
        $newValue = ($kept -join ';')
        if ($newValue -ne [string]$CurrentPath) { $out.changed = $true; $out.value = $newValue }
        return [pscustomobject]$out
    }

    # 不存在则追加到末尾（追加比插到最前更安全：不会覆盖系统里已有的同名命令）
    [void]$kept.Add($Entry.Trim())
    $out.value = ($kept -join ';')
    $out.changed = $true
    $out.added += $Entry.Trim()
    return [pscustomobject]$out
}

function Remove-PathEntry {
    param([string]$CurrentPath, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Entry)
    $out = [ordered]@{ value = [string]$CurrentPath; changed = $false; removed = @() }
    $target = Get-NormalizedPathEntry -Entry $Entry
    if ([string]::IsNullOrEmpty($target)) { return [pscustomobject]$out }
    $kept = New-Object System.Collections.ArrayList
    foreach ($e in @(Get-PathEntryList -PathValue $CurrentPath)) {
        if ((Get-NormalizedPathEntry -Entry $e) -eq $target) {
            $out.removed += $e
        } else {
            [void]$kept.Add($e)
        }
    }
    if ($out.removed.Count -gt 0) {
        $out.changed = $true
        $out.value = ($kept -join ';')
    }
    return [pscustomobject]$out
}

# ======================================================================
#  用户级 PATH 读写（注册表，保留 REG_EXPAND_SZ 类型）
# ======================================================================

function Get-UserPathInfo {
    <#
        直接读注册表而不是用 [Environment]::GetEnvironmentVariable，
        因为后者会展开 %VAR%，我们改写时会把展开后的绝对路径写回去，
        反而破坏用户原有的 %LOCALAPPDATA% 这类写法。
    #>
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
        if (-not $key) { return [pscustomobject]@{ available = $false; value = ''; kind = 'String'; error = 'HKCU\Environment 不存在或不可读' } }
        $raw = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = 'String'
        try { $kind = [string]$key.GetValueKind('Path') } catch { $kind = 'String' }
        return [pscustomobject]@{ available = $true; value = [string]$raw; kind = $kind; error = '' }
    } catch {
        return [pscustomobject]@{ available = $false; value = ''; kind = 'String'; error = (Get-ShortErrorText -Text $_.Exception.Message) }
    } finally {
        if ($key) { try { $key.Close() } catch { } }
    }
}

function Set-UserPathValue {
    <# 保留原始值类型：原本是 REG_EXPAND_SZ 就必须写回 REG_EXPAND_SZ #>
    param([Parameter(Mandatory = $true)][string]$Value, [string]$Kind = 'String')
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        if (-not $key) { throw '无法以写权限打开 HKCU\Environment' }
        $valueKind = [Microsoft.Win32.RegistryValueKind]::String
        if ($Kind -eq 'ExpandString') { $valueKind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $key.SetValue('Path', $Value, $valueKind)
    } finally {
        if ($key) { try { $key.Close() } catch { } }
    }
}

function Send-EnvironmentChangedBroadcast {
    <# 通知资源管理器环境变量变了，让新开的终端立刻生效（不需要重启或注销）#>
    try {
        if (-not ('LLMKit.NativeMethods' -as [type])) {
            Add-Type -Namespace LLMKit -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -ErrorAction Stop
        }
        $result = [UIntPtr]::Zero
        [void][LLMKit.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
        return $true
    } catch { return $false }
}

# ======================================================================
#  网络：取文本 / 下载文件（含镜像改写与校验和）
# ======================================================================

function New-WebRequest {
    param([string]$Url, [hashtable]$Headers, [string]$Proxy, [int]$TimeoutMs = 30000)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'LLMKit/0.1.0'
    $req.AllowAutoRedirect = $true
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = 60000
    $req.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    if ($Proxy) { $req.Proxy = New-Object System.Net.WebProxy($Proxy, $true) }
    if ($Headers) {
        foreach ($k in $Headers.Keys) {
            try { $req.Headers[$k] = [string]$Headers[$k] } catch { }
        }
    }
    return $req
}

function Get-MirrorCandidates {
    <# 生成候选 URL：原始 URL 优先，然后是各镜像改写规则 #>
    param([Parameter(Mandatory = $true)][string]$Url, $MirrorRewriters)
    $list = New-Object System.Collections.ArrayList
    [void]$list.Add($Url)
    foreach ($rw in @($MirrorRewriters)) {
        if (-not $rw) { continue }
        if ([string]::IsNullOrEmpty($rw.match) -or [string]::IsNullOrEmpty($rw.prefix)) { continue }
        try {
            if ($Url -notmatch $rw.match) { continue }
            # 两种改写语义，别搞混：
            #   prefix  —— ghproxy / gh-proxy 这类：把完整原 URL 拼在代理前缀后面
            #              https://github.com/a/b  ->  https://ghproxy.net/https://github.com/a/b
            #   replace —— 域名替换型代理：直接用正则把匹配到的前缀换掉
            # 用错的话兜底镜像会静默 404，用户只看到"下载失败"却查不出原因。
            $mode = 'prefix'
            if ($rw.mode) { $mode = [string]$rw.mode }
            $cand = $null
            if ($mode -eq 'replace') {
                $cand = ($Url -replace $rw.match, [string]$rw.prefix)
            } else {
                $cand = ([string]$rw.prefix).TrimEnd('/') + '/' + $Url
            }
            if ($cand -and $cand -ne $Url -and -not $list.Contains($cand)) { [void]$list.Add($cand) }
        } catch { }
    }
    return @($list)
}

function Invoke-TextFetch {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [hashtable]$Headers,
        [string]$Proxy,
        [int]$TimeoutSec = 60,
        [int]$MaxBytes = 8MB
    )
    $out = [ordered]@{ ok = $false; url = $Url; text = ''; bytes = 0; error = ''; httpStatus = $null; elapsedMs = 0 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    $stream = $null
    $reader = $null
    try {
        $req = New-WebRequest -Url $Url -Headers $Headers -Proxy $Proxy -TimeoutMs ($TimeoutSec * 1000)
        $resp = $req.GetResponse()
        $out.httpStatus = [int]$resp.StatusCode
        $stream = $resp.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $sb = New-Object System.Text.StringBuilder
        $buffer = New-Object char[] 65536
        while ($true) {
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { throw ('读取超时（超过 ' + $TimeoutSec + ' 秒）') }
            $read = $reader.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            [void]$sb.Append($buffer, 0, $read)
            if ($sb.Length -gt $MaxBytes) { throw ('响应过大（超过 ' + $MaxBytes + ' 字符），已中止') }
        }
        $out.text = $sb.ToString()
        $out.bytes = $out.text.Length
        $out.ok = $true
    } catch {
        $out.error = Get-ShortErrorText -Text $_.Exception.Message
    } finally {
        if ($reader) { try { $reader.Close() } catch { } }
        if ($stream) { try { $stream.Close() } catch { } }
        if ($resp) { try { $resp.Close() } catch { } }
    }
    $sw.Stop()
    $out.elapsedMs = [int]$sw.ElapsedMilliseconds
    return [pscustomobject]$out
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Proxy,
        [int]$TimeoutSec = 1800,
        [scriptblock]$OnProgress
    )
    $out = [ordered]@{
        ok = $false; url = $Url; path = $Destination; bytes = 0; sha256 = ''
        error = ''; httpStatus = $null; elapsedMs = 0
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null; $inStream = $null; $outStream = $null
    try {
        $req = New-WebRequest -Url $Url -Proxy $Proxy -TimeoutMs 30000
        $resp = $req.GetResponse()
        $out.httpStatus = [int]$resp.StatusCode
        $total = $resp.ContentLength

        $dir = Split-Path -Parent $Destination
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }

        $inStream = $resp.GetResponseStream()
        $outStream = [System.IO.File]::Create($Destination)
        $buffer = New-Object byte[] 131072
        $received = 0
        $lastReport = -1000
        while ($true) {
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { throw ('下载超时（超过 ' + $TimeoutSec + ' 秒）') }
            $read = $inStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $outStream.Write($buffer, 0, $read)
            $received += $read
            if ($OnProgress) {
                $now = [int]$sw.ElapsedMilliseconds
                if (($now - $lastReport) -ge 400) { $lastReport = $now; & $OnProgress $received $total }
            }
        }
        $outStream.Flush()
        $out.bytes = $received
        $out.ok = $true
        # Content-Length 明确给了总长却没收够，就是被代理/网络提前掐断的下载：必须算失败。
        # 否则半截包会被记成"下载完成"，错误一路拖到解压那一刻才暴露。
        if ($total -gt 0 -and $received -ne $total) {
            $out.ok = $false
            $out.error = '下载不完整：收到 ' + $received + ' / ' + $total + ' 字节'
        }
        if ($OnProgress) { & $OnProgress $received $total }
    } catch {
        $out.error = Get-ShortErrorText -Text $_.Exception.Message
    } finally {
        if ($outStream) { try { $outStream.Close() } catch { } }
        if ($inStream) { try { $inStream.Close() } catch { } }
        if ($resp) { try { $resp.Close() } catch { } }
    }
    $sw.Stop()
    $out.elapsedMs = [int]$sw.ElapsedMilliseconds
    if ($out.ok -and (Test-Path -LiteralPath $Destination)) {
        try { $out.sha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash } catch { }
    }
    return [pscustomobject]$out
}

function Invoke-DownloadWithMirrors {
    <# 依次尝试：原始 URL -> 各镜像。全部失败才返回失败，并保留每次尝试的错误。
       ExpectedBytes 来自 GitHub Release API 的资产大小：镜像把包截短了也照样回 200，
       只有拿官方尺寸当场比对才能识破。它大于 0 时，大小不符按失败处理、继续试下一源。 #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Urls,
        [Parameter(Mandatory = $true)][string]$Destination,
        [long]$ExpectedBytes = 0,
        [string]$Proxy,
        [int]$TimeoutSec = 1800,
        [scriptblock]$OnProgress
    )
    $attempts = New-Object System.Collections.ArrayList
    foreach ($u in $Urls) {
        if ([string]::IsNullOrEmpty($u)) { continue }
        $r = Invoke-FileDownload -Url $u -Destination $Destination -Proxy $Proxy -TimeoutSec $TimeoutSec -OnProgress $OnProgress
        $attemptOk = [bool]$r.ok
        $attemptError = [string]$r.error
        if ($attemptOk -and $ExpectedBytes -gt 0 -and [long]$r.bytes -ne [long]$ExpectedBytes) {
            $attemptOk = $false
            $attemptError = '下载大小不符：收到 ' + $r.bytes + ' 字节，官方资产为 ' + $ExpectedBytes + ' 字节'
        }
        [void]$attempts.Add([pscustomobject]@{ url = $u; ok = $attemptOk; bytes = $r.bytes; error = $attemptError; elapsedMs = $r.elapsedMs })
        if ($attemptOk) {
            $r | Add-Member -NotePropertyName attempts -NotePropertyValue @($attempts) -Force
            return $r
        }
        if (Test-Path -LiteralPath $Destination) { try { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue } catch { } }
    }
    return [pscustomobject]@{
        ok = $false; url = ''; path = $Destination; bytes = 0; sha256 = ''
        error = '所有下载源都失败'; httpStatus = $null; elapsedMs = 0; attempts = @($attempts)
    }
}

function Get-RemoteSha256FromShasums {
    <# 从 SHASUMS256.txt 里挑出目标文件那一行 #>
    param([string]$ShasumsText, [Parameter(Mandatory = $true)][string]$FileName)
    if ([string]::IsNullOrEmpty($ShasumsText)) { return $null }
    foreach ($line in ($ShasumsText -split "`n")) {
        $t = $line.Trim()
        if ([string]::IsNullOrEmpty($t)) { continue }
        $parts = $t -split '\s+'
        if ($parts.Count -ge 2) {
            $name = $parts[$parts.Count - 1].TrimStart('*')
            if ($name -eq $FileName) { return $parts[0].ToUpperInvariant() }
        }
    }
    return $null
}

# ======================================================================
#  版本解析
# ======================================================================

function Resolve-NodeVersionFromIndex {
    param($IndexJsonText, [string]$Filter = 'lts')
    try {
        $arr = $IndexJsonText | ConvertFrom-Json
    } catch {
        return $null
    }
    foreach ($e in $arr) {
        if ($Filter -eq 'lts') {
            if ($null -eq $e.lts) { continue }
            if ($e.lts -eq $false) { continue }
        }
        if ($e.version) { return [string]$e.version }
    }
    return $null
}

function Resolve-GitHubReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$AssetPattern,
        [string]$Proxy,
        [int]$TimeoutSec = 60
    )
    $out = [ordered]@{ ok = $false; tag = ''; assetName = ''; assetUrl = ''; assetSize = 0; error = '' }
    $api = 'https://api.github.com/repos/' + $Repo + '/releases/latest'
    $r = Invoke-TextFetch -Url $api -Proxy $Proxy -TimeoutSec $TimeoutSec -Headers @{
        'Accept' = 'application/vnd.github+json'
    }
    if (-not $r.ok) { $out.error = Get-ShortErrorText -Text ('GitHub API 请求失败：' + $r.error); return [pscustomobject]$out }
    try {
        $rel = $r.text | ConvertFrom-Json
    } catch {
        $out.error = 'GitHub API 返回内容无法解析'
        return [pscustomobject]$out
    }
    $out.tag = [string]$rel.tag_name
    foreach ($a in @($rel.assets)) {
        if (Test-AssetNameMatch -Name ([string]$a.name) -Pattern $AssetPattern) {
            $out.ok = $true
            $out.assetName = [string]$a.name
            $out.assetUrl = [string]$a.browser_download_url
            $out.assetSize = [long]$a.size
            return [pscustomobject]$out
        }
    }
    # 报错时把资产名一起带出来：配置里写错模式（这已经发生过一次）光看"没有匹配"根本改不对。
    $names = @($rel.assets | ForEach-Object { [string]$_.name } | Select-Object -First 6)
    $out.error = ('Release ' + $out.tag + ' 里没有匹配 ' + $AssetPattern + ' 的资产（共 ' + @($rel.assets).Count + ' 个' +
        $(if ($names.Count -gt 0) { '，例如：' + ($names -join '、') } else { '' }) + '）')
    return [pscustomobject]$out
}

function Test-AssetNameMatch {
    <#
        资产名匹配：优先按正则（配置里 assetPattern 一直是正则，git 那条用的就是 ^...$）。
        但配置是人写的，出现 glob 风格（例如 "*windows*x64*.zip"）时 -match 会直接抛
        "Quantifier {x,y} following nothing."，把整份安装计划一起炸掉 —— 一条配置笔误
        不该有这么大的杀伤力，所以正则不成立时退回通配符语义。
    #>
    param([string]$Name, [string]$Pattern)
    if ([string]::IsNullOrEmpty($Name) -or [string]::IsNullOrEmpty($Pattern)) { return $false }
    try {
        return [bool]($Name -match $Pattern)
    } catch {
        $rx = [regex]::Escape($Pattern).Replace('\*', '.*').Replace('\?', '.')
        try { return [bool]($Name -match ('^' + $rx + '$')) } catch { return $false }
    }
}

# ======================================================================
#  解压与目录处理
# ======================================================================

function Test-ZipArchiveReadable {
    <#
        只读地验证一个 zip 能不能被解析。
        截断/损坏的包在 OpenRead 时就会抛「End of Central Directory record could not be found」，
        让它在这里、在下载完那一刻就暴露，而不是等解压到一半、或者更糟：被当成缓存复用。
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $za = $null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $za = [System.IO.Compression.ZipFile]::OpenRead($Path)
        if ($za.Entries.Count -lt 1) { return $false }
        return $true
    } catch {
        return $false
    } finally {
        if ($za) { try { $za.Dispose() } catch { } }
    }
}

function Expand-ZipToDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $Destination -Force)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
        return
    } catch {
        # 兜底：走 Expand-Archive（慢一些，但对老系统更宽容）
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
    }
}

function Remove-SingleRootFolder {
    <#
        node 与 MinGit 的 zip 都带一层顶层目录。
        与其在配置里写死"剥掉几层"，不如运行时看：只有一层目录就把它摊平。
    #>
    param([Parameter(Mandatory = $true)][string]$Root)
    $entries = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)
    if ($entries.Count -ne 1) { return $false }
    if (-not $entries[0].PSIsContainer) { return $false }
    $inner = $entries[0].FullName
    foreach ($child in @(Get-ChildItem -LiteralPath $inner -Force -ErrorAction SilentlyContinue)) {
        Move-Item -LiteralPath $child.FullName -Destination $Root -Force
    }
    Remove-Item -LiteralPath $inner -Recurse -Force -ErrorAction SilentlyContinue
    return $true
}

# ======================================================================
#  会话与 journal（可回滚的依据）
# ======================================================================

function New-InstallSession {
    param(
        [string]$StateDir,
        [switch]$DryRun
    )
    if ([string]::IsNullOrEmpty($StateDir)) { $StateDir = Join-Path $env:LOCALAPPDATA 'LLMKit' }
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([System.Guid]::NewGuid().ToString('N').Substring(0, 6))
    $sessionsDir = Join-Path $StateDir 'sessions'
    $backupDir = Join-Path $StateDir (Join-Path 'backups' $id)
    return [pscustomobject]([ordered]@{
            id          = $id
            dryRun      = [bool]$DryRun
            startedAt   = (Get-Date).ToString('o')
            stateDir    = $StateDir
            sessionsDir = $sessionsDir
            backupDir   = $backupDir
            journalPath = (Join-Path $sessionsDir ($id + '.json'))
            host        = $env:COMPUTERNAME
            entries     = (New-Object System.Collections.ArrayList)
            summary     = [ordered]@{ planned = 0; succeeded = 0; failed = 0; skipped = 0 }
        })
}

function Add-JournalEntry {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Target = '',
        $Before = $null,
        $After = $null,
        [string]$Note = '',
        [string]$Status = 'done'
    )
    [void]$Session.entries.Add([pscustomobject]([ordered]@{
                at     = (Get-Date).ToString('o')
                action = $Action
                target = $Target
                before = $Before
                after  = $After
                note   = $Note
                status = $Status
                dryRun = $Session.dryRun
            }))
}

function Save-InstallJournal {
    param([Parameter(Mandatory = $true)]$Session)
    if ($Session.dryRun) { return $null }
    $doc = [pscustomobject]([ordered]@{
            schemaVersion = '0.1.0'
            engine        = 'LLMKit.Install/' + $script:InstallVersion
            sessionId     = $Session.id
            dryRun        = $Session.dryRun
            startedAt     = $Session.startedAt
            finishedAt    = (Get-Date).ToString('o')
            host          = $Session.host
            backupDir     = $Session.backupDir
            summary       = $Session.summary
            entries       = @($Session.entries)
        })
    Write-JsonFile -Object $doc -Path $Session.journalPath
    return $Session.journalPath
}

function Resolve-ItemDownload {
    <# 把 tier 里的模板解析成具体 URL 与版本。只读网络操作，DryRun 也会调用，让计划是具体的。 #>
    param($Item, $MirrorRewriters, [string]$Proxy, [int]$TimeoutSec = 60)

    $out = [ordered]@{
        ok = $false; kind = $Item.tier.type; version = ''; fileName = ''
        urls = @(); checksumUrl = ''; sizeBytes = $null; error = ''
    }

    if ($Item.tier.type -eq 'portable-zip') {
        $version = $null
        $lastErr = ''
        foreach ($idx in @($Item.tier.versionIndexUrls)) {
            foreach ($u in (Get-MirrorCandidates -Url $idx -MirrorRewriters $MirrorRewriters)) {
                $r = Invoke-TextFetch -Url $u -Proxy $Proxy -TimeoutSec $TimeoutSec
                if (-not $r.ok) { $lastErr = $r.error; continue }
                $v = Resolve-NodeVersionFromIndex -IndexJsonText $r.text -Filter ([string]$Item.tier.versionFilter)
                if ($v) { $version = $v; break }
                $lastErr = '版本索引里没有找到符合条件的版本'
            }
            if ($version) { break }
        }
        if (-not $version) {
            $out.error = Get-ShortErrorText -Text ('无法解析最新版本：' + $lastErr)
            return [pscustomobject]$out
        }
        $out.version = $version
        $primary = ([string]$Item.tier.assetUrlTemplate).Replace('{version}', $version)
        $out.fileName = Split-Path -Leaf $primary
        $urls = New-Object System.Collections.ArrayList
        [void]$urls.Add($primary)
        foreach ($tpl in @($Item.tier.assetUrlFallbacks)) {
            [void]$urls.Add(([string]$tpl).Replace('{version}', $version))
        }
        $out.urls = @($urls)
        foreach ($tpl in @($Item.tier.checksumUrlTemplates)) {
            $cu = ([string]$tpl).Replace('{version}', $version)
            if ($cu) { $out.checksumUrl = $cu; break }
        }
        $out.ok = $true
        return [pscustomobject]$out
    }

    if ($Item.tier.type -eq 'github-release') {
        $rel = Resolve-GitHubReleaseAsset -Repo ([string]$Item.tier.repo) -AssetPattern ([string]$Item.tier.assetPattern) -Proxy $Proxy -TimeoutSec $TimeoutSec
        if (-not $rel.ok) { $out.error = Get-ShortErrorText -Text $rel.error; return [pscustomobject]$out }
        $out.version = $rel.tag
        $out.fileName = $rel.assetName
        $out.sizeBytes = $rel.assetSize
        $out.urls = @(Get-MirrorCandidates -Url $rel.assetUrl -MirrorRewriters $MirrorRewriters)
        $out.ok = $true
        return [pscustomobject]$out
    }

    if ($Item.tier.type -eq 'winget') {
        $out.ok = $true
        $out.version = '(由 winget 决定)'
        return [pscustomobject]$out
    }

    $out.error = ('暂不支持的安装类型：' + [string]$Item.tier.type)
    return [pscustomobject]$out
}

function ConvertTo-CsvList {
    <#
        把可能是"逗号分隔的单字符串"的入参归一成真正的数组。
        必须存在的原因：powershell.exe -File 不会按逗号拆数组参数，
        -Only node,git 会被原样当成一个字符串 "node,git" 传进来。

        注意不要用 `return ,@($out)` 那种写法：函数返回空数组时会被 PowerShell
        "展开成没有输出"，调用方拿到 $null，再 @() 包一下就变成一个空元素。
        这里让调用方统一用 @(... | Where-Object { $_ }) 收口，空就是空。
    #>
    param([object]$Values)
    $out = New-Object System.Collections.ArrayList
    foreach ($v in @($Values)) {
        if ($null -eq $v) { continue }
        foreach ($part in ([string]$v -split ',')) {
            $tv = $part.Trim()
            if ($tv) { [void]$out.Add($tv) }
        }
    }
    return $out.ToArray()
}

# ======================================================================
#  执行
# ======================================================================

function Add-EntriesToUserPath {
    <#
        把若干目录并进用户级 PATH。
        -DryRun 时只算出结果并写 journal，不落盘。
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Entries,
        [Parameter(Mandatory = $true)]$Session,
        [switch]$Apply
    )
    $out = [ordered]@{ changed = $false; added = @(); before = ''; after = ''; error = ''; broadcast = $false }
    # 空列表是正常情况：绿色 GUI 工具（cc-switch 就是）根本没有 PATH 条目。以前直接把空数组绑进
    # Mandatory 参数，参数绑定器会抛 "Cannot bind argument to parameter 'Entries' because it is an empty
    # array" —— 文件明明已经「已就位」，却因为最后一步的 PATH 把整次安装判成失败。
    $real = @($Entries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($real.Count -eq 0) { return [pscustomobject]$out }
    $info = Get-UserPathInfo
    if (-not $info.available) {
        $out.error = $info.error
        return [pscustomobject]$out
    }
    $out.before = $info.value
    $current = $info.value
    $addedNow = New-Object System.Collections.ArrayList
    foreach ($e in $real) {
        $m = Merge-PathEntry -CurrentPath $current -Entry $e
        if ($m.changed) {
            $current = $m.value
            $out.changed = $true
            foreach ($a in @($m.added)) { [void]$addedNow.Add($a) }
        }
    }
    $out.after = $current
    $out.added = @($addedNow)

    if (-not $out.changed) { return [pscustomobject]$out }

    if ($Apply) {
        try {
            Set-UserPathValue -Value $current -Kind $info.kind
            $out.broadcast = Send-EnvironmentChangedBroadcast
        } catch {
            $out.error = Get-ShortErrorText -Text $_.Exception.Message
            return [pscustomobject]$out
        }
    }
    Add-JournalEntry -Session $Session -Action 'path.user.add' -Target 'HKCU:\Environment\Path' -Before $out.before -After $out.after -Note ('新增：' + ($out.added -join ' , ') + $(if ($Apply) { '' } else { '（DryRun，未写入）' }))
    return [pscustomobject]$out
}

function Remove-EntriesFromUserPath {
    <#
        从用户级 PATH 里移除若干目录。卸载流程要用它。
        和"加"那一侧保持一致：保留原有值类型、写前记 journal、DryRun 时不落盘。
        还原靠 journal 里的 path.user.remove 记录，Restore-LLMKitSession 会把它们加回去。
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Entries,
        [Parameter(Mandatory = $true)]$Session,
        [switch]$Apply
    )
    $out = [ordered]@{ changed = $false; removed = @(); before = ''; after = ''; error = ''; broadcast = $false }
    # 同理：没有要移除的条目就直接返回（卸载一个本来就没写 PATH 的绿色工具就是这种情形）。
    $real = @($Entries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($real.Count -eq 0) { return [pscustomobject]$out }
    $info = Get-UserPathInfo
    if (-not $info.available) {
        $out.error = $info.error
        return [pscustomobject]$out
    }
    $out.before = $info.value
    $current = $info.value
    $removedNow = New-Object System.Collections.ArrayList
    foreach ($e in $real) {
        if ([string]::IsNullOrWhiteSpace($e)) { continue }
        $r = Remove-PathEntry -CurrentPath $current -Entry $e
        if ($r.changed) {
            $current = $r.value
            $out.changed = $true
            foreach ($x in @($r.removed)) { [void]$removedNow.Add($x) }
        }
    }
    $out.after = $current
    $out.removed = @($removedNow)
    if (-not $out.changed) { return [pscustomobject]$out }

    if ($Apply) {
        try {
            Set-UserPathValue -Value $current -Kind $info.kind
            $out.broadcast = Send-EnvironmentChangedBroadcast
        } catch {
            $out.error = Get-ShortErrorText -Text $_.Exception.Message
            return [pscustomobject]$out
        }
    }
    Add-JournalEntry -Session $Session -Action 'path.user.remove' -Target 'HKCU:\Environment\Path' -Before $out.before -After $out.after -Note ('移除：' + ($out.removed -join ' , ') + $(if ($Apply) { '' } else { '（DryRun，未写入）' }))
    return [pscustomobject]$out
}

function Install-PortableItem {
    <#
        portable-zip / github-release 的公共执行路径。
        顺序刻意设计成"先全做完再换上去"：解压到 staging、验证能跑，才动最终目录。
        这样任何一步失败都不会留下半坏的安装 —— 那正是 M0 在真机上扫到的那类残留。

        SandboxRoot 非空时为"沙箱模式"：安装落到沙箱目录、PATH 绝不写注册表。
        既给用户"先试装看看"的能力，也让整条链路可以被自动化验证。
    #>
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$Session,
        [string]$CacheDir,
        [string]$Proxy,
        [scriptblock]$OnProgress,
        [switch]$Apply,
        [switch]$KeepCache,
        [string]$SandboxRoot
    )
    $res = [ordered]@{
        ok = $false; stage = ''; error = ''; installedTo = ''; version = ''
        archive = ''; sha256 = ''; sha256Expected = ''; sha256Verified = $null
        backedUpTo = ''; pathResult = $null; verifyOutput = ''; sandboxed = $false; steps = @()
    }
    $steps = New-Object System.Collections.ArrayList
    $tier = $Item.tier
    $dl = $Item.download

    # --- 0) 没有可用的下载信息时，现场重解析一次（计划阶段可能因网络抖动失败）---
    if (-not $dl -or -not $dl.ok) {
        $dl = Resolve-ItemDownload -Item $Item -MirrorRewriters $Item.__mirrorRewriters -Proxy $Proxy
    }
    if (-not $dl.ok) {
        $hint = Get-InstallErrorHint -Message ([string]$dl.error)
        $msg = '无法解析下载信息：' + $dl.error
        if ($hint) { $msg = $msg + ' 可能的原因：' + $hint }
        $res.error = Get-ShortErrorText -Text $msg
        return [pscustomobject]$res
    }
    $res.version = $dl.version
    if ($dl.kind -eq 'winget') {
        $res.error = '内部错误：winget 类型不应进入 portable 流程'
        return [pscustomobject]$res
    }

    # --- 1) 定目录 ---
    $realInstallRoot = Expand-PathToken -Path $tier.installRoot
    $sandboxed = -not [string]::IsNullOrEmpty($SandboxRoot)
    $installRoot = $realInstallRoot
    if ($sandboxed) { $installRoot = Join-Path $SandboxRoot $Item.id }
    $res.sandboxed = $sandboxed
    $installParent = Split-Path -Parent $installRoot

    # PATH 目标：沙箱模式下把真实安装根前缀换成沙箱根；否则用配置原值（保留 %VAR% 写法）
    $pathTargets = New-Object System.Collections.ArrayList
    foreach ($p in @($tier.pathEntries)) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        $expanded = Expand-PathToken -Path $p
        if ($sandboxed) {
            $suffix = ''
            $prefixReal = $realInstallRoot.TrimEnd('\')
            if ($expanded.ToLowerInvariant().StartsWith($prefixReal.ToLowerInvariant())) {
                $suffix = $expanded.Substring($prefixReal.Length)
            }
            [void]$pathTargets.Add(($installRoot + $suffix))
        } else {
            [void]$pathTargets.Add($expanded)
        }
    }
    $writePath = (-not $sandboxed)

    if ([string]::IsNullOrEmpty($CacheDir)) { $CacheDir = Join-Path $env:LOCALAPPDATA 'LLMKit\cache' }
    $archive = Join-Path $CacheDir ([string]$dl.fileName)
    $res.archive = $archive
    $staging = Join-Path $installParent ('.llmkit-staging-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    $res.stage = $staging

    if (-not $Apply) {
        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.plan') -Target $installRoot -Before $null -After $dl.version -Note ('DryRun 计划：下载 ' + $dl.urls[0] + ' -> 解压到 staging -> 验证 -> 就位 ' + $installRoot + ' -> PATH 增加 ' + ($pathTargets -join ' , ')) -Status 'planned'
        foreach ($p in $pathTargets) {
            [void](Add-EntriesToUserPath -Entries @($p) -Session $Session -Apply:$false)
        }
        $res.ok = $true
        $res.steps = @($steps)
        return [pscustomobject]$res
    }

    # archiveType: zip（默认，绿色压缩包）| raw-file（下载下来的就是程序本身）
    # 刻意不实现"静默安装 .exe"：在用户机器上无声执行第三方安装器风险太高，
    # 而且我们无法验证它到底做了什么。遇到安装器形式的资产会走人工引导层。
    $archiveType = 'zip'
    if ($tier.archiveType) { $archiveType = [string]$tier.archiveType }

    try {
        # --- 2) 下载 ---
        # 缓存先验再用：上次失败留下的半截包若被当作缓存"复用"，会一路错到解压那一刻才暴露，
        # 而且每次重试都撞同一堵墙。这里按三件事验：字节数非零、大小对得上、zip 能解析。
        if (Test-Path -LiteralPath $archive) {
            $cacheBytes = 0
            try { $cacheBytes = [long](Get-Item -LiteralPath $archive).Length } catch { }
            $cacheUsable = ($cacheBytes -gt 0)
            if ($cacheUsable -and $dl.sizeBytes -and ($cacheBytes -ne [long]$dl.sizeBytes)) { $cacheUsable = $false }
            if ($cacheUsable -and $archiveType -eq 'zip') { $cacheUsable = Test-ZipArchiveReadable -Path $archive }
            if ($cacheUsable) {
                [void]$steps.Add('复用缓存：' + $archive)
            } else {
                Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
                [void]$steps.Add('缓存不可用（大小不符或压缩包已损坏），已丢弃并重新下载：' + $archive)
                Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.cache') -Target $archive -Before $cacheBytes -Status 'failed' -Note '缓存里的压缩包不可用，已丢弃'
            }
        }
        if (-not (Test-Path -LiteralPath $archive)) {
            [void]$steps.Add('下载开始：' + $dl.urls[0])
            $down = Invoke-DownloadWithMirrors -Urls @($dl.urls) -Destination $archive -Proxy $Proxy -OnProgress $OnProgress -ExpectedBytes ([long]$dl.sizeBytes)
            if (-not $down.ok) {
                $detail = ($down.attempts | ForEach-Object { $_.url + ' => ' + $_.error }) -join ' ; '
                $firstErr = ''
                if ($down.attempts -and $down.attempts.Count -gt 0) { $firstErr = [string]$down.attempts[0].error }
                $hint = Get-InstallErrorHint -Message $firstErr
                if (-not $hint) { $hint = Get-InstallErrorHint -Message [string]$down.error }
                $msg = '下载失败：' + $detail
                if ($hint) { $msg = $msg + ' 可能的原因：' + $hint }
                $res.error = Get-ShortErrorText -Text $msg
                Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.download') -Target $archive -Status 'failed' -Note $res.error
                return [pscustomobject]$res
            }
            $res.sha256 = $down.sha256
            [void]$steps.Add('下载完成：' + (Format-ByteSize -Bytes $down.bytes) + ' / ' + $down.url)
            Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.download') -Target $archive -After ([ordered]@{ url = $down.url; bytes = $down.bytes; sha256 = $down.sha256; elapsedMs = $down.elapsedMs }) -Note '下载完成'
        }

        # 下载完立刻验包：截断的 zip 在解压时会抛 .NET 的晦涩异常，这里先说清楚是包坏了。
        if ($archiveType -eq 'zip' -and -not (Test-ZipArchiveReadable -Path $archive)) {
            $gotBytes = 0
            try { $gotBytes = [long](Get-Item -LiteralPath $archive).Length } catch { }
            $res.error = '下载到的压缩包已损坏或不完整（' + (Format-ByteSize -Bytes $gotBytes) + '）：镜像返回了被截断的文件，请重试或换镜像。'
            Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.download') -Target $archive -Status 'failed' -Note $res.error
            return [pscustomobject]$res
        }

        if (-not $res.sha256) {
            try { $res.sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash } catch { }
        }

        # --- 3) 校验和 ---
        if ($tier.checksumUrlTemplates -and $dl.checksumUrl) {
            $name = ([string]$tier.checksumEntryName).Replace('{version}', $dl.version)
            if (-not $name) { $name = [string]$dl.fileName }
            $sumText = $null
            foreach ($u in @((Get-MirrorCandidates -Url $dl.checksumUrl -MirrorRewriters $Item.__mirrorRewriters))) {
                $sr = Invoke-TextFetch -Url $u -TimeoutSec 60 -Proxy $Proxy
                if ($sr.ok) { $sumText = $sr.text; break }
            }
            if ($sumText) {
                $expected = Get-RemoteSha256FromShasums -ShasumsText $sumText -FileName $name
                if ($expected) {
                    $res.sha256Expected = $expected
                    $res.sha256Verified = ($expected -eq $res.sha256.ToUpperInvariant())
                    if (-not $res.sha256Verified) {
                        $res.error = ('校验和不匹配：期望 ' + $expected + '，实际 ' + $res.sha256 + '。已中止安装。')
                        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.checksum') -Target $archive -Before $expected -After $res.sha256 -Status 'failed' -Note 'SHA256 不匹配，已中止'
                        return [pscustomobject]$res
                    }
                    [void]$steps.Add('校验通过：SHA256 ' + $res.sha256)
                } else {
                    [void]$steps.Add('校验文件里没有 ' + $name + ' 的条目，跳过比对')
                }
            } else {
                [void]$steps.Add('校验文件下载失败，跳过比对（已在 journal 记录实际 SHA256）')
            }
        } else {
            [void]$steps.Add('该来源未提供官方校验和，已在 journal 记录实际 SHA256：' + $res.sha256)
        }
        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.checksum') -Target $archive -After ([ordered]@{ expected = $res.sha256Expected; actual = $res.sha256; verified = $res.sha256Verified }) -Note $(if ($null -eq $res.sha256Verified) { '无官方校验和，仅记录' } else { '校验通过' })

        # --- 4) 落地到 staging ---
        # archiveType 已在下载前定好（缓存校验要用到）；raw-file 与 zip 走两条路。
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
        if ($archiveType -eq 'raw-file') {
            [void](New-Item -ItemType Directory -Path $staging -Force)
            $target = Join-Path $staging ([string]$dl.fileName)
            Move-Item -LiteralPath $archive -Destination $target -Force
            [void]$steps.Add('下载下来的就是可执行文件本身，已放到 staging：' + $target)
        } else {
            Expand-ZipToDirectory -ZipPath $archive -Destination $staging
            [void]$steps.Add('已解压到 staging：' + $staging)
            if ($tier.flattenSingleRoot) {
                $flat = Remove-SingleRootFolder -Root $staging
                [void]$steps.Add($(if ($flat) { '已摊平 zip 的顶层目录' } else { '顶层目录不止一层，保持原样' }))
            }
        }

        # --- 5) 验证能跑起来 ---
        $rel = $null
        if ($tier.verify -and $tier.verify.relativePath) { $rel = [string]$tier.verify.relativePath }
        if (-not $rel -and $tier.verify -and $tier.verify.command) {
            $rel = [string]$tier.verify.command + '.exe'
        }
        if ($rel) {
            $probeExe = Join-Path $staging $rel
            if (-not (Test-Path -LiteralPath $probeExe)) {
                $res.error = ('解压结果里找不到预期的可执行文件：' + $probeExe + '（压缩包结构可能变了，请反馈）')
                Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.verify') -Target $probeExe -Status 'failed' -Note $res.error
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
                return [pscustomobject]$res
            }
            if ($tier.verify.skipRun) {
                # GUI 程序不能拿 --version 去试跑：多半会直接弹出窗口，并且不返回版本号。
                # 对这类程序只做"文件存在"验证，真正的可用性交给后续的人工/图形验证。
                [void]$steps.Add('存在性验证通过（GUI 程序不试跑，避免弹窗）：' + $probeExe)
                Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.verify') -Target $probeExe -Note '存在性验证通过（skipRun）'
                $rel = $null
            }
            $vr = $null
            $vtext = ''
            if ($rel) {
            $vr = Invoke-Process -FilePath $probeExe -Arguments @($tier.verify.args) -TimeoutMs 30000
            $vtext = $vr.stdout
            }
            if (-not $vtext) { $vtext = $vr.stderr }
            $res.verifyOutput = $vtext
            $pattern = [string]$tier.verify.expectedPattern
            $matched = $true
            if ($pattern) { $matched = ([string]$vtext -match $pattern) }
            if ($rel -and -not $matched) {
                $errText = ''
                if ($vr) { $errText = [string]$vr.error }
                $res.error = ('解压出来的程序跑不通：' + $probeExe + ' 输出 [' + $vtext + ']' + $(if ($errText) { ' 错误：' + $errText } else { '' }))
                Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.verify') -Target $probeExe -After $vtext -Status 'failed' -Note $res.error
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
                return [pscustomobject]$res
            }
            if ($rel) {
                [void]$steps.Add('试跑通过：' + $vtext)
                Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.verify') -Target $probeExe -After $vtext -Note 'staging 内试跑通过'
            }
        }

        # --- 6) 旧目录整体挪到备份区（不删除，可还原）---
        if (Test-Path -LiteralPath $installRoot) {
            $backupTarget = Join-Path $Session.backupDir ((Split-Path -Leaf $installRoot) + '-prev')
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $backupTarget) -Force)
            if (Test-Path -LiteralPath $backupTarget) { Remove-Item -LiteralPath $backupTarget -Recurse -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $installRoot -Destination $backupTarget -Force
            $res.backedUpTo = $backupTarget
            [void]$steps.Add('原有安装已备份到：' + $backupTarget)
            Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.backup') -Target $installRoot -Before $installRoot -After $backupTarget -Note '原有安装整体挪到备份区（未删除）'
        }

        # --- 7) staging 就位 ---
        [void](New-Item -ItemType Directory -Path $installParent -Force)
        Move-Item -LiteralPath $staging -Destination $installRoot -Force
        $res.installedTo = $installRoot
        [void]$steps.Add('已就位：' + $installRoot)

        # --- 8) 写清单（供升级/卸载使用）---
        $manifest = [pscustomobject]([ordered]@{
                schemaVersion  = '0.1.0'
                id             = $Item.id
                name           = $Item.name
                version        = $dl.version
                tier           = $tier.id
                sourceUrl      = $dl.urls[0]
                sha256         = $res.sha256
                sha256Expected = $res.sha256Expected
                installedAt    = (Get-Date).ToString('o')
                sessionId      = $Session.id
                sandboxed      = $sandboxed
                pathEntries    = @($pathTargets)
            })
        Write-JsonFile -Object $manifest -Path (Join-Path $installRoot '.llmkit-manifest.json')
        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.place') -Target $installRoot -After ([ordered]@{ version = $dl.version; tier = $tier.id; sha256 = $res.sha256 }) -Note '安装就位并写入清单'

        # --- 9) PATH ---
        $pathResult = Add-EntriesToUserPath -Entries @($pathTargets) -Session $Session -Apply:$writePath
        $res.pathResult = $pathResult
        if (@($pathTargets).Count -eq 0) {
            [void]$steps.Add('这个工具不需要 PATH 条目（绿色 GUI 工具，直接运行就行）')
        } elseif ($sandboxed) {
            [void]$steps.Add('沙箱模式：PATH 目标为 ' + ($pathTargets -join ' , ') + '（未写入注册表）')
        } elseif ($pathResult.error) {
            [void]$steps.Add('PATH 写入失败：' + $pathResult.error)
        } elseif ($pathResult.changed) {
            [void]$steps.Add('PATH 已新增：' + ($pathResult.added -join ' , '))
        } else {
            [void]$steps.Add('PATH 无需改动（已存在）')
        }

        $res.ok = $true
    } catch {
        $res.error = Get-ShortErrorText -Text $_.Exception.Message
        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.error') -Target $installRoot -Status 'failed' -Note $res.error
        if (Test-Path -LiteralPath $staging) { try { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
    } finally {
        # 失败的包绝不留缓存：下一次运行会把它当缓存"复用"，把同样的错误再演一遍。
        if (-not $KeepCache -and (Test-Path -LiteralPath $archive)) {
            try { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    $res.steps = @($steps)
    return [pscustomobject]$res
}
function Install-WingetItem {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$Session,
        [switch]$Apply
    )
    $res = [ordered]@{ ok = $false; error = ''; output = ''; steps = @() }
    $pkg = [string]$Item.tier.packageId
    $winget = Resolve-ExecutablePath -Name 'winget'
    if (-not $winget) {
        $res.error = '系统里没有 winget（应用安装程序）。Windows 10 1809 之前不带它，可从 Microsoft Store 安装「应用安装程序」。'
        return [pscustomobject]$res
    }
    $args = @('install', '--id', $pkg, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    $cmdText = 'winget ' + ($args -join ' ')

    if (-not $Apply) {
        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.plan') -Target $pkg -Note ('DryRun 计划：' + $cmdText) -Status 'planned'
        $res.ok = $true
        return [pscustomobject]$res
    }

    Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.winget') -Target $pkg -Note $cmdText
    $r = Invoke-Process -FilePath $winget -Arguments $args -TimeoutMs 1800000
    $res.output = $r.stdout
    if (-not $res.output) { $res.output = $r.stderr }
    # winget 在"已安装最新版"时会返回非 0，这不算失败
    $already = ($res.output -match 'already installed|已安装|No applicable upgrade|没有可用的升级')
    if ($r.ok -or $already) {
        $res.ok = $true
    } else {
        $res.error = Get-ShortErrorText -Text ($r.error + ' ' + $res.output)
    }
    Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.winget.result') -Target $pkg -After ([ordered]@{ exitCode = $r.exitCode; ok = $res.ok }) -Note (Get-ShortErrorText -Text $res.output) -Status $(if ($res.ok) { 'done' } else { 'failed' })
    return [pscustomobject]$res
}
function Restore-LLMKitSession {
    <#
        回滚一次安装会话：撤掉 PATH 新增项，把备份的目录放回去。
        刻意不做"删除新装的东西"以外的任何猜测动作。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JournalPath,
        [switch]$Apply,
        [switch]$NoColor
    )
    if (-not (Test-Path -LiteralPath $JournalPath)) { throw ('找不到会话日志：' + $JournalPath) }
    $doc = Read-TextFileUtf8 -Path $JournalPath | ConvertFrom-Json
    $toHost = {
        param($text, $color)
        # 必须走 Write-Host。本函数是把提示和返回值写在同一条输出流上的话，
        # 调用方一句 $setup = Invoke-... 就会把整段界面连同返回值一起吃掉，
        # 表现是"运行了但什么都没显示"。
        if (-not $NoColor) { try { Write-Host $text -ForegroundColor $color; return } catch { } }
        try { Write-Host $text } catch { [Console]::Out.WriteLine([string]$text) }
    }
    $actions = New-Object System.Collections.ArrayList

    # 1) PATH：把本会话新增的条目撤掉
    $pathEntries = @($doc.entries | Where-Object { $_.action -eq 'path.user.add' })
    $targetPathEntries = New-Object System.Collections.ArrayList
    foreach ($e in $pathEntries) {
        if ($e.note -match '新增：(.+)$') {
            foreach ($p in ($Matches[1] -split ',')) {
                $t = $p.Trim()
                if ($t -and -not $t.Contains('DryRun')) { [void]$targetPathEntries.Add($t) }
            }
        }
    }
    foreach ($entry in $targetPathEntries) {
        $info = Get-UserPathInfo
        if (-not $info.available) { continue }
        $rm = Remove-PathEntry -CurrentPath $info.value -Entry $entry
        [void]$actions.Add([pscustomobject]@{ kind = 'path.remove'; target = $entry; changed = $rm.changed; before = $info.value; after = $rm.value })
        if ($rm.changed -and $Apply) {
            Set-UserPathValue -Value $rm.value -Kind $info.kind
            [void](Send-EnvironmentChangedBroadcast)
        }
    }

    # 2) 安装目录与残留：备份放回去，新装的挪到 .reverted
    # install.*.backup 是安装时覆盖旧目录的备份，uninstall.*.backup 是卸载时搬走的本体，
    # artifacts.move 是清理残留时整组搬走，conflict.move 是解决冲突时搬走多余副本。
    # 这四者的形态完全一样（target=原位置, after=备份位置），还原动作也相同，所以一并匹配。
    #
    # artifacts.move / conflict.move 原来是漏的 —— 东西搬是搬了，但还原根本不管这些条目，
    # 于是"只搬不删、可以还原"这句话对残留并不成立。这是隔离环境集成测试真跑一遍
    # 才发现的（tests\Test-UninstallCycle.ps1）：搬过去的文件在还原后并没有回来。
    $backups = @($doc.entries | Where-Object {
            $_.action -like '*.backup' -or $_.action -eq 'artifacts.move' -or $_.action -eq 'conflict.move'
        })
    foreach ($b in $backups) {
        $orig = [string]$b.target
        $backup = [string]$b.after
        [void]$actions.Add([pscustomobject]@{ kind = 'dir.restore'; target = $orig; from = $backup; exists = (Test-Path -LiteralPath $backup) })
        if ($Apply -and (Test-Path -LiteralPath $backup)) {
            if (Test-Path -LiteralPath $orig) {
                $reverted = $orig + '.reverted-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
                Move-Item -LiteralPath $orig -Destination $reverted -Force
            }
            Move-Item -LiteralPath $backup -Destination $orig -Force
        }
    }
    # 3) 没有备份（本次是全新安装）的，把装好的挪走
    $placed = @($doc.entries | Where-Object { $_.action -like 'install.*.place' })
    $backedTargets = @($backups | ForEach-Object { [string]$_.target })
    foreach ($p in $placed) {
        if ($backedTargets -contains [string]$p.target) { continue }
        [void]$actions.Add([pscustomobject]@{ kind = 'dir.remove-new'; target = [string]$p.target; exists = (Test-Path -LiteralPath $p.target) })
        if ($Apply -and (Test-Path -LiteralPath $p.target)) {
            $reverted = $p.target + '.reverted-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Move-Item -LiteralPath $p.target -Destination $reverted -Force
        }
    }

    # 3b) 卸载时被移除的 PATH 条目：还原就是加回去
    $removedPaths = @($doc.entries | Where-Object { $_.action -eq 'path.user.remove' })
    foreach ($rp in $removedPaths) {
        $note = [string]$rp.note
        if ($note -notmatch '移除：(.+)') { continue }
        $info = Get-UserPathInfo
        if (-not $info.available) { continue }
        foreach ($entry in ($Matches[1] -split ',')) {
            $e = $entry.Trim()
            if ([string]::IsNullOrEmpty($e) -or $e -like '*DryRun*') { continue }
            $m = Merge-PathEntry -CurrentPath $info.value -Entry $e
            if ($m.changed) {
                [void]$actions.Add([pscustomobject]@{ kind = 'path.restore'; target = $e; from = ''; exists = $true })
                if ($Apply) { Set-UserPathValue -Value $m.value -Kind $info.kind; [void](Send-EnvironmentChangedBroadcast) }
            }
        }
    }

    # 4) 配置文件：按写入前的时间戳备份还原（或撤掉我们新建的文件）
    $cfgRestore = Get-Command -Name 'Restore-ConfigBackups' -ErrorAction SilentlyContinue
    if ($cfgRestore) {
        try {
            foreach ($c in @(& $cfgRestore -JournalDocument $doc -Apply:$Apply)) {
                [void]$actions.Add([pscustomobject]@{ kind = $c.kind; target = $c.target; from = $c.from; exists = $c.exists })
            }
        } catch { }
    }

    & $toHost '' 'Gray'
    & $toHost ('回滚会话 ' + $doc.sessionId + $(if ($Apply) { '（已执行）' } else { '（演练，未改动）' })) 'White'
    foreach ($a in $actions) {
        $line = '  · ' + $a.kind + '  ' + $a.target
        & $toHost $line 'DarkGray'
    }
    if ($actions.Count -eq 0) { & $toHost '  该会话没有需要回滚的改动。' 'DarkGray' }
    & $toHost '' 'Gray'
    return [pscustomobject]@{ sessionId = $doc.sessionId; applied = [bool]$Apply; actions = @($actions) }
}

Export-ModuleMember -Function `
    'Get-LLMKitInstallVersion', `
    'Restore-LLMKitSession', `
    'Merge-PathEntry', 'Remove-PathEntry', 'Get-NormalizedPathEntry', 'Get-PathEntryList', `
    'Get-UserPathInfo', 'Set-UserPathValue', 'Get-MirrorCandidates', 'Get-RemoteSha256FromShasums', `
    'Resolve-NodeVersionFromIndex', 'Format-ByteSize', 'ConvertTo-CsvList'

# 以下为跨模块复用的内部原语（LLMKit.Tools 会用到）。
# 刻意分开声明：这些不是稳定 API，随时可能随实现调整。
Export-ModuleMember -Function `
    'Invoke-Process', 'Resolve-ExecutablePath', 'Read-TextFileUtf8', 'Write-JsonFile', `
    'Get-ShortErrorText', 'Test-IsElevated', 'New-InstallSession', 'Add-JournalEntry', `
    'Save-InstallJournal', 'Invoke-DownloadWithMirrors', 'Expand-ZipToDirectory', `
    'Resolve-ItemDownload', 'Add-EntriesToUserPath', 'Remove-EntriesFromUserPath', 'Install-PortableItem', `
    'Get-InstallErrorHint', 'Send-EnvironmentChangedBroadcast', 'Get-ObjectProp'
