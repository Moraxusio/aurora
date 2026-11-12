// OpenCode-compatible LLM Provider & API Key configuration dialog (D-104).
// Credentials are stored exclusively in the client's sealed profile (DPAPI / Android Keystore).
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../state/app_state.dart';
import '../../theme/ide_theme.dart';

class _Preset {
  final String label;
  final String name;
  final String protocol;
  final String baseUrl;
  final String defaultModel;
  const _Preset(this.label, this.name, this.protocol, this.baseUrl, this.defaultModel);
}

const _presets = <_Preset>[
  _Preset('OpenCode Gateway / 兼容网关', 'OpenCode API', 'openai-chat', 'https://api.openai.com/v1', 'claude-sonnet-4-5'),
  _Preset('Anthropic Messages (/v1/messages)', 'Anthropic', 'anthropic-messages', 'https://api.anthropic.com/v1', 'claude-sonnet-4-5'),
  _Preset('OpenAI Responses (/v1/responses)', 'OpenAI Responses', 'openai-responses', 'https://api.openai.com/v1', 'gpt-5.2-codex'),
  _Preset('OpenRouter', 'OpenRouter', 'openai-chat', 'https://openrouter.ai/api/v1', 'anthropic/claude-sonnet-4.5'),
  _Preset('DeepSeek', 'DeepSeek', 'openai-chat', 'https://api.deepseek.com/v1', 'deepseek-chat'),
  _Preset('OpenCode Zen', 'OpenCode Zen', 'anthropic-messages', 'https://opencode.ai/zen/v1', 'claude-sonnet-4-5'),
];

Future<void> showAiSettingsDialog(BuildContext context, {required AppState app, Workspace? ws}) {
  return showDialog<void>(
    context: context,
    builder: (_) => AiSettingsDialog(app: app, ws: ws),
  );
}

class AiSettingsDialog extends StatefulWidget {
  final AppState app;
  final Workspace? ws;
  const AiSettingsDialog({super.key, required this.app, this.ws});

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

  String _protocol = 'openai-chat';
  String _authMode = '';
  String _reasoningEffort = '';
  bool _useProxy = false;
  bool _obscureKey = true;
  bool _fetchingModels = false;
  List<String> _fetchedModels = [];
  String? _fetchNote;

