# 3.22.0-ide-preview1 完整包验收

> 类型：验收记录 | 状态：已记录 | 维护：构建维护者 | 更新：2026-11-16
> 适用：Aurora 3.22.0-ide-preview1 Windows x64 本地候选及包内双 agent

## 产物

| 项目 | 结果 |
|---|---|
| ZIP | `C:\dev\VPS\preview3\Aurora-3.22.0-ide-preview1.zip` |
| 解压目录 | `C:\dev\VPS\preview3\Aurora-3.22.0-ide-preview1` |
| 大小 | **36,049,252 bytes（约 34.38 MiB）** |
| SHA-256 | `556aaa40de28d07ae9de5949e9cacc1a8e039348edca1f71f15077c754edf42a` |
| Windows 客户端 | Release，文件版本 **3.22.0+32200** |
| Windows 本地 agent／Linux amd64 agent | 均为 **3.22.0**，重新编译 |
| 正式发布公钥 ID | `87828dfb18459372` |
| 启动入口 | `启动验收版.cmd`，配置位于包内 `review-data` |

ZIP 同级 `.sha256` 与 ZIP 实际哈希一致。原始构建、静态检查、协议冒烟与窗口验收见 [证据索引](../performance/20261116-package-ide-preview1/README.md)。用户操作见 [验收指南](../guides/acceptance.md)。

## 构建输入与环境

仓库 `C:\build\aurora`，基线 HEAD `f2873316253e80b9c217dea88eb8048c8dddb10f`，**包含未提交修改**。`tools/package-preview.ps1` 对 **1596 个文件**在构建前后比对 SHA-256；产物检查阶段再次逐文件核对一致。准确构建输入为包内 `SOURCE-HASHES.json`，工作树状态、删除路径与关键二进制指纹为 `BUILD-INFO.json`。

工具链：Flutter 3.47.9、Dart 3.13.7、Go 1.26.0、MSVC 19.50.35730、NASM 3.02。Go 使用 `GOTOOLCHAIN=local`、`GOPROXY=off`、`CGO_ENABLED=0`；Flutter 使用 `--no-pub --release --target=lib/main.dart --build-name=3.22.0 --build-number=32200`，Windows 构建耗时 153.6 秒。

候选后缀属于包名与构建记录；agent 清单按现有协议使用数字版本及 `stable` channel。agent 清单签名不代表客户端 EXE 带有 Authenticode 签名。

| 内容 | SHA-256 |
|---|---|
| 客户端 AOT `data/app.so` | `351f24217eac092d7a6c6e492047a76f1572a59c2fc2ece0bab2212d408a7a47` |
| Linux agent | `c076437c905c04962894025cfa53e1ca513341f01970250a55587576e926ab02` |
| Windows 本地 agent | `d6768116357237dc8763b431610e70e4c3b6676a0278f6d57bcd42d1247427f2` |

## 实测结果

| 检查 | 结果与覆盖 |
|---|---|
| ZIP 与目录一致性 | **134 个文件**逐项大小与 SHA-256 相同 |
| 签名 | Go 内置公钥与 Dart 实际客户端分别验证双 agent 的签名、产品、版本、大小和哈希；Dart 验证升级策略及 3.21.4 → 3.22.0 升级资格 |
| Linux 运行 | 包内 Linux agent 在 Ubuntu-24.04 WSL 执行 `version`，返回 `3.22.0` |
| 文档 | 构建时 **20 份当前文档、44 份源码 Markdown**通过；实际解压包 **43 份 Markdown**通过布局、元信息、索引和本地链接检查 |
| 许可证 | 收集 Windows／Linux 两种 agent 的依赖；实际 vendored `re_editor`、`xterm` 和 OpenCode 原许可证文本一致，包含 PDFium、BoringSSL、Go 模块和 tmux 等声明 |
| IDE agent 冒烟 | 正式签名启动和能力上报、UTF-16 BOM／UTF-8 双文件创建与读取、未保存正文替换预览、外部修改导致整批冲突拒绝且无部分写入、重新取版本后整批更新通过 |
| 开发工具 | 配置持久化与过期版本拒绝；真实 Dart 任务输出、问题行列／级别、退出码；包内 agent 启动真实 Dart LSP／DAP 并完成 initialize |
| AI 扩展 | 项目指令、技能发现、预算配置保存／重读及过期配置拒绝通过 |
| AI harness | 本地模型夹具完成图片／PDF 读取与上游传递、`apply_patch`、结构化 `question`、会话重启及不可变附件保持；夹具检查兼容 UA 和 `x-opencode-client` |
| 本地 agent | TLS、原生监控、模型目录、系统／agent／直连三种代理出口、ConPTY、服务开关和节点重启持久化、退出后代理监听关闭通过 |
| Release 托盘 | **11 项通过**：窗口显示、关闭隐藏、保持进程、第二实例唤回／退出、结束本地任务确认与完整退出 |
| 实际 CMD 启动器 | 包内配置目录和加密 `profile.bin`、原生 MSAA 读到真实工作台及 agent 3.22.0、重复启动唤回、确认退出和子 agent 回收通过 |

