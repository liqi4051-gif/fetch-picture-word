#requires -Version 5.1
<#
    fetch-picture-word 桌面版 —— 构建脚本

    做两件事：
      1. 用系统自带的 .NET Framework 编译器（csc.exe）把 src\launcher.cs 编译成
         dist\FetchPictureWord.exe（不需要安装任何 SDK）；
      2. 把 src\app.ps1 和 src\ocr.ps1 复制到 dist\ 下，形成一个可以直接双击、
         也可以整目录拷走使用的绿色版本。

    用法：
        powershell -ExecutionPolicy Bypass -File build.ps1
        powershell -ExecutionPolicy Bypass -File build.ps1 -Clean
#>
[CmdletBinding()]
param(
    [switch]$Clean
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$src = Join-Path $root 'src'
$dist = Join-Path $root 'dist'

function Write-Step([string]$Message) {
    Write-Host ('  ' + $Message)
}

function Get-CscPath {
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v3.5\csc.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw '找不到 csc.exe（.NET Framework 编译器）。Windows 10/11 自带，通常不需要额外安装。'
}

Write-Host '构建 fetch-picture-word 桌面版'
Write-Host ''

if ($Clean -and (Test-Path -LiteralPath $dist)) {
    Remove-Item -LiteralPath $dist -Recurse -Force
    Write-Step ('已清理 ' + $dist)
}

if (-not (Test-Path -LiteralPath $dist)) {
    $null = New-Item -ItemType Directory -Path $dist -Force
}

# --- 1. 编译启动器 ---------------------------------------------------------
$csc = Get-CscPath
$launcherSource = Join-Path $src 'launcher.cs'
$launcherTarget = Join-Path $dist 'FetchPictureWord.exe'

Write-Step ('编译器：' + $csc)
& $csc /nologo /target:winexe /platform:anycpu /optimize+ `
    /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll `
    "/out:$launcherTarget" $launcherSource
if ($LASTEXITCODE -ne 0) { throw ('编译失败，csc 退出码 ' + $LASTEXITCODE) }
Write-Step ('已生成 ' + $launcherTarget)

# --- 2. 带上运行需要的脚本 -------------------------------------------------
foreach ($name in @('app.ps1', 'ocr.ps1')) {
    $from = Join-Path $src $name
    if (-not (Test-Path -LiteralPath $from)) { throw ('缺少源文件 ' + $from) }
    Copy-Item -LiteralPath $from -Destination (Join-Path $dist $name) -Force
    Write-Step ('已复制 ' + $name)
}

# 这几个脚本里有中文字面量，必须带 UTF-8 BOM，否则 PowerShell 5.1 会按 GBK 解析
foreach ($name in @('app.ps1', 'ocr.ps1')) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $dist $name))
    $hasBom = ($bytes.Length -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if (-not $hasBom) {
        Write-Warning ($name + ' 缺少 UTF-8 BOM，PowerShell 5.1 会把中文按 GBK 解析。请先运行 fix-bom.ps1。')
    }
}

# --- 3. 带上许可证 ---------------------------------------------------------
# MIT 要求分发时随附版权与许可声明，所以绿色版和安装版都带一份。
$licenseSource = Join-Path (Split-Path -Parent $root) 'LICENSE'
if (Test-Path -LiteralPath $licenseSource) {
    Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $dist 'LICENSE.txt') -Force
    Write-Step '已复制 LICENSE.txt'
} else {
    Write-Warning ('没找到 ' + $licenseSource + '，发布出去的副本将不带许可证声明。')
}

$exe = Get-Item -LiteralPath $launcherTarget
Write-Host ''
Write-Host ('构建完成：' + $exe.FullName + '（' + [Math]::Round($exe.Length / 1KB, 1) + ' KB）')
Write-Host '双击 dist\FetchPictureWord.exe 即可试用；要装到开始菜单请运行 install.ps1。'
