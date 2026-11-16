import 'dart:async';
import 'dart:convert';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora/ui/aurora_ui.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import '../development/development_scope.dart';

Future<void> openAiExtensions(BuildContext context, Workspace ws) async {
  final folder = await selectWorkspaceFolder(context, ws);
  if (folder == null) return;
  ws.openTab(
    EditorTab(
      id: 'ai-extensions:${folder.root}:${folder.path}',
      title: 'AI 扩展与预算',
      icon: Icons.extension_outlined,
      builder: (_) =>
          AiExtensionsView(ws: ws, root: folder.root, workdir: folder.path),
    ),
  );
}

class AiExtensionsView extends StatefulWidget {
  final Workspace ws;
  final String root, workdir;
  const AiExtensionsView({
    super.key,
    required this.ws,
    required this.root,
    required this.workdir,
  });
  @override
  State<AiExtensionsView> createState() => _AiExtensionsViewState();
}

class _AiExtensionsViewState extends State<AiExtensionsView> {
  final _editor = TextEditingController();
  Map? _data;
  Link? _link;
  String? _error;
  String _saved = '';
  int _generation = 0;
  bool _busy = false;
  final _probes = <String, Object>{};
  final _probing = <String>{};
  String? _storageResult;
  bool get _dirty => _editor.text != _saved;
  Map<String, Object?> get _scope => {
    'root': widget.root,
    'workdir': widget.workdir,
  };
  @override
  void initState() {
    super.initState();
    widget.ws.addListener(_connection);
    unawaited(_load());
  }

  void _connection() {
    if (identical(_link, widget.ws.link)) return;
    _generation++;
    setState(() {
      _busy = false;
      _probing.clear();
      _probes.clear();
      _data = null;
      _storageResult = null;
      _error = '连接已变化，请重新读取配置。当前草稿仍保留。';
    });
    _link = widget.ws.link;
  }

