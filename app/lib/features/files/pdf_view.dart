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
import 'dart:math' as math;

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../kernel/widgets.dart';
import '../../kernel/input_mode.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'download_action.dart';
import 'pdf_source.dart';
import 'pdf_reader_state.dart';

/// Where the reader stopped, per file, until the app closes.
bool _nightMode = false;

/// Forgets every remembered page and the night-mode choice (tests).
void resetPdfReaderMemory() {
  clearPdfReaderMemory();
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
  const PdfFileViewer({
    super.key,
    required this.ws,
    required this.root,
    required this.path,
    this.opener,
  });

  @override
  State<PdfFileViewer> createState() => _PdfFileViewerState();
}

class _PdfFileViewerState extends State<PdfFileViewer>
    with WidgetsBindingObserver {
  RemoteRangeReader? _reader;
  Uint8List? _bytes; // the whole file, when it was small enough to fetch first
  PdfViewerController _controller = PdfViewerController();
  PdfTextSearchSession? _searcher;
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
  final _viewerFocus = FocusNode();
  PdfPointerMode _pointerMode = PdfPointerMode.select;
  bool _touch = false,
      _trackpad = false,
      _spacePan = false,
      _dragging = false,
      _visible = true,
      _compact = false;
  bool _matchCase = false, _wholeWord = false;
  PdfReaderMemory? _memory;
  final _back = <PdfReadingPlace>[], _forward = <PdfReadingPlace>[];
  final _facingLayout = PdfFacingLayout();
  StreamSubscription<PdfDocumentEvent>? _documentEvents;

  String get _key => 'file:${widget.root}:${widget.path}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_rememberPlace);
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    if (!_visible) {
      _spacePan = false;
      _dragging = false;
    }
    final searcher = _searcher;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(searcher, _searcher)) {
        searcher?.isActive = _visible;
      }
    });
  }

  @override
  void dispose() {
    ++_gen;
    WidgetsBinding.instance.removeObserver(this);
    _closeDocument();
    _pageBox.dispose();
    _pageFocus.dispose();
    _searchBox.dispose();
    _searchFocus.dispose();
    _viewerFocus.dispose();
    _controller.removeListener(_rememberPlace);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && (_spacePan || _dragging)) {
      setState(() {
        _spacePan = false;
        _dragging = false;
      });
    }
  }

  void _closeDocument() {
    _rememberPlace();
    unawaited(_documentEvents?.cancel());
    _documentEvents = null;
    _facingLayout.invalidate();
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
    final generation = _gen;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _gen) setState(f);
    });
  }

  Future<void> _load() async {
    final gen = ++_gen;
    final link = widget.ws.link;
    final opener =
        widget.opener ?? (link == null ? null : linkRangeOpener(link));
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
      _openNodes.clear();
      _back.clear();
      _forward.clear();
      _pages = 0;
      _pwTries = 0;
    });
    final reader = _reader = RemoteRangeReader(
      opener,
      widget.root,
      widget.path,
    );
    try {
      await reader.init();
      if (!mounted || gen != _gen) return;
      if (reader.size > pdfMaxFile) {
        setState(() {
          _loading = false;
          _tooLarge = true;
          _error =
              '文件有 ${formatSize(reader.size)}，超过在线查看的上限（${formatSize(pdfMaxFile)}）。\n下载后在本机用 PDF 阅读器打开。';
        });
        return;
      }
      if (reader.size == 0 ||
          !latin1
              .decode(reader.head(1024), allowInvalid: true)
              .contains('%PDF-')) {
        setState(() {
          _loading = false;
          _error = reader.size == 0
              ? '这是一个空文件。'
              : '这不是有效的 PDF 文件（文件头不对），可能已损坏或扩展名不符。';
        });
        return;
      }
      if (reader.size > pdfChunk && reader.size <= pdfPreloadMax) {
        await reader.preload(
          onProgress: (d, t) {
            if (mounted && gen == _gen && t > 0) {
              setState(() => _progress = d / t);
            }
          },
        );
        if (!mounted || gen != _gen) return;
      }
      // Everything is here: PDFium reads the bytes in memory, so paging and
      // search never wait on the network. Bigger files are read on demand.
      if (reader.complete) _bytes = reader.takeAll();
      _memory = pdfReaderMemory(jsonEncode([widget.ws.serverId, widget.root, widget.path, reader.etag]));
      setState(() {
        _loading = false;
        _page = _memory?.place?.page ?? 1;
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
    _closeDocument();
    _controller.removeListener(_rememberPlace);
    _controller = PdfViewerController();
    _controller.addListener(_rememberPlace);
    unawaited(_load());
  }

  Future<int> _read(
    RemoteRangeReader reader,
    int generation,
    Uint8List b,
    int pos,
    int n,
  ) async {
    try {
      return await reader.read(b, pos, n);
    } on Object catch (e) {
      if (mounted && generation == _gen && identical(reader, _reader)) {
        _readError ??= e;
        _defer(() {});
      }
      rethrow;
    }
  }

  Future<String?> _password(int generation) async {
    if (!mounted || generation != _gen || _pwTries >= 5) return null;
    final again = _pwTries++ > 0;
    final t = await askText(
      context,
      title: again ? '密码不对，再试一次' : '这个 PDF 需要密码',
      hint: '密码',
      ok: '打开',
      obscure: true,
    );
    return (!mounted || generation != _gen || t == null || t.isEmpty)
        ? null
        : t;
  }

  void _status() {
    final t = widget.ws.tab(_key);
    t?.status.value = '$_page / $_pages 页   ${formatSize(_reader?.size ?? 0)}';
  }

  void _onReady(PdfDocument doc, PdfViewerController c) {
    if (!mounted || !identical(c, _controller)) return;
    _doc = doc;
    unawaited(_documentEvents?.cancel());
    _documentEvents = doc.events.listen((_) => _facingLayout.invalidate());
    // a remembered page past the end (the document got shorter) is not a place to start
    if (_page > doc.pages.length) {
      unawaited(
        c.goToPage(pageNumber: doc.pages.length, duration: Duration.zero),
      );
    }
    _searcher?.dispose();
    final s = PdfTextSearchSession(c)..isActive = _visible;
    s.addListener(() {
      if (mounted && identical(_searcher, s)) setState(() {});
    });
    _searcher = s;
    _defer(() {
      _pages = doc.pages.length;
      _page = c.pageNumber ?? _page;
      _ready = true;
      _status();
    });
    final remembered = _memory?.place;
    if (remembered != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_doc, doc)) unawaited(remembered.restore(c));
      });
    }
    unawaited(
      doc.loadOutline().then(
        (o) {
          if (mounted && _doc == doc) setState(() => _outline = o);
        },
        onError: (_) {
          if (mounted && _doc == doc) setState(() => _outline = const []);
        },
      ),
    );
  }

  void _onPage(int? p) {
    if (p == null) return;
    _defer(() {
      _page = p;
      if (!_pageFocus.hasFocus) _pageBox.text = '$p';
      _status();
    });
  }

  // ---- actions ----

  void _rememberPlace() {
    if (_ready && _memory != null) {
      final place = PdfReadingPlace.capture(_controller);
      if (place != null) _memory!.place = place;
    }
  }

  void _rememberJump() {
    final place = PdfReadingPlace.capture(_controller);
    if (place == null) return;
    setState(() {
      _back.add(place);
      if (_back.length > 80) _back.removeAt(0);
      _forward.clear();
    });
  }

  void _history(bool forward) {
    final from = forward ? _forward : _back, to = forward ? _back : _forward;
    if (!_ready || from.isEmpty) return;
    final place = PdfReadingPlace.capture(_controller);
    setState(() {
      if (place != null) to.add(place);
      unawaited(from.removeLast().restore(_controller));
    });
  }

  void _goDest(PdfDest? dest) {
    if (!_ready || dest == null) return;
    _rememberJump();
    if (_compact) setState(() => _sidebar = false);
    unawaited(_controller.goToDest(dest));
  }

  void _bookmark() {
    if (!_ready || _memory == null) return;
    setState(() {
      if (!_memory!.bookmarks.remove(_page)) _memory!.bookmarks.add(_page);
    });
  }

  void _toggleFacing() {
    if (!_ready || _memory == null) return;
    final place = PdfReadingPlace.capture(_controller);
    final controller = _controller;
    setState(() => _memory!.facing = !_memory!.facing);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !identical(controller, _controller) ||
          !_controller.isReady) {
        return;
      }
      _controller.invalidate();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            identical(controller, _controller) &&
            _controller.isReady &&
            place != null) {
          unawaited(
            place.restore(_controller).then((_) {
              if (mounted && identical(controller, _controller) && _ready) {
                _fitWidth();
              }
            }),
          );
        }
      });
    });
  }

  void _pointer(PointerEvent event) {
    final touch =
        event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    final trackpad = event.kind == PointerDeviceKind.trackpad;
    if (_touch != touch || _trackpad != trackpad) {
      setState(() {
        _touch = touch;
        _trackpad = trackpad;
      });
    }
  }

  bool get _hand => _spacePan || _pointerMode == PdfPointerMode.hand;

  void _goPage(int n) {
    if (!_ready || _pages == 0) return;
    _rememberJump();
    if (_compact) setState(() => _sidebar = false);
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
    if (_memory?.facing == true) {
      final size = _controller.viewSize, layout = _controller.layout;
      final zoom = size.width / layout.documentSize.width;
      final page = layout.pageLayouts[(_controller.pageNumber ?? _page) - 1];
      unawaited(
        _controller.goTo(
          _controller.calcMatrixFor(
            Offset(
              layout.documentSize.width / 2,
              page.top + size.height / 2 / zoom - 12,
            ),
            zoom: zoom,
          ),
        ),
      );
      return;
    }
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
      MenuItem(
        '实际大小',
        () => _zoomTo(1),
        icon: Icons.crop_original_rounded,
        hint: '100%',
      ),
      const MenuItem.separator(),
      for (final z in const [0.5, 0.75, 1.25, 1.5, 2.0, 3.0])
        MenuItem('${(z * 100).round()}%', () => _zoomTo(z)),
    ]);
  }

  void _openSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searching) _searchFocus.requestFocus();
    });
    _searchBox.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchBox.text.length,
    );
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
      final text = q.trim();
      final pattern = _wholeWord
          ? RegExp(
              '(?<![\\p{L}\\p{N}_])${RegExp.escape(text)}(?![\\p{L}\\p{N}_])',
              unicode: true,
              caseSensitive: _matchCase,
            )
          : text;
      s.startTextSearch(
        pattern,
        caseInsensitive: !_matchCase,
        searchImmediately: now,
        startPageNumber: _page,
      );
    }
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e.logicalKey == LogicalKeyboardKey.space &&
        e is KeyUpEvent &&
        _spacePan) {
      setState(() => _spacePan = false);
      return KeyEventResult.handled;
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyF) {
      _openSearch();
      return KeyEventResult.handled;
    }
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyG) {
      _pageFocus.requestFocus();
      _pageBox.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _pageBox.text.length,
      );
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && _searching) {
      _closeSearch();
      return KeyEventResult.handled;
    }
    if (_pageFocus.hasFocus || _searchFocus.hasFocus) {
      return KeyEventResult.ignored;
    }
    if (kb.isAltPressed && e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _history(false);
      return KeyEventResult.handled;
    }
    if (kb.isAltPressed && e.logicalKey == LogicalKeyboardKey.arrowRight) {
      _history(true);
      return KeyEventResult.handled;
    }
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyD) {
      _bookmark();
      return KeyEventResult.handled;
    }
    if (!ctrl && !kb.isAltPressed && e.logicalKey == LogicalKeyboardKey.space) {
      setState(() => _spacePan = true);
      return KeyEventResult.handled;
    }
    if (!ctrl &&
        !kb.isAltPressed &&
        (e.logicalKey == LogicalKeyboardKey.keyH ||
            e.logicalKey == LogicalKeyboardKey.keyV)) {
      setState(
        () => _pointerMode = e.logicalKey == LogicalKeyboardKey.keyH
            ? PdfPointerMode.hand
            : PdfPointerMode.select,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- build ----

  Widget _centered(
    Ide ide, {
    required IconData icon,
    required String text,
    List<Widget> actions = const [],
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 30, color: ide.textDim),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: ide.textDim, height: 1.5),
          ),
          const SizedBox(height: 12),
          Row(mainAxisSize: MainAxisSize.min, children: actions),
        ],
      ),
    ),
  );

  void _download() => downloadRemoteFile(
    widget.ws,
    root: widget.root,
    path: widget.path,
    size: _reader?.size ?? 0,
  );

  Widget _toolbar(Ide ide) {
    final touch = _touch || InputMode.isTouch(context);
    final height = touch ? 44.0 : 32.0;
    Widget zoomLabel() => Builder(
      builder: (ctx) => InkWell(
        key: const ValueKey('pdf-zoom'),
        onTap: _ready ? () => _zoomMenu(ctx) : null,
        borderRadius: BorderRadius.circular(Radii.s),
        child: SizedBox(
          width: 58,
          height: height,
          child: Center(
            child: _ready
                ? AnimatedBuilder(
                    animation: _controller,
                    builder: (_, _) => Text(
                      '${(_controller.currentZoom * 100).round()}%',
                      style: TextStyle(fontSize: 12, color: ide.text),
                    ),
                  )
                : Text(
                    '—',
                    style: TextStyle(fontSize: 12, color: ide.textFaint),
                  ),
          ),
        ),
      ),
    );
    return Container(
      height: height + 8,
      color: ide.tabBar,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  IconBtn(
                    Icons.view_sidebar_outlined,
                    _sidebar ? '收起目录和缩略图' : '目录和缩略图',
                    () => setState(() => _sidebar = !_sidebar),
                    color: _sidebar ? ide.accent : null,
                  ),
                  IconBtn(
                    Icons.arrow_back_rounded,
                    '返回上一阅读位置（Alt+←）',
                    _back.isEmpty ? null : () => _history(false),
                  ),
                  IconBtn(
                    Icons.arrow_forward_rounded,
                    '前进阅读位置（Alt+→）',
                    _forward.isEmpty ? null : () => _history(true),
                  ),
                  const SizedBox(width: 4),
                  IconBtn(
                    Icons.keyboard_arrow_up_rounded,
                    '上一页',
                    _ready && _page > 1 ? () => _goPage(_page - 1) : null,
                    size: 20,
                  ),
                  SizedBox(
                    width: 40,
                    height: touch ? 40 : 26,
                    child: TextField(
                      key: const ValueKey('pdf-page'),
                      controller: _pageBox,
                      focusNode: _pageFocus,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      style: TextStyle(fontSize: 12.5, color: ide.text),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 4),
                      ),
                      onSubmitted: _submitPage,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      '/ ${_pages == 0 ? '—' : _pages}',
                      style: TextStyle(fontSize: 12.5, color: ide.textDim),
                    ),
                  ),
                  IconBtn(
                    Icons.keyboard_arrow_down_rounded,
                    '下一页',
                    _ready && _page < _pages ? () => _goPage(_page + 1) : null,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  IconBtn(
                    Icons.remove_rounded,
                    '缩小',
                    _ready ? () => unawaited(_controller.zoomDown()) : null,
                  ),
                  zoomLabel(),
                  IconBtn(
                    Icons.add_rounded,
                    '放大',
                    _ready ? () => unawaited(_controller.zoomUp()) : null,
                  ),
                  const SizedBox(width: 12),
                  IconBtn(
                    Icons.search_rounded,
                    '搜索（Ctrl+F）',
                    _ready ? _openSearch : null,
                    color: _searching ? ide.accent : null,
                  ),
                  const SizedBox(width: 8),
                  _modeButton(
                    ide,
                    PdfPointerMode.select,
                    Icons.text_fields_rounded,
                    '文字选择（V）',
                    height,
                  ),
                  _modeButton(
                    ide,
                    PdfPointerMode.hand,
                    Icons.pan_tool_outlined,
                    '手形拖动（H）',
                    height,
                  ),
                ],
              ),
            ),
          ),
          WorkbenchMenuButton<String>(
            key: const ValueKey('pdf-reader-menu'),
            tooltip: '阅读选项',
            onSelected: (value) {
              if (value == 'select' || value == 'hand') {
                setState(() {
                  _pointerMode = value == 'hand'
                      ? PdfPointerMode.hand
                      : PdfPointerMode.select;
                  _spacePan = false;
                });
              }
              if (value == 'facing') _toggleFacing();
              if (value == 'bookmark') _bookmark();
              if (value == 'marks') {
                setState(() {
                  _sidebar = true;
                  _sideTab = 2;
                });
              }
              if (value == 'night') setState(() => _nightMode = !_nightMode);
              if (value == 'download') _download();
              if (value == 'fit-width') _fitWidth();
              if (value == 'fit-page') _fitPage();
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'select',
                checked: !_hand,
                child: const Text('文字选择（V）'),
              ),
              CheckedPopupMenuItem(
                value: 'hand',
                checked: _hand,
                child: const Text('手形拖动（H）'),
              ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                value: 'facing',
                checked: _memory?.facing == true,
                enabled: _ready,
                child: const Text('双页阅读 · 封面独立'),
              ),
              CheckedPopupMenuItem(
                value: 'bookmark',
                checked: _memory?.bookmarks.contains(_page) == true,
                enabled: _ready,
                child: const Text('标记当前页（Ctrl+D）'),
              ),
              const PopupMenuItem(value: 'marks', child: Text('阅读标记 · 本次会话')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'fit-width', child: Text('适合宽度')),
              const PopupMenuItem(value: 'fit-page', child: Text('适合整页')),
              CheckedPopupMenuItem(
                value: 'night',
                checked: _nightMode,
                child: const Text('夜间模式（页面反色）'),
              ),
              const PopupMenuItem(value: 'download', child: Text('下载')),
            ],
            icon: const Icon(Icons.more_horiz, size: 19),
          ),
        ],
      ),
    );
  }

  Widget _modeButton(
    Ide ide,
    PdfPointerMode mode,
    IconData icon,
    String label,
    double height,
  ) {
    final selected = mode == PdfPointerMode.hand ? _hand : !_hand;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message:
            '$label\n鼠标：滚轮滚动 · Ctrl+滚轮缩放 · 按住空格临时拖动\n触屏：单指拖动 · 双指缩放 · 长按选字',
        child: InkWell(
          key: ValueKey('pdf-mode-${mode.name}'),
          onTap: () => setState(() {
            _pointerMode = mode;
            _spacePan = false;
          }),
          borderRadius: BorderRadius.circular(5),
          child: Container(
            width: height + 2,
            height: height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? ide.accentSoft : null,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(
              icon,
              size: 17,
              color: selected ? ide.accent : ide.textDim,
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchBar(Ide ide) {
    final s = _searcher;
    final hasQuery = _searchBox.text.trim().isNotEmpty;
    String info = '';
    if (s != null && hasQuery) {
      if (s.matches.isNotEmpty) {
        info =
            '${(s.currentIndex ?? 0) + 1} / ${s.matches.length}${s.isSearching ? '+' : ''}';
      } else {
        info = s.isSearching ? '搜索中…' : '没有结果';
      }
    }
    return Container(
      color: ide.sideBar,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 16, color: ide.textFaint),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    key: const ValueKey('pdf-search'),
                    controller: _searchBox,
                    focusNode: _searchFocus,
                    style: TextStyle(fontSize: 12.5, color: ide.text),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '在文档中查找',
                      border: InputBorder.none,
                    ),
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
                Text(
                  info,
                  key: const ValueKey('pdf-search-info'),
                  style: TextStyle(fontSize: 12, color: ide.textDim),
                ),
                IconBtn(
                  Icons.keyboard_arrow_up_rounded,
                  '上一个',
                  s != null && s.matches.isNotEmpty
                      ? () => unawaited(s.goToPrevMatch())
                      : null,
                  size: 20,
                ),
                IconBtn(
                  Icons.keyboard_arrow_down_rounded,
                  '下一个',
                  s != null && s.matches.isNotEmpty
                      ? () => unawaited(s.goToNextMatch())
                      : null,
                  size: 20,
                ),
                IconBtn(Icons.close_rounded, '关闭搜索（Esc）', _closeSearch),
              ],
            ),
          ),
          Row(
            children: [
              FilterChip(
                label: const Text('区分大小写', style: TextStyle(fontSize: 11)),
                selected: _matchCase,
                onSelected: (value) {
                  setState(() => _matchCase = value);
                  _search(_searchBox.text, now: true);
                },
              ),
              const SizedBox(width: 6),
              FilterChip(
                label: const Text('全词匹配', style: TextStyle(fontSize: 11)),
                selected: _wholeWord,
                onSelected: (value) {
                  setState(() => _wholeWord = value);
                  _search(_searchBox.text, now: true);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Iterable<(PdfOutlineNode, int)> _flat(
    List<PdfOutlineNode> nodes,
    int depth,
  ) sync* {
    for (final n in nodes) {
      yield (n, depth);
      if (_openNodes.contains(n)) yield* _flat(n.children, depth + 1);
    }
  }

  Widget _outlineList(Ide ide) {
    final o = _outline;
    if (o == null) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 1.8),
        ),
      );
    }
    if (o.isEmpty) {
      return Center(
        child: Text(
          '这个 PDF 没有目录',
          style: TextStyle(fontSize: 12.5, color: ide.textDim),
        ),
      );
    }
    final rows = _flat(o, 0).toList();
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final (n, depth) = rows[i];
        final open = _openNodes.contains(n);
        return InkWell(
          key: ValueKey('pdf-outline-$i'),
          onTap: n.dest == null ? null : () => _goDest(n.dest),
          child: Padding(
            padding: EdgeInsets.fromLTRB(4 + depth * 14.0, 5, 8, 5),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: n.children.isEmpty
                      ? null
                      : InkWell(
                          onTap: () => setState(
                            () =>
                                open ? _openNodes.remove(n) : _openNodes.add(n),
                          ),
                          child: Icon(
                            open ? Icons.expand_more : Icons.chevron_right,
                            size: 16,
                            color: ide.textDim,
                          ),
                        ),
                ),
                Expanded(
                  child: Text(
                    n.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: ide.text,
                      height: 1.3,
                    ),
                  ),
                ),
                if (n.dest != null)
                  Text(
                    '${n.dest!.pageNumber}',
                    style: TextStyle(fontSize: 11, color: ide.textFaint),
                  ),
              ],
            ),
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
            child: Column(
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: cur ? ide.accent : ide.border,
                        width: cur ? 2 : 1,
                      ),
                    ),
                    child: ColorFiltered(
                      colorFilter: _nightMode
                          ? _invert
                          : const ColorFilter.mode(
                              Colors.transparent,
                              BlendMode.dst,
                            ),
                      child: PdfPageView(
                        document: doc,
                        pageNumber: n,
                        maximumDpi: 72,
                        decoration: const BoxDecoration(color: Colors.white),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    '$n',
                    style: TextStyle(
                      fontSize: 11,
                      color: cur ? ide.accent : ide.textDim,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _side(Ide ide) => Container(
    width: 248,
    decoration: BoxDecoration(
      color: ide.sideBar,
      border: Border(right: BorderSide(color: ide.border)),
    ),
    child: Column(
      children: [
        SizedBox(
          height: 32,
          child: Row(
            children: [
              for (final (i, label) in const [(0, '目录'), (1, '缩略图'), (2, '标记')])
                Expanded(
                  child: InkWell(
                    key: ValueKey('pdf-side-$i'),
                    onTap: () => setState(() => _sideTab = i),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _sideTab == i
                                ? ide.accent
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: _sideTab == i ? ide.text : ide.textDim,
                          fontWeight: _sideTab == i
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: ide.border),
        Expanded(
          child: switch (_sideTab) {
            0 => _outlineList(ide),
            1 => _thumbnails(ide),
            _ => _bookmarks(ide),
          },
        ),
      ],
    ),
  );

  Widget _bookmarks(Ide ide) {
    final pages = (_memory?.bookmarks.toList() ?? <int>[])..sort();
    return Column(
      children: [
        TextButton.icon(
          onPressed: _ready ? _bookmark : null,
          icon: const Icon(Icons.bookmark_add_outlined, size: 16),
          label: const Text('标记当前页'),
        ),
        Text('本次会话内保留', style: TextStyle(fontSize: 11, color: ide.textFaint)),
        Expanded(
          child: pages.isEmpty
              ? Center(
                  child: Text('还没有阅读标记', style: TextStyle(color: ide.textDim)),
                )
              : ListView.builder(
                  itemCount: pages.length,
                  itemBuilder: (_, index) => Material(
                    color: ide.sideBar,
                    child: ListTile(
                      key: ValueKey('pdf-bookmark-${pages[index]}'),
                      dense: true,
                      leading: Icon(
                        Icons.bookmark,
                        size: 16,
                        color: ide.accent,
                      ),
                      title: Text('第 ${pages[index]} 页'),
                      onTap: () => _goPage(pages[index]),
                      trailing: IconButton(
                        tooltip: '移除标记',
                        icon: const Icon(Icons.close, size: 15),
                        onPressed: () => setState(
                          () => _memory!.bookmarks.remove(pages[index]),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _errorBanner(Ide ide, Object error) {
    final text = error is PdfPasswordException
        ? '需要密码，或者密码不对。'
        : (error is RemoteChanged ? error.toString() : '无法打开这个 PDF：$error');
    return _centered(
      ide,
      icon: Icons.picture_as_pdf_outlined,
      text: text,
      actions: [
        OutlinedButton(
          onPressed: _reopen,
          child: Text(error is PdfPasswordException ? '输入密码' : '重试'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: _download, child: const Text('下载')),
      ],
    );
  }

  PdfViewerParams _params(Ide ide, PdfTextSearchSession? searcher) {
    final generation = _gen;
    final controller = _controller;
    return PdfViewerParams(
      isVisible: _visible,
      backgroundColor: ide.sideBar,
      margin: 12,
      pageDropShadow: BoxShadow(
        color: ide.shadow.withValues(alpha: .16),
        blurRadius: 3,
        offset: const Offset(0, 1),
      ),
      layoutPages: _memory?.facing == true ? _facingLayout.call : null,
      panEnabled: _hand || _touch || _trackpad,
      textSelectionParams: PdfTextSelectionParams(
        enabled: !_hand || _touch,
        // Also changes equality when switching mouse modes (pdfrx omits
        // `enabled` from PdfTextSelectionParams equality).
        enableSelectionHandles: _touch || _hand || _trackpad,
      ),
      scrollByMouseWheel: 1,
      scaleInertiaMaxExcursion: .12,
      pageImageColorFilter: _nightMode ? _invert : null,
      onViewerReady: _onReady,
      onPageChanged: (page) {
        if (mounted && generation == _gen) _onPage(page);
      },
      keyHandlerParams: PdfViewerKeyHandlerParams(focusNode: _viewerFocus),
      onKey: (_, key, _) {
        final keyboard = HardwareKeyboard.instance;
        final control = keyboard.isControlPressed || keyboard.isMetaPressed;
        if (key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.keyH ||
            key == LogicalKeyboardKey.keyV ||
            (control &&
                {
                  LogicalKeyboardKey.keyF,
                  LogicalKeyboardKey.keyG,
                  LogicalKeyboardKey.keyD,
                }.contains(key)) ||
            (keyboard.isAltPressed &&
                {
                  LogicalKeyboardKey.arrowLeft,
                  LogicalKeyboardKey.arrowRight,
                }.contains(key))) {
          return false;
        }
        return null;
      },
      pagePaintCallbacks: [
        if (searcher != null) searcher.pageTextMatchPaintCallback,
      ],
      linkHandlerParams: PdfLinkHandlerParams(
        onLinkTap: (link) {
          if (link.dest != null) {
            _goDest(link.dest);
          } else if (link.url != null) {
            copyText(link.url.toString(), what: '链接已复制（不会自动打开）');
          }
        },
      ),
      viewerOverlayBuilder: (context, size, handleLinkTap) => [
        PdfViewerScrollThumb(
          controller: controller,
          orientation: ScrollbarOrientation.right,
        ),
      ],
      errorBannerBuilder: (context, error, stack, ref) =>
          _errorBanner(ide, error),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_error != null) {
      return _centered(
        ide,
        icon: _tooLarge ? Icons.block : Icons.error_outline,
        text: _error!,
        actions: [
          if (!_tooLarge)
            OutlinedButton(onPressed: _reopen, child: const Text('重试')),
          if (!_tooLarge) const SizedBox(width: 8),
          OutlinedButton(onPressed: _download, child: const Text('下载')),
        ],
      );
    }
    if (_loading || _reader == null) {
      final r = _reader;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 180,
              child: LinearProgressIndicator(value: _progress),
            ),
            const SizedBox(height: 10),
            Text(
              r != null && r.size > 0
                  ? '正在打开 PDF（${formatSize(r.size)}）${_progress == null ? '' : ' ${(_progress! * 100).round()}%'}'
                  : '正在打开 PDF…',
              style: TextStyle(fontSize: 12.5, color: ide.textDim),
            ),
          ],
        ),
      );
    }
    final reader = _reader!;
    final generation = _gen;
    final searcher = _searcher;
    return Focus(
      onKeyEvent: _onKey,
      onFocusChange: (focused) {
        if (!focused && _spacePan) setState(() => _spacePan = false);
      },
      child: Column(
        children: [
          _toolbar(ide),
          if (_searching) _searchBar(ide),
          if (_readError != null)
            Container(
              width: double.infinity,
              color: ide.warn.withValues(alpha: 0.16),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _readError is OpError
                          ? (_readError as OpError).message
                          : '$_readError',
                      style: TextStyle(fontSize: 12, color: ide.text),
                    ),
                  ),
                  TextButton(onPressed: _reopen, child: const Text('重新打开')),
                ],
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (_, box) {
                _compact = box.maxWidth < 640;
                final viewer = MouseRegion(
                  cursor: _hand
                      ? (_dragging
                            ? SystemMouseCursors.grabbing
                            : SystemMouseCursors.grab)
                      : MouseCursor.defer,
                  onHover: _pointer,
                  child: Listener(
                    key: const ValueKey('pdf-reading-surface'),
                    onPointerDown: (event) {
                      _pointer(event);
                      _viewerFocus.requestFocus();
                      if (_hand) setState(() => _dragging = true);
                    },
                    onPointerUp: (_) {
                      if (_dragging) setState(() => _dragging = false);
                    },
                    onPointerCancel: (_) {
                      if (_dragging) setState(() => _dragging = false);
                    },
                    onPointerSignal: _pointer,
                    onPointerPanZoomStart: _pointer,
                    child: _bytes != null
                        ? PdfViewer.data(
                            _bytes!,
                            key: ValueKey(_gen),
                            sourceName: jsonEncode([widget.ws.serverId, widget.root, widget.path, reader.etag, generation]),
                            passwordProvider: () => _password(generation),
                            controller: _controller,
                            initialPageNumber: _page,
                            params: _params(ide, searcher),
                          )
                        : PdfViewer.custom(
                            key: ValueKey(_gen),
                            fileSize: reader.size,
                            read: (buffer, position, size) => _read(
                              reader,
                              generation,
                              buffer,
                              position,
                              size,
                            ),
                            sourceName: jsonEncode([widget.ws.serverId, widget.root, widget.path, reader.etag, generation]),
                            passwordProvider: () => _password(generation),
                            controller: _controller,
                            initialPageNumber: _page,
                            params: _params(ide, searcher),
                          ),
                  ),
                );
                return Stack(
                  children: [
                    Row(
                      children: [
                        if (_sidebar && !_compact) _side(ide),
                        Expanded(child: viewer),
                      ],
                    ),
                    if (_sidebar && _compact) ...[
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: () => setState(() => _sidebar = false),
                          child: ColoredBox(
                            color: Colors.black.withValues(alpha: .15),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: math.min(248, box.maxWidth * .85),
                        child: _side(ide),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
