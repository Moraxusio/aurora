# 4.0.0 单文件基础版验收

> 类型：验收记录 | 状态：已记录 | 维护：构建维护者 | 更新：2026-11-21
> 适用：4.0.0-foundation-alpha1；Windows x64、WSL Ubuntu 24.04 Linux amd64

HEAD 为 `c90db8f78a775012afefdfff72dfde8b1b6fee2e`，从未提交工作树构建，Go 1.26.0、Flutter 3.47.9／Dart 3.13.7。初次打包指纹为 2,166 个输入，发包后逐项核对；后续补验收、路线图和发布哈希基线。未公开发布，未部署实际服务器。

| 产物 | SHA-256 |
|---|---|
| Windows `Aurora-4.0.0-foundation-alpha1-single.exe`（58,483,200 字节） | `4baafa5d2271cef5e81a9b1365eda0c59cd6c840853369b1c9aec9a59d5ff744` |
| 兼容 ZIP（55,229,398 字节，665 个文件逐项核验） | `56454b61a14a1936d3d24ee91cada0b670874fd2f0d6a5e9fc48cd1a437497aa` |
| Linux amd64 ELF | `6ed7eb1ad8eb1ab119580b7c8e3078bba4e448a732af56437b588bb5306eb8e2` |

- 内嵌运行包和两个 agent 的发布签名验证通过；外层 Windows EXE 未做 Authenticode 签名。并发首启只发布一个完整目录，缓存多出 DLL 则从原 EXE 解出新目录并保留有问题的旧目录。实测单 EXE 启动 Release GUI，正常 Profile 的文件哈希不变；缓存中的 runner、Flutter 引擎、AOT 和两端 agent 清单与兼容包逐项一致。
- 通过真实 Windows 本机 TLS 握手核对 4.0.0；新身份私钥与本地服务设置使用 DPAPI，重启后身份未变。用已验签 3.26.0 Windows agent 建立隔离旧状态，再用 4.0.0 读取，身份文件和指纹保持不变；此过程未写回旧配置，不等同于迁移。
- Linux ELF 在 WSL 用隔离配置和独立 32 字节凭据启动，身份密钥密文落盘，重启和故意缺少凭据时均未替换原身份。安装器、入口和协议包在 WSL 通过，包含程序替换失败后回退、保留管理员修改的 systemd 单元。
- Flutter 全量 688 通过、20 跳过；静态分析无错误或警告，仍有 lint 信息。Windows Go 非短模式全量、`go vet ./...`、`go build ./...` 通过。未完成真实 systemd 升级和掉电恢复、加密后的数据回退、两端 AI 数据与事务的全量加密；见 [4.0 正式门槛](../development/roadmap-4-0.md)。
