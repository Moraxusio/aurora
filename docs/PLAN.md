# Aurora 实施计划

设计见 `DESIGN.md`。本文按目标列出要做的事，每个目标完成后在第 4 节记下提交号和验收结果。

## 1. 环境

| 工具 | 位置 | 说明 |
|---|---|---|
| Go 1.26.0 | 本机 Go 安装目录 | 安装包 SHA-256 与 go.dev 一致。构建用 `GOTOOLCHAIN=local`、`CGO_ENABLED=0`，离线时加 `GOPROXY=off` |
| Flutter 3.47.9（Dart 3.13.7） | 本机 Flutter SDK 目录 | zip 的 SHA-256 `d8e2b597…3f68a9e` 与官方发布清单一致。网络受限时可在命令里临时设置 `HTTPS_PROXY`，不改全局配置 |
| Visual Studio 生成工具 2026 | 已装 | Flutter Windows 桌面构建用；`aurora_tls` 的构建钩子用其中的 cl.exe 与 lib.exe |
| NASM 3.02 | 本机 NASM 目录（或 PATH 中的 `nasm`） | `aurora_tls` 在 Windows x64 上汇编 BoringSSL 用。哈希与来源见 `app/packages/aurora_tls/third_party/README.md` |
| WSL 的 gcc/g++ 13.3 | 已有 | Windows 上交叉构建 Linux 版时，构建钩子经 `wsl` 调用 `x86_64-linux-gnu-g++` |
| WSL Ubuntu-24.04 | 已有 | 跑着 v2 agent。v3 的 Linux 测试在这里跑，只用 `/tmp` 下的临时目录，不碰 v2 的名字（DESIGN 第 4 节） |
| Android SDK | 未装 | G5 的 Android 部分开始前安装 |

运行 Linux 测试：在 Windows 上 `GOOS=linux go test -c` 生成测试二进制，复制到 WSL 的 `/tmp`，用 `wsl -d Ubuntu-24.04 -- bash -c "/tmp/x.test -test.v"` 运行（直接把 `-test.v` 传给 `wsl` 会被它当作自己的参数）。

## 2. 停止条件

以下情况停下来报告，不自行继续：

- 需要对外发布、上传，或删除、覆盖任何 v2 的文件或运行中的状态。
- 验收失败且原因不明。不跳过失败的验收。
- 设计与代码现实冲突，需要改变已确认的决定。写成新的决定编号，等用户确认。

## 3. 目标

### G0 准备（完成）

Go 工具链、模块、构建脚本、tmux 构建锁。

### G1 agent 内核（完成）

服务注册表、开关、能力上报、依赖检查；复制 `wire`（协议 3.0）、`update`（v3 公钥）、`netproxy`、`p2p`。

### G2 agent 服务

- G2.1 terminal：会话与终端流，tmux 运行在 `aurora3-tmux-*` 单元里（D-35、D-51、D-52）。
- G2.2 files：完成。
- G2.3 git：完成，含 D-69 的代理规则。
- G2.4 devtools。
- G2.5 net。
- G2.6 monitor：`sys.metrics`、`proc.list`、`log.tail` 已复制；`gpu.info` 等 terminal 的中性接口。
- G2.7 systemd：`svc.info`、`svc.action` 已复制。
- G2.8 proxy：完成（D-47 至 D-50、D-53、D-83 至 D-94）。agent 的代理服务、`session.create` 的 `proxy` 参数、git 跟随服务开关；客户端的订阅解析、节点列表、新建会话的“走代理”勾选。协议：Trojan、Hysteria2、VLESS、VMess（不支持的见 D-94）。
- G2.9 入口：`aurora3-agent run`，TCP 直连监听（17710，D-76）、Hello、yamux、按服务分发，Linux TCP 调优。这是客户端联调的前提，排在 G2.1 之前。
- 验收：每个服务有开关测试；关闭后新操作被拒，已有会话不被结束。

### G3 生命周期

安装四阶段、升级与看门狗、卸载、彻底清除，全部使用 v3 的名字（D-71）。验收：在 WSL 上完整跑安装、升级、回滚、卸载，确认 v2 的文件、单元、端口前后不变。

### G4 tmux

- G4.1 amd64：完成。终端信息目录改为 `/var/lib/aurora3/terminfo` 后需要重新构建（见第 5 节）。
- G4.2 arm64：需要 arm64 真机或 QEMU（D-21）。

### G5 客户端（Flutter）

- G5.1 Flutter 工程骨架，Windows 桌面能构建运行。
- G5.2 协议层（纯 Dart，不依赖 Flutter，放在 `app/packages/aurora_wire`）：帧编解码、yamux 会话、TLS 指纹校验、Hello、请求与流式操作。
- G5.3 协议层联调：对真实 Go agent 测试（WSL），覆盖握手成功、令牌被拒、指纹不符、版本不兼容、并发流、大传输、流量控制、keepalive、对端断开。
- G5.4 TCP 性能：按 DESIGN 5.3 的要求实现，并跑基准测试，与 Go 客户端对比。
- G5.5 凭据存储（D-72）：Windows 先做 DPAPI，其它平台随平台打开。
- G5.6 SSH 与安装向导（D-2、D-3、D-4，G3 的四阶段）。
- G5.7 直连与重连（D-24、D-62）。
- G5.8 界面：服务器列表、服务开关、终端、文件、git、监控。
- G5.9 Android 构建。
- 验收：WSL 上走通"添加服务器、安装、连接、开关服务、卸载"。

### 初版（M1，2026-11-07 与用户确认）

范围：Windows 桌面程序，管理 linux/amd64 服务器。交付形式：本机文件夹，内含程序和签名的 agent，解压即用，不上传（G7.2）。

| 步骤 | 内容 | 状态 |
|---|---|---|
| M1.1 | 直连与重连（G5.7） | 完成 |
| M1.2 | 终端服务（G2.1）：会话、终端流，tmux 在 `aurora3-tmux-*` 单元里，agent 重启和升级时会话不断 | 完成 |
| M1.3 | 卸载（G3.3）：列出活动会话，默认保留配置，停 `aurora3-tmux-*`；彻底清除单独一步 | 完成 |
| M1.4 | 界面一：服务器列表、添加服务器（SSH 安装向导、主机指纹确认、进度）、连接状态与重连、服务开关 | 完成 |
| M1.5 | 界面二：终端（xterm 包，会话列表，断线后自动重新连接） | 完成 |
| M1.6 | 界面三：文件（浏览、上传下载、新建、改名、删除）、监控（CPU、内存、磁盘、进程） | 完成 |
| M1.7 | 打包：签名 amd64 agent，随程序放进文件夹；WSL 上完整验收"添加、安装、连接、终端、文件、开关、卸载"，v2 前后不变 | 完成（2026-11-07） |

初版交付：`release3\Aurora-3.0.0`（及同目录的 zip 和 `.sha256`），由 `tools\package.ps1 -Version 3.0.0` 生成，没有上传。agent `aurora3-agent-3.0.0-linux-amd64` 的 SHA-256 为 `9a44d006a08c5650cab3ba43d400107748a76e0a9964e4c6e94ce791a6408e5e`，用发布密钥 `87828dfb18459372` 签名；两次打包得到相同的 agent，构建可复现。验收：`app\tool\accept_release.ps1` 用这个文件夹自己的 agent（不设测试密钥）在界面里装进 WSL，连接、新建会话、卸载；改动 agent 一个字节后客户端拒绝安装；`ui_test`、`install-real`（64 项）、`terminal-survives`（16 项）、`install-e2e`（24 项）、`terminal-e2e`（15 项）和全部 Go、Dart 单元测试通过；v2 的单元、PID、二进制、配置、端口前后一致。v2 的发布目录，v3 不写入。

不在初版里：Android、git 界面、devtools、net、代理（G2.8）、VPS、arm64 服务器。会话按 root 运行（D-25），`session_user` 在代理之后做。

### G6 VPS（可选）

在客户端 QUIC 之后再做（D-73）。

### G7 测试与发布

- G7.1 先在 WSL 验收，再上 203.0.113.10。两台机器都跑着 v2，v3 用独立名字共存；上测试前后都检查 v2 的状态没有变化。
- G7.2 第一个版本只生成产物和清单，不上传 GitHub Release。上传等用户确认。
- G7.3 v2 到 v3 的迁移在 G7.1 通过后开始（D-58）。

## 4. 进度记录

v3 仓库（`aurora-v3`）的历史提交保留在本仓库里，提交号不变。

| 目标 | 状态 | 提交 | 验收结果 |
|---|---|---|---|
| G0.1 Go 1.26.0 | 完成 | — | `go1.26.0`，安装包 SHA-256 与 go.dev 一致 |
| G0.2 模块与入口 | 完成 | a9c942a | Windows、linux/amd64、linux/arm64 构建通过 |
| G0.3 tmux 锁与脚本 | 完成 | 97a42ec | 与 v2 逐字节一致 |
| G0.4 构建脚本 | 完成 | a9c942a、97a42ec | 校验 tmux 锁，损坏或改动都会使构建失败 |
| G1.1–G1.4 服务注册表 | 完成 | dec8165 | 9 项测试通过 |
| G1.5 wire、update、netproxy、p2p | 完成 | fb93d25、558d845、6cc074c、8b62e40 | 与 v2 一致，只改导入路径、协议版本与公钥；测试通过 |
| G4.1 amd64 tmux | 完成 | 97a42ec | 哈希与 v2 的 bundle.lock 一致 |
| G2.2 files | 完成 | d2238a1、d154fb8、30381fc、1154d1f | 8 项 Linux 测试通过 |
| G2.3 git | 完成 | 6fb8c8b、02d3e54、90ee666 | 9 项测试通过（5 项真实仓库，4 项代理） |
| G2.8 proxy（agent） | 完成 | c7b7108 | VLESS、VMess、Trojan、Hysteria2 对真实 Xray 26.10.31 与 Hysteria 官方服务端互通；会话的代理变量、git 跟随开关；入口死锁一例由测试发现并修复 |
| G2.8 proxy（客户端） | 完成 | a2e5063 | `aurora_sub`（订阅读取）、代理页、新建会话的勾选；端到端 `app/tool/proxy_e2e.ps1`：真实 agent、真实 tmux，会话里的 curl 与 git 都经节点到达（节点是另写的 Trojan 服务端，打印它被要求的目标） |
| G2.6 monitor | 部分完成 | ff90f00 | `gpu.info` 未复制；操作未做行为测试 |
| G2.7 systemd | 部分完成 | ff90f00 | 单元名检查有测试；操作未做行为测试 |
| 内核 `internal/paths` | 完成 | 1154d1f、ff90f00 | 7 项测试通过 |
| Aurora 源码仓库 | 完成 | 227da69 | 克隆 aurora-v3，Go 代码移入 `agent/`，设计文档汇总为 `DESIGN.md` |
| Flutter 3.47.9 | 完成 | — | zip 哈希一致；`flutter doctor` 中 Windows 与 Visual Studio 通过，Android SDK 未装 |
| G2.9 agent 入口 | 完成 | f723936 | 17710 端口（D-76）、Hello、yamux、按服务分发、服务开关写回 agent.json 并审计。10 项测试在 Windows 与 Linux 通过。WSL 端到端：普通用户在 `/tmp` 下运行，fs.list、fs.read、sys.metrics、关闭的服务、错误令牌均符合预期；v2 的单元、二进制、配置、tmux 单元、端口前后一致 |
| G5.2 Dart 协议层 | 完成 | 见 git log | `app/packages/aurora_wire`：帧、yamux（兼容 hashicorp/yamux v0.1.1）、TLS 指纹校验、Hello、请求与流。14 项内存测试通过 |
| G5.3 协议层联调 | 完成 | 见 git log | 对真实 Go 入口（`aurora3-testpeer`）13 项测试通过：握手、令牌错误、指纹不符、无人监听、服务开关、流回显、64 MiB 下载与上传逐字节核对、200 个并发调用、下载进行中的调用延迟、ping 与保活、agent 被杀后的断开原因 |
| G5.4 TCP 性能 | 完成（Linux 下载还有差距，见第 6 节） | 见 git log | TLS 改用随 App 编译的 BoringSSL（D-77，`app/packages/aurora_tls`）。下载从 37–58 MB/s 提到 176–218 MB/s，上传从 55–69 MB/s 提到 185–346 MB/s，下载中按键回显 p50 从 13 ms 降到 0.2–1.2 ms。`aurora_tls` 6 项测试（对 Go 的 crypto/tls）、`aurora_wire` 27 项测试全部通过；Windows 构建与 Linux 交叉构建（经 WSL 的 gcc）都由构建钩子完成，未改 Flutter 引擎 |
| G3.1 安装四阶段 | 完成 | 见 git log | `agent/internal/install`，命令 `aurora3-agent install --sha256 HEX [--name] [--user] [--probe]` 和 `aurora3-agent direct-info`（D-4）。输出 JSON 行：每阶段开始与结束，最后是结果；退出码 0 成功、1 拒绝且未改动、2 已回滚、3 回滚未完成。探测不改任何东西，普通用户也能跑；已装版本不低于本次时不改动（D-12）。准备阶段只写 `/var/lib/aurora3/install-*`：复制程序并核对 SHA-256、运行 `version` 核对版本、新装时生成配置并读回、`systemd-analyze verify` 单元。切换前把原状态存进 `rollback-*`，新文件先写在目标旁边，再 rename 提交。确认阶段对本机端口做带指纹的 Hello，并核对版本（D-38）。失败则回滚并再次确认原服务；回滚目录只在确认通过后删除，否则保留并报告，下次安装拒绝（D-17）。安装锁防止两个安装同时运行；SSH 断开时忽略 SIGHUP 和 SIGPIPE，四阶段照样完成或回滚。升级保留 agent.json、证书和令牌。测试：48 项（假 systemd，覆盖 4 种起始状态 × 7 个失败点，逐字节核对回滚后的文件和服务状态）；WSL 上以 root 真实运行（`agent/tools/install-real.ps1`）：普通用户探测、错误哈希、安装、direct-info、同版本、升级、坏版本回滚（33 秒）、SSH 中途断开，全部通过，结束后删除全部 v3 文件，v2 的单元、PID、二进制、配置、端口前后一致 |
| G5.7 直连与重连 | 完成 | 见 git log | `aurora_wire` 的 `Connection`：按顺序试每个地址，上次成功的地址排在最前；网络失败等 2、5、10 秒重试，共 4 轮后报告；令牌被拒、指纹不符、版本不兼容立刻报告，不重试，也不再试其它地址（D-24、D-62）。连接断开后自动重新拨号；`retryNow` 跳过等待，`close` 停止。`aurora3-testpeer` 加 `-state`，重启后保持同一身份。12 项测试，其中 3 项对真实 Go 入口：agent 被杀后重启，连接自己恢复；错误令牌；证书变了 |
| G2.1 terminal | 完成 | 见 git log | `agent/internal/terminal`，移植 v2 的会话和终端代码，改用 v3 的名字：tmux 套接字 `aurora3`，tmux 服务器在 `aurora3-tmux-*` 单元里（D-35），内置 tmux 3.8 嵌进 agent（`internal/bundle`）。操作：`session.list`、`session.create`、`session.cwd`、`session.capture`、`terminal`（流）；`session.kill` 挂在入口上，服务关闭时仍可用（D-52）。关闭服务会断开已连接的窗口并说明原因，会话不结束（D-51）。Dart 端 `Terminal`（按键走交互优先级）。测试：Go 5 项（内置 tmux、建立和结束会话、打字、调整大小、ping、断开后再连、shell 退出、关服务、结束忽略 SIGHUP 的进程）；Dart 对真实 agent 的端到端 15 项（`agent/tools/terminal-e2e.ps1`，普通用户、/tmp、17790 端口），30 万行输出 276 ms，之后 ping 0.4 ms；WSL 上真实安装（`agent/tools/terminal-survives.ps1`）：会话里的进程在 agent 重启和升级后都还在，tmux 不在 agent 的 cgroup 里，`session.kill` 结束进程和单元，v2 不变 |
| G3.3 卸载 | 完成 | 见 git log | `aurora3-agent uninstall [--probe] [--force] [--purge]`：先列出 tmux 会话，有会话又没有 `--force` 时不做改动并报告（D-31）；默认停服务、停全部 `aurora3-tmux-*` 单元（D-37）、删程序和单元，保留 `/etc/aurora3`、`/var/lib/aurora3`（D-32），之后重装令牌和指纹不变；`--purge` 再删配置、状态和 `/usr/local/lib/aurora3`（D-33）。按步骤执行，失败时报告已完成的步骤，不回滚，可重试（D-34）。客户端 `Installer.uninstall`。测试：Go 7 项（含失败步骤、v2 文件不动），Dart 2 项；`install-real.ps1` 增加真实卸载：有会话被拒、`--force` 停掉 tmux 单元、配置保留、重装后指纹和令牌不变、`--purge` 全部删除，v2 不变 |
| G5.8 界面（初版） | 完成 | 见 git log | Flutter Windows 程序（`app/lib`）：左侧服务器列表，右侧终端（xterm 4.0.0）、文件、监控、服务开关、概览（重新配对、卸载、彻底清除）；添加服务器向导：SSH 密码或私钥，第一次连接显示主机指纹并要求确认，密钥变了就停止并说明，各阶段进度，按用户选择加密保存密码（D-1、D-2、D-6）。标签页切走后保留状态；终端一连上就按窗口大小，断线和 agent 重启后自动重新连接。测试：`app/tool/ui_test.ps1`（真实 agent，普通用户，5 个页面，连续 5 次通过，并截图核对）；`app/tool/install_ui_test.ps1`（真实 SSH 服务器和真实安装：在界面里填表、确认指纹、看到 8 个阶段、连上、新建会话、从概览卸载并确认会话），v2 不变 |
| G5.6 SSH 与安装（不含界面） | 完成 | 见 git log | `app/packages/aurora_install`：用 dartssh2 登录（密码或私钥），主机密钥在发送任何凭据前交给回调决定（D-2），不符时停止。签名清单按 Go 的 `update.VerifyFor` 同样的规则校验：v3 发布密钥的 Ed25519 签名（BoringSSL 实现，`aurora_tls` 新增）、key_id、产品 `aurora3-agent`、渠道、文件大小与 SHA-256（D-3）。读取架构和 root/sudo 情况，上传到 `mktemp -d` 建的私有目录，以 root 运行 `aurora3-agent install`，把各阶段转成进度，读回直连参数（D-4）；sudo 密码只走标准输入，不进命令行（D-6）。上传用 exec 加 `cat`，不依赖 SFTP。`update.ProductAgent` 改为 `aurora3-agent`；新工具 `aurora3-release`（sign、verify、pubkey）和测试用 SSH 服务器 `aurora3-sshpeer`。测试：Dart 19 项（Go 签名的清单与 6 种篡改、sudo 与 root 的命令、拒绝条件、结果解析），Go 4 项；WSL 端到端（`agent/tools/install-e2e.ps1`）两种登录各跑一次：root 登录，以及普通用户加密码 sudo（临时用户，测完删除）。都覆盖了错误主机密钥、错误密码、安装、direct-info、直连到新 agent，全部通过，v2 不变 |
| 3.1.0 终端输入、内核与功能、IDE 界面 | 完成（2026-11-08），未发布 | 5b0e76f、628639f、d74242f | 终端打不了字：Flutter Windows 引擎要求文本输入客户端带 view ID，xterm 4.0.0 没带，字符一个也到不了终端，而 Enter、方向键、Ctrl+字母不受影响；xterm 收进 `app/third_party/xterm`（MIT，两处标注的改动，见其中的 AURORA.md），测试去掉了以前对这个错误的过滤，改成从 Windows 键盘路径（SendInput，中文按 Unicode 包）输入 30 行逐行核对，去掉补丁则测试失败。agent：`net` 服务（`net.ports`、`net.dial`），systemd 的 `svc.list` 和 `agent.actions`（D-81），`net.ports` 同端口选取固定。客户端按内核与功能重写（D-78），IDE 布局和鼠标、触控两套尺寸（D-79），文件编辑器（D-80）、git、systemd 与日志、端口转发（D-82）。测试：整窗口对真实 agent（终端输入、编辑与被拒绝的保存、git 差异与提交、systemd 列表、转发带字节、三种宽度）通过；Dart 单元 12、`aurora_wire` 44（含转发 5）、`aurora_profile` 20；Go 在 WSL：install 55、entry 11、files 9、paths 8、systemd 3、netfwd 7、git 9、terminal 5（连跑 40 次）；`install-real` 64、`terminal-survives` 16、`install-e2e` 24、`terminal-e2e` 15；v2 前后不变 |
| G5.5 凭据存储 | Windows 完成，其它平台未做 | 见 git log | `app/packages/aurora_profile`：服务器、SSH 登录（含 sudo 密码，D-6）、直连参数（D-22）和客户端自己的 known_hosts（D-2）存在同一个加密文件里，原子写入（同 v2 的 `client.Store`）。Windows 用 DPAPI 当前用户范围，经 FFI 调用 `crypt32.dll`，带固定的 entropy，其它程序为同一用户加密的数据（包括 v2）打不开。文件头记录加密方式，打不开的文件不会被覆盖，只能由用户选择移到一边重来。没有明文实现：其它平台的 `platformSealer()` 直接拒绝（D-72），WSL 中已验证。20 项测试通过，包括 DPAPI 往返、1 MiB、篡改检测、不同 entropy 打不开 |

