// Viewers for files that are not text: an image and a PDF are read whole
// over fs.download (with a size limit) and shown; video and audio are not
// supported yet and say so instead of opening as garbage text.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'download_action.dart';
import 'file_kind.dart';
import 'remote_bytes.dart';

const imageMaxBytes = 64 * 1024 * 1024;
const pdfMaxBytes = 128 * 1024 * 1024;

/// Loads [root]:[path] and hands the bytes to [builder]. Shows progress, and
/// for a failure or an over-size file a message with a download button.
class RemoteBytesView extends StatefulWidget {
  final Workspace ws;
  final String root;
  final String path;
  final int maxBytes;
  final Widget Function(BuildContext context, RemoteBytes data) builder;
  final DownloadOpener? opener; // tests
  const RemoteBytesView({super.key, required this.ws, required this.root, required this.path, required this.maxBytes, required this.builder, this.opener});

  @override
  State<RemoteBytesView> createState() => _RemoteBytesViewState();
}

class _RemoteBytesViewState extends State<RemoteBytesView> {
  final _cancel = ReadCancel();
  RemoteBytes? _data;
  String? _error;
  bool _tooLarge = false;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final link = widget.ws.link;
    if (link == null) {
      setState(() => _error = '未连接');
      return;
    }
    setState(() {
      _error = null;
      _tooLarge = false;
      _progress = null;
    });
    try {
      final d = await readRemoteBytes(link, widget.root, widget.path, maxBytes: widget.maxBytes, cancel: _cancel, opener: widget.opener, onProgress: (done, total) {
        if (mounted && total > 0) setState(() => _progress = done / total);
      });
      if (mounted) setState(() => _data = d);
    } on RemoteTooLarge catch (e) {
      if (mounted) {
        setState(() {
          _tooLarge = true;
          _error = '文件有 ${formatSize(e.size)}，超过在线查看的上限（${formatSize(e.limit)}）。\n下载后在本机用合适的工具打开。';
        });
      }
    } on Object catch (e) {
      if (mounted && !_cancel.cancelled) setState(() => _error = e is OpError ? e.message : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data != null) return widget.builder(context, data);
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(_tooLarge ? Icons.block : Icons.error_outline, size: 30, color: Ide.of(context).textDim),
            const SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: Ide.of(context).textDim)),
            const SizedBox(height: 12),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (!_tooLarge) OutlinedButton(onPressed: _load, child: const Text('重试')),
              if (!_tooLarge) const SizedBox(width: 8),
              OutlinedButton(onPressed: () => downloadRemoteFile(widget.ws, root: widget.root, path: widget.path), child: const Text('下载')),
            ]),
          ]),
        ),
      );
    }
    return Center(child: SizedBox(width: 160, child: LinearProgressIndicator(value: _progress)));
  }
}

// ---------------------------------------------------------------- image

class ImageViewer extends StatelessWidget {
  final Workspace ws;
  final String root;
  final String path;
  final DownloadOpener? opener; // tests
  const ImageViewer({super.key, required this.ws, required this.root, required this.path, this.opener});

  @override
  Widget build(BuildContext context) => RemoteBytesView(
        opener: opener,
        ws: ws,
        root: root,
        path: path,
        maxBytes: imageMaxBytes,
        builder: (_, d) => _ImageBody(ws: ws, root: root, path: path, data: d),
      );
}

class _ImageBody extends StatefulWidget {
  final Workspace ws;
  final String root;
  final String path;
  final RemoteBytes data;
  const _ImageBody({required this.ws, required this.root, required this.path, required this.data});

  @override
  State<_ImageBody> createState() => _ImageBodyState();
}

