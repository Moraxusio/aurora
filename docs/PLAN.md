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
