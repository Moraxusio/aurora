import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_tls/aurora_tls.dart';

import 'manifest.dart';

class UpgradePolicy {
  final Uint8List bytes;
  final String signature;
  final Set<String> revoked;
  final String? minOK;
  UpgradePolicy._(this.bytes, this.signature, this.revoked, this.minOK);

  factory UpgradePolicy.verify(Uint8List bytes, String signature, {List<Uint8List>? trusted}) {
    final Map<String, dynamic> p;
    Uint8List sig;
    try {
      p = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
      sig = base64.decode(signature.trim());
    } on Object { throw ManifestException('升级撤回清单格式无效'); }
    final keys = trusted ?? [base64.decode(releaseKeyBase64)];
    if (!keys.any((k) => keyIdOf(k) == p['key_id'] && ed25519Verify(bytes, sig, k))) throw ManifestException('升级撤回清单的签名无效');
    if (p['product'] != productAgent || p['channel'] != channelStable || p['created'] is! String || (p['created'] as String).isEmpty || p['revoked'] is! List) throw ManifestException('升级撤回清单的产品或格式无效');
    final rawVersions = p['revoked'] as List;
    if (rawVersions.any((v) => v is! String)) throw ManifestException('撤回清单的版本无效');
    final versions = rawVersions.cast<String>().toSet();
    final rawMin = p['min_ok'];
    if (rawMin != null && rawMin is! String) throw ManifestException('撤回清单的最低版本无效');
    final min = rawMin as String?;
    if ([...versions, if (min != null && min.isNotEmpty) min].any((v) => parseVersion(v) == null)) throw ManifestException('撤回清单的版本无效');
    return UpgradePolicy._(bytes, signature, versions, min == '' ? null : min);
  }

  static Future<UpgradePolicy?> open(String dir, {List<Uint8List>? trusted}) async {
    final file = File('$dir${Platform.pathSeparator}policy.json');
    final sig = File('$dir${Platform.pathSeparator}policy.sig');
    if (!await file.exists() && !await sig.exists()) return null; // old releases
    return UpgradePolicy.verify(await file.readAsBytes(), await sig.readAsString(), trusted: trusted);
  }

  String? refusal(String current, String target) {
    if (parseVersion(current) == null || parseVersion(target) == null) return '版本格式无效，不能安全比较';
    if (revoked.contains(target)) return '目标版本 $target 已撤回';
    if (minOK != null && compareVersions(target, minOK!)! < 0) return '目标版本低于最低安全版本 $minOK';
    final c = compareVersions(target, current)!;
    if (c == 0) return '已是此版本';
    if (c < 0 && !revoked.contains(current)) return '不能降级未撤回的版本';
    return null;
  }
}
