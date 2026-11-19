part of 'ai_settings_dialog.dart';

const _sections = [
  ('personas', '智能体人设', Icons.badge_outlined, '将模型、思考参数与权限组合为可复用 Persona'),
  ('connection', '连接与模型', Icons.cable_outlined, '登录、接口、模型列表获取与快速生成 Persona'),
  ('execution', '权限与工具', Icons.shield_outlined, '执行权限模式、规则与全局工具默认值'),
  ('defaults', '对话与编排', Icons.tune_rounded, '新会话默认值、编排角色与阅读体验'),
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
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: AiPageNavigation(
                              pages: {for (final s in _sections) s.$1: s.$2},
                              selected: _section,
                              keyPrefix: 'ai-settings-nav',
                              onSelected: (v) => _change(() {
                                _section = v;
                                _error = null;
                                _note = null;
                              }),
                            ),
                          ),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (wide)
                                Container(
                                  width: 196,
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    18,
                                    12,
                                    12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: ide.sideBar,
                                    border: Border(
                                      right: BorderSide(
                                        color: ide.border.withValues(alpha: 0.75),
                                      ),
                                    ),
                                  ),
                                  child: ListView(
                                    children: [
                                      for (final s in _sections) _nav(ide, s),
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
                                      if (_section == 'connection') ...[
                                        _providerHeader(ide),
                                        const SizedBox(height: 18),
                                      ],
                                      switch (_section) {
                                        'personas' => _personasPage(ide),
                                        'connection' => _connectionPage(ide),
                                        'execution' => Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            _notice(
                                              ide,
                                              '这里设置全局工具默认开关；单个 Persona 可在「智能体人设」页独立覆盖，并按下方全局权限规则与人设权限模式执行。',
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
    final statusLabel = p.isSubscription
        ? (p.oauth != null ? 'OAuth 已登录' : '待设备码登录')
        : (p.apiKey.isNotEmpty ? '已配置密钥' : '无密钥（本地网关可用）');
    final statusColor = p.isSubscription
        ? (p.oauth != null ? ide.ok : ide.warn)
        : (p.apiKey.isNotEmpty ? ide.ok : ide.textDim);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Radii.s + 2),
                border: Border.all(color: statusColor.withValues(alpha: 0.35)),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                p.model.isEmpty ? '默认模型：未选择' : '默认模型：${p.model}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: ide.textDim),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
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
        if (!p.isSubscription)
          ExpansionTile(
            key: const ValueKey('ai-custom-headers'),
            tilePadding: EdgeInsets.zero,
            title: const Text('自定义请求头', style: TextStyle(fontSize: 13)),
            subtitle: const Text('用于网关路由等高级配置'),
            children: [
              TextField(
                controller: _headers,
                minLines: 2,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: '每行 名称: 值',
                  errorText: _headerErrors[p.id],
                  errorMaxLines: 3,
                  helperText: '凭据随本机加密配置保存。OpenCode 的三个身份标识由协议保持。',
                  helperMaxLines: 3,
                ),
              ),
            ],
          ),
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
          ],
        ),
        const SizedBox(height: 20),
        const AiSectionHeading(
          icon: Icons.memory_outlined,
          title: '模型列表与快速人设',
          subtitle: '拉取或加载模型目录，设置默认模型，或一键生成 Persona。',
        ),
        _modelsPage(ide),
        const SizedBox(height: 16),
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
    final models = <String>{...p.models}
        .where(
          (m) => m.toLowerCase().contains(_search.text.trim().toLowerCase()),
        )
        .toList()
      ..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _field(
                _model,
                '手动添加模型 ID',
                key: 'ai-model-id',
                hint: '输入模型 ID 后添加到清单',
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              key: const ValueKey('ai-add-model'),
              onPressed: _addModel,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加'),
            ),
            const SizedBox(width: 4),
            OutlinedButton.icon(
              key: const ValueKey('ai-fetch-models'),
              onPressed: _fetching || _checking ? null : _discover,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(
                _fetching
                    ? '拉取中…'
                    : p.isSubscription
                    ? '加载订阅模型列表'
                    : '拉取模型列表',
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
            hintText: '搜索模型清单…',
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
                    '暂无模型。点击「${p.isSubscription ? '加载订阅模型列表' : '拉取模型列表'}」或手动添加模型 ID。',
                    style: TextStyle(fontSize: 12, color: ide.textDim),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: models.length,
                  itemBuilder: (_, index) {
                    final id = models[index];
                    final limit = p.modelContextWindows[id];
                    return ListTile(
                      dense: true,
                      title: Text(
                        id,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: ide.text),
                      ),
                      subtitle: limit == null
                          ? null
                          : Text(
                              '目录上下文 ${(limit / 1000).round()}k',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: ide.textFaint,
                              ),
                            ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton.icon(
                            onPressed: () => _createPersonaFromModel(p, id),
                            icon: const Icon(
                              Icons.person_add_alt_1_outlined,
                              size: 15,
                            ),
                            label: const Text('生成 Persona'),
                          ),
                          IconButton(
                            tooltip: '移除 $id',
                            icon: const Icon(Icons.close, size: 15),
                            onPressed: () => _removeModel(id),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _personasPage(Ide ide) {
    final selected =
        _ai.personaById(_editingPersonaId) ?? _ai.personas.firstOrNull;
    if (selected != null && _editingPersonaId != selected.id) {
      _editingPersonaId = selected.id;
    }
    String permBadge(String mode) => switch (mode) {
      'full_access' => '完全权限',
      'auto' => '自动执行',
      'ask' => '先询问',
      _ => '继承权限',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _notice(
          ide,
          'Persona 将「连接 + 模型 + 思考参数 + 权限与工具」封装为独立对象。可在对话中一键切换，或在编排（Orchestrator）模式下分别为「指挥」与「乐手」指派不同 Persona。',
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            FilledButton.icon(
              key: const ValueKey('ai-add-persona'),
              onPressed: _addPersona,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新建 Persona'),
            ),
            if (_ai.activeProvider != null)
              OutlinedButton.icon(
                key: const ValueKey('ai-persona-from-active'),
                onPressed: () => _createPersonaFromModel(
                  _ai.activeProvider!,
                  _ai.activeProvider!.model,
                ),
                icon: const Icon(Icons.auto_fix_high_outlined, size: 16),
                label: const Text('从当前默认模型生成'),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (_ai.personas.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: ide.editor.withValues(alpha: .45),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ide.border),
            ),
            child: Text(
              '还没有 Persona。点击「新建 Persona」或前往「模型」页点击「生成 Persona」即可创建。',
              style: TextStyle(fontSize: 12.5, color: ide.textDim),
            ),
          )
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final persona in _ai.personas)
                _personaCard(ide, persona, selected?.id == persona.id, permBadge),
            ],
          ),
          if (selected != null) ...[
            const SizedBox(height: 18),
            _personaEditor(ide, selected),
          ],
        ],
      ],
    );
  }

  Widget _personaCard(
    Ide ide,
    AiPersona persona,
    bool isSelected,
    String Function(String) permBadge,
  ) {
    final prov = _ai.providers
        .where((p) => p.id == persona.providerId)
        .firstOrNull;
    final isActive = _ai.activePersonaId == persona.id;
    final isConductor = _ai.orchestratorConductorPersonaId == persona.id;
    final isMusician = _ai.orchestratorMusicianPersonaId == persona.id;
    return InkWell(
      key: ValueKey('ai-persona-card-${persona.id}'),
      onTap: () => _change(() => _editingPersonaId = persona.id),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: isSelected
              ? ide.accent.withValues(alpha: .10)
              : ide.editor.withValues(alpha: .5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? ide.accent : ide.border,
            width: isSelected ? 1.4 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.badge_outlined,
                  size: 15,
                  color: isSelected ? ide.accent : ide.textDim,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    persona.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: ide.text,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              '${prov?.name ?? '未绑定连接'} · ${persona.model.isEmpty ? '默认模型' : persona.model}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: ide.textDim),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                _tag(ide, permBadge(persona.permissionMode), ide.textDim),
                if (isActive) _tag(ide, '默认', ide.accent),
                if (isConductor) _tag(ide, '指挥', ide.warn),
                if (isMusician) _tag(ide, '乐手', ide.ok),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tag(Ide ide, String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
    ),
  );

  Widget _personaEditor(Ide ide, AiPersona persona) {
    final prov = _ai.providers
        .where((p) => p.id == persona.providerId)
        .firstOrNull;
    final catalog = prov == null
        ? const <String>[]
        : (<String>{
            ...prov.models,
            if (prov.model.isNotEmpty) prov.model,
            if (persona.model.isNotEmpty) persona.model,
          }.toList()..sort());
    return Material(
      key: ValueKey('ai-persona-editor-${persona.id}'),
      color: ide.editor.withValues(alpha: .35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ide.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ActionChip(
                avatar: Icon(
                  _ai.activePersonaId == persona.id
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  size: 15,
                ),
                label: Text(
                  _ai.activePersonaId == persona.id ? '已是默认人设' : '设为默认人设',
                ),
                onPressed: () => _change(
                  () => _ai.activePersonaId =
                      _ai.activePersonaId == persona.id ? null : persona.id,
                ),
              ),
              ActionChip(
                avatar: const Icon(Icons.campaign_outlined, size: 15),
                label: Text(
                  _ai.orchestratorConductorPersonaId == persona.id
                      ? '已是编排指挥'
                      : '设为编排指挥',
                ),
                onPressed: () => _change(
                  () => _ai.orchestratorConductorPersonaId =
                      _ai.orchestratorConductorPersonaId == persona.id
                      ? null
                      : persona.id,
                ),
              ),
              ActionChip(
                avatar: const Icon(Icons.music_note_outlined, size: 15),
                label: Text(
                  _ai.orchestratorMusicianPersonaId == persona.id
                      ? '已是编排乐手'
                      : '设为编排乐手',
                ),
                onPressed: () => _change(
                  () => _ai.orchestratorMusicianPersonaId =
                      _ai.orchestratorMusicianPersonaId == persona.id
                      ? null
                      : persona.id,
                ),
              ),
              ActionChip(
                avatar: const Icon(Icons.copy_outlined, size: 15),
                label: const Text('复制'),
                onPressed: () => _duplicatePersona(persona),
              ),
              ActionChip(
                avatar: Icon(Icons.delete_outline, size: 15, color: ide.error),
                label: Text('删除', style: TextStyle(color: ide.error)),
                onPressed: () => _deletePersona(persona),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('ai-persona-name-${persona.id}'),
                  initialValue: persona.name,
                  decoration: const InputDecoration(labelText: 'Persona 名称'),
                  onChanged: (v) => _change(() => persona.name = v.trim()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  key: ValueKey('ai-persona-desc-${persona.id}'),
                  initialValue: persona.description,
                  decoration: const InputDecoration(labelText: '用途说明（可选）'),
                  onChanged: (v) =>
                      _change(() => persona.description = v.trim()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey(
                    'ai-persona-provider-${persona.id}-${persona.providerId}',
                  ),
                  initialValue: prov?.id ?? '',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '绑定连接'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('跟随当前连接')),
                    for (final p in _ai.providers)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text(p.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => _change(() {
                    persona.providerId = v ?? '';
                    final nextProv = _ai.providers
                        .where((x) => x.id == persona.providerId)
                        .firstOrNull;
                    if (nextProv != null && persona.model.isEmpty) {
                      persona.model = nextProv.model;
                    }
                  }),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: catalog.isNotEmpty
                    ? DropdownButtonFormField<String>(
                        key: ValueKey(
                          'ai-persona-model-${persona.id}-${persona.model}',
                        ),
                        initialValue: catalog.contains(persona.model)
                            ? persona.model
                            : '',
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '绑定模型'),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('跟随连接默认模型'),
                          ),
                          for (final m in catalog)
                            DropdownMenuItem(
                              value: m,
                              child: Text(m, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (v) =>
                            _change(() => persona.model = v ?? ''),
                      )
                    : TextFormField(
                        key: ValueKey('ai-persona-model-input-${persona.id}'),
                        initialValue: persona.model,
                        decoration: const InputDecoration(labelText: '模型 ID'),
                        onChanged: (v) =>
                            _change(() => persona.model = v.trim()),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('ai-persona-ctx-${persona.id}'),
                  initialValue: persona.contextWindow > 0
                      ? '${persona.contextWindow}'
                      : '',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '上下文窗口（tokens，留空继承）',
                  ),
                  onChanged: (v) => _change(
                    () => persona.contextWindow = int.tryParse(v) ?? 0,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  key: ValueKey('ai-persona-out-${persona.id}'),
                  initialValue: persona.maxTokens > 0
                      ? '${persona.maxTokens}'
                      : '',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '单次最大输出（tokens，留空继承）',
                  ),
                  onChanged: (v) => _change(
                    () => persona.maxTokens = int.tryParse(v) ?? 0,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey(
                    'ai-persona-perm-${persona.id}-${persona.permissionMode}',
                  ),
                  initialValue: persona.permissionMode,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Persona 权限模式'),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('继承会话权限')),
                    DropdownMenuItem(value: 'ask', child: Text('先询问 (Ask)')),
                    DropdownMenuItem(value: 'auto', child: Text('自动执行 (Auto)')),
                    DropdownMenuItem(
                      value: 'full_access',
                      child: Text('完全权限 (Full Access)'),
                    ),
                  ],
                  onChanged: (v) =>
                      _change(() => persona.permissionMode = v ?? ''),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey(
                    'ai-persona-think-${persona.id}-${persona.reasoningMode}',
                  ),
                  initialValue: persona.reasoningMode,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '思考参数格式'),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('跟随连接协议')),
                    DropdownMenuItem(value: 'protocol', child: Text('标准协议参数')),
                    DropdownMenuItem(value: 'disabled', child: Text('不发送思考参数')),
                    DropdownMenuItem(
                      value: 'anthropic-adaptive',
                      child: Text('Anthropic · 自适应 effort'),
                    ),
                    DropdownMenuItem(
                      value: 'anthropic-budget',
                      child: Text('Anthropic · Token 预算'),
                    ),
                  ],
                  onChanged: (v) =>
                      _change(() => persona.reasoningMode = v ?? ''),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AiReasoningField(
            key: ValueKey('ai-persona-effort-${persona.id}'),
            value: persona.reasoningEffort ?? '',
            label: '思考强度（留空不发送，可填 low / medium / high / max）',
            onChanged: (v) => _change(
              () => persona.reasoningEffort = v.trim().isEmpty ? null : v.trim(),
            ),
          ),
          if (persona.reasoningMode == 'anthropic-budget') ...[
            const SizedBox(height: 12),
            TextFormField(
              key: ValueKey('ai-persona-budget-${persona.id}'),
              initialValue: persona.thinkingBudget > 0
                  ? '${persona.thinkingBudget}'
                  : '',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '思考 Token 预算（至少 1024）',
              ),
              onChanged: (v) => _change(
                () => persona.thinkingBudget = int.tryParse(v) ?? 0,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              FilterChip(
                label: const Text('允许联网'),
                selected:
                    persona.capabilities['webfetch'] != false &&
                    persona.capabilities['websearch'] != false,
                onSelected: (on) => _change(() {
                  persona.capabilities['webfetch'] = on;
                  persona.capabilities['websearch'] = on;
                }),
              ),
              FilterChip(
                label: const Text('允许执行命令'),
                selected: persona.capabilities['shell'] != false,
                onSelected: (on) =>
                    _change(() => persona.capabilities['shell'] = on),
              ),
              FilterChip(
                label: const Text('允许修改文件'),
                selected:
                    persona.capabilities['write'] != false &&
                    persona.capabilities['edit'] != false &&
                    persona.capabilities['apply_patch'] != false,
                onSelected: (on) => _change(() {
                  persona.capabilities['write'] = on;
                  persona.capabilities['edit'] = on;
                  persona.capabilities['apply_patch'] = on;
                }),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              'Persona 专属权限规则（${persona.permissionRules.length}）',
              style: const TextStyle(fontSize: 13),
            ),
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ActionChip(
                    label: const Text('+ 禁止写文件'),
                    onPressed: () => _change(
                      () => persona.permissionRules.add(
                        AiPermissionRule(
                          action: 'write_files',
                          resource: '*',
                          effect: 'deny',
                        ),
                      ),
                    ),
                  ),
                  ActionChip(
                    label: const Text('+ 禁止执行命令'),
                    onPressed: () => _change(
                      () => persona.permissionRules.add(
                        AiPermissionRule(
                          action: 'shell',
                          resource: '*',
                          effect: 'deny',
                        ),
                      ),
                    ),
                  ),
                  ActionChip(
                    label: const Text('+ 禁止联网'),
                    onPressed: () => _change(
                      () => persona.permissionRules.add(
                        AiPermissionRule(
                          action: 'network',
                          resource: '*',
                          effect: 'deny',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              for (var i = 0; i < persona.permissionRules.length; i++)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${persona.permissionRules[i].effect.toUpperCase()} · ${persona.permissionRules[i].action} (${persona.permissionRules[i].resource})',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 16),
                    onPressed: () =>
                        _change(() => persona.permissionRules.removeAt(i)),
                  ),
                ),
            ],
          ),
          AiCapabilityEditor(
            model: true,
            values: persona.capabilities,
            inherited: {
              ...aiCapabilityDefaults,
              ..._ai.toolDefaults,
              if (prov != null)
                ...?prov.modelOptions[persona.model.isEmpty
                        ? prov.model
                        : persona.model]
                    ?.capabilities,
            },
            onChanged: (v) => _change(() => persona.capabilities = v),
          ),
        ],
        ),
      ),
    );
  }

  Widget _defaultsPage(Ide ide) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_ai.personas.isEmpty)
        _notice(ide, '尚未创建 Persona，请先在「连接与模型」拉取模型清单并生成 Persona，或在「智能体人设」新建。')
      else ...[
        DropdownButtonFormField<String>(
          key: ValueKey('ai-default-persona-${_ai.activePersonaId ?? ''}'),
          initialValue:
              _ai.personaById(_ai.activePersonaId)?.id ??
              _ai.personas.first.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '新会话默认 Persona'),
          items: [
            for (final persona in _ai.personas)
              DropdownMenuItem(
                value: persona.id,
                child: Text(
                  '${persona.name}${persona.model.isEmpty ? '' : ' · ${persona.model}'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) =>
              _change(() => _ai.activePersonaId = v == null || v.isEmpty ? null : v),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey(
                  'ai-conductor-persona-${_ai.orchestratorConductorPersonaId ?? ''}',
                ),
                initialValue:
                    _ai.personaById(_ai.orchestratorConductorPersonaId)?.id ??
                    '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: '编排 · 指挥官 (主代理)'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('跟随默认 Persona')),
                  for (final persona in _ai.personas)
                    DropdownMenuItem(
                      value: persona.id,
                      child: Text(persona.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => _change(
                  () => _ai.orchestratorConductorPersonaId =
                      v == null || v.isEmpty ? null : v,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey(
                  'ai-musician-persona-${_ai.orchestratorMusicianPersonaId ?? ''}',
                ),
                initialValue:
                    _ai.personaById(_ai.orchestratorMusicianPersonaId)?.id ??
                    '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: '编排 · 乐手 (子代理)'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('跟随指挥官')),
                  for (final persona in _ai.personas)
                    DropdownMenuItem(
                      value: persona.id,
                      child: Text(persona.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => _change(
                  () => _ai.orchestratorMusicianPersonaId =
                      v == null || v.isEmpty ? null : v,
                ),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        initialValue: _ai.defaultAgent,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '新会话的工作模式'),
        items: const [
          DropdownMenuItem(value: 'build', child: Text('构建 · 可以调用工具修改文件')),
          DropdownMenuItem(value: 'plan', child: Text('规划 · 只读分析与方案')),
          DropdownMenuItem(
            value: 'orchestrator',
            child: Text('编排 · 指挥官拆解任务并调度乐手子代理'),
          ),
        ],
        onChanged: (v) => _change(() => _ai.defaultAgent = v!),
      ),
      const SizedBox(height: 16),
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
      const SizedBox(height: 18),
      Row(
        children: [
          Expanded(
            child: Text(
              '默认对话策略（新对话继承，可在各对话内独立调整）',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: ide.text,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('ai-reset-default-policy'),
            onPressed: () => _change(() {
              _ai.defaultPolicy = AiSessionPolicy();
              _policyEpoch++;
            }),
            child: const Text('恢复出厂默认'),
          ),
        ],
      ),
      AiSessionPolicyEditor(
        policy: _ai.defaultPolicy,
        epoch: _policyEpoch,
        onChanged: () => _change(() {}),
      ),
      const SizedBox(height: 16),
      const AiSectionHeading(icon: Icons.keyboard_outlined, title: '输入与阅读'),
      DropdownButtonFormField<String>(
        key: const ValueKey('ai-send-key'),
        initialValue: _ai.sendKey,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '发送快捷键'),
        items: const [
          DropdownMenuItem(
            value: 'enter',
            child: Text('Enter 发送 · Shift+Enter 换行'),
          ),
          DropdownMenuItem(
            value: 'ctrl-enter',
            child: Text('Ctrl / Cmd+Enter 发送 · Enter 换行'),
          ),
        ],
        onChanged: (v) => _change(() => _ai.sendKey = v!),
      ),
      const SizedBox(height: 12),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('默认展开思考过程'),
        subtitle: const Text('关闭时折叠呈现，随时可以展开。'),
        value: _ai.expandReasoning,
        onChanged: (v) => _change(() => _ai.expandReasoning = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('工具失败时展开详情'),
        value: _ai.expandErrors,
        onChanged: (v) => _change(() => _ai.expandErrors = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('显示新对话建议'),
        value: _ai.showQuickPrompts,
        onChanged: (v) => _change(() => _ai.showQuickPrompts = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('常驻消息导航'),
        subtitle: const Text('默认收在对话菜单；Alt+↑ / ↓ 始终可跳转消息。'),
        value: _ai.showMessageNavigation,
        onChanged: (v) => _change(() => _ai.showMessageNavigation = v),
      ),
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

  static const _actionLabels = <String, String>{
    '*': '* · 全部工具',
    'files': 'files · 所有文件操作',
    'write_files': 'write_files · 写入与编辑',
    'read': 'read · 读取文件',
    'edit': 'edit · 精确编辑',
    'write': 'write · 写入文件',
    'shell': 'shell · 执行命令',
    'network': 'network · 网页与搜索',
    'webfetch': 'webfetch · 读取网页',
    'websearch': 'websearch · 联网搜索',
    'subagent': 'subagent · 启动子代理',
    'mcp': 'mcp · MCP 工具',
  };

  static const _agentLabels = <String, String>{
    '': '全部代理（主代理 + 子代理）',
    'primary': '仅主代理（Build / Plan / Orchestrator）',
    'subagent': '仅子代理（Explore / General）',
    'build': 'Build 主代理',
    'plan': 'Plan 规划代理',
    'orchestrator': 'Orchestrator 指挥代理',
    'explore': 'Explore 只读子代理',
    'general': 'General 执行子代理',
  };

  String _ruleHint(String action) => switch (action) {
    'shell' => '例如 git status *、npm test * 或 rm -rf *',
    'network' || 'webfetch' => '例如 https://docs.example.com/* 或 *',
    'websearch' => '搜索词通配符，通常填 *',
    'subagent' => '例如 general 或 explore 或 *',
    'mcp' => '例如 server_id/* 或 *',
    _ => '例如 src/*、*.env* 或 *',
  };

  String _ruleExpiryLabel(AiPermissionRule r) {
    if (r.expiresAt <= 0) return '永久';
    final left = r.expiresAt - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) return '已过期';
    final mins = (left / 60000).ceil();
    if (mins < 60) return '$mins 分钟后过期';
    final hours = (mins / 60).ceil();
    if (hours < 48) return '$hours 小时后过期';
    return '${(hours / 24).ceil()} 天后过期';
  }

  Widget _permissionsPage(Ide ide) {
    final expiredCount = _ai.permissionRules.where((r) => r.isExpired).length;
    return Column(
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
              child: Text('先询问 · 修改文件、命令与外网访问需确认', overflow: TextOverflow.ellipsis),
            ),
            DropdownMenuItem(value: 'auto', child: Text('自动执行 · 高风险操作仍需确认')),
            DropdownMenuItem(
              value: 'full_access',
              child: Text('完全权限 (Full Access) · 免确认自动放行（显式拒绝仍生效）'),
            ),
          ],
          onChanged: (v) => _change(() => _ai.permissionMode = v!),
        ),
        const SizedBox(height: 14),
        Text(
          '一键权限方案',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: ide.text,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            ActionChip(
              key: const ValueKey('ai-preset-readonly'),
              avatar: const Icon(Icons.visibility_outlined, size: 15),
              label: const Text('只读探索'),
              onPressed: () => _applyPermissionPreset('readonly'),
            ),
            ActionChip(
              key: const ValueKey('ai-preset-balanced'),
              avatar: const Icon(Icons.balance_outlined, size: 15),
              label: const Text('标准开发'),
              onPressed: () => _applyPermissionPreset('balanced'),
            ),
            ActionChip(
              key: const ValueKey('ai-preset-isolated-subagent'),
              avatar: const Icon(Icons.security_outlined, size: 15),
              label: const Text('子代理严格隔离'),
              onPressed: () => _applyPermissionPreset('isolated_subagent'),
            ),
            ActionChip(
              key: const ValueKey('ai-preset-auto'),
              avatar: const Icon(Icons.bolt_outlined, size: 15),
              label: const Text('自动受控'),
              onPressed: () => _applyPermissionPreset('auto_guarded'),
            ),
            ActionChip(
              key: const ValueKey('ai-preset-full-access'),
              avatar: const Icon(Icons.lock_open_rounded, size: 15),
              label: const Text('完全权限'),
              onPressed: () => _applyPermissionPreset('full_access'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _notice(
          ide,
          '规则从上到下匹配，最后命中的启用规则生效；显式拒绝优先于规划/探索模式。可分别约束主代理、子代理、网络、文件、命令及规则有效期。\n“本会话允许”是运行时授权，可在对话菜单「本会话授权…」中查看或撤销。',
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Text(
                '权限规则（${_ai.permissionRules.length}）',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: ide.text,
                ),
              ),
            ),
            if (expiredCount > 0)
              TextButton.icon(
                onPressed: _pruneExpiredRules,
                icon: const Icon(Icons.cleaning_services_outlined, size: 15),
                label: Text('清理 $expiredCount 条已过期'),
              ),
          ],
        ),
        const SizedBox(height: 8),
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
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ActionChip(
              label: const Text('+ 允许测试命令'),
              onPressed: () => _fillRuleTemplate(
                effect: 'allow',
                action: 'shell',
                resource: 'npm test *',
              ),
            ),
            ActionChip(
              label: const Text('+ 禁止子代理联网'),
              onPressed: () => _fillRuleTemplate(
                effect: 'deny',
                action: 'network',
                resource: '*',
                agent: 'subagent',
              ),
            ),
            ActionChip(
              label: const Text('+ 禁止子代理执行命令'),
              onPressed: () => _fillRuleTemplate(
                effect: 'deny',
                action: 'shell',
                resource: '*',
                agent: 'subagent',
              ),
            ),
            ActionChip(
              label: const Text('+ 允许文档站'),
              onPressed: () => _fillRuleTemplate(
                effect: 'allow',
                action: 'webfetch',
                resource: 'https://docs.*/*',
              ),
            ),
            ActionChip(
              label: const Text('+ 保护 .env 凭据'),
              onPressed: () => _fillRuleTemplate(
                effect: 'deny',
                action: 'read',
                resource: '*.env*',
              ),
            ),
          ],
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
                    ..._actionLabels.keys,
                    _ruleAction,
                  })
                    DropdownMenuItem(
                      value: a,
                      child: Text(
                        _actionLabels[a] ?? a,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => _change(() => _ruleAction = v!),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('ai-rule-agent-$_ruleAgent'),
                initialValue: _agentLabels.containsKey(_ruleAgent)
                    ? _ruleAgent
                    : '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: '适用代理角色'),
                items: [
                  for (final entry in _agentLabels.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => _change(() => _ruleAgent = v!),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                key: ValueKey('ai-rule-ttl-$_ruleTtlHours'),
                initialValue: _ruleTtlHours,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '规则生命周期'),
                items: [
                  if (_ruleTtlHours < 0)
                    const DropdownMenuItem(value: -1, child: Text('保持原过期时间')),
                  const DropdownMenuItem(value: 0, child: Text('永久有效')),
                  const DropdownMenuItem(value: 1, child: Text('1 小时后过期')),
                  const DropdownMenuItem(value: 24, child: Text('24 小时后过期')),
                  const DropdownMenuItem(value: 168, child: Text('7 天后过期')),
                ],
                onChanged: (v) => _change(() => _ruleTtlHours = v!),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _field(
          _resource,
          '资源模式',
          key: 'ai-rule-resource',
          hint: _ruleHint(_ruleAction),
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
  }

  Widget _ruleTile(Ide ide, int i) {
    final r = _ai.permissionRules[i];
    final here = r.appliesTo(widget.ws?.serverId ?? '', widget.ws?.project?.id);
    final expired = r.isExpired;
    final inactive = r.disabled || expired;
    final roleLabel = _agentLabels[r.agent] ?? r.agent;
    final expiryLabel = _ruleExpiryLabel(r);
    return Opacity(
      opacity: inactive ? 0.55 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: ide.editor,
          border: Border.all(color: expired ? ide.warn : ide.border),
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
                const SizedBox(width: 8),
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
                if (r.agent.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      roleLabel,
                      style: TextStyle(fontSize: 10.5, color: ide.accent),
                    ),
                  ),
                Text(
                  '$expiryLabel · ${r.scope == 'global'
                      ? '全局'
                      : here
                      ? '当前项目'
                      : '其他项目'}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: expired ? ide.warn : ide.textFaint,
                  ),
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
              children: [
                Transform.scale(
                  scale: 0.78,
                  alignment: Alignment.centerLeft,
                  child: Switch(
                    value: !r.disabled,
                    onChanged: (on) => _change(() => r.disabled = !on),
                  ),
                ),
                Text(
                  r.disabled ? '已停用' : '启用中',
                  style: TextStyle(fontSize: 11, color: ide.textDim),
                ),
                const Spacer(),
                IconBtn(
                  Icons.arrow_upward,
                  '上移规则',
                  i == 0
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
                IconBtn(
                  Icons.arrow_downward,
                  '下移规则',
                  i == _ai.permissionRules.length - 1
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
                IconBtn(
                  Icons.edit_outlined,
                  '编辑规则',
                  r.scope != 'global' && !here ? null : () => _editRule(i),
                ),
                IconBtn(
                  Icons.delete_outline,
                  '删除规则',
                  () => _change(() {
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
      ),
    );
  }
}
