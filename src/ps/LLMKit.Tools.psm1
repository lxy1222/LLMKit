#Requires -Version 5.1
<#
    LLMKit 工具安装层（M2）
    ------------------------------------------------------------------
    负责 5 个目标工具的安装与修复：Claude Code / cc-switch / Codex /
    OpenCode / Gemini CLI。依赖 LLMKit.psm1（检测）与 LLMKit.Install.psm1（安装原语）。

    三条不可退让的规则：
      1. 只搬不删。残留清理、冲突清理都是"挪到备份区"，永远不删除用户的东西。
      2. 危险动作必须显式开启。-CleanArtifacts / -ResolveConflicts 不给就不做，
         只在计划里标出来告诉用户"这里有东西需要处理"。
      3. 官方脚本先落地再执行。不把远程脚本直接管道进 iex —— 那样用户和我们
         都无法审计到底跑了什么。下载后记录大小与 SHA256，再以文件方式执行。

    这些规则针对的正是真实世界里最常见的两类事故：把用户数据当垃圾删掉，
    以及在不该动手的时候动了手。
#>

Set-StrictMode -Off

$script:ToolsVersion = '0.1.0'
$script:MaxErrorTextLength = 300

# 依赖的两个模块由调用方（Setup-LLMKit.ps1）负责导入。
# 这里只做存在性检查，避免"函数名打错"变成难查的运行时错误。
function Assert-LLMKitPrerequisites {
    $missing = New-Object System.Collections.ArrayList
    foreach ($fn in @('Find-InstallArtifacts', 'Get-MirrorCandidates', 'Invoke-DownloadWithMirrors',
            'Install-PortableItem', 'Resolve-ItemDownload', 'Add-JournalEntry', 'New-InstallSession',
            'Add-EntriesToUserPath', 'Remove-EntriesFromUserPath', 'Write-JsonFile', 'Read-TextFileUtf8', 'Invoke-Process',
            'Resolve-ExecutablePath', 'Get-UserPathInfo', 'Get-InstallErrorHint')) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) { [void]$missing.Add($fn) }
    }
    if ($missing.Count -gt 0) {
        throw ('缺少前置模块函数：' + ($missing -join '、') + '。请先 Import-Module LLMKit.psm1 与 LLMKit.Install.psm1。')
    }
}

function Get-LLMKitToolsVersion { $script:ToolsVersion }

function Get-ToolCatalog {
    <# 读取 tools.json 与 providers.json #>
    param([string]$ConfigRoot)
    if ([string]::IsNullOrEmpty($ConfigRoot)) {
        $here = $PSScriptRoot
        $ConfigRoot = Split-Path -Parent (Split-Path -Parent $here)
    }
    $toolsPath = Join-Path $ConfigRoot 'config\tools.json'
    $providersPath = Join-Path $ConfigRoot 'config\providers.json'
    if (-not (Test-Path -LiteralPath $toolsPath)) { throw ('找不到工具配置：' + $toolsPath) }
    $tools = Read-TextFileUtf8 -Path $toolsPath | ConvertFrom-Json
    $providers = $null
    if (Test-Path -LiteralPath $providersPath) {
        try { $providers = Read-TextFileUtf8 -Path $providersPath | ConvertFrom-Json } catch { $providers = $null }
    }
    return [pscustomobject]@{ configRoot = $ConfigRoot; tools = $tools; providers = $providers }
}

function Get-ProviderCatalog {
    param([string]$ConfigRoot)
    $cat = Get-ToolCatalog -ConfigRoot $ConfigRoot
    if (-not $cat.providers) { return @() }
    return @($cat.providers.providers)
}

function Show-ProviderGuidance {
    <#
        渠道跳转引导。
        合规要求（决策 D5）：只提供"注册/领 key 的页面链接"，不内置、不代发、不代充任何 key。
        默认只打印链接，必须显式 -Open 才会打开浏览器。
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigRoot,
        [string[]]$ProviderId = @(),
        [switch]$Open,
        [switch]$NoColor
    )
    $all = @(Get-ProviderCatalog -ConfigRoot $ConfigRoot)
    if ($all.Count -eq 0) { throw 'providers.json 里没有渠道配置。' }
    $list = $all
    if ($ProviderId.Count -gt 0) {
        $list = @($all | Where-Object { $ProviderId -contains $_.id })
        if ($list.Count -eq 0) {
            throw ('没有匹配的渠道：' + ($ProviderId -join '、') + '。可用：' + (($all | ForEach-Object { $_.id }) -join '、'))
        }
    }
    $say = {
        param($text, $color)
        if (-not $NoColor) { try { Write-Host $text -ForegroundColor $color; return } catch { } }
        try { Write-Host $text } catch { [Console]::Out.WriteLine([string]$text) }
    }
    $opened = New-Object System.Collections.ArrayList
    foreach ($p in $list) {
        & $say '' 'Gray'
        & $say ('【' + $p.name + '】' + $(if ($p.region -eq 'cn') { '（国内直连）' } else { '（境外）' })) 'White'
        if ($p.tags) { & $say ('  特点：' + ($p.tags -join ' / ')) 'DarkGray' }
        if ($p.freeQuota) { & $say ('  免费额度：' + $p.freeQuota) 'DarkGray' }
        $need = New-Object System.Collections.ArrayList
        if ($p.needsRealName) { [void]$need.Add('需要实名认证') }
        if ($p.needsCreditCard) { [void]$need.Add('需要信用卡') }
        if ($need.Count -gt 0) { & $say ('  门槛：' + ($need -join '、')) 'Yellow' }
        & $say ('  注册/登录：' + $p.registerUrl) 'Cyan'
        if ($p.keyUrl) { & $say ('  创建 API Key：' + $p.keyUrl) 'Cyan' }
        if ($p.anthropicBaseUrl) { & $say ('  Claude Code 用 base_url：' + $p.anthropicBaseUrl) 'DarkGray' }
        if ($p.openaiBaseUrl) { & $say ('  其他工具用 base_url：' + $p.openaiBaseUrl) 'DarkGray' }
        if ($p.models) { & $say ('  常用模型：' + ($p.models -join ', ')) 'DarkGray' }
        if ($p.verified -eq $false) { & $say '  注意：该渠道的 base_url 与模型名尚未在本机实测，写入配置前会先做真实连通性验证。' 'Yellow' }
        if ($Open) {
            foreach ($u in @($p.registerUrl, $p.keyUrl)) {
                if ([string]::IsNullOrWhiteSpace($u)) { continue }
                try {
                    Start-Process $u | Out-Null
                    [void]$opened.Add($u)
                    & $say ('  → 已打开浏览器：' + $u) 'Green'
                } catch {
                    & $say ('  → 打开浏览器失败，请手动访问：' + $u) 'Yellow'
                }
                break   # 一次只开一个页面，避免一口气弹出好几个标签页
            }
        }
    }
    & $say '' 'Gray'
    if (-not $Open) {
        & $say '以上只是链接。加 -Open 可以让工具直接帮你打开注册与创建 Key 的页面。' 'DarkGray'
        & $say '本工具不会内置、代发或代充任何 API Key —— key 始终由你自己创建和保管。' 'DarkGray'
    }
    return [pscustomobject]@{ providers = @($list); opened = @($opened) }
}

# ======================================================================
#  残留清理与冲突处理
# ======================================================================

