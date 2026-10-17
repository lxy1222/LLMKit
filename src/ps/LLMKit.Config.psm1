#Requires -Version 5.1
<#
    LLMKit 配置写入引擎（M3）
    ------------------------------------------------------------------
    负责把选定渠道的 base_url / key / 模型名写进各个工具的配置文件，
    并在写入前做时间戳备份、写入后可一键还原。

    三条不可退让的设计：

      1. 外科手术式改写，绝不整文件重新序列化。
         用户的 settings.json 里可能有 permissions、hooks、statusLine 等等我们
         完全不了解的字段。用 ConvertFrom-Json + ConvertTo-Json 走一圈，看着"等价"，
         实际会改变数字精度、把非 ASCII 转成 \uXXXX、甚至丢掉我们没建模的结构。
         所以这里用 JSON 文本定位器找到受管区域的精确区间，只替换那一段，
         文件其余部分逐字节不动。

      2. 密钥永不进日志与报告。
         journal 只记脱敏值与摘要；报告里只有掩码。唯一出现明文的地方是
         用户自己指定要写入的那个配置文件。

      3. 未实测过的写入目标默认不写。
         配置里 verified=false 的目标（我们无法在真机上确认其格式的工具），
         必须显式 -AllowUnverifiedTargets 才写。宁可给"请手动填这里"的引导，
         也不要盲写一个可能把工具配置搞坏的格式。
#>

Set-StrictMode -Off

$script:ConfigVersion = '0.1.0'

function Get-LLMKitConfigVersion { $script:ConfigVersion }

function Assert-ConfigPrerequisites {
    $missing = New-Object System.Collections.ArrayList
    foreach ($fn in @('New-InstallSession', 'Add-JournalEntry', 'Save-InstallJournal',
            'Read-TextFileUtf8', 'Write-JsonFile', 'Get-ShortErrorText', 'Get-ObjectProp')) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) { [void]$missing.Add($fn) }
    }
    if ($missing.Count -gt 0) {
        throw ('缺少前置模块函数：' + ($missing -join '、') + '。请先 Import-Module LLMKit.psm1 与 LLMKit.Install.psm1。')
    }
}

# ======================================================================
#  JSON 文本定位与外科改写
# ======================================================================

function ConvertFrom-JsonStringLiteral {
    <# 把 JSON 字符串字面量（含引号）还原成实际字符串 #>
    param([Parameter(Mandatory = $true)][string]$Literal)
    $s = $Literal
    if ($s.Length -ge 2 -and $s[0] -eq '"' -and $s[$s.Length - 1] -eq '"') {
        $s = $s.Substring(1, $s.Length - 2)
    }
    if ($s.IndexOf('\') -lt 0) { return $s }
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $s.Length) {
        $c = $s[$i]
        if ($c -ne '\') { [void]$sb.Append($c); $i++; continue }
        $i++
        if ($i -ge $s.Length) { break }
        $e = $s[$i]
        switch ($e) {
            '"' { [void]$sb.Append('"'); $i++ }
            '\' { [void]$sb.Append('\'); $i++ }
            '/' { [void]$sb.Append('/'); $i++ }
            'b' { [void]$sb.Append([char]8); $i++ }
            'f' { [void]$sb.Append([char]12); $i++ }
            'n' { [void]$sb.Append([char]10); $i++ }
            'r' { [void]$sb.Append([char]13); $i++ }
            't' { [void]$sb.Append([char]9); $i++ }
            'u' {
                if ($i + 4 -lt $s.Length) {
                    $hex = $s.Substring($i + 1, 4)
                    try { [void]$sb.Append([char][Convert]::ToInt32($hex, 16)) } catch { }
                    $i += 5
                } else { $i++ }
            }
            default { [void]$sb.Append($e); $i++ }
        }
    }
    return $sb.ToString()
}

function ConvertTo-JsonStringLiteral {
    <#
        把字符串转成 JSON 字面量（含引号）。
        刻意不转义非 ASCII：我们写的是给人看、也要给人改的配置文件，
        中文就该是中文，而不是 \u4e2d\u6587。
    #>
    # 关于 $null：PowerShell 会先把 $null 转成空串（加 AllowNull 也拦不住，
    # 已实测）。而且对配置值来说这正是我们想要的行为 —— 往 env 里写 JSON null
    # 会让很多工具直接报错，写空串至少是个合法的字符串值。
    # 所以这里不刻意区分 null，一律产出 ""。
    param([AllowNull()][string]$Value)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '"' { [void]$sb.Append('\"') }
            '\' { [void]$sb.Append('\\') }
            "`b" { [void]$sb.Append('\b') }
            "`f" { [void]$sb.Append('\f') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default {
                if ([int][char]$ch -lt 32) { [void]$sb.Append('\u' + ([int][char]$ch).ToString('x4')) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-JsonStringEndIndex {
    <# Text[Start] 必须是引号；返回配对闭合引号的下标；失败返回 -1 #>
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][int]$Start)
    if ($Start -ge $Text.Length -or $Text[$Start] -ne '"') { return -1 }
    $i = $Start + 1
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($c -eq '\') { $i += 2; continue }
        if ($c -eq '"') { return $i }
        $i++
    }
    return -1
}

function Get-JsonValueEndIndex {
    <# Text[Start] 是值的第一个字符；返回该值最后一个字符的下标；失败返回 -1 #>
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][int]$Start)
    if ($Start -ge $Text.Length) { return -1 }
    $c = $Text[$Start]
    if ($c -eq '"') { return (Get-JsonStringEndIndex -Text $Text -Start $Start) }
    if ($c -eq '{' -or $c -eq '[') {
        $open = $c
        $close = '}'
        if ($open -eq '[') { $close = ']' }
        $depth = 0
        $i = $Start
        while ($i -lt $Text.Length) {
            $ch = $Text[$i]
            if ($ch -eq '"') {
                $e = Get-JsonStringEndIndex -Text $Text -Start $i
                if ($e -lt 0) { return -1 }
                $i = $e + 1
                continue
            }
            if ($ch -eq $open) { $depth++ }
            elseif ($ch -eq $close) {
                $depth--
                if ($depth -eq 0) { return $i }
            }
            $i++
        }
        return -1
    }
    # 标量：读到分隔符为止
    $i = $Start
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq ',' -or $ch -eq '}' -or $ch -eq ']' -or [char]::IsWhiteSpace($ch)) { break }
        $i++
    }
    return ($i - 1)
}

function Get-JsonValueKind {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][int]$Start)
    $c = $Text[$Start]
    if ($c -eq '"') { return 'string' }
    if ($c -eq '{') { return 'object' }
    if ($c -eq '[') { return 'array' }
    if ($c -eq 't' -or $c -eq 'f') { return 'boolean' }
    if ($c -eq 'n') { return 'null' }
    return 'number'
}

