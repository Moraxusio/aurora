# Aurora

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

## 状态

项目仍在积极开发中，接口和配置格式可能变化。尚未验证的部分（Android、macOS、iOS、arm64 等）记录在 `docs/PLAN.md`。

## 许可证

本仓库尚未选定许可证。第三方组件及其许可见发布包中的 `LICENSES.txt`（由 `tools/licenses.ps1` 生成）。
