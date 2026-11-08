import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_install/aurora_install.dart';
import 'package:test/test.dart';

void main() {
  final fx = Platform.environment['AURORA3_UPGRADE_FIXTURE'];
  final skip = fx == null || fx.isEmpty ? 'AURORA3_UPGRADE_FIXTURE not set' : null;
  final sep = Platform.pathSeparator;

  Uint8List trust() => base64.decode(File('$fx${sep}trust.pub').readAsStringSync().trim());
  Future<UpgradePolicy> policy(String name) async => UpgradePolicy.verify(
        await File('$fx$sep$name.json').readAsBytes(),
        await File('$fx$sep$name.sig').readAsString(),
        trusted: [trust()],
      );

  test('Go-signed policy verifies and has the same safety decisions', () async {
    final p = await policy('normal');
    expect(p.refusal('3.3.0', '3.3.1'), isNull);
    expect(p.refusal('3.3.0', '3.2.9'), contains('最低安全版本'));
    expect(p.refusal('3.3.1', '3.3.0'), contains('降级'));
  }, skip: skip);

  test('Go-signed revocation permits only a safe rollback', () async {
    final p = await policy('revoke-current');
    expect(p.revoked, contains('3.3.1'));
    expect(p.refusal('3.3.1', '3.3.0'), isNull);
    expect(p.refusal('3.3.1', '3.2.9'), contains('最低安全版本'));
    expect(p.refusal('3.3.0', '3.2.9'), contains('最低安全版本'));
  }, skip: skip);

  test('policy bytes and signature tampering are refused', () async {
    final bytes = await File('$fx${sep}normal.json').readAsBytes();
    final sig = await File('$fx${sep}normal.sig').readAsString();
    bytes[0] ^= 1;
    expect(() => UpgradePolicy.verify(bytes, sig, trusted: [trust()]), throwsA(isA<ManifestException>()));
  }, skip: skip);
}
