import 'dart:async';
import 'dart:typed_data';

import 'package:aurora/features/files/remote_bytes.dart';
import 'package:aurora_wire/aurora_wire.dart';

/// A scripted fs.download stream: the announced metadata, then frames.
class FakeDownload implements DownloadStream {
  final Map<String, Object?> meta;
  final List<Frame?> frames;
  final Completer<void>? gate;
  bool wasReset = false, closed = false;
  int reads = 0;
  FakeDownload(this.meta, this.frames, {this.gate});
  @override
  Future<Object?> response() async => meta;
  @override
  Future<Frame?> read() async {
    reads++;
    if (gate != null && reads == 2) await gate!.future;
    return frames.isEmpty ? null : frames.removeAt(0);
  }

  @override
  void reset() => wasReset = true;
  @override
  Future<void> close() async => closed = true;

  /// A complete, well-formed download of [bytes].
  static FakeDownload of(List<int> bytes, {String etag = 'fixture'}) =>
      FakeDownload({'length': bytes.length, 'size': bytes.length, 'etag': etag}, [data(bytes), end()]);
}

Frame data(List<int> b) => Frame(typeData, Uint8List.fromList(b));
Frame end() => Frame(typeEnd, Uint8List(0));
