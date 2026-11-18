# 3.24.0 正式发布证据

结论见 [正式发布记录](../../validation/2026-11-18-release-3.24.0.md)。此目录在发布后补记，发布标签 `v3.24.0` 固定指向实际构建提交 `2710caa4dba39f98e410cee908bd057da487d888`。

- `artifact-summary.json`、`artifact-files.json`：干净提交、2,101 个源码／文档输入指纹、625 个 ZIP 文件一致性、版本、许可证和双 agent VCS 信息。
- `BUILD-INFO.json`、`SOURCE-HASHES.json`：正式包内原始构建记录副本。
- `SHA256SUMS.txt`：实际发布的校验资产副本。
- `build.log`、`package-docs.log`：正式构建、Go 验签及包内文档检查日志。
- `signatures.log`、`linux-version.log`：Dart 正式公钥验签与 WSL Linux `version` 实际执行输出。
- `ide-smoke.log`、`ai-smoke.log`、`local-smoke2.log`：包内 Windows 本地 agent 的真实 TLS IDE／LSP／DAP、AI 夹具及本地监控／代理／ConPTY 冒烟输出。
- `release-tray.log`：解压后的 Release 客户端 11 项窗口、托盘、单实例与本地任务确认退出检查。
- `publication.json`：GitHub 正式 Latest、源码／标签、三项资产服务端摘要及公开无认证下载校验。

日志不包含 GitHub 令牌、签名私钥或真实用户配置。真实模型账号及长期压力没有通过结论。
