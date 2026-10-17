# 演练跑一遍，确认真实配置文件没被动过。
#
# 命令里有 -Uninstall，但没带 -Apply —— 按设计这一定是演练：只出计划，不落地。
# 这条检查守的是"演练零副作用"这个承诺本身。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $root
try {
    $watched = @(
        (Join-Path $env:USERPROFILE '.claude\settings.json'),
        (Join-Path $env:USERPROFILE '.claude.json'),
        (Join-Path $env:USERPROFILE '.cc-switch\settings.json')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $before = @{}
    foreach ($f in $watched) { $before[$f] = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash }
    $pathBefore = (Get-ItemProperty 'HKCU:\Environment' -Name Path).Path

    & (Join-Path $root 'src\ps\Setup-LLMKit.ps1') -SkipCheck -IncludeTools -Uninstall opencode -NoColor
    if ($LASTEXITCODE -ne 0) { throw ('演练退出码非 0：' + $LASTEXITCODE) }

    foreach ($f in $watched) {
        if ($before[$f] -ne (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash) { throw ('演练却改动了：' + $f) }
    }
    if ($pathBefore -ne (Get-ItemProperty 'HKCU:\Environment' -Name Path).Path) { throw '演练却改动了用户 PATH' }
    Write-Host '演练零副作用确认通过'
}
finally {
    Pop-Location
}