### 3.2.0 打包前回归（2026-11-08）

- 新增 `app/tool/proxy_ui_test.ps1` / `integration_test/proxy_ui_test.dart`：真实 Windows 窗口、真实临时 Linux agent（17796）、独立测试 Trojan 节点、本地 HTTP Clash 订阅；从界面添加 URL、不可用节点不能选、跳过证书校验需确认、单节点和批量测速、选用节点、勾选并创建会话，实际 bash 里核对代理环境。
- 窗口测试发现代理页的真实缺陷：每次重建节点行都丢失测速结果。修复单节点与批量操作的 `_timed` 缓存；修复前断言“显示毫秒数”失败，修复后通过，选节点重建后结果仍在。
- 原有 `ui_test.ps1 -TypingLines 6` 通过：终端输入、文件保存/冲突、git、systemd、端口转发、宽度切换；6 行无干扰、无错误。应用单元测试 53 项通过，专用端到端 2 项不在该轮运行；agent 对真实 Xray 与 Hysteria 的互通以及 entry、proxysvc、发布签名测试通过，Linux `go vet ./...` 通过。
- 打包脚本识别自有 `aurora_sub` 包，第三方 `yaml` 许可证正常收录；README 写明支持范围、手动订阅刷新、非 bash 限制、HTTP/HTTPS git 与旧 agent 需更新。计划产物为 `release3/Aurora-3.2.0`，不得覆盖旧包，不上传。
- 此次不进行真实安装；测试 agent 使用临时配置，不更改用户的 3.1.1 身份或二进制。真实机场订阅和公网节点仍未验证。

### 3.2.0 本地交付（2026-11-08）

- 已从干净提交 `f587bca8119c768db4924f58e29ea2b7a665356e` 构建：`release3\Aurora-3.2.0`、同名 ZIP 及 `.zip.sha256`。Windows 客户端文件版本和产品版本均为 3.2.0；agent 为 linux/amd64，Go 构建信息记录 `vcs.modified=false`。
- ZIP：20,167,370 字节，SHA-256 `ecba62afbaed92016a5db75009943acd67793714d3cb70ece87eccd3070f989c`。内置 agent：12,726,434 字节，SHA-256 `c06c628bde167baf67ab8841138e49152e656a7ee3a1bdd55b710ed19cc964bb`，发布密钥 ID `87828dfb18459372`。
- 客户端 `aurora_install/test/e2e/verify_build.dart` 使用正式发布公钥接受原包；临时副本里同大小的 agent 字节篡改被 SHA-256 检查拒绝，清单版本篡改被签名检查拒绝，原包未改。
- `proxy_ui_test.ps1 -AgentFile <包内 agent> -ExpectedVersion 3.2.0` 通过：实际运行的是包内 agent，但窗口客户端是 integration_test 调试构建，不把它称作对打包 Release 客户端的完整界面验收。
- ZIP 内未发现测试 peer/node、外部 Xray/Hysteria 程序、profile、私钥或日志。`yaml`、Hysteria、WebSocket 等许可证已收录。
- 隔离核对前后一致：v2 服务 PID 173、端口和文件状态，用户已安装的 v3 身份与 3.1.1 二进制、本机 profile 哈希；v2 发布目录仍为 13 项。未上传、未替换任何正式安装，未做 SSH 安装向导的再次安装验收。

### 可靠性、升级与凭据收尾（2026-11-09，未打包）

- D-95 已落地：服务开关用独立串行锁，保存 `agent.json` 后才调用服务钩子，修复代理保存/开关的锁顺序死锁；代理监听凭据同步保存，不再有可能覆盖新状态的后台写入。客户端订阅选择增加加密 profile 内的 `pending`、`revision`、`sync_error`，按服务器串行选择/清除/补发；在线刷新自动补发，离线变化跨 AppState 重开保留并在重连后同步，旧响应不能清掉新 revision。能力检查只发送固定占位值及 UTF-8 长度/格式事实，测速和实际选择仍临时发送真实凭据。tmux 会话保存 `@aurora3_proxy` 标记，旧会话显示未知；关闭代理前显示已知受影响会话、名称和未知数。
- D-96 已落地：连接后只提示版本，不自动上传；新 agent 经 TLS/yamux 接收签名 manifest、agent 和签名撤回策略，重新校验架构、大小、SHA-256、`min_from`、`revoked`、`min_ok`；仅当前版本已撤回时允许安全降级。文件传输结束后等待 30 秒安静窗口，最长 15 分钟；独立 `systemd` worker 使用现有四阶段安装器，状态持久化，worker 超时/失联会记失败目标并拒绝盲目重推，结果不携带直连令牌。旧 agent 明示打开 SSH 兼容向导。新增 Dart→Go 真实上传联调，客户端重连可查询回执，终态不会被迟到的 `starting` 覆盖。
- 回归证据：Go `update/upgrade/entry/proxysvc/service/netproxy/wire` 定向测试通过；Linux 交叉测试 `install` 57 项、`terminal` 14 项通过；App 全包 61 项通过（代理 E2E 专用脚本的 2 项按环境跳过）；`aurora_install` 8 项通过、`aurora_profile` 26 项、`aurora_sub` 39 项、`aurora_wire` 23 项通过；新增可靠性模型 5 项、Dart→Go 升级联调 1 项通过；Flutter analyze 无问题。Windows 原生 `go test ./...` 仍只受既有 Linux-only `internal/files/search_text.go` 引用 `paths.SkipDirs` 影响，Linux 测试已覆盖相关安装/终端路径。
- 真实窗口证据（运行会抢焦点）：当前 agent 窗口测试通过版本提示、用户取消升级、代理会话数量/旧会话未知数、关闭代理取消与确认；旧 3.2.0 agent 窗口测试通过版本提示及 SSH 兼容升级入口。测试夹具、临时 agent、节点和 tmux 均已清理。
- WSL 真实升级验收（使用本轮最新代码重建 fixture）通过：正常直连升级、30 秒安静窗口、客户端提交后断开、坏版本回滚、失败目标拒绝重推、普通降级拒绝、签名撤回后的安全降级；tmux 进程全程存活。验收后已恢复原 3.1.1 二进制、配置、证书和 `agent-id`，并再次确认 v2 PID/端口/文件状态不变。没有生成新发布包，没有上传。
- 仍未验证：公网 203.0.113.10、真实机场订阅/真实节点、arm64 真机、Android/macOS/iOS；这些不因本轮本地和 WSL 验收而宣称完成。

### 3.3.0 本地发布包（2026-11-09）

- 已由提交 `ade6c70` 及其父提交构建到 `release3\Aurora-3.3.0`，没有覆盖 3.2.0，也没有写入 v2 的发布目录。
- ZIP：20,220,073 字节，SHA-256 `5a9ee4e2d164ba9e3c50d7c97e18ce6e6d1427c0ffa94afb980f4c8e5c37cc47`。
- 内置 agent：12,796,066 字节，SHA-256 `3d6cbf888573fbf7f428bc140e17967e276b3ecaa0468c6d495e34d73d836efa`；manifest 版本 `3.3.0`，发布密钥 ID `87828dfb18459372`。正式 Go 发布工具验签和无测试密钥的 Dart `AgentBuild.open` 验签均通过。
- 包内 `agent/policy.json`、`policy.sig` 的正式公钥验签通过，篡改策略被拒绝；ZIP sidecar SHA-256 匹配。包内 19 项文件中未发现测试 peer/node、fixture、profile、私钥或真实凭据文本。
- 仅生成本地文件，未上传 GitHub、未上传服务器；公网 202 和真实机场仍未验收。

### 3.3.1 本地发布包（2026-11-09）

- 从干净提交 `5c5aa4364eb110777d35065285d5860edb4150dd` 构建到 `release3\Aurora-3.3.1`、同名 ZIP 和 `.zip.sha256`。包含终端滚轮生命周期、密集彩色绘制、IME 通知、页面配置保留、服务器快照及大型订阅列表优化。修复在客户端生效，现有 3.3.0 agent 不必为了这些显示/滚轮修复立即升级。
- ZIP：20,233,146 字节，SHA-256 `0bd6b374d344d871d5639efd1b16c7ed8280bd3dd1bddeb74f7b09efc24a2b3c`；sidecar 匹配，CRC 检查通过，ZIP 的 19 个文件与产物目录逐字节一致。
- 内置 linux/amd64 agent：12,796,066 字节，SHA-256 `a2204ee860af15d19aadb388b98aaaaa9857f7435ed4e02b8c3ad881888c9a44`，版本 3.3.1，签名密钥 ID `87828dfb18459372`；Go 构建信息 `vcs.modified=false`。Go 发布工具和 Dart 客户端正式公钥验签通过，策略验签及普通降级拒绝通过；临时副本中的同大小 agent 篡改、清单及策略字节篡改均被拒绝，原包未改。
- Windows 文件版本/产品版本均为 `3.3.1.0`；客户端 AOT 文件 `data/app.so` SHA-256 `c907ef5aa3590bdbf26b4b62bb7f36bad9faf60d1ae8560abfa068caa069096b`。包内未发现测试 peer/node、fixture、profile 或私钥文件。性能与完整窗口回归为第 6.0 节所述的 Profile 构建验收，不将此次静态发布包校验称为 Release 客户端的再次完整交互验收。
- 只更新本地发布产物，没有上传、没有替换正式客户端进程或服务器 agent；旧 3.3.0 ZIP 哈希不变，v2 发布目录仍为 13 项。公网 202 和真实机场仍未验收。

### 项目工作区、文件树层次、托盘常驻与新图标（2026-11-10，未打包）

- 设计见 D-97、D-98。用户选择“项目工作区”和“托盘常驻”，不做独立守护进程、开机自启或崩溃自动重启。
- 已实现：profile 新增 `ProjectWorkspace`/`WorkspacePath`/`WorkspaceView`（旧 profile 读取兼容，空视图不写键）；`Workspace` 的项目成员关系、串行项目变更、合并静默视图保存；文件树改为按工作区缓存的虚拟列表，带类型图标、目录引导线、路径层次；窄窗口切换侧栏不再卸载编辑器；Windows 单实例、托盘、Explorer 重启重建、托盘不可用退路；原创 A+3 图标（`tools/icon3.py` 由标准库生成 PNG 与 9 档 ICO，不复制 v2）。
- 已验证：`flutter analyze` 无问题；App 单元/组件测试 78 项通过（含新增工作区模型 10 项、文件树组件 7 项、托盘 Dart 桥 1 项；代理 E2E 与升级 E2E 因环境变量按设计跳过）；`aurora_profile` 32 项通过（含 DPAPI 加密往返、路径穿越/NUL 拒绝）；Windows debug 构建通过；`app/tool/tray_test.ps1` 隔离验收 9 项通过（唯一实例标识、临时 profile：点叉隐藏且进程存活、二次启动唤回原窗口并自行退出、托盘退出命令结束进程）。
- 测试中定位并修复的真实缺陷：工作区通知在 `AppState` 同步通知栈内重入，改为排队派发；删除从未打开过的工作区会丢失已保存的文件引用，现并入“浏览服务器”；关闭标签的异步确认期间切换工作区会改写错误工作区的视图，现按发起时的工作区记录。
- 未验证：真实窗口里的工作区多文件夹交互与截图、托盘退出时脏缓冲保护的真实窗口路径、Explorer 重启与托盘不可用的真实演练、新图标在任务栏/托盘实际缩放下的观感、大型目录下的性能 Profile 复测。这些不因单元与隔离测试而宣称完成。
- 该节的改动已随 3.4.0 本地发布包交付（见下节）；没有上传，不替换正在运行的客户端或服务器 agent。

### 3.4.0 发布包（2026-11-10，已发布到 GitHub Release）

- 历史已脱敏并强推：提交信息与全部文件中的本机路径、测试服务器地址与主机名、本机代理端口、用户名均已替换为中性值；旧 Release 与旧标签已删除。发布包在中性路径从已推送的 `main`（`39ab01c`）干净克隆后重新构建，包内未检出这些字符串。内容：项目工作区、文件管理器层次、Windows 托盘常驻与单实例、新图标。改动都在客户端，已有 agent 不必为此升级。
- ZIP：20,242,531 字节，SHA-256 `8b6b449fef018ca0e4c8dd6d23e635afa391a4f85873f2a75c721f44aa40194e`，sidecar 与重新计算一致，从 GitHub 重新下载后哈希一致；ZIP 的 20 个文件与产物目录逐字节一致（0 处差异）。Windows 文件版本和产品版本均为 3.4.0。
- 内置 linux/amd64 agent：12,796,066 字节，SHA-256 `aba90b6b6c5e8d63a627536aeaf75601b9b8c89a653c41d698d80850341595cd`，版本 3.4.0，发布密钥 ID `87828dfb18459372`。tmux 内置包与 `bundle.lock` 一致；Go 发布工具验签通过；无测试密钥的 Dart `AgentBuild.open` 验签通过（`ok aurora3-agent 3.4.0 amd64`）。
- 验签：无测试密钥的 Dart `AgentBuild.open` 对重打的包验签通过（`ok aurora3-agent 3.4.0 amd64`）。篡改拒绝（同大小 agent 字节翻转、清单版本改动均被拒绝）是在上一次构建的同源包上验证的，重打后未重复这一项。包内有新图标资源 `aurora3-256.png`；未发现私钥、测试 peer、fixture、profile、订阅或日志文件。
- 未改动的旧产物：3.3.1 ZIP 的 SHA-256 仍为 `0bd6b374d344d871d5639efd1b16c7ed8280bd3dd1bddeb74f7b09efc24a2b3c`，v2 发布目录仍为 13 项。
- 未验证：托盘隔离验收（9 项）跑的是 debug 构建，没有对打包出来的 Release 客户端再做一遍；真实窗口里的工作区交互、Explorer 重启与托盘不可用、新图标在任务栏/托盘各缩放下的观感、大目录性能 Profile 复测都未做。公网 202、真实机场订阅/节点、arm64、Android/macOS/iOS 仍未验收。
- 已作为 GitHub Release `v3.4.0` 发布 ZIP 与 `.zip.sha256`；未替换正在运行的客户端或服务器 agent。

## 5. 第三方依赖（DESIGN 5.9：只用 MIT、BSD、Apache-2.0）

