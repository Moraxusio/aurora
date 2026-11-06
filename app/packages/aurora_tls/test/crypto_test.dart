import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_tls/aurora_tls.dart';
import 'package:test/test.dart';

Uint8List hex(String h) =>
    Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

void main() {
  // RFC 8032 section 7.1, TEST 1 (empty message) and TEST 2 (one byte).
  final pub1 = hex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a');
  final sig1 = hex('e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
      '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b');
  final pub2 = hex('3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c');
  final sig2 = hex('92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
      '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00');

  test('Ed25519: RFC 8032 vectors verify', () {
    expect(ed25519Verify(Uint8List(0), sig1, pub1), isTrue);
    expect(ed25519Verify(Uint8List.fromList([0x72]), sig2, pub2), isTrue);
  });

  test('Ed25519: any change is refused', () {
    expect(ed25519Verify(Uint8List.fromList([0x73]), sig2, pub2), isFalse, reason: 'message');
    final bad = Uint8List.fromList(sig2)..[10] ^= 1;
    expect(ed25519Verify(Uint8List.fromList([0x72]), bad, pub2), isFalse, reason: 'signature');
    expect(ed25519Verify(Uint8List.fromList([0x72]), sig2, pub1), isFalse, reason: 'key');
    expect(ed25519Verify(Uint8List(0), Uint8List(63), pub1), isFalse, reason: 'short signature');
    expect(ed25519Verify(Uint8List(0), sig1, Uint8List(31)), isFalse, reason: 'short key');
  });

  test('SHA-256: known values, one shot and in pieces', () {
    expect(hexOf(sha256(Uint8List(0))), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(hexOf(sha256(Uint8List.fromList(utf8.encode('abc')))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    final big = Uint8List(3 << 20); // crosses the 1 MiB staging buffer
    for (var i = 0; i < big.length; i++) {
      big[i] = i & 255;
    }
    final h = Sha256();
    for (var off = 0; off < big.length; off += 777777) {
      h.add(Uint8List.sublistView(big, off, off + 777777 > big.length ? big.length : off + 777777));
    }
    expect(hexOf(h.close()), hexOf(sha256(big)));
  });

  test('SHA-256 of a file equals SHA-256 of its bytes', () async {
    final dir = await Directory.systemTemp.createTemp('aurora3-sha-');
    try {
      final f = File('${dir.path}${Platform.pathSeparator}x.bin');
      final data = Uint8List.fromList([for (var i = 0; i < 2500000; i++) (i * 13) & 255]);
      await f.writeAsBytes(data);
      expect(await sha256File(f.path), hexOf(sha256(data)));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
