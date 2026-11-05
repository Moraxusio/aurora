// A yamux client compatible with hashicorp/yamux v0.1.1, the multiplexer the
// agent runs (agent/internal/wire/session.go MuxConfig).
//
// Wire format: a 12-byte header
//   version u8 (0) | type u8 | flags u16 | stream id u32 | length u32
// all big-endian. Types: 0 data (length bytes of payload follow), 1 window
// update (length is the window delta), 2 ping (length is the ping id),
// 3 go away (length is the reason). Flags: SYN 1, ACK 2, FIN 4, RST 8.
// A client opens odd stream ids. Each stream starts with a 256 KiB window in
// both directions; a receiver grows it with window updates.
//
// Performance (docs/DESIGN.md 5.3):
//   - every stream announces a 4 MiB receive window when it opens, so one
//     stream is not held to 256 KiB per round trip;
//   - frames queued in one event-loop turn go out in one socket write, and
//     one write is in flight at a time, so the socket never buffers more than
//     one batch;
//   - interactive streams are served before bulk ones when both have data.
import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'bytes.dart';

const int _protoVersion = 0;
const int typeDataFrame = 0;
const int typeWindowUpdate = 1;
const int typePing = 2;
const int typeGoAway = 3;

const int flagSyn = 1;
const int flagAck = 2;
const int flagFin = 4;
const int flagRst = 8;

const int headerSize = 12;
const int initialWindow = 256 * 1024;

const int goAwayNormal = 0;
const int goAwayProtoErr = 1;
const int goAwayInternalErr = 2;

/// Settings; the defaults match wire.MuxConfig.
class YamuxConfig {
  /// Largest receive window a stream announces (MaxStreamWindowSize).
  final int maxStreamWindow;

  /// Interval between keep-alive pings; null turns them off.
  final Duration? keepAliveInterval;

  /// A ping, or a socket write, not finished in this time ends the session
  /// (ConnectionWriteTimeout).
  final Duration writeTimeout;

  /// An opened stream the peer does not acknowledge in this time ends the
  /// session (StreamOpenTimeout).
  final Duration streamOpenTimeout;

  /// Streams opened and not yet acknowledged, at most (AcceptBacklog). The
  /// peer resets streams beyond its backlog, so opens wait instead.
  final int acceptBacklog;

  /// Largest data frame this side sends.
  final int maxFramePayload;

  /// Largest batch handed to the socket in one write.
  final int batchBytes;

  const YamuxConfig({
    this.maxStreamWindow = 4 * 1024 * 1024,
    this.keepAliveInterval = const Duration(seconds: 15),
    this.writeTimeout = const Duration(seconds: 30),
    this.streamOpenTimeout = const Duration(seconds: 20),
    this.acceptBacklog = 512,
    this.maxFramePayload = 64 * 1024,
    this.batchBytes = 256 * 1024,
  });
}

class YamuxException implements Exception {
  final String message;
  YamuxException(this.message);
  @override
  String toString() => message;
}

/// The session ended; the message says why.
class SessionClosed extends YamuxException {
  SessionClosed(super.message);
}

/// The peer reset the stream.
class StreamReset extends YamuxException {
  StreamReset() : super('stream reset by peer');
}

Uint8List _header(int type, int flags, int id, int length) {
  final h = Uint8List(headerSize);
  ByteData.sublistView(h)
    ..setUint8(0, _protoVersion)
    ..setUint8(1, type)
    ..setUint16(2, flags)
    ..setUint32(4, id)
    ..setUint32(8, length);
  return h;
}

/// The byte connection under a session: a TLS socket, or a pipe in tests.
abstract class Transport {
  /// Sets the input handlers, replacing earlier ones.
  void listen(void Function(Uint8List data) onData, void Function(Object error) onError, void Function() onDone);

  /// Writes [bytes]. Completes when the transport has taken them; the
  /// session does not start another write before that.
  Future<void> write(Uint8List bytes);

  Future<void> close();
}

enum _State { open, localClosed, remoteClosed, closed, reset }

/// Interactive data (terminal keys, unary calls) is sent before bulk data
/// (file transfers) when both are waiting.
enum Priority { interactive, bulk }

