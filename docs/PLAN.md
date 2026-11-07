# Aurora 实施计划

设计见 `DESIGN.md`。本文按目标列出要做的事，每个目标完成后在第 4 节记下提交号和验收结果。

## 1. 环境

| 工具 | 位置 | 说明 |
|---|---|---|
| Go 1.26.0 | `<go-sdk>` | 安装包 SHA-256 与 go.dev 一致。构建用 `GOTOOLCHAIN=local`、`CGO_ENABLED=0`，离线时加 `GOPROXY=off` |
| Flutter 3.47.9（Dart 3.13.7） | `<flutter-sdk>` | zip 的 SHA-256 `d8e2b597…3f68a9e` 与官方发布清单一致。访问 GitHub 和 pub.dev 需要在命令里设 `HTTPS_PROXY=http://127.0.0.1:<proxy-port>`（本机代理），不改全局配置 |
| Visual Studio 生成工具 2026 | 已装 | Flutter Windows 桌面构建用；`aurora_tls` 的构建钩子用其中的 cl.exe 与 lib.exe |
| NASM 3.02 | `<nasm-dir>` | `aurora_tls` 在 Windows x64 上汇编 BoringSSL 用。哈希与来源见 `app/packages/aurora_tls/third_party/README.md` |
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
- G2.8 proxy：按会话（D-47 至 D-50、D-53）。
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

初版交付：`release3\Aurora-3.0.0`（及同目录的 zip 和 `.sha256`），由 `tools\package.ps1 -Version 3.0.0` 生成，没有上传。agent `aurora3-agent-3.0.0-linux-amd64` 的 SHA-256 为 `9a44d006a08c5650cab3ba43d400107748a76e0a9964e4c6e94ce791a6408e5e`，用发布密钥 `87828dfb18459372` 签名；两次打包得到相同的 agent，构建可复现。验收：`app\tool\accept_release.ps1` 用这个文件夹自己的 agent（不设测试密钥）在界面里装进 WSL，连接、新建会话、卸载；改动 agent 一个字节后客户端拒绝安装；`ui_test`、`install-real`（64 项）、`terminal-survives`（16 项）、`install-e2e`（24 项）、`terminal-e2e`（15 项）和全部 Go、Dart 单元测试通过；v2 的单元、PID、二进制、配置、端口前后一致。`v2-release` 是 v2 的发布目录，v3 不写入。

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
| G2.6 monitor | 部分完成 | ff90f00 | `gpu.info` 未复制；操作未做行为测试 |
| G2.7 systemd | 部分完成 | ff90f00 | 单元名检查有测试；操作未做行为测试 |
| 内核 `internal/paths` | 完成 | 1154d1f、ff90f00 | 7 项测试通过 |
| 新仓库 aurora-next | 完成 | 227da69 | 克隆 aurora-v3，Go 代码移入 `agent/`，设计文档汇总为 `DESIGN.md` |
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
| NASM（构建工具，不进安装包） | 3.02 | BSD-2-Clause | 只在 Windows x64 上汇编 BoringSSL；位于 `<nasm-dir>` |
| github.com/hashicorp/yamux（Go） | 0.1.1 | MPL-2.0 | agent 端多路复用，沿用 v2 |
| github.com/apernet/hysteria/core/v2（Go） | 2.13.0 | MIT | 代理上游，沿用 v2 |
| github.com/apernet/quic-go（Go，间接） | — | MIT | p2p、hysteria |
| github.com/coder/websocket（Go） | 1.8.15 | ISC | 沿用 v2 |
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
- 终端输入偶发错字（2026-11-08 在新布局的测试里见到两次：命令前多一个字符、少一个字符），原因没找到。之后的 30 行连续输入没有复现。`app/tool/ui_test.ps1 -TypingLines N` 可以加大行数再测。
- 关于会话的 agent 测试 `TestKillEndsProcessesThatIgnoreHangup` 以前约 1/6 的概率失败：测试用回显的命令行来取进程号，命令行里的标记没拆开，回显就被当成了结果。已修，连跑 40 次通过。
- G3.1 坏版本回滚要等确认超时（30 秒）。可以在服务进入 failed 状态时提前结束等待，属于优化项。

## 6. TCP 性能基准

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