function Move-ArtifactsToBackup {
    <#
        把安装残留按"组"整体挪到备份区。
        按组而不是按文件：同一个安装器工作目录下的多个残留一起搬，既避免留下空目录，
        也避免搬到一半失败造成的半清理状态。
    #>
    param(
        [Parameter(Mandatory = $true)]$Groups,
        [Parameter(Mandatory = $true)]$Session,
        [string[]]$ProtectedNames = @(),
        [switch]$Apply
    )
    $out = New-Object System.Collections.ArrayList
    $index = 0
    foreach ($g in @($Groups)) {
        $index++
        $src = [string]$g.dir
        $exists = (-not [string]::IsNullOrEmpty($src)) -and (Test-Path -LiteralPath $src)

        # 保护性检查：整组搬走的前提是"这一组全是残渣"。
        # 如果里面躺着一个看起来正常的可执行入口（不是 .old./.restoring. 那种），
        # 说明判断错了 —— 宁可不清理，也不能把用户能用的安装搬走。
        $protected = New-Object System.Collections.ArrayList
        if ($exists -and (Test-Path -LiteralPath $src -PathType Container) -and @($ProtectedNames).Count -gt 0) {
            # 必须递归找：程序实际在 bin\ 这类子目录里，
            # 只看组目录顶层会漏掉，结果就是把能用的安装当残渣搬走（踩过）。
            $artifactFilePattern = '\.(old|restoring|tmp|partial|bak|new)\.[0-9a-fA-F]{4,}$'
            try {
                $files = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -notmatch $artifactFilePattern })
                foreach ($f in $files) {
                    $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                    foreach ($pn in @($ProtectedNames)) {
                        if ([string]::IsNullOrEmpty($pn)) { continue }
                        if ($base -ieq $pn -or $f.Name -ieq $pn) {
                            [void]$protected.Add($f.FullName.Substring($src.Length).TrimStart('\'))
                            break
                        }
                    }
                }
            } catch { }
        }
        if ($protected.Count -gt 0) {
            Add-JournalEntry -Session $Session -Action 'artifacts.skip' -Target $src `
                -Note ('组内发现疑似可用的程序（' + ($protected -join '、') + '），判定为不是残渣，跳过清理') -Status 'skipped'
            [void]$out.Add([pscustomobject]([ordered]@{
                        source = $src; destination = ''; exists = $exists; moved = $false
                        skipped = $true; protectedNames = @($protected); error = ''
                        memberCount = @($g.members).Count
                    }))
            continue
        }
        $leaf = ''
        if ($src) { $leaf = Split-Path -Leaf $src }
        $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
        $dest = Join-Path (Join-Path $Session.backupDir 'artifacts') ($stamp + '_' + $index + '_' + $leaf)
        $record = [pscustomobject]([ordered]@{
                source = $src; destination = $dest; exists = $exists
                moved = $false; skipped = $false; protectedNames = @()
                error = ''; memberCount = @($g.members).Count
            })
        if ($exists -and $Apply) {
            try {
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force)
                Move-Item -LiteralPath $src -Destination $dest -Force
                $record.moved = $true
            } catch {
                $record.error = Get-ShortErrorText -Text $_.Exception.Message
            }
        }
        Add-JournalEntry -Session $Session -Action 'artifacts.move' -Target $src -Before $src -After $dest `
            -Note ('残留清理（' + $record.memberCount + ' 项同组）' + $(if ($Apply) { '' } else { ' · 演练未执行' })) `
            -Status $(if ($Apply -and -not $record.moved -and $exists) { 'failed' } else { 'done' })
        [void]$out.Add($record)
    }
    return @($out)
}

  # 反推"整份安装"该怎么搬。三种结论：
  #   dir     —— 目录是单一用途的安装目录，整份搬走
  #   partial —— 目录里混着别的东西（实测有台机器的 D:\Program Files\Python 里放着 ChatGPT-main 和 log），
  #              只搬"明显属于这套运行时"的条目，用户的东西一个不动
  #   refuse  —— 认不出来，什么都不搬，把原因交出去
  function Get-ConflictMovePlan {
      param([string]$FilePath, [string[]]$ExeNames = @())

      $out = [ordered]@{ kind = 'refuse'; root = ''; entries = @(); reason = '' }
      $parent = ''
      try { $parent = [System.IO.Path]::GetDirectoryName($FilePath) } catch { }
      if ([string]::IsNullOrEmpty($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
          $out.reason = '找不到它所在的目录'
          return [pscustomobject]$out
      }

      $pn = $parent.TrimEnd('\').ToLowerInvariant()
      $forbidden = @(
          ('C:\Windows'),
          ('C:\Windows\System32'),
          (($env:LOCALAPPDATA + '\Microsoft\WindowsApps')),
          ($env:USERPROFILE),
          ($env:ProgramFiles),
          ([string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion' -Name 'ProgramFilesDir' -ErrorAction SilentlyContinue).ProgramFilesDir)
      ) | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\').ToLowerInvariant() }
      if ($forbidden -contains $pn) { $out.reason = '它在系统目录里，不动'; return [pscustomobject]$out }
      if ($pn -match '^[a-z]:\\?$') { $out.reason = '它直接在盘符根下，不动'; return [pscustomobject]$out }
      if ((Split-Path -Leaf $parent) -match '^(bin|scripts|cmd)$') {
          $out.reason = '它在一个 bin/scripts 目录里，真正的安装根不敢猜'
          return [pscustomobject]$out
      }

      $allowedDir = @('dlls', 'doc', 'docs', 'include', 'lib', 'libs', 'scripts', 'tcl', 'tools', 'bin', 'conf', 'etc',
          'share', 'licenses', 'site-packages', 'locale', 'resources')
      $allowedFile = @('^license', '^news', '^readme', '^python', '^pip', '^py\.', '^vcruntime', '^ucrtbase',
          '\.dll$', '\.exe$', '\.pdb$', '\.txt$', '\.cat$', '\.cfg$', '\.ini$', '\.zip$', '\.whl$')

      $entries = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)
      if ($entries.Count -eq 0) { $out.reason = '目录是空的'; return [pscustomobject]$out }

      $hasExe = $false
      foreach ($en in @($ExeNames | Where-Object { $_ })) {
          if (Test-Path -LiteralPath (Join-Path $parent $en) -PathType Leaf) { $hasExe = $true; break }
      }
      if (-not $hasExe -and @($entries | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.exe' }).Count -gt 0) { $hasExe = $true }
      $hasLib = (Test-Path -LiteralPath (Join-Path $parent 'Lib') -PathType Container) -or
      (Test-Path -LiteralPath (Join-Path $parent 'DLLs') -PathType Container)
      if (-not $hasExe -or -not $hasLib) {
          $out.reason = '它看起来不像一份完整的安装（缺可执行文件或 Lib/DLLs）'
          return [pscustomobject]$out
      }

      $mine = New-Object System.Collections.ArrayList
      $others = New-Object System.Collections.ArrayList
      foreach ($e in $entries) {
          $nm = $e.Name.ToLowerInvariant()
          $isMine = $false
          if ($e.PSIsContainer) {
              if ($allowedDir -contains $nm) { $isMine = $true }
              elseif ($nm -match '^python') { $isMine = $true }
          } else {
              foreach ($pat in $allowedFile) { if ($nm -match $pat) { $isMine = $true; break } }
          }
          if ($isMine) { [void]$mine.Add($e.Name) } else { [void]$others.Add($e.Name) }
      }

      $out.root = $parent
      if ($others.Count -eq 0 -and $mine.Count -eq $entries.Count) {
          $out.kind = 'dir'
          return [pscustomobject]$out
      }
      $out.kind = 'partial'
      $out.entries = @($mine)
      $out.reason = '这个目录里还有不属于它的东西（' + (($others | Select-Object -First 3) -join '、') +
      $(if ($others.Count -gt 3) { ' 等' } else { '' }) + '），只搬属于它自己的 ' + $mine.Count + ' 项'
      return [pscustomobject]$out
  }

  function Resolve-ToolConflict {
      <#
          处理同一个工具存在多份安装的情况：保留 PATH 实际命中的那一份，其余挪到备份区（绝不删除）。

          三次真机教训都写进这里了：
            1. 文件型命中（…\Python312\python.exe）要往上找"整份安装"再搬，只搬 shim 没有意义；
            2. 目录里混着用户数据时不能整体放弃，也不能整体搬走 —— 只搬属于这套运行时的条目；
            3. 跨卷搬目录必须用 robocopy /MOVE 并检查退出码，失败要回滚。
               以前用 Move-Item：搬到一半被拒，留下"半份安装"（python.exe 走了、Lib 还在），
               比什么都不做更糟，而且上层还把它记成"成功"。
      #>
      param(
          [Parameter(Mandatory = $true)]$ToolStatus,
          [Parameter(Mandatory = $true)]$Session,
          [string]$KeepPath,
          [string[]]$ExeNames = @(),
          [switch]$Apply
      )
      $instances = @($ToolStatus.installations | Where-Object { @('path', 'file', 'install-dir') -contains $_.kind })
      if ($instances.Count -le 1) { return @() }

      $keep = $KeepPath
      if ([string]::IsNullOrEmpty($keep)) {
          $pathHit = @($instances | Where-Object { $_.kind -eq 'path' } | Select-Object -First 1)
          if ($pathHit.Count -gt 0) { $keep = [string]$pathHit[0].path }
          else { $keep = [string]$instances[0].path }
      }
      $keepRoot = ''
      try { $keepRoot = [System.IO.Path]::GetDirectoryName($keep) } catch { }

      $out = New-Object System.Collections.ArrayList
      $index = 0
      foreach ($inst in $instances) {
          $src = [string]$inst.path
          if ($src.ToLowerInvariant() -eq $keep.ToLowerInvariant()) { continue }
          $index++

          $isDir = (Test-Path -LiteralPath $src -PathType Container)
          $plan = $null
          if ($isDir) {
              $plan = [pscustomobject]@{ kind = 'dir'; root = $src; entries = @(); reason = '' }
          } else {
              $plan = Get-ConflictMovePlan -FilePath $src -ExeNames $ExeNames
          }

          if ($plan.kind -eq 'refuse') {
              Add-JournalEntry -Session $Session -Action 'conflict.manual' -Target $src -Note ('未处理：' + $plan.reason + '；保留 ' + $keep) -Status 'skipped'
              [void]$out.Add([pscustomobject]@{ source = $src; destination = ''; action = 'manual'; kept = $keep; moved = $false; reason = $plan.reason; pathEntries = @() })
              continue
          }
          if ($keepRoot -and $plan.root.ToLowerInvariant() -eq $keepRoot.ToLowerInvariant()) {
              Add-JournalEntry -Session $Session -Action 'conflict.manual' -Target $src -Note '与保留的那份在同一个目录，跳过' -Status 'skipped'
              [void]$out.Add([pscustomobject]@{ source = $src; destination = ''; action = 'manual'; kept = $keep; moved = $false; reason = '与保留的那份在同一个安装目录里'; pathEntries = @() })
              continue
          }

          $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
          $dest = Join-Path (Join-Path $Session.backupDir 'conflicts') ($stamp + '_' + $index + '_' + (Split-Path -Leaf $plan.root))
          $record = [pscustomobject]@{
              source = $src; destination = $dest; action = 'move-to-backup'; kept = $keep
              moved = $false; reason = $plan.reason; pathEntries = @(); movedRoot = $plan.root; mode = $plan.kind
          }

          if ($plan.kind -eq 'dir') {
              if ($Apply) {
                  [void](New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force)
                  # robocopy /MOVE：先复制再删源；退出码 < 8 才算成功
                  $null = & robocopy $plan.root $dest /E /MOVE /R:1 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1
                  $code = $LASTEXITCODE
                  if ($code -lt 8) {
                      $record.moved = $true
                  } else {
                      $record.reason = 'robocopy 退出码 ' + $code + '（搬运未完成）'
                      if (Test-Path -LiteralPath $dest) {
                          $null = & robocopy $dest $plan.root /E /MOVE /R:1 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1
                          if ($LASTEXITCODE -lt 8) { $record.reason = $record.reason + '；已回滚到原样' }
                          else { $record.reason = $record.reason + '；回滚也失败，备份留在 ' + $dest }
                      }
                  }
              }
          } else {
              # 混合目录：只搬属于它的条目，用户的东西一个不动
              if ($Apply) {
                  [void](New-Item -ItemType Directory -Path $dest -Force)
                  $okCount = 0
                  $failList = New-Object System.Collections.ArrayList
                  foreach ($nm in @($plan.entries)) {
                      $s2 = Join-Path $plan.root $nm
                      if (-not (Test-Path -LiteralPath $s2)) { continue }
                      try {
                          Move-Item -LiteralPath $s2 -Destination (Join-Path $dest $nm) -Force -ErrorAction Stop
                          $okCount++
                      } catch { [void]$failList.Add($nm + '：' + (Get-ShortErrorText -Text $_.Exception.Message)) }
                  }
                  $record.moved = ($okCount -gt 0 -and $failList.Count -eq 0)
                  if ($failList.Count -gt 0) {
                      $record.reason = $record.reason + '；其中 ' + $failList.Count + ' 项没搬成：' + (($failList | Select-Object -First 2) -join ' / ')
                  }
              }
          }

          $noteTail = ''
          if ($record.reason) { $noteTail = ' · ' + $record.reason }
          if ($Apply) {
              $journalStatus = 'failed'
              if ($record.moved) { $journalStatus = 'done' }
              Add-JournalEntry -Session $Session -Action 'conflict.move' -Target $plan.root -Before $plan.root -After $dest -Note ('多份安装冲突：保留 ' + $keep + $noteTail) -Status $journalStatus
          } else {
              Add-JournalEntry -Session $Session -Action 'conflict.move' -Target $plan.root -Before $plan.root -After $dest -Note ('多份安装冲突：保留 ' + $keep + ' · 演练未执行' + $noteTail) -Status 'done'
          }

          # 指向被搬走目录的用户 PATH 条目顺手清掉：留着就是死路径
          if ($record.moved -or -not $Apply) {
              $hitEntries = New-Object System.Collections.ArrayList
              $uinfo = Get-UserPathInfo
              if ($uinfo.available) {
                  foreach ($pe in @(Get-PathEntryList -PathValue ([string]$uinfo.value))) {
                      $pl = $pe.TrimEnd('\').ToLowerInvariant()
                      $rl = $plan.root.TrimEnd('\').ToLowerInvariant()
                      if ($pl -eq $rl -or $pl.StartsWith($rl + '\')) { [void]$hitEntries.Add($pe) }
                  }
              }
              if ($hitEntries.Count -gt 0) {
                  $pr = Remove-EntriesFromUserPath -Entries @($hitEntries) -Session $Session -Apply:$Apply
                  $record.pathEntries = @($hitEntries)
                  if ($Apply -and $pr.error) {
                      Add-JournalEntry -Session $Session -Action 'path.remove' -Target (@($hitEntries) -join ' ; ') -Status 'failed' -Note ([string]$pr.error)
                  }
              }
          }
          [void]$out.Add($record)
      }
      return @($out)
  }

# ======================================================================
#  两种新的安装方式
# ======================================================================

function Install-ScriptItem {
    <#
        官方一键脚本（powershell-pipe）。
        不做 "irm ... | iex"：先把脚本下载到本地，记录来源、大小、SHA256，再以文件方式执行。
        这样用户和我们都看得到到底跑了什么，出问题也能拿到脚本原文去核对。
    #>
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$Session,
        [string]$CacheDir,
        [string]$Proxy,
        [switch]$Apply
    )
    $res = [ordered]@{ ok = $false; error = ''; installedTo = ''; version = ''; scriptPath = ''; sha256 = ''; sizeBytes = 0; scriptExitCode = $null; steps = @() }
    $steps = New-Object System.Collections.ArrayList
    $tier = $Item.tier
    $url = [string]$tier.scriptUrl

    if ([string]::IsNullOrWhiteSpace($url)) {
        $m = [regex]::Match([string]$tier.command, 'https://[^\s''"]+')
        if ($m.Success) { $url = $m.Value }
    }
    if ([string]::IsNullOrWhiteSpace($url)) {
        $res.error = 'tier 里没有 scriptUrl，无法定位官方安装脚本。'
        return [pscustomobject]$res
    }
    if ([string]::IsNullOrEmpty($CacheDir)) { $CacheDir = Join-Path $env:LOCALAPPDATA 'LLMKit\cache' }
    $scriptPath = Join-Path $CacheDir ($Item.id + '-install.ps1')
    $res.scriptPath = $scriptPath

    if (-not $Apply) {
        [void]$steps.Add('演练：将下载官方脚本 ' + $url + ' 到 ' + $scriptPath + '，记录 SHA256 后以 -ExecutionPolicy Bypass 执行')
        [void]$steps.Add('演练：执行完成后验证 ' + [string]$tier.verifyExecutable)
        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.plan') -Target $url -Note ('DryRun 计划：下载官方脚本并执行，脚本地址 ' + $url) -Status 'planned'
        $res.ok = $true
        $res.steps = @($steps)
        return [pscustomobject]$res
    }

    try {
        [void]$steps.Add('下载官方安装脚本：' + $url)
        $urls = @(Get-MirrorCandidates -Url $url -MirrorRewriters $Item.__mirrorRewriters)
        $down = Invoke-DownloadWithMirrors -Urls $urls -Destination $scriptPath -Proxy $Proxy
        if (-not $down.ok) {
            $firstErr = ''
            if ($down.attempts -and $down.attempts.Count -gt 0) { $firstErr = [string]$down.attempts[0].error }
            $hint = Get-InstallErrorHint -Message $firstErr
            $res.error = Get-ShortErrorText -Text ('下载官方脚本失败：' + $firstErr + $(if ($hint) { ' 可能的原因：' + $hint } else { '' }))
            Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.script-download') -Target $url -Status 'failed' -Note $res.error
            return [pscustomobject]$res
        }
        $res.sha256 = $down.sha256
        $res.sizeBytes = $down.bytes
        [void]$steps.Add('脚本已下载：' + (Format-ByteSize -Bytes $down.bytes) + ' / SHA256 ' + $down.sha256)
        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.script-download') -Target $scriptPath `
            -After ([ordered]@{ url = $down.url; bytes = $down.bytes; sha256 = $down.sha256 }) `
            -Note '官方安装脚本已落地（未经管道直接执行，先留档再跑）'

        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
        [void]$steps.Add('执行官方安装脚本（-NoProfile -ExecutionPolicy Bypass）')
        $run = Invoke-Process -FilePath $psExe -Arguments @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) -TimeoutMs 1800000
        $res.scriptExitCode = $run.exitCode
        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.script-run') -Target $scriptPath `
            -After ([ordered]@{ exitCode = $run.exitCode; ok = $run.ok }) `
            -Note (Get-ShortErrorText -Text ([string]$run.stdout + ' ' + [string]$run.stderr)) `
            -Status $(if ($run.ok) { 'done' } else { 'failed' })
        if ($run.stdout) { [void]$steps.Add('脚本输出：' + (Get-ShortErrorText -Text $run.stdout)) }
        if (-not $run.ok) {
            $msg = [string]$run.stdout + ' ' + [string]$run.stderr + ' ' + [string]$run.error
            $res.error = Get-ShortErrorText -Text ('官方安装脚本执行失败（退出码 ' + [string]$run.exitCode + '）：' + $msg)
            return [pscustomobject]$res
        }

        # 验证
        $exe = ''
        if ($tier.verifyExecutable) { $exe = [System.Environment]::ExpandEnvironmentVariables([string]$tier.verifyExecutable) }
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            $vArgs = @('--version')
            if ($tier.verifyArgs) { $vArgs = @($tier.verifyArgs) }
            $vr = Invoke-Process -FilePath $exe -Arguments $vArgs -TimeoutMs 60000
            $vtext = $vr.stdout
            if (-not $vtext) { $vtext = $vr.stderr }
            $res.version = $vtext
            $pattern = [string]$tier.verifyPattern
            $matched = $true
            if ($pattern) { $matched = ([string]$vtext -match $pattern) }
            if ($matched) {
                $res.installedTo = $exe
                [void]$steps.Add('试跑通过：' + $vtext)
            } else {
                $res.error = Get-ShortErrorText -Text ('脚本跑完了，但验证失败：' + $exe + ' 输出 [' + $vtext + ']')
                return [pscustomobject]$res
            }
        } else {
            [void]$steps.Add('脚本成功，但预期位置没有找到可执行文件：' + $exe + '（脚本可能装到了别处，请把这句话连同日志一起反馈）')
            $res.error = '安装脚本执行成功但未在预期位置找到程序，需要人工确认。'
            return [pscustomobject]$res
        }

        if ($tier.pathEntries) {
            $targets = @($tier.pathEntries | ForEach-Object { [System.Environment]::ExpandEnvironmentVariables([string]$_) })
            $pr = Add-EntriesToUserPath -Entries $targets -Session $Session -Apply:$true
            if ($pr.error) { [void]$steps.Add('PATH 写入失败：' + $pr.error) }
            elseif ($pr.changed) { [void]$steps.Add('PATH 已新增：' + ($pr.added -join ' , ')) }
        }
        $res.ok = $true
    } catch {
        $res.error = Get-ShortErrorText -Text $_.Exception.Message
        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.error') -Target $scriptPath -Status 'failed' -Note $res.error
    }
    $res.steps = @($steps)
    return [pscustomobject]$res
}

