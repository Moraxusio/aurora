# 历史文档索引

> 类型：历史索引 | 状态：生效 | 维护：文档维护者 | 更新：2026-11-16
> 适用：旧路径迁移和历史追溯；当前规范见文档入口

2026-11-16 完成当前文档体系重组。以下文件保留原版本语义，不是当前开发规范；当前使用方式见 [文档入口](../README.md)。

## 旧开发与功能文档

| 原 docs 根目录文件 | 历史档案 | 当前替代入口 |
|---|---|---|
| DESIGN.md | [旧总设计／D-* 编号](2026-11-16/DESIGN.md) | [架构](../architecture/overview.md) |
| PLAN.md | [旧总计划／版本流水账](2026-11-16/PLAN.md) | [开发流程](../development/contributing.md)、版本与验收目录 |
| AI.md、AI_REDESIGN.md、AI_HARNESS.md | [AI](2026-11-16/AI.md)、[重设计](2026-11-16/AI_REDESIGN.md)、[harness](2026-11-16/AI_HARNESS.md) | [AI 指南](../guides/ai.md) |
| TABS.md、IDE_REDESIGN.md、READER_AI.md | [标签](2026-11-16/TABS.md)、[IDE](2026-11-16/IDE_REDESIGN.md)、[阅读](2026-11-16/READER_AI.md) | [开始使用](../guides/getting-started.md) |
| UI_SYSTEM.md、GUI_FOUNDATION.md、GUI_AUDIT.md | [视觉](2026-11-16/UI_SYSTEM.md)、[基础层](2026-11-16/GUI_FOUNDATION.md)、[GUI 验收](2026-11-16/GUI_AUDIT.md) | [GUI 规范](../development/gui.md) |
| WINDOWS_WORKBENCH.md、WINDOWS_SIMPLIFICATION.md | [工作台](2026-11-16/WINDOWS_WORKBENCH.md)、[减法](2026-11-16/WINDOWS_SIMPLIFICATION.md) | [GUI 规范](../development/gui.md) |
| UI_REVIEW.md、WORKBENCH_REVIEW.md | [UI 验收](2026-11-16/UI_REVIEW.md)、[工作台验收](2026-11-16/WORKBENCH_REVIEW.md) | 当前 validation 目录 |
| LOCAL_AGENT.md、GPU_MONITOR.md | [本地 agent](2026-11-16/LOCAL_AGENT.md)、[GPU](2026-11-16/GPU_MONITOR.md) | [开始使用](../guides/getting-started.md)、[兼容参考](../reference/compatibility.md) |

## 本轮有效内容迁移

- `AURORA_GUI.md` → [development/gui.md](../development/gui.md)
- `DEVELOPMENT_TOOLS.md` → [guides/development-tools.md](../guides/development-tools.md)
- `PROJECT_AUDIT_20261116.md` → [审计记录](../validation/2026-11-16-audit.md)
- `IMPLEMENTATION_ROADMAP_20261116.md` → [实施记录](../validation/2026-11-16-implementation-log.md)
- `IMPLEMENTATION_VALIDATION_20261116.md` → [源码验收](../validation/2026-11-16-implementation.md)

## 更早的讨论

旧 `docs/history` 三份材料移到 `archive/pre-v3`：

- [v3 重设计草案](pre-v3/REDESIGN_V3.md)
- [v3 初期目标](pre-v3/PLAN_V3.md)
- [搜索服务边界讨论](pre-v3/OPEN_DECISION_SEARCH.md)

原始性能 JSON、日志、截图与构建源码哈希仍在 `docs/performance`，文件中的旧路径代表当时源码快照；不要为新文档布局改写这些历史指纹。
