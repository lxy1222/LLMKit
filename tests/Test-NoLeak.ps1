# 泄露扫描：确保仓库里不会混进本机信息或真实凭据。
#
# 为什么要有这个测试：这类东西是"清理一次就干净、下一轮又漏一处"的典型。
# 只靠人工 review 不行 —— 提交前跑一次，比事后补救便宜太多。
#
# 它检查的：
#   1) 本机绝对路径（用户目录、本机项目目录、常见安装目录）
#   2) 真实 API Key 形态（sk-… 之类），占位符不算
#   3) 邮箱
#   4) 同一台机器的用户名出现在配置/代码里（从 $env:USERPROFILE 反推，避免写死）
#
# 它**不**检查 out/ 与 build/dist/ —— 那是运行时产物目录，本来就含本机信息，
# 靠 .gitignore 排除；这里额外断言这两个目录确实在忽略列表里。
param(
    [string]$Root,
    [switch]$NoColor
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }

$pass = 0; $fail = 0
$failures = New-Object System.Collections.ArrayList

function Check([string]$Name, $Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ('  [PASS] ' + $Name) -ForegroundColor DarkGreen }
    else {
        $script:fail++
        [void]$script:failures.Add($Name)
        Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { ' —— ' + $Detail } else { '' })) -ForegroundColor Red
    }
}

Push-Location $Root
try {
    Write-Host '泄露扫描：本机信息与凭据' -ForegroundColor Cyan
    Write-Host ('  仓库根：' + $Root)

    # 要扫的文件：仓库里的文本文件，排除运行时产物目录
    $files = @(Get-ChildItem -Recurse -File | Where-Object {
            $_.FullName -notmatch '\\out\\|\\build\\dist\\|\\.git\\' -and
            ($_.Extension -in @('.md', '.ps1', '.psm1', '.js', '.json', '.html', '.css', '.yml', '.yaml', '.txt', '.bat', '.cmd')) -or
            $_.Name -in @('LICENSE', '.gitignore', '.gitattributes', '.editorconfig')
        })
    Write-Host ('  待扫文件：' + $files.Count + ' 个')
    $paths = $files.FullName

    # ---- 1) 本机绝对路径 ----
    # 用当前机器的真实值反推，而不是写死某个人的路径 —— 换台机器照样能查。
    $userHome = $env:USERPROFILE
    $userName = Split-Path -Leaf $userHome
    $checks = @(
        @{ Name = '用户目录绝对路径'; Pattern = $userHome; Exact = $true },
        @{ Name = '当前项目绝对路径'; Pattern = $Root; Exact = $true },
        @{ Name = '本机用户名（作为路径片段）'; Pattern = ('\Users\' + $userName + '\'); Exact = $true }
    )
    if ($env:LOCALAPPDATA) { $checks += @{ Name = 'LOCALAPPDATA 展开后的绝对路径'; Pattern = $env:LOCALAPPDATA; Exact = $true } }

    foreach ($c in $checks) {
        $hits = @(Select-String -Path $paths -Pattern $c.Pattern -SimpleMatch -ErrorAction SilentlyContinue)
        Check ($c.Name + ' 不出现（' + $hits.Count + ' 处）') ($hits.Count -eq 0) ($(if ($hits.Count) { ($hits | Select-Object -First 2 | ForEach-Object { (Split-Path $_.Path -Leaf) + ':' + $_.LineNumber }) -join ', ' } else { '' }))
    }

    # ---- 2) 真实 key 形态 ----
    # sk- 后面跟足够长的十六进制/字母串才算；文档里的 <你的 DeepSeek API Key>、sk-你的key 不算。
    $keyHits = @(Select-String -Path $paths -Pattern 'sk-[A-Za-z0-9]{20,}' -ErrorAction SilentlyContinue)
    Check ('没有真实 sk- 形态的 key（' + $keyHits.Count + ' 处）') ($keyHits.Count -eq 0) ($(if ($keyHits.Count) { ($keyHits | Select-Object -First 2 | ForEach-Object { (Split-Path $_.Path -Leaf) + ':' + $_.LineNumber }) -join ', ' } else { '' }))

    # ---- 3) 邮箱 ----
    # 允许 GitHub noreply 这类明确的中性地址
    $mailHits = @(Select-String -Path $paths -Pattern '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -ErrorAction SilentlyContinue |
        Where-Object { $_.Line -notmatch 'users\.noreply\.github\.com|example\.com|@example|noreply@' })
    Check ('没有个人邮箱（' + $mailHits.Count + ' 处）') ($mailHits.Count -eq 0) ($(if ($mailHits.Count) { ($mailHits | Select-Object -First 2 | ForEach-Object { (Split-Path $_.Path -Leaf) + ':' + $_.LineNumber }) -join ', ' } else { '' }))

    # ---- 4) 运行时产物目录必须在忽略列表里 ----
    $gi = ''
    if (Test-Path '.gitignore') { $gi = (Get-Content '.gitignore' -Raw -Encoding UTF8) }
    Check '.gitignore 忽略 out/' ($gi -match '(?m)^out/?\s*$')
    Check '.gitignore 忽略 build/dist/' ($gi -match '(?m)^build/dist/?\s*$')

    # ---- 5) 诊断报告不是仓库文件（它们是本机快照）----
    $reportFiles = @($files | Where-Object { $_.Name -match '^(env-report|diagnostic-)' })
    Check ('仓库里没有诊断报告快照（' + $reportFiles.Count + ' 个）') ($reportFiles.Count -eq 0)
}
finally {
    Pop-Location
    Write-Host ''
    Write-Host ('通过 ' + $pass + ' 项，失败 ' + $fail + ' 项') -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
    if ($fail) { Write-Host ('失败项：' + ($failures -join ' ; ')) -ForegroundColor Red; exit 1 }
}
