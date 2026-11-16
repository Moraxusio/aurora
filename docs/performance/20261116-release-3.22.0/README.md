# 3.22.0 正式发布证据

结论见 [正式发布记录](../../validation/2026-11-16-release-3.22.0.md)。此目录在发布后补记，发布标签固定指向实际构建提交。

- `artifact-summary.json`、`artifact-files.json`：干净提交、1621 文件指纹、157 个 ZIP 文件一致性、版本、许可证和双 agent VCS 信息。
- `BUILD-INFO.json`、`SOURCE-HASHES.json`：正式包内原始构建记录副本。
- `acceptance.json`：全部正式包检查的汇总与范围。
- `headless-passed.json`：Dart 验签、IDE、AI harness、本地代理／ConPTY 冒烟全部成功后生成。
- `native-passed.json`：实际 Release 的 11 项检查及测试进程退出结果。
- `go-signatures-final.txt`：显式捕获的 Go 正式公钥验签和 Linux `version` 输出。
- `publication.json`：GitHub 正式 Latest、源码／标签、三项资产服务端及无认证下载校验。
- `SHA256SUMS.txt`：实际发布的校验资产副本。
- `protected-artifacts.json`：三个既有 ZIP 的保留检查。
- `build.txt`、`artifact-check.txt`、`headless-acceptance.txt`、`release-tray.txt`：脚本运行记录。PowerShell transcript 未完整捕获部分直接输出的子进程 stdout，结果同时由上述结构化完成记录支持。
- `publication-output.txt`、`publication-final.txt`：草稿阶段计数错误及首次旧地址下载 404 的原始记录；最终公开下载结果见 `publication.json`。

日志不包含 GitHub 令牌、签名私钥或测试 profile。真实模型账号及长期压力没有通过结论。
