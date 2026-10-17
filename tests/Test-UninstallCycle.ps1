<#
.SYNOPSIS
    真跑一次"残留挪到备份区 → 再还原回来"，全程不碰本机任何真实目录。

.DESCRIPTION
    为什么需要这个测试：单元测试只测纯函数，"卸载/清理只搬不删、可还原"这句话
    在此之前只有**演练**证据 —— 演练只证明它列出的计划对，没证明它真把东西搬过去了、
    也没证明搬过去之后还能搬回来。

    做法：把 APPDATA / USERPROFILE / LOCALAPPDATA 临时指向临时目录（子进程继承），
    用 -StateDir 把日志与备份区也指到临时目录，造两个符合引擎识别规则的假残留组，
    真跑一次清理，再真跑一次还原，最后核对本机真实目录一个字节都没动。

    识别规则（来自 LLMKit.psm1 的 Find-InstallArtifacts）：
      组目录：^\.(claude|codex|gemini|opencode|anthropic|npm)[-_][A-Za-z0-9_-]{6,}$
      残留文件：\.(old|restoring|tmp|partial|bak|new)\.[0-9a-fA-F]{4,}$

.EXAMPLE
    .\tests\Test-UninstallCycle.ps1
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
$setup = Join-Path $repoRoot 'src\ps\Setup-LLMKit.ps1'
if (-not (Test-Path -LiteralPath $setup)) { throw ('找不到引擎入口：' + $setup) }

Write-Host 'LLMKit · 卸载/清理的搬移与还原（隔离环境集成测试）'
Write-Host ('  ' + ('-' * 62))

# ---------------------------------------------------------------- 搭一个假环境
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('llmkit-cycle-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fakeAppData = Join-Path $work 'AppData'
$fakeUserProfile = Join-Path $work 'UserProfile'
$fakeLocalAppData = Join-Path $work 'LocalAppData'
$fakeState = Join-Path $work 'State'
foreach ($d in @($fakeAppData, $fakeUserProfile, $fakeLocalAppData, $fakeState)) {
    [void](New-Item -ItemType Directory -Path $d -Force)
}

# 两个假残留组：一个在 node_modules 顶层、一个在 @anthropic-ai 下，
# 对应真机上实测到的那两种形态。
$groupA = Join-Path $fakeAppData 'npm\node_modules\.claude-code-fake01'
$groupB = Join-Path $fakeAppData 'npm\node_modules\@anthropic-ai\.claude-code-fake02'
$fileA = Join-Path $groupA 'bin\claude.exe.old.20260101a'
$fileB = Join-Path $groupB 'bin\claude.exe.restoring.abcd1234'
$filePkg = Join-Path $groupA 'package.json'
foreach ($f in @($fileA, $fileB)) {
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $f) -Force)
    [System.IO.File]::WriteAllText($f, 'fake leftover', (New-Object System.Text.UTF8Encoding($false)))
}
[System.IO.File]::WriteAllText($filePkg, '{"name":".claude-code-fake01"}', (New-Object System.Text.UTF8Encoding($false)))

Write-Host ('  假环境：' + $work)
Write-Host ''

# ---------------------------------------------------------------- 记录本机真实状态
$realRoots = @()
if ($env:APPDATA) { $realRoots += (Join-Path $env:APPDATA 'npm\node_modules') }
if ($env:USERPROFILE) { $realRoots += (Join-Path $env:USERPROFILE '.local\bin') }
$realBefore = @()
foreach ($r in $realRoots) {
    if (Test-Path -LiteralPath $r) {
        $realBefore += @(Get-ChildItem -LiteralPath $r -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName })
    }
}
$realPathBefore = (Get-ItemProperty 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path

$savedEnv = @{ APPDATA = $env:APPDATA; USERPROFILE = $env:USERPROFILE; LOCALAPPDATA = $env:LOCALAPPDATA }

# 引擎在子进程里跑；子进程继承环境变量，所以这里临时改、跑完还原。
# 注意：PS 5.1 跑在 .NET Framework 上，ProcessStartInfo 没有 ArgumentList（那是 .NET Core 才有的），
# 所以走 Start-Process + 输出重定向到文件这条路（本仓库其它测试也是这么做的）。
function Invoke-Engine {
    param([string[]]$ExtraArgs)
    $env:APPDATA = $fakeAppData
    $env:USERPROFILE = $fakeUserProfile
    $env:LOCALAPPDATA = $fakeLocalAppData
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $o = Join-Path $work ('out-' + $tag + '.txt')
    $e = Join-Path $work ('err-' + $tag + '.txt')
    try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $setup,
            '-SkipCheck', '-SkipDeps', '-StateDir', $fakeState, '-NoColor') + $ExtraArgs
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
            -RedirectStandardOutput $o -RedirectStandardError $e -PassThru -NoNewWindow
        if (-not $p.WaitForExit(300000)) { $p.Kill(); $p.WaitForExit() }
        return [pscustomobject]@{
            exitCode = $p.ExitCode
            stdout   = ((@(Get-Content -LiteralPath $o -Encoding UTF8 -ErrorAction SilentlyContinue)) -join "`n")
            stderr   = ((@(Get-Content -LiteralPath $e -Encoding UTF8 -ErrorAction SilentlyContinue)) -join "`n")
        }
    } finally {
        $env:APPDATA = $savedEnv.APPDATA
        $env:USERPROFILE = $savedEnv.USERPROFILE
        $env:LOCALAPPDATA = $savedEnv.LOCALAPPDATA
    }
}

