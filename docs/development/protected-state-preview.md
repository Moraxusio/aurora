# 4.0 受保护状态隔离验收

> 类型：开发指南 | 状态：候选 | 维护：构建维护者 | 更新：2026-11-21
> 适用：`4.0.0-foundation-alpha1` 之后的未发布源码；不用于生产升级

## Windows

新源码的单 EXE 用 `%LOCALAPPDATA%\Aurora4ProtectedPreviewState\Aurora3\`，不打开 `%LOCALAPPDATA%\Aurora3\` 或旧 Alpha 的 Profile。Windows 本机 agent 需要当前用户解开绑定 agent ID 的 DPAPI 密钥；新建只允许空状态目录。旧运行模式不能打开带加密标记的本机 agent 状态。

[公开预览候选](../releases/4.0.1-public-preview1.md) 改用 `%LOCALAPPDATA%\Aurora4PublicPreviewState\Aurora3\`，不共享以前的预览状态，也不安装／升级远程 agent。导入客户端时请改用该预览的路径作为目标，且不覆盖已经打开过的目标。

验收时可用 `aurora3-local-agent.exe clone-protected-preview --source <已停止的旧本机-agent目录> --dest <尚不存在的验收目录> --source-stopped`。目标用绝对路径，父目录须已存在；不把正式 Profile 或项目目录作为目标。此操作只导入 agent 状态，不复制客户端 Profile，也不启动旧项目或连接远端。

要一并克隆客户端，用 `aurora3-local-agent.exe clone-client-preview --source <已停止的旧Aurora3目录> --dest <尚不存在的验收Aurora3目录> --source-stopped`。它验证并逐字节保留 Profile、文档恢复和开发状态的 DPAPI 密文；若有本机 agent，则在同一个暂存目录中导入。先准备隔离的 `Aurora4ProtectedPreviewState` 父目录，目标使用其中的 `Aurora3` 子目录。使用本版单 EXE 打开隔离克隆时不会自动连接；连接需由用户显式发起。旧版 EXE 和正式 Profile 不受影响。

## Linux

先在隔离环境准备独立的 32 字节二进制凭据 `aurora-state-key`，由 `CREDENTIALS_DIRECTORY` 指向凭据目录。实际密钥不进环境变量值、命令行、状态目录或发行包；开发验证只使用随机的临时凭据，正式环境需要由操作系统或管理员托管的独立来源。

不从 3.x 导入时，给首次启动创建一个新的隔离状态。用密码管理器生成 32 字节随机值（64 个十六进制字符），在 Bash 的隐藏提示输入，令牌只经标准输入交给初始化程序。下例的父目录 `/fixture` 应已创建、仅由当前测试用户访问，`/fixture/fresh` 必须尚不存在。

```bash
read -rsp 'Preview pairing token: ' join_token; printf '\n'
printf '%s\n' "$join_token" | ./aurora3-agent-4.0.1-linux-amd64 init-protected-preview --dest /fixture/fresh --instance verification
unset join_token
./aurora3-agent-4.0.1-linux-amd64 run --config /fixture/fresh/agent.json
```

启动日志显示本次随机回环端口和证书指纹，不输出配对令牌。使用上述令牌在同一台机器上验收；每次启动端口可能不同。两端使用真实项目文件时，普通编辑和文件操作仍会改写所选项目；请用测试项目。

```text
aurora3-agent clone-protected-preview --legacy-config /fixture/old.json --dest /fixture/new --instance verification --source-stopped
aurora3-agent run --config /fixture/new/agent.json
```

`--source-stopped` 是操作者必须确认的前提，不会自行停止旧服务，也不能给不支持锁的 3.x 加写入锁。验收实例只监听随机回环端口，使用空项目目录替代原项目路径，不启用终端、代理、转发、systemd 管理及旧升级 worker；拒绝直接在 systemd 单元中启动这一受保护预览。此约束不改变现有生产安装的 root 运行语义。

`activation-preview` 在独立目录下读取 `programs/<sha256>/` 中的发行物与签名、`policy/` 中的签名撤回策略、`fixtures/<sha256>/agent.json` 中分别准备的加密克隆。空的 `selection/` 为控制记录目录；运行 `init` 或 `trial --root <验收目录> --version <版本> --sha256 <摘要>`。试运行先持久化收据，再使用隔离状态验证 TLS、ID 和版本；`status --root <验收目录>` 只查收据，`launch --root <验收目录>` 只启动已提交版本。未确认候选不会在重启时被重放；已确认程序变坏时停止，而不擅自回到一份可能缺少新写入的旧状态。此命令不是生产 systemd 主程序。

## 导入边界

- 支持保留证书指纹和 agent ID，复制 Linux token／代理凭据或 Windows 本地服务配置，以及 AI 会话、附件、已提交的文件替换收据、有会话引用的旧 Git 快照和工具输出。源文件不改写；源目录不能与目标互相包含。已识别仓库的未引用对象保留在原件中。
- 写到目标同卷的私有暂存目录，只发布完整克隆，不覆盖既有目标。Linux 配置将 token／代理字段封装为认证密文，监听和根目录等公开字段也绑定至该密文；重新验证旧二进制后可以打开未动的源以结束验收。
- 不支持原位升级、仍有文件事务的目录、无法识别的状态、缺失的快照对象或跨机器 DPAPI 迁移。这些情况拒绝克隆，不能通过删掉不识别的目录绕过。
- 未验证生产迁移后的写入如何返回旧格式，也未验证生产 systemd 切换、Windows 持久版本选择、真实机器重启或掉电恢复；**能重新启动不变的源不等于能回滚已经迁移后产生的新写入。**
