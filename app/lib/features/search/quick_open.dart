// Quick open (Ctrl+P): file names across the project, ranked by the agent
// (fs.find, fuzzy). Typing asks again after a short pause; Enter or a click
// opens the file. ":N" after the name opens it at line N.
import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../kernel/widgets.dart';
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
Future<List<QuickOpenItem>> findFiles(Link link, List<SearchFolder> folders, String query, {bool fresh = false, int max = 60}) async {
  final per = await Future.wait([
    for (final f in folders)
      link.call('fs.find', {'root': f.root, 'path': f.path, 'query': query, 'max': max, 'fresh': fresh}).then<List<QuickOpenItem>>(
          (r) => [for (final p in ((r as Map)['files'] as List? ?? const [])) QuickOpenItem(f, normalized(p as String))],
          onError: (Object _) => <QuickOpenItem>[]),
  ]);
  final out = <QuickOpenItem>[];
  for (var i = 0; out.length < max; i++) {
    var any = false;
    for (final l in per) {
      if (i < l.length) {
        out.add(l[i]);
        any = true;
      }
    }
    if (!any) break;
  }
  return out;
}

Future<void> showQuickOpen(Workspace ws, {BuildContext? context}) async {
  final ctx = context ?? Toast.key.currentContext;
  if (ctx == null || ws.link == null) return;
  final folders = await searchFolders(ws);
  if (!ctx.mounted) return;
  final chosen = await showDialog<(QuickOpenItem, int?)>(
    context: ctx,
    barrierColor: Colors.black38,
    builder: (c) => Align(
      alignment: const Alignment(0, -0.6),
      child: Material(
        color: Ide.of(c).sideBar,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: Ide.of(c).border)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 620, maxHeight: 440), child: QuickOpen(ws: ws, folders: folders)),
      ),
    ),
  );
  if (chosen == null) return;
  openFileAt(ws, root: chosen.$1.folder.root, path: chosen.$1.path, line: chosen.$2);
}

class QuickOpen extends StatefulWidget {
  final Workspace ws;
  final List<SearchFolder> folders;
  const QuickOpen({super.key, required this.ws, required this.folders});
  @override
  State<QuickOpen> createState() => _QuickOpenState();
}

class _QuickOpenState extends State<QuickOpen> {
  final _text = TextEditingController();
  List<QuickOpenItem> _items = [];
  int _index = 0;
  bool _loading = true;
  bool _first = true;
  int _gen = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 120), _ask);
    });
    _ask();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final link = widget.ws.link;
    if (link == null) return;
    final gen = ++_gen;
    final (q, _) = splitLine(_text.text);
    // The first call lists the folders again (a file made a minute ago is
    // found); later ones use the agent's cached list.
    final items = await findFiles(link, widget.folders, q, fresh: _first);
    _first = false;
    if (!mounted || gen != _gen) return;
    setState(() {
      _items = items;
      _index = 0;
      _loading = false;
    });
  }

  void _pick(int i) {
    if (i < 0 || i >= _items.length) return;
    Navigator.pop(context, (_items[i], splitLine(_text.text).$2));
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    void move(int d) => setState(() => _index = _items.isEmpty ? 0 : (_index + d) % _items.length);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => move(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-1),
            const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
          },
          child: TextField(
            controller: _text,
            autofocus: true,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(hintText: '输入文件名，加 :行号 跳到那一行', prefixIcon: Icon(Icons.search, size: 18)),
            onSubmitted: (_) => _pick(_index),
          ),
        ),
      ),
      const Divider(),
      Flexible(
        child: _loading
            ? const Padding(padding: EdgeInsets.all(20), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
            : widget.folders.isEmpty
                ? Padding(padding: const EdgeInsets.all(20), child: Text('没有可以搜索的文件夹', style: TextStyle(color: ide.textDim)))
                : _items.isEmpty
                    ? Padding(padding: const EdgeInsets.all(20), child: Text('没有匹配的文件', style: TextStyle(color: ide.textDim)))
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: _items.length,
                        itemBuilder: (_, i) {
                          final it = _items[i];
                          final name = it.path.split('/').last;
                          final dir = displayPath(it.folder, it.path.substring(0, it.path.length - name.length));
                          return InkWell(
                            onTap: () => _pick(i),
                            child: Container(
                              height: 32,
                              color: i == _index ? ide.selection : null,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Row(children: [
                                Builder(builder: (_) {
                                  final (icon, color) = fileGlyph(name, ide);
                                  return Icon(icon, size: 15, color: color);
                                }),
                                const SizedBox(width: 8),
                                Text(name),
                                const SizedBox(width: 10),
                                Expanded(child: Text(dir, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: ide.textDim, fontSize: 12))),
                              ]),
                            ),
                          );
                        },
                      ),
      ),
    ]);
  }
}
