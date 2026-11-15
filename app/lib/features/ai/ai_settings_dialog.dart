// Connection drafts are independent from the default used by new sessions.
// OAuth credentials are the only immediate, sealed action in this editor.
import 'dart:convert';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../state/app_state.dart';
import '../../theme/ide_theme.dart';
import 'ai_auth.dart';
import 'ai_model_discovery.dart';
import 'ai_oauth_client.dart';
import 'ai_capability_editor.dart';
import 'ai_reasoning_field.dart';

part 'ai_settings_pages.dart';

const _presets = <(String, String, String, String)>[
  (
    'ChatGPT 订阅',
    'openai-responses',
    'https://chatgpt.com/backend-api/codex',
    'gpt-6.1-sol',
  ),
  ('OpenAI API', 'openai-chat', 'https://api.openai.com/v1', 'gpt-5.2'),
  (
    'Anthropic',
    'anthropic-messages',
    'https://api.anthropic.com/v1',
    'claude-sonnet-4-5',
  ),
  (
    'OpenAI Responses',
    'openai-responses',
    'https://api.openai.com/v1',
    'gpt-5.2-codex',
  ),
  ('OpenRouter', 'openai-chat', 'https://openrouter.ai/api/v1', ''),
  ('DeepSeek', 'openai-chat', 'https://api.deepseek.com/v1', 'deepseek-chat'),
  ('OpenCode Zen', 'anthropic-messages', 'https://opencode.ai/zen/v1', ''),
  ('自定义兼容网关', 'openai-chat', '', ''),
];

final _settingsDialogs = Expando<Future<void>>();

Future<void> showAiSettingsDialog(
  BuildContext context, {
  required AppState app,
  Workspace? ws,
  String initialSection = 'connection',
  String? providerId,
  String? model,
  AiOAuthClient Function()? localAuthFactory,
}) {
  final pending = _settingsDialogs[app];
  if (pending != null) return pending;
  final dialog = showWorkbenchDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AiSettingsDialog(
      app: app,
      ws: ws,
      localAuthFactory: localAuthFactory,
      initialSection: initialSection,
      providerId: providerId,
      model: model,
    ),
  ).whenComplete(() => _settingsDialogs[app] = null);
  _settingsDialogs[app] = dialog;
  return dialog;
}

