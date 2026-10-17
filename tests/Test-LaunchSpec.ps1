<#
.SYNOPSIS
    六个工具的启动命令是怎么拼出来的，以及起进程这条路真的走得通。

.DESCRIPTION
    分三层：
      1) 拼装：六个工具各自的启动命令形态 —— CLI 要用 cmd /k 开新窗口并留住，
         GUI 直接起 exe，没装的要给出能看懂的原因而不是"点了没反应"。
      2) 拒绝路径：未知工具 / 没装 / 没有冒烟命令，各自要给不同的 code，
         因为 Web 层要靠 code 区分 400 和 409。
      3) 起进程机制：Start-Process + 数组参数 + **带空格的路径**真的能跑起来。
         这一条用 /c 的变体（跑完自己关），免得测试在用户桌面上留一堆窗口。
         生产用的是 /k（窗口留住，用户才看得到输出）—— 那一点只有字符串级断言，
         窗口是否真的留住没有在真实桌面上目视确认过。

.EXAMPLE
    .\tests\Test-LaunchSpec.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$pass = 0
$fail = 0
function Check {
    param([string]$Name, $Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green; $script:pass++ }
    else {
        Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { ' —— ' + $Detail } else { '' })) -ForegroundColor Red
        $script:fail++
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repoRoot 'src\ps'
foreach ($m in @('LLMKit', 'LLMKit.Install', 'LLMKit.Tools', 'LLMKit.Config', 'LLMKit.Diagnose', 'LLMKit.Engine', 'LLMKit.Service')) {
    Import-Module (Join-Path $src ($m + '.psm1')) -Force -DisableNameChecking
}

Write-Host 'LLMKit · 六个工具的启动命令'
Write-Host ('  ' + ('-' * 62))

# 这台机器上装了哪些工具由检测决定，不写死 —— 测试要在任何机器上都得出正确结论
$cfg = $repoRoot
$catalog = Get-LLMKitActionCatalog  # 只是确认模块可用
$all = @((Get-LLMKitOverview -ConfigRoot $cfg).tools)
Write-Host ('  本机装了 ' + @($all | Where-Object { $_.installed }).Count + ' / ' + $all.Count + ' 个工具')

# ---------------- 1) 拼装 ----------------
Write-Host '拼装'
foreach ($t in $all) {
    $spec = Get-LLMKitLaunchSpec -ConfigRoot $cfg -ToolId $t.id -Mode 'interactive'
    if (-not $t.installed) {
        Check ($t.id + '：没装时给 code=not-installed') ($spec.code -eq 'not-installed') ('实际 ' + $spec.code)
        Check ($t.id + '：没装时原因不是空的') (-not [string]::IsNullOrEmpty($spec.reason))
        continue
    }
      # 有些工具本身没有可常驻的窗口（Git 就是：单独跑只打印用法就退出，MinGit 也不带 bash）。
      # 这类工具在配置里标了 launch.disabled，正确行为是"明确拒绝 + 给原因"，而不是硬拼一条命令。
      if ($spec.code -eq 'disabled-by-config') {
          Check ($t.id + '：配置成不可启动时如实拒绝') (-not $spec.ok -and -not [string]::IsNullOrEmpty($spec.reason)) $spec.code
          continue
      }
    Check ($t.id + '：装了就能启动') ($spec.ok) $spec.reason
    if ($t.kind -eq 'gui') {
        Check ($t.id + '：GUI 直接起 exe，不套终端') ($spec.filePath -eq $spec.executable -and @($spec.arguments).Count -eq 0) ($spec.filePath)
    } else {
        Check ($t.id + '：CLI 用 cmd /k 开窗口并留住') ($spec.filePath -eq 'cmd.exe' -and @($spec.arguments)[0] -eq '/k') (@($spec.arguments) -join ' ')
        Check ($t.id + '：可执行文件路径带引号（防空格）') (([string]@($spec.arguments)[1]) -match '^"[^"]+"') (@($spec.arguments) -join ' ')
        Check ($t.id + '：命令原文里能看到 /k 与路径') ($spec.commandLine -match '/k' -and $spec.commandLine.Contains($spec.executable))
    }
    Check ($t.id + '：启动目录是用户主目录') ($spec.workingDir -eq [System.Environment]::GetFolderPath('UserProfile')) $spec.workingDir
}

