// A TLS 1.3 client over a plain dart:io Socket, with the record layer in the
// native engine (src/aurora_tls.c). dart:io's own SecureSocket stages every
// byte through fixed 8 KiB rings and a round trip to its IO thread; here
// ciphertext goes straight from the socket into the engine and plaintext
// straight out (docs/PLAN.md section 6).
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// Why a TLS connection failed.
enum TlsFailure {
  /// Refused, unreachable, timed out, or reset.
  network,

  /// The server's certificate does not match the pin (D-62: never retried).
  pinMismatch,

  /// Any other TLS error.
  protocol,
}

class TlsException implements Exception {
  final TlsFailure kind;
  final String message;
  TlsException(this.kind, this.message);
  @override
  String toString() => message;
}

/// Version of the native TLS library, e.g. "Mbed TLS 4.1.1".
String tlsLibraryVersion() => cString(atVersion());

/// Largest plaintext handed to the engine per call: 4 TLS records.
const int _writeChunk = 64 * 1024;

/// One TLS connection. Use [connect]; then [input] delivers plaintext and
/// [write] sends it. Every method runs on the caller's isolate.
class TlsSocket {
  final Socket _sock;
  Pointer<AtConn> _c;
  late final StreamSubscription<Uint8List> _sub;

  // Native scratch buffers, reused for every call.
  final Pointer<Uint8> _inBuf;
  int _inCap;
  final Pointer<Uint8> _plain;
  static const int _plainCap = 256 * 1024;

  final StreamController<Uint8List> _input = StreamController<Uint8List>(sync: true);
  Completer<void>? _handshake;
  bool _closed = false;
  String? _failure;

  // Back pressure: socket.flush() is awaited before more ciphertext is added.
  Future<void> _flushing = Future.value();
  int _unflushed = 0;

  /// Bytes, socket events and time spent in the native engine on the read
  /// path, for benchmarks.
  int plainIn = 0, plainOut = 0, socketReads = 0, engineMicros = 0;
  final Stopwatch _clock = Stopwatch()..start();

  TlsSocket._(this._sock, this._c)
      : _inCap = 256 * 1024,
        _inBuf = malloc<Uint8>(256 * 1024),
        _plain = malloc<Uint8>(_plainCap);

  /// Plaintext from the server. Completes when the server closes, and fails
  /// with [TlsException] on a TLS or network error.
  Stream<Uint8List> get input => _input.stream;

  /// The negotiated cipher suite.
  String get cipher => cString(atCipher(_c));

  /// Connects to [host]:[port] and completes the handshake. The server is
  /// trusted only if the SHA-256 of its certificate DER is [pin] (32 bytes).
  static Future<TlsSocket> connect(String host, int port, Uint8List pin,
      {Duration timeout = const Duration(seconds: 15)}) async {
    if (pin.length != 32) throw ArgumentError('pin must be 32 bytes');
    Socket sock;
    try {
      sock = await Socket.connect(host, port, timeout: timeout);
    } on SocketException catch (e) {
      throw TlsException(TlsFailure.network, '无法连接 $host:$port：${e.message}');
    }
    sock.setOption(SocketOption.tcpNoDelay, true);
    final pinPtr = malloc<Uint8>(32);
    pinPtr.asTypedList(32).setAll(0, pin);
    // The agent's certificate has no host name to check, so no SNI is sent
    // (Go's tls.Client sends none for an IP address either).
    final c = atNew(pinPtr, nullptr);
    malloc.free(pinPtr);
    if (c.address == 0) {
      sock.destroy();
      throw TlsException(TlsFailure.protocol, 'TLS 引擎初始化失败');
    }
    final t = TlsSocket._(sock, c);
    t._start();
    try {
      await t._doHandshake().timeout(timeout);
    } on TimeoutException {
      t.destroy();
      throw TlsException(TlsFailure.network, 'TLS 握手超时');
    } catch (_) {
      t.destroy();
      rethrow;
    }
    return t;
  }

  void _start() {
    _sub = _sock.listen(_onData, onError: (Object e) => _fail(TlsFailure.network, '连接错误：$e'), onDone: () {
      if (_closed) return;
      _fail(TlsFailure.network, '对端关闭了连接');
    });
  }

  Future<void> _doHandshake() {
    _handshake = Completer<void>();
    _step();
    return _handshake!.future;
  }

  void _onData(Uint8List data) {
    if (_closed) return;
    socketReads++;
    final t0 = _clock.elapsedMicroseconds;
    if (data.length > _inCap) {
      // Rare: a read larger than the scratch buffer. Feed in pieces.
      for (var off = 0; off < data.length; off += _inCap) {
        final end = off + _inCap > data.length ? data.length : off + _inCap;
        if (!_feed(Uint8List.sublistView(data, off, end))) return;
      }
    } else if (!_feed(data)) {
      return;
    }
    _step();
    engineMicros += _clock.elapsedMicroseconds - t0;
  }

