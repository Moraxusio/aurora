# Makes the release fixture for test/manifest_test.dart: builds signed by Go's
# aurora3-release with a throwaway key, plus spoiled copies.
#   powershell -File tool\fixture.ps1 -Out DIR
param([Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$go = 'go'
$agent = Join-Path $PSScriptRoot '..\..\..\..\agent' | Resolve-Path
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:CGO_ENABLED = '0'
if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
New-Item -ItemType Directory -Force $Out | Out-Null
$rel = Join-Path $Out 'aurora3-release.exe'
Push-Location $agent
try { & $go build -o $rel ./cmd/aurora3-release; if ($LASTEXITCODE) { throw 'build' } } finally { Pop-Location }

function NewKey($path) {
    # A throwaway ed25519 key (base64 private key to $path; returns the public
    # key). Windows PowerShell has no ed25519, so a small Go program makes it.
    $src = Join-Path $Out 'keygen.go'
    Set-Content -Encoding ascii $src @'
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
    $pub = & $go run $src $path
    Remove-Item $src
    return $pub
}

$key = Join-Path $Out 'test.key'
$pub = NewKey $key
Set-Content -Encoding ascii (Join-Path $Out 'trust.pub') $pub
$other = Join-Path $Out 'other.key'
$null = NewKey $other
$bin = Join-Path $Out 'agent.bin'
[IO.File]::WriteAllBytes($bin, [Text.Encoding]::ASCII.GetBytes('aurora3-agent test build bytes'))

function Sign($k, $dir, $product = 'aurora3-agent') {
    & $rel sign --key $k --product $product --version 3.0.1 --arch amd64 --file $bin --out (Join-Path $Out $dir) | Out-Null
    if ($LASTEXITCODE) { throw "sign $dir" }
}
function Flip($path, $at) {
    $b = [IO.File]::ReadAllBytes($path); $b[$at] = $b[$at] -bxor 1; [IO.File]::WriteAllBytes($path, $b)
}

Sign $key 'good'
foreach ($d in 'flipped-build', 'flipped-manifest', 'flipped-sig', 'missing-build') { Sign $key $d }
$f = 'aurora3-agent-3.0.1-linux-amd64'
Flip (Join-Path $Out "flipped-build\$f") 3
Flip (Join-Path $Out 'flipped-manifest\manifest.json') 15
Flip (Join-Path $Out 'flipped-sig\manifest.sig') 4
Remove-Item (Join-Path $Out "missing-build\$f")
Sign $key 'v2-product' 'aurora-agent'
Sign $other 'other-key'
Remove-Item $key, $other, $bin, $rel
Get-ChildItem $Out -Directory | ForEach-Object { $_.Name }