function Get-JsonMemberSpan {
    <#
        定位**根对象**下某个成员的值区间。

        关键技巧：处理完一个成员后直接把游标跳到它的值之后，
        因此下一次遇到的引号必然又是一个顶层键 —— 不需要维护括号深度计数器。
        这也天然避开了 projects.* 里同名字段的干扰（.claude.json 里就有）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )
    $res = [ordered]@{
        found = $false; nameStart = -1; nameEnd = -1
        valueStart = -1; valueEnd = -1; valueKind = 'unknown'
        indent = 0; error = ''
    }
    if ([string]::IsNullOrEmpty($Text)) { $res.error = 'empty-text'; return [pscustomobject]$res }

    $n = $Text.Length
    $i = 0
    # 跳过 BOM 与空白，找根对象
    if ($n -gt 0 -and [int][char]$Text[0] -eq 0xFEFF) { $i = 1 }
    while ($i -lt $n -and $Text[$i] -ne '{') { $i++ }
    if ($i -ge $n) { $res.error = 'no-root-object'; return [pscustomobject]$res }
    $i++

    while ($i -lt $n) {
        while ($i -lt $n -and ($Text[$i] -eq ',' -or [char]::IsWhiteSpace($Text[$i]))) { $i++ }
        if ($i -ge $n) { break }
        if ($Text[$i] -eq '}') { break }
        if ($Text[$i] -ne '"') { $res.error = ('unexpected-char-at-' + $i); return [pscustomobject]$res }

        $nameStart = $i
        $nameEnd = Get-JsonStringEndIndex -Text $Text -Start $i
        if ($nameEnd -lt 0) { $res.error = 'unterminated-key'; return [pscustomobject]$res }
        $key = ConvertFrom-JsonStringLiteral -Literal $Text.Substring($nameStart, $nameEnd - $nameStart + 1)

        $j = $nameEnd + 1
        while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
        if ($j -ge $n -or $Text[$j] -ne ':') { $res.error = 'expected-colon'; return [pscustomobject]$res }
        $j++
        while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
        if ($j -ge $n) { $res.error = 'expected-value'; return [pscustomobject]$res }

        $valueStart = $j
        $valueEnd = Get-JsonValueEndIndex -Text $Text -Start $j
        if ($valueEnd -lt 0) { $res.error = 'bad-value'; return [pscustomobject]$res }

        if ($key -eq $Name) {
            $lineStart = $Text.LastIndexOf("`n", [Math]::Min($nameStart, $n - 1))
            if ($lineStart -lt 0) { $lineStart = -1 }
            $indent = 0
            for ($k = $lineStart + 1; $k -lt $nameStart; $k++) {
                if ($Text[$k] -eq ' ' -or $Text[$k] -eq "`t") { $indent++ } else { break }
            }
            $res.found = $true
            $res.nameStart = $nameStart; $res.nameEnd = $nameEnd
            $res.valueStart = $valueStart; $res.valueEnd = $valueEnd
            $res.valueKind = Get-JsonValueKind -Text $Text -Start $valueStart
            $res.indent = $indent
            return [pscustomobject]$res
        }
        $i = $valueEnd + 1
    }
    return [pscustomobject]$res
}

function Get-JsonObjectEntries {
    <#
        枚举一个 JSON 对象文本区间内的顶层成员。
        用于读取 env 块里已有的键，才能做到"只增改我们管的，其它原样保留"。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$End
    )
    $entries = New-Object System.Collections.ArrayList
    $i = $Start
    if ($i -ge $Text.Length -or $Text[$i] -ne '{') { return @() }
    $i++
    while ($i -lt $End) {
        while ($i -lt $End -and ($Text[$i] -eq ',' -or [char]::IsWhiteSpace($Text[$i]))) { $i++ }
        if ($i -ge $End -or $Text[$i] -eq '}') { break }
        if ($Text[$i] -ne '"') { break }
        $ks = $i
        $ke = Get-JsonStringEndIndex -Text $Text -Start $i
        if ($ke -lt 0) { break }
        $key = ConvertFrom-JsonStringLiteral -Literal $Text.Substring($ks, $ke - $ks + 1)
        $j = $ke + 1
        while ($j -lt $End -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
        if ($j -ge $End -or $Text[$j] -ne ':') { break }
        $j++
        while ($j -lt $End -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
        $vs = $j
        $ve = Get-JsonValueEndIndex -Text $Text -Start $j
        if ($ve -lt 0) { break }
        [void]$entries.Add([pscustomobject]([ordered]@{
                    name = $key; nameStart = $ks; valueStart = $vs; valueEnd = $ve
                    valueKind = Get-JsonValueKind -Text $Text -Start $vs
                    rawValue = $Text.Substring($vs, $ve - $vs + 1)
                }))
        $i = $ve + 1
    }
    return @($entries)
}

function ConvertTo-JsonObjectBlock {
    <#
        把有序映射渲染成 JSON 对象文本。
        value 字段必须是"已经是合法 JSON 的文本"，由调用方保证。
        自己写序列化器而不是用 ConvertTo-Json：后者在 PowerShell 5.1 会把所有
        非 ASCII 转成 \uXXXX，还会改变数字表示。
    #>
    param(
        [Parameter(Mandatory = $true)]$Map,
        [int]$Indent = 2,
        [string]$NewLine = "`n"
    )
    if ($Map.Count -eq 0) { return '{}' }
    # Indent 指的是"闭合花括号所在列的缩进"，内部键再往右 2 格。
    # 之前写成 $Indent * 2，结果 env 块里的键被顶到 8 格，跟原文件风格对不上。
    $pad = ' ' * $Indent
    $inner = ' ' * ($Indent + 2)
    $lines = New-Object System.Collections.ArrayList
    foreach ($k in $Map.Keys) {
        [void]$lines.Add($inner + (ConvertTo-JsonStringLiteral -Value $k) + ': ' + [string]$Map[$k])
    }
    return '{' + $NewLine + ($lines -join (',' + $NewLine)) + $NewLine + $pad + '}'
}

function Get-TextNewLine {
    param([string]$Text)
    if ($Text -and $Text.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

function Set-JsonMemberText {
    <#
        用新值文本替换某个成员的值区间。
        Span 来自 Get-JsonMemberSpan 或 Get-JsonObjectEntries。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)]$Span,
        [Parameter(Mandatory = $true)][string]$NewValueText
    )
    $before = $Text.Substring(0, $Span.valueStart)
    $after = $Text.Substring($Span.valueEnd + 1)
    return $before + $NewValueText + $after
}

function Add-JsonMemberText {
    <#
        在根对象里插入一个不存在的成员。
        插入位置紧跟根对象的 '{' 之后，保留原文件的换行风格。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ValueText,
        [int]$Indent = 2
    )
    $n = $Text.Length
    $i = 0
    if ($n -gt 0 -and [int][char]$Text[0] -eq 0xFEFF) { $i = 1 }
    while ($i -lt $n -and $Text[$i] -ne '{') { $i++ }
    if ($i -ge $n) { throw '找不到 JSON 根对象，无法插入成员。' }
    $nl = Get-TextNewLine -Text $Text
    $pad = ' ' * $Indent
    $insertAt = $i + 1
    # 判断根对象是否为空
    $j = $insertAt
    while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
    if ($j -lt $n -and $Text[$j] -eq '}') {
        $body = $nl + $pad + (ConvertTo-JsonStringLiteral -Value $Name) + ': ' + $ValueText + $nl
        return $Text.Substring(0, $insertAt) + $body + $Text.Substring($insertAt)
    }
    $body = $nl + $pad + (ConvertTo-JsonStringLiteral -Value $Name) + ': ' + $ValueText + ','
    return $Text.Substring(0, $insertAt) + $body + $Text.Substring($insertAt)
}

