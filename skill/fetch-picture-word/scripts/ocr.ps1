#requires -Version 5.1
<#
  ocr.ps1 - offline OCR for images using the OCR engine built into Windows.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File ocr.ps1 -InputPath shot.png -Json
    powershell -NoProfile -ExecutionPolicy Bypass -File ocr.ps1 -InputPath shot.png -Lang en-GB
    powershell -NoProfile -ExecutionPolicy Bypass -File ocr.ps1 -ListLanguages
    powershell -NoProfile -ExecutionPolicy Bypass -File ocr.ps1 -ListLanguages -Json

  Output: one line of JSON on stdout when -Json is used, otherwise plain text.
  Exit codes: 0 ok, 2 bad input, 3 OCR engine unavailable, 4 recognition failed.

  Behaviour:
    - Recognition is fully offline; the recognizers come from installed Windows
      language packs (`-ListLanguages` shows the tags).
    - The image is enlarged before recognition: at least -ScaleOverall times the
      original and at least -MinWidth px wide, pulled back only to stay under
      -MaxWidth px. The Windows engine misreads CJK radicals at small sizes (a
      36 px 识 becomes 另刂) and is right from roughly 100 px, which a 3x copy of
      a normal screenshot reaches.
    - `-NoCleanup` disables both post-processing passes and returns raw glyph text.
#>
[CmdletBinding()]
param(
    # Optional only so that -ListLanguages can run without an image; a missing
    # path is reported as exit code 2 by the checks in the main block.
    [Parameter(Position = 0)]
    [string]$InputPath,

    [string]$Lang,

    [double]$ScaleOverall = 3,

    [int]$MaxWidth = 2600,

    [int]$MinWidth = 700,

    [switch]$ListLanguages,

    [switch]$Json,

    [switch]$NoCleanup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Failure {
    param([int]$Code, [string]$Message, [string]$Stage = 'init')
    if ($Json) {
        $payload = [ordered]@{ ok = $false; code = $Code; stage = $Stage; error = $Message }
        [Console]::Out.WriteLine((($payload | ConvertTo-Json -Compress)))
    } else {
        [Console]::Error.WriteLine("ocr.ps1: $Message")
    }
    exit $Code
}

function Initialize-WinRt {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
    } catch {
        Write-Failure 3 "cannot load System.Runtime.WindowsRuntime: $($_.Exception.Message)" 'winrt'
    }
    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
    if ($null -eq $script:AsTaskGeneric) {
        Write-Failure 3 'no IAsyncOperation<T> AsTask overload found' 'winrt'
    }
    # Referring to the WinRT types through their ContentType activates the
    # WindowsRuntime type resolution for this session.
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime]
}

function Await {
    param([Parameter(Mandatory = $true)]$Operation, [Parameter(Mandatory = $true)][Type]$ResultType)
    $task = $script:AsTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $null = $task.Wait(-1)
    if ($task.IsFaulted) { throw $task.Exception.InnerException }
    # Assign then return so no helper output leaks into this function's result.
    $value = $task.Result
    return $value
}

