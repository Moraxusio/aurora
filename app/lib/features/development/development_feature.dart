import 'dart:convert';

import 'package:aurora/ui/aurora_ui.dart';

import '../../kernel/development/development_model.dart';
import '../../kernel/feature.dart';
import '../../kernel/workspace.dart';
import '../files/file_editor.dart';
import 'language_actions.dart';
import 'development_scope.dart';
import 'task_panel.dart';
import 'debug_panel.dart';

class DevelopmentFeature extends Feature {
  const DevelopmentFeature();
  @override
  String get id => 'development';
  @override
  String get title => '开发与问题';
  @override
  IconData get icon => Icons.code;
  @override
  String get service => 'devtools';
  @override
  List<String> get ops => const [
    'devtools.config',
    'devtools.configure',
    'lsp.start',
    'task.run',
    'dap.start',
  ];
  @override
  SideBarView sideBar(BuildContext context, Workspace ws) => SideBarView(
    title: '开发与问题',
    body: DevelopmentPanel(ws: ws),
    actions: [
      IconBtn(
        Icons.settings_outlined,
        '开发配置',
        () => editDevelopmentConfiguration(context, ws),
      ),
      IconBtn(Icons.restart_alt, '重启语言服务', ws.development.restart),
    ],
  );
  @override
  List<Command> commands(Workspace ws) => [
    Command(
      id: 'development.config',
      title: '编辑项目开发配置',
      group: '开发',
      run: () async {
        final c = AppNavigation.context;
        if (c != null) await editDevelopmentConfiguration(c, ws);
      },
    ),
    Command(
      id: 'development.restart',
      title: '重启语言服务',
      group: '开发',
      run: ws.development.restart,
    ),
    Command(
      id: 'development.task',
      title: '运行项目任务',
      group: '开发',
      run: () async {
        final c = AppNavigation.context;
        if (c != null) await runConfiguredTask(c, ws);
      },
    ),
    Command(
      id: 'development.test',
      title: '运行项目测试',
      group: '开发',
      run: () async {
        final c = AppNavigation.context;
        if (c != null) await runConfiguredTask(c, ws, group: 'test');
      },
    ),
    Command(
      id: 'development.debug',
      title: '启动调试',
      group: '调试',
      run: () async {
        final c = AppNavigation.context;
        if (c != null) await startConfiguredDebug(c, ws);
      },
    ),
    Command(
      id: 'development.breakpoint',
      title: '切换当前行断点',
      group: '调试',
      enabled: () => ws.active?.file != null,
      run: () {
        final file = ws.active?.file;
        if (file == null) return;
        final doc = ws.documents.find(file.root, file.path);
        if (doc != null) toggleCursorBreakpoint(ws, doc);
      },
    ),
    for (final action in LanguageAction.values)
      Command(
        id: 'development.${action.name}',
        title: languageActionLabels[action]!,
        group: '语言',
        enabled: () => ws.active?.file != null,
        run: () async {
          final c = AppNavigation.context, f = ws.active?.file;
          if (c == null || f == null) return;
          final doc = ws.documents.find(f.root, f.path);
          if (doc != null) await runLanguageAction(c, ws, doc, action);
        },
      ),
  ];
}

class DevelopmentPanel extends StatelessWidget {
  final Workspace ws;
  const DevelopmentPanel({super.key, required this.ws});
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        const TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: '问题'),
            Tab(text: '任务与测试'),
            Tab(text: '调试'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _ProblemsPanel(ws: ws),
              TaskPanel(ws: ws),
              DebugPanel(ws: ws),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ProblemsPanel extends StatelessWidget {
  final Workspace ws;
  const _ProblemsPanel({required this.ws});
  @override
  Widget build(BuildContext context) {
    installEditReview(ws, context);
    final model = ws.development;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final problems = model.diagnostics.toList();
        final sessions = model.sessions.values.toList();
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: SectionHeader(
                '语言服务器 · ${sessions.length}',
                actions: [
                  IconBtn(
                    Icons.description_outlined,
                    '开发工具日志',
                    () => showWorkbenchDialog<void>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('开发工具日志'),
                        content: SizedBox(
                          width: 780,
                          height: 400,
                          child: ListView.builder(
                            itemCount: model.logs.length,
                            itemBuilder: (_, i) =>
                                SelectableText(model.logs[i]),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SliverList.builder(
              itemCount: sessions.length,
              itemBuilder: (_, i) {
                final session = sessions[i];
                return TreeRow(
                  label: '${session.configuration['id']}',
                  subtitle: model.failures[session.id] ?? session.scope.path,
                  leading: Icon(
                    session.active
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 16,
                  ),
                );
              },
            ),
            if (sessions.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    model.logs.isEmpty
                        ? '在项目开发配置中添加语言服务器，再打开对应文件。'
                        : model.logs.last,
                  ),
                ),
              ),
            SliverToBoxAdapter(child: SectionHeader('问题 · ${problems.length}')),
            SliverList.builder(
              itemCount: problems.length,
              itemBuilder: (_, i) {
                final problem = problems[i];
                return TreeRow(
                  label: problem.message,
                  subtitle:
                      '${problem.key.path}:${problem.line + 1}:${problem.column + 1} · ${problem.source}',
                  leading: Icon(
                    problem.severity == 1
                        ? Icons.error_outline
                        : Icons.warning_amber,
                    size: 16,
                  ),
                  onTap: () => openFileAt(
                    ws,
                    root: problem.key.root,
                    path: problem.key.path,
                    line: problem.line + 1,
                    col: problem.column + 1,
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

Future<void> editDevelopmentConfiguration(
  BuildContext context,
  Workspace ws,
) async {
  try {
    final scope = await selectDevelopmentScope(context, ws);
    if (scope == null || !context.mounted) return;
    final updated = await showWorkbenchDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ConfigurationEditor(scope: scope),
    );
    if (updated != null) {
      await ws.development.saveConfiguration(scope, updated);
      ws.toast('项目开发配置已保存');
    }
  } on Object catch (e) {
    ws.toast('$e', error: true);
  }
}

class _ConfigurationEditor extends StatefulWidget {
  final DevelopmentScope scope;
  const _ConfigurationEditor({required this.scope});
  @override
  State<_ConfigurationEditor> createState() => _ConfigurationEditorState();
}

class _ConfigurationEditorState extends State<_ConfigurationEditor> {
  late final TextEditingController text = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(widget.scope.config),
  );
  String? error;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(12),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '项目开发配置 · ${widget.scope.path}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              '.aurora/development.json · command 使用参数数组；语言服务器和调试适配器运行在文件所在机器。',
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: text,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            ),
            if (error != null) Text(error!),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    try {
                      final parsed = jsonDecode(text.text);
                      if (parsed is! Map)
                        throw const FormatException('配置必须是 JSON 对象');
                      Navigator.pop(context, parsed.cast<String, dynamic>());
                    } on Object catch (e) {
                      setState(() => error = '$e');
                    }
                  },
                  child: const Text('保存配置'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
