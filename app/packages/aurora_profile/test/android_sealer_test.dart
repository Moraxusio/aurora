import 'dart:typed_data';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:test/test.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  test('AES-GCM round trip, 1 MiB', () {
    final s = AndroidSealer(key);
    final plain = Uint8List.fromList(List.generate(1 << 20, (i) => i & 255));
    final sealed = s.seal(plain);
    expect(sealed.length, plain.length + 12 + 16);
    expect(s.unseal(sealed), plain);
  });
  test('nonce differs per seal', () {
    final s = AndroidSealer(key);
    final p = Uint8List.fromList([1, 2, 3]);
    expect(s.seal(p), isNot(s.seal(p)));
  });
  test('tampering, wrong key and wrong purpose are rejected', () {
    final s = AndroidSealer(key);
    final sealed = s.seal(Uint8List.fromList([9, 8, 7, 6]));
    final bad = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
    expect(() => s.unseal(bad), throwsA(isA<SealerException>()));
    final other = Uint8List.fromList(key)..[0] ^= 1;
    expect(() => AndroidSealer(other).unseal(sealed), throwsA(isA<SealerException>()));
    expect(() => AndroidSealer(key, purpose: 'x').unseal(sealed), throwsA(isA<SealerException>()));
    expect(() => s.unseal(Uint8List(5)), throwsA(isA<SealerException>()));
  });
  test('short key is refused', () {
    expect(() => AndroidSealer(Uint8List(16)), throwsA(isA<SealerException>()));
  });
}