  Future<void> _load({bool save = false}) async {
    if (_busy) return;
    final link = widget.ws.link;
    if (link == null) {
      setState(() => _error = '未连接');
      return;
    }
    final text = _editor.text;
    final generation = ++_generation;
    _link = link;
    setState(() {
      _busy = true;
      _error = null;
      _probing.clear();
    });
    bool current() =>
        mounted && generation == _generation && identical(link, widget.ws.link);
    try {
      final args = <String, Object?>{..._scope};
      if (save) {
        final value = jsonDecode(text);
        if (value is! Map) throw const FormatException('AI 配置须是 JSON 对象');
        args.addAll({'config': value, 'if_match': _data?['etag'] ?? ''});
      }
      final response = await link.call('ai.extensions', args) as Map;
      if (!current()) return;
      setState(() {
        _data = response;
        _saved = const JsonEncoder.withIndent('  ').convert(response['config']);
        // Typing during the save receipt must not disappear.
        if (_editor.text == text) _editor.text = _saved;
        _probes.clear();
      });
    } on Object catch (e) {
      if (current()) setState(() => _error = '$e');
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    if (_dirty &&
        !await confirmDialog(
          context,
          title: '重新读取 AI 配置',
          body: '丢弃当前配置草稿并读取已保存的配置？',
        ))
      return;
    if (mounted) await _load();
  }

  Future<void> _probe(String id) async {
    final link = _link, generation = _generation;
    if (link == null || _probing.contains(id)) return;
    setState(() => _probing.add(id));
    Object result;
    try {
      result =
          await link.call('ai.mcp.probe', {
            ..._scope,
            'id': id,
          }, const Duration(seconds: 40)) ??
          {};
    } on Object catch (e) {
      result = '$e';
    }
    if (mounted &&
        generation == _generation &&
        identical(link, widget.ws.link)) {
      setState(() {
        _probing.remove(id);
        _probes[id] = result;
      });
    }
  }

  Future<void> _prune() async {
    final link = _link, generation = _generation;
    if (link == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await link.call(
        'ai.snapshots.prune',
        _scope,
        const Duration(seconds: 70),
      ) as Map;
      if (mounted &&
          generation == _generation &&
          identical(link, widget.ws.link)) {
        setState(
          () => _storageResult =
              '快照占用：${result['beforeBytes']} → ${result['afterBytes']} 字节',
        );
      }
    } on Object catch (e) {
      if (mounted && generation == _generation) setState(() => _error = '$e');
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    widget.ws.removeListener(_connection);
    _editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sources = _data?['instructions'] as List? ?? const [];
    final skills = _data?['skills'] as List? ?? const [];
    final servers = (_data?['config'] as Map?)?['mcp'] as List? ?? const [];
    return CustomScrollView(
      key: const ValueKey('ai-extensions-scroll'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'AI 扩展与预算 · ${widget.root}:${widget.workdir}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Text(
                  '项目配置：.aurora/ai.json。分层指令按用户→根目录→项目→子目录应用；技能按需加载。MCP 支持命令数组 stdio 和 Streamable HTTP，连接随运行结束释放。',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: _busy ? null : _reload,
                      child: const Text('重新读取'),
                    ),
                    FilledButton(
                      onPressed: _busy || _data == null
                          ? null
                          : () => _load(save: true),
                      child: const Text('保存 AI 配置'),
                    ),
                    if (widget.ws.link?.server.caps.contains(
                          'ai.snapshots.prune',
                        ) ==
                        true)
                      TextButton(
                        onPressed: _busy ? null : _prune,
                        child: const Text('清理未引用快照'),
                      ),
                  ],
                ),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  SelectableText(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_storageResult != null) Text(_storageResult!),
                SizedBox(
                  height: 320,
                  child: TextField(
                    controller: _editor,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontFamily: Ide.mono,
                      fontFamilyFallback: Ide.monoFallback,
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'AI 扩展配置 JSON',
                      alignLabelWithHint: true,
                    ),
                  ),
                ),
                const Text(
                  'budget：steps 1–60；seconds 10–3600；tokens 1024–2000000；outputBytes 4096–8388608；cost 为 USD（0 表示不设金额上限）。prices 以模型 ID 为键，input／output／cacheRead／cacheWrite 为每百万 tokens 单价。',
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(child: SectionHeader('MCP 服务 · ${servers.length}')),
        SliverList.builder(
          itemCount: servers.length,
          itemBuilder: (_, i) {
            final server = servers[i] as Map,
                id = '${(servers[i] as Map)['id']}';
            final result = _probes[id];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '$id · ${server['disabled'] == true
                            ? '已停用'
                            : server['url'] != null
                            ? 'HTTP'
                            : 'stdio'}',
                      ),
                      TextButton(
                        onPressed:
                            _busy ||
                                _probing.contains(id) ||
                                server['disabled'] == true
                            ? null
                            : () => _probe(id),
                        child: Text(_probing.contains(id) ? '检测中…' : '检测连接与目录'),
                      ),
                    ],
                  ),
                  if (result is Map)
                    ExpansionTile(
                      title: Text(
                        '${(result['tools'] as List? ?? []).length} 工具 · ${(result['resources'] as List? ?? []).length} 资源 · ${(result['prompts'] as List? ?? []).length} 提示词',
                      ),
                      children: [
                        SelectableText(
                          const JsonEncoder.withIndent('  ').convert(result),
                        ),
                      ],
                    )
                  else if (result != null)
                    SelectableText(
                      '$result',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        SliverToBoxAdapter(child: SectionHeader('生效指令 · ${sources.length}')),
        SliverList.builder(
          itemCount: sources.length,
          itemBuilder: (_, i) => ExpansionTile(
            title: Text('${sources[i]['path']}'),
            children: [SelectableText('${sources[i]['text']}')],
          ),
        ),
        SliverToBoxAdapter(child: SectionHeader('可用技能 · ${skills.length}')),
        SliverList.builder(
          itemCount: skills.length,
          itemBuilder: (_, i) => TreeRow(
            label: '${skills[i]['name']}',
            subtitle: '${skills[i]['description']}\n${skills[i]['path']}',
            leading: const Icon(Icons.school_outlined, size: 16),
          ),
        ),
      ],
    );
  }
}