function Install-NpmItem {
    <#
        npm 全局安装。
        处理了三类真实失败：Node 版本不够、npm 全局目录不可写、npm 官方源不通。
        其中"不可写"会自动把 prefix 改到用户目录并记进 journal（可回滚），
        因为这是新手电脑上最常见的拦路虎，而它完全不需要管理员权限就能解决。
    #>
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$Session,
        [string]$Proxy,
        $NpmRegistryPrimary,
        $NpmRegistryMirrors,
        [switch]$Apply
    )
    $res = [ordered]@{
        ok = $false; error = ''; installedTo = ''; version = ''; npmPrefix = ''
        registryUsed = ''; prefixFixed = $false; steps = @()
    }
    $steps = New-Object System.Collections.ArrayList
    $tier = $Item.tier
    $pkg = [string]$tier.package

    $nodePath = Resolve-ExecutablePath -Name 'node'
    $npmPath = Resolve-ExecutablePath -Name 'npm'
    if (-not $npmPath) {
        $res.error = '没有找到 npm，无法用 npm 方式安装。请先安装 Node.js（也可以改用其他安装层）。'
        return [pscustomobject]$res
    }

    if ($tier.needsNode -or $tier.minNodeMajor) {
        $minMajor = 18
        if ($tier.minNodeMajor) { $minMajor = [int]$tier.minNodeMajor }
        if (-not $nodePath) {
            $res.error = ('该安装方式需要 Node.js ' + $minMajor + ' 以上，但当前没检测到 node。请先完成依赖安装。')
            return [pscustomobject]$res
        }
        $nv = Invoke-Process -FilePath $nodePath -Arguments @('-v') -TimeoutMs 15000
        $nver = ($nv.stdout -split "`n")[0].Trim()
        $m = [regex]::Match($nver, 'v?(\d+)\.')
        if ($m.Success -and [int]$m.Groups[1].Value -lt $minMajor) {
            $res.error = ('Node.js 版本过低（' + $nver + '），需要 v' + $minMajor + ' 以上。请先升级 Node.js。')
            return [pscustomobject]$res
        }
        [void]$steps.Add('Node.js 版本检查通过：' + $nver)
    }

    # npm 全局目录
    $prefixRun = Invoke-Process -FilePath $npmPath -Arguments @('prefix', '-g') -TimeoutMs 30000
    $npmPrefix = ''
    if ($prefixRun.stdout) {
        $lines = @($prefixRun.stdout -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -gt 0) { $npmPrefix = $lines[$lines.Count - 1].Trim() }
    }
    $res.npmPrefix = $npmPrefix
    $fallbackPrefix = Join-Path $env:APPDATA 'npm'
    $prefixWritable = $false
    if ($npmPrefix -and (Test-Path -LiteralPath $npmPrefix)) {
        $probe = Join-Path $npmPrefix ('.llmkit-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try { [System.IO.File]::WriteAllText($probe, 'x'); $prefixWritable = $true } catch { $prefixWritable = $false }
        finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } }
    }

    if (-not $prefixWritable) {
        [void]$steps.Add('npm 全局目录不可写（' + $npmPrefix + '），将把 prefix 改到用户目录：' + $fallbackPrefix)
        Add-JournalEntry -Session $Session -Action 'npm.prefix.set' -Target 'npm config prefix' -Before $npmPrefix -After $fallbackPrefix `
            -Note 'npm 全局目录不可写，改到用户目录（免管理员）' -Status $(if ($Apply) { 'done' } else { 'planned' })
        if ($Apply) {
            $setRun = Invoke-Process -FilePath $npmPath -Arguments @('config', 'set', 'prefix', $fallbackPrefix) -TimeoutMs 60000
            if (-not $setRun.ok) {
                $res.error = Get-ShortErrorText -Text ('无法修改 npm prefix：' + [string]$setRun.stderr + ' ' + [string]$setRun.error)
                return [pscustomobject]$res
            }
            $res.prefixFixed = $true
        }
        # 无论是否真的执行，后续所有路径都必须按"改完之后"来算。
        # 之前只在 Apply 分支里更新，导致演练给出的验证路径是改完就不存在的旧路径，
        # 看着像工具 bug，实际是"计划"和"执行"讲了两份不同的事实。
        $npmPrefix = $fallbackPrefix
        $res.npmPrefix = $npmPrefix
        if ($Apply) { [void]$steps.Add('npm prefix 已改为：' + $npmPrefix) }
    }

    if (-not $Apply) {
        [void]$steps.Add('演练：将执行 npm install -g ' + $pkg)
        [void]$steps.Add('演练：安装后验证 ' + (Join-Path $npmPrefix ((Split-Path -Leaf $Item.commands[0]) + '.cmd')))
        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.plan') -Target $pkg -Note ('DryRun 计划：npm install -g ' + $pkg + '，prefix=' + $npmPrefix) -Status 'planned'
        $res.ok = $true
        $res.steps = @($steps)
        return [pscustomobject]$res
    }

    $registries = New-Object System.Collections.ArrayList
    if ($NpmRegistryPrimary) { [void]$registries.Add([string]$NpmRegistryPrimary) }
    foreach ($r in @($NpmRegistryMirrors)) { if ($r) { [void]$registries.Add([string]$r) } }
    if ($registries.Count -eq 0) { [void]$registries.Add('https://registry.npmjs.org') }

    $lastErr = ''
    foreach ($reg in $registries) {
        [void]$steps.Add('尝试源：' + $reg)
        $args = @('install', '-g', $pkg, '--registry', $reg, '--no-fund', '--no-audit')
        if ($Proxy) { $args += @('--proxy', $Proxy, '--https-proxy', $Proxy) }
        $run = Invoke-Process -FilePath $npmPath -Arguments $args -TimeoutMs 1800000
        Add-JournalEntry -Session $Session -Action ('install.' + $Item.id + '.npm') -Target $pkg `
            -After ([ordered]@{ registry = $reg; exitCode = $run.exitCode; ok = $run.ok }) `
            -Note (Get-ShortErrorText -Text ([string]$run.stdout + ' ' + [string]$run.stderr)) `
            -Status $(if ($run.ok) { 'done' } else { 'failed' })
        if ($run.ok) {
            $res.registryUsed = $reg
            [void]$steps.Add('安装成功（源：' + $reg + '）')
            break
        }
        $lastErr = [string]$run.stderr + ' ' + [string]$run.stdout + ' ' + [string]$run.error
        [void]$steps.Add('该源失败，换下一个')
    }
    if (-not $res.registryUsed) {
        $hint = Get-InstallErrorHint -Message $lastErr
        $res.error = Get-ShortErrorText -Text ('npm 安装失败：' + $lastErr + $(if ($hint) { ' 可能的原因：' + $hint } else { '' }))
        return [pscustomobject]$res
    }

    # 验证
    $cmdName = $Item.commands[0]
    $candidates = @(
        (Join-Path $npmPrefix ($cmdName + '.cmd')),
        (Join-Path $npmPrefix ($cmdName + '.exe')),
        (Join-Path $npmPrefix $cmdName)
    )
    $exe = ''
    foreach ($cand in $candidates) { if (Test-Path -LiteralPath $cand) { $exe = $cand; break } }
    if (-not $exe) {
        $res.error = Get-ShortErrorText -Text ('安装命令返回成功，但在 ' + $npmPrefix + ' 下找不到 ' + $cmdName + ' 的可执行入口。')
        return [pscustomobject]$res
    }
    $vr = Invoke-Process -FilePath $exe -Arguments @('--version') -TimeoutMs 120000
    $vtext = $vr.stdout
    if (-not $vtext) { $vtext = $vr.stderr }
    $res.version = $vtext
    $res.installedTo = $exe
    if (-not $vtext) {
        $res.error = Get-ShortErrorText -Text ('安装完成但无法读取版本：' + [string]$vr.error)
        return [pscustomobject]$res
    }
    [void]$steps.Add('试跑通过：' + $vtext)

    $pr = Add-EntriesToUserPath -Entries @($npmPrefix) -Session $Session -Apply:$true
    if ($pr.error) { [void]$steps.Add('PATH 写入失败：' + $pr.error) }
    elseif ($pr.changed) { [void]$steps.Add('PATH 已新增：' + ($pr.added -join ' , ')) }

    $res.ok = $true
    $res.steps = @($steps)
    return [pscustomobject]$res
}

