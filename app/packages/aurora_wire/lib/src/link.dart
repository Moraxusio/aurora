// The direct link (docs/DESIGN.md 5.3): TCP with no delay, TLS 1.3 trusted by
// certificate pin, one Hello exchange, then a yamux session. Every operation
// opens a stream and starts with a Request frame (agent/internal/wire).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora_tls/aurora_tls.dart';

import 'bytes.dart';
import 'frame.dart';
import 'yamux.dart';

/// Protocol version this client speaks (wire.Version).
const String protocolVersion = '3.0';

const String codeBadRequest = 'bad_request';
const String codeNotFound = 'not_found';
const String codeConflict = 'conflict';
const String codeForbidden = 'forbidden';
const String codeUnsupported = 'unsupported';
const String codeUnavailable = 'unavailable';
const String codeInternal = 'internal';

/// A failed operation, with the agent's code and message.
class OpError implements Exception {
  final String code;
  final String message;
  OpError(this.code, this.message);
  @override
  String toString() => message;
}

/// Why a dial failed. The kinds need different handling (D-24, D-62).
enum DialFailure {
  /// Network: refused, unreachable, timed out. Retry is reasonable.
  network,

  /// The certificate pin did not match: the server's identity changed.
  /// Never retried, never accepted automatically (D-62).
  pinMismatch,

  /// The agent refused the token (D-24: no retry, ask to pair again).
  auth,

  /// The agent speaks another protocol major version.
  version,

  /// Anything else in the handshake.
  protocol,
}

class DialException implements Exception {
  final DialFailure kind;
  final String message;
  DialException(this.kind, this.message);
  @override
  String toString() => message;
}

/// What the client needs to reach an agent (stored per server, D-22).
class Endpoint {
  final String host;
  final int port;

  /// Lower-case hex SHA-256 of the certificate DER.
  final String pin;
  final String token;
  const Endpoint({required this.host, required this.port, required this.pin, required this.token});
}

/// The agent's description, from HelloReply.server (wire.AgentInfo).
class AgentInfo {
  final Map<String, dynamic> raw;
  AgentInfo(this.raw);
  String get id => raw['id'] as String? ?? '';
  String get name => raw['name'] as String? ?? '';
  String get host => raw['host'] as String? ?? '';
  String get os => raw['os'] as String? ?? '';
  String get kind => raw['kind'] == 'local' ? 'local' : 'remote';
  String get platform => raw['platform'] as String? ?? '';
  String get version => raw['version'] as String? ?? '';
  List<String> get caps => (raw['caps'] as List?)?.cast<String>() ?? const [];
}

/// The pin as 32 bytes, or null when it is not 64 hex digits.
Uint8List? _pinBytes(String hex) {
  final h = hex.trim().toLowerCase();
  if (h.length != 64) return null;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    final v = int.tryParse(h.substring(2 * i, 2 * i + 2), radix: 16);
    if (v == null) return null;
    out[i] = v;
  }
  return out;
}

/// Adapts [TlsSocket] (package:aurora_tls) to the session's [Transport]. Its
/// input is one stream; [listen] swaps the handlers (Hello first, then the
/// yamux session) on the single subscription.
class _TlsTransport implements Transport {
  final TlsSocket _s;
  StreamSubscription<Uint8List>? _sub;
  void Function(Uint8List) _onData = (_) {};
  void Function(Object) _onError = (_) {};
  void Function() _onDone = () {};
  _TlsTransport(this._s);

  @override
  void listen(void Function(Uint8List) onData, void Function(Object) onError, void Function() onDone) {
    _onData = onData;
    _onError = onError;
    _onDone = onDone;
    _sub ??= _s.input.listen((d) => _onData(d), onError: (Object e) => _onError(e), onDone: () => _onDone(), cancelOnError: true);
  }

  @override
  Future<void> write(Uint8List bytes) => _s.write(bytes);

  @override
  Future<void> close() => _s.close();
}

/// One direct link: a yamux session to an agent.
class Link {
  final Session session;
  final AgentInfo server;
  final String remote;
  Link._(this.session, this.server, this.remote);

  /// Dials [ep]: TCP, TLS 1.3 checked against the pin, Hello, yamux.
  /// Throws [DialException] with the failure kind.
  static Future<Link> dial(Endpoint ep,
      {String client = 'aurora',
      Duration timeout = const Duration(seconds: 15),
      YamuxConfig config = const YamuxConfig()}) async {
    final pin = _pinBytes(ep.pin);
    if (pin == null) throw DialException(DialFailure.protocol, '证书指纹格式无效');
    TlsSocket sock;
    try {
      // TLS 1.3 in the bundled BoringSSL; trust is the pin alone
      // (wire.PinnedTLS). dart:io's SecureSocket is not used: it caps
      // throughput (docs/PLAN.md section 6).
      sock = await TlsSocket.connect(ep.host, ep.port, pin, timeout: timeout);
    } on TlsException catch (e) {
      throw DialException(
          switch (e.kind) {
            TlsFailure.network => DialFailure.network,
            TlsFailure.pinMismatch => DialFailure.pinMismatch,
            TlsFailure.protocol => DialFailure.protocol,
          },
          e.message);
    }
    final t = _TlsTransport(sock);
    try {
      final (reply, rest) = await _hello(t, ep.token, client).timeout(timeout);
      final server = AgentInfo((reply['server'] as Map?)?.cast<String, dynamic>() ?? const {});
      final s = Session.client(t, config: config, initial: rest);
      return Link._(s, server, '${ep.host}:${ep.port}');
    } on DialException {
      await t.close();
      rethrow;
    } on TimeoutException {
      await t.close();
      throw DialException(DialFailure.network, '握手超时');
    } catch (e) {
      await t.close();
      throw DialException(DialFailure.protocol, '握手失败：$e');
    }
  }

