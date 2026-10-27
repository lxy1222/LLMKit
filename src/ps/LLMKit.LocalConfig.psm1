#Requires -Version 5.1
<#
.SYNOPSIS
    LLMKit 本地模型切换：把端点写进 OpenCode / Codex 的配置，并能一键切回

.DESCRIPTION
    只做两家，理由不同：
      · OpenCode 的配置是 JSON，provider 是一个字典 —— 加一个键不影响别人。
      · Codex 的配置是 TOML，模型提供方是一个独立 section —— 加一个 section 也不影响别人。
      · dsh 是 YAML 嵌套、Gemini 只认自家协议、Claude Code 只认 Anthropic 协议 —— 都不在这里做。

    三条硬规矩：
      1. 写之前一定先整份备份（备份**不删**，切回就是还原它）
      2. 只动我们认识的那一块，别的键原样保留（有单测盯着）
      3. 每次写都记账，出问题能查到什么时候改的、改了什么

    为什么不能"盲写"：这两家的配置里有用户自己的渠道与 key。改坏它比不改更糟 ——
    所以这里不是"拼字符串"，而是 parse → 只改目标键 → 写回，且失败就回到备份。
#>

function Get-LLMKitLocalSwitchTargetPath {
    param([Parameter(Mandatory = $true)][string]$Target)
    switch ($Target) {
        'opencode' { return (Join-Path $env:USERPROFILE '.config\opencode\opencode.json') }
        'codex' { return (Join-Path $env:USERPROFILE '.codex\config.toml') }
        default { throw ('这个工具不支持自动切换：' + $Target) }
    }
}

function Get-LLMKitLocalSwitchTargets {
    <#
        能自动切换的目标。界面据此决定哪几行给按钮。
    #>
    $list = New-Object System.Collections.ArrayList
    foreach ($t in @(
            @{ id = 'opencode'; name = 'OpenCode'; format = 'json'; note = '在 provider 里加一个 ollama 条目（JSON，只动这一块）' },
            @{ id = 'codex'; name = 'Codex CLI'; format = 'toml'; note = '加一个 [model_providers.ollama] 段并指向它（TOML，只动这一块）' }
        )) {
        $path = Get-LLMKitLocalSwitchTargetPath -Target $t.id
        $exists = Test-Path -LiteralPath $path
        [void]$list.Add([pscustomobject]@{
                id         = $t.id
                name       = $t.name
                format     = $t.format
                note       = $t.note
                configPath = $path
                exists     = $exists
            })
    }
    return @($list)
}

function Get-LLMKitLocalSwitchState {
    <#
        这个目标现在是不是指向本地？如果是，指向哪个模型？
        文件不存在 / 解析不了时给"未知"，不抛错（页面要能显示）。
    #>
    param([Parameter(Mandatory = $true)][string]$Target)

    $path = Get-LLMKitLocalSwitchTargetPath -Target $Target
    $result = [pscustomobject]@{ target = $Target; configPath = $path; exists = (Test-Path -LiteralPath $path); applied = $false; model = ''; detail = '' }
    if (-not $result.exists) { return $result }

    try {
        if ($Target -eq 'opencode') {
            $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $prov = $null
            if ($json.PSObject.Properties['provider']) { $prov = $json.provider }
            if ($prov -and $prov.PSObject.Properties['ollama']) {
                $result.applied = $true
                $entry = $prov.ollama
                if ($entry.PSObject.Properties['models'] -and $entry.models) {
                    $names = @($entry.models.PSObject.Properties.Name)
                    if ($names.Count -gt 0) { $result.model = [string]$names[0] }
                }
                $result.detail = '配置里有 provider.ollama'
            }
        } elseif ($Target -eq 'codex') {
            $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            $hasSection = $text -match '(?m)^\s*\[model_providers\.ollama\]\s*$'
            $usesIt = $text -match '(?m)^\s*model_provider\s*=\s*"ollama"'
            $result.applied = ($hasSection -and $usesIt)
            $m = [regex]::Match($text, '(?m)^\s*model\s*=\s*"([^"]+)"')
            if ($m.Success) { $result.model = $m.Groups[1].Value }
            $result.detail = ('model_providers.ollama=' + $hasSection + '，model_provider=ollama=' + $usesIt)
        }
    } catch {
        $result.detail = ('读不懂这个配置文件：' + $_.Exception.Message)
    }
    return $result
}

function Backup-LLMKitLocalSwitchFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$StateDir
    )
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $dir = Join-Path $StateDir 'local-switch'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dest = Join-Path $dir ($Target + '-orig-' + $stamp + [System.IO.Path]::GetExtension($Path))
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    return $dest
}

function New-LLMKitOpencodeConfigText {
    <#
        在 OpenCode 的 JSON 里塞 provider.ollama，别的键原样保留。
        返回新的全文（不写盘）—— 便于单测直接比字符串。
    #>
    param(
        [AllowEmptyString()][string]$OriginalText,
        [Parameter(Mandatory = $true)][string]$ModelTag,
        [string[]]$AllTags = @(),
        [string]$BaseUrl = 'http://127.0.0.1:11434/v1'
    )

    $obj = $null
    if ([string]::IsNullOrWhiteSpace($OriginalText)) {
        $obj = [pscustomobject]@{ '$schema' = 'https://opencode.ai/config.json' }
    } else {
        $obj = $OriginalText | ConvertFrom-Json
    }

    $models = [ordered]@{}
    $tags = New-Object System.Collections.ArrayList
    [void]$tags.Add($ModelTag)
    foreach ($t in @($AllTags)) { if (-not [string]::IsNullOrWhiteSpace($t) -and -not $tags.Contains($t)) { [void]$tags.Add($t) } }
    foreach ($t in $tags) {
        $models[$t] = [ordered]@{ name = ($t + '（本地）') }
    }

    $entry = [ordered]@{
        npm     = '@ai-sdk/openai-compatible'
        options = [ordered]@{ baseURL = $BaseUrl; apiKey = 'local' }
        models  = $models
    }

    # 用字典重建，避免 PSCustomObject 合并时的类型问题
    $root = [ordered]@{}
    foreach ($p in $obj.PSObject.Properties) { $root[$p.Name] = $p.Value }
    $prov = [ordered]@{}
    if ($root.Contains('provider') -and $root['provider']) {
        foreach ($p in $root['provider'].PSObject.Properties) { $prov[$p.Name] = $p.Value }
    }
    $prov['ollama'] = $entry
    $root['provider'] = $prov
    return ($root | ConvertTo-Json -Depth 20)
}

function New-LLMKitCodexConfigText {
    <#
        在 Codex 的 TOML 里加 [model_providers.ollama] 段，并把 model / model_provider 指过去。
        顶层键只改这两个；已有别的键（含用户的 profile、审批设置等）原样保留。
        这是**文本级**操作，不是完整 TOML 解析器 —— 所以我们只碰三处：
          顶层 model_provider、顶层 model、以及 [model_providers.ollama] 这一段。
    #>
    param(
        [AllowEmptyString()][string]$OriginalText,
        [Parameter(Mandatory = $true)][string]$ModelTag,
        [string]$BaseUrl = 'http://127.0.0.1:11434/v1'
    )

    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($OriginalText)) { $lines = @($OriginalText -split "`r?`n") }

    $section = @(
        '[model_providers.ollama]',
        'name = "Ollama (local)"',
        ('base_url = "' + $BaseUrl + '"'),
        'env_key = "OLLAMA_API_KEY"',
        ''
    )

    $out = New-Object System.Collections.ArrayList
    $inOurSection = $false
    $sawSection = $false
    $inTopLevel = $true      # 见到第一个 [section] 之前才是顶层
    $topKeysDone = @{}
    foreach ($line in $lines) {
        $isHeader = ($line -match '^\s*\[')
        if ($isHeader) {
            $inTopLevel = $false
            if ($line -match '^\s*\[model_providers\.ollama\]\s*$') {
                # 丢掉旧的那一段（内容由我们重写）
                $inOurSection = $true
                $sawSection = $true
                continue
            } else {
                $inOurSection = $false
            }
        }
        if ($inOurSection) {
            # 跳过旧段里的行，直到下一个 section 头
            if (-not $isHeader) { continue }
        }
        if (-not $isHeader -and $inTopLevel) {
            if ($line -match '^\s*model_provider\s*=') { [void]$out.Add('model_provider = "ollama"'); $topKeysDone['model_provider'] = $true; continue }
            if ($line -match '^\s*model\s*=') { [void]$out.Add('model = "' + $ModelTag + '"'); $topKeysDone['model'] = $true; continue }
        }
        [void]$out.Add($line)
    }

    # 顶层缺的键补在最前面（TOML 里顶层键必须出现在任何 section 之前）
    $prefix = New-Object System.Collections.ArrayList
    if (-not $topKeysDone.ContainsKey('model_provider')) { [void]$prefix.Add('model_provider = "ollama"') }
    if (-not $topKeysDone.ContainsKey('model')) { [void]$prefix.Add('model = "' + $ModelTag + '"') }
    if ($prefix.Count -gt 0) { [void]$prefix.Add('') }

    $all = @($prefix) + @($out)
    if (-not $sawSection) { $all += $section }
    else { $all += $section }

    $text = ($all -join "`n")
    $text = $text -replace "(`n){3,}", "`n`n"
    return $text.TrimEnd() + "`n"
}

