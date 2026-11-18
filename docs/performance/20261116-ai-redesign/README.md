# AI 交互与运行控制原始证据

> 类型：性能证据 | 状态：已记录 | 维护：AI 维护者 | 更新：2026-11-16
> 适用：3.23.0-ai-preview2 本轮源码、原生及完整包检查

本目录只存本轮执行日志与截图；结果和边界以 [验收记录](../../validation/2026-11-16-ai-redesign.md) 为准，不将上一候选结果视为本轮通过。

| 路径 | 内容 |
|---|---|
| `environment.json` | 源码基线、未提交状态、工具链及执行参数 |
| `checks/` | Windows Go 全量／vet／build、race、Linux AI、GUI contract、Flutter 全量／analyzer、定向交互和内部包检查 |
| `failures/` | 早期运行原始日志，包括测试修正前结果、首次 WSL 参数错误及 Wire 缺少 NASM 的构建失败 |
| `screenshots/` | 56 张本轮合成协议数据截图：宽窄明暗、运行／审批／输出、本次发送、项目代理／工具、全局设置五页 |
| `native-interaction/` | 本轮 Windows Profile 实际窗口交互、无障碍、缩放及状态保持；日志、结果、截图与源码指纹 |
| `native-foundation-first/` | 首轮帧预算失败的全部原始结果；混合拖动、编辑切换及 soak 慢帧，保留截图、日志和源码指纹 |
| `native-trace/` | 同源码／原阈值的 CPU 采样诊断轮，四场景通过；原始采样、摘要及 1207 项源码指纹比较。首次异常原因未确定 |
| `native-confirmation/` | 同源码无采样确认通过，533 帧无超预算帧；原始结果、窗口截图及源码指纹 |
| `package/` | 构建日志、1809 项输入指纹、337 文件 ZIP 复核、正式公钥验签、包内 TLS、Linux 启动与隔离 Release 生命周期；含复核脚本 |

界面截图由 Flutter `RenderRepaintBoundary` 捕获，不是用户桌面截屏。原生 Profile、合成模型 TLS 与 Release 启动分别只证明各自记录的实际范围。包内文档保留构建时快照，本目录的 `package/` 证据及最终验收记录在构建并核对输入后补写。
