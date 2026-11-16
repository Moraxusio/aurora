# Aurora 文档

> 类型：文档索引 | 状态：生效 | 维护：项目维护者 | 更新：2026-11-16
> 适用：3.22.0 正式版及后续维护

## 按任务阅读

| 目标 | 文档 |
|---|---|
| 打开项目、操作工作台、连接服务器 | [开始使用](guides/getting-started.md) |
| 验收本轮完整包 | [验收指南](guides/acceptance.md) |
| 配置 LSP、任务、DAP、编码与批量替换 | [开发工具](guides/development-tools.md) |
| 配置模型、授权、AI 修改与 MCP | [AI 协作](guides/ai.md) |
| 修改源码与选择检查范围 | [贡献流程](development/contributing.md) |
| 准备工具链、编译和生成完整包 | [构建与打包](development/build-and-package.md) |
| 搭建所有新 GUI | [统一 GUI 组件](development/gui.md) |
| 理解模块、状态和持久化 | [架构与状态所有权](architecture/overview.md) |
| 查支持范围、资源上限及未验能力 | [能力与兼容边界](reference/compatibility.md) |
| 编写、移动和归档文档 | [文档规范](standards/documentation.md) |

## 版本与证据

- [3.22.0 正式版本说明](releases/3.22.0.md)
- [3.22.0 正式发布与公开下载复核](validation/2026-11-16-release-3.22.0.md)
- [正式发布原始证据](performance/20261116-release-3.22.0/README.md)
- [3.22.0-ide-preview1 版本说明](releases/3.22.0-ide-preview1.md)
- [3.22.0-ide-preview1 完整包验收](validation/2026-11-16-package-ide-preview1.md)
- [打包与 Release 原始证据](performance/20261116-package-ide-preview1/README.md)
- [2026-11-16 源码验收](validation/2026-11-16-implementation.md)
- [2026-11-16 实施过程](validation/2026-11-16-implementation-log.md)
- [2026-11-16 改造前审计](validation/2026-11-16-audit.md)
- [原始检查与性能证据](performance/20261116-implementation/README.md)

## 文档维护

- [指南模板](templates/guide.md) · [验收记录模板](templates/validation.md) · [决定模板](templates/decision.md)
- [ADR 0001：文档结构与生效规则](decisions/0001-documentation-structure.md)
- [旧文档迁移与历史索引](archive/README.md)

当前规范和实际源码共同维护。版本说明描述该版本变化，验收记录只证明记录中的环境与范围，历史档案保留当时结论。新开发不从旧 `PLAN.md` 或 `DESIGN.md` 继续追加。