# --- text post-processing ----------------------------------------------------
# The engine separates every recognised glyph with a space, which breaks CJK
# output ("识 别 图 片"), and it misreads ASCII punctuation between digits as the
# fullwidth/typographic variant (1，280 · 50 instead of 1,280.50).
$script:Cjk = '[\u2E80-\u2EFF\u3000-\u303F\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\uFE30-\uFE4F\uFF00-\uFFEF]'
$script:Ascii = '[0-9A-Za-z]'
$script:CjkRegex = New-Object System.Text.RegularExpressions.Regex($script:Cjk)
$script:SpaceBetweenCjk = New-Object System.Text.RegularExpressions.Regex("($script:Cjk)\s+($script:Cjk)")
# Only strip those spaces when they sit next to ASCII ("100％ DPI" -> "100％DPI");
# between two Chinese characters the engine's gap must go, but a space that
# separates a Chinese sentence from an ASCII word ("小王， PDF") is kept.
$script:SpaceBeforeCjkPunct = New-Object System.Text.RegularExpressions.Regex("(?<=[0-9A-Za-z])\s+([\u3000-\u303F\uFF00-\uFFEF])")
$script:SpaceAfterCjkPunct = New-Object System.Text.RegularExpressions.Regex("([\u3000-\u303F\uFF00-\uFFEF])\s+(?=[0-9A-Za-z])")
# Boundary between CJK letters and ASCII runs. CJK text carries no spaces of its
# own, so "小王，PDF" and "/tmp/a.png 状态" are already right; the space matters
# only where a Chinese character touches an ASCII run or a bracket
# ("识别图片中的文字" -> unchanged, "文件（F）编辑" -> "文件 (F) 编辑").
$script:CjkBoundary = New-Object System.Text.RegularExpressions.Regex("([\u4E00-\u9FFF\u3040-\u30FF])(?=[0-9A-Za-z(])|(?<=[0-9A-Za-z)])([\u4E00-\u9FFF\u3040-\u30FF])")
# the engine reads a date hyphen as the Chinese character 一: "2024 一 05 一 17"
$script:HanDash = New-Object System.Text.RegularExpressions.Regex('(?<=[0-9])[ \t]*' + [char]0x4E00 + '[ \t]*(?=[0-9])')
# A plain "separator between digits" rule cannot tell 1,204,338.00 from 26.34:
# the engine emits the same glyphs for both, so numbers are rebuilt with their
# grouping intact by Fix-NumberSeparators below. This is the scan pattern.
$script:NumberRun = New-Object System.Text.RegularExpressions.Regex('\d+(?:[ \t]*[\uFF0C\u3001\uFF0E\uFF65\u00B7\u2022\u30FB][ \t]*\d+)+')
$script:NumberParts = New-Object System.Text.RegularExpressions.Regex('\d+')
$script:NumberMark = New-Object System.Text.RegularExpressions.Regex('[\uFF0C\u3001\uFF0E\uFF65\u00B7\u2022\u30FB]')
# Three digits after a separator can only be thousands: "887，120 · 55" is the
# engine dropping a digit rather than a decimal, so those separators are commas.
$script:NumberTrailingGroup = New-Object System.Text.RegularExpressions.Regex('(?<=[0-9])([ \t]*)[\uFF0C\u3001\uFF0E\uFF65\u00B7\u2022\u30FB]([ \t]*)([0-9]{3}(?![0-9]))')
# Fullwidth punctuation wedged between ASCII characters, including the engine's
# stray space: "小王，PDF" / "26.34 ％+" become ASCII. ％ (U+FF05) is deliberately
# NOT in these sets: Chinese typography writes the percent sign fullwidth
# ("26.34％"), so converting it to "%" only makes the output look wrong.
$script:FullwidthPunct = New-Object System.Text.RegularExpressions.Regex("(?<=[0-9A-Za-z])[\uFF0C\u3001\uFF0E\uFF1B\uFF1A\uFF08\uFF09](?=[0-9A-Za-z])")
$script:FullwidthPunctSpaced = New-Object System.Text.RegularExpressions.Regex("(?<=[0-9A-Za-z])[ \t]*([\uFF0C\u3001\uFF0E\uFF1B\uFF1A\uFF08\uFF09])[ \t]*(?=[0-9A-Za-z])")
# drop the space the engine inserts after CJK punctuation
$script:SpaceAfterCjkPunctKeep = New-Object System.Text.RegularExpressions.Regex("([\u3001\u3002\uFF0C\uFF1B\uFF1A\uFF01\uFF1F\uFF09])\s+(?=[\u4E00-\u9FFF\u3040-\u30FF0-9A-Za-z])")
$script:PunctMap = @{
    [char]0xFF0C = ','
    [char]0x3001 = ','
    [char]0xFF0E = '.'
    [char]0xFF1B = ';'
    [char]0xFF1A = ':'
    [char]0xFF08 = '('
    [char]0xFF09 = ')'
}
# The engine sometimes reports wide Latin glyphs as separate single-letter words
# ("X Y Z" -> "XYZ"). The lookarounds keep a run of one-letter words that merely
# abuts a longer word ("rn ess") from being glued together, which would corrupt
# genuinely split words; those stay visible in the `raw` field of -Json output.
$script:SingleLetterRun = New-Object System.Text.RegularExpressions.Regex('(?<![A-Za-z])(?:[A-Za-z] ){2,}[A-Za-z](?![A-Za-z])')
$script:MultiSpace = New-Object System.Text.RegularExpressions.Regex('  +')

