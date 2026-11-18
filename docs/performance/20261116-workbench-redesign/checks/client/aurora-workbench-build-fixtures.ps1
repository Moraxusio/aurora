$ErrorActionPreference = 'Stop'
$env:PATH = 'C:\dev\VPS\go\go\bin;' + $env:PATH
$env:GOTOOLCHAIN = 'local'
$env:GOPROXY = 'off'
$root = 'C:\Users\finwe\AppData\Local\Temp\opencode\aurora-workbench-client'
if (-not (Test-Path "$root\release-fixture")) {
    & 'C:\build\aurora\app\packages\aurora_install\tool\fixture.ps1' -Out "$root\release-fixture"
}
$upgrade = "$root\upgrade-fixture2"
if (Test-Path $upgrade) { throw 'Upgrade fixture exists' }
New-Item -ItemType Directory -Path $upgrade | Out-Null
go run "$PSScriptRoot\aurora-workbench-upgrade-keygen.go" $upgrade
if ($LASTEXITCODE) { throw 'Fixture key generation failed' }
Push-Location 'C:\build\aurora\agent'
try {
    go build -o "$upgrade\release.exe" ./cmd/aurora3-release
    if ($LASTEXITCODE) { throw 'Release helper failed' }
    $bin = "$upgrade\fixture.bin"
    [IO.File]::WriteAllText($bin, 'test-only signed upload content')
    & "$upgrade\release.exe" sign --key "$upgrade\fixture.key" --version 3.3.1 --arch amd64 --file $bin --out "$upgrade\3.3.1"
    if ($LASTEXITCODE) { throw 'Fixture build signing failed' }
    foreach ($name in @('normal','revoke-current')) {
        $revoked = @()
        if ($name -eq 'revoke-current') { $revoked = @('3.3.1') }
        @{min_ok='3.3.0';revoked=$revoked} | ConvertTo-Json | Set-Content "$upgrade\input.json" -Encoding utf8NoBOM
        & "$upgrade\release.exe" policy --key "$upgrade\fixture.key" --input "$upgrade\input.json" --out "$upgrade\$name"
        if ($LASTEXITCODE) { throw 'Fixture policy signing failed' }
        Copy-Item "$upgrade\$name\policy.json" "$upgrade\$name.json"
        Copy-Item "$upgrade\$name\policy.sig" "$upgrade\$name.sig"
    }
} finally {
    Pop-Location
    Remove-Item "$upgrade\fixture.key" -ErrorAction SilentlyContinue
}
Write-Output 'FRESH_RELEASE_AND_UPGRADE_FIXTURES_READY'
