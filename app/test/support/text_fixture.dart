import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workspace_fixture.dart';

/// Scriptable framed peer for lifecycle tests; all files live in memory.
class TextPeer extends Fake implements OpStream {
  final frames = StreamController<Frame>();
  late final iterator = StreamIterator(frames.stream);
  final ended = Completer<void>(),
      resetDone = Completer<void>(),
      dataSeen = Completer<void>();
  final bytes = BytesBuilder(copy: false);
  Future<void> Function()? onEnd;
  Future<void> Function()? onData;
  bool closed = false;
  void json(Object value) {
    if (!closed)
      frames.add(
        Frame(typeJson, Uint8List.fromList(utf8.encode(jsonEncode(value)))),
      );
  }

  void ok(Object value) => json({'ok': true, 'result': value});
  void fail(String code, String message) =>
      json({'ok': false, 'code': code, 'error': message});
  void text(String value, [Map<String, Object?> metadata = const {}]) {
    if (closed) return;
    final encoded = utf8.encode(value);
    ok({'textBytes': encoded.length, ...metadata});
    for (var i = 0; i < encoded.length; i += 1001) {
      // Deliberately split UTF-8 codepoints at transport boundaries.
      frames.add(
        Frame(
          typeData,
          Uint8List.sublistView(
            encoded,
            i,
            (i + 1001).clamp(0, encoded.length),
          ),
        ),
      );
    }
    frames.add(Frame(typeEnd, Uint8List(0)));
  }

  @override
  Future<Frame?> read() async =>
      await iterator.moveNext() ? iterator.current : null;
  @override
  Future<Object?> response() async {
    final frame = await read();
    if (frame == null) throw OpError(codeUnavailable, 'closed');
    final value = frame.json() as Map;
    if (value['ok'] != true)
      throw OpError(value['code'] as String, value['error'] as String);
    return value['result'];
  }

  @override
  Future<void> sendData(List<int> value) async {
    if (closed) throw StateError('closed');
    bytes.add(value);
    if (!dataSeen.isCompleted) dataSeen.complete();
    await onData?.call();
  }

  @override
  Future<void> sendEnd() async {
    if (!ended.isCompleted) ended.complete();
    await onEnd?.call();
  }

  @override
  void reset() {
    if (closed) return;
    closed = true;
    resetDone.complete();
    unawaited(frames.close());
  }
}

class TextFixtureLink extends FileTreeLink {
  final contents = <String, String>{'/a': 'original\n', '/b': 'second\n'};
  final encodings = <String, String>{};
  final tags = <String, String>{};
  final opens = <({String op, Map args, TextPeer peer})>[];
  final opened = StreamController<void>.broadcast();
  void Function(String op, Map args, TextPeer peer)? configure;
  Completer<OpStream>? openGate;
  Completer<void>? commitGate;
  Completer<Object?>? statGate;
  int serial = 0, stats = 0;
  bool rejectCommit = false;
  bool strictFiles = false;
  @override
  AgentInfo get server => AgentInfo({
    'caps': [
      'fs.text',
      'fs.commit',
      'fs.refactor',
      'fs.replace.preview',
      'fs.read',
    ],
  });
  String tag(String path) => tags[path] ?? 'v1';
  Future<TextPeer> saw(String op, {int count = 1}) async {
    while (opens.where((o) => o.op == op).length < count) {
      await opened.stream.first.timeout(const Duration(seconds: 3));
    }
    return opens.where((o) => o.op == op).elementAt(count - 1).peer;
  }

  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    if (op == 'fs.stat') {
      stats++;
      return statGate?.future ?? {'etag': tag((args as Map)['path'] as String)};
    }
    if (op == 'fs.search')
      return {
        'files': [
          for (final entry in contents.entries)
            {
              'path': entry.key,
              'matches': [
                {'line': 1, 'text': entry.value},
              ],
            },
        ],
      };
    return super.call(op, args, timeout);
  }

  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) async {
    final peer = TextPeer(), params = args as Map;
    opens.add((op: op, args: params, peer: peer));
    opened.add(null);
    if (op == 'fs.text') {
      final path = params['path'] as String;
      final encoding = encodings[path] ?? 'utf-8';
      if (strictFiles && !contents.containsKey(path)) {
        peer.fail(codeNotFound, 'not found');
      } else if (params['encoding'] != 'auto' &&
          params['encoding'] != encoding) {
        peer.fail(codeBadRequest, 'wrong encoding');
      } else {
        peer.text(contents[path] ?? '', {
          'etag': tag(path),
          'encoding': encoding,
          'size': contents[path]?.length ?? 0,
        });
      }
    } else {
      peer.ok({'ready': true});
      peer.onEnd = () async {
        if (op == 'fs.replace.preview') {
          peer.text(
            utf8
                .decode(peer.bytes.toBytes())
                .replaceAll(
                  params['query'] as String,
                  params['replacement'] as String,
                ),
          );
          return;
        }
        if (rejectCommit) {
          peer.fail(codeConflict, 'external conflict');
          return;
        }
        final all = peer.bytes.toBytes(), results = <Map<String, Object?>>[];
        if (strictFiles) {
          for (final change in params['changes'] as List) {
            final path = change['path'] as String;
            if (change['create'] == true
                ? contents.containsKey(path)
                : !contents.containsKey(path) ||
                      change['if_match'] != tag(path)) {
              peer.fail(codeConflict, 'version conflict');
              return;
            }
          }
        }
        var offset = 0;
        for (final change in params['changes'] as List) {
          final path = change['path'] as String, size = change['size'] as int;
          if (change['delete'] == true) {
            contents.remove(path);
          } else {
            contents[path] = utf8.decode(all.sublist(offset, offset + size));
          }
          offset += size;
          encodings[path] = change['encoding'] as String;
          tags[path] = 'v${++serial + 1}';
          results.add({
            'root': change['root'],
            'path': path,
            'etag': tag(path),
            'deleted': change['delete'] == true,
            if (change['modeBits'] != null) 'modeBits': change['modeBits'],
          });
        }
        await commitGate?.future;
        peer.ok({'files': results});
      };
    }
    configure?.call(op, params, peer);
    return openGate?.future ?? peer;
  }

  void disposeFixture() {
    for (final item in opens) {
      item.peer.reset();
    }
    unawaited(opened.close());
  }
}
