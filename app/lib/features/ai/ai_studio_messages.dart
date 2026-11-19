part of 'ai_studio_view.dart';

extension _MessagesView on _AiStudioViewState {
  void _openAiFile(String rawPath, {int? line, int col = 1}) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.endsWith('/') || trimmed.endsWith('\\')) {
      ws.toast('这是文件夹路径：$trimmed');
      return;
    }
    if (ws.entry?.isLocal == true &&
        RegExp(r'^[A-Za-z]:[/\\]').hasMatch(trimmed)) {
      try {
        final located = ws.app.localAgent.locate(trimmed);
        openFileAt(
          ws,
          root: located.root,
          path: located.path,
          line: line,
          col: col,
        );
        return;
      } on StateError {
        // Fall through to root-relative resolution
      }
    }
    final normalized = trimmed.replaceAll('\\', '/');
    if (normalized.startsWith('/')) {
      final sortedRoots = [..._roots]
        ..sort(
          (a, b) => ((b['path'] as String?) ?? '').length.compareTo(
            ((a['path'] as String?) ?? '').length,
          ),
        );
      for (final r in sortedRoots) {
        final base = ((r['path'] as String?) ?? '')
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'/+$'), '');
        if (base.isNotEmpty &&
            base != '/' &&
            (normalized == base || normalized.startsWith('$base/'))) {
          openFileAt(
            ws,
            root: r['id'] as String,
            path: WorkspacePath.normalize(normalized.substring(base.length)),
            line: line,
            col: col,
          );
          return;
        }
      }
      if (_root.isNotEmpty) {
        openFileAt(
          ws,
          root: _root,
          path: WorkspacePath.normalize(normalized),
          line: line,
          col: col,
        );
        return;
      }
    }
    if (_root.isEmpty) return;
    final prefix = _workdir == '/' ? '' : _workdir.replaceFirst(RegExp(r'/+$'), '');
    openFileAt(
      ws,
      root: _root,
      path: WorkspacePath.normalize('$prefix/$normalized'),
      line: line,
      col: col,
    );
  }

  void _openAiLink(String href) {
    final target = parseWorkspaceFileHref(href);
    if (target == null) {
      copyText(href, what: '链接已复制（不会自动打开）');
      return;
    }
    _openAiFile(target.path, line: target.line, col: target.col);
  }

  void _openWork(
    String callId,
    String name,
    String input,
    String output,
    Map<String, dynamic> metadata,
    bool running,
    bool error,
  ) {
    final sid = _sessionId;
    if (sid == null) return;
    final key = '$sid:$callId';
    if (!widget.work.items.containsKey(key)) {
      widget.work.event({
        'type': running ? 'tool.running' : 'tool.done',
        'session_id': sid,
        'tool_call_id': callId,
        'tool_name': name,
        'input': input,
        'output': output,
        'metadata': metadata,
        'is_error': error,
      });
    }
    final item = widget.work.items[key];
    if (item != null) widget.work.openItem(item);
  }

  Widget _buildMessageItem(Ide ide, AiMessage msg) {
    if (msg.role == 'compaction') {
      final summary = msg.parts.firstOrNull?.text ?? '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.m),
        child: _CollapsibleBlock(
          icon: Icons.inventory_2_outlined,
          title: '上下文检查点摘要 (OpenCode Compaction)',
          accent: ide.accent,
          initiallyExpanded: false,
          child: SelectableText(
            summary,
            style: TextStyle(fontSize: 12.5, color: ide.textDim, height: 1.5),
          ),
        ),
      );
    }

    if (msg.role == 'user') {
      final text = msg.parts
          .map((p) => p.text)
          .where((s) => s.isNotEmpty)
          .join('\n\n');
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.l),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.l + 2,
            vertical: Space.m + 4,
          ),
          decoration: AiVisuals.surface(
            ide,
            fill: ide.surface.withValues(alpha: 0.85),
            edge: ide.borderStrong.withValues(alpha: 0.45),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: (msg.agent == 'plan' ? ide.warn : ide.accent)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(Radii.s),
                    ),
                    child: Text(
                      msg.agent == 'plan' ? '你 · 规划' : '你',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: msg.agent == 'plan' ? ide.warn : ide.accent,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (text.isNotEmpty)
                    IconBtn(
                      Icons.copy_outlined,
                      '复制提问',
                      () => copyText(text, what: '已复制'),
                      size: 13,
                    ),
                  if (!_running)
                    Tooltip(
                      message: '回退到此消息之前（恢复后续修改的文件）',
                      child: InkWell(
                        onTap: () => _revertTo(msg),
                        borderRadius: BorderRadius.circular(Radii.s),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.undo_rounded,
                                size: 13,
                                color: ide.textFaint,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '回退',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: ide.textFaint,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Space.xs + 2),
              if (text.isNotEmpty)
                SelectableText(
                  text,
                  style: TextStyle(
                    fontFamily: Ide.ui,
                    fontFamilyFallback: Ide.uiFallback,
                    fontSize: _chatFontSize,
                    color: ide.text,
                    height: 1.65,
                  ),
                ),
              for (final part in msg.parts)
                if (part.attachmentId.isNotEmpty && ws.link != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: AiAttachmentTile(
                      key: ValueKey(part.attachmentId),
                      part: part,
                      link: ws.link!,
                    ),
                  ),
            ],
          ),
        ),
      );
    }

    final resultMap = <String, AiPart>{
      for (final p in msg.parts)
        if (p.type == 'tool-result' && p.toolCallId.isNotEmpty) p.toolCallId: p,
    };

    final hasText = msg.parts.any(
      (p) => p.type == 'text' && p.text.trim().isNotEmpty,
    );
    final tokens = msg.usage?.totalTokens ?? 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.l + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (msg.role == 'assistant')
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      msg.runtime?.label ??
                          '未知提供商 / ${msg.model.isEmpty ? '未知模型' : msg.model}（未记录来源）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: ide.textDim),
                    ),
                  ),
                  if (tokens > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Tooltip(
                        message:
                            '输入 ${msg.usage!.inputTokens} · 输出 ${msg.usage!.outputTokens}',
                        child: Text(
                          tokens >= 1000
                              ? '${(tokens / 1000).toStringAsFixed(1)}k tok'
                              : '$tokens tok',
                          style: TextStyle(fontSize: 10.5, color: ide.textFaint),
                        ),
                      ),
                    ),
                  if (msg.finish == 'aborted')
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: ide.warn.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(Radii.s),
                      ),
                      child: Text(
                        '已停止',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          color: ide.warn,
                        ),
                      ),
                    ),
                  if (hasText)
                    IconBtn(
                      Icons.copy_outlined,
                      '复制回答',
                      () => copyText(
                        msg.parts
                            .where((p) => p.type == 'text')
                            .map((p) => p.text)
                            .join('\n\n'),
                        what: '回答已复制',
                      ),
                      size: 14,
                    ),
                ],
              ),
            ),
          for (final p in msg.parts)
            if (p.type == 'reasoning' && p.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s),
                child: _CollapsibleBlock(
                  icon: Icons.psychology_outlined,
                  title: '思考过程',
                  accent: ide.textDim,
                  initiallyExpanded: ws.app.aiSettings.expandReasoning,
                  child: SelectableText(
                    p.text.trim(),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: ide.textDim,
                      height: 1.5,
                    ),
                  ),
                ),
              )
            else if (p.type == 'text' && p.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s + 2),
                child: _MarkdownText(
                  text: p.text.trim(),
                  fontSize: _chatFontSize,
                  onOpenLink: _openAiLink,
                ),
              )
            else if (p.type == 'tool-call')
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s),
                child: _ToolCallCard(
                  name: p.toolName,
                  inputJson: p.inputJson,
                  output: resultMap[p.toolCallId]?.output ?? '',
                  isError: resultMap[p.toolCallId]?.isError ?? false,
                  expandErrors: ws.app.aiSettings.expandErrors,
                  running:
                      msg.finish == 'tool-running' &&
                      resultMap[p.toolCallId] == null,
                  attachments: resultMap[p.toolCallId]?.attachments ?? const [],
                  link: ws.link,
                  metadata: resultMap[p.toolCallId]?.metadata ?? const {},
                  onOpenFile: _openAiFile,
                  onOpen: p.toolName == 'shell' || p.toolName == 'subagent'
                      ? () => _openWork(
                          p.toolCallId,
                          p.toolName,
                          p.inputJson,
                          resultMap[p.toolCallId]?.output ?? '',
                          resultMap[p.toolCallId]?.metadata ?? const {},
                          false,
                          resultMap[p.toolCallId]?.isError ?? false,
                        )
                      : null,
                ),
              ),
          if (msg.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Notice(
                    tone: msg.errorCode.startsWith('budget.')
                        ? Tone.warn
                        : Tone.error,
                    title: msg.errorCode.startsWith('budget.')
                        ? '运行已暂停：预算不足'
                        : '模型请求中断或报错',
                    body: msg.error,
                  ),
                  if (msg.errorCode.startsWith('budget.')) ...[
                    if (msg.budget case final budget?)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: AiBudgetView(budget: budget),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () => _action('budget'),
                          child: const Text('调整预算'),
                        ),
                        OutlinedButton(
                          onPressed: _running ? null : _compactManual,
                          child: const Text('压缩上下文'),
                        ),
                        FilledButton(
                          onPressed: _running || _sending
                              ? null
                              : () =>
                                    _send('请根据已有结果继续完成任务，先检查已执行步骤，避免重复产生副作用。'),
                          child: const Text('继续任务（新预算）'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          if (msg.snapshot?.warning.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Notice(
                tone: Tone.warn,
                title: '本步骤的文件恢复点未完整建立',
                body: msg.snapshot!.warning,
                action: TextButton(
                  onPressed: () => _action('snapshots'),
                  child: const Text('检查快照设置'),
                ),
              ),
            ),
          if (msg.snapshot != null && msg.snapshot!.files.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: _StepDiffCard(
                files: msg.snapshot!.files,
                onOpenFile: _openAiFile,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLiveStep(Ide ide) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_liveCompaction.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s),
              child: _CollapsibleBlock(
                icon: Icons.compress_rounded,
                title: '正在生成检查点摘要…',
                accent: ide.accent,
                initiallyExpanded: true,
                child: SelectableText(
                  _liveCompaction,
                  style: TextStyle(fontSize: 12.5, color: ide.textDim),
                ),
              ),
            ),
          if (_liveReasoning.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s),
              child: _CollapsibleBlock(
                icon: Icons.psychology_outlined,
                title: '正在思考…',
                accent: ide.accent,
                initiallyExpanded: ws.app.aiSettings.expandReasoning,
                child: SelectableText(
                  _liveReasoning,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: ide.textDim,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          if (_liveText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s + 2),
              child: _MarkdownText(
                text: _liveText,
                fontSize: _chatFontSize,
                onOpenLink: _openAiLink,
              ),
            ),
          for (final t in _liveTools)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s),
              child: _ToolCallCard(
                name: t.name,
                inputJson: t.inputJson,
                output: t.output,
                isError: t.isError,
                expandErrors: ws.app.aiSettings.expandErrors,
                running: t.running,
                metadata: t.metadata,
                onOpenFile: _openAiFile,
                onOpen: t.name == 'shell' || t.name == 'subagent'
                    ? () => _openWork(
                        t.callId,
                        t.name,
                        t.inputJson,
                        t.output,
                        t.metadata,
                        t.running,
                        t.isError,
                      )
                    : null,
              ),
            ),
          if (_liveReasoning.isEmpty &&
              _liveText.isEmpty &&
              _liveTools.isEmpty &&
              _liveCompaction.isEmpty &&
              _running)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.s),
              child: Row(
                key: const ValueKey('ai-waiting'),
                children: [
                  if (_pendingPerm == null)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(Icons.pause_circle_outline, size: 15, color: ide.warn),
                  const SizedBox(width: Space.m),
                  Text(
                    _pendingPerm == null ? '正在等待模型响应…' : '等待你的批准后继续',
                    style: TextStyle(fontSize: 12.5, color: ide.textDim),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CollapsibleBlock extends StatefulWidget {
  final IconData icon;
  final String title;
  final Color accent;
  final bool initiallyExpanded;
  final Widget child;

  const _CollapsibleBlock({
    required this.icon,
    required this.title,
    required this.accent,
    required this.initiallyExpanded,
    required this.child,
  });

  @override
  State<_CollapsibleBlock> createState() => _CollapsibleBlockState();
}

class _CollapsibleBlockState extends State<_CollapsibleBlock> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return ClipRRect(
      borderRadius: AiVisuals.radius,
      child: Container(
        decoration: BoxDecoration(
          color: ide.sideBar.withValues(alpha: 0.55),
          border: Border(
            left: BorderSide(
              color: widget.accent.withValues(alpha: 0.6),
              width: 2.5,
            ),
            top: BorderSide(color: ide.border.withValues(alpha: 0.6)),
            right: BorderSide(color: ide.border.withValues(alpha: 0.6)),
            bottom: BorderSide(color: ide.border.withValues(alpha: 0.6)),
          ),
        ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(Radii.l),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.m,
                vertical: 6,
              ),
              child: Row(
                children: [
                  Icon(widget.icon, size: 14, color: widget.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: ide.textDim,
                      ),
                    ),
                  ),
                  Icon(
                    _open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: ide.textFaint,
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...[
            Divider(height: 1, color: ide.border.withValues(alpha: 0.6)),
            Padding(
              padding: const EdgeInsets.all(Space.m),
              child: widget.child,
            ),
          ],
        ],
      ),
      ),
    );
  }
}

class _ToolCallCard extends StatefulWidget {
  final String name;
  final String inputJson;
  final String output;
  final bool isError;
  final bool running;
  final Map<String, dynamic> metadata;
  final VoidCallback? onOpen;
  final ValueChanged<String>? onOpenFile;
  final List<AiPart> attachments;
  final Link? link;
  final bool expandErrors;

  const _ToolCallCard({
    required this.name,
    required this.inputJson,
    required this.output,
    required this.isError,
    required this.running,
    this.metadata = const {},
    this.onOpen,
    this.onOpenFile,
    this.attachments = const [],
    this.link,
    this.expandErrors = true,
  });

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  late bool _open = widget.isError && widget.expandErrors;

  @override
  void didUpdateWidget(covariant _ToolCallCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isError && widget.isError && widget.expandErrors) {
      _open = true;
    }
  }

  List<({String title, String url})> get _sources => [
    for (final s in (widget.metadata['sources'] as List? ?? const []))
      if (s is Map && (s['url'] as String? ?? '').isNotEmpty)
        (
          title: (s['title'] as String?) ?? (s['url'] as String),
          url: s['url'] as String,
        ),
  ];

  List<AiFileDiff> get _fileDiffs => [
    for (final f in (widget.metadata['files'] as List? ?? const []))
      if (f is Map) AiFileDiff.fromJson(f.cast<String, dynamic>()),
  ];

  String _host(String url) => Uri.tryParse(url)?.host ?? url;

  Map<String, dynamic> _parsedArgs() {
    if (widget.inputJson.isEmpty) return const {};
    try {
      final decoded = jsonDecode(widget.inputJson);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on Object {
      // ignore partial JSON
    }
    return const {};
  }

  String? _fileArg() {
    if (widget.name != 'read' &&
        widget.name != 'edit' &&
        widget.name != 'write') {
      return null;
    }
    final args = _parsedArgs();
    final path = (args['path'] ?? args['filePath'] ?? '').toString().trim();
    return path.isEmpty ? null : path;
  }

  (IconData, String) _summary() {
    final args = _parsedArgs();
    final found = _sources.length;
    final path = args['path'] ?? args['filePath'] ?? '';
    final range = args['offset'] != null
        ? ' · L${args['offset']}${args['limit'] != null ? '+${args['limit']}' : ''}'
        : '';
    return switch (widget.name) {
      'read' => (
        Icons.visibility_outlined,
        '读取 $path$range',
      ),
      'edit' => (
        Icons.edit_note_rounded,
        '编辑 $path',
      ),
      'write' => (
        Icons.save_outlined,
        '写入 $path',
      ),
      'apply_patch' => (Icons.difference_outlined, '应用多文件补丁'),
      'question' => (Icons.help_outline, '询问用户'),
      'glob' => (
        Icons.manage_search_rounded,
        '匹配文件 ${args['pattern'] ?? ''}${path != '' ? ' · $path' : ''}',
      ),
      'grep' => (
        Icons.search_rounded,
        '搜索内容 ${args['pattern'] ?? ''}${path != '' ? ' · $path' : ''}',
      ),
      'shell' => (Icons.terminal_rounded, '\$ ${args['command'] ?? ''}'),
      'todowrite' => (Icons.checklist_rounded, '更新任务清单'),
      'websearch' => (
        Icons.travel_explore_rounded,
        '联网搜索「${args['query'] ?? ''}」${!widget.running && found > 0 ? ' · $found 个结果' : ''}',
      ),
      'webfetch' => (
        Icons.language_rounded,
        '抓取网页 ${args['url'] == null ? '' : _host('${args['url']}')}',
      ),
      'subagent' => (
        Icons.account_tree_outlined,
        '子智能体 (${args['agent'] ?? 'explore'}): ${args['description'] ?? ''}',
      ),
      _ => (Icons.extension_outlined, widget.name),
    };
  }

  Widget _sourceList(Ide ide) {
    final list = _sources;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < list.length; i++)
          InkWell(
            key: ValueKey('ai-source-$i'),
            onTap: () => copyText(list[i].url, what: '链接已复制（不会自动打开）'),
            borderRadius: BorderRadius.circular(Radii.s),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: ide.accentSoft,
                      borderRadius: BorderRadius.circular(Radii.s),
                    ),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: ide.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          list[i].title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: ide.text,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          _host(list[i].url),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: ide.textFaint),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.copy_rounded, size: 12, color: ide.textFaint),
                ],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final (icon, label) = _summary();
    final diffs = _fileDiffs;
    final fileArg = _fileArg();
    final statusColor = widget.running
        ? ide.accent
        : widget.isError
        ? ide.error
        : ide.ok;

    return AnimatedContainer(
      duration: UiMotion.hover,
      curve: UiMotion.enterCurve,
      decoration: AiVisuals.surface(
        ide,
        fill: ide.surface.withValues(alpha: 0.72),
        edge: widget.isError
            ? ide.error.withValues(alpha: 0.45)
            : ide.border.withValues(alpha: 0.85),
      ),
      child: AnimatedSize(
        duration: UiMotion.expand,
        curve: UiMotion.enterCurve,
        alignment: Alignment.topCenter,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(Radii.m + 2),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.m,
                vertical: 7,
              ),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: statusColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontFamily: widget.name == 'shell' ? Ide.mono : null,
                        fontFamilyFallback: widget.name == 'shell'
                            ? Ide.monoFallback
                            : null,
                        color: ide.text,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (diffs.isNotEmpty) ...[
                    Builder(
                      builder: (_) {
                        var add = 0, del = 0;
                        for (final f in diffs) {
                          add += f.additions;
                          del += f.deletions;
                        }
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (add > 0)
                              Text(
                                '+$add',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: ide.ok,
                                ),
                              ),
                            if (del > 0) ...[
                              const SizedBox(width: 3),
                              Text(
                                '-$del',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: ide.error,
                                ),
                              ),
                            ],
                            const SizedBox(width: 6),
                          ],
                        );
                      },
                    ),
                  ],
                  AiStatusMark(
                    widget.running
                        ? AiWorkStatus.running
                        : widget.isError
                        ? AiWorkStatus.error
                        : AiWorkStatus.completed,
                    label: false,
                  ),
                  if (widget.onOpen != null)
                    IconButton(
                      tooltip: widget.name == 'subagent' ? '查看子代理会话' : '查看命令输出',
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 26,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: widget.onOpen,
                      icon: const Icon(Icons.open_in_full, size: 14),
                    )
                  else if (fileArg != null && widget.onOpenFile != null)
                    IconButton(
                      tooltip: '在编辑器中打开',
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 26,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: () => widget.onOpenFile!(fileArg),
                      icon: const Icon(Icons.open_in_new_rounded, size: 14),
                    ),
                  Icon(
                    _open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: ide.textFaint,
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...[
            Divider(height: 1, color: ide.border),
            Padding(
              padding: const EdgeInsets.all(Space.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.link != null)
                    for (final attachment in widget.attachments)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: AiAttachmentTile(
                          part: attachment,
                          link: widget.link!,
                        ),
                      ),
                  if (diffs.isNotEmpty) ...[
                    _DiffFileList(
                      files: diffs,
                      onOpenFile: widget.onOpenFile,
                    ),
                  ] else if (widget.name == 'websearch' && _sources.isNotEmpty) ...[
                    Text(
                      '来源',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: ide.textFaint,
                      ),
                    ),
                    const SizedBox(height: 3),
                    _sourceList(ide),
                    const SizedBox(height: Space.s),
                  ] else if (widget.inputJson.isNotEmpty) ...[
                    Text(
                      '参数',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: ide.textFaint,
                      ),
                    ),
                    const SizedBox(height: 3),
                    SelectableText(
                      widget.inputJson,
                      style: TextStyle(
                        fontFamily: Ide.mono,
                        fontFamilyFallback: Ide.monoFallback,
                        fontSize: 11.5,
                        color: ide.textDim,
                      ),
                    ),
                    const SizedBox(height: Space.s),
                  ],
                  if (widget.output.isNotEmpty) ...[
                    Text(
                      '输出',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: ide.textFaint,
                      ),
                    ),
                    const SizedBox(height: 3),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          widget.output,
                          style: TextStyle(
                            fontFamily: Ide.mono,
                            fontFamilyFallback: Ide.monoFallback,
                            fontSize: 11.5,
                            color: widget.isError ? ide.error : ide.text,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }
}

