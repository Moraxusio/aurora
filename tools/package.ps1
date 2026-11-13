# Builds the first-release folder (M1): the Windows client with the
# aurora3-agent it installs, signed with the v3 release key (D-3, D-13).
# Nothing is uploaded (G7.2).
#
#   powershell -File tools\package.ps1 -Version 3.0.0 [-Out dist] [-Key <release.key>]
#
# Layout of the output:
#   Aurora-<version>\
#     aurora.exe, flutter_windows.dll, aurora_tls.dll, data\   the client
#     agent\amd64\  manifest.json, manifest.sig, aurora3-agent-<v>-linux-amd64
#     agent\policy.json, policy.sig  signed upgrade policy
#     LICENSES.txt  every third-party component and its licence
#     README.txt
# plus Aurora-<version>.zip and its SHA-256.
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Out = $(if ($env:AURORA_RELEASE_OUT) { $env:AURORA_RELEASE_OUT } else { Join-Path (Split-Path -Parent $PSScriptRoot) 'dist' }),
    # Release signing key (never commit it). Or set AURORA_RELEASE_KEY.
    [string]$Key = $env:AURORA_RELEASE_KEY,
    [string]$Policy = ''
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$go = 'go'
$flutter = 'flutter'
if ($Version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw "version must be MAJOR.MINOR.PATCH: $Version" }
if (-not $Key -or -not (Test-Path $Key)) { throw "release key not found: $Key" }
$dir = Join-Path $Out "Aurora-$Version"
$zip = Join-Path $Out "Aurora-$Version.zip"
foreach ($target in @($dir, $zip, "$zip.sha256")) {
    if (Test-Path $target) { throw "$target exists; use another version (release artifacts are never overwritten)" }
}
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
        $sha = [Security.Cryptography.SHA256]::Create()
        $got = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($file)) | ForEach-Object { $_.ToString('x2') })
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
# Aurora's own licence (Apache-2.0 asks for the text and the NOTICE with every copy).
Copy-Item (Join-Path $repo 'LICENSE'), (Join-Path $repo 'NOTICE') $dir

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

本次更新（$Version）：
- AI 页显示上下文估算占用/输入预算/百分比，累计用量另列；压缩、回退后重新估算。
- 显示当步实际请求的提供商与模型、下一次选择；每条回答保留当时的提供商和模型。
- 复用 OpenCode（MIT）的 OpenAI / ChatGPT 订阅 device 登录、token 交换/刷新和 Codex
  HTTP SSE 路由。入口：AI 设置 -> 添加 OpenAI / ChatGPT 订阅（设备码）预设。
- API Key 与 OAuth 令牌加密保存在本机 profile.bin；日常调用只发送 access，refresh
  仅在专用刷新 RPC 中短暂经过服务器内存，不写入服务器会话、日志或广播事件。
- 订阅固定使用官方 ChatGPT/Codex，禁止自定义 URL/headers 与重定向；模型列表为内置
  建议，不是账号资格查询。登录/退出立即保存；长任务到期后需由客户端重新发送刷新。
- 上下文数字为活动输入估算，不是全部会话累计 tokens，也不证明网关内部真实模型身份。
- 已做本地 HTTP 授权桩、加密落盘、界面与 Go 测试；真实 ChatGPT 授权/对话、真实
  Windows 窗口交互和 Android 真机尚未验证。未移植 OpenCode 的 WebSocket/zstd。
- 使用本功能需将服务器上的 aurora3-agent 升级至 $Version（连接后点击升级提示即可）。
代理功能：
- 在“代理”页添加 Clash 订阅 URL，或粘贴节点链接；选用节点后，新建终端时勾选
  “这个会话走代理”。git 的 HTTP/HTTPS 远程操作跟随代理服务开关。
- 代理在受控服务器的 agent 上运行，流量不经这台电脑。不会登录、安装或修改代理服务器。
- 已支持 Trojan（TCP/TLS）、Hysteria2（含 Salamander）、VLESS 和 VMess AEAD
  （TCP 或 WebSocket，可加 TLS）。Reality、XTLS Vision、gRPC、h2、XHTTP、端口跳跃、
  旧版 VMess、Shadowsocks、TUIC、AnyTLS 等尚不支持；节点会留在列表并说明原因。
- 订阅 URL 只加密存放在本机；选中节点的凭据会发送给受控服务器，服务器重启后仍可使用。
  “测速”也由受控服务器执行，需要向它临时发送被测节点的参数。
- 订阅更新会在连接恢复后同步已变化的节点；离线变化会保存在本机加密 profile 中。
  代理变量保证在 bash 启动文件之后生效；其它 shell 的启动脚本仍可能覆盖变量。
  已有会话不会因勾选而改成代理会话。
- 连接服务器后会提示可用的 agent 更新，但只有用户明确确认才会执行。新 agent
  通过当前加密连接接收签名版本，等待文件传输结束和 30 秒安静窗口后由独立进程
  切换；失败会自动回滚。旧 agent 会打开 SSH 兼容升级向导，不会静默上传。
- 3.2.0 及更早版本没有直连升级，需要使用 SSH 兼容向导；3.1.1 及更早版本也没有代理服务。

内置 agent：$($m.file)
  版本 $($m.version)，SHA-256 $($m.sha256)
  由发布密钥 $($m.key_id) 签名（agent\amd64\manifest.sig）。

本程序使用 Apache License 2.0（见 LICENSE 和 NOTICE）。第三方组件及许可证见 LICENSES.txt。
"@ | Set-Content -Encoding utf8 "$dir\README.txt"

# 6. Zip and hash.
Compress-Archive -Path $dir -DestinationPath $zip
$shaZip = [Security.Cryptography.SHA256]::Create()
$fsZip = [IO.File]::OpenRead($zip)
$h = -join ($shaZip.ComputeHash($fsZip) | ForEach-Object { $_.ToString('x2') })
$fsZip.Close()
"$h  Aurora-$Version.zip" | Set-Content -Encoding ascii "$zip.sha256"
Remove-Item $work -Recurse -Force
Write-Output "folder: $dir"
Write-Output "zip:    $zip"
Write-Output "sha256: $h"