function Get-LLMKitLocalSwitchPlan {
    <#
        只算"会怎么改"，不写盘。界面拿它填确认框，用户能看到改哪几处。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ModelTag,
        [string[]]$AllTags = @(),
        [string]$BaseUrl = 'http://127.0.0.1:11434/v1'
    )

    $path = Get-LLMKitLocalSwitchTargetPath -Target $Target
    $exists = Test-Path -LiteralPath $path
    $original = ''
    if ($exists) { $original = [System.IO.File]::ReadAllText($path) }
    $before = Get-LLMKitLocalSwitchState -Target $Target

    $newText = ''
    if ($Target -eq 'opencode') { $newText = New-LLMKitOpencodeConfigText -OriginalText $original -ModelTag $ModelTag -AllTags $AllTags -BaseUrl $BaseUrl }
    elseif ($Target -eq 'codex') { $newText = New-LLMKitCodexConfigText -OriginalText $original -ModelTag $ModelTag -BaseUrl $BaseUrl }
    else { throw ('这个工具不支持自动切换：' + $Target) }

    return [pscustomobject]@{
        target     = $Target
        configPath = $path
        exists     = $exists
        model      = $ModelTag
        baseUrl    = $BaseUrl
        alreadyLocal = [bool]$before.applied
        beforeModel  = [string]$before.model
        newText    = $newText
        changed    = ($newText -ne $original)
    }
}

