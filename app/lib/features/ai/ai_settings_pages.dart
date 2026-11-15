part of 'ai_settings_dialog.dart';

const _sections = [
  ('connection', '连接', Icons.cable_outlined, '登录、接口与网络'),
  ('models', '模型', Icons.memory_outlined, '逐模型设置能力和思考参数'),
  ('execution', '工具与权限', Icons.shield_outlined, '全局工具默认值与执行权限'),
  ('defaults', '对话', Icons.tune_rounded, '新会话默认值'),
];

extension _SettingsPages on _AiSettingsDialogState {
  Widget _buildPages(BuildContext context) {
    final ide = Ide.of(context);
    final section = _sections.firstWhere((x) => x.$1 == _section);
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: ide.border),
    );
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: Theme(
          data: Theme.of(context).copyWith(
            inputDecorationTheme: InputDecorationTheme(
              isDense: true,
              filled: true,
              fillColor: ide.editor.withValues(alpha: .45),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 16,
              ),
              border: inputBorder,
              enabledBorder: inputBorder,
              focusedBorder: inputBorder.copyWith(
                borderSide: BorderSide(color: ide.accent, width: 1.5),
              ),
              labelStyle: TextStyle(fontSize: 13, color: ide.textDim),
              floatingLabelStyle: TextStyle(fontSize: 12, color: ide.textDim),
              hintStyle: TextStyle(fontSize: 12, color: ide.textFaint),
            ),
          ),
          child: PopScope(
            canPop: _closing,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _close();
            },
            child: Dialog(
              insetPadding: const EdgeInsets.all(12),
              backgroundColor: ide.panel,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: ide.border),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 960,
                  maxHeight: 760,
                ),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final wide = box.maxWidth >= 740;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: ide.accent.withValues(alpha: .10),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  Icons.auto_awesome_outlined,
                                  color: ide.accent,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'AI 设置',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: ide.text,
                                  ),
                                ),
                              ),
                              IconBtn(Icons.close, '关闭 AI 设置', _close),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: ide.border),
                        if (!wide)
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  for (final s in _sections)
                                    _nav(ide, s, compact: true),
                                ],
                              ),
                            ),
                          ),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (wide)
                                Container(
                                  width: 186,
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    18,
                                    10,
                                    10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: ide.editor.withValues(alpha: .5),
                                    border: Border(
                                      right: BorderSide(color: ide.border),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      for (final s in _sections) _nav(ide, s),
                                      const Spacer(),
                                      Padding(
                                        padding: const EdgeInsets.all(10),
                                        child: Text(
                                          '凭据加密保存在本机\n设置保存后用于后续请求',
                                          style: TextStyle(
                                            fontSize: 11,
                                            height: 1.6,
                                            color: ide.textFaint,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              Expanded(
                                child: SingleChildScrollView(
                                  key: ValueKey(
                                    'ai-settings-page-$_section-$_editingId',
                                  ),
                                  padding: EdgeInsets.all(wide ? 26 : 16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        section.$2,
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w600,
                                          color: ide.text,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        section.$4,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.5,
                                          color: ide.textDim,
                                        ),
                                      ),
                                      const SizedBox(height: 20),
                                      if (_section == 'connection' ||
                                          _section == 'models') ...[
                                        _providerHeader(ide),
                                        const SizedBox(height: 18),
                                      ],
                                      switch (_section) {
                                        'connection' => _connectionPage(ide),
                                        'models' =>
                                          _current == null
                                              ? _emptyConnections(ide)
                                              : _modelsPage(ide),
                                        'execution' => Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            _notice(
                                              ide,
                                              '这里设置所有模型的工具默认值。单个模型可在“模型”页覆盖；开启工具后仍按下方权限规则执行。',
                                            ),
                                            AiCapabilityEditor(
                                              values: _ai.toolDefaults,
                                              inherited: aiCapabilityDefaults,
                                              onChanged: (v) => _change(
                                                () => _ai.toolDefaults = v,
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            _permissionsPage(ide),
                                          ],
                                        ),
                                        _ => _defaultsPage(ide),
                                      },
                                      if (_note != null) ...[
                                        const SizedBox(height: 14),
                                        _notice(ide, _note!),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  color: ide.error,
                                  size: 17,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _error!,
                                    key: const ValueKey('ai-settings-error'),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: ide.error,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Divider(height: 1, color: ide.border),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _dirty ? '有未保存的修改' : '所有配置保存在本机',
                                  key: const ValueKey('ai-settings-dirty'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _dirty ? ide.accent : ide.textFaint,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: _saving ? null : _close,
                                child: const Text('取消'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                key: const ValueKey('ai-save-settings'),
                                onPressed: _saving ? null : _save,
                                child: Text(_saving ? '保存中…' : '保存设置'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _nav(
    Ide ide,
    (String, String, IconData, String) s, {
    bool compact = false,
  }) {
    final selected = s.$1 == _section;
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 0 : 4, right: compact ? 4 : 0),
      child: Material(
        color: selected
            ? ide.accent.withValues(alpha: .10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: ValueKey('ai-settings-nav-${s.$1}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => _change(() {
            _section = s.$1;
            _error = null;
            _note = null;
          }),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: compact ? 10 : 13,
            ),
            child: Row(
              mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
              children: [
                Icon(
                  s.$3,
                  size: 17,
                  color: selected ? ide.accent : ide.textDim,
                ),
                const SizedBox(width: 9),
                Text(
                  s.$2,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? ide.text : ide.textDim,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _notice(Ide ide, String text) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: ide.editor,
      border: Border.all(color: ide.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, height: 1.55, color: ide.textDim),
    ),
  );

  Widget _providerHeader(Ide ide) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(
        child: _ai.providers.isEmpty
            ? Text('尚未添加连接', style: TextStyle(color: ide.textDim))
            : DropdownButtonFormField<String>(
                key: ValueKey('ai-provider-select-$_editingId'),
                initialValue: _editingId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '正在编辑的连接',
                  isDense: true,
                ),
                items: [
                  for (final p in _ai.providers)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        '${p.name.isEmpty ? '未命名连接' : p.name}${p.id == _ai.activeProvider?.id ? ' · 默认' : ''}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _switchProvider,
              ),
      ),
      const SizedBox(width: 8),
      WorkbenchMenuButton<int>(
        key: const ValueKey('ai-add-provider'),
        tooltip: '添加连接',
        onSelected: _add,
        itemBuilder: (_) => [
          for (var i = 0; i < _presets.length; i++)
            PopupMenuItem(value: i, child: Text(_presets[i].$1)),
        ],
        icon: Icon(Icons.add_circle_outline, size: 23, color: ide.accent),
      ),
    ],
  );

  Widget _emptyConnections(Ide ide) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _notice(ide, '先连接一个提供商，再选择模型开始对话。你可以同时保存多个 API 和订阅连接。'),
      const SizedBox(height: 14),
      for (var i = 0; i < _presets.length; i++)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: Icon(
            i == 0 ? Icons.account_circle_outlined : Icons.cable_outlined,
            size: 20,
            color: ide.textDim,
          ),
          title: Text(_presets[i].$1),
          trailing: const Icon(Icons.add, size: 18),
          onTap: () => _add(i),
        ),
    ],
  );

  Widget _connectionPage(Ide ide) {
    final p = _current;
    if (p == null) return _emptyConnections(ide);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(_name, '连接名称', key: 'ai-provider-name'),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: ValueKey('ai-auth-${p.id}-${p.authMode}'),
          initialValue: p.authMode,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '认证方式'),
          items: const [
            DropdownMenuItem(value: '', child: Text('API Key · 自动匹配协议')),
            DropdownMenuItem(value: 'bearer', child: Text('API Key · Bearer')),
            DropdownMenuItem(
              value: 'x-api-key',
              child: Text('API Key · x-api-key'),
            ),
            DropdownMenuItem(
              value: 'chatgpt-device',
              child: Text(
                'ChatGPT 订阅 · Device 设备码',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          onChanged: _authChanged,
        ),
        const SizedBox(height: 16),
        if (p.isSubscription) ...[
          _notice(ide, p.oauth == null ? '尚未登录 ChatGPT 订阅' : '已登录 · 凭据加密保存在本机'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('ai-device-login'),
                onPressed: _login,
                icon: const Icon(Icons.login, size: 16),
                label: Text(p.oauth == null ? '使用设备码登录' : '重新登录'),
              ),
              if (p.oauth != null)
                TextButton(onPressed: _logout, child: const Text('退出登录')),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '登录 / 退出即时加密保存。订阅使用固定 Responses 地址，API Key 保留但不参与订阅请求。',
            style: TextStyle(fontSize: 11.5, height: 1.5, color: ide.textFaint),
          ),
        ] else ...[
          _field(
            _url,
            'Base URL',
            key: 'ai-base-url',
            hint: 'https://api.example.com/v1',
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('ai-api-key'),
            controller: _key,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: '无认证的本地服务可留空',
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密钥' : '隐藏密钥',
                onPressed: () => _change(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('ai-protocol-${p.id}-${p.protocol}'),
            initialValue: p.protocol,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'API 协议'),
            items: const [
              DropdownMenuItem(
                value: 'openai-chat',
                child: Text(
                  'OpenAI Chat Completions',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: 'openai-responses',
                child: Text('OpenAI Responses'),
              ),
              DropdownMenuItem(
                value: 'anthropic-messages',
                child: Text('Anthropic Messages'),
              ),
            ],
            onChanged: (v) => _change(() {
              p.protocol = v!;
              _invalidate();
            }),
          ),
        ],
        const SizedBox(height: 18),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (!p.isSubscription)
              OutlinedButton.icon(
                key: const ValueKey('ai-test-connection'),
                onPressed: _checking || _fetching
                    ? null
                    : () => _discover(checkOnly: true),
                icon: const Icon(Icons.network_check, size: 16),
                label: Text(_checking ? '检查中…' : '检查目录接口'),
              ),
            TextButton.icon(
              onPressed: () => _change(() {
                _section = 'models';
                _note = null;
              }),
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: const Text('选择与管理模型'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        ExpansionTile(
          key: const ValueKey('ai-network-options'),
          tilePadding: EdgeInsets.zero,
          title: const Text('网络出口', style: TextStyle(fontSize: 13)),
          children: [_networkPage(ide)],
        ),
        Divider(color: ide.border),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _delete,
            style: TextButton.styleFrom(foregroundColor: ide.error),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('删除连接'),
          ),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? key,
    String? hint,
    bool numeric = false,
  }) => TextField(
    key: key == null ? null : ValueKey(key),
    controller: controller,
    keyboardType: numeric ? TextInputType.number : TextInputType.text,
    inputFormatters: numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
    decoration: InputDecoration(labelText: label, hintText: hint),
  );

  Widget _modelsPage(Ide ide) {
    final p = _current!;
    final models =
        <String>{...p.models, if (p.model.isNotEmpty) p.model}
            .where(
              (m) =>
                  m.toLowerCase().contains(_search.text.trim().toLowerCase()),
            )
            .toList()
          ..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(
          _model,
          '此连接的默认模型 ID',
          key: 'ai-model-id',
          hint: '手动输入，或从下面的目录选择',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            TextButton.icon(
              key: const ValueKey('ai-add-model'),
              onPressed: _addModel,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加当前模型'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('ai-fetch-models'),
              onPressed: _fetching || _checking ? null : _discover,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(
                _fetching
                    ? '拉取中…'
                    : p.isSubscription
                    ? '加载订阅建议'
                    : '拉取模型',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _search,
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: '搜索已保存的模型',
          ),
        ),
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('ai-model-catalog'),
          decoration: BoxDecoration(
            border: Border.all(color: ide.border),
            borderRadius: BorderRadius.circular(8),
          ),
          constraints: const BoxConstraints(maxHeight: 240),
          child: models.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '暂无模型。拉取目录或手动添加模型 ID。',
                    style: TextStyle(fontSize: 12, color: ide.textDim),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: models.length,
                  itemBuilder: (_, index) {
                    final id = models[index],
                        selected = id == (_inspectedModel ?? p.model);
                    final limit = p.modelContextWindows[id];
                    final image =
                        p.effectiveCapabilities(
                          id,
                          _ai.toolDefaults,
                        )['image_input'] !=
                        false;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      selectedTileColor: ide.accent.withValues(alpha: .07),
                      leading: IconButton(
                        tooltip: id == p.model ? '默认模型' : '设为默认模型',
                        onPressed: () => _model.text = id,
                        icon: Icon(
                          id == p.model
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 17,
                          color: id == p.model ? ide.accent : ide.textFaint,
                        ),
                      ),
                      title: Text(
                        id,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: ide.text),
                      ),
                      subtitle: Text(
                        '图片${image ? '开启' : '关闭'}${limit == null ? '' : ' · ${(limit / 1000).round()}k 上下文'}',
                        style: TextStyle(fontSize: 10.5, color: ide.textFaint),
                      ),
                      trailing: IconButton(
                        tooltip: '移除 $id',
                        icon: const Icon(Icons.close, size: 15),
                        onPressed: () => _removeModel(id),
                      ),
                      onTap: () => _change(() => _inspectedModel = id),
                    );
                  },
                ),
        ),
        const SizedBox(height: 20),
        if ((_inspectedModel ?? p.model).isNotEmpty)
          AiModelOptionsEditor(
            key: ValueKey(
              'ai-model-options-${p.id}-${_inspectedModel ?? p.model}',
            ),
            provider: p,
            model: _inspectedModel ?? p.model,
            defaults: _ai.toolDefaults,
            onChanged: (v) =>
                _change(() => p.modelOptions[_inspectedModel ?? p.model] = v),
          ),
        const SizedBox(height: 16),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('连接级预设', style: TextStyle(fontSize: 13)),
          children: [
            _field(_context, '统一上下文上限', numeric: true, hint: '留空使用模型目录值 / 估计值'),
            const SizedBox(height: 12),
            AiReasoningField(
              key: ValueKey('ai-connection-effort-${p.id}'),
              value: p.reasoningEffort,
              label: '所有模型的默认思考强度',
              onChanged: (v) => _change(() => p.reasoningEffort = v),
            ),
          ],
        ),
      ],
    );
  }

  Widget _defaultsPage(Ide ide) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_ai.providers.isNotEmpty)
        DropdownButtonFormField<String>(
          key: ValueKey('ai-default-provider-${_ai.activeProvider?.id}'),
          initialValue: _ai.activeProvider?.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '新会话的默认连接'),
          items: [
            for (final p in _ai.providers)
              DropdownMenuItem(
                value: p.id,
                child: Text(
                  '${p.name} / ${p.model.isEmpty ? '未选模型' : p.model}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => _change(() => _ai.selectedProviderId = v),
        )
      else
        _notice(ide, '尚未连接提供商，请先在“连接”页添加。'),
      const SizedBox(height: 18),
      DropdownButtonFormField<String>(
        initialValue: _ai.defaultAgent,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '新会话的工作模式'),
        items: const [
          DropdownMenuItem(value: 'build', child: Text('构建 · 可以调用工具修改文件')),
          DropdownMenuItem(value: 'plan', child: Text('规划 · 只读分析与方案')),
        ],
        onChanged: (v) => _change(() => _ai.defaultAgent = v!),
      ),
      const SizedBox(height: 18),
      DropdownButtonFormField<String>(
        initialValue: _ai.followUp,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '运行中发送消息的默认方式'),
        items: const [
          DropdownMenuItem(value: 'steer', child: Text('补充 · 下一步优先处理')),
          DropdownMenuItem(value: 'queue', child: Text('排队 · 当前任务结束后处理')),
        ],
        onChanged: (v) => _change(() => _ai.followUp = v!),
      ),
      const SizedBox(height: 20),
      _notice(ide, '在对话输入区切换模型、思考强度或工作模式，只影响该会话的后续输入。正在执行的步骤会显示其实际使用的模型。'),
    ],
  );

  Widget _networkPage(Ide ide) {
    final p = _current!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _notice(
          ide,
          '执行位置：${widget.ws?.entry?.name ?? '未选择工作区'}\n模型请求和 Shell 工具由当前工作区的 agent 执行。',
        ),
        const SizedBox(height: 18),
        DropdownButtonFormField<String>(
          key: ValueKey('ai-proxy-mode-${p.id}-${p.proxyMode}'),
          initialValue: p.proxyMode,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '模型与工具的网络出口'),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text('沿用旧设置 · ${p.useProxy ? '使用代理' : 'API 直连'}'),
            ),
            const DropdownMenuItem(
              value: 'system',
              child: Text('执行端系统 / 环境代理', overflow: TextOverflow.ellipsis),
            ),
            const DropdownMenuItem(
              value: 'agent',
              child: Text('Aurora agent 的代理节点'),
            ),
            const DropdownMenuItem(value: 'direct', child: Text('直连')),
          ],
          onChanged: (v) => _change(() {
            p.proxyMode = v!;
            if (v == 'agent') _clientNetwork = false;
            _invalidate();
          }),
        ),
        const SizedBox(height: 18),
        DropdownButtonFormField<bool>(
          key: ValueKey('ai-discovery-network-$_clientNetwork'),
          initialValue: _clientNetwork,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '本次目录检查 / 拉取的位置'),
          items: const [
            DropdownMenuItem(value: false, child: Text('当前 agent · 与对话相同的执行端')),
            DropdownMenuItem(value: true, child: Text('本机客户端网络')),
          ],
          onChanged: (v) => _change(() {
            _clientNetwork = v!;
            _invalidate();
          }),
        ),
        const SizedBox(height: 18),
        _notice(
          ide,
          '远程 agent 使用服务器网络；本地 agent 使用本机网络。本机拉取目录不会改变对话的执行位置。\n\nAurora 代理节点在对应工作区的“代理”页配置。设备码登录可在登录窗口中选择网络位置。',
        ),
      ],
    );
  }

  Widget _permissionsPage(Ide ide) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<String>(
        key: const ValueKey('ai-default-permission'),
        initialValue: _ai.permissionMode,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '新会话默认权限'),
        items: const [
          DropdownMenuItem(
            value: 'ask',
            child: Text('先询问 · 修改文件与执行命令需确认', overflow: TextOverflow.ellipsis),
          ),
          DropdownMenuItem(value: 'auto', child: Text('自动执行 · 高风险操作仍需确认')),
        ],
        onChanged: (v) => _change(() => _ai.permissionMode = v!),
      ),
      const SizedBox(height: 16),
      _notice(
        ide,
        '规则从上到下匹配，最后命中的规则生效。项目规则仅在绑定的服务器和项目目录内应用。\n“本会话允许”是运行时授权；不会写成全局规则。',
      ),
      const SizedBox(height: 16),
      Container(
        key: const ValueKey('ai-permission-rules'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < _ai.permissionRules.length; i++)
              _ruleTile(ide, i),
            if (_ai.permissionRules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '暂无自定义规则，使用默认权限。',
                  style: TextStyle(color: ide.textDim, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      Text(
        _editingRule == null ? '添加规则' : '编辑第 ${_editingRule! + 1} 条规则',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: ide.text,
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey('ai-rule-effect-$_ruleEffect'),
              initialValue: _ruleEffect,
              decoration: const InputDecoration(labelText: '处理方式'),
              items: const [
                DropdownMenuItem(value: 'allow', child: Text('允许')),
                DropdownMenuItem(value: 'ask', child: Text('询问')),
                DropdownMenuItem(value: 'deny', child: Text('拒绝')),
              ],
              onChanged: (v) => _change(() => _ruleEffect = v!),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey('ai-rule-action-$_ruleAction'),
              initialValue: _ruleAction,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '工具动作'),
              items: [
                for (final a in {
                  '*',
                  'shell',
                  'read',
                  'edit',
                  'write',
                  'websearch',
                  'webfetch',
                  'subagent',
                  _ruleAction,
                })
                  DropdownMenuItem(
                    value: a,
                    child: Text(a, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => _change(() => _ruleAction = v!),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _field(
        _resource,
        '资源模式',
        key: 'ai-rule-resource',
        hint: '例如 git status * 或 *.env',
      ),
      const SizedBox(height: 14),
      DropdownButtonFormField<String>(
        key: ValueKey('ai-rule-scope-$_ruleScope'),
        initialValue: _ruleScope,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '作用范围'),
        items: [
          const DropdownMenuItem(value: 'global', child: Text('全局 · 所有工作区')),
          DropdownMenuItem(
            value: 'project',
            enabled: widget.ws?.project != null,
            child: Text(
              widget.ws?.project == null
                  ? '项目 · 请先打开项目工作区'
                  : '当前项目 · ${widget.ws!.project!.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        onChanged: (v) => _change(() => _ruleScope = v!),
      ),
      const SizedBox(height: 12),
      Text(
        '填写中的规则也会随「保存设置」一起保存。',
        style: TextStyle(fontSize: 11, color: ide.textFaint),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          FilledButton.icon(
            key: const ValueKey('ai-save-rule'),
            onPressed: _saveRule,
            icon: const Icon(Icons.add, size: 16),
            label: Text(_editingRule == null ? '添加规则' : '更新规则'),
          ),
          if (_editingRule != null || _ruleDirty)
            TextButton(
              onPressed: () => _change(_resetRule),
              child: const Text('清空编辑'),
            ),
        ],
      ),
    ],
  );

  Widget _ruleTile(Ide ide, int i) {
    final r = _ai.permissionRules[i];
    final here = r.appliesTo(widget.ws?.serverId ?? '', widget.ws?.project?.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ide.editor,
        border: Border.all(color: ide.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '${i + 1}  ${r.effect == 'allow'
                    ? '允许'
                    : r.effect == 'deny'
                    ? '拒绝'
                    : '询问'}',
                style: TextStyle(
                  color: r.effect == 'deny'
                      ? ide.error
                      : r.effect == 'allow'
                      ? ide.ok
                      : ide.warn,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  r.action,
                  style: TextStyle(
                    fontFamily: Ide.mono,
                    fontSize: 11,
                    color: ide.textDim,
                  ),
                ),
              ),
              Text(
                r.scope == 'global'
                    ? '全局'
                    : here
                    ? '当前项目'
                    : '其他项目',
                style: TextStyle(fontSize: 10.5, color: ide.textFaint),
              ),
            ],
          ),
          const SizedBox(height: 5),
          SelectableText(
            r.resource,
            style: TextStyle(
              fontFamily: Ide.mono,
              fontSize: 12,
              color: ide.text,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '上移规则',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_upward, size: 16),
                onPressed: i == 0
                    ? null
                    : () => _change(() {
                        _ai.permissionRules.removeAt(i);
                        _ai.permissionRules.insert(i - 1, r);
                        if (_editingRule == i) {
                          _editingRule = i - 1;
                        } else if (_editingRule == i - 1) {
                          _editingRule = i;
                        }
                      }),
              ),
              IconButton(
                tooltip: '下移规则',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_downward, size: 16),
                onPressed: i == _ai.permissionRules.length - 1
                    ? null
                    : () => _change(() {
                        _ai.permissionRules.removeAt(i);
                        _ai.permissionRules.insert(i + 1, r);
                        if (_editingRule == i) {
                          _editingRule = i + 1;
                        } else if (_editingRule == i + 1) {
                          _editingRule = i;
                        }
                      }),
              ),
              IconButton(
                tooltip: '编辑规则',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 16),
                onPressed: r.scope != 'global' && !here
                    ? null
                    : () => _editRule(i),
              ),
              IconButton(
                tooltip: '删除规则',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 16),
                onPressed: () => _change(() {
                  _ai.permissionRules.removeAt(i);
                  if (_editingRule == i) {
                    _resetRule();
                  } else if (_editingRule != null && _editingRule! > i) {
                    _editingRule = _editingRule! - 1;
                  }
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
