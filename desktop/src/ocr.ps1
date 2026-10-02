#requires -Version 5.1
<#
    fetch-picture-word 桌面版 —— OCR 引擎
    调用 Windows 自带的 Windows.Media.Ocr 离线识别图片文字，不需要联网、
    不需要任何第三方依赖（没有 Tesseract / PaddleOCR / 云 API）。

    可以直接当命令行工具用：
        powershell -File ocr.ps1 -InputPath shot.png
        powershell -File ocr.ps1 -InputPath shot.png -Json
        powershell -File ocr.ps1 -ListLanguages

    也可以被 app.ps1 当作模块用（点源进来后调用 Invoke-FpwOcr）。
#>
Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# ---------------------------------------------------------------------------
# WinRT 互操作胶水
# ---------------------------------------------------------------------------
$script:AsTaskOperation = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1

$script:AsTaskAction = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
    } | Select-Object -First 1

function Wait-Operation($Operation, [Type]$ResultType) {
    $task = $script:AsTaskOperation.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $null = $task.Wait(-1)
    if ($task.IsFaulted) { throw $task.Exception.InnerException }
    $value = $task.Result
    return $value
}

function Wait-Action($Operation) {
    $task = $script:AsTaskAction.Invoke($null, @($Operation))
    $null = $task.Wait(-1)
    if ($task.IsFaulted) { throw $task.Exception.InnerException }
}

$script:WinRtReady = $false
function Initialize-FpwWinRt {
    if ($script:WinRtReady) { return }
    Write-Verbose 'loading WinRT projections'
    # 触碰一下这几个类型，让 PowerShell 加载对应的 WinRT 投影程序集
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime]
    $null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
    $script:WinRtReady = $true
}

# ---------------------------------------------------------------------------
# 文本清理：把引擎输出整理成可以直接使用的文字
#   会话技能  ->  会话技能        （CJK 之间的空格去掉）
#   1，280    ->  1.280           （数字里的全角顿号当小数点）
#   视图（V）  ->  视图 (V)        （CJK 与 ASCII 之间补空格）
#   PDF转图片  ->  PDF 转图片      （ASCII 与 CJK 之间补空格）
# 用 C# 实现，避免大段文本在 PowerShell 里逐行正则拖慢速度。
# ---------------------------------------------------------------------------
$script:CleanupSource = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

public static class FpwText
{
    private const string Cjk =
        "\u2E80-\u2EFF\u3000-\u303F\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF" +
        "\uF900-\uFAFF\uFE30-\uFE4F\uFF00-\uFFEF";

    // 汉字/假名本身（不含全角标点）。补中英边界空格时只能用这个范围，
    // 否则“14：08”这种全角冒号也会被当成汉字，空格会被加回去。
    private const string CjkLetters =
        "\u2E80-\u2EFF\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF";

    private static readonly Regex RxCjkSpace =
        new Regex("(?<=[" + Cjk + "])[ \t\u3000]+(?=[" + Cjk + "])", RegexOptions.Compiled);
    private static readonly Regex RxSpaceCjkPunct =
        new Regex("[ \t\u3000]+(?=[\u3001\u3002\uFF0C\uFF1B\uFF1A\uFF01\uFF05\uFF09\uFF1D\uFF3D\uFF5E])", RegexOptions.Compiled);
    private static readonly Regex RxCjkPunctSpace =
        new Regex("(?<=[\u3001\u3002\uFF0C\uFF1B\uFF1A\uFF01\uFF08\uFF09\uFF1D\uFF3D\uFF5E])[ \t\u3000]+", RegexOptions.Compiled);
    // 中英边界补空格。三个例外必须排除，否则会把已经正确的写法改坏：
    //   (?<!（) 全角括号里的 ASCII 不补空格：视图（V）而不是 视图（ V ）
    //   右半边不匹配全角括号/百分号：26.34％、视图（V）都不补
    private static readonly Regex RxCjkBoundary =
        new Regex("(?<=[" + CjkLetters + "])(?<!\uFF08)(?=[0-9A-Za-z(\\[])" +
                  "|(?<=[0-9A-Za-z)\\]%])(?![\uFF05\uFF09\uFF3D\uFF5E])(?=[" + CjkLetters + "])", RegexOptions.Compiled);

