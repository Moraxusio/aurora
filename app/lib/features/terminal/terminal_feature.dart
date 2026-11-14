// Terminals (service "terminal"): the server's tmux sessions are listed in the
// bottom panel, and each one has its own retained terminal viewport. The
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
import '../../kernel/visible_polling.dart';
import '../../kernel/widgets.dart';
import '../../kernel/workspace.dart';
import '../../theme/ide_theme.dart';
import 'terminal_colors.dart';

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
  SideBarView? sideBar(BuildContext context, Workspace ws) => null;

  @override
  void open(Workspace ws) => ws.showTerminalPanel();

  @override
  List<Command> commands(Workspace ws) => [
    Command(id: 'terminal.new', title: '新建终端会话…', group: '终端', icon: Icons.add, shortcut: 'Ctrl+Shift+`', run: () => createSession(ws)),
  ];
}

/// Opens a session in the bottom panel without replacing the editor selection.
void openSession(Workspace ws, String name) {
  ws.openTab(
    EditorTab(
      id: 'term:$name',
      area: TabArea.terminal,
      title: name,
      icon: Icons.terminal,
      tooltip: ws.entry?.isLocal == true ? '本地 PowerShell · $name（退出客户端后结束）' : 'tmux 会话 $name',
      builder: (_) => SessionView(key: ValueKey('${ws.serverId}/$name'), ws: ws, session: name),
    ),
  );
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
  // The proxy box is offered only when this agent has the proxy service on and
  // a node is chosen (D-47): a box that can only fail would be a trap.
  final r = await showDialog<NewSession>(
    context: ctx,
    builder: (_) => NewSessionDialog(initial: suggest, proxy: proxyOffer(ws)),
  );
  if (r == null || r.name.isEmpty) return null;
  final name = r.name;
  if (!_nameRe.hasMatch(name)) {
    ws.toast('会话名只能用字母、数字、点、下划线、连字符', error: true);
    return null;
  }
  final folder = ws.project?.folders.firstOrNull;
  final res = await ws.guard(() => link.call('session.create', {'name': name, if (r.proxy) 'proxy': true, if (folder != null) 'root': folder.root, if (folder != null) 'path': folder.path}));
  if (res == null) return null;
  // A name that was already a session is opened as it is (D-48): say that it
  // was not given the proxy the box asked for, instead of letting the user think so.
  if (r.proxy && (res as Map)['existed'] == true && res['proxy'] != true) {
    ws.toast('会话“$name”早就有了，已打开；它启动时没有代理，不会因为这次勾选而改变', error: true);
  }
  openSession(ws, name);
  return name;
}

/// What the new-session dialog may offer about the proxy.
class ProxyOffer {
  /// Null when the box can be ticked; otherwise why it cannot.
  final String? unavailable;
  final String? nodeName;
  const ProxyOffer.available(this.nodeName) : unavailable = null;
  const ProxyOffer.unavailable(String this.unavailable) : nodeName = null;
  bool get available => unavailable == null;
}

ProxyOffer proxyOffer(Workspace ws) {
  if (ws.entry?.isLocal == true) return const ProxyOffer.unavailable('本地终端自动继承当前用户的环境代理 / Windows 手动系统代理');
  final s = ws.serviceInfo('proxy');
  if (s == null) return const ProxyOffer.unavailable('这台服务器的 agent 没有代理功能');
  if (s['enabled'] != true) return const ProxyOffer.unavailable('代理服务是关闭的：在“代理”页打开它');
  final ops = ((s['ops'] as List?) ?? const []).cast<String>();
  if (!ops.contains('proxy.set')) return const ProxyOffer.unavailable('agent 版本较旧，没有代理功能');
  final c = ws.entry?.proxy;
  if (c == null) return const ProxyOffer.unavailable('还没有选节点：在“代理”页选一个');
  if (c.pending) return const ProxyOffer.unavailable('节点参数待同步：请先在“代理”页同步成功');
  return ProxyOffer.available(c.name);
}

