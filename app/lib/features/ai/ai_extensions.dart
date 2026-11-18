import 'dart:async';
import 'dart:convert';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora/ui/aurora_ui.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import '../development/development_scope.dart';
import 'ai_visuals.dart';

part 'ai_project_pages.dart';

Future<void> openAiExtensions(
  BuildContext context,
  Workspace ws, {
  String? root,
  String? workdir,
  String page = 'budget',
}) async {
  if (root == null || workdir == null) {
    final folder = await selectWorkspaceFolder(context, ws);
    if (folder == null) return;
    root = folder.root;
    workdir = folder.path;
  }
  final selectedRoot = root, selectedWork = workdir;
  final existing = ws.tab('ai-extensions:$selectedRoot:$selectedWork');
  if (existing is _AiExtensionsTab) {
    existing.viewKey.currentState?._switchPage(page);
    ws.activate(existing.id);
    return;
  }
  ws.openTab(
    _AiExtensionsTab(
      id: 'ai-extensions:$selectedRoot:$selectedWork',
      viewKey: GlobalKey<_AiExtensionsViewState>(),
      view: (key) => AiExtensionsView(
        key: key,
        ws: ws,
        root: selectedRoot,
        workdir: selectedWork,
        initialPage: page,
      ),
    ),
  );
}

class _AiExtensionsTab extends EditorTab {
  final GlobalKey<_AiExtensionsViewState> viewKey;
  _AiExtensionsTab({
    required super.id,
    required this.viewKey,
    required Widget Function(Key) view,
  }) : super(title: 'AI 项目配置', icon: Icons.tune, builder: (_) => view(viewKey));
}

class AiExtensionsView extends StatefulWidget {
  final Workspace ws;
  final String root, workdir;
  final String initialPage;
  const AiExtensionsView({
    super.key,
    required this.ws,
    required this.root,
    required this.workdir,
    this.initialPage = 'budget',
  });
  @override
  State<AiExtensionsView> createState() => _AiExtensionsViewState();
}

class _AiExtensionsViewState extends State<AiExtensionsView> {
  void _change(VoidCallback action) => setState(action);
  final _editor = TextEditingController();
  final _form = GlobalKey<FormState>();
  EditorTab? _tab;
  late String _page;
  int _formEpoch = 0;
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
    _page = widget.initialPage;
    _tab = widget.ws.tab('ai-extensions:${widget.root}:${widget.workdir}');
    _tab?.confirmClose = _confirmClose;
    _editor.addListener(_syncDirty);
    widget.ws.addListener(_connection);
    unawaited(_load());
  }

  void _syncDirty() => _tab?.dirty.value = _dirty;

  Future<bool> _confirmClose() async =>
      !_dirty ||
      await confirmDialog(
        context,
        title: '关闭 AI 项目配置？',
        body: '项目配置尚未保存，关闭会丢弃当前草稿。',
      );

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
        if (_page != 'advanced' && !(_form.currentState?.validate() ?? true)) {
          throw const FormatException('请修正表单中标出的字段；修改仍保留在草稿中。');
        }
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
        if (_editor.text == text) {
          _editor.text = _saved;
          _formEpoch++;
        }
        _probes.clear();
        _syncDirty();
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

  Future<void> _inspectSnapshots() async {
    final link = _link, generation = _generation;
    if (link == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await link.call(
        'ai.snapshots.inspect',
        _scope,
        const Duration(seconds: 610),
      ) as Map;
      if (mounted &&
          generation == _generation &&
          identical(link, widget.ws.link)) {
        setState(
          () => _storageResult =
              '当前已保存策略：${r['enabled'] == true ? '已启用' : '已关闭'}\n'
              '有效文件 ${r['files']} · 大型新文件／特殊条目跳过 ${r['skipped']}\n'
              '内容 ${r['contentBytes']} 字节 · 对象库 ${r['storeBytes']} 字节'
              '${r['overTreeBudget'] == true || r['overStoreBudget'] == true ? '\n当前范围超过内容或存储上限，请调整。' : ''}',
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
    _tab?.confirmClose = null;
    _editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _projectPages();
  }
}
