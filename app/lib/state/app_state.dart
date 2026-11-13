// The app's state: the sealed profile (aurora_profile), one Connection per
// server (aurora_wire), and the signed agent builds shipped with the app
// (aurora_install). Widgets listen to it; it owns no widgets.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:aurora_install/aurora_install.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../features/proxy/proxy_model.dart';
import 'android_agent.dart';
import 'profile_access.dart';
import 'upgrade_model.dart';
import 'local_agent.dart';

/// Where the signed agent builds are: `agent/` next to the executable in a
/// release folder (M1.7), or AURORA3_AGENT_DIR for development.
String agentDir() {
  final env = Platform.environment['AURORA3_AGENT_DIR'];
  if (env != null && env.isNotEmpty) return env;
  if (Platform.isAndroid && androidAgentDir != null) return androidAgentDir!;
  final exe = File(Platform.resolvedExecutable).parent.path;
  return '$exe${Platform.pathSeparator}agent';
}

class AppState extends ChangeNotifier implements ProfileAccess {
  final localAgent = LocalAgent();
  ConnStatus? _localFailure;
  String? localEntryError;

  Future<void> ensureLocalEntry() async {
    if (!Platform.isWindows || !ready) return;
    if (servers.any((s) => s.isLocal)) return;
    try {
      // Preserve a byte-for-byte encrypted rollback copy before the first write.
      // This code never decodes, logs or exports the credential payload.
      if (storePath != null) {
        final old = File(storePath!);
        final backup = File('$storePath.before-local-v1');
        if (await old.exists() && !await backup.exists()) await old.copy(backup.path);
      }
      await update((p) { if (p.servers.any((s) => s.isLocal)) return; final s = ServerEntry(id: newId(), name: '本机 Windows', kind: 'local'); p.servers.insert(0, s); p.selected ??= s.id; });
      localEntryError = null;
    } on Object {
      localEntryError = '本机入口保存失败，已有加密配置保持不变；请检查配置目录写入权限';
    }
  }

  Future<String> useLocal() async {
    await ensureLocalEntry();
    final s = servers.where((s) => s.isLocal).firstOrNull;
    if (s == null) throw StateError(localEntryError ?? '无法创建本机入口');
    await select(s.id);
    await connect(s.id);
    return s.id;
  }
  late final ProxyModel proxies = ProxyModel(this);
  late final UpgradeModel upgrades = UpgradeModel(this, () => builds, () => upgradePolicy);
  ProfileStore? _store;

  /// Why the profile cannot be used (no keystore, unreadable file), or null.
  String? storeError;
  String? storePath;
  bool storeUnreadable = false;

  final Map<String, Connection> _conns = {};
  final Map<String, StreamSubscription<ConnStatus>> _subs = {};

  /// Signed agent builds that verified, by architecture.
  List<AgentBuild> builds = [];
  UpgradePolicy? upgradePolicy;
  String? buildsError;

  @override
  Profile get profile => _store?.get() ?? Profile();
  @override
  ServerEntry? server(String id) => _store?.server(id);
  String? get selected => _store?.selected;
  List<ServerEntry> get servers => _store?.servers ?? const [];
  bool get ready => _store != null;

  Future<void> init() => initAt(null);

  /// Opens the profile at [path] (tests), or the default location.
  Future<void> initAt(String? path) async {
    try {
      if (Platform.isAndroid && registeredSealer == null) {
        final r = await const MethodChannel('dev.aurora3/keystore').invokeMapMethod<String, Object?>('init');
        registeredSealer = AndroidSealer(Uint8List.fromList((r!['key']! as List).cast<int>()));
        path ??= '${r['dir']}/profile.bin';
        await unpackAgentAssets('${r['dir']}/agent');
      }
      storePath = path ?? defaultProfilePath();
      _store = await ProfileStore.open(storePath!, platformSealer());
    } on ProfileUnreadable catch (e) {
      storeError = e.message;
      storeUnreadable = true;
    } on SealerUnavailable catch (e) {
      storeError = e.message;
    } on Object catch (e) {
      storeError = '$e';
    }
    await loadBuilds();
    notifyListeners();
  }

  /// Moves an unreadable profile aside (never deletes it) and starts empty.
  Future<String?> resetProfile() async {
    if (storePath == null) return null;
    final aside = await ProfileStore.resetUnreadable(storePath!);
    storeError = null;
    storeUnreadable = false;
    _store = await ProfileStore.open(storePath!, platformSealer());
    notifyListeners();
    return aside;
  }

  /// A test signing key in use (AURORA3_TRUST_KEY), shown as a warning.
  String? testKey;

  Future<void> loadBuilds() async {
    builds = [];
    buildsError = null;
    upgradePolicy = null;
    // Tests sign builds with a throwaway key and trust it through the
    // environment; it replaces the release key for this process only, and the
    // UI says so. A release never sets it.
    final tk = Platform.environment['AURORA3_TRUST_KEY'];
    List<Uint8List>? trusted;
    if (tk != null && tk.trim().isNotEmpty) {
      try {
        final k = base64.decode(tk.trim());
        if (k.length == 32) {
          trusted = [Uint8List.fromList(k)];
          testKey = keyIdOf(trusted.first);
        }
      } on FormatException {
        // ignored: the release key stays
      }
    }
    final dir = Directory(agentDir());
    if (!await dir.exists()) {
      buildsError = '没有找到内置的 agent（${dir.path}）';
      return;
    }
    try { upgradePolicy = await UpgradePolicy.open(dir.path, trusted: trusted); }
    on Object catch (e) { buildsError = '$e'; builds = []; return; }
    final errs = <String>[];
    await for (final d in dir.list()) {
      if (d is! Directory) continue;
      try {
        builds.add(await AgentBuild.open(d.path, trusted: trusted));
      } on Object catch (e) {
        errs.add('${d.path}：$e');
      }
    }
    if (builds.isEmpty) buildsError = errs.isEmpty ? '内置的 agent 目录是空的' : errs.join('\n');
  }

