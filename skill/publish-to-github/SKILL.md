---
name: publish-to-github
description: Package a finished local project and publish it to GitHub end to end — verify git/gh/proxy readiness, write .gitattributes and .gitignore, make the first commit, create the repo, push, tag a version and publish a Release.
---

# Publish to GitHub

把刚写完的代码从「本地一堆文件」推到「GitHub 上有仓库、有 tag、有 Release」。包含这条链路上真实踩过的坑：代理、BOM、署名、`.gitattributes`、临时文件混入提交、tag 与软件内版本号不一致。

**核心安全规则（任何情况下都不违反）**

1. 不把仓库推到用户没确认的地方；仓库名、可见性、要执行的操作**先列出来让用户确认**。
2. 不提交密钥：`.env`、`*.pem`、`id_rsa`、`token`、`credentials` 一律先查再提交。
3. 用户提到密码、验证码、2FA、Token 时，**让用户自己在浏览器完成授权**，绝不要求用户把这些发到对话里。
4. 每次 `git add` 前先看 `git status`，别把临时文件（`*.tmp`、草稿、日志）一起提交。

## When to use

- 用户说「把这个项目推到我的 GitHub」「发布到 GitHub」「推到远程仓库」。
- 用户要打 tag、发 Release，或者要把本地已有仓库关联到新远程。
- 用户的环境还没装 git / gh，或 gh 还没登录，需要先做一次性准备。

## Quick start

```powershell
# 1) 只读自检：git / gh / 代理 / 登录 / 身份 / 仓库 一次看清
powershell -ExecutionPolicy Bypass -File scripts\check-env.ps1 -Repo <项目目录>

# 2) 按下面「发布流程」一节走完 7 步；缺环境先做「一次性准备」
```

`scripts\check-env.ps1` **只读**：不装东西、不改注册表、不写 git config、不做写操作（唯一网络访问是 gh 的令牌校验）。输出末尾有一段 `SUMMARY` 便于快速判断。

| 参数 | 作用 |
| --- | --- |
| `-Repo <目录>` | 检查指定仓库；省略时用当前目录 |
| `-ProxyEnvNames <字符串数组>` | 额外信任的代理环境变量名（默认 `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY` 及小写变体） |

## 一次性准备（只在环境缺东西时做）

### 1. 装 Git（Windows）

先查是否已装：`git --version`。没装就用官方安装包，**不要**新增包管理器（winget 在需要代理的环境里常报 `InternetReadFile() failed. 0x80072ee2`）：

```powershell
$url = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/Git-2.55.0.5-64-bit.exe'
curl.exe -L -o "$env:TEMP\git-setup.exe" $url          # 需要代理时加 -x http://127.0.0.1:7897
Get-AuthenticodeSignature "$env:TEMP\git-setup.exe"    # 必须 Valid，签署者 Johannes Schindelin
Start-Process "$env:TEMP\git-setup.exe" -ArgumentList '/VERYSILENT','/NORESTART','/NOCANCEL','/SP-' -Wait
git --version                                          # 2.55.0.windows.5
```

### 2. 装 GitHub CLI

```powershell
$url = 'https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_windows_amd64.msi'
curl.exe -L -o "$env:TEMP\gh.msi" $url
(Get-FileHash "$env:TEMP\gh.msi" -Algorithm SHA256).Hash   # 与官方发布页/SHA256SUMS 核对
Get-AuthenticodeSignature "$env:TEMP\gh.msi"              # 必须 Valid，签署者 GitHub, Inc.
Start-Process msiexec.exe -ArgumentList '/i',"$env:TEMP\gh.msi",'/qn','/norestart' -Wait
gh --version
```

### 3. 代理（GitHub 直连不通时才需要）

症状：`dial tcp 20.205.243.166:443: connectex: … did not properly respond`、`Timeout was reached`、`proxyconnect tcp: … actively refused`。

原因：**gh 是 Go 写的，只读环境变量，不读 IE/系统代理设置。**

