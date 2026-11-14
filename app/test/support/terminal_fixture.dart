import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';

/// In-memory operation stream for the real wire terminal and SessionView.
/// Never starts a shell, reads a profile, or connects to a server.
class MemoryTerminalStream implements OpStream {
  final ready = Completer<void>();
  final Queue<Frame> frames = Queue();
  final controls = <Map>[];
  final input = <List<int>>[];
  Completer<Frame?>? pending;
  int closes = 0;
  MemoryTerminalStream({bool hold = false}) {
    if (!hold) ready.complete();
  }
  @override
  Future<Object?> response() async {
    await ready.future;
    return null;
  }

  @override
  Future<Frame?> read() async {
    if (frames.isNotEmpty) return frames.removeFirst();
    if (closes > 0) return null;
    pending = Completer<Frame?>();
    return pending!.future;
  }

  void output(String text) {
    final frame = Frame(typeData, Uint8List.fromList(utf8.encode(text)));
    final next = pending;
    pending = null;
    if (next != null) {
      next.complete(frame);
    } else {
      frames.add(frame);
    }
  }

  @override
  Future<void> sendJson(Object? data) async {
    controls.add(data as Map);
  }

  @override
  Future<void> sendData(List<int> data) async { input.add(List<int>.of(data)); }
  @override
  Future<void> close() async {
    closes++;
    pending?.complete(null);
    pending = null;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
