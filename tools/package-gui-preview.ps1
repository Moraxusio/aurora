# GUI-only candidate. Reuses a verified signed backend bundle when the agent
# protocol and production code are unchanged. Never writes to the base release.
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$BaseRelease,
    [Parameter(Mandatory)][string]$Out,
    [string]$Suffix = 'gui-preview1',
    [string]$NotesFile = 'GUI_FOUNDATION.md',
    [string]$Summary = '共享保活视口、监控独立快照、GPU 按需详情／惰性进程列表、局部重绘及本地 GUI 异常诊断。'
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Suffix -notmatch '^[a-zA-Z0-9-]+$') { throw 'Invalid candidate version/name' }
if ($NotesFile -notmatch '^[a-zA-Z0-9_-]+\.md$') { throw 'Invalid notes filename' }
$repo = Split-Path -Parent $PSScriptRoot
$BaseRelease = [IO.Path]::GetFullPath($BaseRelease)
$Out = [IO.Path]::GetFullPath($Out)
$name = "Aurora-$Version-$Suffix"
$dir = Join-Path $Out $name
$zip = "$dir.zip"
function Get-ClientSources {
    Push-Location $repo
    try {
        $files = & git ls-files --cached --others --exclude-standard -- app/lib app/packages app/third_party app/windows app/assets app/pubspec.yaml app/pubspec.lock
        if ($LASTEXITCODE) { throw 'Cannot enumerate client sources' }
        $result = @{}
        foreach ($file in ($files | Sort-Object -Unique)) {
            $result[$file] = (Get-FileHash -LiteralPath (Join-Path $repo $file) -Algorithm SHA256).Hash
        }
        return $result
    } finally { Pop-Location }
}
foreach ($path in @($dir, $zip, "$zip.sha256")) {
    if (Test-Path -LiteralPath $path) { throw "Candidate already exists: $path" }
}
foreach ($path in @('agent\amd64\manifest.json', 'local-agent\windows-amd64\manifest.json', 'LICENSES.txt', 'LICENSE', 'NOTICE')) {
    if (-not (Test-Path -LiteralPath (Join-Path $BaseRelease $path))) { throw "Missing base artifact: $path" }
}
Push-Location (Join-Path $repo 'agent')
try {
    & go run ./cmd/aurora3-release verify --dir "$BaseRelease\agent\amd64"
    if ($LASTEXITCODE) { throw 'Base agent signature verification failed' }
    & go run ./cmd/aurora3-release verify --product aurora3-local-agent --dir "$BaseRelease\local-agent\windows-amd64"
    if ($LASTEXITCODE) { throw 'Base local-agent signature verification failed' }
} finally { Pop-Location }
$parts = $Version.Split('.')
$build = [int]$parts[0] * 10000 + [int]$parts[1] * 100 + [int]$parts[2]
$sources = Get-ClientSources
Push-Location (Join-Path $repo 'app')
try {
    & flutter build windows --no-pub --release --target=lib/main.dart "--build-name=$Version" "--build-number=$build"
    if ($LASTEXITCODE) { throw 'Candidate Windows build failed' }
} finally { Pop-Location }
$after = Get-ClientSources
if ($after.Count -ne $sources.Count) { throw 'Client sources changed during build' }
foreach ($file in $sources.Keys) {
    if ($sources[$file] -ne $after[$file]) { throw "Client source changed during build: $file" }
}
New-Item -ItemType Directory -Path $dir | Out-Null
Copy-Item (Join-Path $repo 'app\build\windows\x64\runner\Release\*') $dir -Recurse
foreach ($path in @('agent','local-agent','LICENSES.txt','LICENSE','NOTICE')) {
    Copy-Item -LiteralPath (Join-Path $BaseRelease $path) -Destination $dir -Recurse
}
$agent = Get-Content -LiteralPath "$dir\local-agent\windows-amd64\manifest.json" -Raw | ConvertFrom-Json
@"
Aurora $Version — Windows GUI 验收版（$Suffix），Windows x64

双击“启动验收版.cmd”，使用本包 review-data 下的独立配置与独立实例。
首次为空白配置；原正式版的 API Key、OAuth、工作区和运行状态保持原样。
可以通过“打开本机文件夹”选择项目。配置隔离不是文件权限沙箱。

本次包含：$Summary
命令面板可“复制界面诊断”。
正式签名的本地／远程 agent 沿用 $($agent.version)，字节未改；本地 agent 随客户端退出。

验收说明与已知边界：$NotesFile
源代码：$repo（工作区改动）。本包为本地候选，尚未对外发布。
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
set "AURORA3_AGENT_DIR=%~dp0agent\amd64"
set "AURORA3_LOCAL_AGENT_DIR=%~dp0local-agent\windows-amd64"
if not exist "%LOCALAPPDATA%" mkdir "%LOCALAPPDATA%"
if not exist "%APPDATA%" mkdir "%APPDATA%"
if not exist "%USERPROFILE%" mkdir "%USERPROFILE%"
start "" "%~dp0aurora.exe"
"@ | Set-Content -LiteralPath "$dir\启动验收版.cmd" -Encoding ascii
Copy-Item -LiteralPath (Join-Path $repo "docs\$NotesFile") -Destination $dir
[pscustomobject]@{
    version = $Version
    candidate = $Suffix
    built_at_utc = [DateTime]::UtcNow.ToString('o')
    source_head = (& git -C $repo rev-parse HEAD)
    source_working_tree = "uncommitted Windows GUI candidate: $Suffix"
    source_files_checked_before_and_after_build = $sources.Count
    client_aot_sha256 = (Get-FileHash -LiteralPath "$dir\data\app.so" -Algorithm SHA256).Hash.ToLowerInvariant()
    backend_version = $agent.version
    isolated_launcher = '启动验收版.cmd'
} | ConvertTo-Json | Set-Content -LiteralPath "$dir\BUILD-INFO.json" -Encoding utf8
Compress-Archive -LiteralPath $dir -DestinationPath $zip
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name.zip" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
Write-Output "Candidate: $dir"
Write-Output "ZIP: $zip"
Write-Output "SHA256: $hash"