class _Pending {
  final Uint8List? bytes; // null: FIN
  int off = 0;
  final Completer<void> done = Completer<void>();
  _Pending(this.bytes) {
    done.future.ignore();
  }
}

/// One logical stream. Read with [next]; write with [write], whose future
/// is the back pressure; half-close with [close]; abort with [reset].
class YamuxStream {
  final Session _s;
  final int id;
  Priority priority;

  _State _state = _State.open;
  final bool _inbound;
  bool _firstSent = false; // SYN (outbound) or ACK (inbound) went out
  bool _acked = false;
  final Completer<void> _established = Completer<void>();

  YamuxException? _err; // why the stream was reset
  final ByteQueue _recv = ByteQueue();
  int _recvWindow = initialWindow; // what the peer may still send
  Completer<void>? _readWaiter;

  int _sendWindow = initialWindow;
  final Queue<_Pending> _out = Queue<_Pending>();
  bool _finQueued = false;
  bool _queued = false; // in the session's ready list

  // Receive window auto-tuning (the algorithm of quic-go's flow controller):
  // the window starts at the protocol's 256 KiB and doubles, up to
  // YamuxConfig.maxStreamWindow, only when the reader consumes it in less
  // than about two round trips. A reader slower than the link keeps a small
  // window, so a bulk stream does not queue seconds of data in front of a
  // terminal's echo.
  int _window = initialWindow;
  int _bytesRead = 0;
  int _epochStartRead = 0;
  int _epochStartUs = 0;
  int _synSentUs = 0;

  YamuxStream._(this._s, this.id, this.priority, this._inbound) {
    _established.future.ignore();
    _epochStartUs = _s._clock.elapsedMicroseconds;
    if (_inbound) {
      _acked = true;
      _established.complete();
    }
  }

  /// Current receive window (bytes the peer may have in flight).
  int get window => _window;

  bool get isClosed => _state == _State.closed || _state == _State.reset;

  /// Bytes received and not yet read.
  int get buffered => _recv.length;

  /// Completes when the peer acknowledges the stream.
  Future<void> get established => _established.future;

  /// The next received bytes, or null at the end of the stream. Throws
  /// [StreamReset] or [SessionClosed].
  Future<Uint8List?> next([int max = 1 << 20]) async {
    if (!await _waitData()) return null;
    final n = math.min(max, _recv.length);
    final out = _recv.take(n);
    _bytesRead += n;
    _s._maybeWindowUpdate(this);
    return out;
  }

  /// Reads exactly [n] bytes; throws [YamuxException] if the stream ends first.
  Future<Uint8List> readExactly(int n) async {
    while (_recv.length < n) {
      final before = _recv.length;
      if (!await _waitData(more: before)) {
        throw YamuxException('stream ended after ${_recv.length} of $n bytes');
      }
    }
    final out = _recv.take(n);
    _bytesRead += n;
    _s._maybeWindowUpdate(this);
    return out;
  }

  /// Waits until more than [more] bytes are buffered; false at end of stream.
  Future<bool> _waitData({int more = 0}) async {
    while (_recv.length <= more) {
      switch (_state) {
        case _State.reset:
          throw _err ?? StreamReset();
        case _State.remoteClosed:
        case _State.closed:
          return false;
        default:
      }
      final why = _s._closedReason;
      if (why != null) throw SessionClosed(why);
      final w = _readWaiter = Completer<void>();
      await w.future;
    }
    return true;
  }

  /// Queues [data]. Completes once all of it is handed to the socket; this
  /// waits for the peer's window, which is the back pressure a sender must
  /// respect.
  Future<void> write(List<int> data) {
    if (_state == _State.reset) return Future.error(_err ?? StreamReset());
    if (_finQueued || _state == _State.localClosed || _state == _State.closed) {
      return Future.error(YamuxException('write on closed stream'));
    }
    final why = _s._closedReason;
    if (why != null) return Future.error(SessionClosed(why));
    if (data.isEmpty) return Future.value();
    final p = _Pending(data is Uint8List ? data : Uint8List.fromList(data));
    _out.add(p);
    _s._ready(this);
    return p.done.future;
  }

