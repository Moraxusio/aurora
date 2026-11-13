import 'dart:convert';
import 'dart:typed_data';
import 'package:aurora/features/ai/ai_history.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';
import 'ai_feature_test.dart' show FakeAiLink;

class _HistoryStream implements OpStream {
  final List<Frame> frames;
  final int size;
  bool closed = false;
  _HistoryStream(this.frames, this.size);
  @override Future<Object?> response() async => {'size': size};
  @override Future<Frame?> read() async => frames.isEmpty ? null : frames.removeAt(0);
  @override void reset() { closed = true; }
  @override dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
class _HistoryLink extends FakeAiLink {
  final _HistoryStream history;
  _HistoryLink(this.history);
  @override AgentInfo get server => AgentInfo({'caps': ['ai.history']});
  @override Future<OpStream> open(String op, [Object? args, Priority priority = Priority.interactive]) async {
    expect(op, 'ai.history'); return history;
  }
}
void main() {
  test('history above one frame reassembles Unicode without changing wire limit', () async {
    final json = {'session': {'id': 'large', 'text': List.filled(100000, '中文与 shell 输出\n').join()}};
    final bytes = utf8.encode(jsonEncode(json));
    expect(bytes.length, greaterThan(1024 * 1024));
    final frames = <Frame>[];
    for (var i=0;i<bytes.length;i+=65537) { frames.add(Frame(typeData, Uint8List.fromList(bytes.sublist(i, (i+65537).clamp(0, bytes.length))))); }
    frames.add(Frame(typeEnd, Uint8List(0)));
    final stream = _HistoryStream(frames, bytes.length);
    expect(await loadAiHistory(_HistoryLink(stream), 'large'), json);
    expect(stream.closed, true);
  });
  test('truncated history is a recoverable error and releases stream', () async {
    final stream = _HistoryStream([Frame(typeData, Uint8List.fromList([123]))], 5);
    await expectLater(loadAiHistory(_HistoryLink(stream), 'large'), throwsStateError);
    expect(stream.closed, true);
  });
  test('old agents retain the ai.get compatibility path', () async {
    final link = FakeAiLink();
    final result = await loadAiHistory(link, 'ses_1');
    expect((result['session'] as Map)['id'], 'ses_1');
    expect(link.rpcCalls.single.$1, 'ai.get');
  });
}
