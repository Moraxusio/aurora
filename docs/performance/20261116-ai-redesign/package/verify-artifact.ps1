param(
    [string]$Package = 'C:\dev\VPS\preview4\Aurora-3.23.0-ai-preview2',
    [string]$Repo = 'C:\build\aurora'
)
$ErrorActionPreference = 'Stop'
$zip = "$Package.zip"
$name = Split-Path -Leaf $Package
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ((Get-Content "$zip.sha256" -Raw).Trim() -ne "$hash  $name.zip") { throw 'ZIP sidecar mismatch' }
$build = Get-Content "$Package\BUILD-INFO.json" -Raw | ConvertFrom-Json
if ($build.version -ne '3.23.0' -or $build.candidate -ne 'ai-preview2' -or
    $build.source_working_tree -ne 'uncommitted working tree') { throw 'Candidate identity mismatch' }
if ((& git -C $Repo rev-parse HEAD) -ne $build.source_head) { throw 'Source HEAD changed' }
$sources = Get-Content "$Package\SOURCE-HASHES.json" -Raw | ConvertFrom-Json
$checked = 0
foreach ($entry in $sources.PSObject.Properties) {
    if ((Get-FileHash -LiteralPath (Join-Path $Repo $entry.Name)).Hash.ToLowerInvariant() -ne $entry.Value) {
        throw "Source fingerprint differs: $($entry.Name)"
    }
    $checked++
}
if ($checked -ne $build.source_files_checked_before_and_after_build) { throw 'Source count mismatch' }
$extract = Join-Path $PSScriptRoot 'extracted'
if (Test-Path $extract) { throw 'Extraction destination exists' }
Expand-Archive -LiteralPath $zip -DestinationPath $extract
$unpacked = Join-Path $extract $name
$files = [ordered]@{}
$actual = @(Get-ChildItem -LiteralPath $Package -Recurse -File -Force)
$copies = @(Get-ChildItem -LiteralPath $unpacked -Recurse -File -Force)
if ($actual.Count -ne $copies.Count) { throw 'ZIP file count mismatch' }
foreach ($file in $actual) {
    $relative = $file.FullName.Substring($Package.Length + 1).Replace('\', '/')
    if ($relative -match '(^|/)(review-data|\.git|\.dart_tool|aurora3-release)(/|\.|$)|\.(key|pdb)$') {
        throw "Unexpected package artifact: $relative"
    }
    $expected = (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    $copy = Get-Item -LiteralPath (Join-Path $unpacked $relative)
    if ($copy.Length -ne $file.Length -or (Get-FileHash -LiteralPath $copy.FullName).Hash.ToLowerInvariant() -ne $expected) {
        throw "Unpacked file mismatch: $relative"
    }
    $files[$relative] = [ordered]@{bytes=$file.Length;sha256=$expected}
}
$version = (Get-Item "$Package\aurora.exe").VersionInfo
if ($version.FileVersion -ne '3.23.0+32300') { throw 'Windows version mismatch' }
if ($files['data/app.so'].sha256 -ne $build.client_aot_sha256) { throw 'AOT hash mismatch' }
$licenses = [IO.File]::ReadAllText("$Package\LICENSES.txt")
foreach ($source in @('app\third_party\re_editor\LICENSE','app\third_party\xterm\LICENSE','agent\internal\ai\THIRD_PARTY_OPENCODE_LICENSE')) {
    if (-not $licenses.Contains([IO.File]::ReadAllText((Join-Path $Repo $source)).TrimEnd())) { throw "License mismatch: $source" }
}
& "$Repo\tools\check-docs.ps1" -Root $unpacked -Package
$agents = @()
foreach ($relative in @('agent/amd64','local-agent/windows-amd64')) {
    $manifest = Get-Content "$Package/$relative/manifest.json" -Raw | ConvertFrom-Json
    if ($manifest.version -ne '3.23.0' -or $manifest.key_id -ne '87828dfb18459372') { throw 'Agent identity mismatch' }
    $vcs = @(& go version -m (Join-Path "$Package/$relative" $manifest.file))
    if ($LASTEXITCODE -or -not ($vcs -match "vcs.revision=$($build.source_head)$") -or
        -not ($vcs -match 'vcs.modified=true$')) { throw 'Agent build metadata mismatch' }
    $agents += $manifest
}
$summary = [ordered]@{
    version='3.23.0'; candidate='ai-preview2'; source_head=$build.source_head
    source_working_tree=$build.source_working_tree; source_files_checked=$checked
    zip=$zip; zip_bytes=(Get-Item $zip).Length; zip_sha256=$hash
    zip_files_matching_directory=$files.Count; client_version=$version.FileVersion
    client_aot_sha256=$build.client_aot_sha256; agents=$agents
    licenses_verified=@('re_editor','xterm','OpenCode'); unpacked_directory=$unpacked
}
$summary | ConvertTo-Json -Depth 6 | Set-Content "$PSScriptRoot\artifact-summary.json" -Encoding utf8
$files | ConvertTo-Json -Depth 5 | Set-Content "$PSScriptRoot\artifact-files.json" -Encoding utf8
$summary | ConvertTo-Json -Depth 6
Write-Output 'CANDIDATE_SOURCE_VERSION_ZIP_LICENSES_OK'