  /// Half-closes: sends FIN after the queued data. Reading goes on until the
  /// peer closes too.
  Future<void> close() {
    if (_finQueued || isClosed || _s._closedReason != null) return Future.value();
    _finQueued = true;
    final p = _Pending(null);
    _out.add(p);
    _s._ready(this);
    return p.done.future;
  }

  /// Aborts at once (RST); queued data is dropped. A stream the peer has not
  /// heard of yet (nothing sent) is just dropped.
  void reset() {
    if (isClosed) return;
    if (_firstSent) _s._control(_header(typeWindowUpdate, flagRst, id, 0));
    _fail(StreamReset());
    _s._forget(this);
  }

  /// Flags for the next frame: the first frame of a stream carries SYN
  /// (outbound) or ACK (inbound).
  int _takeFlags() {
    if (_firstSent) return 0;
    _firstSent = true;
    if (_inbound) return flagAck;
    _synSentUs = _s._clock.elapsedMicroseconds;
    return flagSyn;
  }

  void _onFlags(int flags) {
    if (flags & flagAck != 0 && !_acked) {
      _acked = true;
      if (_synSentUs > 0) _s._rttSample(_s._clock.elapsedMicroseconds - _synSentUs);
      _s._acked(this);
      if (!_established.isCompleted) _established.complete();
    }
    if (flags & flagFin != 0) {
      switch (_state) {
        case _State.open:
          _state = _State.remoteClosed;
          break;
        case _State.localClosed:
          _state = _State.closed;
          _s._forget(this);
          break;
        default:
      }
      _wake();
    }
    if (flags & flagRst != 0) {
      _fail(StreamReset());
      _s._forget(this);
    }
  }

  void _onData(Uint8List payload) {
    if (payload.length > _recvWindow) {
      throw YamuxException('receive window exceeded on stream $id');
    }
    _recvWindow -= payload.length;
    if (isClosed) return;
    _recv.add(payload);
    _wake();
  }

  void _fail(YamuxException err) {
    _state = _State.reset;
    _err ??= err;
    if (!_established.isCompleted) _established.completeError(err);
    while (_out.isNotEmpty) {
      final p = _out.removeFirst();
      if (!p.done.isCompleted) p.done.completeError(err);
    }
    _wake();
  }

  void _wake() {
    final w = _readWaiter;
    _readWaiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }
}

/// A yamux session over a [Transport]: one per direct link.
class Session {
  final Transport _t;
  final YamuxConfig config;

  final Map<int, YamuxStream> _streams = {};
  int _nextId;
  String? _closedReason;
  bool _remoteGoAway = false;
  final Completer<String> _done = Completer<String>();

  final ByteQueue _in = ByteQueue();

  final List<Uint8List> _controlFrames = [];
  final Queue<YamuxStream> _readyInteractive = Queue<YamuxStream>();
  final Queue<YamuxStream> _readyBulk = Queue<YamuxStream>();
  bool _writing = false;

  int _inflightSyn = 0;
  final Queue<Completer<void>> _synWaiters = Queue<Completer<void>>();

  int _pingId = 0;
  final Map<int, Completer<void>> _pings = {};
  Timer? _keepAlive;
  final Stopwatch _sinceRead = Stopwatch()..start();
  final Stopwatch _clock = Stopwatch()..start();
  int _rttUs = 0; // smoothed round trip; 0 until the first sample

  /// Smoothed round-trip estimate (zero before the first sample).
  Duration get rtt => Duration(microseconds: _rttUs);

  void _rttSample(int us) {
    if (us <= 0) return;
    _rttUs = _rttUs == 0 ? us : (_rttUs * 7 + us) ~/ 8;
  }

  final StreamController<YamuxStream> _accepted = StreamController<YamuxStream>();

  /// Counters for benchmarks and diagnostics.
  int socketWrites = 0;
  int bytesOut = 0;
  int bytesIn = 0;

