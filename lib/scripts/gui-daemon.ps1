#requires -Version 5.1
# Persistent GUI-control daemon.
# Compiles the native helpers once, then serves ops over loopback TCP so each action
# costs ~5 ms instead of spawning PowerShell + recompiling C# (~700 ms).
# ASCII only.
param(
    [int]$Port = 38471,
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root = (Resolve-Path $Root).Path

. (Join-Path $Root 'gui-ops.ps1')

$logPath = Join-Path $Root 'gui-daemon.log'
function Write-Log([string]$m) {
    try { Add-Content -Path $logPath -Value ((Get-Date).ToString('MM-dd HH:mm:ss.fff') + '  ' + $m) -Encoding UTF8 } catch { }
}

try {
    Import-DshGui $Root
}
catch {
    Write-Log ('compile failed: ' + $_.Exception.Message)
    throw
}

# UIA is optional: some environments cannot load the accessibility assemblies.
try {
    Import-DshUia $Root
    Write-Log 'uia loaded'
}
catch {
    Write-Log ('uia unavailable: ' + $_.Exception.Message)
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true) } catch { }
$listener.Start()
Write-Log "listening on $Port (pid $PID)"

$running = $true
$served = 0

while ($running) {
    $client = $listener.AcceptTcpClient()
    $client.NoDelay = $true
    $client.ReceiveTimeout = 120000
    try {
        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)))
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
        $writer.AutoFlush = $true
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ($line.Trim().Length -eq 0) { continue }
            $op = $null
            $resp = $null
            try {
                $op = $line | ConvertFrom-Json
                $resp = Invoke-GuiOp $op
            }
            catch {
                $resp = @{ ok = $false; error = $_.Exception.Message }
            }
            $served++
            try {
                $writer.WriteLine((ConvertTo-Json $resp -Compress -Depth 8))
            }
            catch {
                Write-Log ('write failed: ' + $_.Exception.Message)
                break
            }
            if ($null -ne $op -and $op.op -eq 'quit') { $running = $false; break }
        }
    }
    catch {
        Write-Log ('connection error: ' + $_.Exception.Message)
    }
    finally {
        try { $client.Close() } catch { }
    }
}

Write-Log "stopped after $served ops"
$listener.Stop()
