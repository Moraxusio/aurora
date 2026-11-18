$ErrorActionPreference = 'Stop'
$env:PATH='C:\dev\VPS\go\go\bin;C:\dev\VPS\flutter\bin;C:\dev\VPS\flutter\bin\cache\dart-sdk\bin;C:\dev\VPS\tools\nasm-3.02;'+$env:PATH
$env:AURORA_NASM='C:\dev\VPS\tools\nasm-3.02\nasm.exe'
$root='C:\Users\finwe\AppData\Local\Temp\opencode\aurora-workbench-client'
$env:AURORA3_TESTPEER="$root\testpeer.exe"
$env:AURORA3_TESTNODE="$root\testnode.exe"
foreach ($package in @('aurora_wire','aurora_sub')) {
    Push-Location "C:\build\aurora\app\packages\$package"
    try {
        dart test --reporter expanded *> "$root\$package-final3.log"
        if ($LASTEXITCODE) { Get-Content "$root\$package-final3.log" -Tail 50; throw "$package failed" }
        Get-Content "$root\$package-final3.log" -Tail 2
    } finally { Pop-Location }
}
Write-Output 'WORKBENCH_INTERNAL_PACKAGES_PASSED'
