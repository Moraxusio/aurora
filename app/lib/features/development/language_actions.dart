import 'dart:async';

import 'package:aurora/ui/aurora_ui.dart';
import 'package:re_editor/re_editor.dart';

import '../../kernel/development/text_edits.dart';
import '../../kernel/document_model.dart';
import '../../kernel/file_text.dart';
import '../../kernel/snippets.dart';
import '../../kernel/workspace.dart';
import '../files/file_editor.dart';
import '../git/diff_view.dart';
import '../git/text_diff.dart';

enum LanguageAction {
  completion,
  hover,
  definition,
  references,
  format,
  rename,
  codeAction,
}

const languageActionLabels = {
  LanguageAction.completion: '语义补全',
  LanguageAction.hover: '查看类型与文档',
  LanguageAction.definition: '转到定义',
  LanguageAction.references: '查找引用',
  LanguageAction.format: '格式化文档',
  LanguageAction.rename: '重命名符号',
  LanguageAction.codeAction: '代码操作',
};

void installEditReview(Workspace ws, BuildContext context) {
  ws.development.reviewEdit = (plan) async {
    final c = AppNavigation.context ?? context;
    if (!c.mounted) return false;
    final accepted = await reviewDocumentEdits(
      c,
      plan,
      allowSave: ws.link?.server.caps.contains('fs.commit') == true,
    );
    if (accepted) {
      for (final edit in plan.edits) {
        openFileAt(
          ws,
          root: edit.document.key.root,
          path: edit.document.key.path,
        );
      }
    }
    return accepted;
  };
}

class LanguageToolbar extends StatelessWidget {
  final Workspace ws;
  final DocumentModel document;
  const LanguageToolbar({super.key, required this.ws, required this.document});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ws.development,
    builder: (context, _) {
      final model = ws.development;
      if (!model.supported) return const SizedBox.shrink();
      final session = model.sessionFor(document);
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                session?.configuration['id'] as String? ?? '未配置语言服务',
                style: const TextStyle(fontSize: 11),
              ),
            ),
            for (final action in LanguageAction.values)
              IconBtn(
                switch (action) {
                  LanguageAction.completion => Icons.auto_awesome,
                  LanguageAction.hover => Icons.info_outline,
                  LanguageAction.definition => Icons.call_made,
                  LanguageAction.references => Icons.manage_search,
                  LanguageAction.format => Icons.format_align_left,
                  LanguageAction.rename => Icons.drive_file_rename_outline,
                  LanguageAction.codeAction => Icons.lightbulb_outline,
                },
                languageActionLabels[action]!,
                session == null || !session.active
                    ? null
                    : () => runLanguageAction(context, ws, document, action),
              ),
          ],
        ),
      );
    },
  );
}

Map<String, Object> _position(int line, int column) => {
  'line': line,
  'character': column,
};

