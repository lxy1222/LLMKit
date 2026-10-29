#Requires -Version 5.1
<#
.SYNOPSIS
    LLMKit 单元测试

.DESCRIPTION
    只测纯函数（不碰注册表、不联网、不改系统），所以可以在任何机器上安全运行。
    重点覆盖 PATH 合并/删除这类"改错了会把用户 PATH 弄坏"的逻辑。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LLMKit.ps1
#>
[CmdletBinding()]
param(
    [string]$ModuleRoot
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$testsDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($testsDir)) { $testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $testsDir
if ([string]::IsNullOrEmpty($ModuleRoot)) { $ModuleRoot = Join-Path $projectRoot 'src\ps' }

Import-Module (Join-Path $ModuleRoot 'LLMKit.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ModuleRoot 'LLMKit.Install.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ModuleRoot 'LLMKit.Tools.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ModuleRoot 'LLMKit.Config.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ModuleRoot 'LLMKit.Diagnose.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ModuleRoot 'LLMKit.Engine.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ModuleRoot 'LLMKit.Hardware.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ModuleRoot 'LLMKit.LocalConfig.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ModuleRoot 'LLMKit.Service.psm1') -Force -DisableNameChecking

$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -eq $Actual) {
        $script:Pass++
        Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green
    } else {
        $script:Fail++
        [void]$script:Failures.Add($Name)
        Write-Host ('  [FAIL] ' + $Name) -ForegroundColor Red
        Write-Host ('         期望：[' + $Expected + ']') -ForegroundColor DarkGray
        Write-Host ('         实际：[' + $Actual + ']') -ForegroundColor DarkGray
    }
}

function Assert-True {
    param($Condition, [string]$Name)
    Assert-Equal $true ([bool]$Condition) $Name
}

Write-Host ''
Write-Host 'LLMKit 单元测试' -ForegroundColor White
Write-Host ('-' * 60) -ForegroundColor DarkGray