  @override
  Future<void> update(FutureOr<void> Function(Profile p) fn) async {
    await _store!.update(fn);
    notifyListeners();
  }

  /// View snapshots already live in Workspace. Persisting them must not
  /// rebuild every page or re-run connection hooks on every folder click.
  Future<void> saveWorkspaceViews(String id, Map<String, WorkspaceView> views) => _store!.update((p) {
    final server = p.server(id);
    if (server == null) return;
    for (final item in views.entries) {
      final copy = WorkspaceView.fromJson(item.value.toJson());
      if (item.key.isEmpty) {
        server.browserView = copy;
      } else {
        final project = server.workspace(item.key);
        if (project != null) project.view = copy;
      }
    }
  });

  // ---- connections ----

  ConnStatus status(String id) => (server(id)?.isLocal == true ? _localFailure : null) ?? _conns[id]?.status ?? ConnStatus(ConnState.idle);
  @override
  Link? link(String id) {
    final l = _conns[id]?.link;
    return l != null && !l.isClosed ? l : null;
  }

  Target? _target(ServerEntry s) {
    final d = s.direct;
    if (d == null || !d.ready) return null;
    return Target(addrs: d.addrs, pin: d.pin, token: d.token);
  }

  /// Connects (or reconnects after a failure). Failures are in [status].
  Future<void> connect(String id) async {
    final s = profile.server(id);
    if (s == null) return;
    Target? t;
    if (s.isLocal) {
      _localFailure = ConnStatus(ConnState.connecting);
      notifyListeners();
      try {
        t = await localAgent.start('${File(storePath!).parent.path}${Platform.pathSeparator}local-agent');
        _localFailure = null;
      } on Object {
        _localFailure = ConnStatus(ConnState.failed, failure: ConnFailure(DialFailure.protocol, '本地 agent 启动失败。请检查随包 local-agent 的完整性与签名；不会影响远程连接或已有凭证。'));
        notifyListeners(); return;
      }
    } else {
      t = _target(s);
    }
    if (t == null) return;
    var c = _conns[id];
    if (c == null) {
      c = Connection(t, goodAddr: s.isLocal ? null : s.direct?.goodAddr);
      _conns[id] = c;
      _subs[id] = c.changes.listen((st) {
        final freshLink = link(id);
        if (!s.isLocal && st.state == ConnState.connected && freshLink != null) unawaited(proxies.connected(id, freshLink));
        if (!s.isLocal && st.state == ConnState.connected && freshLink != null) unawaited(upgrades.connected(id, freshLink));
        if (!s.isLocal && st.state == ConnState.connected && st.addr != null && st.addr != s.direct?.goodAddr) {
          unawaited(update((p) {
            final e = p.server(id);
            if (e?.direct != null) {
              e!.direct!.goodAddr = st.addr;
              e.lastSeen = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            }
          }));
        }
        notifyListeners();
      });
    } else {
      c.target = t;
    }
    try {
      await c.connect();
    } on ConnFailure {
      // reported through status
    }
    notifyListeners();
  }

  void retryNow(String id) => _conns[id]?.retryNow();

  Future<void> disconnect(String id) async {
    await _subs.remove(id)?.cancel();
    await _conns.remove(id)?.dispose();
    notifyListeners();
  }

  // ---- servers ----

  /// Adds a server after a successful install (or saves new parameters for
  /// an existing one after re-pairing).
  ///
  /// [instance] is the agent instance a new entry is made for (D-101); an
  /// existing entry keeps its own.
  Future<String> saveInstalled(
      {String? id, required String name, required SshLogin ssh, required InstallOutcome o, String instance = ''}) async {
    final d = o.direct!;
    late String sid;
    await update((p) {
      var e = id == null ? null : p.server(id);
      if (e == null) {
        e = ServerEntry.create(name, ssh: ssh, instance: instance);
        p.servers.add(e);
        p.selected = e.id; // a server just added is the one the user wants to see
      }
      e
        ..name = name
        ..ssh = ssh
        ..agentId = o.agentId ?? e.agentId
        ..direct = DirectParams(port: d.port, addrs: _addrs(ssh.host, d), pin: d.pin, token: d.token);
      sid = e.id;
    });
    await disconnect(sid); // new parameters: a fresh connection
    return sid;
  }

  /// The SSH host first (what the user typed reaches the server), then the
  /// agent's own addresses.
  static List<String> _addrs(String sshHost, Direct d) {
    final h = sshHost.contains(':') && !sshHost.startsWith('[') ? '[$sshHost]' : sshHost;
    final first = '$h:${d.port}';
    return [first, ...d.addrs.where((a) => a != first)];
  }

  Future<void> removeServer(String id) async {
    await disconnect(id);
    await update((p) {
      p.servers.removeWhere((s) => s.id == id);
      if (p.selected == id) p.selected = p.servers.isEmpty ? null : p.servers.first.id;
    });
  }

  Future<void> select(String id) => update((p) => p.selected = id);

  @override
  void dispose() {
    unawaited(localAgent.stop());
    for (final s in _subs.values) {
      s.cancel();
    }
    for (final c in _conns.values) {
      c.dispose();
    }
    super.dispose();
  }
}