    // 数字里被 OCR 认错的小数点/千分位：1，204，338 · 00 / 1．280 · 50。
    // 这里只做「先统一成分隔符」的粗加工，真正的千分位 vs 小数点判断交给
    // FixNumberSeparators，因为 1,204,338.00 和 26.34 的 OCR 字形是一样的。
    private static readonly Regex RxNumericDash =
        new Regex("(?<=[0-9])\\s*[\uFF0C\u3001\uFF0E\uFF65\u00B7\u2022\u30FB]\\s*(?=[0-9])", RegexOptions.Compiled);
    private static readonly Regex RxNumberRun =
        new Regex("\\d+(?:[ \\t]*[\\uFF0C\\u3001\\uFF0E\\uFF65\\u00B7\\u2022\\u30FB][ \\t]*\\d+)+", RegexOptions.Compiled);
    private static readonly Regex RxNumberPart = new Regex("\\d+", RegexOptions.Compiled);
    private static readonly Regex RxNumberMark =
        new Regex("[\\uFF0C\\u3001\\uFF0E\\uFF65\\u00B7\\u2022\\u30FB]", RegexOptions.Compiled);
    // 增量列统一写成「+2.1 pt」：去掉正负号和数字之间的空格。
    private static readonly Regex RxLeadingDelta =
        new Regex("(?m)^([ \\t]*)([+\\-\u2212])[ \\t]*(?=[0-9])", RegexOptions.Compiled);
    /// 把增量行的符号与数字粘在一起：+ 2.1 pt -> +2.1 pt
    private static string JoinDeltaSign(Match m)
    {
        return m.Groups[1].Value + m.Groups[2].Value;
    }
    // OCR 常把日期里的短横读成“一”：2024 一 05 一 17 -> 2024-05-17
    private static readonly Regex RxHanDash =
        new Regex("(?<=[0-9])[ \t]*[\u4E00\u2013\u2014\uFF0D][ \t]*(?=[0-9])", RegexOptions.Compiled);
    // 全角标点夹在 ASCII 之间：中文，PDF -> 中文, PDF；顺带吃掉多出来的空格。
    // ％ 故意不在这一组里：中文排版里百分号本来就写作 ％（26.34％），换成半角反而不好看。
    private static readonly Regex RxFullWidthInAscii =
        new Regex("(?<=[0-9A-Za-z])[ \\t]*([\\uFF0C\\u3001\\uFF0E\\uFF1B\\uFF1A\\uFF08\\uFF09])[ \\t]*(?=[0-9A-Za-z])", RegexOptions.Compiled);
    private static readonly Regex RxPunctThenSpace =
        new Regex("([\u3001\u3002\uFF0C\uFF1B\uFF1A\uFF01\uFF1F\uFF09])[ \t]+(?=[0-9A-Za-z" + Cjk + "])", RegexOptions.Compiled);
    // 被拆开的拉丁字母：H a rn ess 里能救回来的部分
    private static readonly Regex RxLetterRun =
        new Regex("(?<![A-Za-z])(?:[A-Za-z] ){2,}[A-Za-z](?![A-Za-z])", RegexOptions.Compiled);
    private static readonly Regex RxManySpaces = new Regex("[ \t]{2,}", RegexOptions.Compiled);
    private static readonly Regex RxBlankLines = new Regex("(\r?\n){3,}", RegexOptions.Compiled);

    private static readonly Dictionary<char, char> AsciiPunct = new Dictionary<char, char>
    {
        { '\uFF0C', ',' }, { '\u3001', ',' }, { '\uFF0E', '.' }, { '\uFF1B', ';' },
        { '\uFF1A', ':' }, { '\uFF08', '(' }, { '\uFF09', ')' }, { '\uFF05', '%' }
    };

