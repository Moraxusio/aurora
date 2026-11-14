import 'package:flutter/material.dart';

import '../features/ai/ai_settings_dialog.dart';
import '../kernel/editor_tab.dart';
import '../kernel/widgets.dart';
import '../state/app_state.dart';
import '../theme/ide_theme.dart';

EditorTab settingsTab(AppState app) => EditorTab(id: 'settings', title: '设置',
  icon: Icons.settings_outlined, builder: (_) => SettingsPage(app: app));

class SettingsPage extends StatefulWidget {
  final AppState app;
  const SettingsPage({super.key, required this.app});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _section = '外观', _query = '';
  final _scroll = ScrollController();
  final _search = TextEditingController();
  @override
  void dispose() { _scroll.dispose(); _search.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context), preferences = widget.app.appearance;
    return ListenableBuilder(listenable: preferences, builder: (context, _) {
      final p = preferences.value;
      final sections = <String, List<Widget>>{
        '外观': [
          _setting('颜色主题', '整个工作台即时切换。', Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (id, title, icon) in const [('system', '跟随系统', Icons.brightness_auto_outlined),
              ('dark', '深色', Icons.dark_mode_outlined), ('light', '浅色', Icons.light_mode_outlined)])
              OutlinedButton.icon(onPressed: () => preferences.set('theme', id),
                style: OutlinedButton.styleFrom(backgroundColor: p.theme == id ? ide.accentSoft : null,
                  side: BorderSide(color: p.theme == id ? ide.accent : ide.borderStrong)),
                icon: Icon(icon, size: 16), label: Text(title)),
          ])),
          _setting('界面缩放', '菜单、标签、文件树和面板同步缩放。Ctrl + / −，Ctrl+0 还原。',
            NumberSetting(id: 'uiScale', value: p.uiScale * 100, min: 80, max: 150, step: 5, unit: '%',
              onChanged: (v) => preferences.set('uiScale', v / 100), onEnd: preferences.flush)),
          _setting('实时预览', '拖动字号控件即可看到变化；停止调整后自动保存。',
            Container(width: double.infinity, padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: ide.sideBar, border: Border.all(color: ide.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Aurora · 专注于工作', style: TextStyle(color: ide.text, fontSize: 14)),
                const SizedBox(height: 8),
                Text('const ready = true;  // 编辑器预览', style: TextStyle(color: ide.accent,
                  fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: p.editorFont)),
                const SizedBox(height: 8),
                Text('PS C:\\project> 终端已就绪', style: TextStyle(color: ide.textDim,
                  fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback, fontSize: p.terminalFont)),
              ]))),
        ],
        '文字与编辑器': [
          _setting('编辑器字号', '已打开的文件即时生效，保留光标、未保存内容与撤销记录。',
            NumberSetting(id: 'editorFont', value: p.editorFont, onChanged: (v) => preferences.set('editorFont', v), onEnd: preferences.flush)),
          _setting('终端字号', '直接调整现有终端，不重新连接。',
            NumberSetting(id: 'terminalFont', value: p.terminalFont, onChanged: (v) => preferences.set('terminalFont', v), onEnd: preferences.flush)),
          _setting('AI 对话字号', '对话正文与输入框同步变化，保持当前阅读位置。',
            NumberSetting(id: 'chatFont', value: p.chatFont, onChanged: (v) => preferences.set('chatFont', v), onEnd: preferences.flush)),
          _setting('自动换行', '长行折到下一行。单个文件可用 Alt+Z 切换。',
            Align(alignment: Alignment.centerLeft, child: SmallSwitch(value: p.wordWrap, onChanged: (v) => preferences.set('wordWrap', v)))),
          _setting('缩进空格数', '之后打开的文件生效。',
            Wrap(spacing: 8, children: [for (final n in [2, 4, 8]) ChoiceChip(label: Text('$n'),
              selected: p.tabSize == n, onSelected: (_) => preferences.set('tabSize', n))])),
        ],
        'AI 助手': [
          _setting('模型与提供商', '管理模型、协议、API Key 和推理强度。',
            Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(
              onPressed: () => showAiSettingsDialog(context, app: widget.app),
              icon: const Icon(Icons.tune, size: 16), label: const Text('管理模型与密钥')))),
          _setting('AI 对话字号', '所有已打开的对话即时更新。', NumberSetting(id: 'chatFont', value: p.chatFont,
            onChanged: (v) => preferences.set('chatFont', v), onEnd: preferences.flush)),
        ],
        '操作与快捷键': [
          _setting('鼠标拖放', '拖动标签重排；拖到另一栏移入；正文方向标记或边缘创建分屏。Escape 取消。',
            const Text('中键关闭标签 · 双击标签放大 / 还原视图\n拖动分隔线调整大小 · 双击分隔线均分', style: TextStyle(height: 1.8))),
          for (final (keys, title) in const [
            ('Ctrl+P', '快速打开文件'), ('Ctrl+Shift+P', '命令面板'), ('Ctrl+,', '设置'),
            ('Ctrl+S', '保存'), ('Ctrl+F', '查找'), ('Ctrl+H', '替换'),
            ('Ctrl+\\', '向右分屏'), ('Ctrl+Shift+\\', '向下分屏'),
            ('Ctrl+W', '关闭标签'), ('Ctrl+Tab', '下一个标签'), ('Ctrl+B', '切换文件侧栏'),
            ('Ctrl+J', '切换终端'), ('Ctrl+Alt+I', '切换 AI'), ('Alt+↑ / ↓', '上一条 / 下一条消息'),
            ('Ctrl+ / Ctrl−', '界面缩放'), ('Ctrl+0', '还原缩放'),
          ]) _setting(title, keys, Align(alignment: Alignment.centerLeft, child: KeyCaps(keys))),
        ],
      };
      return LayoutBuilder(builder: (_, box) {
        final wide = box.maxWidth >= 720;
        final groups = _query.isEmpty ? [_section] : sections.keys.toList();
        final content = ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(28, 20, 28, 36), children: [
          for (final group in groups) ...[
            Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(group,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: ide.text))),
            ...sections[group]!,
          ],
        ]);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ide.border))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Text('设置', style: TextStyle(fontSize: 22, color: ide.text, fontWeight: FontWeight.w500)),
                const Spacer(), Text(preferences.error ?? (preferences.unsaved ? '正在保存…' : '本机 · 自动保存'),
                  style: TextStyle(fontSize: 11, color: preferences.error == null ? ide.textDim : ide.error)),
                if (preferences.error != null) TextButton(onPressed: preferences.flush, child: const Text('重试'))]),
              const SizedBox(height: 14),
              TextField(key: const ValueKey('settings-search'), controller: _search, onChanged: (q) => setState(() => _query = q.trim().toLowerCase()),
                decoration: const InputDecoration(hintText: '搜索设置', prefixIcon: Icon(Icons.search, size: 18))),
              if (!wide) ...[const SizedBox(height: 12), SingleChildScrollView(scrollDirection: Axis.horizontal,
                child: Row(children: [for (final section in sections.keys) _category(section)]))],
            ])),
          Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (wide) Container(width: 172, padding: const EdgeInsets.only(top: 16),
              decoration: BoxDecoration(border: Border(right: BorderSide(color: ide.border))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final section in sections.keys) _category(section)])),
            Expanded(child: content),
          ])),
        ]);
      });
    });
  }

  Widget _category(String name) {
    final ide = Ide.of(context), selected = name == _section;
    return InkWell(onTap: () { setState(() { _section = name; _query = ''; _search.clear(); }); if (_scroll.hasClients) _scroll.jumpTo(0); },
      child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(color: selected ? ide.selection : null,
          border: Border(left: BorderSide(color: selected ? ide.accent : Colors.transparent, width: 2))),
        child: Text(name, style: TextStyle(fontSize: 13, color: selected ? ide.text : ide.textDim))));
  }

  Widget _setting(String title, String detail, Widget control) {
    if (_query.isNotEmpty && !'$title $detail'.toLowerCase().contains(_query)) return const SizedBox.shrink();
    final ide = Ide.of(context);
    return Padding(padding: const EdgeInsets.only(bottom: 26), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ide.text)),
      const SizedBox(height: 5), Text(detail, style: TextStyle(fontSize: 12, color: ide.textDim, height: 1.5)),
      const SizedBox(height: 12), control,
    ]));
  }
}