| 包 | 版本 | 许可证 | 用途 |
|---|---|---|---|
| BoringSSL（C/C++，随 App 编译） | 0.20261020.0 | Apache-2.0 | 客户端 TLS 1.3（D-77）。来源与哈希见 `app/packages/aurora_tls/third_party/README.md` |
| ffi（Dart 团队） | 2.2.0 | BSD-3-Clause | 原生内存分配；`aurora_profile` 调用 DPAPI |
| dartssh2 | 4.1.0（锁定） | MIT | 安装与重新配对时的 SSH（G5.6）。pub.dev 包的 SHA-256 `39359ace…7c84c51` 已核对 |
| pointycastle、pinenacl、asn1lib、convert、meta（dartssh2 的依赖） | 4.0.0、0.6.0、1.6.8、3.1.2、1.19.0 | MIT | — |
| golang.org/x/crypto/ssh（Go，只用于测试工具 `aurora3-sshpeer`） | 0.58.0 | BSD-3-Clause | 不进 agent |
| xterm | 4.0.0（锁定） | MIT | 终端渲染（G5.8）。最近一次发布 2024-02，在 Flutter 3.47 上编译和运行通过 |
| file_picker 及其平台包 | 13.3.2 | MIT | 上传时选文件、下载时选文件夹 |
| dbus（file_picker_linux 的依赖） | 0.8.0 | MPL-2.0 | 只在 Linux 版里用于文件对话框。2026-11-07 用户同意例外：与 hashicorp/yamux 一样，不修改它，随程序附上许可证 |
| Flutter 应用的其它运行时依赖（共 50 个） | 见 `app/pubspec.lock` | MIT、BSD-2/3-Clause、Apache-2.0 | 2026-11-07 逐个核对 pub.dev 上的许可证原文；发布文件夹里的 `LICENSES.txt` 按包列出 |
| hooks、code_assets、native_toolchain_c（Dart 团队） | 2.2.0、2.1.0、0.19.5 | BSD-3-Clause | 构建钩子，只在构建时用 |
| NASM（构建工具，不进安装包） | 3.02 | BSD-2-Clause | 只在 Windows x64 上汇编 BoringSSL；位于 本机 NASM 目录（或 PATH 中的 `nasm`） |
| github.com/hashicorp/yamux（Go） | 0.1.1 | MPL-2.0 | agent 端多路复用，沿用 v2 |
| github.com/apernet/hysteria/core/v2（Go） | 2.13.0 | MIT | 代理上游，沿用 v2 |
| github.com/apernet/quic-go（Go，间接） | — | MIT | p2p、hysteria |
| github.com/coder/websocket（Go） | 1.8.15 | ISC | 沿用 v2；现在也用于 VLESS 与 VMess 的 WebSocket 传输 |
| golang.org/x/crypto（Go） | 0.58.0 | BSD-3-Clause | 已有；VMess 用其中的 chacha20poly1305 与 sha3，Hysteria2 的 Salamander 混淆用 blake2b |
| yaml（Dart，aurora_sub） | 3.1.4 | MIT | 读 Clash 配置的 `proxies:` 段 |
| github.com/creack/pty（Go） | 1.1.24 | MIT | 终端，沿用 v2 |
| github.com/klauspost/compress（Go） | 1.17.9 | BSD-3-Clause | 已有间接依赖改为直接使用；ChatGPT Responses 大请求的 zstd 压缩（D-107） |
| golang.org/x/net、x/sys、x/crypto（Go） | 见 go.mod | BSD-3-Clause | — |

开发依赖（`test`、`lints`、`flutter_lints`）不进入发布产物。hashicorp/yamux 和 dbus 是 MPL-2.0，属于文件级弱 copyleft：只要求修改过的该库文件本身开源，我们没有修改它们。ISC 与 MIT 等价。Dart 端的 yamux 是按协议自行编写的，没有复制 hashicorp/yamux 的代码。

## 5.1 已知待办

- tmux 构建脚本里的终端信息目录是 v2 的 `/var/lib/aurora/terminfo`（`agent/tools/tmux/build-in-container.sh`）。v3 要改为 `/var/lib/aurora3/terminfo` 并重新构建 tmux（需要 Linux 主机上的 Docker）。现在 terminal 服务给 tmux 和会话都设了 `TERMINFO_DIRS`，指向 v3 的目录，实测正常，所以不阻塞初版。
- terminal 服务还没有 v2 的这些部分：会话按 `session_user` 运行、代理变量（G2.8）、`/etc/profile.d` 钩子（登录 shell 重设 PATH 后恢复内置 tmux）、重启后恢复会话、会话内搜索。初版之后补。
- `update/local.go` 的 Windows 路径是 v2 桌面端的 `%LOCALAPPDATA%\Aurora`，没有任何代码调用它。Flutter 客户端有自己的更新方式，这部分在 G5 中删除或改写。
- G5.5 其它平台的加密实现（D-72）：Android Keystore、macOS/iOS Keychain、Linux libsecret。都按 `Sealer` 接口接入，平台打开时（G5.9 等）再做。Linux 需要 libsecret 和一个密钥服务（如 gnome-keyring）；WSL 的 Ubuntu 两者都没装，测试前要先装，或另找一台桌面 Linux。
- 配置文件在 Windows 以外的路径由 App 用 path_provider 给出，接入界面时再定。
- 把签名的 agent 打进客户端安装包（D-3、D-14）：`aurora3-release sign` 已能产出签名目录，Flutter 应用怎样带上 amd64、arm64 两份并在运行时找到它们，在 G5.8 接界面时做。arm64 版要等 G4.2 的 tmux。
- 安装向导的界面（输入地址账号、显示主机指纹请用户确认、显示各阶段进度）属于 G5.8；`aurora_install` 已提供需要的回调和结果。
- 203.0.113.10 的 SSH 端口从本机可达，但没有在它上面跑过安装。真机安装（非 WSL，G7.1）经用户同意再做。
- 初版之后：v2 和 v3 用同一个图标（取自 v2 的 `cmd/aurora/winres/aurora.ico`），任务栏里分不出；可加“3”标记。终端会话按 `session_user` 运行、代理（G2.8）、Android、arm64。`docs/PLAN.md` 第 6 节的 Linux 下载速度。
- 3.1.0 界面（D-78 至 D-82）还没有的部分：触控模式（44 px 行高、终端按键条）只在代码里，没有截图核对；devtools 服务（G2.4）没有客户端；git 的储藏、标签、冲突三方合并没有界面（agent 有操作）；文件树不支持拖放上传和多选；终端里的搜索。
- 终端输入偶发丢字符（2026-11-08）：**很可能是测试时用户同时在用这台电脑，不是程序丢的，但只证明了一半。**
  - 经过：整窗口测试里 40 行曾有 2 行少一个字符或多一个字符（`TYPED9` 变成 `TYPE9`，`$(((` 少一个 `(`），另有一次命令前多了一个 `s`。用户自己也发现过输入框里多出一个 `D`，对得上。测试在 xterm 交给连接的处理函数之前记录它的输出，两次都已经少了，所以丢在连接之前：按键落进了另一个窗口，或别的窗口抢了焦点，不在网络、agent、tmux。
  - 办法：测试加了旁观进程（`app/tool/watchinput.ps1`）。低级键盘钩子里没有 injected 标志的按键算“有人在打字”，前台窗口离开被测程序算“焦点被抢”。受干扰的行单独计数，不算程序出错。
  - 结果：整窗口 100 行连续输入，1 行受干扰，**其余 99 行全部正确，没有一行在无干扰时出错**。
  - 已验证：焦点被另一个真实窗口抢走会被识别（`-DisturbAtLine`，`app/tool/focus_thief.ps1`），被抢的那一行没有算成程序出错。
  - **未验证**：真人按键是否被识别为干扰，脚本无法产生非 injected 的按键，需要人在测试时按一下键。这一轮没有人碰键盘，所以“程序自己不丢字符”也只是一轮的结果。
  - 再遇到时：`app/tool/ui_test.ps1 -TypingLines N -TypingOnly`，看输出里 `TYPING:` 那一行。
- 关于会话的 agent 测试 `TestKillEndsProcessesThatIgnoreHangup` 以前约 1/6 的概率失败：测试用回显的命令行来取进程号，命令行里的标记没拆开，回显就被当成了结果。已修，连跑 40 次通过。
- G3.1 坏版本回滚要等确认超时（30 秒）。可以在服务进入 failed 状态时提前结束等待，属于优化项。

## 6. TCP 性能基准

### 6.0 终端滚轮与页面切换（2026-11-09，客户端修复，未打新包）

- 用户报告：在 Aurora 3 的终端内运行 OpenCode 时滚轮卡顿/偶发失灵，切换功能页掉帧。此次仅改客户端和测试代码；v2 只读参考，没有修改 v2、安装 agent 或正式服务器状态，Flutter 引擎没有重建。
- 已复现并修复：xterm `InfiniteScrollView` 换 position 时没有迁移 `_onScroll` 监听；切回备用缓冲区保留旧滚动计数（一格向下会发出 80 多个向上报告）；有 IDE 侧栏偏移时将全局坐标当局部坐标（测试第 5 列被报成第 22 列）。改为正确迁移监听、重置计数、局部坐标及增量像素累计，保留触控板的不足一行输入，不因改变字体重放旧输入。
- 渲染层：单纯字符/光标变化只重绘，滚动范围或缓冲区尺寸变化才布局；IME 位置在实际绘制后按帧合并并去重，不给后台未绘制终端持续发平台消息。合并同色背景与严格等宽的单格 ASCII 文本段，缓存有界；中文/emoji/宽字符和不能保持网格的字体回退逐格绘制。临时的固定 8 ms 输出缓冲已撤掉，不以增加交互延迟换取表面平滑。
- 页面层：缓存已保留侧栏/编辑器的 widget 配置并隔离 repaint，纯切页不重建其它页面；真实连接、profile、服务和 inherited theme 变化仍刷新配置。服务器快照只复制所读服务器，不再为查一个名称/升级提示复制全部机场节点；返回值仍为隔离副本，失败升级列表也不共享可变 List。代理节点行用 `SliverList.builder` 按需创建。
- 可复现对比：`app/tool/switch_perf.dart OUT.json [TARGET.dart]` 用 CMD 启动 `flutter drive --profile`，对真实普通用户临时 WSL agent 测量，不读用户 profile。基线为 `9bc0624` 的独立 worktree，双方同一夹具（2000 个合成节点、相同页面、真实 tmux 和系统字体）。空闲切页不能冒充终端负载，分别测量：
  - 含大型代理页的切标签：UI build 最慢由 8.1–15.0 ms 降至 1.1–1.5 ms；首次代理页由 28.0 ms 降至 16.3 ms。
  - 连续彩色全屏重绘中，原生 Windows 鼠标滚轮五组各 12 格，程序在 tmux 内每组实际收到 56 个同向报告、0 个反向报告；覆盖退出重进、10 次标签切换和侧栏宽度变化。
  - 同负载基线 raster 最慢 77.9–107.5 ms，每组 12–13 个超过 16.7 ms 的 build/raster 慢帧；修复后两轮 raster 最慢 4.7–8.3 ms，五组均 0 个慢帧。重绘时切标签的 build 由约 8.5–13.1 ms 降至 0.9–3.6 ms。数据是本机这轮实测，不声称任何机器都零掉帧。
- 验证范围：像素对照覆盖 ASCII、中文、emoji、粗体/暗色/反色/斜体/下划线、不同背景及 1/1.25/1.5/2 倍缩放；真实 Windows Consolas、Courier New、Arial 对照通过（无超过 3 色阶的通道差异）。真实窗口完整回归通过：6 行 Windows 中英文键盘输入无干扰/无错误、文件保存/冲突拒绝、Git 差异与提交、systemd、端口转发、三档布局。Profile 回归把 Git 提交说明改走真实键盘输入，因为 `enterText` 在该模式不产生原生编辑输入。
- 新增滚轮测试在未修复的 `9bc0624` 副本中四项均失败（监听、重进反向重放、坐标、字体变化），修复代码中全部通过；另有保留页面不重建、2000 节点行虚拟化、IME 通知去重及服务器快照隔离测试。基线和修复后的 Profile 原始结果见 `docs/performance/20261109-scroll.json`。
- 最终回归：App 73 项通过，代理专用端到端脚本的 2 项按环境跳过；`aurora_profile` 27 项通过；`flutter analyze` 无问题。临时性能 agent 已退出，v2 的 PID 173/7710 端口状态不变。用户正式 WSL v3 已是 3.3.0，本轮只读核对，不执行旧 3.1.1 备份恢复。
- 限制：WSL 未安装 OpenCode 本体，此次真实滚轮性能验收用相同 DEC 备用缓冲区/SGR 鼠标模式的独立全屏重绘程序，不把等效负载说成 OpenCode 本体验收；尚未打新发布包，`release3/Aurora-3.3.0` 不含此次修复。

同一个 `aurora3-testpeer`（真实的 TLS、Hello、hashicorp/yamux 与分发），分别用 Go 客户端（`agent/cmd/aurora3-bench`，即 v2 的客户端协议栈）和 Dart 客户端（`app/packages/aurora_wire/bin/bench.dart`）跑同样的项目。本机回环，i7-1165G7，8 线程。复现：`agent/tools/bench.ps1`（Windows）、`agent/tools/bench-linux.sh`（WSL）。

### 6.1 现在：Dart 客户端用 BoringSSL（D-77，2026-11-06）

| 项目 | Go，Linux | Dart，Linux | Go，Windows | Dart，Windows |
|---|---|---|---|---|
| 建立连接（TCP+TLS+Hello） | 2.6–3.8 ms | 2.8–6.5 ms | 2.7–3.0 ms | 4.8–15.9 ms² |
| 空载单次调用 p50 / p99 | 0.39–0.51 / 0.6–0.8 ms | 0.39–0.45 / 0.6–0.8 ms | —¹ | 0.16–0.18 / 12–15 ms³ |
| 64 路并发调用 | 23859–34302 次/秒 | 32209–43380 次/秒 | 10954–11373 次/秒 | 11218–11258 次/秒 |
| 下载，单流 | 352–445 MB/s | 218–246 MB/s | 202–209 MB/s | 176–192 MB/s |
| 下载，4 流合计 | 578–766 MB/s | 210–229 MB/s | 261–281 MB/s | 202–216 MB/s |
| 上传，单流 | 344–403 MB/s | 346–417 MB/s | 244–246 MB/s | 185–188 MB/s |
| 下载进行中按键回显 p50 / p99 | 0.5–0.6 / 1.0–2.0 ms | 0.9–2.0 / 10–14 ms | —¹ | 0.16–0.22 / 1.8–2.4 ms |

数值是多轮之间的范围。² Windows 上 Dart 第一次连接含 BoringSSL 初始化和 DLL 加载，之后约 5 ms。³ Windows 的 p99 两边都约 13 ms，是 Windows 计时器粒度，不是协议。

**达到 Go 的部分**：上传、并发调用、空载延迟，以及 Windows 上的各项。**还有差距的部分**：Linux 上的下载约为 Go 的 55–65%，4 流下载不叠加。原因已经测出：Dart 的读路径是单个 isolate，解密本身只占约四分之一时间（512 MiB 中 BoringSSL 用 0.3 s，总共 1.2 s），其余是 Dart 事件循环和把明文交给 yamux 的拷贝。BoringSSL 单独的 AES-128-GCM 有 10.6 GB/s，所以加密不是瓶颈。进一步提速需要把读路径移到单独的 isolate 或减少拷贝，这是后续优化项，不影响正确性。

**测出的两个问题已修复**：BoringSSL 的内存 BIO 每次读都把剩余数据前移（`bio_mem.cc` 的 `memmove`），Linux 一次 socket 读交出几 MB 时变成平方级，一轮下载曾降到 11 MB/s；改为自己的队列 BIO 后稳定在 450 MB/s（`aurora_tls` 单独测）。GNU ld 要求 C++ 运行库排在静态库之后，否则 `libaurora_tls.so` 加载时找不到 `operator delete`。

### 6.2 之前：Dart 客户端用 dart:io 的 SecureSocket（2026-11-06，已被 6.1 取代）

| 项目 | Go，Linux | Dart，Linux | Go，Windows | Dart，Windows |
|---|---|---|---|---|
| 建立连接（TCP+TLS+Hello） | 2.7 ms | 3.5 ms | 3.4 ms | 4.2 ms |
| 空载单次调用 p50 / p99 | 0.41 / 0.72 ms | 0.76 / 1.08 ms | —¹ | 0.26 / 0.65 ms |
| yamux ping p50 | 0.25 ms | 0.55 ms | —¹ | 0.16 ms |
| 64 路并发调用 | 32969 次/秒 | 2969 次/秒 | 11043 次/秒 | 6261 次/秒 |
| 下载，单流 | 420 MB/s | 37 MB/s | 205 MB/s | 58 MB/s |
| 下载，4 流合计 | 727 MB/s | 40 MB/s | 265 MB/s | 56 MB/s |
| 上传，单流 | 401 MB/s | 69 MB/s | 242 MB/s | 55 MB/s |
| 下载进行中按键回显 p50 / p99 | 0.57 / 1.12 ms | 13.1 / 14.9 ms | —¹ | 13.8 / 20.8 ms |

¹ Windows 上 Go 的计时精度不足，p50 显示为 0，不可比。

**瓶颈在 Dart SDK 的 TLS，不在 yamux。** 用最简单的程序直接测 `dart:io`（服务端只发数据，不分帧，不走 yamux）：

| | Linux | Windows |
|---|---|---|
| `SecureSocket`（TLS 1.3）读取 | 46–48 MB/s | 69–72 MB/s |
| `Socket`（明文 TCP）读取 | 1168–1274 MB/s | 444–446 MB/s |

`SecureSocket` 每次只交出约 5.4 KB 明文，原因是它内部固定 8 KiB 的环形缓冲区，并在单独的线程上做加解密（Dart SDK 源码 `secure_socket_patch.dart` 第 69 行 `SIZE = 8 * 1024`）。这是 Dart SDK 的已知问题：dart-lang/sdk#64086、#64115（2026-08 起讨论，维护者已同意简化这部分实现，尚未合并）。Dart 客户端的吞吐达到了这个上限的 80% 左右（Linux 37–40 / 47，Windows 56–58 / 70）。多 isolate、多连接在 Windows 上能叠加（4 个 isolate 合计 206 MB/s），在 Linux 上不能（4 个合计 47 MB/s）。

