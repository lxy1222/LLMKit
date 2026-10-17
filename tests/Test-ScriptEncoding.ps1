# 脚本编码与语法守卫：仓库里的 .ps1 / .psm1 必须是 UTF-8 with BOM，且能被 PS 5.1 解析。
#
# 为什么要有它：PS 5.1 读无 BOM 的 UTF-8 会按 ANSI 解码，中文全成乱码、语法都过不了。
# 历史上踩过四次。
#
# 为什么它本身是个"文件"而不是写在 ci.yml 的 run: 里：
# GitHub 会把 run: 里的脚本写成一个**无 BOM** 的临时 .ps1，只要那段脚本里有中文，
# 就会在 runner 上按 ANSI 解码成乱码、然后整段语法崩掉 —— 这条检查自己就先崩了。
# 实测报错：Write-Host ('::error ...::缺少 UTF-8 BOM') → Unexpected token 'UTF-8'。
# 所以：**凡是带中文的 CI 逻辑，一律放进仓库里的脚本（有 BOM）；run: 只留 ASCII 的调用。**
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $root
try {
    $files = @(Get-ChildItem src, tests, build -Recurse -Include *.ps1, *.psm1 | Sort-Object FullName)
    $bad = 0
    Write-Host ('PowerShell ' + $PSVersionTable.PSVersion.ToString() + ' / 脚本 ' + $files.Count + ' 个')
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length + 1)
        $bx = [System.IO.File]::ReadAllBytes($f.FullName)
        $bom = ($bx.Length -ge 3 -and $bx[0] -eq 0xEF -and $bx[1] -eq 0xBB -and $bx[2] -eq 0xBF)
        $tk = $null; $er = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$er)
        $okParse = (-not $er -or @($er).Count -eq 0)
        if (-not $bom) {
            # ::error 会生成 GitHub annotation（公开可读，不登录也能定位到文件）
            Write-Host ('::error file=' + $rel + ',line=1::missing UTF-8 BOM')
            Write-Host ('缺少 BOM：' + $rel)
            $bad++
        }
        if (-not $okParse) {
            $first = @($er)[0]
            Write-Host ('::error file=' + $rel + ',line=' + $first.Extent.StartLineNumber + '::syntax error: ' + $first.Message)
            Write-Host ('语法错误：' + $rel)
            @($er) | Select-Object -First 3 | ForEach-Object { Write-Host ('  L' + $_.Extent.StartLineNumber + ': ' + $_.Message) }
            $bad++
        }
    }
    if ($bad -gt 0) { throw ($bad.ToString() + ' 个脚本不合格') }
    Write-Host '全部合格'
}
finally {
    Pop-Location
}
