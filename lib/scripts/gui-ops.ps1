#requires -Version 5.1
# Shared op implementations for both GuiControl.ps1 (one-shot) and gui-daemon.ps1.
# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI/GBK.

function O([object]$obj, [string]$name, $default) {
    if ($null -eq $obj) { return $default }
    # In-process callers pass hashtables, the wire passes PSCustomObjects. Support both,
    # otherwise every internal call silently degrades to defaults.
    if ($obj -is [System.Collections.IDictionary]) {
        if (-not $obj.Contains($name)) { return $default }
        $v = $obj[$name]
        if ($null -eq $v) { return $default }
        return $v
    }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p) { return $default }
    if ($null -eq $p.Value) { return $default }
    return $p.Value
}

function Has-Key([object]$obj, [string]$name) {
    if ($null -eq $obj) { return $false }
    if ($obj -is [System.Collections.IDictionary]) { return $obj.Contains($name) }
    return ($null -ne $obj.PSObject.Properties[$name])
}

# OCR lives in its own file so the one-shot CLI only pays for it when used.
. (Join-Path $PSScriptRoot 'gui-ocr.ps1')
# Anchor layer: named targets resolved by uia -> ocr -> derive -> point.
. (Join-Path $PSScriptRoot 'gui-anchors.ps1')

function Import-DshGui([string]$root) {
    $cs = Join-Path $root 'DshGui.cs'
    Add-Type -Path $cs -ReferencedAssemblies System.Drawing -ErrorAction Stop
    $size = [DshGui]::Init()
    if ($size -ne 40) { throw 'Need 64-bit PowerShell (INPUT struct must be 40 bytes).' }
}

function Import-DshUia([string]$root) {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    # BoundingRectangle returns System.Windows.Rect, which lives in WindowsBase.
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    $refs = @(
        [System.Windows.Automation.AutomationElement].Assembly.Location,
        [System.Windows.Automation.AutomationIdentifier].Assembly.Location,
        [System.Windows.Rect].Assembly.Location
    )
    Add-Type -Path (Join-Path $root 'DshUia.cs') -ReferencedAssemblies $refs -ErrorAction Stop
}

function Get-Vk([string]$name) {
    $n = $name.Trim().ToLower()
    $map = @{
        'ctrl' = 0x11; 'control' = 0x11; 'shift' = 0x10; 'alt' = 0x12; 'win' = 0x5B
        'enter' = 0x0D; 'return' = 0x0D; 'tab' = 0x09; 'esc' = 0x1B; 'escape' = 0x1B; 'space' = 0x20
        'backspace' = 0x08; 'bs' = 0x08; 'delete' = 0x2E; 'del' = 0x2E; 'insert' = 0x2D
        'home' = 0x24; 'end' = 0x23; 'pageup' = 0x21; 'pgup' = 0x21; 'pagedown' = 0x22; 'pgdn' = 0x22
        'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27
        'capslock' = 0x14; 'printscreen' = 0x2C; 'apps' = 0x5D
        'minus' = 0xBD; 'equal' = 0xBB; 'comma' = 0xBC; 'period' = 0xBE; 'slash' = 0xBF
        'semicolon' = 0xBA; 'quote' = 0xDE; 'backtick' = 0xC0; 'lbracket' = 0xDB; 'rbracket' = 0xDD
        'backslash' = 0xDC
    }
    if ($map.ContainsKey($n)) { return [uint16]$map[$n] }
    if ($n -match '^f([1-9]|1[0-9]|2[0-4])$') { return [uint16](0x6F + [int]$Matches[1]) }
    if ($n.Length -eq 1) {
        $c = $n.ToUpper()[0]
        if ([char]::IsLetterOrDigit($c)) { return [uint16][int][char]$c }
    }
    throw "Unknown key: $name"
}