  @override
  void initState() {
    super.initState();
    _ai = widget.app.ready
        ? AiSettings.fromJson(widget.app.profile.ai.toJson())
        : AiSettings();
    if (_ai.providers.isEmpty) {
      final first = AiProvider.create(
        name: 'OpenCode API',
        protocol: 'openai-chat',
        baseUrl: 'https://api.openai.com/v1',
        model: 'claude-sonnet-4-5',
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
    if (_fetchedModels.isNotEmpty) {
      p.models = List.of(_fetchedModels);
    }
  }

  void _loadProvider(AiProvider p) {
    _editingId = p.id;
    _nameCtl.text = p.name;
    _baseUrlCtl.text = p.baseUrl;
    _apiKeyCtl.text = p.apiKey;
    _modelCtl.text = p.model;
    _protocol = p.protocol;
    _authMode = p.authMode;
    _reasoningEffort = p.reasoningEffort;
    _useProxy = p.useProxy;
    _fetchedModels = List.of(p.models);
    _fetchNote = null;
  }

  void _addFromPreset(_Preset preset) {
    _saveCurrentToMemory();
    final created = AiProvider.create(
      name: preset.name,
      protocol: preset.protocol,
      baseUrl: preset.baseUrl,
      model: preset.defaultModel,
    );
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
    if (link == null) {
      setState(() => _fetchNote = '请先连接一台装有新版 agent 的服务器，以通过服务器测试并拉取模型列表');
      return;
    }
    _saveCurrentToMemory();
    final current = _ai.providers.firstWhere((p) => p.id == _editingId);
    setState(() {
      _fetchingModels = true;
      _fetchNote = null;
    });
    try {
      final res = await link.call('ai.models', {'provider': current.toWireJson()}) as Map;
      final list = <String>[
        for (final m in (res['models'] as List? ?? const []))
          if (m is Map && (m['id'] as String? ?? '').isNotEmpty) m['id'] as String,
      ];
      if (!mounted) return;
      setState(() {
        _fetchedModels = list;
        current.models = list;
        if (_modelCtl.text.trim().isEmpty && list.isNotEmpty) {
          _modelCtl.text = list.first;
        }
        _fetchNote = list.isEmpty ? '接口返回成功，但未列出模型，请手动输入模型 ID' : '已获取 ${list.length} 个可用模型';
      });
    } on OpError catch (e) {
      if (mounted) setState(() => _fetchNote = e.message);
    } on Object catch (e) {
      if (mounted) setState(() => _fetchNote = '拉取失败：$e');
    } finally {
      if (mounted) setState(() => _fetchingModels = false);
    }
  }

  Future<void> _saveAndClose() async {
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
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 660),
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 20, color: ide.accent),
                  const SizedBox(width: Space.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('AI 模型与 OpenCode 协议配置', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ide.text)),
                        Text('密钥仅加密保存在本机（DPAPI / Keystore），按次经固定指纹 TLS 传给服务器内存，绝不落盘。',
                            style: TextStyle(fontSize: 11.5, color: ide.textDim)),
                      ],
                    ),
                  ),
                  IconBtn(Icons.close_rounded, '关闭', () => Navigator.pop(context)),
                ],
              ),
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
                    PopupMenuButton<_Preset>(
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
                            isExpanded: true,
                            initialValue: _protocol,
                            decoration: const InputDecoration(labelText: 'OpenCode 线协议'),
                            items: const [
                              DropdownMenuItem(value: 'openai-chat', child: Text('OpenAI Chat (/chat/completions)', overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: 'anthropic-messages', child: Text('Anthropic Messages (/messages)', overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: 'openai-responses', child: Text('OpenAI Responses (/responses)', overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (v) {
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
                      decoration: const InputDecoration(
                        labelText: 'API Base URL',
                        hintText: 'https://api.openai.com/v1 或你的 OpenCode 兼容网关地址',
                      ),
                    ),
                    const SizedBox(height: Space.m + 2),
                    Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: TextField(
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
                        const SizedBox(width: Space.m),
                        Expanded(
                          flex: 3,
                          child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: _authMode,
                            decoration: const InputDecoration(labelText: '鉴权头格式'),
                            items: const [
                              DropdownMenuItem(value: '', child: Text('自动 (兼容网关推荐)', overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: 'bearer', child: Text('Authorization: Bearer', overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: 'x-api-key', child: Text('x-api-key', overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (v) => setState(() => _authMode = v ?? ''),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.m + 2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
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
                    if (_fetchNote != null) ...[
                      const SizedBox(height: Space.xs + 2),
                      Text(_fetchNote!, style: TextStyle(fontSize: 12, color: ide.textDim)),
                    ],
                    if (_fetchedModels.isNotEmpty) ...[
                      const SizedBox(height: Space.s),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 88),
                        child: SingleChildScrollView(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final m in _fetchedModels)
                                ActionChip(
                                  visualDensity: VisualDensity.compact,
                                  label: Text(m, style: const TextStyle(fontSize: 11.5)),
                                  onPressed: () => setState(() => _modelCtl.text = m),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: Space.m + 2),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
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
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: Space.m + 2, vertical: Space.s + 2),
                      decoration: BoxDecoration(
                        color: ide.sideBar,
                        borderRadius: BorderRadius.circular(Radii.l),
                        border: Border.all(color: ide.border),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.public_rounded, size: 17, color: ide.textDim),
                          const SizedBox(width: Space.m),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('通过服务器的「代理出口」访问模型 API 与执行命令', style: TextStyle(fontSize: 12.5, color: ide.text)),
                                Text('当国内服务器无法直连 Anthropic / OpenAI / GitHub 时开启（复用代理出口节点）',
                                    style: TextStyle(fontSize: 11.5, color: ide.textFaint)),
                              ],
                            ),
                          ),
                          SmallSwitch(value: _useProxy, onChanged: (v) => setState(() => _useProxy = v)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.l),
              Row(
                children: [
                  if (_ai.providers.length > 1)
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: ide.error),
                      onPressed: _deleteCurrent,
                      icon: const Icon(Icons.delete_outline_rounded, size: 16),
                      label: const Text('删除此配置'),
                    ),
                  const Spacer(),
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
