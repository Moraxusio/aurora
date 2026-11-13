// Tab-first layout state. No widgets, network calls, or document contents.
// Every live tab belongs to exactly one group; splits only move its viewport.
enum TabPlacement { top, bottom, left, right, wrap }

enum EditorArrangement { single, columns, rows, threeColumns, grid }

enum SplitAxis { horizontal, vertical }

class TabGroup {
  final String id;
  final List<String> tabs;
  String? active;
  TabGroup(this.id, {List<String>? tabs, this.active}) : tabs = tabs ?? [];
}

sealed class TabNode {
  const TabNode();
}

class TabLeaf extends TabNode {
  final String group;
  const TabLeaf(this.group);
}

class TabSplit extends TabNode {
  final String id;
  final SplitAxis axis;
  double ratio;
  TabNode first, second;
  TabSplit(this.id, this.axis, this.first, this.second, {this.ratio = .5});
}

class TabLayout {
  static const maxGroups = 4;
  final List<TabGroup> groups = [TabGroup('g1')];
  final Set<String> pinned = {};
  TabNode root = const TabLeaf('g1');
  String focused = 'g1';
  TabPlacement placement = TabPlacement.top;
  double sideWidth = 300, tabsWidth = 180, tabWidth = 160;
  int _serial = 1;

  TabGroup get current =>
      groups.firstWhere((g) => g.id == focused, orElse: () => groups.first);
  List<String> get ordered => [for (final g in groups) ...g.tabs];
  TabGroup? group(String id) => groups.where((g) => g.id == id).firstOrNull;
  TabGroup? owner(String tab) =>
      groups.where((g) => g.tabs.contains(tab)).firstOrNull;
  void focus(String id) {
    if (group(id) != null) focused = id;
  }

  void activate(String tab) {
    final g = owner(tab);
    if (g == null) return;
    focused = g.id;
    g.active = tab;
  }

  void reconcile(Iterable<String> valid, {bool collapseEmpty = false}) {
    final allowed = valid.toSet(), seen = <String>{};
    pinned.removeWhere((id) => !allowed.contains(id));
    for (final g in groups) {
      g.tabs.removeWhere((id) => !allowed.contains(id) || !seen.add(id));
      if (!g.tabs.contains(g.active)) g.active = g.tabs.firstOrNull;
      _sortPins(g);
    }
    for (final id in allowed) {
      if (seen.add(id)) {
        current.tabs.add(id);
        current.active ??= id;
      }
    }
    if (collapseEmpty) {
      for (final g in groups.toList()) {
        if (g.tabs.isEmpty && groups.length > 1) mergeGroup(g.id);
      }
    }
  }

  void add(String tab) {
    if (owner(tab) == null) current.tabs.add(tab);
    activate(tab);
  }

  void togglePin(String tab) {
    final g = owner(tab);
    if (g == null) return;
    if (!pinned.remove(tab)) pinned.add(tab);
    _sortPins(g);
  }

  void _sortPins(TabGroup g) {
    final ids = [...g.tabs];
    g.tabs
      ..clear()
      ..addAll(ids.where(pinned.contains))
      ..addAll(ids.where((id) => !pinned.contains(id)));
  }

  bool move(String tab, String destination, {int? index}) {
    final from = owner(tab), to = group(destination);
    if (from == null || to == null) return false;
    final same = identical(from, to);
    final oldIndex = from.tabs.indexOf(tab);
    var at = index ?? to.tabs.length;
    if (same && at > oldIndex) at--;
    final pins =
        to.tabs.where(pinned.contains).length -
        (same && pinned.contains(tab) ? 1 : 0);
    at = pinned.contains(tab)
        ? at.clamp(0, pins)
        : at.clamp(pins, to.tabs.length - (same ? 1 : 0));
    if (same && at == oldIndex) {
      final changed = from.active != tab || focused != from.id;
      activate(tab);
      return changed;
    }
    from.tabs.remove(tab);
    if (from.active == tab) {
      from.active = from.tabs.isEmpty
          ? null
          : from.tabs[oldIndex.clamp(0, from.tabs.length - 1)];
    }
    to.tabs.insert(at, tab);
    to.active = tab;
    focused = to.id;
    if (!identical(from, to) && from.tabs.isEmpty) mergeGroup(from.id);
    return true;
  }