# 每个工具都要有"怎么启动"的人话说明
foreach ($t in $all) {
    $L = (Get-LLMKitToolDetail -ConfigRoot $cfg -ToolId $t.id).launch
    Check ($t.id + '：有「怎么启动」说明') (@($L.howTo).Count -ge 2) ('实际 ' + @($L.howTo).Count + ' 条')
    $blank = @($L.howTo | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count
    Check ($t.id + '：说明里没有空条目') ($blank -eq 0) ('空条目 ' + $blank + ' 条')
}

# ---------------- 2) 拒绝路径 ----------------
Write-Host ''
Write-Host '拒绝路径'
$unknown = Get-LLMKitLaunchSpec -ConfigRoot $cfg -ToolId 'no-such-tool' -Mode 'interactive'
Check '未知工具 → code=unknown-tool' ($unknown.code -eq 'unknown-tool') ('实际 ' + $unknown.code)
Check '未知工具的提示里列出了可用工具' ($unknown.reason -match '可用：') $unknown.reason

$gui = @($all | Where-Object { $_.installed -and $_.kind -eq 'gui' })
if ($gui.Count -gt 0) {
    $s = Get-LLMKitLaunchSpec -ConfigRoot $cfg -ToolId $gui[0].id -Mode 'smoke'
    Check 'GUI 工具没有冒烟命令 → code=no-smoke' ($s.code -eq 'no-smoke') ('实际 ' + $s.code)
}

# ---------------- 3) 起进程机制 ----------------
Write-Host ''
Write-Host '起进程机制（用会自关的 /c 变体，不在桌面上留窗口）'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('llmkit launch test')   # 故意带空格
[void](New-Item -ItemType Directory -Path $work -Force)
$marker = Join-Path $work 'marker.txt'
$script = Join-Path $work 'say.cmd'
[System.IO.File]::WriteAllText($script, "@echo off`r`necho launched > `"$marker`"`r`n", (New-Object System.Text.UTF8Encoding($false)))

Check '测试目录确实带空格' ($work -match ' ')
# 与生产同形：cmd.exe + 数组参数 + 带引号的路径，只是把 /k 换成 /c 好让它自己关
try {
    # -WindowStyle Hidden 只是为了让这个测试别在你桌面上闪一个窗口；生产环境不用它
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('"' + $script + '"')) -WorkingDirectory $work -WindowStyle Hidden -Wait
    Check '带空格的路径能被正确启动' (Test-Path -LiteralPath $marker) ('标记文件没生成：' + $marker)
} catch {
    Check '带空格的路径能被正确启动' $false $_.Exception.Message
}

try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ('  ' + ('-' * 62))
Write-Host '';
Write-Host '服务型工具（dsh web）：必须带子命令，端口被占时自动换一个'

# dsh 的网页界面必须 `dsh web`。这条以前缺过：启动器只拼了 exe，用户还得自己在窗口里敲 web。
$dshSpec = Get-LLMKitLaunchSpec -ConfigRoot $cfg -ToolId 'dsh' -Mode 'interactive'
if ($dshSpec.ok) {
    Check 'dsh 的启动参数里带 web 子命令' ((@($dshSpec.arguments) -join ' ') -match '\bweb\b') (@($dshSpec.arguments) -join ' ')
    Check 'dsh 的命令行里也有 web' ($dshSpec.commandLine -match '\bweb\b') $dshSpec.commandLine
    Check 'dsh 声明了服务型工具 → 有端口' ([int]$dshSpec.port -gt 0) ('port=' + $dshSpec.port)
    Check '命令行里带上 --port' ($dshSpec.commandLine -match '--port\s+\d+') $dshSpec.commandLine
    Check '--port 用的就是 spec.port' ($dshSpec.commandLine -match ('--port\s+' + $dshSpec.port)) $dshSpec.commandLine

    # 端口被占时要避开它。这里自己占住默认端口来做这条断言 ——
    # 如果默认端口本来就被占（比如机器上正跑着一个 DSH），那就直接断言"没选它"。
    $defaultPort = 3080
    $listener = $null
    $holding = $false
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $defaultPort)
        $listener.Start()
        $holding = $true
    } catch { $holding = $false }
    
    # 不管是"我们自己占住"还是"别人本来占着"，结论都一样：不能选这个端口
    $spec2 = Get-LLMKitLaunchSpec -ConfigRoot $cfg -ToolId 'dsh' -Mode 'interactive'
    Check '默认端口被占时不选它' ([int]$spec2.port -ne $defaultPort) ('port=' + $spec2.port + '，占据者=' + $(if ($holding) { '测试自己' } else { '其它进程' }))
    
    # 只有在"默认端口本来是空的"这种机器上，才能顺带验"释放后回到默认端口"
    if ($listener) { try { $listener.Stop() } catch { } }
    if ($holding) {
        $spec3 = Get-LLMKitLaunchSpec -ConfigRoot $cfg -ToolId 'dsh' -Mode 'interactive'
        Check '端口释放后回到默认端口' ([int]$spec3.port -eq $defaultPort) ('port=' + $spec3.port)
    }

}

# 反向断言：没声明 server 的工具不能凭空多出端口和参数（否则就是"只改 dsh"没守住）
foreach ($other in @('opencode', 'cc-switch')) {
    $o = Get-LLMKitLaunchSpec -ConfigRoot $cfg -ToolId $other -Mode 'interactive'
    if ($o.ok) {
        Check ($other + ' 没有端口（不是服务型工具）') ([int]$o.port -eq 0) ('port=' + $o.port)
        Check ($other + ' 的命令行里没有 --port') ($o.commandLine -notmatch '--port') $o.commandLine
    }
}

Write-Host ('通过 ' + $pass + ' 项，失败 ' + $fail + ' 项')
if ($fail -gt 0) { exit 1 }
exit 0
