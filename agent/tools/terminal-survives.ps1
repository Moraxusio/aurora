# Builds two agent versions and the probe, then runs terminal-survives.sh as
# root in WSL (a real install, removed at the end).
#   powershell -File agent\tools\terminal-survives.ps1 [-Distro Ubuntu-24.04]
param([string]$Distro = 'Ubuntu-24.04')
$ErrorActionPreference = 'Stop'
$agent = Split-Path -Parent $PSScriptRoot
$go = 'go'
$out = Join-Path $env:LOCALAPPDATA 'Temp\aurora3\term-survive'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:CGO_ENABLED = '0'; $env:GOOS = 'linux'; $env:GOARCH = 'amd64'
Push-Location $agent
try {
    foreach ($v in '3.0.1', '3.0.2') {
        & $go build -trimpath -ldflags "-s -w -X main.Version=$v" -o "$out\aurora3-agent-$v" ./cmd/aurora3-agent
        if ($LASTEXITCODE) { throw "build $v" }
    }
    & $go build -trimpath -o "$out\aurora3-probe" ./cmd/aurora3-probe
} finally { Pop-Location; Remove-Item Env:GOOS, Env:GOARCH }
Copy-Item (Join-Path $PSScriptRoot 'terminal-survives.sh') $out
$wslOut = '/mnt/' + $out.Substring(0, 1).ToLower() + $out.Substring(2).Replace('\', '/')
wsl -d $Distro -u root -- bash "$wslOut/terminal-survives.sh" $wslOut
$code = $LASTEXITCODE
Remove-Item $out -Recurse -Force
exit $code