function Get-DefaultArtifactRoots {
    <# 安装残留的默认扫描根。集中一处，免得三个模块各写一份慢慢走偏 #>
    $roots = New-Object System.Collections.ArrayList
    if ($env:APPDATA) { [void]$roots.Add((Join-Path $env:APPDATA 'npm\node_modules')) }
    if ($env:USERPROFILE) { [void]$roots.Add((Join-Path $env:USERPROFILE '.local\bin')) }
    return @($roots)
}

function Get-LLMKitToolArtifacts {
    <# 只取属于某个工具的残留组：每个工具页要单独展示与清理自己那一份 #>
    param([string]$ToolId, [string[]]$Roots, [int]$MaxDepth = 3)
    if (-not $Roots -or $Roots.Count -eq 0) { $Roots = @(Get-DefaultArtifactRoots) }
    $scan = Find-InstallArtifacts -Roots $Roots -MaxDepth $MaxDepth
    return @($scan.groups | Where-Object { (Get-ArtifactOwnerToolId -Group $_) -eq $ToolId })
}

function Uninstall-LLMKitTool {
    <#
        卸载一个工具：安装本体、它加进 PATH 的条目、它的安装残留，一起处理掉。

        三条与安装时一致的原则：
          1. 只搬不删 —— 一切都挪到备份区，journal 留痕，Restore-LLMKitSession 可整体还原
          2. 先演练 —— 不加 -Apply 只列计划
          3. 用户配置默认不动 —— ~/.claude/settings.json 这类含你 API 配置的文件保留，
             要一起清掉必须显式 -RemoveUserConfig

        与"残留清理"的区别：残留清理带保护性检查（组里有能跑的程序就跳过），
        而卸载是用户明确要求删掉这个工具，所以不再做那个保护 —— 否则卸载会变成"什么也没干"。
    #>
    param(
        [Parameter(Mandatory = $true)]$Tool,
        $ToolStatus,
        $ArtifactGroups = @(),
        [Parameter(Mandatory = $true)]$Session,
        [switch]$RemoveUserConfig,
        [switch]$Apply
    )
    $steps = New-Object System.Collections.ArrayList
    $res = [ordered]@{
        ok = $false; error = ''; steps = @(); destRoot = ''
        movedInstalls = 0; pathRemoved = 0; artifactsMoved = 0; configMoved = 0
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destRoot = Join-Path $Session.backupDir ('uninstall-' + $stamp)
    $res.destRoot = $destRoot

    try {
        # ---- 1) 安装本体 ----
        $installs = @()
        if ($ToolStatus) {
            $installs = @($ToolStatus.installations | Where-Object {
                    @('path', 'file', 'install-dir', 'directory') -contains $_.kind
                })
        }
        # 去重：同一份安装常常既以"安装目录"出现、又以"目录里的 exe"出现。
        # 先搬父目录，子项就不该再单独搬一次（否则第二次会因路径不存在而报错）。
        $paths = @($installs | ForEach-Object { [string]$_.path } | Where-Object { $_ } | Sort-Object -Unique)
        $top = New-Object System.Collections.ArrayList
        foreach ($p in $paths) {
            $isChild = $false
            foreach ($q in $paths) {
                if ($p -eq $q) { continue }
                if ($p.StartsWith($q.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $isChild = $true; break }
            }
            if (-not $isChild) { [void]$top.Add($p) }
        }
        $idx = 0
        foreach ($src in $top) {
            $idx++
            $exists = Test-Path -LiteralPath $src
            if (-not $exists) {
                [void]$steps.Add('跳过（已不存在）：' + $src)
                continue
            }
            $dest = Join-Path $destRoot ((Split-Path -Leaf $src) + $(if ($idx -gt 1) { '.' + $idx } else { '' }))
            if ($Apply) {
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force)
                Move-Item -LiteralPath $src -Destination $dest -Force
            }
            $res.movedInstalls++
            [void]$steps.Add('安装本体 → ' + $(if ($Apply) { $dest } else { '（演练，未搬动）' }) + '  ' + $src)
            Add-JournalEntry -Session $Session -Action ('uninstall.' + $Tool.id + '.backup') -Target $src -Before $src -After $dest `
                -Note ('卸载：安装本体挪到备份区' + $(if ($Apply) { '' } else { '（演练）' }))
        }

        # ---- 2) 它加进 PATH 的条目 ----
        $pathEntries = New-Object System.Collections.ArrayList
        foreach ($tier in @($Tool.install.tiers)) {
            foreach ($pe in @($tier.pathEntries)) {
                if ([string]::IsNullOrEmpty($pe)) { continue }
                [void]$pathEntries.Add([System.Environment]::ExpandEnvironmentVariables([string]$pe))
            }
        }
        $uniq = @($pathEntries | Sort-Object -Unique)
        if ($uniq.Count -gt 0) {
            $pr = Remove-EntriesFromUserPath -Entries $uniq -Session $Session -Apply:$Apply
            $res.pathRemoved = @($pr.removed).Count
            if ($pr.error) {
                [void]$steps.Add('PATH 移除失败：' + $pr.error)
            } elseif ($pr.changed) {
                [void]$steps.Add('PATH 移除：' + ($pr.removed -join ' , ') + $(if ($Apply) { '' } else { '（演练）' }))
            } else {
                [void]$steps.Add('PATH 无需改动（这些目录本来就不在用户 PATH 里）')
            }
        }

        # ---- 3) 安装残留 ----
        $groups = @($ArtifactGroups | Where-Object { $_ })
        if ($groups.Count -gt 0) {
            # 注意这里不传 ProtectedNames：卸载是用户的明确意图
            $movedList = @(Move-ArtifactsToBackup -Groups $groups -Session $Session -Apply:$Apply)
            $res.artifactsMoved = @($movedList | Where-Object { $_.exists }).Count
            foreach ($m in $movedList) {
                [void]$steps.Add('残留清理 → ' + $(if ($m.moved) { $m.destination } else { '（演练，未搬动）' }) + '  ' + $m.source)
            }
        }

        # ---- 4) 用户配置（默认不动）----
        foreach ($cf in @($Tool.configFiles)) {
            $p = [System.Environment]::ExpandEnvironmentVariables([string]$cf.path)
            if (-not (Test-Path -LiteralPath $p)) { continue }
            if (-not $RemoveUserConfig) {
                [void]$steps.Add('保留用户配置（含你的 API 设置，未动）：' + $p)
                continue
            }
            $dest = Join-Path $destRoot ('config-' + (Split-Path -Leaf $p))
            if ($Apply) {
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force)
                Move-Item -LiteralPath $p -Destination $dest -Force
            }
            $res.configMoved++
            [void]$steps.Add('用户配置 → ' + $(if ($Apply) { $dest } else { '（演练，未搬动）' }) + '  ' + $p)
            Add-JournalEntry -Session $Session -Action ('uninstall.' + $Tool.id + '.config') -Target $p -Before $p -After $dest `
                -Note ('卸载：配置文件挪到备份区' + $(if ($Apply) { '' } else { '（演练）' }))
        }

        Add-JournalEntry -Session $Session -Action ('uninstall.' + $Tool.id + ($(if ($Apply) { '.done' } else { '.plan' }))) -Target $Tool.id `
            -After ([ordered]@{ installs = $res.movedInstalls; path = $res.pathRemoved; artifacts = $res.artifactsMoved; config = $res.configMoved }) `
            -Note ('卸载结果' + $(if ($Apply) { '' } else { '（演练）' })) -Status $(if ($Apply) { 'done' } else { 'planned' })
        $res.ok = $true
    } catch {
        $res.error = Get-ShortErrorText -Text $_.Exception.Message
        Add-JournalEntry -Session $Session -Action ('uninstall.' + $Tool.id + '.error') -Target $Tool.id -Status 'failed' -Note $res.error
    }
    $res.steps = @($steps)
    return [pscustomobject]$res
}

# ======================================================================
#  工具安装计划
# ======================================================================


function Get-ArtifactOwnerToolId {
    <#
        把一组残留归属到具体工具。
        归属不出来的返回 ''，会作为"全局残留"单独提示 —— 宁可不猜，也不要归错工具
        然后把它连到错误的安装流程上。
    #>
    param([Parameter(Mandatory = $true)]$Group)
    $text = (([string]$Group.dir) + ' ' + (@($Group.members) -join ' ')).ToLowerInvariant()
    if ($text -match 'claude|anthropic') { return 'claude-code' }
    if ($text -match 'cc-?switch') { return 'cc-switch' }
    if ($text -match 'codex') { return 'codex' }
    if ($text -match 'opencode') { return 'opencode' }
    if ($text -match 'gemini') { return 'gemini-cli' }
    if ($text -match 'dsh') { return 'dsh' }
    return ''
}

function Select-ToolTier {
    <#
        选出可用的安装层。
        type=manual 的层不参与自动安装 —— 它是兜底引导，由计划单独展示。
    #>
    param($Tool, [bool]$IsAdmin, [string[]]$OnlyTiers = @(), [string[]]$SkipTiers = @())
    foreach ($t in @($Tool.install.tiers)) {
        if ([string]$t.type -eq 'manual') { continue }
        if ($OnlyTiers.Count -gt 0 -and ($OnlyTiers -notcontains $t.id)) { continue }
        if ($SkipTiers.Count -gt 0 -and ($SkipTiers -contains $t.id)) { continue }
        if ($t.needsAdmin -and -not $IsAdmin) { continue }
        return $t
    }
    return $null
}

function New-LLMKitToolPlan {
    <#
        产出 5 个目标工具的安装计划。纯规划：不下载、不解压、不写注册表。
        唯一的网络动作是解析 Release 资产信息，让计划在确认前就是具体的。
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigRoot,
        [string]$ReportPath,
        [string[]]$Only = @(),
        [string[]]$Skip = @(),
        [string[]]$OnlyTiers = @(),
        [string[]]$SkipTiers = @(),
        [switch]$Force,
        [string]$Proxy,
        [int]$TimeoutSec = 60,
        [switch]$NoVersionResolve
    )
    Assert-LLMKitPrerequisites

    $cat = Get-ToolCatalog -ConfigRoot $ConfigRoot
    $Only = @(ConvertTo-CsvList -Values $Only | Where-Object { $_ })
    $Skip = @(ConvertTo-CsvList -Values $Skip | Where-Object { $_ })
    $OnlyTiers = @(ConvertTo-CsvList -Values $OnlyTiers | Where-Object { $_ })
    $SkipTiers = @(ConvertTo-CsvList -Values $SkipTiers | Where-Object { $_ })

    $knownIds = @($cat.tools.tools | ForEach-Object { $_.id })
    foreach ($pair in @(@{ n = '-Only'; v = $Only }, @{ n = '-Skip'; v = $Skip })) {
        $bad = @($pair.v | Where-Object { $knownIds -notcontains $_ })
        if ($bad.Count -gt 0) {
            throw ($pair.n + ' 里出现了未知的工具名：' + ($bad -join '、') + '。当前可用的有：' + ($knownIds -join '、'))
        }
    }

    # 镜像规则只有一份，放在 dependencies.json 里，避免两处各写一份迟早走偏
    $depPath = Join-Path $cat.configRoot 'config\dependencies.json'
    $mirrorRewriters = @()
    if (Test-Path -LiteralPath $depPath) {
        try { $mirrorRewriters = @((Read-TextFileUtf8 -Path $depPath | ConvertFrom-Json).mirrorRewriters) } catch { $mirrorRewriters = @() }
    }

      # 体检报告在这条链里只是"工具状态"的缓存。拿不到报告时**不能**要求用户"先去跑一次体检" ——
      # 网页版早就没有那个按钮了（顶栏的刷新只是重扫页面）。所以：有报告就用（快），
      # 没有就现场检测一次（准），两种都不打断安装。
      $reportTools = $null
      if ($report) { $reportTools = Get-ObjectProp -Object $report -Name 'tools' }
      $liveState = $null
      if (-not $reportTools) {
          # 现场检测要和工具页用同一套口径，所以这里也把 npm 的 prefix 现问一次
          $npmPrefix = ''
          $npmExe = Resolve-ExecutablePath -Name 'npm'
          if ($npmExe) {
              $nr = Invoke-Process -FilePath $npmExe -Arguments @('prefix', '-g') -TimeoutMs 20000
              if ($nr.stdout) {
                  $pl = @($nr.stdout -split "`n" | Where-Object { $_.Trim() })
                  if ($pl.Count -gt 0) { $npmPrefix = $pl[$pl.Count - 1].Trim() }
              }
          }
          $liveState = [pscustomobject]@{ npmPrefix = [pscustomobject]@{ path = $npmPrefix } }
      }

    # 残留扫描：范围与检测阶段保持一致
    $roots = New-Object System.Collections.ArrayList
    if ($env:APPDATA) { [void]$roots.Add((Join-Path $env:APPDATA 'npm\node_modules')) }
    if ($env:USERPROFILE) { [void]$roots.Add((Join-Path $env:USERPROFILE '.local\bin')) }
    $scan = Find-InstallArtifacts -Roots @($roots) -MaxDepth 3
    $byTool = @{}
    $unassigned = New-Object System.Collections.ArrayList
    foreach ($g in @($scan.groups)) {
        $owner = Get-ArtifactOwnerToolId -Group $g
        if ([string]::IsNullOrEmpty($owner)) { [void]$unassigned.Add($g); continue }
        if (-not $byTool.ContainsKey($owner)) { $byTool[$owner] = New-Object System.Collections.ArrayList }
        [void]$byTool[$owner].Add($g)
    }

    $isAdmin = Test-IsElevated
    $items = New-Object System.Collections.ArrayList

    foreach ($tool in @($cat.tools.tools)) {
        if ($Only.Count -gt 0 -and ($Only -notcontains $tool.id)) { continue }
        if ($Skip.Count -gt 0 -and ($Skip -contains $tool.id)) {
            [void]$items.Add([pscustomobject]([ordered]@{
                        id = $tool.id; name = $tool.name; action = 'user-skip'; reason = '按你的要求跳过'
                        installed = $false; conflict = $false; artifacts = @(); tier = $null; download = $null
                    }))
            continue
        }

          $st = $null
          if ($reportTools) { $st = Get-ObjectProp -Object $reportTools -Name $tool.id }
          if (-not $st) { $st = Get-ToolStatus -Tool $tool -State $liveState }
        $installed = [bool](Get-ObjectProp -Object $st -Name 'installed')
        $conflict = [bool](Get-ObjectProp -Object $st -Name 'conflict')
        $installCount = [int](Get-ObjectProp -Object $st -Name 'installCount')
        $version = [string](Get-ObjectProp -Object $st -Name 'version')
        $artifacts = @()
        if ($byTool.ContainsKey($tool.id)) { $artifacts = @($byTool[$tool.id]) }

        $action = 'skip'
        $reason = ''
        if ($Force) {
            $action = 'reinstall'; $reason = '按 -Force 要求重新安装'
        } elseif (-not $installed) {
            if ($artifacts.Count -gt 0) {
                $action = 'install-clean'
                $reason = ('未安装，但发现 ' + $artifacts.Count + ' 组上次安装残留，需要先清理再装')
            } else {
                $action = 'install'; $reason = '未安装'
            }
        } elseif ($conflict) {
            $action = 'conflict'
            $reason = ('检测到 ' + $installCount + ' 份安装共存，需要先决定保留哪一份')
        } else {
            $action = 'skip'; $reason = ('已就绪' + $(if ($version) { '：' + $version } else { '' }))
        }

        $tier = $null
        $download = $null
        $manualTiers = @($tool.install.tiers | Where-Object { [string]$_.type -eq 'manual' })
        if ($action -in @('install', 'reinstall', 'install-clean')) {
            $tier = Select-ToolTier -Tool $tool -IsAdmin $isAdmin -OnlyTiers $OnlyTiers -SkipTiers $SkipTiers
            if ($null -eq $tier) {
                $action = 'manual'
                $reason += '；没有可用的自动安装层（可能全都需要管理员权限）'
            }
        }

        $item = [pscustomobject]([ordered]@{
                id              = $tool.id
                name            = $tool.name
                vendor          = $tool.vendor
                purpose         = (Get-ObjectProp -Object $tool -Name 'notes')
                installed       = $installed
                version         = $version
                installCount    = $installCount
                conflict        = $conflict
                installations   = @(Get-ObjectProp -Object $st -Name 'installations')
                commands        = @($tool.commands)
                artifacts       = $artifacts
                action          = $action
                reason          = $reason
                tier            = $tier
                manualTiers     = $manualTiers
                availableTiers  = @($tool.install.tiers | Where-Object {
                        $ok = $true
                        if ([string]$_.type -eq 'manual') { $ok = $false }
                        if ($_.needsAdmin -and -not $isAdmin) { $ok = $false }
                        if ($SkipTiers.Count -gt 0 -and ($SkipTiers -contains $_.id)) { $ok = $false }
                        $ok
                    })
                download        = $null
                homeUrl         = (Get-ObjectProp -Object $tool -Name 'homeUrl')
            })

        if ($tier -and -not $NoVersionResolve -and @('github-release', 'portable-zip') -contains [string]$tier.type) {
            $item | Add-Member -NotePropertyName __mirrorRewriters -NotePropertyValue $mirrorRewriters -Force
            # 解析资产只影响"能不能自动装"，不该连累整份计划：出错就退化成"需在线重试"，
            # 这样人工引导层仍然可选 —— 以前这里一抛错，工具页两个模式会一起变成"计划失败"。
            try {
                $download = Resolve-ItemDownload -Item $item -MirrorRewriters $mirrorRewriters -Proxy $Proxy -TimeoutSec $TimeoutSec
            } catch {
                $download = [pscustomobject]([ordered]@{
                        ok = $false; kind = [string]$tier.type; version = ''; fileName = ''
                        urls = @(); checksumUrl = ''; sizeBytes = $null
                        error = [string]$_.Exception.Message
                    })
            }
            $item = [pscustomobject]([ordered]@{
                    id = $item.id; name = $item.name; vendor = $item.vendor; purpose = $item.purpose
                    installed = $item.installed; version = $item.version; installCount = $item.installCount
                    conflict = $item.conflict; installations = $item.installations; artifacts = $item.artifacts
                    action = $item.action; reason = $item.reason; tier = $item.tier; manualTiers = $item.manualTiers
                    availableTiers = $item.availableTiers; download = $download; homeUrl = $item.homeUrl
                })
            if (-not $download.ok -and $item.action -eq 'install') { $item.action = 'install-degraded' }
        }
        [void]$items.Add($item)
    }

    return [pscustomobject]([ordered]@{
            schemaVersion   = '0.1.0'
            engine          = 'LLMKit.Tools/' + $script:ToolsVersion
            generatedAt     = (Get-Date).ToString('o')
            configRoot      = $cat.configRoot
            isAdmin         = $isAdmin
            mirrorRewriters = $mirrorRewriters
            npmRegistryPrimary = (Get-ObjectProp -Object $cat.tools -Name 'npmRegistryPrimary')
            npmRegistryMirrors = @(Get-ObjectProp -Object $cat.tools -Name 'npmRegistryMirrors')
            artifactScan    = [ordered]@{
                artifactCount = $scan.artifacts.Count
                groupCount    = $scan.groups.Count
                unassigned    = @($unassigned | ForEach-Object { $_.dir })
            }
            items           = @($items)
        })
}

