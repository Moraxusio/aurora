// Terminals (service "terminal"): the server's tmux sessions are listed in the
// side bar, and each one opens as an editor tab with its own terminal. The
// attach logic is the first version's: the view asks tmux for its real size
// at once, a stream that ended because the link dropped or the agent restarted
// attaches again by itself (D-18), "exit" and "closed" (D-51) do not.
//
// Keyboard: xterm's key handling plus Ctrl+Shift+C/V for copy and paste.
// Touch: a bar of the keys a phone keyboard lacks (Esc, Tab, Ctrl, arrows).
import 'dart:async';
import 'dart:convert';

import 'package:aurora_wire/aurora_wire.dart' as w;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/feature.dart';
import '../../kernel/input_mode.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';

class TerminalFeature extends Feature {
  const TerminalFeature();

  @override
  String get id => 'terminal';
  @override
  String get title => '终端';
  @override
  IconData get icon => Icons.terminal;
  @override
  String get service => 'terminal';
  @override
  List<String> get ops => const ['session.list', 'session.create', 'terminal'];

  @override
  SideBarView? sideBar(BuildContext context, Workspace ws) => SideBarView(title: '终端会话', body: SessionList(ws: ws));

  @override
  List<Command> commands(Workspace ws) => [
        Command(id: 'terminal.new', title: '新建终端会话…', group: '终端', icon: Icons.add, shortcut: 'Ctrl+Shift+`', run: () => createSession(ws)),
      ];
}

/// Opens a session as a tab (or brings its tab to the front).
void openSession(Workspace ws, String name) {
  ws.openTab(EditorTab(
    id: 'term:$name',
    title: name,
    icon: Icons.terminal,
    tooltip: 'tmux 会话 $name',
    builder: (_) => SessionView(key: ValueKey('${ws.serverId}/$name'), ws: ws, session: name),
  ));
}

final _nameRe = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

/// Asks for a name, creates the session, opens it. Returns the name or null.
Future<String?> createSession(Workspace ws, {BuildContext? context}) async {
  final ctx = context ?? Toast.key.currentContext;
  final link = ws.link;
  if (link == null) {
    ws.toast('未连接', error: true);
    return null;
  }
  // The next free "sN" is the suggestion.
  var taken = <String>{};
  try {
    final r = await link.call('session.list') as Map;
    taken = {for (final s in r['sessions'] as List) (s as Map)['name'] as String};
  } on w.OpError {
    // the name check below still catches a duplicate on the server
  }
  var suggest = taken.isEmpty ? 'main' : 's${taken.length + 1}';
  for (var i = taken.length + 1; taken.contains(suggest); i++) {
    suggest = 's$i';
  }
  if (ctx == null || !ctx.mounted) return null;
  final name = await askText(ctx, title: '新建终端会话', initial: suggest, hint: '字母、数字、点、下划线、连字符', ok: '创建');
  if (name == null || name.isEmpty) return null;
  if (!_nameRe.hasMatch(name)) {
    ws.toast('会话名只能用字母、数字、点、下划线、连字符', error: true);
    return null;
  }
  final ok = await ws.guard(() => link.call('session.create', {'name': name}));
  if (ok == null) return null;
  openSession(ws, name);
  return name;
}

class SessionList extends StatefulWidget {
  final Workspace ws;
  const SessionList({super.key, required this.ws});
  @override
  State<SessionList> createState() => _SessionListState();
}