Future<void> runLanguageAction(
  BuildContext context,
  Workspace ws,
  DocumentModel doc,
  LanguageAction action,
) async {
  installEditReview(ws, context);
  final selection = doc.controller.unfoldLineSelection;
  final position = _position(selection.extentIndex, selection.extentOffset);
  final range = {
    'start': _position(selection.startIndex, selection.startOffset),
    'end': _position(selection.endIndex, selection.endOffset),
  };
  try {
    String? name;
    if (action == LanguageAction.rename) {
      name = await askText(context, title: '重命名符号', hint: '新名称', ok: '预览修改');
      if (name == null || name.trim().isEmpty || !context.mounted) return;
    }
    final method = switch (action) {
      LanguageAction.completion => 'textDocument/completion',
      LanguageAction.hover => 'textDocument/hover',
      LanguageAction.definition => 'textDocument/definition',
      LanguageAction.references => 'textDocument/references',
      LanguageAction.format => 'textDocument/formatting',
      LanguageAction.rename => 'textDocument/rename',
      LanguageAction.codeAction => 'textDocument/codeAction',
    };
    final reply = await ws.development.request(doc, method, switch (action) {
      LanguageAction.format => {
        'options': {'tabSize': doc.indent, 'insertSpaces': true},
      },
      LanguageAction.rename => {'position': position, 'newName': name},
      LanguageAction.references => {
        'position': position,
        'context': {'includeDeclaration': true},
      },
      LanguageAction.completion => {
        'position': position,
        'context': {'triggerKind': 1},
      },
      LanguageAction.codeAction => {
        'range': range,
        'context': {
          'diagnostics': [
            for (final d in ws.development.diagnostics)
              if (d.key == doc.key) d.raw,
          ],
        },
      },
      _ => {'position': position},
    });
    if (!context.mounted) return;
    final result = reply.result;
    if (result == null) {
      ws.toast('没有可用结果');
      return;
    }
    if (action == LanguageAction.hover) {
      String content(Object? value) {
        if (value is List) return value.map(content).join('\n\n');
        if (value is Map) return content(value['value'] ?? value['contents']);
        return value?.toString() ?? '';
      }

      await showWorkbenchDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('类型与文档'),
          content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
              child: SelectableText(content(result)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
    if (action == LanguageAction.definition ||
        action == LanguageAction.references) {
      final locations = result is List ? result : [result];
      final choices = [
        for (final value in locations)
          if (value is Map) value.cast<String, dynamic>(),
      ];
      final selected = choices.length == 1
          ? choices.single
          : await _pick(
              context,
              '选择位置',
              choices,
              (item) => '${item['uri'] ?? item['targetUri']}',
            );
      if (selected == null) return;
      final path = reply.session.scope.pathFromUri(
        '${selected['uri'] ?? selected['targetUri']}',
      );
      if (path == null) {
        ws.toast('目标位于当前工作根目录之外', error: true);
        return;
      }
      final target = selected['targetSelectionRange'] ?? selected['range'];
      final start = target is Map ? target['start'] : null;
      openFileAt(
        ws,
        root: reply.session.scope.root,
        path: path,
        line: start is Map ? ((start['line'] as num?)?.toInt() ?? 0) + 1 : 1,
        col: start is Map
            ? ((start['character'] as num?)?.toInt() ?? 0) + 1
            : 1,
      );
      return;
    }
    Map edit;
    Map? command;
    SnippetExpansion? snippet;
    int? snippetStart;
    if (action == LanguageAction.completion) {
      final items = result is List
          ? result
          : result is Map
          ? result['items'] as List? ?? []
          : [];
      final selected = await _pick(
        context,
        '语义补全',
        [
          for (final item in items.take(300))
            if (item is Map) item.cast<String, dynamic>(),
        ],
        (item) => '${item['label']}',
        detail: (item) => '${item['detail'] ?? ''}',
      );
      if (selected == null || !context.mounted) return;
      if (doc.controller.unfoldLineSelection != selection)
        throw StateError('光标已移动，请重新补全');
      var change = selected['textEdit'];
      if (change is Map) {
        change = {
          'range': change['range'] ?? change['replace'] ?? change['insert'],
          'newText': change['newText'],
        };
      } else {
        var start = selection.startOffset;
        if (selection.isCollapsed) {
          final line = doc.text.split('\n')[selection.startIndex];
          final word = RegExp(r'[\w$]+$').firstMatch(line.substring(0, start));
          if (word != null) start = word.start;
        }
        change = {
          'range': {
            'start': _position(selection.startIndex, start),
            'end': range['end'],
          },
          'newText': selected['insertText'] ?? selected['label'],
        };
      }
      if (selected['insertTextFormat'] == 2) {
        final path = doc.key.path, filename = path.split('/').last;
        final line = doc.text.split(
          RegExp(r'\r\n|\r|\n'),
        )[selection.extentIndex];
        final template = '${change['newText']}'.replaceAll(
          RegExp(r'\r\n|\r|\n'),
          doc.lineBreak.value,
        );
        snippet = expandSnippet(template, {
          'TM_SELECTED_TEXT': doc.selectedText,
          'TM_CURRENT_LINE': line,
          'TM_CURRENT_WORD':
              RegExp(r'[\w$]+')
                  .allMatches(line)
                  .where(
                    (m) =>
                        m.start <= selection.extentOffset &&
                        m.end >= selection.extentOffset,
                  )
                  .firstOrNull
                  ?.group(0) ??
              '',
          'TM_LINE_INDEX': '${selection.extentIndex}',
          'TM_LINE_NUMBER': '${selection.extentIndex + 1}',
          'TM_FILENAME': filename,
          'TM_FILENAME_BASE': filename.contains('.')
              ? filename.substring(0, filename.lastIndexOf('.'))
              : filename,
          'TM_DIRECTORY': path.substring(0, path.lastIndexOf('/')),
          'TM_FILEPATH': Uri.parse(reply.session.scope.documentUri(path))
              .toFilePath(windows: reply.session.scope.platform == 'windows'),
          'RELATIVE_FILEPATH': path.replaceFirst(RegExp(r'^/'), ''),
          'WORKSPACE_FOLDER': Uri.parse(reply.session.scope.workspaceUri)
              .toFilePath(windows: reply.session.scope.platform == 'windows'),
        });
        final primaryStart = positionOffset(
          doc.text,
          change['range']['start'] as Map,
        );
        snippetStart = primaryStart;
        for (final additional
            in selected['additionalTextEdits'] as List? ?? []) {
          final from = positionOffset(
                doc.text,
                additional['range']['start'] as Map,
              ),
              to = positionOffset(doc.text, additional['range']['end'] as Map);
          if (from < primaryStart && to <= primaryStart)
            snippetStart =
                snippetStart! +
                (additional['newText'] as String).length -
                (to - from);
        }
        change = {...change, 'newText': snippet.text};
      }
      edit = {
        'changes': {
          reply.session.scope.documentUri(doc.key.path): [
            change,
            ...selected['additionalTextEdits'] as List? ?? [],
          ],
        },
      };
      if (selected['command'] is Map) command = selected['command'] as Map;
    } else if (action == LanguageAction.codeAction) {
      final selected = await _pick(context, '代码操作', [
        for (final item in result as List)
          if (item is Map && item['disabled'] == null)
            item.cast<String, dynamic>(),
      ], (item) => '${item['title']}');
      if (selected == null) return;
      var resolved = selected;
      if (selected['edit'] == null &&
          selected['command'] == null &&
          selected['data'] != null) {
        final response = await reply.session.peer.request(
          'codeAction/resolve',
          selected,
        );
        if (response is Map) resolved = response.cast<String, dynamic>();
      }
      edit = resolved['edit'] is Map ? resolved['edit'] as Map : {};
      command = resolved['command'] is Map
          ? resolved['command'] as Map
          : resolved['command'] is String
          ? resolved
          : null;
    } else {
      edit = action == LanguageAction.format
          ? {
              'changes': {
                reply.session.scope.documentUri(doc.key.path): result,
              },
            }
          : result as Map;
    }
    final plan = await ws.development.prepareEdit(
      reply.session,
      edit,
      reply.versions,
    );
    if (!context.mounted) return;
    if (plan.edits.isNotEmpty) {
      if (action != LanguageAction.completion &&
          !await ws.development.reviewEdit!(plan))
        return;
      if (!plan.applied) plan.apply();
      if (snippet != null && snippetStart != null) {
        final after = plan.edits
            .firstWhere((e) => identical(e.document, doc))
            .after;
        final normalizedStart = after
            .substring(0, snippetStart)
            .replaceAll(RegExp(r'\r\n|\r|\n'), doc.lineBreak.value)
            .length;
        doc.startSnippet(snippet, normalizedStart);
      }
      for (final item in plan.edits) {
        if (action == LanguageAction.completion &&
            identical(item.document, doc))
          continue;
        openFileAt(
          ws,
          root: item.document.key.root,
          path: item.document.key.path,
        );
      }
    }
    if (command != null && reply.session.active) {
      await reply.session.peer.request('workspace/executeCommand', {
        'command': command['command'],
        'arguments': command['arguments'] ?? [],
      });
    }
  } on Object catch (e) {
    ws.toast('$e', error: true);
  }
}

Future<Map<String, dynamic>?> _pick(
  BuildContext context,
  String title,
  List<Map<String, dynamic>> items,
  String Function(Map<String, dynamic>) label, {
  String Function(Map<String, dynamic>)? detail,
}) {
  return showWorkbenchDialog<Map<String, dynamic>>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 680,
        height: 380,
        child: items.isEmpty
            ? const Center(child: Text('没有可用结果'))
            : ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) => TreeRow(
                  label: label(items[i]),
                  subtitle: detail?.call(items[i]),
                  onTap: () => Navigator.pop(c, items[i]),
                ),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
      ],
    ),
  );
}

