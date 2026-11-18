import 'dart:convert';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora/ui/aurora_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:flutter/services.dart';

import '../../theme/ide_theme.dart';
import 'ai_models.dart';
import 'ai_attachments.dart';

class AiAttachmentTile extends StatefulWidget {
  final AiPart part;
  final Link link;
  const AiAttachmentTile({super.key, required this.part, required this.link});
  @override
  State<AiAttachmentTile> createState() => _AiAttachmentTileState();
}

class _AiAttachmentTileState extends State<AiAttachmentTile> {
  Future<Uint8List>? data;
  bool _opening = false;
  bool get isImage => widget.part.mime.startsWith('image/');
  @override
  void initState() {
    super.initState();
    if (isImage)
      data = downloadAiAttachment(widget.link, widget.part.attachmentId);
  }

  @override
  void didUpdateWidget(covariant AiAttachmentTile old) {
    super.didUpdateWidget(old);
    if (old.part.attachmentId != widget.part.attachmentId ||
        !identical(old.link, widget.link)) {
      data = isImage
          ? downloadAiAttachment(widget.link, widget.part.attachmentId)
          : null;
    }
  }

  Future<void> _open() async {
    if (_opening) return;
    final link = widget.link, part = widget.part;
    setState(() => _opening = true);
    try {
      final bytes = await (data ??= downloadAiAttachment(
        widget.link,
        widget.part.attachmentId,
      ));
      if (!mounted ||
          !identical(widget.link, link) ||
          widget.part.attachmentId != part.attachmentId)
        return;
      await showWorkbenchDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(widget.part.filename),
          content: SizedBox(
            width: 720,
            child: isImage
                ? InteractiveViewer(
                    child: Image.memory(
                      bytes,
                      cacheWidth: 1600,
                      errorBuilder: (_, _, _) => const Text('图片解码失败'),
                    ),
                  )
                : widget.part.mime == 'application/pdf'
                ? SizedBox(
                    height: 480,
                    child: PdfViewer.data(
                      bytes,
                      sourceName: widget.part.filename,
                    ),
                  )
                : SingleChildScrollView(
                    child: SelectableText(
                      widget.part.mime.startsWith('text/')
                          ? utf8.decode(bytes)
                          : '此附件没有可用的文本预览。',
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } on Object {
      if (mounted) {
        data = null; // A failed download can be retried from the same tile.
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('附件读取失败，文件可能已清理或服务器未连接')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Material(
          color: ide.editor,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _opening ? null : _open,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (isImage)
                  FutureBuilder<Uint8List>(
                    future: data,
                    builder: (context, snapshot) {
                      if (snapshot.hasData) {
                        return ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: Image.memory(
                            snapshot.data!,
                            cacheWidth: 640,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('图片无法解码'),
                            ),
                          ),
                        );
                      }
                      return SizedBox(
                        height: 70,
                        child: Center(
                          child: snapshot.hasError
                              ? const Icon(Icons.broken_image_outlined)
                              : const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                        ),
                      );
                    },
                  ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Icon(
                        isImage
                            ? Icons.image_outlined
                            : widget.part.mime == 'application/pdf'
                            ? Icons.picture_as_pdf_outlined
                            : Icons.description_outlined,
                        size: 18,
                        color: ide.accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.part.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: ide.text),
                        ),
                      ),
                      Text(
                        _opening
                            ? '读取中…'
                            : '${(widget.part.size / 1024).toStringAsFixed(0)} KiB',
                        style: TextStyle(fontSize: 11.5, color: ide.textDim),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