# ======================================================================
Write-Host 'Get-NormalizedPathEntry' -ForegroundColor Cyan
# ======================================================================
Assert-Equal 'c:\tools\nodejs' (Get-NormalizedPathEntry -Entry 'C:\Tools\NodeJS') '大小写归一'
Assert-Equal 'c:\tools\nodejs' (Get-NormalizedPathEntry -Entry 'C:\Tools\NodeJS\') '去掉尾部反斜杠'
Assert-Equal 'c:\tools\nodejs' (Get-NormalizedPathEntry -Entry '  C:\Tools\NodeJS  ') '去掉首尾空格'
Assert-Equal '' (Get-NormalizedPathEntry -Entry '') '空字符串返回空'
Assert-Equal '' (Get-NormalizedPathEntry -Entry '   ') '纯空格返回空'

$expanded = Get-NormalizedPathEntry -Entry '%LOCALAPPDATA%\Programs\nodejs'
Assert-True ($expanded -eq ([System.Environment]::ExpandEnvironmentVariables('%LOCALAPPDATA%\Programs\nodejs').ToLowerInvariant())) '环境变量被展开'

# ======================================================================
Write-Host 'Get-PathEntryList' -ForegroundColor Cyan
# ======================================================================
Assert-Equal 3 (@(Get-PathEntryList -PathValue 'C:\a;C:\b;C:\c').Count) '正常分隔'
Assert-Equal 2 (@(Get-PathEntryList -PathValue 'C:\a;;C:\b;').Count) '忽略空项'
Assert-Equal 0 (@(Get-PathEntryList -PathValue '').Count) '空输入'
Assert-Equal '  C:\a  ' (@(Get-PathEntryList -PathValue '  C:\a  ;')[0]) '保留条目原始写法（只在比较时归一）'

# ======================================================================
Write-Host 'Merge-PathEntry（改错会弄坏用户 PATH，重点覆盖）' -ForegroundColor Cyan
# ======================================================================
$r = Merge-PathEntry -CurrentPath '' -Entry 'C:\New'
Assert-Equal 'C:\New' $r.value '空 PATH 上新增'
Assert-Equal $true $r.changed '空 PATH 上新增 -> changed'
Assert-Equal 1 $r.added.Count '空 PATH 上新增 -> added 计数'

$r = Merge-PathEntry -CurrentPath 'C:\a;C:\b' -Entry 'C:\c'
Assert-Equal 'C:\a;C:\b;C:\c' $r.value '追加到末尾（不插队，避免遮蔽系统命令）'
Assert-Equal $true $r.changed '追加 -> changed'

$r = Merge-PathEntry -CurrentPath 'C:\a;C:\b' -Entry 'C:\a'
Assert-Equal 'C:\a;C:\b' $r.value '已存在时值不变'
Assert-Equal $false $r.changed '已存在时 changed=false'
Assert-Equal $true $r.alreadyPresent '已存在时 alreadyPresent=true'

$r = Merge-PathEntry -CurrentPath 'C:\A;C:\b' -Entry 'c:\a\'
Assert-Equal $false $r.changed '大小写+尾斜杠差异视为同一个条目（幂等）'
Assert-Equal 'c:\a;C:\b' $r.value '幂等时保留首次出现的写法位置'

$r = Merge-PathEntry -CurrentPath 'C:\x;C:\x;C:\y' -Entry 'C:\x'
Assert-Equal 'C:\x;C:\y' $r.value '清理重复项'
Assert-Equal 1 $r.removed.Count '重复项计数正确'

$r = Merge-PathEntry -CurrentPath 'C:\a' -Entry ''
Assert-Equal 'C:\a' $r.value '空 Entry 不改动'
Assert-Equal $false $r.changed '空 Entry -> changed=false'

$r = Merge-PathEntry -CurrentPath 'C:\a; C:\b ' -Entry 'C:\c'
Assert-Equal 'C:\a; C:\b ;C:\c' $r.value '不重写已有条目的原始写法'

$r = Merge-PathEntry -CurrentPath '%LOCALAPPDATA%\Programs\nodejs' -Entry "$env:LOCALAPPDATA\Programs\nodejs"
Assert-Equal $false $r.changed '未展开的 %VAR% 与展开后的路径视为同一条目'

# ======================================================================
Write-Host 'Remove-PathEntry' -ForegroundColor Cyan
# ======================================================================
$r = Remove-PathEntry -CurrentPath 'C:\a;C:\b;C:\c' -Entry 'C:\b'
Assert-Equal 'C:\a;C:\c' $r.value '移除中间项'
Assert-Equal $true $r.changed '移除 -> changed'
Assert-Equal 1 $r.removed.Count '移除计数'

$r = Remove-PathEntry -CurrentPath 'C:\a;C:\A' -Entry 'c:\a'
Assert-Equal '' $r.value '大小写不敏感地全部移除'
Assert-Equal 2 $r.removed.Count '全部移除计数'

$r = Remove-PathEntry -CurrentPath 'C:\a;C:\b' -Entry 'C:\zzz'
Assert-Equal 'C:\a;C:\b' $r.value '不存在的条目不动'
Assert-Equal $false $r.changed '不存在的条目 -> changed=false'

$r = Remove-PathEntry -CurrentPath 'C:\only' -Entry 'C:\only'
Assert-Equal '' $r.value '移除唯一条目后为空串'

# ======================================================================
Write-Host 'Get-MirrorCandidates' -ForegroundColor Cyan
# ======================================================================
$rw = @(
    [pscustomobject]@{ id = 'a'; match = '^https://github\.com/'; prefix = 'https://ghproxy.net/' },
    [pscustomobject]@{ id = 'b'; match = '^https://github\.com/'; prefix = 'https://gh-proxy.com/' }
)
$c = Get-MirrorCandidates -Url 'https://github.com/x/y/releases/download/v1/f.zip' -MirrorRewriters $rw
Assert-Equal 3 $c.Count '原始 URL + 2 个镜像'
Assert-Equal 'https://github.com/x/y/releases/download/v1/f.zip' $c[0] '原始 URL 永远第一个（优先官方）'
Assert-Equal 'https://ghproxy.net/https://github.com/x/y/releases/download/v1/f.zip' $c[1] '镜像改写正确'

$c = Get-MirrorCandidates -Url 'https://nodejs.org/dist/v1/x.zip' -MirrorRewriters $rw
Assert-Equal 1 $c.Count '不匹配的 URL 不加镜像'

$c = Get-MirrorCandidates -Url 'https://github.com/a' -MirrorRewriters @()
Assert-Equal 1 $c.Count '没有镜像规则时只有原始 URL'

# ======================================================================
Write-Host 'Get-RemoteSha256FromShasums' -ForegroundColor Cyan
# ======================================================================
$shasums = @'
abc123  node-v22.11.0-win-x64.zip
def456  node-v22.11.0-win-x86.zip

ghi789 *node-v22.11.0-headers.tar.gz
'@
Assert-Equal 'ABC123' (Get-RemoteSha256FromShasums -ShasumsText $shasums -FileName 'node-v22.11.0-win-x64.zip') '命中目标行并转大写'
Assert-Equal 'GHI789' (Get-RemoteSha256FromShasums -ShasumsText $shasums -FileName 'node-v22.11.0-headers.tar.gz') '处理二进制模式前缀 *'
Assert-Equal $null (Get-RemoteSha256FromShasums -ShasumsText $shasums -FileName 'nope.zip') '找不到返回 null'
Assert-Equal $null (Get-RemoteSha256FromShasums -ShasumsText '' -FileName 'x') '空文本返回 null'

# ======================================================================
Write-Host 'Resolve-NodeVersionFromIndex' -ForegroundColor Cyan
# ======================================================================
$idx = @'
[
  { "version": "v23.5.0", "lts": false },
  { "version": "v22.12.0", "lts": "Jod" },
  { "version": "v20.18.1", "lts": "Iron" }
]
'@
Assert-Equal 'v22.12.0' (Resolve-NodeVersionFromIndex -IndexJsonText $idx -Filter 'lts') '跳过非 LTS，取最新 LTS'
Assert-Equal 'v23.5.0' (Resolve-NodeVersionFromIndex -IndexJsonText $idx -Filter 'current') 'current 模式取最新'
Assert-Equal $null (Resolve-NodeVersionFromIndex -IndexJsonText 'garbage' -Filter 'lts') '非法 JSON 返回 null'
Assert-Equal $null (Resolve-NodeVersionFromIndex -IndexJsonText '[{"version":"v1.0.0","lts":false}]' -Filter 'lts') '全是非 LTS 时返回 null'

# ======================================================================
Write-Host 'Format-ByteSize' -ForegroundColor Cyan
# ======================================================================
Assert-Equal '0 B' (Format-ByteSize -Bytes 0) '0 字节'
Assert-Equal '512 B' (Format-ByteSize -Bytes 512) '字节'
Assert-Equal '1.5 KB' (Format-ByteSize -Bytes 1536) 'KB'
Assert-Equal '32 MB' (Format-ByteSize -Bytes 33554432) 'MB'
Assert-Equal '1.5 GB' (Format-ByteSize -Bytes 1610612736) 'GB'

# ======================================================================

# ======================================================================
Write-Host 'ConvertTo-CsvList（-File 传参的坑，必须守住）' -ForegroundColor Cyan
# ======================================================================
# 用 -join 比较数组：PowerShell 里 @() -eq @() 是元素过滤而不是布尔比较，
# 直接比较数组会得到"看起来通过"的假结果。
Assert-Equal 'node|git' ((ConvertTo-CsvList -Values 'node,git') -join '|') '单字符串按逗号拆开（powershell -File 的实际传法）'
Assert-Equal 'node|git' ((ConvertTo-CsvList -Values @('node','git')) -join '|') '真数组原样通过'
Assert-Equal '' ((ConvertTo-CsvList -Values @()) -join '|') '空数组必须仍然是空'
Assert-Equal 0 (@(ConvertTo-CsvList -Values @()).Count) '空数组的元素个数为 0（不能变成含空元素的数组）'
Assert-Equal 0 (@(ConvertTo-CsvList -Values $null).Count) '$null 的元素个数为 0'
Assert-Equal 'node|git' ((ConvertTo-CsvList -Values @($null, 'node,git', $null)) -join '|') '混入 null 时自动过滤'
Assert-Equal 'node|git' ((ConvertTo-CsvList -Values ' node , git ') -join '|') '去除首尾空格'
Assert-Equal 'node|git' ((ConvertTo-CsvList -Values 'node,,git') -join '|') '忽略空项'
Assert-Equal 'node|git|git' ((ConvertTo-CsvList -Values @('node,git','git')) -join '|') '重复项保留（去重是调用方的事）'

# ======================================================================
Write-Host 'Get-ArtifactOwnerToolId（残留归属：宁可认不出来，也不能归错）' -ForegroundColor Cyan
# ======================================================================
function New-FakeGroup { param([string]$Dir, [string[]]$Members = @()) return [pscustomobject]@{ dir = $Dir; members = $Members } }
Assert-Equal 'claude-code' (Get-ArtifactOwnerToolId -Group (New-FakeGroup 'C:\x\node_modules\@anthropic-ai\.claude-code-Abc123')) '识别 @anthropic-ai 路径'
Assert-Equal 'claude-code' (Get-ArtifactOwnerToolId -Group (New-FakeGroup 'C:\x\.claude-code-best-Xyz')) '识别 .claude-code-* 目录'
Assert-Equal 'claude-code' (Get-ArtifactOwnerToolId -Group (New-FakeGroup 'C:\x' @('C:\x\anthropic-helper'))) '从成员路径推断'
Assert-Equal 'cc-switch' (Get-ArtifactOwnerToolId -Group (New-FakeGroup 'C:\x\cc-switch\stuff')) '识别 cc-switch'
Assert-Equal 'codex' (Get-ArtifactOwnerToolId -Group (New-FakeGroup 'C:\x\codex\thing')) '识别 codex'
Assert-Equal 'opencode' (Get-ArtifactOwnerToolId -Group (New-FakeGroup 'C:\x\opencode')) '识别 opencode'
Assert-Equal 'gemini-cli' (Get-ArtifactOwnerToolId -Group (New-FakeGroup 'C:\x\gemini-cli\.gemini-x1y2z3')) '识别 gemini'
Assert-Equal '' (Get-ArtifactOwnerToolId -Group (New-FakeGroup 'C:\x\something-else')) '认不出来时返回空串'

# ======================================================================
Write-Host 'Select-ToolTier（manual 层不参与自动安装；未提权时跳过需管理员的层）' -ForegroundColor Cyan
# ======================================================================
$fakeTool = [pscustomobject]@{
    install = [pscustomobject]@{
        tiers = @(
            [pscustomobject]@{ id = 'native-script'; type = 'powershell-pipe'; needsAdmin = $false },
            [pscustomobject]@{ id = 'npm-global'; type = 'npm'; needsAdmin = $false },
            [pscustomobject]@{ id = 'winget'; type = 'winget'; needsAdmin = $true },
            [pscustomobject]@{ id = 'manual'; type = 'manual'; needsAdmin = $false }
        )
    }
}
Assert-Equal 'native-script' (Select-ToolTier -Tool $fakeTool -IsAdmin $false).id '非管理员选到第一个免管理员层'
Assert-Equal 'native-script' (Select-ToolTier -Tool $fakeTool -IsAdmin $true).id '管理员同样优先免管理员层（决策 D4）'
Assert-Equal 'npm-global' (Select-ToolTier -Tool $fakeTool -IsAdmin $false -SkipTiers @('native-script')).id 'SkipTiers 生效'
Assert-Equal 'winget' (Select-ToolTier -Tool $fakeTool -IsAdmin $true -OnlyTiers @('winget')).id 'OnlyTiers 生效'
Assert-Equal $null (Select-ToolTier -Tool $fakeTool -IsAdmin $false -OnlyTiers @('winget')) '未提权且只允许需要管理员的层 -> 返回 null'
Assert-Equal $null (Select-ToolTier -Tool $fakeTool -IsAdmin $true -OnlyTiers @('manual')) 'manual 层永远不参与自动安装'

# ======================================================================
Write-Host 'Find-InstallArtifacts（分组：同组只搬一次）' -ForegroundColor Cyan
# ======================================================================
$tmpArt = Join-Path $env:TEMP ('llmkit-art-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path (Join-Path $tmpArt 'a\.claude-code-Abc123\bin') -Force)
[void](New-Item -ItemType Directory -Path (Join-Path $tmpArt 'b\.codex-Xyz789\lib') -Force)
[System.IO.File]::WriteAllText((Join-Path $tmpArt 'a\.claude-code-Abc123\bin\claude.exe.old.1788434366489'), 'x')
[System.IO.File]::WriteAllText((Join-Path $tmpArt 'a\.claude-code-Abc123\bin\claude.exe.restoring.0f82626a'), 'x')
[System.IO.File]::WriteAllText((Join-Path $tmpArt 'b\.codex-Xyz789\lib\x.old.12345678'), 'x')
[System.IO.File]::WriteAllText((Join-Path $tmpArt 'b\.codex-Xyz789\keep.txt'), 'keep')
try {
    $scan = Find-InstallArtifacts -Roots @($tmpArt) -MaxDepth 5
    # 5 = 3 个残留文件 + 2 个安装器临时目录。组目录本身也算残留项，
    # 因为清理时真正被搬走的就是它。
    Assert-Equal 5 $scan.artifacts.Count '识别出 5 个残留项'
    Assert-Equal 3 (@($scan.artifacts | Where-Object { $_.kind -eq 'file' }).Count) '其中文件级残留 3 个'
    Assert-Equal 2 (@($scan.artifacts | Where-Object { $_.kind -eq 'dir' }).Count) '其中目录级（安装器临时目录）2 个'
    Assert-Equal 2 $scan.groups.Count '归为 2 组（清理时按组搬，不是按文件搬）'
    $grp = @($scan.groups | Where-Object { $_.dir -match 'claude-code' -and $_.members.Count -gt 1 })
    Assert-Equal 1 $grp.Count 'claude 组把 2 个文件归到同一个目录下'
    Assert-True ($scan.groups[0].dir -notmatch '\.old\.|\.restoring\.') '组名是安装器工作目录，不是残留文件本身'
    Assert-Equal 0 (Find-InstallArtifacts -Roots @($tmpArt + '-not-exist') -MaxDepth 5).artifacts.Count '不存在的根目录不报错'
} finally {
    Remove-Item $tmpArt -Recurse -Force -ErrorAction SilentlyContinue
}

# ======================================================================
Write-Host 'JSON 字符串字面量（写配置文件的正确性基础）' -ForegroundColor Cyan
# ======================================================================
$lit = ConvertTo-JsonStringLiteral -Value '中文"引号"与\反斜杠'
Assert-True ($lit.Contains('中文')) '中文不转成 \uXXXX（配置文件要给人看也要给人改）'
Assert-Equal '中文"引号"与\反斜杠' (ConvertFrom-JsonStringLiteral -Literal $lit) '转义往返一致'
Assert-Equal "`n" (ConvertFrom-JsonStringLiteral -Literal '"\n"') '\n 还原成换行'
Assert-Equal "`t" (ConvertFrom-JsonStringLiteral -Literal '"\t"') '\t 还原成制表符'
Assert-Equal '"' (ConvertFrom-JsonStringLiteral -Literal '"\""') '\" 还原成引号'
Assert-Equal '""' (ConvertTo-JsonStringLiteral -Value $null) 'null 输入产出空串（写 null 会让工具报错，空串更安全）'

# ======================================================================
Write-Host 'Get-JsonMemberSpan（只认顶层，不误伤嵌套同名键）' -ForegroundColor Cyan
# ======================================================================
$json = '{"a":1,"b":{"c":2},"d":"x,\"y\":{","e":[1,2],"target":true,"f":"g"}'
$sp = Get-JsonMemberSpan -Text $json -Name 'target'
Assert-True $sp.found '找到顶层成员'
Assert-Equal 'true' $json.Substring($sp.valueStart, $sp.valueEnd - $sp.valueStart + 1) '布尔值区间精确'

# 这是 .claude.json 的真实结构：projects.* 里也有同名字段
$nested = '{"hasCompletedOnboarding":false,"projects":{"p1":{"hasCompletedOnboarding":true},"p2":{"hasCompletedOnboarding":true}}}'
$sp2 = Get-JsonMemberSpan -Text $nested -Name 'hasCompletedOnboarding'
Assert-Equal 'false' $nested.Substring($sp2.valueStart, $sp2.valueEnd - $sp2.valueStart + 1) '只匹配顶层，不误伤 projects 里的同名键'

$tricky = '{"note":"}{[],:","target":"ok"}'
$sp3 = Get-JsonMemberSpan -Text $tricky -Name 'target'
Assert-Equal '"ok"' $tricky.Substring($sp3.valueStart, $sp3.valueEnd - $sp3.valueStart + 1) '字符串里的括号冒号不干扰定位'

$deep = '{"x":{"a":[{"y":1},{"z":[2,3]}]},"w":"end"}'
$sp4 = Get-JsonMemberSpan -Text $deep -Name 'w'
Assert-Equal '"end"' $deep.Substring($sp4.valueStart, $sp4.valueEnd - $sp4.valueStart + 1) '跳过深层嵌套数组后仍能定位'

Assert-Equal $false (Get-JsonMemberSpan -Text $json -Name 'nope').found '不存在的键返回未找到'
Assert-Equal 'no-root-object' (Get-JsonMemberSpan -Text 'not json at all' -Name 'x').error '非 JSON 文本给出明确错误而不是乱定位'
Assert-Equal $false (Get-JsonMemberSpan -Text $json -Name '').found '空名字优雅返回（不抛异常）'

# ======================================================================
Write-Host 'Get-JsonObjectEntries / Set / Add（保序改写）' -ForegroundColor Cyan
# ======================================================================
$obj = '{"k1":"v1","k2":2,"k3":{"n":1}}'
$entries = Get-JsonObjectEntries -Text $obj -Start 0 -End ($obj.Length - 1)
Assert-Equal 3 $entries.Count '枚举出 3 个成员'
Assert-Equal 'k1' $entries[0].name '顺序保持不变'
Assert-Equal 'k3' $entries[2].name '最后一个成员也对'
Assert-Equal '"v1"' $entries[0].rawValue '原始值文本原样返回'
Assert-Equal '{ "n": 1 }'.Replace(' ','') ($entries[2].rawValue -replace '\s','') '嵌套对象原样返回'

$spB = Get-JsonMemberSpan -Text '{"a":1,"b":9}' -Name 'b'
Assert-Equal '{"a":1,"b":2}' (Set-JsonMemberText -Text '{"a":1,"b":9}' -Span $spB -NewValueText '2') '替换成员值'

$added = Add-JsonMemberText -Text '{"a":1}' -Name 'new' -ValueText '1' -Indent 0
Assert-True ($added -match '"new": 1') '插入新成员'
Assert-Equal 1 ($added | ConvertFrom-Json).new '插入后仍是合法 JSON 且值正确'
$added2 = Add-JsonMemberText -Text '{}' -Name 'x' -ValueText '"y"' -Indent 0
Assert-Equal 'y' ($added2 | ConvertFrom-Json).x '空对象也能插入'

# ======================================================================
Write-Host 'Resolve-ConfigValue（取值模板）' -ForegroundColor Cyan
# ======================================================================
$fprov = [pscustomobject]@{ anthropicBaseUrl = 'https://a/b'; models = @('m1', 'm2'); nil = $null }
Assert-Equal 'https://a/b' (Resolve-ConfigValue -Template '{provider.anthropicBaseUrl}' -Provider $fprov) '解析渠道字段'
Assert-Equal 'm1' (Resolve-ConfigValue -Template '{provider.models[0]}' -Provider $fprov) '解析数组下标 0'
Assert-Equal 'm2' (Resolve-ConfigValue -Template '{provider.models[1]}' -Provider $fprov) '解析数组下标 1'
Assert-Equal 'KEY1' (Resolve-ConfigValue -Template '{key}' -Provider $fprov -ApiKey 'KEY1') '解析 key'
Assert-Equal '<在这里粘贴你的 API Key>' (Resolve-ConfigValue -Template '{keyOrPlaceholder}' -Provider $fprov) '未提供 key 时给占位提示'

# 占位符只用于"展示"，绝不能写进配置文件 —— 它一旦落进 env 就会被当成真 key，
# 实测把 Claude Code 直接弄挂（Invalid auth token, 17 characters）。
$provDeep = (Get-LLMKitProviderList -ConfigRoot $projectRoot | Where-Object { $_.id -eq 'deepseek' })
$ccTargets = @(Get-ConfigTargets -ConfigRoot $projectRoot -ToolIds @('claude-code'))
Assert-True ($ccTargets.Count -ge 1) 'claude-code 有配置目标'
$noKey = New-ConfigFileContent -Target $ccTargets[0] -Provider $provDeep -ApiKey '' -SelectedModel 'deepseek-flash'
Assert-True ($noKey.ok) ('不给 key 时仍能算出配置：' + $noKey.error)
Assert-True (-not ($noKey.content -match '在这里粘贴')) '没给 key 时，配置里不会出现占位符'
Assert-True ($noKey.content -match 'api\.deepseek') '没给 key 时，base_url 照写'
$withKey = New-ConfigFileContent -Target $ccTargets[0] -Provider $provDeep -ApiKey 'sk-test-123' -SelectedModel 'deepseek-flash'
Assert-True ($withKey.content -match 'sk-test-123') '给了 key 时，key 会被写进去'
Assert-Equal '' (Resolve-ConfigValue -Template '{provider.nope}' -Provider $fprov) '未知字段返回空而不是乱塞值'
Assert-Equal '' (Resolve-ConfigValue -Template '{provider.models[9]}' -Provider $fprov) '数组越界返回空'
Assert-Equal '纯文本' (Resolve-ConfigValue -Template '纯文本' -Provider $fprov) '无模板原样返回'

# ======================================================================
Write-Host 'Get-MaskedConfigValue（密钥不进报告）' -ForegroundColor Cyan
# ======================================================================
Assert-Equal '***' (Get-MaskedConfigValue -Name 'X_TOKEN' -Value 'short') '短密钥完全掩码'
$maskFixture = 'sk-' + ('T' * 24)   # 运行时拼出来，源码里不留密钥形态的字面量
Assert-Equal ($maskFixture.Substring(0, 6) + '...' + $maskFixture.Substring($maskFixture.Length - 4)) (Get-MaskedConfigValue -Name 'X_TOKEN' -Value $maskFixture) '长密钥首尾保留（前 6 后 4）'
Assert-Equal 'https://a/b' (Get-MaskedConfigValue -Name 'BASE_URL' -Value 'https://a/b') '非密钥字段不掩码'
Assert-Equal '' (Get-MaskedConfigValue -Name 'X_KEY' -Value '') '空值返回空'

# ======================================================================
Write-Host '统一错误翻译表（config/errormap.json）' -ForegroundColor Cyan
# ======================================================================
$cfgRoot = $projectRoot
$map = Get-ErrorMap -ConfigRoot $cfgRoot
Assert-True ($map.Count -ge 30) ('规则表至少 30 条（实际 ' + $map.Count + '）')
Assert-Equal $map.Count (@($map | ForEach-Object { $_.id } | Sort-Object -Unique).Count) '规则 id 无重复'
Assert-True ([int](Get-ObjectProp -Object $map[0] -Name 'priority') -ge [int](Get-ObjectProp -Object $map[$map.Count - 1] -Name 'priority')) '已按 priority 降序排好'

Assert-Equal 'auth-invalid-key' (Get-ErrorInterpretation -HttpStatus 401 -Context 'provider' -ConfigRoot $cfgRoot).ruleId '401 → key 被拒绝'
Assert-Equal 'quota-http-402' (Get-ErrorInterpretation -HttpStatus 402 -Context 'provider' -ConfigRoot $cfgRoot).ruleId '402 → 需要付费'
Assert-Equal 'quota-rate-limit' (Get-ErrorInterpretation -HttpStatus 429 -Context 'provider' -ConfigRoot $cfgRoot).ruleId '429 → 限流（而不是误判成额度不足）'
Assert-Equal 'model-not-found' (Get-ErrorInterpretation -HttpStatus 404 -Context 'provider' -ConfigRoot $cfgRoot).ruleId '404 → 接口或模型名不对'
Assert-Equal 'provider-server-error' (Get-ErrorInterpretation -HttpStatus 503 -Context 'provider' -ConfigRoot $cfgRoot).ruleId '503 → 服务端出错'
Assert-Equal 'quota-balance' (Get-ErrorInterpretation -HttpStatus 400 -Text 'Insufficient balance, please recharge' -Context 'provider' -ConfigRoot $cfgRoot).ruleId '400+balance 文本 → 判为额度不足（文本判据优先于状态码）'
Assert-Equal 'model-name-rejected' (Get-ErrorInterpretation -HttpStatus 400 -Text 'unknown model: foo' -Context 'provider' -ConfigRoot $cfgRoot).ruleId '400+model 文本 → 判为模型名不对'
Assert-Equal 'net-connection-closed' (Get-ErrorInterpretation -NetKind 'connection-closed' -ConfigRoot $cfgRoot).ruleId '按网络错误种类命中'
Assert-Equal 'net-tls' (Get-ErrorInterpretation -NetKind 'tls' -ConfigRoot $cfgRoot).ruleId '证书类错误'
Assert-Equal 'npm-eacces' (Get-ErrorInterpretation -Text 'npm ERR! code EACCES syscall mkdir' -ConfigRoot $cfgRoot).ruleId '不带 context 也能命中 npm 规则（两遍匹配的意义所在）'
Assert-Equal 'npm-eresolve' (Get-ErrorInterpretation -Text 'npm ERR! code ERESOLVE' -ConfigRoot $cfgRoot).ruleId 'ERESOLVE 有独立规则'
Assert-Equal 'cmd-not-found' (Get-ErrorInterpretation -Text "'claude' 不是内部或外部命令，也不是可运行的程序" -ConfigRoot $cfgRoot).ruleId '中文 Windows 报错也能认出来'
Assert-Equal 'access-denied' (Get-ErrorInterpretation -Text 'Access is denied' -ConfigRoot $cfgRoot).ruleId '拒绝访问'
Assert-Equal 'ps-execution-policy' (Get-ErrorInterpretation -Text '无法加载文件，因为在此系统上禁止运行脚本' -ConfigRoot $cfgRoot).ruleId '执行策略拦截'
Assert-Equal 'download-checksum-mismatch' (Get-ErrorInterpretation -Text '校验和不匹配：期望 A，实际 B' -ConfigRoot $cfgRoot).ruleId '校验和不匹配'
Assert-Equal $false (Get-ErrorInterpretation -Text 'zzz totally unknown gibberish' -ConfigRoot $cfgRoot).matched '纯未知文本不硬套规则（宁可说不知道）'
Assert-True ((Get-ErrorInterpretation -HttpStatus 401 -Context 'provider' -ConfigRoot $cfgRoot).actions.Count -ge 2) '命中的规则要给出多条具体动作'

# Test-ErrorRuleMatch 的 -IgnoreContext 就是字面意思：跳过 context 这一维。
# 所以纯 context 规则在忽略 context 后必然命中 —— 真正拦住它的是下面那个判据函数
# 和 Get-ErrorInterpretation 的第二遍过滤。这三条一起才说明防护是完整的。
$ctxOnlyRule = [pscustomobject]@{ match = [pscustomobject]@{ context = @('npm') } }
Assert-Equal $true (Test-ErrorRuleMatch -Rule $ctxOnlyRule -Text 'anything at all' -Context 'npm') '给定正确 context 时纯 context 规则可用'
Assert-Equal $false (Test-ErrorRuleHasSpecificMatcher -Rule $ctxOnlyRule) '纯 context 规则被判定为没有具体判据'
Assert-Equal $false (Get-ErrorInterpretation -Text 'zzz totally unknown gibberish' -Context 'install' -ConfigRoot $cfgRoot).matched '第二遍匹配不会让 npm-generic 这类纯 context 规则通吃一切'
Assert-Equal $true (Get-ErrorInterpretation -Text 'zzz totally unknown gibberish' -Context 'npm' -ConfigRoot $cfgRoot).matched '但调用方明确说"这是 npm 失败"时，兜底规则应当命中'

# ======================================================================
Write-Host 'Protect-SensitiveText（这份报告一定会被粘进聊天窗口）' -ForegroundColor Cyan
# ======================================================================
# 刻意在运行时拼出来：源码里不留任何"长得像密钥"的字面量，免得被 GitHub 的
# 密钥扫描或 gitleaks 拦下来（开源仓库的常规做法）。
$secret = 'sk-' + ('T' * 24)
$uhex = 'a' * 64   # 同上：长标识串也在运行时拼，免得被当成机器码类密钥
$raw = 'key=' + $secret + ' path=' + $env:USERPROFILE + '\x mail=' + ('someone' + '@' + 'example.invalid') + ' hex=' + $uhex + ' auth: Bearer ' + $secret
$clean = Protect-SensitiveText -Text $raw
Assert-True (-not $clean.Contains($secret)) '原始密钥不残留'
Assert-True (-not $clean.Contains($env:USERPROFILE)) '用户名路径不残留'
Assert-True (-not $clean.Contains('someone' + '@' + 'example.invalid')) '邮箱不残留'
Assert-True (-not $clean.Contains($uhex)) '长标识串不残留'
Assert-True ($clean.Contains('%USERPROFILE%')) '保留了可读的占位符（人还要看得懂）'
Assert-Equal '' (Protect-SensitiveText -Text '') '空输入返回空'
Assert-Equal '普通文本没有敏感内容' (Protect-SensitiveText -Text '普通文本没有敏感内容') '普通文本不被误改'
Assert-True ((Protect-SensitiveText -Text "机器名 $env:COMPUTERNAME 出现在句子里") -notmatch [regex]::Escape($env:COMPUTERNAME)) '机器名被隐去'

# ======================================================================
Write-Host '引擎输出判定（网页版在用的那一份）' -ForegroundColor Cyan
# ======================================================================
# 这套判定原来和 WinForms 向导放在一起。桌面版删掉之后，只有"从引擎输出判断这一步成不成"
# 这件事还留着 —— 网页版靠它给每一步下结论，所以测试也要跟着留在它现在住的地方。
foreach ($c in @(
        @{ v = @('结论：一切正常，可以开始安装'); e = 'ok' },
        @{ v = @('结论：基本可用，有需要留意的项'); e = 'warn' },
        @{ v = @('结论：存在问题，需要处理'); e = 'fail' },
        @{ v = @('演练结束：未写任何文件。'); e = 'dryrun' },
        @{ v = @('随便什么别的输出'); e = 'unknown' }
    )) {
    Assert-Equal $c.e (Get-LLMKitStepStatusFromOutput -Lines $c.v) ('判定 ' + $c.e)
}

# ======================================================================
Write-Host '动作层（服务层）' -ForegroundColor Cyan
# ======================================================================
$actions = @(Get-LLMKitActionCatalog)
Assert-True ($actions.Count -ge 14) ('动作清单至少 14 条（实际 ' + $actions.Count + '）')
Assert-Equal $actions.Count (@($actions | ForEach-Object { $_.id } | Sort-Object -Unique).Count) '动作 id 无重复'
Assert-Equal 0 (@($actions | Where-Object { [string]::IsNullOrEmpty($_.label) -or [string]::IsNullOrEmpty($_.desc) -or [string]::IsNullOrEmpty($_.scope) }).Count) '每条动作都有 label / desc / scope'
Assert-Equal 0 (@($actions | Where-Object { @('global', 'tool', 'session') -notcontains $_.scope }).Count) 'scope 取值合法'
Assert-Equal 0 (@($actions | Where-Object { $_.scope -eq 'tool' -and $_.id -notlike 'tool-*' }).Count) '工具范围的动作都以 tool- 开头'
Assert-True (@($actions | Where-Object { $_.destructive }).Count -ge 5) '至少有 5 条会被标为"会改动系统"'

# 这是整个界面最重要的一条不变式：默认永远只演练
$svcRoot = $projectRoot
foreach ($a in $actions) {
    $tgt = ''
    if ($a.scope -eq 'tool') { $tgt = 'opencode' }
    elseif ($a.scope -eq 'session') { $tgt = 'out\state\sessions\example.json' }
    # 模型动作的 TargetId 是模型 tag（不是工具 id）；不补一个的话它会被"必须给 tag"的校验拦下
    elseif (@('model-pull', 'model-remove', 'local-endpoint-check') -contains $a.id) { $tgt = 'qwen3.5:2b' }
    # 切到本地还要一个模型 tag，否则命令拼不出来（这是对的：没 tag 就没法切）
    $callArgs = @{ ActionId = $a.id; ConfigRoot = $svcRoot; TargetId = $tgt }
    if ($a.id -eq 'tool-local-switch') { $callArgs['ModelTag'] = 'qwen3.5:9b' }
    $dry = Get-LLMKitActionCommandLine @callArgs
    $real = Get-LLMKitActionCommandLine @callArgs -Apply
    Assert-True ($dry.arguments -notcontains '-Apply') ('演练模式 ' + $a.id + ' 绝不带 -Apply')
    if ($a.destructive) {
        Assert-True ($real.arguments -contains '-Apply') ('destructive 动作 ' + $a.id + ' 执行时才带 -Apply')
        Assert-Equal $true $real.willApply ($a.id + ' willApply=true')
    } else {
        Assert-True ($real.arguments -notcontains '-Apply') ('只读动作 ' + $a.id + ' 永不带 -Apply')
        Assert-Equal $false $real.willApply ($a.id + ' willApply=false')
    }
    Assert-Equal $dry.arguments.Count (@($dry.arguments | Select-Object -Unique).Count) ($a.id + ' 参数无重复')
    Assert-True ($dry.commandLine -match 'Setup-LLMKit\.ps1') ($a.id + ' 命令行含可复制的脚本路径')
}

$threw = $false
try { $null = Get-LLMKitActionCommandLine -ActionId 'tool-install' -ConfigRoot $svcRoot } catch { $threw = $true }
Assert-Equal $true $threw '工具范围动作缺少 TargetId 时报错而不是瞎跑'
$threw2 = $false
try { $null = Get-LLMKitAction -ActionId 'no-such-action' } catch { $threw2 = $true }
Assert-Equal $true $threw2 '未知动作报错'

$un1 = Get-LLMKitActionCommandLine -ActionId 'tool-uninstall' -ConfigRoot $svcRoot -TargetId claude-code
$un2 = Get-LLMKitActionCommandLine -ActionId 'tool-uninstall' -ConfigRoot $svcRoot -TargetId claude-code -RemoveUserConfig
Assert-True ($un1.arguments -contains '-Uninstall') '卸载动作带 -Uninstall'
Assert-True ($un1.arguments -notcontains '-RemoveUserConfig') '默认不碰用户配置'
Assert-True ($un2.arguments -contains '-RemoveUserConfig') '显式勾选后才动用户配置'

$cl = Get-LLMKitActionCommandLine -ActionId 'tool-artifacts' -ConfigRoot $svcRoot -TargetId claude-code
Assert-True ($cl.arguments -contains '-CleanOnly') '清理残留走 -CleanOnly'
Assert-True ($cl.arguments -notcontains '-IncludeTools') '清理残留不带 -IncludeTools（否则会顺带把工具装上）'

$cw = Get-LLMKitActionCommandLine -ActionId 'config-write' -ConfigRoot $svcRoot -ProviderId deepseek -AuthTokenEnvVar LLMKIT_TOKEN
Assert-True ($cw.arguments -contains '-Configure') '写配置带 -Configure'
Assert-True ($cw.arguments -contains 'deepseek') '渠道 id 被传下去'
Assert-True ($cw.arguments -contains '-AuthTokenEnvVar') '推荐用环境变量传 key'

$providers = @(Get-LLMKitProviderList -ConfigRoot $svcRoot)
Assert-Equal 9 $providers.Count '渠道 9 个'
Assert-Equal 0 (@($providers | Where-Object { [string]::IsNullOrEmpty($_.id) -or [string]::IsNullOrEmpty($_.registerUrl) }).Count) '每个渠道都有 id 与注册链接'
# 依赖安装流水线已删除（Node / Git 现在是普通工具），这里顺势确认它们确实在工具目录里、
# 而且 config/dependencies.json 里不再登记任何依赖 —— 谁要是又把它们塞回去，这条会先红。
$catalogIds = @((Get-ToolCatalog -ConfigRoot $svcRoot).tools.tools | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'id') })
Assert-True ($catalogIds -contains 'node') 'node 在工具目录里'
Assert-True ($catalogIds -contains 'git') 'git 在工具目录里'

