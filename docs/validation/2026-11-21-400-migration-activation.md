# 4.0 迁移与版本选择验收

> 类型：验收记录 | 状态：已记录 | 维护：构建维护者 | 更新：2026-11-21
> 适用：未发布源码；Windows x64 与 WSL Ubuntu 24.04 的隔离夹具

从基线 `c90db8f78a775012afefdfff72dfde8b1b6fee2e` 的未提交工作树验证。版本选择测试使用内存生成的临时签名密钥和测试 ELF，不是另一个以同版本发布的正式二进制。

| 验证 | 结果 |
|---|---|
| 历史快照与工具输出 | 源影子 Git 只读，缺失对象时不发布部分克隆。加密副本的旧会话可查看 Unicode 文件的原差异、生成原来的回退计划；工具输出指向克隆中的加密记录。 |
| Windows 客户端配置 | 验证并逐字节复制 DPAPI Profile、文档恢复、开发记录，不用 JSON 重写 Profile。错放的恢复记录拒绝；不覆盖目标。隔离单 EXE 打开克隆时不会自动连接。 |
| 版本选择 | 用签名 Linux 测试 ELF 和独立状态验证 TLS、ID、token 与版本后才提交。调用 `SelectOnBoot` 重新验证被选版本和撤回策略，拒绝启动已撤回版本。 |
| 进程退出和写入结果不明 | 子进程在试运行中退出，重开仍选择原确认版本；持久收据保留并标为放弃。模拟提交前和提交后报错时，查询发现正确状态，不重放操作。 |

Windows Go 全量测试及 `go vet ./...` 通过；WSL 中 `aurora3-agent`、`activation`、`ai`、`install` 和 `statecrypt` 全量包测试通过，含已签名的 3.26.0 基线克隆。Flutter **690 项通过、20 项跳过**，静态分析及 GUI 合约通过。3.26.0 ZIP、既有 4.0 Alpha EXE 与 ELF 的 SHA-256 未变。

外层 Authenticode 不再列作发布门槛；仍保留 Aurora 内嵌签名和产物校验。没有替换生产 Profile、systemd 服务或任何已签名版本。**没有通过生产 systemd、Windows 生产程序选择、真实磁盘写满／掉电，以及迁移后新写入的跨格式回退。** [隔离验收操作](../development/protected-state-preview.md) · [发布门槛](../development/roadmap-4-0.md)
