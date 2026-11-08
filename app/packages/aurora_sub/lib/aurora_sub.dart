/// Reads a proxy subscription into nodes the agent can use
/// (docs/DESIGN.md D-84 to D-88). Pure Dart: no network and no Flutter.
library;

import 'src/clash.dart';
import 'src/links.dart';
import 'src/node.dart';

export 'src/fetch.dart';
export 'src/links.dart' show parseLink;
export 'src/node.dart';

/// Reads a subscription as it was downloaded. Clash YAML is tried when the text
/// has a `proxies:` section; otherwise it is read as share links, base64 or not.
SubResult parseSubscription(String body) {
  var text = body.trim();
  if (text.startsWith('\uFEFF')) text = text.substring(1).trim();
  if (text.isEmpty) return SubResult([], ['订阅内容是空的'], 'unknown');

  final decoded = decodeBlock(text);
  if (decoded != null) text = decoded.trim();

  if (RegExp(r'^proxies\s*:', multiLine: true).hasMatch(text)) {
    return parseClash(text);
  }
  if (text.contains('://')) {
    final r = parseLinks(text);
    if (r.nodes.isNotEmpty || r.skipped.isNotEmpty) return r;
  }
  return SubResult([], ['不认识的订阅格式（需要 Clash 配置，或每行一个节点链接）'], 'unknown');
}
