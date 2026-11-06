// Signed release manifests (agent/internal/update), checked before an agent
// build is uploaded to a server (D-3). Same rules as Go's update.VerifyFor:
// the ed25519 signature over the exact manifest bytes, a trusted key named by
// key_id, the expected product and channel, and well-formed fields.
import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora_tls/aurora_tls.dart';

/// The v3 release key (D-13, docs/DESIGN.md 5.10). Same bytes as
/// agent/internal/update/pubkey.go; key_id 87828dfb18459372.
const String releaseKeyBase64 = 'ZkXgb9QfuaRzm77NoOxMTOrB+8hMkbx2lc5gRTKdtrk=';

const String productAgent = 'aurora3-agent';
const String channelStable = 'stable';

class ManifestException implements Exception {
  final String message;
  ManifestException(this.message);
  @override
  String toString() => message;
}

class Manifest {
  final String product, channel, version, file, sha256, created, keyId;
  final int size;
  Manifest._(this.product, this.channel, this.version, this.file, this.size, this.sha256, this.created, this.keyId);
}

/// The first 16 hex digits of the SHA-256 of [pub] (update.KeyID).
String keyIdOf(Uint8List pub) => hexOf(sha256(pub)).substring(0, 16);

final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');
final _keyId = RegExp(r'^[0-9a-f]{16}$');
const int _maxSize = 2 << 30;

/// Verifies [manifestBytes] and its signature [sig] (base64 text, as in
/// manifest.sig, or 64 raw bytes) for [product] and [channel]. [trusted]
/// defaults to the release key.
Manifest verifyManifest(Uint8List manifestBytes, Uint8List sig,
    {String product = productAgent, String channel = channelStable, List<Uint8List>? trusted}) {
  final keys = trusted ?? [base64.decode(releaseKeyBase64)];
  Uint8List rawSig;
  try {
    rawSig = base64.decode(ascii.decode(sig).trim());
  } on FormatException {
    rawSig = sig;
  }
  Map<String, dynamic> j;
  try {
    final v = jsonDecode(utf8.decode(manifestBytes));
    if (v is! Map) throw const FormatException('not an object');
    j = v.cast<String, dynamic>();
  } on FormatException catch (e) {
    throw ManifestException('签名清单格式错误：${e.message}');
  }
  final keyId = j['key_id'] is String ? j['key_id'] as String : '';
  var matched = false;
  var ok = false;
  for (final k in keys) {
    if (keyId.isNotEmpty && keyId != keyIdOf(k)) continue;
    matched = true;
    if (ed25519Verify(manifestBytes, rawSig, k)) {
      ok = true;
      break;
    }
  }
  if (keyId.isNotEmpty && !matched) throw ManifestException('签名清单由不受信任的发布密钥 $keyId 签名');
  if (!ok) throw ManifestException('签名清单的签名无效');

  String str(String k) => j[k] is String ? j[k] as String : '';
  final m = Manifest._(str('product'), str('channel'), str('version'), str('file'),
      j['size'] is int ? j['size'] as int : -1, str('sha256'), str('created'), keyId);
  if (!_name.hasMatch(m.product) || !_name.hasMatch(m.channel)) throw ManifestException('签名清单的产品或渠道无效');
  if (m.version.isEmpty || m.version.contains(RegExp(r'\s'))) throw ManifestException('签名清单的版本无效');
  if (m.file.isEmpty || m.file.contains(RegExp(r'[/\\:]')) || m.file == '.' || m.file == '..') {
    throw ManifestException('签名清单的文件名无效');
  }
  if (m.size < 0 || m.size > _maxSize) throw ManifestException('签名清单的大小无效');
  if (!_hex64.hasMatch(m.sha256)) throw ManifestException('签名清单的 SHA-256 无效');
  if (m.created.isEmpty) throw ManifestException('签名清单缺少创建时间');
  if (keyId.isNotEmpty && !_keyId.hasMatch(keyId)) throw ManifestException('签名清单的密钥 id 无效');
  if (m.product != product) throw ManifestException('签名清单的产品是 ${m.product}，应为 $product');
  if (m.channel != channel) throw ManifestException('签名清单的渠道是 ${m.channel}，应为 $channel');
  return m;
}

/// Parses MAJOR.MINOR.PATCH with an optional +STAMP (update.ParseVersionStrict);
/// null when malformed.
(List<int>, int)? parseVersion(String v) {
  final m = RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\+([0-9]{1,18}))?$').firstMatch(v);
  if (m == null) return null;
  return ([int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)], m[4] == null ? 0 : int.parse(m[4]!));
}

/// -1, 0 or 1; null when either is malformed (update.CompareVersionStrict).
int? compareVersions(String a, String b) {
  final x = parseVersion(a), y = parseVersion(b);
  if (x == null || y == null) return null;
  for (var i = 0; i < 3; i++) {
    if (x.$1[i] != y.$1[i]) return x.$1[i] < y.$1[i] ? -1 : 1;
  }
  return x.$2.compareTo(y.$2).sign;
}