**客户端已做的优化**（DESIGN 5.3）：同一轮事件里的帧合并成一次写（20 个小帧合并为 1 次）；一次只有一个写在进行；交互流优先于批量流；一元调用的 SYN、请求和 FIN 在同一次写中发出；接收窗口按读取速度自动增长（与 quic-go 的流量控制算法相同），读取方跟不上时窗口不放大，下载进行中的按键回显 p50 从 52.6 ms 降到 13.1 ms（Linux），下载速度不变。

这些问题促成了 D-77。


### 3.5.0 Android APK (2026-11-10)

- Android 凭据存储：`MainActivity.kt` 在 Android Keystore 里放一个不可导出的 AES-256-GCM 包装密钥，32 字节数据密钥随机生成，只以被包装的形式存在 `files/profile.key`；Dart 侧 `AndroidSealer`（AES-256-GCM，AAD 为用途串）用它加密配置文件。无法解包的密钥文件会报错，不会被覆盖。`aurora_profile` 新增 4 项测试通过（1 MiB 往返、nonce 不重复、篡改/错误密钥/错误用途被拒、短密钥被拒）。
- 构建：JDK 17、Android SDK 36、NDK 28 装在独立目录；`flutter build apk --release --split-per-abi`，三个 ABI（arm64-v8a、armeabi-v7a、x86_64），minSdk 24，APK Signature Scheme v2 验签通过，发布 keystore 在仓库外（`AURORA_ANDROID_KEYSTORE`、`AURORA_ANDROID_STORE_PASS`），未提供时回落 debug 签名。APK 内未检出本机路径、用户名或测试服务器地址。
- 未验证：没有在真机或模拟器上运行过；Android 上的 Keystore 流程、触摸交互、SSH 安装与直连、终端与文件功能均未验收；未做 v3 签名方案。agent 安装包不随 APK 分发，Android 端只作为客户端。

### 3.5.1 Android: 内置 agent（2026-11-10）

- Android 没有“可执行文件旁的 agent 目录”，所以 `tools/package-android.ps1` 把已签名的 agent（`amd64/` 下的二进制、manifest.json、manifest.sig，以及 policy.json、policy.sig）复制到 `app/assets/agent/` 再构建，构建后清理，不提交。首次启动时 `unpackAgentAssets` 只是把它们复制到 `files/agent`，`AgentBuild.open` 仍照常验 Ed25519 签名、大小和 SHA-256，文件被改动会被拒绝，与 Windows 一样。
- 三个 APK 内的 5 个 agent 文件与 3.4.0 签名源逐字节一致；APK v2 签名与 3.5.0 同一证书；未检出本机路径/用户名/测试服务器地址。`aurora_profile` 的 pointycastle 改为 ^4.0.0（与 dartssh2 4.1.0 一致），4 项 sealer 测试仍通过。
- 未验证：没有在真机或模拟器上运行；解包、SSH 登录、上传、安装 agent、直连在 Android 上都未实际跑过。

### 3.6.0 编辑器多格式文件 + Windows/Android 统一版本（2026-11-10）

- 见 DESIGN D-99、D-100。编辑器：图片（缩放）、PDF（pdfrx，MIT，PDFium 由构建时下载）、Markdown 预览、CSV/TSV 表格；视频/音频暂不播放，提示下载。PDFium 及其 17 个组件许可证存在 `app/third_party/pdfium`，写入 LICENSES.txt；`licenses.ps1` 排除 `flutter_localizations`。
- 测试：`app` 全量 102 项通过（15 项按设计跳过），其中新增：类型判断与 CSV 解析、按字节读取（成功、超上限、短流、断流、取消）、查看器 widget（预览不丢未保存文字且编辑器状态不重建、图片解码、损坏图片、超限、读取失败）。
- 统一版本：同一个 `-Version 3.6.0` 构建 Windows 包和 3 个 APK，versionCode 31600/32600/34600 由版本号推算（后两位为 ABI），APK 内的 agent 与 Windows 包的逐字节一致。
- Windows ZIP：24,764,182 字节，SHA-256 `40df587e86e9ace6f96d0645f46b7bc75b1374e609988751756ca3bb4a866606`，27 个文件与目录逐字节一致；agent SHA-256 `4e2b84b8fdd4c870dec99ba5c66b17676ed51c0cf81e6fb51735877444e4b6e0`，发布密钥 `87828dfb18459372` 验签通过。
- APK SHA-256：arm64-v8a `54dc1c1a810080cdb842ddcc2176c08227d2009fca1880907d1917cbf2dd4f5a`；armeabi-v7a `d95cbe60db611478fa0727c6b55544069adeebca3a2f78196a49a79a05dfc806`；x86_64 `09e9f2fa1201ced86665c918203fbf4b6825caded106681fe6118b47703e9ff0`。证书与 3.5.x 相同，包内 agent 与签名源一致，未检出本机路径、用户名、测试服务器地址。
- 未验证：真实窗口/真机上的查看器观感与手感；大 PDF、高分辨率图片的内存和性能；Android 上的 PDFium（libpdfium.so 已打包，未运行）；Android 上的 Keystore、agent 安装；篡改拒绝测试未在重打后重复。尚未推送到 GitHub。


### 3.7.0 一个客户端一个 agent 实例（2026-11-11）

- 见 DESIGN D-101。agent：`--instance NAME`（install、uninstall、direct-info；`upgrade-worker` 内部带实例名），具名实例的程序、单元、配置、状态目录、端口、tmux socket、tmux 单元、升级单元都与默认实例和其它实例分开；默认实例的名字和行为不变。客户端：新条目生成随机实例名，安装、读直连参数、卸载都按条目的实例走；服务器详情显示实例。
- 测试（Go，在 WSL Ubuntu 24.04 中运行）：install 新增 9 项（三个实例并存且端口、令牌、证书互不相同；升级、失败回滚、卸载、彻底清除一个实例时，其它实例的文件逐字节不变、服务状态不变；失败升级记录只记在失败的那个实例；清除默认实例不删具名实例；清除最后一个具名实例删空的父目录；端口跳过其它实例和被占用的端口；13 个非法名被拒且机器不变；默认布局等于原名）；entry 新增 4 项（名字规则；多个实例的布局两两不重叠、tmux 通配不会匹配到别的实例、目录互不嵌套）；terminal 新增 2 项（两个 socket 的同名会话互不可见，杀掉一个服务器不影响另一个；单元前缀）。install、entry、upgrade、terminal 全部通过，原有测试未改动语义。
- 真实 systemd 验证（WSL，与已在运行的默认 agent 并存）：装了 `e2ea`、`e2eb` 两个实例，分别监听 17711、17712；默认 17710 的 agent 进程、配置、单元、证书逐字节不变、没被重启；重复安装得 up_to_date；非法名被拒；卸载一个实例另一个仍 active；彻底清除后 `/etc/aurora3.d`、`/var/lib/aurora3.d` 消失，默认实例前后快照一致。测试用的二进制版本号是 3.99.0（只在 WSL 里用，未发布）。
- 测试（Dart）：`aurora_profile` 38 项通过（新增实例字段往返、旧条目无字段、随机名合法且不重复）；`aurora_install` 通过 6 项、21 项因没有发布夹具而跳过（新增的 2 项安装参数测试在跳过之列，未实际运行；卸载与读直连参数的实例测试已运行）；`app` 全量 102 项通过。
- 未验证：客户端界面里真的添加第二台“同一服务器”的流程没有在窗口里走过；会话隔离只在单元测试和真 tmux 的两个 socket 上验证过，没有用两个真实客户端同时操作；权限仍是 root（见 D-101 的限制）。

- 打包（源提交 `015f945`，同一个 `-Version 3.7.0` 出 Windows 包和 3 个 APK，versionCode 30700 系：31700/32700/34700）：
  - Windows ZIP：24,773,464 字节，SHA-256 `616585c80dc57ba55987c51de7c25ee1d627fdd4209fc65341f9f10dc0747bb8`，27 个文件与目录逐字节一致，exe 版本 3.7.0；agent SHA-256 `985ce4cdbc3ab6c68a02ecf402d1388b5d1e934f6ae2d7909eaa426d519be925`，发布密钥 `87828dfb18459372` 验签通过。
  - APK SHA-256：arm64-v8a `5211fcfa6404e222fc0cbfa8bcd4425275e38b6bc393d47a16e66ab991965115`；armeabi-v7a `2d75075fdd88b4b80fa5ea6dad2c582d25dddd333dfbdf1a86bea1f74f889221`；x86_64 `328152c6b28ccfb637af7a70230f4401a9aed17152afa84c9a1d15c35d6d4369`。证书与 3.5.x/3.6.0 相同（`db59a41d…1554882`），包内 agent 与 Windows 包逐字节一致，未检出本机路径、用户名、测试服务器地址。
  - 篡改拒绝测试未在本次重打后重复；Android 仍未在真机或模拟器上运行。

### 3.8.0 全局搜索、快速打开、编辑器基础、git 补全（2026-11-12）

- 见 DESIGN D-102。只改客户端，agent 不变（用的是已有的 `fs.search`、`fs.find`、`fs.watch`、`fs.stat`、`git.stash`、`git.tag`、`git.branch`、`git.remote`、`git.op`、`git.blame`、`git.show`）。
- 测试：`app` 全量 135 项通过（15 项按设计跳过），`aurora_profile` 38 项通过，`flutter analyze` 无问题。新增：冲突解析 8 项（未改动的文本逐字节往返、diff3、只改已决定的块、CRLF、不完整标记当文本、无结尾换行）；搜索/快速打开/拆分/设置/编辑器 16 项（行号解析、多文件夹交替与单个失败、搜索参数与行列范围、旧搜索作废、无效表达式、搜索范围、拆分不重复显示与关闭时取消、设置钳制与默认不写入、换行符识别、CRLF 打开不脏且保存仍为 CRLF、服务器变化时干净编辑器重新载入而有未保存修改时只显示横幅、定位到行）；git 9 项（储藏/分支/标签/远程/操作的参数、冲突是结果而非错误、合并视图选一边带 etag 保存后暂存、未决定的块原样保留、文件已被修改时不覆盖且保留决定、blame 显示）。
- 修正：编辑器以前保存时会把 CRLF 文件改成 LF（re_editor 默认换行符），现在按文件原有换行符保存。
- 未验证：没有在真实窗口里操作过（拆分的观感、快捷键在终端获得焦点时是否被终端吃掉、设置页、合并视图布局）；没有连真实 agent 跑搜索、`fs.watch`、冲突合并（测试里都是模拟的 agent 应答）；大仓库下搜索的速度未测。
- 打包（源提交 `cd84ad6`，同一个 `-Version 3.8.0` 出 Windows 包和 3 个 APK，versionCode 31800/32800/34800）：Windows 文件夹新增 Aurora 自己的 `LICENSE`（Apache-2.0）和 `NOTICE`。
  - Windows ZIP：24,909,181 字节，SHA-256 `981a6cbcce6ce4925e8d0491861d50cb8a83830449cbccd66b2392b7a6a86c7b`，29 个文件与目录逐字节一致，exe 版本 3.8.0；agent SHA-256 `2e9177dfad434fb84baef81492ab1968afb85e509535beb493e443d6e0087eed`，发布密钥 `87828dfb18459372` 验签通过。
  - APK SHA-256：arm64-v8a `67cd75903622e72eaa0e9714df83af928cca21f084089bff456a33cb0e32446d`；armeabi-v7a `6a2480f8eea25209cebc85762da3355191b99f421814b7c11299e7ee8439181d`；x86_64 `9994f841658163d5eeceefd5a7bd34fd316e325ea6c49f368d190adc195cf728`。证书与之前相同（`db59a41d…1554882`），包内 agent 与 Windows 包逐字节一致，未检出本机路径、用户名、测试服务器地址。
  - APK 里还没有带 Aurora 自己的 LICENSE 文本（仓库和 Release 页有）；篡改拒绝测试未在本次重打后重复；Android 仍未在真机或模拟器上运行。

### 3.9.0 界面重做（2026-11-12）

- 见 DESIGN D-103。只改客户端：`theme/ide_theme.dart`（设计令牌与 Material 主题）、`kernel/shell.dart`（岛式布局、标题栏、活动栏、标签、欢迎页、状态栏、服务器下拉、空首页、手机布局）、`kernel/widgets.dart`（列表行、分组标题、空状态、菜单、提示条，新增浮层选择器与键帽）、`kernel/palette.dart` 和 `features/search/quick_open.dart`（新选择器）。
- 测试：`flutter analyze` 无问题；`app` 全量 135 项通过（20 项跳过，其中 5 项是只在设置 `AURORA_SHOTS` 时运行的截图测试），`aurora_profile` 38 项通过。
- 截图：用 `ui_shots_test.dart` 渲染了 14 张（宽屏深/浅色的欢迎页、文件树、编辑器、命令面板、服务器下拉；中等宽度和侧栏浮层；手机；没有服务器的首页），逐张看过。修正了截图里发现的问题：键帽单边粗边框在 Flutter 里不能配圆角（改用阴影做底边）、主题的文字样式丢了字体、欢迎页副标题在系统名为空时多出一个分隔点、手机底部导航文字挤在一起（改为只显示选中项的文字）。
- 第二轮：自绘标题栏（原生 `win32_window.cpp`、`flutter_window.cpp` 与 `kernel/window_frame.dart`），监控仪表盘，概览页、设置页、添加服务器页重做，共用 `FormPage`/`FormSection`/`FormRow`/`SmallSwitch`/`Notice`，git 分支行与储藏数的用词修正。截图测试改为给每个面板喂假数据并按无标题栏渲染，一次出 33 张（深浅色各自的欢迎页、编辑器、命令面板、服务器下拉、6 个侧栏面板、监控两帧、概览、设置；中等宽度、手机、空首页、添加服务器页），逐张看过。截图里发现并修正：窗口按钮的悬停提示在 Navigator 之外会报错（真实窗口也会），改用无障碍标签；添加服务器页的勾选行需要 Material 底；关闭状态的开关太淡。
- 验证：`flutter analyze` 无问题；`app` 135 项通过（20 项跳过，其中 5 项是截图测试），`aurora_profile` 38 项通过；`flutter build windows --release` 编译通过（原生代码无错误）。
- 未验证：没有在真实 Windows 窗口里试过自绘标题栏（拖动、双击最大化、顶边改变大小、贴边、多显示器不同 DPI、Windows 10 顶边），因为本机正在运行 3.8.0，单实例锁会把新启动的程序转到它；截图是测试环境渲染的；没在 Android 设备上看过。
- 打包（源提交 `4ef1173`，同一个 `-Version 3.9.0` 出 Windows 包和 3 个 APK，versionCode 31900/32900/34900）：Windows 文件夹带 `LICENSE`、`NOTICE`、`LICENSES.txt`；APK 里也带了这三个文件（`assets/flutter_assets/assets/legal/`，与源文件逐字节一致，三个 APK 都验过）。
  - Windows ZIP：24,952,377 字节，SHA-256 `bda52deabf127aab69136e49cd1036f2433f67ba7a4cb069af4d20c0791966c3`；agent 用发布密钥 `87828dfb18459372` 验签通过。
  - APK SHA-256：arm64-v8a `ea7b2c58870d5bbca920af6ee4c79d5ce9de0c79cee0efede5819d55fa860e12`；armeabi-v7a `b9a106927aaaa384dde3b09fc2e39a6c49a14c3504466ff53c57ce6d7b3e65c2`；x86_64 `842c5df7cb0101245f374b540c42aa1771b86ed712c96a5b08546ff988c8d3e7`。证书 SHA-256 与之前相同（`db59a41d…1554882`），三个 APK 里的 agent、清单、策略与 Windows 包逐字节一致，敏感字符串命中 0。
  - 构建经过：第一次在全新的 git worktree 里打 APK，`pdfium_dart` 的构建钩子要联网下载 pdfium，TLS 握手被断开，卡了 16 小时后失败；改在带缓存的主仓库里只跑 APK 步骤（同一提交、工作区干净），133 秒完成。Windows 包来自前一次构建。
  - 未重复：篡改拒绝测试；Android 仍未在真机或模拟器上运行。
### 3.9.1 升级提示条修复（2026-11-12）

- 问题：agent 有新版本时，窗口顶部的升级提示条在标题栏上方，被右上角的窗口按钮盖住。修复（ba205e）：把 AgentUpgradeNotice 移到标题栏下方（kernel/shell.dart）。
- 测试：`flutter analyze` 无问题；`app` 135 项通过（20 项跳过），`aurora_profile` 38 项通过。
- 打包（源提交 `bfbad75`，`-Version 3.9.1`，versionCode 31901/32901/34901）：在带缓存的主仓库里一次出 Windows 包和 3 个 APK。验证：敏感字符串命中 0；ZIP 30 个文件与文件夹逐个一致；agent 用发布密钥 `87828dfb18459372` 验签通过；APK 证书与之前相同，APK 里的 agent、清单、策略与 Windows 包逐字节一致；三个 APK 里的 LICENSE、NOTICE、LICENSES.txt 与源文件一致。
  - Windows ZIP：24,954,475 字节，SHA-256 `bf9f9f3a4b04bc861159fd9267253e6e5c63ba1f4dc9575791bcfed98ee4c97b`。
  - APK SHA-256：arm64-v8a `55c942fd5f36e8dfb08ccd880ce0573f1c0cf3d7f817c7df2e54d18219c6b317`；armeabi-v7a `c2e12342d10d0abe2b064d0220f99c8ae7fe0546ea21e9971cd9ad25f225ed46`；x86_64 `4a025223bed2813c12e9f53d79df82d1d895347173a3a1946523f64544a18479`。
  - 发布后重新下载 5 个文件，与本地逐个比对，全部一致。（发布脚本自带的比对因缺少 `Get-FileHash` 而无效，是另外手工比对的。）
- 未验证：升级提示条在测试里触发不了，修复后的样子没有看到过；自绘标题栏仍没在真实窗口里试过；Android 仍未在真机或模拟器上运行；篡改拒绝测试未重复。

### 3.10.0 内置 LLM 编码与服务器智能体（OpenCode 引擎移植，2026-11-12）