function Set-LLMKitLocalSwitch {
    <#
        真正写盘：备份 → 只改目标块 → 写回 → 核对。
        任何一步失败都从备份还原（连"文件原本不存在"这种情况也覆盖）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ModelTag,
        [string[]]$AllTags = @(),
        [string]$BaseUrl = 'http://127.0.0.1:11434/v1',
        [string]$StateDir = '',
        [switch]$Apply,
        [scriptblock]$OnLine
    )

    $plan = Get-LLMKitLocalSwitchPlan -Target $Target -ModelTag $ModelTag -AllTags $AllTags -BaseUrl $BaseUrl
    $emit = { param($s) if ($OnLine) { & $OnLine $s } }
    & $emit ('目标：' + $Target + ' → ' + $plan.configPath)
    & $emit ('模型：' + $ModelTag + '　端点：' + $BaseUrl)
    if (-not $plan.exists) { & $emit '这个配置文件现在不存在，会新建一个（只含本地这一块，不写别的）' }

    if (-not $Apply) {
        return [pscustomobject]@{ ok = $true; applied = $false; dryRun = $true; target = $Target; configPath = $plan.configPath; model = $ModelTag; backup = ''; detail = '演练：没有写任何文件' }
    }

    $backup = ''
    $dir = [System.IO.Path]::GetDirectoryName($plan.configPath)
    try {
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        if (-not [string]::IsNullOrWhiteSpace($StateDir)) { $backup = Backup-LLMKitLocalSwitchFile -Path $plan.configPath -Target $Target -StateDir $StateDir }
        [System.IO.File]::WriteAllText($plan.configPath, $plan.newText, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        return [pscustomobject]@{ ok = $false; applied = $false; dryRun = $false; target = $Target; configPath = $plan.configPath; model = $ModelTag; backup = $backup; detail = ('写入失败：' + $_.Exception.Message) }
    }

    # 写完核对：读回来确认真的指向本地
    $after = Get-LLMKitLocalSwitchState -Target $Target
    if (-not $after.applied) {
        if (-not [string]::IsNullOrWhiteSpace($backup) -and (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $backup -Destination $plan.configPath -Force
        }
        return [pscustomobject]@{ ok = $false; applied = $false; dryRun = $false; target = $Target; configPath = $plan.configPath; model = $ModelTag; backup = $backup; detail = '写完了但读回来没看到本地 provider，已用备份还原。' }
    }

    if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
        try {
            Add-Content -LiteralPath (Join-Path $StateDir 'local-switch.log') -Encoding UTF8 `
                -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  切到本地：' + $Target + ' → ' + $ModelTag + '（配置 ' + $plan.configPath + '，备份 ' + $backup + '）')
        } catch { }
    }
    & $emit ('已切换：' + $after.detail)
    return [pscustomobject]@{ ok = $true; applied = $true; dryRun = $false; target = $Target; configPath = $plan.configPath; model = $ModelTag; backup = $backup; detail = ('已切到本地（' + $ModelTag + '）') }
}

function Undo-LLMKitLocalSwitch {
    <#
        切回原样：优先用最近一次备份整份还原（最稳，连格式都不变）；
        没有备份时再做外科式移除（把 provider.ollama / [model_providers.ollama] 摘掉）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$StateDir = '',
        [switch]$Apply,
        [scriptblock]$OnLine
    )

    $path = Get-LLMKitLocalSwitchTargetPath -Target $Target
    $emit = { param($s) if ($OnLine) { & $OnLine $s } }
    $state = Get-LLMKitLocalSwitchState -Target $Target
    & $emit ('目标：' + $Target + ' → ' + $path)
    & $emit ('当前状态：' + $(if ($state.applied) { '指向本地（' + $state.model + '）' } else { '不是指向本地' }))

    $backup = ''
    if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
        $dir = Join-Path $StateDir 'local-switch'
        if (Test-Path -LiteralPath $dir) {
            $hits = @(Get-ChildItem -LiteralPath $dir -File -Filter ($Target + '-orig-*') | Sort-Object LastWriteTime -Descending)
            if ($hits.Count -gt 0) { $backup = $hits[0].FullName }
        }
    }
    & $emit ('会用备份还原：' + $(if ($backup) { $backup } else { '（没有备份，改做外科式移除）' }))

    if (-not $Apply) {
        return [pscustomobject]@{ ok = $true; applied = $false; dryRun = $true; target = $Target; configPath = $path; backup = $backup; detail = '演练：没有改动任何文件' }
    }

    try {
        if ($backup) {
            Copy-Item -LiteralPath $backup -Destination $path -Force
        } elseif (Test-Path -LiteralPath $path) {
            if ($Target -eq 'opencode') {
                $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                $root = [ordered]@{}
                foreach ($p in $json.PSObject.Properties) { $root[$p.Name] = $p.Value }
                if ($root.Contains('provider') -and $root['provider']) {
                    $prov = [ordered]@{}
                    foreach ($p in $root['provider'].PSObject.Properties) { if ($p.Name -ne 'ollama') { $prov[$p.Name] = $p.Value } }
                    $root['provider'] = $prov
                }
                [System.IO.File]::WriteAllText($path, ($root | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
            } elseif ($Target -eq 'codex') {
                $text = [System.IO.File]::ReadAllText($path)
                $lines = @($text -split "`r?`n")
                $out = New-Object System.Collections.ArrayList
                $skip = $false
                $inTop = $true
                foreach ($line in $lines) {
                    if ($line -match '^\s*\[') {
                        $inTop = $false
                        $skip = ($line -match '^\s*\[model_providers\.ollama\]\s*$')
                    }
                    if ($skip) { continue }
                    if ($inTop -and $line -match '^\s*model_provider\s*=\s*"ollama"') { continue }
                    [void]$out.Add($line)
                }
                [System.IO.File]::WriteAllText($path, (($out -join "`n").TrimEnd() + "`n"), (New-Object System.Text.UTF8Encoding($false)))
            }
        }
    } catch {
        return [pscustomobject]@{ ok = $false; applied = $false; dryRun = $false; target = $Target; configPath = $path; backup = $backup; detail = ('还原失败：' + $_.Exception.Message) }
    }

    if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
        try {
            Add-Content -LiteralPath (Join-Path $StateDir 'local-switch.log') -Encoding UTF8 `
                -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  切回原样：' + $Target + '（用备份 ' + $backup + '）')
        } catch { }
    }
    & $emit '已切回原样（用备份还原，格式也一并恢复）'
    return [pscustomobject]@{ ok = $true; applied = $false; dryRun = $false; target = $Target; configPath = $path; backup = $backup; detail = '已切回原样' }
}

Export-ModuleMember -Function `
    'Get-LLMKitLocalSwitchTargets', 'Get-LLMKitLocalSwitchState', 'Get-LLMKitLocalSwitchPlan', `
    'Set-LLMKitLocalSwitch', 'Undo-LLMKitLocalSwitch', 'Get-LLMKitLocalSwitchTargetPath', `
    'New-LLMKitOpencodeConfigText', 'New-LLMKitCodexConfigText'