启动器在独立解压副本中运行。为避开已有同名候选实例，测试仅将该副本 CMD 内的 `AURORA3_INSTANCE_SCOPE` 换成唯一测试名；客户端和 agent 二进制保持 ZIP 字节。原始 ZIP 与交付目录中的启动器未修改。

## 验收工具修正与失败记录

1. 随包文档检查发现 PowerShell 对单元素数组解包，拼成 `README.mdCHANGES.md`；已修复数组构造，构建前重新通过。
2. 首个协议冒烟组合命令在 240 秒总时限内完成了验签、IDE 与 AI harness，但在后续 Dart 原生构建钩子期间超时。本地 agent 冒烟另用新目录独立完成，未把超时当作成功。
3. 旧托盘脚本假定退出无需确认，实际客户端已自动连接本地 agent，显示“结束本地任务并退出”。补充确认操作时发现 UIA 只返回 `FLUTTERVIEW`；改用 Flutter 实际 MSAA 语义树后，点击真实确认按钮并完整退出通过。清理逻辑也取消了对同一进程的重复 Kill。
4. 启动器首次复验与已有候选实例名相同，触发了既有单实例唤回；后续使用上述唯一测试实例完成验证。

失败日志与最终日志均保留，见证据索引。

## 构建后的补充材料

包内文档是**构建时快照**。本记录、证据目录、文档导航补充，以及 `app/tool/tray_test.ps1` 和新 `native_accessibility.ps1` 的验收工具修正发生在构建之后；没有更改包内运行代码或重写原始构建指纹。最终检查将这些文档／工具差异列入 `post-build-source-check.json`。

前阶段 [源码验收](2026-11-16-implementation.md) 的 602 项客户端测试、Windows／Linux Go 检查、race 与 541 帧原生 Profile，证明其记录的源码与场景；本记录新增的是打包 Release 与实际签名 agent 检查。LSP／DAP 包冒烟仅验证初始化，完整调试场景沿用源码验收证据。

## 文档规范落地

- 17 份旧根目录专题和 3 份早期讨论进入 `docs/archive`，保留归档提示、D-* 编号与历史证据。
- 当前文档按指南、架构、开发、参考、规范、决定、版本和验收组织，`docs/README.md` 为导航。
- [文档规范](../standards/documentation.md)、指南／验收／决定模板及 ADR 0001 已落地；检查接入源码检查和打包流程。
- 版本说明保留原目录，包根 `CHANGES.md` 链接到对应文档；许可证相对链接在实际包目录验证。

## 复验入口与边界

```powershell
# app 目录，PATH 中准备 Dart、NASM、C++ 工具链；各临时目录必须是新的
$env:AURORA3_LOCAL_AGENT_DIR = '<解压目录>\local-agent\windows-amd64'
Remove-Item Env:AURORA3_TRUST_KEY -ErrorAction SilentlyContinue
dart run tool/ide_agent_smoke.dart <新IDE临时目录> 3.22.0
dart run tool/ai_harness_smoke.dart <新AI临时目录>

$env:HTTP_PROXY = 'http://127.0.0.1:18101'
$env:HTTPS_PROXY = 'http://127.0.0.1:18102'
$env:ALL_PROXY = 'socks5://127.0.0.1:18103'
$env:NO_PROXY = 'system.fixture'
dart run tool/local_agent_smoke.dart <新本地临时目录>

# 新终端、仓库根目录：测试直接使用 EXE 旁的 agent
powershell -NoProfile -File app/tool/tray_test.ps1 -Exe <解压目录>\aurora.exe
```

真实模型设备授权、订阅资格、识图及固定代码任务成功率、长期弱网／慢盘与 24 小时泄漏测试尚未完成。此次仅生成本地候选，未进行远程安装或服务器部署。其它限制见 [能力边界](../reference/compatibility.md)。

旧正式包与旧 harness 候选的 SHA-256 已再次核对，分别保持 `087348a08f4f0af051a89b81dde7d5eb86a2136045d6199ebdb5c8ec2aa95ae1` 和 `78ca0c41012e5647cfd5080a47ba8b9f0f74a979f3c99eeaf6f747af2a19fb7d`。
