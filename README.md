# Aurora

核心理念：**布局服务于任务，移动位置不丢状态**。3.21.4 完善自有 AI harness 的图片／PDF 读取、工具执行和中断恢复，提供全局／逐模型能力及自定义思考强度，并统一四页设置和会话交互。文档、右侧 AI 和底部终端继续保留各自状态。操作见 [标签页工作台](docs/TABS.md)。

**当前优先维护 Windows。** [3.21.4 Windows x64](https://github.com/Moraxusio/aurora/releases/tag/v3.21.4)，Android 构建/发行暂缓；安卓用户可继续使用既有 3.16.0。

**3.21.4：AI harness 与简洁交互。** `read` 可向模型传递工作区图片／PDF；新增多文件 `apply_patch`、结构化 `question` 和逐工具持久化检查点。工具能力支持全局默认与逐模型覆盖，思考强度支持 `high`、`max` 等自定义值和协议映射。设置收敛为连接、模型、工具与权限、对话四页；会话选择先选再应用，PDF 附件使用实际阅读器。保活浮层随面板隐藏，修复原生无障碍树残留。设计与验证见 [AI_HARNESS.md](docs/AI_HARNESS.md)。

正式包包含 Windows 客户端、本地 agent 和 Linux amd64 远程 agent，统一版本 3.21.4。新版工具链和显式能力设置需要本轮 agent；本地随客户端提供，远程由用户确认升级。OpenCode 兼容协议、请求标识及原有加密凭据继续保留。

3.20.0 的工作台基础、PDF／AI 导航与统一浮层说明仍见 [UI_SYSTEM.md](docs/UI_SYSTEM.md)、[PDF 阅读与 AI 工作导航](docs/READER_AI.md)。

3.19.0 的文件树、本地监控与代理说明见 [Windows 本地 agent](docs/LOCAL_AGENT.md) 和 [GPU 监控](docs/GPU_MONITOR.md)。远程完整 GPU 详情／AI 出口选择需要 agent 3.19.0 或以上；3.20.0 随包两类 agent 同版本，原 API Key／OAuth 与旧代理设置继续保留。

3.18.1 的修复原理与回归范围见 [GUI 交互检查](docs/GUI_AUDIT.md)。3.18.0 的设计见 [Windows 工作台](docs/WINDOWS_WORKBENCH.md) 和 [侧栏跟手与界面减法](docs/WINDOWS_SIMPLIFICATION.md)。

当前 GUI 基础层重构与原生验收记录见 [GUI_FOUNDATION.md](docs/GUI_FOUNDATION.md)：共享保活视口、监控独立快照、按需详情与帧预算。

菜单、弹窗、浮层及动画的统一接入规则见 [UI_SYSTEM.md](docs/UI_SYSTEM.md)。PDF 阅读与 AI 工作导航见 [READER_AI.md](docs/READER_AI.md)。

3.17.0 的文档网格与阅读锚点设计见 [IDE 重设计](docs/IDE_REDESIGN.md)，3.16.0 的历史记录见 [工作台验收](docs/WORKBENCH_REVIEW.md)。

3.14.0 增加 Windows 本地模式：直接打开本机文件夹，使用 PowerShell、Git 和 AI；本地 agent 随客户端运行，与 Linux 远程 agent 分开。设计、构建和限制见 [Windows 本地 agent](docs/LOCAL_AGENT.md)。

Aurora is a remote server management tool that aims to go beyond what plain SSH offers.
Aurora 是一个远程服务器管理工具，目标是比 SSH 更强的远程管理能力。

- 服务器上只装一个 `aurora3-agent`（Go）。终端、文件、git、代理、监控等都是它上面可以单独启停的服务。
- 客户端用 Flutter 编写，目标平台为 Windows、Linux、macOS、Android、iOS（不做 Web）。当前经过验证的是 Windows 客户端 + Linux amd64 agent。
- 客户端通过 SSH 安装 agent，之后用 TLS 直连，日常使用不再依赖 SSH。
- 客户端内置项目工作区、分层文件树、多标签终端与编辑器；Windows 版支持托盘常驻和单实例（不是后台服务）。
- 发布包里的 agent 经过签名，客户端安装前验证签名，签名或哈希不符则拒绝安装。

## 仓库结构

| 目录 | 内容 |
|---|---|
| `agent/` | Go：agent、内核与服务、tmux 构建工具 |
| `app/` | Flutter 客户端及其内部包（`aurora_profile`、`aurora_install`、`aurora_tls` 等） |
| `tools/` | 打包、许可证汇总、图标生成脚本 |
| `docs/DESIGN.md` | 设计与全部决定 |
| `docs/PLAN.md` | 实施计划与进度 |
| `docs/history/` | 早期讨论记录，仅作追溯 |

## 构建

需要：Go 1.26、Flutter 稳定版（见 `docs/PLAN.md` 的工具链表）、Windows 上还需要 Visual Studio C++ 工具链和 NASM 3.02（`PATH` 中，或设置 `AURORA_NASM`）。

```powershell
# agent
powershell -File agent\build.ps1

# 客户端检查与测试
cd app
flutter analyze
flutter test

# 打包 Windows 发布文件夹和 ZIP（输出到 dist\，需要你自己的发布签名密钥）
powershell -File tools\package.ps1 -Version X.Y.Z -Key path\to\release.key
```

发布签名密钥不在仓库中，也不要提交。`*.key` 已被 `.gitignore` 忽略。

## 安全模型

- 客户端与 agent 之间使用 TLS，agent 证书指纹在首次安装时由客户端经 SSH 取得并固定。
- 本地配置（服务器、凭据）使用系统机制加密保存（Windows 为 DPAPI）。
- 详细威胁模型和决定见 `docs/DESIGN.md`。

## AI 工作台

内置可独立启停的 `ai` 服务，支持 API Key 网关与 OpenAI / ChatGPT 设备码订阅登录；工作台区分实际请求的提供商/模型、下一次选择、上下文估算与累计用量。3.13.0 增加本机授权/出口切换、图片及文件粘贴/选择、目录下拉浏览和对话阅读优化；原始文件附件需要客户端及 agent 3.13.0 以上。使用方法、凭据边界和未验证范围见 [AI 使用说明](docs/AI.md)。

## 状态

项目仍在积极开发中，接口和配置格式可能变化。尚未验证的部分（Android、macOS、iOS、arm64 等）记录在 `docs/PLAN.md`。

## 许可证

本项目使用 [Apache License 2.0](LICENSE)，版权声明见 [NOTICE](NOTICE)。第三方组件及其许可见发布包中的 `LICENSES.txt`（由 `tools/licenses.ps1` 生成）。