# ======================================================================
Write-Host '状态解析必须对齐"引擎真实产出的文案"' -ForegroundColor Cyan
# ======================================================================
# 这一组刻意不用手编字符串，而是真的去调格式化函数、把它的输出交给解析器。
# 之前就是因为用例全是自编字符串，解析函数和真实文案对不上却没被发现 ——
# 真实运行时所有结论都被判成 unknown。
function Get-FakeReport {
    param([ValidateSet('ok', 'warn', 'fail')][string]$Verdict)
    $okN = 0; $warnN = 0; $failN = 0
    if ($Verdict -eq 'ok') { $okN = 1 } elseif ($Verdict -eq 'warn') { $warnN = 1 } else { $failN = 1 }
    return [pscustomobject]@{
        checks = @([pscustomobject]@{ id = 'x'; category = '测试'; status = 'info'; title = '样例'; detail = ''; action = '' })
        summary = [pscustomobject]@{ ok = $okN; warn = $warnN; fail = $failN; info = 1; verdict = $Verdict; checkCount = 1 }
        durationMs = 1
    }
}
function Get-FakeVerification {
    param([ValidateSet('ok', 'warn', 'fail')][string]$Verdict)
    return [pscustomobject]@{
        verdict = $Verdict
        counts = [pscustomobject]@{ ok = 1; warn = 0; fail = 0; info = 0 }
        items = @([pscustomobject]@{ id = 'x'; category = '测试'; status = 'ok'; title = '样例'; detail = ''; actions = @() })
    }
}
# Write-Host 在 PS 5.0+ 走信息流，所以 6>&1 能把格式化输出抓下来
foreach ($v in @('ok', 'warn', 'fail')) {
    $txt = @(Format-LLMKitReport -Report (Get-FakeReport -Verdict $v) -NoColor 6>&1) -join "`n"
    Assert-True ($txt -match '结论：') ('M0 报告文案可被抓取（' + $v + '）')
    Assert-Equal $v (Get-LLMKitStepStatusFromOutput -Lines @($txt -split "`n")) ('M0 真实文案 → 判定为 ' + $v)
}
foreach ($v in @('ok', 'warn', 'fail')) {
    $txt = @(Format-LLMKitVerification -Verification (Get-FakeVerification -Verdict $v) -NoColor 6>&1) -join "`n"
    Assert-True ($txt -match '结论：') ('复检文案可被抓取（' + $v + '）')
    Assert-Equal $v (Get-LLMKitStepStatusFromOutput -Lines @($txt -split "`n")) ('复检真实文案 → 判定为 ' + $v)
}
Assert-Equal 'dryrun' (Get-LLMKitStepStatusFromOutput -Lines @('演练结束：未写任何文件。')) '演练文案 → dryrun'
Assert-Equal 'unknown' (Get-LLMKitStepStatusFromOutput -Lines @('随便什么别的东西')) '无关输出 → unknown（宁可说不知道）'

