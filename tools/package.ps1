# Builds the first-release folder (M1): the Windows client with the
# aurora3-agent it installs, signed with the v3 release key (D-3, D-13).
# Nothing is uploaded (G7.2).
#
#   powershell -File tools\package.ps1 -Version 3.0.0 [-Out release3]
#
# Layout of the output:
#   Aurora-<version>\
#     aurora.exe, flutter_windows.dll, aurora_tls.dll, data\   the client
#     agent\amd64\  manifest.json, manifest.sig, aurora3-agent-<v>-linux-amd64
#     LICENSES.txt  every third-party component and its licence
#     README.txt
# plus Aurora-<version>.zip and its SHA-256.
param(
    [Parameter(Mandatory)][string]$Version,
    # Not v2-release: that is v2's release folder (D-75).
    [string]$Out = 'release3',
    [string]$Key = '<release-key>',
    [string]$Policy = ''
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$go = 'go'
$flutter = 'flutter'
if ($Version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw "version must be MAJOR.MINOR.PATCH: $Version" }
if (-not (Test-Path $Key)) { throw "release key not found: $Key" }
$dir = Join-Path $Out "Aurora-$Version"
if (Test-Path $dir) { throw "$dir exists; remove it or use another version" }
$work = Join-Path $env:LOCALAPPDATA "Temp\aurora3\package-$Version"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force $work, $dir | Out-Null

# 1. The tmux bundle must be the pinned build (agent/tools/tmux/bundle.lock).
$lock = Get-Content (Join-Path $repo 'agent\tools\tmux\bundle.lock') | Where-Object { $_ -match '^[0-9a-f]{64}\s' }
foreach ($l in $lock) {
    $want, $name = $l -split '\s+', 2
    $file = Join-Path $repo "agent\internal\bundle\$name"
    if ($name -eq 'tmux') {
        # bundle.lock pins the unpacked binary; the bundle carries it gzipped
        $gz = [IO.File]::OpenRead((Join-Path $repo 'agent\internal\bundle\tmux.gz'))
        $z = New-Object IO.Compression.GZipStream($gz, [IO.Compression.CompressionMode]::Decompress)
        $sha = [Security.Cryptography.SHA256]::Create()
        $got = -join ($sha.ComputeHash($z) | ForEach-Object { $_.ToString('x2') })
        $z.Close(); $gz.Close()
    } else {
        $got = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    }
    if ($got -ne $want) { throw "bundle $name is $got, bundle.lock says $want" }
}
Write-Output "tmux bundle matches bundle.lock"

# 2. The agent, signed.
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:CGO_ENABLED = '0'
Push-Location (Join-Path $repo 'agent')
try {
    & $go build -o "$work\aurora3-release.exe" ./cmd/aurora3-release
    if ($LASTEXITCODE) { throw 'build aurora3-release' }
    $env:GOOS = 'linux'; $env:GOARCH = 'amd64'
    & $go build -trimpath -ldflags "-s -w -X main.Version=$Version" -o "$work\aurora3-agent" ./cmd/aurora3-agent
    if ($LASTEXITCODE) { throw 'build aurora3-agent' }
} finally { Pop-Location; Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue }
& "$work\aurora3-release.exe" sign --key $Key --version $Version --arch amd64 --file "$work\aurora3-agent" --out "$dir\agent\amd64"
if ($LASTEXITCODE) { throw 'sign' }
# Checked with the release key compiled into the tools, as the client does.
& "$work\aurora3-release.exe" verify --dir "$dir\agent\amd64"
if ($LASTEXITCODE) { throw 'verify' }
$policyArgs = @('policy', '--key', $Key, '--out', "$dir\agent")
if ($Policy) { $policyArgs += @('--input', $Policy) }
& "$work\aurora3-release.exe" @policyArgs
if ($LASTEXITCODE) { throw 'sign upgrade policy' }

# 3. The client.
Push-Location (Join-Path $repo 'app')
try {
    & $flutter build windows --release "--build-name=$Version"
    if ($LASTEXITCODE) { throw 'flutter build' }
} finally { Pop-Location }
Copy-Item (Join-Path $repo 'app\build\windows\x64\runner\Release\*') $dir -Recurse

# 4. Licences: every third-party component in the folder.
& powershell -NoProfile -File (Join-Path $PSScriptRoot 'licenses.ps1') -Out "$dir\LICENSES.txt"
if ($LASTEXITCODE) { throw 'licenses' }

# 5. README.
$m = Get-Content "$dir\agent\amd64\manifest.json" -Raw | ConvertFrom-Json
@"
Aurora $Version (Windows)

运行 aurora.exe。第一次使用时点“添加服务器”，填写 Linux 服务器的 SSH 地址和账号，
程序会通过 SSH 安装 aurora3-agent，之后直接连接，不再需要 SSH。

- 支持的服务器：Linux x86-64（amd64），需要 systemd。
- 服务器上只使用 v3 的名字：/usr/local/bin/aurora3-agent、aurora3-agent.service、
  /etc/aurora3、/var/lib/aurora3，端口 17710。已有的 Aurora 2（aurora-agent）不受影响。
- 保存的服务器和密码在 %LOCALAPPDATA%\Aurora3\profile.bin，用 Windows DPAPI 加密，
  只有当前 Windows 用户能打开。

代理功能（3.2.0）：
- 在“代理”页添加 Clash 订阅 URL，或粘贴节点链接；选用节点后，新建终端时勾选
  “这个会话走代理”。git 的 HTTP/HTTPS 远程操作跟随代理服务开关。
- 代理在受控服务器的 agent 上运行，流量不经这台电脑。不会登录、安装或修改代理服务器。
- 已支持 Trojan（TCP/TLS）、Hysteria2（含 Salamander）、VLESS 和 VMess AEAD
  （TCP 或 WebSocket，可加 TLS）。Reality、XTLS Vision、gRPC、h2、XHTTP、端口跳跃、
  旧版 VMess、Shadowsocks、TUIC、AnyTLS 等尚不支持；节点会留在列表并说明原因。
- 订阅 URL 只加密存放在本机；选中节点的凭据会发送给受控服务器，服务器重启后仍可使用。
  “测速”也由受控服务器执行，需要向它临时发送被测节点的参数。
- 订阅更新请使用“重新读取订阅”按钮。代理变量保证在 bash 启动文件之后生效；
  其它 shell 的启动脚本仍可能覆盖变量。已有会话不会因勾选而改成代理会话。
- 请使用本包的 agent：旧版 3.1.1 没有代理服务。更新客户端不会自动替换正在运行的 agent。

内置 agent：$($m.file)
  版本 $($m.version)，SHA-256 $($m.sha256)
  由发布密钥 $($m.key_id) 签名（agent\amd64\manifest.sig）。

第三方组件及许可证见 LICENSES.txt。
"@ | Set-Content -Encoding utf8 "$dir\README.txt"

# 6. Zip and hash.
$zip = Join-Path $Out "Aurora-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $dir -DestinationPath $zip
$h = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$h  Aurora-$Version.zip" | Set-Content -Encoding ascii "$zip.sha256"
Remove-Item $work -Recurse -Force
Write-Output "folder: $dir"
Write-Output "zip:    $zip"
Write-Output "sha256: $h"