class NewSession {
  final String name;
  final bool proxy;
  NewSession(this.name, this.proxy);
}

class NewSessionDialog extends StatefulWidget {
  final String initial;
  final ProxyOffer proxy;
  const NewSessionDialog({super.key, required this.initial, required this.proxy});
  @override
  State<NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<NewSessionDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.initial);
  bool _proxy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _ok() => Navigator.pop(context, NewSession(_name.text.trim(), _proxy && widget.proxy.available));

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final p = widget.proxy;
    return AlertDialog(
      title: const Text('新建终端会话'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(hintText: '字母、数字、点、下划线、连字符'),
              onSubmitted: (_) => _ok(),
            ),
            const SizedBox(height: 10),
            CheckboxListTile(
              key: const ValueKey('session-proxy'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: _proxy && p.available,
              onChanged: p.available ? (v) => setState(() => _proxy = v ?? false) : null,
              title: const Text('这个会话走代理'),
              subtitle: Text(p.available ? '用“${p.nodeName}”。会话开始时就定下来，之后不能改。' : p.unavailable!, style: TextStyle(fontSize: 11.5, color: ide.textDim)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消', style: TextStyle(color: ide.textDim)),
        ),
        FilledButton(onPressed: _ok, child: const Text('创建')),
      ],
    );
  }
}

class SessionList extends StatefulWidget {
  final Workspace ws;
  final bool compact;
  final VoidCallback? onOpened;
  const SessionList({super.key, required this.ws, this.compact = false, this.onOpened});
  @override
  State<SessionList> createState() => _SessionListState();
}

class _SessionListState extends State<SessionList> with VisiblePolling<SessionList> {
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;
  String? _error;
  String? _active;
  int _loadGeneration = 0;
  final Set<String> _ending = {};

  Workspace get ws => widget.ws;

  @override
  Duration get pollEvery => const Duration(seconds: 5);

  @override
  void poll() => _load(quiet: true);

  @override
  void initState() {
    super.initState();
    _active = ws.terminalActiveId;
    ws.addListener(_selectionChanged);
    _load();
  }

  void _selectionChanged() {
    if (_active == ws.terminalActiveId) return;
    setState(() => _active = ws.terminalActiveId);
  }