/// Precise typing, arrow buttons and dragging all share the same live value.
class NumberSetting extends StatefulWidget {
  final String id, unit;
  final double value, min, max, step;
  final ValueChanged<double> onChanged;
  final VoidCallback? onEnd;
  const NumberSetting({super.key, required this.id, required this.value, required this.onChanged,
    this.onEnd, this.min = 9, this.max = 28, this.step = .5, this.unit = 'px'});
  @override
  State<NumberSetting> createState() => _NumberSettingState();
}

class _NumberSettingState extends State<NumberSetting> {
  late final _text = TextEditingController(text: _label(widget.value));
  final _focus = FocusNode();
  String _label(double value) => value.toStringAsFixed(value % 1 == 0 ? 0 : 1);
  @override
  void didUpdateWidget(NumberSetting old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || (!_focus.hasFocus && old.value != widget.value)) _text.text = _label(widget.value);
  }
  void _commit() {
    final n = double.tryParse(_text.text);
    if (n != null && n.isFinite) widget.onChanged(n.clamp(widget.min, widget.max));
    _focus.unfocus();
    _text.text = _label(n == null || !n.isFinite ? widget.value : n.clamp(widget.min, widget.max));
    widget.onEnd?.call();
  }
  @override
  void dispose() { _text.dispose(); _focus.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460),
    child: Row(children: [
      IconButton(tooltip: '减小${widget.unit == '%' ? '缩放' : '字号'}', icon: const Icon(Icons.remove, size: 16),
        onPressed: widget.value > widget.min ? () => widget.onChanged((widget.value - widget.step).clamp(widget.min, widget.max)) : null),
      Expanded(child: Slider(key: ValueKey('setting-${widget.id}'), value: widget.value.clamp(widget.min, widget.max), min: widget.min, max: widget.max,
        divisions: ((widget.max - widget.min) / widget.step).round(),
        onChanged: widget.onChanged, onChangeEnd: (_) => widget.onEnd?.call())),
      IconButton(tooltip: '增大${widget.unit == '%' ? '缩放' : '字号'}', icon: const Icon(Icons.add, size: 16),
        onPressed: widget.value < widget.max ? () => widget.onChanged((widget.value + widget.step).clamp(widget.min, widget.max)) : null),
      SizedBox(width: 76, child: TextField(key: ValueKey('setting-input-${widget.id}'), controller: _text, focusNode: _focus,
        keyboardType: const TextInputType.numberWithOptions(decimal: true), textAlign: TextAlign.center,
        onSubmitted: (_) => _commit(), onTapOutside: (_) { if (_focus.hasFocus) _commit(); },
        decoration: InputDecoration(suffixText: widget.unit, contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8)))),
    ]));
}
