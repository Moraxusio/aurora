import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_tls/aurora_tls.dart' show hexOf, sha256;

/// Bounded development history is separate from the profile and document text.
/// Sections share a serial, encrypted record so task completion cannot overwrite
/// a breakpoint edit. A corrupt record is retained and never implicitly reset.
class DevelopmentStore {
  final Directory? directory;
  final Sealer? sealer;
  final Map<String, Map<String, dynamic>> _memory = {};
  final Map<String, Future<void>> _writers = {};
  static const maxBytes = 16 * 1024 * 1024;
  DevelopmentStore.memory() : directory = null, sealer = null;
  DevelopmentStore.file(this.directory, this.sealer);

  File _file(String server) => File(
    '${directory!.path}/'
    '${hexOf(sha256(Uint8List.fromList(utf8.encode(server))))}.dev',
  );

  Future<T> _serial<T>(String server, Future<T> Function() action) {
    final work = (_writers[server] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final tail = work.then<void>((_) {}, onError: (Object _) {});
    _writers[server] = tail;
    tail.then((_) {
      if (identical(_writers[server], tail)) _writers.remove(server);
    });
    return work;
  }

  Future<Map<String, dynamic>> _read(String server) async {
    if (directory == null) return _memory[server] ?? {};
    final file = _file(server);
    if (!await file.exists()) return {};
    final input = await file.open();
    late Uint8List bytes;
    try {
      if (await input.length() > maxBytes)
        throw const FormatException('开发历史超过存储预算');
      bytes = await input.read(maxBytes + 1);
    } finally {
      await input.close();
    }
    if (bytes.length > maxBytes) throw const FormatException('开发历史超过存储预算');
    final plain = sealer!.unseal(bytes);
    try {
      final record = jsonDecode(utf8.decode(plain));
      if (record is! Map ||
          record['version'] != 1 ||
          record['server'] != server ||
          record['sections'] is! Map) {
        throw const FormatException('开发历史格式无效，已保留原记录');
      }
      return (record['sections'] as Map).cast<String, dynamic>();
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  Future<Object?> read(String server, String section) =>
      _serial(server, () async {
        final value = (await _read(server))[section];
        return value == null ? null : jsonDecode(jsonEncode(value));
      });

  Future<void> write(String server, String section, Object value) {
    final snapshot = jsonDecode(jsonEncode(value));
    return _serial(server, () async {
      final record = await _read(server);
      record[section] = snapshot;
      if (directory == null) {
        _memory[server] = record;
        return;
      }
      final plain = Uint8List.fromList(
        utf8.encode(
          jsonEncode({'version': 1, 'server': server, 'sections': record}),
        ),
      );
      late Uint8List sealed;
      try {
        if (plain.length > maxBytes - 1024)
          throw const FormatException('开发历史超过存储预算');
        sealed = sealer!.seal(plain);
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
      await directory!.create(recursive: true);
      final file = _file(server), tmp = File('${_file(server).path}.tmp');
      try {
        await tmp.writeAsBytes(sealed, flush: true);
        await tmp.rename(file.path);
      } finally {
        if (await tmp.exists()) await tmp.delete();
      }
    });
  }
}