  @override
  void dispose() {
    ws.removeListener(_selectionChanged);
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final link = ws.link;
    if (link == null) return;
    final generation = ++_loadGeneration;
    final observed = ws.terminalTabs.toSet();
    try {
      final r = await link.call('session.list') as Map;
      final list = [for (final s in r['sessions'] as List) (s as Map).cast<String, dynamic>()];
      if (!mounted || generation != _loadGeneration || !identical(link, ws.link)) return;
      setState(() {
        _sessions = list;
        _error = null;
        _loading = false;
      });
      // a tab whose session no longer exists has nothing to show
      final names = {for (final s in list) s['name'] as String};
      ws.dropTabs((t) => observed.contains(t) && t.id.startsWith('term:') && !names.contains(t.id.substring(5)));
    } on w.OpError catch (e) {
      if (mounted && generation == _loadGeneration && identical(link, ws.link) && (!quiet || _loading)) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  Future<void> _kill(String name) async {
    final link = ws.link;
    if (link == null || !_ending.add(name)) return;
    final target = ws.tab('term:$name');
    try {
      final ok = await confirmDialog(context, title: '结束会话 $name？', body: '会话里运行的程序都会被结束。', ok: '结束', danger: true);
      if (!ok || !mounted || !identical(link, ws.link)) return;
      final ended = await ws.guard(() async {
        await link.call('session.kill', {'name': name});
        return true;
      });
      if (ended != true || !mounted || !identical(link, ws.link)) return;
      ws.dropTabs((t) => identical(t, target));
      await _load();
    } finally {
      _ending.remove(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    if (_error != null) return EmptyHint(icon: Icons.error_outline, text: _error!, actionLabel: '重试', onAction: _load);
    return Column(
      children: [
        Container(
          height: InputMode.isTouch(context) ? 44 : 30,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
            children: [
              if (!widget.compact) IconBtn(Icons.add, '新建会话', () async {
                final n = await createSession(ws, context: context);
                if (n != null) _load();
              }),
              if (widget.compact) Padding(padding: const EdgeInsets.only(left: 8), child: Text('会话', style: TextStyle(fontSize: 11, color: ide.textDim))),
              const Spacer(),
              IconBtn(Icons.refresh, '刷新', _load),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: _loading
              ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              : _sessions.isEmpty
              ? EmptyHint(
                  icon: Icons.terminal,
                  text: '还没有会话',
                  actionLabel: '新建会话',
                  onAction: () async {
                    final n = await createSession(ws, context: context);
                    if (n != null) _load();
                  },
                )
              : ListView(
                  children: [
                    for (final s in _sessions)
                      TreeRow(
                        leading: Icon(Icons.terminal, size: 14, color: (s['attached'] as num? ?? 0) > 0 ? ide.ok : ide.textDim),
                        label: s['name'] as String,
                        detail: '${s['windows'] ?? 1} 个窗口${(s['attached'] as num? ?? 0) > 0 ? ' · 已连接' : ''}',
                        selected: ws.terminalActiveId == 'term:${s['name']}',
                        onTap: () { openSession(ws, s['name'] as String); widget.onOpened?.call(); },
                        trailing: IconBtn(Icons.close, '结束会话', () => _kill(s['name'] as String)),
                        menu: () => [
                          MenuItem('打开', () { openSession(ws, s['name'] as String); widget.onOpened?.call(); }, icon: Icons.open_in_new),
                          MenuItem('复制会话名', () => copyText(s['name'] as String), icon: Icons.copy),
                          const MenuItem.separator(),
                          MenuItem('结束会话…', () => _kill(s['name'] as String), icon: Icons.close, danger: true),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
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
    ws.app.appearance.addListener(_onAppearance);
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

  double? _fontSize;
  void _onAppearance() {
    final size = ws.app.appearance.value.terminalFont;
    if (mounted && size != _fontSize && TickerMode.valuesOf(context).enabled) setState(() => _fontSize = size);
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
      if (_wantsFocus) _focus.requestFocus();
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
    ws.app.appearance.removeListener(_onAppearance);
    _out?.cancel();
    _t?.close();
    if (ws.entry?.isLocal == true && ws.link != null) unawaited(ws.link!.call('session.kill', {'name': widget.session}).catchError((Object _) => null));
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
    } else if (_wantsFocus && _t != null && !_focus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && _wantsFocus) _focus.requestFocus();
      });
    }
  }

  bool get _wantsFocus => mounted && ws.terminalFocused && ws.terminalActiveId == 'term:${widget.session}' && TickerMode.valuesOf(context).enabled && (ModalRoute.of(context)?.isCurrent ?? true);

  void _key(TerminalKey k) {
    _term.keyInput(k);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    final touch = InputMode.isTouch(context);
    final theme = terminalTheme(ide);
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
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
                    autofocus: false,
                    theme: theme,
                    textStyle: TerminalStyle(fontSize: _fontSize = ws.app.appearance.value.terminalFont, fontFamily: Ide.mono, fontFamilyFallback: Ide.monoFallback),
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
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                      side: BorderSide(color: ide.border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_t == null && _state.startsWith('正在'))
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                            ),
                          Text(_state),
                          if (_t == null && !_state.startsWith('正在')) TextButton(onPressed: _attach, child: const Text('重新连接')),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (touch) _keyBar(ide),
      ],
    );
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
          decoration: BoxDecoration(
            color: on ? ide.selection : ide.hover,
            borderRadius: BorderRadius.circular(4),
            border: on ? Border.all(color: ide.accent) : null,
          ),
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
      ),
    );
    return Container(
      color: ide.sideBar,
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [
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
        ],
      ),
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
