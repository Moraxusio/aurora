import 'dart:convert';

import 'node.dart';

/// Reads a list of share links, one per line: trojan://, hysteria2:// (hy2://),
/// vless://, vmess://, and ss:// (kept as a node the agent cannot use yet).
/// The whole text may itself be base64, as many providers send it.
SubResult parseLinks(String text) {
  final nodes = <SubNode>[];
  final skipped = <String>[];
  for (final raw in text.split(RegExp(r'[\r\n]+'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    try {
      final n = parseLink(line);
      if (n == null) {
        skipped.add('${_shorten(line)}：不是已知的链接');
      } else {
        nodes.add(n);
      }
    } on FormatException catch (e) {
      skipped.add('${_shorten(line)}：${e.message}');
    }
  }
  return SubResult(nodes, skipped, 'links');
}

/// A line, cut short and with anything after "://" hidden, for messages: a
/// link carries a password and an error message must not repeat it.
String _shorten(String line) {
  final i = line.indexOf('://');
  if (i < 0) return line.length > 24 ? '${line.substring(0, 24)}…' : line;
  return '${line.substring(0, i + 3)}…';
}

/// One link, or null when its scheme is not one this reads.
SubNode? parseLink(String link) {
  final i = link.indexOf('://');
  if (i < 0) return null;
  final scheme = link.substring(0, i).toLowerCase();
  switch (scheme) {
    case 'vmess':
      return _vmess(link.substring(i + 3));
    case 'vless':
      return _vless(Uri.parse(link));
    case 'trojan':
      return _trojan(Uri.parse(link));
    case 'hysteria2' || 'hy2':
      return _hy2(Uri.parse(link));
    case 'ss':
      return _ss(link);
    case 'tuic' || 'anytls' || 'hysteria' || 'ssr' || 'wireguard':
      return _opaque(scheme, Uri.parse(link));
  }
  return null;
}

String _name(Uri u, String fallback) {
  final f = u.fragment;
  if (f.isEmpty) return fallback;
  try {
    return Uri.decodeComponent(f);
  } on ArgumentError {
    return f;
  }
}

String _q(Uri u, String k) => u.queryParameters[k] ?? '';

int _port(Uri u) {
  if (!u.hasPort || u.port < 1) throw const FormatException('缺少端口');
  return u.port;
}

String _user(Uri u) {
  try {
    return Uri.decodeComponent(u.userInfo);
  } on ArgumentError {
    return u.userInfo;
  }
}

// ---- vmess://<base64 of a JSON object> ----

SubNode _vmess(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(_b64(body)));
  } catch (_) {
    throw const FormatException('vmess 链接的内容不是有效的 base64 JSON');
  }
  if (decoded is! Map) throw const FormatException('vmess 链接的内容不是对象');
  final Map j = decoded;
  String s(String k) => j[k] == null ? '' : '${j[k]}'.trim();
  final host = s('add'), port = int.tryParse(s('port')) ?? 0;
  if (host.isEmpty || port < 1 || port > 65535) throw const FormatException('缺少地址或端口');
  final n = SubNode(proto: 'vmess', host: host, port: port, name: s('ps'), secret: s('id'), cipher: s('scy'));
  final reasons = <String>[];
  n.tls = s('tls') == 'tls';
  n.sni = s('sni');
  if (n.sni.isEmpty && n.tls) n.sni = s('host');
  n.insecure = s('allowInsecure') == '1' || s('allowInsecure') == 'true';
  if (s('alpn').isNotEmpty) n.alpn = s('alpn').split(',');
  if ((int.tryParse(s('aid')) ?? 0) != 0) reasons.add('旧版 VMess（alterId 不为 0）暂不支持');
  switch (s('net')) {
    case '' || 'tcp':
      if (s('type').isNotEmpty && s('type') != 'none') reasons.add('HTTP 伪装头暂不支持');
    case 'ws':
      n.transport = 'ws';
      n.wsPath = s('path');
      n.wsHost = s('host');
    default:
      reasons.add('传输方式 ${s('net')} 暂不支持（支持 tcp、ws）');
  }
  if (reasons.isNotEmpty) n.unsupported = reasons.join('；');
  return n;
}

// ---- vless://uuid@host:port?type=ws&security=tls&sni=..&flow=..#name ----

SubNode _vless(Uri u) {
  final n = SubNode(proto: 'vless', host: u.host, port: _port(u), name: _name(u, u.host), secret: _user(u));
  final reasons = <String>[];
  final sec = _q(u, 'security');
  n.tls = sec == 'tls' || sec == 'reality';
  if (sec == 'reality') reasons.add('Reality 暂不支持');
  n.sni = _q(u, 'sni').isNotEmpty ? _q(u, 'sni') : _q(u, 'peer');
  n.insecure = _q(u, 'allowInsecure') == '1' || _q(u, 'insecure') == '1';
  if (_q(u, 'alpn').isNotEmpty) n.alpn = _q(u, 'alpn').split(',');
  n.flow = _q(u, 'flow');
  final enc = _q(u, 'encryption');
  if (enc.isNotEmpty && enc != 'none') reasons.add('VLESS Encryption 暂不支持');
  _linkTransport(n, _q(u, 'type'), u, reasons);
  if (reasons.isNotEmpty) n.unsupported = reasons.join('；');
  return n;
}