  void remove(String tab) {
    final g = owner(tab);
    if (g == null) return;
    final i = g.tabs.indexOf(tab);
    g.tabs.remove(tab);
    pinned.remove(tab);
    if (g.active == tab) {
      g.active = g.tabs.isEmpty ? null : g.tabs[i.clamp(0, g.tabs.length - 1)];
    }
    if (g.tabs.isEmpty && groups.length > 1) mergeGroup(g.id);
  }

  String? split(
    String groupId,
    SplitAxis axis, {
    String? tab,
    bool before = false,
  }) {
    final original = group(groupId);
    if (original == null || groups.length >= maxGroups) return null;
    final next = TabGroup('g${++_serial}');
    groups.insert(groups.indexOf(original) + (before ? 0 : 1), next);
    final branch = TabSplit(
      's${++_serial}',
      axis,
      TabLeaf(before ? next.id : original.id),
      TabLeaf(before ? original.id : next.id),
    );
    root = _replace(root, groupId, branch);
    // A deliberate split can leave an empty group ready for the next document.
    if (tab != null) {
      final from = owner(tab);
      if (from != null) {
        final i = from.tabs.indexOf(tab);
        from.tabs.remove(tab);
        if (from.active == tab) {
          from.active = from.tabs.isEmpty
              ? null
              : from.tabs[(i - 1).clamp(0, from.tabs.length - 1)];
        }
        next.tabs.add(tab);
        next.active = tab;
      }
    }
    focused = next.id;
    return next.id;
  }

  TabNode _replace(TabNode node, String id, TabNode replacement) {
    if (node is TabLeaf) return node.group == id ? replacement : node;
    final s = node as TabSplit;
    s.first = _replace(s.first, id, replacement);
    s.second = _replace(s.second, id, replacement);
    return s;
  }

  TabNode? _without(TabNode node, String id) {
    if (node is TabLeaf) return node.group == id ? null : node;
    final s = node as TabSplit;
    final a = _without(s.first, id), b = _without(s.second, id);
    if (a == null) return b;
    if (b == null) return a;
    s.first = a;
    s.second = b;
    return s;
  }

  void mergeGroup(String id) {
    final g = group(id);
    if (g == null || groups.length < 2) return;
    final i = groups.indexOf(g);
    final to = groups[i == 0 ? 1 : i - 1];
    to.tabs.addAll(g.tabs);
    if (focused == id) {
      focused = to.id;
      to.active = g.active ?? to.active;
    }
    to.active ??= to.tabs.firstOrNull;
    groups.remove(g);
    root = _without(root, id)!;
    _sortPins(to);
  }

  void arrange(EditorArrangement arrangement) {
    final ids = ordered, active = current.active;
    final count = switch (arrangement) {
      EditorArrangement.single => 1,
      EditorArrangement.threeColumns => 3,
      EditorArrangement.grid => 4,
      _ => 2,
    };
    groups
      ..clear()
      ..addAll(List.generate(count, (_) => TabGroup('g${++_serial}')));
    for (var i = 0; i < ids.length; i++) {
      groups[(i * count ~/ ids.length).clamp(0, count - 1)].tabs.add(ids[i]);
    }
    for (final g in groups) {
      g.active = g.tabs.contains(active) ? active : g.tabs.firstOrNull;
      _sortPins(g);
    }
    focused = owner(active ?? '')?.id ?? groups.first.id;
    TabNode leaf(int i) => TabLeaf(groups[i].id);
    TabSplit branch(
      SplitAxis axis,
      TabNode a,
      TabNode b, [
      double ratio = .5,
    ]) => TabSplit('s${++_serial}', axis, a, b, ratio: ratio);
    root = switch (arrangement) {
      EditorArrangement.single => leaf(0),
      EditorArrangement.rows => branch(SplitAxis.vertical, leaf(0), leaf(1)),
      EditorArrangement.threeColumns => branch(
        SplitAxis.horizontal,
        leaf(0),
        branch(SplitAxis.horizontal, leaf(1), leaf(2)),
        1 / 3,
      ),
      EditorArrangement.grid => branch(
        SplitAxis.vertical,
        branch(SplitAxis.horizontal, leaf(0), leaf(1)),
        branch(SplitAxis.horizontal, leaf(2), leaf(3)),
      ),
      _ => branch(SplitAxis.horizontal, leaf(0), leaf(1)),
    };
  }

