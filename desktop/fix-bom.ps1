#requires -Version 5.1
# 本仓库里所有 .ps1 都必须是 UTF-8 with BOM：Windows PowerShell 5.1 读到
# 没有 BOM 的脚本会按系统 ANSI 代码页（中文系统是 GBK）解码，脚本里的
# 中文字面量会全部变成乱码，甚至直接把语法读坏。
$targets = @()
if ($args.Count -gt 0) {
    foreach ($item in $args) {
        if (Test-Path -LiteralPath $item -PathType Container) {
            $targets += Get-ChildItem -LiteralPath $item -Filter '*.ps1' -Recurse -File
        } else {
            $targets += Get-Item -LiteralPath $item
        }
    }
} else {
    $targets += Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -Recurse -File
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$fixed = 0
foreach ($file in $targets) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Write-Host "  ok    $($file.Name)"
        continue
    }
    $text = [System.IO.File]::ReadAllText($file.FullName, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($file.FullName, $text, $utf8Bom)
    $fixed++
    Write-Host "  fixed $($file.Name)"
}
Write-Host "UTF-8 BOM 检查完成：$($targets.Count) 个文件，补写 BOM $fixed 个。"
