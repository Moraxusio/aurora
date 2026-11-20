# Aurora 统一 GUI 组件

> 类型：开发规范 | 状态：生效 | 维护：客户端维护者 | 更新：2026-11-16
> 适用：3.22.0 源码及后续 GUI 开发

所有功能页和工作台共用 **`package:aurora/ui/aurora_ui.dart`**。设置 → 外观 → **统一组件展示** 是生产组件的交互目录，包含按钮、字段、表单、通知、快捷键和 10,000 行虚拟列表。

## 结构与视觉

| 文件 | 职责 |
|---|---|
| `app/lib/ui/aurora_ui.dart` | 公开入口、布局原语和统一控件 |
| `controls.dart` | 主要／次要／轻量／tonal 按钮、输入框、可滚动对话框 |
| `workbench_components.dart` | 行、表单、图标按钮、开关、通知、选择器和上下文菜单 |
| `panels.dart` | 可换行工具栏、共享滚动面板、虚拟列表 |
| `component_gallery.dart` | 可操作的组件目录 |
| `theme/ide_theme.dart` | 明暗语义色、字体、间距与 Material 主题 |
| `theme/workbench_tokens.dart` | 密度、圆角、尺寸和减少动画规则 |
| `kernel/overlays.dart` | 统一浮层、缩放坐标、焦点和退出时序 |

视觉采用紧凑中性 IDE：连续内容表面、细分隔线、蓝色焦点与主操作；错误／成功／警告同时通过图标和文字表达。正文、编辑器、侧栏、选中态分别使用 `Ide` 的语义颜色。界面字号默认 13，代码使用等宽字体；间距沿用 4px 主网格。

工作台工具使用 `UiNavigationItem`（常显名称、选中语义、键盘激活）和 `UiPanelHeader`（标题、上下文、可换行操作）。两者已接入统一组件展示。侧栏按 Workspace 保活，连接状态作为独立可见性门；功能需要自己监听连接变化并隔离迟到回执，不能依赖重建页面刷新数据。

### 密度与布局

| 组件 | 鼠标基准 | 触控基准 |
|---|---:|---:|
| 普通树／列表行、图标按钮 | 28 | 44 |
| 文本按钮 | 32 | 44 |
| 选择器行 | 34 | ≥44 |
| 输入框 | 主题内边距 | ≥44 |
| 浮层菜单 | 32 | 44 |

数值为逻辑像素。`InputMode` 根据最近输入方式切换；选择器行另按文字缩放计算行高。工作台缩放使用 `WorkbenchScale`，不改变编辑控件身份。

表单在窄宽度或较大文字下上下排列；通知操作放在正文下方。工具栏、拥挤的区段操作允许换行。空状态和面板内容可滚动，极矮面板仍可到达操作。对话框内容可滚动，操作区由 Material `OverflowBar` 自动排列。

## 功能接入

```dart
import 'package:aurora/ui/aurora_ui.dart';

UiPanel(
  title: '项目检查',
  description: '运行结果属于工作区模型',
  actions: [
    FilledButton.icon(
      icon: const Icon(Icons.play_arrow),
      label: const Text('运行'),
      busy: model.running,
      onPressed: model.run,
    ),
    OutlinedButton(
      onPressed: model.running ? model.cancel : null,
      child: const Text('取消'),
    ),
  ],
  notice: model.error == null
      ? null
      : Notice(tone: Tone.error, title: '执行失败', body: model.error),
  slivers: [
    SliverList.builder(
      itemCount: model.results.length,
      itemBuilder: (_, index) => TreeRow(
        label: model.results[index].title,
        subtitle: model.results[index].detail,
        onTap: () => model.openResult(index),
      ),
    ),
  ],
);
```

### 基础控件

