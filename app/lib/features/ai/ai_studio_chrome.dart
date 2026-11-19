part of 'ai_studio_view.dart';

extension _ChromeView on _AiStudioViewState {
  Widget _buildWorkspaceBar(Ide ide, {bool compact = false}) {
    final canPick =
        !_sending && (_session == null || _session!.messages.isEmpty);
    final native = ws.entry?.isLocal == true
        ? ws.app.localAgent.nativePath(_root, _workdir)
        : '$_root : $_workdir';
    final label = _workdir == '/'
        ? '根目录'
        : _workdir.split('/').where((p) => p.isNotEmpty).lastOrNull ?? _workdir;
    final statusColor = _pendingPerm != null || _pendingQuestion != null
        ? ide.warn
        : _running
        ? ide.accent
        : ide.ok;
    final statusText = _pendingQuestion != null
        ? '等待回答'
        : _pendingPerm != null
        ? '等待批准'
        : _running
        ? '运行中'
        : _session == null
        ? '新会话'
        : '已就绪';
    return Container(
      key: const ValueKey('ai-workspace-bar'),
      padding: EdgeInsets.symmetric(
        horizontal: Space.l,
        vertical: compact ? 3 : 6,
      ),
      decoration: BoxDecoration(
        color: ide.tabBar,
        border: Border(
          bottom: BorderSide(color: ide.border.withValues(alpha: 0.75)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.folder_open_rounded, size: 14, color: ide.accent),
          const SizedBox(width: 6),
          Expanded(
            child: canPick
                ? WorkbenchMenuButton<AiPathChoice>(
                    key: const ValueKey('ai-workdir-menu'),
                    enabled: canPick,
                    tooltip: '$native\n点击更换工作目录',
                    padding: EdgeInsets.zero,
                    onSelected: (choice) {
                      if (choice.root == '*browse*') {
                        _pickWorkdir();
                      } else {
                        _set(() {
                          _root = choice.root;
                          _workdir = choice.path;
                        });
                      }
                    },
                    itemBuilder: (_) => [
                      for (final folder
                          in ws.project?.folders ?? const <WorkspacePath>[])
                        PopupMenuItem(
                          value: AiPathChoice(
                            folder.root,
                            folder.path,
                            folder.path,
                          ),
                          child: Text('项目：${folder.path}'),
                        ),
                      for (final r in _roots)
                        PopupMenuItem(
                          value: AiPathChoice(r['id'] as String, '/', '/'),
                          child: Text('${r['label'] ?? r['id']} /'),
                        ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: const AiPathChoice('*browse*', '', ''),
                        child: MenuLabel(
                          ws.entry?.isLocal == true ? '浏览本机目录…' : '浏览服务器目录…',
                          icon: Icons.folder_open_outlined,
                        ),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Tooltip(
                              message: native,
                              child: Text(
                                compact ? label : native,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w500,
                                  color: ide.text,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.expand_more_rounded,
                            size: 15,
                            color: ide.textDim,
                          ),
                        ],
                      ),
                    ),
                  )
                : Tooltip(
                    message: native,
                    child: Text(
                      compact ? label : native,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: ide.text,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: _session?.budget?.summary ?? statusText,
            child: InkWell(
              key: const ValueKey('ai-run-budget-summary'),
              onTap: () => _action('details'),
              borderRadius: BorderRadius.circular(UiMetrics.controlRadius),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: AiVisuals.badge(ide, statusColor, alpha: 0.10),
                child: Row(
                  key: const ValueKey('ai-context-indicator'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: statusColor,
                      ),
                    ),
                    if (_session?.context?.ratio case final double ratio) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${(ratio * 100).round()}%',
                        style: TextStyle(
                          fontSize: 11,
                          color: ratio >= .85 ? ide.warn : ide.textDim,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          _buildConversationActions(ide),
        ],
      ),
    );
  }

  Widget _buildConversationActions(Ide ide) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.primary && !widget.work.showNavigation)
          IconBtn(
            Icons.checklist,
            '任务',
            () => widget.work.select('tasks'),
            key: const ValueKey('ai-work-list'),
            size: 15,
          ),
        if (widget.primary && (_session?.parentId.isNotEmpty ?? false))
          IconBtn(
            Icons.subdirectory_arrow_left_rounded,
            '返回上级代理',
            () => ws.openTab(
              aiStudioTab(ws, sessionId: _session!.parentId, title: '上级代理'),
            ),
            size: 16,
          ),
        SizedBox(
          width: 28,
          child: WorkbenchMenuButton<String>(
            key: const ValueKey('ai-chat-font'),
            tooltip: '对话选项',
            padding: EdgeInsets.zero,
            onSelected: _action,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'navigate', child: Text('跳转到消息…')),
              const PopupMenuItem(value: 'latest', child: Text('回到最新消息')),
              const PopupMenuItem(
                value: 'send-options',
                child: Text('此对话的执行策略…'),
              ),
              if (_sessionId != null &&
                  ws.link?.server.caps.contains('ai.permissions') == true)
                const PopupMenuItem(value: 'grants', child: Text('本会话授权…')),
              const PopupMenuItem(value: 'details', child: Text('人设与上下文详情')),
              PopupMenuItem(
                value: 'compact',
                enabled: !_running && (_session?.messages.isNotEmpty ?? false),
                child: const Text('压缩上下文'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                key: ValueKey('ai-settings-open'),
                value: 'settings',
                child: MenuLabel('AI 设置', icon: Icons.settings_outlined),
              ),
              const PopupMenuItem(value: 'smaller', child: Text('缩小字号')),
              const PopupMenuItem(value: 'larger', child: Text('增大字号')),
              const PopupMenuItem(value: 'reset', child: Text('还原字号 · 15 px')),
            ],
            icon: Icon(Icons.more_horiz, size: 17, color: ide.textDim),
          ),
        ),
      ],
    );
  }