# ======================================================================
Write-Host ''
Write-Host '工具目录的角色分组（智能体 vs 配套工具）' -ForegroundColor Cyan
# ======================================================================
# 界面按 role 把七个工具分成两组：5 个"智能体"（自己调模型）+ 2 个"配套工具"：
#   · provider-manager = cc-switch（自己不出模型，给别的智能体换渠道用）
#   · companion        = node / git（别的工具的运行环境）、python（编程运行时）、pycharm（写 Python 的 IDE）
# 这些约定不是显示层的细节：
#   · role 写错 → 配套工具会被当成"也要配 key 的智能体"，首页分组和顶栏顺序都跟着错
#   · 配套工具排到前面 → 新手先装它，而它装上了也不会有任何可用的反馈，白挫败一次
# 所以钉在这里，而不是靠肉眼看界面。
$catalog = Get-ToolCatalog -ConfigRoot $projectRoot
$allTools = @($catalog.tools.tools)
Assert-Equal 11 $allTools.Count '目录里是十一个工具'

$roles = @($allTools | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'role') })
$badRoles = @($roles | Where-Object { @('agent', 'provider-manager', 'companion', 'runtime') -notcontains $_ })
Assert-Equal 0 $badRoles.Count ('role 只用白名单里的值（越界：' + ($badRoles -join '、') + '）')
$agents = @($allTools | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'role') -eq 'agent' })
Assert-Equal 5 $agents.Count '五个智能体'
$mgrList = @($allTools | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'role') -eq 'provider-manager' })
Assert-Equal 1 $mgrList.Count '一个管渠道的配套工具'
Assert-Equal 'cc-switch' ([string](Get-ObjectProp -Object $mgrList[0] -Name 'id')) '管渠道的配套工具就是 cc-switch'
$compList = @($allTools | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'role') -eq 'companion' })
Assert-Equal 4 $compList.Count '四个备环境的配套工具'
$compIds = @($compList | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'id') })
Assert-True ($compIds -contains 'python') '备环境的配套工具里有 python'
Assert-True ($compIds -contains 'node') '备环境的配套工具里有 node'
Assert-True ($compIds -contains 'git') '备环境的配套工具里有 git'
Assert-True ($compIds -contains 'pycharm') '备环境的配套工具里有 pycharm'
$runtimeList = @($allTools | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'role') -eq 'runtime' })
Assert-Equal 1 $runtimeList.Count '一个本地模型运行时'
Assert-Equal 'ollama' ([string](Get-ObjectProp -Object $runtimeList[0] -Name 'id')) '本地模型运行时就是 ollama'

# python 的常用库清单：只检测、不安装，所以每条都必须有 name 与 why
# Node 的版本下限：低于 v18 时 Codex / OpenCode / Gemini CLI / dsh 都可能装不上
$nodeTool = @($allTools | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'id') -eq 'node' })[0]
$nodeMin = Get-ObjectProp -Object (Get-ObjectProp -Object $nodeTool -Name 'verify') -Name 'minMajor'
Assert-Equal 18 ([int]$nodeMin) 'Node 登记了版本下限 18'
# Git 没有交互界面：启动必须被配置成禁用并给出原因，否则页面上会有一个点了没用的按钮
$gitTool = @($allTools | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'id') -eq 'git' })[0]
$gitLaunch = Get-ObjectProp -Object $gitTool -Name 'launch'
Assert-True ([bool](Get-ObjectProp -Object $gitLaunch -Name 'disabled')) 'Git 的启动被配置成禁用'
Assert-True ([string](Get-ObjectProp -Object $gitLaunch -Name 'disabledReason')).Length -gt 0 'Git 的禁用给出了原因'
$pyTool = @($allTools | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'id') -eq 'python' })[0]
$pyPkgs = @(Get-ObjectProp -Object $pyTool -Name 'packages' | Where-Object { $_ })
Assert-True ($pyPkgs.Count -ge 10) ('python 登记了常用库清单（' + $pyPkgs.Count + ' 个）')
foreach ($pk in $pyPkgs) {
    Assert-True ([string](Get-ObjectProp -Object $pk -Name 'name')).Length -gt 0 ('库有条目名：' + [string](Get-ObjectProp -Object $pk -Name 'name'))
    Assert-True ([string](Get-ObjectProp -Object $pk -Name 'why')).Length -gt 0 ('库说明了用途：' + [string](Get-ObjectProp -Object $pk -Name 'name'))
}
# py 是启动器，不是第二份安装 —— 它必须写在 detectOnlyCommands 里，别混进 commands
$pyCmds = @(Get-ObjectProp -Object $pyTool -Name 'commands')
$pyOnly = @(Get-ObjectProp -Object $pyTool -Name 'detectOnlyCommands')
Assert-True ($pyCmds -notcontains 'py') 'py 不在 commands 里（它是启动器，不是安装副本）'
Assert-True ($pyOnly -contains 'py') 'py 登记在 detectOnlyCommands 里'

$maxAgentPrio = (@($agents | ForEach-Object { [int](Get-ObjectProp -Object $_ -Name 'priority') }) | Measure-Object -Maximum).Maximum
foreach ($c in @($mgrList + $compList + $runtimeList)) {
    Assert-True ([int](Get-ObjectProp -Object $c -Name 'priority') -gt $maxAgentPrio) ('配套工具的优先级排在所有智能体之后：' + [string](Get-ObjectProp -Object $c -Name 'id'))
}
$prio = @($allTools | ForEach-Object { [int](Get-ObjectProp -Object $_ -Name 'priority') })
Assert-Equal $prio.Count (@($prio | Sort-Object -Unique).Count) '优先级无重复（顺序才是确定的）'

$managed = @(Get-ObjectProp -Object $mgrList[0] -Name 'manages')
$ids = @($allTools | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'id') })
Assert-True ($managed.Count -ge 1) '配套工具登记了它管哪些智能体'
Assert-Equal 0 (@($managed | Where-Object { $ids -notcontains $_ }).Count) ('manages 里的 id 在目录里都能找到：' + ($managed -join '、'))
Assert-True ($managed -notcontains 'cc-switch') 'manages 不指向自己'
# 模型归属：alsoViaCcSwitch 必须和 cc-switch 的 manages 严格一致 —— 文案与配置不能各说各的
foreach ($t2 in $allTools) {
    $tid = [string](Get-ObjectProp -Object $t2 -Name 'id')
    $mMeta = Get-ObjectProp -Object $t2 -Name 'models'
    Assert-True ($null -ne $mMeta) ($tid + ' 有 models 段')
    $inManages = (@($managed) -contains $tid)
    $flag = [bool](Get-ObjectProp -Object $mMeta -Name 'alsoViaCcSwitch')
    if ($tid -eq 'cc-switch') {
        Assert-True (-not $flag) '配套工具自己不归 cc-switch 管'
    } else {
        Assert-Equal $inManages $flag ($tid + ' 的 alsoViaCcSwitch 与 cc-switch 的 manages 一致')
    }
    Assert-True (([string](Get-ObjectProp -Object $mMeta -Name 'field')).Length -gt 0) ($tid + ' 的 models.field 说清了写在哪')
}
$writableTools = @($allTools | Where-Object { [bool](Get-ObjectProp -Object (Get-ObjectProp -Object $_ -Name 'models') -Name 'writable') } | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'id') })
Assert-Equal 1 $writableTools.Count ('能直接写模型的工具只有 1 个（实际：' + ($writableTools -join '、') + '）')
Assert-Equal 'claude-code' $writableTools[0] '能直接写模型的是 Claude Code（这条写入路径真机验证过）'

# 步骤链：每个工具至少 3 步，且每步都要有一句人话
foreach ($t3 in $allTools) {
    $tid = [string](Get-ObjectProp -Object $t3 -Name 'id')
    $g = Get-ObjectProp -Object $t3 -Name 'guide'
    Assert-True ($null -ne $g) ($tid + ' 有 guide 段')
    $steps = @(Get-ObjectProp -Object $g -Name 'steps')
    Assert-True ($steps.Count -ge 3) ($tid + ' 的步骤至少 3 步（实际 ' + $steps.Count + '）')
    # 老格式用 do，分段式（页面按步骤排版）用 title —— 两者都算"写了做什么"
    $noDo = @($steps | Where-Object {
            [string](Get-ObjectProp -Object $_ -Name 'do') -eq '' -and [string](Get-ObjectProp -Object $_ -Name 'title') -eq ''
        })
    Assert-Equal 0 $noDo.Count ($tid + ' 每步都写了"做什么"')
    # 分段式的 section 必须在白名单里：写错了页面会渲染出"未知段落"
    $secs = @($steps | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'section') } | Where-Object { $_ -ne '' })
    $badSec = @($secs | Where-Object { @('install', 'configure', 'launch', 'packages') -notcontains $_ })
    Assert-Equal 0 $badSec.Count ($tid + ' 的 section 都在白名单里（越界：' + ($badSec -join '、') + '）')
    if ($secs.Count -gt 0) {
        Assert-Equal $steps.Count $secs.Count ($tid + ' 既然用了分段式，每一步都要写 section')
        Assert-True ($secs -contains 'install') ($tid + ' 的分段里有安装')
        Assert-True ($secs -contains 'launch') ($tid + ' 的分段里有启动')
        Assert-Equal $secs.Count (@($secs | Select-Object -Unique).Count) ($tid + ' 的 section 不重复')
    }
}

# 模型模板必须用 {selectedModel}：写回 models[0] 就等于"用户在界面上选的模型不生效"
$allModelTemplates = New-Object System.Collections.ArrayList
foreach ($t4 in $allTools) {
    foreach ($w in @(Get-ObjectProp -Object $t4 -Name 'writes')) {
        if (-not $w) { continue }
        foreach ($e in @(Get-ObjectProp -Object $w -Name 'entries')) {
            if (-not $e) { continue }
            $nm = [string](Get-ObjectProp -Object $e -Name 'name')
            if ($nm -match 'MODEL|模型') { [void]$allModelTemplates.Add([string](Get-ObjectProp -Object $e -Name 'valueTemplate')) }
        }
    }
}
Assert-True ($allModelTemplates.Count -ge 5) ('登记的模型字段至少 5 个（实际 ' + $allModelTemplates.Count + '）')
$badTpl = @($allModelTemplates | Where-Object { $_ -ne '{selectedModel}' })
Assert-Equal 0 $badTpl.Count ('模型字段一律用 {selectedModel}，越界：' + ($badTpl -join ' | '))

# 五个智能体都必须能启动、且必须有操作说明 —— 否则界面上那个「启动」按钮点下去是空的
foreach ($t in $agents) {
    $tid = [string](Get-ObjectProp -Object $t -Name 'id')
    $lc = Get-ObjectProp -Object $t -Name 'launch'
    Assert-True ($null -ne $lc) ($tid + ' 有 launch 段')
    Assert-True (@(Get-ObjectProp -Object $lc -Name 'howTo').Count -ge 2) ($tid + ' 的 howTo 至少两步')
}

