param([string]$Work = (Join-Path $env:LOCALAPPDATA ('Temp\opencode\aurora-local-smoke-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (Test-Path -LiteralPath $Work) { throw 'Test sandbox already exists; refusing overwrite' }
New-Item -ItemType Directory -Path $Work | Out-Null
$oldKey = $env:AURORA3_TRUST_KEY
$oldDir = $env:AURORA3_LOCAL_AGENT_DIR
try {
  Push-Location (Join-Path $repo 'agent')
  try {
    & go run tools/localtest/keygen.go $Work
    if ($LASTEXITCODE) { throw 'fixture key generation failed' }
    & go build -ldflags '-H=windowsgui -X main.Version=3.99.0' -o "$Work\local.exe" ./cmd/aurora3-local-agent
    if ($LASTEXITCODE) { throw 'local agent build failed' }
    & go build -o "$Work\release.exe" ./cmd/aurora3-release
    if ($LASTEXITCODE) { throw 'release helper build failed' }
    & "$Work\release.exe" sign --key "$Work\fixture.key" --product aurora3-local-agent --os windows --arch amd64 --version 3.99.0 --file "$Work\local.exe" --out "$Work\signed"
    if ($LASTEXITCODE) { throw 'fixture sign failed' }
  } finally { Pop-Location }
  $env:AURORA3_TRUST_KEY = [IO.File]::ReadAllText("$Work\fixture.pub").Trim()
  $env:AURORA3_LOCAL_AGENT_DIR = "$Work\signed"
  Push-Location (Join-Path $repo 'app')
  try {
    & dart run tool/local_agent_smoke.dart "$Work\sandbox"
    if ($LASTEXITCODE) { throw 'headless client smoke failed' }
  } finally { Pop-Location }
} finally {
  $env:AURORA3_TRUST_KEY = $oldKey
  $env:AURORA3_LOCAL_AGENT_DIR = $oldDir
  if (Test-Path -LiteralPath "$Work\fixture.key") { Remove-Item -LiteralPath "$Work\fixture.key" -Force }
}
