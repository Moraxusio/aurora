# AI 配置与快照改造证据

结论见 [本轮验收](../../validation/2026-11-16-ai-control.md)。日志来自本轮实际检查；协议夹具不代替真实模型账号验证。构建信息及源码指纹随完整候选提供。

- `flutter-full.txt`：全量客户端回归，604 通过、20 跳过。
- `analyze.txt`、`ui-contract.txt`：静态分析与统一 GUI 入口检查。
- `aurora_profile.txt`、`aurora_wire.txt`、`aurora_install.txt`、`aurora_sub.txt`：内部包检查。
- `settings-overview-390-dark.png`、`settings-models-1100-light.png`：本轮设置界面截图，来自 Widget 渲染。
- `go-windows.txt`：Windows 全量 Go test／vet／build。
- `go-linux-ai.txt`：WSL 中实际执行的 Linux AI 包 87 项回归。
- `go-race.txt`：预算、运行器、Git 快照与实际对象存储上限的 Windows race。
- `smoke-analyze.txt`：包内 IDE/TLS 冒烟脚本分析。
- `native-profile.log`、`native-profile.json`、`native-profile.png`、`native-source-hashes.json`：本轮 Windows 原生 Profile 交互／无障碍验收及其客户端输入指纹。
- `build.txt`、`build-info.json`、`source-hashes.json`：完整候选构建、输入指纹和双 agent 版本。
- `artifact-summary.json`、`artifact-files.json`、`artifact.txt`：ZIP、解压逐文件、源码指纹、版本与许可证复核。
- `signatures.txt`、`linux-version.txt`：正式公钥验签与 Linux agent 实际执行。
- `ide-smoke.txt`、`ai-smoke.txt`：包内 Windows agent 的真实 TLS／本地协议夹具冒烟。
- `release-native.txt`、`release-startup-ui.txt`：最终 Release 启动、隔离配置、托盘恢复、退出与 agent 清理；使用窗口句柄定向操作。
- `release-native-first.txt`、`release-native-keyboard-attempt.txt`：额外 Release 命令面板自动化未完成的原始日志，不计为通过。
- `verify-launcher.ps1`、`native-accessibility.ps1`：最终 Release 原生校验脚本。