  bool _feed(Uint8List chunk) {
    // One copy into native memory; the engine's BIO then takes it (a second
    // copy inside BoringSSL's memory BIO).
    _inBuf.asTypedList(chunk.length).setAll(0, chunk);
    if (atFeed(_c, _inBuf, chunk.length) != atOk) {
      _fail(TlsFailure.protocol, 'TLS 引擎内存不足');
      return false;
    }
    return true;
  }

  /// Advances the handshake or decrypts what is buffered, then sends any
  /// output the engine produced.
  void _step() {
    if (_closed) return;
    final hs = _handshake;
    if (hs != null && !hs.isCompleted) {
      final r = atHandshake(_c);
      _drainOut();
      if (r == atOk) {
        hs.complete();
      } else if (r != atWantIo) {
        _fail(r == atErrPin ? TlsFailure.pinMismatch : TlsFailure.protocol, _err(r));
        return;
      } else {
        return;
      }
    }
    // SSL_read returns one record (<= 16 KiB) per call; fill the scratch
    // buffer with as many as are ready and hand them on as one chunk, so the
    // reader above sees few, large chunks.
    var filled = 0;
    while (!_closed) {
      final n = atRead(_c, _plain + filled, _plainCap - filled);
      if (n > 0) {
        filled += n;
        plainIn += n;
        if (_plainCap - filled < 16 * 1024 + 256) {
          _emit(filled);
          filled = 0;
        }
        continue;
      }
      if (filled > 0) {
        _emit(filled);
        filled = 0;
      }
      if (n == 0) break;
      if (n == -atEof) {
        _drainOut();
        _closed = true;
        _input.close();
        _sock.destroy();
        return;
      }
      _fail(n == atErrPin ? TlsFailure.pinMismatch : TlsFailure.protocol, _err(n));
      return;
    }
    _drainOut();
  }

  /// Hands the first [n] bytes of the scratch buffer to the reader. A copy:
  /// the scratch buffer is reused by the next call.
  void _emit(int n) => _input.add(Uint8List.fromList(_plain.asTypedList(n)));

  String _err(int code) {
    if (code == atErrPin) return '服务器身份已变化（证书指纹不符）';
    final m = cString(atError(_c));
    return m.isEmpty ? 'TLS 错误 $code' : 'TLS 错误：$m';
  }

  void _drainOut() {
    final n = atOutLen(_c);
    if (n == 0) return;
    final bytes = Uint8List.fromList(atOutPtr(_c).asTypedList(n));
    atConsume(_c, n);
    _sock.add(bytes);
    _unflushed += n;
  }

  /// Encrypts and sends [data]. The future completes when the socket has
  /// taken it, which is the back pressure a writer must respect.
  Future<void> write(Uint8List data) async {
    if (_closed) throw TlsException(TlsFailure.network, _failure ?? '连接已关闭');
    var off = 0;
    final scratch = data.length <= _writeChunk ? data.length : _writeChunk;
    final p = malloc<Uint8>(scratch == 0 ? 1 : scratch);
    try {
      while (off < data.length) {
        final take = data.length - off < _writeChunk ? data.length - off : _writeChunk;
        p.asTypedList(take).setAll(0, Uint8List.sublistView(data, off, off + take));
        var done = 0;
        while (done < take) {
          final n = atWrite(_c, p + done, take - done);
          if (n < 0) {
            _fail(TlsFailure.protocol, _err(n));
            throw TlsException(TlsFailure.protocol, _failure!);
          }
          done += n;
          if (n == 0) break;
        }
        plainOut += done;
        off += done;
        _drainOut();
        if (_unflushed >= 256 * 1024) {
          _unflushed = 0;
          _flushing = _sock.flush();
          await _flushing;
        }
      }
    } finally {
      malloc.free(p);
    }
  }

  /// Waits until everything written has been handed to the OS.
  Future<void> flush() async {
    _unflushed = 0;
    await _sock.flush();
  }

  /// Sends close_notify and closes the socket.
  Future<void> close() async {
    if (_closed) return;
    atClose(_c);
    _drainOut();
    _closed = true;
    try {
      await _sock.flush();
      await _sock.close();
    } catch (_) {}
    _release();
    if (!_input.isClosed) await _input.close();
  }

  /// Drops the connection at once.
  void destroy() {
    if (!_closed) _closed = true;
    _sock.destroy();
    _release();
    if (!_input.isClosed) _input.close();
  }

  void _fail(TlsFailure kind, String msg) {
    if (_closed) return;
    _closed = true;
    _failure = msg;
    final err = TlsException(kind, msg);
    final hs = _handshake;
    if (hs != null && !hs.isCompleted) {
      hs.completeError(err);
    } else if (!_input.isClosed) {
      _input.addError(err);
      _input.close();
    }
    _sock.destroy();
    _release();
  }

  bool _released = false;
  void _release() {
    if (_released) return;
    _released = true;
    _sub.cancel();
    atFree(_c);
    _c = nullptr;
    malloc.free(_inBuf);
    malloc.free(_plain);
    _inCap = 0;
  }
}