Future<bool> reviewDocumentEdits(
  BuildContext context,
  DocumentEditPlan plan, {
  bool allowSave = false,
  String? detail,
}) async =>
    await showWorkbenchDialog<bool>(
      context: context,
      builder: (_) =>
          _EditReview(plan: plan, allowSave: allowSave, detail: detail),
    ) ??
    false;

class _EditReview extends StatefulWidget {
  final DocumentEditPlan plan;
  final bool allowSave;
  final String? detail;
  const _EditReview({required this.plan, required this.allowSave, this.detail});
  @override
  State<_EditReview> createState() => _EditReviewState();
}

class _EditReviewState extends State<_EditReview> {
  int index = 0;
  final Map<int, Future<List<DiffLine>>> _diffs = {};
  FileTextOperation? _operation;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    widget.plan.cancelled?.then((_) {
      if (!mounted) return;
      _operation?.cancel();
      final route = ModalRoute.of(context);
      if (route != null && route.isActive)
        Navigator.of(context).removeRoute(route, false);
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final operation = _operation = FileTextOperation(
      active: () => mounted && widget.plan.active(),
    );
    try {
      await widget.plan.applyAndSave(operation: operation);
      if (mounted && !widget.plan.requiresSave) Navigator.pop(context, true);
    } on Object catch (e) {
      if (mounted)
        setState(
          () => _error =
              '$e${widget.plan.applied ? '\n修改已保留在缓冲中，可撤销或核对磁盘后保存。' : ''}',
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _undo() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final operation = _operation = FileTextOperation(active: () => mounted);
    try {
      await widget.plan.undo(operation: operation);
      if (mounted) Navigator.pop(context, false);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _operation?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final edits = widget.plan.edits;
    return PopScope(
      canPop: !_saving,
      child: Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 700),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${edits.length} 个文档的修改预览',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(widget.detail ?? '接受到编辑缓冲后可撤销；整批保存同时检查缓冲和磁盘版本。'),
                if (widget.plan.requiresSave)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 100),
                    child: SingleChildScrollView(
                      child: Text(
                        '${widget.plan.resources.join('\n')}\n${widget.plan.saved ? '已提交；可在下方撤销整批事务。' : '包含文件资源操作，须整批保存。删除／移动前的缓冲会保留为恢复副本。'}',
                      ),
                    ),
                  ),
                if (_saving) const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (edits.isNotEmpty) ...[
                  DropdownButton<int>(
                    isExpanded: true,
                    value: index,
                    items: [
                      for (var i = 0; i < edits.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            edits[i].document.key.path,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (i) {
                      if (i != null) setState(() => index = i);
                    },
                  ),
                  Expanded(
                    child: FutureBuilder<List<DiffLine>>(
                      future: _diffs.putIfAbsent(
                        index,
                        () => diffTextsAsync(
                          edits[index].before,
                          edits[index].after,
                          active: () => mounted && widget.plan.active(),
                        ),
                      ),
                      builder: (_, result) => result.hasError
                          ? Center(child: Text('${result.error}'))
                          : result.data == null
                          ? const Center(child: CircularProgressIndicator())
                          : DiffView(lines: result.data!),
                    ),
                  ),
                ],
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: _saving
                          ? () => _operation?.cancel()
                          : () => Navigator.pop(
                              context,
                              widget.plan.applied && !widget.plan.undone,
                            ),
                      child: Text(_saving ? '取消保存' : '关闭'),
                    ),
                    if (widget.plan.canUndo)
                      OutlinedButton(
                        onPressed: _saving ? null : _undo,
                        child: const Text('撤销整批资源修改'),
                      ),
                    if (widget.allowSave || widget.plan.requiresSave)
                      OutlinedButton(
                        onPressed: _saving || widget.plan.applied
                            ? null
                            : _save,
                        child: const Text('接受并整批保存'),
                      ),
                    if (!widget.plan.requiresSave)
                      FilledButton(
                        onPressed: _saving || widget.plan.applied
                            ? null
                            : () => Navigator.pop(context, true),
                        child: const Text('接受全部修改'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