# ======================================================================
#  目标解析与取值
# ======================================================================

function Resolve-ConfigValue {
    <#
        解析配置里写的取值模板。支持：
          {key}                    用户提供的 API Key
          {keyOrPlaceholder}       Key，或未提供时的占位提示
          {provider.<字段>}        渠道属性
          {provider.models[0]}     渠道数组字段
          {now}                    当前时间戳
        解析不出来时返回空串，绝不静默塞一个错值进去。
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Template,
        $Provider,
        [string]$ApiKey = '',
        [AllowEmptyString()][string]$SelectedModel = ''
    )
    if ([string]::IsNullOrEmpty($Template)) { return '' }
    $value = $Template
    $value = $value.Replace('{keyOrPlaceholder}', $(if ($ApiKey) { $ApiKey } else { '<在这里粘贴你的 API Key>' }))
    $value = $value.Replace('{key}', $ApiKey)
    $value = $value.Replace('{now}', (Get-Date).ToString('o'))
    # {selectedModel}：用户在界面上选的那个模型名。没选就退回渠道的第一个模型 ——
    # 这样"不指定模型"时行为和以前完全一致，新增变量不会改变既有结果。
    if ($value.Contains('{selectedModel}')) {
        $pick = $SelectedModel
        if ([string]::IsNullOrEmpty($pick) -and $Provider) {
            $models = @(Get-ObjectProp -Object $Provider -Name 'models' | Where-Object { $null -ne $_ -and ([string]$_).Trim() -ne '' })
            if ($models.Count -gt 0) { $pick = [string]$models[0] }
        }
        $value = $value.Replace('{selectedModel}', $pick)
    }
    $rx = [regex]'\{(provider)\.([A-Za-z0-9_]+)(?:\[(\d+)\])?\}'
    $value = $rx.Replace($value, {
            param($m)
            $field = $m.Groups[2].Value
            $idx = $m.Groups[3].Value
            $pv = $null
            if ($Provider) { $pv = Get-ObjectProp -Object $Provider -Name $field }
            if ($null -eq $pv) { return '' }
            if ($idx -ne '') {
                $list = @($pv)
                $k = [int]$idx
                if ($k -lt $list.Count) { return [string]$list[$k] }
                return ''
            }
            return [string]$pv
        })
    return $value
}

function Get-ConfigTargets {
    <# 从 tools.json 里读出各工具的配置写入目标 #>
    param($ConfigRoot, [string[]]$ToolIds = @())
    Assert-ConfigPrerequisites
    $toolsPath = Join-Path $ConfigRoot 'config\tools.json'
    if (-not (Test-Path -LiteralPath $toolsPath)) { throw ('找不到工具配置：' + $toolsPath) }
    $cfg = Read-TextFileUtf8 -Path $toolsPath | ConvertFrom-Json
    $out = New-Object System.Collections.ArrayList
    foreach ($tool in @($cfg.tools)) {
        if ($ToolIds.Count -gt 0 -and ($ToolIds -notcontains $tool.id)) { continue }
        # 注意 `@($null)` 会得到"含一个空元素"的数组 —— 一个完全不写文件的工具（例如 python）
        # 没有 writes 段，过滤掉空值，否则下面会造出一个 path 为空的假目标，
        # 到界面那一层 Test-Path -LiteralPath '' 直接抛错，整页打不开。
        foreach ($w in @(Get-ObjectProp -Object $tool -Name 'writes' | Where-Object { $_ })) {
            [void]$out.Add([pscustomobject]([ordered]@{
                        toolId     = $tool.id
                        toolName   = $tool.name
                        id         = [string]$w.id
                        label      = [string]$w.label
                        path       = [string]$w.path
                        kind       = [string]$w.kind
                        objectPath = [string](Get-ObjectProp -Object $w -Name 'objectPath')
                        entries    = @(Get-ObjectProp -Object $w -Name 'entries')
                        mode       = [string](Get-ObjectProp -Object $w -Name 'mode')
                        verified   = [bool](Get-ObjectProp -Object $w -Name 'verified')
                        notes      = [string](Get-ObjectProp -Object $w -Name 'notes')
                        guidance   = (Get-ObjectProp -Object $w -Name 'guidance')
                    }))
        }
    }
    return @($out)
}