Write-Host '第一步：清理残留（真的执行）'
$r1 = Invoke-Engine -ExtraArgs @('-CleanOnly', '-OnlyTools', 'claude-code', '-Apply')
# 沙箱里 Process.ExitCode 可能读不到（本仓库多处遇到过）：读不到就如实记录，
# 结论以"有没有报错输出"和"实际效果"为准，而不是硬认退出码。
$rc1 = $r1.exitCode
$rcNote = if ($null -eq $rc1) { '退出码读不到（环境限制）' } else { '退出码 ' + $rc1 }
Check '清理命令没有报错' ((($null -eq $rc1) -or ($rc1 -eq 0)) -and [string]::IsNullOrWhiteSpace($r1.stderr)) ($rcNote + ' / stderr: ' + $r1.stderr.Trim())

Check '第一组已从原位置消失' (-not (Test-Path -LiteralPath $groupA)) $groupA
Check '第二组已从原位置消失' (-not (Test-Path -LiteralPath $groupB)) $groupB

# ---------------------------------------------------------------- 备份区
$backupRoot = Join-Path $fakeState 'backups'
$backupDirs = @()
if (Test-Path -LiteralPath $backupRoot) { $backupDirs = @(Get-ChildItem -LiteralPath $backupRoot -Directory) }
Check '备份区建立起来了' ($backupDirs.Count -ge 1) $backupRoot

$movedFiles = @()
foreach ($b in $backupDirs) {
    $movedFiles += @(Get-ChildItem -LiteralPath $b.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
}
Check '搬过去的是真文件，不是空目录' ($movedFiles.Count -ge 2) ('实际 ' + $movedFiles.Count + ' 个文件')

$hit = 0
foreach ($mf in $movedFiles) {
    try { if ([System.IO.File]::ReadAllText($mf.FullName) -eq 'fake leftover') { $hit++ } } catch { }
}
Check '搬过去的文件内容原样' ($hit -ge 2) ('实际 ' + $hit + ' 个')
Check '整目录搬走（package.json 也一起）' (@($movedFiles | Where-Object { $_.Name -eq 'package.json' }).Count -ge 1)

# ---------------------------------------------------------------- 会话日志
$sessionsDir = Join-Path $fakeState 'sessions'
$sessions = @()
if (Test-Path -LiteralPath $sessionsDir) {
    $sessions = @(Get-ChildItem -LiteralPath $sessionsDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
}
Check '留下了会话日志' ($sessions.Count -ge 1) $sessionsDir

$journalPath = ''
if ($sessions.Count -ge 1) {
    $journalPath = $sessions[0].FullName
    $doc = [System.IO.File]::ReadAllText($journalPath) | ConvertFrom-Json
    # 还原真正消费的是这几类搬移条目（*.backup / artifacts.move / conflict.move），
    # 而不是名字里带 backup 的任意条目 —— 断言要贴着还原的实现写，否则会误报。
    $moveActions = @('artifacts.move', 'conflict.move')
    $moveEntries = @($doc.entries | Where-Object {
            $moveActions -contains [string]$_.action -or [string]$_.action -like '*.backup'
        })
    Check '日志里记下了可还原的搬移条目' ($moveEntries.Count -ge 1) ('实际 ' + $moveEntries.Count)
    $usable = @($moveEntries | Where-Object {
            -not [string]::IsNullOrEmpty([string]$_.target) -and -not [string]::IsNullOrEmpty([string]$_.after)
        })
    Check '这些条目都带还原所需的 target 与 after' ($usable.Count -eq $moveEntries.Count) `
        ('可用 ' + $usable.Count + ' / ' + $moveEntries.Count)
    Check '日志标明这是真跑而不是演练' ($doc.dryRun -eq $false) ('dryRun=' + $doc.dryRun)
}

# ---------------------------------------------------------------- 还原
if ($journalPath) {
    Write-Host ''
    Write-Host '第二步：按日志还原（真的执行）'
    $r2 = Invoke-Engine -ExtraArgs @('-Restore', $journalPath, '-Apply')
    $rc2 = $r2.exitCode
    $rc2Note = if ($null -eq $rc2) { '退出码读不到（环境限制）' } else { '退出码 ' + $rc2 }
    Check '还原命令没有报错' ((($null -eq $rc2) -or ($rc2 -eq 0)) -and [string]::IsNullOrWhiteSpace($r2.stderr)) ($rc2Note + ' / stderr: ' + $r2.stderr.Trim())
    Check '第一组回到了原位置' (Test-Path -LiteralPath $fileA) $fileA
    Check '第二组回到了原位置' (Test-Path -LiteralPath $fileB) $fileB
    if (Test-Path -LiteralPath $fileA) {
        Check '还原后内容一致' ([System.IO.File]::ReadAllText($fileA) -eq 'fake leftover')
    }
    Check 'package.json 也回来了' (Test-Path -LiteralPath $filePkg) $filePkg
}

# ---------------------------------------------------------------- 本机真实目录必须没动
Write-Host ''
Write-Host '第三步：核对本机真实目录'
$realAfter = @()
foreach ($r in $realRoots) {
    if (Test-Path -LiteralPath $r) {
        $realAfter += @(Get-ChildItem -LiteralPath $r -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName })
    }
}
$diff = @(Compare-Object $realBefore $realAfter)
Check '本机真实产物目录未被改动' ($diff.Count -eq 0) ('差异 ' + $diff.Count + ' 项')
$realPathAfter = (Get-ItemProperty 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
Check '用户 PATH 未被改动' ($realPathBefore -eq $realPathAfter)

# ---------------------------------------------------------------- 收尾
try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ('  ' + ('-' * 62))
Write-Host ('通过 ' + $pass + ' 项，失败 ' + $fail + ' 项')
if ($fail -gt 0) { exit 1 }
exit 0