function Clear-CjkSpaces {
    param([string]$Text)
    $result = $Text
    for ($i = 0; $i -lt 8; $i++) {
        $next = $script:SpaceBetweenCjk.Replace($result, '$1$2')
        $next = $script:SpaceBeforeCjkPunct.Replace($next, '$1')
        $next = $script:SpaceAfterCjkPunct.Replace($next, '$1')
        if ($next -eq $result) { break }
        $result = $next
    }
    $previous = $null
    while ($previous -ne $result) {
        $previous = $result
        $result = $script:CjkBoundary.Replace($result, { param($m) if ($m.Groups[1].Success) { "$($m.Groups[1].Value) " } else { " $($m.Groups[2].Value)" } })
    }
    return $result
}

function Get-NumberParts {
    param([string]$Run)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($match in $script:NumberParts.Matches($Run)) { [void]$parts.Add($match.Value) }
    return [string[]]$parts.ToArray()
}

function Get-NumberMarks {
    param([string]$Run)
    $marks = New-Object System.Collections.Generic.List[string]
    foreach ($match in $script:NumberMark.Matches($Run)) { [void]$marks.Add($match.Value) }
    return [string[]]$marks.ToArray()
}

# Rebuild a run of digits joined by OCR'd separators ("1，204，338 · 00",
# "26 · 34 ％", "1，280 · 50"). A separator that is followed by exactly three
# digits and at least one more separator is a thousands separator, everything
# else is a decimal point - which is what keeps 1,204,338.00 from turning into
# 1.204.338.00 while 26.34 stays a decimal.
function Fix-NumberSeparators {
    param([string]$Text)
    $evaluator = {
        param($match)
        $parts = @(Get-NumberParts $match.Value)
        $marks = @(Get-NumberMarks $match.Value)
        $builder = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $parts.Count; $i++) {
            [void]$builder.Append($parts[$i])
            if ($i -lt $marks.Count) {
                $thousands = ($i -lt $parts.Count - 1) -and ($parts[$i + 1].Length -eq 3) -and (($i + 1) -lt $marks.Count)
                if ($thousands) { [void]$builder.Append(',') } else { [void]$builder.Append('.') }
            }
        }
        return $builder.ToString()
    }
    return $script:NumberRun.Replace($Text, $evaluator)
}

function Format-OcrText {
    param([string]$Text)
    $result = $script:HanDash.Replace($Text, '-')
    $result = Fix-NumberSeparators $result
    $result = $script:NumberTrailingGroup.Replace($result, ',$3')
    $result = $script:FullwidthPunctSpaced.Replace($result, { param($m) $script:PunctMap[$m.Groups[1].Value[0]] })
    # drop the space the engine inserts after CJK punctuation
    $result = $script:SpaceAfterCjkPunctKeep.Replace($result, '$1')
    $result = Clear-CjkSpaces $result
    $result = $script:SingleLetterRun.Replace($result, { param($m) ($m.Value -replace ' ', '') })
    $result = $script:MultiSpace.Replace($result, ' ')
    return $result
}

# --- engine ------------------------------------------------------------------
$script:OcrEngine = $null
$script:EngineLanguage = $null

function Get-OcrEngine {
    param([string]$LanguageTag)
    if ($null -ne $script:OcrEngine) { return $script:OcrEngine }
    if ($LanguageTag) {
        $language = New-Object Windows.Globalization.Language $LanguageTag
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
        if ($null -eq $engine) {
            Write-Failure 3 "Windows OCR has no recognizer for language '$LanguageTag'" 'engine'
        }
    } else {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if ($null -eq $engine) {
            $available = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages |
                ForEach-Object { $_.LanguageTag }) -join ', '
            Write-Failure 3 "Windows OCR has no recognizer for the user profile languages (available: $available)" 'engine'
        }
    }
    $script:OcrEngine = $engine
    $script:EngineLanguage = $engine.RecognizerLanguage.LanguageTag
    return $engine
}

