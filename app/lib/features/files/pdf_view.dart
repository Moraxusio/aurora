// The PDF reader tab. A PDF is opened by byte ranges (pdf_source.dart), so a
// big file shows its first page quickly; a small one is fetched completely
// first so paging never waits. Around PDFium's view this adds what makes a
// document pleasant to read: an outline and page-thumbnail side bar, a page box
// to jump to, zoom (fit width, fit page, actual size, percentages), text search
// with highlights (Ctrl+F), a night mode that inverts the page, a password
// prompt, and the place you stopped reading is remembered for the session.
// Like the rest of the app it never opens a link on its own: a web link is
// copied, an in-document link jumps.
import 'dart:async';
import 'dart:convert';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'download_action.dart';
import 'pdf_source.dart';

/// Where the reader stopped, per file, until the app closes.
final _lastPage = <String, int>{};
bool _nightMode = false;

/// Forgets every remembered page and the night-mode choice (tests).
void resetPdfReaderMemory() {
  _lastPage.clear();
  _nightMode = false;
}

const _invert = ColorFilter.matrix(<double>[
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255,
  0, 0, -1, 0, 255,
  0, 0, 0, 1, 0,
]);

class PdfFileViewer extends StatefulWidget {
  final Workspace ws;
  final String root;
  final String path;
  final RangeOpener? opener; // tests
  const PdfFileViewer({super.key, required this.ws, required this.root, required this.path, this.opener});

  @override
  State<PdfFileViewer> createState() => _PdfFileViewerState();
}

class _PdfFileViewerState extends State<PdfFileViewer> {
  RemoteRangeReader? _reader;
  Uint8List? _bytes; // the whole file, when it was small enough to fetch first
  PdfViewerController _controller = PdfViewerController();
  PdfTextSearcher? _searcher;
  PdfDocument? _doc;
  int _gen = 0; // bumped on every (re)open: a new viewer for a new generation
  bool _loading = true;
  double? _progress;
  String? _error;
  bool _tooLarge = false;
  Object? _readError;
  bool _ready = false;
  int _pages = 0;
  int _page = 1;
  bool _sidebar = false;
  int _sideTab = 0; // 0 outline, 1 thumbnails
  bool _searching = false;
  List<PdfOutlineNode>? _outline;
  final _openNodes = <PdfOutlineNode>{};
  int _pwTries = 0;
  final _pageBox = TextEditingController(text: '1');
  final _pageFocus = FocusNode();
  final _searchBox = TextEditingController();
  final _searchFocus = FocusNode();

  String get _key => 'file:${widget.root}:${widget.path}';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _closeDocument();
    _pageBox.dispose();
    _pageFocus.dispose();
    _searchBox.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _closeDocument() {
    _searcher?.dispose();
    _searcher = null;
    _reader?.close();
    _reader = null;
    _bytes = null;
    _doc = null;
    _ready = false;
  }

