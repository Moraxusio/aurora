# Full client + agent candidate, with an isolated launcher. Never publishes.
param(
    [string]$Version = '3.21.4',
    [string]$Suffix = 'harness-preview1',
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][string]$Key
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Suffix -notmatch '^[a-zA-Z0-9-]+$') { throw 'Invalid candidate name' }
$repo = Split-Path -Parent $PSScriptRoot
$name = "Aurora-$Version-$Suffix"
$dir = Join-Path ([IO.Path]::GetFullPath($Out)) $name
$zip = "$dir.zip"
foreach ($path in @($dir, $zip, "$zip.sha256")) {
    if (Test-Path -LiteralPath $path) { throw "Candidate already exists: $path" }
}
function Get-Sources {
    $files = & git -C $repo ls-files --cached --others --exclude-standard -- agent app/lib app/packages app/third_party app/windows app/assets app/tool app/test app/integration_test app/test_driver app/pubspec.yaml app/pubspec.lock docs/AI_HARNESS.md tools/package.ps1 tools/package-harness-preview.ps1
    if ($LASTEXITCODE) { throw 'Cannot enumerate sources' }
    $hashes = [ordered]@{}
    foreach ($file in ($files | Sort-Object -Unique)) {
        $hashes[$file] = (Get-FileHash -LiteralPath (Join-Path $repo $file) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}
$sources = Get-Sources
$stage = Join-Path $env:LOCALAPPDATA ("Temp\opencode\aurora-harness-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
& (Join-Path $PSScriptRoot 'package.ps1') -Version $Version -Out $stage -Key $Key
if ($LASTEXITCODE) { throw 'Full candidate build failed' }
$after = Get-Sources
if ($sources.Count -ne $after.Count) { throw 'Sources changed during build' }
foreach ($file in $sources.Keys) {
    if ($sources[$file] -ne $after[$file]) { throw "Source changed during build: $file" }
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Move-Item -LiteralPath (Join-Path $stage "Aurora-$Version") -Destination $dir
Copy-Item -LiteralPath (Join-Path $repo 'docs\AI_HARNESS.md') -Destination $dir
@"
Aurora $Version — AI harness 验收版（$Suffix），Windows x64

双击“启动验收版.cmd”。本包使用 review-data 下的独立配置与独立实例。
包括本轮新编译并签名的 Windows 本地 agent 与 Linux amd64 agent。
打开本机文件夹即可验证工具；服务器更新仍需用户明确操作。

本轮：图片/PDF 工具读取、全局/逐模型能力、自由思考档位及映射、
多文件补丁、结构化询问、工具步骤恢复、统一四页设置与会话按钮。
完整语义和验证边界见 AI_HARNESS.md。

本包为本地候选，尚未发布。源代码：$repo（工作树）。
源码指纹：SOURCE-HASHES.json；构建记录：BUILD-INFO.json。
许可证：LICENSE、NOTICE、LICENSES.txt，保留 OpenCode MIT 署名。
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
[ordered]@{
    version = $Version
    candidate = $Suffix
    built_at_utc = [DateTime]::UtcNow.ToString('o')
    source_head = (& git -C $repo rev-parse HEAD)
    source_working_tree = 'uncommitted AI harness candidate'
    source_files_checked = $sources.Count
    client_aot_sha256 = (Get-FileHash -LiteralPath "$dir\data\app.so" -Algorithm SHA256).Hash.ToLowerInvariant()
    isolated_launcher = '启动验收版.cmd'
    agent_version = $Version
} | ConvertTo-Json | Set-Content -LiteralPath "$dir\BUILD-INFO.json" -Encoding utf8
Compress-Archive -LiteralPath $dir -DestinationPath $zip
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name.zip" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
Write-Output "Candidate: $zip"
Write-Output "SHA256: $hash"