function Format-LLMKitToolPlan {
    param([Parameter(Mandatory = $true)]$Plan, [switch]$NoColor)
    $useColor = -not $NoColor
    $say = {
        param($text, $color)
        if ($useColor) { try { Write-Host $text -ForegroundColor $color; return } catch { } }
        try { Write-Host $text } catch { [Console]::Out.WriteLine([string]$text) }
    }

    & $say '' 'Gray'
    & $say '=========== 工具安装计划（尚未执行任何改动） ===========' 'White'
    & $say ('管理员权限：' + $(if ($Plan.isAdmin) { '有' } else { '无（只走免管理员路线）' })) 'DarkGray'
    if ($Plan.artifactScan.artifactCount -gt 0) {
        & $say ('检测到 ' + $Plan.artifactScan.artifactCount + ' 个安装残留，归为 ' + $Plan.artifactScan.groupCount + ' 组（清理时按组整目录搬走）') 'Yellow'
    }
    & $say '' 'Gray'

    foreach ($it in $Plan.items) {
        $mark = ' .. '; $color = 'Gray'; $verdict = ''
        switch ($it.action) {
            'skip' { $mark = ' OK '; $color = 'Green'; $verdict = '已就绪，无需安装' }
            'install' { $mark = ' >> '; $color = 'Yellow'; $verdict = '将安装' }
            'install-clean' { $mark = ' >> '; $color = 'Yellow'; $verdict = '将先清理残留再安装' }
            'install-degraded' { $mark = ' !! '; $color = 'Yellow'; $verdict = '将安装（资产信息解析失败，需在线重试）' }
            'reinstall' { $mark = ' >> '; $color = 'Yellow'; $verdict = '将重新安装（-Force）' }
            'conflict' { $mark = ' !! '; $color = 'Yellow'; $verdict = '存在多份安装，需要先决定保留哪一份' }
            'manual' { $mark = ' XX '; $color = 'Red'; $verdict = '需要手动安装' }
            'user-skip' { $mark = ' -- '; $color = 'DarkGray'; $verdict = '按你的要求跳过' }
        }
        & $say ('[' + $mark + '] ' + $it.name + ' —— ' + $verdict) $color
        & $say ('        ' + $it.reason) 'DarkGray'

        if ($it.conflict -and $it.installations) {
            & $say '        检测到以下安装共存：' 'Yellow'
            foreach ($inst in @($it.installations)) {
                & $say ('          · [' + $inst.kind + '] ' + $inst.path) 'DarkGray'
            }
            & $say '        → 默认保留 PATH 实际命中的那一份，其余挪到备份区（不删除）。需要加 -ResolveConflicts 才执行。' 'DarkGray'
        }
        if ($it.artifacts -and @($it.artifacts).Count -gt 0) {
            & $say ('        上次安装残留（' + @($it.artifacts).Count + ' 组）：') 'Yellow'
            foreach ($g in @($it.artifacts)) { & $say ('          · ' + $g.dir) 'DarkGray' }
            & $say '        → 这些是上次安装/升级中断留下的，直接重装往往会继续失败。需要加 -CleanArtifacts 才会清理（挪到备份区，不删除）。' 'DarkGray'
        }
        if ($it.tier) {
            & $say ('        方式：' + $it.tier.label) 'Cyan'
            if ($it.tier.detail) { & $say ('              ' + $it.tier.detail) 'DarkGray' }
            & $say ('        需要管理员：' + $(if ($it.tier.needsAdmin) { '是' } else { '否' })) 'DarkGray'
            if ($it.tier.installRoot) { & $say ('        安装到：' + $it.tier.installRoot) 'DarkGray' }
            if ($it.tier.scriptUrl) { & $say ('        官方脚本：' + $it.tier.scriptUrl + '（会先下载留档再执行）') 'DarkGray' }
            if ($it.tier.package) { & $say ('        npm 包：' + $it.tier.package) 'DarkGray' }
            if ($it.availableTiers -and @($it.availableTiers).Count -gt 1) {
                $alt = @($it.availableTiers | Select-Object -Skip 1 | ForEach-Object { $_.label })
                & $say ('        失败时兜底：' + ($alt -join ' → ')) 'DarkGray'
            }
            if ($it.tier.verified -eq $false) {
                & $say '        注意：该安装方式尚未在真机实测确认（配置里标了 verified=false），失败会自动退到下一层或人工引导。' 'Yellow'
            }
        }
        if ($it.download) {
            if ($it.download.ok) {
                & $say ('        版本：' + $it.download.version) 'DarkGray'
                foreach ($u in @($it.download.urls)) { & $say ('        下载：' + $u) 'DarkGray' }
                if ($null -ne $it.download.sizeBytes -and [long]$it.download.sizeBytes -gt 0) {
                    & $say ('        大小：' + (Format-ByteSize -Bytes ([long]$it.download.sizeBytes))) 'DarkGray'
                }
            } else {
                & $say ('        资产信息解析失败：' + $it.download.error) 'Yellow'
            }
        }
        if ($it.action -eq 'manual') {
            foreach ($mt in @($it.manualTiers)) {
                & $say ('        手动方式：' + $mt.label) 'Red'
                if ($mt.manualUrl) { & $say ('        下载页：' + $mt.manualUrl) 'DarkGray' }
                foreach ($s in @((Get-ObjectProp -Object $mt.guidance -Name 'steps'))) { & $say ('          - ' + $s) 'DarkGray' }
            }
        }
        & $say '' 'Gray'
    }

    $toInstall = @($Plan.items | Where-Object { $_.action -in @('install', 'install-clean', 'install-degraded', 'reinstall') })
    $toConflict = @($Plan.items | Where-Object { $_.action -eq 'conflict' })
    $toManual = @($Plan.items | Where-Object { $_.action -eq 'manual' })
    $toSkip = @($Plan.items | Where-Object { $_.action -in @('skip', 'user-skip') })
    & $say ('合计：待安装 ' + $toInstall.Count + ' / 已就绪 ' + $toSkip.Count + ' / 待处理冲突 ' + $toConflict.Count + ' / 需手动 ' + $toManual.Count) 'White'
    & $say '=====================================================' 'White'
    & $say '' 'Gray'
}

