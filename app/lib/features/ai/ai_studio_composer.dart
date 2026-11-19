part of 'ai_studio_view.dart';

extension _ComposerView on _AiStudioViewState {
  Widget _buildComposer(Ide ide, AiProvider? prov, {bool compact = false}) {
    return LayoutBuilder(
      builder: (_, box) {
        if (compact) return _buildCompactComposer(ide, prov, box.maxWidth);
        final narrow = box.maxWidth < 460;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 792),
            child: AnimatedContainer(
              duration: UiMotion.reduced(context)
                  ? Duration.zero
                  : UiMotion.hover,
              curve: UiMotion.enterCurve,
              key: const ValueKey('ai-composer'),
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
              decoration: BoxDecoration(
                color: ide.surface,
                borderRadius: AiVisuals.radius,
                border: Border.all(
                  color: _running
                      ? ide.accent.withValues(alpha: 0.48)
                      : ide.borderStrong.withValues(alpha: 0.55),
                ),
                boxShadow: [
                  BoxShadow(
                    color: ide.shadow.withValues(
                      alpha: ide.isDark ? 0.24 : 0.08,
                    ),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_attachments.isNotEmpty) ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 110),
                      child: SingleChildScrollView(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (var i = 0; i < _attachments.length; i++)
                              InputChip(
                                visualDensity: VisualDensity.compact,
                                avatar:
                                    _attachments[i].mime.startsWith('image/') &&
                                        _attachments[i].bytes != null
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image.memory(
                                          _attachments[i].bytes!,
                                          width: 28,
                                          height: 28,
                                          cacheWidth: 64,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) => const Icon(
                                            Icons.broken_image_outlined,
                                            size: 16,
                                          ),
                                        ),
                                      )
                                    : FileIcon(
                                        name: _attachments[i].label,
                                        size: 16,
                                      ),
                                label: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 200,
                                  ),
                                  child: Text(
                                    '${_attachments[i].label}${_attachments[i].bytes != null ? ' · ${(_attachments[i].bytes!.length / 1024).toStringAsFixed(0)} KiB' : ''}',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                onDeleted: () => _set(() {
                                  _uploadedAttachments.remove(_attachments[i]);
                                  _attachments.removeAt(i);
                                }),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (_attachmentNote != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        _attachmentNote!,
                        style: TextStyle(fontSize: 11.5, color: ide.accent),
                      ),
                    ),
                  if (_slashSuggestions(_inputCtl.text).isNotEmpty)
                    _buildSlashSuggestions(ide),
                  _buildPromptField(
                    ide,
                    minLines: 2,
                    maxLines: box.maxWidth < 600 ? 4 : 7,
                  ),
                  const SizedBox(height: 8),
                  _buildComposerFooter(ide, prov, box.maxWidth, narrow: narrow),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPromptField(
    Ide ide, {
    required int minLines,
    required int maxLines,
  }) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.keyV, control: true): _AiPasteIntent(),
      SingleActivator(LogicalKeyboardKey.keyV, meta: true): _AiPasteIntent(),
    },
    child: Actions(
      actions: {
        _AiPasteIntent: CallbackAction<_AiPasteIntent>(
          onInvoke: (_) {
            unawaited(_action('paste'));
            return null;
          },
        ),
      },
      child: Focus(
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.enter &&
              !HardwareKeyboard.instance.isShiftPressed &&
              (ws.app.aiSettings.sendKey != 'ctrl-enter' ||
                  HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isMetaPressed) &&
              !(_inputCtl.value.composing.isValid &&
                  !_inputCtl.value.composing.isCollapsed)) {
            unawaited(_action('send'));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          key: const ValueKey('ai-prompt-input'),
          controller: _inputCtl,
          focusNode: _inputFocus,
          minLines: minLines,
          maxLines: maxLines,
          onSubmitted: (_) => _action('send'),
          style: TextStyle(
            fontFamily: Ide.ui,
            fontFamilyFallback: Ide.uiFallback,
            fontSize: _chatFontSize,
            color: ide.text,
            height: 1.5,
          ),
          contentInsertionConfiguration: ContentInsertionConfiguration(
            allowedMimeTypes: const [
              'image/png',
              'image/jpeg',
              'image/gif',
              'image/webp',
              'application/pdf',
              'text/plain',
            ],
            onContentInserted: (c) => unawaited(_insertContent(c)),
          ),
          contextMenuBuilder: (_, state) =>
              AdaptiveTextSelectionToolbar.buttonItems(
                anchors: state.contextMenuAnchors,
                buttonItems: [
                  for (final item in state.contextMenuButtonItems)
                    if (item.type != ContextMenuButtonType.paste) item,
                  ContextMenuButtonItem(
                    label: '粘贴 / 图片 / 文件',
                    onPressed: () {
                      state.hideToolbar();
                      unawaited(_action('paste'));
                    },
                  ),
                ],
              ),
          onChanged: (_) => _set(() {}),
          decoration: InputDecoration(
            hintText: _running && _deliveryMode == 'queue'
                ? '输入下一项任务，当前任务结束后自动开始…'
                : AiComposerText.hint(running: _running, agentMode: _agentMode),
            filled: false,
            isCollapsed: true,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
        ),
      ),
    ),
  );

