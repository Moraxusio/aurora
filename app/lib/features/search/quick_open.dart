// Quick open (Ctrl+P): file names across the project, ranked by the agent
// (fs.find, fuzzy). Typing asks again after a short pause; Enter or a click
// opens the file. ":N" after the name opens it at line N.
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora/ui/aurora_ui.dart';
import 'package:flutter/services.dart';

import '../../kernel/feature.dart';
import '../../kernel/input_mode.dart';
import '../../kernel/palette.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import '../files/file_editor.dart';
import '../files/file_tree_row.dart';
import 'search_scope.dart';

class QuickOpenItem {
  final SearchFolder folder;
  final String path;
  const QuickOpenItem(this.folder, this.path);
}

/// "name:12" -> ("name", 12); a query without a line number has line null.
(String, int?) splitLine(String q) {
  final m = RegExp(r'^(.*?):(\d+)$').firstMatch(q.trim());
  if (m == null) return (q.trim(), null);
  return (m.group(1)!.trim(), int.tryParse(m.group(2)!));
}

/// Asks every folder for [query] and merges the answers in each folder's own
/// order (the agent ranks within one folder), folder by folder interleaved so
/// the best match of each comes first.
Future<List<QuickOpenItem>> findFiles(
  Link link,
  List<SearchFolder> folders,
  String query, {
  bool fresh = false,
  int max = 60,
}) async {
  final per = await Future.wait([
    for (final f in folders)
      link
          .call('fs.find', {
            'root': f.root,
            'path': f.path,
            'query': query,
            'max': max,
            'fresh': fresh,
          })
          .then<List<QuickOpenItem>>(
            (r) => [
              for (final p in ((r as Map)['files'] as List? ?? const []))
                QuickOpenItem(f, normalized(p as String)),
            ],
            onError: (Object _) => <QuickOpenItem>[],
          ),
  ]);
  final out = <QuickOpenItem>[];
  for (var i = 0; out.length < max; i++) {
    var any = false;
    for (final l in per) {
      if (out.length >= max) break;
      if (i < l.length) {
        out.add(l[i]);
        any = true;
      }
    }
    if (!any) break;
  }
  return out;
}

enum WorkbenchSearchMode { files, contents, commands }

Future<void> showQuickOpen(Workspace ws, {BuildContext? context}) async {
  final open = ws.openQuickSearch;
  if (open != null) {
    open();
    return;
  }
  final ctx = context ?? AppNavigation.context;
  if (ctx == null || ws.link == null) return;
  await showWorkbenchSearch(ctx, workspace: ws, fileSearch: true);
}

Future<void> showWorkbenchSearch(
  BuildContext context, {
  Workspace? workspace,
  bool fileSearch = false,
  ValueChanged<String>? onContents,
  VoidCallback? onPickerClosed,
  List<Command> commands = const [],
  WorkbenchSearchMode initialMode = WorkbenchSearchMode.files,
}) async {
  final _SearchChoice? chosen;
  try {
    chosen = await showPicker<_SearchChoice>(
      context,
      maxWidth: 620,
      topInset: 48,
      builder: (_) => WorkbenchSearchPicker(
        ws: fileSearch ? workspace : null,
        allowContents: onContents != null,
        commands: commands,
        initialMode: fileSearch ? initialMode : WorkbenchSearchMode.commands,
      ),
    );
  } finally {
    onPickerClosed?.call();
  }
  if (chosen == null || !context.mounted) return;
  switch (chosen) {
    case _CommandChoice(:final command):
      RecentCommands.used(command.id);
      await command.run();
    case _FileChoice(:final item, :final line, :final scope):
      if (workspace == null ||
          !identical(scope.$1, workspace.link) ||
          scope.$2 != workspace.projectGeneration)
        return;
      openFileAt(
        workspace,
        root: item.folder.root,
        path: item.path,
        line: line,
      );
    case _ContentChoice(:final query):
      onContents?.call(query);
  }
}

sealed class _SearchChoice {
  const _SearchChoice();
}

class _CommandChoice extends _SearchChoice {
  final Command command;
  const _CommandChoice(this.command);
}

class _FileChoice extends _SearchChoice {
  final QuickOpenItem item;
  final int? line;
  final (Link?, int?) scope;
  const _FileChoice(this.item, this.line, this.scope);
}

class _ContentChoice extends _SearchChoice {
  final String query;
  const _ContentChoice(this.query);
}

/// One picker, one text field, and separate drafts for the three scopes.
class WorkbenchSearchPicker extends StatefulWidget {
  final Workspace? ws;
  final List<SearchFolder>? folders;
  final List<Command> commands;
  final bool allowContents;
  final WorkbenchSearchMode initialMode;
  const WorkbenchSearchPicker({
    super.key,
    this.ws,
    this.folders,
    this.commands = const [],
    this.allowContents = false,
    this.initialMode = WorkbenchSearchMode.files,
  });
  @override
  State<WorkbenchSearchPicker> createState() => _WorkbenchSearchPickerState();
}

