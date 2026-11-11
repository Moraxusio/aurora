// The settings page: this client's appearance and editor choices. They are
// kept in the sealed profile with the servers, and apply to every server.
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/material.dart';

import '../kernel/editor_tab.dart';
import '../kernel/widgets.dart';
import '../state/app_state.dart';
import '../theme/ide_theme.dart';

EditorTab settingsTab(AppState app) =>
    EditorTab(id: 'settings', title: '设置', icon: Icons.settings_outlined, builder: (_) => SettingsPage(app: app));

class SettingsPage extends StatelessWidget {
  final AppState app;
  const SettingsPage({super.key, required this.app});

  Future<void> _set(void Function(EditorSettings s) f) async {
    if (!app.ready) return Toast.show('配置文件不可用，设置无法保存', error: true);
    try {
      await app.update((p) => f(p.editor));
    } on Object catch (e) {
      Toast.show('保存设置失败：$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final s = app.ready ? app.profile.editor : EditorSettings();
        Widget row(String title, String? sub, Widget control) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title),
                    if (sub != null) Text(sub, style: TextStyle(color: ide.textDim, fontSize: 12)),
                  ]),
                ),
                control,
              ]),
            );
        Widget section(String t) => Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 4),
              child: Text(t, style: Theme.of(context).textTheme.titleSmall),
            );
        return Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(padding: const EdgeInsets.all(24), children: [
              Text('设置', style: Theme.of(context).textTheme.titleLarge),
              Text('只保存在这台电脑上，对所有服务器生效。', style: TextStyle(color: ide.textDim, fontSize: 12)),
              section('外观'),
              row(
                '主题',
                null,
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'system', label: Text('跟随系统')),
                    ButtonSegment(value: 'light', label: Text('浅色')),
                    ButtonSegment(value: 'dark', label: Text('深色')),
                  ],
                  selected: {s.theme},
                  onSelectionChanged: (v) => _set((e) => e.theme = v.first),
                ),
              ),
              section('编辑器'),
              row(
                '字号',
                '${s.fontSize.toStringAsFixed(s.fontSize % 1 == 0 ? 0 : 1)} 像素',
                SizedBox(
                  width: 240,
                  child: Slider(
                    value: s.fontSize,
                    min: EditorSettings.minFont,
                    max: EditorSettings.maxFont,
                    divisions: ((EditorSettings.maxFont - EditorSettings.minFont) * 2).round(),
                    label: s.fontSize.toStringAsFixed(1),
                    onChanged: (v) => _set((e) => e.fontSize = v),
                  ),
                ),
              ),
              row('自动换行', '长行折到下一行显示，不改变文件内容。单个文件可以用 Alt+Z 切换。',
                  Switch(value: s.wordWrap, onChanged: (v) => _set((e) => e.wordWrap = v))),
              row(
                '缩进空格数',
                '按 Tab 插入的空格数。之后打开的文件生效。',
                SegmentedButton<int>(
                  segments: const [ButtonSegment(value: 2, label: Text('2')), ButtonSegment(value: 4, label: Text('4')), ButtonSegment(value: 8, label: Text('8'))],
                  selected: {s.tabSize},
                  onSelectionChanged: (v) => _set((e) => e.tabSize = v.first),
                ),
              ),
              section('快捷键'),
              for (final (k, v) in const [
                ('Ctrl+P', '按文件名打开'),
                ('Ctrl+Shift+F', '在文件中搜索'),
                ('Ctrl+Shift+P', '命令面板'),
                ('Ctrl+S', '保存'),
                ('Ctrl+F / Ctrl+H', '查找 / 替换'),
                ('Ctrl+G', '转到行'),
                ('Alt+Z', '切换自动换行'),
                ('Ctrl+\\', '向右拆分编辑器'),
                ('Ctrl+W', '关闭标签'),
                ('Ctrl+Tab', '下一个标签'),
                ('Ctrl+B', '显示或隐藏侧栏'),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    SizedBox(width: 160, child: Text(k, style: TextStyle(fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: 12.5))),
                    Text(v, style: TextStyle(color: ide.textDim)),
                  ]),
                ),
            ]),
          ),
        );
      },
    );
  }
}
