# Builds the binaries for install-real.sh and runs it as root in a WSL
# distribution. Only v3 names are written there, and all are removed at the
# end (see install-real.sh).
#   powershell -File agent\tools\install-real.ps1 [-Distro Ubuntu-24.04]
param([string]$Distro = 'Ubuntu-24.04')
$ErrorActionPreference = 'Stop'
$agent = Split-Path -Parent $PSScriptRoot
$go = 'go'
$out = Join-Path $env:LOCALAPPDATA 'Temp\aurora3\install-real'
New-Item -ItemType Directory -Force $out | Out-Null
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:CGO_ENABLED = '0'; $env:GOOS = 'linux'; $env:GOARCH = 'amd64'
Push-Location $agent
try {
    foreach ($v in '3.0.1', '3.0.2', '3.0.4') {
        & $go build -trimpath -ldflags "-s -w -X main.Version=$v" -o "$out\aurora3-agent-$v" ./cmd/aurora3-agent
        if ($LASTEXITCODE) { throw "build $v" }
    }
    & $go build -trimpath -ldflags '-s -w -X main.Version=3.0.3' -o "$out\aurora3-agent-3.0.3" ./cmd/aurora3-brokenagent
    if ($LASTEXITCODE) { throw 'build broken' }
    & $go build -trimpath -o "$out\aurora3-probe" ./cmd/aurora3-probe
    if ($LASTEXITCODE) { throw 'build probe' }
} finally {
    Pop-Location
    Remove-Item Env:GOOS, Env:GOARCH
}
Copy-Item (Join-Path $PSScriptRoot 'install-real.sh') "$out\install-real.sh" -Force
$wslOut = '/mnt/' + $out.Substring(0, 1).ToLower() + $out.Substring(2).Replace('\', '/')
wsl -d $Distro -u root -- bash "$wslOut/install-real.sh" $wslOut
$code = $LASTEXITCODE
Remove-Item $out -Recurse -Force
exit $code