function New-ConfigFileContent {
    <#
        为一个写入目标算出"写入后的完整文件文本"。
        不落盘，纯计算 —— 这样计划阶段就能把改动完整展示给用户确认。
        返回 { ok; content; changes; error }
    #>
    param(
        [Parameter(Mandatory = $true)]$Target,
        $Provider,
        [string]$ApiKey = '',
        [AllowEmptyString()][string]$SelectedModel = ''
    )
    $result = [ordered]@{ ok = $false; content = ''; changes = @(); error = ''; existed = $false }
    $path = [System.Environment]::ExpandEnvironmentVariables($Target.path)
    $existed = Test-Path -LiteralPath $path -PathType Leaf
    $result.existed = $existed
    $text = ''
    if ($existed) {
        try { $text = Read-TextFileUtf8 -Path $path } catch {
            $result.error = Get-ShortErrorText -Text ('读取失败：' + $_.Exception.Message)
            return [pscustomobject]$result
        }
    }

    # ---- 目标类型：JSON 对象内的一组键 ----
    if ($Target.kind -eq 'json-object-patch') {
        $changes = New-Object System.Collections.ArrayList
        $map = [ordered]@{}
        $nl = Get-TextNewLine -Text $text

        # 先收集对象里已有的键（保持原有顺序）
        $objName = $Target.objectPath
        if ($objName) {
            $span = Get-JsonMemberSpan -Text $text -Name $objName
            if ($existed -and -not $span.found) {
                # 缺这个对象：新建一个，插到根对象开头
                $inner = [ordered]@{}
                foreach ($e in @($Target.entries)) {
                    $nm = [string](Get-ObjectProp -Object $e -Name 'name')
                    $tpl = [string](Get-ObjectProp -Object $e -Name 'valueTemplate')
                    $val = Resolve-ConfigValue -Template $tpl -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel
                    [void]$inner.Add($nm, (Get-EntryValueLiteral -Entry $e -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel))
                    [void]$changes.Add([pscustomobject]@{ name = $nm; from = '(不存在)'; to = (Get-EntryDisplayValue -Entry $e -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel) })
                }
                $block = ConvertTo-JsonObjectBlock -Map $inner -Indent 2 -NewLine $nl
                $text = Add-JsonMemberText -Text $text -Name $objName -ValueText $block -Indent 2
                $result.content = $text
                $result.changes = @($changes)
                $result.ok = $true
                return [pscustomobject]$result
            }
            if (-not $existed) {
                # 全新文件：直接构造
                foreach ($e in @($Target.entries)) {
                    $nm = [string](Get-ObjectProp -Object $e -Name 'name')
                    $tpl = [string](Get-ObjectProp -Object $e -Name 'valueTemplate')
                    $val = Resolve-ConfigValue -Template $tpl -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel
                    [void]$map.Add($nm, (Get-EntryValueLiteral -Entry $e -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel))
                    [void]$changes.Add([pscustomobject]@{ name = $nm; from = '(文件不存在)'; to = (Get-EntryDisplayValue -Entry $e -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel) })
                }
                $block = ConvertTo-JsonObjectBlock -Map $map -Indent 2 -NewLine $nl
                $fresh = [ordered]@{}
                $fresh[$objName] = $block
                $result.content = ConvertTo-JsonObjectBlock -Map $fresh -Indent 0 -NewLine $nl + $nl
                $result.changes = @($changes)
                $result.ok = $true
                return [pscustomobject]$result
            }

            # 对象已存在：按原有顺序走一遍，受管的换成新值、非受管原样保留，
            # 最后再把原本没有的受管键追加到末尾。
            # 这样键的顺序与用户文件一致 —— 无谓地打乱顺序会让人以为改动很大。
            $existing = @(Get-JsonObjectEntries -Text $text -Start $span.valueStart -End $span.valueEnd)
            $managed = @{}
            foreach ($e in @($Target.entries)) { $managed[[string](Get-ObjectProp -Object $e -Name 'name')] = $e }
            $emitted = @{}
            foreach ($ent in $existing) {
                $emitted[$ent.name] = $true
                if (-not $managed.ContainsKey($ent.name)) {
                    [void]$map.Add($ent.name, $ent.rawValue)   # 原样保留，连数值写法都不动
                    continue
                }
                $e = $managed[$ent.name]
                $nm = $ent.name
                $newLiteral = Get-EntryValueLiteral -Entry $e -Provider $Provider -ApiKey $ApiKey
                [void]$map.Add($nm, $newLiteral)
                # 比较 JSON 字面量而不是模板解析值：rawValue 条目的模板是空的，
                # 拿空值去比会每次都判定"有改动"，导致反复写入。
                if ($ent.rawValue -ne $newLiteral) {
                    [void]$changes.Add([pscustomobject]@{
                            name = $nm
                            from = (ConvertFrom-JsonStringLiteral -Literal $ent.rawValue)
                            to   = (Get-EntryDisplayValue -Entry $e -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel)
                        })
                }
            }
            foreach ($e in @($Target.entries)) {
                $nm = [string](Get-ObjectProp -Object $e -Name 'name')
                if ($emitted.ContainsKey($nm)) { continue }
                [void]$map.Add($nm, (Get-EntryValueLiteral -Entry $e -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel))
                [void]$changes.Add([pscustomobject]@{
                        name = $nm; from = '(不存在)'
                        to = (Get-EntryDisplayValue -Entry $e -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel)
                    })
            }
            $indent = $span.indent + 2
            $block = ConvertTo-JsonObjectBlock -Map $map -Indent $span.indent -NewLine $nl
            $result.content = Set-JsonMemberText -Text $text -Span $span -NewValueText $block
            $result.changes = @($changes)
            $result.ok = $true
            return [pscustomobject]$result
        }

        # 没有 objectPath：直接在根对象上增改
        foreach ($e in @($Target.entries)) {
            $nm = [string](Get-ObjectProp -Object $e -Name 'name')
            $tpl = [string](Get-ObjectProp -Object $e -Name 'valueTemplate')
            $val = Resolve-ConfigValue -Template $tpl -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel
            $span = $null
            if ($existed) { $span = Get-JsonMemberSpan -Text $text -Name $nm }
            $newValueText = Get-EntryValueLiteral -Entry $e -Provider $Provider -ApiKey $ApiKey
            if ($span -and $span.found) {
                # 同样比较 JSON 字面量：rawValue 条目的模板是空串，
                # 拿空值去比会每次都误报"有改动"，写出一个字节没变却记一笔的假改动。
                $oldLiteral = $text.Substring($span.valueStart, $span.valueEnd - $span.valueStart + 1)
                if ($oldLiteral -ne $newValueText) {
                    $text = Set-JsonMemberText -Text $text -Span $span -NewValueText $newValueText
                    [void]$changes.Add([pscustomobject]@{
                            name = $nm
                            from = (ConvertFrom-JsonStringLiteral -Literal $oldLiteral)
                            to   = (Get-EntryDisplayValue -Entry $e -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel)
                        })
                }
            } else {
                if ($existed) {
                    $text = Add-JsonMemberText -Text $text -Name $nm -ValueText $newValueText -Indent 2
                } else {
                    $text = '{' + (Get-TextNewLine -Text "`n") + '  ' + (ConvertTo-JsonStringLiteral -Value $nm) + ': ' + $newValueText + (Get-TextNewLine -Text "`n") + '}'
                    $text = $text + (Get-TextNewLine -Text "`n")
                }
                [void]$changes.Add([pscustomobject]@{ name = $nm; from = '(不存在)'; to = (Get-EntryDisplayValue -Entry $e -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel) })
            }
        }
        $result.content = $text
        $result.changes = @($changes)
        $result.ok = $true
        return [pscustomobject]$result
    }

    # ---- 目标类型：key=value 环境文件 ----
    if ($Target.kind -eq 'env-file') {
        $changes = New-Object System.Collections.ArrayList
        $lines = @()
        if ($existed) { $lines = @($text -split "`r?`n") }
        foreach ($e in @($Target.entries)) {
            $nm = [string](Get-ObjectProp -Object $e -Name 'name')
            $tpl = [string](Get-ObjectProp -Object $e -Name 'valueTemplate')
            $val = Resolve-ConfigValue -Template $tpl -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel
            $old = ''
            $found = $false
            for ($k = 0; $k -lt $lines.Count; $k++) {
                if ($lines[$k] -match ('^\s*' + [regex]::Escape($nm) + '\s*=')) {
                    $old = ($lines[$k] -split '=', 2)[1]
                    $lines[$k] = $nm + '=' + $val
                    $found = $true
                    break
                }
            }
            if (-not $found) { $lines += ($nm + '=' + $val) }
            if ($old -ne $val) {
                [void]$changes.Add([pscustomobject]@{ name = $nm; from = (Get-MaskedConfigValue -Name $nm -Value $old); to = (Get-EntryDisplayValue -Entry $e -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel) })
            }
        }
        $nl = Get-TextNewLine -Text $text
        $result.content = (($lines | Where-Object { $_ -ne $null }) -join $nl).TrimEnd("`r", "`n") + $nl
        $result.changes = @($changes)
        $result.ok = $true
        return [pscustomobject]$result
    }

    # ---- 目标类型：只给引导，不写文件 ----
    if ($Target.kind -eq 'guidance') {
        $result.ok = $false
        $result.error = 'guidance-only'
        return [pscustomobject]$result
    }

    $result.error = ('暂不支持的写入类型：' + $Target.kind)
    return [pscustomobject]$result
}