```powershell
# 写入用户级（长期有效；写完后新开的终端才认）
[Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://127.0.0.1:7897', 'User')
[Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://127.0.0.1:7897', 'User')

# 验证：直连应超时、走代理应 200
curl.exe -sS -o NUL -w "direct: %{http_code} in %{time_total}s`n" --max-time 15 --noproxy '*' https://github.com
curl.exe -sS -o NUL -w "proxy : %{http_code} in %{time_total}s`n" --max-time 15 -x http://127.0.0.1:7897 https://github.com
```

⚠️ 端口要按用户实际的代理软件调整。如果代理软件中途重启，登录会失败，重试即可。

### 4. 登录 gh（由用户在浏览器完成授权）

```powershell
gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key

# 让 Git 走 gh 的凭据（不执行这步，git push 会另外要用户名/密码）
gh auth setup-git --hostname github.com

gh auth status      # ✓ Logged in to github.com account <账号>
```

`gh auth login --web` 会打印一次性代码并打开 `https://github.com/login/device`。代码可以直接从命令输出里读给用户，也可以帮用户放进剪贴板。**浏览器里的密码、验证码、2FA 由用户自己完成。**

## 发布流程

### 步骤 1：准备与自检

```powershell
powershell -ExecutionPolicy Bypass -File <skill>\scripts\check-env.ps1 -Repo <项目目录>
```

先解决输出里「需要处理」的每一条，再往下走。新装的软件**必须新开终端**才在 PATH 里（脚本自己会从注册表重建 PATH 兜底）。

### 步骤 2：确认版本号一致

软件内显示的版本号和要打的 tag 必须一致，否则用户装完看到 `1.0.0`、GitHub 上是 `v0.1.0`。搜一遍：

```powershell
Get-ChildItem <项目> -Recurse -File -Include *.cs,*.ps1,*.md,*.json,*.yaml,*.toml |
  Select-String -Pattern '\d+\.\d+\.\d+' | Select-Object -First 40
```

典型落点：程序集版本特性（`AssemblyVersion` / `AssemblyFileVersion`）、安装脚本里的 `DisplayVersion`、README 的安装说明。

### 步骤 3：初始化仓库（只做一次）

```powershell
git init -b main
```

**`.gitattributes`（有必须保 BOM 的脚本或二进制资源时尤其重要）**

```gitattributes
# PowerShell 脚本必须保留 UTF-8 BOM（无 BOM 时 PS 5.1 按 GBK 读，中文全乱）
*.ps1   binary
*.cs    binary
*.png   binary
*.jpg   binary
*.ico   binary
# 文档与代码统一换行
*.md    text eol=crlf
*.txt   text eol=crlf
*.yaml  text eol=crlf
*.py    text eol=lf
*.html  text eol=lf
*.js    text eol=lf
*.json  text eol=lf
```

配套设置：

```powershell
git config core.autocrlf false
git check-attr -a -- path\to\script.ps1    # 确认 binary: set / text: unset
```

**`.gitignore`（按项目类型裁剪，构建产物一定排除）**

```gitignore
*.log
.tmp*/
__pycache__/
.vscode/
.idea/
Thumbs.db
Desktop.ini
```

### 步骤 4：Git 署名（本机第一次提交必做）

不配会被拦：`fatal: Author identity unknown`。

```powershell
# 推荐：只在本仓库署名，不写全局，避免泄露个人信息
git config --local user.name  '项目署名或用户名'
git config --local user.email 'you@users.noreply.github.com'
```

### 步骤 5：第一次提交

```powershell
git status                 # 先看！确认没有密钥、临时文件、草稿
git add -A
git status --porcelain     # 再确认一次暂存区
git commit -m "feat: <一句话说明这个项目是什么>"
git log --oneline -n 1
```

⚠️ **别在仓库里同时创建「提交信息临时文件」和 `git add -A`**：临时文件会被一起提交进去（实测踩过，只能 `git reset --soft HEAD~1` 重来）。多行提交信息要么用 here-string 传 `-m`，要么把临时文件放在仓库**外面**。

