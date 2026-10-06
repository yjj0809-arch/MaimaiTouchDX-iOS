param(
    [string]$HostName = "127.0.0.1",
    [int]$Port = 4321,
    [UInt64]$State = 0,
    [int]$DurationMs = 1500
)

$ErrorActionPreference = "Stop"

$client = New-Object System.Net.Sockets.TcpClient
$client.NoDelay = $true
$client.Connect($HostName, $Port)
$stream = $client.GetStream()
$bytes = [BitConverter]::GetBytes($State)

$deadline = [DateTime]::UtcNow.AddMilliseconds($DurationMs)
while ([DateTime]::UtcNow -lt $deadline) {
    $stream.Write($bytes, 0, $bytes.Length)
    Start-Sleep -Milliseconds 4
}

$stream.Close()
$client.Close()
Write-Host ("Sent TouchDX state 0x{0:X16} to {1}:{2}" -f $State, $HostName, $Port)
