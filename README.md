# Aurora

Windows 本地与 Linux 远程开发工作台：文件编辑、终端、Git、监控、语言服务、任务／调试和 AI 协作。布局服务于任务，移动、隐藏和缩放面板保留工作状态。

当前正式版：**[3.22.0，Windows x64](https://github.com/Moraxusio/aurora/releases/tag/v3.22.0)**。完整包包含同版本 Windows 本地 agent 和 Linux amd64 agent；完整解压后运行 **`aurora.exe`**。操作见 [开始使用](docs/guides/getting-started.md)，正式版成果见 [3.22.0 版本说明](docs/releases/3.22.0.md)。

正式版已完成双 agent 验签、ZIP 一致性、真实 agent 冒烟、Release 启动／退出，以及三项 GitHub 资产的无认证下载复核；详见 [正式发布记录](docs/validation/2026-11-16-release-3.22.0.md)。包内附带构建信息、源码指纹和许可证。

本地候选：[3.24.0-workbench-preview1](docs/releases/3.24.0-workbench-preview1.md)，重点为非 AI 功能可靠性和工作台 GUI 重构。候选完整解压后使用 `启动验收版.cmd`，按 [候选验收指南](docs/guides/acceptance.md) 检查。

## 文档

**[文档入口](docs/README.md)** 是当前文档的唯一导航入口。

- 使用：[开始使用](docs/guides/getting-started.md) · [开发工具](docs/guides/development-tools.md) · [AI 协作](docs/guides/ai.md)
- 开发：[贡献流程](docs/development/contributing.md) · [构建与打包](docs/development/build-and-package.md) · [统一 GUI](docs/development/gui.md)
- 设计：[架构与状态所有权](docs/architecture/overview.md) · [能力与边界](docs/reference/compatibility.md)
- 维护：[文档规范](docs/standards/documentation.md) · [历史档案](docs/archive/README.md)

所有新 GUI 从 `package:aurora/ui/aurora_ui.dart` 接入。设置 → 外观 → 统一组件展示提供生产组件目录。

## 仓库

| 目录 | 职责 |
|---|---|
| `agent/` | Go 服务、开发进程桥、文件事务、AI 与 Linux 安装生命周期 |
| `app/` | Flutter 客户端、工作区模型、统一 GUI 与内部 Dart 包 |
| `tools/` | 源码检查、文档检查、打包、许可证与验收工具 |
| `docs/` | 当前指南与规范、版本记录、验收证据及只读历史 |

## 开发入口

工具链：Go 1.26.0、Flutter 3.47.9／Dart 3.13.7、Visual Studio C++ 工具链、NASM 3.02。

```powershell
# 仓库根目录
powershell -NoProfile -File tools/check-docs.ps1
powershell -NoProfile -File tools/check.ps1

# 完整包；签名密钥由本机环境提供
powershell -NoProfile -File tools/package.ps1 `
  -Version 3.22.0 -Out <输出目录> -Key <发布密钥路径> `
  -NotesFile docs/releases/3.22.0.md
```

最新候选的检查结果与原始证据见 [工作台重构验收](docs/validation/2026-11-16-workbench-redesign.md)；正式版基础记录见 [源码验收记录](docs/validation/2026-11-16-implementation.md)。条件跳过及真实账号／长期压力未验项目分别保留在对应记录中。

## 许可证

[Apache License 2.0](LICENSE)，版权声明见 [NOTICE](NOTICE)。分发包附带 `LICENSES.txt`；OpenCode 兼容协议、请求标识及 MIT 署名保留。Windows 客户端与 Linux amd64 agent 是当前交付平台，其它平台状态见能力边界。