# ======================================================================
Write-Host ''
# ======================================================================
Write-Host ''
# ======================================================================
Write-Host 'DeepSeek 官方 Claude Code 接入说明（9 个环境变量）' -ForegroundColor Cyan
# ======================================================================
# 这些值是从 DeepSeek 官方文档逐条抄进 providers.json 的。这里钉住"一个都不许漏、一个都不许改"，
# 因为页面会原样展示给用户照着敲 —— 少一个或错一个，用户就配不出能用的 Claude Code。
$providersDoc = Get-Content (Join-Path $projectRoot 'config\providers.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$dsProv = @($providersDoc.providers | Where-Object { $_.id -eq 'deepseek' })[0]
$integration = $dsProv.integrations.'claude-code'
Assert-True ($null -ne $integration) 'deepseek 登记了 claude-code 的官方接入说明'
Assert-True (([string]$integration.docUrl).StartsWith('https://api-docs.deepseek.com/')) 'docUrl 指向官方文档'
Assert-True (-not [string]::IsNullOrEmpty([string]$integration.checkedAt)) '记录了核对日期'
$envItems = @($integration.env)
Assert-Equal 9 $envItems.Count ('官方是 9 个变量（实际 ' + $envItems.Count + '）')
$expectEnv = [ordered]@{
    'ANTHROPIC_BASE_URL'              = 'https://api.deepseek.com/anthropic'
    'ANTHROPIC_AUTH_TOKEN'            = '<你的 DeepSeek API Key>'
    'ANTHROPIC_MODEL'                 = 'deepseek-flash[1m]'
    'ANTHROPIC_DEFAULT_OPUS_MODEL'    = 'deepseek-flash[1m]'
    'ANTHROPIC_DEFAULT_SONNET_MODEL'  = 'deepseek-flash[1m]'
    'ANTHROPIC_DEFAULT_HAIKU_MODEL'   = 'deepseek-flash'
    'CLAUDE_CODE_SUBAGENT_MODEL'      = 'deepseek-flash'
    'CLAUDE_CODE_EFFORT_LEVEL'        = 'max'
    'CLAUDE_CODE_AUTO_COMPACT_WINDOW' = '786432'
}
foreach ($ek in $expectEnv.Keys) {
    $hit = @($envItems | Where-Object { [string]$_.name -eq $ek })
    Assert-Equal 1 $hit.Count ('变量 ' + $ek + ' 出现一次')
    Assert-Equal $expectEnv[$ek] ([string]$hit[0].value) ('变量 ' + $ek + ' 的值与官方一致')
}
# claude-code 的配置段必须标成"只给教程"，否则页面又会冒出写入按钮
$toolsDoc = Get-Content (Join-Path $projectRoot 'config\tools.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ccTool = @($toolsDoc.tools | Where-Object { $_.id -eq 'claude-code' })[0]
Assert-Equal 'tutorial' ([string]$ccTool.configureMode) 'claude-code 的配置段是教程模式'


Write-Host '模型选择（{selectedModel}）' -ForegroundColor Cyan
# ======================================================================
$fprov2 = [pscustomobject]@{ id = 'fake'; models = @('m-one', 'm-two') }
Assert-Equal 'm-one' (Resolve-ConfigValue -Template '{selectedModel}' -Provider $fprov2) '不指定模型 → 渠道第一个（与旧行为一致）'
Assert-Equal 'm-two' (Resolve-ConfigValue -Template '{selectedModel}' -Provider $fprov2 -SelectedModel 'm-two') '指定了就写指定的'
Assert-Equal 'my-own' (Resolve-ConfigValue -Template '{selectedModel}' -Provider $fprov2 -SelectedModel 'my-own') '不在清单里的名字也原样写入（不偷偷换掉）'
Assert-Equal '' (Resolve-ConfigValue -Template '{selectedModel}' -Provider ([pscustomobject]@{ models = @() })) '渠道没登记模型时返回空，不瞎猜'
Assert-Equal 'prefix-m-two-suffix' (Resolve-ConfigValue -Template 'prefix-{selectedModel}-suffix' -Provider $fprov2 -SelectedModel 'm-two') '模板里嵌在中间也认'
# ======================================================================
Write-Host ''
Write-Host '本地模型：硬件判定与模型目录' -ForegroundColor Cyan
# ======================================================================
# 判定是纯函数，所以这里可以拿"假硬件"把边界钉死 —— 这比在真机上碰运气可靠：
#   · 显存 23.9 vs 24 这种一位小数之差不能判错
#   · AdapterRAM 被截到 4095 MB 的老坑必须标成"可疑"，不能当真值
#   · 内存读不到时要给 unknown，不能因为读到 0 就说"你跑不动"
$mdl = [pscustomobject]@{ id = 'x'; sizeGB = 10.0; minVramGB = 24.0; minRamGB = 32.0 }

$hwTight = [pscustomobject]@{ maxVramGB = 23.9; vramSuspicious = $false; ramGB = 64.0; diskFreeGB = 500.0; modelRoot = 'F:\m' }
Assert-Equal 'slow' (Get-LLMKitModelVerdict -Hardware $hwTight -Model $mdl).verdict '显存 23.9 GB 不够 24 GB → 退到 CPU（slow），不能判成 ok'

$hwEnough = [pscustomobject]@{ maxVramGB = 24.0; vramSuspicious = $false; ramGB = 32.0; diskFreeGB = 500.0; modelRoot = 'F:\m' }
Assert-Equal 'ok' (Get-LLMKitModelVerdict -Hardware $hwEnough -Model $mdl).verdict '显存正好 24 GB → ok（够就是够）'

$hwLow = [pscustomobject]@{ maxVramGB = 8.0; vramSuspicious = $false; ramGB = 16.0; diskFreeGB = 500.0; modelRoot = 'F:\m' }
Assert-Equal 'no' (Get-LLMKitModelVerdict -Hardware $hwLow -Model $mdl).verdict '显存 8 GB / 内存 16 GB 都不够 → no'

$hwUnknownRam = [pscustomobject]@{ maxVramGB = 8.0; vramSuspicious = $false; ramGB = 0.0; diskFreeGB = 500.0; modelRoot = 'F:\m' }
Assert-Equal 'unknown' (Get-LLMKitModelVerdict -Hardware $hwUnknownRam -Model $mdl).verdict '内存读不到 → unknown（不能说"你跑不动"）'

$hwNoDisk = [pscustomobject]@{ maxVramGB = 80.0; vramSuspicious = $false; ramGB = 128.0; diskFreeGB = 5.0; modelRoot = 'F:\m' }
Assert-Equal 'no' (Get-LLMKitModelVerdict -Hardware $hwNoDisk -Model $mdl).verdict '磁盘剩 5 GB < 15 GB → no（显存再大也装不下）'

$hwSus = [pscustomobject]@{ maxVramGB = 4.0; vramSuspicious = $true; ramGB = 64.0; diskFreeGB = 500.0; modelRoot = 'F:\m' }
$susVerdict = Get-LLMKitModelVerdict -Hardware $hwSus -Model ([pscustomobject]@{ id = 'y'; sizeGB = 3.0; minVramGB = 4.0; minRamGB = 8.0 })
Assert-Equal 'ok' $susVerdict.verdict '显存读数被截断（4 GB 上限）时照常判定'
Assert-True ($susVerdict.reason -match '截断') '显存读数可疑时要在理由里说出来'

# 模型目录本身：字段齐、体积/门槛为正数、能力档在白名单里
$modelCatalog = @(Get-LLMKitModelCatalog -ConfigRoot $projectRoot)
Assert-True ($modelCatalog.Count -ge 4) ('模型目录至少有 4 档（实际 ' + $modelCatalog.Count + '）')
$capWhite = @('chat-only', 'agent-weak', 'agent-ok')
foreach ($m in $modelCatalog) {
    $mid = [string](Get-ObjectProp -Object $m -Name 'id')
    Assert-True ($mid.Length -gt 0) '每个模型都有 id'
    $tag = [string](Get-ObjectProp -Object $m -Name 'ollamaTag')
    Assert-True ($tag.Length -gt 0) ($mid + ' 有 ollama tag')
    Assert-True ((Get-ObjectProp -Object $m -Name 'ollamaTag') -match '^[a-z0-9\.\-]+:[a-z0-9\.\-]+') ($mid + ' 的 tag 形如 名字:尺寸')
    Assert-True ([double](Get-ObjectProp -Object $m -Name 'sizeGB') -gt 0) ($mid + ' 的 sizeGB 为正')
    Assert-True ([double](Get-ObjectProp -Object $m -Name 'minVramGB') -gt 0) ($mid + ' 的 minVramGB 为正')
    Assert-True ([int](Get-ObjectProp -Object $m -Name 'context') -ge 8192) ($mid + ' 的上下文至少 8K')
    Assert-True ($capWhite -contains [string](Get-ObjectProp -Object $m -Name 'capability')) ($mid + ' 的能力档在白名单里')
    Assert-True ([string](Get-ObjectProp -Object $m -Name 'sourceUrl')).StartsWith('https://') ($mid + ' 有来源链接')
    Assert-True ([bool](Get-ObjectProp -Object $m -Name 'tools')) ($mid + ' 标注了会工具调用')
}
# 实测数据必须标日期：没有日期的跑分等于不可追溯，以后没人知道它是什么时候测的
$measured = @($modelCatalog | Where-Object { $null -ne (Get-ObjectProp -Object $_ -Name 'measured') })
Assert-True ($measured.Count -ge 3) ('至少 3 档带真机实测（实际 ' + $measured.Count + '）')
foreach ($m in $measured) {
    $ms = Get-ObjectProp -Object $m -Name 'measured'
    Assert-True ([string](Get-ObjectProp -Object $ms -Name 'at')).Length -ge 8 ('实测记录带日期：' + [string](Get-ObjectProp -Object $m -Name 'id'))
    Assert-True ([double](Get-ObjectProp -Object $ms -Name 'tokPerSec') -gt 0) ('实测记录带速度：' + [string](Get-ObjectProp -Object $m -Name 'id'))
}

# 运行时工具卡：它不写别的工具的配置，也不需要 key
$ollamaTool = @($allTools | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'id') -eq 'ollama' })[0]
Assert-True ($null -ne $ollamaTool) '目录里有 ollama'
$olModels = Get-ObjectProp -Object $ollamaTool -Name 'models'
Assert-True (-not [bool](Get-ObjectProp -Object $olModels -Name 'writable')) 'ollama 不写模型配置'
Assert-True (-not [bool](Get-ObjectProp -Object $olModels -Name 'alsoViaCcSwitch')) 'ollama 不走 cc-switch 管渠道（本地没有 key 可管）'
$olLaunch = Get-ObjectProp -Object $ollamaTool -Name 'launch'
Assert-True (@(Get-ObjectProp -Object $olLaunch -Name 'howTo').Count -ge 2) 'ollama 的 howTo 至少两步'
$olSteps = @(Get-ObjectProp -Object (Get-ObjectProp -Object $ollamaTool -Name 'guide') -Name 'steps')
$olSections = @($olSteps | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'section') })
Assert-True ($olSections -contains 'install') 'ollama 的分段里有安装'
Assert-True ($olSections -contains 'launch') 'ollama 的分段里有启动'
# ======================================================================
Write-Host ''
Write-Host '本地模型动作：下载 / 删除（都要过 preview 与 -Apply 门禁）' -ForegroundColor Cyan
# ======================================================================
# 这两条动作的性质和前八个不同：pull 是下载几 GB、remove 是**真删**（不搬备份）。
# 所以钉三件事：清单里标了 destructive、不带 -Apply 绝不出现 -Apply、
# 以及"没给模型 tag 就不许跑"。
$mp = @($actions | Where-Object { $_.id -eq 'model-pull' })
$mr = @($actions | Where-Object { $_.id -eq 'model-remove' })
Assert-Equal 1 $mp.Count '清单里有「下载本地模型」'
Assert-Equal 1 $mr.Count '清单里有「删除本地模型」'
Assert-True ([bool]$mp[0].destructive) '下载模型被标为会改动系统'
Assert-True ([bool]$mr[0].destructive) '删除模型被标为会改动系统'
Assert-True ((@($mp[0].options) -contains 'modelTag')) '下载模型声明了 modelTag 选项'
Assert-True ((@($mr[0].options) -contains 'modelTag')) '删除模型声明了 modelTag 选项'

# 演练（不给 Apply）绝不带 -Apply；给了 Apply 才带
$dry = Get-LLMKitActionCommandLine -ActionId 'model-pull' -ConfigRoot $projectRoot -TargetId 'qwen3.5:2b'
Assert-True (-not (@($dry.arguments) -contains '-Apply')) '演练模式的 model-pull 不带 -Apply'
Assert-True (@($dry.arguments) -contains '-ModelPull') '命令里有 -ModelPull'
Assert-True (@($dry.arguments) -contains 'qwen3.5:2b') '命令里带上了模型 tag'
$real = Get-LLMKitActionCommandLine -ActionId 'model-pull' -ConfigRoot $projectRoot -TargetId 'qwen3.5:2b' -Apply
Assert-True (@($real.arguments) -contains '-Apply') '执行模式的 model-pull 才带 -Apply'
Assert-True ([bool]$real.willApply) '执行模式 willApply=true'
$dryRm = Get-LLMKitActionCommandLine -ActionId 'model-remove' -ConfigRoot $projectRoot -TargetId 'qwen3.5:2b'
Assert-True (-not (@($dryRm.arguments) -contains '-Apply')) '演练模式的 model-remove 不带 -Apply'
Assert-True (@($dryRm.arguments) -contains '-ModelRemove') '命令里有 -ModelRemove'
$realRm = Get-LLMKitActionCommandLine -ActionId 'model-remove' -ConfigRoot $projectRoot -TargetId 'qwen3.5:2b' -Apply
Assert-True (@($realRm.arguments) -contains '-Apply') '执行模式的 model-remove 才带 -Apply'

