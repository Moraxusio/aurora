# Native Windows GUI audit with synthetic services/input and isolated settings.
# Fails on engine accessibility errors as well as Dart/test failures.
param([string]$Out = (Join-Path $env:LOCALAPPDATA ('Temp\aurora3\gui-audit-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))))
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$Out = [IO.Path]::GetFullPath($Out)
if (Test-Path $Out) { throw "Audit output already exists: $Out" }
New-Item -ItemType Directory -Path $Out | Out-Null
$saved = @{}
foreach ($name in @('AURORA3_INSTANCE_SCOPE', 'LOCALAPPDATA', 'APPDATA', 'AURORA3_TRUST_KEY')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
Push-Location $app
try {
    $env:AURORA3_INSTANCE_SCOPE = 'gui-audit-' + [guid]::NewGuid().ToString('N')
    $env:LOCALAPPDATA = Join-Path $Out 'profile\Local'
    $env:APPDATA = Join-Path $Out 'profile\Roaming'
    $env:AURORA3_TRUST_KEY = $null
    New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA, $env:APPDATA | Out-Null
    $prefix = (Join-Path $Out 'gui').Replace('\', '/')
    & flutter drive --no-pub -d windows --profile --target=integration_test/gui_interaction_test.dart --driver=test_driver/workbench.dart "--dart-define=AURORA_REVIEW_OUT=$prefix" *> "$Out\native.log"
    $code = $LASTEXITCODE
    Get-Content "$Out\native.log" -Tail 35
    if ($code) { throw "Native GUI tests failed ($code): $Out\native.log" }
    if (Select-String "$Out\native.log" -Pattern 'Failed to update ui::AXTree' -Quiet) {
        throw "Windows accessibility rejected a semantics update: $Out\native.log"
    }
    $result = Get-Content "$Out\gui.json" -Raw | ConvertFrom-Json
    if (-not $result.native_engine -or -not $result.dirty_buffer_retained -or $result.terminal_attaches -ne 1 -or -not (Test-Path "$Out\gui.png")) {
        throw 'Native GUI result is incomplete'
    }
    Write-Output "Native GUI and accessibility checks passed: $Out"
} finally {
    Pop-Location
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