    /// 重建被 OCR 用各种分隔符连起来的数字串。分号后三位数字且后面还有分隔符的
    /// 是千分位（1，204，338 · 00 -> 1,204,338.00），其余是小数点（26 · 34 -> 26.34）；
    /// 另外「分隔符 + 恰好三位数字 + 结尾」也只可能是千分位（887，120 → 887,120）。
    public static string FixNumberSeparators(string text)
    {
        if (string.IsNullOrEmpty(text)) { return ""; }
        string result = RxNumberRun.Replace(text, delegate(Match m)
        {
            string run = m.Value;
            List<string> parts = new List<string>();
            foreach (Match part in RxNumberPart.Matches(run)) { parts.Add(part.Value); }
            List<string> marks = new List<string>();
            foreach (Match mark in RxNumberMark.Matches(run)) { marks.Add(mark.Value); }
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < parts.Count; i++)
            {
                sb.Append(parts[i]);
                if (i < marks.Count)
                {
                    bool thousands = (i < parts.Count - 1) && (parts[i + 1].Length == 3) && ((i + 1) < marks.Count);
                    sb.Append(thousands ? ',' : '.');
                }
            }
            return sb.ToString();
        });
        // 分隔符后恰好三位数字且不是四位以上的数字：只可能是千分位
        result = Regex.Replace(result, "([0-9])[ \\t]*[\\uFF0C\\u3001\\uFF0E\\uFF65\\u00B7\\u2022\\u30FB][ \\t]*([0-9]{3}(?![0-9]))", "$1,$2");
        return result;
    }

    private static bool IsCjk(char c)
    {
        return (c >= '\u2E80' && c <= '\u2EFF') || (c >= '\u3000' && c <= '\u303F') ||
               (c >= '\u3040' && c <= '\u30FF') || (c >= '\u3400' && c <= '\u4DBF') ||
               (c >= '\u4E00' && c <= '\u9FFF') || (c >= '\uF900' && c <= '\uFAFF') ||
               (c >= '\uFE30' && c <= '\uFE4F') || (c >= '\uFF00' && c <= '\uFFEF');
    }

    /// 把一行里的若干 word 拼起来：CJK 与 CJK 之间不加空格，其余加。
    public static string JoinWords(IList<string> words)
    {
        if (words == null || words.Count == 0) { return ""; }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < words.Count; i++)
        {
            string word = words[i] ?? "";
            if (i > 0 && sb.Length > 0 && word.Length > 0)
            {
                char previous = sb[sb.Length - 1];
                char next = word[0];
                if (!(IsCjk(previous) && IsCjk(next))) { sb.Append(' '); }
            }
            sb.Append(word);
        }
        return sb.ToString();
    }

    /// 整理引擎文字：去 CJK 间空格、修标点、补中英边界空格。
    public static string ClearCjkSpaces(string text)
    {
        if (string.IsNullOrEmpty(text)) { return ""; }
        string current = text;
        for (int pass = 0; pass < 8; pass++)
        {
            string next = RxCjkSpace.Replace(current, "");
            next = RxSpaceCjkPunct.Replace(next, "");
            next = RxCjkPunctSpace.Replace(next, "");
            next = RxCjkBoundary.Replace(next, " ");
            if (next == current) { break; }
            current = next;
        }
        return current;
    }

    /// 在 ClearCjkSpaces 的基础上再做标点与数字的修正。
    public static string Format(string text)
    {
        if (string.IsNullOrEmpty(text)) { return ""; }
        // 先重建数字里的分隔符，再处理全角标点，最后统一空格与中英边界
        string current = FixNumberSeparators(text);
        current = RxLeadingDelta.Replace(current, new MatchEvaluator(JoinDeltaSign));
        current = RxHanDash.Replace(current, "-");
        current = RxFullWidthInAscii.Replace(current, delegate(Match m)
        {
            char mapped;
            return AsciiPunct.TryGetValue(m.Groups[1].Value[0], out mapped) ? mapped.ToString() : m.Value;
        });
        current = RxLetterRun.Replace(current, delegate(Match m) { return m.Value.Replace(" ", ""); });
        current = RxPunctThenSpace.Replace(current, "$1");
        current = RxManySpaces.Replace(current, " ");
        current = RxBlankLines.Replace(current, "\n\n");
        current = ClearCjkSpaces(current);
        // 全角标点后面多出来的空格（14 ： 08 -> 14:08）与百分号前面的空格
        current = RxSpaceCjkPunct.Replace(current, "");
        current = RxCjkPunctSpace.Replace(current, "");
        // 上面两步会把“视图 (V)”又并回“视图(V)”，这里按中英边界补一次空格
        current = RxCjkBoundary.Replace(current, " ");
        return current.Trim();
    }

    /// 整理多行文本，逐行处理，最后做一次跨行收尾（表格里「％」和下一行的
    /// 「+12.4％」本来是一格，逐行处理时看不到彼此，只能拼起来再修一遍）。
    public static string FormatLines(IList<string> lines, bool raw)
    {
        if (lines == null) { return ""; }
        List<string> output = new List<string>(lines.Count);
        foreach (string line in lines)
        {
            if (line == null) { continue; }
            output.Add(raw ? line.Trim() : Format(line));
        }
        string joined = string.Join("\n", output.ToArray()).Trim();
        if (!raw && joined.Length > 0)
        {
            joined = RxLeadingDelta.Replace(joined, new MatchEvaluator(JoinDeltaSign));
            joined = RxCjkBoundary.Replace(joined, " ");
        }
        return joined;
    }

    public static string EscapeJson(string value)
    {
        if (value == null) { return ""; }
        StringBuilder sb = new StringBuilder(value.Length + 16);
        foreach (char c in value)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < ' ' || c > '\uFFFD') { sb.Append("\\u" + ((int)c).ToString("x4", CultureInfo.InvariantCulture)); }
                    else { sb.Append(c); }
                    break;
            }
        }
        return sb.ToString();
    }
}
'@

