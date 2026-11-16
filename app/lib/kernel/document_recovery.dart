import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_tls/aurora_tls.dart' show hexOf, sha256;

/// A document is independent of tabs, split groups and the selected project.
class DocumentKey {
  final String server, root, path;
  DocumentKey(this.server, this.root, String path)
    : path = WorkspacePath.normalize(path);

  String get identity => jsonEncode([server, root, path]);
  Uri get uri => Uri(scheme: 'aurora', host: server, path: '/$root$path');
  Map<String, Object> toJson() => {
    'server': server,
    'root': root,
    'path': path,
  };
  factory DocumentKey.fromJson(Map j) => DocumentKey(
    j['server'] as String,
    j['root'] as String,
    j['path'] as String,
  );
  @override
  bool operator ==(Object other) =>
      other is DocumentKey && other.identity == identity;
  @override
  int get hashCode => Object.hash(server, root, path);
}

class DocumentRecovery {
  final DocumentKey key;
  final String text, baseText;
  final String encoding, savedEncoding;
  final String? etag;
  final int version, line, column, updatedAt;
  const DocumentRecovery({
    required this.key,
    required this.text,
    required this.baseText,
    this.encoding = 'utf-8',
    this.savedEncoding = 'utf-8',
    this.etag,
    required this.version,
    this.line = 0,
    this.column = 0,
    required this.updatedAt,
  });
  Map<String, Object?> toJson() => {
    'format': 1,
    'key': key.toJson(),
    'text': text,
    'base': baseText,
    'encoding': encoding,
    'savedEncoding': savedEncoding,
    'etag': etag,
    'version': version,
    'line': line,
    'column': column,
    'updated_at': updatedAt,
  };
  factory DocumentRecovery.fromJson(Map j) {
    if (j['format'] != 1) throw const FormatException('不支持的文档恢复格式');
    return DocumentRecovery(
      key: DocumentKey.fromJson(j['key'] as Map),
      text: j['text'] as String,
      baseText: j['base'] as String,
      encoding: j['encoding'] as String? ?? 'utf-8',
      savedEncoding: j['savedEncoding'] as String? ?? 'utf-8',
      etag: j['etag'] as String?,
      version: j['version'] as int,
      line: j['line'] as int,
      column: j['column'] as int,
      updatedAt: j['updated_at'] as int,
    );
  }
}

abstract interface class DocumentRecoveryStore {
  Future<DocumentRecovery?> load(DocumentKey key);
  Future<void> save(DocumentRecovery recovery);
  Future<void> remove(DocumentKey key);
  Future<List<DocumentRecovery>> list(String server);
}

/// Healthy checkpoints remain available when another record cannot be read.
class DocumentRecoveryScanError implements Exception {
  final List<DocumentRecovery> recovered;
  final List<String> unreadable;
  const DocumentRecoveryScanError(this.recovered, this.unreadable);
}

/// Used by isolated/in-memory workspaces, never by the production profile.
class MemoryDocumentRecoveryStore implements DocumentRecoveryStore {
  final Map<DocumentKey, DocumentRecovery> entries = {};
  @override
  Future<DocumentRecovery?> load(DocumentKey key) async => entries[key];
  @override
  Future<void> save(DocumentRecovery recovery) async =>
      entries[recovery.key] = recovery;
  @override
  Future<void> remove(DocumentKey key) async => entries.remove(key);
  @override
  Future<List<DocumentRecovery>> list(String server) async =>
      entries.values.where((e) => e.key.server == server).toList();
}

/// Separate per-document encrypted checkpoints: editing never rewrites the
/// complete profile (which can contain large proxy subscriptions).
class FileDocumentRecoveryStore implements DocumentRecoveryStore {
  final Directory directory;
  final Sealer sealer;
  final Map<String, Future<void>> _writers = {};
  static const maxBytes = 40 * 1024 * 1024;
  FileDocumentRecoveryStore(this.directory, this.sealer);

  File _file(DocumentKey key) => File(
    '${directory.path}/${hexOf(sha256(Uint8List.fromList(utf8.encode(key.identity))))}.doc',
  );

  Future<T> _serial<T>(DocumentKey key, Future<T> Function() action) {
    final id = key.identity;
    final work = (_writers[id] ?? Future<void>.value()).then((_) => action());
    final tail = work.then<void>((_) {}, onError: (Object _) {});
    _writers[id] = tail;
    unawaitedCleanup() async {
      await tail;
      if (identical(_writers[id], tail)) _writers.remove(id);
    }

    unawaitedCleanup();
    return work;
  }

  Future<DocumentRecovery> _read(File file) async {
    final input = await file.open();
    late Uint8List sealed;
    try {
      if (await input.length() > maxBytes)
        throw const FormatException('文档恢复记录过大');
      sealed = await input.read(maxBytes + 1);
      if (sealed.length > maxBytes) throw const FormatException('文档恢复记录过大');
    } finally {
      await input.close();
    }
    final plain = sealer.unseal(sealed);
    try {
      if (plain.length > maxBytes) throw const FormatException('文档恢复正文过大');
      return DocumentRecovery.fromJson(jsonDecode(utf8.decode(plain)) as Map);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  @override
  Future<DocumentRecovery?> load(DocumentKey key) => _serial(key, () async {
    final file = _file(key);
    if (!await file.exists()) return null;
    final result = await _read(file);
    if (result.key != key) throw const FormatException('文档恢复身份不匹配');
    return result;
  });

  @override
  Future<void> save(DocumentRecovery recovery) =>
      _serial(recovery.key, () async {
        final plain = Uint8List.fromList(
          utf8.encode(jsonEncode(recovery.toJson())),
        );
        late Uint8List bytes;
        try {
          if (plain.length > maxBytes) throw const FormatException('文档恢复正文过大');
          bytes = sealer.seal(plain);
        } finally {
          plain.fillRange(0, plain.length, 0);
        }
        await directory.create(recursive: true);
        final target = _file(recovery.key);
        final tmp = File('${target.path}.tmp');
        try {
          final out = await tmp.open(mode: FileMode.writeOnly);
          try {
            await out.writeFrom(bytes);
            await out.flush();
          } finally {
            await out.close();
          }
          await tmp.rename(target.path);
        } finally {
          if (await tmp.exists()) await tmp.delete();
        }
      });

  @override
  Future<void> remove(DocumentKey key) => _serial(key, () async {
    final file = _file(key);
    if (await file.exists()) await file.delete();
  });

  @override
  Future<List<DocumentRecovery>> list(String server) async {
    await Future.wait(_writers.values.toList());
    if (!await directory.exists()) return [];
    final out = <DocumentRecovery>[];
    final unreadable = <String>[];
    await for (final file in directory.list()) {
      if (file is! File || !file.path.endsWith('.doc')) continue;
      // Surface corruption to the recovery UI; do not overwrite or delete it.
      try {
        final recovery = await _read(file);
        if (_file(recovery.key).uri != file.uri)
          throw const FormatException('文档恢复身份不匹配');
        if (recovery.key.server == server) out.add(recovery);
      } on Object {
        unreadable.add(file.path);
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (unreadable.isNotEmpty) throw DocumentRecoveryScanError(out, unreadable);
    return out;
  }
}
