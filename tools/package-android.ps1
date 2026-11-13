# Builds the Android APKs with the signed agent inside (assets/agent/), so the
# phone can install the agent over SSH like the Windows client does.
#   -AgentDir  a signed agent directory from tools\package.ps1 (amd64\, policy.json, policy.sig)
#   -Out       where the APKs and SHA256SUMS.txt go
# The release keystore stays outside the repository:
#   AURORA_ANDROID_KEYSTORE, AURORA_ANDROID_STORE_PASS (and AURORA_ANDROID_KEY_ALIAS, default aurora3)
#
# One version for every client: -Version is the same MAJOR.MINOR.PATCH that
# tools\package.ps1 gets for Windows. Android's versionCode is derived from it
# (MAJOR*10000 + MINOR*100 + PATCH), so a newer version always installs over an
# older one and the two clients can never disagree. -AgentDir defaults to the
# agent inside the Windows package of the same version in -Out, so both ship the
# same signed agent.
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$AgentDir,
  [Parameter(Mandatory = $true)][string]$Out
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw "version must be MAJOR.MINOR.PATCH: $Version" }
$p = $Version.Split('.')
if ([int]$p[1] -gt 99 -or [int]$p[2] -gt 99) { throw 'MINOR and PATCH must be 0-99 for the Android version code' }
$BuildNumber = [int]$p[0] * 10000 + [int]$p[1] * 100 + [int]$p[2]
if (-not $AgentDir) { $AgentDir = Join-Path $Out "Aurora-$Version\agent" }
$repo = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $repo 'app\assets\agent'
# Apache-2.0 asks for the licence text and the NOTICE with every copy; the
# third-party list comes from the Windows package of the same version.
$legal = Join-Path $repo 'app\assets\legal'
$windowsDir = Join-Path $Out "Aurora-$Version"
if (-not (Test-Path (Join-Path $windowsDir 'LICENSES.txt'))) { throw "no LICENSES.txt in $windowsDir; build the Windows package of this version first" }
if (-not (Test-Path (Join-Path $AgentDir 'amd64\manifest.sig'))) { throw "no signed agent in $AgentDir" }
$agentVersion = (Get-Content (Join-Path $AgentDir 'amd64\manifest.json') -Raw | ConvertFrom-Json).version
if ($agentVersion -ne $Version) { throw "the agent in ${AgentDir} is ${agentVersion}, not ${Version}; build the Windows package of this version first" }
# Never overwrite a previously built APK or append duplicate checksum entries.
foreach ($name in @("Aurora-$Version-android-arm64-v8a.apk", "Aurora-$Version-android-armeabi-v7a.apk", "Aurora-$Version-android-x86_64.apk", 'SHA256SUMS.txt')) {
  if (Test-Path -LiteralPath (Join-Path $Out $name)) { throw "$(Join-Path $Out $name) exists; use a fresh output directory" }
}
function Clear-Agent {
  Get-ChildItem $dest -Recurse -File | Where-Object { $_.Name -ne '.gitkeep' } | Remove-Item -Force
  Get-ChildItem $legal -File | Where-Object { $_.Name -ne '.gitkeep' } | Remove-Item -Force
}
Clear-Agent
Copy-Item (Join-Path $AgentDir 'policy.json'), (Join-Path $AgentDir 'policy.sig') $dest
Copy-Item (Join-Path $AgentDir 'amd64\*') (Join-Path $dest 'amd64')
Copy-Item (Join-Path $repo 'LICENSE'), (Join-Path $repo 'NOTICE'), (Join-Path $windowsDir 'LICENSES.txt') $legal
try {
  Push-Location (Join-Path $repo 'app')
  & flutter build apk --release --split-per-abi --build-name $Version --build-number $BuildNumber
  if ($LASTEXITCODE) { throw 'flutter build apk' }
  New-Item -ItemType Directory -Force $Out | Out-Null
  $shaApk = [Security.Cryptography.SHA256]::Create()
  foreach ($a in 'arm64-v8a', 'armeabi-v7a', 'x86_64') {
    $n = "Aurora-$Version-android-$a.apk"
    $apkOut = Join-Path $Out $n
    Copy-Item "build\app\outputs\flutter-apk\app-$a-release.apk" $apkOut
    $fsApk = [IO.File]::OpenRead($apkOut)
    $apkHash = -join ($shaApk.ComputeHash($fsApk) | ForEach-Object { $_.ToString('x2') })
    $fsApk.Close()
    "$apkHash  $n" | Add-Content (Join-Path $Out 'SHA256SUMS.txt')
  }
} finally {
  Pop-Location
  Clear-Agent
}
