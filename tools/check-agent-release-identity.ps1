# Call after production signature/hash verification. Reserve each identity
# before producing a distributable, even if the client build fails later.
param(
    [Parameter(Mandatory)][string[]]$ManifestPaths,
    [string]$Ledger = $env:AURORA_AGENT_RELEASE_LEDGER
)
$ErrorActionPreference = 'Stop'
if (-not $Ledger) { $Ledger = Join-Path $env:LOCALAPPDATA 'AuroraRelease\agent-identities' }
$Ledger = [IO.Path]::GetFullPath($Ledger)
$known = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'agent-release-seeds.json') -Raw | ConvertFrom-Json
[IO.Directory]::CreateDirectory($Ledger) | Out-Null
$lock = [IO.File]::Open((Join-Path $Ledger '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $entries = [ordered]@{}
    foreach ($path in $ManifestPaths) {
        $m = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($m.version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
            $m.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
            -not (($m.product -ceq 'aurora3-agent' -and $m.file -cmatch "^aurora3-agent-$([regex]::Escape($m.version))-linux-(amd64|arm64)$") -or
                 ($m.product -ceq 'aurora3-local-agent' -and $m.file -ceq "aurora3-local-agent-$($m.version)-windows-amd64.exe"))) {
            throw "Invalid agent release identity: $path"
        }
        $id = $m.file
        $record = Join-Path $Ledger "$id.sha256"
        $seed = $known.PSObject.Properties[$id]
        if (($seed -and $seed.Value -cne $m.sha256) -or
            ([IO.File]::Exists($record) -and [IO.File]::ReadAllText($record).Trim() -cne $m.sha256) -or
            ($entries.Contains($record) -and $entries[$record] -cne $m.sha256)) {
            throw "Agent $id already has different bytes. Increment the agent version; do not replace the released identity."
        }
        $entries[$record] = $m.sha256
    }
    foreach ($entry in $entries.GetEnumerator()) {
        if ([IO.File]::Exists($entry.Key)) { continue }
        $temporary = "$($entry.Key).$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllText($temporary, "$($entry.Value)`n", [Text.Encoding]::ASCII)
        [IO.File]::Move($temporary, $entry.Key)
    }
    Write-Output "Agent release identities verified: $($entries.Count)"
} finally {
    $lock.Dispose()
}