  Session._(this._t, this.config, bool client, Uint8List? initial) : _nextId = client ? 1 : 2 {
    _t.listen(_onInput, (Object e) => _shutdown('读取失败：$e'), () => _shutdown('对端关闭了连接'));
    final ka = config.keepAliveInterval;
    if (ka != null) _keepAlive = Timer.periodic(ka, (_) => _keepAliveTick());
    if (initial != null && initial.isNotEmpty) _onInput(initial);
  }

  /// A client session over [t]. [initial] holds bytes already read from the
  /// transport after the Hello exchange.
  factory Session.client(Transport t, {YamuxConfig config = const YamuxConfig(), Uint8List? initial}) =>
      Session._(t, config, true, initial);

  /// A server session over [t] (tests).
  factory Session.server(Transport t, {YamuxConfig config = const YamuxConfig()}) =>
      Session._(t, config, false, null);

  bool get isClosed => _closedReason != null;

  /// Why the session ended, once it has.
  String? get closedReason => _closedReason;

  /// Completes with the reason when the session ends.
  Future<String> get done => _done.future;

  int get numStreams => _streams.length;

  /// Time since bytes last arrived from the peer.
  Duration get idle => _sinceRead.elapsed;

  /// Streams the peer opens.
  Stream<YamuxStream> get accepted => _accepted.stream;

  /// Opens a stream. Its first frame carries SYN; the receive window then
  /// grows with the reader's pace (auto-tuning, see [YamuxStream.window]).
  Future<YamuxStream> open({Priority priority = Priority.interactive}) async {
    while (_inflightSyn >= config.acceptBacklog) {
      _checkOpen();
      final w = Completer<void>();
      _synWaiters.add(w);
      await w.future;
    }
    _checkOpen();
    final id = _nextId;
    if (id >= 0xfffffffe) throw YamuxException('streams exhausted');
    _nextId += 2;
    final st = YamuxStream._(this, id, priority, false);
    _streams[id] = st;
    _inflightSyn++;
    _announceWindow(st);
    final t = config.streamOpenTimeout;
    Timer(t, () {
      if (!st._acked && !st.isClosed && _closedReason == null) {
        _shutdown('stream $id not acknowledged within ${t.inSeconds}s');
      }
    });
    return st;
  }

  void _checkOpen() {
    final why = _closedReason;
    if (why != null) throw SessionClosed(why);
    if (_remoteGoAway) throw YamuxException('remote end is not accepting streams');
  }

  /// Measures one round trip at the session level.
  Future<Duration> ping() async {
    _checkOpen();
    final id = _pingId;
    _pingId = (_pingId + 1) & 0xffffffff;
    final c = Completer<void>();
    _pings[id] = c;
    final sw = Stopwatch()..start();
    _control(_header(typePing, flagSyn, 0, id));
    try {
      await c.future.timeout(config.writeTimeout);
    } on TimeoutException {
      _pings.remove(id);
      throw YamuxException('ping timeout');
    }
    _rttSample(sw.elapsedMicroseconds);
    return sw.elapsed;
  }

