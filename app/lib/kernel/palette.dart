// The command palette (Ctrl+Shift+P): every command of every available
// feature, plus the shell's own, filtered as you type. Arrow keys and Enter
// work; so does a tap.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/ide_theme.dart';
import 'feature.dart';
import 'widgets.dart';

/// Opens the palette over [context]; runs the chosen command.
Future<void> showPalette(BuildContext context, List<Command> commands) async {
  final chosen = await showPicker<Command>(context, maxWidth: 600, builder: (_) => _Palette(commands: commands));
  if (chosen != null) await chosen.run();
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

  /// A command matches when every typed character appears in order in
  /// "group title" (a subsequence match), ranked by earliest start.
  List<Command> get _shown {
    final q = _text.text.trim().toLowerCase();
    final list = widget.commands.where((c) => c.enabled?.call() ?? true).toList();
    if (q.isEmpty) return list;
    final scored = <(int, Command)>[];
    for (final c in list) {
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
      if (ok) scored.add((first + (hay.contains(q) ? -100 : 0), c));
    }
    scored.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final s in scored) s.$2];
  }

  void _move(int d, int n) {
    if (n == 0) return;
    setState(() => _index = (_index + d + n) % n);
    WidgetsBinding.instance.addPostFrameCallback((_) => revealPickerRow(_scroll, _index));
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final shown = _shown;
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
                  return PickerRow(
                    selected: i == _index,
                    onTap: () => Navigator.pop(context, c),
                    child: Row(children: [
                      SizedBox(width: 26, child: Icon(c.icon ?? Icons.chevron_right_rounded, size: 16, color: i == _index ? ide.text : ide.textDim)),
                      Expanded(child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: ide.text))),
                      const SizedBox(width: Space.m),
                      Text(c.group, style: TextStyle(fontSize: 12, color: ide.textFaint)),
                      if (c.shortcut != null) ...[const SizedBox(width: Space.m), KeyCaps(c.shortcut!)],
                    ]),
                  );
                },
              ),
      ),
    ]);
  }
}
