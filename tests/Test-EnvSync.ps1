<#
.SYNOPSIS
    环境同步的两条关键性质：该补的要补上，不该动的绝不动。

.DESCRIPTION
    为什么需要这个测试：Sync-ProcessEnvironmentFromRegistry 会在检测/写配置之前，
    把注册表里已经更新、但**当前进程还看不到**的环境补进本进程。它修的是两个真实抱怨：
      · "Node 明明装好了，界面还显示未安装"（进程环境是启动那一刻的快照）
      · "我刚 setx 存的 key，为什么界面说没有"（同理）

    这个函数有"顺手搞坏用户环境"的能力，所以测试必须同时钉住两头：
      A) 注册表里有、进程里没有的 → 必须补进来（含 REG_EXPAND_SZ 的 %VAR% 展开）
      B) 进程里已经有的（含用户在当前会话里临时改过的）→ 一个字节都不许改
      C) 不存在的目录不许塞进 PATH；用户手动加的条目不许清掉
      D) 幂等：连做两次，第二次补 0 个

    为什么不建临时注册表键：这个函数读的是 HKCU:\Environment。测试既不新建也不修改
    任何注册表项，只做两件安全的事 —— 从**当前进程**里删掉一个已经在注册表里的变量，
    以及删掉进程 PATH 里的一条目录。两者都只影响这个临时进程，进程一退就没了。
    如果 HKCU:\Environment 里除了 Path 什么都没有（干净的 CI 机器可能如此），
    涉及用户变量的那几项会明确报"跳过"，而不是假装通过。

.EXAMPLE
    .\tests\Test-EnvSync.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$pass = 0
