// Quick model and thinking-strength picker for the AI composer (D-104).
//
// Everything a person changes while chatting lives here, one click from the
// input box: which provider, which model (typed, picked from the list the
// gateway reported, or fetched on the spot), and how hard it thinks. Keys and
// base URLs stay in the full settings dialog; this only flips the choices.
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'ai_settings_dialog.dart';
import 'ai_auth.dart';
import 'ai_visuals.dart';

/// The thinking-strength choices. The value is what `reasoning_effort` carries
/// (OpenAI) and what the Anthropic budget is derived from; '' is the model's own default.
const aiEfforts = <(String, String, String)>[
  ('', '默认', '由模型或网关决定'),
  ('low', '轻度', '反应快，适合简单任务'),
  ('medium', '中度', '速度与质量均衡'),
  ('high', '深度', '复杂问题，较慢、更贵'),
];

String aiEffortLabel(String v) =>
    aiEfforts.firstWhere((e) => e.$1 == v, orElse: () => aiEfforts.first).$2;

class AiModelSelection {
  final String providerId, model;
  final String? reasoning;
  const AiModelSelection(this.providerId, this.model, this.reasoning);
}

Future<AiModelSelection?> showAiModelPicker(
  BuildContext context,
  Workspace ws, {
  String? initialProviderId,
  String? initialModel,
  String? initialReasoning,
}) {
  return showPicker<AiModelSelection>(
    context,
    maxWidth: 480,
    maxHeight: 600,
    builder: (_) => _ModelPicker(
      ws: ws,
      initialProviderId: initialProviderId,
      initialModel: initialModel,
      initialReasoning: initialReasoning,
    ),
  );
}