  Widget _buildCompactComposer(Ide ide, AiProvider? prov, double width) {
    return Container(
      key: const ValueKey('ai-composer'),
      margin: const EdgeInsets.fromLTRB(6, 2, 6, 4),
      padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
      decoration: AiVisuals.surface(ide),
      child: Row(
        children: [
          Expanded(child: _buildPromptField(ide, minLines: 1, maxLines: 1)),
          WorkbenchMenuButton<String>(
            key: const ValueKey('ai-compact-menu'),
            tooltip: '切换模式、Persona 与附件',
            padding: EdgeInsets.zero,
            onSelected: _action,
            itemBuilder: (_) {
              final persona = _personaById(_activePersonaId);
              final label = persona != null
                  ? '${persona.name}${persona.model.isEmpty ? '' : ' · ${persona.model}'}'
                  : '选择 Persona…';
              final nextAgent = switch (_agentMode) {
                'build' => 'plan',
                'plan' => 'orchestrator',
                _ => 'build',
              };
              final nextPerm = switch (_permMode) {
                'ask' => 'auto',
                'auto' => 'full_access',
                _ => 'ask',
              };
              return [
                PopupMenuItem(value: 'model', child: Text(label)),
                if (_agentMode != 'explore')
                  PopupMenuItem(
                    value: nextAgent,
                    child: Text(
                      '切换工作模式 → ${AiComposerText.agent(nextAgent, narrow: true)}',
                    ),
                  ),
                PopupMenuItem(
                  value: nextPerm,
                  child: Text(
                    '切换权限 → ${AiComposerText.permission(nextPerm, narrow: true)}',
                  ),
                ),
                const PopupMenuItem(
                  value: 'send-options',
                  child: Text('此对话的执行策略…'),
                ),
                const PopupMenuItem(value: 'attach', child: Text('添加附件…')),
                const PopupMenuItem(
                  value: 'paste',
                  child: Text('粘贴图片 / 文件 / 文本'),
                ),
                if (_attachments.isNotEmpty)
                  PopupMenuItem(
                    value: 'attachments',
                    child: Text('管理 ${_attachments.length} 个附件…'),
                  ),
                if (_running) ...const [
                  PopupMenuItem(value: 'steer', child: Text('补充指令 · 下一步优先')),
                  PopupMenuItem(value: 'queue', child: Text('排队发送 · 当前任务结束后')),
                ],
              ];
            },
            icon: Badge.count(
              count: _attachments.length,
              isLabelVisible: _attachments.isNotEmpty,
              child: Icon(Icons.tune_rounded, size: 16, color: ide.textDim),
            ),
          ),
          if (_running)
            IconBtn(
              Icons.stop_rounded,
              '停止当前运行',
              () => _action('stop'),
              key: const ValueKey('ai-stop-btn'),
              size: 16,
              color: ide.error,
            ),
          FilledButton(
            key: const ValueKey('ai-send-btn'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(30, 26),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            ),
            onPressed: _sending ? null : () => _action('send'),
            child: const Icon(Icons.arrow_upward_rounded, size: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildComposerFooter(
    Ide ide,
    AiProvider? prov,
    double width, {
    required bool narrow,
  }) {
    final overrideLabel = !_sessionPolicy.budgetEnabled
        ? '预算关'
        : !_sessionPolicy.isDefault
        ? '已改策略'
        : '';
    final personas = ws.app.ready
        ? ws.app.aiSettings.personas
        : const <AiPersona>[];
    final activePersona = _personaById(_activePersonaId);
    final conductorPersona = _personaById(_conductorPersonaId);
    final musicianPersona = _personaById(_musicianPersonaId);
    final nextAgent = switch (_agentMode) {
      'build' => 'plan',
      'plan' => 'orchestrator',
      _ => 'build',
    };
    final nextPerm = switch (_permMode) {
      'ask' => 'auto',
      'auto' => 'full_access',
      _ => 'ask',
    };
    final quickControls = Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _ComposerPill(
          key: const ValueKey('ai-mode-pill'),
          icon: switch (_agentMode) {
            'plan' => Icons.architecture_rounded,
            'explore' => Icons.explore_outlined,
            'orchestrator' => Icons.hub_outlined,
            _ => Icons.build_outlined,
          },
          label: switch (_agentMode) {
            'explore' => '探索',
            'plan' => '规划',
            'orchestrator' => '编排',
            _ => '构建',
          },
          tooltip: AiComposerText.agentTip(_agentMode),
          accent: _agentMode == 'plan'
              ? ide.warn
              : _agentMode == 'orchestrator'
              ? ide.ok
              : ide.accent,
          highlighted: _agentMode == 'plan' || _agentMode == 'orchestrator',
          onTap: _agentMode == 'explore' ? null : () => _action(nextAgent),
        ),
        _ComposerPill(
          key: const ValueKey('ai-perm-pill'),
          icon: switch (_permMode) {
            'auto' => Icons.bolt_rounded,
            'full_access' => Icons.lock_open_rounded,
            _ => Icons.shield_outlined,
          },
          label: AiComposerText.permission(_permMode, narrow: narrow),
          tooltip: AiComposerText.permissionTip(_permMode),
          accent: _permMode == 'full_access'
              ? ide.error
              : _permMode == 'auto'
              ? ide.warn
              : ide.textDim,
          highlighted: _permMode == 'auto' || _permMode == 'full_access',
          onTap: () => _action(nextPerm),
        ),
        if (_agentMode == 'orchestrator') ...[
          _buildPersonaMenuPill(
            ide,
            key: const ValueKey('ai-conductor-pill'),
            prefix: '指挥',
            persona: conductorPersona ?? activePersona,
            personas: personas,
            accent: ide.accent,
            onSelected: (id) {
              _set(() => _conductorPersonaId = id);
              _refreshEffectivePermissions();
            },
          ),
          _buildPersonaMenuPill(
            ide,
            key: const ValueKey('ai-musician-pill'),
            prefix: '乐手',
            persona: musicianPersona,
            personas: personas,
            accent: ide.ok,
            onSelected: (id) => _set(() => _musicianPersonaId = id),
          ),
        ],
        if (_running)
          _ComposerPill(
            key: const ValueKey('ai-delivery-pill'),
            icon: _deliveryMode == 'queue'
                ? Icons.schedule_send_outlined
                : Icons.bolt_outlined,
            label: _deliveryMode == 'queue' ? '排队' : '补充',
            tooltip: _deliveryMode == 'queue'
                ? '当前任务结束后发送（点击切为补充指令）'
                : '下一步优先插入当前任务（点击切为排队发送）',
            accent: _deliveryMode == 'queue' ? ide.accent : ide.textDim,
            highlighted: _deliveryMode == 'queue',
            onTap: () => _action(_deliveryMode == 'queue' ? 'steer' : 'queue'),
          ),
        Tooltip(
          message: '此对话的执行策略（预算、子代理、工具边界、快照与指令）',
          child: InkWell(
            key: const ValueKey('ai-send-options'),
            onTap: () => _action('send-options'),
            borderRadius: BorderRadius.circular(Radii.s + 2),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: overrideLabel.isNotEmpty ? ide.accentSoft : null,
                borderRadius: BorderRadius.circular(Radii.s + 2),
                border: Border.all(
                  color: overrideLabel.isNotEmpty
                      ? ide.accent.withValues(alpha: 0.4)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.tune_rounded,
                    size: 14,
                    color: overrideLabel.isNotEmpty ? ide.accent : ide.textDim,
                  ),
                  if (overrideLabel.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Text(
                      overrideLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: ide.accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );

    final sendBar = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        WorkbenchMenuButton<String>(
          key: const ValueKey('ai-attach-menu'),
          tooltip: '添加图片或文件',
          onSelected: _action,
          itemBuilder: (_) {
            final file = ws.tab(ws.editorActiveId ?? '')?.file;
            return [
              if (file != null)
                PopupMenuItem(
                  value: 'active',
                  child: Text('附加当前文件：${file.name}'),
                ),
              if (file != null)
                const PopupMenuItem(value: 'selection', child: Text('附加编辑器选区')),
              const PopupMenuItem(value: 'local', child: Text('选择本机图片 / 文件…')),
              const PopupMenuItem(
                value: 'paste',
                child: Text('粘贴图片 / 文件 / 文本'),
              ),
              PopupMenuItem(
                value: 'remote',
                child: Text(
                  ws.entry?.isLocal == true ? '浏览本机项目文件…' : '浏览服务器文件…',
                ),
              ),
            ];
          },
          icon: Icon(Icons.attach_file_rounded, size: 17, color: ide.textDim),
        ),
        if (_running) ...[
          const SizedBox(width: 2),
          IconBtn(
            Icons.stop_rounded,
            '停止当前运行',
            () => _action('stop'),
            key: const ValueKey('ai-stop-btn'),
            color: ide.error,
          ),
        ],
        const SizedBox(width: 4),
        FilledButton(
          key: const ValueKey('ai-send-btn'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          onPressed: _sending ? null : () => _action('send'),
          child: Text(
            _sending
                ? '准备中'
                : _running && _deliveryMode == 'queue'
                ? '排队发送'
                : _running
                ? '补充指令'
                : '发送',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );

    if (width >= 740 && _agentMode != 'orchestrator') {
      return Row(
        children: [
          Expanded(flex: 2, child: _buildModelChoice(ide, prov)),
          const SizedBox(width: 8),
          Flexible(flex: 3, child: quickControls),
          const SizedBox(width: 8),
          sendBar,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _buildModelChoice(ide, prov)),
            const SizedBox(width: 8),
            sendBar,
          ],
        ),
        const SizedBox(height: 6),
        quickControls,
      ],
    );
  }

  Widget _buildPersonaMenuPill(
    Ide ide, {
    required Key key,
    required String prefix,
    required AiPersona? persona,
    required List<AiPersona> personas,
    required Color accent,
    required ValueChanged<String?> onSelected,
  }) {
    final label = persona == null ? '$prefix: 默认' : '$prefix: ${persona.name}';
    return PopupMenuButton<String>(
      key: key,
      tooltip: '选择$prefix Persona（或在设置中管理）',
      onSelected: (v) {
        if (v == '__manage__') {
          unawaited(_action('personas'));
        } else {
          onSelected(v.isEmpty ? null : v);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: '', child: Text('使用默认 / 当前模型')),
        for (final p in personas)
          PopupMenuItem(
            value: p.id,
            child: Text(
              '${p.name}${p.model.isEmpty ? '' : ' · ${p.model}'}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '__manage__', child: Text('管理 Persona…')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: persona != null ? accent.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(Radii.s + 2),
          border: Border.all(
            color: persona != null
                ? accent.withValues(alpha: 0.35)
                : ide.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.badge_outlined,
              size: 13,
              color: persona != null ? accent : ide.textDim,
            ),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: persona != null ? accent : ide.textDim,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlashSuggestions(Ide ide) {
    final suggestions = _slashSuggestions(_inputCtl.text);
    return Container(
      key: const ValueKey('ai-slash-suggestions'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: ide.editor,
        borderRadius: BorderRadius.circular(Radii.m),
        border: Border.all(color: ide.border),
      ),
      child: Column(
        children: [
          for (final entry in suggestions)
            InkWell(
              onTap: () {
                _inputCtl.text = '${entry.$1} ';
                _inputCtl.selection = TextSelection.collapsed(
                  offset: _inputCtl.text.length,
                );
                _set(() {});
                _inputFocus.requestFocus();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Row(
                  children: [
                    Text(
                      entry.$1,
                      style: TextStyle(
                        fontFamily: Ide.mono,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: ide.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        entry.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: ide.textDim),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildModelChoice(Ide ide, AiProvider? prov) {
    final defaults = ws.app.ready
        ? ws.app.aiSettings.toolDefaults
        : const <String, bool>{};
    final persona = _agentMode == 'orchestrator'
        ? (_personaById(_conductorPersonaId) ?? _personaById(_activePersonaId))
        : _personaById(_activePersonaId);
    final effectiveProv = _providerForPersona(persona, prov);
    final modelName = effectiveProv?.model ?? persona?.model ?? '';
    final image = effectiveProv == null || modelName.isEmpty
        ? null
        : effectiveProv.effectiveCapabilities(
            modelName,
            defaults,
          )['image_input'];
    final effort = effectiveProv == null
        ? ''
        : (_reasoningOverride ??
              persona?.reasoningEffort ??
              effectiveProv.effectiveReasoning(modelName));
    final displayText = persona != null
        ? '${persona.name}${modelName.isEmpty ? '' : ' · $modelName'}'
        : effectiveProv == null || modelName.isEmpty
        ? '选择 Persona / 模型…'
        : '${effectiveProv.name} / $modelName';
    final tooltip = persona != null
        ? '当前 Persona：${persona.name}${modelName.isEmpty ? '' : ' ($modelName)'}${effort.isEmpty ? '' : ' · ${aiEffortLabel(effort)}'}'
        : effectiveProv == null || modelName.isEmpty
        ? '点击选择 Persona 或模型'
        : '${effectiveProv.name} / $modelName${effort.isEmpty ? '' : ' · ${aiEffortLabel(effort)}'}';
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: const ValueKey('ai-model-btn'),
        onTap: () => _action('model'),
        borderRadius: BorderRadius.circular(UiMetrics.controlRadius),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: ide.input.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(UiMetrics.controlRadius),
            border: Border.all(color: ide.border.withValues(alpha: 0.85)),
          ),
          child: Row(
            children: [
              Icon(
                persona != null
                    ? Icons.auto_awesome_outlined
                    : Icons.memory_rounded,
                size: 14,
                color: persona != null ? ide.accent : ide.textDim,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  displayText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: effectiveProv == null && persona == null
                        ? ide.warn
                        : ide.text,
                  ),
                ),
              ),
              if (effort.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: AiVisuals.badge(ide, ide.accent, alpha: 0.12),
                  child: Text(
                    effort,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: ide.accent,
                    ),
                  ),
                ),
              ],
              if (image == true) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: '图片输入已开启',
                  child: Icon(Icons.image_outlined, size: 13, color: ide.ok),
                ),
              ],
              if (image == false) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: '图片输入已关闭',
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    size: 13,
                    color: ide.textFaint,
                  ),
                ),
              ],
              const SizedBox(width: 2),
              Icon(Icons.expand_more_rounded, size: 14, color: ide.textDim),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComposerPill extends StatelessWidget {
  final IconData icon;
  final String label, tooltip;
  final Color accent;
  final bool highlighted;
  final VoidCallback? onTap;

  const _ComposerPill({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.accent,
    required this.highlighted,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => AiPillButton(
    icon: icon,
    label: label,
    tooltip: tooltip,
    accent: accent,
    highlighted: highlighted,
    compact: true,
    onTap: onTap,
  );
}
