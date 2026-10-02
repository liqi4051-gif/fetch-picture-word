#requires -Version 5.1
<#
    publish-to-github —— 只读环境自检

    检查「把代码推送到 GitHub」这条链路上每一环是否就绪，并给出现成的修复命令。
    脚本**只读**：不安装任何东西、不改注册表、不写 git config、不访问网络写操作
    （唯一的一次网络访问是 gh auth status 的令牌校验）。

    用法：
        powershell -ExecutionPolicy Bypass -File check-env.ps1
        powershell -ExecutionPolicy Bypass -File check-env.ps1 -Repo D:\code\my-project

    输出：一张状态表 + 「需要处理」清单（含可直接复制的命令）+ 一段紧凑的机器可读摘要。
#>
[CmdletBinding()]
param(
    # 只读检查这个仓库（可省略；省略时若当前目录是仓库则用当前目录）
    [string]$Repo,
    # 额外信任这些环境变量名里的代理（默认 HTTPS_PROXY / HTTP_PROXY / ALL_PROXY / https_proxy / http_proxy）
    [string[]]$ProxyEnvNames
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $ProxyEnvNames -or $ProxyEnvNames.Count -eq 0) {
    $ProxyEnvNames = @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'https_proxy', 'http_proxy')
}
$script:Problems = New-Object System.Collections.Generic.List[string]

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host $Title
    Write-Host ('-' * 60)
}

function Write-Item([string]$Label, [string]$Value, [string]$State) {
    $mark = switch ($State) {
        'ok'   { '[ok]  ' }
        'warn' { '[warn]' }
        'bad'  { '[bad] ' }
        default { '[--]  ' }
    }
    Write-Host ("  {0} {1,-22} {2}" -f $mark, $Label, $Value)
}

function Add-Problem([string]$Text) {
    $script:Problems.Add($Text) | Out-Null
}

# ---------------------------------------------------------------------------
# 0. 关键前提：本会话的 PATH 可能是安装软件之前拍下来的快照
# ---------------------------------------------------------------------------
function Repair-PathFromRegistry {
    # 新装的 Git / gh 会把目录写进注册表 PATH，但当前已开着的终端读不到。
    # 这里把机器级 + 用户级 PATH 重新拼一遍，纯内存操作，不写注册表。
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $merged = @($machine, $user) -join ';'
    if ($merged -and $merged -ne $env:Path) {
        $env:Path = $merged
        return $true
    }
    return $false
}

function Get-RegistryEnv([string]$Name) {
    # 从注册表读用户级环境变量（不依赖当前进程的环境块）
    $value = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, 'Machine')
    }
    return $value
}

$pathRepaired = Repair-PathFromRegistry

Write-Host 'publish-to-github 环境自检'
Write-Host ("时间: {0}    主机: {1}    PowerShell: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $PSVersionTable.PSVersion)

# ---------------------------------------------------------------------------
# 1. Git
# ---------------------------------------------------------------------------
Write-Section '1. Git'
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    $gitVersion = (& git --version 2>&1 | Out-String).Trim()
    Write-Item 'git' $gitVersion 'ok'
    if ($pathRepaired) {
        Write-Item 'PATH' '已从注册表重建（仅本进程有效，旧终端要重开）' 'warn'
    }
    Write-Item '路径' $git.Source 'ok'
} else {
    Write-Item 'git' '未找到' 'bad'
    Add-Problem 'Git 未安装或不在 PATH 里 → 装完 Git 后**必须新开终端**再继续（本会话可重跑本脚本，它会自动从注册表重建 PATH）。'
}

