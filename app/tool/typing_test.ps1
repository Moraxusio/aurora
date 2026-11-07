# Types into a bare terminal view (no agent, no network) on the real Windows
# keyboard path and checks every character reaches Terminal.onOutput.
#   powershell -File app\tool\typing_test.ps1 [-Lines 60] [-GapMs 15]
param([int]$Lines = 40, [int]$GapMs = 15)
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
Push-Location $app
try {
    & flutter test integration_test\typing_test.dart -d windows `
        "--dart-define=AURORA3_UI_SENDKEYS=$(Join-Path $PSScriptRoot 'sendkeys.ps1')" `
        "--dart-define=AURORA3_TYPING_LINES=$Lines" "--dart-define=AURORA3_TYPING_GAP_MS=$GapMs"
    exit $LASTEXITCODE
} finally { Pop-Location }