class _WorkbenchSearchPickerState extends State<WorkbenchSearchPicker> {
  final _text = TextEditingController();
  final _focus = FocusNode(debugLabel: 'workbench search');
  final _scroll = ScrollController();
  late WorkbenchSearchMode _mode = widget.initialMode;
  final _drafts = <WorkbenchSearchMode, TextEditingValue>{};
  List<QuickOpenItem> _items = [];
  List<SearchFolder>? _folders;
  int _index = 0;
  bool _loading = true;
  bool _first = true;
  bool _switching = false;
  String _lastText = '';
  int _gen = 0;
  Timer? _debounce;

  bool get _files => _mode == WorkbenchSearchMode.files;
  bool get _contents => _mode == WorkbenchSearchMode.contents;

  @override
  void initState() {
    super.initState();
    _folders = widget.folders;
    final retained = widget.ws?.searchQuery.text ?? '';
    _drafts[WorkbenchSearchMode.contents] = TextEditingValue(
      text: retained,
      selection: TextSelection(baseOffset: 0, extentOffset: retained.length),
    );
    _text.value = _drafts[_mode] ?? TextEditingValue.empty;
    _lastText = _text.text;
    _text.addListener(_changed);
    _scope = (widget.ws?.link, widget.ws?.projectGeneration);
    widget.ws?.addListener(_scopeChanged);
    if (_files) unawaited(_ask());
  }

  late (Link?, int?) _scope;

  void _scopeChanged() {
    final next = (widget.ws?.link, widget.ws?.projectGeneration);
    if (next == _scope) return;
    _scope = next;
    _gen++;
    _debounce?.cancel();
    setState(() {
      _items = [];
      _folders = widget.folders;
      _index = 0;
      _loading = _files;
      _first = true;
    });
    if (_files) unawaited(_ask());
  }

