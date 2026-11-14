import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import '../../kernel/overlays.dart';

import '../../theme/ide_theme.dart';

class AiPathChoice {
  final String root, path, name;
  const AiPathChoice(this.root, this.path, this.name);
}

Future<AiPathChoice?> showAiPathPicker(
  BuildContext context, {
  required Link link,
  required List<Map<String, dynamic>> roots,
  required String root,
  required String path,
  bool directory = true,
}) => showWorkbenchDialog<AiPathChoice>(
  context: context,
  builder: (_) => _PathPicker(link: link, roots: roots, initialRoot: root, initialPath: path, directory: directory),
);

class _PathPicker extends StatefulWidget {
  final Link link;
  final List<Map<String, dynamic>> roots;
  final String initialRoot, initialPath;
  final bool directory;
  const _PathPicker({
    required this.link,
    required this.roots,
    required this.initialRoot,
    required this.initialPath,
    required this.directory,
  });
  @override
  State<_PathPicker> createState() => _PathPickerState();
}

class _PathPickerState extends State<_PathPicker> {
  late String root, path;
  List<Map<String, dynamic>> entries = [];
  bool loading = true;
  String? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    root = widget.initialRoot;
    path = widget.initialPath;
    _load();
  }

  String _parent(String p) {
    final parts = p.split('/').where((x) => x.isNotEmpty).toList();
    if (parts.isNotEmpty) parts.removeLast();
    return '/${parts.join('/')}';
  }

  Future<void> _load() async {
    final g = ++generation;
    setState(() {
      loading = true;
      error = null;
      entries = [];
    });
    try {
      final r = await widget.link.call('fs.list', {'root': root, 'path': path}) as Map;
      if (!mounted || g != generation) return;
      final items = [
        for (final e in r['entries'] as List? ?? [])
          if (e is Map) e.cast<String, dynamic>(),
      ];
      items.removeWhere((e) {
        final n = e['name'];
        return n is! String ||
            n.isEmpty ||
            n == '.' ||
            n == '..' ||
            n.contains('/') ||
            n.contains('\\') ||
            (widget.directory && e['type'] != 'dir');
      });
      items.sort((a, b) {
        final d = (a['type'] == 'dir' ? 0 : 1).compareTo(b['type'] == 'dir' ? 0 : 1);
        return d != 0 ? d : (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase());
      });
      setState(() {
        entries = items;
        loading = false;
      });
    } on Object catch (e) {
      if (mounted && g == generation) {
        setState(() {
          loading = false;
          error = e is OpError ? e.message : '目录读取失败，请重试';
        });
      }
    }
  }

  void _go(String next) {
    path = next;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.directory ? '选择会话工作目录' : widget.link.server.kind == 'local' ? '选择本机文件' : '选择服务器文件',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: ide.text),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                key: ValueKey('ai-picker-root-$root'),
                initialValue: widget.roots.any((r) => r['id'] == root) ? root : null,
                isExpanded: true,
                decoration: InputDecoration(labelText: widget.link.server.kind == 'local' ? '本机根目录' : '服务器根目录'),
                items: [
                  for (final r in widget.roots)
                    DropdownMenuItem(value: r['id'] as String, child: Text('${r['label'] ?? r['id']}')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    root = v;
                    _go('/');
                  }
                },
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '上一级',
                      onPressed: path == '/' ? null : () => _go(_parent(path)),
                      icon: const Icon(Icons.arrow_upward, size: 18),
                    ),
                    TextButton(onPressed: () => _go('/'), child: const Text('/')),
                    for (var i = 0; i < parts.length; i++)
                      TextButton(onPressed: () => _go('/${parts.take(i + 1).join('/')}'), child: Text('${parts[i]} /')),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(error!),
                            TextButton(onPressed: _load, child: const Text('重试')),
                          ],
                        ),
                      )
                    : entries.isEmpty
                    ? Center(
                        child: Text(
                          widget.directory ? '此目录下没有子目录，可选择当前目录' : '目录为空',
                          style: TextStyle(color: ide.textDim),
                        ),
                      )
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final e = entries[index];
                          final name = e['name'] as String;
                          final isDir = e['type'] == 'dir';
                          return ListTile(
                            key: ValueKey('ai-path-$name'),
                            dense: true,
                            leading: Icon(
                              isDir ? Icons.folder_outlined : Icons.description_outlined,
                              color: isDir ? ide.accent : ide.textDim,
                            ),
                            title: Text(name),
                            trailing: isDir ? const Icon(Icons.chevron_right, size: 18) : null,
                            onTap: () {
                              final next = path == '/' ? '/$name' : '$path/$name';
                              if (isDir) {
                                _go(next);
                              } else {
                                Navigator.pop(context, AiPathChoice(root, next, name));
                              }
                            },
                          );
                        },
                      ),
              ),
              const SizedBox(height: 10),
              Text(
                '$root : $path',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: ide.textDim),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                  if (widget.directory)
                    FilledButton(
                      key: const ValueKey('ai-select-directory'),
                      onPressed: loading || error != null
                          ? null
                          : () => Navigator.pop(context, AiPathChoice(root, path, parts.lastOrNull ?? '/')),
                      child: const Text('选择当前目录'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
