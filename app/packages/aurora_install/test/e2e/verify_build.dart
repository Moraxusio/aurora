// Checks a release folder's agent build with the real release key, the way
// the packaged app does (no AURORA3_TRUST_KEY).
//   dart run test/e2e/verify_build.dart RELEASE_DIR\agent\amd64
import 'dart:io';

import 'package:aurora_install/aurora_install.dart';

Future<void> main(List<String> a) async {
  try {
    final b = await AgentBuild.open(a[0]);
    stdout.writeln('ok ${b.manifest.product} ${b.manifest.version} ${b.arch} key ${b.manifest.keyId}');
  } on Object catch (e) {
    stdout.writeln('refused: $e');
    exit(1);
  }
}
