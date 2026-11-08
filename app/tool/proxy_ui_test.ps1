# Runs the real proxy page window test. WARNING: this opens a Windows Flutter
# window and takes keyboard focus, just like ui_test.ps1.
param([string]$Distro = 'Ubuntu-24.04', [string]$AgentFile = '', [string]$ExpectedVersion = '3.2.0', [string]$UpgradeFixture = '', [switch]$OldAgent)
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $app
$go = 'go'
$tmp = Join-Path $env:LOCALAPPDATA 'Temp\aurora3\proxy-ui-test'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:CGO_ENABLED = '0'; $env:GOOS = 'linux'; $env:GOARCH = 'amd64'
Push-Location (Join-Path $repo 'agent')
try {
    if ($AgentFile) {
        Copy-Item $AgentFile "$tmp\aurora3-agent"
    } else {
        & $go build -trimpath -ldflags '-s -w -X main.Version=3.2.0' -o "$tmp\aurora3-agent" ./cmd/aurora3-agent
        if ($LASTEXITCODE) { throw 'go build agent' }
    }
    Remove-Item Env:GOOS, Env:GOARCH
    & $go build -trimpath -o "$tmp\testnode.exe" ./cmd/aurora3-testnode
    if ($LASTEXITCODE) { throw 'go build testnode' }
} finally { Pop-Location; Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue }
Copy-Item (Join-Path $repo 'agent\tools\ui-agent.sh') $tmp
$wsl = '/mnt/' + $tmp.Substring(0, 1).ToLower() + $tmp.Substring(2).Replace('\', '/')

$node = $null; $agent = $null; $code = 1
try {
    $np = New-Object Diagnostics.ProcessStartInfo "$tmp\testnode.exe"
    $np.Arguments = '-secret ui-node-password-5d2c91'
    $np.RedirectStandardInput = $true; $np.RedirectStandardOutput = $true; $np.UseShellExecute = $false
    $node = [Diagnostics.Process]::Start($np)
    $nodePort = (($node.StandardOutput.ReadLine() | ConvertFrom-Json).port)

    $ap = New-Object Diagnostics.ProcessStartInfo 'wsl'
    $legacyFlag = if ($OldAgent) { '1' } else { '0' }
    # The proxy warning scenario needs one deliberately unmarked legacy
    # session even for a current agent. The old-agent switch is independent
    # from this fixture choice.
    $legacyFlag = '1'
    $ap.Arguments = "-d $Distro -- bash $wsl/ui-agent.sh $wsl/aurora3-agent 17796 /tmp/aurora3-proxy-ui-agent $legacyFlag"
    $ap.RedirectStandardInput = $true; $ap.RedirectStandardOutput = $true; $ap.UseShellExecute = $false
    $agent = [Diagnostics.Process]::Start($ap)
    $line = $agent.StandardOutput.ReadLine()
    if (-not $line -or -not $line.StartsWith('{')) { throw "agent did not start: $line" }
    $ep = $line | ConvertFrom-Json

    Push-Location $app
    try {
        if ($UpgradeFixture) {
            $fixtureCopy = Join-Path $tmp 'upgrade-fixture'
            Copy-Item $UpgradeFixture $fixtureCopy -Recurse
            Copy-Item (Join-Path $fixtureCopy 'normal.json') (Join-Path $fixtureCopy 'policy.json')
            Copy-Item (Join-Path $fixtureCopy 'normal.sig') (Join-Path $fixtureCopy 'policy.sig')
            $env:AURORA3_AGENT_DIR = $fixtureCopy
            $env:AURORA3_TRUST_KEY = (Get-Content (Join-Path $fixtureCopy 'trust.pub') -Raw).Trim()
        }
        $defs = @("--dart-define=AURORA3_PROXY_UI_ADDR=$($ep.addr)", "--dart-define=AURORA3_PROXY_UI_PIN=$($ep.pin)", "--dart-define=AURORA3_PROXY_UI_TOKEN=$($ep.token)", "--dart-define=AURORA3_PROXY_UI_NODE_PORT=$nodePort", "--dart-define=AURORA3_PROXY_UI_VERSION=$ExpectedVersion")
        if ($UpgradeFixture) { $defs += "--dart-define=AURORA3_PROXY_UI_UPGRADE=1" }
        if ($OldAgent) { $defs += "--dart-define=AURORA3_PROXY_UI_OLD_AGENT=true" }
        & flutter test integration_test\proxy_ui_test.dart -d windows @defs
        $code = $LASTEXITCODE
    } finally { Pop-Location }
} finally {
    if ($agent) { $agent.StandardInput.Close(); if (-not $agent.WaitForExit(15000)) { $agent.Kill() } }
    if ($node) { $node.StandardInput.Close(); if (-not $node.WaitForExit(5000)) { $node.Kill() } }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
