# Aurora 客户端开发约定

## GUI 统一入口

- 新增及修改功能 GUI 使用 `package:aurora/ui/aurora_ui.dart`；基础组件在 `lib/ui` 实现。功能代码不要直接 import/export `package:flutter/material.dart`。
- 沿用 `Ide`／`Space`／`Radii`／`UiMetrics`／`UiMotion` 的语义 tokens。新增通用交互先进入组件层，并在设置 → 外观 → 统一组件展示接入。
- 按钮、字段、对话框使用统一入口导出的同名控件；图标操作使用 `IconBtn`；列表使用 `TreeRow`／`PickerRow`；工具栏和面板优先使用 `UiToolbar`／`UiPanel`。
- 浮层使用 `showWorkbenchDialog`／`showWorkbenchMenu`／`showPicker`，保留缩放坐标、焦点恢复、减少动画及退出生命周期。
- 长列表按需构建；等高列表提供 `itemExtent` 或 `prototypeItem`，避免跳到末尾时遍历全部项目。触控最小目标 44 逻辑像素；文本放大时允许换行和滚动。
- 状态属于文档／工作区／功能模型。重建组件、切换主题／缩放和隐藏页面不得重建编辑器、终端连接或丢弃草稿。
- 不替换 Material 的 IME、文本选择、焦点及语义实现。统一控件的调用方 key 指向实际交互节点；Widget 测试可通过 Material 类型检查底层节点。

使用规范与示例：`../docs/development/gui.md`。文档修改遵循 `../docs/standards/documentation.md`，从 `../docs/README.md` 查当前说明。

## 验证

在 `app` 目录运行：

```text
dart tool/ui_contract.dart
flutter analyze --no-pub --no-fatal-infos
flutter test --no-pub --reporter expanded
```

GUI 组件改动至少覆盖 `test/unified_ui_test.dart` 及受影响功能；全项目检查入口为 `../tools/check.ps1`。原生帧预算检查使用 `tool/gui_audit.ps1 -Suite foundation`，运行期间不修改客户端源码。
