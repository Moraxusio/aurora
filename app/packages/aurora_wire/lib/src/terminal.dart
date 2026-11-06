// A terminal stream to a tmux session (agent/internal/terminal): 'D' frames
// carry terminal bytes both ways, 'J' frames carry control messages
// (wire.TerminalControl). Keystrokes go on the interactive priority so they
// are never queued behind a file transfer (DESIGN 5.3).
import 'dart:async';
import 'dart:typed_data';

import 'frame.dart';
import 'link.dart';
import 'yamux.dart';

/// Why a terminal stream ended.
enum TerminalEnd {
  /// The session's shell exited: the session is gone.
  exit,

  /// Detached, or the agent restarted: the session is still there; attach
  /// again.
  detached,

  /// The terminal service was switched off (D-51); [Terminal.endReason] says so.
  closed,

  /// The link dropped; attach again when it is back.
  lost,
}

class Terminal {
  final OpStream _s;
  final String session;
  // Broadcast: a view may stop listening and listen again (the screen is
  // tmux's to redraw, so nothing is lost by not buffering).
  final StreamController<Uint8List> _out = StreamController<Uint8List>.broadcast();
  final Completer<TerminalEnd> _end = Completer<TerminalEnd>();
  String endReason = '';
  final Map<int, Completer<Duration>> _pings = {};
  int _ping = 0;

  Terminal._(this._s, this.session);

  /// Attaches to an existing session. Throws [OpError] (not_found when the
  /// session ended, unavailable when the service is off).
  static Future<Terminal> attach(Link link, String session, {int cols = 80, int rows = 24}) async {
    final s = await link.open('terminal', {'name': session, 'cols': cols, 'rows': rows}, Priority.interactive);
    await s.response();
    final t = Terminal._(s, session);
    unawaited(t._read());
    return t;
  }

  /// Terminal output, in order.
  Stream<Uint8List> get output => _out.stream;

  /// Completes when the stream ends, with why.
  Future<TerminalEnd> get done => _end.future;

  Future<void> _read() async {
    try {
      while (true) {
        final f = await _s.read();
        if (f == null) return _finish(TerminalEnd.lost);
        if (f.type == typeData) {
          _out.add(f.payload);
          continue;
        }
        if (f.type != typeJson) continue;
        final m = f.json();
        if (m is! Map) continue;
        switch (m['type']) {
          case 'pong':
            final c = _pings.remove(m['code']);
            if (c != null && !c.isCompleted) c.complete(_sw.elapsed - (_sent[m['code']] ?? Duration.zero));
          case 'exit':
            return _finish(TerminalEnd.exit);
          case 'detached':
            return _finish(TerminalEnd.detached);
          case 'closed':
            endReason = m['reason'] as String? ?? '';
            return _finish(TerminalEnd.closed);
          case 'ok' || null:
            if (m['ok'] == false) {
              endReason = m['error'] as String? ?? '';
              return _finish(TerminalEnd.lost);
            }
        }
      }
    } on OpError catch (e) {
      endReason = e.message;
      _finish(TerminalEnd.lost);
    }
  }

  final Stopwatch _sw = Stopwatch()..start();
  final Map<int, Duration> _sent = {};

  void _finish(TerminalEnd why) {
    if (!_end.isCompleted) _end.complete(why);
    if (!_out.isClosed) _out.close();
    for (final c in _pings.values) {
      if (!c.isCompleted) c.completeError(OpError(codeUnavailable, '终端已关闭'));
    }
    _pings.clear();
  }

  bool get isOpen => !_end.isCompleted;

  /// Sends keystrokes or pasted text.
  Future<void> write(List<int> bytes) async {
    if (!isOpen) return;
    await _s.sendData(bytes);
  }

  Future<void> resize(int cols, int rows) async {
    if (!isOpen) return;
    await _s.sendJson({'type': 'resize', 'cols': cols, 'rows': rows});
  }

  /// Round trip through the attached tmux client.
  Future<Duration> ping() {
    final id = ++_ping;
    final c = Completer<Duration>();
    _pings[id] = c;
    _sent[id] = _sw.elapsed;
    _s.sendJson({'type': 'ping', 'code': id}).catchError((Object e) {
      if (!c.isCompleted) c.completeError(e);
    });
    return c.future;
  }

  /// Detaches; the session keeps running.
  Future<void> close() async {
    if (!isOpen) return;
    try {
      await _s.sendJson({'type': 'close'});
      await _s.close();
    } on OpError {
      // already gone
    }
    _finish(TerminalEnd.detached);
  }
}
