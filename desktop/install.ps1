#requires -Version 5.1
<#
  安装「提取图片文字」桌面版。

  默认装到当前用户目录（不需要管理员）：
    %LocalAppData%\Programs\FetchPictureWord
  同时创建桌面 + 开始菜单快捷方式，并登记到「设置 → 应用」的卸载列表。

  用法：
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$InstallDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$AppName = '提取图片文字'
$AppId = 'FetchPictureWord.Desktop'
$Root = $PSScriptRoot
$Dist = Join-Path $Root 'dist'

if (-not $InstallDir -or $InstallDir.Trim().Length -eq 0) {
    $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\FetchPictureWord'
}

function Get-ShortcutPaths {
    $list = New-Object System.Collections.ArrayList
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop) {
        [void]$list.Add((Join-Path $desktop ($AppName + '.lnk')))
    }
    $programs = [Environment]::GetFolderPath('Programs')
    if ($programs) {
        [void]$list.Add((Join-Path $programs ($AppName + '.lnk')))
    }
    return $list
}

function New-Shortcut([string]$LinkPath, [string]$TargetPath, [string]$WorkingDirectory) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($LinkPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = '从图片里读出文字，微信对话框风格，离线可用'
    $shortcut.IconLocation = ($TargetPath + ',0')
    $shortcut.Save()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}

function Remove-App([string]$Path) {
    Write-Host '正在卸载…'
    foreach ($link in (Get-ShortcutPaths)) {
        if (Test-Path -LiteralPath $link) {
            Remove-Item -LiteralPath $link -Force
            Write-Host ('  已删除快捷方式 ' + $link)
        }
    }
    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $AppId
    if (Test-Path $uninstallKey) {
        Remove-Item -Path $uninstallKey -Recurse -Force
        Write-Host '  已移除卸载列表登记'
    }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        Write-Host ('  已删除 ' + $Path)
    }
    Write-Host '卸载完成。'
}

function Install-App([string]$Path) {
    $exeSource = Join-Path $Dist 'FetchPictureWord.exe'
    if (-not (Test-Path -LiteralPath $exeSource)) {
        throw ('没找到 ' + $exeSource + '，请先运行 build.ps1 生成它。')
    }

    Write-Host ('安装到 ' + $Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    [void](New-Item -ItemType Directory -Path $Path -Force)

    $payload = @('FetchPictureWord.exe', 'app.ps1', 'ocr.ps1')
    foreach ($name in $payload) {
        $from = Join-Path $Dist $name
        if (-not (Test-Path -LiteralPath $from)) {
            throw ('缺少文件 ' + $from + '，请先运行 build.ps1。')
        }
        Copy-Item -LiteralPath $from -Destination (Join-Path $Path $name) -Force
        Write-Host ('  ' + $name)
    }

    Copy-Item -LiteralPath (Join-Path $Dist 'README.txt') -Destination $Path -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $Dist 'LICENSE.txt') -Destination $Path -Force -ErrorAction SilentlyContinue

    $target = Join-Path $Path 'FetchPictureWord.exe'
    foreach ($link in (Get-ShortcutPaths)) {
        New-Shortcut $link $target $Path
        Write-Host ('  快捷方式 ' + $link)
    }

    $size = [int]((Get-ChildItem -LiteralPath $Path -File | Measure-Object -Property Length -Sum).Sum / 1KB)
    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $AppId
    [void](New-Item -Path $uninstallKey -Force)
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $uninstallCommand = '"' + $powershell + '" -NoProfile -ExecutionPolicy Bypass -File "' +
        (Join-Path $Path 'install.ps1') + '" -Uninstall'
    New-ItemProperty -Path $uninstallKey -Name 'DisplayName' -Value $AppName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'DisplayVersion' -Value '0.1.0' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'Publisher' -Value 'fetch-picture-word' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'InstallLocation' -Value $Path -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'DisplayIcon' -Value ($target + ',0') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'UninstallString' -Value $uninstallCommand -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'QuietUninstallString' -Value ($uninstallCommand + ' -Quiet') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'EstimatedSize' -Value $size -PropertyType DWord -Force | Out-Null

    # 装到安装目录里的 install.ps1 自己也要能卸载
    if (-not [string]::IsNullOrEmpty($PSCommandPath) -and (Test-Path -LiteralPath $PSCommandPath)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $Path 'install.ps1') -Force
    }

    Write-Host ''
    Write-Host '安装完成，现在可以：'
    Write-Host '  · 双击桌面上的「提取图片文字」'
    Write-Host '  · 或者在开始菜单里搜「提取图片文字」'
    Write-Host ('  · 卸载：' + (Join-Path $Path 'install.ps1') + ' -Uninstall')
}

if ($Uninstall) {
    Remove-App $InstallDir
} else {
    Install-App $InstallDir
}
