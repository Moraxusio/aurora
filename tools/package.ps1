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
#     local-agent\windows-amd64\  signed client-owned Windows backend
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
    $env:GOOS = 'windows'
    & $go build -trimpath -ldflags "-H=windowsgui -s -w -X main.Version=$Version" -o "$work\aurora3-local-agent.exe" ./cmd/aurora3-local-agent
    if ($LASTEXITCODE) { throw 'build Windows local agent' }
} finally { Pop-Location; Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue }
& "$work\aurora3-release.exe" sign --key $Key --version $Version --arch amd64 --file "$work\aurora3-agent" --out "$dir\agent\amd64"
if ($LASTEXITCODE) { throw 'sign' }
# Checked with the release key compiled into the tools, as the client does.
& "$work\aurora3-release.exe" verify --dir "$dir\agent\amd64"
if ($LASTEXITCODE) { throw 'verify' }
& "$work\aurora3-release.exe" sign --key $Key --product aurora3-local-agent --os windows --version $Version --arch amd64 --file "$work\aurora3-local-agent.exe" --out "$dir\local-agent\windows-amd64"
if ($LASTEXITCODE) { throw 'sign Windows local agent' }
& "$work\aurora3-release.exe" verify --product aurora3-local-agent --dir "$dir\local-agent\windows-amd64"
if ($LASTEXITCODE) { throw 'verify Windows local agent' }
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

运行 aurora.exe。Windows 可直接打开本机文件夹，无需服务器或管理员安装。
本地 agent 随客户端启动，完全退出客户端时结束其受管终端和任务，不提供 tmux 持久会话。
优先使用已安装的 pwsh，否则回退 Windows PowerShell；使用用户本机开发环境与代理。
远程开发仍可“添加服务器”，通过 SSH 安装 Linux agent，之后直接加密连接。

- 支持的服务器：Linux x86-64（amd64），需要 systemd。
- 服务器上只使用 v3 的名字：/usr/local/bin/aurora3-agent、aurora3-agent.service、
  /etc/aurora3、/var/lib/aurora3，端口 17710。已有的 Aurora 2（aurora-agent）不受影响。
- 保存的服务器和密码在 %LOCALAPPDATA%\Aurora3\profile.bin，用 Windows DPAPI 加密，
  只有当前 Windows 用户能打开。

本次更新（$Version）：
- 更简洁的深浅色工作台：去掉常驻“编辑组”标题、重复布局按钮和层层圆角面板。
  默认只保留文件、搜索、Git、终端与 AI，低频管理功能在“更多工具”，设置与连接统一入口。
  文件侧栏去重，上传、隐藏文件、排序与大小统计收进“文件选项”；AI 运行统计默认一行、详情可展开。
- 直接拖动标签排序、贴边分屏、跨视图移动；只显示当前落点预览，悬停不改布局，放下才提交。
  标签前后半部决定插入位置，长列表边缘自动滚动，普通鼠标滚轮可横移标签。
  标签栏“…”支持分屏、放大/还原和合并；Ctrl+Shift+Enter 放大/还原，保留原布局树。
  顶部“布局”图形化选择单页、左右、上下、三列、四宫格及标签栏位置，宽度设置按需展开。
- 减少无关工作：隐藏正文保留最后约束，几何更新与文件/AI/终端业务通知分离，拖放指示器独立重绘。
  确定性回归中，30 标签、24 次缩放的隐藏正文布局从 696 次降至 0；240 次宽度更新的业务通知
  从 240 次降至 0，几何通知按帧合并为 1 次。这不是实际设备 FPS 保证。
- 项目文件布局、固定状态和未保存缓冲保护保留；取消或切换项目停止后续批量关闭，旧拖动不影响新标签。
  不保存未保存文字，不自动复活终端进程或 AI 运行任务。真实桌面长期拖放、多屏 DPI、触摸仍待实机验证。
- 补齐既有高亮库的 Dart 语法支持，没有新增依赖。原加密 API Key/OAuth 和服务器配置不迁移、不重置。
- Windows 可直接打开本机文件夹，使用本地 PowerShell、Git 和 AI，无需远程服务器。
  本地 agent 随客户端更新；隐藏到托盘继续运行，完全退出结束受管任务，不提供 tmux 持久会话。
- AI 长历史改为分块加载；工作面板显示子代理、shell 输出和代理来源，状态流可恢复。
  提供商设置支持手动添加/搜索模型，拉取与手动模型合并，可选择本机或当前 agent 网络。
  继续保留原加密配置、API Key 和 OAuth；首次增加本机入口前备份原加密 profile。
- OpenAI / ChatGPT 设备码授权默认走本机网络/系统代理，可切换服务器出口并重试。
  本机刷新不把 refresh 发给 agent；模型请求由当前本地 / 远程 agent 发出。获取设备码时的 403
  不等于订阅无效，更换授权出口不保证解决所有上游限制。Windows PAC-only 暂不解析。
- AI 输入框支持 Ctrl+V/菜单粘贴图片和复制的文件、本机选文件及服务器文件浏览。
  支持 PNG/JPEG/GIF/WebP、PDF、UTF-8 文本/代码；单件 8 MiB、文本 256 KiB，
  每条最多 8 件且合计 20 MiB。粘贴不上传，发送才分块上传；图片/PDF 需要模型支持。
- 附件明文保留在当前 agent 的 AI 私有目录用于历史重放，库限额 512 MiB，不写工作目录；
  删除会话保护共享引用。发送未成功或回退形成的孤儿附件尚无自动清理。
- 新会话工作目录使用项目/根目录下拉和面包屑浏览，不再手输；已有会话目录固定。
- 正文默认 15 px，支持持久化字号、复制回答、惰性历史及流式合帧，读历史不强制滚底，
  中文组词时 Enter 不发送。上下文估算、累计用量、实际模型与下一次选择仍分开显示。
- 继续复用 OpenCode（MIT）的设备码、Codex HTTP SSE 与协议实现；大 ChatGPT 请求
  使用 zstd。尚未移植 WebSocket、browser callback 或 token-sharing。
- 自动化测试与宽屏/手机组件截图通过；真实 ChatGPT 授权/对话、Windows 原生剪贴板
  和 Android 真机尚未验证。令牌仍加密保存在本机，长任务到期需客户端下次调用刷新。
- 本轮 UI 改造本身不要求将已有 3.14.0 远程 agent 升级；随包 agent 统一为 $Version，可由用户确认后升级。
  长历史/执行活动能力仍要求 agent 至少 3.14.0，本地 agent 随客户端提供。
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
