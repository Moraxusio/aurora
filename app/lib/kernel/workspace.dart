// One server's workspace: its editor tabs, what its agent reports about each
// service, and the way features reach the link. It outlives the widgets: the
// shell can be rebuilt, or another server shown, and the tabs stay.
import 'dart:async';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'editor_tab.dart';
import 'feature.dart';
import 'widgets.dart';

class Workspace extends ChangeNotifier {
  final AppState app;
  final String serverId;
  final List<EditorTab> tabs = [];
  String? activeId;

  /// agent.services: id, enabled, available, reason, ops.
  List<Map<String, dynamic>> services = [];
  String? servicesError;
  Link? _servicesFor;

  /// Whether services is the answer of the current link. False from the
  /// moment a link is up until agent.services has answered.
  bool servicesLoaded = false;

  /// Narrow layouts show either the side bar or the editor area.
  bool compactEditor = false;

  Workspace(this.app, this.serverId) {
    app.addListener(_onApp);
    _onApp();
  }

  ServerEntry? get entry => app.profile.server(serverId);
  String get name => entry?.name ?? serverId;
  Link? get link => app.link(serverId);
  ConnStatus get status => app.status(serverId);

  void _onApp() {
    final l = link;
    if (l != null && !identical(l, _servicesFor)) {
      _servicesFor = l;
      servicesLoaded = false;
      unawaited(refreshServices());
    }
    if (l == null) {
      _servicesFor = null;
      servicesLoaded = false;
    }
    notifyListeners();
  }

  /// Reads the service list again (after a switch, or a new link).
  Future<void> refreshServices() async {
    final l = link;
    if (l == null) return;
    try {
      final r = await l.call('agent.services') as Map;
      services = [for (final s in r['services'] as List) (s as Map).cast<String, dynamic>()];
      servicesError = null;
    } on OpError catch (e) {
      servicesError = e.message;
    }
    // an answer or an error: either way the wait is over
    if (identical(l, link)) servicesLoaded = true;
    notifyListeners();
  }

  // ---- what the agent offers ----

  Map<String, dynamic>? serviceInfo(String id) {
    for (final s in services) {
      if (s['id'] == id) return s;
    }
    return null;
  }

  FeatureState stateOf(Feature f) {
    if (link != null && !servicesLoaded) return FeatureState.loading;
    final s = serviceInfo(f.service);
    if (s == null) return FeatureState.unreported;
    if (s['enabled'] != true) return FeatureState.disabled;
    if (s['available'] == false) return FeatureState.unavailable;
    final ops = ((s['ops'] as List?) ?? const []).cast<String>();
    for (final op in f.ops) {
      if (!ops.contains(op)) return FeatureState.outdated;
    }
    return FeatureState.available;
  }

  String reasonOf(Feature f) => (serviceInfo(f.service)?['reason'] as String?) ?? '';

  /// Whether the agent reports an operation (an optional part of a feature).
  bool hasOp(String op) => link?.server.caps.contains(op) ?? false;

  // ---- tabs ----

  EditorTab? get active {
    for (final t in tabs) {
      if (t.id == activeId) return t;
    }
    return null;
  }

  EditorTab? tab(String id) {
    for (final t in tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Opens [t], or brings the open tab with the same id to the front.
  void openTab(EditorTab t) {
    if (tab(t.id) != null) {
      t.dispose();
      activate(t.id);
      return;
    }
    tabs.add(t);
    activeId = t.id;
    compactEditor = true;
    notifyListeners();
  }

  void activate(String id) {
    if (tab(id) == null) return;
    activeId = id;
    compactEditor = true;
    notifyListeners();
  }

  /// Closes a tab; asks first when it has unsaved changes. Returns whether it closed.
  Future<bool> closeTab(String id) async {
    final t = tab(id);
    if (t == null) return true;
    if (t.confirmClose != null && !await t.confirmClose!()) return false;
    final i = tabs.indexOf(t);
    tabs.removeAt(i);
    if (activeId == id) activeId = tabs.isEmpty ? null : tabs[i.clamp(0, tabs.length - 1)].id;
    t.dispose();
    notifyListeners();
    return true;
  }

  /// Closes tabs that match [test] without asking (their content is gone from
  /// the server, e.g. a session that ended).
  void dropTabs(bool Function(EditorTab) test) {
    final gone = tabs.where(test).toList();
    if (gone.isEmpty) return;
    for (final t in gone) {
      final i = tabs.indexOf(t);
      tabs.remove(t);
      if (activeId == t.id) activeId = tabs.isEmpty ? null : tabs[i.clamp(0, tabs.length - 1)].id;
      t.dispose();
    }
    notifyListeners();
  }

  void next(int step) {
    if (tabs.length < 2) return;
    final i = tabs.indexWhere((t) => t.id == activeId);
    activate(tabs[((i < 0 ? 0 : i) + step) % tabs.length].id);
  }

  // ---- messages ----

  void toast(String msg, {bool error = false}) => Toast.show(msg, error: error);

  /// Runs [f] and shows an agent error as a message instead of throwing.
  Future<T?> guard<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on OpError catch (e) {
      toast(e.message, error: true);
    }
    return null;
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    for (final t in tabs) {
      t.dispose();
    }
    super.dispose();
  }
}

/// Builds [builder] with the link, or says why there is none. Rebuilds with a
/// fresh state when the link is replaced (reconnect), because what a feature
/// loaded from the old link may be stale.
class LinkGate extends StatelessWidget {
  final Workspace ws;
  final Widget Function(BuildContext context, Link link) builder;
  const LinkGate({super.key, required this.ws, required this.builder});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ws,
      builder: (context, _) {
        final l = ws.link;
        if (l == null) return NotConnected(ws: ws);
        return KeyedSubtree(key: ObjectKey(l), child: builder(context, l));
      },
    );
  }
}

/// The side bar or tab body while the server is not connected.
class NotConnected extends StatelessWidget {
  final Workspace ws;
  const NotConnected({super.key, required this.ws});

  @override
  Widget build(BuildContext context) {
    final st = ws.status;
    final connecting = st.state == ConnState.connecting || st.state == ConnState.waiting;
    final text = switch (st.state) {
      ConnState.connecting => '正在连接…',
      ConnState.waiting => '连接失败，${st.retryIn?.inSeconds ?? 0} 秒后重试\n${st.failure?.message ?? ''}',
      ConnState.failed => st.failure?.message ?? '连接失败',
      _ => '未连接',
    };
    return EmptyHint(
      icon: connecting ? Icons.sync : Icons.link_off,
      text: text,
      actionLabel: connecting ? null : '连接',
      onAction: connecting ? null : () => ws.app.connect(ws.serverId),
    );
  }
}