- 见 DESIGN D-104。agent 新增可开关服务 `ai`（`agent/internal/ai/`），移植 OpenCode（MIT，`anomalyco/opencode`）的三大流式协议（`openai-chat`、`anthropic-messages`、`openai-responses`）、OpenCode 请求头（`User-Agent: opencode/stable/1.4.0/opencode`、`HTTP-Referer`、`X-Title`、`x-opencode-client`、`x-opencode-session-id`、`x-session-affinity`）、系统提示词（`build`、`plan`、`explore`、`title`、`compaction` 检查点模板、模型身份与 `AGENTS.md`/`CLAUDE.md` 发现）、同名同 Schema 工具链（`read`、`write`、`edit`、`glob`、`grep`、`shell`、`todowrite`、`subagent`）、三级精确 `edit`（保留 UTF-8 BOM 与 CRLF/LF）、2000 行 / 50 KiB 输出截断落盘、影子 Git 树快照（`<StateDir>/ai/snapshots/`）与一键回退、`Ask`/`Auto` 权限审批与死循环拦截，以及复用服务器 `proxysvc` 代理出口（`px.GitEnv`）。客户端新增 `aurora_profile` 密封 `AiSettings`/`AiProvider`（API Key 仅保存在本机加密 `profile.bin`，按次经固定指纹 TLS 传至 agent 内存，服务器绝不落盘）、活动栏「AI 助手」与会话侧栏、`AiStudioView` 工作台标签页、模型与协议配置弹窗；`tools/licenses.ps1` 收录 `THIRD_PARTY_OPENCODE_LICENSE`（MIT），同时将 `package.ps1` 与 `package-android.ps1` 中的哈希计算改为原生 `[Security.Cryptography.SHA256]` 以免无 `PSModulePath` 时缺失 `Get-FileHash`。
- 已验证：Go `aurora3-agent`（`linux/amd64`）构建通过，WSL Ubuntu 24.04 下 `internal/ai` 与 `internal/entry` 测试全部通过（三大协议 SSE 流与 OpenCode 请求头、三级 `edit` 与 CRLF/BOM 保留、50 KiB 截断落盘、运行循环改文件、影子 Git 一键回退恢复文件、会话落盘零 API Key 泄露）；`aurora_profile` 39 项单测通过；`flutter analyze lib test` 0 问题；`app` 全量 138 项测试通过（含新增 `ai_feature_test.dart` 3 项）；`ui_shots_test.dart` 深浅色宽屏/中屏/手机截图全部渲染核对通过（并修复工具卡片与代码块使用 `Ide.mono` 字体链）。
- 未验证：真实外部网关 API Key 的在线多轮对话联调（自动化测试使用本地 SSE 桩）；真实 Windows 窗口交互与 Android 真机/模拟器运行。
- 打包与归档（源提交 `53f6f7c`，`-Version 3.10.0`，versionCode 32000/33000/35000，已归档至 `release3\Aurora-3.10.0` 供本地试用，尚未上传 GitHub）：
  - Windows ZIP：25,236,260 字节，SHA-256 `d8f26d6b4c38588415474e026007def023d7ea5b39aca098ed2f46e6f14ff194`，30 个文件与目录逐字节一致；内置 `aurora3-agent-3.10.0-linux-amd64` SHA-256 `48411f41b9f8a2cef1a54c898122d803e49382b83595436af8ed3eac3dcfe1df`，发布密钥 `87828dfb18459372` 验签及副本字节篡改拒绝测试均通过；`LICENSES.txt` 已收录 OpenCode MIT 许可证。
  - APK SHA-256：arm64-v8a `63a12e8da802e7cbc03e9a858cc6209dd6b2c81cd281d1ea8fc5c35dfad7a7a9`；armeabi-v7a `0ee8ab8fb1e51d85647617499f4212fe30d31e6f71e37058017fb30a7248deee`；x86_64 `fa345eb58cbd15d615d9fdf6b4406113adc5f4df127c9fef2a56886771152112`。证书与之前相同（`db59a41d…1554882`），三个 APK 内置 5 个 agent 文件及 3 个法律文件与 Windows 包逐字节一致，敏感字符串命中 0；v2 发布目录仍为 13 项。

### 3.10.1 AI 体验打磨：联网搜索、统一历史、模型与思考强度（2026-11-13）

- 见 DESIGN D-104 末段。agent：移植 OpenCode 的 `webfetch` 与 `websearch`（Exa MCP），所有智能体模式可用；历史新增 `pinned`/`preview`/`created_at` 与 `ai.update`、`ai.search`、`ai.export`；`ai.models` 在 Base URL 缺 `/v1` 时自动重试并给出明确提示。客户端：历史侧栏（置顶、按日分组、预览、全文搜索、重命名、复制为 Markdown）、输入框模型快速选择器与思考强度、联网搜索来源卡、Markdown 回复渲染。
- 已验证：Go `internal/ai` 与 `internal/entry` 在 WSL 下通过（含新增 `web_test.go`：HTML 转 Markdown、Exa 解析 JSON 与 SSE、本地桩的搜索与抓取含重定向、二进制与危险 URL 拒绝、`/v1` 回退、置顶/重命名/搜索/导出）；`flutter analyze lib test` 0 问题；`app` 全量测试通过（142 项，20 项按设计跳过），其中 `ai_feature_test.dart` 7 项；`ui_shots_test.dart` 截图已核对侧栏与工作台。
- 未验证：真实 `mcp.exa.ai` 在线搜索（测试用本地桩，服务器需能访问该地址或开启 `use_proxy`）；真实网页抓取；重命名菜单没有组件测试；真实窗口交互、Android 真机。新操作需要服务器上的 agent 升级到同版本，旧 agent 上搜索、置顶、重命名会失败。
- 打包与归档（源提交 `4acd381`，`-Version 3.10.1`，已归档至 `release3\Aurora-3.10.1`；2026-11-13 已发布为 GitHub Release `v3.10.1`（ZIP、sidecar、3 个 APK、`SHA256SUMS.txt` 共 6 个文件，重新下载后逐个与本地一致），同时删除了废弃的 `v3.5.0`、`v3.5.1` Release 与标签）：
  - Windows ZIP：25,312,615 字节，SHA-256 `de94baeba7c799aa04dd8d630d0953ab979f8ca6a96bea17dc6052eff781e8ca`，sidecar 一致，30 个文件与目录逐字节一致；文件/产品版本 3.10.1；内置 `aurora3-agent-3.10.1-linux-amd64` SHA-256 `3eced00a35d7c7704f77f0e6083f7f03f8ee11687afba5dd4196c04af9b91968`，发布密钥 `87828dfb18459372` 验签及副本字节篡改拒绝测试通过；敏感字符串命中 0，可疑文件 0，`LICENSES.txt` 已收录 OpenCode MIT。
  - APK SHA-256：arm64-v8a `df4c4220b77ab8207ea2ce582512f84fc3f267525a56b97d504328093e2e5761`；armeabi-v7a `bdc1babf991438243a91753e9c37717a2f7e6d414d98abcf4f06202fad42ce9f`；x86_64 `865d014e9afe3e011bed535ae3ea739b71ce104568e3e191f2add7add266fb61`。证书与之前相同（`db59a41d…1554882`），三个 APK 内置 5 个 agent 文件及 3 个法律文件与 Windows 包逐字节一致，敏感字符串命中 0；v2 发布目录仍为 13 项。

### 3.11.0 文件管理器与 PDF 阅读器深度优化（2026-11-13）

- 见 DESIGN D-105。文件管理器新增文件大小、权限/属主/修改时间提示、文件夹大小统计（`fs.du`）、名称/大小/修改时间/类型排序、升降序及文件夹优先设置；新增 Ctrl/Shift 多选、复制、剪切、粘贴、创建副本、F2 重命名、Delete 删除、属性对话框和键盘快捷键。粘贴支持同根目录 `fs.copy`/`fs.rename`、跨根目录 `to_root`，冲突时替换/保留两者/跳过并支持应用到全部；有未保存文件时拒绝破坏性移动。agent 的 `fs.copy` 新增 `to_root`，复制保留属主、权限、修改时间，保留符号链接并限制目录深度；新增 `copy_du_test.go`。
- PDF 改为 PDFium 按需分块读取：小于 16 MiB 的 PDF 预加载后打开，大文件用 512 KiB range、并发合并与最近块缓存，按 etag 检测远端替换；阅读器新增目录、缩略图、页码跳转、缩放、全文搜索高亮、夜间模式、密码提示、文档链接跳转/外链复制和会话内阅读位置记忆。
- 已验证：`flutter analyze lib test` 0 问题；`aurora_profile` 42 项通过；Go `internal/files` 在 WSL 下通过；文件管理器测试 11 项、文件逻辑测试 18 项、PDF range 测试 9 项、真实 PDFium 阅读器测试 8 项通过；app 全量测试 187 项通过（20 项按设计跳过），UI 截图与既有文件/PDF 测试通过。
- 未验证：真实远程大 PDF 在高延迟网络下的翻页体验、加密 PDF 的真实密码文件、Windows 真实窗口操作、Android 真机；文件夹大小是手动快照，不会自动更新。
- 打包与归档（源提交 `13848b9`，`-Version 3.11.0`，已归档至 `release3\Aurora-3.11.0`；2026-11-13 已发布 GitHub Release `v3.11.0`，6 个文件重新下载后全部与本地一致；远程 main 为 `3da7826`）：
  - Windows ZIP：25,446,238 字节，SHA-256 `dd38d2a3bd9bf267de28ee65e8e5db72cb173a1248e3232cf4c5746b05115c39`，sidecar 一致，30 个文件与目录逐字节一致；文件/产品版本 3.11.0；内置 agent SHA-256 `8aa930c5c7e011de048e17effc41a3dee4255794f3f2ec7f23f6e95daf014911`，签名验证及篡改拒绝通过；敏感字符串命中 0、可疑文件 0。
  - APK SHA-256：arm64-v8a `f949e596c1486756614f5bb9e56ef4986929c1928177549f500be9d2bc61b406`；armeabi-v7a `6fe334a88b3424fe427a96e64eb82af2d29edc3a206230fa64e2f7a073f1a1aa`；x86_64 `0cb007f4ae4ad0bf557812b878636a210946f4d1bbdf8ada9416b7672b3383ab`。证书与之前相同，三个 APK 的 agent/法律文件逐字节核对通过，敏感字符串命中 0；v2 发布目录仍为 13 项。

### AI 上下文、提供商/模型与 OpenAI 订阅 device 登录（2026-11-13，未打包）

- 见 D-106、`docs/AI.md`。AI 工作台增加当步/最近实际请求的提供商与模型、下一次选择、上下文估算/输入预算/百分比与占用条、单独的累计用量；每条回答保存提供商/模型，旧记录明确未知。窗口元数据按模型保留，设置页支持手动覆盖。窄屏输入工具栏换行，长工作目录可横向滚动；重复 finish/compaction 事件不重复累加。
- 复用 OpenCode（参考仓库提交 `3d308eae2e68dc39dfc12aba9dd408f9ce1cc0a1`）的 device 授权、token exchange/refresh、account 路由与 Codex headers/body；MIT 署名沿用 `agent/internal/ai/THIRD_PARTY_OPENCODE_LICENSE`。新增三项 `ai.auth.*` RPC、客户端授权对话框、并发刷新与安全存储、固定订阅路由。标题和压缩同样支持订阅，主调用、子智能体共用 Responses 分发。订阅模型建议不冒充账号资格列表，不调用 API Key 的 `/v1/models`。
- 已验证：Go `internal/ai` 17 项顶层测试（含本地 HTTP 授权桩、pending/interval、交换/刷新/JWT routing、重定向拒绝、标题/压缩、过期/流错误/断流、上下文压缩重算、凭据不落盘/不广播）和 `internal/entry` 17 项在 WSL 直接执行通过，严格保留退出码，未使用旧的 `| tail` 测试脚本；linux/amd64、linux/arm64 agent 构建与定向 `go vet` 通过。`aurora_profile` 46 项通过，含真实 AES-GCM 加密落盘/重开/篡改拒绝及 wire 不带 refresh。Flutter 全量 201 项通过、20 项按设计跳过；AI 定向 21 项，覆盖取消/到期/在途授权、并发刷新/失败保存/删除提供商、输入保留、实际与下一次模型分离、事件幂等、窄屏布局。
- `flutter analyze lib test` 0 问题。无真实窗口截图：使用 Windows 字体在组件测试中渲染并检查 AI 宽屏/390 px 窄屏，输出到本机临时目录；不抢焦点、不读取真实账号或现有 profile。不更改 v2、正式 agent 安装及 release3 旧产物。
- 未验证：真实 OpenAI/ChatGPT 账号的完整授权与多轮订阅对话、真实服务器代理出口、真实 Windows 窗口、Android 真机。仅 HTTP SSE 移植，未移植 OpenCode WebSocket/zstd/browser callback/token-sharing；长任务过期需客户端下次调用刷新，退出登录不会撤销账号端授权。尚未打包或发布新版本。

### 3.12.0 编译、打包与本地归档（2026-11-13）

- 用户已授权编译、打包、发布。源码提交 `0dabbe2bb0dd766a5357fe383d222c629e4eaac4`，Windows 与 Android 统一 `-Version 3.12.0`；已归档至 `release3\Aurora-3.12.0` 及同目录对应 ZIP、sidecar、三个 APK 和 Android SHA-256 清单，未覆盖任何旧产物。2026-11-13 已发布 GitHub Release `v3.12.0`：https://github.com/Moraxusio/aurora/releases/tag/v3.12.0 。ZIP、sidecar、3 个 APK、`SHA256SUMS.txt` 共 6 个资产全部重新下载，逐个 SHA-256 与本地一致；标签指向产物记录提交 `813745317138ff13eb9142494fa37434caea3b5e`。
- Windows ZIP：25,507,680 字节，SHA-256 `9661cca3da4138c358f96a5c9f5703d8eebd172088b17e94d37c13c4584fb49a`；sidecar 一致，ZIP 的 30 个文件与文件夹逐字节一致，归档后的文件夹和资产再次逐个比对一致；文件/产品版本 3.12.0。
- 内置 linux/amd64 agent：13,578,402 字节，SHA-256 `7838f6871836e791cacc06235618e9b734e288ada0067889a7d1be9f36484b1f`，版本命令输出 3.12.0；Go 构建元数据 `vcs.revision=0dabbe2bb0dd766a5357fe383d222c629e4eaac4`、`vcs.modified=false`。正式发布公钥（key ID `87828dfb18459372`）验签通过；临时副本中的 agent 字节与 manifest 篡改被拒。签名策略验签、策略篡改拒绝、普通降级拒绝均通过。
- Android APK：arm64-v8a（versionCode 33200）39,490,634 字节，SHA-256 `926bab560ecfcea31322ee64bcf12a72d198c68834b8fa96407b52d8d1e22e38`；armeabi-v7a（32200）34,901,458 字节，SHA-256 `48a0a98c51e2b86f3d14b59dbe3c55eed18f9895a4c24710aa8902bb2f0856a7`；x86_64（35200）41,718,756 字节，SHA-256 `8931c8af2bd760d51d3546209691b22b32769b605404f68c1b2b73065118ba81`。versionName 均为 3.12.0；apksigner、ABI 与版本检查通过，签名证书 SHA-256 与之前相同（`db59a41d…1554882`），三个 APK 的 5 个 agent 文件和 3 个法律文件逐字节与 Windows 包一致，Android SHA-256 清单通过。
- Windows 与全部 APK 的敏感字符串扫描通过，未检出私钥、profile 或测试文件，OpenCode MIT 署名在许可证汇总中。v2 的 release 目录仍为 13 项，旧 3.11.0 ZIP 哈希未变；未更改正式服务器安装，也未启动真实客户端窗口。真实 ChatGPT 授权/订阅对话与 Android 真机仍未验证，发布说明明确保留这些边界。

### AI 授权出口、粘贴附件与阅读体验（2026-11-13，未提交、未打包）

- 见 D-107、`docs/AI.md`。针对获取设备码阶段的 403，新增默认本机 device/exchange/refresh、环境/系统代理与服务器出口下拉切换、按阶段解释的安全错误、重试/取消/超时及 generation 防迟到响应。OAuth 凭据保存授权出口，旧值缺失默认 client；本机刷新不经 agent，模型调用仍从服务器发出。保留 OpenCode MIT 署名，不宣称能绕过所有上游网络/账号限制。
- 新增 Windows PNG/位图/复制文件粘贴、Android content URI/IME 图片、本机文件选择和服务器文件浏览；用户主动粘贴才读取，发送才上传，普通路径文本不自动打开。原始媒体经 `ai.attach.*` 分块流传输，会话只存引用，支持三协议多模态与历史重放；单件 8 MiB、文本 256 KiB、每条 8 件/20 MiB、私有附件库 512 MiB（包括元数据余量），SHA-256 及 0700/0600。删除会话保护共享引用及运行中 inbox；未关联/回退形成的孤儿附件无自动 GC。大 ChatGPT 请求使用已有 BSD zstd 依赖。
- 工作目录使用项目/根目录下拉及面包屑浏览，已有会话目录固定；默认 15 px、字体回退/行距、13.5/15/17 本机持久化、复制回答、惰性消息及 widget 缓存、33 ms 流式合帧、历史阅读不强制滚底、中文 composing Enter 不发送。
- 已验证：Go `internal/ai` 23 项顶层测试及 `internal/entry` 17 项在 WSL 直接执行通过；新增 >1 MiB 附件流、上传中断/错误帧不提交、三协议媒体结构、zstd、共享引用/活动 inbox 删除保护、条数/大小/库限额及读取校验测试。定向 `go vet`、linux/amd64 与 linux/arm64 agent 构建通过；`aurora_profile` 47 项通过；`flutter analyze lib test` 0 问题。最终源 Windows Release、Android arm64 Debug 编译通过，仅验编、不运行。最终 runtime/截图 6 项通过，宽屏、390 px 手机和手机双附件三张截图已读取核对，无布局溢出。首轮全量唯一失败是滚动测试未推进动画启动首帧，补齐测试时钟后定向及最终全量均通过：**Flutter 218 项通过、20 项按设计跳过、0 失败，退出码 0**；未过滤、跳过失败测试。
- 隔离：只用合成令牌/文件和本地 HTTP 桩；未读取真实剪贴板、浏览器账号、SSH 私钥、订阅或节点凭据；未启动真实窗口或替换正式安装。3.12.0 ZIP 与三个 APK 哈希和发布记录一致，v2 release 仍为 13 项。没有改版本、提交、打包或发布。
- 未验证：真实 OpenAI/ChatGPT 授权及多轮模型对话、真实 Windows 原生剪贴板和 Android 真机/输入法、Windows PAC-only 代理。附件需要本轮新版 agent；组件渲染及编译不替代实机验收。