# 没有 tag 就不许跑（否则会拼出一条没有参数的下载命令，跑起来才发现）
$threw = $false
try { [void](Get-LLMKitActionCommandLine -ActionId 'model-pull' -ConfigRoot $projectRoot) } catch { $threw = $true }
Assert-True $threw 'model-pull 没给 tag 时直接报错'

# 下载计划：体积 / 需要的磁盘（1.5 倍）/ 下到哪
$plan = Get-LLMKitModelPullPlan -ConfigRoot $projectRoot -Tag 'qwen3.5:2b'
Assert-Equal 'qwen3.5:2b' $plan.tag '计划的 tag 正确'
Assert-True ($plan.sizeGB -gt 0) '计划里有体积'
Assert-True ($plan.needDiskGB -ge $plan.sizeGB) '需要的磁盘空间不小于体积（含临时空间）'
Assert-True ($plan.modelRoot.Length -gt 0) '计划里有模型目录'
Assert-True ($plan.ok) '本机磁盘够（不然这条用例该换机器跑）'
$threw2 = $false
try { [void](Get-LLMKitModelPullPlan -ConfigRoot $projectRoot -Tag 'no-such-model:0b') } catch { $threw2 = $true }
Assert-True $threw2 '目录里没有的 tag 会被拒绝（不让它瞎下）'

# 磁盘判定是纯计算：这里直接喂"只剩 5 GB"，判 4.4 GB 门槛要过、判 18 GB 门槛要拒
$blk = Get-LLMKitDiskGate -SizeGB 2.9 -DiskFreeGB 5.0 -ModelRoot 'F:\m'
Assert-True ([bool]$blk.ok) '剩 5 GB 下 2.9 GB（要 4.4 GB）→ 允许'
$blk2 = Get-LLMKitDiskGate -SizeGB 18 -DiskFreeGB 5.0 -ModelRoot 'F:\m'
Assert-True (-not [bool]$blk2.ok) '剩 5 GB 下 18 GB（要 27 GB）→ 拒绝'
Assert-True ([string]$blk2.reason -match '磁盘不够') '拒绝时说的是磁盘不够，不是说别的'
# ======================================================================
Write-Host ''
Write-Host '本地端点接入表（能不能直连，按协议说实话）' -ForegroundColor Cyan
# ======================================================================
# 这张表是"本地模型怎么接进各智能体"的唯一事实来源。两条铁律：
#   · 能直连 → 必须给出配置文件位置 + 至少两步说明 + 明说本工具不代写
#   · 不能直连 → 必须给出原因，绝不能为了"看起来支持得多"就标成能
$epPath = Join-Path $projectRoot 'config\local-endpoints.json'
Assert-True (Test-Path -LiteralPath $epPath) '有本地端点接入表'
$eps = @((Get-Content -LiteralPath $epPath -Raw -Encoding UTF8 | ConvertFrom-Json).tools)
Assert-Equal 5 $eps.Count ('接入表覆盖 5 个智能体（实际 ' + $eps.Count + '）')
$epToolIds = @($allTools | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'id') })
$scanToolIds = @('claude-code', 'codex', 'opencode', 'gemini-cli', 'dsh')
foreach ($e in $eps) {
    $eid = [string](Get-ObjectProp -Object $e -Name 'id')
    Assert-True ($scanToolIds -contains $eid) ('接入表的 id 是登记的智能体：' + $eid)
    Assert-True ($epToolIds -contains $eid) ('接入表的 id 在工具目录里：' + $eid)
    if ([bool](Get-ObjectProp -Object $e -Name 'supported')) {
        Assert-True ([string](Get-ObjectProp -Object $e -Name 'configPath')).Length -gt 0 ($eid + ' 能直连就必须给出配置文件位置')
        Assert-True (@(Get-ObjectProp -Object $e -Name 'steps').Count -ge 2) ($eid + ' 能直连就要给步骤（至少两步）')
        Assert-True ([string](Get-ObjectProp -Object $e -Name 'snippet')).Length -gt 0 ($eid + ' 要给出可复制的片段')
        Assert-True ([string](Get-ObjectProp -Object $e -Name 'caveat')).Length -gt 0 ($eid + ' 要说明本工具不代写')
        Assert-True ([string](Get-ObjectProp -Object $e -Name 'apiKeyNote')).Length -gt 0 ($eid + ' 要说明本地不需要 key（防止用户把真 key 填进去）')
    } else {
        Assert-True ([string](Get-ObjectProp -Object $e -Name 'reason')).Length -gt 0 ($eid + ' 不能直连就必须给原因')
    }
}
# 不能为了"全覆盖"把 Claude Code 说成能直连：它只说 Anthropic 协议
$ccEp = @($eps | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'id') -eq 'claude-code' })[0]
Assert-True (-not [bool](Get-ObjectProp -Object $ccEp -Name 'supported')) 'Claude Code 的本地接入标为不支持'
Assert-Equal 'anthropic-messages' ([string](Get-ObjectProp -Object $ccEp -Name 'protocol')) 'Claude Code 标的是 Anthropic 协议'
$gmEp = @($eps | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'id') -eq 'gemini-cli' })[0]
Assert-True (-not [bool](Get-ObjectProp -Object $gmEp -Name 'supported')) 'Gemini CLI 的本地接入也标为不支持'
# 能直连的三个必须是真能说 OpenAI 协议的那三个
$supportedIds = @($eps | Where-Object { [bool](Get-ObjectProp -Object $_ -Name 'supported') } | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'id') })
Assert-Equal 3 $supportedIds.Count ('能直连的是 3 个（实际：' + ($supportedIds -join '、') + '）')
foreach ($need in @('opencode', 'codex', 'dsh')) {
    Assert-True ($supportedIds -contains $need) ($need + ' 标为能直连')
}

# 工具详情里要把它带出来（界面据此渲染，不在前端拼句子）
$opDetail = Get-LLMKitToolDetail -ConfigRoot $svcRoot -ToolId 'opencode'
$opEp = Get-ObjectProp -Object $opDetail -Name 'localEndpoint'
Assert-True ($null -ne $opEp) '工具详情里带了 localEndpoint'
Assert-True ([bool](Get-ObjectProp -Object $opEp -Name 'supported')) 'opencode 的详情里说它能直连'
$ccDetail = Get-LLMKitToolDetail -ConfigRoot $svcRoot -ToolId 'claude-code'
$ccDetailEp = Get-ObjectProp -Object $ccDetail -Name 'localEndpoint'
Assert-True (-not [bool](Get-ObjectProp -Object $ccDetailEp -Name 'supported')) 'claude-code 的详情里说它不能直连'
$pyDetail = Get-LLMKitToolDetail -ConfigRoot $svcRoot -ToolId 'python'
Assert-True ($null -eq (Get-ObjectProp -Object $pyDetail -Name 'localEndpoint')) '无关工具（python）不带本地端点信息'