$fail = 0
$skip = 0
function Check {
    param([string]$Name, $Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green; $script:pass++ }
    else {
        Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { ' —— ' + $Detail } else { '' })) -ForegroundColor Red
        $script:fail++
    }
}
function Skip {
    param([string]$Name, [string]$Why)
    Write-Host ('  [SKIP] ' + $Name + ' —— ' + $Why) -ForegroundColor DarkYellow
    $script:skip++
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repoRoot 'src\ps'
Import-Module (Join-Path $src 'LLMKit.psm1') -Force -DisableNameChecking

Write-Host 'LLMKit · 环境同步（只补不覆盖）'
Write-Host ('  ' + ('-' * 62))

# ---------------- 0) 摸清注册表里有什么 ----------------
$envKey = Get-Item -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue
$userVars = @()
if ($envKey) {
    foreach ($n in @($envKey.Property)) {
        if ([string]::IsNullOrEmpty($n)) { continue }
        if ($n -ieq 'Path') { continue }
        if ($n.StartsWith('=')) { continue }
        $raw = $null
        try { $raw = $envKey.GetValue($n, $null, 'DoNotExpandEnvironmentNames') } catch { }
        $userVars += [pscustomobject]@{
            name = $n
            raw  = [string]$raw
            kind = $envKey.GetValueKind($n).ToString()
            expanded = [System.Environment]::ExpandEnvironmentVariables([string]$raw)
        }
    }
}
Write-Host ('  注册表用户变量：' + $userVars.Count + ' 个' + $(if ($userVars.Count) { '（' + (@($userVars | ForEach-Object { $_.name }) -join ', ') + '）' } else { '' }))
Write-Host ''

# ---------------- A) 基线：能跑通、返回形状稳定 ----------------
Write-Host 'A) 返回形状与基线'
# 先数缺失（必须在同步之前数，否则同步已经把它们补上了）
$missingBefore = @($userVars | Where-Object { -not (Test-Path -LiteralPath ('Env:' + $_.name)) })
$r0 = Sync-ProcessEnvironmentFromRegistry
Check 'ok 为真' ($r0.ok -eq $true) ('error=' + $r0.error)
$props = @($r0.PSObject.Properties.Name)
Check '返回 4 个字段 ok/addedPath/addedEnv/error' ($props.Count -eq 4 -and ($props -contains 'addedPath') -and ($props -contains 'addedEnv')) ('实际 ' + ($props -join ','))
Check 'addedPath 是数组（空也不能退化成 null）' ($r0.addedPath -is [array])
Check 'addedEnv 是数组' ($r0.addedEnv -is [array])

Check '缺失数 = 首次补入数（不多补也不少补）' (@($r0.addedEnv).Count -eq $missingBefore.Count) `
    ('注册表缺 ' + $missingBefore.Count + ' 个，实际补了 ' + @($r0.addedEnv).Count + ' 个')

# ---------------- B) 缺的要补上（含 %VAR% 展开）----------------
Write-Host ''
Write-Host 'B) 注册表里有、进程里没有 → 补进来'
$probeVar = @($userVars | Where-Object { $_.name -inotmatch '^(TEMP|TMP)$' } | Select-Object -First 1)
$skipVar = ($null -eq $probeVar)
if ($skipVar) { $probeVar = $userVars | Select-Object -First 1 }

if (-not $probeVar) {
    Skip '删掉后能被补回' 'HKCU:\Environment 里除 Path 外没有用户变量'
    Skip '补回的值等于注册表的值' '同上'
    Skip '手动改过的值不被覆盖' '同上'
    Skip '改过的值不出现在 addedEnv 里' '同上'
} else {
    $name = $probeVar.name
    $savedValue = [System.Environment]::GetEnvironmentVariable($name, 'Process')
    Remove-Item -LiteralPath ('Env:' + $name) -Force -ErrorAction SilentlyContinue
    Check ('删掉后进程里确实没有（' + $name + '）') (-not (Test-Path -LiteralPath ('Env:' + $name)))

    $r1 = Sync-ProcessEnvironmentFromRegistry
    Check ('同步后它回来了（' + $name + '）') (Test-Path -LiteralPath ('Env:' + $name))
    $addedNames = @($r1.addedEnv)
    Check '同步结果里报告了它' ($addedNames -contains $name) ('实际补入 ' + ($addedNames -join ', '))
    Check '值等于注册表的值' ([System.Environment]::GetEnvironmentVariable($name, 'Process') -eq $probeVar.expanded) `
        ('进程里 ' + [System.Environment]::GetEnvironmentVariable($name, 'Process') + ' / 注册表 ' + $probeVar.expanded)

    # 用户在当前会话里临时改过的值：必须原样保留
    $marker = 'llmkit-keepme-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    [System.Environment]::SetEnvironmentVariable($name, $marker, 'Process')
    $r2 = Sync-ProcessEnvironmentFromRegistry
    Check '进程里改过的值没有被注册表覆盖' ([System.Environment]::GetEnvironmentVariable($name, 'Process') -eq $marker) `
        ('实际变成 ' + [System.Environment]::GetEnvironmentVariable($name, 'Process'))
    Check '已存在的变量不出现在 addedEnv 里' (-not (@($r2.addedEnv) -contains $name))

    if ($null -ne $savedValue) { [System.Environment]::SetEnvironmentVariable($name, $savedValue, 'Process') }
}

# REG_EXPAND_SZ 的 %VAR%：新开的进程拿到的是展开后的值，补进来的也必须是
$expandVar = @($userVars | Where-Object { $_.raw -like '*%*' } | Select-Object -First 1)
Write-Host ''
Write-Host 'C) REG_EXPAND_SZ 的 %VAR% 要展开'
if (-not $expandVar) {
    Skip '%VAR% 被展开' '注册表里没有含 % 的用户变量'
    Skip '展开结果与新进程一致' '同上'
} else {
    $savedA = [System.Environment]::GetEnvironmentVariable($expandVar.name, 'Process')
    Remove-Item -LiteralPath ('Env:' + $expandVar.name) -Force -ErrorAction SilentlyContinue
    $r3 = Sync-ProcessEnvironmentFromRegistry
    $got = [System.Environment]::GetEnvironmentVariable($expandVar.name, 'Process')
    Check ('%VAR% 被展开（' + $expandVar.name + ' = ' + $expandVar.raw + '）') ($got -notlike '*%*') ('实际 ' + $got)
    Check '展开结果与新进程会拿到的一致' ($got -eq $expandVar.expanded) ('实际 ' + $got + ' / 预期 ' + $expandVar.expanded)
    if ($null -ne $savedA) { [System.Environment]::SetEnvironmentVariable($expandVar.name, $savedA, 'Process') }
}

# ---------------- D) PATH：该补的补、不存在的别塞、别清用户加的 ----------------
Write-Host ''
Write-Host 'D) PATH 的边界'
$regPathParts = @()
foreach ($src2 in @(
        (Get-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -ErrorAction SilentlyContinue).Path,
        (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'Path' -ErrorAction SilentlyContinue).Path)) {
    if ([string]::IsNullOrEmpty($src2)) { continue }
    $regPathParts += @(([System.Environment]::ExpandEnvironmentVariables([string]$src2)) -split ';')
}
$curParts = @([string]$env:PATH -split ';' | Where-Object { $_.Trim() })
$curKeys = @($curParts | ForEach-Object { $_.Trim().TrimEnd('\').ToLowerInvariant() })

# 挑一条"注册表里有、进程里也有、目录真实存在"的条目，把它从进程里删掉
$target = $null
foreach ($p in ($regPathParts | Where-Object { $_.Trim() })) {
    $t = $p.Trim().TrimEnd('\')
    if ($curKeys -notcontains $t.ToLowerInvariant()) { continue }
    if (-not (Test-Path -LiteralPath $t -PathType Container)) { continue }
    $target = $t
}
if (-not $target) {
    Skip '删掉的 PATH 条目能被补回' '注册表 PATH 里的条目当前进程全都没有（或目录都不存在）'
    Skip '补回的条目出现在 addedPath 里' '同上'
} else {
    $bogus = Join-Path $env:SystemDrive ('LLMKIT_nonexistent_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $env:PATH = ((@($curParts | Where-Object { $_.Trim().TrimEnd('\') -ine $target }) + $bogus) -join ';')
    Check ('删掉的条目确实不在了（' + $target + '）') (-not (@([string]$env:PATH -split ';' | ForEach-Object { $_.Trim().TrimEnd('\').ToLowerInvariant() }) -contains $target.ToLowerInvariant()))

    $r4 = Sync-ProcessEnvironmentFromRegistry
    $nowKeys = @([string]$env:PATH -split ';' | ForEach-Object { $_.Trim().TrimEnd('\').ToLowerInvariant() })
    Check '注册表里的那条被补回 PATH' ($nowKeys -contains $target.ToLowerInvariant())
    Check '补回的条目出现在 addedPath 里' (@(@($r4.addedPath) | ForEach-Object { ([string]$_).TrimEnd('\').ToLowerInvariant() }) -contains $target.ToLowerInvariant()) `
        ('实际补入 ' + (@($r4.addedPath) -join ' | '))
    $badAdded = @(@($r4.addedPath) | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })
    Check '补进来的目录全都真实存在（不存在的绝不塞）' ($badAdded.Count -eq 0) ('混进了 ' + ($badAdded -join ', '))
    Check '用户手动加的条目没有被清掉' (@([string]$env:PATH -split ';' | ForEach-Object { $_.Trim() }) -contains $bogus)
}