### 3.13.0 提交、打包与发布（2026-11-13）

- 用户已授权提交代码、打包及发布；Windows 与 Android 统一使用 3.13.0。源码提交及标签 `v3.13.0` 均为 `d8d78e01debb283f508c2c111757c776cea3ba77`，从干净提交构建。已发布：https://github.com/Moraxusio/aurora/releases/tag/v3.13.0 。Windows ZIP、sidecar、三个 APK、`SHA256SUMS.txt` 共 6 个资产全部重新下载，SHA-256 与本地一致。
- 已归档至 `release3\Aurora-3.13.0` 及同目录 ZIP、sidecar、三个 APK 和 Android SHA-256 清单；不覆盖旧产物，不替换正式安装。Windows 文件/产品版本均为 3.13.0；ZIP 的 30 个文件与产物目录逐字节一致，归档后再次核对一致。ZIP：25,750,178 字节，SHA-256 `eac52677aaa4c7d5ceb793d86b87c2410e1d70b375e97e37c4e6c267aa53f493`。
- 内置 Linux amd64 agent：13,992,098 字节，SHA-256 `9058b31efe76b7743b9070147e30fb4bdcd03b3edff8f5da162ba8795ce66e9a`，签名密钥 ID `87828dfb18459372`。Go 构建元数据记录上述源码提交且 `vcs.modified=false`；正式公钥验签、agent/manifest 篡改拒绝、升级策略验签/篡改拒绝/普通降级拒绝通过。
- Android APK：arm64-v8a（33300）39,807,090 字节，SHA-256 `c5a492dd0aac6c6da8b54685ac84b454e98f8060c9a4f8735109ccaa4c77a521`；armeabi-v7a（32300）35,185,146 字节，SHA-256 `a7ebe9b9e34b4969be0316a694fdd464832973769841f6ddc08b421e3258b193`；x86_64（35300）42,035,216 字节，SHA-256 `4e4d3917115415a32f907b0bd7abb45b0deb3530a9fb245b32cfa3402b369f1f`。versionName 均为 3.13.0；apksigner、版本/ABI 检查通过，证书 SHA-256 沿用 `db59a41d0511deaae35f6848e4088db20a8a9846635975635e79efa6f1554882`；三个 APK 的 5 个 agent 文件、3 个法律文件均与 Windows 包逐字节一致。
- 敏感字符串及可疑文件扫描通过，OpenCode MIT 署名完整，APK/ZIP 哈希清单通过。v2 release 仍为 13 项，旧 3.12.0 ZIP 哈希不变。首次校验因旧脚本残留的 3.12.0 版本正则而停止，核对实际 3.13.0 元数据并修正验证器后全部通过，未重复构建或放宽校验。
- 自动化验收沿用上节 218 项 Flutter 通过、20 项按设计跳过和 Go/配置测试；发布未启动真实窗口、未做真实账号授权或 Android 真机验收，发布说明明确这些边界。

### Windows 本地 agent、AI 断流修复与执行体验（2026-11-13，未发布）

- 用户要求实施 Windows 本地开发、修复截图中的会话加载失败，并优化 AI 执行可视化和提供商配置；明确本地 agent 不需要 tmux 持久会话。决定见 D-108/D-109，使用与限制见 `docs/LOCAL_AGENT.md`。本轮不改正式版本、不提交发布、不覆盖旧产物或替换已装客户端/服务器。
- 新增独立 Windows 用户态 `cmd/aurora3-local-agent`：仅回环随机端口、固定指纹 TLS/yamux、管道启动握手/退出、每次启动随机 token、用户私有 ACL、Job Object 任务树；签名产品与远程 agent 分离。Flutter 增加 `kind` 类型、本机入口/原生打开目录/项目恢复、本地概览与随包升级，不走 SSH 或远程安装器。旧条目仍是 remote，已有远程选择不变；首次增加入口前保留原始加密备份，不解封导出。
- 文件/Git/AI 抽离 Linux 系统依赖，保留共用协议与界面；Windows 路径验证拒绝 ADS、设备名、盘符注入和越界。文件变化使用 800 ms 有界目录快照；首版不含 UNC、可移动盘、目录大小统计、日志 tail、systemd/监控/端口转发/节点代理。本机原生路径用于“复制路径”和 AI 目录栏。
- ConPTY + 用户 PowerShell（优先 pwsh，缺失回退 Windows PowerShell），不做跨 agent 重启保活。终端切换/托盘仍运行，关闭终端/完全退出结束受管任务。AI shell 单独使用非交互 NoProfile PowerShell，通过创建时 Job Object 绑定实现取消及子进程清理；继承环境/手动系统代理，远程代理设置沿用。修正 ConPTY 在父进程标准流重定向时错误继承管道的问题，明确设置 STARTF_USESTDHANDLES；opaque HPCON 通过 Win32 uintptr 传递，不伪造由 Go GC 保存的指针。
- 修复可复现的 1 MiB 单帧历史/步骤结果缺陷：新增 `ai.history` 分块（单次 64 MiB 上限），旧 `ai.get` 兼容；入口超大 unary 结果返回明确错误，超大实时事件发送 `sync.required` 而不空断流。客户端保留已有画面/输入、独立恢复事件流并在加载期间缓冲事件。新增主/子工具活动快照、子代理入口、shell 增量输出与不含 URL/凭据的代理来源信息；恢复子代理待批准操作。
- 提供商配置增加手动添加、可搜索/选择/移除的惰性模型列表，拉取与手动模型合并；可从客户端网络或当前 agent 拉取，支持常见列表形状、上下文字段与有界分页，拒绝重定向并区分网页/鉴权/空列表。订阅仍明确为内置建议，不是账号权限查询。保留原 API Key/OAuth，后台刷新与设置保存冲突不覆盖新凭据；新增手动模型/并发轮换/窄屏回归。
- 已通过阶段验证：Windows Go 全量测试、定向 vet、Windows 原生 PowerShell/ConPTY/缩放/子进程取消、本地 TLS/文件/模型/终端协议；使用 `tools/test-local-agent.ps1` 的一次性签名密钥和真实 Dart 客户端完成 `LOCAL_AGENT_SIGNED_CLIENT_TLS_FILES_MODELS_CONPTY_EXIT_OK`。过程中发现 AgentBuild 原先固定远程产品，已新增显式预期产品参数，默认仍只接受远程产品。测试私钥已由脚本删除。
- Linux AI/entry/files/git/paths 与 terminal 回归及 Linux 全量构建通过；terminal 首次因测试二进制工作目录不对跳过，改在包目录运行后 16 项全部实际通过，包括 tmux 持久会话和代理。Flutter 最终全量 **230 通过、20 既有条件跳过、0 失败**；`aurora_profile` 包 47 项全部通过。新增 390 px 提供商设置回归发现鉴权下拉框溢出，已增加有界展开/文本省略，并验证选择最长设备码选项后仍保留原 API Key；定向 10 项与全量均通过，未删减失败测试。宽屏/390 px 工作面板截图已核对。构建依赖问题为 hooks 环境过滤自定义 NASM 变量，改为将 NASM 加入 PATH 后解决，未放宽或跳过断言。
- 最终源码验编：`flutter analyze` 零问题（5.7 s），Windows Release 构建通过（61.8 s），Android arm64 Debug 构建通过（21.6 s）；均仅为工作区验编，不是正式发行包。Windows Go 全量以 `-count=1 -timeout=120s` 取消缓存复跑通过，定向 `go vet` 通过。未启动真实客户端窗口或安装到设备。
- `aurora_install` 包额外回归为 7 通过、21 因未设置远程签名/升级 fixture 而跳过、0 失败；不将这些跳过项计为远程安装验收。独立本地产品的真实签名启动由上述沙箱联调覆盖，远程产品隔离/篡改拒绝由 Go 回归覆盖。
- 最终差异检查：77 个修改/新增文件未发现私钥材料、GitHub/AWS/JWT 令牌模式或新增发行二进制；`git diff --check` 无空白错误，两个 PowerShell 构建/联调脚本语法检查通过，依赖声明/锁文件与 OpenCode MIT 署名未变。v2 工作区仍干净，`release` 顶层仍为 13 项，旧 3.13.0 ZIP SHA-256 仍为 `eac52677aaa4c7d5ceb793d86b87c2410e1d70b375e97e37c4e6c267aa53f493`。仅在 `C:\build\aurora` 保留未提交源码与验编输出。
- 验收隔离：只使用沙箱、合成凭据、一次性签名密钥和本地 HTTP 桩；不读取真实 profile、SSH 私钥、订阅/节点凭据，不执行真实账号模型调用，不启动真实客户端窗口。本轮没有新增第三方依赖，OpenCode MIT 署名保持。真实窗口、不同权限账户/Windows 版本、PowerShell 5.1 回退、Windows 原生剪贴板与 Android 真机仍未验证。

### 标签页优先、多编辑组与潜在缺陷回归（2026-11-14，未发布）

- 新核心理念见 D-110：**标签页优先，布局服务于任务；位置可以变，工作不能丢。** 文件、终端、AI、PDF、差异与工具页统一作为标签工作单元，侧栏发现/打开，编辑组组织工作。首版实现最多 4 组，支持单组、左右、上下、三列、四宫格，以及顶部/底部单行、顶部多行和左右纵向标签。使用、快捷键、持久化规则和限制见 `docs/TABS.md`，README 已增加入口；不宣称未经真实用户对比已超越 VS Code。
- `TabLayout` 独立保存布局树、次序、活动项与固定状态；`TabWorkspaceView` 将所有正文作为同一稳定 Stack 中的唯一实例。拖放支持组内重排、跨组移动、中央接收与四边拆分，单标签可拆出空组，合并不关闭任务。主侧栏、纵向标签与组间分隔条支持拖动/双击复位；横向标签提供宽度滑块。单行/纵向列表惰性构建，含多行模式在切换活动项、重排与缩放后保持活动标签可见。
- 每个项目独立记忆文件分组、次序、固定、活动文件、焦点、比例、标签位置和宽度，存入原加密 profile 的可选 `WorkspaceView.tabLayout`；深拷贝隔离 Profile 副本与 JSON 调用者，缺失/损坏视图安全回退。只保存文件引用与几何，不保存未保存文字或自动复活终端进程/AI 运行任务；布局变化保留当前缓冲、撤销与流实例。窄屏按实际编辑区尺寸暂时聚焦当前组，恢复宽屏后原布局不变，纵向标签过窄时临时放到顶部。
- 修复并补测：旧连接的服务列表晚到覆盖新连接能力、关闭 AI 页后晚到 roots 响应继续初始化、事件流握手失败未释放 stream、同步失败未重放已有会话的缓冲事件、AI 标题变化未通知标签栏、主侧栏分隔条零高度无法拖动，以及长服务器名的窄屏标题/状态栏溢出。恢复无变化文件视图保存短路，消除打开运行时服务标签产生的无意义写入与对应 500 ms 遗留 timer。
- 批量关闭保护固定项，取消后停止；同一关闭请求去重，保留发起项目的异步关闭语义。新增测试先复现了“切走再切回项目仍继续批量关闭”和“同 ID 新开标签被原快照误关”两项失败，再改为项目切换代次与标签实例快照；修复后工作区/标签组件定向 27 项全部通过。焦点回归验证切换组确实恢复输入焦点，而不只是改变高亮。
- 最终 Flutter 全量 **258 通过、20 既有条件跳过、0 失败**（70 s），完整 `flutter analyze` 零问题（6.2 s）；`aurora_profile` 包 **49 项全部通过**。跳过项仍是需要专用代理/升级 fixture 的既有条件测试，不计作真实端到端验收，也未因本轮失败增加跳过。布局纯状态测试包含 1200 次随机操作的不丢失/不重复检查；带真实字体的四宫格、纵向标签与 390 px 聚焦截图已核对。
- 同一最终源码顺序验编通过：Windows Release（63.1 s）、Android arm64 Debug（21.1 s），仅生成工作区构建输出，未安装设备、未组装正式发行包。Windows Go `go test -count=1 ./...`、Windows 定向 vet、Linux amd64 全量构建与相关包 vet 均通过；本轮未重做真实远程安装或 tmux 生命周期演练，沿用上节已完成的隔离 Linux 回归。
- 本地 agent 再次使用 `tools/test-local-agent.ps1`、一次性签名密钥和真实 Dart 客户端完成 `LOCAL_AGENT_SIGNED_CLIENT_TLS_FILES_MODELS_CONPTY_EXIT_OK`，验证签名产品隔离、回环 TLS、文件、模型、ConPTY 与退出；确认测试私钥已删除。3.99.0 仅为沙箱签名版本，不改变正式版本或发布密钥。
- 最终保护检查：86 个修改/新增源码与文档未发现私钥材料、GitHub/AWS/JWT 令牌模式或新增发行二进制；`git diff --check` 通过，PowerShell 脚本语法检查通过，依赖声明/锁文件及 OpenCode MIT 署名未变。v2 工作区干净，`release` 顶层仍为 13 项，旧 3.13.0 ZIP SHA-256 仍为 `eac52677aaa4c7d5ceb793d86b87c2410e1d70b375e97e37c4e6c267aa53f493`；HEAD 仍为 `25cb8dcc5d449bbbc0462c70be35b7241b5f180d`，全部实现保留为未提交改动。
- 首版边界：不含跨服务器/项目拖放、重复文档视图、浮动原生窗口、无限组或崩溃文本恢复；真实桌面拖放、多屏 DPI、触摸设备、可访问性实机、Android 真机、真实模型账号与 PowerShell 5.1 回退未验收。仅用合成 profile、沙箱和本地桩，不读取真实凭据、不启动抢焦点的真实客户端窗口；本轮不改正式版本、不提交、不打正式包、不发布，也不覆盖 `release` / `release3`。

### 3.14.0 发布准备（2026-11-14）

- 用户在上述开发验收后授权“打包发布”，Windows 与 Android 统一使用 3.14.0。包含 D-108 Windows 本地 agent、D-109 AI 长历史与活动体验、D-110 标签页工作台及后续回归修复；先提交源码，再从干净提交生成签名包，不覆盖任何旧版本或替换正在运行的客户端/服务器。
- 自动化基线为上述 Flutter 258 通过、20 既有条件跳过、完整分析零问题、profile 49 项及 Go/本地 agent 沙箱回归。正式包另核对版本、发布公钥签名、篡改拒绝、ZIP/文件夹一致、Android 证书/ABI/内置文件、许可证与敏感模式；不能将组件测试或签名验收称作真实窗口/账号/设备验收。
- 发布准备时 GitHub 凭据未继承，上次一次性 DPAPI 授权已清理；用户随后提供了本次发布授权，按当前用户 DPAPI 加密暂存，仅在进程内解封用于推送与发布，不写入源码/包。此条保留为准备阶段记录，正式结果见下节。

### 3.14.0 提交、签名打包与 GitHub 发布（2026-11-14）

- 已发布：https://github.com/Moraxusio/aurora/releases/tag/v3.14.0 。源码提交与标签 `v3.14.0` 均为 `689047d903d5cf098c43f1f3ea11a1a3a1b7442c`，从干净提交构建，Windows 与 Android 统一 3.14.0。先上传草稿并核对全部资产的服务端摘要，再转为正式 Release；ZIP、sidecar、三个 APK、`SHA256SUMS.txt` 共 **6 个资产全部重新下载，SHA-256 与本地一致**。
- 已归档至 `release3\Aurora-3.14.0` 及同目录 ZIP、sidecar、三个 APK 和 Android SHA-256 清单。Windows 文件/产品版本均为 3.14.0；ZIP 的 **33 个文件**与产物目录及归档逐文件一致。ZIP：29,811,272 字节，SHA-256 `cb6d0944d803357543931fa7b28cc2f0294abe5bd602a0c974b29c6e1de1caf4`。
- Linux amd64 远程 agent：14,020,770 字节，SHA-256 `6d2c43f2a3fe111eac24ab28deaca922b3411d5360360e8c069cf2ee735f2750`；Windows amd64 本地 agent：9,629,696 字节，SHA-256 `32b72c5417ce67b360c3af73df0477166042f50bfaef40403d8b698e70a1dcb2`。二者版本 3.14.0、发布密钥 ID `87828dfb18459372`，分别使用 `aurora3-agent` / `aurora3-local-agent` 产品；Go 元数据均为上述源码提交且 `vcs.modified=false`。
- 正式公钥验签、远程 agent/manifest 篡改拒绝、签名升级策略验签/篡改拒绝/普通降级拒绝通过。Windows 本地产品额外验证双向产品隔离、二进制/manifest 篡改拒绝，并用**包内正式签名本地 agent**再次完成 `LOCAL_AGENT_SIGNED_CLIENT_TLS_FILES_MODELS_CONPTY_EXIT_OK`；只访问隔离沙箱与本地 HTTP 桩，不打开真实 profile/客户端窗口。首次专用 Dart 验收的原生 hooks 构建超过 120 秒工具时限，延长时限后全部通过，未跳过校验。
- Android APK：arm64-v8a（versionCode 33400）40,083,102 字节，SHA-256 `a2667a25b64bf9ac94a42aa35d11cd6d14ff8233831a6e51472a144438c0d05c`；armeabi-v7a（32400）35,477,542 字节，SHA-256 `ae37b6e18ee166b4aa2839ed49cb933f00562cf8301c803afe94fbb0ee0687fe`；x86_64（35400）42,311,228 字节，SHA-256 `086e14c03136328e2c7274b127416aa41c6ba786ad57f7401f97fca9ee1432cb`。versionName 均为 3.14.0；apksigner、版本/ABI 检查通过，证书 SHA-256 沿用 `db59a41d0511deaae35f6848e4088db20a8a9846635975635e79efa6f1554882`，三个 APK 的 5 个远程 agent 文件和 3 个法律文件均与 Windows 包逐字节一致。
- 包内敏感字符串/可疑文件扫描通过，OpenCode MIT 署名完整，ZIP 与 Android 哈希清单通过；没有私钥、profile、测试夹具或 GitHub 凭据进入包。v2 工作区仍干净，`release` 顶层仍为 13 项；旧 3.13.0 ZIP SHA-256 仍为 `eac52677aaa4c7d5ceb793d86b87c2410e1d70b375e97e37c4e6c267aa53f493`。没有覆盖旧版本或替换正式安装。
- 自动化验收基线与未验证边界沿用上节：Flutter 258 通过、20 既有条件跳过、完整分析零问题、profile 49 项及 Go/沙箱回归；发布准备时另复跑标签组件 9 项和完整分析通过。真实桌面拖放、多屏 DPI、触摸/可访问性实机、Android 真机、真实模型账号、PowerShell 5.1 回退等仍未验收，发布说明已明确列出。

