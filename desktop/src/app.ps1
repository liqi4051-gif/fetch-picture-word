#requires -Version 5.1
<#
    fetch-picture-word 桌面版 —— 主程序（微信风格窗口）

    这个脚本被 launcher.exe（或 install.ps1 生成的快捷方式）以隐藏控制台的方式
    启动，出来就是一个微信对话样式的窗口：
      · 左边「图」气泡 = 识别结果，右边「我」气泡 = 发出去的图片
      · 下面一排按钮：区域截图 / 粘贴图片 / 选择文件 / 清空
      · 完全离线：OCR 用 Windows 自带的 Windows.Media.Ocr，图片不出本机

    界面是内嵌的一段 HTML，用 WebBrowser 控件（IE11 内核）渲染；
    JS 通过 window.external.Call() 调用本脚本的动作，结果用 InvokeScript 推回页面。

    开发时可以用 -SelfTest <图片> 自检：启动后自动识别这张图，把窗口截图与识别
    结果写到 -SelfTestOut 指定的目录，然后退出。正常双击启动不会走到这条路径。
#>
[CmdletBinding()]
param(
    [string]$SelfTest,
    [string]$SelfTestOut
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

# 原生调用：高分屏适配、窗口截图、窗口边框尺寸
if (-not ('FpwNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FpwNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    // flags=2 是 PW_RENDERFULLCONTENT，只有它能把 WebBrowser 这种控件的画面画出来
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT value, int size);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetricsForDpi(int index, uint dpi);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hWnd);

    // PrintWindow 画出来的位图里，客户区左上角的位置。
    // 左边框取 DWM 扩展边框（Win11 上是 7 左右），上边距是标题栏 + 上边框：
    // DWM 的扩展边框在 Win11 上不含标题栏，直接用它会切掉顶部。
    public static bool GetFrameSize(IntPtr hWnd, out int borderX, out int borderY)
    {
        borderX = 0;
        borderY = 0;
        RECT frame;
        try
        {
            // DWMWA_EXTENDED_FRAME_BOUNDS = 9
            if (DwmGetWindowAttribute(hWnd, 9, out frame, Marshal.SizeOf(typeof(RECT))) == 0 &&
                frame.Right - frame.Left > 0 && frame.Bottom - frame.Top > 0)
            {
                borderX = frame.Left - GetWindowRectLeft(hWnd);
            }
        }
        catch (Exception)
        {
            borderX = 0;
        }
        if (borderX < 0) { borderX = 0; }

        int caption = 0;
        int padded = 0;
        try
        {
            uint dpi = GetDpiForWindow(hWnd);
            if (dpi == 0) { dpi = 96; }
            caption = GetSystemMetricsForDpi(4, dpi);   // SM_CYCAPTION
            padded = GetSystemMetricsForDpi(92, dpi);   // SM_CXPADDEDBORDER
        }
        catch (Exception)
        {
            caption = GetSystemMetrics(4);
            padded = GetSystemMetrics(92);
        }
        if (caption <= 0) { caption = GetSystemMetrics(4); }
        if (padded < 0) { padded = 0; }
        borderY = caption + padded;
        if (borderY < 0) { borderY = 0; }
        LastFrame = "caption=" + caption + " padded=" + padded;
        return true;
    }

    private static int GetWindowRectLeft(IntPtr hWnd)
    {
        RECT window;
        GetWindowRect(hWnd, out window);
        return window.Left;
    }

    private static int GetWindowRectTop(IntPtr hWnd)
    {
        RECT window;
        GetWindowRect(hWnd, out window);
        return window.Top;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    /// 让本进程按显示器实际 DPI 渲染。必须在创建任何窗口/控件之前调用：
    /// IE 的 WebBrowser 控件在高 DPI 机器上会被系统按 200% 拉伸，页面里的
    /// 绝对定位（底部输入框）就会跑到窗口之外，底部提示行被切掉。
    public static bool MakeDpiAware()
    {
        try
        {
            // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
            if (SetProcessDpiAwarenessContext(new IntPtr(-4))) { return true; }
        }
        catch (Exception) { }
        try { return SetProcessDPIAware(); }
        catch (Exception) { return false; }
    }

    public static string LastFrame = "";
}
'@ -ErrorAction Stop
}

try { [void][FpwNative]::MakeDpiAware() } catch { }

$script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:ScriptRoot 'ocr.ps1')

# ---------------------------------------------------------------------------
# 与页面通信的桥（必须是 COM 可见的编译类，PSObject 不行）
# ---------------------------------------------------------------------------
if (-not ('FpwBridge' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComVisible(true)]
[ClassInterface(ClassInterfaceType.AutoDual)]
public class FpwBridge
{
    public static System.Func<string, string, string> Router;

    public string Call(string action, string payload)
    {
        if (Router == null) { return "{\"ok\":false,\"error\":\"router not ready\"}"; }
        try
        {
            return Router(action == null ? "" : action, payload == null ? "" : payload);
        }
        catch (Exception)
        {
            return "{\"ok\":false,\"error\":\"router failed\"}";
        }
    }

    public string Ping() { return Call("ping", ""); }
}
'@
}