void _linkTransport(SubNode n, String type, Uri u, List<String> reasons) {
  switch (type) {
    case '' || 'tcp':
      if (_q(u, 'headerType').isNotEmpty && _q(u, 'headerType') != 'none') reasons.add('HTTP 伪装头暂不支持');
    case 'ws':
      n.transport = 'ws';
      n.wsPath = _q(u, 'path');
      n.wsHost = _q(u, 'host');
    default:
      reasons.add('传输方式 $type 暂不支持（支持 tcp、ws）');
  }
}

// ---- trojan://password@host:port?sni=..&type=ws#name ----

SubNode _trojan(Uri u) {
  final n = SubNode(proto: 'trojan', host: u.host, port: _port(u), name: _name(u, u.host), secret: _user(u), tls: true);
  final reasons = <String>[];
  n.sni = _q(u, 'sni').isNotEmpty ? _q(u, 'sni') : _q(u, 'peer');
  n.insecure = _q(u, 'allowInsecure') == '1' || _q(u, 'insecure') == '1';
  if (_q(u, 'alpn').isNotEmpty) n.alpn = _q(u, 'alpn').split(',');
  final sec = _q(u, 'security');
  if (sec == 'reality') reasons.add('Reality 暂不支持');
  _linkTransport(n, _q(u, 'type'), u, reasons);
  if (n.transport == 'ws') reasons.add('Trojan 经 WebSocket 暂不支持');
  if (reasons.isNotEmpty) n.unsupported = reasons.join('；');
  return n;
}

// ---- hysteria2://password@host:port?sni=..&obfs=salamander&obfs-password=..#name ----

SubNode _hy2(Uri u) {
  // A password with a colon is "user:pass" in the userinfo and is the whole
  // authentication string for Hysteria2.
  final n = SubNode(proto: 'hysteria2', host: u.host, port: _port(u), name: _name(u, u.host), secret: _user(u), tls: true);
  final reasons = <String>[];
  n.sni = _q(u, 'sni');
  n.insecure = _q(u, 'insecure') == '1' || _q(u, 'allowInsecure') == '1';
  final pin = _q(u, 'pinSHA256').replaceAll(':', '').toLowerCase();
  if (pin.length == 64) n.pin = pin;
  final obfs = _q(u, 'obfs').toLowerCase();
  if (obfs.isNotEmpty) {
    if (obfs == 'salamander') {
      n.obfs = 'salamander';
      n.obfsPassword = _q(u, 'obfs-password');
    } else {
      reasons.add('Hysteria2 的混淆 $obfs 暂不支持');
    }
  }
  if (_q(u, 'mport').isNotEmpty) reasons.add('端口跳跃暂不支持');
  if (reasons.isNotEmpty) n.unsupported = reasons.join('；');
  return n;
}

// ---- ss://: read so it shows in the list, not dialled yet ----

SubNode _ss(String link) {
  var rest = link.substring(5);
  var name = '';
  final h = rest.indexOf('#');
  if (h >= 0) {
    try {
      name = Uri.decodeComponent(rest.substring(h + 1));
    } on ArgumentError {
      name = rest.substring(h + 1);
    }
    rest = rest.substring(0, h);
  }
  final q = rest.indexOf('?');
  if (q >= 0) rest = rest.substring(0, q);
  rest = rest.replaceAll(RegExp(r'/$'), '');
  String host = '';
  int port = 0;
  final at = rest.lastIndexOf('@');
  if (at >= 0) {
    final hp = Uri.tryParse('x://${rest.substring(at + 1)}');
    host = hp?.host ?? '';
    port = hp != null && hp.hasPort ? hp.port : 0;
  } else {
    // the whole thing is base64 of "method:password@host:port"
    try {
      final d = utf8.decode(_b64(rest));
      final a = d.lastIndexOf('@');
      final hp = Uri.tryParse('x://${d.substring(a + 1)}');
      host = hp?.host ?? '';
      port = hp != null && hp.hasPort ? hp.port : 0;
    } catch (_) {}
  }
  if (host.isEmpty || port < 1) throw const FormatException('缺少地址或端口');
  return SubNode(proto: 'ss', host: host, port: port, name: name.isEmpty ? host : name, unsupported: 'Shadowsocks 暂不支持');
}

SubNode _opaque(String scheme, Uri u) {
  final label = switch (scheme) {
    'tuic' => 'TUIC',
    'anytls' => 'AnyTLS',
    'hysteria' => 'Hysteria 1',
    'ssr' => 'ShadowsocksR',
    _ => scheme,
  };
  return SubNode(proto: scheme, host: u.host, port: u.hasPort ? u.port : 0, name: _name(u, u.host), unsupported: '$label 暂不支持');
}

/// Base64 in either alphabet, with or without padding, with stray whitespace.
List<int> _b64(String s) {
  var t = s.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
  while (t.length % 4 != 0) {
    t += '=';
  }
  return base64.decode(t);
}

/// Decodes [text] when it is base64 of a text, or returns null. A real
/// subscription is either plain lines or one base64 block of them.
String? decodeBlock(String text) {
  final t = text.trim();
  if (t.isEmpty || t.contains('://') || t.contains(':')) return null;
  if (!RegExp(r'^[A-Za-z0-9+/_\-=\s]+$').hasMatch(t)) return null;
  try {
    return utf8.decode(_b64(t));
  } catch (_) {
    return null;
  }
}
