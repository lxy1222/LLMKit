<#
.SYNOPSIS
    工具检测的两条关键性质：npm 启动器要折叠，真多副本仍要报警。

.DESCRIPTION
    为什么需要这个测试：npm 全局安装同一个命令会放三个启动器文件
    （例如 dsh / dsh.cmd / dsh.ps1）。检测以前只按完整路径去重，于是这三个被
    数成三份安装，而冲突判定是 `execCount > 1` —— 结果给一个**完全健康**的
    npm 安装报"多副本冲突"，还建议用户去清理残留再重装，把人往错的方向指。

    修法是把"同一目录 + 同一命令基名"的启动器折叠成一份。但这个修法有个风险：
    万一折叠过头，真冲突就再也发现不了了 —— 那比假警报更糟。所以这个测试同时钉住两头：
      A) 三个启动器在同一个目录 → 只算 1 份，不报冲突，且留下的是能直接跑的 .cmd
      B) 同一个命令出现在**两个不同目录** → 必须算 2 份并报冲突

    用的是 probePaths（不是 PATH），所以全程只碰临时目录，不动系统。

.EXAMPLE
    .\tests\Test-ToolDetection.ps1
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
foreach ($m in @('LLMKit', 'LLMKit.Install', 'LLMKit.Tools')) {
    Import-Module (Join-Path $src ($m + '.psm1')) -Force -DisableNameChecking
}

Write-Host 'LLMKit · 工具检测（启动器折叠 vs 真冲突）'
Write-Host ('  ' + ('-' * 62))

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('llmkit-detect-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $work -Force)

# 造三个启动器：一个能跑的 .cmd、一个 .ps1、一个无扩展名（npm 在 Windows 上的典型三件套）
function New-ShimTriple {
    param([string]$Dir)
    [void](New-Item -ItemType Directory -Path $Dir -Force)
    $cmd = Join-Path $Dir 'zzz.cmd'
    [System.IO.File]::WriteAllText($cmd, "@echo off`r`necho 9.9.9-fake`r`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $Dir 'zzz.ps1'), "Write-Output '9.9.9-fake'`r`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $Dir 'zzz'), "#!/bin/sh`necho 9.9.9-fake`n", (New-Object System.Text.UTF8Encoding($false)))
    return @($cmd, (Join-Path $Dir 'zzz.ps1'), (Join-Path $Dir 'zzz'))
}

function New-FakeTool {
    param([string]$Id, [string[]]$ProbePaths)
    return [pscustomobject]([ordered]@{
            id = $Id; name = $Id; vendor = 'test'; kind = 'cli'
            # 特意用一个不存在的命令名：让第 1 步（PATH 命中）什么都不加，
            # 这样测的就纯粹是 probePaths 那条路。折叠代码两条路都要过。
            commands = @('llmkit-zzz-not-a-real-command-9f3a')
            probePaths = $ProbePaths
            npmPackage = $null
            verify = [pscustomobject]@{ versionCommand = 'zzz --version'; smokeTest = $null }
            homeUrl = ''; install = $null
        })
}
$fakeState = [pscustomobject]@{ npmPrefix = $null }

# ---------------- A) 三个启动器在同一目录 ----------------
Write-Host 'A) npm 三件套在同一个目录 → 应只算 1 份'
$dirA = Join-Path $work 'A'
$shimsA = New-ShimTriple -Dir $dirA
$stA = Get-ToolStatus -Tool (New-FakeTool -Id 'fake-a' -ProbePaths $shimsA) -State $fakeState
Check '三个启动器折叠成 1 份安装' ($stA.installCount -eq 1) ('实际 ' + $stA.installCount)
Check '不报多副本冲突' (-not $stA.conflict)
Check '保留的是能直接跑的 .cmd 启动器' ([System.IO.Path]::GetExtension($stA.executable) -eq '.cmd') ('实际 ' + $stA.executable)
Check '版本探测真的跑起来了' ($stA.version -eq '9.9.9-fake') ('实际 ' + $stA.version)
Check '仍然算作已安装' ($stA.installed)
$execEntriesA = @($stA.installations | Where-Object { $_.kind -eq 'path' -or $_.kind -eq 'file' })
Check '清单里只有 1 条安装位置' ($execEntriesA.Count -eq 1) ('实际 ' + $execEntriesA.Count)

# ---------------- B) 两个不同目录各有一份 ----------------
Write-Host ''
Write-Host 'B) 同一个命令在两个不同目录 → 必须算 2 份并报冲突'
$dirB1 = Join-Path $work 'B1'
$dirB2 = Join-Path $work 'B2'
$shimsB1 = New-ShimTriple -Dir $dirB1
$shimsB2 = New-ShimTriple -Dir $dirB2
$stB = Get-ToolStatus -Tool (New-FakeTool -Id 'fake-b' -ProbePaths (@($shimsB1) + @($shimsB2))) -State $fakeState
Check '两个目录算 2 份安装' ($stB.installCount -eq 2) ('实际 ' + $stB.installCount)
Check '真冲突仍然被报出来' ($stB.conflict)
$dirsB = @($stB.installations | Where-Object { $_.kind -eq 'path' -or $_.kind -eq 'file' } |
        ForEach-Object { (Split-Path -Parent $_.path).ToLowerInvariant() } | Sort-Object -Unique)
Check '两份来自两个不同目录' ($dirsB.Count -eq 2) ('实际 ' + $dirsB.Count)

# ---------------- C) 只给 .ps1（没有可跑的启动器）也不能崩 ----------------
Write-Host ''
Write-Host 'C) 只有一个 .ps1 启动器 → 不崩，且仍算 1 份'
$dirC = Join-Path $work 'C'
[void](New-Item -ItemType Directory -Path $dirC -Force)
$ps1C = Join-Path $dirC 'zzz.ps1'
[System.IO.File]::WriteAllText($ps1C, "Write-Output '9.9.9-fake'`r`n", (New-Object System.Text.UTF8Encoding($false)))
$stC = Get-ToolStatus -Tool (New-FakeTool -Id 'fake-c' -ProbePaths @($ps1C)) -State $fakeState
Check '只有 .ps1 时算 1 份' ($stC.installCount -eq 1) ('实际 ' + $stC.installCount)
Check '不报冲突' (-not $stC.conflict)
Check '兜底选中了这个 .ps1' ($stC.executable -eq $ps1C)

try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ('  ' + ('-' * 62))
Write-Host ('通过 ' + $pass + ' 项，失败 ' + $fail + ' 项')
if ($fail -gt 0) { exit 1 }
exit 0