function Get-MaskedConfigValue {
    <# 报告与计划里展示用的脱敏值 #>
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    # 占位符原样展示：它本身就是"请你填这里"的提示，
    # 再按密钥规则掩码成 <在这里粘贴...Key> 会让人误以为那里已经有值了。
    if ($Value.StartsWith('<') -and $Value.EndsWith('>')) { return $Value }
    $secretPattern = 'TOKEN|KEY|SECRET|PASSWORD|AUTH'
    if ($Name -match $secretPattern) {
        if ($Value.Length -le 12) { return '***' }
        return $Value.Substring(0, 6) + '...' + $Value.Substring($Value.Length - 4)
    }
    return $Value
}

function Get-EntryValueLiteral {
    <#
        算出一个配置项的 JSON 值文本。
        支持 rawValue：像 hasCompletedOnboarding 这种必须是布尔值而不是字符串，
        统一走字符串序列化会写出 "true"（带引号），工具读到就当成非法值。
    #>
    param($Entry, $Provider, [string]$ApiKey = '', [AllowEmptyString()][string]$SelectedModel = '')
    $raw = Get-ObjectProp -Object $Entry -Name 'rawValue'
    if ($null -ne $raw -and ([string]$raw) -ne '') { return [string]$raw }
    $tpl = [string](Get-ObjectProp -Object $Entry -Name 'valueTemplate')
    $val = Resolve-ConfigValue -Template $tpl -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel
    return (ConvertTo-JsonStringLiteral -Value $val)
}

function Get-EntryDisplayValue {
    <# 计划里展示用：rawValue 条目显示原始字面量，其余显示脱敏后的解析值 #>
    param($Entry, $Provider, [string]$ApiKey = '', [AllowEmptyString()][string]$SelectedModel = '')
    $raw = Get-ObjectProp -Object $Entry -Name 'rawValue'
    if ($null -ne $raw -and ([string]$raw) -ne '') { return [string]$raw }
    $tpl = [string](Get-ObjectProp -Object $Entry -Name 'valueTemplate')
    $nm = [string](Get-ObjectProp -Object $Entry -Name 'name')
    $val = Resolve-ConfigValue -Template $tpl -Provider $Provider -ApiKey $ApiKey -SelectedModel $SelectedModel
    return (Get-MaskedConfigValue -Name $nm -Value $val)
}

# ======================================================================
#  真实可用性验证
# ======================================================================

function Test-ProviderEndpoint {
    <#
        拿真实凭据打一次最小请求，验证"这个 key + 这个 base_url + 这个模型"确实能用。
        这是整个工具最有价值的一步：新手卡住的地方十有八九是这里，而只看配置文件
        写得对不对是查不出来的。

        只要收到 HTTP 响应就算"链路通"，再按状态码与响应体分类给出人话解释。
    #>
    param(
        # 空 key 必须允许：新手最常见的状态就是"还没拿到 key"，
        # 这时工具应当只写 base_url 与模型名、把 key 留成占位符，而不是直接崩掉。
        # 之前标了 Mandatory，导致这条被文档化的路径根本走不通（实测撞到）。
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$BaseUrl,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ApiKey,
        [ValidateSet('anthropic', 'openai')][string]$Style = 'anthropic',
        [string]$Model = '',
        [int]$TimeoutMs = 30000,
        [string]$Proxy
    )
    $out = [ordered]@{
        ok = $false; kind = 'unknown'; hint = ''; httpStatus = $null
        model = $Model; style = $Style; endpoint = ''; elapsedMs = 0
        error = ''; responseSnippet = ''
    }
    if ([string]::IsNullOrEmpty($BaseUrl) -or [string]::IsNullOrEmpty($ApiKey)) {
        $out.kind = 'not-configured'
        $out.hint = '缺少 base_url 或 API Key，无法验证。'
        return [pscustomobject]$out
    }

    $base = $BaseUrl.TrimEnd('/')
    $url = $base
    if ($Style -eq 'anthropic') {
        if ($base -notmatch '/v1$') { $url = $base + '/v1/messages' } else { $url = $base + '/messages' }
    } else {
        if ($base -notmatch '/v\d+$') { $url = $base + '/v1/chat/completions' } else { $url = $base + '/chat/completions' }
    }
    $out.endpoint = $url

    $body = [pscustomobject]@{
        model      = $Model
        max_tokens = 8
        messages   = @([pscustomobject]@{ role = 'user'; content = 'ping' })
    }
    $bodyText = $body | ConvertTo-Json -Depth 6 -Compress

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    $stream = $null
    $reader = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.UserAgent = 'LLMKit/0.1.0'
        if ($Style -eq 'anthropic') {
            $req.Headers['x-api-key'] = $ApiKey
            $req.Headers['anthropic-version'] = '2023-06-01'
        } else {
            $req.Headers['Authorization'] = 'Bearer ' + $ApiKey
        }
        if ($Proxy) { $req.Proxy = New-Object System.Net.WebProxy($Proxy, $true) }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
        $req.ContentLength = $bytes.Length
        $rs = $req.GetRequestStream()
        $rs.Write($bytes, 0, $bytes.Length)
        $rs.Close()

        $resp = $req.GetResponse()
        $out.httpStatus = [int]$resp.StatusCode
        $stream = $resp.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $out.responseSnippet = Get-ShortErrorText -Text $text
        $out.ok = $true
        $out.kind = 'ok'
        $out.hint = '连通性与鉴权都正常，这个 key 可以直接用。'
    } catch {
        $msg = $_.Exception.Message
        $status = $null
        $bodyText2 = ''
        try {
            $we = $_.Exception
            if ($we.Response) {
                $status = [int]$we.Response.StatusCode
                $sr = New-Object System.IO.StreamReader($we.Response.GetResponseStream())
                $bodyText2 = $sr.ReadToEnd()
            }
        } catch { }
        $out.httpStatus = $status
        if ($bodyText2) { $out.responseSnippet = Get-ShortErrorText -Text $bodyText2 }
        $out.error = Get-ShortErrorText -Text $msg

        $classifier = Get-Command -Name 'Get-NetworkErrorKind' -ErrorAction SilentlyContinue
        $kind = 'unknown'
        if ($classifier) { $kind = [string](& $classifier -Message $msg) }

        if ($status -eq 401 -or $status -eq 403) {
            $out.kind = 'auth-failed'
            $out.hint = 'Key 被拒绝了（' + $status + '）。检查：① key 是否复制完整、有没有多余空格；② key 是否属于当前这个渠道（不同平台的 key 不通用）；③ 该 key 是否被删除或停用。'
        } elseif ($status -eq 402 -or ($status -eq 429 -and $bodyText2 -match 'balance|quota|余额|额度|insufficient')) {
            $out.kind = 'no-balance'
            $out.hint = '账户余额或额度不足（' + $status + '）。需要去渠道控制台充值或领取免费额度。'
        } elseif ($status -eq 429) {
            $out.kind = 'rate-limited'
            $out.hint = '请求过于频繁（429）。稍等一会儿再试，或检查该 key 的并发限制。'
        } elseif ($status -eq 404) {
            $out.kind = 'model-or-path'
            $out.hint = '接口或模型不存在（404）。多半是 base_url 写错了，或模型名在这个渠道下不叫这个名字。当前用的是 ' + $url + ' 与模型 ' + $Model + '。'
        } elseif ($status -eq 400 -and $bodyText2 -match 'model') {
            $out.kind = 'model-or-path'
            $out.hint = '渠道说模型名不对（400）。请到渠道控制台确认该模型的确切名称。'
        } else {
            $out.kind = $kind
            $hintFn = Get-Command -Name 'Get-NetworkErrorHint' -ErrorAction SilentlyContinue
            if ($hintFn) { $out.hint = [string](& $hintFn -Kind $kind) }
        }
    } finally {
        if ($reader) { try { $reader.Close() } catch { } }
        if ($stream) { try { $stream.Close() } catch { } }
        if ($resp) { try { $resp.Close() } catch { } }
    }
    $sw.Stop()
    $out.elapsedMs = [int]$sw.ElapsedMilliseconds
    return [pscustomobject]$out
}