  /// Sends GoAway after the queued frames and closes the transport.
  Future<void> close() async {
    if (_closedReason != null) return;
    _control(_header(typeGoAway, 0, 0, goAwayNormal));
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while ((_writing || _controlFrames.isNotEmpty) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    _shutdown('closed locally');
  }

  // --- sending ---

  /// The first frame of a stream: SYN (or ACK) with no window growth; the
  /// window starts at the protocol's 256 KiB and is tuned as data is read.
  void _announceWindow(YamuxStream st) {
    _control(_header(typeWindowUpdate, st._takeFlags(), st.id, 0));
  }

  /// Returns credit once the reader has consumed half the window (the rule
  /// hashicorp/yamux uses), after deciding whether the window should grow.
  void _maybeWindowUpdate(YamuxStream st) {
    if (st.isClosed || _closedReason != null) return;
    if ((st._window - st._recv.length) - st._recvWindow < st._window ~/ 2) return;
    _autoTune(st);
    final delta = (st._window - st._recv.length) - st._recvWindow;
    st._recvWindow += delta;
    _control(_header(typeWindowUpdate, 0, st.id, delta));
  }

  /// Doubles the window when the reader consumed the last epoch's data in
  /// less than 4 × (fraction of the window) × RTT, i.e. the window, not the
  /// reader, limits the transfer (quic-go flowcontrol). Without an RTT
  /// sample the window stays as it is.
  void _autoTune(YamuxStream st) {
    final now = _clock.elapsedMicroseconds;
    final read = st._bytesRead - st._epochStartRead;
    if (_rttUs > 0 && read > 0 && st._window < config.maxStreamWindow) {
      final fraction = read / st._window;
      if (now - st._epochStartUs < 4 * fraction * _rttUs) {
        st._window = math.min(st._window * 2, config.maxStreamWindow);
      }
    }
    st._epochStartUs = now;
    st._epochStartRead = st._bytesRead;
  }

  void _control(Uint8List frame) {
    if (_closedReason != null) return;
    _controlFrames.add(frame);
    _kick();
  }

  void _ready(YamuxStream st) {
    if (st._queued) return;
    st._queued = true;
    (st.priority == Priority.interactive ? _readyInteractive : _readyBulk).add(st);
    _kick();
  }

  void _kick() {
    if (_writing || _closedReason != null) return;
    _writing = true;
    // A microtask: frames queued in the same turn join this batch.
    scheduleMicrotask(_writeLoop);
  }

  Future<void> _writeLoop() async {
    try {
      while (_closedReason == null) {
        final batch = _batch();
        if (batch == null) break;
        socketWrites++;
        bytesOut += batch.length;
        await _t.write(batch).timeout(config.writeTimeout);
      }
    } on TimeoutException {
      _shutdown('写入超时（${config.writeTimeout.inSeconds} 秒）');
    } catch (e) {
      _shutdown('写入失败：$e');
    } finally {
      _writing = false;
    }
  }

  /// Control frames, then one frame per ready stream per round, interactive
  /// streams first, up to [YamuxConfig.batchBytes]. Null when idle.
  Uint8List? _batch() {
    final out = BytesBuilder(copy: false);
    for (final f in _controlFrames) {
      out.add(f);
    }
    _controlFrames.clear();
    while (out.length < config.batchBytes) {
      final YamuxStream st;
      if (_readyInteractive.isNotEmpty) {
        st = _readyInteractive.removeFirst();
      } else if (_readyBulk.isNotEmpty) {
        st = _readyBulk.removeFirst();
      } else {
        break;
      }
      st._queued = false;
      // A stream that sent a frame goes to the back of its queue (round
      // robin). One that is out of window waits for the peer's update,
      // which puts it back (_onStream).
      if (_emit(st, out) && _canSend(st)) _ready(st);
    }
    if (out.isEmpty) return null;
    return out.takeBytes();
  }

  bool _canSend(YamuxStream st) =>
      st._out.isNotEmpty && !st.isClosed && (st._out.first.bytes == null || st._sendWindow > 0);

  /// Puts one frame of [st] into [out]; false when nothing could go (the
  /// window is exhausted, or the stream has nothing queued).
  bool _emit(YamuxStream st, BytesBuilder out) {
    if (st._out.isEmpty || st.isClosed) return false;
    final p = st._out.first;
    final bytes = p.bytes;
    if (bytes == null) {
      st._out.removeFirst();
      out.add(_header(typeWindowUpdate, st._takeFlags() | flagFin, st.id, 0));
      switch (st._state) {
        case _State.open:
          st._state = _State.localClosed;
          break;
        case _State.remoteClosed:
          st._state = _State.closed;
          _forget(st);
          break;
        default:
      }
      p.done.complete();
      return true;
    }
    if (st._sendWindow <= 0) return false;
    final n = math.min(math.min(bytes.length - p.off, st._sendWindow), config.maxFramePayload);
    out.add(_header(typeDataFrame, st._takeFlags(), st.id, n));
    out.add(Uint8List.sublistView(bytes, p.off, p.off + n));
    p.off += n;
    st._sendWindow -= n;
    if (p.off == bytes.length) {
      st._out.removeFirst();
      p.done.complete();
    }
    return true;
  }

  // --- receiving ---

  void _onInput(Uint8List chunk) {
    if (_closedReason != null) return;
    _sinceRead
      ..reset()
      ..start();
    bytesIn += chunk.length;
    _in.add(chunk);
    try {
      while (_in.length >= headerSize && _closedReason == null) {
        final h = ByteData.sublistView(_in.peek(headerSize));
        final ver = h.getUint8(0);
        final type = h.getUint8(1);
        final flags = h.getUint16(2);
        final id = h.getUint32(4);
        final length = h.getUint32(8);
        if (ver != _protoVersion) throw YamuxException('invalid protocol version $ver');
        if (type > typeGoAway) throw YamuxException('invalid message type $type');
        if (type == typeDataFrame) {
          if (_in.length < headerSize + length) break;
          _in.skip(headerSize);
          _onStream(type, flags, id, length, _in.take(length));
          continue;
        }
        _in.skip(headerSize);
        switch (type) {
          case typeWindowUpdate:
            _onStream(type, flags, id, length, null);
            break;
          case typePing:
            _onPing(flags, length);
            break;
          case typeGoAway:
            _onGoAway(length);
            break;
        }
      }
    } on YamuxException catch (e) {
      _controlFrames.insert(0, _header(typeGoAway, 0, 0, goAwayProtoErr));
      _shutdown('协议错误：${e.message}');
    }
  }

  void _onStream(int type, int flags, int id, int length, Uint8List? payload) {
    var st = _streams[id];
    if (flags & flagSyn != 0) {
      if (st != null) throw YamuxException('duplicate stream $id');
      st = YamuxStream._(this, id, Priority.interactive, true);
      _streams[id] = st;
      _accepted.add(st);
      _announceWindow(st);
    }
    if (st == null) return; // a stream we already forgot (closed or reset)
    if (type == typeWindowUpdate) {
      st._onFlags(flags);
      if (length > 0 && !st.isClosed) {
        st._sendWindow += length;
        if (st._out.isNotEmpty) _ready(st);
      }
      return;
    }
    st._onFlags(flags & ~flagFin);
    if (payload!.isNotEmpty) st._onData(payload);
    if (flags & flagFin != 0) st._onFlags(flagFin);
  }

  void _onPing(int flags, int id) {
    if (flags & flagSyn != 0) {
      _control(_header(typePing, flagAck, 0, id));
      return;
    }
    final c = _pings.remove(id);
    if (c != null && !c.isCompleted) c.complete();
  }

  void _onGoAway(int code) {
    switch (code) {
      case goAwayNormal:
        // The peer accepts no new streams; open ones go on.
        _remoteGoAway = true;
        break;
      case goAwayProtoErr:
        _shutdown('对端报告协议错误');
        break;
      default:
        _shutdown('对端内部错误（$code）');
    }
  }

  void _keepAliveTick() {
    if (_closedReason != null) return;
    ping().then<void>((_) {}, onError: (Object e) {
      if (_closedReason == null) _shutdown('保活失败：$e');
    });
  }

  void _acked(YamuxStream st) {
    if (_inflightSyn > 0) _inflightSyn--;
    if (_synWaiters.isNotEmpty) _synWaiters.removeFirst().complete();
  }

  void _forget(YamuxStream st) {
    if (_streams.remove(st.id) == null) return;
    if (!st._inbound && !st._acked) _acked(st);
  }

  void _shutdown(String why) {
    if (_closedReason != null) return;
    _closedReason = why;
    _keepAlive?.cancel();
    final err = SessionClosed(why);
    for (final st in _streams.values.toList()) {
      if (!st.isClosed) st._fail(err);
    }
    _streams.clear();
    for (final c in _pings.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pings.clear();
    while (_synWaiters.isNotEmpty) {
      _synWaiters.removeFirst().completeError(err);
    }
    _accepted.close();
    final pending = _controlFrames.isNotEmpty ? Uint8List.fromList(_controlFrames.first) : null;
    _controlFrames.clear();
    () async {
      if (pending != null && !_writing) {
        try {
          await _t.write(pending).timeout(const Duration(seconds: 1));
        } catch (_) {}
      }
      try {
        await _t.close();
      } catch (_) {}
    }();
    if (!_done.isCompleted) _done.complete(why);
  }
}
