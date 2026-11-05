<#
  Builds the static tmux that aurora-agent carries, on a Linux host with
  Docker, from the sources pinned in sources.lock. Nothing is pulled from a
  registry: the Alpine root filesystem comes from the pinned tarball.

    .\tools\tmux\build.ps1 -BuildHost 203.0.113.10

  Sources are read from .cache\tmux (download them with the URLs in
  sources.lock). Output goes to internal\bundle\ and its hashes to
  tools\tmux\bundle.lock, which the main build.ps1 checks.
#>
param(
  [Parameter(Mandatory)] [string]$BuildHost,
  [string]$Cache = ''
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Cache) { $Cache = Join-Path $repo '.cache\tmux' }
$bundle = Join-Path $repo 'internal\bundle'

$files = @(); $checks = @()
foreach ($line in Get-Content (Join-Path $PSScriptRoot 'sources.lock')) {
  if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
  $sha, $name, $url = $line -split '\s+'
  $p = Join-Path $Cache $name
  if (-not (Test-Path $p)) { throw "missing source $name (download $url into $Cache)" }
  $got = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
  if ($got -ne $sha) { throw "$name has sha256 $got, expected $sha" }
  $files += $p; $checks += "$sha  src/$name"
}
Write-Host 'sources verified'

$work = '/tmp/aurora-tmux-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
try {
  ssh -o BatchMode=yes $BuildHost "mkdir -p $work/src $work/out"
if ($LASTEXITCODE -ne 0) { throw 'ssh failed' }
scp -o BatchMode=yes @files (Join-Path $PSScriptRoot 'build-in-container.sh') "$($BuildHost):$work/src/" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'scp failed' }
$lf = [string][char]10
$remote = @(
  'set -e',
  "cd $work",
  'sha256sum -c --quiet SHA256SUMS',
  'img=aurora-build-alpine:3.24.3',
  'docker image inspect $img >/dev/null 2>&1 || docker import src/alpine-minirootfs-3.24.3-x86_64.tar.gz $img >/dev/null',
  ("docker run --rm --network host -v $work/src:/src:ro -v $work/out:/out " + '$img sh /src/build-in-container.sh')
) -join $lf
# Through a file: Windows PowerShell would prefix piped stdin with a BOM.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aurora-tmux-' + [guid]::NewGuid().ToString('N') + '.sh')
$sums = $tmp + '.sums'
[IO.File]::WriteAllText($tmp, $remote + $lf, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($sums, ($checks -join $lf) + $lf, (New-Object Text.UTF8Encoding($false)))
scp -o BatchMode=yes $tmp "$($BuildHost):$work/run.sh" | Out-Null
scp -o BatchMode=yes $sums "$($BuildHost):$work/SHA256SUMS" | Out-Null
Remove-Item $tmp, $sums
# Native tools write progress to stderr; that is not a failure.
$ErrorActionPreference = 'Continue'
ssh -o BatchMode=yes $BuildHost "bash $work/run.sh 2>&1" | ForEach-Object { Write-Host $_ }
  $ok = $LASTEXITCODE -eq 0
  if ($ok) {
  New-Item -ItemType Directory -Force $bundle | Out-Null
  scp -o BatchMode=yes "$($BuildHost):$work/out/tmux" "$($BuildHost):$work/out/terminfo.tar.gz" "$($BuildHost):$work/out/manifest.txt" "$bundle\" | Out-Null
}
ssh -o BatchMode=yes $BuildHost "rm -rf $work"
$ErrorActionPreference = 'Stop'
  if (-not $ok) { throw 'container build failed' }
} finally {
  Remove-Item $tmp, $sums -ErrorAction SilentlyContinue
  ssh -o BatchMode=yes $BuildHost "rm -rf $work"
}

# The agent carries tmux gzip-compressed.
$tmuxPath = Join-Path $bundle 'tmux'
$raw = [IO.File]::ReadAllBytes($tmuxPath)
$gzPath = Join-Path $bundle 'tmux.gz'
$fs = [IO.File]::Create($gzPath)
$gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionLevel]::Optimal)
$gz.Write($raw, 0, $raw.Length); $gz.Close(); $fs.Close()
$tmuxSha = (Get-FileHash $tmuxPath -Algorithm SHA256).Hash.ToLower()
Remove-Item $tmuxPath
$tiSha = (Get-FileHash (Join-Path $bundle 'terminfo.tar.gz') -Algorithm SHA256).Hash.ToLower()
$lock = @(
  '# Written by tools/tmux/build.ps1; the main build.ps1 checks internal/bundle against it.',
  "$tmuxSha  tmux",
  "$tiSha  terminfo.tar.gz"
)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'bundle.lock'), ($lock -join $lf) + $lf)
Get-Content (Join-Path $bundle 'manifest.txt') | ForEach-Object { Write-Host $_ }
Write-Host ('tmux.gz ' + (Get-Item $gzPath).Length + ' bytes')