# ======================================================================
#  配置写入计划
# ======================================================================

function New-LLMKitConfigPlan {
    <#
        产出配置写入计划。纯计算：只读文件、算内容，不写任何东西。
        计划里就能看到每个文件"会变成什么样"以及密钥的脱敏前后对比。
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigRoot,
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [AllowEmptyString()][string]$ApiKey = '',
        [string[]]$OnlyTools = @(),
        [AllowEmptyString()][string]$Model = '',
        [switch]$SkipOnboarding,
        [switch]$AllowUnverifiedTargets,
        [switch]$NoVerify
    )
    Assert-ConfigPrerequisites
    if ([string]::IsNullOrEmpty($ConfigRoot)) {
        $here = $PSScriptRoot
        $ConfigRoot = Split-Path -Parent (Split-Path -Parent $here)
    }
    $providersPath = Join-Path $ConfigRoot 'config\providers.json'
    if (-not (Test-Path -LiteralPath $providersPath)) { throw ('找不到渠道目录：' + $providersPath) }
    $catalog = Read-TextFileUtf8 -Path $providersPath | ConvertFrom-Json
    $provider = @($catalog.providers | Where-Object { $_.id -eq $ProviderId })
    if ($provider.Count -eq 0) {
        throw ('未知渠道：' + $ProviderId + '。可用：' + (($catalog.providers | ForEach-Object { $_.id }) -join '、'))
    }
    $provider = $provider[0]

    $toolIds = @($OnlyTools | Where-Object { $_ })
    $targets = @(Get-ConfigTargets -ConfigRoot $ConfigRoot -ToolIds $toolIds)

    $items = New-Object System.Collections.ArrayList
    foreach ($t in $targets) {
        if ($t.id -eq 'claude-onboarding' -and -not $SkipOnboarding) {
            [void]$items.Add([pscustomobject]([ordered]@{
                        id = $t.id; toolId = $t.toolId; toolName = $t.toolName; label = $t.label
                        path = $t.path; kind = $t.kind; action = 'held'; verified = $t.verified
                        reason = '未开启 -SkipOnboarding，保持现状（如果你希望 Claude Code 首次启动不弹交互式引导，加上这个开关）'
                        changes = @(); notes = $t.notes; guidance = $null; existed = (Test-Path -LiteralPath ([System.Environment]::ExpandEnvironmentVariables($t.path)) -PathType Leaf)
                    }))
            continue
        }
        if ($t.kind -eq 'guidance') {
            $entries = New-Object System.Collections.ArrayList
            foreach ($e in @($t.entries)) {
                [void]$entries.Add([pscustomobject]@{
                        name = [string](Get-ObjectProp -Object $e -Name 'name')
                        value = Get-MaskedConfigValue -Name ([string](Get-ObjectProp -Object $e -Name 'name')) -Value (Resolve-ConfigValue -Template ([string](Get-ObjectProp -Object $e -Name 'valueTemplate')) -Provider $provider -ApiKey $ApiKey -SelectedModel $Model)
                    })
            }
            [void]$items.Add([pscustomobject]([ordered]@{
                        id = $t.id; toolId = $t.toolId; toolName = $t.toolName; label = $t.label
                        path = $t.path; kind = $t.kind; action = 'guidance'; verified = $t.verified
                        reason = '该工具由界面或数据库管理，本工具刻意不直接改写'
                        changes = @($entries); notes = $t.notes; guidance = $t.guidance
                        existed = (Test-Path -LiteralPath ([System.Environment]::ExpandEnvironmentVariables($t.path)))
                    }))
            continue
        }

        $calc = New-ConfigFileContent -Target $t -Provider $provider -ApiKey $ApiKey -SelectedModel $Model
        if (-not $calc.ok) {
            [void]$items.Add([pscustomobject]([ordered]@{
                        id = $t.id; toolId = $t.toolId; toolName = $t.toolName; label = $t.label
                        path = $t.path; kind = $t.kind; action = 'error'; verified = $t.verified
                        reason = ('无法生成内容：' + $calc.error); changes = @(); notes = $t.notes
                        guidance = $null; existed = $calc.existed
                    }))
            continue
        }

        $action = 'write'
        $reason = ''
        if (@($calc.changes).Count -eq 0) {
            $action = 'skip'; $reason = '已经就是目标值，无需改动'
        } elseif (-not $t.verified -and -not $AllowUnverifiedTargets) {
            $action = 'unverified-hold'
            $reason = '该写入目标的字段名尚未在真机确认，默认不写。确认你了解风险后可加 -AllowUnverifiedTargets'
        }
        [void]$items.Add([pscustomobject]([ordered]@{
                    id = $t.id; toolId = $t.toolId; toolName = $t.toolName; label = $t.label
                    path = $t.path; kind = $t.kind; action = $action; verified = $t.verified
                    reason = $reason; changes = @($calc.changes); notes = $t.notes
                    guidance = $null; existed = $calc.existed
                    content = $(if ($action -eq 'write' -or $action -eq 'unverified-hold') { $calc.content } else { '' })
                }))
    }

    # 真实可用性验证（可选）
    $verify = $null
    if (-not $NoVerify) {
        $style = 'openai'
        $baseUrl = ''
        if ($provider.anthropicBaseUrl) { $style = 'anthropic'; $baseUrl = [string]$provider.anthropicBaseUrl }
        elseif ($provider.openaiBaseUrl) { $style = 'openai'; $baseUrl = [string]$provider.openaiBaseUrl }
        $model = ''
        if ($provider.models) { $model = [string]@($provider.models)[0] }
        $verify = Test-ProviderEndpoint -BaseUrl $baseUrl -ApiKey $ApiKey -Style $style -Model $model
    }

    return [pscustomobject]([ordered]@{
            schemaVersion = '0.1.0'
            engine        = 'LLMKit.Config/' + $script:ConfigVersion
            generatedAt   = (Get-Date).ToString('o')
            configRoot    = $ConfigRoot
            provider      = [pscustomobject]([ordered]@{
                    id = $provider.id; name = $provider.name; region = $provider.region
                    anthropicBaseUrl = $provider.anthropicBaseUrl
                    openaiBaseUrl    = $provider.openaiBaseUrl
                    models           = @($provider.models)
                    verified         = $provider.verified
                })
            keyProvided   = (-not [string]::IsNullOrEmpty($ApiKey))
            verification  = $verify
            items         = @($items)
        })
}

