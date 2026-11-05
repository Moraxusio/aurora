# Builds the v3 agent for linux/amd64 and linux/arm64 and the Windows client.
# Output goes to dist\. Every build is static (CGO disabled).
param(
    [string]$Version = '3.0.0-dev'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

$go = if (Get-Command go -ErrorAction SilentlyContinue) { 'go' } else { 'go' }
$env:GOTOOLCHAIN = 'local'
$env:CGO_ENABLED = '0'
$ldflags = "-s -w -X main.Version=$Version"

New-Item -ItemType Directory -Force dist | Out-Null

function Invoke-Build([string]$out, [string]$pkg, [string]$goos, [string]$goarch) {
    $env:GOOS = $goos
    $env:GOARCH = $goarch
    try {
        & $go build -trimpath -ldflags $ldflags -o (Join-Path $root "dist\$out") $pkg
        if ($LASTEXITCODE -ne 0) { throw "build failed: $out" }
    } finally {
        Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue
    }
    "built dist\$out"
}

Invoke-Build 'aurora-agent-linux-amd64' './cmd/aurora-agent' 'linux' 'amd64'
Invoke-Build 'aurora-agent-linux-arm64' './cmd/aurora-agent' 'linux' 'arm64'
Invoke-Build 'aurora-client.exe' './cmd/aurora-client' 'windows' 'amd64'
