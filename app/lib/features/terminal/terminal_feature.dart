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
import 'package:aurora/ui/aurora_ui.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../kernel/editor_tab.dart';
import '../../kernel/feature.dart';
import '../../kernel/input_mode.dart';
import '../../kernel/visible_polling.dart';
import '../../kernel/workspace.dart';
import '../../kernel/workbench_shortcuts.dart';
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
  void open(Workspace ws) => ws.toggleTerminalPanel();

  @override
  List<Command> commands(Workspace ws) => [
    Command(
      id: 'terminal.new',
      title: '新建终端会话…',
      group: '终端',
      icon: Icons.add,
      shortcut: 'Ctrl+Shift+`',
      run: () => createSession(ws),
    ),
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
      tooltip: ws.entry?.isLocal == true
          ? '本地 PowerShell · $name（退出客户端后结束）'
          : 'tmux 会话 $name',
      confirmClose: ws.entry?.isLocal == true
          ? () async {
              final context = AppNavigation.context;
              final link = ws.link;
              return context != null &&
                  await confirmDialog(
                    context,
                    title: '结束本地终端 $name？',
                    body: '会话里运行的程序都会被结束。只想收起输出时，请隐藏终端面板。',
                    ok: '结束终端',
                    danger: true,
                  ) &&
                  identical(link, ws.link);
            }
          : null,
      builder: (_) => SessionView(
        key: ValueKey('${ws.serverId}/$name'),
        ws: ws,
        session: name,
      ),
    ),
  );
}

final _nameRe = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