  /// Callbacks from the viewer can arrive while it is building.
  void _defer(VoidCallback f) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(f);
    });
  }

  Future<void> _load() async {
    final gen = ++_gen;
    final link = widget.ws.link;
    final opener = widget.opener ?? (link == null ? null : linkRangeOpener(link));
    if (opener == null) {
      setState(() {
        _loading = false;
        _error = '未连接';
      });
      return;
    }
    _closeDocument();
    setState(() {
      _loading = true;
      _error = null;
      _tooLarge = false;
      _readError = null;
      _progress = null;
      _outline = null;
      _pages = 0;
      _pwTries = 0;
    });
    final reader = _reader = RemoteRangeReader(opener, widget.root, widget.path);
    try {
      await reader.init();
      if (!mounted || gen != _gen) return;
      if (reader.size > pdfMaxFile) {
        setState(() {
          _loading = false;
          _tooLarge = true;
          _error = '文件有 ${formatSize(reader.size)}，超过在线查看的上限（${formatSize(pdfMaxFile)}）。\n下载后在本机用 PDF 阅读器打开。';
        });
        return;
      }
      if (reader.size == 0 || !latin1.decode(reader.head(1024), allowInvalid: true).contains('%PDF-')) {
        setState(() {
          _loading = false;
          _error = reader.size == 0 ? '这是一个空文件。' : '这不是有效的 PDF 文件（文件头不对），可能已损坏或扩展名不符。';
        });
        return;
      }
      if (reader.size > pdfChunk && reader.size <= pdfPreloadMax) {
        await reader.preload(onProgress: (d, t) {
          if (mounted && gen == _gen && t > 0) setState(() => _progress = d / t);
        });
        if (!mounted || gen != _gen) return;
      }
      // Everything is here: PDFium reads the bytes in memory, so paging and
      // search never wait on the network. Bigger files are read on demand.
      if (reader.complete) _bytes = reader.takeAll();
      final page = _lastPage['$_key:${reader.etag}'];
      setState(() {
        _loading = false;
        _page = page ?? 1;
        _pageBox.text = '$_page';
      });
    } on Object catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loading = false;
        _error = e is OpError ? e.message : '$e';
      });
    }
  }

  void _reopen() {
    _controller = PdfViewerController();
    unawaited(_load());
  }

  Future<int> _read(Uint8List b, int pos, int n) async {
    try {
      return await _reader!.read(b, pos, n);
    } on Object catch (e) {
      _readError ??= e;
      _defer(() {});
      rethrow;
    }
  }

  Future<String?> _password() async {
    if (!mounted || _pwTries >= 5) return null;
    final again = _pwTries++ > 0;
    final t = await askText(context, title: again ? '密码不对，再试一次' : '这个 PDF 需要密码', hint: '密码', ok: '打开', obscure: true);
    return (t == null || t.isEmpty) ? null : t;
  }

  void _status() {
    final t = widget.ws.tab(_key);
    t?.status.value = '$_page / $_pages 页   ${formatSize(_reader?.size ?? 0)}';
  }

  void _onReady(PdfDocument doc, PdfViewerController c) {
    _doc = doc;
    // a remembered page past the end (the document got shorter) is not a place to start
    if (_page > doc.pages.length) {
      unawaited(c.goToPage(pageNumber: doc.pages.length, duration: Duration.zero));
    }
    final s = PdfTextSearcher(c);
    s.addListener(() {
      if (mounted) setState(() {});
    });
    _searcher = s;
    _defer(() {
      _pages = doc.pages.length;
      _page = c.pageNumber ?? _page;
      _ready = true;
      _status();
    });
    unawaited(doc.loadOutline().then((o) {
      if (mounted && _doc == doc) setState(() => _outline = o);
    }, onError: (_) {
      if (mounted && _doc == doc) setState(() => _outline = const []);
    }));
  }

  void _onPage(int? p) {
    if (p == null) return;
    _lastPage['$_key:${_reader?.etag}'] = p;
    _defer(() {
      _page = p;
      if (!_pageFocus.hasFocus) _pageBox.text = '$p';
      _status();
    });
  }

  // ---- actions ----

  void _goPage(int n) {
    if (!_ready || _pages == 0) return;
    unawaited(_controller.goToPage(pageNumber: n.clamp(1, _pages)));
  }

  void _submitPage(String v) {
    final n = int.tryParse(v.trim());
    if (n != null) _goPage(n);
    _pageBox.text = '$_page';
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _fitWidth() {
    if (!_ready) return;
    final m = _controller.calcMatrixFitWidthForPage(pageNumber: _page);
    if (m != null) unawaited(_controller.goTo(m));
  }

  void _fitPage() {
    if (!_ready) return;
    final m = _controller.calcMatrixForFit(pageNumber: _page);
    if (m != null) unawaited(_controller.goTo(m));
  }

  void _zoomTo(double z) {
    if (_ready) unawaited(_controller.setZoom(_controller.centerPosition, z));
  }

  void _zoomMenu(BuildContext ctx) {
    final box = ctx.findRenderObject() as RenderBox;
    showMenuAt(ctx, box.localToGlobal(Offset(0, box.size.height)), [
      MenuItem('适合宽度', _fitWidth, icon: Icons.width_normal_rounded),
      MenuItem('适合整页', _fitPage, icon: Icons.fit_screen_rounded),
      MenuItem('实际大小', () => _zoomTo(1), icon: Icons.crop_original_rounded, hint: '100%'),
      const MenuItem.separator(),
      for (final z in const [0.5, 0.75, 1.25, 1.5, 2.0, 3.0]) MenuItem('${(z * 100).round()}%', () => _zoomTo(z)),
    ]);
  }

  void _openSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
    _searchBox.selection = TextSelection(baseOffset: 0, extentOffset: _searchBox.text.length);
  }

  void _closeSearch() {
    _searcher?.resetTextSearch();
    setState(() => _searching = false);
  }

  void _search(String q, {bool now = false}) {
    final s = _searcher;
    if (s == null) return;
    if (q.trim().isEmpty) {
      s.resetTextSearch();
    } else {
      s.startTextSearch(q.trim(), searchImmediately: now, startPageNumber: _page);
    }
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyF) {
      _openSearch();
      return KeyEventResult.handled;
    }
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyG) {
      _pageFocus.requestFocus();
      _pageBox.selection = TextSelection(baseOffset: 0, extentOffset: _pageBox.text.length);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && _searching) {
      _closeSearch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- build ----

  Widget _centered(Ide ide, {required IconData icon, required String text, List<Widget> actions = const []}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 30, color: ide.textDim),
            const SizedBox(height: 10),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: ide.textDim, height: 1.5)),
            const SizedBox(height: 12),
            Row(mainAxisSize: MainAxisSize.min, children: actions),
          ]),
        ),
      );

  void _download() => downloadRemoteFile(widget.ws, root: widget.root, path: widget.path, size: _reader?.size ?? 0);

  Widget _toolbar(Ide ide) {
    Widget zoomLabel() => Builder(
          builder: (ctx) => InkWell(
            key: const ValueKey('pdf-zoom'),
            onTap: _ready ? () => _zoomMenu(ctx) : null,
            borderRadius: BorderRadius.circular(Radii.s),
            child: SizedBox(
              width: 58,
              height: 26,
              child: Center(
                child: _ready
                    ? AnimatedBuilder(
                        animation: _controller,
                        builder: (_, _) => Text('${(_controller.currentZoom * 100).round()}%', style: TextStyle(fontSize: 12, color: ide.text)),
                      )
                    : Text('—', style: TextStyle(fontSize: 12, color: ide.textFaint)),
              ),
            ),
          ),
        );
    return Container(
      height: 34,
      color: ide.tabBar,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          IconBtn(Icons.view_sidebar_outlined, _sidebar ? '收起目录和缩略图' : '目录和缩略图', () => setState(() => _sidebar = !_sidebar), color: _sidebar ? ide.accent : null),
          const SizedBox(width: 4),
          IconBtn(Icons.keyboard_arrow_up_rounded, '上一页', _ready && _page > 1 ? () => _goPage(_page - 1) : null, size: 20),
          SizedBox(
            width: 40,
            height: 24,
            child: TextField(
              key: const ValueKey('pdf-page'),
              controller: _pageBox,
              focusNode: _pageFocus,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              style: TextStyle(fontSize: 12.5, color: ide.text),
              decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 4)),
              onSubmitted: _submitPage,
            ),
          ),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text('/ ${_pages == 0 ? '—' : _pages}', style: TextStyle(fontSize: 12.5, color: ide.textDim))),
          IconBtn(Icons.keyboard_arrow_down_rounded, '下一页', _ready && _page < _pages ? () => _goPage(_page + 1) : null, size: 20),
          const SizedBox(width: 8),
          IconBtn(Icons.remove_rounded, '缩小', _ready ? () => unawaited(_controller.zoomDown()) : null),
          zoomLabel(),
          IconBtn(Icons.add_rounded, '放大', _ready ? () => unawaited(_controller.zoomUp()) : null),
          const SizedBox(width: 12),
          IconBtn(Icons.search_rounded, '搜索（Ctrl+F）', _ready ? _openSearch : null, color: _searching ? ide.accent : null),
          IconBtn(_nightMode ? Icons.dark_mode_rounded : Icons.dark_mode_outlined, _nightMode ? '关闭夜间模式' : '夜间模式（页面反色）', () => setState(() => _nightMode = !_nightMode),
              color: _nightMode ? ide.accent : null),
          IconBtn(Icons.download_rounded, '下载', _download),
        ]),
      ),
    );
  }

  Widget _searchBar(Ide ide) {
    final s = _searcher;
    final hasQuery = _searchBox.text.trim().isNotEmpty;
    String info = '';
    if (s != null && hasQuery) {
      if (s.matches.isNotEmpty) {
        info = '${(s.currentIndex ?? 0) + 1} / ${s.matches.length}${s.isSearching ? '+' : ''}';
      } else {
        info = s.isSearching ? '搜索中…' : '没有结果';
      }
    }
    return Container(
      height: 36,
      color: ide.sideBar,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        Icon(Icons.search_rounded, size: 16, color: ide.textFaint),
        const SizedBox(width: 6),
        SizedBox(
          width: 220,
          child: TextField(
            key: const ValueKey('pdf-search'),
            controller: _searchBox,
            focusNode: _searchFocus,
            style: TextStyle(fontSize: 12.5, color: ide.text),
            decoration: const InputDecoration(isDense: true, hintText: '在文档中查找', border: InputBorder.none),
            onChanged: (q) {
              setState(() {});
              _search(q);
            },
            onSubmitted: (q) {
              if (_searcher?.matches.isNotEmpty ?? false) {
                unawaited(_searcher!.goToNextMatch());
              } else {
                _search(q, now: true);
              }
              _searchFocus.requestFocus();
            },
          ),
        ),
        const SizedBox(width: 8),
        Text(info, key: const ValueKey('pdf-search-info'), style: TextStyle(fontSize: 12, color: ide.textDim)),
        const Spacer(),
        IconBtn(Icons.keyboard_arrow_up_rounded, '上一个', s != null && s.matches.isNotEmpty ? () => unawaited(s.goToPrevMatch()) : null, size: 20),
        IconBtn(Icons.keyboard_arrow_down_rounded, '下一个', s != null && s.matches.isNotEmpty ? () => unawaited(s.goToNextMatch()) : null, size: 20),
        IconBtn(Icons.close_rounded, '关闭搜索（Esc）', _closeSearch),
      ]),
    );
  }

  Iterable<(PdfOutlineNode, int)> _flat(List<PdfOutlineNode> nodes, int depth) sync* {
    for (final n in nodes) {
      yield (n, depth);
      if (_openNodes.contains(n)) yield* _flat(n.children, depth + 1);
    }
  }

  Widget _outlineList(Ide ide) {
    final o = _outline;
    if (o == null) return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8)));
    if (o.isEmpty) return Center(child: Text('这个 PDF 没有目录', style: TextStyle(fontSize: 12.5, color: ide.textDim)));
    final rows = _flat(o, 0).toList();
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final (n, depth) = rows[i];
        final open = _openNodes.contains(n);
        return InkWell(
          key: ValueKey('pdf-outline-$i'),
          onTap: n.dest == null ? null : () => unawaited(_controller.goToDest(n.dest)),
          child: Padding(
            padding: EdgeInsets.fromLTRB(4 + depth * 14.0, 5, 8, 5),
            child: Row(children: [
              SizedBox(
                width: 20,
                child: n.children.isEmpty
                    ? null
                    : InkWell(
                        onTap: () => setState(() => open ? _openNodes.remove(n) : _openNodes.add(n)),
                        child: Icon(open ? Icons.expand_more : Icons.chevron_right, size: 16, color: ide.textDim),
                      ),
              ),
              Expanded(child: Text(n.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: ide.text, height: 1.3))),
              if (n.dest != null) Text('${n.dest!.pageNumber}', style: TextStyle(fontSize: 11, color: ide.textFaint)),
            ]),
          ),
        );
      },
    );
  }

  Widget _thumbnails(Ide ide) {
    final doc = _doc;
    if (doc == null || _pages == 0) return const SizedBox();
    return ListView.builder(
      itemCount: _pages,
      itemExtent: 188,
      itemBuilder: (_, i) {
        final n = i + 1, cur = n == _page;
        return InkWell(
          key: ValueKey('pdf-thumb-$n'),
          onTap: () => _goPage(n),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Column(children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(border: Border.all(color: cur ? ide.accent : ide.border, width: cur ? 2 : 1)),
                  child: ColorFiltered(
                    colorFilter: _nightMode ? _invert : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
                    child: PdfPageView(document: doc, pageNumber: n, maximumDpi: 72, decoration: const BoxDecoration(color: Colors.white)),
                  ),
                ),
              ),
              Padding(padding: const EdgeInsets.only(top: 3), child: Text('$n', style: TextStyle(fontSize: 11, color: cur ? ide.accent : ide.textDim))),
            ]),
          ),
        );
      },
    );
  }

  Widget _side(Ide ide) => Container(
        width: 232,
        decoration: BoxDecoration(color: ide.sideBar, border: Border(right: BorderSide(color: ide.border))),
        child: Column(children: [
          SizedBox(
            height: 32,
            child: Row(children: [
              for (final (i, label) in const [(0, '目录'), (1, '缩略图')])
                Expanded(
                  child: InkWell(
                    key: ValueKey('pdf-side-$i'),
                    onTap: () => setState(() => _sideTab = i),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _sideTab == i ? ide.accent : Colors.transparent, width: 2))),
                      child: Text(label, style: TextStyle(fontSize: 12.5, color: _sideTab == i ? ide.text : ide.textDim, fontWeight: _sideTab == i ? FontWeight.w600 : FontWeight.w400)),
                    ),
                  ),
                ),
            ]),
          ),
          Divider(height: 1, color: ide.border),
          Expanded(child: _sideTab == 0 ? _outlineList(ide) : _thumbnails(ide)),
        ]),
      );

  Widget _errorBanner(Ide ide, Object error) {
    final text = error is PdfPasswordException
        ? '需要密码，或者密码不对。'
        : (error is RemoteChanged ? error.toString() : '无法打开这个 PDF：$error');
    return _centered(ide, icon: Icons.picture_as_pdf_outlined, text: text, actions: [
      OutlinedButton(onPressed: _reopen, child: Text(error is PdfPasswordException ? '输入密码' : '重试')),
      const SizedBox(width: 8),
      OutlinedButton(onPressed: _download, child: const Text('下载')),
    ]);
  }

  PdfViewerParams _params(Ide ide, PdfTextSearcher? searcher) => PdfViewerParams(
        backgroundColor: ide.editor,
        pageImageColorFilter: _nightMode ? _invert : null,
        onViewerReady: _onReady,
        onPageChanged: _onPage,
        keyHandlerParams: const PdfViewerKeyHandlerParams(autofocus: true),
        pagePaintCallbacks: [if (searcher != null) searcher.pageTextMatchPaintCallback],
        linkHandlerParams: PdfLinkHandlerParams(onLinkTap: (link) {
          if (link.dest != null) {
            unawaited(_controller.goToDest(link.dest));
          } else if (link.url != null) {
            copyText(link.url.toString(), what: '链接已复制（不会自动打开）');
          }
        }),
        viewerOverlayBuilder: (context, size, handleLinkTap) => [
          PdfViewerScrollThumb(controller: _controller, orientation: ScrollbarOrientation.right),
        ],
        errorBannerBuilder: (context, error, stack, ref) => _errorBanner(ide, error),
      );

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_error != null) {
      return _centered(ide, icon: _tooLarge ? Icons.block : Icons.error_outline, text: _error!, actions: [
        if (!_tooLarge) OutlinedButton(onPressed: _reopen, child: const Text('重试')),
        if (!_tooLarge) const SizedBox(width: 8),
        OutlinedButton(onPressed: _download, child: const Text('下载')),
      ]);
    }
    if (_loading || _reader == null) {
      final r = _reader;
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 180, child: LinearProgressIndicator(value: _progress)),
          const SizedBox(height: 10),
          Text(r != null && r.size > 0 ? '正在打开 PDF（${formatSize(r.size)}）${_progress == null ? '' : ' ${(_progress! * 100).round()}%'}' : '正在打开 PDF…', style: TextStyle(fontSize: 12.5, color: ide.textDim)),
        ]),
      );
    }
    final reader = _reader!;
    final searcher = _searcher;
    return Focus(
      onKeyEvent: _onKey,
      child: Column(children: [
        _toolbar(ide),
        if (_searching) _searchBar(ide),
        if (_readError != null)
          Container(
            width: double.infinity,
            color: ide.warn.withValues(alpha: 0.16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(children: [
              Expanded(child: Text(_readError is OpError ? (_readError as OpError).message : '$_readError', style: TextStyle(fontSize: 12, color: ide.text))),
              TextButton(onPressed: _reopen, child: const Text('重新打开')),
            ]),
          ),
        Expanded(
          child: Row(children: [
            if (_sidebar) _side(ide),
            Expanded(
              child: _bytes != null
                  ? PdfViewer.data(
                      _bytes!,
                      key: ValueKey(_gen),
                      sourceName: '$_key:${reader.etag ?? ''}:$_gen',
                      passwordProvider: _password,
                      controller: _controller,
                      initialPageNumber: _page,
                      params: _params(ide, searcher),
                    )
                  : PdfViewer.custom(
                      key: ValueKey(_gen),
                      fileSize: reader.size,
                      read: _read,
                      sourceName: '$_key:${reader.etag ?? ''}:$_gen',
                      passwordProvider: _password,
                      controller: _controller,
                      initialPageNumber: _page,
                      params: _params(ide, searcher),
                    ),
            ),
          ]),
        ),
      ]),
    );
  }
}
