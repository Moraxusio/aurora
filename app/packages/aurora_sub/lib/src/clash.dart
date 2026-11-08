import 'package:yaml/yaml.dart';

import 'node.dart';

/// Reads the `proxies:` list of a Clash (mihomo) file. Field names are those
/// of the mihomo documentation. A proxy it cannot read becomes a skipped
/// entry; one it can read but the agent cannot dial becomes a node with
/// [SubNode.unsupported] set, so the user sees it and why.
SubResult parseClash(String text) {
  final nodes = <SubNode>[];
  final skipped = <String>[];
  Object? doc;
  try {
    doc = loadYaml(text);
  } on YamlException catch (e) {
    return SubResult(nodes, ['不是有效的 YAML：${e.message}'], 'clash');
  }
  if (doc is! YamlMap) return SubResult(nodes, ['内容不是 Clash 配置'], 'clash');
  final list = doc['proxies'];
  if (list is! YamlList) return SubResult(nodes, ['配置里没有 proxies'], 'clash');
  for (final p in list) {
    if (p is! YamlMap) {
      skipped.add('一个节点不是键值对');
      continue;
    }
    final m = _plain(p);
    final name = _s(m['name']);
    try {
      final n = _node(m);
      if (n == null) {
        skipped.add('$name：缺少类型、地址或端口');
      } else {
        nodes.add(n);
      }
    } on FormatException catch (e) {
      skipped.add('$name：${e.message}');
    }
  }
  return SubResult(nodes, skipped, 'clash');
}

Map<String, dynamic> _plain(YamlMap m) => {for (final e in m.entries) '${e.key}': _unyaml(e.value)};

Object? _unyaml(Object? v) {
  if (v is YamlMap) return {for (final e in v.entries) '${e.key}': _unyaml(e.value)};
  if (v is YamlList) return [for (final x in v) _unyaml(x)];
  return v;
}

String _s(Object? v) => v == null ? '' : '$v'.trim();

int _i(Object? v) {
  if (v is int) return v;
  return int.tryParse(_s(v)) ?? 0;
}

bool _b(Object? v) => v == true || _s(v).toLowerCase() == 'true';

SubNode? _node(Map<String, dynamic> m) {
  final type = _s(m['type']).toLowerCase();
  final host = _s(m['server']);
  final port = _i(m['port']);
  if (type.isEmpty || host.isEmpty || port < 1 || port > 65535) return null;
  final name = _s(m['name']);

  final n = SubNode(proto: type, host: host, port: port, name: name);
  final reasons = <String>[];

  // TLS, shared by every type that has it.
  n.sni = _s(m['sni']).isNotEmpty ? _s(m['sni']) : _s(m['servername']);
  n.insecure = _b(m['skip-cert-verify']);
  n.alpn = [for (final a in (m['alpn'] as List? ?? const [])) _s(a)];
  final fp = _s(m['fingerprint']).replaceAll(':', '').toLowerCase();
  if (fp.length == 64) n.pin = fp;
  if (m['reality-opts'] is Map) reasons.add('Reality 暂不支持');
  for (final k in ['shadow-tls-opts', 'restls-opts', 'jls-opts', 'tlsmirror-opts', 'ech-opts']) {
    if (m[k] is Map) reasons.add('$k 暂不支持');
  }
  if (m['smux'] is Map && (m['smux'] as Map)['enabled'] == true) reasons.add('多路复用（smux）暂不支持');

  final network = _s(m['network']).toLowerCase();
  switch (type) {
    case 'trojan':
      n.proto = 'trojan';
      n.secret = _s(m['password']);
      n.tls = true;
      if (m['ss-opts'] is Map && (m['ss-opts'] as Map)['enabled'] == true) reasons.add('Trojan-Go 的 Shadowsocks 加密暂不支持');
      _transport(n, network, m, reasons);
      if (n.transport == 'ws') reasons.add('Trojan 经 WebSocket 暂不支持');
    case 'hysteria2' || 'hy2':
      n.proto = 'hysteria2';
      n.secret = _s(m['password']);
      n.tls = true;
      if (_s(m['ports']).isNotEmpty) reasons.add('端口跳跃暂不支持');
      final obfs = _s(m['obfs']).toLowerCase();
      if (obfs.isNotEmpty) {
        if (obfs == 'salamander') {
          n.obfs = 'salamander';
          n.obfsPassword = _s(m['obfs-password']);
        } else {
          reasons.add('Hysteria2 的混淆 $obfs 暂不支持');
        }
      }
      n.upMbps = _mbps(m['up']);
      n.downMbps = _mbps(m['down']);
    case 'vless':
      n.proto = 'vless';
      n.secret = _s(m['uuid']);
      n.tls = _b(m['tls']);
      n.flow = _s(m['flow']);
      final enc = _s(m['encryption']);
      if (enc.isNotEmpty && enc != 'none') reasons.add('VLESS Encryption 暂不支持');
      _transport(n, network, m, reasons);
    case 'vmess':
      n.proto = 'vmess';
      n.secret = _s(m['uuid']);
      n.tls = _b(m['tls']);
      n.cipher = _s(m['cipher']);
      if (_i(m['alterId']) != 0) reasons.add('旧版 VMess（alterId 不为 0）暂不支持');
      _transport(n, network, m, reasons);
    default:
      // Shadowsocks, TUIC, AnyTLS, WireGuard and the rest: the node is kept
      // and shown, with a reason, so a subscription never looks emptier than it is.
      reasons.add(switch (type) {
        'ss' => 'Shadowsocks 暂不支持',
        'ssr' => 'ShadowsocksR 暂不支持',
        'tuic' => 'TUIC 暂不支持',
        'anytls' => 'AnyTLS 暂不支持',
        'hysteria' => 'Hysteria 1 暂不支持（只支持 Hysteria2）',
        _ => '$type 暂不支持',
      });
  }
  if (reasons.isNotEmpty) n.unsupported = reasons.join('；');
  return n;
}

/// Reads `network` and its options. Only tcp and ws are dialled; any other
/// transport is recorded as the reason, not quietly turned into tcp.
void _transport(SubNode n, String network, Map<String, dynamic> m, List<String> reasons) {
  switch (network) {
    case '' || 'tcp':
      break;
    case 'ws':
      n.transport = 'ws';
      final o = (m['ws-opts'] as Map?)?.cast<String, dynamic>() ?? const {};
      n.wsPath = _s(o['path']);
      final h = o['headers'];
      if (h is Map) {
        for (final e in h.entries) {
          if ('${e.key}'.toLowerCase() == 'host') n.wsHost = _s(e.value);
        }
      }
      if (_i(o['max-early-data']) > 0) reasons.add('WebSocket 早期数据（0-RTT）暂不支持');
      if (_b(o['v2ray-http-upgrade'])) reasons.add('HTTPUpgrade 暂不支持');
    default:
      reasons.add('传输方式 $network 暂不支持（支持 tcp、ws）');
  }
}

/// "30 Mbps", "30", 30: megabits per second. Anything with another unit is 0,
/// which leaves the rate to the congestion control instead of guessing.
int _mbps(Object? v) {
  final s = _s(v).toLowerCase();
  if (s.isEmpty) return 0;
  final m = RegExp(r'^(\d+)\s*(mbps)?$').firstMatch(s);
  return m == null ? 0 : int.parse(m.group(1)!);
}
