// Port forwarding (the "net" service, agent/internal/netfwd): a port on the
// server is opened on this machine's loopback, and every connection to it
// becomes one net.dial stream. The listener is bound to 127.0.0.1 only, so
// nothing on the network can use it. Forwarded traffic goes on the bulk
// priority: a download through a forward never delays a keystroke.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'link.dart';
import 'yamux.dart';

/// One open forward: local 127.0.0.1:[local] to [host]:[port] on the server.
class Forward {
  final String host;
  final int port;
  final int local;
  final ServerSocket _server;
  final Link _link;

  int connections = 0;
  int total = 0;
  int bytesIn = 0;
  int bytesOut = 0;

  /// The last connection error (the server could not reach the port).
  String? lastError;
  final Set<Socket> _open = {};
  bool _closed = false;

  Forward._(this.host, this.port, this.local, this._server, this._link);

  bool get isClosed => _closed;

  /// Listens on the loopback. [local] 0 picks a free port. Throws
  /// [SocketException] when the port is taken.
  static Future<Forward> start(Link link, {String host = '127.0.0.1', required int port, int local = 0}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, local);
    final f = Forward._(host, port, server.port, server, link);
    server.listen(f._accept, onError: (Object _) {}, cancelOnError: false);
    return f;
  }

  Future<void> _accept(Socket sock) async {
    if (_closed) {
      sock.destroy();
      return;
    }
    sock.setOption(SocketOption.tcpNoDelay, true);
    _open.add(sock);
    connections++;
    total++;
    OpStream? s;
    try {
      s = await _link.open('net.dial', {'host': host, 'port': port}, Priority.bulk);
      await s.response(); // the agent reached the port
    } on OpError catch (e) {
      lastError = e.message;
      _end(sock);
      s?.reset();
      return;
    }
    final stream = s;
    // socket -> server, with backpressure: the next chunk is read once the
    // last one has been handed to the session.
    late final StreamSubscription<Uint8List> sub;
    sub = sock.listen(
      (data) {
        sub.pause();
        bytesOut += data.length;
        stream.send(data).then((_) => sub.resume(), onError: (Object _) => sock.destroy());
      },
      onDone: () => stream.close().catchError((_) {}), // the client is done sending; the answer may still come
      onError: (Object _) => stream.reset(),
      cancelOnError: true,
    );
    // server -> socket
    try {
      while (true) {
        final chunk = await stream.readRaw();
        if (chunk == null) break;
        bytesIn += chunk.length;
        sock.add(chunk);
        await sock.flush();
      }
    } on Object {
      // the link dropped or the socket went away
    }
    await sub.cancel();
    _end(sock);
  }

  void _end(Socket sock) {
    if (_open.remove(sock)) connections--;
    sock.close().catchError((_) {});
    sock.destroy();
  }

  /// Stops listening and ends every connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
    for (final s in _open.toList()) {
      s.destroy();
    }
    _open.clear();
    connections = 0;
  }
}
