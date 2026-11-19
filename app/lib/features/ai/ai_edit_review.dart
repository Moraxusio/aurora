import 'dart:async';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora/ui/aurora_ui.dart';

import 'ai_model_picker.dart';
import 'ai_visuals.dart';

import '../../kernel/ai_edits.dart';
import '../../kernel/document_model.dart';
import '../../kernel/editor_tab.dart';
import '../../kernel/file_text.dart';
import '../../kernel/workspace.dart';
import '../development/task_panel.dart';
import '../git/diff_view.dart';
import '../git/text_diff.dart';
import 'ai_auth.dart';

Future<Map<String, Object?>> aiProposalArguments(
  Workspace ws,
  AiBufferSnapshot origin,
  String instruction, {
  bool inline = false,
  AiProvider? providerOverride,
}) async {
  final link = ws.link,
      provider = providerOverride ?? ws.app.aiSettings.activeProvider;
  if (link == null || !link.server.caps.contains('ai.propose'))
    throw StateError('需要支持 AI 编辑建议的 agent');
  if (provider == null) throw StateError('请先在 AI 设置中选择模型');
  final prepared = await prepareAiProvider(ws.app, link, provider);
  if (!identical(link, ws.link) || !origin.current)
    throw StateError('连接或编辑缓冲已变化');
  final folder = ws.development.scopeFor(origin.document);
  final caret = origin.caret;
  return {
    'root': origin.document.key.root,
    'workdir': folder.path,
    'instruction': instruction,
    'provider': prepared.toWireJson(
      extensionCapabilities: link.server.caps.contains('ai.extensions'),
      capabilityDefaults: ws.app.aiSettings.toolDefaults,
    ),
    'selection': origin.selectedText,
    if (inline)
      'prefix': origin.text.substring((caret - 8192).clamp(0, caret), caret),
    if (inline)
      'suffix': origin.text.substring(
        caret,
        (caret + 4096).clamp(caret, origin.text.length),
      ),
    'diagnostics': [
      for (final d
          in ws.development.diagnostics
              .where((d) => d.key == origin.document.key)
              .take(100))
        {'path': d.key.path, 'diagnostic': d.raw},
    ],
  };
}

void openAiEditReview(Workspace ws, DocumentModel origin) {
  ws.openTab(
    EditorTab(
      id: 'ai-edit:${DateTime.now().microsecondsSinceEpoch}',
      title: 'AI 修改审阅',
      icon: Icons.auto_fix_high,
      builder: (_) => AiEditReview(ws: ws, origin: origin),
    ),
  );
}

class AiEditReview extends StatefulWidget {
  final Workspace ws;
  final DocumentModel origin;
  const AiEditReview({super.key, required this.ws, required this.origin});
  @override
  State<AiEditReview> createState() => _AiEditReviewState();
}

class _AiEditReviewState extends State<AiEditReview> {
  final instruction = TextEditingController();
  late final selected = <DocumentModel>{widget.origin};
  final diffs = <AiEditChunk, Future<List<DiffLine>>>{};
  AiProposalOperation? operation;
  FileTextOperation? saveOperation;
  AiEditSet? edits;
  AiProvider? selectedProvider;
  String? reasoningOverride;
  bool busy = false;
  String? error;
  int requested = 0;

  AiProvider? get _effectiveProvider {
    if (selectedProvider != null) return selectedProvider;
    return widget.ws.app.ready ? widget.ws.app.aiSettings.activeProvider : null;
  }

  Future<void> _chooseModel() async {
    final ai = widget.ws.app.ready ? widget.ws.app.aiSettings : null;
    final pickedId = await showAiPersonaPicker(
      context,
      widget.ws,
      initialPersonaId: ai?.activePersonaId,
    );
    if (pickedId == null || !mounted || ai == null) return;
    final persona = ai.personaById(pickedId);
    if (persona == null) return;
    final source = (persona.providerId.isNotEmpty
            ? ai.providers.where((p) => p.id == persona.providerId).firstOrNull
            : ai.activeProvider);
    if (source == null) return;
    setState(() {
      selectedProvider = AiProvider.fromJson(source.toJson());
      if (persona.model.isNotEmpty) selectedProvider!.model = persona.model;
      reasoningOverride = persona.reasoningEffort;
    });
  }

