// "Properties" of a file or folder: where it is, how big, when it changed, who
// owns it. For a folder the size is not known until asked for (walking a big
// tree takes time), so the dialog has a button that measures it with fs.du and
// hands the result back so the tree can show it too.
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../../kernel/widgets.dart';
import '../../theme/ide_theme.dart';
import 'file_ops.dart';

String fileTypeLabel(Map<String, dynamic>? entry, bool isDir) {
  final t = entry?['type'];
  if (entry == null) return '文件夹（根目录）';
  if (t == 'link') {
    final target = switch (entry['target']) {
      'dir' => '文件夹',
      'file' => '文件',
      'outside' => '指向根目录之外',
      _ => '目标不存在',
    };
    return '符号链接（$target）';
  }
  if (t == 'dir') return '文件夹';
  if (t == 'file') return '文件';
  return '特殊文件';
}

Future<void> showFileInfo(
  BuildContext context, {
  required String root,
  required String path,
  required Map<String, dynamic>? entry,
  required bool isDir,
  DuInfo? du,
  Future<DuResult> Function()? measure,
  void Function(DuResult)? onMeasured,
}) {
  return showWorkbenchDialog<void>(
    context: context,
    builder: (_) => _InfoDialog(root: root, path: path, entry: entry, isDir: isDir, du: du, measure: measure, onMeasured: onMeasured),
  );
}

class _InfoDialog extends StatefulWidget {
  final String root, path;
  final Map<String, dynamic>? entry;
  final bool isDir;
  final DuInfo? du;
  final Future<DuResult> Function()? measure;
  final void Function(DuResult)? onMeasured;
  const _InfoDialog({required this.root, required this.path, required this.entry, required this.isDir, this.du, this.measure, this.onMeasured});

  @override
  State<_InfoDialog> createState() => _InfoDialogState();
}

class _InfoDialogState extends State<_InfoDialog> {
  DuInfo? _du;
  List<String> _skipped = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _du = widget.du;
  }

  Future<void> _measure() async {
    final m = widget.measure;
    if (m == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await m();
      widget.onMeasured?.call(r);
      if (mounted) {
        setState(() {
          _du = r.total;
          _skipped = r.skipped;
        });
      }
    } on OpError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _row(Ide ide, String k, Widget v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 84, child: Text(k, style: TextStyle(fontSize: 12.5, color: ide.textDim))),
          Expanded(child: v),
        ]),
      );

  Widget _text(Ide ide, String s) => SelectableText(s, style: TextStyle(fontSize: 12.5, color: ide.text, height: 1.4));

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final e = widget.entry;
    final name = e?['name'] as String? ?? baseName(widget.path);
    final size = (e?['size'] as num?)?.toInt();
    final mtime = (e?['mtime'] as num?)?.toInt() ?? 0;
    final du = _du;
    final rows = <Widget>[
      _row(ide, '名称', _text(ide, name.isEmpty ? '/' : name)),
      _row(ide, '位置', _text(ide, '${widget.root}:${widget.path}')),
      _row(ide, '类型', _text(ide, fileTypeLabel(e, widget.isDir))),
      if (!widget.isDir && size != null) _row(ide, '大小', _text(ide, '${formatSize(size)}（$size 字节）')),
      if (widget.isDir)
        _row(
          ide,
          '大小',
          du != null
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _text(ide, '${du.partial ? '至少 ' : ''}${formatSize(du.bytes)}（${du.bytes} 字节）'),
                  _text(ide, '占用磁盘 ${formatSize(du.disk)} · ${du.files} 个文件 · ${du.dirs} 个子文件夹'),
                  if (du.partial) Text('统计超时，只算了一部分。', style: TextStyle(fontSize: 11.5, color: ide.warn)),
                  if (_skipped.isNotEmpty) Text('不含挂载点：${_skipped.take(3).join('、')}${_skipped.length > 3 ? '…' : ''}', style: TextStyle(fontSize: 11.5, color: ide.textDim)),
                  Text('统计于 ${formatShortTime(du.at.millisecondsSinceEpoch)}，之后的变化不会自动更新', style: TextStyle(fontSize: 11, color: ide.textFaint)),
                ])
              : (_busy
                  ? Row(children: [
                      const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
                      const SizedBox(width: 8),
                      Text('正在统计…', style: TextStyle(fontSize: 12.5, color: ide.textDim)),
                    ])
                  : Text('尚未统计', style: TextStyle(fontSize: 12.5, color: ide.textDim))),
        ),
      if (mtime > 0) _row(ide, '修改时间', _text(ide, formatTime(mtime))),
      if (e?['mode'] != null) _row(ide, '权限', _text(ide, '${e!['mode']}')),
      if ((e?['owner'] as String? ?? '').isNotEmpty) _row(ide, '所有者', _text(ide, '${e!['owner']}:${e['group'] ?? ''}')),
      if (e?['type'] == 'link' && e?['link_path'] != null) _row(ide, '链接目标', _text(ide, '${e!['link_root']}:${e['link_path']}')),
    ];
    return AlertDialog(
      title: const Text('属性'),
      content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        ...rows,
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: TextStyle(fontSize: 12, color: ide.error))),
      ])),
      actions: [
        TextButton(onPressed: () => copyText(widget.path, what: '已复制路径'), child: const Text('复制路径')),
        if (widget.isDir && widget.measure != null) OutlinedButton(onPressed: _busy ? null : _measure, child: Text(du == null ? '计算大小' : '重新计算')),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }
}
