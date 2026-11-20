part of 'ai_studio_view.dart';

extension _DialogsView on _AiStudioViewState {
  Future<void> _showInbox() => showPicker<void>(
    context,
    maxWidth: 540,
    maxHeight: 560,
    builder: (dialogContext) => ListenableBuilder(
      listenable: _inboxChanges,
      builder: (dialogContext, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _running ? '待发送与保留的输入' : '任务已停止 · 输入已保留',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (_inboxBusy) const LinearProgressIndicator(minHeight: 2),
            if (_inboxError != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  _inboxError!,
                  style: TextStyle(color: Ide.of(context).error, fontSize: 12),
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final item in _inbox)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SelectableText(
                            (item['text'] as String? ?? '').trim().isEmpty
                                ? '附件输入'
                                : item['text'] as String,
                            style: const TextStyle(fontSize: 13),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${item['held'] == true || !_running
                                ? '已保留 · 等待重新发送'
                                : item['delivery'] == 'queue'
                                ? '当前任务结束后'
                                : '下一步优先'}\n'
                            '${(item['runtime'] as Map?)?['provider_name'] ?? ''} / ${(item['runtime'] as Map?)?['model'] ?? '已选模型'}'
                            ' · ${item['agent'] == 'plan' ? '规划' : item['agent'] == 'orchestrator' ? '编排' : '构建'} · ${AiComposerText.permission(item['permission_mode'] as String? ?? 'ask', narrow: false)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Ide.of(context).textDim,
                            ),
                          ),
                          for (final attachment
                              in (item['attachments'] as List? ?? [])
                                  .whereType<Map>())
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '附件 · ${attachment['label'] ?? '未命名附件'}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Ide.of(context).textDim,
                                ),
                              ),
                            ),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            children: [
                              if (!_running)
                                TextButton(
                                  onPressed: _inboxBusy || _sending
                                      ? null
                                      : () {
                                          Navigator.pop(dialogContext);
                                          _send('', item['id'] as String);
                                        },
                                  child: const Text('用当前选择重新发送'),
                                ),
                              if (_running &&
                                  item['held'] != true &&
                                  item['delivery'] == 'queue')
                                TextButton(
                                  onPressed: _inboxBusy
                                      ? null
                                      : () => _changeInbox(
                                          item['id'] as String,
                                          'steer',
                                        ),
                                  child: const Text('改为补充'),
                                ),
                              TextButton(
                                onPressed: _inboxBusy
                                    ? null
                                    : () => _changeInbox(
                                        item['id'] as String,
                                        'cancel',
                                      ),
                                child: const Text('移除'),
                              ),
                            ],
                          ),
                          const Divider(height: 1),
                        ],
                      ),
                    ),
                  if (_inbox.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('没有待发送输入'),
                    ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
            ),
          ],
        );
      },
    ),
  );

  Future<void> _showComposerAttachments() => showPicker<void>(
    context,
    maxWidth: 520,
    maxHeight: 460,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, update) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '本条消息的附件',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final attachment in _attachments)
                  ListTile(
                    leading: FileIcon(
                      name: attachment.label,
                      size: 18,
                    ),
                    title: Text(attachment.label),
                    subtitle: Text(
                      attachment.bytes == null
                          ? '文本上下文'
                          : '${(attachment.bytes!.length / 1024).toStringAsFixed(0)} KiB',
                    ),
                    trailing: IconButton(
                      tooltip: '移除 ${attachment.label}',
                      onPressed: () {
                        _set(() {
                          _attachments.remove(attachment);
                          _uploadedAttachments.remove(attachment);
                        });
                        update(() {});
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ),
                if (_attachments.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('没有待发送附件'),
                  ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('完成'),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _showDetailsDialog() => showPicker<void>(
    context,
    maxWidth: 520,
    maxHeight: 520,
    builder: (_) => ListenableBuilder(
      listenable: _runtimeChanges,
      builder: (_, _) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: _buildRuntimeBar(Ide.of(context), _activeProvider),
      ),
    ),
  );

  Future<void> _showNavigateDialog() => showWorkbenchDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('跳转到消息'),
      content: SizedBox(
        width: 520,
        child: _buildMessageNavigation(
          Ide.of(context),
          (_session?.messages ?? const <AiMessage>[])
              .where((m) => !m.isSystemReminder)
              .toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Widget _buildRuntimeBar(Ide ide, AiProvider? prov) {
    final runtime = _session?.runtime;
    final ctx = _session?.context;
    final usage = _session?.totalUsage;
    final ratio = ctx?.ratio;
    final color = ratio != null && ratio >= 1
        ? ide.error
        : ratio != null && ratio >= 0.85
        ? ide.warn
        : ide.accent;
    final actual =
        runtime?.label ??
        (_session?.model.isNotEmpty == true
            ? '未知提供商 / ${_session!.model}（旧会话）'
            : '尚未调用模型');
    final guessed =
        ctx != null && ctx.limit > 0 && ctx.limitSource != 'configured';
    final contextText = ctx == null
        ? '上下文：暂无统计（旧 agent / 尚未调用）'
        : '上下文 ${ctx.estimated ? '≈' : ''}${_fmtTokens(ctx.tokens)} / ${ctx.limit > 0 ? '${guessed ? '约 ' : ''}${_fmtTokens(ctx.limit)}' : '未知'} tokens${ratio != null ? ' · ${(ratio * 100).toStringAsFixed(1)}%' : ''}${guessed ? '（上限为估计值）' : ''}';
    return Container(
      key: const ValueKey('ai-runtime-bar'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Space.l),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ide.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message:
                        '本步实际发送的提供商配置与模型 ID；网关可能自行映射模型，无法认证其内部模型身份。\n$actual',
                    child: Text(
                      '${_running ? '本步实际' : '最近实际'}：$actual',
                      key: const ValueKey('ai-actual-model'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: ide.textDim),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Tooltip(
                  message: contextText,
                  child: Text(
                    ratio == null
                        ? '暂无统计'
                        : '${(ratio * 100).round()}% 上下文',
                    style: TextStyle(fontSize: 11.5, color: color),
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: _running || _session == null ? null : _compactManual,
                  child: const Text('压缩上下文'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (prov != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '下次调用：${prov.name} / ${prov.model}',
                      key: const ValueKey('ai-next-model'),
                      style: TextStyle(fontSize: 11.5, color: ide.textDim),
                    ),
                  ),
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Tooltip(
                      message: ctx == null
                          ? '需新版 agent；累计用量不代表当前上下文。'
                          : '活动上下文估算（包括系统提示、工具定义、回答与工具输出），不含尚未发送的输入。图片/PDF 使用粗略估值，不按 base64 长度计算。\n上次实际输入：${ctx.lastInput > 0 ? '${ctx.lastInput} tokens（已含缓存）' : '暂无 / 已压缩或回退'}\n上限来源：${ctx.limitSource == 'configured' ? '目录 / 手动配置' : '模型默认输入预算（可能与真实窗口不同）'}。\n压缩后重新估算；累计用量另列。',
                      child: Text(
                        contextText,
                        key: const ValueKey('ai-context-usage'),
                        style: TextStyle(fontSize: 11.5, color: color),
                      ),
                    ),
                    if (usage != null && usage.totalTokens > 0)
                      Tooltip(
                        message:
                            '累计输入 ${usage.inputTokens}（含缓存 ${usage.cacheReadTokens}）· 输出 ${usage.outputTokens}',
                        child: Text(
                          '累计用量 ${_fmtTokens(usage.totalTokens)} tokens',
                          key: const ValueKey('ai-total-usage'),
                          style: TextStyle(fontSize: 11, color: ide.textFaint),
                        ),
                      ),
                  ],
                ),
                if (ratio != null) ...[
                  const SizedBox(height: 5),
                  LinearProgressIndicator(
                    value: ratio.clamp(0.0, 1.0),
                    minHeight: 3,
                    color: color,
                    backgroundColor: ide.border,
                  ),
                ],
                const SizedBox(height: 8),
                if (_session?.budget case final budget?)
                  ExpansionTile(
                    key: const ValueKey('ai-budget-details'),
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      budget.summary,
                      style: TextStyle(
                        fontSize: 12,
                        color: budget.blockedBy.isEmpty ? ide.textDim : ide.warn,
                      ),
                    ),
                    subtitle: const Text(
                      '运行预算 · 点击查看明细',
                      style: TextStyle(fontSize: 11),
                    ),
                    children: [
                      AiBudgetView(
                        budget: budget,
                        onConfigure: () => _action('budget'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}
