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

# The agent must carry its tmux: check the bundle against tools/tmux/bundle.lock
# before any agent is built (same rule as v2, D-20).
$bundleDir = Join-Path $root 'internal\bundle'
$lockFile = Join-Path $root 'tools\tmux\bundle.lock'
if (-not (Test-Path (Join-Path $bundleDir 'tmux.gz'))) { throw 'internal/bundle/tmux.gz missing: run tools/tmux/build.ps1 -BuildHost <linux host with docker>' }
$want = @{}
foreach ($l in Get-Content $lockFile) { if ($l -notmatch '^\s*#' -and $l.Trim()) { $p = $l -split '\s+'; $want[$p[1]] = $p[0] } }
$gzIn = [IO.File]::OpenRead((Join-Path $bundleDir 'tmux.gz'))
$ms = New-Object IO.MemoryStream
try {
    $gzs = New-Object IO.Compression.GZipStream($gzIn, [IO.Compression.CompressionMode]::Decompress)
    $gzs.CopyTo($ms); $gzs.Close()
} catch {
    throw "internal/bundle/tmux.gz is not a valid gzip stream (rebuild it with tools/tmux/build.ps1): $($_.Exception.Message)"
} finally {
    $gzIn.Close()
}
$sha = [Security.Cryptography.SHA256]::Create()
$gotTmux = ([BitConverter]::ToString($sha.ComputeHash($ms.ToArray())) -replace '-', '').ToLower()
$gotTi = (Get-FileHash (Join-Path $bundleDir 'terminfo.tar.gz') -Algorithm SHA256).Hash.ToLower()
if ($gotTmux -ne $want['tmux'] -or $gotTi -ne $want['terminfo.tar.gz']) { throw "tmux bundle does not match tools/tmux/bundle.lock (tmux $gotTmux, terminfo $gotTi)" }
"tmux bundle matches tools/tmux/bundle.lock"

Invoke-Build 'aurora-agent-linux-amd64' './cmd/aurora-agent' 'linux' 'amd64'
Invoke-Build 'aurora-agent-linux-arm64' './cmd/aurora-agent' 'linux' 'arm64'
Invoke-Build 'aurora-client.exe' './cmd/aurora-client' 'windows' 'amd64'
