// Terminal tab: the server's tmux sessions, and one attached terminal
// rendered with package:xterm. A stream that ends because the link dropped
// or the agent restarted attaches again by itself once the link is back
// (D-18); "exit" (the shell ended) and "closed" (service off, D-51) do not.
import 'dart:async';
import 'dart:convert';

import 'package:aurora_wire/aurora_wire.dart' as w;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../state/app_state.dart';

class TerminalTab extends StatefulWidget {
  final AppState app;
  final String id;
  const TerminalTab({super.key, required this.app, required this.id});
  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> {
  List<Map<String, dynamic>> _sessions = [];
  String? _current;
  String? _error;

  w.Link? get _link => widget.app.link(widget.id);

  w.Link? _loadedFor;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_onApp);
    _load();
  }

  @override
  void dispose() {
    widget.app.removeListener(_onApp);
    super.dispose();
  }

  /// A new link (first connect, or after a drop): list the sessions again.
  void _onApp() {
    final l = _link;
    if (l != null && !identical(l, _loadedFor)) _load();
    if (l == null && mounted) setState(() {});
  }

  Future<void> _load() async {
    final l = _link;
    if (l == null) return;
    _loadedFor = l;
    try {
      final r = await l.call('session.list') as Map;
      final list = [for (final s in r['sessions'] as List) (s as Map).cast<String, dynamic>()];
      setState(() {
        _sessions = list;
        _error = null;
        if (_current != null && !list.any((s) => s['name'] == _current)) _current = null;
        _current ??= list.isEmpty ? null : list.first['name'] as String;
      });
    } on w.OpError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _create() async {
    final c = TextEditingController(text: _sessions.isEmpty ? 'main' : 's${_sessions.length + 1}');
    final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('新建会话'),
              content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(helperText: '字母、数字、点、下划线、连字符')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('新建')),
              ],
            ));
    if (name == null || name.isEmpty) return;
    try {
      await _link!.call('session.create', {'name': name});
      _current = name;
      await _load();
    } on w.OpError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _kill(String name) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: Text('结束会话 $name？'),
              content: const Text('会话里运行的程序都会被结束。'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('结束')),
              ],
            ));
    if (ok != true) return;
    try {
      await _link!.call('session.kill', {'name': name});
    } on w.OpError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
    if (_current == name) _current = null;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_link == null && _current == null) return const Center(child: Text('未连接'));
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!), TextButton(onPressed: _load, child: const Text('重试'))]));
    }
    return Column(children: [
      SizedBox(
        height: 44,
        child: Row(children: [
          Expanded(
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (final s in _sessions)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: ChoiceChip(
                    label: Text(s['name'] as String),
                    selected: s['name'] == _current,
                    onSelected: (_) => setState(() => _current = s['name'] as String),
                  ),
                ),
            ]),
          ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: '刷新'),
          IconButton(onPressed: _create, icon: const Icon(Icons.add), tooltip: '新建会话'),
          // Ending a session ends the programs in it, so it is a menu
          // action with a confirmation, not a close button on the tab.
          PopupMenuButton<String>(
            tooltip: '更多',
            enabled: _current != null,
            onSelected: (v) {
              if (v == 'kill' && _current != null) _kill(_current!);
            },
            itemBuilder: (_) => [PopupMenuItem(value: 'kill', child: Text('结束会话 ${_current ?? ''}…'))],
          ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: _current == null
            ? Center(child: FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: const Text('新建会话')))
            : SessionView(key: ValueKey('${widget.id}/$_current'), app: widget.app, id: widget.id, session: _current!, onEnded: _load),
      ),
    ]);
  }
}

