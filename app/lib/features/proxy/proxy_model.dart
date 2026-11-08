// What the proxy feature does, apart from how it looks: fetch a source, keep
// its nodes, ask an agent which it can use and how fast, and tell an agent
// which one to use (D-83 to D-90). No widgets here, so tests can drive it.
import 'dart:async';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_sub/aurora_sub.dart';
import 'package:aurora_wire/aurora_wire.dart';

import '../../state/profile_access.dart';

/// A node of a source as the list shows it.
class NodeRow {
  final ProxySource source;
  final SubNode node;

  /// Why the agent cannot use it (the parser's reason, or the agent's), or ''.
  String blocked;

  /// The last timing from this server: milliseconds, or null when not measured.
  int? ms;

  /// Why the last timing failed, or null.
  String? testError;
  NodeRow(this.source, this.node, this.blocked);

  bool get usable => blocked.isEmpty;
}

class ProxyModel {
  final ProfileAccess app;
  ProxyModel(this.app);
  final Map<String, Future<RefreshResult>> _refreshes = {};
  final Map<String, Future<void>> _queues = {};
  final Map<String, Link> _seenLinks = {};

  /// Every fresh authenticated link refreshes its selected subscription and
  /// drains durable pending work. Failed fetches keep the cached parameters.
  Future<void> connected(String id, Link link) async {
    if (identical(_seenLinks[id], link)) return;
    _seenLinks[id] = link;
    final c = app.profile.server(id)?.proxy;
    if (c == null) return;
    try {
      if (app.profile.proxySource(c.source)?.url != null) await refresh(c.source);
      if (app.profile.server(id)?.proxy?.pending == true) {
        await repush(app.profile.server(id)!, link);
      }
    } on Object {
      // push() persists an actionable error; network retries happen on the
      // next connection or explicit user retry, not in a tight loop.
    }
  }

