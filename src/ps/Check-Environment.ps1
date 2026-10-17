#Requires -Version 5.1
<#
.SYNOPSIS
    LLMKit 环境体检（M0）

.DESCRIPTION
    对当前 Windows 电脑做一次只读体检，产出一份结构化 JSON 报告与中文控制台摘要。
    不会安装任何东西、不修改任何系统设置、不读取完整密钥。

.PARAMETER OutFile
    报告输出路径。默认写到 <项目根>\out\env-report-latest.json，
    同时另存一份带时间戳的 env-report-<时间>.json。

.PARAMETER NoColor
    不输出颜色，摘要走标准输出流，便于重定向到文件。

.PARAMETER Quiet
    不打印摘要，只输出报告路径（或配合 -Json 输出 JSON）。

.PARAMETER Json
    把完整 JSON 打印到标准输出（机器可读）。

.PARAMETER SkipNetwork
    跳过联网探测，用于离线环境或内网。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\src\ps\Check-Environment.ps1

.EXAMPLE
    .\src\ps\Check-Environment.ps1 -SkipNetwork -NoColor
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [switch]$NoColor,
    [switch]$Quiet,
    [switch]$Json,
    [switch]$SkipNetwork,
    [string]$ConfigRoot,
    [int]$NetworkTimeoutMs = 4000,
    [int]$CommandTimeoutMs = 8000
)

$ErrorActionPreference = 'Stop'

# 中文输出：显式把控制台输出编码设为 UTF-8，避免 GBK 代码页下乱码
try {
    if ([Console]::OutputEncoding.WebName -ne 'utf-8') {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
} catch { }

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if ([string]::IsNullOrEmpty($ConfigRoot)) { $ConfigRoot = $projectRoot }

$modulePath = Join-Path $scriptDir 'LLMKit.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Error ('找不到检测引擎模块：' + $modulePath)
    exit 2
}

Import-Module -Name $modulePath -Force -DisableNameChecking

if (-not $Quiet -and -not $Json) {
    Write-Host ''
    Write-Host 'LLMKit · 环境体检' -ForegroundColor White
    Write-Host ('引擎版本 ' + (Get-LLMKitVersion) + ' / 目标：' + $env:COMPUTERNAME) -ForegroundColor DarkGray
    Write-Host ('-' * 72) -ForegroundColor DarkGray
}

$report = $null
try {
    $report = Invoke-LLMKitEnvironmentCheck -ConfigRoot $ConfigRoot -SkipNetwork:$SkipNetwork -NetworkTimeoutMs $NetworkTimeoutMs -CommandTimeoutMs $CommandTimeoutMs
} catch {
    Write-Host ''
    Write-Host ('体检过程本身失败了：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 2
}

if ([string]::IsNullOrEmpty($OutFile)) {
    $outDir = Join-Path $projectRoot 'out'
    $OutFile = Join-Path $outDir 'env-report-latest.json'
}

$stampedPath = ''
try {
    [void](Save-LLMKitReport -Report $report -Path $OutFile)
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $stampedPath = Join-Path (Split-Path -Parent $OutFile) ('env-report-' + $stamp + '.json')
    [void](Save-LLMKitReport -Report $report -Path $stampedPath)
} catch {
    Write-Host ('写报告失败：' + $_.Exception.Message) -ForegroundColor Red
}

$verdictCode = 2
if ($report.summary.verdict -eq 'ok') { $verdictCode = 0 }
elseif ($report.summary.verdict -eq 'warn') { $verdictCode = 1 }

if ($Json) {
    $report | ConvertTo-Json -Depth 14
    exit $verdictCode
}

if (-not $Quiet) {
    # NoColor 模式下摘要走标准输出流，可以被重定向；彩色模式走 Host
    Format-LLMKitReport -Report $report -NoColor:$NoColor
    Write-Host ('报告已写入：' + $OutFile) -ForegroundColor DarkGray
    if ($stampedPath) { Write-Host ('历史快照：  ' + $stampedPath) -ForegroundColor DarkGray }
} else {
    Write-Output $OutFile
}

exit $verdictCode