  bool resizeSplit(String id, double ratio) {
    var changed = false;
    void visit(TabNode node) {
      if (node is! TabSplit) return;
      if (node.id == id && ratio.isFinite) {
        final next = ratio.clamp(.15, .85);
        if (node.ratio != next) {
          node.ratio = next;
          changed = true;
        }
      }
      visit(node.first);
      visit(node.second);
    }

    visit(root);
    return changed;
  }

  /// Call with file IDs only for persistence. Terminal/AI tasks are never
  /// resurrected from this snapshot, and no buffer contents are serialized.
  Map<String, dynamic> toJson({Set<String>? allowed}) {
    bool keep(String id) => allowed == null || allowed.contains(id);
    Object node(TabNode n) => n is TabLeaf
        ? {'group': n.group}
        : {
            'id': (n as TabSplit).id,
            'axis': n.axis.name,
            'ratio': n.ratio,
            'first': node(n.first),
            'second': node(n.second),
          };
    return {
      'version': 1,
      'focused': focused,
      'placement': placement.name,
      'side_width': sideWidth,
      'tabs_width': tabsWidth,
      'tab_width': tabWidth,
      'pinned': pinned.where(keep).toList(),
      'groups': [
        for (final g in groups)
          {
            'id': g.id,
            'tabs': g.tabs.where(keep).toList(),
            if (g.active != null && keep(g.active!)) 'active': g.active,
          },
      ],
      'root': node(root),
    };
  }

  factory TabLayout.fromJson(
    Map<String, dynamic> json,
    Iterable<String> valid,
  ) {
    final layout = TabLayout();
    double number(String name, double fallback, double min, double max) {
      final v = json[name];
      return v is num && v.isFinite ? v.toDouble().clamp(min, max) : fallback;
    }

    layout.sideWidth = number('side_width', 300, 180, 640);
    layout.tabsWidth = number('tabs_width', 180, 120, 400);
    layout.tabWidth = number('tab_width', 160, 100, 260);
    layout.placement =
        TabPlacement.values
            .where((p) => p.name == json['placement'])
            .firstOrNull ??
        TabPlacement.top;
    try {
      final raw = json['groups'];
      if (raw is! List || raw.isEmpty || raw.length > maxGroups) {
        throw const FormatException();
      }
      final groups = <TabGroup>[];
      for (final item in raw) {
        if (item is! Map ||
            item['id'] is! String ||
            groups.any((g) => g.id == item['id'])) {
          throw const FormatException();
        }
        final id = item['id'] as String;
        if (!RegExp(r'^g[0-9]{1,8}$').hasMatch(id)) {
          throw const FormatException();
        }
        final tabs = item['tabs'];
        groups.add(
          TabGroup(
            id,
            tabs: tabs is List
                ? tabs.whereType<String>().take(2000).toList()
                : [],
            active: item['active'] is String ? item['active'] as String : null,
          ),
        );
      }
      final used = <String>{};
      var serial = 100;
      TabNode parse(Object? value, int depth) {
        if (value is! Map || depth > 4) throw const FormatException();
        final id = value['group'];
        if (id is String) {
          if (!groups.any((g) => g.id == id) || !used.add(id)) {
            throw const FormatException();
          }
          return TabLeaf(id);
        }
        final axis = SplitAxis.values
            .where((a) => a.name == value['axis'])
            .firstOrNull;
        if (axis == null) throw const FormatException();
        final r = value['ratio'];
        return TabSplit(
          's${++serial}',
          axis,
          parse(value['first'], depth + 1),
          parse(value['second'], depth + 1),
          ratio: r is num && r.isFinite ? r.toDouble().clamp(.15, .85) : .5,
        );
      }

      final root = parse(json['root'], 0);
      if (used.length != groups.length) throw const FormatException();
      layout.groups
        ..clear()
        ..addAll(groups);
      layout.root = root;
      layout._serial = groups
          .map((g) => int.parse(g.id.substring(1)))
          .fold(serial, (a, b) => a > b ? a : b);
      layout.focused =
          json['focused'] is String && used.contains(json['focused'])
          ? json['focused'] as String
          : groups.first.id;
      if (json['pinned'] is List) {
        layout.pinned.addAll(
          (json['pinned'] as List).whereType<String>().take(2000),
        );
      }
    } on Object {
      /* A damaged view must never make the encrypted profile unreadable. */
    }
    layout.reconcile(valid);
    return layout;
  }

  TabLayout();
}