class AiSettingsDialog extends StatefulWidget {
  final AppState app;
  final Workspace? ws;
  final String initialSection;
  final String? providerId, model;
  final AiOAuthClient Function()? localAuthFactory;
  const AiSettingsDialog({
    super.key,
    required this.app,
    this.ws,
    this.initialSection = 'connection',
    this.providerId,
    this.model,
    this.localAuthFactory,
  });
  @override
  State<AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<AiSettingsDialog> {
  late AiSettings _ai;
  late Map<String, String> _originalKeys;
  late String _baseline;
  String? _editingId;
  String? _inspectedModel;
  String _section = 'connection';
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _context = TextEditingController();
  final _search = TextEditingController();
  final _resource = TextEditingController(text: '*');
  bool _loadingFields = false;
  bool _obscure = true;
  bool _saving = false;
  bool _closing = false;
  bool _confirmingClose = false;
  bool _fetching = false;
  bool _checking = false;
  bool _clientNetwork = false;
  int _request = 0;
  String? _note;
  String? _error;
  String _ruleEffect = 'ask', _ruleAction = 'shell', _ruleScope = 'global';
  int? _editingRule;
  late String _ruleBaseline;

  AiProvider? get _current =>
      _ai.providers.where((p) => p.id == _editingId).firstOrNull;
  Iterable<TextEditingController> get _fields => [
    _name,
    _url,
    _key,
    _model,
    _context,
  ];

  @override
  void initState() {
    super.initState();
    _ai = widget.app.ready
        ? AiSettings.fromJson(widget.app.profile.ai.toJson())
        : AiSettings();
    _originalKeys = {for (final p in _ai.providers) p.id: p.apiKey};
    _clientNetwork = widget.ws?.link == null;
    _load(
      _ai.providers.where((p) => p.id == widget.providerId).firstOrNull ??
          _ai.activeProvider,
    );
    _section = _sections.any((s) => s.$1 == widget.initialSection)
        ? widget.initialSection
        : 'connection';
    _inspectedModel = widget.model;
    _baseline = _snapshot();
    _ruleBaseline = _ruleSnapshot();
    for (final field in _fields) {
      field.addListener(_fieldChanged);
    }
    _search.addListener(_searchChanged);
    _resource.addListener(_searchChanged);
  }

  @override
  void dispose() {
    for (final field in [..._fields, _search, _resource]) {
      field.dispose();
    }
    super.dispose();
  }

  String _snapshot() {
    final json = _ai.toJson();
    for (final p in (json['providers'] as List? ?? [])) {
      (p as Map).remove('oauth');
    }
    return jsonEncode(json);
  }

  String _ruleSnapshot() =>
      jsonEncode([_ruleAction, _ruleEffect, _ruleScope, _resource.text.trim()]);

  bool get _ruleDirty => _ruleSnapshot() != _ruleBaseline;
  bool get _dirty => _snapshot() != _baseline || _ruleDirty;

  void _resetRule() {
    _editingRule = null;
    _ruleAction = 'shell';
    _ruleEffect = 'ask';
    _ruleScope = 'global';
    _resource.text = '*';
    _ruleBaseline = _ruleSnapshot();
  }

  void _invalidate() {
    _request++;
    _fetching = _checking = false;
    _note = _error = null;
  }

  void _fieldChanged() {
    if (_loadingFields) return;
    setState(() {
      _flush();
      _invalidate();
    });
  }

  void _searchChanged() => setState(() {});
  void _change(VoidCallback action) => setState(action);

  void _flush() {
    final p = _current;
    if (p == null) return;
    p.name = _name.text.trim();
    p.baseUrl = _url.text.trim();
    p.apiKey = _key.text.trim();
    p.model = _model.text.trim();
    p.contextWindow = int.tryParse(_context.text) ?? 0;
  }

  void _load(AiProvider? p) {
    _loadingFields = true;
    _editingId = p?.id;
    _inspectedModel = null;
    _name.text = p?.name ?? '';
    _url.text = p?.baseUrl ?? '';
    _key.text = p?.apiKey ?? '';
    _model.text = p?.model ?? '';
    _context.text = (p?.contextWindow ?? 0) > 0 ? '${p!.contextWindow}' : '';
    _search.clear();
    _loadingFields = false;
    _invalidate();
  }

  void _switchProvider(String? id) {
    setState(() => _load(_ai.providers.where((p) => p.id == id).firstOrNull));
  }

  void _add(int index) {
    final preset = _presets[index];
    var name = preset.$1;
    for (var i = 2; _ai.providers.any((p) => p.name == name); i++) {
      name = '${preset.$1} $i';
    }
    final p = AiProvider.create(
      name: name,
      protocol: preset.$2,
      baseUrl: preset.$3,
      model: preset.$4,
    );
    if (index == 0) p.authMode = 'chatgpt-device';
    setState(() {
      _ai.providers.add(p);
      // The first connection becomes the default; adding others only opens them.
      _ai.selectedProviderId ??= p.id;
      _section = 'connection';
      _load(p);
    });
  }

  final _beforeSubscription = <String, (String, String, String)>{};
  void _authChanged(String? value) {
    final p = _current!;
    final next = value ?? '';
    if (next == p.authMode) return;
    setState(() {
      if (next == 'chatgpt-device') {
        _beforeSubscription[p.id] = (p.protocol, p.baseUrl, p.model);
        p.protocol = 'openai-responses';
        p.baseUrl = 'https://chatgpt.com/backend-api/codex';
        p.model = 'gpt-6.1-sol';
      } else if (p.isSubscription) {
        final old = _beforeSubscription[p.id];
        p.protocol = old?.$1 ?? 'openai-chat';
        p.baseUrl = old?.$2 ?? '';
        p.model = old?.$3 ?? '';
      }
      p.authMode = next;
      _load(p);
    });
  }

  Future<void> _delete() async {
    final p = _current;
    if (p == null) return;
    final ok = await confirmDialog(
      context,
      title: '删除“${p.name}”？',
      body: '保存设置后删除这条本机连接配置。已有对话记录保留。',
      ok: '删除连接',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      _ai.providers.remove(p);
      if (_ai.selectedProviderId == p.id) {
        _ai.selectedProviderId = _ai.providers.firstOrNull?.id;
      }
      _load(_ai.activeProvider);
    });
  }

