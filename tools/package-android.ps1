# Builds the Android APKs with the signed agent inside (assets/agent/), so the
# phone can install the agent over SSH like the Windows client does.
#   -AgentDir  a signed agent directory from tools\package.ps1 (amd64\, policy.json, policy.sig)
#   -Out       where the APKs and SHA256SUMS.txt go
# The release keystore stays outside the repository:
#   AURORA_ANDROID_KEYSTORE, AURORA_ANDROID_STORE_PASS (and AURORA_ANDROID_KEY_ALIAS, default aurora3)
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][int]$BuildNumber,
  [Parameter(Mandatory = $true)][string]$AgentDir,
  [Parameter(Mandatory = $true)][string]$Out
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $repo 'app\assets\agent'
if (-not (Test-Path (Join-Path $AgentDir 'amd64\manifest.sig'))) { throw "no signed agent in $AgentDir" }
function Clear-Agent { Get-ChildItem $dest -Recurse -File | Where-Object { $_.Name -ne '.gitkeep' } | Remove-Item -Force }
Clear-Agent
Copy-Item (Join-Path $AgentDir 'policy.json'), (Join-Path $AgentDir 'policy.sig') $dest
Copy-Item (Join-Path $AgentDir 'amd64\*') (Join-Path $dest 'amd64')
try {
  Push-Location (Join-Path $repo 'app')
  & flutter build apk --release --split-per-abi --build-name $Version --build-number $BuildNumber
  if ($LASTEXITCODE) { throw 'flutter build apk' }
  New-Item -ItemType Directory -Force $Out | Out-Null
  foreach ($a in 'arm64-v8a', 'armeabi-v7a', 'x86_64') {
    $n = "Aurora-$Version-android-$a.apk"
    Copy-Item "build\app\outputs\flutter-apk\app-$a-release.apk" (Join-Path $Out $n) -Force
    (Get-FileHash (Join-Path $Out $n) -Algorithm SHA256).Hash.ToLower() + '  ' + $n | Add-Content (Join-Path $Out 'SHA256SUMS.txt')
  }
} finally {
  Pop-Location
  Clear-Agent
}
