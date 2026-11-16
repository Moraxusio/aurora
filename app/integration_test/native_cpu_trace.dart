import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

/// Opt-in native diagnosis. Default frame-budget runs do not connect or sample.
class NativeCpuTrace {
  final WebSocket _socket;
  late final _messages = StreamIterator(_socket);
  final String _isolate = developer.Service.getIsolateId(Isolate.current)!;
  int _id = 0, _start = 0;
  NativeCpuTrace._(this._socket);

  static Future<NativeCpuTrace> start() async {
    final uri = (await developer.Service.getInfo()).serverUri;
    if (uri == null) {
      throw StateError('Native CPU trace needs the VM service');
    }
    final trace = NativeCpuTrace._(
      await WebSocket.connect(
        uri.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
      ),
    );
    await trace._call('setFlag', {'name': 'profiler', 'value': 'true'});
    await trace._call('clearCpuSamples', {'isolateId': trace._isolate});
    trace._start =
        (await trace._call('getVMTimelineMicros'))['timestamp'] as int;
    return trace;
  }

  Future<Map> _call(
    String method, [
    Map<String, Object> params = const {},
  ]) async {
    final id = '${++_id}';
    _socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    while (await _messages.moveNext().timeout(const Duration(seconds: 30))) {
      final response = jsonDecode(_messages.current as String) as Map;
      if (response['id'] != id) continue;
      if (response['error'] != null) {
        throw StateError('$method: ${response['error']}');
      }
      return response['result'] as Map;
    }
    throw StateError('VM service closed during $method');
  }

  Future<void> finish(String path) async {
    try {
      final end = (await _call('getVMTimelineMicros'))['timestamp'] as int;
      final samples = await _call('getCpuSamples', {
        'isolateId': _isolate,
        'timeOriginMicros': _start,
        'timeExtentMicros': end - _start,
      });
      await File(path).writeAsString(jsonEncode(samples));
    } finally {
      await _messages.cancel();
      await _socket.close();
    }
  }
}
