# Builds what install-e2e.sh needs (test/e2e/e2e.dart and the Go tools) and runs it as root in WSL, once with a
# root login and once with a normal user and password sudo.
#   powershell -File agent\tools\install-e2e.ps1 [-Distro Ubuntu-24.04]
param([string]$Distro = 'Ubuntu-24.04')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$agent = Join-Path $repo 'agent'
$pkg = Join-Path $repo 'app\packages\aurora_install'
$go = 'go'
$dart = 'dart'
$out = Join-Path $env:LOCALAPPDATA 'Temp\aurora3\install-e2e'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null

# Signed build: a throwaway key, never the release key.
& powershell -NoProfile -File (Join-Path $pkg 'tool\fixture.ps1') -Out "$out\fx" | Out-Null
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:CGO_ENABLED = '0'
Push-Location $agent
try {
    & $go build -o "$out\aurora3-release.exe" ./cmd/aurora3-release
    $env:GOOS = 'linux'; $env:GOARCH = 'amd64'
    & $go build -trimpath -ldflags '-s -w -X main.Version=3.0.1' -o "$out\agent.bin" ./cmd/aurora3-agent
    & $go build -trimpath -o "$out\aurora3-sshpeer" ./cmd/aurora3-sshpeer
    if ($LASTEXITCODE) { throw 'go build' }
} finally {
    Pop-Location
    Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue
}
# Re-sign the real agent with a fresh throwaway key; trust.pub is its public key.
$keygen = Join-Path $out 'keygen.go'
Set-Content -Encoding ascii $keygen @'
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
)

func main() {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	_ = os.WriteFile(os.Args[1], []byte(base64.StdEncoding.EncodeToString(priv)), 0o600)
	fmt.Print(base64.StdEncoding.EncodeToString(pub))
}
'@
$pub = & $go run $keygen "$out\test.key"
[IO.File]::WriteAllText("$out\trust.pub", $pub.Trim())
& "$out\aurora3-release.exe" sign --key "$out\test.key" --version 3.0.1 --arch amd64 --file "$out\agent.bin" --out "$out\release" | Out-Null
if ($LASTEXITCODE) { throw 'sign' }
Remove-Item "$out\test.key", $keygen, "$out\agent.bin", "$out\aurora3-release.exe", "$out\fx" -Recurse -Force

Push-Location $pkg
try {
    & $dart build cli -t test\e2e\e2e.dart --target-os linux --target-arch x64 -o "$out\dartbuild" | Select-String 'Generated'
    if ($LASTEXITCODE) { throw 'dart build' }
} finally { Pop-Location }
Copy-Item "$out\dartbuild\bundle\*" $out -Recurse
Remove-Item "$out\dartbuild" -Recurse -Force
Copy-Item (Join-Path $PSScriptRoot 'install-e2e.sh') $out

$wslOut = '/mnt/' + $out.Substring(0, 1).ToLower() + $out.Substring(2).Replace('\', '/')
$code = 0
foreach ($mode in '', '--sudo') {
    Write-Output "##### install-e2e $mode"
    wsl -d $Distro -u root -- bash "$wslOut/install-e2e.sh" $wslOut $mode
    if ($LASTEXITCODE) { $code = $LASTEXITCODE }
}
Remove-Item $out -Recurse -Force
exit $code
