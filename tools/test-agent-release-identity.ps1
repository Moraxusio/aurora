$ErrorActionPreference = 'Stop'
$base = Join-Path $env:LOCALAPPDATA 'Temp\opencode'
$temp = Join-Path $base ('aurora-release-identity-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$verify = Join-Path $PSScriptRoot 'check-agent-release-identity.ps1'
$manifest = Join-Path $temp 'manifest.json'
$ledger = Join-Path $temp 'ledger'
function Assert-Conflict {
    $refused = $false
    try {
        & $verify -Ledger $ledger -ManifestPaths $manifest
    } catch {
        if ($_.Exception.Message -notlike '*already has different bytes*') { throw }
        $refused = $true
    }
    if (-not $refused) { throw 'The existing version accepted changed bytes' }
}
try {
    $doc = @{ product = 'aurora3-agent'; version = '99.12.3'; file = 'aurora3-agent-99.12.3-linux-amd64'; sha256 = 'a' * 64 }
    $doc | ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding ascii
    & $verify -Ledger $ledger -ManifestPaths $manifest
    & $verify -Ledger $ledger -ManifestPaths $manifest
    $doc.sha256 = 'b' * 64
    $doc | ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding ascii
    Assert-Conflict
    $doc.version = '3.25.1'
    $doc.file = 'aurora3-agent-3.25.1-linux-amd64'
    $doc | ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding ascii
    Assert-Conflict
    Write-Output 'Agent identity ledger passed: identical rebuild and both conflict cases'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
