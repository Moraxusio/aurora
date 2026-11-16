# 开发流程

> 类型：开发规范 | 状态：生效 | 维护：项目维护者 | 更新：2026-11-16
> 适用：agent、客户端、内部包、脚本和文档

## 开始修改

从 [架构](../architecture/overview.md) 找到状态所有者与服务边界，再阅读目录内的 `AGENTS.md`。保留当前工作树和已有验收证据；不要用重新生成控制器、清空配置或重新建立连接掩盖生命周期问题。

## 实现约定

- Go 使用既有包组织和 `gofmt`；Dart 使用项目 formatter 和 analyzer。依赖版本由 `go.mod/go.sum`、`pubspec.lock` 固定。
- 网络流、后台工作和开发子进程可取消；迟到结果核对连接身份／请求代次／文档版本。
- 文件修改由共享事务协调，预览不能绕过提交时的版本复核；网络接收与用户审批不能持提交锁。
- 文档正文、撤销和保存点属于 Workspace 文档模型；GUI 只持有视图状态。遵循 [统一 GUI](gui.md)，不用功能页私建另一套按钮／浮层体系。
- AI 请求保留 OpenCode 兼容协议及 `User-Agent`、`originator`、`x-opencode-client`；协议修改覆盖三种上游适配路径。
- vendored 第三方补丁在库内 `AURORA.md` 说明，许可证取实际随包版本；不以整个第三方库格式重写制造无关差异。

## 验证

```powershell
# 仓库根目录，先配置构建工具 PATH
powershell -NoProfile -File tools/check.ps1

# 含 Windows 原生 Profile：输出目录必须是新的
powershell -NoProfile -File tools/check.ps1 -Native -NativeOut <新目录>
```

按改动选择有意义的回归：文件事务覆盖冲突／故障恢复；异步逻辑覆盖取消与迟到响应；GUI 覆盖状态保留、键盘、窄宽与必要的原生路径。发现回归时保留修改前失败和修改后通过的证据。

`tools/check.ps1` 运行文档检查、Go test／vet／build、GUI contract、Flutter analyze／test 及内部 Dart 包测试。Linux-only 行为和 race 使用 Linux 工具链补充执行。真实 Dart LSP／DAP 可通过 `AURORA_TEST_DART` 指定 SDK。

analyzer 的 error／warning 必须解决；info 单独计数。条件跳过写明夹具和环境原因，不记为成功。一次通过后仅因新增改动、失败或尚未解决的疑点追加测试。

## 交付

功能修改同步更新对应指南；检查结果按 [文档规范](../standards/documentation.md) 进入验收记录。构建候选见 [构建与打包](build-and-package.md)，包的静态校验、真实 agent 冒烟与 Release 窗口检查分别记录。
