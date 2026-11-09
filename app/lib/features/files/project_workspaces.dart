import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/material.dart';

import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';

class ProjectWorkspaceBar extends StatelessWidget {
  final Workspace ws;
  const ProjectWorkspaceBar({super.key, required this.ws});
  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context), current = ws.project;
    return Container(padding: const EdgeInsets.fromLTRB(9, 9, 5, 8),
      decoration: BoxDecoration(color: ide.tabBar, border: Border(bottom: BorderSide(color: ide.border))),
      child: Row(children: [
        Icon(current == null ? Icons.dns_outlined : Icons.workspaces_outline, size: 19, color: ide.accent),
        const SizedBox(width: 7),
        Expanded(child: PopupMenuButton<String>(key: const ValueKey('project-switcher'), tooltip: '切换工作区',
          onSelected: (id) => ws.selectProject(id.isEmpty ? null : id),
          itemBuilder: (_) => [
            const PopupMenuItem(value: '', child: Text('浏览服务器')),
            if (ws.entry?.workspaces.isNotEmpty == true) const PopupMenuDivider(),
            for (final p in ws.entry?.workspaces ?? const <ProjectWorkspace>[])
              PopupMenuItem(value: p.id, child: Row(children: [
                Icon(p.id == ws.projectKey ? Icons.check : Icons.workspaces_outline, size: 16), const SizedBox(width: 9),
                Expanded(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                Text('${p.folders.length}', style: TextStyle(color: ide.textDim, fontSize: 11)),
              ])),
          ],
          child: Row(children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(current?.name ?? '浏览服务器', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
            Text(current == null ? '全部可用根目录' : '${current.folders.length} 个项目文件夹', style: TextStyle(fontSize: 10.5, color: ide.textDim)),
          ])), Icon(Icons.unfold_more, size: 16, color: ide.textDim)]),
        )),
        IconBtn(Icons.add, '新建工作区', () => createProjectWorkspace(context, ws)),
        PopupMenuButton<String>(tooltip: '工作区选项', padding: EdgeInsets.zero,
          icon: Icon(Icons.more_horiz, size: 18, color: ide.textDim),
          onSelected: (action) async {
            if (action == 'create') { await createProjectWorkspace(context, ws); return; }
            if (action == 'add') { await addProjectFolder(context, ws); return; }
            if (action == 'rename') {
              final name = await askText(context, title: '重命名工作区', initial: current!.name);
              if (name != null && name.isNotEmpty) await ws.renameProject(name);
              return;
            }
            if (action == 'delete' && context.mounted) {
              final ok = await confirmDialog(context, title: '删除工作区“${current!.name}”？',
                body: '只删除本机的工作区分组，不删除远程文件。已打开的文件会移到“浏览服务器”；未保存内容、终端和传输保留。', ok: '删除工作区');
              if (ok) await ws.deleteProject();
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'create', child: Text('新建工作区…')),
            if (current != null) ...[
              const PopupMenuItem(value: 'add', child: Text('添加远程文件夹…')),
              const PopupMenuItem(value: 'rename', child: Text('重命名工作区…')),
              const PopupMenuDivider(), const PopupMenuItem(value: 'delete', child: Text('删除工作区…')),
            ],
          ],
        ),
      ]));
  }
}

Future<void> createProjectWorkspace(BuildContext context, Workspace ws, {WorkspacePath? initial}) async {
  final name = await askText(context, title: '新建项目工作区', initial: initial?.name ?? '', hint: '工作区名称，例如 Aurora / 实验项目', ok: '下一步');
  if (name == null || name.isEmpty || !context.mounted) return;
  final folder = initial ?? await showDialog<WorkspacePath>(context: context, builder: (_) => _FolderPicker(ws: ws));
  if (folder == null) return;
  await ws.createProject(name, [folder]);
}

Future<void> addProjectFolder(BuildContext context, Workspace ws) async {
  if (ws.project == null) return;
  final folder = await showDialog<WorkspacePath>(context: context, builder: (_) => _FolderPicker(ws: ws));
  if (folder != null) await ws.addFolder(folder);
}

class _FolderPicker extends StatefulWidget {
  final Workspace ws;
  const _FolderPicker({required this.ws});
  @override State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  List<Map> _roots = [], _dirs = [];
  String? _root, _error;
  String _path = '/';
  bool _busy = true;
  int _generation = 0;
  @override void initState() { super.initState(); _start(); }
  Future<void> _start() async {
    try {
      final result = await widget.ws.link!.call('fs.roots') as Map;
      if (!mounted) return;
      _roots = (result['roots'] as List).whereType<Map>().where((r) => r['ok'] != false).toList();
      _root = _roots.firstOrNull?['id'] as String?;
      await _load('/');
    } on Object { if (mounted) setState(() { _error = '无法读取远程文件夹，请先连接服务器'; _busy = false; }); }
  }
  Future<void> _load(String path) async {
    final root = _root;
    if (root == null) { setState(() { _busy = false; _error = '服务器没有可用的根目录'; }); return; }
    final generation = ++_generation;
    setState(() { _busy = true; _error = null; });
    try {
      final r = await widget.ws.link!.call('fs.list', {'root': root, 'path': path, 'hidden': false}) as Map;
      if (!mounted || generation != _generation) return;
      setState(() {
        _path = path;
        _dirs = (r['entries'] as List).whereType<Map>().where((e) => e['type'] == 'dir' || e['target'] == 'dir').toList()
          ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
      });
    } on Object { if (mounted && generation == _generation) setState(() => _error = '这个文件夹无法读取，请选择其它目录'); }
    finally { if (mounted && generation == _generation) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('选择远程文件夹'),
    content: SizedBox(width: 480, height: 360, child: Column(children: [
      DropdownButtonFormField<String>(key: ValueKey(_root), initialValue: _root, decoration: const InputDecoration(labelText: '服务器根目录'),
        items: [for (final r in _roots) DropdownMenuItem(value: r['id'] as String, child: Text('${r['label'] ?? r['id']}  ${r['path'] ?? ''}', overflow: TextOverflow.ellipsis))],
        onChanged: _busy ? null : (id) { _root = id; _load('/'); }),
      const SizedBox(height: 10),
      Row(children: [IconButton(tooltip: '上一级', onPressed: _busy || _path == '/' ? null : () { final parent = _path.substring(0, _path.lastIndexOf('/')); _load(parent.isEmpty ? '/' : parent); },
        icon: const Icon(Icons.arrow_upward, size: 18)), Expanded(child: Text(_path, maxLines: 2, overflow: TextOverflow.ellipsis))]),
      const Divider(),
      Expanded(child: _busy ? const Center(child: CircularProgressIndicator()) : _error != null ? Center(child: Text(_error!)) : ListView.builder(
        itemCount: _dirs.length, itemBuilder: (_, i) => ListTile(dense: true, leading: const Icon(Icons.folder_outlined), title: Text('${_dirs[i]['name']}'),
          onTap: () => _load('${_path == '/' ? '' : _path}/${_dirs[i]['name']}')))),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _busy || _error != null || _root == null ? null : () => Navigator.pop(context, WorkspacePath(root: _root!, path: _path)), child: const Text('选择此文件夹'))],
  );
}