### 奥卡姆剃刀 UI、直接拖放与性能验收版（2026-11-14，未发布）

- 用户要求以顶级审美与奥卡姆剃刀重新整理冗杂 UI，保留分屏想法但操作更直觉，修复标签拖动卡顿，编译后先人工验收。决定见 D-111，设计与操作见 `docs/UI_REVIEW.md`；本轮没有提交、推送、正式打包或发布授权。
- 删除常驻编辑组标题、重复布局控件和五区整屏拖放提示，合并为单一标签栏/按需视图菜单；支持单一落点预览、标签前后半区插入、长列表边缘自动滚动和普通滚轮横移。放大/还原保持原布局树；项目代次与标签实例验证拒绝旧拖动作用于切换后/新开标签。保留全部排布、固定项与异步关闭保护。
- 平整连续的深浅色工作台、收敛的强调色、简化的活动栏/设置入口/欢迎动作列表；文件侧栏去重复标题，文件低频动作收进选项。AI 运行统计默认压为一行，详情按需展开，不隐藏批准/错误/执行活动。补齐既有高亮库的 Dart 语法支持，没有新增依赖或借用第三方图形资源。
- 性能回归先复现：30 个标签、24 次窗口缩放产生 696 次隐藏正文布局；240 次宽度更新产生 240 次业务广播。修复后均为 0，几何事件同一帧合并为 1 次；几何快照延迟到保存/flush，保留最后约束与编辑区 widget，拖放预览独立重绘。测试计数不作为真实 FPS 或用户设备流畅度保证。
- 定向测试通过：工作区/标签/性能 33 项；文件操作、编辑器、真实 Shell 组件截图与拖放定向 44 项。深浅色、分屏 AI、纵向标签、布局面板与 390 px 截图使用真实字体和内存夹具，已核对；不读真实 profile，不打开原生窗口。
- 最终 Flutter 全量 **267 通过、20 个既有条件跳过、0 失败**（43 秒），完整分析零问题（5.8 秒）；Windows x64 Release 编译成功（52.4 秒），Android arm64 Debug 兼容编译成功（266.7 秒），均显式保留基础版本 3.14.0，Android Debug 不作为正式分发包。其后对最新原生标题栏模拟截图测试再次复跑通过，最终完整分析仍为零问题（6.3 秒）。生产 UI 源码在上述编译后未再改变。
- 独立验收目录：`C:\dev\VPS\preview3\Aurora-UI-Review-20261114`。交付完整 `app` 目录、中文 README、六张组件截图、`BUILD-INFO.json` 与 SHA-256 清单；从根目录 `启动验收版.cmd` 启动，设置独立 `AURORA3_INSTANCE_SCOPE`，将 `LOCALAPPDATA`/`APPDATA` 指向本包 `review-data`，清除测试信任覆盖并固定使用随包 agent。首次配置为空，不复制或读取原 profile/API Key/OAuth；这是配置隔离，不是文件权限沙箱，用户选择的真实项目仍可编辑。
- 验收包 `data/app.so` SHA-256：`524d4246142d015936c970374a9de036d0f42a3a12ce82f5078fe35138d64817`，与旧正式 AOT 不同，与最新 Release 编译产物逐文件一致。8 个远程/本地后端文件及法律文件沿用正式包，后端字节不变；Linux agent 发布公钥验签通过，包内 Windows 本地 agent 再次完成 `LOCAL_AGENT_SIGNED_CLIENT_TLS_FILES_MODELS_CONPTY_EXIT_OK`，仅操作独立临时沙箱和回环 HTTP 桩。首次专用 Dart 原生 hooks 超过 120 秒工具时限，延长时限后验签及联调均通过，没有跳过检查。
- 未启动真实验收客户端窗口、未安装系统服务或触及正式服务器。真实桌面长期拖放、多屏 DPI、触摸/可访问性实机、Android 真机和真实模型账号仍待用户验收。依赖声明、后端源码及正式打包脚本未修改；敏感模式/许可证检查通过，v2 工作区干净，`release` 顶层仍为 13 项，正式 3.14.0 ZIP SHA-256 仍为 `cb6d0944d803357543931fa7b28cc2f0294abe5bd602a0c974b29c6e1de1caf4`；本轮源码未提交、未推送、未发布。

### 3.15.0 发布准备（2026-11-14）

- 用户验收 UI 预览后明确授权提交、推送与发布，Windows、Android 和随包两类 agent 统一为 3.15.0。包含 D-111 的界面减法、直接拖放与几何更新隔离；不新增依赖，不改变 profile 格式或后端功能。先提交最终源码，再从干净提交构建签名包，旧版与独立验收包保持原样，不替换正在运行的安装。
- README、标签页操作说明与包内更新说明同步为实际 3.15.0 界面；保留预览包的历史验收记录及真实原生窗口/设备/账号未验证边界。正式发布前复跑全量回归、完整分析，检查签名与篡改拒绝、Windows ZIP 一致、Android 签名/版本/ABI/内置文件、许可证和敏感模式。
- 发布前复测：Flutter 全量仍为 **267 通过、20 个既有条件跳过、0 失败**（49 秒），完整分析零问题（6.1 秒）；Windows Go `go test -count=1 ./...` 全部通过，两个正式 PowerShell 打包脚本语法检查通过。首次执行因包含原生 hooks 构建超过工具 180 秒上限而中止，延长执行方式后完整复跑通过，没有跳过失败测试或改动验收标准。
- 上次一次性发布凭据已清理；用户重新授权后，本次凭据仅以当前用户加密形式暂存于仓库外，在进程内解封使用，发布完成后清理，不进入源码、发行包或发布说明。正式发布与重新下载核验结果另补。

### 3.15.0 提交、签名打包与 GitHub 发布（2026-11-14）

- 已发布：https://github.com/Moraxusio/aurora/releases/tag/v3.15.0 。源码提交及标签 `v3.15.0` 均为 `b78a0aaf6308eccb840810a29d944184dade9c59`；源码先推送到 main，从干净提交构建。Windows、Android 及两类随包 agent 统一 3.15.0。先上传草稿并验证所有资产的服务端 SHA-256，再转为正式 Release；Windows ZIP、sidecar、三个 APK 与 `SHA256SUMS.txt` 共 **6 个资产全部重新下载，哈希及大小与本地一致**。
- 已归档至 `release3\Aurora-3.15.0`、同目录 ZIP/sidecar、三个 APK 和 Android SHA-256 清单。Windows 文件/产品版本均为 3.15.0，ZIP 的 **33 个文件**与产物目录及归档逐文件一致。ZIP：29,828,270 字节，SHA-256 `51f834fced3c21b47a4f1705867e497c94a7ce56e36e755219f5c34aff0ab10e`。Windows Release 构建 68.1 秒；Android 首轮因 Google Maven 元数据 TLS 握手中断失败，Flutter 自动重试后三个 Release ABI 均构建成功，没有更改依赖或跳过校验。
- Linux amd64 agent：14,020,770 字节，SHA-256 `e559d0c84dbddf9a9e62278895857098d9ed5adbf4b8082e28a2880ee3b4d2f4`；Windows amd64 本地 agent：9,629,696 字节，SHA-256 `adfa4599d79d946f2626b0be39475d000da518f6d42c9931168f89b4318a3c84`。版本均为 3.15.0、发布密钥 ID `87828dfb18459372`、产品分别为 `aurora3-agent` / `aurora3-local-agent`，Go 元数据均标识上述源码提交且 `vcs.modified=false`。
- 两类后端正式公钥验签、二进制/manifest 篡改拒绝、双向产品隔离通过；签名升级策略验签、篡改拒绝及普通降级拒绝通过。使用包内正式本地 agent 再次完成 `LOCAL_AGENT_SIGNED_CLIENT_TLS_FILES_MODELS_CONPTY_EXIT_OK`，只访问独立临时目录与回环 HTTP 桩，不读取真实 profile、凭据或启动客户端原生窗口。
- Android：arm64-v8a（versionCode 33500）40,083,094 字节，SHA-256 `34094b0f8c797b7a6baf6522a2e3ac68513ed239c3f5d8a85504e793bd9f119f`；armeabi-v7a（32500）35,526,690 字节，SHA-256 `7a632dd5bac962442c9c49dfca53b939c69ccea8196612bc4ab2f26ce75c5be8`；x86_64（35500）42,311,224 字节，SHA-256 `0e331e130a222f4bfe35614d84ff3d94bec7a0a8852853ced65d25a934205a08`。versionName 均为 3.15.0；apksigner、ABI 和内置文件检查通过，发布证书 SHA-256 沿用 `db59a41d0511deaae35f6848e4088db20a8a9846635975635e79efa6f1554882`，每个 APK 的 5 个 agent 文件、3 个法律文件均与 Windows 包逐字节一致。
- 敏感字符串/可疑文件扫描、许可证与校验清单通过，保留 OpenCode MIT 署名。没有私钥、真实 profile、测试夹具或发布凭据进入包；不重置 API Key/OAuth。v2 工作区仍干净，`release` 顶层仍为 13 项，旧 3.14.0 ZIP SHA-256 仍为 `cb6d0944d803357543931fa7b28cc2f0294abe5bd602a0c974b29c6e1de1caf4`；独立预览 AOT 哈希仍为 `524d4246142d015936c970374a9de036d0f42a3a12ce82f5078fe35138d64817`，未替换正在运行的客户端或服务器。
- 自动化基线为发布前 Flutter 267 通过、20 个既有条件跳过、0 失败，完整分析零问题与 Windows Go 全量回归。用户已验收独立 Windows UI 预览；长期原生拖放、多屏 DPI、触摸/可访问性实机、Android 真机、真实模型账号及 PowerShell 5.1 回退仍未作完整实机验证，发布说明已明确列出。

### D-112 工作台稳定性与底部终端（2026-11-14，独立验收，未提交/发布）

- 用户反馈右侧标签遮挡正文、终端应放到底部及整体标签逻辑不稳定。本轮按 VS Code 的区域职责改为固定双宿主：文档/AI/工具页在编辑区，终端正文及会话列表在底部；不替换文件树，不参加文档分屏、拖放或批量关闭。实际先复现四项失败再修复，新增正文/欢迎页裁剪。
- 预设保留既有组身份、标签归属、活动项和焦点，新增格子为空、减少才合并。隐藏/最大化/窄窗切换保持缓冲、AI 状态和终端流；终端连接与模态窗口焦点有异步保护，列表结果检查连接/代次/实例，结束失败不丢视图。快捷键执行时判断异步服务可用性。仅保存浏览视图 `panel_height`，不保存会话或正文，不迁移凭据。
- 回归覆盖 1,152 组区域几何状态、125 组文档组合、拖放边界、固定标签、未保存/异步关闭、独立焦点和持久化。真实终端 widget 配合内存协议桩保留后台输出、全程一次连接；240 次面板高度更新的工作量为 0 次业务通知、1 次几何通知、0 次隐藏终端布局。11 张真实组件截图覆盖深浅色、底部终端、右侧标签、AI 分屏、最大化及手机。
- 最终 Flutter 全量 **293 通过、20 个既有条件跳过、0 失败**（49 秒）；完整 `flutter analyze` 零问题（8.4 秒）。包含新增的会话结束失败、确认时换连接、旧列表不得删除重开实例、结束响应后换连接等异步保护；没有为通过而修改或新增跳过条件。
- Windows x64 Release 编译成功（213.3 秒），Android arm64 Debug 兼容编译成功（256.1 秒），均显式指定 3.15.0 / build 31500；生产源码在最终测试与两次构建间冻结，78 个源码文件哈希未变化。Android Debug 只用于兼容检查，未安装或分发。
- 已交付 `C:\dev\VPS\preview3\Aurora-Workbench-Review-20261114`，从根目录 `启动验收版.cmd` 启动：32 个运行文件、11 张组件截图、中文说明、操作文档及构建记录；48 个文件逐项 SHA-256 校验通过。新 AOT SHA-256 为 `a01c1c4abbb375bfad37d389197651c36416d2f0237ea88e5ed459872d193cca`，与正式版/上轮预览不同。8 个后端文件逐字节沿用正式 3.15.0，法律文件与 OpenCode MIT 署名保留，无新依赖；敏感模式与可疑文件检查通过。
- 独立实例及配置启动器静态检查通过，包内尚无 `review-data`，没有自动启动真实窗口。67 个受保护旧产物哈希不变，v2 工作区干净、`release` 顶层仍为 13 项；不读取原 profile 或凭据、不覆盖正式客户端/服务器、不提交/推送/发布。本轮未运行原生窗口集成测试，不将选择器更新或组件截图冒充长期原生拖放、多屏 DPI、触摸、Android 真机或真实账号验收。

### 3.16.0 发布准备（2026-11-14）

- 用户验收 D-112 独立预览后明确授权快速打包发布。包含底部终端、右侧正文裁剪、保持归属的布局预设和异步焦点/会话保护；Windows、Android 与两类 agent 统一为 3.16.0，使用既有发布签名。不新增业务功能，不覆盖旧包或正在运行的安装。
- 沿用刚完成且生产源码未改变的 Flutter 293 通过、20 个既有条件跳过、零分析问题结果，不重复长期/原生窗口测试。发布只检查必要的构建、版本、产品签名、Android 发行证书、包体与上传摘要，不再进行全量下载或真实服务联调。
- 原 profile/API Key/OAuth 不迁移、不重置；发布授权仅用于本仓库，凭据不进入源码、发行包和发布说明，完成后清理临时授权。打包和发布结果完成后补记。

### 3.16.0 已发布（2026-11-14）

- 发布：https://github.com/Moraxusio/aurora/releases/tag/v3.16.0 。源码与版本标签均为 `095c94fb6a5fe209b55548d33a2adef0fd2206eb`，先从干净提交构建，再上传草稿；Windows ZIP、sidecar、三个 Android APK 和 `SHA256SUMS.txt` 共 6 个资产，大小及 GitHub 服务端 SHA-256 全部匹配后转为正式 Release。按用户要求不重复全量下载、原生窗口或真实服务联调。
- Windows Release 构建 171.4 秒，Android 三 ABI Release 构建 79.7 秒；客户端与两类 agent 均为 3.16.0，沿用既有发布密钥和 Android 发行证书。包内产品签名、Windows/Android 版本及 ABI 检查通过，ZIP 的 33 个文件与目录一致，法律文件和 OpenCode MIT 署名保留。回归结果沿用发布前同一生产源码的 Flutter 293 通过、20 个既有条件跳过及完整分析零问题，没有将复用结果写成再次运行。
- 本地归档为 `release3\Aurora-3.16.0` 及同目录 ZIP/校验文件、三个 APK 和 `Aurora-3.16.0-android.sha256`。ZIP 29,847,540 字节，SHA-256 `805d0bd2bab72f6bd47aed2a0c38260b807ce595de2ffe3738865e412fda91cd`。Linux agent SHA-256 `9d27f45408d1a703a66c4809dadddbd1b894d46941ea59ae3a5e5f3d079c82f7`；Windows 本地 agent `64b4e752efd71e50d82c75c3e1990cc073408e8f9be69708cc4b8ba6fbf17793`。
- Android arm64-v8a（33600）：40,148,718 字节，SHA-256 `89f97e2658b51fed5f252edd84b8b672068b2d8fc9357a5cb5e83e0662adfdae`；armeabi-v7a（32600）：35,559,542 字节，`98c7634c08098f75f64907a0eb2883083c3029d8aba894605e745d51c20ea5ea`；x86_64（35600）：42,442,380 字节，`178105d9502a791461e9e3992c090c1449d7602394a96e3bc3e3e03a45b1966d`。证书 SHA-256 仍为 `db59a41d0511deaae35f6848e4088db20a8a9846635975635e79efa6f1554882`。
- 旧 3.15.0 ZIP 与已验收工作台预览 AOT 哈希不变，v2 工作区干净、`release` 顶层仍为 13 项；不替换正在运行的客户端或服务器，不读取真实 profile 或迁移凭据。用户已验收独立 Windows 预览，长期原生拖放、多屏 DPI、触摸/可访问性、Android 真机及真实模型账号仍未完整验收，发布说明保留这些边界。

### D-113 / D-114：工作台与 AI 阅读重设计（2026-11-14，未提交/发布）

