// Android has no "agent/ next to the executable": the signed agent ships as
// Flutter assets (assets/agent/...), which are unpacked once into the app's
// private directory. Unpacking is only a copy: AgentBuild.open still verifies
// the Ed25519 signature, size and SHA-256 of what it finds there, so a file
// changed on disk is refused exactly as on Windows.
import 'dart:io';

import 'package:flutter/services.dart';

/// Where the unpacked agent is, once [unpackAgentAssets] has run.
String? androidAgentDir;

const _prefix = 'assets/agent/';

/// Copies every asset under assets/agent/ into [target]. Files whose size
/// already matches are kept. Returns the number of files present.
Future<int> unpackAgentAssets(String target) async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  var n = 0;
  for (final key in manifest.listAssets()) {
    if (!key.startsWith(_prefix) || key.endsWith('.gitkeep')) continue;
    final data = await rootBundle.load(key);
    final f = File('$target/${key.substring(_prefix.length)}');
    await f.parent.create(recursive: true);
    if (!await f.exists() || await f.length() != data.lengthInBytes) {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      await tmp.rename(f.path);
    }
    n++;
  }
  androidAgentDir = target;
  return n;
}
