# 架构与状态所有权

> 类型：架构说明 | 状态：生效 | 维护：项目维护者 | 更新：2026-11-16
> 适用：3.22.0 的 Windows 客户端、Windows 本地 agent、Linux 远程 agent

## 模块

| 层 | 源码入口 | 职责 |
|---|---|---|
| 客户端应用状态 | `app/lib/state` | 加密 Profile、连接、外观、本地 agent 生命周期 |
| 工作区内核 | `app/lib/kernel` | 文档、面板／标签、恢复、开发任务与调试模型 |
| 功能界面 | `app/lib/features` | AI、文件、开发工具、Git、终端、监控等交互 |
| 统一 GUI | `app/lib/ui/aurora_ui.dart` | 组件、组合布局、浮层与交互规范 |
| Dart 内部包 | `app/packages` | TLS／wire、安装验签、配置加密、订阅读取 |
| agent 入口与服务 | `agent/internal/entry`、`service` | 身份、服务能力、RPC／流分发 |
| 文件协调 | `agent/internal/files`、`filetxn` | 路径约束、版本复核、原子提交和崩溃恢复 |
| 开发进程 | `agent/internal/devtools`、`devprocess`、`mcp` | stdio／HTTP 桥、进程配额、取消和回收 |
| AI 执行 | `agent/internal/ai` | 上游适配、工具权限、建议、会话持久化与快照 |

## 状态边界

- Workspace 拥有文档正文、控制器、版本、保存点、选区、撤销与恢复记录。视图销毁和面板隐藏不等于丢弃正文。
- 工作区布局、终端面板和 AI 面板分别维护活动项；保活宿主保留身份，隐藏时暂停不必要的绘制。只使用菜单内上下文时，在打开菜单时查询。
- Profile 保存客户端凭据、配置及偏好；文档恢复、任务历史和断点采用独立加密分区，坏记录保留证据并阻止覆盖。
- agent 会话用 JSON 检查点、长度／CRC32／序号 journal 和派生 index；启动先读元数据，正文按需加载。每会话 IO lease 保证顺序，编码／fsync 不占全局会话锁。

## 数据写入

AI 工具、普通保存／上传、多文件修改及会话回退共用文件提交协调。审批和网络接收在锁外；提交时校验所有目标的预期版本，持久化 undo journal，再替换目标。

崩溃恢复不能确定提交结果时停止后续写入，保留日志与原始错误。会话回退把磁盘变更、会话检查点和 journal 同批处理；外部修改不能被静默覆盖。事务与正文预算见 [能力边界](../reference/compatibility.md)。

## 连接与执行端

- 远程首次通过 SSH 配对／安装，随后使用固定证书指纹的 TLS 和 yamux；操作使用有界 JSON／数据帧。
- Windows 本地 agent 是客户端子进程，使用私有 stdin/stdout 完成临时身份引导，再连接 loopback TLS；完整退出客户端会结束受管进程。
- LSP、DAP、任务、MCP stdio 和 AI shell 在文件所在 agent 机器运行，使用该机器的 SDK／工具和权限。
- 异步操作核对连接身份、请求代次和文档版本，取消传播到网络流和子进程。传输有磁盘背压与并发预算。

## 凭据、协议与兼容

Windows Profile 使用当前用户 DPAPI。客户端安装／启动 agent 前验证发布公钥签名及文件哈希；数字版本和签名 channel 是更新协议的一部分。Windows EXE 的 agent 清单签名不等于 Windows Authenticode 签名。

AI 保留 OpenCode 兼容标识及 Chat／Responses／Anthropic 适配路径。OAuth 刷新和客户端授权、agent 模型调用是不同网络路径，详见 [AI 协作](../guides/ai.md)。普通文件与 agent 端会话／附件不是客户端加密 Profile。

历史 D-* 设计号保留于 [历史设计](../archive/2026-11-16/DESIGN.md)，新决定使用独立 ADR。