function Get-WinRows {
    $out = @()
    foreach ($h in [DshGui]::TopWindows()) {
        if (-not [DshGui]::IsWindowVisible($h)) { continue }
        $t = [DshGui]::Title($h)
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $procId = [uint32]0
        [void][DshGui]::GetWindowThreadProcessId($h, [ref]$procId)
        $r = New-Object 'DshGui+RECT'
        [void][DshGui]::GetWindowRect($h, [ref]$r)
        $pn = ''
        try { $pn = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { }
        $out += [pscustomobject]@{
            Hex = ('0x{0:X}' -f $h.ToInt64()); Pid = $procId; Process = $pn; Title = $t
            Left = $r.Left; Top = $r.Top; Right = $r.Right; Bottom = $r.Bottom
        }
    }
    return $out
}

function Resolve-Win([string]$m) {
    if ([string]::IsNullOrEmpty($m)) { return $null }
    $rows = @(Get-WinRows)
    if ($m -match '^\d+$') {
        $byPid = @($rows | Where-Object { $_.Pid -eq [uint32]$m })
        if ($byPid.Count -ge 1) { return $byPid[0] }
    }
    $hit = @($rows | Where-Object { $_.Title -like "*$m*" -or $_.Process -like "*$m*" })
    if ($hit.Count -eq 0) { throw "No window matching '$m'." }
    return $hit[0]
}

function Get-OpPoint($op) {
    # Absolute x/y, or window-relative when "win" is supplied.
    $x = O $op 'x' $null
    $y = O $op 'y' $null
    if ($null -eq $x -or $null -eq $y) { return $null }
    if (Has-Key $op 'win') {
        $w = Resolve-Win (O $op 'win' '')
        if ($null -ne $w) {
            $h = [IntPtr][Convert]::ToInt64($w.Hex, 16)
            $origin = [DshGui]::ClientOrigin($h)
            return @{ x = [int]$origin.X + [int]$x; y = [int]$origin.Y + [int]$y }
        }
    }
    return @{ x = [int]$x; y = [int]$y }
}

function Get-WinRect($w) {
    return @{ x = [int]$w.Left; y = [int]$w.Top; w = [int]($w.Right - $w.Left); h = [int]($w.Bottom - $w.Top) }
}

function Get-UiaWindow([string]$name, [int]$timeoutMs = 2500) {
    # A window can exist in the Win32 sense before it registers in the UIA tree, so wait.
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    do {
        $w = [DshUia]::FindWindow($name)
        if ($null -ne $w) { return $w }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Find-Uia($scope, [string]$text, [string]$type, [int]$max, [int]$timeoutMs = 0) {
    # A window exists before its children register in the UIA tree; poll briefly on empty.
    $deadline = (Get-Date).AddMilliseconds([Math]::Max(0, $timeoutMs))
    do {
        $els = [DshUia]::Find($scope, $text, $type, $max)
        if ($els.Count -gt 0) { return $els }
        if ($timeoutMs -le 0) { return $els }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    return $els
}

function Get-CaptureRect($op) {
    # Explicit x/y/w/h wins over "win": "a region inside this window" is the common case.
    if ((Has-Key $op 'x') -and (Has-Key $op 'w')) {
        return @{ x = [int](O $op 'x' 0); y = [int](O $op 'y' 0); w = [int](O $op 'w' 0); h = [int](O $op 'h' 0) }
    }
    if (Has-Key $op 'win') {
        $w = Resolve-Win (O $op 'win' '')
        return Get-WinRect $w
    }
    $vs = [DshGui]::VirtualScreen()
    return @{ x = $vs.Left; y = $vs.Top; w = ($vs.Right - $vs.Left); h = ($vs.Bottom - $vs.Top) }
}

function Invoke-Capture($op) {
    $r = Get-CaptureRect $op
    if ($r.w -le 0 -or $r.h -le 0) { throw 'invalid capture region' }
    $path = Join-Path $env:TEMP ('cap-{0}-{1}.png' -f $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    [DshGui]::Shot($r.x, $r.y, $r.w, $r.h, $path)
    return @{ path = $path; x = $r.x; y = $r.y; w = $r.w; h = $r.h }
}

# Windows OCR splits CJK into per-glyph words, so line text arrives as "插 件 市 场".
# Match on both the raw string and a whitespace-stripped form.
function Test-TextHit([string]$hay, [string]$needle) {
    if ([string]::IsNullOrEmpty($hay) -or [string]::IsNullOrEmpty($needle)) { return $false }
    if ($hay.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    $h = ($hay -replace '\s+', '')
    $n = ($needle -replace '\s+', '')
    if ($n.Length -eq 0) { return $false }
    return ($h.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Invoke-Btn([string]$btn, [int]$times, [int]$gap) {
    $down = 2; $up = 4
    switch ($btn) {
        'right' { $down = 8; $up = 16 }
        'middle' { $down = 32; $up = 64 }
        'left' { $down = 2; $up = 4 }
        default { throw "Unknown button: $btn" }
    }
    for ($i = 0; $i -lt $times; $i++) {
        [DshGui]::Mouse($down, 0); Start-Sleep -Milliseconds $gap
        [DshGui]::Mouse($up, 0); Start-Sleep -Milliseconds $gap
    }
}

function Send-Txt([string]$s, [string]$mode) {
    if ($mode -eq 'paste') {
        Set-Clipboard -Value $s
        Start-Sleep -Milliseconds 50
        [DshGui]::Key(0x11, $false); [DshGui]::Key(0x56, $false)
        Start-Sleep -Milliseconds 25
        [DshGui]::Key(0x56, $true); [DshGui]::Key(0x11, $true)
        return "pasted $($s.Length)"
    }
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq [char]10) { [DshGui]::Key(0x0D, $false); [DshGui]::Key(0x0D, $true) }
        elseif ($ch -eq [char]13) { }
        else { [DshGui]::Char([uint16][int]$ch) }
    }
    return "typed $($s.Length)"
}

# Executes one op; returns a hashtable describing the result.
function Invoke-GuiOp($op) {
    $name = (O $op 'op' '').ToString().ToLower()
    switch ($name) {

        'ping' { return @{ ok = $true; result = 'pong' } }

        'screen' {
            $r = [DshGui]::VirtualScreen()
            return @{ ok = $true; result = @{ x = $r.Left; y = $r.Top; w = ($r.Right - $r.Left); h = ($r.Bottom - $r.Top) } }
        }

        'pos' {
            $p = [DshGui]::Cursor()
            return @{ ok = $true; result = @{ x = $p.X; y = $p.Y } }
        }

        'move' {
            $pt = Get-OpPoint $op
            if ($null -eq $pt) { throw 'move needs x/y' }
            [DshGui]::MoveAbs($pt.x, $pt.y)
            return @{ ok = $true; result = @{ x = $pt.x; y = $pt.y } }
        }

        'click' {
            $pt = Get-OpPoint $op
            if ($null -ne $pt) { [DshGui]::MoveAbs($pt.x, $pt.y); Start-Sleep -Milliseconds (O $op 'settle' 30) }
            Invoke-Btn (O $op 'button' 'left') ([int](O $op 'count' 1)) ([int](O $op 'gap' 25))
            return @{ ok = $true; result = 'clicked' }
        }

        'drag' {
            $a = Get-OpPoint $op
            $b = @{ x = [int](O $op 'x2' 0); y = [int](O $op 'y2' 0) }
            if (Has-Key $op 'win') {
                $w = Resolve-Win (O $op 'win' '')
                $h = [IntPtr][Convert]::ToInt64($w.Hex, 16)
                $o2 = [DshGui]::ClientOrigin($h)
                $b = @{ x = [int]$o2.X + $b.x; y = [int]$o2.Y + $b.y }
            }
            [DshGui]::MoveAbs($a.x, $a.y); Start-Sleep -Milliseconds 60
            [DshGui]::Mouse(2, 0); Start-Sleep -Milliseconds 70
            [DshGui]::MoveAbs($b.x, $b.y); Start-Sleep -Milliseconds 90
            [DshGui]::Mouse(4, 0)
            return @{ ok = $true; result = 'dragged' }
        }

        'scroll' {
            $pt = Get-OpPoint $op
            if ($null -ne $pt) { [DshGui]::MoveAbs($pt.x, $pt.y); Start-Sleep -Milliseconds 25 }
            [DshGui]::ScrollWheel([int](O $op 'amount' 120))
            return @{ ok = $true; result = 'scrolled' }
        }

        'type' {
            $t = (O $op 'text' '').ToString()
            if ([string]::IsNullOrEmpty($t)) { throw 'type needs text' }
            return @{ ok = $true; result = (Send-Txt $t (O $op 'method' 'auto')) }
        }

        'key' {
            $vk = Get-Vk (O $op 'key' '')
            [DshGui]::Key($vk, $false); Start-Sleep -Milliseconds 20; [DshGui]::Key($vk, $true)
            return @{ ok = $true; result = 'key' }
        }

        'hotkey' {
            $parts = (O $op 'key' '') -split '\+'
            $vks = @()
            foreach ($p in $parts) { $vks += (Get-Vk $p) }
            foreach ($v in $vks) { [DshGui]::Key($v, $false); Start-Sleep -Milliseconds 12 }
            Start-Sleep -Milliseconds 18
            for ($i = $vks.Count - 1; $i -ge 0; $i--) { [DshGui]::Key($vks[$i], $true); Start-Sleep -Milliseconds 12 }
            return @{ ok = $true; result = 'hotkey' }
        }

        'sleep' { Start-Sleep -Milliseconds ([int](O $op 'ms' 200)); return @{ ok = $true; result = 'slept' } }

        'windows' {
            $rows = @(Get-WinRows | ForEach-Object {
                    @{ hex = $_.Hex; pid = $_.Pid; process = $_.Process; title = $_.Title
                        rect = "$($_.Left),$($_.Top) $($_.Right - $_.Left)x$($_.Bottom - $_.Top)" }
                })
            return @{ ok = $true; result = $rows }
        }

        'foreground' {
            $h = [DshGui]::GetForegroundWindow()
            $procId = [uint32]0
            [void][DshGui]::GetWindowThreadProcessId($h, [ref]$procId)
            $pn = ''
            try { $pn = (Get-Process -Id $procId).ProcessName } catch { }
            return @{ ok = $true; result = @{ title = [DshGui]::Title($h); process = $pn; pid = $procId; hex = ('0x{0:X}' -f $h.ToInt64()) } }
        }

        'activate' {
            $w = Resolve-Win (O $op 'win' '')
            $h = [IntPtr][Convert]::ToInt64($w.Hex, 16)
            if ([DshGui]::IsIconic($h)) { [void][DshGui]::ShowWindow($h, 9); Start-Sleep -Milliseconds 120 }
            [void][DshGui]::SetForegroundWindow($h)
            $t0 = [DateTime]::Now
            while ((([DateTime]::Now) - $t0).TotalMilliseconds -lt 700) {
                if ([DshGui]::GetForegroundWindow() -eq $h) { break }
                [DshGui]::SwitchToThisWindow($h, $true)
                Start-Sleep -Milliseconds 80
            }
            return @{ ok = ([DshGui]::GetForegroundWindow() -eq $h); result = @{ title = $w.Title; rect = (Get-WinRect $w) } }
        }

        'winrect' {
            $w = Resolve-Win (O $op 'win' '')
            $r = Get-WinRect $w
            $h = [IntPtr][Convert]::ToInt64($w.Hex, 16)
            $o2 = [DshGui]::ClientOrigin($h)
            return @{ ok = $true; result = @{ title = $w.Title; x = $r.x; y = $r.y; w = $r.w; h = $r.h; clientX = $o2.X; clientY = $o2.Y } }
        }

        'winmove' {
            $w = Resolve-Win (O $op 'win' '')
            $h = [IntPtr][Convert]::ToInt64($w.Hex, 16)
            $ok = [DshGui]::MoveWindow($h, [int](O $op 'x' 0), [int](O $op 'y' 0), [int](O $op 'w' 800), [int](O $op 'h' 600), $true)
            return @{ ok = $ok; result = 'moved' }
        }

        'winmax' {
            $w = Resolve-Win (O $op 'win' '')
            [void][DshGui]::ShowWindow([IntPtr][Convert]::ToInt64($w.Hex, 16), 3)
            return @{ ok = $true; result = 'maximized' }
        }

        'waitwin' {
            $m = O $op 'win' ''
            $timeout = [int](O $op 'timeout' 10)
            $deadline = [DateTime]::Now.AddSeconds($timeout)
            while ([DateTime]::Now -lt $deadline) {
                $hit = @(Get-WinRows | Where-Object { $_.Title -like "*$m*" -or $_.Process -like "*$m*" })
                if ($hit.Count -ge 1) { return @{ ok = $true; result = @{ title = $hit[0].Title; hex = $hit[0].Hex } } }
                Start-Sleep -Milliseconds 120
            }
            return @{ ok = $false; error = "waitwin timeout: $m" }
        }

        'waitgone' {
            $m = O $op 'win' ''
            $timeout = [int](O $op 'timeout' 10)
            $deadline = [DateTime]::Now.AddSeconds($timeout)
            while ([DateTime]::Now -lt $deadline) {
                $hit = @(Get-WinRows | Where-Object { $_.Title -like "*$m*" -or $_.Process -like "*$m*" })
                if ($hit.Count -eq 0) { return @{ ok = $true; result = 'gone' } }
                Start-Sleep -Milliseconds 120
            }
            return @{ ok = $false; error = "waitgone timeout: $m" }
        }

        'waittitle' {
            # Wait until the matched window's title contains a given substring (page changed).
            $m = O $op 'win' ''
            $want = O $op 'text' ''
            $timeout = [int](O $op 'timeout' 10)
            $deadline = [DateTime]::Now.AddSeconds($timeout)
            while ([DateTime]::Now -lt $deadline) {
                $hit = @(Get-WinRows | Where-Object { $_.Title -like "*$want*" })
                if ($hit.Count -ge 1) { return @{ ok = $true; result = @{ title = $hit[0].Title; hex = $hit[0].Hex } } }
                Start-Sleep -Milliseconds 150
            }
            return @{ ok = $false; error = "waittitle timeout: $want" }
        }

        'launch' {
            # Some desktop apps refuse CreateProcess from an automation host and exit 0
            # immediately (the bilibili client does). via=explorer goes through ShellExecute
            # like a desktop double-click, which those apps accept.
            $t = (O $op 'text' '').ToString()
            if ([string]::IsNullOrEmpty($t)) { throw 'launch needs text' }
            $via = (O $op 'via' '').ToString().ToLower()
            $cwd = (O $op 'cwd' '').ToString()
            if ($via -eq 'explorer') {
                Start-Process -FilePath 'explorer.exe' -ArgumentList $t
                return @{ ok = $true; result = 'launched via explorer' }
            }
            if ([string]::IsNullOrEmpty($cwd)) { Start-Process -FilePath $t }
            else { Start-Process -FilePath $t -WorkingDirectory $cwd }
            return @{ ok = $true; result = 'launched' }
        }

        'clipset' { Set-Clipboard -Value (O $op 'text' ''); return @{ ok = $true; result = 'set' } }
        'clipget' { return @{ ok = $true; result = (Get-Clipboard -Raw) } }

        'pixel' {
            $pt = Get-OpPoint $op
            $c = [DshGui]::Pixel($pt.x, $pt.y)
            return @{ ok = $true; result = @{ x = $pt.x; y = $pt.y; rgb = ('#{0:X6}' -f $c) } }
        }

        'waitpixel' {
            # Wait until pixel at x,y matches rgb within tolerance.
            $pt = Get-OpPoint $op
            $want = (O $op 'rgb' '#000000').TrimStart('#')
            $tol = [int](O $op 'tol' 12)
            $timeout = [int](O $op 'timeout' 5)
            $wr = [Convert]::ToInt32($want, 16)
            $deadline = [DateTime]::Now.AddSeconds($timeout)
            while ([DateTime]::Now -lt $deadline) {
                $c = [DshGui]::Pixel($pt.x, $pt.y)
                $dr = [Math]::Abs((($c -shr 16) -band 255) - (($wr -shr 16) -band 255))
                $dg = [Math]::Abs((($c -shr 8) -band 255) - (($wr -shr 8) -band 255))
                $db = [Math]::Abs(($c -band 255) - ($wr -band 255))
                if ($dr -le $tol -and $dg -le $tol -and $db -le $tol) { return @{ ok = $true; result = @{ rgb = ('#{0:X6}' -f $c) } } }
                Start-Sleep -Milliseconds 60
            }
            return @{ ok = $false; error = 'waitpixel timeout' }
        }

        'shot' {
            # Options that make a screenshot readable by the model without arithmetic:
            #   rulers=1 -> screen-coordinate tick labels; scale<1 -> smaller image;
            #   unchanged=true when the frame is byte-identical to the previous one.
            $path = (O $op 'path' '').ToString()
            if ([string]::IsNullOrEmpty($path)) {
                $path = Join-Path $env:TEMP ('shot-{0:HHmmssfff}.png' -f (Get-Date))
            }
            $r = Get-CaptureRect $op
            $scale = [double](O $op 'scale' 1)
            if ($scale -le 0 -or $scale -gt 1) { $scale = 1 }
            $dW = [int]($r.w * $scale); $dH = [int]($r.h * $scale)
            $step = [int](O $op 'step' 200)

            if ((O $op 'rulers' $false) -eq $true) {
                $note = ('origin {0},{1}  capture {2}x{3}  delivered {4}x{5}  scale {6}  step {7}' -f $r.x, $r.y, $r.w, $r.h, $dW, $dH, $scale, $step)
                [DshGui]::ShotRuled($r.x, $r.y, $r.w, $r.h, $scale, $step, $path, $note)
            }
            elseif ($scale -lt 1) {
                [DshGui]::ShotScaled($r.x, $r.y, $r.w, $r.h, $scale, $path)
            }
            else {
                [DshGui]::Shot($r.x, $r.y, $r.w, $r.h, $path)
            }

            $bytes = [System.IO.File]::ReadAllBytes($path)
            $md5 = [System.Security.Cryptography.MD5]::Create()
            $hash = [BitConverter]::ToString($md5.ComputeHash($bytes)).Replace('-', '')

            if ((O $op 'force' $false) -ne $true -and $hash -eq $script:LastShotHash -and (Test-Path $script:LastShotPath)) {
                Remove-Item $path -Force -ErrorAction SilentlyContinue
                return @{ ok = $true; result = @{ unchanged = $true; path = $script:LastShotPath; x = $r.x; y = $r.y
                        w = $dW; h = $dH; scale = $scale; hash = $hash } }
            }
            $script:LastShotHash = $hash
            $script:LastShotPath = $path
            return @{ ok = $true; result = @{ unchanged = $false; path = $path; x = $r.x; y = $r.y
                    w = $dW; h = $dH; scale = $scale; hash = $hash; bytes = $bytes.Length } }
        }

        'ocr' {
            # OCR a window or region; returns text lines with absolute boxes.
            $cap = Invoke-Capture $op
            try {
                $lines = @(Get-OcrLines $cap.path $cap.x $cap.y)
            }
            finally {
                Remove-Item $cap.path -Force -ErrorAction SilentlyContinue
            }
            return @{ ok = $true; result = $lines }
        }

        'findtext' {
            # Locate a control by its visible text. Semantic targeting without UIA.
            # grow=1 retries with an expanded crop: Windows OCR is sensitive to where the
            # crop cuts, so the same label can vanish when the region is 10 px shorter.
            $needle = (O $op 'text' '').ToString()
            if ([string]::IsNullOrEmpty($needle)) { throw 'findtext needs text' }
            $max = [int](O $op 'max' 10)
            $grow = [int](O $op 'grow' 0)
            $regions = @(Get-CaptureRect $op)
            if ($grow -gt 0) {
                $base = $regions[0]
                foreach ($f in @(0.12, 0.25)) {
                    $dx = [int]($base.w * $f); $dy = [int]($base.h * $f)
                    $regions += @{ x = $base.x - $dx; y = $base.y - $dy; w = $base.w + 2 * $dx; h = $base.h + 2 * $dy }
                }
                $vs = [DshGui]::VirtualScreen()
                $regions += @{ x = $vs.Left; y = $vs.Top; w = ($vs.Right - $vs.Left); h = ($vs.Bottom - $vs.Top) }
            }

            $lines = @()
            foreach ($reg in $regions) {
                $cap = @{ }
                if ((Has-Key $reg 'x')) { $cap = $reg } else { $cap = Get-CaptureRect $op }
                $path = Join-Path $env:TEMP ('cap-{0}-{1}.png' -f $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
                [DshGui]::Shot($cap.x, $cap.y, $cap.w, $cap.h, $path)
                try { $lines = @(Get-OcrLines $path $cap.x $cap.y) }
                finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }

                $hits = @()
                $i = 0
                foreach ($l in $lines) {
                    if (Test-TextHit $l.text $needle) {
                        $hits += @{ index = $i; text = $l.text; x = $l.x; y = $l.y; w = $l.w; h = $l.h; cx = $l.cx; cy = $l.cy }
                        $i++
                        if ($hits.Count -ge $max) { break }
                    }
                }
                if ($hits.Count -ge 1) {
                    if ((O $op 'list' $false) -eq $true) {
                        return @{ ok = $true; result = @{ matches = $hits; all = $lines } }
                    }
                    return @{ ok = $true; result = $hits }
                }
            }
            return @{ ok = $false; error = "text not found: $needle" }
        }

        'clicktext' {
            # find it, then click its center. The accuracy workhorse for CEF apps.
            $needle = (O $op 'text' '').ToString()
            if ([string]::IsNullOrEmpty($needle)) { throw 'clicktext needs text' }
            $cap = Invoke-Capture $op
            try {
                $lines = @(Get-OcrLines $cap.path $cap.x $cap.y)
            }
            finally {
                Remove-Item $cap.path -Force -ErrorAction SilentlyContinue
            }
            $hits = @($lines | Where-Object { Test-TextHit $_.text $needle })
            if ($hits.Count -eq 0) { return @{ ok = $false; error = "text not found: $needle" } }
            $pick = [int](O $op 'index' 0)
            if ($pick -ge $hits.Count) { $pick = $hits.Count - 1 }
            $t = $hits[$pick]
            [DshGui]::MoveAbs($t.cx, $t.cy)
            Start-Sleep -Milliseconds ([int](O $op 'settle' 40))
            Invoke-Btn 'left' 1 25
            return @{ ok = $true; result = @{ text = $t.text; x = $t.cx; y = $t.cy; index = $pick } }
        }

        'waittext' {
            $needle = (O $op 'text' '').ToString()
            $timeout = [int](O $op 'timeout' 10)
            $deadline = [DateTime]::Now.AddSeconds($timeout)
            while ([DateTime]::Now -lt $deadline) {
                $cap = Invoke-Capture $op
                try { $lines = @(Get-OcrLines $cap.path $cap.x $cap.y) }
                finally { Remove-Item $cap.path -Force -ErrorAction SilentlyContinue }
                $hit = @($lines | Where-Object { Test-TextHit $_.text $needle })
                if ($hit.Count -ge 1) { return @{ ok = $true; result = @{ text = $hit[0].text; cx = $hit[0].cx; cy = $hit[0].cy } } }
                Start-Sleep -Milliseconds 200
            }
            return @{ ok = $false; error = "waittext timeout: $needle" }
        }

        'uia-find' {
            # Exact control lookup through accessibility. Falls back to nothing: if the app
            # exposes no UIA tree, use findtext/clicktext (OCR) instead.
            $winName = (O $op 'win' '').ToString()
            $scope = Get-UiaWindow $winName
            if ($null -eq $scope) { return @{ ok = $false; error = "uia window not found: $winName" } }
            $els = [DshUia]::Find($scope, (O $op 'text' ''), (O $op 'type' ''), [int](O $op 'max' 20))
            $out = @()
            foreach ($e in $els) {
                $r = [DshUia]::Rect($e)
                $out += @{
                    name = [DshUia]::Name($e); auto = [DshUia]::AutoId($e); type = [DshUia]::TypeOf($e)
                    x = [int]$r[0]; y = [int]$r[1]; w = [int]$r[2]; h = [int]$r[3]
                    cx = [int]($r[0] + $r[2] / 2); cy = [int]($r[1] + $r[3] / 2)
                }
            }
            if ($out.Count -eq 0) { return @{ ok = $false; error = "uia no match: $($op.text)" } }
            return @{ ok = $true; result = $out }
        }

        'uia-click' {
            $winName = (O $op 'win' '').ToString()
            $scope = Get-UiaWindow $winName
            if ($null -eq $scope) { return @{ ok = $false; error = "uia window not found: $winName" } }
            $els = Find-Uia $scope (O $op 'text' '') (O $op 'type' '') 50 ([int](O $op 'waitMs' 2500))
            if ($els.Count -eq 0) { return @{ ok = $false; error = "uia no match: $($op.text)" } }
            $pick = [int](O $op 'index' 0)
            if ($pick -ge $els.Count) { $pick = $els.Count - 1 }
            $e = $els[$pick]
            $how = [DshUia]::Activate($e)
            if ($how -eq 'none') {
                $r = [DshUia]::Rect($e)
                [DshGui]::MoveAbs([int]($r[0] + $r[2] / 2), [int]($r[1] + $r[3] / 2))
                Start-Sleep -Milliseconds 40
                Invoke-Btn 'left' 1 25
                $how = 'mouse'
            }
            $r2 = [DshUia]::Rect($e)
            return @{ ok = $true; result = @{ name = [DshUia]::Name($e); how = $how; x = [int]$r2[0]; y = [int]$r2[1] } }
        }

        'uia-set' {
            $winName = (O $op 'win' '').ToString()
            $scope = Get-UiaWindow $winName
            if ($null -eq $scope) { return @{ ok = $false; error = "uia window not found: $winName" } }
            $els = Find-Uia $scope (O $op 'text' '') (O $op 'type' '') 20 ([int](O $op 'waitMs' 2500))
            if ($els.Count -eq 0) { return @{ ok = $false; error = "uia no match: $($op.text)" } }
            $how = [DshUia]::SetText($els[0], (O $op 'value' '').ToString())
            return @{ ok = ($how -ne 'none'); result = @{ how = $how } }
        }

        'uia-get' {
            # Read a control's text/value: the cheapest possible verification.
            $winName = (O $op 'win' '').ToString()
            $scope = Get-UiaWindow $winName
            if ($null -eq $scope) { return @{ ok = $false; error = "uia window not found: $winName" } }
            $els = Find-Uia $scope (O $op 'text' '') (O $op 'type' '') 20 ([int](O $op 'waitMs' 2500))
            if ($els.Count -eq 0) { return @{ ok = $false; error = "uia no match: $($op.text)" } }
            return @{ ok = $true; result = @{ text = [DshUia]::GetText($els[0]); name = [DshUia]::Name($els[0]) } }
        }

        'anchor' {
            # Resolve a named target from apps\<app>.json. No pixels in the caller.
            $r = Resolve-Anchor (O $op 'app' '') (O $op 'name' '') (O $op 'win' '')
            return @{ ok = $true; result = $r }
        }

        'anchor-click' {
            $r = Resolve-Anchor (O $op 'app' '') (O $op 'name' '') (O $op 'win' '')
            [DshGui]::MoveAbs($r.cx, $r.cy)
            Start-Sleep -Milliseconds ([int](O $op 'settle' 40))
            Invoke-Btn 'left' 1 25
            return @{ ok = $true; result = $r }
        }

        'anchor-dump' {
            # Authoring aid: every OCR line of the window with fractional coordinates.
            $r = Get-AnchorDump (O $op 'app' '')
            return @{ ok = $true; result = $r }
        }

        'uia-dump' {
            # Read a web page (or any app) as a structured list instead of pixels.
            # Chromium exposes the DOM through UIA, so this is exact and position independent.
            $winName = (O $op 'win' '').ToString()
            $scope = Get-UiaWindow $winName
            if ($null -eq $scope) { return @{ ok = $false; error = "uia window not found: $winName" } }
            if ((O $op 'document' $true) -eq $true) { $scope = [DshUia]::DocumentOf($scope) }
            $max = [int](O $op 'max' 300)
            $els = [DshUia]::Descendants($scope, $max)
            $out = @()
            foreach ($e in $els) {
                $nm = [DshUia]::Name($e)
                $tp = [DshUia]::TypeOf($e)
                if ($nm.Length -eq 0 -and $tp -notin @('Edit', 'Document', 'Button')) { continue }
                $r = [DshUia]::Rect($e)
                $out += @{
                    name = $nm; type = $tp; auto = [DshUia]::AutoId($e)
                    x = [int]$r[0]; y = [int]$r[1]; w = [int]$r[2]; h = [int]$r[3]
                    cx = [int]($r[0] + $r[2] / 2); cy = [int]($r[1] + $r[3] / 2)
                }
                if ($out.Count -ge $max) { break }
            }
            return @{ ok = $true; result = $out }
        }

        'uia-pick' {
            # Pick the Nth element of a control type, ordered top-to-bottom.
            # Radios and checkboxes on a web page carry no accessible name, so name-based
            # lookup cannot address them; index + SELECT pattern does, even off-screen.
            $winName = (O $op 'win' '').ToString()
            $scope = Get-UiaWindow $winName
            if ($null -eq $scope) { return @{ ok = $false; error = "uia window not found: $winName" } }
            if ((O $op 'document' $true) -eq $true) { $scope = [DshUia]::DocumentOf($scope) }
            $type = (O $op 'type' 'RadioButton').ToString()
            $els = [DshUia]::Find($scope, '', $type, 800)
            $ex = (O $op 'exclude' '').ToString()
            if ($ex.Length -gt 0) { $els = @($els | Where-Object { [DshUia]::Name($_) -notmatch $ex }) }
            $sorted = @($els)
            $idx = [int](O $op 'index' 0)
            if ($idx -lt 0 -or $idx -ge $sorted.Count) { return @{ ok = $false; error = "index $idx out of range ($($sorted.Count) $type found)" } }
            $e = $sorted[$idx]
            # Identity check: the list may have re-rendered since it was read.
            # Identity predicate: name AND automation id, checked before any dispatch.
            $expect = (O $op 'expect' '').ToString()
            $expectId = (O $op 'expectId' '').ToString()
            $actName = [DshUia]::Name($e)
            $actId = [DshUia]::AutoId($e)
            $actType = [DshUia]::TypeOf($e)
            if ($expect.Length -gt 0 -and $actName.IndexOf($expect, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                return @{ ok = $false; error = ('identity mismatch at index ' + $idx + ': expected name "' + $expect + '", found "' + $actName + '"'); delivery = 'not_delivered' }
            }
            if ($expectId.Length -gt 0 -and $actId -ne $expectId) {
                return @{ ok = $false; error = ('identity mismatch at index ' + $idx + ': expected id "' + $expectId + '", found "' + $actId + '"'); delivery = 'not_delivered' }
            }
            $how = [DshUia]::Activate($e)
            $r = [DshUia]::Rect($e)
            $sel = [DshUia]::IsSelected($e)
            return @{ ok = $true; result = @{ index = $idx; count = $sorted.Count; how = $how; selected = $sel; identity = @{ type = $actType; name = $actName; autoId = $actId }
                    x = [int]$r[0]; y = [int]$r[1]; cx = [int]($r[0] + $r[2] / 2); cy = [int]($r[1] + $r[3] / 2) } }
        }

        'uia-state' {
            # Which radios/checkboxes are currently on - the cheapest way to verify a form.
            $winName = (O $op 'win' '').ToString()
            $scope = Get-UiaWindow $winName
            if ($null -eq $scope) { return @{ ok = $false; error = "uia window not found: $winName" } }
            if ((O $op 'document' $true) -eq $true) { $scope = [DshUia]::DocumentOf($scope) }
            $type = (O $op 'type' 'RadioButton').ToString()
            $els = [DshUia]::Find($scope, '', $type, 800)
            $ex = (O $op 'exclude' '').ToString()
            if ($ex.Length -gt 0) { $els = @($els | Where-Object { [DshUia]::Name($_) -notmatch $ex }) }
            $sorted = @($els)
            $out = @()
            for ($i = 0; $i -lt $sorted.Count; $i++) {
                $r = [DshUia]::Rect($sorted[$i])
                $out += @{ index = $i; selected = [DshUia]::IsSelected($sorted[$i]); y = [int]$r[1] }
            }
            return @{ ok = $true; result = $out }
        }

        'batch' {
            # Run many ops inside one round-trip. Stops on first failure unless "keepGoing".
            $ops = @(O $op 'ops' @())
            $results = @()
            foreach ($sub in $ops) {
                $r = Invoke-GuiOp $sub
                $results += $r
                if (-not $r.ok -and -not (O $op 'keepGoing' $false)) { break }
            }
            $allOk = $true
            foreach ($r in $results) { if (-not $r.ok) { $allOk = $false } }
            return @{ ok = $allOk; result = $results }
        }

        'uia-mini' {
            # Token-cheap page read: dedupe by name, no rects, truncate long text.
            # uia-dump returns objects with rects (~7k chars per page); this returns lines.
            $winName = (O $op 'win' '').ToString()
            $scope = Get-UiaWindow $winName
            if ($null -eq $scope) { return @{ ok = $false; error = "uia window not found: $winName" } }
            if ((O $op 'document' $true) -eq $true) { $scope = [DshUia]::DocumentOf($scope) }
            $cap = [int](O $op 'chars' 60)
            $maxOut = [int](O $op 'lines' 60)
            $region = $null
            if ((Has-Key $op 'x') -and (Has-Key $op 'w')) {
                $region = @{ x = [int](O $op 'x' 0); y = [int](O $op 'y' 0); w = [int](O $op 'w' 0); h = [int](O $op 'h' 0) }
            }
            $keep = (O $op 'types' '').ToString().ToLower()
            $els = [DshUia]::Descendants($scope, 2000)
            $seen = @{}
            $out = @()
            foreach ($e in $els) {
                $nm = [DshUia]::Name($e)
                $tp = [DshUia]::TypeOf($e)
                if ([string]::IsNullOrWhiteSpace($nm)) {
                    # An unnamed editable field still matters; show its value, redacted when secret.
                    if ($tp -notin @('Edit', 'Text', 'Document')) { continue }
                    if ([DshUia]::IsPassword($e)) { $nm = '<redacted>' }
                    else {
                        $nm = [DshUia]::Value($e)
                        if ([string]::IsNullOrWhiteSpace($nm)) { $nm = '(empty ' + $tp + ')' }
                    }
                }
                if ($keep.Length -gt 0 -and $keep.IndexOf($tp.ToLower()) -lt 0) { continue }
                if ($null -ne $region) {
                    $r = [DshUia]::Rect($e)
                    if ($r[0] -lt $region.x -or $r[1] -lt $region.y -or
                        ($r[0] + $r[2]) -gt ($region.x + $region.w) -or ($r[1] + $r[3]) -gt ($region.y + $region.h)) { continue }
                }
                $t = $nm -replace '\s+', ' '
                $key = $tp + '|' + $t
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = 1
                if ($t.Length -gt $cap) { $t = $t.Substring(0, $cap) + '~' }
                $short = $tp
                if ($short.Length -gt 5) { $short = $short.Substring(0, 5) }
                $out += ('{0} {1}' -f $short, $t)
                if ($out.Count -ge $maxOut) { break }
            }
            return @{ ok = $true; result = $out }
        }

        'task' {
            # Declarative task runner: a list of steps executed inside the daemon with no
            # agent in the loop. One call = one task, verified step by step.
            # Step fields: do (op name), plus that op's params,
            #              until (op polled until ok), untilTimeout (s), retry, soft.
            $name = (O $op 'name' 'task').ToString()
            $steps = @()
            if (Has-Key $op 'file') {
                $p = (O $op 'file' '').ToString()
                if (-not (Test-Path $p)) { return @{ ok = $false; error = "task file not found: $p" } }
                $def = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json
                if ($def.name) { $name = $def.name }
                $steps = @($def.steps)
            }
            else { $steps = @(O $op 'steps' @()) }
            if ($steps.Count -eq 0) { return @{ ok = $false; error = 'task has no steps' } }

            # Risk gate: a medium/high step must never run before the caller confirms.
            $confirm = (O $op 'confirm' $false) -eq $true
            $dryRun = (O $op 'dryRun' $false) -eq $true
            $risky = @()
            $plan = @()
            $n = 0
            foreach ($s in $steps) {
                $n++
                $risk = (O $s 'risk' 'low').ToString().ToLower()
                $plan += @{ n = $n; do = (O $s 'do' '').ToString(); risk = $risk }
                if ($risk -ne 'low') { $risky += @{ n = $n; do = (O $s 'do' '').ToString(); risk = $risk } }
            }
            if ($dryRun) { return @{ ok = $true; result = @{ name = $name; dryRun = $true; steps = $plan } } }
            if ($risky.Count -gt 0 -and -not $confirm) {
                return @{ ok = $false; error = ('confirm required for ' + $risky.Count + ' risky step(s)')
                    result = @{ name = $name; risky = $risky; hint = 'resend with confirm=true, or dryRun=true to inspect' } }
            }

            $T = [Diagnostics.Stopwatch]::StartNew()
            $log = @()
            $i = 0
            foreach ($s in $steps) {
                $i++
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $o = @{}
                foreach ($p in $s.PSObject.Properties) { $o[$p.Name] = $p.Value }
                $doName = (O $s 'do' '').ToString()
                if ([string]::IsNullOrEmpty($doName)) { $doName = (O $s 'op' '').ToString() }
                $o.Remove('do')
                $null = $o.Remove('op')
                $o['op'] = $doName

                $until = $null
                if (Has-Key $s 'until') { $until = $s.until }
                $untilTimeout = 8; if (Has-Key $s 'untilTimeout') { $untilTimeout = [int]$s.untilTimeout }
                $retry = 1; if (Has-Key $s 'retry') { $retry = [int]$s.retry }
                foreach ($k in @('until', 'untilTimeout', 'retry', 'risk')) { $null = $o.Remove($k) }

                # Delivery semantics: what a failure says about whether input actually landed.
                # not_delivered = nothing was sent, safe to retry; delivered_unverified = it may
                # have landed, so retrying risks a duplicate; delivered_verified = re-read agreed.
                $inputOps = @('click', 'dclick', 'move', 'drag', 'scroll', 'type', 'key', 'hotkey',
                    'uia-click', 'uia-pick', 'uia-set', 'activate', 'winmove', 'launch', 'closeapp')
                $isInput = $inputOps -contains $doName

                $stepOk = $false
                $note = ''
                $delivery = 'not_delivered'
                for ($try = 1; $try -le [Math]::Max(1, $retry); $try++) {
                    $r = $null
                    try { $r = Invoke-GuiOp $o } catch { $r = @{ ok = $false; error = $_.Exception.Message } }
                    if (-not $r.ok) {
                        $note = [string]$r.error
                        # A refusal before dispatch sent nothing, so retrying it is always safe.
                        $preDispatch = ($note -match 'not found|no match|no window|unknown op|out of range|invalid|needs |not exist')
                        if ($isInput -and -not $preDispatch) { $delivery = 'delivered_unverified' }
                        else { $delivery = 'not_delivered' }
                        if ($delivery -ne 'not_delivered') { break }
                        continue
                    }
                    if ($null -eq $until) {
                        $stepOk = $true
                        if ($isInput) { $delivery = 'delivered_unverified' } else { $delivery = 'not_delivered' }
                        break
                    }

                    $u = @{}
                    $u = @{}
                    foreach ($p in $until.PSObject.Properties) { $u[$p.Name] = $p.Value }
                    if (-not $u.ContainsKey('waitMs')) { $u['waitMs'] = 0 }
                    $deadline = (Get-Date).AddSeconds($untilTimeout)
                    while ((Get-Date) -lt $deadline) {
                        $ur = $null
                        try { $ur = Invoke-GuiOp $u } catch { $ur = @{ ok = $false } }
                        if ($ur.ok) { $stepOk = $true; break }
                        Start-Sleep -Milliseconds 150
                    }
                    if ($stepOk) { $delivery = 'delivered_verified'; break }
                    # The step dispatched but its effect never showed up: do NOT replay it.
                    $delivery = $(if ($isInput) { 'delivered_unverified' } else { 'not_delivered' })
                    $note = 'until-timeout'
                    break
                }
                # Carry a compact value out of read-only steps (uia-get / clipget / ...).
                $outText = ''
                if ($stepOk -and $null -ne $r -and $null -ne $r.result) {
                    if ($r.result -is [string]) { $outText = $r.result }
                    elseif ($r.result -is [hashtable] -and $r.result.ContainsKey('text')) { $outText = [string]$r.result.text }
                }
                $sw.Stop()
                $log += @{ n = $i; do = $doName; ok = $stepOk; ms = $sw.ElapsedMilliseconds; note = $note; out = $outText; delivery = $delivery; retrySafe = ($delivery -eq 'not_delivered') }
                if (-not $stepOk) {
                    return @{ ok = $false; error = ('step ' + $i + ' (' + $doName + ') failed: ' + $note); delivery = $delivery; retry = $(if ($delivery -eq 'not_delivered') { 'safe' } else { 'unsafe' }); result = @{ name = $name; steps = $log; total = $T.ElapsedMilliseconds } }
                }
            }
            return @{ ok = $true; result = @{ name = $name; steps = $log; total = $T.ElapsedMilliseconds } }
        }

        'pathexists' {
            # Filesystem as a step condition: lets a task wait for the real outcome instead
            # of sleeping a guessed interval.
            $p = (O $op 'text' '').ToString()
            if ([string]::IsNullOrEmpty($p)) { throw 'pathexists needs text' }
            if (Test-Path -LiteralPath $p) {
                $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
                $size = 0
                if ($item -and -not $item.PSIsContainer) { $size = $item.Length }
                return @{ ok = $true; result = @{ path = $p; exists = $true; bytes = $size } }
            }
            return @{ ok = $false; error = ('missing: ' + $p) }
        }

        default { return @{ ok = $false; error = "unknown op: $name" } }
    }
}