# ---------------- E) 幂等 + 绝不碰 Path 这个名字 ----------------
Write-Host ''
Write-Host 'E) 幂等与护栏'
$r5 = Sync-ProcessEnvironmentFromRegistry
Check '再同步一次：环境变量补 0 个' (@($r5.addedEnv).Count -eq 0) ('实际 ' + @($r5.addedEnv).Count)
Check '再同步一次：PATH 补 0 条' (@($r5.addedPath).Count -eq 0) ('实际 ' + @($r5.addedPath).Count)
$allAdded = @(@($r0.addedEnv) + @($r5.addedEnv))
Check 'addedEnv 里绝不会出现 Path' (@($allAdded | Where-Object { $_ -ieq 'Path' }).Count -eq 0)
Check 'addedEnv 里绝不会有以 = 开头的注册表特殊项' (@($allAdded | Where-Object { ([string]$_).StartsWith('=') }).Count -eq 0)
Check '同步不会把 PATH 拆没（条数仍然合理）' (@([string]$env:PATH -split ';' | Where-Object { $_.Trim() }).Count -ge 5) `
    ('实际 ' + @([string]$env:PATH -split ';' | Where-Object { $_.Trim() }).Count + ' 条')

Write-Host ('  ' + ('-' * 62))
Write-Host ('通过 ' + $pass + ' 项，失败 ' + $fail + ' 项，跳过 ' + $skip + ' 项')
if ($fail -gt 0) { exit 1 }
exit 0