class _DiffFileList extends StatelessWidget {
  final List<AiFileDiff> files;
  final ValueChanged<String>? onOpenFile;
  const _DiffFileList({required this.files, this.onOpenFile});

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in files) ...[
          Row(
            children: [
              FileIcon(
                name: f.file.split('/').last,
                size: 13,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  f.file,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: ide.text,
                  ),
                ),
              ),
              Text(
                '+${f.additions}',
                style: TextStyle(
                  fontSize: 11,
                  color: ide.ok,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '-${f.deletions}',
                style: TextStyle(
                  fontSize: 11,
                  color: ide.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (onOpenFile != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '在编辑器中打开',
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 22,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: () => onOpenFile!(f.file),
                  icon: Icon(
                    Icons.open_in_new_rounded,
                    size: 13,
                    color: ide.textDim,
                  ),
                ),
              ],
            ],
          ),
          if (f.patch.isNotEmpty) ...[
            const SizedBox(height: 4),
            Container(
              constraints: const BoxConstraints(maxHeight: 240),
              decoration: BoxDecoration(
                color: ide.editor,
                borderRadius: BorderRadius.circular(Radii.s),
                border: Border.all(color: ide.border),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final line in withoutFileHeader(parseDiff(f.patch)))
                      Container(
                        color: switch (line.kind) {
                          DiffLineKind.add => ide.ok.withValues(alpha: 0.12),
                          DiffLineKind.del => ide.error.withValues(alpha: 0.12),
                          _ => Colors.transparent,
                        },
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: SelectableText(
                          '${switch (line.kind) {
                            DiffLineKind.add => '+',
                            DiffLineKind.del => '-',
                            DiffLineKind.context => ' ',
                            _ => '',
                          }}${line.text}',
                          style: TextStyle(
                            fontFamily: Ide.mono,
                            fontFamilyFallback: Ide.monoFallback,
                            fontSize: 11,
                            height: 1.4,
                            color: switch (line.kind) {
                              DiffLineKind.add => ide.ok,
                              DiffLineKind.del => ide.error,
                              DiffLineKind.hunk => ide.accent,
                              _ => ide.textDim,
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: Space.s),
        ],
      ],
    );
  }
}

