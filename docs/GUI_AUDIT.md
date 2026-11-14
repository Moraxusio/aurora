# GUI 交互检查（3.18.1）

用户在 85% 缩放下反馈按钮失效后，本轮从正式 `AuroraApp` 根节点检查绘制、命中、浮层、焦点、快捷键、保活宿主与 Windows 窗口桥接。

## 已复现并修复

| 问题 | 根因与修复 |
|---|---|
| 缩小后右侧及底部点击死区 | `Transform.scale + OverflowBox` 绘制超出实际命中边界。改用固定逻辑尺寸的 `SizedBox + FittedBox`，绘制、命中和语义共用一个变换；MediaQuery 的大小、有效 DPR 和 inset 同步换算。 |
| 右键菜单偏离鼠标 | 屏幕坐标直接当作 Overlay 坐标。公共菜单改用 `globalToLocal`，布局变化时由 `positionBuilder` 重算。 |
| 命令面板功能弹窗打不开 | ScaffoldMessenger 的 context 位于 Navigator 外。功能命令改用全局 Navigator 内的 Overlay context，覆盖新建终端、AI 设置及快速打开。 |
| 放大后的通知文字零宽 | 用未缩放窗口宽度计算左右边距，挤光逻辑视口。改由 Scaffold 约束固定最大宽度。 |
| 终端吞掉工作台快捷键 | xterm 在祖先快捷键之前把按键编码为 shell 输入。新 `WorkbenchShortcuts` 在终端编码前分发工作台保留键，Ctrl+C 和粘贴保留。 |
| 文件预览只占半屏、隐藏编辑器仍可获焦 | 两个 Expanded 仍均分高度，Offstage 不禁止焦点。改为单视口保活 Stack，隐藏源编辑器排除焦点及 ticker；未保存内容和撤销宿主保留。 |
| 外部打开 AI 会话仍停在历史页 | 历史显示状态未跟随活动会话。按 EditorTab 对象身份识别真正的激活变化，草稿后台 ID 晋升不算导航。 |
| Windows 无障碍语义更新失败 | Slider 的常驻 OverlayPortal 跨越滚动语义子树，原生 AXTree 拒绝孤立的 indicator 节点。设置和标签宽度滑块采用同子树的局部 Overlay，并按显示单位朗读数值；保留 Tooltip、数值指示与全应用语义。 |

以上均先用失败回归确认，再修复实现。未改变凭据格式及 agent 协议。

## 自动化覆盖

- 全量 Flutter 回归：329 项通过、20 项既有环境条件跳过；`flutter analyze --no-pub` 零问题。
- `workbench_scale_test.dart`：80%–150% 每 5% 一档，DPR 1/1.25/1.5/2，四角及中央按钮真实命中；85%/125% 右键菜单位置与动作。
- `gui_routing_test.dart`：正式根节点命令弹窗、放大后通知、终端键盘路由，以及多缩放/DPI 下三类标题按钮点击。窗口按钮使用 mock channel，断言真实指针事件分发到对应原生方法。
- `gui_workflow_test.dart` / `support/gui_workflow.dart`：通过设置控件连续切换 85/80/100/125/150/85%，操作文件树、AI 输入/菜单/底部遮罩/历史/放大/详情、终端、分隔线、停靠及未保存关闭取消；单次终端连接、编辑器实例与草稿保留。
- `integration_test/gui_interaction_test.dart`：同一工作流运行于 Windows Profile 原生引擎，保留 JSON 与 PNG。使用内存服务及测试输入事件，不接入用户 profile、凭据、服务器或真实模型。
- 原生复现命令：`powershell -NoProfile -File app/tool/gui_audit.ps1`（Flutter/NASM 在 PATH 中）。脚本隔离实例/配置并检查 Windows AXTree 日志；Dart 断言通过但引擎拒绝语义更新时仍判失败。

最终 Windows Profile 工作流在 1682×1066 物理像素、DPR 1.25 下运行 78 秒，全部通过；AXTree 错误为 0，终端只连接一次，未保存内容保留。最后局部浮层改动的定向回归 18/18，分析零问题。[3.18.1 已发布](https://github.com/Moraxusio/aurora/releases/tag/v3.18.1)，构建与摘要见 PLAN。组件 DPI 矩阵不等同于实际多屏拖动、屏幕阅读器或 Android 真机验收。
