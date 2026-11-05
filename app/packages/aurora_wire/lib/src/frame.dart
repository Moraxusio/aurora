// Aurora's operation frames (agent/internal/wire/frame.go): a 4-byte
// big-endian length that counts the type byte, a 1-byte type and the payload.
import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';
import 'yamux.dart';

/// Largest frame (type byte included), as in wire.MaxFrame.
const int maxFrame = 1 << 20;

/// Payload size the agent uses for bulk transfers (wire.DataChunk).
const int dataChunk = 256 * 1024;

const int typeJson = 0x4A; // 'J'
const int typeData = 0x44; // 'D'
const int typeEnd = 0x45; // 'E'

class FrameTooLarge implements Exception {
  final int size;
  FrameTooLarge(this.size);
  @override
  String toString() => 'frame too large: $size';
}

/// Encodes one frame into a single buffer, so it is written in one call.
Uint8List encodeFrame(int type, List<int> payload) {
  if (payload.length + 1 > maxFrame) throw FrameTooLarge(payload.length + 1);
  final out = Uint8List(5 + payload.length);
  ByteData.sublistView(out).setUint32(0, payload.length + 1);
  out[4] = type;
  out.setRange(5, out.length, payload);
  return out;
}

Uint8List encodeJson(Object? value) => encodeFrame(typeJson, utf8.encode(jsonEncode(value)));

class Frame {
  final int type;
  final Uint8List payload;
  Frame(this.type, this.payload);

  bool get isJson => type == typeJson;
  bool get isData => type == typeData;
  bool get isEnd => type == typeEnd;

  /// Decodes a JSON frame; throws [FormatException] for any other type.
  Object? json() {
    if (!isJson) {
      throw FormatException('expected JSON frame, got ${String.fromCharCode(type)}');
    }
    return jsonDecode(utf8.decode(payload));
  }
}

/// Splits a byte queue into frames.
class FrameParser {
  final ByteQueue _q = ByteQueue();

  void add(Uint8List chunk) => _q.add(chunk);

  int get buffered => _q.length;

  /// The next whole frame, or null when more bytes are needed.
  Frame? next() {
    if (_q.length < 4) return null;
    final n = _q.peekUint32(0);
    if (n < 1 || n > maxFrame) throw FrameTooLarge(n);
    if (_q.length < 4 + n) return null;
    _q.skip(4);
    final type = _q.takeByte();
    return Frame(type, _q.take(n - 1));
  }
}

/// Reads frames from one yamux stream.
class FrameReader {
  final YamuxStream _st;
  final FrameParser _p = FrameParser();
  FrameReader(this._st);

  /// The next frame, or null when the stream ends cleanly between frames.
  Future<Frame?> read() async {
    while (true) {
      final f = _p.next();
      if (f != null) return f;
      final c = await _st.next();
      if (c == null) {
        if (_p.buffered == 0) return null;
        throw YamuxException('stream ended inside a frame');
      }
      _p.add(c);
    }
  }
}