class _SessionListState extends State<SessionList> {
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;
  String? _error;
  Timer? _timer;

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final link = ws.link;
    if (link == null) return;
    try {
      final r = await link.call('session.list') as Map;
      final list = [for (final s in r['sessions'] as List) (s as Map).cast<String, dynamic>()];
      if (!mounted) return;
      setState(() {
        _sessions = list;
        _error = null;
        _loading = false;
      });
      // a tab whose session no longer exists has nothing to show
      final names = {for (final s in list) s['name'] as String};
      ws.dropTabs((t) => t.id.startsWith('term:') && !names.contains(t.id.substring(5)));
    } on w.OpError catch (e) {
      if (mounted && !quiet) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  Future<void> _kill(String name) async {
    final ok = await confirmDialog(context, title: '结束会话 $name？', body: '会话里运行的程序都会被结束。', ok: '结束', danger: true);
    if (!ok) return;
    await ws.guard(() => ws.link!.call('session.kill', {'name': name}));
    ws.dropTabs((t) => t.id == 'term:$name');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_error != null) return EmptyHint(icon: Icons.error_outline, text: _error!, actionLabel: '重试', onAction: _load);
    return Column(children: [
      Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(children: [
          IconBtn(Icons.add, '新建会话', () async {
            final n = await createSession(ws, context: context);
            if (n != null) _load();
          }),
          const Spacer(),
          IconBtn(Icons.refresh, '刷新', _load),
        ]),
      ),
      const Divider(),
      Expanded(
        child: _loading
            ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
            : _sessions.isEmpty
                ? EmptyHint(icon: Icons.terminal, text: '还没有会话', actionLabel: '新建会话', onAction: () async {
                    final n = await createSession(ws, context: context);
                    if (n != null) _load();
                  })
                : ListView(children: [
                    for (final s in _sessions)
                      TreeRow(
                        leading: Icon(Icons.terminal, size: 14, color: (s['attached'] as num? ?? 0) > 0 ? ide.ok : ide.textDim),
                        label: s['name'] as String,
                        detail: '${s['windows'] ?? 1} 个窗口${(s['attached'] as num? ?? 0) > 0 ? ' · 已连接' : ''}',
                        selected: ws.activeId == 'term:${s['name']}',
                        onTap: () => openSession(ws, s['name'] as String),
                        trailing: IconBtn(Icons.close, '结束会话', () => _kill(s['name'] as String)),
                        menu: () => [
                          MenuItem('打开', () => openSession(ws, s['name'] as String), icon: Icons.open_in_new),
                          MenuItem('复制会话名', () => copyText(s['name'] as String), icon: Icons.copy),
                          const MenuItem.separator(),
                          MenuItem('结束会话…', () => _kill(s['name'] as String), icon: Icons.close, danger: true),
                        ],
                      ),
                  ]),
      ),
    ]);
  }
}