# ======================================================================
#  执行
# ======================================================================

function Invoke-LLMKitToolSetup {
    <#
        执行工具安装计划。默认 DryRun，必须显式 -Apply。
        两个"危险动作"各自需要单独开关：
          -CleanArtifacts    清理上次安装残留（挪到备份区）
          -ResolveConflicts  处理多份安装共存（保留一份，其余挪到备份区）
        不给开关时只在计划里标出来，绝不擅自动手。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [switch]$Apply,
        [string]$StateDir,
        [string]$Proxy,
        [switch]$CleanArtifacts,
        [switch]$ResolveConflicts,
        [hashtable]$KeepPaths,
        [string]$SandboxRoot,
        [switch]$KeepCache,
        [switch]$NoColor
    )
    Assert-LLMKitPrerequisites
    if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'LLMKit' }
    $sandboxed = -not [string]::IsNullOrEmpty($SandboxRoot)
    $doExecute = ($Apply -or $sandboxed)
    $session = New-InstallSession -StateDir $StateDir -DryRun:(-not $doExecute)
    $cacheDir = Join-Path $StateDir 'cache'
    if ($doExecute -and -not (Test-Path -LiteralPath $cacheDir)) { [void](New-Item -ItemType Directory -Path $cacheDir -Force) }

    $say = {
        param($text, $color)
        if (-not $NoColor) { try { Write-Host $text -ForegroundColor $color; return } catch { } }
        try { Write-Host $text } catch { [Console]::Out.WriteLine([string]$text) }
    }

    $results = New-Object System.Collections.ArrayList
    $targets = @($Plan.items | Where-Object { $_.action -in @('install', 'install-clean', 'install-degraded', 'reinstall', 'conflict') })

    & $say '' 'Gray'
    if ($sandboxed) {
        & $say ('沙箱模式：安装到 ' + $SandboxRoot) 'Yellow'
        & $say '只对绿色包（zip）类安装生效；npm 与官方脚本类会跳过，因为它们必然写真实目录。' 'Yellow'
    } elseif ($doExecute) {
        & $say ('开始安装工具（会话 ' + $session.id + '）') 'White'
        & $say ('日志：' + $session.journalPath) 'DarkGray'
        & $say ('备份区：' + $session.backupDir) 'DarkGray'
        if ($CleanArtifacts) { & $say '残留清理：已开启' 'Yellow' }
        if ($ResolveConflicts) { & $say '冲突处理：已开启（保留 PATH 命中的那份）' 'Yellow' }
    } else {
        & $say '演练模式（DryRun）：不会下载、不会解压、不会改注册表。' 'Yellow'
        & $say '确认无误后加 -Apply 真正执行。' 'Yellow'
    }
    & $say '' 'Gray'

    foreach ($item in $targets) {
        $session.summary.planned++
        & $say ('-> ' + $item.name) 'Cyan'
        $steps = New-Object System.Collections.ArrayList
        $ok = $true
        $errText = ''
        $installedTo = ''

        # ---- 1) 残留清理 ----
        if ($item.artifacts -and @($item.artifacts).Count -gt 0) {
            if ($CleanArtifacts) {
                $moved = Move-ArtifactsToBackup -Groups $item.artifacts -Session $session -ProtectedNames @($item.commands) -Apply:$doExecute
                $failed = @($moved | Where-Object { $_.exists -and -not $_.moved -and $doExecute })
                foreach ($m in $moved) {
                    if ($m.skipped) {
                        [void]$steps.Add('残留清理跳过：' + $m.source + ' —— 组内有疑似可用的程序（' + ($m.protectedNames -join '、') + '），判定为不是残渣')
                    } else {
                        [void]$steps.Add('残留清理：' + $m.source + ' → ' + $(if ($m.moved) { $m.destination } else { '（演练，未搬动）' }))
                    }
                }
                if ($failed.Count -gt 0) { $ok = $false; $errText = '残留清理失败，已中止该项安装。' }
            } else {
                [void]$steps.Add('发现 ' + @($item.artifacts).Count + ' 组安装残留，但未开启 -CleanArtifacts，保持原样。')
            }
        }
        if (-not $ok) {
            [void]$results.Add([pscustomobject]@{ id = $item.id; name = $item.name; ok = $false; action = 'clean-artifacts'; error = $errText; steps = @($steps); installedTo = '' })
            $session.summary.failed++
            & $say ('   失败：' + $errText) 'Red'
            foreach ($s in $steps) { & $say ('     · ' + $s) 'DarkGray' }
            continue
        }

        # ---- 2) 冲突处理 ----
        if ($item.conflict) {
            if ($ResolveConflicts) {
                $keep = ''
                if ($KeepPaths -and $KeepPaths.ContainsKey($item.id)) { $keep = [string]$KeepPaths[$item.id] }
                $fakeStatus = [pscustomobject]@{ installations = $item.installations }
                $conflictActions = Resolve-ToolConflict -ToolStatus $fakeStatus -Session $session -KeepPath $keep -ExeNames @($item.commands) -Apply:$doExecute
                foreach ($c in $conflictActions) {
                    $cLabel = '（演练）'
                    if ($c.moved) { $cLabel = '（已搬到 ' + $c.destination + '）' }
                    elseif ($c.action -eq 'manual') { $cLabel = '（未处理：' + $c.reason + '）' }
                    elseif ($c.reason) { $cLabel = '（说明：' + $c.reason + '）' }
                    [void]$steps.Add('冲突处理：' + $c.source + ' → ' + $c.action + $cLabel)
                    if (@($c.pathEntries).Count -gt 0) { [void]$steps.Add('　顺带清掉指向它的 PATH 条目：' + (@($c.pathEntries) -join ' ; ')) }
                    # 真执行时"该搬却没搬成"就是失败 —— 以前这里不看结果，搬挂了照样报"成功"
                    if ($doExecute -and $c.action -eq 'move-to-backup' -and -not $c.moved) {
                        $ok = $false
                        $errText = ('副本没能搬走：' + [string]$c.reason)
                    }
                }
            } else {
                [void]$steps.Add('存在 ' + $item.installCount + ' 份安装共存，未开启 -ResolveConflicts，保持原样。')
            }
            if ($item.action -eq 'conflict') {
                # 只处理冲突，不重装
                $session.summary.succeeded++
                [void]$results.Add([pscustomobject]@{ id = $item.id; name = $item.name; ok = $true; action = 'conflict'; error = ''; steps = @($steps); installedTo = '' })
                foreach ($s in $steps) { & $say ('     · ' + $s) 'DarkGray' }
                continue
            }
        }

        # ---- 3) 安装 ----
        $tier = $item.tier
        $r = $null
        try {
            if ($null -eq $tier) {
                $r = [pscustomobject]@{ ok = $false; error = '没有可用的安装层。'; steps = @(); installedTo = '' }
          } elseif ([string]$tier.type -eq 'npm') {
              if ($sandboxed) {
                  $r = [pscustomobject]@{ ok = $false; error = '沙箱模式不支持 npm 安装层（必然写真实目录）。请去掉 -SandboxRoot 或用 -OnlyTiers 指定绿色包层。'; steps = @(); installedTo = '' }
              } else {
                  $r = Install-NpmItem -Item $item -Session $session -Proxy $Proxy `
                      -NpmRegistryPrimary $Plan.npmRegistryPrimary -NpmRegistryMirrors $Plan.npmRegistryMirrors -Apply:$doExecute
              }
          } elseif ([string]$tier.type -eq 'powershell-pipe') {
              if ($sandboxed) {
                  $r = [pscustomobject]@{ ok = $false; error = '沙箱模式不支持官方脚本安装层（脚本会写真实目录）。'; steps = @(); installedTo = '' }
              } else {
                  $item | Add-Member -NotePropertyName __mirrorRewriters -NotePropertyValue $Plan.mirrorRewriters -Force
                  $r = Install-ScriptItem -Item $item -Session $session -CacheDir $cacheDir -Proxy $Proxy -Apply:$doExecute
              }
          } elseif ([string]$tier.type -eq 'winget') {
              # 工具路径原来不支持 winget（那是依赖路径专属），Node / Git 升格成工具后要接上。
              # 复用 Install-WingetItem：需要管理员权限的层在计划阶段就已被标成"需提权"，走到这里的是真的要用它。
              if ($sandboxed) {
                  $r = [pscustomobject]@{ ok = $false; error = '沙箱模式不支持 winget 安装层（会写真实系统）。'; steps = @(); installedTo = '' }
              } else {
                  $r = Install-WingetItem -Item $item -Session $session -Apply:$doExecute
                  $r | Add-Member -NotePropertyName installedTo -NotePropertyValue ($(if ($doExecute) { 'winget' } else { '' })) -Force
              }
          } elseif ([string]$tier.type -eq 'github-release' -or [string]$tier.type -eq 'portable-zip') {
              $item | Add-Member -NotePropertyName __mirrorRewriters -NotePropertyValue $Plan.mirrorRewriters -Force
              if ($item.action -eq 'install-degraded') {
                  $item = [pscustomobject]@{ id = $item.id; name = $item.name; tier = $tier; download = (Resolve-ItemDownload -Item $item -MirrorRewriters $Plan.mirrorRewriters -Proxy $Proxy); __mirrorRewriters = $Plan.mirrorRewriters }
              }
              $r = Install-PortableItem -Item $item -Session $session -CacheDir $cacheDir -Proxy $Proxy -Apply:$doExecute -KeepCache:$KeepCache -SandboxRoot $SandboxRoot
          } else {
              $r = [pscustomobject]@{ ok = $false; error = ('暂不支持的安装层类型：' + [string]$tier.type + '。计划里应已标为需手动安装。'); steps = @(); installedTo = '' }
          }
        } catch {
            $r = [pscustomobject]@{ ok = $false; error = (Get-ShortErrorText -Text $_.Exception.Message); steps = @(); installedTo = '' }
        }

        foreach ($s in @($r.steps)) { [void]$steps.Add($s) }
        $installedTo = [string]$r.installedTo
        if (-not $r.ok) { $ok = $false; $errText = [string]$r.error }

        $status = 'ok'
        if (-not $ok) { $status = 'failed' }
        if (-not $doExecute) { $status = 'planned' }
        switch ($status) {
            'ok' { $session.summary.succeeded++ }
            'failed' { $session.summary.failed++ }
        }

        Add-JournalEntry -Session $session -Action ('tool.' + $item.id + '.' + $status) -Target $(if ($installedTo) { $installedTo } else { $item.id }) `
            -After ([ordered]@{ ok = $ok; tier = $(if ($tier) { $tier.id } else { '' }); version = $r.version }) `
            -Note (Get-ShortErrorText -Text $(if ($errText) { $errText } else { '完成' })) -Status $status

        [void]$results.Add([pscustomobject]([ordered]@{
                    id = $item.id; name = $item.name; ok = $ok
                    action = $(if ($tier) { [string]$tier.type } else { 'none' })
                    tier = $(if ($tier) { $tier.id } else { '' })
                    error = $errText; steps = @($steps); installedTo = $installedTo
                    version = [string]$r.version
                }))

        if ($doExecute) {
            if ($ok) { & $say ('   完成：' + $(if ($installedTo) { $installedTo } else { '见上' })) 'Green' }
            else { & $say ('   失败：' + $errText) 'Red' }
        } else {
            & $say '   已记录到计划（未执行）' 'DarkGray'
        }
        foreach ($s in $steps) { & $say ('     · ' + $s) 'DarkGray' }
    }

    $journalPath = Save-InstallJournal -Session $session
    & $say '' 'Gray'
    if (-not $doExecute) {
        & $say ('演练结束：计划处理 ' + $session.summary.planned + ' 项，未做任何改动。') 'Yellow'
    } else {
        & $say ('工具安装结束：成功 ' + $session.summary.succeeded + ' / 失败 ' + $session.summary.failed) $(if ($session.summary.failed -gt 0) { 'Red' } else { 'Green' })
        if ($journalPath) { & $say ('日志已写入：' + $journalPath) 'DarkGray' }
    }

    return [pscustomobject]([ordered]@{
            sessionId   = $session.id
            dryRun      = (-not $doExecute)
            sandboxed   = $sandboxed
            journalPath = $journalPath
            summary     = $session.summary
            results     = @($results)
        })
}

Export-ModuleMember -Function `
    'Get-LLMKitToolsVersion', 'Get-ToolCatalog', 'Get-ProviderCatalog', 'Show-ProviderGuidance', `
    'Move-ArtifactsToBackup', 'Resolve-ToolConflict', `
    'Install-ScriptItem', 'Install-NpmItem', `
    'New-LLMKitToolPlan', 'Format-LLMKitToolPlan', 'Invoke-LLMKitToolSetup', `
    'Get-ArtifactOwnerToolId', 'Select-ToolTier', 'Assert-LLMKitPrerequisites', `
    'Uninstall-LLMKitTool', 'Get-LLMKitToolArtifacts', 'Get-DefaultArtifactRoots'
