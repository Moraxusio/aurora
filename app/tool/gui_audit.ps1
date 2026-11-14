# Native Windows GUI audit with synthetic services/input and isolated settings.
# Fails on engine accessibility errors as well as Dart/test failures.
param([string]$Out = (Join-Path $env:LOCALAPPDATA ('Temp\aurora3\gui-audit-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [ValidateSet('interaction','foundation')][string]$Suite = 'interaction',
    [switch]$Baseline)
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$Out = [IO.Path]::GetFullPath($Out)
if (Test-Path $Out) { throw "Audit output already exists: $Out" }
New-Item -ItemType Directory -Path $Out | Out-Null
$sourceFiles = & git -C $app ls-files --cached --others --exclude-standard -- lib packages third_party windows assets pubspec.yaml pubspec.lock
if ($LASTEXITCODE) { throw 'Cannot enumerate audit sources' }
$sourceHashes = @{}
foreach ($file in ($sourceFiles | Sort-Object -Unique)) {
    $sourceHashes[$file] = (Get-FileHash -LiteralPath (Join-Path $app $file) -Algorithm SHA256).Hash
}
$sourceHashes | ConvertTo-Json | Set-Content -LiteralPath "$Out\source-hashes.json" -Encoding utf8
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
    $target = if ($Suite -eq 'foundation') { 'integration_test/gui_foundation_test.dart' } else { 'integration_test/gui_interaction_test.dart' }
    $budget = (-not $Baseline).ToString().ToLowerInvariant()
    # Flutter's driver writes connection notices to stderr. Windows PowerShell
    # turns those into NativeCommandError; only the process exit code decides.
    $ErrorActionPreference = 'Continue'
    try {
        & flutter drive --no-pub -d windows --profile "--target=$target" --driver=test_driver/workbench.dart "--dart-define=AURORA_REVIEW_OUT=$prefix" "--dart-define=AURORA_ENFORCE_BUDGET=$budget" *> "$Out\native.log"
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = 'Stop' }
    $log = [IO.File]::ReadAllText("$Out\native.log")
    [IO.File]::WriteAllText("$Out\native.log", $log, [Text.UTF8Encoding]::new($false))
    Get-Content "$Out\native.log" -Tail 35
    if ($code) { throw "Native GUI tests failed ($code): $Out\native.log" }
    foreach ($file in $sourceHashes.Keys) {
        if ((Get-FileHash -LiteralPath (Join-Path $app $file) -Algorithm SHA256).Hash -ne $sourceHashes[$file]) {
            throw "Source changed during native audit: $file"
        }
    }
    if (Select-String "$Out\native.log" -Pattern 'Failed to update ui::AXTree|EXCEPTION CAUGHT BY|Unhandled Exception|RenderFlex overflowed' -Quiet) {
        throw "Windows accessibility rejected a semantics update: $Out\native.log"
    }
    $result = Get-Content "$Out\gui.json" -Raw | ConvertFrom-Json
    $shot = if ($Suite -eq 'foundation') { "$Out\gui-loaded.png" } else { "$Out\gui.png" }
    if (-not $result.native_engine -or -not $result.dirty_buffer_retained -or $result.terminal_attaches -ne 1 -or -not (Test-Path $shot)) {
        throw 'Native GUI result is incomplete'
    }
    Write-Output "Native GUI and accessibility checks passed: $Out"
} finally {
    Pop-Location
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