function Get-Languages {
    @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages) | ForEach-Object {
        [ordered]@{ tag = $_.LanguageTag; name = $_.DisplayName }
    }
}

# --- image preparation -------------------------------------------------------
function Add-ImageSupport {
    foreach ($name in @('System.Drawing', 'System.Drawing.Imaging')) {
        try { Add-Type -AssemblyName $name -ErrorAction Stop } catch { }
    }
}

function Get-PreparedImage {
    <#
      Upscale the source so its glyphs are large enough for the engine, then
      write a 24bpp PNG (the engine rejects indexed/alpha formats).
      Returns a single object; never write to the pipeline anywhere else here.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][double]$ScaleOverall,
        [Parameter(Mandatory = $true)][int]$MaxWidth,
        [Parameter(Mandatory = $true)][int]$MinWidth,
        [Parameter(Mandatory = $true)][string]$WorkDirectory
    )
    Add-ImageSupport
    try {
        $source = [System.Drawing.Image]::FromFile($Path)
    } catch {
        Write-Failure 2 "cannot open image '$Path': $($_.Exception.Message)" 'image'
    }
    try {
        $originalWidth = $source.Width
        $originalHeight = $source.Height
        # The Windows engine misreads radicals below roughly 30 px glyph height,
        # so the working copy is always enlarged: at least -MinWidth px wide and
        # at least -ScaleOverall times the original, pulled back only to stay
        # under -MaxWidth px so a huge region does not slow recognition down.
        $scale = [Math]::Max([double]$ScaleOverall, [double]$MinWidth / [Math]::Max(1, $originalWidth))
        $scale = [Math]::Min($scale, [double]$MaxWidth / [Math]::Max(1, $originalWidth))
        $scale = [Math]::Max(1.0, [Math]::Round($scale, 2))
        $targetWidth = [int][Math]::Round($originalWidth * $scale)
        $targetHeight = [int][Math]::Round($originalHeight * $scale)
        $bitmap = New-Object System.Drawing.Bitmap $targetWidth, $targetHeight, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($source, 0, 0, $targetWidth, $targetHeight)
        $graphics.Dispose()
        $prepared = Join-Path $WorkDirectory ("prepared-{0}.png" -f ([Guid]::NewGuid().ToString('N')))
        $bitmap.Save($prepared, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
        return [ordered]@{
            Path            = $prepared
            OriginalWidth   = $originalWidth
            OriginalHeight  = $originalHeight
            Width           = $targetWidth
            Height          = $targetHeight
            Scale           = [Math]::Round($scale, 3)
        }
    } finally {
        $source.Dispose()
    }
}

