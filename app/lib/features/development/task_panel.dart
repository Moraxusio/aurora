import 'package:aurora/ui/aurora_ui.dart';

import '../../kernel/development/task_model.dart';
import '../../kernel/editor_tab.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import '../files/file_editor.dart';
import 'development_scope.dart';

const taskStatusLabels = {
  'running': '运行中',
  'cancelling': '正在取消',
  'cancelled': '已取消',
  'passed': '成功',
  'failed': '失败',
  'interrupted': '已中断',
};
const testStatusLabels = {
  'running': '运行中',
  'pass': '通过',
  'fail': '失败',
  'skip': '跳过',
  'interrupted': '已中断',
};

Future<void> runConfiguredTask(
  BuildContext context,
  Workspace ws, {
  String? group,
  void Function(TaskRun)? onStarted,
  VoidCallback? beforeStart,
}) async {
  try {
    final scope = await selectDevelopmentScope(context, ws);
    if (scope == null || !context.mounted) return;
    final tasks = scope
        .entries('tasks')
        .where((t) => group == null || t['group'] == group)
        .toList();
    final selected = await showWorkbenchDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(group == 'test' ? '运行测试' : '运行任务'),
        content: SizedBox(
          width: 600,
          height: 320,
          child: tasks.isEmpty
              ? const Center(child: Text('请在开发配置 tasks 中添加任务。'))
              : ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (_, i) => TreeRow(
                    label: '${tasks[i]['label'] ?? tasks[i]['id']}',
                    subtitle: (tasks[i]['command'] as List? ?? []).join(' '),
                    onTap: () => Navigator.pop(c, '${tasks[i]['id']}'),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    beforeStart?.call();
    final run = await ws.tasks.start(scope, selected);
    onStarted?.call(run);
    openTaskResult(ws, run);
  } on Object catch (e) {
    ws.toast('$e', error: true);
  }
}

void openTaskResult(Workspace ws, TaskRun run) => ws.openTab(
  EditorTab(
    id: 'task:${run.id}',
    title: run.label,
    icon: Icons.fact_check_outlined,
    builder: (_) => TaskResultView(ws: ws, run: run),
  ),
);

class TaskPanel extends StatelessWidget {
  final Workspace ws;
  const TaskPanel({super.key, required this.ws});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ws.tasks,
    builder: (context, _) {
      final model = ws.tasks;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: model.supported
                    ? () => runConfiguredTask(context, ws)
                    : null,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('运行任务'),
              ),
              TextButton.icon(
                onPressed: model.supported
                    ? () => runConfiguredTask(context, ws, group: 'test')
                    : null,
                icon: const Icon(Icons.science_outlined, size: 16),
                label: const Text('运行测试'),
              ),
            ],
          ),
          if (model.storageError != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('结果保存：${model.storageError}'),
            ),
          if (model.history.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('任务完成后可在这里查看日志、退出码与测试结果。'),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: model.history.length,
              itemBuilder: (_, i) {
                final run = model.history[i];
                return TreeRow(
                  label: run.label,
                  leading: Icon(
                    run.running
                        ? Icons.pending_outlined
                        : run.status == 'passed'
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 16,
                  ),
                  subtitle:
                      '${taskStatusLabels[run.status] ?? run.status} · ${run.tests.length} 测试 · ${run.problems.length} 问题',
                  trailing: run.running
                      ? IconBtn(Icons.stop, '取消任务', () => model.cancel(run.id))
                      : null,
                  onTap: () => openTaskResult(ws, run),
                );
              },
            ),
          ),
        ],
      );
    },
  );
}

class TaskResultView extends StatelessWidget {
  final Workspace ws;
  final TaskRun run;
  const TaskResultView({super.key, required this.ws, required this.run});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ws.tasks,
    builder: (context, _) {
      final tests = run.tests.values.toList();
      final lines = run.output.split('\n');
      return DefaultTabController(
        length: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${run.label} · ${taskStatusLabels[run.status] ?? run.status}',
                  ),
                  if (run.exitCode != null) Text('退出码 ${run.exitCode}'),
                  Text(run.started.toLocal().toString()),
                  if (run.running)
                    TextButton.icon(
                      onPressed: () => ws.tasks.cancel(run.id),
                      icon: const Icon(Icons.stop, size: 16),
                      label: const Text('取消'),
                    ),
                  TextButton.icon(
                    onPressed: run.running
                        ? null
                        : () async {
                            try {
                              final scope = await ws.development.configuration(
                                run.root,
                                run.path,
                                refresh: true,
                              );
                              openTaskResult(
                                ws,
                                await ws.tasks.start(scope, run.task),
                              );
                            } on Object catch (e) {
                              ws.toast('$e', error: true);
                            }
                          },
                    icon: const Icon(Icons.replay, size: 16),
                    label: const Text('重新运行'),
                  ),
                ],
              ),
            ),
            if (run.error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(run.error!),
              ),
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                const Tab(text: '输出'),
                Tab(text: '问题 ${run.problems.length}'),
                Tab(text: '测试 ${tests.length}'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (run.outputTruncated)
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text('显示最近 128 Ki 字符输出'),
                        ),
                      Expanded(
                        child: SelectionArea(
                          child: ListView.builder(
                            itemCount: lines.length,
                            padding: const EdgeInsets.all(12),
                            itemBuilder: (_, i) => Text(
                              lines[i],
                              style: const TextStyle(
                                fontFamily: Ide.mono,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  ListView.builder(
                    itemCount: run.problems.length,
                    itemBuilder: (_, i) {
                      final p = run.problems[i];
                      return TreeRow(
                        label: p.message,
                        subtitle: '${p.path}:${p.line}:${p.column}',
                        leading: Icon(
                          p.severity == 'warning'
                              ? Icons.warning_amber
                              : Icons.error_outline,
                          size: 16,
                        ),
                        onTap: () => openFileAt(
                          ws,
                          root: p.root,
                          path: p.path,
                          line: p.line,
                          col: p.column,
                        ),
                      );
                    },
                  ),
                  ListView.builder(
                    itemCount: tests.length,
                    itemBuilder: (_, i) {
                      final test = tests[i];
                      return ExpansionTile(
                        key: ValueKey(test.id),
                        leading: Icon(
                          test.status == 'pass'
                              ? Icons.check_circle_outline
                              : test.status == 'fail'
                              ? Icons.error_outline
                              : Icons.pending_outlined,
                          size: 16,
                        ),
                        title: Text(test.name),
                        subtitle: Text(
                          '${testStatusLabels[test.status] ?? test.status} · ${test.elapsed.toStringAsFixed(3)}s',
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: SelectableText(
                              test.output.isEmpty ? '无附加输出' : test.output,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
