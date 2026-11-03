#requires -Version 5.1
# Anchor resolution layer: named targets instead of hardcoded pixels.
#
# An anchor is resolved with a fixed priority chain, first hit wins:
#   uia      -> accessibility element (exact, position independent)
#   ocr      -> exact label found by OCR             (survives resize/move)
#   ocr_any  -> any text inside a band               (survives placeholder -> value swap)
#   derive   -> bounding box of OCR lines matching a regex (survives layout changes)
#   point    -> fraction of the window               (last resort, no text available)
#
# Profiles live in apps\<name>.json. All coordinates in a profile are fractions of the
# target window (0..1), so moving/resizing the window cannot invalidate them.
# ASCII only.
$script:GuiRoot = $PSScriptRoot

function Get-AppProfile([string]$app) {
    $p = Join-Path (Join-Path $script:GuiRoot 'apps') ($app + '.json')
    if (-not (Test-Path $p)) { throw ('profile not found: ' + $app) }
    return (Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json)
}

function Get-FracRect($win, $f) {
    # f = [rx, ry, rw, rh] as fractions of the window frame
    return @{
        x = [int]($win.Left + $win.Width * [double]$f[0])
        y = [int]($win.Top + $win.Height * [double]$f[1])
        w = [int]($win.Width * [double]$f[2])
        h = [int]($win.Height * [double]$f[3])
    }
}

function Get-AnchorScope($anchor, $win) {
    if ($null -eq $anchor.scope) { return $null }
    return Get-FracRect $win $anchor.scope
}

# OCR the window (or a sub-rect) through the normal op pipeline.
function Get-Lines([hashtable]$rect) {
    $op = @{ op = 'ocr' }
    if ($null -ne $rect) { $op.x = $rect.x; $op.y = $rect.y; $op.w = $rect.w; $op.h = $rect.h }
    $r = Invoke-GuiOp $op
    if (-not $r.ok) { return @() }
    return @($r.result)
}

function Resolve-Anchor([string]$app, [string]$name, [string]$winMatch = '') {
    $prof = Get-AppProfile $app
    $anchor = $prof.anchors.$name
    if ($null -eq $anchor) { throw ('anchor not found: ' + $app + '.' + $name) }

    if ([string]::IsNullOrEmpty($winMatch)) { $winMatch = $prof.window_match }
    $win = Resolve-Win $winMatch
    $frame = @{ Left = [double]$win.Left; Top = [double]$win.Top
        Width = [double]($win.Right - $win.Left); Height = [double]($win.Bottom - $win.Top) }

    # 1) uia
    if ($null -ne $anchor.uia) {
        try {
            $scope = [DshUia]::FindWindow($winMatch)
            $els = [DshUia]::Find($scope, $anchor.uia.name, $anchor.uia.type, 5)
            if ($els.Count -ge 1) {
                $rr = [DshUia]::Rect($els[0])
                return @{ how = 'uia'; x = [int]$rr[0]; y = [int]$rr[1]; w = [int]$rr[2]; h = [int]$rr[3]
                    cx = [int]($rr[0] + $rr[2] / 2); cy = [int]($rr[1] + $rr[3] / 2) }
            }
        }
        catch { }
    }

    # 2) ocr (exact label)
    if ($anchor.ocr) {
        $scope = Get-AnchorScope $anchor $frame
        try {
            $op = @{ op = 'findtext'; text = $anchor.ocr }
            if ($null -ne $scope) { $op += $scope } else { $op.win = $winMatch }
            $r = Invoke-GuiOp $op
            if ($r.ok -and @($r.result).Count -ge 1) {
                $h = @($r.result)[0]
                return @{ how = 'ocr'; x = $h.x; y = $h.y; w = $h.w; h = $h.h; cx = $h.cx; cy = $h.cy; text = $h.text }
            }
        }
        catch { }
    }

    # 3) ocr_any (any text inside the band - the search box keeps either placeholder or value)
    if ($anchor.ocr_any) {
        $scope = Get-AnchorScope $anchor $frame
        if ($null -ne $scope) {
            $lines = @(Get-Lines $scope | Where-Object { ((($_.text -replace '\s+', ''))).Length -ge 2 })
            if ($lines.Count -ge 1) {
                $l = $lines[0]
                return @{ how = 'ocr_any'; x = $l.x; y = $l.y; w = $l.w; h = $l.h; cx = $l.cx; cy = $l.cy; text = $l.text }
            }
        }
    }

    # 4) derive (bounding box of matching rows)
    if ($anchor.derive) {
        $scan = Get-FracRect $frame $anchor.scan
        $lines = @(Get-Lines $scan | Where-Object { ($_.text -replace '\s+', '') -match $anchor.derive })
        if ($lines.Count -ge 1) {
            $pad = 0; if ($null -ne $anchor.pad) { $pad = [int]$anchor.pad }
            $minX = ($lines | Measure-Object -Property x -Minimum).Minimum
            $minY = ($lines | Measure-Object -Property y -Minimum).Minimum
            $maxX = ($lines | ForEach-Object { $_.x + $_.w } | Measure-Object -Maximum).Maximum
            $maxY = ($lines | ForEach-Object { $_.y + $_.h } | Measure-Object -Maximum).Maximum
            $x = [int]($minX - $pad); $y = [int]($minY - $pad)
            $w = [int]($maxX - $minX + 2 * $pad); $h = [int]($maxY - $minY + 2 * $pad)
            return @{ how = 'derive'; x = $x; y = $y; w = $w; h = $h
                cx = [int]($x + $w / 2); cy = [int]($y + $h / 2); rows = $lines.Count }
        }
    }

    # 5) rect / point fallback
    if ($anchor.rect) {
        $r = Get-FracRect $frame $anchor.rect
        return @{ how = 'rect'; x = $r.x; y = $r.y; w = $r.w; h = $r.h
            cx = [int]($r.x + $r.w / 2); cy = [int]($r.y + $r.h / 2) }
    }
    if ($anchor.point) {
        $pt = Get-FracRect $frame @($anchor.point[0], $anchor.point[1], 0, 0)
        return @{ how = 'point'; x = $pt.x; y = $pt.y; w = 0; h = 0; cx = $pt.x; cy = $pt.y }
    }

    throw ('anchor unresolvable: ' + $app + '.' + $name)
}

# Discovery helper: dump every OCR line of a window with fractional coordinates, so a new
# app profile can be authored by copy-paste instead of trial and error.
function Get-AnchorDump([string]$app) {
    $prof = Get-AppProfile $app
    $win = Resolve-Win $prof.window_match
    $frame = @{ Left = [double]$win.Left; Top = [double]$win.Top
        Width = [double]($win.Right - $win.Left); Height = [double]($win.Bottom - $win.Top) }
    $lines = @(Get-Lines @{ x = [int]$frame.Left; y = [int]$frame.Top; w = [int]$frame.Width; h = [int]$frame.Height })
    $out = @()
    foreach ($l in $lines) {
        $out += @{
            text = ($l.text -replace '\s+', '')
            rx = [math]::Round(($l.cx - $frame.Left) / $frame.Width, 3)
            ry = [math]::Round(($l.cy - $frame.Top) / $frame.Height, 3)
            abs = ('{0},{1}' -f $l.cx, $l.cy)
        }
    }
    return @{ window = $win.Title; size = ('{0}x{1}' -f $frame.Width, $frame.Height); lines = $out }
}
