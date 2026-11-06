# Builds the agent (with the bundled tmux) and the Dart terminal_e2e for
# linux, then runs terminal-e2e.sh in WSL as the normal user: no install, no
# root, no systemd unit; port 17790; everything under /tmp, removed after.
#   powershell -File agent\tools\terminal-e2e.ps1 [-Distro Ubuntu-24.04]
param([string]$Distro = 'Ubuntu-24.04')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$go = 'go'
$dart = 'dart'
$out = Join-Path $env:LOCALAPPDATA 'Temp\aurora3\term-e2e'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:CGO_ENABLED = '0'; $env:GOOS = 'linux'; $env:GOARCH = 'amd64'
Push-Location (Join-Path $repo 'agent')
try {
    & $go build -trimpath -ldflags '-s -w -X main.Version=3.0.1' -o "$out\aurora3-agent" ./cmd/aurora3-agent
    if ($LASTEXITCODE) { throw 'go build' }
} finally { Pop-Location; Remove-Item Env:GOOS, Env:GOARCH }
Push-Location (Join-Path $repo 'app\packages\aurora_wire')
try {
    & $dart build cli -t test\e2e\terminal_e2e.dart --target-os linux --target-arch x64 -o "$out\b" | Select-String 'Generated'
    if ($LASTEXITCODE) { throw 'dart build' }
} finally { Pop-Location }
Copy-Item "$out\b\bundle\*" $out -Recurse
Remove-Item "$out\b" -Recurse -Force
Copy-Item (Join-Path $PSScriptRoot 'terminal-e2e.sh') $out
$wslOut = '/mnt/' + $out.Substring(0, 1).ToLower() + $out.Substring(2).Replace('\', '/')
wsl -d $Distro -- bash "$wslOut/terminal-e2e.sh" $wslOut
$code = $LASTEXITCODE
Remove-Item $out -Recurse -Force
exit $code
