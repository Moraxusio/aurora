import 'dart:async';
import 'dart:convert';

import 'package:aurora_wire/aurora_wire.dart';

class ProtocolError implements Exception {
  final String message;
  const ProtocolError(this.message);
  @override
  String toString() => message;
}

/// Correlates LSP/DAP messages over a single cancellable agent-owned process.
/// A serial writer preserves didChange/request order; server requests never
/// block reading unrelated replies while a user reviews an edit.
class ProtocolPeer {
  final OpStream stream;
  final bool dap;
  final Map<String, dynamic> metadata;
  final Map<int, Completer<Object?>> _pending = {};
  int _next = 0;
  bool _closed = false;
  int _serverRequests = 0;
  final _done = Completer<void>();
  Future<void> get done => _done.future;
  Future<void> _write = Future.value();
  FutureOr<Object?> Function(String method, Map<String, dynamic> params)?
  onRequest;
  void Function(String method, Map<String, dynamic> params)? onNotification;
  void Function(Map<String, dynamic>)? onTransport;
  void Function()? onClosed;
  ProtocolPeer._(this.stream, this.metadata, this.dap);
  bool get closed => _closed;

  static Future<ProtocolPeer> open(
    Link link,
    String op,
    Map<String, Object?> args, {
    required bool Function() active,
    bool dap = false,
  }) async {
    final stream = await link.open(op, args);
    try {
      if (!active()) throw const ProtocolError('连接已变化');
      final metadata =
          await stream.response().timeout(const Duration(seconds: 15)) as Map;
      if (!active()) throw const ProtocolError('连接已变化');
      final peer = ProtocolPeer._(
        stream,
        metadata.cast<String, dynamic>(),
        dap,
      );
      unawaited(peer._read());
      return peer;
    } on Object {
      stream.reset();
      rethrow;
    }
  }

  Future<void> send(Map<String, Object?> message) {
    if (_closed) return Future.error(const ProtocolError('开发工具已停止'));
    final data = utf8.encode(jsonEncode(message));
    if (data.length >= maxFrame)
      return Future.error(const ProtocolError('开发协议消息超过 1 MiB'));
    final write = _write.then((_) {
      if (_closed) throw const ProtocolError('开发工具已停止');
      return stream.sendData(data);
    });
    _write = write.then<void>((_) {}, onError: (Object e) => close(e));
    return write;
  }

  Future<Object?> request(
    String method, [
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 20),
  ]) async {
    if (_closed) throw const ProtocolError('开发工具已停止');
    if (_pending.length >= 64) throw const ProtocolError('开发工具请求达到并发上限');
    final id = ++_next, result = Completer<Object?>();
    _pending[id] = result;
    final timer = Timer(timeout, () {
      if (_pending.remove(id) == null) return;
      result.completeError(ProtocolError('$method 请求超时'));
      if (!dap)
        unawaited(
          notify(r'$/cancelRequest', {'id': id}).catchError((Object _) {}),
        );
    });
    // Observe the future before writing, since a disconnected peer can fail
    // pending requests while sendData is still completing.
    final answer = result.future.whenComplete(() {
      timer.cancel();
      _pending.remove(id);
    });
    unawaited(
      send(
        dap
            ? {
                'seq': id,
                'type': 'request',
                'command': method,
                'arguments': params,
              }
            : {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params},
      ).catchError((Object e) {
        if (!result.isCompleted) result.completeError(e);
      }),
    );
    return answer;
  }

  Future<void> notify(String method, Map<String, Object?> params) =>
      send({'jsonrpc': '2.0', 'method': method, 'params': params});

  Future<void> _read() async {
    Object? failure;
    try {
      while (!_closed) {
        final frame = await stream.read();
        if (frame == null || frame.type == typeEnd) break;
        final raw = jsonDecode(utf8.decode(frame.payload));
        if (raw is! Map) throw const ProtocolError('开发工具返回无效 JSON 对象');
        final message = raw.cast<String, dynamic>();
        if (frame.type == typeJson) {
          onTransport?.call(message);
          if (message['type'] == 'exit' || message['type'] == 'error') break;
          continue;
        }
        if (frame.type != typeData) throw const ProtocolError('开发工具返回无效帧');
        final id = dap ? message['request_seq'] : message['id'];
        final response = dap
            ? message['type'] == 'response'
            : !message.containsKey('method');
        if (response) {
          final pending = _pending.remove(id);
          if (pending == null || pending.isCompleted) continue;
          if (message['error'] != null || (dap && message['success'] != true)) {
            final error = message['error'];
            pending.completeError(
              ProtocolError(
                error is Map
                    ? '${error['message']}'
                    : '${message['message'] ?? error}',
              ),
            );
          } else {
            pending.complete(dap ? message['body'] : message['result']);
          }
        } else if (dap
            ? message['type'] == 'request'
            : message.containsKey('id')) {
          unawaited(_serverRequest(message));
        } else {
          final method = dap ? message['event'] : message['method'];
          final params = dap ? message['body'] : message['params'];
          if (method is String)
            onNotification?.call(
              method,
              params is Map ? params.cast<String, dynamic>() : {},
            );
        }
      }
    } on Object catch (e) {
      failure = e;
    } finally {
      close(failure);
    }
  }

  Future<void> _serverRequest(Map<String, dynamic> message) async {
    final method = '${dap ? message['command'] : message['method']}';
    final params = (dap ? message['arguments'] : message['params']);
    Object? result, error;
    final admitted = _serverRequests < 8;
    if (admitted) _serverRequests++;
    try {
      if (!admitted) throw const ProtocolError('服务端请求超过 8 个并发预算');
      if (onRequest == null) throw ProtocolError('不支持服务端请求：$method');
      result = await Future.any<Object?>([
        Future.sync(
          () => onRequest!(
            method,
            params is Map ? params.cast<String, dynamic>() : {},
          ),
        ),
        done.then<Object?>((_) => throw const ProtocolError('开发工具已停止')),
      ]);
    } on Object catch (e) {
      error = e;
    } finally {
      if (admitted) _serverRequests--;
    }
    if (_closed) return;
    try {
      await send(
        dap
            ? {
                'seq': ++_next,
                'type': 'response',
                'request_seq': message['seq'],
                'command': method,
                'success': error == null,
                if (error == null) 'body': result,
                if (error != null) 'message': '$error',
              }
            : {
                'jsonrpc': '2.0',
                'id': message['id'],
                if (error == null) 'result': result,
                if (error != null)
                  'error': {'code': -32601, 'message': '$error'},
              },
      );
    } on Object {
      /* Closing a process cancels server-side requests as well. */
    }
  }

  void close([Object? cause]) {
    if (_closed) return;
    _closed = true;
    _done.complete();
    stream.reset();
    for (final pending in _pending.values) {
      if (!pending.isCompleted)
        pending.completeError(cause ?? const ProtocolError('开发工具已停止'));
    }
    _pending.clear();
    onClosed?.call();
  }
}