  Widget _buildMessageNavigation(
    Ide ide,
    List<AiMessage> messages, {
    bool floating = false,
  }) {
    final pill = Container(
      key: floating ? const ValueKey('ai-message-navigation') : null,
      constraints: floating ? const BoxConstraints(maxWidth: 268) : null,
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: floating
          ? BoxDecoration(
              color: ide.sideBar.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: ide.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            )
          : null,
      child: ValueListenableBuilder<String?>(
        valueListenable: _scrollCtl.currentMessage,
        builder: (_, current, _) {
          final index = messages.indexWhere((m) => m.id == current);
          final at = index < 0 ? messages.length - 1 : index;
          String label(AiMessage m) {
            final text = m.parts
                .where((p) => p.type == 'text')
                .map((p) => p.text)
                .join(' ')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            return '${m.role == 'user'
                ? '你'
                : m.role == 'assistant'
                ? 'AI'
                : '检查点'} · ${text.isEmpty ? '工具与执行记录' : text}';
          }

          return Row(
            mainAxisSize: floating ? MainAxisSize.min : MainAxisSize.max,
            children: [
              IconButton(
                key: floating ? const ValueKey('ai-previous-message') : null,
                tooltip: '上一条消息（Alt+↑）',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 24,
                  height: 24,
                ),
                onPressed: at > 0
                    ? () => _scrollCtl.reveal(messages[at - 1].id)
                    : null,
                icon: const Icon(Icons.arrow_upward_rounded, size: 14),
              ),
              Flexible(
                fit: floating ? FlexFit.loose : FlexFit.tight,
                child: WorkbenchMenuButton<String>(
                  key: floating ? const ValueKey('ai-message-anchors') : null,
                  tooltip: '对话锚点 · 跳转到消息',
                  onSelected: _scrollCtl.reveal,
                  itemBuilder: (_) => [
                    for (var i = 0; i < messages.length; i++)
                      PopupMenuItem(
                        value: messages[i].id,
                        child: SizedBox(
                          width: 300,
                          child: Text(
                            '${i + 1}. ${label(messages[i])}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      messages.isEmpty
                          ? '对话锚点'
                          : '${at + 1}/${messages.length}  ${label(messages[at])}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: ide.textDim),
                    ),
                  ),
                ),
              ),
              IconButton(
                key: floating ? const ValueKey('ai-next-message') : null,
                tooltip: '下一条消息（Alt+↓）',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 24,
                  height: 24,
                ),
                onPressed: at >= 0 && at < messages.length - 1
                    ? () => _scrollCtl.reveal(messages[at + 1].id)
                    : null,
                icon: const Icon(Icons.arrow_downward_rounded, size: 14),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _scrollCtl.followsLatest,
                builder: (_, follows, _) => IconButton(
                  key: floating ? const ValueKey('ai-jump-latest') : null,
                  tooltip: follows ? '已在最新消息' : '回到最新消息',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 24,
                  ),
                  onPressed: () => _scrollToBottom(force: true),
                  icon: Icon(
                    Icons.vertical_align_bottom_rounded,
                    size: 14,
                    color: follows ? ide.textFaint : ide.accent,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    return pill;
  }

  Widget _buildEmptyWelcome(Ide ide, AiProvider? prov) {
    final hasKey = prov != null && prov.model.isNotEmpty;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline, size: 22, color: ide.textDim),
              const SizedBox(height: Space.m),
              Text(
                '新对话',
                style: TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w600,
                  color: ide.text,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                hasKey ? '从一个问题开始，或把下面的示例填入输入框。' : '配置连接和 Persona 后即可开始。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: ide.textDim,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: Space.l),
              if (!hasKey)
                FilledButton.icon(
                  key: const ValueKey('ai-configure-btn'),
                  onPressed: () => _action('settings'),
                  icon: const Icon(Icons.key_rounded, size: 16),
                  label: const Text('连接模型'),
                )
              else if (ws.app.aiSettings.showQuickPrompts)
                Wrap(
                  spacing: Space.s + 2,
                  runSpacing: Space.s + 2,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final (icon, label, prompt) in [
                      (
                        Icons.explore_outlined,
                        '梳理项目结构',
                        '请快速浏览当前目录结构与核心代码，总结架构与技术栈。',
                      ),
                      if (ws.entry?.isLocal == true)
                        (
                          Icons.fact_check_outlined,
                          '检查测试与构建问题',
                          '请检查当前项目的测试、静态分析或构建问题，并给出修复建议。',
                        )
                      else
                        (
                          Icons.monitor_heart_outlined,
                          '排查服务器负载与日志',
                          '请检查当前服务器的 CPU、内存、磁盘状态及近期异常服务日志，给出诊断建议。',
                        ),
                      (
                        Icons.bug_report_outlined,
                        '查找潜在问题',
                        '请检查最近修改的代码与 git 状态，看看是否有明显的 bug、构建错误或遗漏。',
                      ),
                    ])
                      TextButton.icon(
                        icon: Icon(icon, size: 15, color: ide.textDim),
                        label: Text(
                          label,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () {
                          final current = _inputCtl.text;
                          final draft = current.trim().isEmpty
                              ? prompt
                              : '$current\n\n$prompt';
                          _inputCtl.value = TextEditingValue(
                            text: draft,
                            selection: TextSelection.collapsed(
                              offset: draft.length,
                            ),
                          );
                          _inputFocus.requestFocus();
                        },
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTodoBanner(Ide ide, List<AiTodoItem> todos) {
    final done = todos.where((t) => t.status == 'completed').length;
    final ratio = todos.isEmpty ? 0.0 : done / todos.length;
    return Container(
      width: double.infinity,
      key: const ValueKey('ai-active-plan'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: ide.sideBar.withValues(alpha: 0.78),
        border: Border(top: BorderSide(color: ide.border)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () => _set(() => _planExpanded = !_planExpanded),
                child: SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      Icon(
                        Icons.checklist_rounded,
                        size: 14,
                        color: ide.accent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '任务进度 ($done/${todos.length})',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: ide.text,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 44,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: ratio,
                            minHeight: 4,
                            color: ide.accent,
                            backgroundColor: ide.border,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          todos
                                  .where((t) => t.status == 'in_progress')
                                  .firstOrNull
                                  ?.content ??
                              '计划进行中',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: ide.textDim),
                        ),
                      ),
                      Icon(
                        _planExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 16,
                        color: ide.textDim,
                      ),
                    ],
                  ),
                ),
              ),
              if (_planExpanded)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 140),
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final t in todos)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3.5),
                            child: Row(
                              children: [
                                Icon(
                                  t.status == 'completed'
                                      ? Icons.check_circle_rounded
                                      : t.status == 'in_progress'
                                      ? Icons.timelapse_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  size: 13,
                                  color: t.status == 'completed'
                                      ? ide.ok
                                      : t.status == 'in_progress'
                                      ? ide.accent
                                      : ide.textFaint,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    t.content,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: t.status == 'completed'
                                          ? ide.textDim
                                          : ide.text,
                                      decoration: t.status == 'completed'
                                          ? TextDecoration.lineThrough
                                          : null,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionDocks(Ide ide, {required bool compact}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_pendingQuestion != null)
          _DockPromptBar(
            key: const ValueKey('ai-question-open'),
            icon: Icons.help_outline_rounded,
            color: ide.warn,
            label: '需要你的选择 · 点击回答',
            onTap: () => _action('question'),
          ),
        if (_pendingQuestion == null && _childQuestions.isNotEmpty)
          _DockPromptBar(
            key: const ValueKey('ai-child-question-open'),
            icon: Icons.help_outline_rounded,
            color: ide.warn,
            label: '子代理需要你的回答 · 打开',
            onTap: () => widget.work.openSession(_childQuestions.first),
          ),
        if (_pendingPerm != null)
          _buildApprovalDock(ide, _pendingPerm!, compact: compact),
        if (_inbox.isNotEmpty)
          _DockPromptBar(
            key: const ValueKey('ai-inbox-open'),
            icon: Icons.schedule_send_outlined,
            color: ide.accent,
            label: '${_inbox.length} 条${_running ? '待发送输入' : '保留的输入'} · 查看',
            onTap: () => _action('inbox'),
          ),
      ],
    );
  }

  Widget _buildApprovalDock(
    Ide ide,
    AiPermissionQuestion q, {
    required bool compact,
  }) {
    final card = AiPermissionCard(
      question: q,
      workdir: ws.entry?.isLocal == true
          ? ws.app.localAgent.nativePath(_root, _workdir)
          : _workdir,
      compact: true,
      busy: _approvalBusy,
      onDetails: () => showWorkbenchDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          insetPadding: const EdgeInsets.all(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780, maxHeight: 620),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    child: AiPermissionCard(
                      question: q,
                      workdir: _workdir,
                      showActions: false,
                      onDecide: ({required bool allow, bool always = false}) {},
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('返回审批'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      onDecide: ({required bool allow, bool always = false}) =>
          _approve(q, allow: allow, always: always),
    );
    return Container(
      key: const ValueKey('ai-approval-dock'),
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      decoration: BoxDecoration(
        color: ide.sideBar,
        border: Border.all(color: ide.warn.withValues(alpha: .55)),
        borderRadius: BorderRadius.circular(Radii.l),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!compact)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              color: ide.warn.withValues(alpha: .08),
              child: Row(
                children: [
                  Icon(Icons.pause_circle_outline, size: 14, color: ide.warn),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      _permissions.length > 1
                          ? '${_permissions.length} 项等待批准 · 逐项处理'
                          : '需要你的决定 · ${q.sessionId == _sessionId ? '主代理' : '子代理'}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: ide.warn,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_approvalBusy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    ),
                ],
              ),
            ),
          card,
          if (!compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    q.reasonText,
                    style: TextStyle(fontSize: 11, color: ide.textDim),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    q.alwaysLabel,
                    style: TextStyle(fontSize: 10.5, color: ide.textFaint),
                  ),
                ],
              ),
            ),
          if (_approvalError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Text(
                _approvalError!,
                key: const ValueKey('ai-approval-error'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: ide.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _DockPromptBar extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _DockPromptBar({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      child: Material(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.m),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.m),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.m),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded, size: 15, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
