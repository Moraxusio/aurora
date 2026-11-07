# Writes LICENSES.txt for the release folder: every third-party component
# that ships in it, with its licence text, read from the files on this
# machine (pub cache, Go module cache, vendored sources). Fails when a
# licence file is missing, so nothing ships unlisted.
#   powershell -File tools\licenses.ps1 -Out LICENSES.txt
param([Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$pub = Join-Path $env:LOCALAPPDATA 'Pub\Cache\hosted\pub.dev'
$gomod = Join-Path $env:USERPROFILE 'go\pkg\mod'
$sb = New-Object Text.StringBuilder

function Add-License($title, $file) {
    if (-not (Test-Path $file)) { throw "licence file missing for ${title}: $file" }
    [void]$sb.AppendLine(('=' * 78))
    [void]$sb.AppendLine($title)
    [void]$sb.AppendLine(('=' * 78))
    [void]$sb.AppendLine((Get-Content $file -Raw).TrimEnd())
    [void]$sb.AppendLine('')
}

[void]$sb.AppendLine('Aurora 3: third-party components and their licences')
[void]$sb.AppendLine('')

# The client: Dart packages that the app depends on at run time ("pub deps
# --no-dev --style=compact" lists each once with its resolved version; path
# packages are this repository's own).
$deps = & 'flutter' pub deps --no-dev --style=compact --directory (Join-Path $repo 'app') 2>$null |
    Where-Object { $_ -match '^- (\S+) (\d\S*)' } | ForEach-Object { [pscustomobject]@{ name = $Matches[1]; version = $Matches[2] } }
if (@($deps).Count -lt 20) { throw "pub deps listed only $(@($deps).Count) packages" }
foreach ($d in ($deps | Sort-Object name -Unique)) {
    if ($d.name -in 'aurora_install', 'aurora_profile', 'aurora_tls', 'aurora_wire', 'aurora', 'flutter', 'flutter_web_plugins', 'sky_engine') { continue }
    # xterm is vendored (app/third_party/xterm, patched): its licence is there.
    $p = if ($d.name -eq 'xterm') { Join-Path $repo 'app\third_party\xterm' } else { Join-Path $pub "$($d.name)-$($d.version)" }
    $lic = @('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING') | ForEach-Object { Join-Path $p $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    Add-License "Dart package $($d.name) $($d.version)" $lic
}

# Flutter's engine and framework carry their own notices (NOTICES.Z in the
# app's data folder); point to it rather than copy 100 KB of text twice.
[void]$sb.AppendLine(('=' * 78))
[void]$sb.AppendLine('Flutter engine and framework')
[void]$sb.AppendLine(('=' * 78))
[void]$sb.AppendLine('Their licences, and those of the libraries the engine includes, are in')
[void]$sb.AppendLine('data\flutter_assets\NOTICES.Z (gzip-compressed text).')
[void]$sb.AppendLine('')

# BoringSSL, compiled into aurora_tls.dll.
Add-License 'BoringSSL 0.20261020.0 (in aurora_tls.dll)' (Join-Path $repo 'app\packages\aurora_tls\third_party\boringssl\LICENSE')

# The agent: Go modules compiled into aurora3-agent, and the bundled tmux.
Push-Location (Join-Path $repo 'agent')
try {
    $env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:GOOS = 'linux'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
    $goList = & 'go' list -deps -f '{{with .Module}}{{if not .Main}}{{.Path}} {{.Version}}{{end}}{{end}}' ./cmd/aurora3-agent | Sort-Object -Unique
    if ($LASTEXITCODE) { throw 'go list' }
} finally { Pop-Location; Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue }
foreach ($m in $goList) {
    if (-not $m) { continue }
    $path, $ver = $m -split ' '
    # module cache paths escape upper case as !lower
    $esc = ($path -creplace '([A-Z])', '!$1').ToLower()
    $dirm = Join-Path $gomod "$esc@$ver"
    $lic = @('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING') | ForEach-Object { Join-Path $dirm $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    Add-License "Go module $path $ver (in aurora3-agent)" $lic
}
$tl = Join-Path $repo 'agent\tools\tmux\LICENSES.txt'
if (Test-Path $tl) {
    Add-License 'tmux, libevent, ncurses, musl (the tmux bundled in aurora3-agent)' $tl
} else {
    [void]$sb.AppendLine(('=' * 78))
    [void]$sb.AppendLine('tmux, libevent, ncurses, musl (the tmux bundled in aurora3-agent)')
    [void]$sb.AppendLine(('=' * 78))
    [void]$sb.AppendLine((Get-Content (Join-Path $repo 'agent\internal\bundle\manifest.txt') -Raw).TrimEnd())
    [void]$sb.AppendLine('tmux: ISC licence. libevent: BSD-3-Clause. ncurses: MIT (X11). musl: MIT.')
    [void]$sb.AppendLine('Sources are pinned in agent/tools/tmux/sources.lock.')
    [void]$sb.AppendLine('')
}
[IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
"{0}: {1:N0} KB" -f $Out, ((Get-Item $Out).Length / 1KB)
