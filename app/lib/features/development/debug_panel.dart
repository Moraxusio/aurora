import 'dart:async';

import 'package:aurora/ui/aurora_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:re_editor/re_editor.dart';

import '../../kernel/development/debug_model.dart';
import '../../kernel/document_model.dart';
import '../../kernel/editor_tab.dart';
import '../../kernel/workspace.dart';
import '../files/file_editor.dart';
import 'development_scope.dart';

Future<void> startConfiguredDebug(BuildContext context, Workspace ws) async {
  try {
    final scope = await selectDevelopmentScope(context, ws);
    if (scope == null || !context.mounted) return;
    final configs = scope.entries('debug');
    final id = await showWorkbenchDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('启动调试'),
        content: SizedBox(
          width: 600,
          height: 320,
          child: configs.isEmpty
              ? const Center(child: Text('请在开发配置 debug 中添加调试适配器。'))
              : ListView.builder(
                  itemCount: configs.length,
                  itemBuilder: (_, i) => TreeRow(
                    label: '${configs[i]['label'] ?? configs[i]['id']}',
                    subtitle:
                        '${configs[i]['request']} · ${(configs[i]['command'] as List? ?? []).join(' ')}',
                    onTap: () => Navigator.pop(c, '${configs[i]['id']}'),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (id == null || !context.mounted) return;
    await ws.debugger.start(scope, id);
    if (ws.debugger.error != null) ws.toast(ws.debugger.error!, error: true);
  } on Object catch (e) {
    ws.toast('$e', error: true);
  }
}

void toggleCursorBreakpoint(Workspace ws, DocumentModel document) {
  unawaited(
    ws.debugger
        .toggleBreakpoint(
          document.key.root,
          document.key.path,
          document.controller.unfoldLineSelection.extentIndex + 1,
        )
        .catchError((Object e) => ws.toast('$e', error: true)),
  );
}

class DebugPanel extends StatelessWidget {
  final Workspace ws;
  const DebugPanel({super.key, required this.ws});
  Future<void> _action(Future<void> Function() run) async {
    try {
      await run();
    } on Object catch (e) {
      ws.toast('$e', error: true);
    }
  }

  void _reveal(Map frame) {
    final model = ws.debugger, path = ws.debugger.pathForFrame(frame);
    if (path == null || model.scope == null) {
      final source = frame['source'];
      if (source is! Map) {
        ws.toast('该栈帧没有源文件');
        return;
      }
      final name = '${source['name'] ?? source['path'] ?? '调试源文件'}';
      ws.openTab(
        EditorTab(
          id: 'debug-source:${identityHashCode(model.peer)}:${source['sourceReference']}:${source['path']}',
          title: name,
          icon: Icons.description_outlined,
          builder: (_) =>
              DebugSourceView(model: model, frame: Map.of(frame), name: name),
        ),
      );
      return;
    }
    openFileAt(
      ws,
      root: model.scope!.root,
      path: path,
      line: frame['line'] as int? ?? 1,
      col: frame['column'] as int? ?? 1,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ws.debugger,
    builder: (context, _) {
      final model = ws.debugger;
      final sections = <Widget>[
        Wrap(
          children: [
            IconBtn(
              Icons.play_arrow,
              model.stopped ? '继续 (F5)' : '启动调试',
              model.stopped && !model.controlling
                  ? () => _action(() => model.control('continue'))
                  : !model.active && model.supported
                  ? () => startConfiguredDebug(context, ws)
                  : null,
            ),
            IconBtn(
              Icons.pause,
              '暂停',
              model.phase == DebugPhase.running && !model.controlling
                  ? () => _action(() => model.control('pause'))
                  : null,
            ),
            IconBtn(
              Icons.redo,
              '单步跳过 (F10)',
              model.stopped && !model.controlling ? () => _action(() => model.control('next')) : null,
            ),
            IconBtn(
              Icons.south,
              '单步进入 (F11)',
              model.stopped && !model.controlling
                  ? () => _action(() => model.control('stepIn'))
                  : null,
            ),
            IconBtn(
              Icons.north,
              '单步跳出 (Shift+F11)',
              model.stopped && !model.controlling
                  ? () => _action(() => model.control('stepOut'))
                  : null,
            ),
            IconBtn(
              Icons.stop,
              '停止 (Shift+F5)',
              model.active && model.phase != DebugPhase.stopping ? () => _action(model.stop) : null,
            ),
            IconBtn(Icons.terminal, '调试控制台', () => _console(context)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(switch (model.phase) {
            DebugPhase.idle => '选择配置启动调试；在编辑器按 F9 切换断点。',
            DebugPhase.starting => '正在启动调试…',
            DebugPhase.running => '正在运行',
            DebugPhase.stopped => model.reason ?? '已暂停',
            DebugPhase.stopping => '正在停止…',
            DebugPhase.terminated => '调试已结束',
            DebugPhase.failed => '调试启动失败',
          }),
        ),
        if (model.error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(model.error!)),
        if (model.storageError != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('调试状态保存：${model.storageError}'),
          ),
        SectionHeader('断点 · ${model.breakpoints.length}'),
        CheckboxListTile(
          dense: true,
          title: const Text('在所有异常处暂停'),
          value: model.breakOnExceptions,
          onChanged: (value) =>
              _action(() => model.setBreakOnExceptions(value == true)),
        ),
        for (final b in model.breakpoints)
          TreeRow(
            label: '${b.path}:${b.actualLine ?? b.line}',
            subtitle:
                b.message ??
                ((b.condition ?? '').isNotEmpty ? '条件：${b.condition}' : null),
            leading: Checkbox(
              value: b.enabled,
              onChanged: (value) =>
                  _action(() => model.updateBreakpoint(b, enabled: value)),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconBtn(
                  Icons.edit_outlined,
                  '编辑断点',
                  () => _editBreakpoint(context, b),
                ),
                IconBtn(
                  Icons.close,
                  '删除断点',
                  () => _action(
                    () => model.toggleBreakpoint(b.root, b.path, b.line),
                  ),
                ),
              ],
            ),
            onTap: () =>
                openFileAt(ws, root: b.root, path: b.path, line: b.line),
          ),
        SectionHeader('调用栈 · ${model.frames.length}'),
        if (model.threads.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: DropdownButton<int>(
              isExpanded: true,
              value: model.threads.any((t) => t['id'] == model.threadId)
                  ? model.threadId
                  : null,
              hint: const Text('选择线程'),
              items: [
                for (final thread in model.threads)
                  DropdownMenuItem(
                    value: thread['id'] as int,
                    child: Text(
                      '${thread['name']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (id) =>
                  _action(() => model.refreshStack(selectThread: id)),
            ),
          ),
        for (final frame in model.frames)
          TreeRow(
            label: '${frame['name']}',
            subtitle:
                '${model.pathForFrame(frame) ?? '外部源文件'}:${frame['line']}',
            selected: frame['id'] == model.frameId,
            onTap: () {
              _reveal(frame);
              _action(() => model.selectFrame(frame['id'] as int));
            },
          ),
        if (model.frames.length < model.totalFrames &&
            model.frames.length < 1000)
          TextButton(
            onPressed: () => _action(() => model.refreshStack(more: true)),
            child: const Text('加载更多栈帧'),
          ),
        SectionHeader(
          '监视',
          actions: [
            IconBtn(Icons.add, '添加监视', () async {
              final expression = await askText(
                context,
                title: '监视表达式',
                hint: '表达式',
              );
              if (expression != null)
                await _action(() => model.addWatch(expression));
            }),
          ],
        ),
        for (final expression in model.watches)
          TreeRow(
            label: expression,
            subtitle: model.watchValues[expression] ?? '等待暂停',
            trailing: IconBtn(
              Icons.close,
              '移除监视',
              () => _action(() => model.removeWatch(expression)),
            ),
          ),
        const SectionHeader('变量'),
        for (final scope in model.scopes)
          _Variables(
            key: ValueKey(
              '${model.pauseGeneration}:${model.frameId}:${scope['variablesReference']}',
            ),
            model: model,
            reference: scope['variablesReference'] as int? ?? 0,
            label: '${scope['name']}',
            depth: 0,
          ),
      ];
      return ListView.builder(
        itemCount: sections.length,
        itemBuilder: (_, i) => sections[i],
      );
    },
  );
  Future<void> _editBreakpoint(
    BuildContext context,
    DebugBreakpoint point,
  ) async {
    final value = await showWorkbenchDialog<(String, String, String)>(
      context: context,
      builder: (_) => _BreakpointEditor(point: point),
    );
    if (value != null)
      await _action(
        () => ws.debugger.updateBreakpoint(
          point,
          condition: value.$1,
          hitCondition: value.$2,
          logMessage: value.$3,
        ),
      );
  }

  Future<void> _console(BuildContext context) => showWorkbenchDialog<void>(
    context: context,
    builder: (_) => _DebugConsole(model: ws.debugger),
  );
}

class _BreakpointEditor extends StatefulWidget {
  final DebugBreakpoint point;
  const _BreakpointEditor({required this.point});
  @override
  State<_BreakpointEditor> createState() => _BreakpointEditorState();
}

class _BreakpointEditorState extends State<_BreakpointEditor> {
  late final condition = TextEditingController(
    text: widget.point.condition ?? '',
  );
  late final hits = TextEditingController(
    text: widget.point.hitCondition ?? '',
  );
  late final message = TextEditingController(
    text: widget.point.logMessage ?? '',
  );
  @override
  void dispose() {
    condition.dispose();
    hits.dispose();
    message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('编辑断点'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: condition,
              maxLength: 4096,
              decoration: const InputDecoration(
                labelText: '条件表达式',
                hintText: '例如 i > 10；留空取消',
              ),
            ),
            TextField(
              controller: hits,
              maxLength: 4096,
              decoration: const InputDecoration(
                labelText: '命中次数条件',
                hintText: '例如 10 或 >= 10（由适配器解释）',
              ),
            ),
            TextField(
              controller: message,
              maxLength: 4096,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '日志断点消息',
                hintText: '例如 value = {value}；留空恢复暂停断点',
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, (condition.text, hits.text, message.text)),
        child: const Text('保存断点'),
      ),
    ],
  );
}

/// Adapter-provided virtual / external source is a bounded read-only snapshot,
/// never aliased to an editable workspace document or its saved version.
class DebugSourceView extends StatefulWidget {
  final DebugModel model;
  final Map frame;
  final String name;
  const DebugSourceView({
    super.key,
    required this.model,
    required this.frame,
    required this.name,
  });
  @override
  State<DebugSourceView> createState() => _DebugSourceViewState();
}

class _DebugSourceViewState extends State<DebugSourceView> {
  late final Future<String> source = widget.model.readSource(widget.frame);
  CodeLineEditingController? controller;
  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Text('${widget.name} · 调试源文件快照 · 只读'),
      ),
      Expanded(
        child: FutureBuilder<String>(
          future: source,
          builder: (_, result) {
            if (result.hasError)
              return Center(child: SelectableText('${result.error}'));
            if (!result.hasData)
              return const Center(child: CircularProgressIndicator());
            if (controller == null) {
              controller = CodeLineEditingController.fromText(result.data!);
              final line = ((widget.frame['line'] as int? ?? 1) - 1).clamp(
                0,
                controller!.codeLines.length - 1,
              );
              controller!.selection = CodeLineSelection.collapsed(
                index: line,
                offset: 0,
              );
            }
            return CodeEditor(controller: controller!, readOnly: true);
          },
        ),
      ),
    ],
  );
}

class _Variables extends StatefulWidget {
  final DebugModel model;
  final int reference, depth;
  final String label;
  const _Variables({
    super.key,
    required this.model,
    required this.reference,
    required this.label,
    required this.depth,
  });
  @override
  State<_Variables> createState() => _VariablesState();
}

class _VariablesState extends State<_Variables> {
  final List<Map<String, dynamic>> values = [];
  bool loading = false, hasMore = true;
  String? error;
  Future<void> load() async {
    if (loading || !hasMore) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final next = await widget.model.variables(
        widget.reference,
        start: values.length,
      );
      if (!mounted) return;
      setState(() {
        values.addAll(next);
        hasMore = next.length == 100 && values.length < 500;
      });
    } on Object catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text(widget.label, maxLines: 3, overflow: TextOverflow.ellipsis),
    onExpansionChanged: (open) {
      if (open && values.isEmpty) load();
    },
    children: [
      if (error != null) Text(error!),
      for (final variable in values)
        if ((variable['variablesReference'] as int? ?? 0) > 0 &&
            widget.depth < 8)
          _Variables(
            model: widget.model,
            reference: variable['variablesReference'] as int,
            label: '${variable['name']}: ${variable['value']}',
            depth: widget.depth + 1,
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 8, 4),
            child: SelectableText('${variable['name']}: ${variable['value']}'),
          ),
      if (loading) const LinearProgressIndicator(),
      if (!loading && hasMore)
        TextButton(
          onPressed: load,
          child: Text(values.isEmpty ? '读取变量' : '加载更多变量'),
        ),
    ],
  );
}

class _DebugConsole extends StatefulWidget {
  final DebugModel model;
  const _DebugConsole({required this.model});
  @override
  State<_DebugConsole> createState() => _DebugConsoleState();
}

class _DebugConsoleState extends State<_DebugConsole> {
  final input = TextEditingController();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> evaluate(String expression) async {
    if (expression.trim().isEmpty) return;
    input.clear();
    widget.model.log('> $expression');
    try {
      widget.model.log(await widget.model.evaluate(expression));
    } on Object catch (e) {
      widget.model.log('$e');
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(12),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(child: Text('调试控制台')),
                IconBtn(Icons.close, '关闭', () => Navigator.pop(context)),
              ],
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.model,
                builder: (_, _) => ListView.builder(
                  itemCount: widget.model.output.length,
                  itemBuilder: (_, i) => SelectableText(widget.model.output[i]),
                ),
              ),
            ),
            TextField(
              controller: input,
              decoration: const InputDecoration(
                labelText: '暂停时求值',
                hintText: '输入表达式并按 Enter',
              ),
              onSubmitted: evaluate,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Only visible editor paragraphs get hit targets; folded lines use their real
/// document indices. The document model remains independent of this gutter.
class BreakpointGutter extends LeafRenderObjectWidget {
  final Workspace ws;
  final DocumentModel document;
  final CodeIndicatorValueNotifier notifier;
  const BreakpointGutter({
    super.key,
    required this.ws,
    required this.document,
    required this.notifier,
  });
  @override
  RenderObject createRenderObject(BuildContext context) => _BreakpointRender(
    ws,
    document,
    notifier,
    Theme.of(context).colorScheme.error,
  );
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _BreakpointRender).update(
      ws,
      document,
      notifier,
      Theme.of(context).colorScheme.error,
    );
  }
}