/// One attached session.
class SessionView extends StatefulWidget {
  final Workspace ws;
  final String session;
  const SessionView({super.key, required this.ws, required this.session});
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
  bool _ctrl = false; // the on-screen Ctrl is armed for the next key
  late final ByteConversionSink _decoder;

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    // Decodes across chunk boundaries: a multi-byte character split between
    // two frames is not mangled.
    _decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_StringSink((s) => _term.write(s)));
    _term.onOutput = (data) {
      if (_ctrl && data.length == 1) {
        final c = data.codeUnitAt(0);
        _ctrl = false;
        if (mounted) setState(() {});
        if (c >= 0x61 && c <= 0x7a) {
          _t?.write([c - 0x60]);
          return;
        }
        if (c >= 0x40 && c <= 0x5f) {
          _t?.write([c & 0x1f]);
          return;
        }
      }
      _t?.write(utf8.encode(data));
    };
    _term.onResize = (cols, rows, _, _) {
      _cols = cols;
      _rows = rows;
      _t?.resize(cols, rows);
    };
    ws.addListener(_onWs);
    // After the first frame the view has its real size, so the attach asks
    // tmux for it at once instead of drawing at 80x24 and redrawing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _attach();
    });
  }

  void _onWs() {
    // The link came back: attach again if we lost the stream.
    if (_t == null && !_attaching && ws.link != null && _state.startsWith('连接已断开')) _attach();
  }

  Future<void> _attach() async {
    final link = ws.link;
    if (link == null || _disposed) return;
    _attaching = true;
    try {
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
          ws.dropTabs((x) => x.id == 'term:${widget.session}');
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
        if (e.code == w.codeNotFound) ws.dropTabs((x) => x.id == 'term:${widget.session}');
      }
    } finally {
      _attaching = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ws.removeListener(_onWs);
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

  void _key(TerminalKey k) {
    _term.keyInput(k);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final touch = InputMode.isTouch(context);
    final theme = TerminalTheme(
      cursor: ide.accent,
      selection: ide.selection,
      foreground: ide.text,
      background: ide.panel,
      black: const Color(0xFF000000),
      red: const Color(0xFFCD3131),
      green: const Color(0xFF0DBC79),
      yellow: const Color(0xFFE5E510),
      blue: const Color(0xFF2472C8),
      magenta: const Color(0xFFBC3FBC),
      cyan: const Color(0xFF11A8CD),
      white: const Color(0xFFE5E5E5),
      brightBlack: const Color(0xFF666666),
      brightRed: const Color(0xFFF14C4C),
      brightGreen: const Color(0xFF23D18B),
      brightYellow: const Color(0xFFF5F543),
      brightBlue: const Color(0xFF3B8EEA),
      brightMagenta: const Color(0xFFD670D6),
      brightCyan: const Color(0xFF29B8DB),
      brightWhite: const Color(0xFFFFFFFF),
      searchHitBackground: const Color(0xFFFFFF2B),
      searchHitBackgroundCurrent: const Color(0xFF31FF26),
      searchHitForeground: const Color(0xFF000000),
    );
    return Column(children: [
      Expanded(
        child: Stack(children: [
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
                theme: theme,
                textStyle: const TerminalStyle(fontSize: 14, fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback),
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
                onSecondaryTapDown: (d, _) {
                  final sel = _controller.selection;
                  showMenuAt(context, d.globalPosition, [
                    MenuItem('复制', sel == null ? null : _copy, icon: Icons.copy, hint: 'Ctrl+Shift+C'),
                    MenuItem('粘贴', _paste, icon: Icons.paste, hint: 'Ctrl+Shift+V'),
                    const MenuItem.separator(),
                    MenuItem('清屏', () => _term.keyInput(TerminalKey.keyL, ctrl: true), icon: Icons.clear_all),
                  ]);
                },
              ),
            ),
          ),
          if (_state.isNotEmpty)
            Positioned(
              right: 12,
              top: 10,
              child: Material(
                color: ide.tabBar,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: BorderSide(color: ide.border)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (_t == null && _state.startsWith('正在')) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))),
                    Text(_state),
                    if (_t == null && !_state.startsWith('正在')) TextButton(onPressed: _attach, child: const Text('重新连接')),
                  ]),
                ),
              ),
            ),
        ]),
      ),
      if (touch) _keyBar(ide),
    ]);
  }

  /// The keys a touch keyboard does not have.
  Widget _keyBar(Ide ide) {
    Widget k(String label, VoidCallback f, {bool on = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: f,
            child: Container(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(color: on ? ide.selection : ide.hover, borderRadius: BorderRadius.circular(4), border: on ? Border.all(color: ide.accent) : null),
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
          ),
        );
    return Container(
      color: ide.sideBar,
      height: 46,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 4), children: [
        k('Esc', () => _key(TerminalKey.escape)),
        k('Tab', () => _key(TerminalKey.tab)),
        k('Ctrl', () => setState(() => _ctrl = !_ctrl), on: _ctrl),
        k('↑', () => _key(TerminalKey.arrowUp)),
        k('↓', () => _key(TerminalKey.arrowDown)),
        k('←', () => _key(TerminalKey.arrowLeft)),
        k('→', () => _key(TerminalKey.arrowRight)),
        k('Home', () => _key(TerminalKey.home)),
        k('End', () => _key(TerminalKey.end)),
        k('PgUp', () => _key(TerminalKey.pageUp)),
        k('PgDn', () => _key(TerminalKey.pageDown)),
        k('粘贴', _paste),
      ]),
    );
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
