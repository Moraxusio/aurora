$ErrorActionPreference = 'Stop'
$env:PATH='C:\dev\VPS\go\go\bin;C:\dev\VPS\flutter\bin;C:\dev\VPS\flutter\bin\cache\dart-sdk\bin;C:\dev\VPS\tools\nasm-3.02;'+$env:PATH
$env:AURORA_NASM='C:\dev\VPS\tools\nasm-3.02\nasm.exe'
$env:FLUTTER_ROOT='C:\dev\VPS\flutter'
foreach ($suite in @('interaction','foundation')) {
    & powershell -NoProfile -File 'C:\build\aurora\app\tool\gui_audit.ps1' -Suite $suite -Out "$PSScriptRoot\aurora-workbench-native-$suite" *> "$PSScriptRoot\aurora-workbench-native-$suite.log"
    if ($LASTEXITCODE) {
        Get-Content "$PSScriptRoot\aurora-workbench-native-$suite.log" -Tail 45
        throw "Native $suite failed"
    }
    Get-Content "$PSScriptRoot\aurora-workbench-native-$suite.log" -Tail 12
}
Write-Output 'WORKBENCH_NATIVE_INTERACTION_AND_FOUNDATION_PASSED'