// re_editor publishes visible paragraphs during layout. Observe them in a
// render object (like its native line numbers), never through widget setState.
class _BreakpointRender extends RenderBox {
  Workspace ws;
  DocumentModel document;
  CodeIndicatorValueNotifier notifier;
  Color color;
  final Map<int, SemanticsNode> _nodes = {};
  Offset? _down;
  _BreakpointRender(this.ws, this.document, this.notifier, this.color);
  void _listen(bool add) {
    if (add) {
      notifier.addListener(_changed);
      ws.debugger.addListener(_changed);
    } else {
      notifier.removeListener(_changed);
      ws.debugger.removeListener(_changed);
    }
  }

  void update(
    Workspace next,
    DocumentModel doc,
    CodeIndicatorValueNotifier value,
    Color nextColor,
  ) {
    if (attached) _listen(false);
    ws = next;
    document = doc;
    notifier = value;
    color = nextColor;
    if (attached) _listen(true);
    _changed();
  }

  void _changed() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen(true);
  }

  @override
  void detach() {
    _listen(false);
    super.detach();
  }

  @override
  void performLayout() => size = constraints.constrain(
    Size(20, constraints.hasBoundedHeight ? constraints.maxHeight : 0),
  );
  int _line(CodeLineRenderParagraph paragraph) =>
      document.controller.index2lineIndex(paragraph.index) + 1;
  Iterable<CodeLineRenderParagraph> get _visible =>
      (notifier.value?.paragraphs ?? <CodeLineRenderParagraph>[]).where(
        (p) => p.bottom > 0 && p.top < size.height,
      );
  DebugBreakpoint? _point(int line) => ws.debugger.breakpoints
      .where(
        (b) =>
            b.root == document.key.root &&
            b.path == document.key.path &&
            b.line == line,
      )
      .firstOrNull;
  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRect(offset & size);
    for (final paragraph in _visible) {
      final point = _point(_line(paragraph));
      if (point == null) continue;
      final paint = Paint()
        ..color = color
        ..style = point.enabled ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(
        offset +
            Offset(
              size.width / 2,
              paragraph.top + paragraph.preferredLineHeight / 2,
            ),
        4.5,
        paint,
      );
    }
    canvas.restore();
  }

  void _toggle(int line) => unawaited(
    ws.debugger
        .toggleBreakpoint(document.key.root, document.key.path, line)
        .catchError((Object e) => ws.toast('$e', error: true)),
  );
  @override
  bool hitTestSelf(Offset position) => true;
  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent && event.buttons == kPrimaryButton)
      _down = event.localPosition;
    if (event is PointerCancelEvent) _down = null;
    if (event is PointerUpEvent) {
      final down = _down;
      _down = null;
      if (down == null || (event.localPosition - down).distance > 6) return;
      final paragraph = _visible
          .where((p) => p.inVerticalRange(event.localPosition))
          .firstOrNull;
      if (paragraph != null) _toggle(_line(paragraph));
    }
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.isSemanticBoundary = true;
    config.explicitChildNodes = true;
  }

  @override
  void assembleSemanticsNode(
    SemanticsNode node,
    SemanticsConfiguration config,
    Iterable<SemanticsNode> children,
  ) {
    final active = <int>{}, result = <SemanticsNode>[];
    for (final paragraph in _visible) {
      final line = _line(paragraph);
      active.add(line);
      final point = _point(line);
      final child = _nodes.putIfAbsent(line, SemanticsNode.new)
        ..rect = Rect.fromLTRB(
          0,
          paragraph.top.clamp(0, size.height),
          size.width,
          paragraph.bottom.clamp(0, size.height),
        );
      child.updateWith(
        config: SemanticsConfiguration()
          ..isButton = true
          ..textDirection = TextDirection.ltr
          ..label = '${point == null ? '添加' : '删除'}第 $line 行断点'
          ..onTap = () => _toggle(line),
      );
      result.add(child);
    }
    _nodes.removeWhere((key, _) => !active.contains(key));
    node.updateWith(
      config: config,
      childrenInInversePaintOrder: result.reversed.toList(),
    );
  }
}
