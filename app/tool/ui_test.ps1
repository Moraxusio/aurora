# Runs integration_test/ui_test.dart on Windows against a real aurora3-agent
# in WSL (agent/tools/ui-agent.sh: normal user, /tmp, 127.0.0.1:17791).
#   powershell -File app\tool\ui_test.ps1 [-Distro Ubuntu-24.04]
param([string]$Distro = 'Ubuntu-24.04', [string]$Shots = '', [int]$TypingLines = 6, [switch]$TypingOnly)
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $app
$go = 'go'
$tmp = Join-Path $env:LOCALAPPDATA 'Temp\aurora3\ui-test'
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
try {
    $line = $agent.StandardOutput.ReadLine()
    if (-not $line -or -not $line.StartsWith('{')) { throw "agent did not start: $line" }
    $ep = $line | ConvertFrom-Json
    Push-Location $app
    try {
        # Plain values: PowerShell strips the quotes of a JSON argument.
        $defs = @("--dart-define=AURORA3_UI_ADDR=$($ep.addr)", "--dart-define=AURORA3_UI_PIN=$($ep.pin)", "--dart-define=AURORA3_UI_TOKEN=$($ep.token)",
            "--dart-define=AURORA3_UI_SENDKEYS=$(Join-Path $PSScriptRoot 'sendkeys.ps1')", "--dart-define=AURORA3_UI_TYPING_LINES=$TypingLines", "--dart-define=AURORA3_UI_STOP_AFTER_TYPING=$($TypingOnly.IsPresent.ToString().ToLower())")
        if ($Shots) { New-Item -ItemType Directory -Force $Shots | Out-Null; $defs += "--dart-define=AURORA3_UI_SHOTS=$Shots" }
        & flutter test integration_test\ui_test.dart -d windows @defs
        $code = $LASTEXITCODE
    } finally { Pop-Location }
} finally {
    $agent.StandardInput.Close()
    if (-not $agent.WaitForExit(15000)) { $agent.Kill() }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