function Initialize-FpwText {
    if (-not ('FpwText' -as [type])) {
        Add-Type -TypeDefinition $script:CleanupSource -Language CSharp | Out-Null
    }
}

# ---------------------------------------------------------------------------
# OCR
# ---------------------------------------------------------------------------
# 放大到合理尺寸再识别：字太小（13~18px）时 Windows OCR 会把偏旁认错，
# 放大 5 倍以内效果最好；同时避免超大图拖慢识别。
$script:OcrScale = 5
$script:OcrMinWidth = 800
$script:OcrMaxWidth = 3200

function Get-FpwOcrEngine([string]$LanguageTag) {
    Initialize-FpwWinRt
    if ($LanguageTag) {
        $language = New-Object Windows.Globalization.Language $LanguageTag
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
    } else {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if (-not $engine) {
            $available = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages
            if ($available.Count -gt 0) {
                $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($available[0])
            }
        }
    }
    return $engine
}

function Get-FpwLanguages {
    Initialize-FpwWinRt
    $list = @()
    foreach ($language in [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages) {
        $list += [pscustomobject]@{ tag = $language.LanguageTag; name = $language.DisplayName }
    }
    return $list
}

function ConvertTo-FpwPng {
    <#
        把任意位图编码成 PNG 文件，返回 { Path; Width; Height; Scale }。
        顺手做两件事：按宽度自适应放大、重画成 24bpp（去掉 alpha / 索引色，
        Windows OCR 对这两类格式不友好）。
    #>
    param(
        [Parameter(Mandatory = $true)] $Bitmap,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MinWidth = $script:OcrMinWidth,
        [int]$MaxWidth = $script:OcrMaxWidth,
        [double]$MaxScale = $script:OcrScale,
        [double]$MinScale = $script:OcrScale
    )

    $width = $Bitmap.Width
    $height = $Bitmap.Height
    if ($width -le 0 -or $height -le 0) { throw "图片尺寸无效：${width}x${height}" }

    $scale = 1.0
    if ($width -lt $MinWidth) { $scale = [Math]::Min($MaxScale, $MinWidth / [double]$width) }
    if ($scale * $width -gt $MaxWidth) { $scale = $MaxWidth / [double]$width }
    if ($scale -lt $MinScale) { $scale = $MinScale }
    if ($scale -lt 1.0) { $scale = 1.0 }
    $scale = [Math]::Round($scale, 2)

    $targetWidth = [int][Math]::Round($width * $scale)
    $targetHeight = [int][Math]::Round($height * $scale)

    $canvas = New-Object System.Drawing.Bitmap $targetWidth, $targetHeight, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($canvas)
    try {
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.DrawImage($Bitmap, 0, 0, $targetWidth, $targetHeight)
    } finally {
        $graphics.Dispose()
    }
    try {
        $canvas.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $canvas.Dispose()
    }

    return [pscustomobject]@{
        Path   = $Path
        Width  = $targetWidth
        Height = $targetHeight
        Scale  = $scale
    }
}

function Invoke-FpwOcr {
    <#
        .SYNOPSIS
            识别一张图片或一个位图对象，返回可直接使用的文本。
        .OUTPUTS
            [pscustomobject] 字段：Ok Text Raw Lines RawLines Width Height Scale
            Language Words(数) ElapsedMs 或者 Error
    #>
    param(
        [string]$Path,
        $Bitmap,
        [string]$Language,
        [switch]$Raw,
        [switch]$KeepBitmap
    )

    Initialize-FpwText
    Initialize-FpwWinRt

    $started = Get-Date
    $temporary = $null
    $source = $null
    $ownsBitmap = $false
    try {
        if ($Bitmap) {
            $source = $Bitmap
        } elseif ($Path) {
            if (-not (Test-Path -LiteralPath $Path)) { throw "找不到图片：$Path" }
            $source = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Path).ProviderPath)
            $ownsBitmap = $true
        } else {
            throw '没有指定图片'
        }

        $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("fpw-" + [guid]::NewGuid().ToString('n') + ".png")
        $prepared = ConvertTo-FpwPng -Bitmap $source -Path $temporary

        $file = Wait-Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($prepared.Path)) ([Windows.Storage.StorageFile])
        $stream = Wait-Operation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        try {
            $decoder = Wait-Operation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
            $software = Wait-Operation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

            $engine = Get-FpwOcrEngine $Language
            if (-not $engine) { throw '这台电脑没有可用的 OCR 语言包（设置 → 时间和语言 → 语言和区域 → 添加语言 → 可选功能 → 光学字符识别）' }

            $result = Wait-Operation ($engine.RecognizeAsync($software)) ([Windows.Media.Ocr.OcrResult])
        } finally {
            if ($stream) { $stream.Dispose() }
        }

        $rawLines = New-Object System.Collections.Generic.List[string]
        $wordCount = 0
        foreach ($line in $result.Lines) {
            $words = New-Object System.Collections.Generic.List[string]
            foreach ($word in $line.Words) {
                $words.Add($word.Text)
                $wordCount++
            }
            $rawLines.Add([FpwText]::JoinWords($words))
        }

        $cleanLines = New-Object System.Collections.Generic.List[string]
        foreach ($line in $rawLines) { $cleanLines.Add([FpwText]::Format($line)) }
        if ($Raw) { $lines = $rawLines } else { $lines = $cleanLines }

        $text = ([FpwText]::FormatLines($lines, $false))
        $rawText = ([FpwText]::FormatLines($rawLines, $true))

        return [pscustomobject]@{
            Ok        = $true
            Text      = $text
            Raw       = $rawText
            Lines     = $lines.ToArray()
            RawLines  = $rawLines.ToArray()
            Width     = $prepared.Width
            Height    = $prepared.Height
            Scale     = $prepared.Scale
            Language  = $engine.RecognizerLanguage.LanguageTag
            Words     = $wordCount
            ElapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
        }
    } catch {
        return [pscustomobject]@{
            Ok        = $false
            Error     = $_.Exception.Message
            ElapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
        }
    } finally {
        if ($ownsBitmap -and $source) { $source.Dispose() }
        if ($temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Show-FpwUsage {
    Write-Host @'
用法：
  ocr.ps1 -InputPath <图片>            输出识别到的文字
  ocr.ps1 -InputPath <图片> -Json      输出 JSON（含逐行文本与尺寸）
  ocr.ps1 -InputPath <图片> -Raw       保留引擎原始结果，不做空格/标点整理
  ocr.ps1 -InputPath <图片> -Language en-GB
  ocr.ps1 -ListLanguages               列出本机可用的 OCR 语言
'@
}

# ---------------------------------------------------------------------------
# 命令行入口（被 app.ps1 用 `. .\ocr.ps1` 点源加载时不会执行）
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    $options = @{
        InputPath     = ''
        Language      = ''
        Raw           = $false
        Json          = $false
        ListLanguages = $false
        Help          = $false
    }
    for ($i = 0; $i -lt $args.Count; $i++) {
        $name = ([string]$args[$i]).ToLowerInvariant()
        switch ($name) {
            '-inputpath' { $i++; $options.InputPath = [string]$args[$i] }
            '-language' { $i++; $options.Language = [string]$args[$i] }
            '-lang' { $i++; $options.Language = [string]$args[$i] }
            '-raw' { $options.Raw = $true }
            '-nocleanup' { $options.Raw = $true }
            '-json' { $options.Json = $true }
            '-listlanguages' { $options.ListLanguages = $true }
            '-help' { $options.Help = $true }
            '-h' { $options.Help = $true }
            default {
                if (-not $options.InputPath -and -not $name.StartsWith('-')) { $options.InputPath = [string]$args[$i] }
            }
        }
    }

    if ($options.Help -or (-not $options.InputPath -and -not $options.ListLanguages)) {
        Show-FpwUsage
        exit 0
    }

    if ($options.ListLanguages) {
        $languages = Get-FpwLanguages
        if ($options.Json) {
            $items = @()
            foreach ($language in $languages) {
                $items += '{"tag":"' + [FpwText]::EscapeJson($language.tag) + '","name":"' + [FpwText]::EscapeJson($language.name) + '"}'
            }
            Write-Output ('{"ok":true,"languages":[' + ($items -join ',') + ']}')
        } else {
            foreach ($language in $languages) { Write-Output ("{0}`t{1}" -f $language.tag, $language.name) }
        }
        exit 0
    }

    Initialize-FpwText
    $ocr = Invoke-FpwOcr -Path $options.InputPath -Language $options.Language -Raw:$options.Raw

    if ($options.Json) {
        if (-not $ocr.Ok) {
            Write-Output ('{"ok":false,"code":3,"stage":"ocr","error":"' + [FpwText]::EscapeJson($ocr.Error) + '"}')
            exit 3
        }
        $lines = @()
        foreach ($line in $ocr.Lines) { $lines += '"' + [FpwText]::EscapeJson($line) + '"' }
        $rawLines = @()
        foreach ($line in $ocr.RawLines) { $rawLines += '"' + [FpwText]::EscapeJson($line) + '"' }
        $json = '{"ok":true' +
            ',"engine":"Windows.Media.Ocr"' +
            ',"language":"' + [FpwText]::EscapeJson($ocr.Language) + '"' +
            ',"width":' + $ocr.Width + ',"height":' + $ocr.Height + ',"scale":' + $ocr.Scale +
            ',"lines":[' + ($lines -join ',') + ']' +
            ',"rawLines":[' + ($rawLines -join ',') + ']' +
            ',"text":"' + [FpwText]::EscapeJson($ocr.Text) + '"' +
            ',"raw":"' + [FpwText]::EscapeJson($ocr.Raw) + '"' +
            ',"elapsedMs":' + $ocr.ElapsedMs + '}'
        Write-Output $json
        exit 0
    }

    if (-not $ocr.Ok) {
        [Console]::Error.WriteLine($ocr.Error)
        exit 3
    }
    Write-Output $ocr.Text
    exit 0
}