function Format-LLMKitConfigPlan {
    param([Parameter(Mandatory = $true)]$Plan, [switch]$NoColor)
    $useColor = -not $NoColor
    $say = {
        param($text, $color)
        if ($useColor) { try { Write-Host $text -ForegroundColor $color; return } catch { } }
        try { Write-Host $text } catch { [Console]::Out.WriteLine([string]$text) }
    }

    & $say '' 'Gray'
    & $say '=========== 配置写入计划（尚未执行任何改动） ===========' 'White'
    & $say ('渠道：' + $Plan.provider.name + '（' + $Plan.provider.id + '）') 'White'
    if ($Plan.provider.anthropicBaseUrl) { & $say ('  Claude Code base_url：' + $Plan.provider.anthropicBaseUrl) 'DarkGray' }
    if ($Plan.provider.openaiBaseUrl) { & $say ('  其他工具 base_url：' + $Plan.provider.openaiBaseUrl) 'DarkGray' }
    if ($Plan.provider.models) { & $say ('  模型：' + ($Plan.provider.models -join ', ')) 'DarkGray' }
    & $say ('  API Key：' + $(if ($Plan.keyProvided) { '已提供（全程脱敏显示，不写入日志）' } else { '未提供 —— 会先写入占位符，你稍后自己填' })) $(if ($Plan.keyProvided) { 'Green' } else { 'Yellow' })

    if ($Plan.verification) {
        $v = $Plan.verification
        $vc = 'DarkGray'; $vt = $v.kind
        if ($v.ok) { $vc = 'Green'; $vt = '可用' }
        elseif ($v.kind -eq 'auth-failed') { $vc = 'Red'; $vt = 'Key 被拒绝' }
        elseif ($v.kind -eq 'no-balance') { $vc = 'Red'; $vt = '余额/额度不足' }
        elseif ($v.kind -eq 'model-or-path') { $vc = 'Red'; $vt = '接口或模型名不对' }
        elseif ($v.kind -eq 'not-configured') { $vc = 'DarkGray'; $vt = '未验证（缺 key）' }
        else { $vc = 'Yellow'; $vt = $v.kind }
        & $say ''
        & $say ('【真实可用性验证】' + $vt) $vc
        & $say ('  端点：' + $v.endpoint) 'DarkGray'
        if ($null -ne $v.httpStatus) { & $say ('  HTTP：' + $v.httpStatus + ' / 耗时 ' + $v.elapsedMs + ' ms') 'DarkGray' }
        if ($v.hint) { & $say ('  ' + $v.hint) $vc }
        if ($v.responseSnippet -and -not $v.ok) { & $say ('  响应片段：' + $v.responseSnippet) 'DarkGray' }
    }
    & $say ''

    foreach ($it in $Plan.items) {
        $mark = ' .. '; $color = 'Gray'; $verdict = ''
        switch ($it.action) {
            'skip' { $mark = ' OK '; $color = 'Green'; $verdict = '无需改动' }
            'write' { $mark = ' >> '; $color = 'Yellow'; $verdict = '将写入' }
            'guidance' { $mark = ' ?? '; $color = 'Cyan'; $verdict = '需要你在该工具界面里填（本工具不改它的存储）' }
            'unverified-hold' { $mark = ' !! '; $color = 'Yellow'; $verdict = '字段名未实测，默认不写' }
            'held' { $mark = ' -- '; $color = 'DarkGray'; $verdict = '未开启开关，保持现状' }
            'error' { $mark = ' XX '; $color = 'Red'; $verdict = '无法生成内容' }
        }
        & $say ('[' + $mark + '] ' + $it.toolName + ' · ' + $it.label) $color
        & $say ('        ' + $verdict + $(if ($it.reason) { ' —— ' + $it.reason } else { '' })) 'DarkGray'
        & $say ('        文件：' + $it.path + $(if ($it.existed) { '（已存在，将备份后合并）' } else { '（将新建）' })) 'DarkGray'
        foreach ($c in @($it.changes)) {
            if ($c.PSObject.Properties['from']) {
                & $say ('          · ' + $c.name + ' : ' + $(if ($c.from) { $c.from } else { '(空)' }) + '  →  ' + $c.to) 'DarkGray'
            } else {
                & $say ('          · ' + $c.name + ' = ' + $c.value) 'Cyan'
            }
        }
        if ($it.notes) { & $say ('        说明：' + $it.notes) 'DarkGray' }
        if ($it.action -eq 'guidance' -and $it.guidance) {
            $why = Get-ObjectProp -Object $it.guidance -Name 'why'
            if ($why) { & $say ('        ' + $why) 'Yellow' }
            foreach ($s in @((Get-ObjectProp -Object $it.guidance -Name 'steps'))) { & $say ('          - ' + $s) 'DarkGray' }
        }
        & $say '' 'Gray'
    }

    $w = @($Plan.items | Where-Object { $_.action -eq 'write' }).Count
    $g = @($Plan.items | Where-Object { $_.action -eq 'guidance' }).Count
    $h = @($Plan.items | Where-Object { $_.action -in @('unverified-hold', 'held') }).Count
    $s = @($Plan.items | Where-Object { $_.action -eq 'skip' }).Count
    & $say ('合计：将写入 ' + $w + ' 个文件 / 需手动填 ' + $g + ' 处 / 暂缓 ' + $h + ' 处 / 无需改动 ' + $s + ' 处') 'White'
    & $say '======================================================' 'White'
    & $say '' 'Gray'
}

# ======================================================================
#  执行与还原
# ======================================================================

