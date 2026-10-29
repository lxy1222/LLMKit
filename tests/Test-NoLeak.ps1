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
    # 注意：先按目录排除，再按扩展名/文件名筛选 —— 两步写在一个 Where-Object 里时，
    # 那个 -or 会让"文件名是 LICENSE"这个条件绕过目录排除（实测把 out\ 下第三方 LICENSE 也扫进来了）。
    $inRepo = @(Get-ChildItem -Recurse -Force -File | Where-Object { $_.FullName -notmatch '\\out\\|\\build\\dist\\|\\.git\\' })
    $files = @($inRepo | Where-Object {
            ($_.Extension -in @('.md', '.ps1', '.psm1', '.js', '.json', '.html', '.css', '.yml', '.yaml', '.txt', '.bat', '.cmd')) -or
            ($_.Name -in @('LICENSE', '.gitignore', '.gitattributes', '.editorconfig'))
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

    # ---- 5) 产品代码里不许写死"本机专属"的东西 ----
    # 这一类是"改一次就忘了"的典型：本机装在哪、什么显卡、调成多少，
    # 一旦被抄进代码，换台机器就变成错的结论。允许存在的位置只有实测记录与配置。
    $prodFiles = @($files | Where-Object {
            $_.FullName -notmatch '\\tests\\' -and
            $_.FullName -notmatch '\\out\\' -and
            $_.FullName -notmatch '\\build\\dist\\' -and
            $_.Extension -in @('.ps1', '.psm1', '.js', '.json', '.html', '.css')
        })
    function Get-ProdHits([string]$Pattern) {
        return @($prodFiles | Select-String -Pattern $Pattern -ErrorAction SilentlyContinue)
    }

    # 本机模型目录 / 安装盘（E:\Program Files 之类）出现在任何地方都不行
    $machinePaths = @(Get-ProdHits '[A-Za-z]:\\Program Files\\model|E:\\Program Files')
    Check ('产品代码里没有本机专属目录（' + $machinePaths.Count + ' 处）') ($machinePaths.Count -eq 0) `
    (($machinePaths | ForEach-Object { $_.Filename + ':' + $_.LineNumber + ':' + $_.Line.Trim() }) -join ' ; ')

    # 显卡型号只允许作为"实测记录"出现在配置里（models.json 的 measured / tools.json 的 notes）
    $gpuHits = @(Get-ProdHits 'RTX 3080|GeForce RTX')
    $gpuBad = @($gpuHits | Where-Object { $_.Path -notmatch 'config\\(models|tools)\.json$' })
    Check ('显卡型号只出现在配置的实测记录里（越界 ' + $gpuBad.Count + ' 处）') ($gpuBad.Count -eq 0) `
    (($gpuBad | ForEach-Object { $_.Filename + ':' + $_.LineNumber }) -join ' ; ')

    # Ollama 端口只允许串在模块常量与配置里出现；代码里别各写一份 11434
    $portHits = @(Get-ProdHits '11434')
    $portBad = @($portHits | Where-Object {
            $_.Path -notmatch 'LLMKit\.Hardware\.psm1$' -and
            $_.Path -notmatch '\\config\\'
        })
    # 注释里解释"这不是数字来源"的那一行不算
    $portBad = @($portBad | Where-Object { -not ($_.Path -match 'app\.js$' -and $_.Line -match '"11434"或"32768"') })
    Check ('Ollama 端口的字面量只在模块常量与配置里（越界 ' + $portBad.Count + ' 处）') ($portBad.Count -eq 0) `
    (($portBad | ForEach-Object { $_.Filename + ':' + $_.LineNumber }) -join ' ; ')

    # 32K 上下文：允许在配置（contextHint/各档 context）、模块常量、以及界面那句兜底里
    $ctxHits = @(Get-ProdHits '32768')
    $ctxBad = @($ctxHits | Where-Object {
            $_.Path -notmatch '\\config\\models\.json$' -and
            $_.Path -notmatch 'LLMKit\.Hardware\.psm1$' -and
            -not ($_.Path -match 'app\.js$' -and $_.Line -match '\|\|\s*32768|"11434"或"32768"|环境变量是 32768')
        })
    Check ('32K 上下文只从配置/模块常量来（越界 ' + $ctxBad.Count + ' 处）') ($ctxBad.Count -eq 0) `
    (($ctxBad | ForEach-Object { $_.Filename + ':' + $_.LineNumber + ':' + $_.Line.Trim() }) -join ' ; ')

    # ---- 6) 诊断报告不是仓库文件（它们是本机快照）----
    $reportFiles = @($files | Where-Object { $_.Name -match '^(env-report|diagnostic-)' })
    Check ('仓库里没有诊断报告快照（' + $reportFiles.Count + ' 个）') ($reportFiles.Count -eq 0)
}
finally {
    Pop-Location
    Write-Host ''
    Write-Host ('通过 ' + $pass + ' 项，失败 ' + $fail + ' 项') -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
    if ($fail) { Write-Host ('失败项：' + ($failures -join ' ; ')) -ForegroundColor Red; exit 1 }
}
