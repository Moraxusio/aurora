// OpenCode-compatible LLM Provider & API Key configuration dialog (D-104).
// Credentials are stored exclusively in the client's sealed profile (DPAPI / Android Keystore).
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../state/app_state.dart';
import '../../theme/ide_theme.dart';
import 'ai_auth.dart';
import 'ai_oauth_client.dart';
import 'ai_model_discovery.dart';
import 'ai_visuals.dart';

class _Preset {
  final String label;
  final String name;
  final String protocol;
  final String baseUrl;
  final String defaultModel;
  const _Preset(this.label, this.name, this.protocol, this.baseUrl, this.defaultModel);
}

const _presets = <_Preset>[
  _Preset('OpenAI / ChatGPT 订阅（设备码）', 'ChatGPT 订阅', 'openai-responses', 'https://chatgpt.com/backend-api/codex', 'gpt-6.1-sol'),
  _Preset('自定义 OpenAI 兼容网关', '兼容网关', 'openai-chat', '', ''),
  _Preset('OpenAI API Key', 'OpenAI API', 'openai-chat', 'https://api.openai.com/v1', 'gpt-5.2'),
  _Preset('Anthropic Messages (/v1/messages)', 'Anthropic', 'anthropic-messages', 'https://api.anthropic.com/v1', 'claude-sonnet-4-5'),
  _Preset('OpenAI Responses (/v1/responses)', 'OpenAI Responses', 'openai-responses', 'https://api.openai.com/v1', 'gpt-5.2-codex'),
  _Preset('OpenRouter', 'OpenRouter', 'openai-chat', 'https://openrouter.ai/api/v1', 'anthropic/claude-sonnet-4.5'),
  _Preset('DeepSeek', 'DeepSeek', 'openai-chat', 'https://api.deepseek.com/v1', 'deepseek-chat'),
  _Preset('OpenCode Zen', 'OpenCode Zen', 'anthropic-messages', 'https://opencode.ai/zen/v1', 'claude-sonnet-4-5'),
];

Future<void> showAiSettingsDialog(BuildContext context, {required AppState app, Workspace? ws,AiOAuthClient Function()? localAuthFactory}) {
  return showWorkbenchDialog<void>(
    context: context,
    builder: (_) => AiSettingsDialog(app: app, ws: ws,localAuthFactory:localAuthFactory),
  );
}

class AiSettingsDialog extends StatefulWidget {
  final AppState app;
  final Workspace? ws;
  final AiOAuthClient Function()? localAuthFactory;
  const AiSettingsDialog({super.key, required this.app, this.ws,this.localAuthFactory});

