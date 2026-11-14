# 统一视觉架构：表面、状态与动效

Windows 工作台采用紧凑、中性的 IDE 视觉：内容占主导，蓝色表示焦点和主操作，颜色与图标共同表达状态。延续共享保活视口；浮层只负责当前操作，不重建背后的文档、终端或 AI 会话。

## 1. 三层实现

| 层 | 代码 | 职责 |
|---|---|---|
| 视觉基础 | `app/lib/theme/ide_theme.dart` | `Ide` 深浅色语义配色、字体、Material 主题及双层浮层阴影；`Space` 间距、`Radii` 兼容入口 |
| 几何与动效 | `app/lib/theme/workbench_tokens.dart` | `UiMetrics` 尺寸、`UiMotion` 时长／曲线／减少动画策略 |
| 共享组件 | `app/lib/kernel/overlays.dart`、`widgets.dart` | 菜单、弹窗、选择器表面、提示、焦点和退出生命周期 |

功能代码提供选项、内容、状态与操作。新浮层从共享入口接入；功能内部不重新定义阴影、圆角、动画时长或深浅色分支。AI 卡片的 `AiVisuals.radius` 同样引用基础 token。

## 2. 表面层级与状态

- **工作区**：`frame` 是窗口框架；`editor`、`sideBar`、`panel` 是连续内容面；用 1px 分隔线和选中态区分功能区域。
- **浮层**：`surface` 背景、`borderStrong` 边框、6px 圆角。菜单／搜索选择器／服务器切换器共用 `FloatingSurface`，采用轻近影＋柔和远影；不使用背景模糊。
- **模态**：同一 `surface` 配色，12 级 Material 阴影；深色遮罩透明度 38%，浅色 18%。默认窗口内边距水平 16px、垂直 24px；按钮区域统一留白。
- **反馈**：Toast 和 tooltip 复用浮层色板；tooltip 延迟 450ms，Toast 按可用宽度约束到最多 480px。
- **文字**：界面字体 Segoe UI Variable，回退 Segoe UI、Microsoft YaHei UI；正文 13px，辅助信息 11.5–12px，弹窗标题 16px / 600。
- **状态**：普通文字 `text`，说明 `textDim`，禁用 `textFaint`，悬停 `hover`，键盘焦点 `accentSoft`，危险操作 `error`。勾选同时有图形与可访问性状态；禁用项不能点击或获得键盘焦点。

## 3. 菜单几何与定位

- 鼠标最小行高 **32px**，触控 **44px**；长标题最多两行，自然增加高度。
- 外内边距 4px，行内水平 8px，20px 图标列＋8px 间隙，图标 16px。普通项、勾选项使用同一文字起点；快捷键独立右列，窄窗可省略。
- 宽度按内容在 200–360px 内选择；窗口更窄时缩至可用宽度，长菜单滚动。分组线高 9px。
- 按钮菜单位于按钮下方 4px；下方不足且上方足够时上翻。左右按锚点所在半屏对齐，四边保留 8px 安全距离。
- 使用 Navigator overlay 坐标换算，支持工作台缩放与窗口调整。测量在 `LayoutBuilder` 构建阶段完成，避免布局委托中读取其它渲染对象的尺寸。锚点消失时保留最后位置，失效页面不执行回调。
- `↑/↓` 跳过禁用项并循环移动焦点，`Enter/Space` 执行，`Escape`／点击外部关闭；键盘移动自动滚动到对应项目，关闭后由 Navigator 恢复原焦点。
- 打开菜单或弹窗时收起已有 tooltip；文件排序的后续菜单同样按按钮锚点定位，保留 4px 间隔。

## 4. 动效规则

| 类型 | 进入 | 退出 | 方式 |
|---|---:|---:|---|
| 菜单 | 140ms | 90ms | 整体淡入淡出，纵向 3px 轻移；尺寸始终完整 |
| 弹窗／选择器 | 180ms | 120ms | 整体淡入淡出，遮罩同步过渡 |
| Toast | 180ms | 120ms | Material 浮动提示过渡，统一时长 |
| 局部反馈 | 100ms | — | 紧凑状态变化与展开指示 |

进入使用 `easeOutCubic`，退出使用 `easeInCubic`。菜单采用有生命周期的 `CurvedAnimation`，进入尚未完成时反向关闭也不会切换曲线造成闪跳。尊重 `disableAnimations` 和 `accessibleNavigation`，共享菜单／弹窗／Toast 取消过渡。

`DialogRoute` 在当前 Flutter 版本忽略 `AnimationStyle.reverseDuration`，因此统一弹窗 route 明确覆写退出时长。菜单和弹窗返回 Future 时已完成退场；菜单的选项回调也在退场完成后执行，后续弹窗不会与旧菜单重叠。

## 5. 功能接入

```dart
WorkbenchMenuButton<String>(
  tooltip: '文件选项',
  itemBuilder: (_) => [
    const PopupMenuItem(value: 'new',
      child: MenuLabel('新建文件夹…', icon: Icons.create_new_folder_outlined)),
    const PopupMenuDivider(),
    CheckedPopupMenuItem(value: 'hidden', checked: showHidden,
      child: const MenuLabel('显示隐藏文件', icon: Icons.visibility_outlined)),
  ],
  onSelected: handleFileAction,
);
```

- `PopupMenuItem`、`CheckedPopupMenuItem` 是功能侧描述；实际布局由 `WorkbenchMenuEntry` 统一渲染，避免默认 `ListTile` 额外缩进与高度。
- 右键／长按沿用 `ContextArea`、`MenuItem`、`showMenuAt`；选择器沿用 `showPicker`；普通对话框使用 `showWorkbenchDialog`，简短输入使用 `askText`。
- 异步操作仍由功能自己的 `PopScope` 和 `barrierDismissible` 控制；输入 controller 由弹窗 State 管理，随 route 实际移除后销毁。
- 此轮接入文件、PDF、项目、Git、终端、AI、标签布局、代理和升级窗口；表单字段与原生系统文件选择器保留各自输入语义。

## 6. 验收与发布

`test/overlays_test.dart` 检查焦点循环、禁用与勾选语义、触控密度、退场顺序、动画中断、窄窗／滚动、锚点失效及减少动画；现有工作台回归检查未保存缓冲区、撤销、终端连接、AI 草稿及异步关闭保护。

`integration_test/overlays_test.dart` 使用正式 `AuroraApp`、合成内存数据和 Windows 原生窗口，记录深浅色菜单中间帧、勾选项、菜单接输入弹窗、窄窗、150% 缩放与减少动画。

历史候选后缀为 `ui-polish-preview3`，从正式 `lib/main.dart` 构建 Release，沿用已验签的 3.19.0 后端；使用包内“启动验收版.cmd”启动独立配置和实例。3.20.0 正式包包含本轮改动并重建同版本签名后端。实际验收结果与产物摘要记录在 `PLAN.md` 和 `docs/performance/20261115-ui-polish.json`。

相关回归 184 项通过，静态分析零问题。Windows Profile 原生交互 16 秒通过，已检查 16 个截图场景，包括深浅色完整菜单、勾选状态、菜单进入／退出、弹窗进入／输入、工作台菜单、窄窗、150% 缩放及减少动画；未保存文本、撤销／重做与同一终端流保留。原生测试使用合成数据和输入通道。