  void _changed() {
    if (_switching || _lastText == _text.text) return;
    _lastText = _text.text;
    setState(() {
      _index = 0;
      if (_files) {
        _gen++;
        _items = [];
        _loading = true;
      }
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (_files) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 120), _ask);
    }
  }

  void _selectMode(WorkbenchSearchMode mode) {
    if (_mode == mode) {
      _focus.requestFocus();
      return;
    }
    _gen++;
    _debounce?.cancel();
    _drafts[_mode] = _text.value.copyWith(composing: TextRange.empty);
    setState(() {
      _mode = mode;
      _index = 0;
      _items = [];
      _loading = _files;
      _switching = true;
      _text.value = _drafts[mode] ?? TextEditingValue.empty;
      _lastText = _text.text;
      _switching = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _focus.requestFocus();
    if (_files) unawaited(_ask());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.ws?.removeListener(_scopeChanged);
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final ws = widget.ws, link = widget.ws?.link;
    if (ws == null || link == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final gen = ++_gen;
    final project = ws.projectGeneration;
    final (q, _) = splitLine(_text.text);
    bool current() =>
        mounted &&
        gen == _gen &&
        identical(link, ws.link) &&
        project == ws.projectGeneration;
    try {
      final folders = _folders ?? await searchFolders(ws);
      if (!current()) return;
      _folders = folders;
      final items = await findFiles(link, folders, q, fresh: _first);
      if (!current()) return;
      _first = false;
      setState(() {
        _items = items;
        _index = 0;
        _loading = false;
      });
    } on Object {
      if (current()) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final commands = _files || _contents
        ? const <Command>[]
        : rankCommands(widget.commands, _text.text);
    final count = _files ? _items.length : commands.length;
    final selected = count == 0 ? 0 : _index.clamp(0, count - 1);
    final modes = [
      if (widget.ws != null) WorkbenchSearchMode.files,
      if (widget.allowContents) WorkbenchSearchMode.contents,
      if (widget.commands.isNotEmpty) WorkbenchSearchMode.commands,
    ];
    void pick(int i) {
      if (_contents) {
        Navigator.pop(context, _ContentChoice(_text.text.trim()));
      } else if (i >= 0 && i < count) {
        Navigator.pop(
          context,
          _files
              ? _FileChoice(_items[i], splitLine(_text.text).$2, _scope)
              : _CommandChoice(commands[i]),
        );
      }
    }

    void move(int d) {
      if (count == 0) return;
      setState(() => _index = (selected + d + count) % count);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted)
          revealPickerRow(
            _scroll,
            _index,
            rowHeight: PickerRow.heightOf(context),
          );
      });
    }

    final (icon, hint) = switch (_mode) {
      WorkbenchSearchMode.files => (Icons.search_rounded, '输入文件名，可加 :行号'),
      WorkbenchSearchMode.contents => (Icons.manage_search_rounded, '搜索文件内容…'),
      WorkbenchSearchMode.commands => (Icons.keyboard_command_key, '输入命令…'),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => move(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-1),
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.pop(context),
            if (widget.ws != null)
              const SingleActivator(
                LogicalKeyboardKey.keyP,
                control: true,
              ): () =>
                  _selectMode(WorkbenchSearchMode.files),
            if (widget.commands.isNotEmpty)
              const SingleActivator(
                LogicalKeyboardKey.keyP,
                control: true,
                shift: true,
              ): () =>
                  _selectMode(WorkbenchSearchMode.commands),
            if (widget.allowContents)
              const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
                shift: true,
              ): () =>
                  _selectMode(WorkbenchSearchMode.contents),
          },
          child: PickerField(
            controller: _text,
            focusNode: _focus,
            inputKey: const ValueKey('workbench-search-query'),
            icon: icon,
            hint: hint,
            onSubmitted: (_) => pick(selected),
          ),
        ),
        if (modes.length > 1)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.s),
              child: Wrap(
                key: const ValueKey('workbench-search-mode'),
                spacing: Space.xs,
                runSpacing: Space.xs,
                children: [
                  for (final mode in modes)
                    _SearchModeButton(
                      mode: mode,
                      selected: _mode == mode,
                      onTap: () => _selectMode(mode),
                    ),
                ],
              ),
            ),
          ),
        Stack(
          children: [
            const Divider(),
            if (_files && _loading)
              const LinearProgressIndicator(
                minHeight: 1.5,
                backgroundColor: Colors.transparent,
              ),
          ],
        ),
        Flexible(
          child: _contents
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.s),
                  child: PickerRow(
                    selected: true,
                    onTap: () => pick(0),
                    child: Row(
                      children: [
                        Icon(
                          Icons.manage_search_rounded,
                          size: 18,
                          color: ide.accent,
                        ),
                        const SizedBox(width: Space.m),
                        Expanded(
                          child: Text(
                            _text.text.trim().isEmpty
                                ? '打开内容搜索结果'
                                : '在项目中搜索「${_text.text.trim()}」',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: Space.m),
                        const SizedBox(height: 19, child: KeyCaps('Enter')),
                      ],
                    ),
                  ),
                )
              : count == 0
              ? Padding(
                  padding: const EdgeInsets.all(Space.xl),
                  child: Text(
                    !_files
                        ? '没有匹配的命令'
                        : _loading
                        ? '正在查找文件…'
                        : _folders?.isEmpty == true
                        ? '没有可以搜索的文件夹'
                        : '没有匹配的文件',
                    style: TextStyle(color: ide.textDim, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: Space.s),
                  itemExtent: PickerRow.heightOf(context),
                  itemCount: count,
                  itemBuilder: (_, i) {
                    return MouseRegion(
                      onHover: (_) {
                        if (i != _index) setState(() => _index = i);
                      },
                      child: PickerRow(
                        selected: i == selected,
                        followsPointer: true,
                        onTap: () => pick(i),
                        child: _files
                            ? _fileRow(ide, _items[i])
                            : _commandRow(ide, commands[i]),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _fileRow(Ide ide, QuickOpenItem it) {
    final name = it.path.split('/').last;
    final dir = displayPath(
      it.folder,
      it.path.substring(0, it.path.length - name.length),
    );
    return Row(
      children: [
        FileIcon(name: name, size: 16),
        const SizedBox(width: Space.m + 2),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: ide.text),
          ),
        ),
        const SizedBox(width: Space.m + 2),
        Expanded(
          child: Text(
            dir,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: ide.textFaint, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _commandRow(Ide ide, Command command) => LayoutBuilder(
    builder: (_, box) => Row(
      children: [
        Icon(commandIcon(command), size: 16, color: ide.textDim),
        const SizedBox(width: Space.m + 2),
        Expanded(
          child: Text(
            command.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: ide.text, fontSize: 13),
          ),
        ),
        if (box.maxWidth >= 360) ...[
          const SizedBox(width: Space.m),
          Text(
            command.group,
            style: TextStyle(color: ide.textFaint, fontSize: 11),
          ),
        ],
        if (box.maxWidth >= 490 && command.shortcut != null) ...[
          const SizedBox(width: Space.m),
          SizedBox(height: 19, child: KeyCaps(command.shortcut!)),
        ],
      ],
    ),
  );
}

class _SearchModeButton extends StatelessWidget {
  final WorkbenchSearchMode mode;
  final bool selected;
  final VoidCallback onTap;
  const _SearchModeButton({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final (label, shortcut) = switch (mode) {
      WorkbenchSearchMode.files => ('文件名', 'Ctrl+P'),
      WorkbenchSearchMode.contents => ('文件内容', 'Ctrl+Shift+F'),
      WorkbenchSearchMode.commands => ('命令', 'Ctrl+Shift+P'),
    };
    return Tooltip(
      message: '$label（$shortcut）',
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? ide.accentSoft : Colors.transparent,
          borderRadius: UiMetrics.controlCorners,
          child: InkWell(
            onTap: onTap,
            borderRadius: UiMetrics.controlCorners,
            child: Container(
              constraints: BoxConstraints(
                minHeight: InputMode.isTouch(context) ? 44 : 28,
              ),
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              alignment: Alignment.center,
              width: InputMode.isTouch(context) ? 100 : 84,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? ide.accent : ide.textDim,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