# ---------------------------------------------------------------------------
# JSON 小工具（自己拼，避免 ConvertTo-Json 在 PS 5.1 里的转义坑）
# ---------------------------------------------------------------------------
function ConvertTo-FpwJsonString([string]$Text) {
    if ($null -eq $Text) { return '""' }
    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append('"')
    foreach ($character in $Text.ToCharArray()) {
        $code = [int]$character
        switch ($character) {
            '"' { $null = $builder.Append('\"'); continue }
            '\' { $null = $builder.Append('\\'); continue }
            "`n" { $null = $builder.Append('\n'); continue }
            "`r" { $null = $builder.Append('\r'); continue }
            "`t" { $null = $builder.Append('\t'); continue }
        }
        if ($code -lt 0x20) {
            $null = $builder.Append('\u' + $code.ToString('x4'))
        } elseif ($code -gt 0x7E) {
            # \uXXXX 转义，避免脚本与页面之间的编码问题
            $null = $builder.Append('\u' + $code.ToString('x4'))
        } else {
            $null = $builder.Append($character)
        }
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Select-FpwEngine {
    try {
        $engine = Get-FpwOcrEngine ''
        if ($engine) {
            return [pscustomobject]@{ ok = $true; tag = $engine.RecognizerLanguage.LanguageTag }
        }
        return [pscustomobject]@{ ok = $false; error = '这台电脑没有安装 OCR 语言包' }
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# 界面 HTML
# ---------------------------------------------------------------------------
$script:PageHtml = @'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<title>提取图片文字</title>
<style>
* { box-sizing: border-box; }
html, body { height: 100%; margin: 0; padding: 0; }
body {
  font-family: "Microsoft YaHei", "微软雅黑", sans-serif;
  font-size: 14px; color: #191919; background: #ededed;
  overflow: hidden; cursor: default;
}
#app { width: 100%; height: 100%; display: block; }

/* 顶栏 */
#titlebar {
  height: 58px; background: #f5f5f5; border-bottom: 1px solid #dcdcdc;
  padding: 0 16px;
}
#titlebar .avatar {
  width: 32px; height: 32px; border-radius: 4px; background: #07c160;
  color: #fff; text-align: center; line-height: 32px; font-size: 17px;
  display: inline-block; vertical-align: middle; margin-top: 13px;
}
#titlebar .title {
  font-size: 16px; font-weight: bold; margin-left: 10px;
  display: inline-block; vertical-align: middle; margin-top: 13px;
}
#titlebar .status {
  float: right; color: #9a9a9a; font-size: 12px; margin-top: 21px;
}
#titlebar .dot {
  width: 8px; height: 8px; border-radius: 4px; background: #cccccc;
  display: inline-block; margin-right: 6px; vertical-align: middle;
}
#titlebar .dot.on { background: #07c160; }

