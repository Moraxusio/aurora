# Runs the Dart client benchmark and the Go reference against one fresh
# aurora3-testpeer each, on this machine (loopback). Build first:
#   agent: go build -o dist\aurora3-testpeer.exe ./cmd/aurora3-testpeer
#          go build -o dist\aurora3-bench.exe ./cmd/aurora3-bench
#   app\packages\aurora_wire: dart build cli -t bin\bench.dart -o build\benchcli
param([int]$Rounds = 1)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$peerExe = Join-Path $root 'agent\dist\aurora3-testpeer.exe'
$goBench = Join-Path $root 'agent\dist\aurora3-bench.exe'
$dartBench = Join-Path $root 'app\packages\aurora_wire\build\benchcli\bundle\bin\bench.exe'

function Start-Peer {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $peerExe
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    $info = $p.StandardOutput.ReadLine() | ConvertFrom-Json
    return @{ Proc = $p; Info = $info }
}

for ($r = 1; $r -le $Rounds; $r++) {
    foreach ($side in 'go', 'dart') {
        $peer = Start-Peer
        try {
            $i = $peer.Info
            "=== $side (round $r)"
            if ($side -eq 'go') {
                & $goBench -addr $i.addr -pin $i.pin -token $i.token
            } else {
                & $dartBench $i.addr $i.pin $i.token
            }
        } finally {
            $peer.Proc.StandardInput.Close()
            if (-not $peer.Proc.WaitForExit(10000)) { $peer.Proc.Kill() }
        }
    }
}
