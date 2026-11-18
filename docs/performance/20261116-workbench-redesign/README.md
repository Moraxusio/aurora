# 工作台重构证据

> 类型：证据索引 | 状态：已记录 | 维护：项目维护者 | 更新：2026-11-16
> 适用：3.24.0-workbench-preview1 的源码、GUI 与候选包验收

本目录收集本轮原始日志、明暗宽窄截图、原生帧数据及源码指纹。失败轮和修复后的复验分别保留，不覆盖历史证据。

最终数字及运行范围见 [验收记录](../../validation/2026-11-16-workbench-redesign.md)。

| 路径 | 内容 |
|---|---|
| `environment.json`、`baseline/` | 环境、开始前的修改基线、AI 文件一致性 |
| `checks/`、`linux/` | Windows Go、WSL Linux、systemd 与客户端检查 |
| `checks/client/flutter-all4.log` | 最终 662 通过、2 条件跳过；早期轮次同目录保留 |
| `proxy-e2e/` | 两项独立真实代理端到端验收 |
| `screenshots/`、`contact-sheets/` | 最终 71 张 GUI 截图及全部联系表 |
| `native-interaction/` | Windows Profile 交互结果、截图、源码指纹 |
| `native-foundation/`、`native-foundation2/` | 原生测试窗口／输入夹具的失败轮 |
| `native-foundation3/` | 通过的性能复验：539 帧、四场景、0 超预算帧 |
| `failures/`、`runners/` | 其它失败证据及复验运行器 |
| `package/` | 构建后补记的完整候选验签、ZIP 一致性、真实 agent 冒烟与 Release 生命周期 |

包内证据截止到构建开始；`package/` 的后验结果写入仓库及交付目录外层，不反向修改已校验的 ZIP。
