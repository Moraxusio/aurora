# Build only the wrapper, from the known fresh complete package. The Windows
# client and both agents are not recompiled or re-signed by this step.
param(
    [Parameter(Mandatory)][string]$BaseRelease,
    [Parameter(Mandatory)][string]$Out,
    [string]$Key = $env:AURORA_RELEASE_KEY,
    [string]$AuthenticodeThumbprint,
    [string]$TimestampUrl,
    [string]$SignTool = 'signtool.exe'
)
$ErrorActionPreference = 'Stop'
$authenticode = -not [string]::IsNullOrEmpty($AuthenticodeThumbprint) -or -not [string]::IsNullOrEmpty($TimestampUrl)
if ($authenticode) {
    [uri]$timestamp = $null
    if ($AuthenticodeThumbprint -notmatch '^[a-fA-F0-9]{40}$' -or
        -not [uri]::TryCreate($TimestampUrl, [UriKind]::Absolute, [ref]$timestamp) -or
        $timestamp.Scheme -ne 'https' -or $timestamp.UserInfo) {
        throw 'Authenticode requires a certificate thumbprint and an HTTPS RFC 3161 timestamp URL'
    }
    $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$AuthenticodeThumbprint" -ErrorAction SilentlyContinue
    $now = Get-Date
    if (-not $cert -or -not $cert.HasPrivateKey -or $cert.NotBefore -gt $now -or $cert.NotAfter -le $now -or
        @($cert.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' }).Count -eq 0) {
        throw 'The requested current-user Code Signing certificate is not usable'
    }
    $SignTool = (Get-Command $SignTool -CommandType Application -ErrorAction Stop).Source
}
$repo = Split-Path -Parent $PSScriptRoot
$base = [IO.Path]::GetFullPath($BaseRelease)
$Out = [IO.Path]::GetFullPath($Out)
if (-not $Key -or -not (Test-Path -LiteralPath $Key -PathType Leaf)) { throw 'Release signing key not found' }
$Key = (Resolve-Path -LiteralPath $Key).Path
$info = Get-Content -LiteralPath "$base\BUILD-INFO.json" -Raw | ConvertFrom-Json
$version = $info.version
if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$' -or $info.candidate -notmatch '^[a-zA-Z0-9-]+$') { throw 'Invalid base candidate' }
$linuxChannel = if ($info.channel) { [string]$info.channel } else { 'stable' }
if ($linuxChannel -cnotin @('stable', 'preview')) { throw 'Invalid Linux agent channel' }
$publicPreview = if ($linuxChannel -ceq 'preview') { '1' } else { '0' }
$exe = Join-Path $Out "Aurora-$version-$($info.candidate)-single.exe"
if ((Test-Path -LiteralPath $exe) -or (Test-Path -LiteralPath "$exe.sha256")) { throw "Candidate already exists: $exe" }
$payload = Join-Path $repo 'agent\cmd\aurora4-bootstrap\payload'
$temp = Join-Path $env:LOCALAPPDATA ('Temp\opencode\aurora-single-' + [guid]::NewGuid().ToString('N'))
$tmpExe = $null
$ownedPayload = $false
$saved = @{}
foreach ($name in @('GOOS','GOARCH','CGO_ENABLED','GOTOOLCHAIN','GOPROXY')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    New-Item -ItemType Directory -Path $payload | Out-Null
    $ownedPayload = $true
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $env:CGO_ENABLED = '0'
    $env:GOTOOLCHAIN = 'local'
    $env:GOPROXY = 'off'
    # Refuse state-bearing trees and only include this package's runtime and
    # shipped documentation. Never recursively archive the candidate root.
    if (Test-Path -LiteralPath "$base\review-data") { throw 'Use a fresh candidate, before launching its review profile' }
    $items = @('aurora.exe','data','agent','local-agent','docs','LICENSE','NOTICE','LICENSES.txt','CHANGES.md')
    $items += @(Get-ChildItem -LiteralPath $base -File -Filter '*.dll' | ForEach-Object Name)
    if ($items -notcontains 'flutter_windows.dll') { throw 'Flutter runtime missing' }
    $paths = foreach ($item in $items) { Join-Path $base $item }
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Missing runtime component: $p" }
        if ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Unexpected reparse point: $p"
        }
        if (Test-Path -LiteralPath $p -PathType Container) {
            $unsafe = Get-ChildItem -LiteralPath $p -Recurse -Force | Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                $_.Name -in @('profile.bin','agent.key','agent-id','local-agent.json','review-data',
                    'file-transactions', 'attachments', 'snapshots', 'sessions', 'tool-output')
            } | Select-Object -First 1
            if ($unsafe) { throw "Candidate contains non-distributable state: $($unsafe.FullName)" }
        }
    }
    $aot = (Get-FileHash -LiteralPath "$base\data\app.so").Hash.ToLowerInvariant()
    if ($aot -cne $info.client_aot_sha256) { throw 'Windows AOT differs from the complete candidate' }
    Push-Location (Join-Path $repo 'agent')
    try {
        & go build -o "$temp\release.exe" ./cmd/aurora3-release
        if ($LASTEXITCODE) { throw 'Release helper build failed' }
        & "$temp\release.exe" verify --channel $linuxChannel --dir "$base\agent\amd64"
        if ($LASTEXITCODE) { throw 'Linux agent verification failed' }
        & "$temp\release.exe" verify --product aurora3-local-agent --dir "$base\local-agent\windows-amd64"
        if ($LASTEXITCODE) { throw 'Windows agent verification failed' }
        foreach ($pair in @(@("$base\agent\amd64\manifest.json",$info.linux_agent_sha256),
                @("$base\local-agent\windows-amd64\manifest.json",$info.local_agent_sha256))) {
            $agent = Get-Content -LiteralPath $pair[0] -Raw | ConvertFrom-Json
            if ($agent.version -cne $version -or $agent.sha256 -cne $pair[1]) { throw 'Agent identity differs from base candidate' }
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Add-Type -AssemblyName System.IO.Compression
        $stream = [IO.File]::Open("$payload\runtime.zip", 'CreateNew', 'Write', 'None')
        try {
            $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                foreach ($p in $paths) {
                    $files = if (Test-Path -LiteralPath $p -PathType Container) {
                        Get-ChildItem -LiteralPath $p -File -Recurse -Force
                    } else { Get-Item -LiteralPath $p }
                    foreach ($f in $files) {
                        $entry = $f.FullName.Substring($base.Length + 1).Replace('\','/')
                        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry,
                            [IO.Compression.CompressionLevel]::Optimal) | Out-Null
                    }
                }
            } finally { $archive.Dispose() }
        } finally { $stream.Dispose() }
        & "$temp\release.exe" sign --product aurora4-runtime --os windows --arch amd64 --version $version `
            --key $Key --file "$payload\runtime.zip" --out "$payload\sign"
        if ($LASTEXITCODE) { throw 'Runtime signing failed' }
        & "$temp\release.exe" verify --product aurora4-runtime --dir "$payload\sign"
        if ($LASTEXITCODE) { throw 'Runtime signature verification failed' }
        Copy-Item -LiteralPath "$payload\sign\manifest.json","$payload\sign\manifest.sig" -Destination $payload
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        $tmpExe = Join-Path $Out ('.aurora-single-' + [guid]::NewGuid().ToString('N') + '.exe')
        & go build -tags aurora_bundle -trimpath -ldflags "-H=windowsgui -s -w -X main.Version=$version -X main.PublicPreview=$publicPreview" -o $tmpExe ./cmd/aurora4-bootstrap
        if ($LASTEXITCODE) { throw 'Single EXE build failed' }
    } finally { Pop-Location }
    if ($authenticode) {
        & $SignTool sign /s My /sha1 $AuthenticodeThumbprint /fd SHA256 /tr $timestamp.AbsoluteUri /td SHA256 $tmpExe
        if ($LASTEXITCODE) { throw 'Authenticode signing or RFC 3161 timestamping failed' }
        & $SignTool verify /pa /tw $tmpExe
        if ($LASTEXITCODE) { throw 'Authenticode verification failed' }
        $signature = Get-AuthenticodeSignature -LiteralPath $tmpExe
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $AuthenticodeThumbprint -or
            -not $signature.TimeStamperCertificate) {
            throw 'The signed wrapper is not trusted, timestamped or signed by the requested certificate'
        }
    }
    $p = Start-Process -FilePath $tmpExe -ArgumentList '--verify' -Wait -PassThru
    if ($p.ExitCode) { throw "Single EXE self-verification failed: $($p.ExitCode)" }
    [IO.File]::Move($tmpExe, $exe)
    $hash = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    "$hash  $(Split-Path -Leaf $exe)" | Set-Content -LiteralPath "$exe.sha256" -Encoding ascii
    "Single EXE: $exe"
    "SHA256: $hash"
} finally {
    if ($ownedPayload) { Remove-Item -LiteralPath $payload -Recurse -Force }
    if ($tmpExe -and (Test-Path -LiteralPath $tmpExe)) { Remove-Item -LiteralPath $tmpExe -Force }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