class _ModelPicker extends StatefulWidget {
  final Workspace ws;
  final String? initialProviderId, initialModel;
  final String? initialReasoning;
  const _ModelPicker({
    required this.ws,
    this.initialProviderId,
    this.initialModel,
    this.initialReasoning,
  });

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  final _filter = TextEditingController();
  bool _fetching = false;
  String? _note;
  String? _reasoningOverride;
  String? _providerId;
  int _fetchGeneration = 0;

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    _reasoningOverride = widget.initialReasoning;
    _providerId =
        widget.initialProviderId ?? ws.app.aiSettings.activeProvider?.id;
    _filter.addListener(_filterChanged);
  }

  void _filterChanged() => setState(() {});

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _fetch(AiProvider prov) async {
    final link = ws.link;
    if (link == null) {
      setState(() => _note = '服务器未连接');
      return;
    }
    final generation = ++_fetchGeneration;
    bool active() =>
        mounted && generation == _fetchGeneration && _providerId == prov.id;
    setState(() {
      _fetching = true;
      _note = null;
    });
    try {
      final prepared = await prepareAiProvider(ws.app, link, prov);
      final res = await link.call('ai.models', {
        'provider': prepared.toWireJson(),
      }) as Map;
      final ids = <String>[
        for (final m in (res['models'] as List? ?? const []))
          if (m is Map && (m['id'] as String? ?? '').isNotEmpty)
            m['id'] as String,
      ];
      final imageSupport = <String, bool>{};
      for (final m in (res['models'] as List? ?? const [])) {
        if (m is Map &&
            m['id'] is String &&
            m['image_support_known'] == true &&
            m['supports_image'] is bool) {
          imageSupport[m['id'] as String] = m['supports_image'] as bool;
        }
      }
      if (!active()) return;
      await ws.app.update((profile) {
        final ai = profile.ai;
        for (final p in ai.providers) {
          if (p.id == prov.id &&
              p.authMode == prov.authMode &&
              p.baseUrl == prov.baseUrl &&
              p.apiKey == prov.apiKey &&
              p.oauth?.access == prepared.oauth?.access) {
            p.models = {...p.models, ...ids}.toList()..sort();
            p.modelImageSupport.addAll(imageSupport);
            for (final m in (res['models'] as List? ?? const [])) {
              if (m is Map &&
                  m['id'] is String &&
                  m['context_window'] is num &&
                  (m['context_window'] as num) > 0)
                p.modelContextWindows[m['id'] as String] =
                    (m['context_window'] as num).toInt();
            }
          }
        }
      });
      if (active())
        setState(
          () => _note = prov.isSubscription
              ? '内置订阅模型建议，非账号可用性校验；可手动输入模型 ID'
              : ids.isEmpty
              ? '网关没有列出模型，可在上面手动输入模型 ID'
              : '已获取 ${ids.length} 个模型',
        );
    } on OpError catch (e) {
      if (active()) setState(() => _note = e.message);
    } on Object catch (e) {
      if (active())
        setState(() => _note = e is StateError ? e.message : '拉取模型失败，请检查连接');
    } finally {
      if (active()) setState(() => _fetching = false);
    }
  }

  void _pickModel(AiProvider prov, String model) {
    Navigator.pop(
      context,
      AiModelSelection(prov.id, model, _reasoningOverride),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return ListenableBuilder(
      listenable: ws.app,
      builder: (context, _) {
        final ai = ws.app.ready ? ws.app.profile.ai : AiSettings();
        final prov =
            ai.providers.where((p) => p.id == _providerId).firstOrNull ??
            ai.activeProvider;
        if (prov == null) {
          return Padding(
            padding: const EdgeInsets.all(Space.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.key_rounded, size: 26, color: ide.textDim),
                const SizedBox(height: Space.m),
                Text(
                  '还没有配置模型提供商',
                  style: TextStyle(fontSize: 14, color: ide.text),
                ),
                const SizedBox(height: Space.l),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    showAiSettingsDialog(context, app: ws.app, ws: ws);
                  },
                  child: const Text('添加提供商'),
                ),
              ],
            ),
          );
        }
        final q = _filter.text.trim().toLowerCase();
        final selectedModel = prov.id == widget.initialProviderId
            ? widget.initialModel ?? prov.model
            : prov.model;
        final models = <String>{
          if (selectedModel.isNotEmpty) selectedModel,
          if (prov.model.isNotEmpty) prov.model,
          ...prov.models,
        }.where((m) => q.isEmpty || m.toLowerCase().contains(q)).toList();
        final typed = _filter.text.trim();
        final canUseTyped =
            typed.isNotEmpty &&
            !prov.models.contains(typed) &&
            typed != prov.model;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: AiSectionHeading(
                icon: Icons.memory_outlined,
                title: '本次对话设置',
                subtitle: '仅当前会话 · 应用于后续发送的消息',
                trailing: IconBtn(
                  Icons.close,
                  '关闭',
                  () => Navigator.pop(context),
                ),
              ),
            ),
            if (ai.providers.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.l,
                  Space.l,
                  Space.l,
                  0,
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in ai.providers)
                      ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          p.name,
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: p.id == prov.id,
                        onSelected: (_) => setState(() {
                          _providerId = p.id;
                          _note = null;
                          _fetching = false;
                          _fetchGeneration++;
                        }),
                      ),
                  ],
                ),
              ),
            PickerField(
              controller: _filter,
              hint: '搜索模型，或直接输入模型 ID',
              icon: Icons.memory_rounded,
              onSubmitted: (v) {
                final t = v.trim();
                if (t.isEmpty) return;
                _pickModel(
                  prov,
                  models.contains(t) || models.length != 1 ? t : models.first,
                );
              },
            ),
            Divider(height: 1, color: ide.border),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: Space.s),
                children: [
                  if (canUseTyped)
                    PickerRow(
                      selected: false,
                      onTap: () => _pickModel(prov, typed),
                      child: Row(
                        children: [
                          Icon(
                            Icons.keyboard_return_rounded,
                            size: 15,
                            color: ide.accent,
                          ),
                          const SizedBox(width: Space.m),
                          Expanded(
                            child: Text(
                              '使用 "$typed"',
                              style: TextStyle(fontSize: 13, color: ide.accent),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (final m in models)
                    PickerRow(
                      selected: m == selectedModel,
                      onTap: () => _pickModel(prov, m),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 18,
                            child: m == selectedModel
                                ? Icon(
                                    Icons.check_rounded,
                                    size: 15,
                                    color: ide.accent,
                                  )
                                : null,
                          ),
                          const SizedBox(width: Space.s),
                          Expanded(
                            child: Text(
                              m,
                              style: TextStyle(fontSize: 13, color: ide.text),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (prov.imageSupport(m) == true)
                            const Tooltip(
                              message: '此模型已声明支持图片输入',
                              child: Icon(Icons.image_outlined, size: 14),
                            ),
                          if (prov.imageSupport(m) == false)
                            Tooltip(
                              message: '此模型已声明不支持图片输入',
                              child: Icon(
                                Icons.image_not_supported_outlined,
                                size: 14,
                                color: ide.textFaint,
                              ),
                            ),
                          if (prov.effectiveContextWindow(m) > 0)
                            Tooltip(
                              message: '上下文输入预算；目录或手动配置值，不代表订阅权限',
                              child: Text(
                                '${(prov.effectiveContextWindow(m) / 1000).toStringAsFixed(0)}k',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: ide.textFaint,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (models.isEmpty && !canUseTyped)
                    Padding(
                      padding: const EdgeInsets.all(Space.xl),
                      child: Text(
                        prov.models.isEmpty
                            ? '还没有模型列表。点下面的“拉取模型”，或直接输入模型 ID 回车。'
                            : '没有匹配的模型',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: ide.textDim,
                          height: 1.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: ide.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.l,
                Space.m + 2,
                Space.l,
                Space.s,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.psychology_outlined,
                        size: 15,
                        color: ide.textDim,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '本次思考强度',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: ide.text,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '不修改配置预设',
                        style: TextStyle(fontSize: 11, color: ide.textFaint),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.s),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      padding: WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 6),
                      ),
                    ),
                    segments: [
                      for (final e in aiEfforts)
                        ButtonSegment(
                          value: e.$1,
                          label: Text(
                            e.$2,
                            style: const TextStyle(fontSize: 12),
                          ),
                          tooltip: e.$3,
                        ),
                    ],
                    selected: {_reasoningOverride ?? prov.reasoningEffort},
                    onSelectionChanged: (v) {
                      setState(() {
                        _reasoningOverride = v.first;
                      });
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.s, Space.s),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _note ??
                          '图片输入：${prov.imageSupport(prov.model) == true
                              ? '支持'
                              : prov.imageSupport(prov.model) == false
                              ? '不支持'
                              : '能力未知，可尝试发送后查看结果'}',
                      style: TextStyle(fontSize: 11.5, color: ide.textDim),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _fetching ? null : () => _fetch(prov),
                    icon: _fetching
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          )
                        : const Icon(Icons.refresh_rounded, size: 15),
                    label: const Text('拉取模型'),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      showAiSettingsDialog(context, app: ws.app, ws: ws);
                    },
                    child: const Text('管理连接…'),
                  ),
                  IconButton(
                    tooltip: '应用到当前会话',
                    onPressed: selectedModel.isEmpty
                        ? null
                        : () => _pickModel(prov, selectedModel),
                    icon: Icon(Icons.check, color: ide.accent, size: 19),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