/// One attached session.
class SessionView extends StatefulWidget {
  final AppState app;
  final String id;
  final String session;
  final VoidCallback onEnded;
  const SessionView({super.key, required this.app, required this.id, required this.session, required this.onEnded});
  @override
  State<SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends State<SessionView> {
  final _term = Terminal(maxLines: 10000);
  final _controller = TerminalController();
  final _focus = FocusNode();
  w.Terminal? _t;
  StreamSubscription<Uint8List>? _out;
  String _state = '正在连接…';
  bool _disposed = false;
  bool _attaching = false;
  int _cols = 80, _rows = 24;
  final _utf8 = const Utf8Decoder(allowMalformed: true);
  late final ByteConversionSink _decoder;

  @override
  void initState() {
    super.initState();
    // Decodes across chunk boundaries: a multi-byte character split between
    // two frames is not mangled.
    _decoder = _utf8.startChunkedConversion(_StringSink((s) => _term.write(s)));
    _term.onOutput = (data) => _t?.write(utf8.encode(data));
    _term.onResize = (cols, rows, _, _) {
      _cols = cols;
      _rows = rows;
      _t?.resize(cols, rows);
    };
    widget.app.addListener(_onApp);
    // After the first frame the view has its real size, so the attach asks
    // tmux for it at once instead of drawing at 80x24 and redrawing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _attach();
    });
  }

  void _onApp() {
    // The link came back: attach again if we lost the stream.
    if (_t == null && !_attaching && widget.app.link(widget.id) != null && _state.startsWith('连接已断开')) _attach();
  }

  Future<void> _attach() async {
    final link = widget.app.link(widget.id);
    if (link == null || _disposed) return;
    _attaching = true;
    try {
      // The view has laid out by now (its size is the terminal's), unless
      // this runs before the first frame; then onResize sends it later.
      if (_term.viewWidth > 1 && _term.viewHeight > 1) {
        _cols = _term.viewWidth;
        _rows = _term.viewHeight;
      }
      final t = await w.Terminal.attach(link, widget.session, cols: _cols, rows: _rows);
      if (_disposed) {
        await t.close();
        return;
      }
      _t = t;
      // A resize that happened while attaching went nowhere: send the
      // current size once more.
      if (_term.viewWidth > 1 && (_term.viewWidth != _cols || _term.viewHeight != _rows)) {
        _cols = _term.viewWidth;
        _rows = _term.viewHeight;
      }
      unawaited(t.resize(_cols, _rows));
      _out = t.output.listen(_decoder.add);
      setState(() => _state = '');
      _focus.requestFocus();
      final why = await t.done;
      await _out?.cancel();
      _t = null;
      if (_disposed) return;
      switch (why) {
        case w.TerminalEnd.exit:
          setState(() => _state = '会话已结束');
          widget.onEnded();
        case w.TerminalEnd.closed:
          setState(() => _state = t.endReason);
        case w.TerminalEnd.detached:
          // detached (C-d) or the agent restarting: attach again shortly
          setState(() => _state = '连接已断开，正在重新连接…');
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (!_disposed) unawaited(_attach());
        case w.TerminalEnd.lost:
          setState(() => _state = '连接已断开，等待重新连接…');
      }
    } on w.OpError catch (e) {
      if (!_disposed) {
        setState(() => _state = e.code == w.codeNotFound ? '会话已结束' : '无法连接终端：${e.message}');
        if (e.code == w.codeNotFound) widget.onEnded();
      }
    } finally {
      _attaching = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    widget.app.removeListener(_onApp);
    _out?.cancel();
    _t?.close();
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final text = d?.text;
    if (text != null && text.isNotEmpty) _term.paste(text);
  }

  void _copy() {
    final sel = _controller.selection;
    if (sel == null) return;
    Clipboard.setData(ClipboardData(text: _term.buffer.getText(sel)));
    _controller.clearSelection();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A kept-alive tab that is not shown must not hold keyboard focus: xterm
    // would keep reporting a caret position for an offstage view (the cause
    // of a JsonUnsupportedObjectError from the text input channel).
    final visible = TickerMode.valuesOf(context).enabled;
    if (!visible && _focus.hasFocus) {
      _focus.unfocus();
    } else if (visible && _t != null && !_focus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && TickerMode.valuesOf(context).enabled) _focus.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true): _copy,
            const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true): _paste,
          },
          child: TerminalView(
            _term,
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            textStyle: const TerminalStyle(fontSize: 14, fontFamily: 'Cascadia Mono'),
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
            onSecondaryTapDown: (_, _) async {
              if (_controller.selection != null) {
                _copy();
              } else {
                await _paste();
              }
            },
          ),
        ),
      ),
      if (_state.isNotEmpty)
        Positioned(
          right: 12,
          top: 12,
          child: Material(
            color: Theme.of(context).colorScheme.inverseSurface,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_state, style: TextStyle(color: Theme.of(context).colorScheme.onInverseSurface)),
                if (_t == null && !_state.startsWith('正在'))
                  TextButton(onPressed: _attach, child: const Text('重新连接')),
              ]),
            ),
          ),
        ),
    ]);
  }
}

class _StringSink implements Sink<String> {
  final void Function(String) f;
  _StringSink(this.f);
  @override
  void add(String data) => f(data);
  @override
  void close() {}
}