- 根据用户截图与反馈重整区域职责，实际阅读 VS Code editorPart/editorDropTarget/splitview/chatListWidget 的 MIT 源码，并参考 Codex IDE 官方侧栏层级。文档网格、AI 右侧栏、底部终端固定独立宿主；纯网格求解替代按聚合最小尺寸突变的布局。拖放变为修订/实例保护的事务，唯一标签不能拆到自己，跨组最后标签移动原组身份。显式分屏创建空视图，历史打开复用原 AI 草稿宿主；不再为新建对话删除 `ai:new`。
- 新 AI 时间线以稳定消息为中心惰性构建，固定上一条/下一条/锚点列表/最新入口；以可见文字字符修正缩放换行的位置，修正发生在布局阶段，不排队 animateTo。上读历史时流式输出/尺寸变化/后台同步不恢复自动跟随。已完成/取消计划立即退出固定区域，活动计划默认一行，工具活动留在时间线；输入区固定控制行。仅增加可选 `assistant_width` 几何字段，不迁移凭据或保存草稿。
- 最终完整 Flutter 分析零问题，全量 **313 通过、20 个既有条件跳过、0 失败**，总测试耗时 58 秒。新增回归覆盖 Escape 后再次拖放、缓存消息同原点/同尺寸回最新在同次布局完成且延时不抖动、短历史顶部对齐、240 高窗口输入、保存草稿历史复用/重命名/删除与失败删除保留，以及 AI 放大后新建/激活/聚焦/放大终端必须先退出 AI 放大；三宿主几何遍历 2880 种组合。生成 17 张真实组件截图，实际查看了双文档 + AI + 终端、拖放预览、深浅色/手机 AI、右侧标签及完成计划界面；未运行真实原生窗口。
- 最后补齐 AI 放大后的终端焦点切换时，冻结校验拦截了旧构建，未组装或交付旧二进制；随后重新通过上述 313 项全量回归，并更新冻结记录。最终 998 个客户端/本地包/第三方/平台及资源生产文件在构建前后逐个核对一致。
- 独立验收包已生成：`C:\dev\VPS\preview3\Aurora-IDE-Review-20261114\启动验收版.cmd`。最终 Windows x64 Release 构建命令耗时 62.3 秒，Android arm64 Debug 兼容编译 15.4 秒（含命令开销）；显式版本 `3.16.0+31600`，未签发 Android 正式包。Windows AOT 14,238,600 字节，SHA-256 `dc5e4bed1f5ae14d8971fd423c2feba022a1d0185733a045f2797444d3fced1a`，与正式版及旧预览均不同；Android 兼容 APK SHA-256 `f0e18055196ad7b466d0d4f7361199e591f1d8b409056137fd1bd53daa6390b9`，只留在构建缓存。
- 包内含完整 Windows runtime、正式 3.16.0 两类 agent 与其策略/清单/签名（8 个后端文件逐字节一致）、法律文件、OpenCode MIT 署名、17 张组件截图、中文说明和构建信息；32 个程序载荷文件复制一致，56 项 SHA-256 校验全部通过。启动器隔离实例及 Local/Roaming 配置目录，清空测试信任密钥并固定随包后端，未创建运行配置或启动原生窗口；配置隔离不是文件权限沙箱。
- 正式 3.16.0 ZIP/AOT 与两个旧验收 AOT 均与保护记录一致，v2 工作区仍干净、`release` 顶层仍为 13 项。没有覆盖正式包、旧预览或运行中的客户端/服务器，没有读取真实 profile/SSH/订阅/模型凭据，未提交、推送或发布。长期原生拖放、多屏 DPI、触摸/输入法/可访问性、Android 真机及真实模型账号仍待实机验收。

### 3.17.0 发布准备（2026-11-14）

- 用户验收 D-113/D-114 独立预览后明确授权打包发布。文档网格、AI 右侧栏、底部终端独立，包含可取消的拖放事务、固定消息锚点、稳定缩放阅读和完成计划自动收起；Windows、三 ABI Android 与两类 agent 统一为 3.17.0，客户端 build number 31700，沿用原发布签名与 Android 发行证书。
- 验收后的 998 个生产文件哈希不变，复用刚完成的 Flutter 313 通过、20 个既有条件跳过、0 失败及完整分析零问题结果，不重复 UI/原生长期测试。仅更新发布说明和 Windows 打包脚本的显式 build number，使其与 Android 一致；必要验证限于版本、构建、签名、包内文件及服务端上传摘要，不重复全量下载。
- 先从本地干净提交构建，不覆盖正式安装、旧归档或三个独立预览。GitHub 授权只临时加密保存并限定本仓库发布用途，不进入源码、包或日志，完成后清理；原 profile/API Key/OAuth 不迁移、不重置。构建与发布结果完成后补记。

### 3.17.0 Windows 已发布（2026-11-14）

- 发布：https://github.com/Moraxusio/aurora/releases/tag/v3.17.0 。源码及版本标签指向 `b8feba43b0ee44a6a891f284177109b1ef501687`；Windows 包由该干净提交构建，客户端版本 `3.17.0+31700`，两类签名 agent 同为 3.17.0，沿用发布密钥 ID `87828dfb18459372`。
- 用户补充要求主要维护 Windows、Android 可以暂缓，已停止本轮 Android 构建，并只清理与本次来源哈希一致的 8 个 Android 暂存资源；**本 Release 仅含 Windows ZIP、ZIP sidecar 和 SHA256SUMS 共 3 个资产，不提供 3.17.0 APK**。后续 Windows 维护不再默认等待 Android 三 ABI 构建，安卓既有 3.16.0 保留不动。
- Windows Release 编译 183.1 秒，包内 33 个文件与 ZIP 逐项一致，产品签名、版本、许可证和敏感文件/字符串检查通过；保留 OpenCode MIT 署名。AOT SHA-256 `dc5e4bed1f5ae14d8971fd423c2feba022a1d0185733a045f2797444d3fced1a` 与已验收预览逐字节相同，998 个生产文件哈希一致，复用 Flutter 313 通过、20 个既有条件跳过、零分析问题结果，没有重复整轮 UI/原生/真实服务测试。
- 本地归档 `release3\Aurora-3.17.0` 及 ZIP/sidecar。ZIP 30,461,852 字节，SHA-256 `5ca41970183e95b784ded1bb1545efe26eb2ab8c840840c2614b140d56ab796e`；Linux agent `dee6f4a4d73991a420f7293332f4162315e1e4cdf4de311f0e5c9aa0d6f82fa3`，Windows 本地 agent `38531348ac0a0788ed00878d5474149ccf10d448a853b55df675237334f8404f`。先上传草稿，3 个资产的大小与 GitHub 服务端 SHA-256 全部匹配后才发布；公开 latest API 已确认 v3.17.0、非草稿、非预发布，未重复全量下载。
- 正式 3.16.0 与三个旧预览的 5 项保护哈希不变，v2 工作区仍干净、`release` 顶层仍为 13 项；未覆盖运行中的客户端或服务器，未迁移原 profile/API Key/OAuth。发布授权仅临时使用并在全部推送后清理；长期原生拖放、多屏 DPI、触摸/输入法/可访问性及真实模型账号仍保留实机验收边界。

### D-115：Astra Windows 工作台重构验收（2026-11-14，未提交/发布）

- 用户对之前 UI 不满意并授权彻底重构，要求对齐 VS Code 严肃界面、实时字号与灵活鼠标拖放。基于 `16c4b842673be665116fcc1dec2c21d59e69366e` 重写显示偏好/设置页、统一主题与公共控件、加入工作台缩放、固定侧栏宿主和五向停靠标记。详见 [WINDOWS_WORKBENCH.md](WINDOWS_WORKBENCH.md)，Android 暂缓。
- 查明终端字号硬编码、滑块写盘阻塞预览及工作区通知级联。独立 `AppearanceController` 同步预览、240ms 防抖、字段合并/串行保存/失败重试；文件、终端、AI 独立订阅字号。保留控制器、未保存内容、撤销、连接、消息阅读锚点及关闭保护；隐藏文件延后到显示时应用字体。原生测试另发现 AI 占宽后终端和文档分屏被误判窄屏，均已修复。
- 完整 Flutter 分析零问题；全量 316 通过、20 个既有条件跳过、0 失败（早于最后的几何/隐藏字体修改）。最终定向回归 62/62 通过，之后分析零问题；没有重复声称做过最终全量重跑。`aurora_profile` 原全量 48 通过、1 个旧上限断言失败；更新 AI 范围 9–28 并增加可选字段兼容性测试后，该文件 6/6 通过。
- Windows Profile 原生测试最终通过：1682×1066、DPR 1.25、12 文件、一次终端连接，真实组件鼠标停靠、AI 旁双文档同时可见、字号、缩放与缓冲保留。字号 build/raster P95 从优化前 36.269/29.541ms 降为 6.550/4.801ms；最终分隔线 4.621/3.769ms、文件切换 7.761/4.106ms、整体缩放 8.401/11.310ms。对应 25/72/37/5 帧均未超过 16.7ms；缩放采样少且之前一次有慢帧，不作为所有环境 60fps 保证。全部使用内存协议桩，不读取真实账号或服务器。
- 生产入口 `lib/main.dart` Windows x64 Release 构建成功，耗时 160.7 秒，客户端 `3.17.0+31701`；AOT SHA-256 `8f23bddc3e9abc4bc35ebabef6edb26ce2b4535c942b5e2956a860c966067292`。构建期间记录的 989 个 Windows 相关源码/资源/本地依赖文件在组包时逐项核对一致，未在构建后修改生产代码。
- 独立验收包：`C:\dev\VPS\preview3\Aurora-Astra-Review-20261114\启动验收版.cmd`。32 个程序载荷文件、正式 3.17.0 两类 agent/策略/清单/签名逐字节复用、许可证与 OpenCode MIT 署名、6 张截图、测试/性能日志、源码摘要、BUILD-INFO 与 SHA256SUMS；53 项包内摘要校验通过。启动器隔离 Local/Roaming 配置、实例名和 agent 路径，首次启动创建空配置目录；交付 Release 本身未自动启动，原生测试使用独立 Profile 入口。
- 正式 3.16.0/3.17.0 ZIP/AOT 与三个旧预览的共 7 项保护哈希匹配，v2 工作区干净、`release` 顶层仍为 13 项。开发修改保留在本地工作树，未提交、推送或发布；验收包等待用户体验。

### D-116：侧栏跟手与界面减法验收（2026-11-14，未提交/发布）

- 用户初步认可标签栏，要求修复拖宽不跟手并按奥卡姆剃刀原则压平界面。定位到同帧事件用旧布局宽度叠加单次增量，导致先前位移被覆盖；统一分隔线改为按下时实际尺寸、全局原点与缩放比例计算总位移，第一像素响应，保持按帧几何通知及固定文档宿主。
- 文件只保留一条工具栏，根节点单行，移除重复选中路径条与文档路径条；AI 目录/选项合入固定消息导航，输入控件一行，运行详情按需展开；历史原位切换并去掉重复的新建整行入口。中等窗口侧栏并排、齿轮直达设置。详见 [WINDOWS_SIMPLIFICATION.md](WINDOWS_SIMPLIFICATION.md)。
- 本轮覆盖 78 个不同定向测试：首次 77 通过、1 个旧“推理强度常驻文本”断言失败，改为 tooltip 后通过；后续 18 通过、1 个历史截图等待运行中 spinner 的超时，改为固定 pump 并验证已加载后视觉单项通过。最后历史入口精简后 AI/原位历史保活/真实组件视觉 17/17 通过，分析零问题。没有重新跑全量；不将多次定向结果表述为最终单次全量通过。
- Windows Profile 原生测试通过：12 文件、一次终端 attach、128 次高频侧栏移动，逐帧最大指针位置偏差 **0.0 逻辑像素**。侧栏 51 帧 build/raster P95 **6.577/4.403ms**；字号 25 帧 13.520/7.170ms、AI 分隔线 55 帧 8.126/4.047ms、标签切换 37 帧 9.744/4.933ms、缩放 5 帧 8.208/12.630ms，均无超 16.7ms 帧。使用模拟协议及独立配置；测量早于最后历史按钮显隐改动，拖宽热路径此后未变。
- 生产入口 `lib/main.dart` Windows x64 Release `3.17.0+31702`：第一次构建 228.0 秒；最后隐藏历史重复入口后重新构建 58.5 秒。最终 AOT SHA-256 `f535b0bb94ce8051630b6117e4930de68eec3f94a3ac150fabc0abd822b4d55b`。最终构建启动后修正源码快照的根目录，记录 989 个 Windows 源码/资源/本地依赖文件，组包逐项核对一致；该次构建启动后无生产代码修改。
- 独立验收包：`C:\dev\VPS\preview3\Aurora-Lean-Review-20261114\启动验收版.cmd`。32 个程序载荷文件、7 张截图、4 份说明、测试/原生性能/构建日志、源码摘要、BUILD-INFO 与 SHA256SUMS，56 项摘要校验通过；两类正式 3.17.0 agent/策略/清单/签名逐字节复用，保留法律文件和 OpenCode MIT 署名。启动器使用独立空配置和实例名，交付 Release 未自动启动。
- 正式包及四个旧预览的 8 项保护摘要匹配，v2 工作区干净、`release` 顶层仍为 13 项。未读取真实 profile、SSH 私钥、订阅或模型凭据，未迁移 API Key/OAuth；源码修改保留在工作树，未提交、推送或正式发行。

### 3.18.0 发布准备（2026-11-14）

- 用户完成 Windows 工作台/精简版验收后明确要求“编译打包发布”。本轮发布 Windows x64，客户端与 Linux/Windows 两类随包签名 agent 统一为 3.18.0，客户端 build number 31800；Android 继续暂缓。
- 保持已验收的 989 个 Windows 生产源码/资源/本地依赖文件，复用上述定向测试、最终 17/17、分析零问题及原生 Profile 结果，不重复整轮 UI 测试。仅补发布说明与打包说明，从提交后的干净源码构建；旧正式包及五个独立预览保留。
- 发布过程校验版本、签名、ZIP 与目录逐项一致性及 GitHub 上传资产摘要；原 profile/API Key/OAuth 不迁移、不重置。当前 GitHub 无非交互登录凭据，编译打包先行，发布授权补齐后上传。

### 3.18.0 Windows 已发布（2026-11-14）

- 发布：https://github.com/Moraxusio/aurora/releases/tag/v3.18.0 。源码与标签指向 `b685a45402ef5f466e619b4fefe0c32647b35973`，来自干净工作树；Windows 客户端 `3.18.0+31800`，两类签名 agent 同为 3.18.0，沿用密钥 ID `87828dfb18459372`。本轮只发布 Windows ZIP、ZIP sidecar、SHA256SUMS 共 3 项资产，Android 暂缓。
- Windows Release 构建耗时 184.2 秒；33 个包内文件与 ZIP 逐项一致。最终 AOT `f535b0bb94ce8051630b6117e4930de68eec3f94a3ac150fabc0abd822b4d55b` 与用户验收的 Lean 预览逐字节相同，989 个生产文件摘要匹配，复用已记录的定向/分析/原生 Profile 结果，没有重复整轮回归。构建后的 Go 元数据检查原先错误地要求 `-trimpath` 产物记录 linker flags，已改为核对干净源码 revision 并运行两类二进制的 `version`；均返回 3.18.0，Windows GUI 子系统通过显式重定向读取输出。
- 本地包 `C:\dev\VPS\release3\Aurora-3.18.0.zip`，30,477,694 字节；SHA-256 `18ddbf4d19cedac6cdcb0b50a040be7cc4e654012bd124bfc0261e70e04e1f10`。Linux agent `0c01b188439f2ee672a0c4b723de0e7f798197acffae329c2bd6d507344e1309`，Windows agent `73c910af292643cfd5f6c4557d6cd109e092b723f4b82bfbce05e6b354776258`；产品签名与版本验证通过，保留 OpenCode MIT 署名。
- 源码及标签已推送，先上传草稿，在 3 项资产大小及 GitHub 服务端 SHA-256 全部匹配后发布为 latest；没有重复整包下载。正式包及五个预览的 9 项保护哈希匹配，v2 工作区干净、`release` 顶层仍为 13 项。正式包沿用已有加密配置，未迁移 API Key/OAuth；临时发布授权在本机 DPAPI 暂存，仅用于本次 GitHub 发布，完成后清理。

### 3.18.1 GUI 检查与发布准备（2026-11-14）

- 用户在 85% 缩放发现按钮失效，随后授权完整 GUI 检查、端到端测试和直接编译发布。D-117 统一缩放绘制/命中与 Overlay 坐标；修复命令弹窗 Navigator 上下文、通知宽度、终端保留快捷键、文件预览的焦点/半屏及 AI 历史激活。具体失败回归与覆盖见 [GUI_AUDIT.md](GUI_AUDIT.md)。
- 正式 `AuroraApp` 根节点新增连续缩放工作流，覆盖菜单遮罩、输入、历史、终端、分隔线、拖放及未保存关闭取消。缩放命中矩阵 80–150% 每 5% 一档 × DPR 1/1.25/1.5/2，窗口标题按钮另测 5 档缩放 × 4 档 DPR；语义开启下也执行完整组件流程。
- Windows Profile 测试的首次失败分别定位为测试 IME 未注册（Profile 拒绝 debug 专用 client ID -1）、模拟键盘未显式传入 physicalKey（Profile 无 debugName）和触摸点击后直接发鼠标拖动；修正测试输入注册、显式键码及统一鼠标手势后，完整交互工作流通过。原生窗口为 1682×1066 物理像素、DPR 1.25，内存服务和测试输入，不连接真实账号/服务器。
- 原生日志进一步发现 settings Slider 的 OverlayPortal 语义节点 137 未被 Windows AXTree 接受。语义快照定位到 slider 的跨滚动子树 traversal parent；单独语义边界、关闭数值提示均不足以修复，最终改为同子树局部 Overlay 后，完整原生工作流及 AXTree 日志检查通过。相同修复覆盖标签宽度滑块，并按真实 %/px 朗读数值。关联 Flutter 上游 #182444/#190344；保留全应用语义、Tooltip 和数值提示。
- 发布版本采用 3.18.1，客户端 build number 31801、两类随包签名 agent 同版本；从提交后的干净源码构建，旧正式包/五个预览保护项增为 11 项。GitHub 授权仅本机 DPAPI 临时保存，发行后清理。
- 全量回归 329 项通过、20 项按既有条件跳过；最终局部 Overlay/布局滑块改动后定向回归 18/18，通过包含语义开启的正式根节点工作流；最终静态分析零问题。原生脚本把 AXTree 日志拒绝也视为失败，避免仅依据 Dart 的 `All tests passed` 发行。