  Future<void> _discover({bool checkOnly = false}) async {
    final selected = _current;
    if (selected == null || _fetching || _checking) return;
    final p = AiProvider.fromJson(selected.toJson());
    final link = widget.ws?.link;
    if (_clientNetwork && p.proxyMode == 'agent') {
      setState(() => _error = '此连接使用 agent 代理，请在“连接 → 网络出口”选择“当前 agent”拉取目录。');
      return;
    }
    if (!_clientNetwork && link == null) {
      setState(() => _error = '当前 agent 未连接；可在“连接 → 网络出口”选择本机网络。');
      return;
    }
    final request = ++_request;
    setState(() {
      _checking = checkOnly;
      _fetching = !checkOnly;
      _note = _error = null;
    });
    bool active() => mounted && request == _request && _current?.id == p.id;
    try {
      final List<dynamic> models;
      if (_clientNetwork) {
        models = await discoverAiModels(p);
      } else {
        final prepared = await prepareAiProvider(widget.app, link!, p);
        final result = await link.call('ai.models', {
          'provider': prepared.toWireJson(),
        }) as Map;
        models = result['models'] as List? ?? [];
      }
      if (!active()) return;
      setState(() {
        if (!checkOnly) {
          final ids = <String>{...selected.models};
          for (final m in models) {
            if (m is! Map || m['id'] is! String || (m['id'] as String).isEmpty)
              continue;
            final id = m['id'] as String;
            ids.add(id);
            if (m['image_support_known'] == true &&
                m['supports_image'] is bool) {
              selected.modelImageSupport[id] = m['supports_image'] as bool;
            }
            if (m['context_window'] is num &&
                (m['context_window'] as num) > 0) {
              selected.modelContextWindows[id] = (m['context_window'] as num)
                  .toInt();
            }
          }
          selected.models = ids.toList()..sort();
        }
        _note = p.isSubscription
            ? '内置订阅模型建议 · 未验证账号可用性。实际权限以模型调用结果为准。'
            : checkOnly
            ? '目录接口可达 · 返回 ${models.length} 个模型；尚未进行对话调用。'
            : models.isEmpty
            ? '接口返回成功，但没有模型目录。可以手动添加模型 ID。'
            : '已获取 ${models.length} 个模型';
      });
    } on Object catch (e) {
      if (active()) setState(() => _error = _message(e, '目录请求失败，请检查连接和网络出口。'));
    } finally {
      if (active()) setState(() => _fetching = _checking = false);
    }
  }

  String _message(Object e, String fallback) => e is OpError
      ? e.message
      : e is StateError
      ? e.message
      : fallback;

  void _addModel() {
    final p = _current!;
    final id = _model.text.trim();
    setState(() {
      if (id.isEmpty) {
        _error = '请先输入模型 ID。';
        return;
      }
      p.models = {...p.models, id}.toList()..sort();
      _error = null;
      _note = '已添加 $id，保存后可在会话中选择。';
    });
  }

