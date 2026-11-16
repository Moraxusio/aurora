import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora/ui/aurora_ui.dart';

import '../../kernel/document_model.dart';
import '../../theme/ide_theme.dart';

/// A reviewable three-way view. Disk reads and accepting the edited result are
/// version guarded; accepting a merge changes the buffer, never writes blindly.
Future<void> showDocumentMerge(
  BuildContext context,
  DocumentModel document,
) async {
  final link = document.currentLink();
  if (link == null) return;
  final version = document.version;
  final mine = document.text, base = document.baseText;
  try {
    final disk = await document.readDisk();
    if (!context.mounted || !identical(link, document.currentLink())) return;
    if (disk['binary'] == true ||
        disk['truncated'] == true ||
        disk['etag'] is! String) {
      throw StateError('磁盘文件无法完整读取，保留了你的编辑内容');
    }
    final diskText = disk['content'] as String? ?? '';
    final result = await showWorkbenchDialog<String>(
      context: context,
      builder: (_) => _MergeDialog(base: base, mine: mine, disk: diskText),
    );
    if (result == null || !context.mounted) return;
    if (!identical(link, document.currentLink())) {
      throw StateError('连接已变化，请重新比较');
    }
    document.acceptMerge(
      result,
      diskText,
      disk['etag'] as String,
      expectedVersion: version,
    );
  } on Object catch (e) {
    if (context.mounted) {
      Toast.show(
        e is OpError
            ? e.message
            : e is StateError
            ? e.message
            : '比较失败，请重试',
        error: true,
      );
    }
  }
}

class _MergeDialog extends StatefulWidget {
  final String base, mine, disk;
  const _MergeDialog({
    required this.base,
    required this.mine,
    required this.disk,
  });
  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  late final TextEditingController _result = TextEditingController(
    text: widget.mine,
  );
  @override
  void dispose() {
    _result.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    Widget source(String title, String text) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.all(8), child: Text(title)),
        Expanded(
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: ide.border)),
            padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(fontFamily: Ide.mono, fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    );
    final editor = TextField(
      key: const ValueKey('document-merge-result'),
      controller: _result,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontFamily: Ide.mono, fontSize: 12),
      decoration: const InputDecoration(
        labelText: '合并结果（接受后仍需保存）',
        border: OutlineInputBorder(),
      ),
    );
    final choices = Wrap(
      spacing: 8,
      children: [
        TextButton(
          onPressed: () => _result.text = widget.mine,
          child: const Text('使用我的版本'),
        ),
        TextButton(
          onPressed: () => _result.text = widget.disk,
          child: const Text('使用磁盘版本'),
        ),
      ],
    );
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, size) {
              final compact = size.maxWidth < 720 || size.maxHeight < 450;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('比较并合并', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Expanded(
                    child: compact
                        ? DefaultTabController(
                            length: 4,
                            initialIndex: 3,
                            child: Column(
                              children: [
                                const TabBar(
                                  isScrollable: true,
                                  tabAlignment: TabAlignment.start,
                                  tabs: [
                                    Tab(text: '基准'),
                                    Tab(text: '磁盘'),
                                    Tab(text: '我的'),
                                    Tab(text: '结果'),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Expanded(
                                  child: TabBarView(
                                    children: [
                                      source('打开时的版本', widget.base),
                                      source('磁盘当前版本', widget.disk),
                                      source('我的未保存版本', widget.mine),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          choices,
                                          const SizedBox(height: 8),
                                          Expanded(child: editor),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: source('打开时的版本', widget.base),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: source('磁盘当前版本', widget.disk),
                                    ),
                                  ],
                                ),
                              ),
                              choices,
                              const SizedBox(height: 8),
                              Expanded(child: editor),
                            ],
                          ),
                  ),
                  const SizedBox(height: 12),
                  OverflowBar(
                    spacing: 8,
                    overflowSpacing: 4,
                    alignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, _result.text),
                        child: const Text('接受合并到编辑器'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