  Future<void> generate() async {
    if (busy || instruction.text.trim().isEmpty) return;
    final link = widget.ws.link;
    if (link == null) return;
    final snapshots = [for (final d in selected) AiBufferSnapshot(d)];
    if (snapshots.isEmpty) return;
    final op = operation = AiProposalOperation(
      snapshots,
      active: () => mounted && identical(widget.ws.link, link),
    );
    setState(() {
      busy = true;
      error = null;
      requested++;
    });
    try {
      final prompt = instruction.text;
      final result = await op.run(
        link,
        () => aiProposalArguments(
          widget.ws,
          snapshots.first,
          prompt,
          providerOverride: _effectiveProvider,
        ),
      );
      if (!mounted) return;
      edits?.dispose();
      setState(() {
        edits = result;
        diffs.clear();
      });
    } on Object catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted)
        setState(() {
          busy = false;
          operation = null;
        });
    }
  }

  void act(VoidCallback action) {
    try {
      action();
      setState(() => error = null);
    } on Object catch (e) {
      setState(() => error = '$e');
    }
  }

  Future<void> save() async {
    final current = edits!;
    final op = saveOperation = FileTextOperation(
      active: () => mounted && current.active(),
    );
    try {
      await current.save(operation: op);
      if (mounted) setState(() => error = null);
    } on Object catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saveOperation = null);
    }
  }

  Future<void> validate() async {
    final current = edits!;
    if (!current.chunks.any((c) => c.accepted) ||
        !current.acceptedBuffersClean) {
      setState(() => error = '请先保存已接受的修改，再运行关联验证任务');
      return;
    }
    var versions = <DocumentModel, (int, String?)>{};
    await runConfiguredTask(
      context,
      widget.ws,
      beforeStart: () {
        final docs = current.chunks
            .where((c) => c.accepted)
            .map((c) => c.snapshot.document)
            .toSet();
        current.validate(docs);
        if (!current.acceptedBuffersClean) throw StateError('缓冲已变化，请保存后重新验证');
        versions = {for (final d in docs) d: (d.version, d.etag)};
      },
      onStarted: (run) {
        if (mounted)
          setState(() {
            current.validationTasks.add(run.id);
            current.validationVersions[run.id] = versions;
          });
      },
    );
  }

  @override
  void dispose() {
    operation?.cancel();
    saveOperation?.cancel();
    edits?.dispose();
    instruction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = edits;
    final files = widget.ws.documents.all
        .where(
          (d) =>
              d.phase == DocumentPhase.ready &&
              !d.isClosed &&
              !d.diskMissing &&
              d.key.root == widget.origin.key.root,
        )
        .toList();
    return ListenableBuilder(
      listenable: Listenable.merge([
        if (current != null) current,
        widget.ws.tasks,
        widget.ws.documents,
      ]),
      builder: (_, _) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AiSectionHeading(
                    icon: Icons.difference_outlined,
                    title: 'AI 修改审阅',
                    subtitle: '选择上下文 → 生成建议 → 逐块接受 → 保存与验证',
                  ),
                  TextField(
                    controller: instruction,
                    minLines: 1,
                    maxLines: 3,
                    maxLength: 8192,
                    decoration: const InputDecoration(
                      labelText: 'AI 修改要求',
                      hintText: '基于当前缓冲生成可逐块接受的修改…',
                    ),
                    onSubmitted: (_) => generate(),
                  ),
                  ExpansionTile(
                    title: Text('参考文件 · 已选择 ${selected.length} 个'),
                    subtitle: const Text('使用当前编辑缓冲，包括尚未保存的内容'),
                    tilePadding: EdgeInsets.zero,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final doc in files.take(32))
                            FilterChip(
                              label: Text(doc.key.path),
                              selected: selected.contains(doc),
                              onSelected: busy
                                  ? null
                                  : (yes) => setState(() {
                                      if (yes) {
                                        selected.add(doc);
                                      } else {
                                        selected.remove(doc);
                                      }
                                    }),
                            ),
                        ],
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: busy || current?.saving == true
                            ? null
                            : generate,
                        icon: const Icon(Icons.auto_fix_high, size: 16),
                        label: Text(busy ? '生成中…' : '生成修改建议'),
                      ),
                      if (busy)
                        TextButton(
                          onPressed: () => operation?.cancel(),
                          child: const Text('取消生成'),
                        ),
                      if (current != null) ...[
                        TextButton(
                          onPressed: current.pending.isEmpty || current.saving
                              ? null
                              : () => act(
                                  () =>
                                      current.accept(current.pending.toList()),
                                ),
                          child: const Text('接受剩余修改'),
                        ),
                        TextButton(
                          onPressed: current.canUndo
                              ? () => act(current.undo)
                              : null,
                          child: const Text('撤销上批接受'),
                        ),
                        OutlinedButton(
                          onPressed: current.saving ? null : save,
                          child: const Text('整批保存已接受修改'),
                        ),
                        TextButton(
                          onPressed: current.saving ? null : validate,
                          child: const Text('运行关联验证'),
                        ),
                        Text(
                          '${current.chunks.where((c) => c.accepted).length}/${current.chunks.length} 块已接受 · ${current.elapsedMs} ms · ${current.usage['total_tokens'] ?? 0} tokens',
                        ),
                      ],
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: TextButton.icon(
                          key: const ValueKey('ai-edit-model-btn'),
                          onPressed: busy ? null : _chooseModel,
                          icon: const Icon(Icons.memory_rounded, size: 15),
                          label: Text(
                            _effectiveProvider == null ||
                                    _effectiveProvider!.model.isEmpty
                                ? '选择模型'
                                : '${_effectiveProvider!.name} / ${_effectiveProvider!.model}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (busy || current?.saving == true)
                    const LinearProgressIndicator(),
                  if (error != null)
                    Notice(tone: Tone.error, title: '操作未完成', body: error),
                  if (current != null && current.chunks.isEmpty)
                    const Text('没有需要修改的内容。'),
                ],
              ),
            ),
          ),
          if (current != null && current.validationTasks.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  children: [
                    for (final id in current.validationTasks)
                      for (final run in widget.ws.tasks.history.where(
                        (r) => r.id == id,
                      ))
                        TextButton(
                          onPressed: () => openTaskResult(widget.ws, run),
                          child: Text(
                            '${run.label} · ${taskStatusLabels[run.status] ?? run.status}${current.validationCurrent(id) ? '' : ' · 文件版本已变化'}',
                          ),
                        ),
                  ],
                ),
              ),
            ),
          if (current != null)
            SliverList.builder(
              itemCount: current.chunks.length,
              itemBuilder: (c, i) {
                final chunk = current.chunks[i];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: [
                            Text(
                              '${chunk.snapshot.document.key.path} · 修改 ${i + 1}',
                            ),
                            if (chunk.accepted)
                              const Text('已接受')
                            else if (chunk.rejected)
                              const Text('已拒绝')
                            else ...[
                              TextButton(
                                onPressed: current.saving
                                    ? null
                                    : () => act(() => current.accept([chunk])),
                                child: const Text('接受此块'),
                              ),
                              TextButton(
                                onPressed: current.saving
                                    ? null
                                    : () => current.reject(chunk),
                                child: const Text('拒绝此块'),
                              ),
                            ],
                          ],
                        ),
                        SizedBox(
                          height: 180,
                          child: FutureBuilder<List<DiffLine>>(
                            future: diffs.putIfAbsent(
                              chunk,
                              () => diffTextsAsync(
                                chunk.before,
                                chunk.replacement,
                                active: () => mounted,
                              ),
                            ),
                            builder: (_, s) => s.hasData
                                ? DiffView(lines: s.data!)
                                : s.hasError
                                ? Text('${s.error}')
                                : const Center(
                                    child: CircularProgressIndicator(),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
