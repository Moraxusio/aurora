$ErrorActionPreference = 'Stop'
$env:PATH = 'C:\dev\VPS\go\go\bin;C:\dev\VPS\tools\nasm-3.02;C:\dev\VPS\flutter\bin;C:\dev\VPS\flutter\bin\cache\dart-sdk\bin;' + $env:PATH
$env:AURORA_NASM = 'C:\dev\VPS\tools\nasm-3.02\nasm.exe'
$env:GOTOOLCHAIN = 'local'
$env:GOPROXY = 'off'
$env:AURORA_RELEASE_KEY = 'C:\dev\VPS\keys\aurora-v3-release.key'
& 'C:\build\aurora\tools\package-preview.ps1' -Version 3.24.0 -Suffix workbench-preview1 -Out 'C:\dev\VPS\preview5' *> "$PSScriptRoot\build.log"
& "$PSScriptRoot\check-package.ps1" *> "$PSScriptRoot\verification.log"
Get-Content "$PSScriptRoot\build.log" -Tail 5
Get-Content "$PSScriptRoot\verification.log" -Tail 20
