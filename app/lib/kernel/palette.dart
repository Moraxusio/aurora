// The command palette (Ctrl+Shift+P): every command of every available
// feature, plus the shell's own, filtered as you type. Arrow keys and Enter
// work; so does a tap.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/ide_theme.dart';
import 'feature.dart';

/// Opens the palette over [context]; runs the chosen command.
Future<void> showPalette(BuildContext context, List<Command> commands) async {
  final ide = Ide.of(context);
  final chosen = await showDialog<Command>(
    context: context,
    barrierColor: Colors.black38,
    builder: (c) => Align(
      alignment: const Alignment(0, -0.6),
      child: Material(
        color: ide.sideBar,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: ide.border)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 420),
          child: _Palette(commands: commands),
        ),
      ),
    ),
  );
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

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final shown = _shown;
    if (_index >= shown.length) _index = shown.isEmpty ? 0 : shown.length - 1;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => setState(() => _index = shown.isEmpty ? 0 : (_index + 1) % shown.length),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => setState(() => _index = shown.isEmpty ? 0 : (_index - 1 + shown.length) % shown.length),
            const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
          },
          child: TextField(
            controller: _text,
            focusNode: _focus,
            autofocus: true,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(hintText: '输入命令…', prefixIcon: Icon(Icons.keyboard_command_key, size: 18)),
            onSubmitted: (_) {
              if (shown.isNotEmpty) Navigator.pop(context, shown[_index]);
            },
          ),
        ),
      ),
      const Divider(),
      Flexible(
        child: shown.isEmpty
            ? Padding(padding: const EdgeInsets.all(20), child: Text('没有匹配的命令', style: TextStyle(color: ide.textDim)))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: shown.length,
                itemBuilder: (_, i) {
                  final c = shown[i];
                  return InkWell(
                    onTap: () => Navigator.pop(context, c),
                    child: Container(
                      height: 32,
                      color: i == _index ? ide.selection : null,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(children: [
                        SizedBox(width: 24, child: c.icon == null ? null : Icon(c.icon, size: 15, color: ide.textDim)),
                        Text('${c.group}：', style: TextStyle(color: ide.textDim)),
                        Expanded(child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        if (c.shortcut != null) Text(c.shortcut!, style: TextStyle(color: ide.textDim, fontSize: 11)),
                      ]),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}