class _StepDiffCard extends StatefulWidget {
  final List<AiFileDiff> files;
  final ValueChanged<String>? onOpenFile;
  const _StepDiffCard({required this.files, this.onOpenFile});

  @override
  State<_StepDiffCard> createState() => _StepDiffCardState();
}

class _StepDiffCardState extends State<_StepDiffCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    var add = 0, del = 0;
    for (final f in widget.files) {
      add += f.additions;
      del += f.deletions;
    }
    return Container(
      decoration: BoxDecoration(
        color: ide.sideBar.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.m + 2),
        border: Border.all(color: ide.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(Radii.m + 2),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.m,
                vertical: 6,
              ),
              child: Row(
                children: [
                  Icon(Icons.difference_outlined, size: 14, color: ide.accent),
                  const SizedBox(width: 6),
                  Text(
                    '本步变更 ${widget.files.length} 个文件',
                    style: TextStyle(fontSize: 12, color: ide.text),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '+$add',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: ide.ok,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '-$del',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: ide.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: ide.textFaint,
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...[
            Divider(height: 1, color: ide.border),
            Padding(
              padding: const EdgeInsets.all(Space.m),
              child: _DiffFileList(
                files: widget.files,
                onOpenFile: widget.onOpenFile,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MarkdownText extends StatelessWidget {
  final String text;
  final double fontSize;
  final ValueChanged<String>? onOpenLink;
  const _MarkdownText({
    required this.text,
    this.fontSize = 15,
    this.onOpenLink,
  });

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final blocks = _splitFencedBlocks(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in blocks)
          if (b.isCode)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: ide.sideBar,
                borderRadius: BorderRadius.circular(Radii.m + 2),
                border: Border.all(color: ide.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.m,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: ide.border)),
                    ),
                    child: Row(
                      children: [
                        Text(
                          b.lang.isEmpty ? 'code' : b.lang,
                          style: TextStyle(fontSize: 11, color: ide.textFaint),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () => copyText(b.content, what: '已复制代码'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.copy_rounded,
                                  size: 12,
                                  color: ide.textDim,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '复制',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: ide.textDim,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(Space.m),
                    child: SelectableText(
                      b.content,
                      style: TextStyle(
                        fontFamily: Ide.mono,
                        fontFamilyFallback: Ide.monoFallback,
                        fontSize: fontSize - 1,
                        color: ide.text,
                        height: 1.6,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (b.content.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: MarkdownBody(
                data: b.content.trim(),
                selectable: true,
                styleSheet: _chatMarkdownStyle(context, ide),
                imageBuilder: (uri, title, alt) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '[图片未加载${alt == null || alt.isEmpty ? '' : '：$alt'}]',
                    style: TextStyle(
                      color: ide.textDim,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                onTapLink: (text, href, title) {
                  if (href == null) return;
                  if (onOpenLink != null) {
                    onOpenLink!(href);
                  } else {
                    copyText(href, what: '链接已复制（不会自动打开）');
                  }
                },
              ),
            ),
      ],
    );
  }

  MarkdownStyleSheet _chatMarkdownStyle(BuildContext context, Ide ide) {
    final body = TextStyle(
      fontFamily: Ide.ui,
      fontFamilyFallback: Ide.uiFallback,
      color: ide.text,
      fontSize: fontSize,
      height: 1.7,
    );
    final mono = TextStyle(
      fontFamily: Ide.mono,
      fontFamilyFallback: Ide.monoFallback,
      fontSize: fontSize - 1,
      color: ide.text,
      height: 1.5,
    );
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: body,
      h1: body.copyWith(
        fontSize: fontSize * 1.35,
        fontWeight: FontWeight.w600,
        height: 1.5,
      ),
      h2: body.copyWith(
        fontSize: fontSize * 1.2,
        fontWeight: FontWeight.w600,
        height: 1.5,
      ),
      h3: body.copyWith(
        fontSize: fontSize * 1.1,
        fontWeight: FontWeight.w600,
        height: 1.5,
      ),
      h4: body.copyWith(fontWeight: FontWeight.w600, height: 1.5),
      strong: TextStyle(color: ide.text, fontWeight: FontWeight.w700),
      em: TextStyle(color: ide.text, fontStyle: FontStyle.italic),
      listBullet: body.copyWith(color: ide.textDim),
      code: mono.copyWith(backgroundColor: ide.hover),
      codeblockDecoration: BoxDecoration(
        color: ide.sideBar,
        borderRadius: BorderRadius.circular(Radii.m),
      ),
      blockquoteDecoration: BoxDecoration(
        color: ide.hover.withValues(alpha: 0.4),
        border: Border(left: BorderSide(color: ide.accent, width: 3)),
      ),
      a: TextStyle(color: ide.accent),
      tableBorder: TableBorder.all(color: ide.border),
      tableHead: body.copyWith(fontWeight: FontWeight.w600),
      tableBody: body.copyWith(fontSize: fontSize - 1),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: ide.border)),
      ),
    );
  }

  List<({bool isCode, String lang, String content})> _splitFencedBlocks(
    String src,
  ) {
    final out = <({bool isCode, String lang, String content})>[];
    final re = RegExp(r'```([^\n`]*)\n([\s\S]*?)```');
    var cursor = 0;
    for (final m in re.allMatches(src)) {
      if (m.start > cursor) {
        out.add((
          isCode: false,
          lang: '',
          content: src.substring(cursor, m.start),
        ));
      }
      out.add((
        isCode: true,
        lang: (m.group(1) ?? '').trim(),
        content: (m.group(2) ?? '').trimRight(),
      ));
      cursor = m.end;
    }
    if (cursor < src.length) {
      out.add((isCode: false, lang: '', content: src.substring(cursor)));
    }
    return out;
  }
}
