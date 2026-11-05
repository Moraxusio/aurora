# Aurora

Aurora 是一个远程服务器管理工具，目标是比 SSH 更强的远程管理能力。

- 服务器上只装一个 `aurora3-agent`（Go），终端、文件、git、代理、监控等都是它上面可以单独启停的服务。
- 客户端用 Flutter 编写，面向 Windows、Linux、macOS、Android、iOS。
- 客户端通过 SSH 安装 agent，之后用 TLS 直连，日常使用不再依赖 SSH。
- VPS 是可选项，只提供代理网络和打洞，不承担凭据。

## 目录

| 目录 | 内容 |
|---|---|
| `agent/` | Go：agent、内核与服务、tmux 构建工具。构建：`agent\build.ps1` |
| `app/` | Flutter 客户端 |
| `docs/DESIGN.md` | 设计（全部决定） |
| `docs/PLAN.md` | 实施计划与进度 |
| `docs/history/` | 旧的讨论记录，只作追溯 |

## 与 v2 的关系

v2（`aurora-v2`，标签 `archive/v2-final`）已封存，只读参考。v3 使用独立的名字、路径和端口，可以与 v2 装在同一台机器上，测试和部署都不影响 v2。详见 `docs/DESIGN.md` 第 4 节。
