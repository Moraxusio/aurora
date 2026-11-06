# Runs integration_test/install_ui_test.dart: the add-server wizard against a
# real SSH server and a real install in WSL (agent/tools/ui-ssh.sh, as root;
# every v3 name is removed afterwards and v2 is compared). The agent build is
# signed with a throwaway key that this test run trusts, never the release
# key.
#   powershell -File app\tool\install_ui_test.ps1 [-Distro Ubuntu-24.04]
param([string]$Distro = 'Ubuntu-24.04')
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $app
$go = 'go'
$tmp = Join-Path $env:LOCALAPPDATA 'Temp\aurora3\install-ui'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force "$tmp\agent" | Out-Null
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:CGO_ENABLED = '0'
Push-Location (Join-Path $repo 'agent')
try {
    & $go build -o "$tmp\aurora3-release.exe" ./cmd/aurora3-release
    $env:GOOS = 'linux'; $env:GOARCH = 'amd64'
    & $go build -trimpath -ldflags '-s -w -X main.Version=3.0.1' -o "$tmp\agent.bin" ./cmd/aurora3-agent
    & $go build -trimpath -o "$tmp\aurora3-sshpeer" ./cmd/aurora3-sshpeer
    if ($LASTEXITCODE) { throw 'go build' }
} finally { Pop-Location; Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue }
$keygen = "$tmp\keygen.go"
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
$pub = (& $go run $keygen "$tmp\test.key").Trim()
& "$tmp\aurora3-release.exe" sign --key "$tmp\test.key" --version 3.0.1 --arch amd64 --file "$tmp\agent.bin" --out "$tmp\agent\amd64" | Out-Null
if ($LASTEXITCODE) { throw 'sign' }
Remove-Item "$tmp\test.key", $keygen, "$tmp\agent.bin", "$tmp\aurora3-release.exe"
Copy-Item (Join-Path $repo 'agent\tools\ui-ssh.sh') $tmp
$wsl = '/mnt/' + $tmp.Substring(0, 1).ToLower() + $tmp.Substring(2).Replace('\', '/')

$psi = New-Object Diagnostics.ProcessStartInfo 'wsl'
$psi.Arguments = "-d $Distro -u root -- bash $wsl/ui-ssh.sh $wsl/aurora3-sshpeer"
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
$ssh = [Diagnostics.Process]::Start($psi)
$code = 1
try {
    $line = $ssh.StandardOutput.ReadLine()
    $ep = $line | ConvertFrom-Json
    if ($ep.error) { throw "ssh side: $($ep.error)" }
    Push-Location $app
    try {
        $env:AURORA3_AGENT_DIR = "$tmp\agent"
        $env:AURORA3_TRUST_KEY = $pub
        & flutter test integration_test\install_ui_test.dart -d windows `
            "--dart-define=AURORA3_SSH_ADDR=$($ep.addr)" "--dart-define=AURORA3_SSH_HOSTKEY=$($ep.host_key)" "--dart-define=AURORA3_SSH_PASSWORD=$($ep.password)"
        $code = $LASTEXITCODE
    } finally { Pop-Location; Remove-Item Env:AURORA3_AGENT_DIR, Env:AURORA3_TRUST_KEY -ErrorAction SilentlyContinue }
} finally {
    $ssh.StandardInput.Close()
    if (-not $ssh.WaitForExit(60000)) { $ssh.Kill() }
    $ssh.StandardError.ReadToEnd()
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