function Invoke-LLMKitConfigSetup {
    <#
        执行配置写入。默认 DryRun，必须显式 -Apply。
        每个被改动的文件都会先做时间戳备份，journal 里记下备份路径，
        因此任何一次写入都可以用 Restore-LLMKitSession 原样还回去。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [switch]$Apply,
        [string]$StateDir,
        [switch]$NoColor
    )
    Assert-ConfigPrerequisites
    if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'LLMKit' }
    $session = New-InstallSession -StateDir $StateDir -DryRun:(-not $Apply)

    $say = {
        param($text, $color)
        if (-not $NoColor) { try { Write-Host $text -ForegroundColor $color; return } catch { } }
        try { Write-Host $text } catch { [Console]::Out.WriteLine([string]$text) }
    }

    $results = New-Object System.Collections.ArrayList
    $targets = @($Plan.items | Where-Object { $_.action -eq 'write' })

    & $say '' 'Gray'
    if ($Apply) {
        & $say ('开始写入配置（会话 ' + $session.id + '）') 'White'
        & $say ('备份区：' + $session.backupDir) 'DarkGray'
        & $say ('还原命令：Setup-LLMKit.ps1 -Restore ' + $session.journalPath) 'DarkGray'
    } else {
        & $say '演练模式（DryRun）：不会写任何文件。' 'Yellow'
    }
    & $say '' 'Gray'

    foreach ($it in $targets) {
        $session.summary.planned++
        $path = [System.Environment]::ExpandEnvironmentVariables($it.path)
        $ok = $true
        $errText = ''
        $backupPath = ''

        if ($Apply) {
            try {
                if (-not (Test-Path -LiteralPath $path)) {
                    $dir = Split-Path -Parent $path
                    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
                } else {
                    # 时间戳备份
                    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
                    $backupPath = Join-Path (Join-Path $session.backupDir 'config') ($it.id + '.' + $stamp + '.bak')
                    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force)
                    Copy-Item -LiteralPath $path -Destination $backupPath -Force
                    Add-JournalEntry -Session $session -Action 'config.backup' -Target $path -After $backupPath -Note '写入前的时间戳备份'
                }

                # 原子写入：先写临时文件再替换，避免写到一半断电/被杀留下半个文件
                $tmp = $path + '.llmkit-tmp'
                [System.IO.File]::WriteAllText($tmp, $it.content, (New-Object System.Text.UTF8Encoding($false)))
                Move-Item -LiteralPath $tmp -Destination $path -Force

                # 回读校验：写得对不对，用解析说话，不靠猜
                $readback = Read-TextFileUtf8 -Path $path
                if ($it.kind -like 'json*') {
                    $null = $readback | ConvertFrom-Json -ErrorAction Stop
                }
                Add-JournalEntry -Session $session -Action 'config.write' -Target $path `
                    -Before $(if ($backupPath) { $backupPath } else { '(文件原不存在)' }) `
                    -After ([ordered]@{ bytes = $readback.Length; changes = @($it.changes).Count }) `
                    -Note ('写入 ' + @($it.changes).Count + ' 项（密钥值不记入日志）')
                $session.summary.succeeded++
            } catch {
                $ok = $false
                $errText = Get-ShortErrorText -Text $_.Exception.Message
                $session.summary.failed++
                Add-JournalEntry -Session $session -Action 'config.write' -Target $path -Status 'failed' -Note $errText
                # 写入失败时立刻尝试把备份还回去，不给用户留一个半坏的文件
                if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
                    try { Copy-Item -LiteralPath $backupPath -Destination $path -Force; $errText += '（已自动还原到写入前的状态）' } catch { }
                }
            }
        } else {
            Add-JournalEntry -Session $session -Action 'config.write' -Target $path -Note ('DryRun：将写入 ' + @($it.changes).Count + ' 项') -Status 'planned'
        }

        [void]$results.Add([pscustomobject]([ordered]@{
                    id = $it.id; toolId = $it.toolId; path = $path; ok = $ok
                    error = $errText; backupPath = $backupPath; changeCount = @($it.changes).Count
                }))

        if ($Apply) {
            if ($ok) { & $say ('  完成：' + $path + '（改动 ' + @($it.changes).Count + ' 项）') 'Green' }
            else { & $say ('  失败：' + $path + ' —— ' + $errText) 'Red' }
            if ($backupPath) { & $say ('        备份：' + $backupPath) 'DarkGray' }
        } else {
            & $say ('  将写入：' + $path + '（改动 ' + @($it.changes).Count + ' 项）') 'DarkGray'
        }
    }

    $journalPath = Save-InstallJournal -Session $session
    & $say '' 'Gray'
    if (-not $Apply) {
        & $say '演练结束：未写任何文件。' 'Yellow'
    } else {
        & $say ('配置写入结束：成功 ' + $session.summary.succeeded + ' / 失败 ' + $session.summary.failed) $(if ($session.summary.failed -gt 0) { 'Red' } else { 'Green' })
        if ($journalPath) { & $say ('还原命令：Setup-LLMKit.ps1 -Restore ' + $journalPath) 'DarkGray' }
    }
    return [pscustomobject]([ordered]@{
            sessionId = $session.id; dryRun = (-not $Apply)
            journalPath = $journalPath; summary = $session.summary; results = @($results)
        })
}

function Restore-ConfigBackups {
    <#
        把某次会话写过的配置文件按备份还原。
        单独抽出来是为了让 Restore-LLMKitSession 能直接复用。
    #>
    param($JournalDocument, [switch]$Apply)
    $actions = New-Object System.Collections.ArrayList
    $backups = @($JournalDocument.entries | Where-Object { $_.action -eq 'config.backup' })
    foreach ($b in $backups) {
        $target = [string]$b.target
        $backup = [string]$b.after
        $exists = (Test-Path -LiteralPath $backup)
        $record = [pscustomobject]@{ kind = 'config.restore'; target = $target; from = $backup; exists = $exists; restored = $false; error = '' }
        if ($exists -and $Apply) {
            try { Copy-Item -LiteralPath $backup -Destination $target -Force; $record.restored = $true }
            catch { $record.error = Get-ShortErrorText -Text $_.Exception.Message }
        }
        [void]$actions.Add($record)
    }
    # 目标文件在写入前不存在的情况：还原等于删掉我们新建的文件
    $writes = @($JournalDocument.entries | Where-Object { $_.action -eq 'config.write' -and ([string]$_.before) -eq '(文件原不存在)' })
    foreach ($w in $writes) {
        $target = [string]$w.target
        $record = [pscustomobject]@{ kind = 'config.remove-created'; target = $target; from = ''; exists = (Test-Path -LiteralPath $target); restored = $false; error = '' }
        if ($Apply -and (Test-Path -LiteralPath $target)) {
            try {
                $moved = $target + '.reverted-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
                Move-Item -LiteralPath $target -Destination $moved -Force
                $record.restored = $true
                $record.from = $moved
            } catch { $record.error = Get-ShortErrorText -Text $_.Exception.Message }
        }
        [void]$actions.Add($record)
    }
    return @($actions)
}

Export-ModuleMember -Function `
    'Get-LLMKitConfigVersion', 'Assert-ConfigPrerequisites', `
    'New-LLMKitConfigPlan', 'Format-LLMKitConfigPlan', 'Invoke-LLMKitConfigSetup', `
    'Test-ProviderEndpoint', 'Restore-ConfigBackups', 'Resolve-ConfigValue', `
    'Get-ConfigTargets', 'New-ConfigFileContent', 'Get-MaskedConfigValue', `
    'Get-JsonMemberSpan', 'Get-JsonObjectEntries', 'Set-JsonMemberText', 'Add-JsonMemberText', `
    'ConvertTo-JsonStringLiteral', 'ConvertFrom-JsonStringLiteral', 'ConvertTo-JsonObjectBlock', `
    'Get-JsonValueEndIndex', 'Get-JsonStringEndIndex', 'Get-TextNewLine', 'Get-EntryValueLiteral', 'Get-EntryDisplayValue'