  /// Fetches a subscription and keeps what it gave. A fetch that fails leaves
  /// the nodes from the last good one, and records why (a provider's page being
  /// down must not empty the list the user was using).
  Future<ProxySource> addSubscription(String name, String url, {Future<String> Function(Uri)? fetch}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) throw FetchError('订阅地址格式不对');
    final text = await (fetch ?? fetchSubscription)(uri);
    final r = parseSubscription(text);
    if (r.nodes.isEmpty) {
      throw FetchError(r.skipped.isEmpty ? '订阅里没有节点' : r.skipped.first);
    }
    final src = ProxySource.create(name, url: url.trim());
    src.nodes = [for (final n in r.nodes) n.toAgent()];
    await app.update((p) => p.proxySources.add(src));
    return src;
  }

  /// Nodes from links the user pasted (one per line, or a Clash `proxies:` block).
  Future<ProxySource> addPasted(String name, String text) async {
    final r = parseSubscription(text);
    if (r.nodes.isEmpty) {
      throw FetchError(r.skipped.isEmpty ? '没有读到节点' : r.skipped.first);
    }
    final src = ProxySource.create(name);
    src.nodes = [for (final n in r.nodes) n.toAgent()];
    await app.update((p) => p.proxySources.add(src));
    return src;
  }

  /// Fetches a subscription again. Returns what changed for the chosen nodes:
  /// the servers whose chosen node's parameters are now different. They are not
  /// pushed here: the caller decides (the agent may not be reachable).
  Future<RefreshResult> refresh(String sourceId, {Future<String> Function(Uri)? fetch}) {
    final running = _refreshes[sourceId];
    if (running != null) return running;
    final work = _refresh(sourceId, fetch: fetch);
    _refreshes[sourceId] = work;
    return work.whenComplete(() => _refreshes.remove(sourceId));
  }

  Future<RefreshResult> _refresh(String sourceId, {Future<String> Function(Uri)? fetch}) async {
    final src = app.profile.proxySource(sourceId);
    if (src == null || src.url == null) return RefreshResult(const [], 0, 0, 'not a subscription');
    String? failure;
    SubResult? r;
    try {
      r = parseSubscription(await (fetch ?? fetchSubscription)(Uri.parse(src.url!)));
      if (r.nodes.isEmpty) {
        failure = r.skipped.isEmpty ? '订阅里没有节点' : r.skipped.first;
        r = null;
      }
    } on FetchError catch (e) {
      failure = e.message;
    }
    final changed = <String>[];
    var gone = 0;
    await app.update((p) {
      final s = p.proxySource(sourceId);
      if (s == null) return;
      if (r == null) {
        s.error = failure; // the old nodes stay
        return;
      }
      s.error = null;
      s.updated = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final fresh = [for (final n in r.nodes) n.toAgent()];
      for (final e in p.servers) {
        final c = e.proxy;
        if (c == null || c.source != sourceId) continue;
        final now = _find(fresh, c.key);
        if (now == null) {
          gone++;
        } else if (_secretsOf(now) != _secretsOf(_find(s.nodes, c.key) ?? now) || _shape(now) != _shape(_find(s.nodes, c.key) ?? now)) {
          changed.add(e.id);
          c.pending = true;
          c.revision++;
          c.syncError = null;
          c.name = (now['name'] as String?) ?? c.name;
        } else {
          c.name = (now['name'] as String?) ?? c.name;
        }
      }
      s.nodes = fresh;
    });
    // Retry previously failed generations too; a successful cache refresh
    // must not hide an older unsent change.
    for (final e in app.profile.servers) {
      if (e.proxy?.source == sourceId && e.proxy!.pending && !changed.contains(e.id)) changed.add(e.id);
    }
    // A shared subscription may be used by several already connected servers.
    // Drain every online target here, not only the workspace whose page is
    // open; offline targets retain their durable pending marker.
    for (final id in changed) {
      final link = app.link(id), entry = app.profile.server(id);
      if (link == null || entry == null) continue;
      try { await repush(entry,link); } on Object { /* persisted by _push */ }
    }
    return RefreshResult(changed, gone, r?.nodes.length ?? 0, failure);
  }

  Map<String, dynamic>? _find(List<Map<String, dynamic>> nodes, String key) {
    for (final n in nodes) {
      if (SubNode.fromJson(n).key == key) return n;
    }
    return null;
  }

  String _secretsOf(Map<String, dynamic> n) => '${n['secret']}|${n['obfs_password']}';

  /// Everything about a node that changes how it is dialled, except its name.
  String _shape(Map<String, dynamic> n) {
    final m = Map<String, dynamic>.from(n)
      ..remove('name')
      ..remove('secret')
      ..remove('obfs_password');
    return m.toString();
  }

  List<NodeRow> rows(ProxySource s, Map<String, String> agentReasons) {
    return [
      for (final j in s.nodes)
        () {
          final n = SubNode.fromJson(j);
          final key = n.key;
          return NodeRow(s, n, n.unsupported.isNotEmpty ? n.unsupported : (agentReasons[key] ?? ''));
        }(),
    ];
  }

  /// Asks the agent which of [nodes] it can use. Returns reasons by node key; a
  /// node not in the map is usable. An agent without `proxy.check` (older) gives
  /// an empty map, and the parser's own reasons still apply.
  Future<Map<String, String>> check(Link link, List<SubNode> nodes) async {
    final out = <String, String>{};
    for (var i = 0; i < nodes.length; i += 500) {
      final part = nodes.sublist(i, (i + 500).clamp(0, nodes.length));
      final r = await link.call('proxy.check', {'nodes': [for (final n in part) n.toCheck()]}) as Map;
      final reasons = (r['reasons'] as List).cast<String>();
      for (var k = 0; k < part.length; k++) {
        if (reasons[k].isNotEmpty) out[part[k].key] = reasons[k];
      }
    }
    return out;
  }

  /// Times a node from the server: one tunnel opened through it. The number is
  /// what a terminal on that server would get, which is not what this PC would.
  Future<void> test(Link link, NodeRow row, {String target = 'www.gstatic.com:80'}) async {
    row.ms = null;
    row.testError = null;
    try {
      final r = await link.call('proxy.test', {'node': row.node.toAgent(), 'target': target}, const Duration(seconds: 20)) as Map;
      if (r['ok'] == true) {
        row.ms = (r['ms'] as num).toInt();
      } else {
        row.testError = (r['error'] as String?) ?? '失败';
      }
    } on OpError catch (e) {
      row.testError = e.message;
    }
  }

  /// Times every usable node, [parallel] at a time, in the order of [rows].
  Future<void> testAll(Link link, List<NodeRow> rows, {int parallel = 4, void Function()? onEach, bool Function()? cancelled}) async {
    final todo = [for (final r in rows) if (r.usable) r];
    var next = 0;
    Future<void> worker() async {
      while (next < todo.length) {
        if (cancelled?.call() ?? false) return;
        final r = todo[next++];
        await test(link, r);
        onEach?.call();
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
  }

  /// Tells the server to use [row] and remembers the choice.
  Future<void> choose(ServerEntry server, Link link, NodeRow row) async {
    await _serialize(server.id, () async {
      await app.update((p) {
        final e = p.server(server.id);
        if (e == null) return;
        e.proxy = ProxyChoice(source: row.source.id, key: row.node.key, name: row.node.name, pending: true, revision: (e.proxy?.revision ?? 0) + 1);
      });
      await _push(server.id, link);
    });
  }

  Future<void> clear(ServerEntry server, Link link) async {
    await _serialize(server.id, () async {
      await link.call('proxy.clear');
      await app.update((p) => p.server(server.id)?.proxy = null);
    });
  }

  Future<T> _serialize<T>(String id, Future<T> Function() run) {
    final result = (_queues[id] ?? Future<void>.value()).then((_) => run());
    // The tail never fails; callers still receive the original error. This
    // serializes local choices as well as network writes, so a late clear
    // cannot erase a node the user selected while that clear was in flight.
    final tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _queues[id] = tail;
    unawaited(tail.whenComplete(() { if (identical(_queues[id], tail)) _queues.remove(id); }));
    return result;
  }

  /// Sends the server the current parameters of the node it was told to use,
  /// when the source has moved them (a refreshed subscription). Returns false
  /// when the node is no longer in the source: the server keeps what it has.
  Future<bool> repush(ServerEntry server, Link link) async {
    return _serialize(server.id, () => _push(server.id, link));
  }

  Future<bool> _push(String id, Link link) async {
    final c = app.profile.server(id)?.proxy;
    if (c == null) return true;
    final src = app.profile.proxySource(c.source);
    final j = src == null ? null : _find(src.nodes, c.key);
    if (j == null) {
      await app.update((p) { final v = p.server(id)?.proxy; if (v?.key == c.key) v!.syncError = '所选节点已不在订阅中，服务器保持原配置'; });
      return false;
    }
    final n = SubNode.fromJson(j);
    if (n.unsupported.isNotEmpty) {
      await app.update((p) {final v=p.server(id)?.proxy;if(v?.key==c.key){v!.pending=true;v.syncError=n.unsupported;}});
      return false;
    }
    // A successful generation was already pushed by a refresh or a previous
    // reconnect. Explicit retries still work when pending is true, but do not
    // resend the real credential on every ordinary connection.
    if (!c.pending) return true;
    final rev = c.revision, key = c.key, source = c.source;
    try {
      await link.call('proxy.set', {'node': n.toAgent()});
      await app.update((p) {
        final current = p.server(id)?.proxy;
        if (current != null && current.source == source && current.key == key && current.revision == rev) {
          current.pending = false;
          current.syncError = null;
        }
      });
    } on Object catch (e) {
      await app.update((p) {
        final current = p.server(id)?.proxy;
        if (current != null && current.source == source && current.key == key && current.revision == rev) {
          current.pending = true;
          current.syncError = e is OpError ? e.message : '连接中断，节点参数将在重连后同步';
        }
      });
      rethrow;
    }
    return true;
  }

  Future<void> remove(String sourceId) async {
    await app.update((p) {
      p.proxySources.removeWhere((s) => s.id == sourceId);
      for (final e in p.servers) {
        if (e.proxy?.source == sourceId) e.proxy = null;
      }
    });
  }
}

class RefreshResult {
  /// Servers whose chosen node's parameters changed.
  final List<String> changedServers;

  /// Servers whose chosen node is no longer in the subscription.
  final int gone;
  final int count;

  /// Why the refresh failed, or null.
  final String? error;
  RefreshResult(this.changedServers, this.gone, this.count, this.error);
}
