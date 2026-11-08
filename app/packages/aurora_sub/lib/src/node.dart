/// One outbound server of a subscription, in the shape the agent takes
/// (agent/internal/netproxy/node.go). The field names are the agent's JSON.
class SubNode {
  String name;
  String proto; // trojan | hysteria2 | vless | vmess | and, for display only, others
  String host;
  int port;

  /// The password (Trojan, Hysteria2) or the UUID (VLESS, VMess). A secret.
  String secret;

  bool tls;
  String sni;
  String pin;
  bool insecure;
  List<String> alpn;

  String transport; // '' or tcp, ws
  String wsPath;
  String wsHost;
  String cipher;
  String flow;

  String obfs;
  String obfsPassword;
  int upMbps;
  int downMbps;

  /// Why this node cannot be dialled, or '' when nothing known stands in the way.
  /// The agent has the last word (proxy.check); this is what the parser could
  /// already see, such as Reality or a transport the agent does not speak.
  String unsupported;

  SubNode({
    this.name = '',
    required this.proto,
    required this.host,
    required this.port,
    this.secret = '',
    this.tls = false,
    this.sni = '',
    this.pin = '',
    this.insecure = false,
    this.alpn = const [],
    this.transport = '',
    this.wsPath = '',
    this.wsHost = '',
    this.cipher = '',
    this.flow = '',
    this.obfs = '',
    this.obfsPassword = '',
    this.upMbps = 0,
    this.downMbps = 0,
    this.unsupported = '',
  });

  /// What the agent receives in proxy.set / proxy.test / proxy.check.
  Map<String, dynamic> toAgent() => {
        if (name.isNotEmpty) 'name': name,
        'proto': proto,
        'host': host,
        'port': port,
        if (secret.isNotEmpty) 'secret': secret,
        'tls': {
          'enabled': tls,
          if (sni.isNotEmpty) 'sni': sni,
          if (pin.isNotEmpty) 'pin': pin,
          if (insecure) 'insecure': true,
          if (alpn.isNotEmpty) 'alpn': alpn,
        },
        if (transport.isNotEmpty) 'transport': transport,
        if (wsPath.isNotEmpty) 'ws_path': wsPath,
        if (wsHost.isNotEmpty) 'ws_host': wsHost,
        if (cipher.isNotEmpty) 'cipher': cipher,
        if (flow.isNotEmpty) 'flow': flow,
        if (obfs.isNotEmpty) 'obfs': obfs,
        if (obfsPassword.isNotEmpty) 'obfs_password': obfsPassword,
        if (upMbps > 0) 'up_mbps': upMbps,
        if (downMbps > 0) 'down_mbps': downMbps,
        if (unsupported.isNotEmpty) 'unsupported': unsupported,
      };

  /// How the certificate is checked, in words: shown beside the node so the
  /// user sees a node that skips the check (D-88).
  String get verify {
    if (!tls) return '无 TLS';
    if (pin.isNotEmpty) return '指纹校验';
    if (insecure) return '不校验证书';
    return '系统根证书';
  }

  /// Identity of a node across refreshes of the subscription: where it is and
  /// how it is reached, not what the provider calls it and not its password. A
  /// provider renames nodes ("HK 01" to "香港 01 | 2x") and rotates passwords far
  /// more often than it moves a server; if the password were part of the
  /// identity, a rotation would look like the node vanishing and the server
  /// would never get the new one. Two entries that differ only in their
  /// password are the same node to this key; the first one wins.
  String get key => '$proto|$host|$port|$transport|$wsPath';

  /// Like [toAgent] but without the secret, for the list the user reads.
  Map<String, dynamic> toPublic() {
    final m = toAgent();
    m.remove('secret');
    m.remove('obfs_password');
    return m;
  }

  factory SubNode.fromJson(Map<String, dynamic> j) {
    final t = (j['tls'] as Map?)?.cast<String, dynamic>() ?? const {};
    return SubNode(
      name: j['name'] as String? ?? '',
      proto: j['proto'] as String? ?? '',
      host: j['host'] as String? ?? '',
      port: j['port'] as int? ?? 0,
      secret: j['secret'] as String? ?? '',
      tls: t['enabled'] as bool? ?? false,
      sni: t['sni'] as String? ?? '',
      pin: t['pin'] as String? ?? '',
      insecure: t['insecure'] as bool? ?? false,
      alpn: [for (final a in (t['alpn'] as List? ?? const [])) '$a'],
      transport: j['transport'] as String? ?? '',
      wsPath: j['ws_path'] as String? ?? '',
      wsHost: j['ws_host'] as String? ?? '',
      cipher: j['cipher'] as String? ?? '',
      flow: j['flow'] as String? ?? '',
      obfs: j['obfs'] as String? ?? '',
      obfsPassword: j['obfs_password'] as String? ?? '',
      upMbps: j['up_mbps'] as int? ?? 0,
      downMbps: j['down_mbps'] as int? ?? 0,
      unsupported: j['unsupported'] as String? ?? '',
    );
  }
}

/// What a subscription held: the nodes it was possible to read, and what was
/// skipped. A line that cannot be read never makes the whole subscription fail.
class SubResult {
  final List<SubNode> nodes;

  /// One entry per line or proxy that could not be turned into a node at all.
  final List<String> skipped;

  /// 'clash', 'links' or 'unknown': how the text was read.
  final String format;
  SubResult(this.nodes, this.skipped, this.format);
}
