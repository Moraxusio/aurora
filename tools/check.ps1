# Reproducible source validation. Requires the documented Go/Flutter/NASM PATH.
param([switch]$Native, [string]$NativeOut)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'check-docs.ps1')
Push-Location (Join-Path $repo 'agent')
try {
    & go test ./... -count=1 -timeout=180s
    if ($LASTEXITCODE) { throw 'Agent tests failed' }
    & go vet ./...
    if ($LASTEXITCODE) { throw 'Agent vet failed' }
    & go build ./...
    if ($LASTEXITCODE) { throw 'Agent build failed' }
} finally { Pop-Location }
Push-Location (Join-Path $repo 'app')
try {
    & dart tool/ui_contract.dart
    if ($LASTEXITCODE) { throw 'GUI contract failed' }
    & flutter analyze --no-pub --no-fatal-infos
    if ($LASTEXITCODE) { throw 'Client analysis failed' }
    & flutter test --no-pub --reporter expanded
    if ($LASTEXITCODE) { throw 'Client tests failed' }
    foreach ($package in @('aurora_profile','aurora_wire','aurora_install','aurora_sub')) {
        Push-Location (Join-Path 'packages' $package)
        try {
            & dart test --reporter expanded
            if ($LASTEXITCODE) { throw "$package tests failed" }
        } finally { Pop-Location }
    }
    if ($Native) {
        $options = @{Suite='foundation'}
        if ($NativeOut) { $options.Out = $NativeOut }
        & (Join-Path $repo 'app\tool\gui_audit.ps1') @options
    }
} finally { Pop-Location }