function Invoke-Recognition {
    param([Parameter(Mandatory = $true)][string]$Path)
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $ocrResult = Await ($script:OcrEngine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        return $ocrResult
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Convert-Result {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [switch]$NoCleanup
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $cleanLines = New-Object System.Collections.Generic.List[string]
    $words = New-Object System.Collections.Generic.List[object]
    $total = 0
    # Materialise the WinRT projections before iterating: the COM-backed
    # collections are only reliable once copied into a .NET array.
    foreach ($line in @($Result.Lines)) {
        $piece = New-Object System.Text.StringBuilder
        foreach ($word in @($line.Words)) {
            $wordText = [string]$word.Text
            $total++
            if ($wordText) {
                if ($piece.Length -gt 0) {
                    $lastChar = $piece.ToString($piece.Length - 1, 1)
                    $firstChar = $wordText.Substring(0, 1)
                    $addSpace = -not ($script:CjkRegex.IsMatch($lastChar) -and $script:CjkRegex.IsMatch($firstChar))
                    if ($addSpace) { $null = $piece.Append(' ') }
                }
                $null = $piece.Append($wordText)
            }
            $rect = $word.BoundingRect
            $words.Add([ordered]@{
                    text = $wordText
                    x    = [int][Math]::Round([double]$rect.X)
                    y    = [int][Math]::Round([double]$rect.Y)
                    w    = [int][Math]::Round([double]$rect.Width)
                    h    = [int][Math]::Round([double]$rect.Height)
                })
        }
        if ($piece.Length -gt 0) { $lines.Add($piece.ToString()) }
    }
    $raw = $lines -join "`n"
    $text = $raw
    if (-not $NoCleanup) {
        $text = Clear-CjkSpaces $text
        $text = Format-OcrText $text
    }
    # Per-line cleaned text, so a reader can compare one line against its raw
    # glyphs without diffing the whole block.
    foreach ($line in $lines) {
        if ($NoCleanup) {
            $cleanLines.Add($line)
        } else {
            $cleanLines.Add((Format-OcrText (Clear-CjkSpaces $line)))
        }
    }
    # NOTE (PowerShell 5.1): a generic List must be converted to a plain array
    # before it can be stored in an [ordered] dictionary, otherwise the cast
    # fails with "Argument types do not match".
    return [ordered]@{
        text      = $text
        raw       = $raw
        lines     = [string[]]$cleanLines.ToArray()
        rawLines  = [string[]]$lines.ToArray()
        words     = [object[]]$words.ToArray()
        stats     = [ordered]@{ lineCount = $lines.Count; wordCount = $total }
    }
}

# --- main --------------------------------------------------------------------
if ($ListLanguages) {
    Initialize-WinRt
    $languages = Get-Languages
    if ($Json) {
        [Console]::Out.WriteLine((([ordered]@{ ok = $true; languages = @($languages) }) | ConvertTo-Json -Depth 5 -Compress))
    } else {
        $languages | ForEach-Object { "{0}`t{1}" -f $_.tag, $_.name }
    }
    exit 0
}

$resolved = $null
if (-not $InputPath) { Write-Failure 2 'no image given: pass -InputPath <file>' 'input' }
try {
    $candidate = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).ProviderPath
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $resolved = $candidate }
} catch {
    $resolved = $null
}
if (-not $resolved) { Write-Failure 2 "image not found: $InputPath" 'input' }

Initialize-WinRt
$null = Get-OcrEngine -LanguageTag $Lang

$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("dsh-ocr-{0}" -f ([Guid]::NewGuid().ToString('N')))
$null = New-Item -ItemType Directory -Path $workDirectory -Force
try {
    $prepared = Get-PreparedImage -Path $resolved -ScaleOverall $ScaleOverall -MaxWidth $MaxWidth -MinWidth $MinWidth -WorkDirectory $workDirectory

    try {
        $result = Invoke-Recognition -Path $prepared.Path
    } catch {
        Write-Failure 4 "recognition failed: $($_.Exception.Message)" 'recognize'
    }

    $payload = Convert-Result -Result $result -NoCleanup:$NoCleanup

    if ($Json) {
        # NOTE: do not name this variable `$json` — PowerShell variables are
        # case-insensitive, and assigning to the [switch]$Json parameter throws
        # "Cannot convert ... to SwitchParameter".
        $payloadJson = [ordered]@{
            ok       = $true
            engine   = 'Windows.Media.Ocr'
            language = $script:EngineLanguage
            input    = $resolved
            source   = [ordered]@{ width = $prepared.OriginalWidth; height = $prepared.OriginalHeight }
            ocrImage = [ordered]@{ width = $prepared.Width; height = $prepared.Height; scale = $prepared.Scale }
            stats    = $payload.stats
            text     = $payload.text
            raw      = $payload.raw
            lines    = [string[]]$payload.lines
            rawLines = [string[]]$payload.rawLines
            words    = [object[]]$payload.words
        }
        [Console]::Out.WriteLine(($payloadJson | ConvertTo-Json -Depth 6 -Compress))
    } else {
        [Console]::Out.WriteLine($payload.text)
    }
    exit 0
} finally {
    if ($workDirectory -and (Test-Path -LiteralPath $workDirectory)) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
