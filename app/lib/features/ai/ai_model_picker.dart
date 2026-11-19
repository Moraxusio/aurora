import 'dart:async';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora/ui/aurora_ui.dart';

import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'ai_settings_dialog.dart';
import 'ai_visuals.dart';

String aiEffortLabel(String v) => v.isEmpty ? '默认' : v;

Future<String?> showAiPersonaPicker(
  BuildContext context,
  Workspace ws, {
  String? initialPersonaId,
  String title = '选择智能体人设 (Persona)',
}) {
  return showPicker<String>(
    context,
    maxWidth: 480,
    maxHeight: 560,
    builder: (_) => _PersonaPicker(
      ws: ws,
      initialPersonaId: initialPersonaId,
      title: title,
    ),
  );
}

class _PersonaPicker extends StatefulWidget {
  final Workspace ws;
  final String? initialPersonaId;
  final String title;
  const _PersonaPicker({
    required this.ws,
    this.initialPersonaId,
    required this.title,
  });

  @override
  State<_PersonaPicker> createState() => _PersonaPickerState();
}

class _PersonaPickerState extends State<_PersonaPicker> {
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    _filter.addListener(_onFilter);
  }

  void _onFilter() => setState(() {});

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  String _permLabel(String mode) => switch (mode) {
    'full_access' => '完全权限',
    'auto' => '自动执行',
    'ask' => '先询问',
    _ => '继承权限',
  };

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final ai = widget.ws.app.ready ? widget.ws.app.aiSettings : AiSettings();
    final q = _filter.text.trim().toLowerCase();
    final personas = ai.personas.where((p) {
      if (q.isEmpty) return true;
      return p.name.toLowerCase().contains(q) ||
          p.description.toLowerCase().contains(q) ||
          p.model.toLowerCase().contains(q);
    }).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: AiSectionHeading(
            icon: Icons.badge_outlined,
            title: widget.title,
            subtitle: '对话通过 Persona 使用模型、思考参数、工具与权限',
            trailing: IconBtn(
              Icons.close,
              '关闭',
              () => Navigator.pop(context),
            ),
          ),
        ),
        if (ai.personas.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, 0),
            child: TextField(
              key: const ValueKey('ai-picker-search'),
              controller: _filter,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 17),
                hintText: '搜索 Persona 名称或模型…',
              ),
            ),
          ),
        Flexible(
          child: personas.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.badge_outlined,
                        size: 36,
                        color: ide.textFaint,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        ai.personas.isEmpty
                            ? '尚未创建 Persona，请先在设置中创建。'
                            : '没有匹配的 Persona。',
                        style: TextStyle(fontSize: 12.5, color: ide.textDim),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(Space.m),
                  itemCount: personas.length,
                  itemBuilder: (_, index) {
                    final p = personas[index];
                    final selected = p.id == widget.initialPersonaId;
                    final prov = ai.providers
                        .where((x) => x.id == p.providerId)
                        .firstOrNull;
                    final meta = [
                      if (prov != null) prov.name,
                      if (p.model.isNotEmpty) p.model,
                      if (p.reasoningEffort?.isNotEmpty == true)
                        '思考:${p.reasoningEffort}',
                      _permLabel(p.permissionMode),
                    ].join(' · ');
                    return Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      color: selected
                          ? ide.accent.withValues(alpha: .10)
                          : ide.editor.withValues(alpha: .55),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          color: selected ? ide.accent : ide.border,
                        ),
                      ),
                      child: ListTile(
                        key: ValueKey('ai-persona-option-${p.id}'),
                        dense: true,
                        leading: Icon(
                          Icons.badge_outlined,
                          size: 18,
                          color: selected ? ide.accent : ide.textDim,
                        ),
                        title: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: ide.text,
                          ),
                        ),
                        subtitle: Text(
                          p.description.isNotEmpty
                              ? '${p.description} · $meta'
                              : meta,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: ide.textDim),
                        ),
                        trailing: selected
                            ? Icon(Icons.check_rounded, size: 17, color: ide.accent)
                            : null,
                        onTap: () => Navigator.pop(context, p.id),
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              TextButton.icon(
                key: const ValueKey('ai-picker-manage-personas'),
                onPressed: () {
                  Navigator.pop(context);
                  unawaited(
                    showAiSettingsDialog(
                      context,
                      app: widget.ws.app,
                      ws: widget.ws,
                      initialSection: 'personas',
                    ),
                  );
                },
                icon: const Icon(Icons.tune_rounded, size: 15),
                label: const Text('管理 / 新建 Persona…'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
