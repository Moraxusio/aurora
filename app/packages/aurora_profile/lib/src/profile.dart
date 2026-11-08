// The client's remembered state. Everything here is sealed together (D-72):
// SSH logins (D-1, D-6), direct-link parameters (D-22) and the client's own
// known_hosts (D-2), whose integrity matters as much as the secrets' privacy.
import 'dart:math';

/// Everything the client remembers.
class Profile {
  List<ServerEntry> servers;

  /// [ServerEntry.id] of the server in front, or null.
  String? selected;

  /// Host keys the user confirmed (D-2).
  List<KnownHost> knownHosts;

  /// Where proxy nodes come from: subscriptions and pasted links (D-83). They
  /// belong to the user, not to a server; each server remembers which node it uses.
  List<ProxySource> proxySources;

  Profile({List<ServerEntry>? servers, this.selected, List<KnownHost>? knownHosts, List<ProxySource>? proxySources})
      : servers = servers ?? [],
        knownHosts = knownHosts ?? [],
        proxySources = proxySources ?? [];

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        servers: [for (final s in (j['servers'] as List? ?? const [])) ServerEntry.fromJson(_map(s))],
        selected: j['selected'] as String?,
        knownHosts: [for (final k in (j['known_hosts'] as List? ?? const [])) KnownHost.fromJson(_map(k))],
        proxySources: [for (final s in (j['proxy_sources'] as List? ?? const [])) ProxySource.fromJson(_map(s))],
      );

  Map<String, dynamic> toJson() => {
        if (servers.isNotEmpty) 'servers': [for (final s in servers) s.toJson()],
        'selected': ?selected,
        if (knownHosts.isNotEmpty) 'known_hosts': [for (final k in knownHosts) k.toJson()],
        if (proxySources.isNotEmpty) 'proxy_sources': [for (final s in proxySources) s.toJson()],
      };

  ProxySource? proxySource(String id) {
    for (final s in proxySources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// A deep copy.
  Profile copy() => Profile.fromJson(toJson());

  ServerEntry? server(String id) {
    for (final s in servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// The confirmed key of [host]:[port], or null when the host is unknown.
  KnownHost? knownHost(String host, int port) {
    final h = host.toLowerCase();
    for (final k in knownHosts) {
      if (k.host == h && k.port == port) return k;
    }
    return null;
  }

  /// Records the key the user confirmed for [host]:[port], replacing an
  /// older one (only after the user accepted the change, D-62).
  void trustHost(String host, int port, String type, String fingerprint) {
    final h = host.toLowerCase();
    knownHosts.removeWhere((k) => k.host == h && k.port == port);
    knownHosts.add(KnownHost(host: h, port: port, type: type, fingerprint: fingerprint, added: _now()));
  }
}

/// One server the client manages.
class ServerEntry {
  /// Client-local id, fixed when the entry is created.
  final String id;
  String name;

  /// The agent's own id (wire.AgentInfo.ID), once paired.
  String? agentId;

  /// How to reach the server over SSH for install and re-pairing.
  SshLogin? ssh;

  /// How to reach the agent directly, once paired (D-4, D-22).
  DirectParams? direct;

  /// Unix seconds of the last successful direct link.
  int? lastSeen;

  /// Port forwards (the "net" service): opened again when the server connects.
  List<ForwardSpec> forwards;

  /// The proxy node this server was told to use (the "proxy" service). The
  /// agent keeps the node itself; this is what lets the client say which one
  /// it is, and push it again when the provider changes it.
  ProxyChoice? proxy;

  ServerEntry({required this.id, required this.name, this.agentId, this.ssh, this.direct, this.lastSeen, List<ForwardSpec>? forwards, this.proxy}) : forwards = forwards ?? [];

  /// A new entry with a random id.
  factory ServerEntry.create(String name, {SshLogin? ssh}) => ServerEntry(id: newId(), name: name, ssh: ssh);

  factory ServerEntry.fromJson(Map<String, dynamic> j) => ServerEntry(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        agentId: j['agent_id'] as String?,
        ssh: j['ssh'] == null ? null : SshLogin.fromJson(_map(j['ssh'])),
        direct: j['direct'] == null ? null : DirectParams.fromJson(_map(j['direct'])),
        lastSeen: j['last_seen'] as int?,
        forwards: [for (final f in (j['forwards'] as List? ?? const [])) ForwardSpec.fromJson(_map(f))],
        proxy: j['proxy'] == null ? null : ProxyChoice.fromJson(_map(j['proxy'])),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'agent_id': ?agentId,
        'ssh': ?ssh?.toJson(),
        'direct': ?direct?.toJson(),
        'last_seen': ?lastSeen,
        if (forwards.isNotEmpty) 'forwards': [for (final f in forwards) f.toJson()],
        'proxy': ?proxy?.toJson(),
      };
}

/// A place proxy nodes come from (D-83, D-84): a subscription address, or links
/// the user pasted. The address holds the account's key, so it is sealed with
/// the rest of the profile and never shown whole. [nodes] is what the last
/// fetch gave, in the agent's JSON (aurora_sub SubNode.toAgent), with the
/// nodes' passwords: the profile is sealed, and the nodes are needed to push
/// one to a server without fetching again.
class ProxySource {
  final String id;
  String name;

  /// The subscription address, or null for pasted links.
  String? url;
  List<Map<String, dynamic>> nodes;

  /// Unix seconds of the last successful fetch (or of the paste).
  int updated;

  /// Why the last refresh failed, or null.
  String? error;

  ProxySource({required this.id, required this.name, this.url, List<Map<String, dynamic>>? nodes, this.updated = 0, this.error}) : nodes = nodes ?? [];

  factory ProxySource.create(String name, {String? url}) => ProxySource(id: newId(), name: name, url: url, updated: _now());

  factory ProxySource.fromJson(Map<String, dynamic> j) => ProxySource(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        url: j['url'] as String?,
        nodes: [for (final n in (j['nodes'] as List? ?? const [])) _map(n)],
        updated: j['updated'] as int? ?? 0,
        error: j['error'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': ?url,
        if (nodes.isNotEmpty) 'nodes': nodes,
        'updated': updated,
        'error': ?error,
      };
}

/// Which node of which source a server uses. [key] is the node's identity
/// (where it is and how it logs in, not its display name), so a provider that
/// renames its nodes does not lose the choice.
class ProxyChoice {
  String source;
  String key;

  /// The name at the time of choosing, shown if the source no longer has the node.
  String name;

  ProxyChoice({required this.source, required this.key, required this.name});

  factory ProxyChoice.fromJson(Map<String, dynamic> j) => ProxyChoice(source: j['source'] as String? ?? '', key: j['key'] as String? ?? '', name: j['name'] as String? ?? '');

  Map<String, dynamic> toJson() => {'source': source, 'key': key, 'name': name};
}

/// One port forward: [host]:[port] on the server, opened on this machine's
/// loopback at [local]. Not a secret, but kept in the same sealed file.
class ForwardSpec {
  String host;
  int port;
  int local;
  String label;

  ForwardSpec({this.host = '127.0.0.1', required this.port, required this.local, this.label = ''});

  factory ForwardSpec.fromJson(Map<String, dynamic> j) => ForwardSpec(
        host: j['host'] as String? ?? '127.0.0.1',
        port: j['port'] as int? ?? 0,
        local: j['local'] as int? ?? 0,
        label: j['label'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'host': host, 'port': port, 'local': local, if (label.isNotEmpty) 'label': label};
}
/// An SSH account. Secrets are optional: a field left null is asked for
/// each time it is needed (D-1: saving is the user's choice).
class SshLogin {
  String host;
  int port;
  String user;
  String? password;

  /// OpenSSH or PEM private key text, and its passphrase.
  String? privateKey;
  String? passphrase;

  /// For `sudo` when [user] is not root (D-6).
  String? sudoPassword;

  SshLogin({
    required this.host,
    this.port = 22,
    required this.user,
    this.password,
    this.privateKey,
    this.passphrase,
    this.sudoPassword,
  });

  factory SshLogin.fromJson(Map<String, dynamic> j) => SshLogin(
        host: j['host'] as String,
        port: j['port'] as int? ?? 22,
        user: j['user'] as String,
        password: j['password'] as String?,
        privateKey: j['private_key'] as String?,
        passphrase: j['passphrase'] as String?,
        sudoPassword: j['sudo_password'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'user': user,
        'password': ?password,
        'private_key': ?privateKey,
        'passphrase': ?passphrase,
        'sudo_password': ?sudoPassword,
      };
}

/// The agent's direct-link parameters (wire.DirectInfo), read over SSH at
/// install (D-4) and replaced on token rotation (D-60).
class DirectParams {
  int port;

  /// Candidate host:port addresses the agent reported.
  List<String> addrs;

  /// Lower-case hex SHA-256 of the agent's certificate DER.
  String pin;
  String token;

  /// The last address that worked, tried first.
  String? goodAddr;

  DirectParams({required this.port, List<String>? addrs, required this.pin, required this.token, this.goodAddr})
      : addrs = addrs ?? [];

  /// Has what a dial needs.
  bool get ready =>
      token.isNotEmpty && RegExp(r'^[0-9a-f]{64}$').hasMatch(pin) && (addrs.isNotEmpty || goodAddr != null);

  factory DirectParams.fromJson(Map<String, dynamic> j) => DirectParams(
        port: j['port'] as int? ?? 0,
        addrs: [for (final a in (j['addrs'] as List? ?? const [])) a as String],
        pin: j['pin'] as String? ?? '',
        token: j['token'] as String? ?? '',
        goodAddr: j['good_addr'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'port': port,
        if (addrs.isNotEmpty) 'addrs': addrs,
        'pin': pin,
        'token': token,
        'good_addr': ?goodAddr,
      };
}

/// A host key the user confirmed on first SSH contact (D-2).
class KnownHost {
  /// Lower-case host name or address, as the user typed it.
  final String host;
  final int port;

  /// Key type, e.g. "ssh-ed25519".
  final String type;

  /// OpenSSH-style `SHA256:<base64>`.
  final String fingerprint;

  /// Unix seconds when it was confirmed.
  final int added;

  KnownHost({required this.host, required this.port, required this.type, required this.fingerprint, required this.added});

  factory KnownHost.fromJson(Map<String, dynamic> j) => KnownHost(
        host: j['host'] as String,
        port: j['port'] as int? ?? 22,
        type: j['type'] as String,
        fingerprint: j['fingerprint'] as String,
        added: j['added'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {'host': host, 'port': port, 'type': type, 'fingerprint': fingerprint, 'added': added};
}

/// 16 random hex digits.
String newId() {
  final r = Random.secure();
  final b = StringBuffer();
  for (var i = 0; i < 8; i++) {
    b.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Map<String, dynamic> _map(Object? o) => (o as Map).cast<String, dynamic>();
