$ErrorActionPreference = 'Stop'
$env:PATH='C:\dev\VPS\go\go\bin;C:\dev\VPS\flutter\bin;C:\dev\VPS\flutter\bin\cache\dart-sdk\bin;C:\dev\VPS\tools\nasm-3.02;'+$env:PATH
$env:AURORA_NASM='C:\dev\VPS\tools\nasm-3.02\nasm.exe'
$env:FLUTTER_ROOT='C:\dev\VPS\flutter'
$root='C:\Users\finwe\AppData\Local\Temp\opencode\aurora-workbench-client'
$env:AURORA3_TESTPEER="$root\testpeer.exe"
$env:AURORA3_TESTNODE="$root\testnode.exe"
$env:AURORA3_RELEASE_FIXTURE="$root\release-fixture"
$env:AURORA3_UPGRADE_FIXTURE="$root\upgrade-fixture2"
$env:AURORA_UI_SHOTS="$root\shots-final4"
$env:AURORA_SHOTS="$root\shots-extra4"
Push-Location 'C:\build\aurora\app'
try {
    flutter analyze --no-pub --no-fatal-infos *> "$root\analyze-final4.log"
    if ($LASTEXITCODE) { Get-Content "$root\analyze-final4.log" -Tail 30; throw 'Analysis failed' }
    dart tool/ui_contract.dart *> "$root\ui-contract-final4.log"
    if ($LASTEXITCODE) { Get-Content "$root\ui-contract-final4.log"; throw 'GUI contract failed' }
    flutter test --no-pub --reporter expanded *> "$root\flutter-all4.log"
    if ($LASTEXITCODE) { Get-Content "$root\flutter-all4.log" -Tail 75; throw 'Full client regression failed' }
    Get-Content "$root\flutter-all4.log" -Tail 5
} finally { Pop-Location }
Write-Output 'WORKBENCH_FINAL_CLIENT_PASSED'