/* 对话区 */
#feed {
  position: absolute; top: 59px; bottom: 96px; left: 0; right: 0;  /* 底边由脚本按输入条实际高度对齐 */
  overflow-y: auto; overflow-x: hidden; padding: 14px 18px 6px 18px;
}
.row { margin-bottom: 16px; }
.row .avatar {
  width: 34px; height: 34px; border-radius: 4px; background: #07c160; color: #fff;
  text-align: center; line-height: 34px; font-size: 17px;
}
.row.me .avatar { background: #3b7ef2; }
.row .avatar, .row .bubble { display: inline-block; vertical-align: top; }
.row .bubble {
  max-width: 74%; margin: 0 10px; padding: 9px 13px; border-radius: 5px;
  background: #ffffff; line-height: 1.65; word-wrap: break-word;
  word-break: break-all; white-space: pre-wrap; position: relative;
  border: 1px solid #e3e3e3;
}
.row.me { text-align: right; }
.row.me .bubble { background: #95ec69; border-color: #8fe063; text-align: left; }
.row .bubble img { max-width: 100%; max-height: 420px; display: block; border-radius: 3px; }
.row .meta {
  color: #9a9a9a; font-size: 11px; margin: 4px 0 0 54px;
}
.row.me .meta { margin: 4px 54px 0 0; text-align: right; }
.row .acts { margin: 5px 0 0 54px; }
.row .acts a {
  color: #576b95; font-size: 12px; margin-right: 14px; cursor: pointer;
  text-decoration: none;
}
.row .acts a:hover { text-decoration: underline; }

/* 等待气泡 */
.dots span {
  display: inline-block; width: 6px; height: 6px; margin-right: 4px;
  background: #b8b8b8; border-radius: 3px; vertical-align: middle;
}
.dots span:nth-child(2) { opacity: 0.7; }
.dots span:nth-child(3) { opacity: 0.4; }

/* 底部输入条 */
#composer {
  position: absolute; bottom: 0; left: 0; right: 0;
  background: #f7f7f7; border-top: 1px solid #dcdcdc; padding: 8px 16px 6px 16px;
}
#composer .field {
  height: 32px; line-height: 32px; background: #ffffff; border: 1px solid #e0e0e0;
  border-radius: 4px; color: #a6a6a6; padding: 0 12px; margin-bottom: 8px;
  white-space: nowrap; overflow: hidden;
}
#composer .field kbd {
  font-family: Consolas, monospace; background: #f0f0f0; border: 1px solid #ddd;
  border-radius: 3px; padding: 0 4px; color: #666666;
}
.btn {
  display: inline-block; padding: 0 16px; height: 30px; line-height: 28px;
  border: 1px solid #dcdcdc; border-radius: 15px; background: #ffffff;
  color: #333333; margin-right: 9px; cursor: pointer; font-size: 13px;
}
.btn:hover { background: #f2f2f2; }
.btn.primary { background: #07c160; border-color: #07c160; color: #ffffff; }
.btn.primary:hover { background: #06ad56; }
#hint { color: #9a9a9a; font-size: 11px; margin-top: 2px; line-height: 15px; }
</style>
</head>
<body>
<div id="app">
  <div id="titlebar">
    <div class="avatar">图</div>
    <div class="title">提取图片文字</div>
    <div class="status"><span class="dot" id="dot"></span><span id="engine">正在检查识别引擎…</span></div>
  </div>

  <div id="feed">
    <div class="row bot">
      <div class="avatar">图</div>
      <div class="bubble">把图片发给我，我读出里面的文字。<br>点下面的「区域截图」框选屏幕，也可以直接 Ctrl+V 粘贴图片，或者选择本地文件。识别完全在本机离线完成，图片不会上传。</div>
      <div class="meta">刚刚</div>
    </div>
  </div>

  <div id="composer">
    <div class="field">按 <kbd>Ctrl</kbd> + <kbd>V</kbd> 粘贴截图，或把图片文件拖进窗口…</div>
    <div>
      <span class="btn primary" onclick="act('region')">区域截图</span>
      <span class="btn" onclick="act('paste')">粘贴图片</span>
      <span class="btn" onclick="act('file')">选择文件</span>
      <span class="btn" onclick="act('clear')">清空</span>
    </div>
    <div id="hint">结果会以对话气泡的形式出现在上方 · 点「复制文字」可直接粘贴到别处</div>
  </div>
</div>

<script>
var feed = document.getElementById('feed');
var busy = null;

// 输入条高度随内容变化，量一次写回 #feed，保证两边不重叠也不留缝
function fitFeed() {
  var composer = document.getElementById('composer');
  if (!composer) { return; }
  feed.style.bottom = (composer.offsetHeight + 1) + 'px';
}
fitFeed();
if (window.addEventListener) {
  window.addEventListener('resize', fitFeed, false);
}

function clock() {
  var now = new Date();
  function pad(value) { return value < 10 ? '0' + value : '' + value; }
  return pad(now.getHours()) + ':' + pad(now.getMinutes());
}

function scrollDown() { feed.scrollTop = feed.scrollHeight; }

function act(name) {
  var reply = '';
  try { reply = window.external.Call(name, ''); } catch (error) { alert('调用失败：' + error.message); return; }
  if (!reply) { return; }
  var info;
  try { info = JSON.parse(reply); } catch (error) { return; }
  if (info.action === 'clear') { clearFeed(); }
  if (info.notice) { showNotice(info.notice); }
}

function newRow(kind) {
  var row = document.createElement('div');
  row.className = 'row ' + kind;
  var avatar = document.createElement('div');
  avatar.className = 'avatar';
  avatar.innerText = kind === 'me' ? '我' : '图';
  var bubble = document.createElement('div');
  bubble.className = 'bubble';
  row.bubble = bubble;
  if (kind === 'me') { row.appendChild(bubble); row.appendChild(avatar); }
  else { row.appendChild(avatar); row.appendChild(bubble); }
  feed.appendChild(row);
  scrollDown();
  return row;
}

function addMeta(row, text) {
  var meta = document.createElement('div');
  meta.className = 'meta';
  meta.innerText = text;
  row.appendChild(meta);
  scrollDown();
  return meta;
}

function addActions(row, text, raw) {
  var acts = document.createElement('div');
  acts.className = 'acts';
  var copy = document.createElement('a');
  copy.innerText = '复制文字';
  copy.onclick = function () {
    try { window.external.Call('copy', text); } catch (error) { }
  };
  acts.appendChild(copy);
  if (raw && raw !== text) {
    var toggle = document.createElement('a');
    toggle.innerText = '查看原始识别结果';
    toggle.onclick = function () {
      if (toggle.innerText === '查看原始识别结果') {
        row.bubble.innerText = raw;
        toggle.innerText = '返回整理后的文字';
      } else {
        row.bubble.innerText = text;
        toggle.innerText = '查看原始识别结果';
      }
      scrollDown();
    };
    acts.appendChild(toggle);
  }
  row.appendChild(acts);
}

function showBusy(label) {
  var row = newRow('bot');
  row.bubble.className = 'bubble dots';
  row.bubble.innerHTML = '<span></span><span></span><span></span> 正在识别' + (label ? '（' + label + '）' : '') + '…';
  busy = row;
  scrollDown();
  return row;
}

function clearBusy() {
  if (busy && busy.parentNode) { busy.parentNode.removeChild(busy); }
  busy = null;
}

// 图片气泡：图片以 data URI 传进来。
// 注意：这里不能写 <img src="file:///...">，IE 内核在 about:blank 页面上加载本地文件
// 会直接抛异常，后面的代码全部不执行。
function showImage(fileName, label, stamp) {
  var row = newRow('me');
  try {
    var image = document.createElement('img');
    // 页面本身是 file:// 打开的临时页，图片放同一个目录里用相对路径引用即可
    image.src = fileName + '?t=' + new Date().getTime();
    row.bubble.appendChild(image);
  } catch (error) {
    row.bubble.innerText = '（缩略图加载失败：' + error.message + '）';
  }
  addMeta(row, label + ' · ' + (stamp || clock()));
  return row;
}

function showText(text, meta, stamp) {
  var row = newRow('bot');
  row.bubble.innerText = text;
  addMeta(row, meta + ' · ' + (stamp || clock()));
  return row;
}

function showNotice(text) {
  showText(text, '提示');
}

function prettyJson(text) {
  try { return JSON.stringify(JSON.parse(text), null, 2); } catch (error) { return text; }
}

function clearFeed() {
  while (feed.firstChild) { feed.removeChild(feed.firstChild); }
  busy = null;
  showNotice('对话已清空，继续发图片给我吧。');
}

// ---- 由 PowerShell 调用的入口 ----
window.fpwEngine = function (json) {
  var info = JSON.parse(json);
  var label = document.getElementById('engine');
  var dot = document.getElementById('dot');
  if (info.ok) {
    label.innerText = info.languages + ' · 离线';
    dot.className = 'dot on';
  } else {
    label.innerText = info.error;
    dot.className = 'dot';
  }
  return 'ok';
};

window.fpwImage = function (json) {
  var info = JSON.parse(json);
  clearBusy();
  showImage(info.file, info.label, info.time);
  showBusy(info.label);
  return 'ok';
};

window.fpwResult = function (json) {
  var result = JSON.parse(json);
  clearBusy();
  if (!result.ok) {
    showText('识别失败：' + result.error, '出错了');
    return 'ok';
  }
  if (!result.text) {
    showText('这张图片里没有找到文字。可以试试裁得更紧一点，或者换一张更清楚的图。', result.label + ' · 共 0 行');
    return 'ok';
  }
  var row = showText(result.text, result.label + ' · 共 ' + result.words + ' 词 · ' + result.lines + ' 行 · ' + result.elapsed + ' ms');
  addActions(row, result.text, result.raw);
  return 'ok';
};

window.fpwNotice = function (json) {
  var info = JSON.parse(json);
  showNotice(info.text);
  return 'ok';
};

window.fpwRaw = function (json) {
  var info = JSON.parse(json);
  var row = showText(prettyJson(info.data), info.label);
  return 'ok';
};
</script>
</body>
</html>
'@

# ---------------------------------------------------------------------------
# 窗体
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = '提取图片文字'
$form.ClientSize = New-Object System.Drawing.Size 880, 700
$form.MinimumSize = New-Object System.Drawing.Size 620, 480
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(237, 237, 237)

$browser = New-Object System.Windows.Forms.WebBrowser
$browser.Dock = 'Fill'
$browser.IsWebBrowserContextMenuEnabled = $false
$browser.WebBrowserShortcutsEnabled = $false
$browser.AllowWebBrowserDrop = $false
$browser.ScriptErrorsSuppressed = $true
# 滚动交给页面自己管（#feed 内部滚动），控件不要再加一条滚动条，否则底部按钮会被挤出去
$browser.ScrollBarsEnabled = $false
$browser.ObjectForScripting = (New-Object FpwBridge)
$form.Controls.Add($browser)

$script:ShotCounter = 0
$script:SessionFolder = Join-Path ([System.IO.Path]::GetTempPath()) ('fpw-app-' + [guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $script:SessionFolder -Force
$script:PendingLabel = ''
$script:EngineInfo = Select-FpwEngine

function Invoke-Page([string]$Function, [string]$Json) {
    try {
        $document = $browser.Document
        if ($null -eq $document) {
            if ($SelfTest) { Add-FpwSelfTestLog ('invoke ' + $Function + ' skipped: no document') }
            return
        }
        try {
            $reply = [string]$document.InvokeScript($Function, @([object]$Json))
            if ($SelfTest) { Add-FpwSelfTestLog ('invoke ' + $Function + ' -> [' + $reply + '] (' + $Json.Length + ' chars)') }
        } catch {
            if ($SelfTest) { Add-FpwSelfTestLog ('invoke ' + $Function + ' script error: ' + $_.Exception.Message) }
            throw
        }
    } catch {
        # 页面还没加载完时忽略
        if ($SelfTest) { Add-FpwSelfTestLog ('invoke ' + $Function + ' failed: ' + $_.Exception.Message) }
    }
}

function ConvertTo-FpwDataUri($Bitmap, [int]$MaxEdge = 420) {
    # 气泡里的缩略图：缩小再存成 JPEG，写进会话目录供页面用相对路径引用。
    $width = $Bitmap.Width
    $height = $Bitmap.Height
    $scale = 1.0
    if ($width -gt $MaxEdge -or $height -gt $MaxEdge) {
        $scale = [Math]::Min($MaxEdge / [double]$width, $MaxEdge / [double]$height)
    }
    $targetWidth = [Math]::Max(1, [int][Math]::Round($width * $scale))
    $targetHeight = [Math]::Max(1, [int][Math]::Round($height * $scale))

    $thumb = New-Object System.Drawing.Bitmap $targetWidth, $targetHeight
    $graphics = [System.Drawing.Graphics]::FromImage($thumb)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.Clear([System.Drawing.Color]::White)
    $graphics.DrawImage($Bitmap, 0, 0, $targetWidth, $targetHeight)
    $graphics.Dispose()

    $script:ShotCounter = $script:ShotCounter + 1
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
        Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    if ($codec) {
        $name = 'shot-{0}.jpg' -f $script:ShotCounter
        $parameters = New-Object System.Drawing.Imaging.EncoderParameters 1
        $parameters.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 82L
        $thumb.Save((Join-Path $script:SessionFolder $name), $codec, $parameters)
    } else {
        $name = 'shot-{0}.png' -f $script:ShotCounter
        $thumb.Save((Join-Path $script:SessionFolder $name), [System.Drawing.Imaging.ImageFormat]::Png)
    }
    $thumb.Dispose()
    return $name
}

function Start-FpwRecognition($Bitmap, [string]$Label) {
    $fileName = ConvertTo-FpwDataUri $Bitmap
    $imageJson = '{"file":' + (ConvertTo-FpwJsonString $fileName) +
        ',"label":' + (ConvertTo-FpwJsonString $Label) +
        ',"time":' + (ConvertTo-FpwJsonString (Get-Date -Format 'HH:mm')) + '}'
    Invoke-Page 'fpwImage' $imageJson
    $form.Refresh()

    $outcome = $null
    try {
        $outcome = Invoke-FpwOcr -Bitmap $Bitmap
    } catch {
        $outcome = [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message; ElapsedMs = 0 }
    }

    if ($outcome.Ok) {
        $resultJson = '{"ok":true,"text":' + (ConvertTo-FpwJsonString $outcome.Text) +
            ',"raw":' + (ConvertTo-FpwJsonString $outcome.Raw) +
            ',"lines":' + $outcome.Lines.Count +
            ',"words":' + $outcome.Words +
            ',"elapsed":' + $outcome.ElapsedMs +
            ',"label":' + (ConvertTo-FpwJsonString $Label) +
            ',"language":' + (ConvertTo-FpwJsonString $outcome.Language) + '}'
    } else {
        $resultJson = '{"ok":false,"error":' + (ConvertTo-FpwJsonString $outcome.Error) +
            ',"label":' + (ConvertTo-FpwJsonString $Label) + '}'
    }
    Invoke-Page 'fpwResult' $resultJson
}

# ---------------------------------------------------------------------------
# 区域截图：全屏覆盖层 + 拖框
# ---------------------------------------------------------------------------
function Initialize-FpwOverlay {
    # 框选浮层的绘制控件：开双缓冲、自己接管背景绘制，鼠标移动时整屏不闪。
    if ('FpwOverlayCanvas' -as [type]) { return $true }
    Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

public class FpwOverlayCanvas : Control
{
    public Image Image;
    public Rectangle Selection;
    public Rectangle Result;

    private Point origin;
    private bool dragging;
    private readonly Font labelFont;
    private readonly Font hintFont;
    private readonly Brush shade;
    private readonly Brush labelBack;
    private readonly Brush hintBack;
    private readonly Pen border;

    public FpwOverlayCanvas()
    {
        // 双缓冲 + 只走 OnPaint：不再先擦背景再画图，整屏才不会闪
        SetStyle(ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint |
                 ControlStyles.ResizeRedraw, true);
        UpdateStyles();
        BackColor = Color.Black;
        labelFont = new Font("Microsoft YaHei", 9F);
        hintFont = new Font("Microsoft YaHei", 12F);
        shade = new SolidBrush(Color.FromArgb(120, 0, 0, 0));
        labelBack = new SolidBrush(Color.FromArgb(200, 0, 0, 0));
        hintBack = new SolidBrush(Color.FromArgb(190, 0, 0, 0));
        border = new Pen(Color.FromArgb(7, 193, 96), 2F);
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        // 背景由 OnPaint 整块画掉，这里什么都不做
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        if (Image != null)
        {
            g.DrawImageUnscaled(Image, 0, 0);
        }
        else
        {
            g.Clear(Color.Black);
        }

        Rectangle sel = Selection;
        int w = ClientSize.Width;
        int h = ClientSize.Height;

        if (sel.Width > 0 && sel.Height > 0)
        {
            // 只压暗选区外的四条边
            g.FillRectangle(shade, 0, 0, w, sel.Top);
            g.FillRectangle(shade, 0, sel.Bottom, w, h - sel.Bottom);
            g.FillRectangle(shade, 0, sel.Top, sel.Left, sel.Height);
            g.FillRectangle(shade, sel.Right, sel.Top, w - sel.Right, sel.Height);
            g.DrawRectangle(border, sel.Left, sel.Top, sel.Width - 1, sel.Height - 1);

            string label = sel.Width + " × " + sel.Height;
            SizeF labelSize = g.MeasureString(label, labelFont);
            float labelX = Math.Min(sel.Left + 4, Math.Max(2, w - labelSize.Width - 8));
            float labelY = sel.Top - labelSize.Height - 4;
            if (labelY < 2)
            {
                labelY = sel.Top + 4;
            }
            g.FillRectangle(labelBack, labelX, labelY, labelSize.Width + 6, labelSize.Height + 2);
            g.DrawString(label, labelFont, Brushes.White, labelX + 3, labelY + 1);
        }
        else
        {
            g.FillRectangle(shade, 0, 0, w, h);
        }

        string hint = "拖动鼠标框选要识别的区域，按 Esc 取消";
        SizeF hintSize = g.MeasureString(hint, hintFont);
        g.FillRectangle(hintBack, 22, 22, hintSize.Width + 20, hintSize.Height + 12);
        g.DrawString(hint, hintFont, Brushes.White, 32, 28);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left)
        {
            return;
        }
        dragging = true;
        origin = e.Location;
        Selection = new Rectangle(e.X, e.Y, 0, 0);
        Invalidate();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (!dragging)
        {
            return;
        }
        Selection = new Rectangle(
            Math.Min(origin.X, e.X),
            Math.Min(origin.Y, e.Y),
            Math.Abs(origin.X - e.X),
            Math.Abs(origin.Y - e.Y));
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left)
        {
            return;
        }
        dragging = false;
        if (Selection.Width < 4 || Selection.Height < 4)
        {
            Selection = Rectangle.Empty;
            Invalidate();
            return;
        }
        Result = Selection;
        Form owner = FindForm();
        if (owner != null)
        {
            owner.Close();
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            if (labelFont != null) { labelFont.Dispose(); }
            if (hintFont != null) { hintFont.Dispose(); }
            if (shade != null) { shade.Dispose(); }
            if (labelBack != null) { labelBack.Dispose(); }
            if (hintBack != null) { hintBack.Dispose(); }
            if (border != null) { border.Dispose(); }
        }
        base.Dispose(disposing);
    }
}
'@ -ReferencedAssemblies @('System.Drawing', 'System.Windows.Forms') -ErrorAction Stop
    return $true
}

function Get-FpwRegion {
    # 全屏浮层负责框选。绘制全部交给一个开好双缓冲的 C# 控件：
    # 之前用 Form.BackgroundImage + Paint 事件画，每移动一次鼠标都会先擦背景再重画整张
    # 2560x1440 的截图，整屏就在闪；双缓冲 + 自己画背景才是稳的。
    [void](Initialize-FpwOverlay)

    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $snapshot = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $capture = [System.Drawing.Graphics]::FromImage($snapshot)
    $capture.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $snapshot.Size)
    $capture.Dispose()

    $overlay = New-Object System.Windows.Forms.Form
    $overlay.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $overlay.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $overlay.Bounds = $bounds
    $overlay.TopMost = $true
    $overlay.ShowInTaskbar = $false
    $overlay.KeyPreview = $true
    $overlay.Cursor = [System.Windows.Forms.Cursors]::Cross

    $canvas = New-Object FpwOverlayCanvas
    $canvas.Image = $snapshot
    $canvas.Dock = [System.Windows.Forms.DockStyle]::Fill
    [void]$overlay.Controls.Add($canvas)

    $overlay.Add_KeyDown({
        param($sender, $event)
        if ($event.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $sender.Close() }
    })

    [void]$overlay.ShowDialog()
    $result = $canvas.Result
    $overlay.Dispose()
    $canvas.Dispose()

    if ($null -eq $result -or $result.Width -lt 4 -or $result.Height -lt 4) {
        $snapshot.Dispose()
        return $null
    }

    $crop = New-Object System.Drawing.Bitmap $result.Width, $result.Height
    $cropGraphics = [System.Drawing.Graphics]::FromImage($crop)
    $cropGraphics.DrawImage($snapshot, (New-Object System.Drawing.Rectangle 0, 0, $result.Width, $result.Height), $result, [System.Drawing.GraphicsUnit]::Pixel)
    $cropGraphics.Dispose()
    $snapshot.Dispose()
    return $crop
}

# ---------------------------------------------------------------------------
# 动作路由（页面上的按钮 → window.external.Call）
# ---------------------------------------------------------------------------
function Invoke-FpwAction([string]$Action, [string]$Payload) {
    switch ($Action) {
        'ping' { return '{"ok":true}' }

        'engine' {
            $info = $script:EngineInfo
            $languages = ''
            if ($info.ok) {
                try {
                    $languages = (Get-FpwLanguages | ForEach-Object { $_.name }) -join '、'
                } catch { $languages = $info.tag }
            }
            if ($info.ok) {
                return '{"ok":true,"languages":' + (ConvertTo-FpwJsonString $languages) +
                    ',"tag":' + (ConvertTo-FpwJsonString $info.tag) + '}'
            }
            return '{"ok":false,"error":' + (ConvertTo-FpwJsonString $info.error) + '}'
        }

        'region' {
            $bitmap = Get-FpwRegion
            if ($bitmap) { Start-FpwRecognition $bitmap '区域截图'; $bitmap.Dispose() }
            return '{"ok":true}'
        }

        'paste' {
            $bitmap = $null
            if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
                $bitmap = [System.Windows.Forms.Clipboard]::GetImage()
            }
            if ($bitmap) { Start-FpwRecognition $bitmap '粘贴的图片'; return '{"ok":true}' }
            return '{"ok":false,"notice":"剪贴板里没有图片。可以先截图（Win+Shift+S）再按 Ctrl+V。"}'
        }

        'file' {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Title = '选择要识别的图片'
            $dialog.Filter = '图片文件|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|所有文件|*.*'
            $dialog.Multiselect = $false
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                try {
                    $image = [System.Drawing.Image]::FromFile($dialog.FileName)
                    $copy = New-Object System.Drawing.Bitmap $image
                    $image.Dispose()
                    Start-FpwRecognition $copy ([System.IO.Path]::GetFileName($dialog.FileName))
                    $copy.Dispose()
                    return '{"ok":true}'
                } catch {
                    return '{"ok":false,"notice":"打不开这个文件：' + $_.Exception.Message + '"}'
                }
            }
            return '{"ok":true}'
        }

        'clear' {
            Invoke-Page 'fpwNotice' '{"text":"对话已清空，继续发图片给我吧。"}'
            return '{"ok":true,"action":"clear"}'
        }

        'copy' {
            try {
                [System.Windows.Forms.Clipboard]::SetText($Payload)
                return '{"ok":true}'
            } catch {
                return '{"ok":false,"error":' + (ConvertTo-FpwJsonString $_.Exception.Message) + '}'
            }
        }

        default { return '{"ok":false,"error":"unknown action"}' }
    }
}

