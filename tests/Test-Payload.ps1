# 载荷内容自证：从单文件 .cmd 的 base64 段里解出 zip，核对内容。
#
# 桌面版那条 exe 分支删掉之后，没有现成的 _payload.zip 可查了，
# 于是直接从单文件 .cmd 解出来验 —— 校验的正是用户手上那份载荷。
# 带中文的逻辑必须放在这个文件里（有 BOM）；ci.yml 的 run: 只有 ASCII 调用。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $root
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $single = @(Get-ChildItem 'build\dist\LLMKit-web-single-*.cmd' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($single.Count -eq 0) { throw 'build\dist 里没有单文件 .cmd' }
    $target = $single[0]
    Write-Host ('检查载荷：' + $target.Name)
    $lines = [System.IO.File]::ReadAllLines($target.FullName, [System.Text.Encoding]::UTF8)
    $marker = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq ':LLMKIT-PAYLOAD') { $marker = $i; break } }
    if ($marker -lt 0) { throw '单文件里找不到载荷标记' }
    $b64 = ($lines[($marker + 1)..($lines.Count - 1)] -join '').Trim()
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) ('llmkit-payload-' + [guid]::NewGuid().ToString('N') + '.zip')
    [System.IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($b64))
    $arch = [System.IO.Compression.ZipFile]::OpenRead($zip)
    $names = @($arch.Entries | ForEach-Object { $_.FullName })
    $arch.Dispose()
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    # 反斜杠条目名不符合 zip 规范，严格的解压器会解出名字里带反斜杠的怪文件
    $backslash = @($names | Where-Object { $_.Contains('\') })
    if ($backslash.Count -gt 0) { throw ('载荷里有 ' + $backslash.Count + ' 个反斜杠条目名') }
    foreach ($need in @('web/index.html', 'web/assets/app.js', 'web/assets/app.css', 'src/ps/LLMKit.Web.psm1', 'src/ps/LLMKit.Engine.psm1', 'src/ps/LLMKit.Hardware.psm1', 'config/tools.json', 'config/models.json')) {
        if ($names -notcontains $need) { throw ('载荷缺少：' + $need) }
    }
    Write-Host ('载荷 ' + $names.Count + ' 个文件，关键文件齐全')
}
finally {
    Pop-Location
}