- `FilledButton`：主操作；`OutlinedButton`：次要操作；`TextButton`：轻量操作；`.icon` 和 `.tonalIcon` 支持图标。`busy: true` 同时禁止点击和长按，显示进度。
- `TextField`：保留 controller、焦点、IME、格式化、组合输入、选择菜单及内容插入。密码、只读、多行／展开等沿用熟悉的参数。
- `IconBtn`：必须提供 tooltip，同时提供语义名称；支持 Tab、Enter／Space、禁用状态和可见焦点边框。
- `TreeRow`／`PickerRow`：选中态有对应语义。带副标题的行自然扩展，不使用固定单行高度压缩说明。
- `FormPage`／`FormSection`／`FormRow`：设置与信息页；`SmallSwitch` 为密集行开关，触控时保留完整点击目标。
- `Notice`／`EmptyHint`：反馈与空状态。错误文字可选择，操作允许重试；模型负责保留草稿与失败状态。

底层仍构建真正的 Material 控件，因此系统输入法、辅助功能和平台文本编辑行为继续可用。调用方 key 转交实际控件节点；现有 Widget 测试使用 Material `TextField`／`FilledButton` 类型或 key 能继续访问实际交互节点。

### 长列表

```dart
UiVirtualList(
  controller: scroll,
  itemCount: items.length,
  itemExtent: PickerRow.heightOf(context),
  itemBuilder: (_, index) => PickerRow(
    selected: index == selected,
    onTap: () => select(index),
    child: Text(items[index], maxLines: 1, overflow: TextOverflow.ellipsis),
  ),
);
```

**等高长列表必须提供 `itemExtent` 或 `prototypeItem`。** 普通 builder 只保证首次构建懒加载；未知行高时，跳到远端可能测量中间全部行。可变高度内容使用普通 builder，避免建立包含全部项目的 `Column`。组件目录采用固定高度 sliver；回归同时验证首次构建和跳到第 10,000 行。

### 浮层与状态所有权

- 对话框：`showWorkbenchDialog` + `AlertDialog`；复杂编辑器可用 `Dialog` 和有界布局。
- 菜单：`WorkbenchMenuButton`／`showWorkbenchMenu`；右键和长按用 `ContextArea`（右键在释放并赢得手势后触发）。文件等菜单可用 `MenuItem(…, quick: true)` 放置可聚焦的快捷图标，用 `MenuItem.more` 在当前菜单关闭后打开分组，避免菜单叠放。
- 简短输入／确认：`askText`／`confirmDialog`。不要在功能中直接调用 `showDialog` 或 `showMenu`。
- 请求必须核对连接、版本与生命周期。异步关闭要取消 operation，迟到结果不得重写新状态。
- 文档、终端、任务及 AI 会话状态归工作区模型；组件 State 仅管理视图状态和自身 controller。缩放、主题、停靠或隐藏不触发重连。
- 只在菜单中使用的当前文档等上下文，在菜单打开时查询；不要为了更新一个未打开的菜单重建会话正文或整个页面。
- 本地保活 Overlay 与独立 Semantics 边界继续由工作台管理，避免原生辅助功能树引用已移除节点。

## 检查与维护

```powershell
# app/
dart tool/ui_contract.dart
flutter test --no-pub test/unified_ui_test.dart test/overlays_test.dart

# 仓库根目录：全项目检查，可加 -Native -NativeOut <新目录>
powershell -File tools/check.ps1

# app/：原生帧预算验收，使用新的隔离输出目录
./tool/gui_audit.ps1 -Suite foundation -Out <新目录>

# 仅定位热点：采样会影响性能，Baseline 关闭预算，结果不能作为验收通过
./tool/gui_audit.ps1 -Suite foundation -Baseline -TraceCPU -Out <诊断新目录>
```

导入／浮层约束已接入正式 Windows、GUI 验收包、Android 打包入口以及原生 GUI 审计入口。`app/AGENTS.md` 同时约束以后新增页面。`kernel/widgets.dart` 是旧导入的兼容导出；新页面使用公开入口。

回归覆盖明暗主题、360／1280 宽、150% 工作台缩放与文字缩放、触控目标、键盘焦点、禁用／忙碌／选中语义、窄表单、极矮空状态、嵌套滚动弹窗和万行虚拟列表。基础记录见 [实施验收](../validation/2026-11-16-implementation.md)，最新工具面板、跨服务器／重连保持及原生结果见 [工作台重构验收](../validation/2026-11-16-workbench-redesign.md)。