[FpwBridge]::Router = {
    param([string]$Action, [string]$Payload)
    $outcome = Invoke-FpwAction $Action $Payload
    if ($Action -eq 'copy') {
        $form.Refresh()
    }
    return $outcome
}

# ---------------------------------------------------------------------------
# 键盘 / 拖放
# ---------------------------------------------------------------------------
function Receive-FpwClipboard {
    if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) {
        Invoke-Page 'fpwRaw' ('{"label":"提示","data":"剪贴板里没有图片，先截图再按 Ctrl+V"}')
        return
    }
    $bitmap = [System.Windows.Forms.Clipboard]::GetImage()
    if ($bitmap) { Start-FpwRecognition $bitmap '粘贴的图片' }
}

$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $event)
    if ($event.Control -and $event.KeyCode -eq [System.Windows.Forms.Keys]::V) {
        $event.Handled = $true
        Receive-FpwClipboard
    }
})

$form.AllowDrop = $true
$dropHandler = {
    param($sender, $event)
    if ($event.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $paths = $event.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        foreach ($path in $paths) {
            $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
            if (@('.png', '.jpg', '.jpeg', '.bmp', '.gif', '.tif', '.tiff') -contains $extension) {
                try {
                    $image = [System.Drawing.Image]::FromFile($path)
                    $copy = New-Object System.Drawing.Bitmap $image
                    $image.Dispose()
                    Start-FpwRecognition $copy ([System.IO.Path]::GetFileName($path))
                    $copy.Dispose()
                } catch {
                    Invoke-Page 'fpwResult' ('{"ok":false,"error":' + (ConvertTo-FpwJsonString $_.Exception.Message) + ',"label":"拖入的图片"}')
                }
                break
            }
        }
    }
}
$form.Add_DragEnter({ param($sender, $event) $event.Effect = [System.Windows.Forms.DragDropEffects]::Copy })
$form.Add_DragDrop($dropHandler)