/// Asks for a name, creates the session, opens it. Returns the name or null.
Future<String?> createSession(Workspace ws, {BuildContext? context}) async {
  final ctx = context ?? AppNavigation.context;
  final link = ws.link;
  if (link == null) {
    ws.toast('未连接', error: true);
    return null;
  }
  // The next free "sN" is the suggestion.
  var taken = <String>{};
  try {
    final r = await link.call('session.list') as Map;
    taken = {
      for (final s in r['sessions'] as List) (s as Map)['name'] as String,
    };
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
  final r = await showWorkbenchDialog<NewSession>(
    context: ctx,
    builder: (_) => NewSessionDialog(
      initial: suggest,
      proxy: proxyOffer(ws),
      local: ws.entry?.isLocal == true,
      networkChoice: ws.hasOp('session.network'),
    ),
  );
  if (r == null || r.name.isEmpty || !identical(link, ws.link)) return null;
  final name = r.name;
  if (!_nameRe.hasMatch(name)) {
    ws.toast('会话名只能用字母、数字、点、下划线、连字符', error: true);
    return null;
  }
  final folder = ws.project?.folders.firstOrNull;
  final res = await ws.guard(
    () => link.call('session.create', {
      'name': name,
      if (r.proxy) 'proxy': true,
      if (r.proxyMode != null) 'proxy_mode': r.proxyMode,
      if (folder != null) 'root': folder.root,
      if (folder != null) 'path': folder.path,
    }),
  );
  if (res == null || !identical(link, ws.link)) return null;
  // A name that was already a session is opened as it is (D-48): say that it
  // was not given the proxy the box asked for, instead of letting the user think so.
  if (r.proxyMode != null &&
      (res as Map)['existed'] == true &&
      res['proxy_mode'] != r.proxyMode) {
    ws.toast('已打开现有会话“$name”；它保留创建时的代理出口');
  } else if (r.proxy &&
      (res as Map)['existed'] == true &&
      res['proxy'] != true) {
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
  final s = ws.serviceInfo('proxy');
  if (s == null) return const ProxyOffer.unavailable('这台服务器的 agent 没有代理功能');
  if (s['enabled'] != true)
    return const ProxyOffer.unavailable('代理服务是关闭的：在“代理”页打开它');
  final ops = ((s['ops'] as List?) ?? const []).cast<String>();
  if (!ops.contains('proxy.set'))
    return const ProxyOffer.unavailable('agent 版本较旧，没有代理功能');
  final c = ws.entry?.proxy;
  if (c == null) return const ProxyOffer.unavailable('还没有选节点：在“代理”页选一个');
  if (c.pending) return const ProxyOffer.unavailable('节点参数待同步：请先在“代理”页同步成功');
  return ProxyOffer.available(c.name);
}

class NewSession {
  final String name;
  final bool proxy;
  final String? proxyMode;
  NewSession(this.name, this.proxy, {this.proxyMode});
}

class NewSessionDialog extends StatefulWidget {
  final String initial;
  final ProxyOffer proxy;
  final bool local, networkChoice;
  const NewSessionDialog({
    super.key,
    required this.initial,
    required this.proxy,
    this.local = false,
    this.networkChoice = false,
  });
  @override
  State<NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<NewSessionDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial,
  );
  bool _proxy = false;
  String _proxyMode = 'system';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _ok() {
    if (!_nameRe.hasMatch(_name.text.trim())) {
      setState(() => _error = '使用 1–64 个字母、数字、点、下划线或连字符');
      return;
    }
    Navigator.pop(
      context,
      NewSession(
        _name.text.trim(),
        !widget.local && _proxy && widget.proxy.available,
        proxyMode: widget.local && widget.networkChoice ? _proxyMode : null,
      ),
    );
  }

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
              decoration: InputDecoration(
                hintText: '字母、数字、点、下划线、连字符',
                errorText: _error,
              ),
              onSubmitted: (_) => _ok(),
            ),
            const SizedBox(height: 10),
            if (widget.local && widget.networkChoice) ...[
              DropdownButtonFormField<String>(
                key: const ValueKey('session-proxy-mode'),
                initialValue: _proxyMode,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '网络出口'),
                items: [
                  const DropdownMenuItem(
                    value: 'system',
                    child: Text(
                      '本机代理（环境 / Windows 系统代理）',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'agent',
                    enabled: p.available,
                    child: Text(
                      'Aurora agent 代理${p.available ? ' · ${p.nodeName}' : '（未就绪）'}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const DropdownMenuItem(
                    value: 'direct',
                    child: Text('直连（不注入代理）'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _proxyMode = v);
                },
              ),
              const SizedBox(height: 8),
              Text(
                p.available
                    ? '出口在创建时确定；Aurora 节点可在代理页切换。'
                    : '${p.unavailable}；本机代理与直连仍可使用。',
                style: TextStyle(fontSize: 11.5, color: ide.textDim),
              ),
            ] else if (widget.local)
              Text(
                '本地终端继承本机代理；升级本地 agent 后可选择出口。',
                style: TextStyle(fontSize: 11.5, color: ide.textDim),
              )
            else
              CheckboxListTile(
                key: const ValueKey('session-proxy'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                value: _proxy && p.available,
                onChanged: p.available
                    ? (v) => setState(() => _proxy = v ?? false)
                    : null,
                title: const Text('这个会话走代理'),
                subtitle: Text(
                  p.available
                      ? '用“${p.nodeName}”。会话开始时就定下来，之后不能改。'
                      : p.unavailable!,
                  style: TextStyle(fontSize: 11.5, color: ide.textDim),
                ),
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
  const SessionList({
    super.key,
    required this.ws,
    this.compact = false,
    this.onOpened,
  });
  @override
  State<SessionList> createState() => _SessionListState();
}

class _SessionListState extends State<SessionList>
    with VisiblePolling<SessionList> {
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;
  String? _error;
  String? _active;
  int _loadGeneration = 0;
  w.Link? _listLink;
  bool _reading = false;
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
    _listLink = ws.link;
    ws.addListener(_selectionChanged);
    _load();
  }

  void _selectionChanged() {
    if (!identical(_listLink, ws.link)) {
      _listLink = ws.link;
      _loadGeneration++;
      _reading = false;
      _sessions = [];
      _load();
    }
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
    if (_reading) return;
    if (link == null) {
      setState(() {
        _loading = false;
        _error = '未连接';
      });
      return;
    }
    _reading = true;
    final generation = ++_loadGeneration;
    final observed = ws.terminalTabs.toSet();
    try {
      final r = await link.call('session.list') as Map;
      final list = [
        for (final s in r['sessions'] as List)
          (s as Map).cast<String, dynamic>(),
      ];
      if (!mounted ||
          generation != _loadGeneration ||
          !identical(link, ws.link))
        return;
      setState(() {
        _sessions = list;
        _error = null;
        _loading = false;
      });
      // a tab whose session no longer exists has nothing to show
      final names = {for (final s in list) s['name'] as String};
      ws.dropTabs(
        (t) =>
            observed.contains(t) &&
            t.id.startsWith('term:') &&
            !names.contains(t.id.substring(5)),
      );
    } on Object catch (e) {
      if (mounted &&
          generation == _loadGeneration &&
          identical(link, ws.link) &&
          (!quiet || _loading)) {
        setState(() {
          _error = e is w.OpError ? e.message : '$e';
          _loading = false;
        });
      }
    } finally {
      if (generation == _loadGeneration) _reading = false;
    }
  }

  Future<void> _kill(String name) async {
    final link = ws.link;
    if (link == null || !_ending.add(name)) return;
    final target = ws.tab('term:$name');
    try {
      final ok = await confirmDialog(
        context,
        title: '结束会话 $name？',
        body: '会话里运行的程序都会被结束。',
        ok: '结束',
        danger: true,
      );
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
    if (_error != null)
      return EmptyHint(
        icon: Icons.error_outline,
        text: _error!,
        actionLabel: '重试',
        onAction: _load,
      );
    if (_loading)
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    if (_sessions.isEmpty) {
      return EmptyHint(
        icon: Icons.terminal_rounded,
        text: widget.compact ? '没有运行中的会话，可从工具栏新建终端' : '还没有会话',
        actionLabel: widget.compact ? null : '新建会话',
        onAction: widget.compact
            ? null
            : () async {
                if (await createSession(ws, context: context) != null) _load();
              },
      );
    }
    final touch = InputMode.isTouch(context);
    final extent = InputMode.row(context) + 4;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, Space.xs, Space.s, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '可用会话  ${_sessions.length}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: ide.textDim,
                  ),
                ),
              ),
              if (!widget.compact)
                IconBtn(Icons.add, '新建会话', () async {
                  if (await createSession(ws, context: context) != null)
                    _load();
                }),
              IconBtn(Icons.refresh_rounded, '刷新会话', _load, size: 14),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(
              Space.s,
              Space.xs,
              Space.s,
              Space.s,
            ),
            itemCount: _sessions.length,
            itemExtent: extent,
            itemBuilder: (_, index) {
              final s = _sessions[index];
              final name = s['name'] as String;
              final attached = (s['attached'] as num? ?? 0) > 0;
              final mode = const {
                'system': '本机代理',
                'agent': 'Aurora 代理',
                'direct': '直连',
              }[s['proxy_mode']];
              void open() {
                openSession(ws, name);
                widget.onOpened?.call();
              }

              return Padding(
                key: ValueKey('terminal-session-$name'),
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: ClipRRect(
                  borderRadius: UiMetrics.controlCorners,
                  child: TreeRow(
                    leading: Tooltip(
                      message: attached ? '已连接' : '可重新连接',
                      child: Icon(
                        Icons.terminal_rounded,
                        size: 15,
                        color: attached ? ide.ok : ide.textDim,
                      ),
                    ),
                    label: name,
                    detail: mode ?? '${s['windows'] ?? 1} 个窗口',
                    selected: _active == 'term:$name',
                    onTap: open,
                    trailing: SizedBox(
                      width: touch ? UiMetrics.touchRow : UiMetrics.compactRow,
                      child: WorkbenchMenuButton<String>(
                        tooltip: '会话操作 · $name',
                        icon: Icon(
                          Icons.more_horiz_rounded,
                          size: 15,
                          color: ide.textDim,
                        ),
                        onSelected: (action) {
                          if (action == 'copy') copyText(name);
                          if (action == 'end') _kill(name);
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'copy',
                            child: MenuLabel(
                              '复制会话名',
                              icon: Icons.copy_outlined,
                            ),
                          ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'end',
                            child: MenuLabel(
                              '结束会话…',
                              icon: Icons.stop_circle_outlined,
                              danger: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                    menu: () => [
                      MenuItem('打开', open, icon: Icons.open_in_new),
                      MenuItem(
                        '复制会话名',
                        () => copyText(name),
                        icon: Icons.copy_outlined,
                      ),
                      const MenuItem.separator(),
                      MenuItem(
                        '结束会话…',
                        () => _kill(name),
                        icon: Icons.stop_circle_outlined,
                        danger: true,
                      ),
                    ],
                  ),
                ),
              );
            },
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
  final _scroll = ScrollController();
  final _readingHistory = ValueNotifier(false);
  bool _tailCheckScheduled = false;
  w.Terminal? _t;
  StreamSubscription<Uint8List>? _out;
  String _state = '正在连接…';
  bool _disposed = false;
  bool _attaching = false;
  int _attachGeneration = 0;
  w.Link? _streamLink;
  Timer? _retry;
  int _cols = 80, _rows = 24;
  bool _ctrl = false; // the on-screen Ctrl is armed for the next key

  Workspace get ws => widget.ws;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_queueTailCheck);
    _term.onOutput = (data) {
      if (_ctrl && data.length == 1) {
        final c = data.codeUnitAt(0);
        _ctrl = false;
        if (mounted) setState(() {});
        if (c >= 0x61 && c <= 0x7a) {
          _send([c - 0x60]);
          return;
        }
        if (c >= 0x40 && c <= 0x5f) {
          _send([c & 0x1f]);
          return;
        }
      }
      _send(utf8.encode(data));
    };
    _term.onResize = (cols, rows, _, _) {
      _cols = cols;
      _rows = rows;
      _resize(cols, rows);
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
    if (identical(_streamLink, ws.link)) return;
    _attachGeneration++;
    _retry?.cancel();
    _attaching = false;
    _streamLink = ws.link;
    final terminal = _t;
    _t = null;
    _out?.cancel();
    _out = null;
    unawaited(terminal?.close());
    setState(() => _state = '连接已断开，等待重新连接…');
    if (ws.link != null) unawaited(_attach());
  }

  void _send(List<int> bytes) {
    final terminal = _t;
    if (terminal == null) return;
    unawaited(
      terminal.write(bytes).catchError((Object e) {
        if (!_disposed && identical(_t, terminal)) {
          setState(() => _state = '终端写入失败：$e');
        }
      }),
    );
  }

  void _resize(int cols, int rows) {
    final terminal = _t;
    if (terminal != null)
      unawaited(terminal.resize(cols, rows).catchError((Object _) {}));
  }

  double? _fontSize;
  void _onAppearance() {
    final size = ws.app.appearance.value.terminalFont;
    if (mounted && size != _fontSize && TickerMode.valuesOf(context).enabled)
      setState(() => _fontSize = size);
  }

  Future<void> _attach() async {
    final link = ws.link;
    if (link == null || _disposed || _attaching || _t != null) return;
    _retry?.cancel();
    final generation = ++_attachGeneration;
    _streamLink = link;
    bool current() =>
        !_disposed &&
        generation == _attachGeneration &&
        identical(link, ws.link);
    _attaching = true;
    setState(() => _state = '正在连接…');
    StreamSubscription<Uint8List>? output;
    try {
      if (_term.viewWidth > 1 && _term.viewHeight > 1) {
        _cols = _term.viewWidth;
        _rows = _term.viewHeight;
      }
      final t = await w.Terminal.attach(
        link,
        widget.session,
        cols: _cols,
        rows: _rows,
      );
      if (!current()) {
        await t.close();
        return;
      }
      _t = t;
      _attaching = false;
      if (_term.viewWidth > 1 &&
          (_term.viewWidth != _cols || _term.viewHeight != _rows)) {
        _cols = _term.viewWidth;
        _rows = _term.viewHeight;
      }
      _resize(_cols, _rows);
      // UTF-8 state belongs to this stream; a reconnect cannot join partial
      // bytes from the old connection to the new terminal's first character.
      final decoder = const Utf8Decoder(allowMalformed: true)
          .startChunkedConversion(
            _StringSink((s) {
              if (current()) _term.write(s);
            }),
          );
      output = _out = t.output.listen(decoder.add, onDone: decoder.close);
      setState(() => _state = '');
      if (_wantsFocus) _focus.requestFocus();
      final why = await t.done;
      await output.cancel();
      if (!current()) return;
      _out = null;
      _t = null;
      switch (why) {
        case w.TerminalEnd.exit:
          setState(() => _state = '会话已结束');
          ws.dropTabs((x) => x.id == 'term:${widget.session}');
        case w.TerminalEnd.closed:
          setState(() => _state = t.endReason);
        case w.TerminalEnd.detached:
          // detached (C-d) or the agent restarting: attach again shortly
          setState(() => _state = '连接已断开，正在重新连接…');
          _retry = Timer(const Duration(milliseconds: 500), () {
            if (current()) unawaited(_attach());
          });
        case w.TerminalEnd.lost:
          setState(() => _state = '连接已断开，等待重新连接…');
      }
    } on Object catch (e) {
      if (current()) {
        final missing = e is w.OpError && e.code == w.codeNotFound;
        setState(
          () => _state = missing
              ? '会话已结束'
              : '无法连接终端：${e is w.OpError ? e.message : e}',
        );
        if (missing) ws.dropTabs((x) => x.id == 'term:${widget.session}');
      }
    } finally {
      await output?.cancel();
      if (current()) _attaching = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _attachGeneration++;
    _retry?.cancel();
    ws.removeListener(_onWs);
    ws.app.appearance.removeListener(_onAppearance);
    _out?.cancel();
    _t?.close();
    if (ws.entry?.isLocal == true && ws.link != null)
      unawaited(
        ws.link!
            .call('session.kill', {'name': widget.session})
            .catchError((Object _) => null),
      );
    _focus.dispose();
    _controller.dispose();
    _scroll.dispose();
    _readingHistory.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (_disposed) return;
    final text = d?.text;
    if (text != null && text.isNotEmpty) _term.paste(text);
  }

  void _copy() {
    final sel = _controller.selection;
    if (sel == null) return;
    Clipboard.setData(ClipboardData(text: _term.buffer.getText(sel)));
    _controller.clearSelection();
  }

  void _selectAll() {
    _controller.setSelection(
      _term.buffer.createAnchor(0, _term.buffer.height - _term.viewHeight),
      _term.buffer.createAnchor(_term.viewWidth, _term.buffer.height - 1),
      mode: SelectionMode.line,
    );
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

  bool get _wantsFocus =>
      mounted &&
      ws.terminalFocused &&
      ws.terminalActiveId == 'term:${widget.session}' &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _key(TerminalKey k) {
    _term.keyInput(k);
    _focus.requestFocus();
  }

  void _queueTailCheck() {
    if (_tailCheckScheduled) return;
    _tailCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tailCheckScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      _readingHistory.value =
          position.hasContentDimensions && position.extentAfter > 32;
    });
  }

  void _jumpToTail() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    if (_wantsFocus) _focus.requestFocus();
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
                    const SingleActivator(
                      LogicalKeyboardKey.keyC,
                      control: true,
                      shift: true,
                    ): _copy,
                    const SingleActivator(
                      LogicalKeyboardKey.keyV,
                      control: true,
                      shift: true,
                    ): _paste,
                  },
                  child: Scrollbar(
                    controller: _scroll,
                    thickness: 5,
                    radius: const Radius.circular(3),
                    child: NotificationListener<ScrollMetricsNotification>(
                      onNotification: (_) {
                        _queueTailCheck();
                        return false;
                      },
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context)
                            .copyWith(scrollbars: false),
                        child: TerminalView(
                          _term,
                          controller: _controller,
                          scrollController: _scroll,
                          focusNode: _focus,
                          autofocus: false,
                          onKeyEvent: (_, event) =>
                              WorkbenchShortcuts.handle(context, event),
                          theme: theme,
                          textStyle: TerminalStyle(
                            fontSize: _fontSize =
                                ws.app.appearance.value.terminalFont,
                            fontFamily: Ide.mono,
                            fontFamilyFallback: Ide.monoFallback,
                          ),
                          padding: const EdgeInsets.fromLTRB(13, 8, 8, 5),
                          onSecondaryTapDown: (d, _) {
                            final sel = _controller.selection;
                            showMenuAt(context, d.globalPosition, [
                              MenuItem(
                                '复制',
                                sel == null ? null : _copy,
                                icon: Icons.copy,
                                hint: 'Ctrl+Shift+C',
                              ),
                              MenuItem(
                                '粘贴',
                                _paste,
                                icon: Icons.paste,
                                hint: 'Ctrl+Shift+V',
                              ),
                              MenuItem(
                                '全选',
                                _selectAll,
                                icon: Icons.select_all,
                              ),
                              const MenuItem.separator(),
                              MenuItem(
                                '清屏',
                                () => _term.keyInput(
                                  TerminalKey.keyL,
                                  ctrl: true,
                                ),
                                icon: Icons.clear_all,
                              ),
                            ]);
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_state.isNotEmpty)
                Positioned(
                  left: Space.m,
                  right: Space.m,
                  top: Space.m,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: _statusBanner(ide),
                  ),
                ),
              if (_state.isEmpty)
                Positioned(
                  right: Space.l,
                  bottom: Space.m,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _readingHistory,
                    builder: (_, reading, _) => !reading
                        ? const SizedBox.shrink()
                        : Material(
                            color: ide.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius: UiMetrics.controlCorners,
                              side: BorderSide(color: ide.borderStrong),
                            ),
                            child: IconBtn(
                              Icons.arrow_downward_rounded,
                              '回到最新输出',
                              _jumpToTail,
                              key: const ValueKey('terminal-jump-to-tail'),
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

  Widget _statusBanner(Ide ide) {
    final busy = _state.startsWith('正在');
    return Material(
      color: ide.surface,
      shape: RoundedRectangleBorder(
        borderRadius: UiMetrics.controlCorners,
        side: BorderSide(color: ide.borderStrong),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.m,
          vertical: Space.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            else
              Icon(Icons.info_outline_rounded, size: 15, color: ide.textDim),
            const SizedBox(width: Space.m),
            Flexible(
              child: Tooltip(
                message: _state,
                child: Text(
                  _state,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: ide.text, fontSize: 12),
                ),
              ),
            ),
            if (_t == null && !busy)
              IconBtn(
                Icons.refresh_rounded,
                '重新连接',
                ws.link == null || _attaching ? null : _attach,
                size: 14,
              ),
          ],
        ),
      ),
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
