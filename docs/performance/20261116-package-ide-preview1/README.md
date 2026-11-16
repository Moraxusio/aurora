# 3.22.0-ide-preview1 打包验收证据

结论见 [完整包验收](../../validation/2026-11-16-package-ide-preview1.md)。本目录在构建完成后归档，ZIP 内文档保持构建时快照。

## 产物与最终检查

- `build.txt`：完整客户端、双 agent、清单和策略签名、许可证、文档及 ZIP 构建日志。
- `BUILD-INFO.json`、`SOURCE-HASHES.json`：从交付包复制的原始构建信息与 1596 文件指纹。
- `artifact-summary.json`、`artifact-files.json`、`artifact-check.txt`：ZIP／目录 134 个文件一致性、版本、源码复核和许可证检查。
- `go-signatures-linux-version.txt`：Go 正式公钥验签与包内 Linux agent 实际执行。
- `packaged-agent-smokes.txt`：Dart 双 agent／策略验签、IDE、Dart LSP／DAP initialize 与 AI harness 成功日志；组合命令末尾在本地冒烟构建钩子阶段达到外层时限。
- `local-agent-smoke-final.txt`：独立完成的 TLS、监控、代理、ConPTY、持久化与退出冒烟。
- `ide-smoke-analyze.txt`：新增 IDE 冒烟脚本的定向静态分析。
- `release-tray-final.txt`：修正验收工具后的 11 项托盘／单实例／确认退出检查。
- `release-launcher-msaa.txt`、`release-startup-ui.txt`：唯一测试实例的实际 CMD 启动、原生语义树、配置隔离与退出清理。
- `preflight-final.txt`、`final-checks.txt`、`post-build-source-check.json`：文档／脚本／差异检查、旧产物核对及构建后补充材料差异。

## 保留的失败与诊断

- `preflight.txt`：包文档检查首次发现单元素数组解包。
- `release-window.txt`：旧托盘脚本未处理退出确认，且清理重复 Kill。
- `release-window-final.txt`：首次尝试 UIA 读取确认按钮失败。
- `release-launcher-final.txt`：实际启动器同名实例唤回使测试找不到副本窗口。
- `release-launcher-isolated.txt`：唯一实例已启动，但 UIA 未暴露 Flutter 语义子节点。

这里的协议夹具、短时 Release 冒烟和前阶段源码 Profile 各有明确范围，不能合并为真实模型账号、远程部署或长时间压力验证。未归档测试 profile、引导令牌、项目状态或屏幕前台归属不确定的截图。