# ---------------------------------------------------------------------------
# 2. GitHub CLI
# ---------------------------------------------------------------------------
Write-Section '2. GitHub CLI (gh)'
$gh = Get-Command gh -ErrorAction SilentlyContinue
$ghOk = $false
if ($gh) {
    $ghVersion = (& gh --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
    Write-Item 'gh' $ghVersion 'ok'
    Write-Item '路径' $gh.Source 'ok'
    $ghOk = $true
} else {
    Write-Item 'gh' '未找到' 'bad'
    Add-Problem 'GitHub CLI 未安装 → 从 https://github.com/cli/cli/releases 下载 gh_*_windows_amd64.msi 后 msiexec /i <msi> /qn /norestart（装完新开终端）。'
}

# ---------------------------------------------------------------------------
# 3. 代理
# ---------------------------------------------------------------------------
Write-Section '3. 代理（GitHub 直连不通的环境必须配）'
$proxyVar = $null
foreach ($name in $ProxyEnvNames) {
    $value = Get-RegistryEnv $name
    if (-not [string]::IsNullOrWhiteSpace($value)) { $proxyVar = [pscustomobject]@{ Name = $name; Value = $value }; break }
}
if ($proxyVar) {
    Write-Item '环境变量' ("{0} = {1}" -f $proxyVar.Name, $proxyVar.Value) 'ok'
    $current = [Environment]::GetEnvironmentVariable($proxyVar.Name)
    if ([string]::IsNullOrWhiteSpace($current)) {
        Write-Item '当前会话' '未生效（环境块是旧快照）' 'warn'
        Add-Problem ('本进程还没有代理变量 → 本次命令里显式带上，例如：$env:HTTPS_PROXY=''' + $proxyVar.Value + '''')
    } else {
        Write-Item '当前会话' '已生效' 'ok'
    }
    $uri = $null
    if ([Uri]::TryCreate($proxyVar.Value, [UriKind]::Absolute, [ref]$uri)) {
        $port = $uri.Port
        $listening = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($listening) {
            $owner = Get-Process -Id $listening[0].OwningProcess -ErrorAction SilentlyContinue
            Write-Item '端口监听' ("{0} 在监听（{1}）" -f $port, $owner.ProcessName) 'ok'
        } else {
            Write-Item '端口监听' ("{0} 没有进程监听 → 代理软件没开" -f $port) 'bad'
            Add-Problem ("代理端口 {0} 无监听：先把代理软件打开，再重试 gh / git 命令。" -f $port)
        }
    }
} else {
    $ie = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($ie -and $ie.ProxyEnable -eq 1 -and $ie.ProxyServer) {
        Write-Item '环境变量' '未设置' 'warn'
        Write-Item '系统代理(IE)' $ie.ProxyServer 'warn'
        Add-Problem ("系统代理是 {0}，但 gh（Go 写的）**不读系统代理**，只读 HTTPS_PROXY/HTTP_PROXY。若要长期使用，写入用户级变量：`n        [Environment]::SetEnvironmentVariable('HTTPS_PROXY','http://{0}','User')`n        [Environment]::SetEnvironmentVariable('HTTP_PROXY','http://{0}','User')`n        （写完后**新开终端**才生效）" -f $ie.ProxyServer)
    } else {
        Write-Item '环境变量' '未设置' '--'
        Write-Item '系统代理(IE)' '未启用' '--'
    }
}

# ---------------------------------------------------------------------------
# 4. gh 登录
# ---------------------------------------------------------------------------
Write-Section '4. gh 登录状态'
$account = $null
if ($ghOk) {
    $statusText = (& gh auth status 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
        $m = [regex]::Match($statusText, 'account\s+(\S+)')
        $account = if ($m.Success) { $m.Groups[1].Value } else { '（已登录）' }
        Write-Item 'auth status' ("已登录: {0}" -f $account) 'ok'
        $scopes = [regex]::Match($statusText, 'Token scopes:\s*(.+)')
        if ($scopes.Success) { Write-Item '令牌范围' $scopes.Groups[1].Value.Trim() 'ok' }
    } else {
        Write-Item 'auth status' '未登录' 'bad'
        Add-Problem "gh 未登录 → 运行（注意必须带上代理变量）：`n        gh auth login --hostname github.com --git-protocol https --web`n        浏览器里完成授权；**不要把密码/Token 发到对话里**。"
    }
}

# ---------------------------------------------------------------------------
# 5. Git 身份与凭据
# ---------------------------------------------------------------------------
Write-Section '5. Git 身份与凭据'
if ($git) {
    $userName = (& git config --get user.name 2>&1 | Out-String).Trim()
    $userEmail = (& git config --get user.email 2>&1 | Out-String).Trim()
    if ($userName -and $userEmail) {
        Write-Item 'user.name' $userName 'ok'
        Write-Item 'user.email' $userEmail 'ok'
    } else {
        Write-Item 'user.name / user.email' '未配置' 'warn'
        Add-Problem "Git 身份缺失（首次 commit 会被拦：`fatal: Author identity unknown`）→ 只在本仓库署名：`n        git config --local user.name '你的名字'`n        git config --local user.email 'you@users.noreply.github.com'"
    }
    $helper = (& git config --get-all 'credential.https://github.com.helper' 2>&1 | Out-String).Trim()
    if ($helper) {
        Write-Item 'credential.helper' ($helper -replace "`r?`n", ' / ') 'ok'
    } else {
        Write-Item 'credential.helper' '未接 gh' 'warn'
        Add-Problem "Git 还没有用 gh 的凭据 → 运行：gh auth setup-git --hostname github.com`n        （否则 git push 走 HTTPS 时会单独要求用户名/密码）"
    }
} else {
    Write-Item 'user.name / user.email' '（Git 未安装，跳过）' '--'
    Write-Item 'credential.helper' '（Git 未安装，跳过）' '--'
}

# ---------------------------------------------------------------------------
# 6. 仓库状态
# ---------------------------------------------------------------------------
Write-Section '6. 仓库状态'
if (-not $git) {
    Write-Item '仓库' '（Git 未安装，跳过）' '--'
} else {
    $target = $Repo
    if ([string]::IsNullOrWhiteSpace($target)) { $target = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Item '路径' ("不存在: {0}" -f $target) 'bad'
        Add-Problem ("指定的仓库目录不存在：{0}" -f $target)
    } else {
        $inside = (& git -C $target rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
        if ($inside -ne 'true') {
            Write-Item '仓库' ("{0} 还不是 Git 仓库" -f $target) 'warn'
            Add-Problem ("目录 {0} 未初始化 Git → git init -b main，或让 skill 里的发布流程带你走一遍。" -f $target)
        } else {
            $branch = (& git -C $target rev-parse --abbrev-ref HEAD 2>&1 | Out-String).Trim()
            $commitCount = (& git -C $target rev-list --count HEAD 2>&1 | Out-String).Trim()
            $dirty = (& git -C $target status --porcelain 2>&1 | Out-String).Trim()
            Write-Item '分支' $branch 'ok'
            Write-Item '提交数' $commitCount 'ok'
            Write-Item '工作区' $(if ($dirty) { '有未提交的改动' } else { '干净' }) $(if ($dirty) { 'warn' } else { 'ok' })
            if ($dirty) {
                $count = @($dirty -split "`r?`n" | Where-Object { $_.Trim() }).Count
                Add-Problem ("工作区有 {0} 处未提交改动 → 发布前先 git add -A && git commit（或明确说明只发布已提交的内容）。" -f $count)
            }
            $remote = (& git -C $target remote -v 2>&1 | Out-String).Trim()
            if ($remote) {
                Write-Item 'remote' (($remote -replace "`r?`n", ' ; ')) 'ok'
            } else {
                Write-Item 'remote' '未配置（还没连到 GitHub）' '--'
            }
            $tags = (& git -C $target tag -l 2>&1 | Out-String).Trim()
            Write-Item '本地 tag' $(if ($tags) { ($tags -replace "`r?`n", ', ') } else { '（无）' }) '--'
            $headFiles = (& git -C $target ls-tree -r --name-only HEAD 2>&1 | Out-String).Trim()
            if ($headFiles) {
                Write-Item '受控文件数' (@($headFiles -split "`r?`n" | Where-Object { $_.Trim() }).Count) 'ok'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 7. 结论
# ---------------------------------------------------------------------------
Write-Section '7. 需要处理'
if ($script:Problems.Count -eq 0) {
    Write-Host '  没有发现问题，可以开始发布流程（SKILL.md 里的「发布流程」一节）。'
} else {
    $i = 1
    foreach ($p in $script:Problems) {
        Write-Host ("  {0}) {1}" -f $i, $p)
        $i++
    }
}

Write-Host ''
Write-Host 'SUMMARY'
if ($git) { Write-Host ("  git=ok ({0})" -f $gitVersion) } else { Write-Host '  git=missing' }
if ($ghOk) { Write-Host ("  gh=ok ({0})" -f $ghVersion) } else { Write-Host '  gh=missing' }
if ($account) { Write-Host ("  gh_auth={0}" -f $account) } else { Write-Host '  gh_auth=none' }
if ($pathRepaired) { Write-Host '  path_repaired=yes (取自注册表，仅本进程有效)' }
Write-Host ("  problems={0}" -f $script:Problems.Count)
exit 0
