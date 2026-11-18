$ErrorActionPreference = 'Stop'
$repo = 'C:\build\aurora'
$package = 'C:\dev\VPS\preview4\Aurora-3.23.0-ai-preview2'
$env:PATH = 'C:\dev\VPS\go\go\bin;C:\dev\VPS\tools\nasm-3.02;C:\dev\VPS\flutter\bin;C:\dev\VPS\flutter\bin\cache\dart-sdk\bin;' + $env:PATH
$env:AURORA_NASM = 'C:\dev\VPS\tools\nasm-3.02\nasm.exe'
$env:AURORA3_TRUST_KEY = $null
$env:AURORA3_LOCAL_AGENT_DIR = "$package\local-agent\windows-amd64"
& "$PSScriptRoot\verify-artifact.ps1" *> "$PSScriptRoot\artifact.txt"
& dart "--packages=$repo\app\.dart_tool\package_config.json" "$PSScriptRoot\verify-signatures.dart" $package *> "$PSScriptRoot\signatures.txt"
if ($LASTEXITCODE) { throw 'Production-key verification failed' }
$manifest = Get-Content "$package\agent\amd64\manifest.json" -Raw | ConvertFrom-Json
$linuxPath = "$package\agent\amd64\$($manifest.file)".Replace('\','/').Replace('C:','/mnt/c')
& wsl -d Ubuntu-24.04 --exec $linuxPath version *> "$PSScriptRoot\linux-version.txt"
if ($LASTEXITCODE -or (Get-Content "$PSScriptRoot\linux-version.txt" -Raw) -notmatch '3\.23\.0') { throw 'Linux agent version failed' }
Push-Location "$repo\app"
try {
    & dart run tool/ide_agent_smoke.dart "$PSScriptRoot\ide-fixture" 3.23.0 *> "$PSScriptRoot\ide-smoke.txt"
    if ($LASTEXITCODE) { Get-Content "$PSScriptRoot\ide-smoke.txt" -Tail 30; throw 'Packaged IDE smoke failed' }
    & dart run tool/ai_harness_smoke.dart "$PSScriptRoot\ai-fixture" *> "$PSScriptRoot\ai-smoke.txt"
    if ($LASTEXITCODE) { Get-Content "$PSScriptRoot\ai-smoke.txt" -Tail 30; throw 'Packaged AI smoke failed' }
} finally { Pop-Location }
& powershell -NoProfile -File "$PSScriptRoot\verify-launcher.ps1" -Package "$PSScriptRoot\extracted\Aurora-3.23.0-ai-preview2" *> "$PSScriptRoot\release-native.txt"
if ($LASTEXITCODE) { Get-Content "$PSScriptRoot\release-native.txt" -Tail 30; throw 'Release native check failed' }
Get-Content "$PSScriptRoot\signatures.txt"
Get-Content "$PSScriptRoot\linux-version.txt"
Get-Content "$PSScriptRoot\ide-smoke.txt" -Tail 8
Get-Content "$PSScriptRoot\ai-smoke.txt" -Tail 5
Get-Content "$PSScriptRoot\release-native.txt" -Tail 8
Write-Output 'AI_REDESIGN_FULL_CANDIDATE_VERIFIED'