  void _removeModel(String id) {
    setState(() {
      final p = _current!;
      p.models.remove(id);
      p.modelImageSupport.remove(id);
      p.modelContextWindows.remove(id);
      p.modelOptions.remove(id);
      if (_inspectedModel == id) _inspectedModel = null;
      if (p.model == id) _model.clear();
    });
  }

  Future<void> _login() async {
    final p = _current!;
    if (!widget.app.ready) {
      setState(() => _error = '请先解锁本机加密配置。');
      return;
    }
    final live = widget.app.profile.ai.providers
        .where((x) => x.id == p.id)
        .firstOrNull;
    final previousRefresh = live?.oauth?.refresh;
    final previousMode = live?.authMode;
    final credential = await showAiDeviceLogin(
      context,
      widget.ws?.link,
      useProxy: p.usesProxy,
      proxyMode: p.proxyMode,
      initialTransport: p.proxyMode == 'agent' ? 'server' : 'client',
      localFactory: widget.localAuthFactory,
    );
    if (!mounted ||
        credential == null ||
        _current?.id != p.id ||
        !p.isSubscription)
      return;
    try {
      await widget.app.update((profile) {
        var target = profile.ai.providers
            .where((x) => x.id == p.id)
            .firstOrNull;
        if (target == null) {
          target = AiProvider.fromJson(p.toJson());
          profile.ai.providers.add(target);
        } else if (target.oauth?.refresh != previousRefresh ||
            target.authMode != previousMode) {
          throw StateError('登录配置已在别处变更，请重新打开设置。');
        }
        target.oauth = credential;
        target.authMode = 'chatgpt-device';
        target.protocol = 'openai-responses';
        target.baseUrl = 'https://chatgpt.com/backend-api/codex';
        // Do not commit unrelated name/model/default drafts when signing in.
      });
      if (mounted)
        setState(() {
          p.oauth = credential;
          _note = '登录凭据已加密保存；其他设置仍需点击保存。';
        });
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e, '登录凭据保存失败，请重试。'));
    }
  }

  Future<void> _logout() async {
    final p = _current!;
    try {
      await widget.app.update((profile) {
        for (final live in profile.ai.providers.where((x) => x.id == p.id)) {
          live.oauth = null;
        }
      });
      if (mounted)
        setState(() {
          p.oauth = null;
          _note = '已退出订阅登录。';
        });
    } on Object {
      if (mounted) setState(() => _error = '退出登录保存失败，请重试。');
    }
  }

  bool _saveRule() {
    if (_resource.text.trim().isEmpty) {
      setState(() => _error = '请输入权限资源模式。');
      return false;
    }
    final ws = widget.ws;
    if (_ruleScope == 'project' && ws?.project == null) {
      setState(() => _error = '请先打开项目工作区，或改为全局规则。');
      return false;
    }
    final rule = AiPermissionRule(
      action: _ruleAction,
      resource: _resource.text.trim(),
      effect: _ruleEffect,
      scope: _ruleScope,
      serverId: _ruleScope == 'project' ? ws!.serverId : '',
      projectId: _ruleScope == 'project' ? ws!.project!.id : '',
    );
    setState(() {
      if (_editingRule case final index?) {
        _ai.permissionRules[index] = rule;
      } else {
        _ai.permissionRules.add(rule);
      }
      _resetRule();
      _error = null;
    });
    return true;
  }

  void _editRule(int index) {
    if (_ruleDirty && !_saveRule()) return;
    final rule = _ai.permissionRules[index];
    setState(() {
      _editingRule = index;
      _ruleAction = rule.action;
      _ruleEffect = rule.effect;
      _ruleScope = rule.scope;
      _resource.text = rule.resource;
      _ruleBaseline = _ruleSnapshot();
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_ruleDirty && !_saveRule()) {
      setState(() => _section = 'execution');
      return;
    }
    for (final p in _ai.providers) {
      String? error;
      if (p.reasoningEffort.length > 64 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(p.reasoningEffort)) {
        setState(() {
          _load(p);
          _section = 'models';
          _error = '连接思考预设最多 64 字符，不能包含控制字符。';
        });
        return;
      }
      for (final entry in p.modelOptions.entries) {
        final options = entry.value;
        final efforts = [
          options.reasoningEffort ?? '',
          ...options.reasoningEfforts.keys,
          ...options.reasoningEfforts.values,
        ];
        if (efforts.any(
          (v) => v.length > 64 || RegExp(r'[\x00-\x1f]').hasMatch(v),
        )) {
          error = '${entry.key}：思考档位与发送值最多 64 字符，不能包含控制字符。';
        } else if (options.reasoningMode.startsWith('anthropic-') &&
            p.protocol != 'anthropic-messages') {
          error = '${entry.key}：Anthropic 思考格式需要 Messages 协议。';
        } else if (options.reasoningMode == 'anthropic-budget' &&
            (options.thinkingBudget < 1024 ||
                options.thinkingBudget > 1000000)) {
          error = '${entry.key}：思考预算应为 1024–1000000 Token。';
        }
        if (error != null) {
          setState(() {
            _load(p);
            _inspectedModel = entry.key;
            _section = 'models';
            _error = error;
          });
          return;
        }
      }
      final uri = Uri.tryParse(p.baseUrl);
      if (p.name.trim().isEmpty) {
        error = '请为连接填写名称。';
      } else if (!p.isSubscription &&
          (uri == null ||
              !uri.hasAuthority ||
              uri.userInfo.isNotEmpty ||
              !['http', 'https'].contains(uri.scheme))) {
        error = '请输入有效的 HTTP / HTTPS Base URL。';
      } else if (!p.isSubscription &&
          uri?.host == 'chatgpt.com' &&
          (uri?.path.startsWith('/backend-api/codex') ?? false)) {
        error = 'ChatGPT 订阅地址需使用设备码登录方式。';
      }
      if (error != null) {
        setState(() {
          _load(p);
          _section = 'connection';
          _error = error;
        });
        return;
      }
    }
    final defaultProvider = _ai.activeProvider;
    if (defaultProvider != null && defaultProvider.model.isEmpty) {
      setState(() {
        _load(defaultProvider);
        _section = 'models';
        _error = '请为默认连接选择一个模型，或在对话默认值中更换连接。';
      });
      return;
    }
    if (!widget.app.ready) {
      setState(() => _error = '本机加密配置未就绪，无法保存。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.app.update((profile) {
        final draft = AiSettings.fromJson(_ai.toJson());
        for (final p in draft.providers) {
          final live = profile.ai.providers
              .where((x) => x.id == p.id)
              .firstOrNull;
          if (live == null) continue;
          p.oauth = live.oauth;
          if (_originalKeys.containsKey(p.id) &&
              live.apiKey != _originalKeys[p.id]) {
            if (p.apiKey != _originalKeys[p.id]) {
              throw StateError('密钥已在别处更新，请重新打开设置以免覆盖。');
            }
            p.apiKey = live.apiKey;
          }
        }
        draft.chatFontSize = profile.ai.chatFontSize;
        profile.ai = draft;
      });
      if (!mounted) return;
      setState(() => _closing = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e, '保存失败，修改已保留，请重试。'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _close() async {
    if (_saving || _closing || _confirmingClose) return;
    if (_dirty) {
      _confirmingClose = true;
      final discard = await confirmDialog(
        context,
        title: '放弃未保存的修改？',
        body: '连接、模型、权限和默认值尚未保存。已完成的登录或退出操作即时生效。',
        ok: '放弃修改',
        danger: true,
      );
      _confirmingClose = false;
      if (!discard || !mounted) return;
    }
    if (!mounted) return;
    setState(() => _closing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) => _buildPages(context);
}
