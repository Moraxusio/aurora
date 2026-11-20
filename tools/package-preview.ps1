# Complete candidate: fresh client and both signed agents, isolated launcher.
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Suffix = 'ide-preview1',
    [Parameter(Mandatory)][string]$Out,
    [string]$Key = $env:AURORA_RELEASE_KEY,
    [string]$NotesFile = '',
    [switch]$PublicPreview
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Suffix -notmatch '^[a-zA-Z0-9-]+$') { throw 'Invalid candidate name' }
$repo = Split-Path -Parent $PSScriptRoot
$name = "Aurora-$Version-$Suffix"
$Out = [IO.Path]::GetFullPath($Out)
$dir = Join-Path $Out $name
$zip = "$dir.zip"
if (-not $NotesFile) { $NotesFile = "docs/releases/$Version-$Suffix.md" }
foreach ($path in @($dir, $zip, "$zip.sha256")) {
    if (Test-Path -LiteralPath $path) { throw "Candidate already exists: $path" }
}
function Get-Sources {
    $files = & git -C $repo ls-files --cached --others --exclude-standard -- agent app/lib app/packages app/third_party app/windows app/assets app/tool app/test app/integration_test app/test_driver app/pubspec.yaml app/pubspec.lock app/AGENTS.md tools docs README.md AGENTS.md LICENSE NOTICE
    if ($LASTEXITCODE) { throw 'Cannot enumerate build inputs' }
    $hashes = [ordered]@{}
    foreach ($file in ($files | Sort-Object -Unique)) {
        $path = Join-Path $repo $file
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $hashes[$file] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return $hashes
}
& (Join-Path $PSScriptRoot 'check-docs.ps1')
$sources = Get-Sources
$stage = Join-Path $env:LOCALAPPDATA ('Temp\opencode\aurora-preview-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
& (Join-Path $PSScriptRoot 'package.ps1') -Version $Version -Out $stage -Key $Key -NotesFile $NotesFile -NoArchive -PublicPreview:$PublicPreview
$after = Get-Sources
if ($sources.Count -ne $after.Count) { throw 'Build inputs changed during compilation' }
foreach ($file in $sources.Keys) {
    if (-not $after.Contains($file) -or $sources[$file] -ne $after[$file]) { throw "Build input changed: $file" }
}
New-Item -ItemType Directory -Path $Out -Force | Out-Null
Move-Item -LiteralPath (Join-Path $stage "Aurora-$Version") -Destination $dir
@"
Aurora $Version — 完整验收候选（$Suffix），Windows x64

解压后双击“启动验收版.cmd”，再打开 docs\guides\acceptance.md 按步骤验收。
使用包内 review-data 的独立配置和独立实例；首次为空白配置。
项目文件仍是实际选择的文件。直接运行 aurora.exe 使用普通启动配置。

包含新编译并签名的 Windows 本地 agent 与 Linux amd64 agent，统一版本 $Version。
本地模式可直接打开项目；远程 agent 更新由用户选择。
本次功能与边界：CHANGES.md；完整文档入口：docs\README.md。
源码指纹：SOURCE-HASHES.json；构建记录：BUILD-INFO.json。
本包为本地候选，尚未对外发布。
许可证：LICENSE、NOTICE、LICENSES.txt，包含 OpenCode MIT 署名。
"@ | Set-Content -LiteralPath "$dir\README.txt" -Encoding utf8
@"
@echo off
setlocal
set "LOCALAPPDATA=%~dp0review-data\Local"
set "APPDATA=%~dp0review-data\Roaming"
set "USERPROFILE=%~dp0review-data\Home"
set "AURORA3_INSTANCE_SCOPE=$name"
set "AURORA3_TRUST_KEY="
set "AURORA3_AGENT_DIR=%~dp0agent"
set "AURORA3_LOCAL_AGENT_DIR=%~dp0local-agent\windows-amd64"
if not exist "%LOCALAPPDATA%" mkdir "%LOCALAPPDATA%"
if not exist "%APPDATA%" mkdir "%APPDATA%"
if not exist "%USERPROFILE%" mkdir "%USERPROFILE%"
start "" "%~dp0aurora.exe"
"@ | Set-Content -LiteralPath "$dir\启动验收版.cmd" -Encoding ascii
$sources | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$dir\SOURCE-HASHES.json" -Encoding utf8
$linux = Get-Content "$dir\agent\amd64\manifest.json" -Raw | ConvertFrom-Json
$local = Get-Content "$dir\local-agent\windows-amd64\manifest.json" -Raw | ConvertFrom-Json
[ordered]@{
    version = $Version
    candidate = $Suffix
    channel = $linux.channel
    built_at_utc = [DateTime]::UtcNow.ToString('o')
    source_head = (& git -C $repo rev-parse HEAD)
    source_working_tree = $(if (@(& git -C $repo status --porcelain).Count) { 'uncommitted working tree' } else { 'clean' })
    source_files_checked_before_and_after_build = $sources.Count
    source_deleted_files = @(& git -C $repo diff --name-only --diff-filter=D)
    client_aot_sha256 = (Get-FileHash -LiteralPath "$dir\data\app.so" -Algorithm SHA256).Hash.ToLowerInvariant()
    isolated_launcher = '启动验收版.cmd'
    agent_version = $Version
    linux_agent_sha256 = $linux.sha256
    local_agent_sha256 = $local.sha256
    signing_key_id = $linux.key_id
    document_entry = 'docs/README.md'
    acceptance_guide = 'docs/guides/acceptance.md'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$dir\BUILD-INFO.json" -Encoding utf8
Compress-Archive -LiteralPath $dir -DestinationPath $zip
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name.zip" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Output "Candidate: $dir"
Write-Output "ZIP: $zip"
Write-Output "SHA256: $hash"
