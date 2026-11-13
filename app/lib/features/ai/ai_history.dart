import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';

/// New agents stream complete JSON in bounded frames; older agents retain ai.get.
Future<Map<String, dynamic>> loadAiHistory(Link link, String id) async {
  if (!link.server.caps.contains('ai.history')) {
    return (await link.call('ai.get', {'id': id}) as Map)
        .cast<String, dynamic>();
  }
  final stream = await link.open('ai.history', {'id': id});
  try {
    final meta = await stream.response() as Map;
    final size = (meta['size'] as num?)?.toInt() ?? -1;
    if (size < 0 || size > 64 * 1024 * 1024) throw StateError('会话历史大小无效');
    final bytes = BytesBuilder(copy: false);
    while (true) {
      final frame = await stream.read();
      if (frame == null) throw StateError('会话历史传输中断，请重试');
      if (frame.type == typeEnd) break;
      if (frame.type != typeData) throw StateError('会话历史数据无效');
      bytes.add(frame.payload);
      if (bytes.length > size) throw StateError('会话历史长度不匹配');
    }
    if (bytes.length != size) throw StateError('会话历史传输不完整，请重试');
    return (jsonDecode(utf8.decode(bytes.takeBytes())) as Map)
        .cast<String, dynamic>();
  } finally {
    stream.reset();
  }
}