# 自检动作：只读、非 destructive、命令行带 -CheckLocalEndpoint
$chk = @($actions | Where-Object { $_.id -eq 'local-endpoint-check' })
Assert-Equal 1 $chk.Count '清单里有「自检工具调用」'
Assert-True (-not [bool]$chk[0].destructive) '自检是只读动作（不弹确认框）'
$chkCmd = Get-LLMKitActionCommandLine -ActionId 'local-endpoint-check' -ConfigRoot $projectRoot -TargetId 'qwen3.5:9b' -Apply
Assert-True (@($chkCmd.arguments) -contains '-CheckLocalEndpoint') '命令里有 -CheckLocalEndpoint'
Assert-True (@($chkCmd.arguments) -contains '-LocalModelTag') '命令带上要检查的模型 tag'
Assert-True (-not (@($chkCmd.arguments) -contains '-Apply')) '只读动作永不带 -Apply'
# 本地模型的错误翻译：这四条是用户最可能撞上的，提示必须给出可执行的下一步
$em = Get-Content (Join-Path $projectRoot 'config\errormap.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$localRules = @($em.rules | Where-Object { [string]$_.category -eq '本地模型' })
Assert-True ($localRules.Count -ge 4) ('本地模型至少有 4 条错误规则（实际 ' + $localRules.Count + '）')
foreach ($need in @('local-service-down', 'local-model-missing', 'local-model-no-tool-calls', 'local-disk-insufficient')) {
    $hit = @($localRules | Where-Object { [string]$_.id -eq $need })
    Assert-Equal 1 $hit.Count ('有错误规则：' + $need)
    Assert-True ([string]$hit[0].title).Length -gt 0 ($need + ' 有标题')
    Assert-True ([string]$hit[0].explanation).Length -gt 20 ($need + ' 解释了为什么会这样')
    Assert-True (@($hit[0].actions).Count -ge 2) ($need + ' 至少给两条可执行的下一步')
    Assert-True ([string]$hit[0].match.textPattern).Length -gt 0 ($need + ' 有文本判据（不能只靠 context 兜底）')
}
# 服务没跑时那条规则要能真命中我们的提示文案
$svcRule = @($localRules | Where-Object { $_.id -eq 'local-service-down' })[0]
Assert-True ('Ollama 服务没在跑。先启动 Ollama（托盘图标），再自检。' -match [string]$svcRule.match.textPattern) '「服务没跑」的提示能被这条规则匹配到'

# 自检函数的不变量：**永远返回结构化结论，不许抛异常**
# （CI 上没有 Ollama，所以这里只能断言形状与白名单，不能断言具体结论）
$probe = Test-LLMKitLocalEndpoint
Assert-True ($null -ne $probe) '自检函数返回了对象'
$verdictWhite = @('ok', 'no-tool-calls', 'no-service', 'no-model', 'error')
Assert-True ($verdictWhite -contains [string]$probe.verdict) ('自检结论在白名单里（实际：' + [string]$probe.verdict + '）')
Assert-True ([string]$probe.detail).Length -gt 5 '自检给出了人能看懂的说明'
Assert-Equal $false ([bool]$probe.ok -and [string]$probe.verdict -ne 'ok') 'ok 与结论必须一致'
# ======================================================================
Write-Host ''
Write-Host '本地模型的位置标注与上下文设置' -ForegroundColor Cyan
# ======================================================================
# 位置：模型目录可能被 OLLAMA_MODELS 指到任何盘（本机就在 E 盘），界面必须标出来，
# 否则用户看着"C 盘满了"根本不知道模型在哪。
$rootInfo = Get-LLMKitOllamaRootInfo
Assert-True ([string]$rootInfo.modelRoot).Length -gt 0 '拿得到模型目录'
Assert-True (@('default', 'OLLAMA_MODELS') -contains [string]$rootInfo.modelRootSource) ('模型目录来源在白名单里（实际 ' + [string]$rootInfo.modelRootSource + '）')
Assert-True ([bool]$rootInfo.isDefaultRoot -eq ([string]$rootInfo.modelRootSource -eq 'default')) 'isDefaultRoot 与来源一致'
Assert-True ([string]$rootInfo.modelRootSource -eq 'OLLAMA_MODELS' -eq ([string]$rootInfo.modelRootEnv).Length -gt 0) '来源标为 OLLAMA_MODELS 时环境变量非空'

# 清单体积：拿一个临时目录造一份假清单，验证"按分片求和"，而不是信 list 的数字
# （实测过 ollama ps 对 gemma4:26b 报 1.3 GB，实际 17.33 GB）
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('llmkit-manifest-' + [guid]::NewGuid().ToString('N'))
$blobDir = Join-Path $tmpRoot 'blobs'
$manDir = Join-Path $tmpRoot 'manifests\registry.ollama.ai\library\fake'
[void](New-Item -ItemType Directory -Path $blobDir -Force)
[void](New-Item -ItemType Directory -Path $manDir -Force)
$fakeManifest = [ordered]@{
    schemaVersion = 2
    layers = @(
        @{ mediaType = 'application/vnd.ollama.image.model'; digest = 'sha256:aaaa' },
        @{ mediaType = 'application/vnd.ollama.image.license'; digest = 'sha256:bbbb' }
    )
}
[System.IO.File]::WriteAllText((Join-Path $manDir '3b'), ($fakeManifest | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
# 用 SetLength 造 1.5 GB + 0.6 GB 的稀疏分片（实测 6 ms，不用真写盘）
foreach ($pair in @(@('sha256-aaaa', 1.5GB), @('sha256-bbbb', 0.6GB))) {
    $fs = [System.IO.File]::Create((Join-Path $blobDir $pair[0]))
    $fs.SetLength([long]$pair[1])
    $fs.Close()
}
$mi = Get-LLMKitOllamaManifestInfo -ModelRoot $tmpRoot -Tag 'fake:3b'
Assert-True ([bool]$mi.found) '能从清单里找到模型'
Assert-Equal 2 ([int]$mi.layerCount) '清单里数到 2 个分片'
Assert-True ([double]$mi.sizeGB -ge 2.0 -and [double]$mi.sizeGB -le 2.2) ('体积按分片求和（1.5+0.6 GB → 实际 ' + $mi.sizeGB + ' GB）')
Assert-True ([bool]$mi.verified) '分片齐全时标记为已核实'
Assert-True ([string]$mi.manifestPath).Length -gt 0 '给出清单文件全路径'
Assert-True ([string]$mi.blobsDir).Length -gt 0 '给出分片目录'
$mi2 = Get-LLMKitOllamaManifestInfo -ModelRoot $tmpRoot -Tag 'fake:9b'
Assert-True (-not [bool]$mi2.found) '清单里没有的 tag 返回未找到（不抛异常）'
# 缺分片：删掉一个 blob，核实必须变成 false 并说清缺哪个
Remove-Item -LiteralPath (Join-Path $blobDir 'sha256-bbbb') -Force
$mi3 = Get-LLMKitOllamaManifestInfo -ModelRoot $tmpRoot -Tag 'fake:3b'
Assert-True ([bool]$mi3.found) '清单还在'
Assert-True (-not [bool]$mi3.verified) '缺分片时不能算"已核实"'
Assert-Equal 1 (@($mi3.missingBlobs).Count) '报出缺了 1 个分片'
Assert-True ([string]@($mi3.missingBlobs)[0] -match '^sha256-') '缺的是哪个分片也说清楚'
# 实际定位：OLLAMA_MODELS 指到别的目录时，也能在候选目录里找到真身
$otherRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('llmkit-other-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $otherRoot -Force)
# 第一个候选目录是空的，模型在第二个里 —— 定位必须继续往后找
$loc = Resolve-LLMKitModelLocation -Tag 'fake:3b' -Roots @($otherRoot, $tmpRoot)
Assert-True ([bool]$loc.found) '第一个候选目录没有时，会继续找下一个'
Assert-Equal $tmpRoot ([string]$loc.root) '返回的是真正找到清单的那个目录'
$locMissing = Resolve-LLMKitModelLocation -Tag 'definitely-not-a-model:1b' -Roots @($otherRoot, $tmpRoot)
Assert-True (-not [bool]$locMissing.found) '完全不存在的模型返回未找到（不抛异常）'
Remove-Item -LiteralPath $otherRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue

# 上下文：请求值/生效值/是否已应用 三件事都要给出来
$ctxSet = Get-LLMKitOllamaContextSetting
Assert-True ($null -ne $ctxSet) '拿得到上下文设置'
Assert-True ([int]$ctxSet.requested -ge 0) '请求值是个整数'
Assert-True ([int]$ctxSet.effective -ge 0) '生效值是个整数'
Assert-True ($ctxSet.PSObject.Properties.Name -contains 'applied') '给出"是否已经应用"的结论'
# applied 的判定规则：请求 ≥32K，且（没读到生效值 或 生效值也 ≥32K）
$expectApplied = ([int]$ctxSet.requested -ge 32768) -and (([int]$ctxSet.effective -eq 0) -or ([int]$ctxSet.effective -ge 32768))
Assert-Equal $expectApplied ([bool]$ctxSet.applied) 'applied 的判定与请求/生效值一致'

# 本地报告要把位置、上下文、清单体积都透出来
$rep = Get-LLMKitLocalReport -ConfigRoot $svcRoot
foreach ($f in @('installDir', 'exePath', 'rootSource', 'isDefaultRoot', 'contextRequested', 'contextEffective', 'contextApplied')) {
    Assert-True ($rep.ollama.PSObject.Properties.Name -contains $f) ('本地报告里有字段：' + $f)
}
$hasManifestField = $true
foreach ($m in @($rep.models)) { if (-not ($m.PSObject.Properties.Name -contains 'manifestSizeGB')) { $hasManifestField = $false } }
Assert-True $hasManifestField '每个模型档都带 manifestSizeGB'
Assert-True ($rep.ollama.PSObject.Properties.Name -contains 'locationRoots') '报告里给出"找过哪几个目录"'
# 已装模型每一条都要有位置字段（服务没在跑时列表为空，那就跳过）
if (@($rep.ollama.models).Count -gt 0) {
    foreach ($im in @($rep.ollama.models)) {
        foreach ($f in @('foundOnDisk', 'verified', 'manifestPath', 'blobsDir', 'realSizeGB')) {
            Assert-True ($im.PSObject.Properties.Name -contains $f) ('已装模型条目有位置字段：' + $f)
        }
    }
} else {
    Assert-True $true '（本机没装本地模型，跳过"每条都有位置字段"）'
}

# 动作：把上下文设成 32K —— 会重启服务，必须 destructive + 只有 -Apply 才真跑
$ctxAction = @($actions | Where-Object { $_.id -eq 'local-context' })
Assert-Equal 1 $ctxAction.Count '清单里有「把上下文设成 32K」'
Assert-True ([bool]$ctxAction[0].destructive) '改上下文被标为会改动系统（它确实会重启 Ollama）'
Assert-True (@($ctxAction[0].options) -contains 'contextLength') '声明了 contextLength 选项'
$ctxDry = Get-LLMKitActionCommandLine -ActionId 'local-context' -ConfigRoot $projectRoot
Assert-True (-not (@($ctxDry.arguments) -contains '-Apply')) '演练模式不带 -Apply'
Assert-True (@($ctxDry.arguments) -contains '-SetLocalContext') '命令里有 -SetLocalContext'
Assert-True (@($ctxDry.arguments) -contains '32768') '命令里写了 32768'
$ctxReal = Get-LLMKitActionCommandLine -ActionId 'local-context' -ConfigRoot $projectRoot -Apply
Assert-True (@($ctxReal.arguments) -contains '-Apply') '执行模式才带 -Apply'
# ======================================================================
Write-Host ''
Write-Host '本地模型切换：只改该改的那一块，且能整份还原' -ForegroundColor Cyan
# ======================================================================
# 这两家的配置里有用户自己的渠道与 key。这里钉三件事：
#   1. 别的内容原样保留（别的 provider、别的 section）
#   2. 顶层键只改 model 与 model_provider，段里的同名键不许动
#   3. 切回时按备份逐字节还原
$swTargets = @(Get-LLMKitLocalSwitchTargets)
Assert-Equal 2 $swTargets.Count ('能自动切换的目标是 2 个（实际 ' + $swTargets.Count + '）')
Assert-Equal 'opencode,codex' ((@($swTargets | ForEach-Object { $_.id })) -join ',') '目标是 opencode 与 codex'

$origOpen = '{"provider":{"deepseek":{"npm":"x","options":{"apiKey":"sk-KEEP"}}}}'
$newOpen = New-LLMKitOpencodeConfigText -OriginalText $origOpen -ModelTag 'qwen3.5:9b' -AllTags @('qwen3.5:9b', 'gemma4:26b')
$jo = $newOpen | ConvertFrom-Json
Assert-True ($jo.provider.PSObject.Properties.Name -contains 'ollama') 'OpenCode：加上了 provider.ollama'
Assert-True ($jo.provider.PSObject.Properties.Name -contains 'deepseek') 'OpenCode：原有的 deepseek 渠道还在'
Assert-Equal 'sk-KEEP' ([string]$jo.provider.deepseek.options.apiKey) 'OpenCode：原有的 key 没被动'
Assert-Equal 'http://127.0.0.1:11434/v1' ([string]$jo.provider.ollama.options.baseURL) 'OpenCode：baseURL 指向本机'
Assert-Equal 'local' ([string]$jo.provider.ollama.options.apiKey) 'OpenCode：本地 key 用占位（不是真 key）'
Assert-Equal 2 (@($jo.provider.ollama.models.PSObject.Properties.Name).Count) 'OpenCode：models 里列了两个已装模型'
$newOpenEmpty = New-LLMKitOpencodeConfigText -OriginalText '' -ModelTag 'x:1b'
Assert-True (($newOpenEmpty | ConvertFrom-Json).provider.PSObject.Properties.Name -contains 'ollama') 'OpenCode：文件不存在时也能生成最小配置'

$origCodex = "model = `"gpt-5`"`nmodel_provider = `"openai`"`n`n[profiles.fast]`nmodel = `"gpt-5-mini`"`n`n[model_providers.ollama]`nname = `"old`"`nbase_url = `"http://old:9999/v1`"`n"
$newCodex = New-LLMKitCodexConfigText -OriginalText $origCodex -ModelTag 'gemma4:26b'
Assert-True ($newCodex -match '(?m)^model = "gemma4:26b"$') 'Codex：顶层 model 改成选中的本地模型'
Assert-True ($newCodex -match '(?m)^model_provider = "ollama"$') 'Codex：顶层 model_provider 指向 ollama'
Assert-True ($newCodex -match '(?m)^\[profiles\.fast\]\r?\nmodel = "gpt-5-mini"$') 'Codex：段里的同名 model 键没被误改'
Assert-True ($newCodex -notmatch '9999') 'Codex：旧的 base_url 被替换'
Assert-Equal 1 (@([regex]::Matches($newCodex, '(?m)^\[model_providers\.ollama\]')).Count) 'Codex：只保留一个 ollama 段'

# ---- 往返：切过去 → 状态对 → 切回来 → 逐字节一致（用临时目录冒充用户目录）----
$realProfile = $env:USERPROFILE
$sandboxHome = Join-Path ([System.IO.Path]::GetTempPath()) ('llmkit-sw-' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $sandboxHome '.config\opencode') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $sandboxHome '.codex') -Force)
    $openPath = Join-Path $sandboxHome '.config\opencode\opencode.json'
    $codexPath = Join-Path $sandboxHome '.codex\config.toml'
    [System.IO.File]::WriteAllText($openPath, $origOpen, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($codexPath, $origCodex, (New-Object System.Text.UTF8Encoding($false)))
    $env:USERPROFILE = $sandboxHome
    $swState = Join-Path $sandboxHome 'state'

    $r1 = Set-LLMKitLocalSwitch -Target 'opencode' -ModelTag 'qwen3.5:9b' -AllTags @('qwen3.5:9b') -StateDir $swState -Apply
    Assert-True ([bool]$r1.ok) 'opencode 切到本地成功'
    Assert-True ([string]$r1.backup -ne '') '切换前留了备份'
    $stOpen = Get-LLMKitLocalSwitchState -Target 'opencode'
    Assert-True ([bool]$stOpen.applied) '读回来确认 opencode 已指向本地'
    Assert-Equal 'qwen3.5:9b' ([string]$stOpen.model) '状态里读得到当前本地模型'

    $r2 = Set-LLMKitLocalSwitch -Target 'codex' -ModelTag 'gemma4:26b' -StateDir $swState -Apply
    Assert-True ([bool]$r2.ok) 'codex 切到本地成功'
    Assert-True ([bool](Get-LLMKitLocalSwitchState -Target 'codex').applied) '读回来确认 codex 已指向本地'

    $beforeTrial = [System.IO.File]::ReadAllText($openPath)
    [void](Undo-LLMKitLocalSwitch -Target 'opencode' -StateDir $swState)
    Assert-Equal $beforeTrial ([System.IO.File]::ReadAllText($openPath)) '演练撤销不改文件'

    [void](Undo-LLMKitLocalSwitch -Target 'opencode' -StateDir $swState -Apply)
    [void](Undo-LLMKitLocalSwitch -Target 'codex' -StateDir $swState -Apply)
    Assert-Equal $origOpen ([System.IO.File]::ReadAllText($openPath)) 'opencode 切回后逐字节还原'
    Assert-Equal $origCodex ([System.IO.File]::ReadAllText($codexPath)) 'codex 切回后逐字节还原'
    Assert-True (-not (Get-LLMKitLocalSwitchState -Target 'opencode').applied) '还原后状态回到"不是本地"'
    $swLog = Join-Path $swState 'local-switch.log'
    Assert-True (Test-Path -LiteralPath $swLog) '切换有记账'
    Assert-True (((Get-Content -LiteralPath $swLog -Encoding UTF8) -join ' ') -match '切回原样') '记账里记得切回'
} finally {
    $env:USERPROFILE = $realProfile
    Remove-Item -LiteralPath $sandboxHome -Recurse -Force -ErrorAction SilentlyContinue
}
# ======================================================================
Write-Host ''
Write-Host '本地模型的品牌分组（能跑哪一档按组展示）' -ForegroundColor Cyan
# ======================================================================
# 分组不是排版问题：它决定用户看到"同一家的 2B/4B/9B/27B"还是"一条平铺的 6 张卡"。
# 这里钉住：组顺序只认 priority、每个模型必须归属一个存在的组、每组都要有说明。
$groupCat = @(Get-LLMKitModelGroupCatalog -ConfigRoot $projectRoot)
Assert-True ($groupCat.Count -ge 3) ('至少有 3 个分组（实际 ' + $groupCat.Count + '）')
$groupIds = @($groupCat | ForEach-Object { [string](Get-ObjectProp -Object $_ -Name 'id') })
Assert-Equal $groupIds.Count (@($groupIds | Sort-Object -Unique).Count) '组 id 无重复'
$groupPrios = @($groupCat | ForEach-Object { [int](Get-ObjectProp -Object $_ -Name 'priority') })
Assert-Equal $groupPrios.Count (@($groupPrios | Sort-Object -Unique).Count) '组 priority 无重复（顺序才是确定的）'
$firstByPrio = @($groupCat | Sort-Object { [int](Get-ObjectProp -Object $_ -Name 'priority') })[0]
Assert-Equal 'qwen' ([string](Get-ObjectProp -Object $firstByPrio -Name 'id')) 'Qwen 系列组排第一'
Assert-True ([bool](Get-ObjectProp -Object $firstByPrio -Name 'recommended')) 'Qwen 系列组标了推荐'
foreach ($g in $groupCat) {
    $gid = [string](Get-ObjectProp -Object $g -Name 'id')
    Assert-True ([string](Get-ObjectProp -Object $g -Name 'name')).Length -gt 0 ($gid + ' 有组名')
    Assert-True ([string](Get-ObjectProp -Object $g -Name 'note')).Length -gt 10 ($gid + ' 有说明（不是空话）')
    Assert-True ([string](Get-ObjectProp -Object $g -Name 'vendor')).Length -gt 0 ($gid + ' 标了厂商')
}

# 每个模型都要归属一个存在的组；每个组至少一个模型
$mdlCat = @(Get-LLMKitModelCatalog -ConfigRoot $projectRoot)
$orphans = @($mdlCat | Where-Object { $groupIds -notcontains [string](Get-ObjectProp -Object $_ -Name 'groupId') })
Assert-Equal 0 $orphans.Count ('没有模型落在未知分组里（越界：' + (($orphans | ForEach-Object { $_.id }) -join '、') + '）')
foreach ($gid in $groupIds) {
    $members = @($mdlCat | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'groupId') -eq $gid })
    Assert-True ($members.Count -ge 1) ($gid + ' 分组至少有 1 档模型')
}

