// One server's direct link, kept up (D-24, D-62). A network failure is
// retried a bounded number of times, then reported; a rejected token or a
// changed certificate is reported at once and never retried. The caller
// decides when to try again after a report (the user presses "reconnect").
import 'dart:async';

import 'link.dart';

/// Where to reach one agent: candidate addresses, the pin and the token.
class Target {
  /// host:port values, tried in order. IPv6 hosts are in brackets.
  final List<String> addrs;
  final String pin;
  final String token;
  const Target({required this.addrs, required this.pin, required this.token});
}

enum ConnState {
  /// Not started, or [Connection.close] was called.
  idle,
  connecting,
  connected,

  /// Waiting before the next attempt after a network failure.
  waiting,

  /// Stopped: [Connection.failure] says why. Needs [Connection.connect].
  failed,
}

/// The failure that stopped a [Connection].
class ConnFailure {
  final DialFailure kind;
  final String message;
  ConnFailure(this.kind, this.message);

  /// The user must act: pair again (token) or confirm the new identity over
  /// SSH (pin). Retrying cannot help.
  bool get needsUser => kind == DialFailure.auth || kind == DialFailure.pinMismatch || kind == DialFailure.version;
  @override
  String toString() => message;
}

/// What a [Connection] reports on [Connection.changes].
class ConnStatus {
  final ConnState state;
  final Link? link;
  final ConnFailure? failure;

  /// The address that worked, when connected.
  final String? addr;

  /// Attempt number within the current run (1 = first try), and the delay
  /// before the next one while waiting.
  final int attempt;
  final Duration? retryIn;
  ConnStatus(this.state, {this.link, this.failure, this.addr, this.attempt = 0, this.retryIn});
  @override
  String toString() => '$state${addr == null ? '' : ' $addr'}${failure == null ? '' : ' $failure'}';
}

typedef Dialer = Future<Link> Function(Endpoint ep);

/// Splits host:port; brackets around an IPv6 host are removed.
(String, int)? splitHostPort(String a) {
  final i = a.lastIndexOf(':');
  if (i <= 0) return null;
  final port = int.tryParse(a.substring(i + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  var host = a.substring(0, i);
  if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
  if (host.isEmpty) return null;
  return (host, port);
}

class Connection {
  Target _target;

  /// Waits after each failed round of addresses (D-24: about 2, 5, 10 s).
  final List<Duration> retryDelays;
  final Dialer _dial;
  final StreamController<ConnStatus> _changes = StreamController<ConnStatus>.broadcast();

  ConnStatus _status = ConnStatus(ConnState.idle);
  String? _good;
  int _run = 0; // bumps on connect()/close(): stale attempts stop
  Timer? _timer;
  Completer<void>? _wake;

  Connection(Target target,
      {this.retryDelays = const [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 10)],
      Dialer? dial,
      String? goodAddr,
      Duration dialTimeout = const Duration(seconds: 10)})
      : _target = target,
        _good = goodAddr,
        _dial = dial ?? ((ep) => Link.dial(ep, timeout: dialTimeout));

  ConnStatus get status => _status;
  Stream<ConnStatus> get changes => _changes.stream;
  Link? get link => _status.link;
  ConnFailure? get failure => _status.failure;

  /// The last address that worked, to store (DirectParams.goodAddr).
  String? get goodAddr => _good;

  /// New parameters (after re-pairing or token rotation). Takes effect on
  /// the next attempt; an open link is kept.
  set target(Target t) => _target = t;

  void _set(ConnStatus s) {
    _status = s;
    if (!_changes.isClosed) _changes.add(s);
  }

  /// Starts connecting, or restarts after a failure. Completes when the
  /// link is up, or with the failure that stopped this run.
  Future<Link> connect() {
    if (_status.state == ConnState.connected && _status.link != null && !_status.link!.isClosed) {
      return Future.value(_status.link!);
    }
    final run = ++_run;
    _timer?.cancel();
    final c = Completer<Link>();
    unawaited(_loop(run, c));
    return c.future;
  }

  /// Skips the wait before the next attempt (the user pressed "reconnect
  /// now" while waiting).
  void retryNow() {
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _loop(int run, Completer<Link> out) async {
    for (var attempt = 1;; attempt++) {
      if (run != _run) return;
      _set(ConnStatus(ConnState.connecting, attempt: attempt));
      ConnFailure? last;
      for (final addr in _order()) {
        final hp = splitHostPort(addr);
        if (hp == null) {
          last = ConnFailure(DialFailure.protocol, '地址格式无效：$addr');
          continue;
        }
        try {
          final l = await _dial(Endpoint(host: hp.$1, port: hp.$2, pin: _target.pin, token: _target.token));
          if (run != _run) {
            unawaited(l.close());
            return;
          }
          _good = addr;
          _set(ConnStatus(ConnState.connected, link: l, addr: addr, attempt: attempt));
          if (!out.isCompleted) out.complete(l);
          unawaited(_watch(run, l));
          return;
        } on DialException catch (e) {
          last = ConnFailure(e.kind, e.message);
          if (last.needsUser) break; // the same agent answers on every address
        }
      }
      if (run != _run) return;
      last ??= ConnFailure(DialFailure.network, '没有可用的地址');
      if (last.needsUser || attempt > retryDelays.length) {
        _set(ConnStatus(ConnState.failed, failure: last, attempt: attempt));
        if (!out.isCompleted) out.completeError(last);
        return;
      }
      final wait = retryDelays[attempt - 1];
      _set(ConnStatus(ConnState.waiting, failure: last, attempt: attempt, retryIn: wait));
      final wake = _wake = Completer<void>();
      _timer = Timer(wait, () {
        if (!wake.isCompleted) wake.complete();
      });
      await wake.future;
      _timer?.cancel();
      _wake = null;
    }
  }

  /// The last good address first, then the others in the given order.
  List<String> _order() {
    final a = [..._target.addrs];
    final g = _good;
    if (g != null) {
      a.remove(g);
      a.insert(0, g);
    }
    return a;
  }

  /// A link that drops is redialled with a fresh set of retries (D-18: one
  /// short break, then the client reconnects by itself).
  Future<void> _watch(int run, Link l) async {
    await l.done;
    if (run != _run) return;
    final again = ++_run;
    unawaited(_loop(again, Completer<Link>()..future.ignore()));
  }

  /// Closes the link and stops reconnecting.
  Future<void> close() async {
    _run++;
    _timer?.cancel();
    retryNow();
    final l = _status.link;
    _set(ConnStatus(ConnState.idle));
    if (l != null && !l.isClosed) await l.close();
  }

  Future<void> dispose() async {
    await close();
    await _changes.close();
  }
}
