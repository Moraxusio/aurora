# AI 配置与快照改造验收

> 类型：验收记录 | 状态：已记录 | 维护：AI 维护者 | 更新：2026-11-16
> 适用：3.23.0-ai-preview1 本地候选源码；基线 da239052098f610716a8f2b82ed072aa001953dc，加本轮未提交修改

## 范围

实现与使用见 [AI 协作](../guides/ai.md)、[候选说明](../releases/3.23.0-ai-preview1.md)。快照对照 2026-11-16 读取的 [OpenCode 配置](https://opencode.ai/docs/config) 和 [Snapshots](https://opencode.ai/docs/snapshots)，采用相同的独立对象库、会话目录范围与有效文件筛选原则；Aurora 的非 Git 目录支持及事务冲突校验保留。

## 执行记录

本记录随实际检查更新；完整包内保留构建时的文档快照，构建后产物复核在源码记录补充。原始输出见 [证据目录](../performance/20261116-ai-control/README.md)。

- Windows Go 全量 `test ./... -count=1`（20 个有测试的包）、`vet ./...`、`build ./...` 通过；AI 定向 race 通过。
- Linux AI 包交叉编译测试二进制后在 WSL Ubuntu 24.04 实际执行：87 通过、0 跳过。覆盖 20001 文件快照、真实 Git 上级忽略／info-exclude、已跟踪忽略文件及删除、真实索引不变、内容去重后实际存储上限、超限恢复、零预算持久化和失败提供商元数据。此结果不是 Linux 全仓库或 Linux race。
- GUI contract 通过；Flutter analyzer 复验 0 error、0 warning，205 条 info。
- 全量 Flutter：604 通过、20 跳过。新增覆盖预算中断恢复入口、零值保存／校验、360／1280 宽度和 1.5 倍文字、保存过程中继续编辑、外部冲突、重连异步结果隔离，以及已有项目页的快捷跳转／草稿关闭保护。
- 内部包：Profile 58、Wire 23（跳过 21）、Install 7（跳过 21）、Subscription 39 通过；环境型跳过由后续包内 TLS／正式公钥冒烟补验相应范围。
- 设置总览、连接、模型、工具权限、对话在 390／1100 宽度与深浅色均通过回归，并保留截图。
- Windows 原生 Profile GUI 交互与无障碍检查通过：真实应用根节点，合成服务与输入；80／85／100／125／150% 缩放、AI 设置／对话／历史／详情、布局、退出取消、终端快捷键。脏缓冲、撤销重做和同一终端连接保留；未发现 AXTree 拒绝或布局溢出。
- 首次 Flutter 检查因未设置 NASM 在进入测试前失败，补齐 `AURORA_NASM` 后通过；首次 analyzer 的 4 条新 warning 已修复并复验清零。
- 真实模型账号、订阅资格、模型质量、长期压力不属于本次自动化通过结论。

## 构建

使用 `tools/package-preview.ps1 -Version 3.23.0 -Suffix ai-preview1`，完整客户端与双平台 agent 均从本轮工作树编译。输出为 `C:\dev\VPS\preview3\Aurora-3.23.0-ai-preview1`；本地候选采用正式公钥可验证的 agent 签名。构建前后 1664 个输入文件指纹一致；构建后再次逐项核对，随后补入本节验收结果及原始证据。本轮不提交、不推送、不发布 GitHub。

| 产物 | 结果 |
|---|---|
| ZIP | `C:\dev\VPS\preview3\Aurora-3.23.0-ai-preview1.zip`，37245093 字节 |
| ZIP SHA-256 | `b9ef6d6c240d925083f3bc0dbe7df1e048485c5c57613d23bf4853e4570d70b4` |
| 解压复核 | 197 文件逐个大小与 SHA-256 一致，sidecar、许可证、随包文档链接通过 |
| 客户端版本 | `3.23.0+32300` |
| 客户端 AOT SHA-256 | `02d7e55f930cb1db9f033e3e68117864bfbb6edee1fef546bb5cfd8536cce419` |
| Linux agent SHA-256 | `e1db782500c7b5a5ecab76ba4847f53a0d0c92a516a793a4f1e17893bc515f63` |
| Windows agent SHA-256 | `24c37f18eecdb24af7b47dcb5c99959163336dcb75e46f15fb843374557b922c` |
| 签名 | 双 agent 及升级策略通过正式公钥校验，key ID `87828dfb18459372` |

## 包内运行

- 包内 Linux agent 在 WSL 实际执行 `version` 返回 `3.23.0`。
- 包内 Windows agent 通过真实 TLS 的文本编码、批量事务冲突、任务、Dart LSP／DAP、指令／技能／预算持久化冒烟；新增的零值不限、自动功能开关和快照范围检查均通过。
- AI 合成模型服务冒烟通过媒体读取、补丁事务、结构化问题与重启历史恢复。
- Release 完整包通过实际 CMD 启动、独立加密配置、局部工作区语义、关闭到托盘、二次启动恢复同一进程、退出确认及本地 agent 清理；最终自动化以窗口句柄定向操作并保持 MSAA 对象引用。
- 两次额外的 Release 命令面板自动化尝试未完成（语义调用未成功／前台键盘等待超时），未计为通过；未采用全屏拷贝图片作此包的证据。AI 设置页面的原生交互结论来自上面的 Profile GUI 验收，Release 的 AI 运行结论来自包内真实 TLS 冒烟。

## 使用入口

直接运行 `C:\dev\VPS\preview3\Aurora-3.23.0-ai-preview1\aurora.exe` 沿用现有本机配置；`启动验收版.cmd` 使用独立空白 `review-data`。正式交付目录和 ZIP 保持构建时内容；以上原生验证使用另行解压的临时副本。