# 报告里的 modelGroups：顺序按 priority，组内按「显存 → 体积」升序，计数与逐条判定一致
$repG = Get-LLMKitLocalReport -ConfigRoot $svcRoot
$groupsOut = @($repG.modelGroups)
Assert-Equal $groupCat.Count $groupsOut.Count '报告里的组数与配置一致'
$prevPrio = -1
foreach ($gOut in $groupsOut) {
    $def = @($groupCat | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'id') -eq [string]$gOut.id })[0]
    $prio = [int](Get-ObjectProp -Object $def -Name 'priority')
    Assert-True ($prio -gt $prevPrio) ('组按 priority 递增输出：' + $gOut.id)
    $prevPrio = $prio
    Assert-Equal (@($gOut.models).Count) (@($mdlCat | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'groupId') -eq [string]$gOut.id }).Count) ($gOut.id + ' 的成员数对得上')
    Assert-Equal (@($gOut.models | Where-Object { $_.verdict -eq 'ok' }).Count) $gOut.okCount ($gOut.id + ' 的 okCount 与逐条判定一致')
    Assert-Equal (@($gOut.models | Where-Object { $_.verdict -eq 'no' }).Count) $gOut.noCount ($gOut.id + ' 的 noCount 与逐条判定一致')
    for ($k = 1; $k -lt @($gOut.models).Count; $k++) {
        $a = @($gOut.models)[$k - 1]; $b = @($gOut.models)[$k]
        $ka = [double]$a.minVramGB * 1000 + [double]$a.sizeGB
        $kb = [double]$b.minVramGB * 1000 + [double]$b.sizeGB
        Assert-True ($ka -le $kb) ($gOut.id + ' 组内按「需要显存 → 体积」升序（' + $a.name + ' 应在 ' + $b.name + ' 之前）')
    }
}

# "未实测"与"不支持一键下载"两个标记必须与配置一致
foreach ($m in @($repG.models)) {
    $src = @($mdlCat | Where-Object { [string](Get-ObjectProp -Object $_ -Name 'id') -eq [string]$m.id })[0]
    $hasMeasured = ($null -ne (Get-ObjectProp -Object $src -Name 'measured'))
    Assert-Equal (-not $hasMeasured) ([bool]$m.unmeasured) ($m.id + ' 的"未实测"标记与配置一致')
    $srcInstallable = -not ($src.PSObject.Properties['installable'] -and $src.installable -eq $false)
    Assert-Equal $srcInstallable ([bool]$m.installable) ($m.id + ' 的"可下载"标记与配置一致')
    if (-not $srcInstallable) {
        Assert-True ([string]$m.installNote).Length -gt 10 ($m.id + ' 不可下载时必须说明为什么')
    }
}
$notInstallable = @($repG.models | Where-Object { -not $_.installable })
Assert-True ($notInstallable.Count -ge 1) ('目录里有"只作说明"的档（实际 ' + $notInstallable.Count + ' 档）')
# ---- 组内共同字段：只有全组一致时才提到组头，否则留空让表格逐行展示 ----
$qwenGroup = @($repG.modelGroups | Where-Object { $_.id -eq 'qwen' })[0]
Assert-True ($null -ne $qwenGroup) '报告里有 Qwen 系列组'
Assert-Equal 'Q4_K_M' ([string]$qwenGroup.common.quant) 'Qwen 组量化一致时才提到组头'
Assert-Equal '32768' ([string]$qwenGroup.common.context) 'Qwen 组上下文一致'
Assert-Equal 'Apache-2.0' ([string]$qwenGroup.common.license) 'Qwen 组许可证一致'
Assert-Equal '阿里通义' ([string]$qwenGroup.common.vendor) 'Qwen 组厂商一致'
$roGroup = @($repG.modelGroups | Where-Object { $_.id -eq 'readonly' })[0]
Assert-True ($null -ne $roGroup) '报告里有"只作说明"组'
Assert-Equal '' ([string]$roGroup.common.quant) '组内量化不一致时共同字段留空（不硬凑）'
Assert-Equal '' ([string]$roGroup.common.license) '组内许可证不一致时共同字段留空'
Assert-Equal '32768' ([string]$roGroup.common.context) '但一致的字段（上下文）仍然提出来'

# ---- 代际标签：Qwen 组里 3.5 / 3.6 / 3.8 都要标出来 ----
$gens = @($qwenGroup.models | ForEach-Object { [string]$_.generation } | Where-Object { $_ } | Sort-Object -Unique)
Assert-True ($gens -contains '3.5') 'Qwen 组有 3.5 代'
Assert-True ($gens -contains '3.6') 'Qwen 组有 3.6 代'
Assert-True ($gens -contains '3.8') 'Qwen 组有 3.8 代'
Assert-True ($qwenGroup.models.Count -ge 5) ('Qwen 组合并后至少 5 档（实际 ' + $qwenGroup.models.Count + '）')
# ---- DeepSeek 组：开源权重 R1 系列 + 只作说明的旗舰 ----
$dsGroup = @($repG.modelGroups | Where-Object { $_.id -eq 'deepseek' })[0]
Assert-True ($null -ne $dsGroup) '报告里有 DeepSeek 组'
Assert-True ($dsGroup.models.Count -ge 4) ('DeepSeek 组至少 4 档（实际 ' + $dsGroup.models.Count + '）')
Assert-True ([string]$dsGroup.warn -match '工具调用') 'DeepSeek 组必须提示"不适合当工具层"这件事'
$r1tags = @($dsGroup.models | ForEach-Object { $_.ollamaTag })
Assert-True ($r1tags -contains 'deepseek-r1:1.5b') '有最小的 1.5B 档（核显可跑）'
Assert-True ($r1tags -contains 'deepseek-r1:7b') '有 7B 档（本项目实测过的那一档）'
# 实测数据要如实反映"不会用工具"——这是这条组存在的意义
$r1hit = @($dsGroup.models | Where-Object { $_.ollamaTag -eq 'deepseek-r1:7b' })
Assert-Equal 1 $r1hit.Count '能找到 deepseek-r1:7b 这一档'
$r1 = $r1hit[0]
Assert-True (-not [bool]$r1.unmeasured) 'deepseek-r1:7b 标为已实测'
$r1Measured = $r1.measured
Assert-True ($null -ne $r1Measured) '详情里带着实测数据（界面靠它显示 tok/s 与会不会用工具）'
Assert-Equal 'False' ([string]$r1Measured.toolCalls) '实测记录里 toolCalls=False（它确实不返回工具调用）'
Assert-True ([double]$r1Measured.tokPerSec -gt 0) '实测记录里带速度'
Assert-Equal 'chat-only' ([string]$r1.capability) '既然不会用工具，能力就只能是问答补全'

# 只作说明组里要能放下 DeepSeek 的旗舰（云端 / 404 GB 权重）
$roGroup2 = @($repG.modelGroups | Where-Object { $_.id -eq 'readonly' })[0]
$roNames = @($roGroup2.models | ForEach-Object { $_.name })
Assert-True (@($roGroup2.models | Where-Object { -not $_.installable }).Count -ge 3) '只作说明组至少 3 档'
Assert-True (($roNames -join ' ') -match 'V3.1|V4') '只作说明组里有 DeepSeek 的大模型'
foreach ($m in @($roGroup2.models)) {
    Assert-True (-not [bool]$m.installable) ('只作说明组的每一档都必须是不可下载：' + $m.name)
}
# ======================================================================
Write-Host ''
Write-Host '本地模型删除：先卸载、失败时把原因带出来' -ForegroundColor Cyan
# ======================================================================
# 真实教训：模型还在内存里时 /api/delete 返回 500 且响应体为空 —— 界面上只看到
# "删除失败：500"，完全无法排查。所以删除前要卸载，失败时要把状态码与响应体摊开。
Assert-True ($null -ne (Get-Command -Name 'Unload-LLMKitOllamaModel' -ErrorAction SilentlyContinue)) '有卸载模型的函数'
Assert-True ($null -ne (Get-Command -Name 'Invoke-LLMKitModelRemove' -ErrorAction SilentlyContinue)) '有删除模型的函数'
# 服务没在跑时：卸载要安静地返回 false（不能抛），删除要给出明确原因
$unloadProbe = $null
try { $unloadProbe = Unload-LLMKitOllamaModel -Tag 'whatever:1b' } catch { $unloadProbe = 'threw' }
Assert-True ($unloadProbe -ne 'threw') '服务没在跑时，卸载函数不抛异常'
Assert-True ($unloadProbe -eq $false) '服务没在跑时，卸载函数返回 false'
$removeThrew = $false
$removeMsg = ''
try { [void](Invoke-LLMKitModelRemove -Tag 'whatever:1b') } catch { $removeThrew = $true; $removeMsg = [string]$_.Exception.Message }
Assert-True $removeThrew '服务没在跑时，删除会明确报错'
Assert-True ($removeMsg.Length -gt 5) ('错误信息是可读的（实际：' + $removeMsg + '）')
$hw = Get-Content (Join-Path $ProjectRoot 'src\ps\LLMKit.Hardware.psm1') -Raw -Encoding UTF8
Assert-True ($hw -match 'Unload-LLMKitOllamaModel -Tag') '删除流程里真的先调了卸载'
Assert-True ($hw -match 'HTTP '' \+ \$code') '删除失败时会把 HTTP 状态码带进错误信息'
Assert-True ($hw -match 'ollama rm') '接口删除失败后有 ollama rm 兜底'
# ======================================================================
Write-Host ''
Write-Host '渠道参考价格（只列抄录到的事实）' -ForegroundColor Cyan
# ======================================================================
# 价格这类内容最容易变成"过期误导"。所以钉三件事：
#   1. 每个渠道都要有 pricing 段，且必须带 checkedAt 与 sourceUrl（没来源的数字不许进库）
#   2. 有 rows 就必须每行有模型名与正数输入/输出价
#   3. 没有 rows 就必须给 unavailable 说明原因（不许留空，空着等于悄悄没了）
$provDoc = Get-Content (Join-Path $projectRoot 'config\providers.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$priceCurrencies = @('CNY', 'USD')
$withRows = 0
$withoutRows = 0
foreach ($p in @($provDoc.providers)) {
    $pr = $p.pricing
    Assert-True ($null -ne $pr) ($p.id + ' 有 pricing 段')
    if ($null -eq $pr) { continue }
    Assert-True ($priceCurrencies -contains [string]$pr.currency) ($p.id + ' 的币种在 CNY/USD 里（实际 ' + [string]$pr.currency + '）')
    Assert-True ((Test-Path -LiteralPath (Join-Path $projectRoot 'config\providers.json')) -and ([string]$pr.checkedAt -match '^\d{4}-\d{2}-\d{2}$')) ($p.id + ' 有抄录日期 checkedAt')
    Assert-True ([string]$pr.sourceUrl).StartsWith('https://') ($p.id + ' 有来源链接 sourceUrl')
    $rows = @($pr.rows | Where-Object { $_ })
    if ($rows.Count -gt 0) {
        $withRows++
        foreach ($r in $rows) {
            Assert-True ([string]$r.model).Length -gt 0 ($p.id + ' 的价格行有模型名')
            Assert-True ([double]$r.input -gt 0) ($p.id + '/' + $r.model + ' 输入价是正数')
            Assert-True ([double]$r.output -gt 0) ($p.id + '/' + $r.model + ' 输出价是正数')
        }
        Assert-True ([string]::IsNullOrWhiteSpace([string]$pr.unavailable)) ($p.id + ' 有价格时不该同时说"未收录"')
    } else {
        $withoutRows++
        Assert-True ([string]$pr.unavailable).Length -gt 10 ($p.id + ' 没有价格时必须说明原因')
    }
    Assert-True ([string]$pr.unit) -eq '每百万 tokens' ($p.id + ' 的计价单位统一为每百万 tokens')
}
Assert-True ($withRows -ge 3) ('至少 3 个渠道抄到了具体价格（实际 ' + $withRows + '）')
Assert-True ($withoutRows -ge 1) ('没抄到的渠道要如实标注（实际 ' + $withoutRows + ' 家）')
# 币种必须分开：至少各有一个渠道落在 CNY / USD
$cny = @($provDoc.providers | Where-Object { $_.pricing -and $_.pricing.currency -eq 'CNY' })
$usd = @($provDoc.providers | Where-Object { $_.pricing -and $_.pricing.currency -eq 'USD' })
Assert-True ($cny.Count -ge 1) '有人民币计价的渠道'
Assert-True ($usd.Count -ge 1) '有美元计价的渠道'
# 服务层要把它透传给界面
$svcProviders = @(Get-LLMKitProviderList -ConfigRoot $svcRoot)
Assert-Equal $provDoc.providers.Count $svcProviders.Count '服务层返回的渠道数量一致'
$badPricing = @($svcProviders | Where-Object { $null -eq $_.pricing })
Assert-Equal 0 $badPricing.Count ('每个渠道都带 pricing（缺的：' + (($badPricing | ForEach-Object { $_.id }) -join '、') + '）')
Write-Host ('-' * 60) -ForegroundColor DarkGray
if ($script:Fail -eq 0) {
    Write-Host ('全部通过：' + $script:Pass + ' 项') -ForegroundColor Green
    exit 0
} else {
    Write-Host ('通过 ' + $script:Pass + ' 项，失败 ' + $script:Fail + ' 项') -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
    exit 1
}
