# Windows 本地 agent（D-108、D-119）

本实现与现有 Linux **远程 agent** 分开，不把 Windows 本机伪装成需要 SSH 安装的服务器。

## 使用与生命周期

- 客户端首次启动新增“本机 Windows”入口；已有用户仍恢复原来选择的远程工作区。
- 欢迎页、连接切换菜单和命令面板可“打开本机文件夹”。原生选目录后创建/恢复项目；终端和 AI 使用项目目录。
- 本地 agent 是当前用户下的后台进程，不注册 Windows SCM 服务、不自动提权、不开机自启。便携 ZIP 即可分发；本轮不新增 MSI/Setup 安装器。
- 最小化、切换标签、隐藏到托盘继续运行。明确关闭本地终端结束其进程；完全退出客户端会先提示，再结束 agent 和受管任务。
- 不实现 tmux、跨 agent 重启保活或无人登录运行。历史 AI 会话仍保存到磁盘；终端进程不因“恢复布局”而复活。
- 优先使用 PATH 中的 `pwsh.exe`，否则回退系统 Windows PowerShell。终端使用用户配置；AI shell 使用非交互、NoProfile PowerShell，避免启动脚本干扰工具输出。

## 架构与安全边界

```
Flutter 客户端 → 启动管道交换身份 → 127.0.0.1 随机端口上的固定指纹 TLS/yamux
                                      └─ aurora3-local-agent.exe
                                           ├─ files / search / git / ai / monitor / proxy
                                           └─ ConPTY → PowerShell
```

- 目标类型 `kind: local|remote` 与平台 `platform: windows|linux` 是独立维度。旧 profile/旧 agent 缺类型时仍视为 remote。
- 本地监听严格限定 `127.0.0.1:0`，不宣告局域网地址。每次启动生成随机 token，通过父子进程管道交接，不放命令行、不写 profile；保留原有 TLS 指纹校验。
- 客户端 stdin 管道 EOF 是退出信号。agent 的 Job Object 在异常退出时结束后代进程；每个 ConPTY 和 AI shell 另有独立 Job Object，创建进程时即绑定，取消不通过全机进程名扫描。
- 本地二进制使用单独签名产品 `aurora3-local-agent`，文件名包含 `windows-amd64.exe`，不能被当作远程 `aurora3-agent`。启动前检查签名、哈希、产品、平台命名与启动版本。
- 程序在 `local-agent/windows-amd64/`；状态在加密 profile 所在目录下的 `local-agent/`。状态目录设置当前用户与 SYSTEM 的继承 ACL。Windows 不依赖 chmod 0700/0600 来提供私密性。
- 继续使用原 `profile.bin` 格式与 DPAPI/Keystore，不改凭据密封方式。首次增加本机入口前，保留一份原始**加密字节**备份 `profile.bin.before-local-v1`；不导出明文。AI 设置保存时保留已轮换 OAuth；未在对话框修改的 API Key 跟随最新值，冲突则拒绝覆盖。
- 本地 agent 拥有当前用户权限，**不是沙箱**。默认提供用户目录和固定磁盘根目录；“打开项目”是工作区选择，不意味着把所有 shell 的文件访问限制在项目内。

## 功能与首版限制

- 文件：浏览、读写、etag 冲突检测、创建/重命名/复制/删除、分块上传下载、文本搜索与文件查找。协议继续使用 root ID + `/` 相对路径，Windows 端映射为原生路径；拒绝盘符注入、ADS、保留设备名、越界路径。文件“复制路径”和 AI 目录栏在本地显示 Windows 路径。
- 文件变化通知暂用 800 ms 的有界目录快照，只扫描订阅目录，不递归。不是 ReadDirectoryChangesW；超大目录性能仍需实机评估。
- 本地终端最多 32 个；每个终端有 256 KiB 的本次运行输出缓存。短暂重连回放是尽力恢复，不等同于 tmux 完整屏幕/历史持久化。暂不宣告 `session.capture` 或实时 `session.cwd`。
- Git 使用用户已安装的 Git for Windows，不随包携带 Git；缺失时显示依赖不可用。Node、Python、编译器等也使用用户本机环境。
- 提供文件、搜索、终端、Git、AI、监控和代理入口。目录大小统计、日志 tail、systemd 和端口转发暂不提供，客户端按本地能力禁用相应入口。
- 当前目标是 Windows x64、ConPTY 可用的系统（Windows 10 1809+）；尚无原生 ARM64 本地 agent，UNC/网络共享与可移动盘不在首版“打开文件夹”支持范围内。

