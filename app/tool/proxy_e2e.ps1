# End to end, with real parts at every step and nothing of the node's side
# written from the agent's code:
#
#   a real aurora3-agent in WSL (as the normal user, under /tmp, port 17795:
#   not the installed agent)
#     <- the client's proxy model: reads a subscription served over HTTP,
#        asks the agent which nodes it can use, times one, chooses it
#   a terminal session created with proxy:true, in real tmux, real bash
#     -> `curl` run inside that session, and `git ls-remote` too
#     -> the agent's loopback proxy -> the node (aurora3-testnode, on Windows)
#   the node prints the destination of every tunnel; that is what is asserted.
#
# The destination is a name that exists nowhere (.invalid): the only way for
# the node to see it is for the traffic to have gone through the proxy.
#
#   powershell -File app\tool\proxy_e2e.ps1 [-Distro Ubuntu-24.04]
param([string]$Distro = 'Ubuntu-24.04')
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $app
$go = 'go'
$tmp = Join-Path $env:LOCALAPPDATA 'Temp\aurora3\proxy-e2e'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:CGO_ENABLED = '0'

Push-Location (Join-Path $repo 'agent')
try {
    $env:GOOS = 'linux'; $env:GOARCH = 'amd64'
    & $go build -trimpath -ldflags '-s -w -X main.Version=3.0.1' -o "$tmp\aurora3-agent" ./cmd/aurora3-agent
    if ($LASTEXITCODE) { throw 'go build agent' }
    Remove-Item Env:GOOS, Env:GOARCH
    & $go build -trimpath -o "$tmp\testnode.exe" ./cmd/aurora3-testnode
    if ($LASTEXITCODE) { throw 'go build testnode' }
} finally { Pop-Location; Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue }

# the e2e agent: like tools/ui-agent.sh but on its own port, and with no helper services
$sh = @'
#!/bin/bash
set -u
BIN=${1:?}
W=/tmp/aurora3-proxy-e2e
rm -rf "$W"; mkdir -p "$W/state" "$W/home"
cp "$BIN" "$W/aurora3-agent"; chmod 755 "$W/aurora3-agent"
TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
cat > "$W/agent.json" <<EOF
{"name":"wsl-proxy-e2e","listen":"127.0.0.1:17795","token":"$TOKEN","state_dir":"$W/state",
 "roots":[{"id":"home","label":"home","path":"$W/home"}],"audit_log":"$W/state/audit.log"}
EOF
chmod 600 "$W/agent.json"
"$W/aurora3-agent" run --config "$W/agent.json" 2>"$W/agent.log" &
AGENT=$!
cleanup() {
  kill $AGENT 2>/dev/null; wait $AGENT 2>/dev/null
  for b in "$W/state/bin/"tmux-*; do [ -x "$b" ] && "$b" -L aurora3 kill-server 2>/dev/null; done
  rm -rf "$W"
}
trap cleanup EXIT
for i in $(seq 50); do [ -f "$W/state/agent.crt" ] && ss -ltn 2>/dev/null | grep -q ':17795 ' && break; sleep 0.1; done
PIN=$(openssl x509 -in "$W/state/agent.crt" -outform der | sha256sum | cut -d' ' -f1)
echo "{\"addr\":\"127.0.0.1:17795\",\"pin\":\"$PIN\",\"token\":\"$TOKEN\"}"
cat >/dev/null
'@
[IO.File]::WriteAllText("$tmp\proxy-e2e-agent.sh", $sh.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
$wsl = '/mnt/' + $tmp.Substring(0, 1).ToLower() + $tmp.Substring(2).Replace('\', '/')

$node = $null; $agent = $null; $code = 1
try {
    # the node, on Windows
    $nodeLog = Join-Path $tmp 'node.log'
    $psi = New-Object Diagnostics.ProcessStartInfo "$tmp\testnode.exe"
    $psi.Arguments = "-secret e2e-node-password-5d2c91 -log `"$nodeLog`""
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $node = [Diagnostics.Process]::Start($psi)
    $nodePort = ($node.StandardOutput.ReadLine() | ConvertFrom-Json).port

    # the agent, in WSL
    $psi2 = New-Object Diagnostics.ProcessStartInfo 'wsl'
    $psi2.Arguments = "-d $Distro -- bash $wsl/proxy-e2e-agent.sh $wsl/aurora3-agent"
    $psi2.RedirectStandardInput = $true; $psi2.RedirectStandardOutput = $true; $psi2.UseShellExecute = $false
    $agent = [Diagnostics.Process]::Start($psi2)
    $line = $agent.StandardOutput.ReadLine()
    if (-not $line -or -not $line.StartsWith('{')) { throw "agent did not start: $line" }
    $ep = $line | ConvertFrom-Json

    Push-Location $app
    try {
        $defs = @("--dart-define=AURORA3_E2E_ADDR=$($ep.addr)", "--dart-define=AURORA3_E2E_PIN=$($ep.pin)", "--dart-define=AURORA3_E2E_TOKEN=$($ep.token)",
            "--dart-define=AURORA3_E2E_NODE_PORT=$nodePort", "--dart-define=AURORA3_E2E_NODE_LOG=$nodeLog", "--dart-define=AURORA3_E2E_NODE_PASS=e2e-node-password-5d2c91")
        # The first build of the native TLS library prints its compiler banner on stderr, which
        # PowerShell turns into errors. cmd merges the two streams into a file before PowerShell
        # sees either.
        $outFile = Join-Path $tmp 'flutter.out'
        $argLine = ($defs | ForEach-Object { '"' + $_ + '"' }) -join ' '
        cmd /c ('"flutter" test test\proxy_e2e_test.dart ' + $argLine + ' > "' + $outFile + '" 2>&1')
        $code = $LASTEXITCODE
        $text = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
        $lines = @($text -split "`n")
        $lines | Where-Object { $_ -match '^\s*\d\d:\d\d \+\d+|\[E\]|Expected|Actual|Which|All tests|Some tests|E2E' } | ForEach-Object { $_.TrimEnd() }
        "flutter test exit code: $code"
        if ($code -eq 0 -and ($text -match 'All tests skipped' -or $text -notmatch 'All tests passed')) { "FAIL: no test actually ran (skipped, or no pass line)"; $code = 1 }
        if ($code -ne 0) { "--- last lines of the output:"; $lines | Where-Object { $_.Trim() } | Select-Object -Last 25 | ForEach-Object { $_.TrimEnd() } }
    } finally { Pop-Location }
} finally {
    if ($agent) { $agent.StandardInput.Close(); if (-not $agent.WaitForExit(15000)) { $agent.Kill() } }
    if ($node) { $node.StandardInput.Close(); if (-not $node.WaitForExit(5000)) { $node.Kill() } }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
