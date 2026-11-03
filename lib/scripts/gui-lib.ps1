#requires -Version 5.1
# Client helpers for the persistent daemon. Dot-source this, then call G/GStart.
# ASCII only.
#
#   . C:\path\to\gui-control\gui-lib.ps1
#   G @{ op = 'screen' }
#   G @{ op = 'click'; win = 'bilibili'; x = 120; y = 40 }
#   G @{ op = 'findtext'; win = 'bilibili'; text = '第153话' }

$script:GuiRoot = $PSScriptRoot
$script:GuiPort = 38471

function Test-GuiDaemon {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $script:GuiPort)
        $c.Close()
        return $true
    }
    catch { return $false }
}

function Start-GuiDaemon {
    if (Test-GuiDaemon) { return 'already running' }
    $daemon = Join-Path $script:GuiRoot 'gui-daemon.ps1'
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $daemon, '-Port', $script:GuiPort) `
        -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 100; $i++) {
        Start-Sleep -Milliseconds 100
        if (Test-GuiDaemon) { return 'started' }
    }
    throw 'daemon did not come up (see gui-daemon.log)'
}

function Stop-GuiDaemon {
    try { [void](Send-GuiRaw @{ op = 'quit' }) } catch { }
}

function Send-GuiRaw($op) {
    $json = ($op | ConvertTo-Json -Compress -Depth 8)
    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    $client.Connect('127.0.0.1', $script:GuiPort)
    try {
        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
        $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)))
        $writer.WriteLine($json)
        $line = $reader.ReadLine()
        if ($null -eq $line) { throw 'daemon closed the connection' }
        return ($line | ConvertFrom-Json)
    }
    finally { $client.Close() }
}

# Main entry: runs one op, throws on failure, returns the raw result payload.
function G($op) {
    $r = Send-GuiRaw $op
    if (-not $r.ok) { throw $r.error }
    return $r.result
}

# Batch: run an array of ops in ONE round-trip.
function GBatch([object[]]$ops) {
    return (G @{ op = 'batch'; ops = $ops })
}
