# GUI 底层重构与 Windows 验收

2026-11-15。共享视口与监控刷新层已重构并通过以下自动化验收，纳入 Windows 3.20.0。以下保留独立候选验收记录；原始截图灰屏尚未捕获对应异常，不能据此宣称其根因已经修复。

## 对比与选型依据

- v2：只读核对 `desktop/main.js`，桌面壳为 Electron，Chromium 承担 DOM/CSS 布局、输入和合成；Go core 是独立子进程。v2 的使用体验不能由 v3 的组件测试代替。
- VS Code：阅读 MIT 的 [SplitView](https://github.com/microsoft/vscode/blob/main/src/vs/base/browser/ui/splitview/splitview.ts)。值得复用的是有约束的尺寸计算、稳定视图身份、可见性生命周期和批量布局。它直接依赖 DOM、Sash 和浏览器滚动实现，不能作为 Dart 控件直接导入。
- [Avalonia](https://github.com/AvaloniaUI/avalonia-docs/blob/main/docs/fundamentals/architecture.md)：MIT，retained visual tree、measure/arrange、平台输入后端，是可选的原生桌面栈；更换后仍须重新实现并验证编辑器、PTY、AI、输入法和无障碍。
- [Flutter 官方性能建议](https://docs.flutter.dev/perf/best-practices)：收窄状态更新范围、缓存不变子树、惰性列表、避免 intrinsic 布局、用 Profile 实测 UI／raster 帧时间。重构先落实这些结构性约束，保留原生 Flutter 引擎和已有文档／连接状态。

此轮不引入 Web 运行目标或 GPL 依赖。现有 OpenCode MIT 署名继续保留；未复制 VS Code 源码。

## 已实现的底层契约

1. 所有保活视口共用 `RetainedPane`：身份稳定，隐藏时不接收焦点、指针、语义和 ticker；缓存布局尺寸及 MediaQuery，恢复时使用最新可见尺寸。
2. 监控采集从 Widget State 移出：系统与 GPU 发布独立、不可变快照，验证数据后才交给视图；并发、可见性、连接代次和释放由控制器统一管理。
3. 系统／GPU 更新只重建自己的订阅区块；详情立即展开、折叠时不构建正文，统一 SelectionArea 替代逐项文本编辑宿主。超过 6 个 GPU 进程使用 320 px 有界惰性列表，系统进程使用 sliver；窄面板有明确的布局约束，图表只在数据／颜色变化时重绘。
4. 生产根节点共用工作流同时在 widget 环境和 Windows Profile 引擎执行。任何 ErrorWidget、Flutter 异常、布局溢出或 Windows AXTree 错误都使验收失败。
5. 原生验收记录 UI／raster p95、峰值及超过 16.67ms 的帧数；预算断言与编辑状态、终端连接身份、真实命中位置一起检查。
6. 正式入口记录有界本地 GUI 异常类型／代码栈，保留原错误处理链。错误区域显示诊断编号；命令面板“复制界面诊断”导出本次会话记录。磁盘记录位于 `%LOCALAPPDATA%\Aurora3\diagnostics\gui.jsonl`，不记录异常消息、文档、网络参数或配置内容。

## 回归与复现记录

- 最终全量 Flutter：**373 通过、20 个既有环境条件跳过、0 失败**（58 秒）；完整 `dart analyze --fatal-infos` 零问题。包含最后补齐的祖先隐藏回归。跳过项依赖代理／远程升级等专用环境，没有新增跳过条件。
- 正式根节点监控矩阵：1800×1100／1200×800／900×700 逻辑尺寸 × 深浅主题 × DPR 1／1.5，逐一展开、刷新并切换 85／100／125／150% 缩放，包含 MX450 脱敏样本。600 个 GPU 进程验证折叠时零正文、展开时仅构建可视附近行、可以滚动到最后一行。
- 首轮全量 356 通过、13 失败：8 项为切换硬件样本后的屏幕外标题、4 项为窄窗初次屏幕外标题，另外 1 项为新测试缺少 Ide 主题；补齐惰性内容滚动定位／数据断言与主题后，定向 32 项及最终全量通过。没有删掉断言或放宽预算。
- 30 个标签／24 次窗口变化：隐藏正文重建 0、隐藏布局 0；240 次几何更新：业务通知 0、几何通知合为 1 帧。控制器另覆盖 120 次轮询的 60 点历史上限、快照脱离来源、并发／隐藏／换连接／释放和格式错误恢复。
- 额外先复现“父视口隐藏、内部局部 visible 仍为 true”的遗漏：24 次窗口度量变化产生 24 次隐藏内容重建。共享视口现在以局部可见性与祖先 TickerMode 的合取控制缓存／焦点／绘制，覆盖整窗隐藏及嵌套宿主；这不是原始截图灰屏根因的证据。
- 代码复核发现旧 GPU 回退的格式错误可能污染系统刷新，已隔离到 GPU 错误状态并补齐 unsupported 回退／恢复测试；Windows `go test ./internal/monitor -count=1` 通过。
- 本机检测到 GeForce MX450，驱动 573.91。已经使用生产 `nvidia-smi` 执行路径和 XML 解析器生成脱敏硬件样本（UUID、进程名／PID 替换），采集未读取客户端 profile。
- 另启动隔离配置的 **3.19.0 正式二进制及其签名本地 agent**，用该窗口的原生鼠标消息展开真实 MX450 详情，成功显示。测试客户端及其自有 agent 已退出。该次未复现用户原始灰屏；合成数据下旧版也能展开，因此不把重构当作已证实的灰屏根因修复。

## Windows 原生验收

使用生产 AuroraApp、Windows Profile 引擎和内存服务，DPR 1.25；硬件样本来自实际驱动，AI／终端流为合成协议数据。实际 WM_SIZE 覆盖 1200×800、1000×700、1500×1000，再还原原窗口。

最终综合原生测试 **87 秒通过**，包含 12 个文件、GPU 展开／缩放／硬件样本、并发 AI／终端／监控、30 秒持续负载、未保存文件／固定标签／AI 草稿／阅读位置及单次连接身份检查。滚动测量明确定位到 GPU 详情正文，已查看该区域和硬件样本截图。

| 场景 | 帧数 | UI p95 | raster p95 | UI 最大帧 | 超过 16.67ms |
|---|---:|---:|---:|---:|---:|
| 监控 + AI 流 + 终端输出 + 侧栏拖拽 | 161 | 6.453ms | 3.959ms | 7.872ms | 0 |
| 12 个保活编辑器切换 | 49 | 9.385ms | 4.417ms | 10.422ms | 0 |
| 展开的 GPU 详情正文滚动／刷新 | 58 | 1.398ms | 3.403ms | 7.850ms | 0 |
| 30 秒并发轮询／流式输出 | 301 | 3.232ms | 3.671ms | 4.321ms | 0 |

完整原生交互工作流 **79 秒通过**：85／80／100／125／150／85% 缩放、设置、文件树、AI 输入／菜单／历史／最大化、终端快捷键、分隔线、缩放后拖放停靠、未保存关闭取消、布局滑块、命令弹窗和 Escape；显式验证撤销／重做历史与未保存正文保留。两轮原生日志均无 Flutter／布局／AXTree 错误。综合测试编译缓存记录的 RetainedPane 源摘要与祖先隐藏修正后的源码一致，见 [机器可读帧记录](performance/20261115-gui-foundation.json)。

阈值：UI／raster p95 <16.667ms，UI 最大帧 <100ms；日志中 Flutter 异常、布局溢出或 AXTree 拒绝均判失败。未得到有效的旧版同场景性能 JSON，**不报告重构前后百分比提升**。

## 本地候选与实际 Release 检查

- 启动：`C:\dev\VPS\preview3\Aurora-3.20.0-gui-preview1\启动验收版.cmd`。中文启动器使用包内 `review-data` 独立配置及实例，首次为空白配置。
- 客户端文件版本 `3.20.0+32000`，正式入口 `lib/main.dart`；构建前后 994 个客户端源码摘要一致。复用验签后的 3.19.0 本地／远程后端，法律文件与 OpenCode MIT 署名核对通过。
- 另以全新临时配置运行包内实际 Release 二进制，原生点击打开监控、展开真实 MX450 详情并滚动到 GPU 进程列表；刷新后仍显示正常，本地 GUI 异常记录为 0。自有客户端与 agent 已退出。
- ZIP 为同级 `Aurora-3.20.0-gui-preview1.zip`，SHA-256 `eba61e0c45cb8c7b1977248ccb4944a8e2e37093187a02f8a5a66726ac5a1591`；机器可读摘要见 [Release 检查记录](performance/20261115-gui-release.json)。此处补记的是构建后的运行检查，包内文档保留构建时的验收快照。
- 截图中的功耗上限 5001 W 已与当时 `nvidia-smi -q -x` 的 `current_power_limit` 核对一致，驱动同时报告默认上限 9.50 W；这是采集源返回值，本轮未擅自替换为默认值，不将该数值当作硬件能力结论。

## 运行与证据

```powershell
# app 目录，Flutter / NASM 在 PATH 中
flutter test --no-pub --reporter expanded
dart analyze --fatal-infos
.\tool\gui_audit.ps1 -Suite foundation -Out <新的输出目录>
.\tool\gui_audit.ps1 -Suite interaction -Out <另一个新的输出目录>
```

可选硬件路径：先设置 `AURORA_GPU_NATIVE_FIXTURE` 到新 JSON 路径，在 agent 目录运行 `go test ./internal/monitor -run TestNativeGPUFixture -v -count=1`，随后带同一变量运行界面测试。

本机证据根目录：`C:\Users\finwe\AppData\Local\Temp\opencode`。

- `gui-foundation-final-373-tests.log`：最终全量；`gui-foundation-final-tests.log`、`gui-foundation-fix-tests.log` 保留前轮全量与定向证据。
- `gui-foundation-after-02`：最终综合原生 JSON／PNG／日志；`after-01` 为首轮记录。
- `gui-interaction-foundation-02`：完整原生交互、撤销／重做验证及截图。
- `gui-release-repro`：隔离正式包复现截图与自有进程记录。
- `gui-foundation-release-preview1`：本次候选的实际 Release 启动、GPU 展开／滚动截图及自有进程退出记录。

本轮保持 Flutter 引擎、配置格式与 agent 协议；不迁移 API Key／OAuth，不改本地 agent 生命周期。当前实测覆盖上述本机环境；没有进行多屏混合 DPI 拖动、屏幕阅读器实操、真实模型账号、长期数小时负载或 Android 真机验收。