### 步骤 6：建远程仓库并推送

**执行前先把仓库名、可见性、要执行的命令列给用户确认。**

```powershell
$env:HTTPS_PROXY = (Get-ItemProperty 'HKCU:\Environment' -Name HTTPS_PROXY).HTTPS_PROXY  # 旧会话需要

gh repo create <仓库名> --public --source . --remote origin --disable-wiki
git push -u origin main

# 或者关联到已经存在的远程仓库
git remote add origin https://github.com/<账号>/<仓库名>.git
git push -u origin main
```

**执行后核对（务必做，别默认成功）**

```powershell
git remote -v
git rev-parse main origin/main                  # 两个 SHA 必须相同
git rev-list --left-right --count main...origin/main   # 期望 0  0
gh repo view <账号>/<仓库名> --json nameWithOwner,visibility,defaultBranchRef,url
git ls-tree -r --name-only origin/main          # 远端到底有哪些文件
```

### 步骤 7：打 tag + 发 Release

```powershell
git tag -a v0.1.0 -m "v0.1.0 首个公开版本"
git push origin main
git push origin v0.1.0

gh release create v0.1.0 --title "v0.1.0 — <一句话标题>" --notes-file <说明文件> --latest
gh release list                                 # 确认 Latest
gh release view v0.1.0 --json body --jq '.body' # 确认正文真的进去了
```

发布说明建议结构：一句话定位 → 两种/主要用法（带可复制命令）→ 当前功能（分块列）→ 系统要求 → 已知限制 → 许可。用 `--notes-file` 传文件，避免长文本在命令行里被转义。

```powershell
# 想让用户直接下载可执行文件，把构建产物作为附件上传
gh release upload v0.1.0 <产物路径>
```

## 排错表

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `git: command not found` | 装完 Git 没重开终端 | 新开终端；本会话内可让 `check-env.ps1` 从注册表重建 PATH |
| `Author identity unknown` | 没配 user.name/email | 步骤 4 的 `--local` 配置 |
| `dial tcp … did not properly respond` | 直连 GitHub 不通 | 设 `HTTPS_PROXY`/`HTTP_PROXY` 后重试 |
| `proxyconnect tcp: … actively refused` | 代理软件没开/端口变了 | 启动代理软件；用 `Get-NetTCPConnection -LocalPort <端口> -State Listen` 确认 |
| `gh: not logged into any GitHub hosts` | 未登录 | 步骤 4 登录，注意带上代理变量 |
| `git push` 反复要密码 | 没执行 `gh auth setup-git` | 执行它，再 `git config --get-all credential.https://github.com.helper` 复核 |
| 中文变乱码 / 脚本解析报错 | `.ps1` 的 UTF-8 BOM 丢了 | 补回 `EF BB BF`；`.gitattributes` 里把 `*.ps1` 设为 `binary` |
| `git status` 显示 `.ps1`/`.png` 为 `Bin` | `.gitattributes` 声明了 `binary` | 正常，是有意保护字节不变 |
| 远端文件数比预期多 | 临时文件被提交 | `git rm --cached <文件>` 后重新提交 |
| 提交里混进了临时文件 | `git add -A` 之前创建了它 | `git reset --soft HEAD~1`，`git rm --cached <文件>`，重新提交 |
| tag 打错位置 | 打在了旧提交上 | `git tag -d v0.1.0`、`git push origin :refs/tags/v0.1.0`，再重新打 |
| `gh release view --json isLatest` 报 Unknown JSON field | 该 gh 版本没这个字段 | 用 `gh release list` 看 Latest 状态 |

## 收尾

- 发布后把临时文件（登录日志、发布说明草稿、自检输出目录、`%TEMP%` 下自己建的中间文件）删掉。
- 报给用户的结果要带上可核对的证据：仓库 URL、远端文件数、`main` 与 `origin/main` 是否同 SHA、tag 名、Release URL。
