# Full signed Windows client/backend bundle. Produces local artifacts only.
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Out = $(if ($env:AURORA_RELEASE_OUT) { $env:AURORA_RELEASE_OUT } else { Join-Path (Split-Path -Parent $PSScriptRoot) 'dist' }),
    [string]$Key = $env:AURORA_RELEASE_KEY,
    [string]$Policy = '',
    [string]$NotesFile = '',
    [switch]$NoArchive,
    [switch]$PublicPreview
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if ($Version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw 'Version must be MAJOR.MINOR.PATCH' }
$parts = $Version.Split('.')
if ([int]$parts[1] -gt 99 -or [int]$parts[2] -gt 99) { throw 'MINOR and PATCH must be 0-99' }
$buildNumber = [int]$parts[0] * 10000 + [int]$parts[1] * 100 + [int]$parts[2]
$linuxChannel = if ($PublicPreview) { 'preview' } else { 'stable' }
if (-not $Key -or -not (Test-Path -LiteralPath $Key -PathType Leaf)) { throw 'Release signing key not found' }
$Key = (Resolve-Path -LiteralPath $Key).Path
$Out = [IO.Path]::GetFullPath($Out)
$dir = Join-Path $Out "Aurora-$Version"
$zip = "$dir.zip"
foreach ($target in @($dir, $zip, "$zip.sha256")) {
    if (Test-Path -LiteralPath $target) { throw "Artifact already exists: $target" }
}
if ($NotesFile) {
    if (-not [IO.Path]::IsPathRooted($NotesFile)) { $NotesFile = Join-Path $repo $NotesFile }
    if (-not (Test-Path -LiteralPath $NotesFile -PathType Leaf)) { throw 'Version notes not found' }
}
& (Join-Path $PSScriptRoot 'check-docs.ps1')
function Get-BuildSources {
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
$sources = Get-BuildSources
$sourceHead = (& git -C $repo rev-parse HEAD)
if ($LASTEXITCODE) { throw 'Cannot identify build revision' }
$sourceStatus = @(& git -C $repo status --porcelain)
if ($LASTEXITCODE) { throw 'Cannot identify working tree state' }

$work = Join-Path $env:LOCALAPPDATA ('Temp\opencode\aurora-package-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work, $dir -Force | Out-Null
$saved = @{}
foreach ($name in @('GOTOOLCHAIN', 'GOPROXY', 'CGO_ENABLED', 'GOOS', 'GOARCH')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    $lock = Get-Content (Join-Path $repo 'agent\tools\tmux\bundle.lock') | Where-Object { $_ -match '^[0-9a-f]{64}\s' }
    foreach ($line in $lock) {
        $want, $name = $line -split '\s+', 2
        $path = Join-Path $repo "agent\internal\bundle\$name"
        if ($name -eq 'tmux') {
            $input = [IO.File]::OpenRead("$path.gz")
            $stream = New-Object IO.Compression.GZipStream($input, [IO.Compression.CompressionMode]::Decompress)
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $got = -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
            finally { $sha.Dispose(); $stream.Dispose(); $input.Dispose() }
        } else { $got = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
        if ($got -ne $want) { throw "tmux bundle mismatch: $name" }
    }
    Write-Output 'tmux bundle matches bundle.lock'
    $env:GOTOOLCHAIN = 'local'
    $env:GOPROXY = 'off'
    $env:CGO_ENABLED = '0'
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    Push-Location (Join-Path $repo 'agent')
    try {
        & go build -o "$work\aurora3-release.exe" ./cmd/aurora3-release
        if ($LASTEXITCODE) { throw 'Release helper build failed' }
        $env:GOOS = 'linux'
        $previewTag = if ($PublicPreview) { @('-tags', 'aurora_public_preview') } else { @() }
        & go build @previewTag -trimpath -ldflags "-s -w -X main.Version=$Version" -o "$work\aurora3-agent" ./cmd/aurora3-agent
        if ($LASTEXITCODE) { throw 'Linux agent build failed' }
        $env:GOOS = 'windows'
        & go build -trimpath -ldflags "-H=windowsgui -s -w -X main.Version=$Version" -o "$work\aurora3-local-agent.exe" ./cmd/aurora3-local-agent
        if ($LASTEXITCODE) { throw 'Windows local agent build failed' }
    } finally { Pop-Location }
    & "$work\aurora3-release.exe" sign --key $Key --version $Version --channel $linuxChannel --arch amd64 --file "$work\aurora3-agent" --out "$dir\agent\amd64"
    if ($LASTEXITCODE) { throw 'Linux agent signing failed' }
    & "$work\aurora3-release.exe" verify --channel $linuxChannel --dir "$dir\agent\amd64"
    if ($LASTEXITCODE) { throw 'Linux agent verification failed' }
    & "$work\aurora3-release.exe" sign --key $Key --product aurora3-local-agent --os windows --version $Version --arch amd64 --file "$work\aurora3-local-agent.exe" --out "$dir\local-agent\windows-amd64"
    if ($LASTEXITCODE) { throw 'Local agent signing failed' }
    & "$work\aurora3-release.exe" verify --product aurora3-local-agent --dir "$dir\local-agent\windows-amd64"
    if ($LASTEXITCODE) { throw 'Local agent verification failed' }
    & (Join-Path $PSScriptRoot 'check-agent-release-identity.ps1') -ManifestPaths @(
        "$dir\agent\amd64\manifest.json", "$dir\local-agent\windows-amd64\manifest.json"
    )
    $policyArgs = @('policy', '--key', $Key, '--out', "$dir\agent")
    if ($Policy) { $policyArgs += @('--input', $Policy) }
    & "$work\aurora3-release.exe" @policyArgs
    if ($LASTEXITCODE) { throw 'Upgrade policy signing failed' }

    Push-Location (Join-Path $repo 'app')
    try {
        & dart tool/ui_contract.dart
        if ($LASTEXITCODE) { throw 'Aurora GUI contract failed' }
        & flutter build windows --no-pub --release --target=lib/main.dart "--build-name=$Version" "--build-number=$buildNumber" "--dart-define=AURORA_CLIENT_VERSION=$Version"
        if ($LASTEXITCODE) { throw 'Windows client build failed' }
    } finally { Pop-Location }
    Copy-Item (Join-Path $repo 'app\build\windows\x64\runner\Release\*') $dir -Recurse
    & powershell -NoProfile -File (Join-Path $PSScriptRoot 'licenses.ps1') -Out "$dir\LICENSES.txt"
    if ($LASTEXITCODE) { throw 'License collection failed' }
    & (Join-Path $PSScriptRoot 'copy-package-docs.ps1') -Destination $dir -NotesFile $NotesFile
    @"
Aurora $Version — Windows x64

运行 aurora.exe，选择“打开本机文件夹”开始。本地 agent 随客户端运行；
点窗口关闭会隐藏到托盘，托盘“退出”完整结束本地受管终端和任务。
远程开发通过“添加服务器”安装／连接 Linux amd64 agent。

文档入口：docs\README.md
开始使用：docs\guides\getting-started.md
开发工具：docs\guides\development-tools.md
AI 协作：docs\guides\ai.md
能力边界：docs\reference\compatibility.md
本次变更：CHANGES.md（指定版本说明时提供）

Windows 本地 agent、Linux amd64 agent 和客户端统一版本 $Version。
两种 agent 和升级策略由发布密钥签名，客户端使用内置公钥验证。
本脚本仅生成本地文件；签名 agent 不表示 Windows EXE 带有 Authenticode 签名。
许可证：LICENSE、NOTICE、LICENSES.txt（保留 OpenCode MIT 署名）。
"@ | Set-Content -LiteralPath "$dir\README.txt" -Encoding utf8
    $after = Get-BuildSources
    if ($sources.Count -ne $after.Count) { throw 'Build inputs changed during compilation' }
    foreach ($file in $sources.Keys) {
        if (-not $after.Contains($file) -or $sources[$file] -ne $after[$file]) { throw "Build input changed: $file" }
    }
    if ((& git -C $repo rev-parse HEAD) -ne $sourceHead -or
        (@(& git -C $repo status --porcelain) -join "`n") -ne ($sourceStatus -join "`n")) {
        throw 'Source revision or working tree state changed during compilation'
    }
    $sources | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$dir\SOURCE-HASHES.json" -Encoding utf8
    $linux = Get-Content -LiteralPath "$dir\agent\amd64\manifest.json" -Raw | ConvertFrom-Json
    $local = Get-Content -LiteralPath "$dir\local-agent\windows-amd64\manifest.json" -Raw | ConvertFrom-Json
    [ordered]@{
        version = $Version
        channel = $linuxChannel
        built_at_utc = [DateTime]::UtcNow.ToString('o')
        source_head = $sourceHead
        source_working_tree = $(if ($sourceStatus.Count) { 'uncommitted working tree' } else { 'clean' })
        source_files_checked_before_and_after_build = $sources.Count
        source_deleted_files = @(& git -C $repo diff --name-only --diff-filter=D)
        client_aot_sha256 = (Get-FileHash -LiteralPath "$dir\data\app.so" -Algorithm SHA256).Hash.ToLowerInvariant()
        agent_version = $Version
        linux_agent_sha256 = $linux.sha256
        local_agent_sha256 = $local.sha256
        signing_key_id = $linux.key_id
        document_entry = 'docs/README.md'
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$dir\BUILD-INFO.json" -Encoding utf8
    if (-not $NoArchive) {
        Compress-Archive -LiteralPath $dir -DestinationPath $zip
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  Aurora-$Version.zip" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
        Write-Output "ZIP: $zip"
        Write-Output "SHA256: $hash"
    }
    Write-Output "Folder: $dir"
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