$browser.Add_DocumentCompleted({
    $engineJson = Invoke-FpwAction 'engine' ''
    Invoke-Page 'fpwEngine' $engineJson
    if ($SelfTest) { Start-FpwSelfTest }
})

$form.Add_FormClosed({
    if ($script:SessionFolder) {
        Remove-Item -LiteralPath $script:SessionFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
})

# ---------------------------------------------------------------------------
# 自检（只在 -SelfTest 时启用，给开发/回归用）
# ---------------------------------------------------------------------------
$script:SelfTestStage = 0
$script:SelfTestLog = New-Object System.Collections.Generic.List[string]

function Add-FpwSelfTestLog([string]$Text) {
    $script:SelfTestLog.Add(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Text))
    if ($SelfTestOut -and (Test-Path -LiteralPath $SelfTestOut)) {
        Set-Content -LiteralPath (Join-Path $SelfTestOut 'stage.log') -Encoding UTF8 -Value $script:SelfTestLog
    }
}

function Save-FpwWindowShot([string]$Path) {
    # 三种截法各存一份：PrintWindow 能拿到 WebBrowser 这种控件的画面，
    # DrawToBitmap 是纯 GDI 绘制，CopyFromScreen 是屏幕上真实看到的样子。
    $width = $form.Width
    $height = $form.Height

    $printed = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($printed)
    $hdc = $graphics.GetHdc()
    $ok = [FpwNative]::PrintWindow($form.Handle, $hdc, 2)
    $graphics.ReleaseHdc($hdc)
    $graphics.Dispose()
    if ($ok) {
        # PrintWindow 从整窗左上角开始画，外面裹着不可见的 DWM 边框，
        # 所以按边框宽度裁掉，只留客户区，底部按钮才不会被切掉。
        $clientWidth = $form.ClientSize.Width
        $clientHeight = $form.ClientSize.Height
        $borderX = 0
        $borderY = 0
        [void][FpwNative]::GetFrameSize($form.Handle, [ref]$borderX, [ref]$borderY)
        if (($borderX + $clientWidth) -le $width -and ($borderY + $clientHeight) -le $height) {
            $cropped = New-Object System.Drawing.Bitmap $clientWidth, $clientHeight
            $cropGraphics = [System.Drawing.Graphics]::FromImage($cropped)
            $cropGraphics.DrawImage($printed,
                (New-Object System.Drawing.Rectangle 0, 0, $clientWidth, $clientHeight),
                (New-Object System.Drawing.Rectangle $borderX, $borderY, $clientWidth, $clientHeight),
                [System.Drawing.GraphicsUnit]::Pixel)
            $cropGraphics.Dispose()
            $printed.Dispose()
            $printed = $cropped
        }
        $printed.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    $printed.Dispose()

    $drawn = New-Object System.Drawing.Bitmap $width, $height
    $form.DrawToBitmap($drawn, (New-Object System.Drawing.Rectangle 0, 0, $width, $height))
    $drawn.Save(($Path -replace '\.png$', '-draw.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $drawn.Dispose()

    $rectangle = $form.Bounds
    $screenShot = New-Object System.Drawing.Bitmap $rectangle.Width, $rectangle.Height
    $screenGraphics = [System.Drawing.Graphics]::FromImage($screenShot)
    $screenGraphics.CopyFromScreen($rectangle.Left, $rectangle.Top, 0, 0, $screenShot.Size)
    $screenGraphics.Dispose()
    $screenShot.Save(($Path -replace '\.png$', '-screen.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $screenShot.Dispose()
}

function Complete-FpwSelfTest([string]$ErrorText) {
    $payload = [ordered]@{
        stage = 'selftest'
        image = $SelfTest
        error = $ErrorText
        bubble = $script:SelfTestBubble
        rows = $script:SelfTestRows
        shot = (Join-Path $SelfTestOut 'window.png')
        log = $script:SelfTestLog.ToArray()
    }
    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $SelfTestOut 'result.json') -Encoding UTF8
    $form.Close()
}

function Invoke-FpwSelfTestStage {
    $script:SelfTestStage = $script:SelfTestStage + 1
    Add-FpwSelfTestLog ('stage ' + $script:SelfTestStage + ' begin')
    switch ($script:SelfTestStage) {
        1 {
            [void][FpwNative]::SetForegroundWindow($form.Handle)
            $form.Activate()
            $image = [System.Drawing.Image]::FromFile($SelfTest)
            $copy = New-Object System.Drawing.Bitmap $image
            $image.Dispose()
            Start-FpwRecognition $copy ([System.IO.Path]::GetFileName($SelfTest))
            $copy.Dispose()
            Add-FpwSelfTestLog 'stage 1 done (recognition finished)'
        }
        2 {
            [void][FpwNative]::SetForegroundWindow($form.Handle)
            $form.Activate()
            Start-Sleep -Milliseconds 900
            Save-FpwWindowShot (Join-Path $SelfTestOut 'window.png')
            Add-FpwSelfTestLog 'stage 2 saved window.png'
            $elements = @($browser.Document.GetElementsByTagName('div'))
            $script:SelfTestRows = $elements.Count
            $bubbles = New-Object System.Collections.Generic.List[string]
            foreach ($element in $elements) {
                # IE 的 GetAttribute('class') 拿不到东西，必须用 className
                $class = [string]$element.GetAttribute('className')
                if ($class -like '*bubble*') { $bubbles.Add([string]$element.InnerText) }
            }
            $script:SelfTestBubble = ($bubbles -join ' || ')
            Add-FpwSelfTestLog ('stage 2 divs=' + $elements.Count + ' bubbles=' + $bubbles.Count)
            Add-FpwSelfTestLog ('stage 2 bubble: ' + $script:SelfTestBubble)
        }
        3 {
            # 停在窗口上多等一拍，让截图与识别结果都稳定下来
            Add-FpwSelfTestLog 'stage 3 (waiting before close)'
        }
        default {
            $script:SelfTestTimer.Stop()
            Add-FpwSelfTestLog 'closing form'
            Complete-FpwSelfTest ''
            # 必须真的关掉窗口，否则进程会一直挂着不退（自检是给自动化用的）
            $form.Close()
        }
    }
}

function Start-FpwSelfTest {
    if (-not $SelfTestOut) { $SelfTestOut = [System.IO.Path]::GetTempPath() }
    if (-not (Test-Path -LiteralPath $SelfTestOut)) {
        $null = New-Item -ItemType Directory -Path $SelfTestOut -Force
    }
    Add-FpwSelfTestLog ('selftest start: ' + $SelfTest)

    $script:SelfTestTimer = New-Object System.Windows.Forms.Timer
    $script:SelfTestTimer.Interval = 1500
    $script:SelfTestTimer.Add_Tick({
        try {
            Invoke-FpwSelfTestStage
        } catch {
            $script:SelfTestTimer.Stop()
            Add-FpwSelfTestLog ('stage failed: ' + $_.Exception.Message)
            Complete-FpwSelfTest $_.Exception.Message
        }
    })
    $script:SelfTestTimer.Start()
}

# 页面走临时文件 + file:// 打开：这样页面里的 <img> 可以直接用相对路径引用
# 同目录下的截图，不受 about:blank 页面读本地文件的限制。
$pagePath = Join-Path $script:SessionFolder 'page.html'
[System.IO.File]::WriteAllText($pagePath, $script:PageHtml, (New-Object System.Text.UTF8Encoding($false)))
$browser.Navigate('file:///' + $pagePath.Replace('\', '/'))
[void]$form.ShowDialog()
