# Aurora 实施计划

设计见 `DESIGN.md`。本文按目标列出要做的事，每个目标完成后在第 4 节记下提交号和验收结果。

## 1. 环境

| 工具 | 位置 | 说明 |
|---|---|---|
| Go 1.26.0 | `<go-sdk>` | 安装包 SHA-256 与 go.dev 一致。构建用 `GOTOOLCHAIN=local`、`CGO_ENABLED=0`，离线时加 `GOPROXY=off` |
| Flutter 3.47.9（Dart 3.13.7） | `<flutter-sdk>` | zip 的 SHA-256 `d8e2b597…3f68a9e` 与官方发布清单一致。访问 GitHub 和 pub.dev 需要在命令里设 `HTTPS_PROXY=http://127.0.0.1:<proxy-port>`（本机代理），不改全局配置 |
| Visual Studio 生成工具 2026 | 已装 | Flutter Windows 桌面构建用 |
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
| G5.4 TCP 性能 | 部分完成 | 见 git log | 见第 6 节。客户端自身的优化已做；吞吐受 Dart SDK 的 TLS 实现限制，需要你决定是否进一步处理 |

## 5. 第三方依赖（DESIGN 5.9：只用 MIT、BSD、Apache-2.0）

| 包 | 版本 | 许可证 | 用途 |
|---|---|---|---|
| crypto（Dart 团队） | 3.0.8 | BSD-3-Clause | 证书指纹 SHA-256 |
| typed_data（crypto 的依赖） | 1.4.0 | BSD-3-Clause | — |
| github.com/hashicorp/yamux（Go） | 0.1.1 | MPL-2.0 | agent 端多路复用，沿用 v2 |
| github.com/apernet/hysteria/core/v2（Go） | 2.13.0 | MIT | 代理上游，沿用 v2 |
| github.com/apernet/quic-go（Go，间接） | — | MIT | p2p、hysteria |
| github.com/coder/websocket（Go） | 1.8.15 | ISC | 沿用 v2 |
| github.com/creack/pty（Go） | 1.1.24 | MIT | 终端，沿用 v2 |
| golang.org/x/net、x/sys、x/crypto（Go） | 见 go.mod | BSD-3-Clause | — |

开发依赖（`test`、`lints`、`flutter_lints`）不进入发布产物。hashicorp/yamux 是 MPL-2.0，沿用自 v2，属于文件级弱 copyleft：只要求修改过的该库文件本身开源，我们没有修改它。ISC 与 MIT 等价。Dart 端的 yamux 是按协议自行编写的，没有复制 hashicorp/yamux 的代码。

## 5.1 已知待办

- tmux 构建脚本里的终端信息目录是 v2 的 `/var/lib/aurora/terminfo`（`agent/tools/tmux/build-in-container.sh`）。v3 要改为 `/var/lib/aurora3/terminfo` 并重新构建 tmux（需要 Linux 主机上的 Docker）。在此之前，内置 tmux 也能通过 `TERMINFO_DIRS` 环境变量找到 v3 的目录，所以不阻塞 G2.1。
- `update/local.go` 的 Windows 路径是 v2 桌面端的 `%LOCALAPPDATA%\Aurora`，没有任何代码调用它。Flutter 客户端有自己的更新方式，这部分在 G5 中删除或改写。
- `update.ProductAgent` 的值是 `aurora-agent`，发布清单里的产品名应改为 `aurora3-agent`，在 G7 做发布清单时一起改。

## 6. TCP 性能基准（2026-11-06）

同一个 `aurora3-testpeer`（真实的 TLS、Hello、hashicorp/yamux 与分发），分别用 Go 客户端（`agent/cmd/aurora3-bench`，即 v2 的客户端协议栈）和 Dart 客户端（`app/packages/aurora_wire/bin/bench.dart`）跑同样的项目。本机回环，8 核。复现：`agent/tools/bench.ps1`（Windows）、`agent/tools/bench-linux.sh`（WSL）。

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

**对实际使用的意义**：37–69 MB/s 约等于 300–550 Mbps。经公网或校园网连接服务器时，链路通常低于这个值，TLS 不会成为瓶颈；千兆局域网下的大文件传输会受它限制。64 路并发调用每秒约 3000–6000 次，界面操作用不到这个量。
