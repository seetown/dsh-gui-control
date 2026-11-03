#requires -Version 5.1
# Windows.Media.Ocr wrapper for PowerShell 5.1 (WinRT interop).
# Gives semantic targeting: find a control by its text instead of guessing pixels.
# ASCII only.

$script:OcrReady = $false
$script:OcrEngine = $null
$script:AsTask = $null

function Initialize-Ocr {
    if ($script:OcrReady) { return }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]

    $script:AsTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
    if ($null -eq $script:AsTask) { throw 'AsTask(IAsyncOperation<T>) not found' }

    $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($null -eq $script:OcrEngine) { throw 'No OCR engine for user profile languages' }
    $script:OcrReady = $true
}

function Await-WinRt($op, [Type]$type) {
    $m = $script:AsTask.MakeGenericMethod($type)
    $t = $m.Invoke($null, @($op))
    if (-not $t.Wait(20000)) { throw 'WinRT await timeout' }
    if ($t.IsFaulted) { throw $t.Exception.GetBaseException().Message }
    return $t.Result
}

# Returns an array of @{ text; x; y; w; h } using absolute screen coordinates.
# $offsetX/$offsetY are the screen position of the captured image's top-left corner.
function Get-OcrLines([string]$path, [int]$offsetX, [int]$offsetY) {
    Initialize-Ocr
    $file = Await-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = Await-WinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bmp = Await-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $res = Await-WinRt ($script:OcrEngine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])

    $lines = @()
    foreach ($line in @($res.Lines)) {
        $words = @($line.Words)
        if ($words.Count -eq 0) { continue }
        $minX = [double]::MaxValue; $minY = [double]::MaxValue
        $maxX = 0.0; $maxY = 0.0
        foreach ($wd in $words) {
            $r = $wd.BoundingRect
            if ($r.X -lt $minX) { $minX = $r.X }
            if ($r.Y -lt $minY) { $minY = $r.Y }
            if (($r.X + $r.Width) -gt $maxX) { $maxX = $r.X + $r.Width }
            if (($r.Y + $r.Height) -gt $maxY) { $maxY = $r.Y + $r.Height }
        }
        $lines += @{
            text = $line.Text
            x    = [int]($offsetX + $minX)
            y    = [int]($offsetY + $minY)
            w    = [int]($maxX - $minX)
            h    = [int]($maxY - $minY)
            cx   = [int]($offsetX + ($minX + $maxX) / 2)
            cy   = [int]($offsetY + ($minY + $maxY) / 2)
        }
    }
    $stream.Dispose()
    return $lines
}
