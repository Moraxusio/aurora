// The command palette (Ctrl+Shift+P): every command of every available
// feature, plus the shell's own, filtered as you type. Arrow keys and Enter
// work; so does a tap.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/ide_theme.dart';
import 'feature.dart';
import 'widgets.dart';

/// The commands run most recently, newest first. Kept for the life of the
/// process: the palette opens on what was used last instead of an arbitrary
/// first entry.
class RecentCommands {
  static final List<String> _ids = [];
  static const _max = 12;

  static List<String> get ids => List.unmodifiable(_ids);

  static void used(String id) {
    _ids.remove(id);
    _ids.insert(0, id);
    if (_ids.length > _max) _ids.removeRange(_max, _ids.length);
  }

  static void clear() => _ids.clear();
}

/// Commands that are for fixing the app, not for working in it: they come last
/// so a bare Enter never runs one by accident.
const _tailIds = {'diagnostics.copyGui'};

/// The order the palette shows. With nothing typed: what was used last, then the
/// rest in their own order, diagnostics at the end. With a query: every command
/// whose letters appear in order in "group title", a whole-text hit first, then
/// the earliest match.
List<Command> rankCommands(List<Command> commands, String query, {List<String>? recent}) {
  final list = commands.where((c) => c.enabled?.call() ?? true).toList();
  final q = query.trim().toLowerCase();
  if (q.isEmpty) {
    final order = recent ?? RecentCommands.ids;
    int rank(Command c) {
      if (_tailIds.contains(c.id)) return 1 << 20;
      final i = order.indexOf(c.id);
      return i < 0 ? 1 << 10 : i;
    }

    // a stable sort: commands of equal rank keep the order they came in
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      final r = rank(a.$2).compareTo(rank(b.$2));
      return r != 0 ? r : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }
  final scored = <(int, int, Command)>[];
  for (var n = 0; n < list.length; n++) {
    final c = list[n];
    final hay = '${c.group} ${c.title}'.toLowerCase();
    var at = -1, first = -1, ok = true;
    for (final ch in q.split('')) {
      if (ch == ' ') continue;
      at = hay.indexOf(ch, at + 1);
      if (at < 0) {
        ok = false;
        break;
      }
      first = first < 0 ? at : first;
    }
    if (ok) {
      final tail = _tailIds.contains(c.id) ? 1000 : 0;
      scored.add((first + (hay.contains(q) ? -100 : 0) + tail, n, c));
    }
  }
  scored.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [for (final s in scored) s.$3];
}

/// The icon of a command: its own, else one for its group, else a quiet dot.
/// Never a chevron: that reads as "expands".
IconData commandIcon(Command c) => c.icon ?? groupIcon(c.group);

IconData groupIcon(String group) => switch (group) {
      '服务器' => Icons.dns_outlined,
      '视图' => Icons.visibility_outlined,
      '外观' => Icons.palette_outlined,
      '终端' => Icons.terminal,
      '文件' => Icons.folder_outlined,
      '搜索' => Icons.search,
      'Git' => Icons.fork_right,
      'AI 助手' => Icons.auto_awesome_outlined,
      '诊断' => Icons.bug_report_outlined,
      '设置' => Icons.settings_outlined,
      '标签与布局' => Icons.view_quilt_outlined,
      '本机' => Icons.computer_outlined,
      '监控' => Icons.monitor_heart_outlined,
      '代理' => Icons.alt_route,
      _ => Icons.circle_outlined,
    };

/// Fixed width of the group column, so the groups and the key caps line up in
/// every row instead of following the length of each title.
const double _groupWidth = 76;
const double _keysWidth = 132;

/// Opens the palette over [context]; runs the chosen command.
Future<void> showPalette(BuildContext context, List<Command> commands) async {
  final chosen = await showPicker<Command>(context, maxWidth: 640, builder: (_) => _Palette(commands: commands));
  if (chosen != null) {
    RecentCommands.used(chosen.id);
    await chosen.run();
  }
}

class _Palette extends StatefulWidget {
  final List<Command> commands;
  const _Palette({required this.commands});
  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() => _index = 0));
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _move(int d, int n) {
    if (n == 0) return;
    setState(() => _index = (_index + d + n) % n);
    WidgetsBinding.instance.addPostFrameCallback((_) => revealPickerRow(_scroll, _index));
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final shown = rankCommands(widget.commands, _text.text);
    if (_index >= shown.length) _index = shown.isEmpty ? 0 : shown.length - 1;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1, shown.length),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1, shown.length),
          const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
        },
        child: PickerField(
          controller: _text,
          focusNode: _focus,
          icon: Icons.keyboard_command_key,
          hint: '输入命令…',
          onSubmitted: (_) {
            if (shown.isNotEmpty) Navigator.pop(context, shown[_index]);
          },
        ),
      ),
      const Divider(),
      Flexible(
        child: shown.isEmpty
            ? Padding(padding: const EdgeInsets.all(Space.xxl), child: Text('没有匹配的命令', style: TextStyle(color: ide.textDim)))
            : ListView.builder(
                controller: _scroll,
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: Space.s),
                itemExtent: PickerRow.height,
                itemCount: shown.length,
                itemBuilder: (_, i) {
                  final c = shown[i];
                  // The pointer moves the one highlight; a second, hover-only
                  // colour would leave two rows lit.
                  return MouseRegion(
                    onHover: (_) {
                      if (_index != i) setState(() => _index = i);
                    },
                    child: PickerRow(
                      followsPointer: true,
                      selected: i == _index,
                      onTap: () => Navigator.pop(context, c),
                      child: Row(children: [
                        SizedBox(width: 26, child: Icon(commandIcon(c), size: 16, color: i == _index ? ide.text : ide.textDim)),
                        Expanded(child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: ide.text))),
                        const SizedBox(width: Space.m),
                        SizedBox(width: _groupWidth, child: Text(c.group, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: ide.textFaint))),
                        const SizedBox(width: Space.m),
                        SizedBox(width: _keysWidth, child: Align(alignment: Alignment.centerRight, child: c.shortcut == null ? null : FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: KeyCaps(c.shortcut!)))),
                      ]),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}