class _ImageBodyState extends State<_ImageBody> {
  ui.Image? _img;
  String? _error;
  double? _zoom; // null = fit the window

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      // one decode, kept as a ui.Image: the picture is drawn from it directly
      final codec = await ui.instantiateImageCodec(widget.data.bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _img = frame.image);
      final t = widget.ws.tab('file:${widget.root}:${widget.path}');
      t?.status.value = '${frame.image.width} × ${frame.image.height}   ${formatSize(widget.data.size)}';
    } on Object {
      if (mounted) setState(() => _error = '无法显示这张 ${extOf(widget.path).toUpperCase()} 图片：格式不受支持或文件已损坏。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_error != null) {
      return EmptyHint(icon: Icons.broken_image_outlined, text: _error!, actionLabel: '下载', onAction: () => downloadRemoteFile(widget.ws, root: widget.root, path: widget.path, size: widget.data.size));
    }
    final img = _img;
    if (img == null) return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    final w = img.width.toDouble(), h = img.height.toDouble();
    final stage = _zoom == null
        ? InteractiveViewer(
            key: const ValueKey('fit'),
            maxScale: 8,
            child: SizedBox.expand(child: RawImage(image: img, fit: BoxFit.contain, filterQuality: FilterQuality.medium)),
          )
        : InteractiveViewer(
            key: ValueKey(_zoom),
            constrained: false,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            minScale: 0.1,
            maxScale: 8,
            child: SizedBox(width: w * _zoom!, height: h * _zoom!, child: RawImage(image: img, fit: BoxFit.fill, filterQuality: FilterQuality.medium)),
          );
    return Column(children: [
      Container(
        height: 30,
        color: ide.tabBar,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          Text('${img.width} × ${img.height} · ${formatSize(widget.data.size)}', style: TextStyle(color: ide.textDim, fontSize: 12)),
          const Spacer(),
          IconBtn(Icons.remove, '缩小', () => setState(() => _zoom = ((_zoom ?? _fitScale(context, w, h)) / 1.25).clamp(0.05, 16))),
          TextButton(onPressed: () => setState(() => _zoom = null), child: const Text('适应')),
          TextButton(onPressed: () => setState(() => _zoom = 1), child: const Text('100%')),
          IconBtn(Icons.add, '放大', () => setState(() => _zoom = ((_zoom ?? _fitScale(context, w, h)) * 1.25).clamp(0.05, 16))),
          IconBtn(Icons.download, '下载', () => downloadRemoteFile(widget.ws, root: widget.root, path: widget.path, size: widget.data.size)),
        ]),
      ),
      Expanded(child: ColoredBox(color: ide.editor, child: stage)),
    ]);
  }

  double _fitScale(BuildContext context, double w, double h) {
    final s = MediaQuery.sizeOf(context);
    final f = (s.width / w) < (s.height / h) ? s.width / w : s.height / h;
    return f.clamp(0.05, 16).toDouble();
  }
}

// ------------------------------------------------------------------ pdf

class PdfFileViewer extends StatelessWidget {
  final Workspace ws;
  final String root;
  final String path;
  const PdfFileViewer({super.key, required this.ws, required this.root, required this.path});

  @override
  Widget build(BuildContext context) => RemoteBytesView(
        ws: ws,
        root: root,
        path: path,
        maxBytes: pdfMaxBytes,
        builder: (_, d) => _PdfBody(ws: ws, root: root, path: path, data: d),
      );
}

class _PdfBody extends StatefulWidget {
  final Workspace ws;
  final String root;
  final String path;
  final RemoteBytes data;
  const _PdfBody({required this.ws, required this.root, required this.path, required this.data});

  @override
  State<_PdfBody> createState() => _PdfBodyState();
}

class _PdfBodyState extends State<_PdfBody> {
  final _controller = PdfViewerController();
  int _pages = 0;

  void _status(int? page) {
    final t = widget.ws.tab('file:${widget.root}:${widget.path}');
    t?.status.value = '${page ?? 1} / $_pages 页   ${formatSize(widget.data.size)}';
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return PdfViewer.data(
      widget.data.bytes,
      sourceName: 'file:${widget.root}:${widget.path}:${widget.data.etag ?? ''}',
      controller: _controller,
      params: PdfViewerParams(
        backgroundColor: ide.editor,
        onViewerReady: (doc, c) {
          _pages = doc.pages.length;
          _status(c.pageNumber);
        },
        onPageChanged: _status,
      ),
    );
  }
}

// ------------------------------------------------------- video and audio

/// Video and audio need a player that reads the file in byte ranges, and one
/// that is not GPL on Windows; neither is in place yet, so the file is not
/// opened. Nothing is fetched here.
class MediaUnsupported extends StatelessWidget {
  final Workspace ws;
  final String root;
  final String path;
  final FileKind kind;
  const MediaUnsupported({super.key, required this.ws, required this.root, required this.path, required this.kind});

  @override
  Widget build(BuildContext context) => EmptyHint(
        icon: kind == FileKind.video ? Icons.movie_outlined : Icons.audiotrack_outlined,
        text: '暂不支持在 Aurora 里播放${kind == FileKind.video ? '视频' : '音频'}。\n下载后用本机播放器打开。',
        actionLabel: '下载',
        onAction: () => downloadRemoteFile(ws, root: root, path: path),
      );
}
