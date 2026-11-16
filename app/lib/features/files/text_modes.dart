import 'dart:async';

import 'package:aurora/ui/aurora_ui.dart';

import '../../kernel/document_model.dart';
import '../../kernel/file_text.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';

Future<void> chooseTextEncoding(
  BuildContext context,
  DocumentModel document,
) async {
  final choice = await showWorkbenchDialog<(String, bool)>(
    context: context,
    builder: (_) => _EncodingDialog(document: document),
  );
  if (choice == null) return;
  try {
    if (choice.$2) {
      document.setSaveEncoding(choice.$1);
    } else {
      await document.reopenEncoding(choice.$1);
    }
  } on Object catch (e) {
    if (context.mounted) Toast.show('$e', error: true);
  }
}

class _EncodingDialog extends StatefulWidget {
  final DocumentModel document;
  const _EncodingDialog({required this.document});
  @override
  State<_EncodingDialog> createState() => _EncodingDialogState();
}

class _EncodingDialogState extends State<_EncodingDialog> {
  late String encoding = widget.document.encoding;
  late bool save = widget.document.phase == DocumentPhase.ready;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('文本编码'),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<bool>(
            initialValue: save,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '操作'),
            items: [
              if (!widget.document.dirty)
                const DropdownMenuItem(value: false, child: Text('重新以编码打开')),
              if (widget.document.phase == DocumentPhase.ready)
                const DropdownMenuItem(value: true, child: Text('更改保存编码')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => save = value);
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: encoding,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '编码'),
            items: [
              for (final entry in textEncodings.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => encoding = value);
            },
          ),
          const SizedBox(height: 12),
          Text(save ? '只更改保存格式，按保存后写入磁盘。无法表示的字符会阻止保存。' : '按所选编码重新读取磁盘文件。'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, (encoding, save)),
        child: const Text('确定'),
      ),
    ],
  );
}

class TextModeToolbar extends StatelessWidget {
  final DocumentModel document;
  const TextModeToolbar({super.key, required this.document});
  @override
  Widget build(BuildContext context) {
    if (document.currentLink()?.server.caps.contains('fs.text') != true)
      return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton(
          onPressed: () => chooseTextEncoding(context, document),
          child: Text(textEncodings[document.encoding] ?? document.encoding),
        ),
        if (document.large)
          const Text('大文件精简编辑 · 关闭高亮与语言同步')
        else if (!document.languageSyncEligible)
          const Text('文本超过语言协议预算 · 暂停语言同步'),
      ],
    );
  }
}

class LargeTextReader extends StatefulWidget {
  final Workspace ws;
  final DocumentModel document;
  final VoidCallback onBack;
  const LargeTextReader({
    super.key,
    required this.ws,
    required this.document,
    required this.onBack,
  });
  @override
  State<LargeTextReader> createState() => _LargeTextReaderState();
}

class _LargeTextReaderState extends State<LargeTextReader> {
  static const windowSize = 64 * 1024;
  FileTextOperation? operation;
  Object? linkIdentity;
  int generation = 0, offset = 0, next = 0, size = 0;
  String? etag, error;
  bool busy = true, eof = false;
  List<String> lines = [];
  @override
  void initState() {
    super.initState();
    size = widget.document.fileSize;
    linkIdentity = widget.ws.link;
    widget.ws.addListener(_connection);
    unawaited(load(0));
  }

  void _connection() {
    if (identical(linkIdentity, widget.ws.link)) return;
    linkIdentity = widget.ws.link;
    etag = null;
    unawaited(load(0));
  }

  Future<void> load(int position) async {
    final request = ++generation, link = widget.ws.link;
    operation?.cancel();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (link == null) throw StateError('未连接');
      operation = FileTextOperation(
        active: () =>
            mounted && generation == request && identical(link, widget.ws.link),
      );
      final result = await operation!.read(
        link,
        widget.document.key.root,
        widget.document.key.path,
        window: true,
        offset: position,
        length: windowSize,
        etag: etag,
      );
      if (!mounted || request != generation) return;
      if (result['binary'] == true)
        throw StateError(result['message'] as String? ?? '此文件不能以 UTF-8 阅读');
      setState(() {
        etag = result['etag'] as String;
        offset = (result['offset'] as num).toInt();
        next = (result['nextOffset'] as num).toInt();
        size = (result['size'] as num).toInt();
        eof = result['eof'] == true;
        lines = (result['content'] as String).split('\n');
      });
    } on Object catch (e) {
      if (mounted && request == generation) setState(() => error = '$e');
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    generation++;
    operation?.cancel();
    widget.ws.removeListener(_connection);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IconBtn(Icons.arrow_back, '返回文件提示', widget.onBack),
          IconBtn(Icons.first_page, '文件开头', busy ? null : () => load(0)),
          IconBtn(
            Icons.chevron_left,
            '上一段',
            busy || offset == 0
                ? null
                : () => load((offset - windowSize).clamp(0, size)),
          ),
          IconBtn(
            Icons.chevron_right,
            '下一段',
            busy || eof ? null : () => load(next),
          ),
          IconBtn(
            Icons.last_page,
            '文件末尾',
            busy ? null : () => load((size - windowSize).clamp(0, size)),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    final value = await askText(
                      context,
                      title: '跳到字节位置',
                      initial: '$offset',
                      hint: '0–$size',
                    );
                    final position = int.tryParse(value ?? '');
                    if (position != null && mounted)
                      await load(position.clamp(0, size));
                  },
            child: Text('$offset–$next / $size 字节 · 只读'),
          ),
          IconBtn(Icons.refresh, '重新加载当前版本', () {
            etag = null;
            load(offset);
          }),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      if (error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: SelectableText(error!),
        ),
      Expanded(
        child: SelectionArea(
          child: ListView.builder(
            key: ValueKey('$etag:$offset'),
            padding: const EdgeInsets.all(12),
            itemCount: lines.length,
            itemBuilder: (_, i) => Text(
              lines[i].replaceFirst(RegExp(r'\r$'), ''),
              style: const TextStyle(fontFamily: Ide.mono, fontSize: 12),
            ),
          ),
        ),
      ),
    ],
  );
}
