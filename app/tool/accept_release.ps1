# M1.7 acceptance: the release folder's own signed agent (no test key) is
# installed through the UI's wizard into WSL, used, and uninstalled.
# install_ui_test.dart runs the app code with AURORA3_AGENT_DIR pointing at
# the release folder's agent\ directory, and AURORA3_TRUST_KEY unset, so the
# real release key decides. The SSH side is agent/tools/ui-ssh.sh (root,
# every v3 name removed afterwards, v2 compared).
#   powershell -File app\tool\accept_release.ps1 -Release dist\Aurora-3.0.0
param([Parameter(Mandatory)][string]$Release, [string]$Distro = 'Ubuntu-24.04')
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $app
$go = 'go'
if (-not (Test-Path "$Release\agent\amd64\manifest.sig")) { throw "no signed agent in $Release" }
$tmp = Join-Path $env:LOCALAPPDATA 'Temp\aurora3\accept'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:CGO_ENABLED = '0'; $env:GOOS = 'linux'; $env:GOARCH = 'amd64'
Push-Location (Join-Path $repo 'agent')
try { & $go build -trimpath -o "$tmp\aurora3-sshpeer" ./cmd/aurora3-sshpeer; if ($LASTEXITCODE) { throw 'build sshpeer' } }
finally { Pop-Location; Remove-Item Env:GOOS, Env:GOARCH }
Copy-Item (Join-Path $repo 'agent\tools\ui-ssh.sh') $tmp
$wsl = '/mnt/' + $tmp.Substring(0, 1).ToLower() + $tmp.Substring(2).Replace('\', '/')
$psi = New-Object Diagnostics.ProcessStartInfo 'wsl'
$psi.Arguments = "-d $Distro -u root -- bash $wsl/ui-ssh.sh $wsl/aurora3-sshpeer"
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
$ssh = [Diagnostics.Process]::Start($psi)
$code = 1
try {
    $ep = $ssh.StandardOutput.ReadLine() | ConvertFrom-Json
    if ($ep.error) { throw "ssh side: $($ep.error)" }
    Push-Location $app
    try {
        Remove-Item Env:AURORA3_TRUST_KEY -ErrorAction SilentlyContinue
        $env:AURORA3_AGENT_DIR = "$Release\agent"
        & flutter test integration_test\install_ui_test.dart -d windows `
            "--dart-define=AURORA3_SSH_ADDR=$($ep.addr)" "--dart-define=AURORA3_SSH_HOSTKEY=$($ep.host_key)" "--dart-define=AURORA3_SSH_PASSWORD=$($ep.password)" `
            "--dart-define=AURORA3_EXPECT_VERSION=$((Get-Content "$Release\agent\amd64\manifest.json" -Raw | ConvertFrom-Json).version)"
        $code = $LASTEXITCODE
    } finally { Pop-Location; Remove-Item Env:AURORA3_AGENT_DIR -ErrorAction SilentlyContinue }
} finally {
    $ssh.StandardInput.Close()
    if (-not $ssh.WaitForExit(60000)) { $ssh.Kill() }
    $ssh.StandardError.ReadToEnd()
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