  @override
  State<AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<AiSettingsDialog> {
  late AiSettings _ai;
  String? _editingId;

  final _nameCtl = TextEditingController();
  final _baseUrlCtl = TextEditingController();
  final _apiKeyCtl = TextEditingController();
  final _modelCtl = TextEditingController();
  final _contextCtl = TextEditingController();
  final _modelSearchCtl = TextEditingController();
  bool _modelsViaClient = false;
  Map<String, String> _originalKeys = {};

  String _protocol = 'openai-chat';
  String _authMode = '';
  String _reasoningEffort = '';
  bool _useProxy = false;
  String _proxyMode = '';
  bool _obscureKey = true;
  bool _fetchingModels = false;
  List<String> _fetchedModels = [];
  String? _fetchNote;
  bool get _subscription => _authMode == 'chatgpt-device';

  @override
  void initState() {
    super.initState();
    _ai = widget.app.ready
        ? AiSettings.fromJson(widget.app.profile.ai.toJson())
        : AiSettings();
    _originalKeys = {for (final p in _ai.providers) p.id: p.apiKey};
    _modelsViaClient = widget.ws?.link == null;
    if (_ai.providers.isEmpty) {
      final first = AiProvider.create(
        name: 'OpenAI API',
        protocol: 'openai-chat',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5.2',
      );
      _ai.providers.add(first);
      _ai.selectedProviderId = first.id;
    }
    _loadProvider(_ai.activeProvider!);
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _baseUrlCtl.dispose();
    _apiKeyCtl.dispose();
    _modelCtl.dispose();
    _contextCtl.dispose();
    _modelSearchCtl.dispose();
    super.dispose();
  }

  void _saveCurrentToMemory() {
    final id = _editingId;
    if (id == null) return;
    final idx = _ai.providers.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    final p = _ai.providers[idx];
    p.name = _nameCtl.text.trim().isEmpty ? 'OpenCode API' : _nameCtl.text.trim();
    p.protocol = _protocol;
    p.baseUrl = _baseUrlCtl.text.trim();
    p.apiKey = _apiKeyCtl.text.trim();
    p.authMode = _authMode;
    p.model = _modelCtl.text.trim();
    p.reasoningEffort = _reasoningEffort;
    p.useProxy = _useProxy;
    p.proxyMode = _proxyMode;
    p.contextWindow = int.tryParse(_contextCtl.text.trim()) ?? 0;
    p.models = {..._fetchedModels, if (p.model.isNotEmpty) p.model}.toList();
  }

  void _loadProvider(AiProvider p) {
    _editingId = p.id;
    _nameCtl.text = p.name;
    _baseUrlCtl.text = p.baseUrl;
    _apiKeyCtl.text = p.apiKey;
    _modelCtl.text = p.model;
    _contextCtl.text = p.contextWindow > 0 ? '${p.contextWindow}' : '';
    _protocol = p.protocol;
    _authMode = p.authMode;
    _reasoningEffort = p.reasoningEffort;
    _useProxy = p.useProxy;
    _proxyMode = p.proxyMode;
    _fetchedModels = List.of(p.models);
    _fetchNote = null;
    _modelSearchCtl.clear();
  }

  void _addFromPreset(_Preset preset) {
    _saveCurrentToMemory();
    final created = AiProvider.create(
      name: preset.name,
      protocol: preset.protocol,
      baseUrl: preset.baseUrl,
      model: preset.defaultModel,
    );
    if (preset.baseUrl == 'https://chatgpt.com/backend-api/codex') created.authMode = 'chatgpt-device';
    setState(() {
      _ai.providers.add(created);
      _ai.selectedProviderId = created.id;
      _loadProvider(created);
    });
  }

  void _deleteCurrent() {
    if (_ai.providers.length <= 1) {
      Toast.show('至少保留一个提供商配置', error: true);
      return;
    }
    setState(() {
      _ai.providers.removeWhere((p) => p.id == _editingId);
      final next = _ai.providers.first;
      _ai.selectedProviderId = next.id;
      _loadProvider(next);
    });
  }

  Future<void> _fetchModels() async {
    final link = widget.ws?.link;
    if (!_modelsViaClient && link == null) {
      setState(() => _fetchNote = '所选 agent 未连接，可切换“本机网络”拉取，或手动添加模型');
      return;
    }
    _saveCurrentToMemory();
    final current = _ai.providers.firstWhere((p) => p.id == _editingId);
    setState(() {
      _fetchingModels = true;
      _fetchNote = null;
    });
    try {
      final Map res;
      if (_modelsViaClient) {
        if (current.proxyMode == 'agent') throw StateError('Aurora 代理由 agent 提供，请选择“当前 agent 网络”拉取模型');
        res = {'models': await discoverAiModels(current)};
      } else {
        final prepared = await prepareAiProvider(widget.app, link!, current);
        res = await link.call('ai.models', {'provider': prepared.toWireJson()}) as Map;
      }
      final list = <String>[
        for (final m in (res['models'] as List? ?? const []))
          if (m is Map && (m['id'] as String? ?? '').isNotEmpty) m['id'] as String,
      ];
      if (!mounted || current.id != _editingId || !_ai.providers.contains(current)) return;
      setState(() {
        _fetchedModels = {..._fetchedModels, ...list, if (_modelCtl.text.trim().isNotEmpty) _modelCtl.text.trim()}.toList()..sort();
        current.models = List.of(_fetchedModels);
        for (final m in (res['models'] as List? ?? const [])) {
          if (m is Map && m['id'] is String && m['context_window'] is num && (m['context_window'] as num) > 0) {
            current.modelContextWindows[m['id'] as String] = (m['context_window'] as num).toInt();
          }
        }
        if (_modelCtl.text.trim().isEmpty && list.isNotEmpty) {
          _modelCtl.text = list.first;
        }
        _fetchNote = current.isSubscription ? '内置订阅模型建议（不是账号可用性校验），支持手动输入；窗口为 OpenCode 默认输入预算。' : list.isEmpty ? '接口返回成功，但未列出模型，请手动输入模型 ID' : '已获取 ${list.length} 个模型';
      });
    } on OpError catch (e) {
      if (mounted && current.id == _editingId) setState(() => _fetchNote = e.message);
    } on Object catch (e) {
      if (mounted && current.id == _editingId) setState(() => _fetchNote = e is StateError ? e.message : '拉取失败，请检查连接');
    } finally {
      if (mounted) setState(() => _fetchingModels = false);
    }
  }

  Future<void> _login() async {
    final link = widget.ws?.link;
    if (!widget.app.ready) { Toast.show('请先解锁本机加密配置', error:true); return; }
    _saveCurrentToMemory();
    final current = _ai.providers.firstWhere((p) => p.id == _editingId);
    final baseline = widget.app.profile.ai.providers.where((p) => p.id == current.id).firstOrNull;
    final c = await showAiDeviceLogin(context, link, useProxy:current.usesProxy, proxyMode: _proxyMode, initialTransport: _proxyMode == 'agent' ? 'server' : 'client', localFactory:widget.localAuthFactory);
    if (!mounted || c == null || current.id != _editingId || !current.isSubscription) return;
    try {
      await widget.app.update((profile) {
        var target = profile.ai.providers.where((p) => p.id == current.id).firstOrNull;
        if (target == null) {
          target = AiProvider.fromJson(current.toJson());
          profile.ai.providers.add(target);
        } else if (target.oauth?.refresh != baseline?.oauth?.refresh || target.authMode != baseline?.authMode) {
          throw StateError('登录配置已变更，请重新打开设置');
        }
        target.oauth = c;
        target.authMode = 'chatgpt-device';
        target.protocol = 'openai-responses';
        target.baseUrl = 'https://chatgpt.com/backend-api/codex';
        target.model = current.model;
      });
      if (mounted) setState(() { current.oauth = c; _fetchNote = '订阅登录已加密保存；原 API Key 保留但订阅调用不使用它'; });
    } on Object { if (mounted) setState(() => _fetchNote = '登录凭据保存失败或配置已变更，请重试'); }
  }

  Future<void> _logout() async {
    final id = _editingId;
    try {
      await widget.app.update((profile) {
        for (final p in profile.ai.providers) { if (p.id == id) p.oauth = null; }
      });
      if (mounted) setState(() { for (final p in _ai.providers) { if (p.id == id) p.oauth = null; } });
    } on Object { Toast.show('退出登录保存失败', error:true); }
  }

  Future<void> _saveAndClose() async {
    if (!_subscription) {
      final uri = Uri.tryParse(_baseUrlCtl.text.trim());
      if (uri == null || !uri.hasAuthority || uri.userInfo.isNotEmpty || !['http','https'].contains(uri.scheme)) {
        Toast.show('请填写有效的 HTTP(S) API Base URL，不能在 URL 中嵌入账号密码', error: true); return;
      }
    }
    final contextValue = int.tryParse(_contextCtl.text.trim());
    if (_contextCtl.text.trim().isNotEmpty && (contextValue == null || contextValue < 0)) {
      Toast.show('上下文窗口应为非负整数，留空或 0 使用模型默认值', error:true); return;
    }
    _saveCurrentToMemory();
    if (_modelCtl.text.trim().isEmpty) {
      Toast.show('请填写模型 ID（例如 claude-sonnet-4-5 或 gpt-5.2-codex）', error: true);
      return;
    }
    _ai.selectedProviderId = _editingId;
    if (!widget.app.ready) {
      Toast.show('本机加密配置未就绪，无法保存', error: true);
      return;
    }
    try {
      await widget.app.update((p) {
        // A refresh may have rotated tokens while this settings dialog was open.
        for (final local in _ai.providers) {
          final live = p.ai.providers.where((x) => x.id == local.id).firstOrNull;
          if (live != null) {
            local.oauth = live.oauth;
            if (live.apiKey != _originalKeys[local.id]) {
              if (local.apiKey != _originalKeys[local.id]) throw StateError('凭证已在别处更新，请重新打开设置，防止覆盖');
              local.apiKey = live.apiKey;
            }
          }
        }
        _ai.chatFontSize = p.ai.chatFontSize;
        p.ai = AiSettings.fromJson(_ai.toJson());
      });
      if (mounted) Navigator.pop(context);
    } on Object catch (e) {
      Toast.show('保存失败：$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final visibleModels = _fetchedModels.where((m) => m.toLowerCase().contains(_modelSearchCtl.text.trim().toLowerCase())).toList();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 660),
        child: Padding(
          padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 500 ? 16 : Space.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AiSectionHeading(icon: Icons.tune_rounded, title: 'AI 模型与 OpenCode 协议配置',
                subtitle: '管理提供商、连接与模型。凭据加密保存在本机。',
                trailing: IconBtn(Icons.close_rounded, '关闭', () => Navigator.pop(context))),
              const SizedBox(height: Space.l),
              // Provider tabs + add preset button
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final p in _ai.providers)
                      Padding(
                        padding: const EdgeInsets.only(right: Space.s),
                        child: ChoiceChip(
                          label: Text(p.id == _editingId ? (_nameCtl.text.trim().isEmpty ? p.name : _nameCtl.text.trim()) : p.name),
                          selected: p.id == _editingId,
                          onSelected: (_) {
                            _saveCurrentToMemory();
                            setState(() {
                              _ai.selectedProviderId = p.id;
                              _loadProvider(p);
                            });
                          },
                        ),
                      ),
                    WorkbenchMenuButton<_Preset>(
                      tooltip: '添加提供商预设',
                      onSelected: _addFromPreset,
                      itemBuilder: (_) => [
                        for (final pr in _presets)
                          PopupMenuItem(value: pr, child: Text(pr.label, style: const TextStyle(fontSize: 13))),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(Radii.m),
                          border: Border.all(color: ide.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_rounded, size: 15, color: ide.accent),
                            const SizedBox(width: 4),
                            Text('添加预设', style: TextStyle(fontSize: 12, color: ide.accent)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.l),
              Expanded(
                child: ListView(
                  children: [
                    const AiSectionHeading(icon: Icons.dns_outlined, title: '提供商连接', subtitle: '模型调用由当前本地 / 远程 agent 执行'),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: _nameCtl,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(labelText: '配置名称', hintText: '例如 OpenCode 主力网关'),
                          ),
                        ),
                        const SizedBox(width: Space.m),
                        Expanded(
                          flex: 4,
                            child: DropdownButtonFormField<String>(
                              key: ValueKey('ai-protocol-$_editingId-$_protocol'),
                            isExpanded: true,
                            initialValue: _protocol,
                            decoration: const InputDecoration(labelText: 'OpenCode 线协议'),
                            items: const [
                              DropdownMenuItem(value: 'openai-chat', child: Text('OpenAI Chat (/chat/completions)', overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: 'anthropic-messages', child: Text('Anthropic Messages (/messages)', overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: 'openai-responses', child: Text('OpenAI Responses (/responses)', overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: _subscription ? null : (v) {
                              if (v == null) return;
                              setState(() {
                                _protocol = v;
                                if (_baseUrlCtl.text.trim() == 'https://api.openai.com/v1' && v == 'anthropic-messages') {
                                  _baseUrlCtl.text = 'https://api.anthropic.com/v1';
                                } else if (_baseUrlCtl.text.trim() == 'https://api.anthropic.com/v1' && v != 'anthropic-messages') {
                                  _baseUrlCtl.text = 'https://api.openai.com/v1';
                                }
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.m + 2),
                    TextField(
                      controller: _baseUrlCtl,
                      enabled: !_subscription,
                      decoration: const InputDecoration(
                        labelText: 'API Base URL',
                        hintText: 'https://api.openai.com/v1 或你的 OpenCode 兼容网关地址',
                      ),
                    ),
                    const SizedBox(height: Space.m + 2),
                    const AiSectionHeading(icon: Icons.key_outlined, title: '身份与凭据'),
                    DropdownButtonFormField<String>(
                      key: ValueKey('ai-auth-$_editingId-$_authMode'),
                      isExpanded: true,
                      initialValue: _authMode,
                      decoration:const InputDecoration(labelText:'登录方式 / 鉴权格式'),
                      items:const [
                        DropdownMenuItem(value:'', child:Text('API Key · 自动兼容', overflow: TextOverflow.ellipsis)),
                        DropdownMenuItem(value:'bearer', child:Text('API Key · Bearer', overflow: TextOverflow.ellipsis)),
                        DropdownMenuItem(value:'x-api-key', child:Text('API Key · x-api-key', overflow: TextOverflow.ellipsis)),
                        DropdownMenuItem(value:'chatgpt-device', child:Text('ChatGPT 订阅 · Device 设备码', overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged:(v) => setState(() {
                        _authMode = v ?? '';
                        if (_subscription) { _protocol = 'openai-responses'; _baseUrlCtl.text = 'https://chatgpt.com/backend-api/codex'; if (!_modelCtl.text.startsWith('gpt-')) _modelCtl.text = 'gpt-6.1-sol'; }
                      }),
                    ),
                    const SizedBox(height:Space.m),
                    if (_subscription) ...[
                      Text(_ai.providers.firstWhere((p) => p.id == _editingId).oauth == null ? '尚未登录 ChatGPT 订阅' : '已登录 · 凭据加密保存在本机', style:TextStyle(color:ide.textDim, fontSize:12)),
                      Wrap(spacing:8, children:[
                        FilledButton.icon(key:const ValueKey('ai-device-login'), onPressed:_login, icon:const Icon(Icons.login, size:16), label:const Text('使用设备码登录')),
                        TextButton(onPressed:widget.app.ready ? _logout : null, child:const Text('退出订阅登录')),
                      ]),
                      const Text('固定连接官方 ChatGPT/Codex；不允许自定义地址或请求头。登录/退出立即保存，不受底部取消按钮影响。', style:TextStyle(fontSize:11.5)),
                    ] else Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: TextField(
                            key: const ValueKey('ai-api-key'),
                            controller: _apiKeyCtl,
                            obscureText: _obscureKey,
                            decoration: InputDecoration(
                              labelText: 'API Key',
                              hintText: 'sk-...',
                              suffixIcon: IconButton(
                                icon: Icon(_obscureKey ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 17),
                                onPressed: () => setState(() => _obscureKey = !_obscureKey),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.m + 2),
                    const AiSectionHeading(icon: Icons.memory_outlined, title: '模型与上下文'),
                    TextField(
                      key:const ValueKey('ai-context-window'),
                      controller:_contextCtl, keyboardType:TextInputType.number,
                      decoration:const InputDecoration(labelText:'上下文输入窗口（tokens，可选）', hintText:'留空使用模型目录 / 默认估值；切换模型前请检查手动覆盖值'),
                    ),
                    const SizedBox(height: Space.m + 2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('ai-model-id'),
                            controller: _modelCtl,
                            decoration: const InputDecoration(
                              labelText: '模型 ID (Model)',
                              hintText: 'claude-sonnet-4-5 / gpt-5.2-codex / deepseek-reasoner',
                            ),
                          ),
                        ),
                        const SizedBox(width: Space.m),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: OutlinedButton.icon(
                            onPressed: _fetchingModels ? null : _fetchModels,
                            icon: _fetchingModels
                                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.refresh_rounded, size: 16),
                            label: const Text('拉取模型'),
                          ),
                        ),
                      ],
                    ),
                    Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      TextButton.icon(key: const ValueKey('ai-add-model'), onPressed: () {
                        final id = _modelCtl.text.trim();
                        if (id.isEmpty) { setState(() => _fetchNote = '先填写模型 ID，再点击添加'); return; }
                        setState(() { _fetchedModels = {..._fetchedModels, id}.toList()..sort(); _fetchNote = '已添加 $id，保存后可在会话模型选择器使用'; });
                      }, icon: const Icon(Icons.add, size: 16), label: const Text('添加此模型')),
                      ChoiceChip(label: const Text('本机网络'), selected: _modelsViaClient, onSelected: _fetchingModels ? null : (_) => setState(() => _modelsViaClient = true)),
                      ChoiceChip(label: const Text('当前 agent 网络'), selected: !_modelsViaClient, onSelected: _fetchingModels ? null : (_) => setState(() => _modelsViaClient = false)),
                    ]),
                    if (_fetchNote != null) ...[
                      const SizedBox(height: Space.xs + 2),
                      Text(_fetchNote!, style: TextStyle(fontSize: 12, color: ide.textDim)),
                    ],
                    if (_fetchedModels.isNotEmpty) ...[
                      const SizedBox(height: Space.s),
                      TextField(key: const ValueKey('ai-search-models'), controller: _modelSearchCtl, onChanged: (_) => setState(() {}), decoration: InputDecoration(prefixIcon: const Icon(Icons.search, size: 16), hintText: '搜索 ${_fetchedModels.length} 个模型（手动模型会保留）', isDense: true)),
                      SizedBox(height: visibleModels.isEmpty ? 42 : (visibleModels.length * 40.0).clamp(40, 140), child: visibleModels.isEmpty
                        ? const Center(child: Text('没有匹配模型，可在上方手动添加'))
                        : ListView.builder(key: const ValueKey('ai-model-catalog'), itemExtent: 40, itemCount: visibleModels.length, itemBuilder: (_, index) {
                          final m = visibleModels[index];
                          return ListTile(dense: true, selected: _modelCtl.text.trim() == m,
                            title: Text(m, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                            leading: Icon(_modelCtl.text.trim() == m ? Icons.check_circle_outline : Icons.circle_outlined, size: 16),
                            trailing: IconButton(tooltip: '从已保存列表移除', icon: const Icon(Icons.close, size: 14), onPressed: () => setState(() => _fetchedModels.remove(m))),
                            onTap: () => setState(() => _modelCtl.text = m));
                        })),
                    ],
                    const SizedBox(height: Space.m + 2),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            key: ValueKey('ai-reasoning-$_editingId'),
                            isExpanded: true,
                            initialValue: _reasoningEffort,
                            decoration: const InputDecoration(labelText: '推理思考强度 (Reasoning / Thinking)'),
                            items: const [
                              DropdownMenuItem(value: '', child: Text('默认（由模型或网关决定）', overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: 'low', child: Text('Low（快速思考）', overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: 'medium', child: Text('Medium（均衡思考）', overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: 'high', child: Text('High（深度思考）', overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (v) => setState(() => _reasoningEffort = v ?? ''),
                          ),
                        ),
                        const SizedBox(width: Space.m),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: _ai.permissionMode,
                            decoration: const InputDecoration(labelText: '默认工具执行权限'),
                            items: const [
                              DropdownMenuItem(value: 'ask', child: Text('询问批准（写文件与非只读命令需确认）', overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: 'auto', child: Text('自动执行（Build 模式自动运行工具）', overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (v) => setState(() => _ai.permissionMode = v ?? 'ask'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.m),
                    DropdownButtonFormField<String>(
                      key: ValueKey('ai-proxy-mode-$_editingId-$_proxyMode'), initialValue: _proxyMode, isExpanded: true,
                      decoration: const InputDecoration(labelText: '模型 API / AI 工具的网络出口'),
                      items: [
                        DropdownMenuItem(value: '', child: Text('沿用旧设置（${_useProxy ? '使用执行端代理' : 'API 直连，shell 继承环境'}）', overflow: TextOverflow.ellipsis)),
                        const DropdownMenuItem(value: 'system', child: Text('本机代理 / 执行端环境代理', overflow: TextOverflow.ellipsis)),
                        const DropdownMenuItem(value: 'agent', child: Text('Aurora agent 配置的代理节点', overflow: TextOverflow.ellipsis)),
                        const DropdownMenuItem(value: 'direct', child: Text('直连（API 和工具不注入代理）', overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (v) => setState(() { _proxyMode = v ?? ''; if (_proxyMode == 'agent') _modelsViaClient = false; }),
                    ),
                    const SizedBox(height: Space.s),
                    Text('本地 agent 的“本机代理”读取环境变量 / Windows 手动代理；远程 agent 读取服务器环境。Aurora 节点在对应工作区的“代理”页配置。', style: TextStyle(fontSize: 11.5, color: ide.textFaint)),
                  ],
                ),
              ),
              const SizedBox(height: Space.l),
              Wrap(alignment: WrapAlignment.end, spacing: Space.s,
                children: [
                  if (_ai.providers.length > 1)
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: ide.error),
                      onPressed: _deleteCurrent,
                      icon: const Icon(Icons.delete_outline_rounded, size: 16),
                      label: const Text('删除此配置'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('取消', style: TextStyle(color: ide.text)),
                  ),
                  const SizedBox(width: Space.s),
                  FilledButton(
                    key: const ValueKey('ai-save-settings'),
                    onPressed: _saveAndClose,
                    child: const Text('保存并启用'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
