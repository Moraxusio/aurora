# 3.26.0 事务替换与回退审阅验收

> 类型：验收记录 | 状态：已记录 | 维护：构建维护者 | 更新：2026-11-21
> 适用：3.26.0-safety-preview1，Windows x64、WSL Ubuntu 24.04（Linux amd64）

## 构建与签名

`tools/package-preview.ps1 -Version 3.26.0 -Suffix safety-preview1` 基于 `c90db8f78a775012afefdfff72dfde8b1b6fee2e` 和未提交工作树构建。Go 1.26.0、Flutter 3.47.9、Dart 3.13.7。包内 `BUILD-INFO.json` 和 `SOURCE-HASHES.json` 记录了 2,149 个输入，打包后与工作树逐项核对，随后只补文档和签名 agent 哈希基线。签名的 Windows 本地 agent 与 Linux agent 均为 `3.26.0`，Windows Release 文件版本为 `3.26.0+32600`。

首轮打包与 Flutter 全量测试同时写 Windows 原生资产目录，导致 PDFium 占用及测试 TLS DLL 暂时缺失，未生成 ZIP；串行复跑成功，两份签名 agent 二进制哈希没有变化。最终 ZIP 为 55,203,706 字节，662 个文件与候选目录逐项哈希匹配。SHA-256 为 `2e23baf6059b430b73081bbb82a5bd3c8a420a98744abbed54b03557abfa6992`。

## 复验

- Flutter 全量 688 通过、20 跳过；静态分析无错误或警告，仍有 lint 信息；GUI、文档、agent 版本身份检查通过。
- Windows Go 非短模式全量 `go test -p 2 ./... -count=1 -timeout=8m` 通过，包含 20,000 项以上快照用例；`go vet ./...`、`go build ./...` 通过。Linux WSL 定向验证事务恢复、普通复制、替换收据、上传条件、实时撤权及回退选择。
- Windows 原生下载夹具先在最终名称创建另一个文件，结果保留两份内容并报冲突；另验超过 260 字符的 Unicode 路径。
- 启动隔离 Windows Release 主窗口。用包内签名本地 agent，通过现场 TLS 连接验证替换收据在进程重启后仍能查询，重复操作编号不重放；AI 文件回退需要预览，纯对话回退保持文件不变。Linux 二进制在 WSL 报告 `3.26.0`。验签升级策略接受 `3.24.0`、`3.25.1`、`3.25.3` 升到 `3.26.0`，拒绝同版本替换。

未公开发布或升级真实服务器。不把进程重启验收等同于物理掉电测试；目录替换、客户端退出后的待查询恢复和 AI 写入归因仍待做。
