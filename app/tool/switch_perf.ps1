# Measures how long switching between side bars and editor tabs takes, on the
# real window against a real aurora3-agent in WSL (agent/tools/ui-agent.sh).
# Prints one "PERF ..." line per switch.
#
# `flutter test` has no profile or release mode: the app runs as a DEBUG build
# (JIT, assertions), several times slower than what a user runs. The absolute
# numbers are therefore not what a user sees. Use them only against each other:
# the same test before and after a change. `-Out` writes the results as JSON
# (the file says debug), for that comparison.
#   powershell -File app\tool\switch_perf.ps1 [-Out file.json]
param([string]$Distro = 'Ubuntu-24.04', [string]$Out = '')
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $app
$go = 'go'
$tmp = Join-Path $env:LOCALAPPDATA 'Temp\aurora3\perf'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:CGO_ENABLED = '0'; $env:GOOS = 'linux'; $env:GOARCH = 'amd64'
Push-Location (Join-Path $repo 'agent')
try {
    & $go build -trimpath -ldflags '-s -w -X main.Version=3.0.1' -o "$tmp\aurora3-agent" ./cmd/aurora3-agent
    if ($LASTEXITCODE) { throw 'go build' }
} finally { Pop-Location; Remove-Item Env:GOOS, Env:GOARCH }
Copy-Item (Join-Path $repo 'agent\tools\ui-agent.sh') $tmp
$wsl = '/mnt/' + $tmp.Substring(0, 1).ToLower() + $tmp.Substring(2).Replace('\', '/')

$psi = New-Object Diagnostics.ProcessStartInfo 'wsl'
$psi.Arguments = "-d $Distro -- bash $wsl/ui-agent.sh $wsl/aurora3-agent"
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
$agent = [Diagnostics.Process]::Start($psi)
$code = 1
try {
    $line = $agent.StandardOutput.ReadLine()
    if (-not $line -or -not $line.StartsWith('{')) { throw "agent did not start: $line" }
    $ep = $line | ConvertFrom-Json
    Push-Location $app
    try {
        $defs = @("--dart-define=AURORA3_UI_ADDR=$($ep.addr)", "--dart-define=AURORA3_UI_PIN=$($ep.pin)", "--dart-define=AURORA3_UI_TOKEN=$($ep.token)")
        if ($Out) { $defs += "--dart-define=AURORA3_PERF_OUT=$Out" }
        $text = & flutter test integration_test\switch_perf_test.dart -d windows @defs 2>&1 | Out-String
        $code = $LASTEXITCODE
        ($text -split "`n") | Where-Object { $_ -match '^\s*PERF |tests passed|Some tests|EXCEPTION|Error:|not found within' } | ForEach-Object { $_.TrimEnd() }
        'build mode: debug (flutter test has no other); compare only with another run of this script'
    } finally { Pop-Location }
} finally {
    $agent.StandardInput.Close()
    if (-not $agent.WaitForExit(15000)) { $agent.Kill() }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