  static Future<(Map<String, dynamic>, Uint8List)> _hello(_TlsTransport t, String token, String client) {
    final done = Completer<(Map<String, dynamic>, Uint8List)>();
    final q = ByteQueue();
    void fail(Object e) {
      if (!done.isCompleted) done.completeError(e);
    }

    t.listen((data) {
      if (done.isCompleted) return;
      q.add(data);
      if (q.length < 4) return;
      final n = q.peekUint32(0);
      if (n < 1 || n > maxFrame) {
        fail(DialException(DialFailure.protocol, '握手帧长度无效：$n'));
        return;
      }
      if (q.length < 4 + n) return;
      q.skip(4);
      final type = q.takeByte();
      final payload = q.take(n - 1);
      if (type != typeJson) {
        fail(DialException(DialFailure.protocol, '握手帧类型错误'));
        return;
      }
      final reply = (jsonDecode(utf8.decode(payload)) as Map).cast<String, dynamic>();
      if (reply['ok'] != true) {
        final msg = reply['error'] as String? ?? '握手被拒绝';
        final kind = msg.contains('版本') ? DialFailure.version : (msg.contains('认证') ? DialFailure.auth : DialFailure.protocol);
        fail(DialException(kind, msg));
        return;
      }
      final version = reply['version'] as String? ?? '';
      if (version.split('.').first != protocolVersion.split('.').first) {
        fail(DialException(DialFailure.version, '协议版本不兼容：客户端 $protocolVersion，服务端 $version'));
        return;
      }
      done.complete((reply, q.takeAll()));
    }, fail, () => fail(DialException(DialFailure.protocol, '对端在握手时关闭了连接')));
    t.write(encodeJson({'role': 'client', 'token': token, 'version': protocolVersion, 'client': client})).catchError(fail);
    return done.future;
  }

  bool get isClosed => session.isClosed;

  Future<String> get done => session.done;

  /// Runs a unary operation and returns its result.
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    final op_ = await open(op, args);
    // A unary call sends nothing after the request: half-close now, so SYN,
    // request and FIN leave in one socket write and the agent's reply ends
    // the stream on both sides.
    unawaited(op_.close().catchError((_) {}));
    try {
      return await op_.response().timeout(timeout);
    } on TimeoutException {
      op_.reset();
      throw OpError(codeUnavailable, '请求超时');
    }
  }

  /// Requests sent on any link since the program started. Every operation goes
  /// through [open], so this is what the performance test reads to count what
  /// a click on the window costs the server.
  static int requestCount = 0;

  /// Opens a stream operation: the Request is sent, frames follow.
  Future<OpStream> open(String op, [Object? args, Priority priority = Priority.interactive]) async {
    requestCount++;
    final YamuxStream st;
    try {
      st = await session.open(priority: priority);
    } on YamuxException catch (e) {
      throw OpError(codeUnavailable, '连接不可用：$e');
    }
    final req = <String, Object?>{'op': op};
    if (args != null) req['args'] = args;
    final s = OpStream._(st);
    unawaited(s.send(encodeJson(req)).catchError((_) {}));
    return s;
  }

  Future<Duration> ping() => session.ping();

  Future<void> close() => session.close();
}

/// One operation's stream: frames in both directions.
class OpStream {
  final YamuxStream stream;
  final FrameReader _r;
  OpStream._(this.stream) : _r = FrameReader(stream);

  /// The next frame, or null at end of stream.
  Future<Frame?> read() async {
    try {
      return await _r.read();
    } on YamuxException catch (e) {
      throw OpError(codeUnavailable, '连接中断：$e');
    }
  }

  /// For a stream that carries raw bytes after its Response (net.dial): the
  /// bytes that came with the Response first, then the rest, until the peer
  /// closes (null). Do not mix with [read].
  Future<Uint8List?> readRaw() async {
    final rest = _r.takeBuffered();
    if (rest.isNotEmpty) return rest;
    try {
      return await _r.nextRaw();
    } on YamuxException catch (e) {
      throw OpError(codeUnavailable, '连接中断：$e');
    }
  }
  /// Reads the Response frame: its result, or [OpError].
  Future<Object?> response() async {
    final f = await read();
    if (f == null) throw OpError(codeUnavailable, '连接中断：对端未返回结果');
    final m = (f.json() as Map).cast<String, dynamic>();
    if (m['ok'] != true) {
      throw OpError(m['code'] as String? ?? codeInternal, m['error'] as String? ?? '未知错误');
    }
    return m['result'];
  }

  /// Sends raw bytes (an encoded frame, or several).
  Future<void> send(Uint8List bytes) async {
    try {
      await stream.write(bytes);
    } on YamuxException catch (e) {
      throw OpError(codeUnavailable, '连接中断：$e');
    }
  }

  Future<void> sendJson(Object? v) => send(encodeJson(v));

  Future<void> sendData(List<int> payload) => send(encodeFrame(typeData, payload));

  Future<void> sendEnd() => send(encodeFrame(typeEnd, const []));

  /// Half-closes the stream.
  Future<void> close() => stream.close();

  void reset() => stream.reset();
}
