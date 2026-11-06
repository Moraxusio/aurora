// Manifest checks against releases signed by Go (agent/cmd/aurora3-release).
// Set AURORA3_RELEASE_FIXTURE to a directory made by tool/fixture.ps1; it
// holds good/, a key file trust.pub, and spoiled copies. Without it the
// Go-signed cases are skipped; the pure-Dart cases always run.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_install/aurora_install.dart';
import 'package:test/test.dart';

void main() {
  final fx = Platform.environment['AURORA3_RELEASE_FIXTURE'];
  final skip = fx == null || fx.isEmpty ? 'AURORA3_RELEASE_FIXTURE not set' : null;
  final sep = Platform.pathSeparator;
  List<Uint8List> trust() => [base64.decode(File('$fx${sep}trust.pub').readAsStringSync().trim())];

  test('the release key is v3\'s (key_id 87828dfb18459372)', () {
    expect(keyIdOf(base64.decode(releaseKeyBase64)), '87828dfb18459372');
  });

  test('versions compare like update.CompareVersionStrict', () {
    expect(compareVersions('3.0.1', '3.0.2'), -1);
    expect(compareVersions('3.1.0', '3.0.9'), 1);
    expect(compareVersions('3.0.1+5', '3.0.1+12'), -1);
    expect(compareVersions('3.0.1', '3.0.1+0'), 0);
    expect(compareVersions('3.0.0-dev', '3.0.1'), isNull);
    expect(compareVersions('03.0.1', '3.0.1'), isNull);
  });

  test('a Go-signed build verifies', () async {
    final b = await AgentBuild.open('$fx${sep}good', trusted: trust());
    expect(b.manifest.product, 'aurora3-agent');
    expect(b.manifest.version, '3.0.1');
    expect(b.arch, 'amd64');
  }, skip: skip);

  test('the real release key does not accept the test signature', () async {
    await expectLater(AgentBuild.open('$fx${sep}good'), throwsA(isA<ManifestException>()));
  }, skip: skip);

  for (final (name, want) in [
    ('flipped-build', 'SHA-256'),
    ('flipped-manifest', '签名'),
    ('flipped-sig', '签名'),
    ('missing-build', '缺少'),
    ('v2-product', '产品'),
    ('other-key', '签名'),
  ]) {
    test('refused: $name', () async {
      await expectLater(AgentBuild.open('$fx$sep$name', trusted: trust()),
          throwsA(isA<ManifestException>().having((e) => e.message, 'message', contains(want))));
    }, skip: skip);
  }
}