## 代理

- 新建本地终端的“网络出口”、AI 提供商的“模型 API / AI 工具的网络出口”可选择：
  - **本机代理**：优先当前用户环境 HTTP_PROXY／HTTPS_PROXY／ALL_PROXY，没有时读取 Windows 手动 HTTP(S) 代理，遵守 NO_PROXY。
  - **Aurora agent 代理**：在本机工作区的“代理”页选择节点，复用现有 Trojan／Hysteria2／VLESS／VMess 代理服务；服务关闭或节点缺失时拒绝创建／请求。
  - **直连**：模型与网页 HTTP 请求不用代理，终端／AI shell 清除继承的大小写代理变量。
- 终端出口在创建时确定，重开同名会话不修改出口；已选择 Aurora 的会话可跟随代理页切换节点。交互 shell 的用户启动脚本仍可能自行覆盖环境。
- AI 子代理、压缩、标题、模型列表、网页与 shell 工具延续提供商出口；远程 agent 的“system”指服务器环境。旧提供商未选择新模式时保持原 `use_proxy` 行为。Git 继续使用本机代理。
- OAuth 的 client/server 授权路径独立保留；server 路径使用选择的代理模式，client 路径使用客户端网络（显式 direct 时直连）。API Key、OAuth 不迁移、不重置。
- 服务开关和节点保存在状态目录 `local-agent.json`，重启恢复；该文件不保存本地连接 token、地址或根目录。退出 agent 关闭其代理监听。
- 工作状态只显示代理来源，不广播代理 URL、账号、密码或完整环境。
- 不解析 PAC-only/WPAD，不保证替第三方 CLI 解决其自身代理配置或网络限制。

## 监控

- CPU、物理内存、提交内存、固定磁盘、进程使用原生 Windows API，无需 PowerShell 轮询或 WMI。
- Windows 不伪造 Unix load；进程首帧 CPU、权限不足的内存等显示未知。用户字段优先保持本地 SID，避免域账号查询阻塞采样。
- NVIDIA 详情与 Linux 共用 `gpu.info`；优先 PATH 中的 `nvidia-smi.exe`，其次 Program Files 下 NVSMI 默认路径，隐藏命令窗口。没有工具时基础监控仍可用。字段、缓存、超时与硬件限制见 [GPU_MONITOR.md](GPU_MONITOR.md)。

## 构建与测试

- `tools/package.ps1` 同时构建 Linux 远程 agent 与 Windows GUI-subsystem 本地 agent，分别签名；没有覆盖任何旧发布产物。
- 单独的 `flutter build windows --release` 只用于客户端验编，**不会自动放入签名本地 agent**，不能把这个输出目录当作完整分发包。完整分发包由 `tools/package.ps1` 组装，发布验收记录见 `docs/PLAN.md`。
- `tools/test-local-agent.ps1` 使用一次性测试签名密钥、独立沙箱和本地 HTTP 桩运行真实 Dart 客户端联调；不打开正式 profile、不使用真实账号、不连接用户服务器。依赖 PATH 中的 Go、Dart、NASM。
- 单元与组件测试不启动真实客户端窗口；真实窗口、Windows PowerShell 5.1 回退、不同 Windows 版本/权限账户、真实上游账号仍需另行验收。

在仓库根目录执行无窗口联调：

```powershell
# 先将本机 Go、Dart SDK 与 NASM 3.02 目录加入当前进程 PATH。
.\tools\test-local-agent.ps1
```

成功标记为 `LOCAL_AGENT_SIGNED_TLS_MONITOR_PROXY_ROUTES_PERSISTENCE_CONPTY_EXIT_OK`。联调包含监控、合成 VLESS 节点、模型请求出口、三种 ConPTY 环境、同名会话保持出口、不可用节点拒绝、配置重启保留及退出监听关闭。脚本自动生成新沙箱，已有路径拒绝覆盖；使用合成代理环境并在 finally 恢复，临时测试私钥同样删除。`3.99.0` 仅是这项签名测试的沙箱版本，不是正式产品版本，也不会更新用户已安装的客户端或远程 agent。
