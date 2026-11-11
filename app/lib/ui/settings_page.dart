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
        return FormPage(
          title: '设置',
          subtitle: '只保存在这台电脑上，对所有服务器生效。',
          children: [
            FormSection(title: '外观', children: [
              Padding(
                padding: const EdgeInsets.all(Space.l + 2),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('主题', style: TextStyle(fontSize: 13, color: ide.text)),
                  const SizedBox(height: Space.m + 2),
                  Wrap(spacing: Space.l, runSpacing: Space.l, children: [
                    for (final (v, label) in const [('system', '跟随系统'), ('light', '浅色'), ('dark', '深色')])
                      _ThemeCard(value: v, label: label, selected: s.theme == v, onTap: () => _set((e) => e.theme = v)),
                  ]),
                ]),
              ),
            ]),
            FormSection(title: '编辑器', children: [
              FormRow(
                title: '字号',
                subtitle: '编辑器和终端的文字大小',
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    width: 200,
                    child: Slider(
                      value: s.fontSize,
                      min: EditorSettings.minFont,
                      max: EditorSettings.maxFont,
                      divisions: ((EditorSettings.maxFont - EditorSettings.minFont) * 2).round(),
                      onChanged: (v) => _set((e) => e.fontSize = v),
                    ),
                  ),
                  Container(
                    width: 52,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: ide.input, borderRadius: BorderRadius.circular(Radii.s), border: Border.all(color: ide.border)),
                    child: Text('${s.fontSize.toStringAsFixed(s.fontSize % 1 == 0 ? 0 : 1)} px', style: TextStyle(fontSize: 12, color: ide.text)),
                  ),
                ]),
              ),
              FormRow(
                title: '自动换行',
                subtitle: '长行折到下一行显示，不改变文件内容。单个文件可以用 Alt+Z 切换。',
                trailing: SmallSwitch(value: s.wordWrap, onChanged: (v) => _set((e) => e.wordWrap = v)),
              ),
              FormRow(
                title: '缩进空格数',
                subtitle: '按 Tab 插入的空格数。之后打开的文件生效。',
                trailing: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [ButtonSegment(value: 2, label: Text('2')), ButtonSegment(value: 4, label: Text('4')), ButtonSegment(value: 8, label: Text('8'))],
                  selected: {s.tabSize},
                  onSelectionChanged: (v) => _set((e) => e.tabSize = v.first),
                ),
              ),
            ]),
            FormSection(title: '快捷键', children: [
              for (final (k, v) in const [
                ('Ctrl+P', '按文件名打开'),
                ('Ctrl+Shift+F', '在文件中搜索'),
                ('Ctrl+Shift+P', '命令面板'),
                ('Ctrl+S', '保存'),
                ('Ctrl+F', '查找'),
                ('Ctrl+H', '替换'),
                ('Ctrl+G', '转到行'),
                ('Alt+Z', '切换自动换行'),
                ('Ctrl+\\', '向右拆分编辑器'),
                ('Ctrl+W', '关闭标签'),
                ('Ctrl+Tab', '下一个标签'),
                ('Ctrl+B', '显示或隐藏侧栏'),
              ])
                FormRow(title: v, trailing: KeyCaps(k)),
            ]),
          ],
        );
      },
    );
  }
}

/// A theme choice drawn as a small picture of the window in that theme.
class _ThemeCard extends StatelessWidget {
  final String value, label;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeCard({required this.value, required this.label, required this.selected, required this.onTap});

  Widget _mini(Ide c) => Container(
        color: c.frame,
        padding: const EdgeInsets.all(5),
        child: Row(children: [
          Column(children: [
            for (var i = 0; i < 4; i++)
              Container(width: 8, height: 8, margin: const EdgeInsets.only(bottom: 4), decoration: BoxDecoration(color: i == 0 ? c.accent : c.textFaint.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(2))),
          ]),
          const SizedBox(width: 5),
          Container(
            width: 34,
            decoration: BoxDecoration(color: c.sideBar, borderRadius: BorderRadius.circular(3), border: Border.all(color: c.border)),
            padding: const EdgeInsets.all(4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final w in [20.0, 14.0, 22.0, 12.0])
                Container(width: w, height: 3, margin: const EdgeInsets.only(bottom: 4), color: c.textFaint.withValues(alpha: 0.6)),
            ]),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: c.editor, borderRadius: BorderRadius.circular(3), border: Border.all(color: c.border)),
              padding: const EdgeInsets.all(5),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final (w, col) in [(30.0, c.accent), (44.0, c.textDim), (22.0, c.ok), (36.0, c.textDim)])
                  Container(width: w, height: 3, margin: const EdgeInsets.only(bottom: 5), color: col.withValues(alpha: 0.8)),
              ]),
            ),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final picture = switch (value) {
      'light' => _mini(Ide.light),
      'dark' => _mini(Ide.dark),
      _ => Row(children: [
          Expanded(child: ClipRect(child: OverflowBox(alignment: Alignment.centerLeft, maxWidth: 136, minWidth: 136, child: _mini(Ide.light)))),
          Expanded(child: ClipRect(child: OverflowBox(alignment: Alignment.centerRight, maxWidth: 136, minWidth: 136, child: _mini(Ide.dark)))),
        ]),
    };
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Column(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 136,
            height: 84,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.l + 2),
              border: Border.all(color: selected ? ide.accent : ide.border, width: selected ? 2 : 1),
            ),
            child: picture,
          ),
          const SizedBox(height: Space.s + 1),
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (selected) ...[Icon(Icons.check_circle_rounded, size: 14, color: ide.accent), const SizedBox(width: 4)],
            Text(label, style: TextStyle(fontSize: 12.5, color: selected ? ide.text : ide.textDim, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
          ]),
        ]),
      ),
    );
  }
}
