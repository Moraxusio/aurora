import 'dart:typed_data';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:test/test.dart';

void main() {
  test('take across chunks', () {
    final q = ByteQueue()
      ..add(Uint8List.fromList([1, 2]))
      ..add(Uint8List.fromList([3]))
      ..add(Uint8List.fromList([4, 5, 6]));
    expect(q.length, 6);
    expect(q.peekUint32(1), 0x02030405);
    expect(q.take(4), [1, 2, 3, 4]);
    expect(q.takeByte(), 5);
    expect(q.takeAll(), [6]);
    expect(q.isEmpty, isTrue);
  });

  test('frame encode and parse', () {
    final p = FrameParser();
    final f1 = encodeJson({'a': '中文'});
    final f2 = encodeFrame(typeData, List.filled(70000, 7));
    final all = Uint8List.fromList([...f1, ...f2]);
    for (var i = 0; i < all.length; i += 1000) {
      p.add(Uint8List.sublistView(all, i, i + 1000 > all.length ? all.length : i + 1000));
    }
    expect(p.next()!.json(), {'a': '中文'});
    final d = p.next()!;
    expect(d.isData, isTrue);
    expect(d.payload.length, 70000);
    expect(p.next(), isNull);
  });

  test('oversized frames are refused', () {
    expect(() => encodeFrame(typeData, Uint8List(maxFrame)), throwsA(isA<FrameTooLarge>()));
    final p = FrameParser()..add(Uint8List.fromList([0x7f, 0, 0, 0, typeData]));
    expect(p.next, throwsA(isA<FrameTooLarge>()));
  });
}
