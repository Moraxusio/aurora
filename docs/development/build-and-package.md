# 构建与打包

> 类型：开发规范 | 状态：生效 | 维护：构建维护者 | 更新：2026-11-16
> 适用：Windows x64 完整包及 Linux amd64 agent

## 工具链

| 工具 | 当前验证版本 | 用途 |
|---|---|---|
| Go | 1.26.0 | 两种 agent、签名和验签工具 |
| Flutter／Dart | 3.47.9／3.13.7 | Windows 客户端及内部包 |
| Visual Studio C++ | Build Tools 2026 | Windows runner、TLS 原生库 |
| NASM | 3.02 | BoringSSL 汇编 |
| PowerShell | Windows PowerShell 5.1 或 PowerShell 7 | 检查与打包脚本 |
| WSL Ubuntu | 24.04，Linux Go 1.26.0 | Linux 运行时测试与 race |

把 Go、Flutter、Dart、NASM 加入当前进程 `PATH`。NASM 也支持 `AURORA_NASM`。首次构建先在 `app` 运行 `flutter pub get`，准备 Go module cache；离线构建使用已有锁文件与缓存，不在打包期间自动更新依赖。

agent 环境使用 `GOTOOLCHAIN=local`、`GOPROXY=off`、`CGO_ENABLED=0`。Linux race 改为 `CGO_ENABLED=1`，需要 C 工具链。

## 源码检查

```powershell
# 仓库根目录
powershell -NoProfile -File tools/check.ps1
```

Linux 在 `agent` 目录补充 `go test ./...`、`go vet ./...`、`go build ./...`；`go test -race ./internal/ai ./internal/mcp ./internal/devtools ./internal/files ./internal/filetxn` 覆盖相关共享状态。

WSL 未安装 Go 时，可在 Windows 用 `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go test -c -o <输出> ./internal/ai`，再在 WSL 对应包目录实际执行测试二进制并保存日志。只交叉编译不等于运行测试；此方式也不等于 Linux race。本轮预算与快照的 race 使用 Windows Go＋MinGW 执行。

## 完整验收候选

```powershell
# 仓库根目录；AURORA_RELEASE_KEY 指向本机既有签名密钥
powershell -NoProfile -File tools/package-preview.ps1 `
  -Version 3.23.0 -Suffix ai-preview2 -Out <新输出目录> `
  -Key $env:AURORA_RELEASE_KEY
```

- `Version` 为 `MAJOR.MINOR.PATCH`，客户端和两种 agent 一致；候选后缀进入目录／ZIP 名及构建元数据。
- 当前签名协议接受数字版本和 `stable` channel，候选身份由外层名称与 `BUILD-INFO.json` 标明；本地生成不等于对外正式发布。
- 生成客户端、正式公钥可验证的两种 agent、升级策略、许可证、使用文档、源码哈希、构建信息、独立启动脚本、ZIP 和 SHA-256。
- `启动验收版.cmd` 使用包内 `review-data` 和独立实例名。该目录是配置隔离；选择的项目仍是实际项目文件。
- 同名候选已存在时拒绝覆盖；复验或重打使用新后缀。
- 构建前后检查源码、测试、工具和随包文档指纹；构建期间保持这些输入稳定。
- 随包文档保留原目录，根 `CHANGES.md` 链接到版本说明；`copy-package-docs.ps1` 在实际包目录再次检查链接。构建后的验收记录另行归档，包内文档保留构建时快照。

单独 `flutter build windows --release` 只生成客户端，缺少签名 agent 和完整交付文档，不能替代上述完整包。

## 普通完整包与 GUI-only 候选

`tools/package.ps1 -Version <版本> -Out <目录> -Key <密钥> -NotesFile docs/releases/<版本>.md` 生成完整普通包，同样检查构建前后源码指纹、HEAD 和工作树状态，并附带 `SOURCE-HASHES.json`、`BUILD-INFO.json`。正式发布先提交源码，从干净工作树构建；上传到远端是独立操作。

GitHub 发布使用带注释版本标签。先推送源码和标签，创建草稿并上传 ZIP、ZIP sidecar 和 `SHA256SUMS.txt`；逐项核对服务端大小与 SHA-256 后转为正式 latest，再从公开下载地址无认证下载复核。发布记录进入 `validation`，原始证据进入对应目录，包内文档保持构建时快照。

`tools/package-gui-preview.ps1` 仅适用于 backend 的协议和生产代码没有变化时，复用指定旧包并先验签。本轮 agent 已改动，使用完整候选脚本。旧 `package-harness-preview.ps1` 是完整候选的兼容入口。

## 交付校验

1. ZIP SHA-256 与 sidecar 一致，解压后每个文件与产物目录匹配。
2. 两种 agent 的签名、产品、版本、文件哈希通过；客户端的版本资源与 `BUILD-INFO.json` 一致。
3. 使用包内本地 agent 运行真实 TLS 冒烟；使用包内 Linux agent 执行 `version`；明确记录是否进行了远程安装。
4. 使用打包的 Release EXE 验证独立启动、窗口、托盘／单实例与退出。源码 Profile 性能不冒充 Release 全功能手工验收。
5. 输出中不含私钥、开发 helper、测试配置或个人 profile；许可证来自实际 vendored／锁定依赖。

实际包的无界面冒烟入口位于 `app/tool`：`local_agent_smoke.dart` 验证 TLS、监控、代理与终端；`ai_harness_smoke.dart` 使用本地模型夹具；`ide_agent_smoke.dart` 验证文本编码、批量事务冲突、开发任务及 AI 扩展配置。通过 `AURORA3_LOCAL_AGENT_DIR` 指向待验包的 `local-agent/windows-amd64`，使用新的临时目录；正常验签时清除测试用 `AURORA3_TRUST_KEY`。本地代理冒烟还需脚本指定的合成代理环境值。

检查记录使用 [验收模板](../templates/validation.md)，用户操作见 [验收指南](../guides/acceptance.md)。
