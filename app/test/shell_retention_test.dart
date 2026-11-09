import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/feature.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'side bar and editor switches do not rebuild unrelated retained bodies',
    (t) async {
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final app = _App();
      final builds = <String, int>{};
      final terminal = _Feature('terminal', 'Terminal fixture', builds);
      final files = _Feature('files', 'Files fixture', builds);
      final features = Features();
      features.all
        ..clear()
        ..addAll([
          terminal,
          files,
          _Feature('monitor', 'Monitor fixture', builds),
        ]);
      final input = InputMode(touch: false);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: InputMode.scope(
            mode: input,
            child: Shell(app: app, features: features),
          ),
        ),
      );
      await t.pumpAndSettle();
      final ws = terminal.workspace!;
      ws.openTab(
        EditorTab(
          id: 'one',
          title: 'One',
          icon: Icons.description,
          builder: (_) => _Probe('one', builds),
        ),
      );
      ws.openTab(
        EditorTab(
          id: 'two',
          title: 'Two',
          icon: Icons.description,
          builder: (_) => _Probe('two', builds),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Files fixture'));
      await t.pumpAndSettle();
      final before = Map<String, int>.from(builds);
      for (var i = 0; i < 4; i++) {
        ws.activate(i.isEven ? 'one' : 'two');
        await t.pumpAndSettle();
        await t.tap(
          find.byTooltip(i.isEven ? 'Terminal fixture' : 'Files fixture'),
        );
        await t.pumpAndSettle();
      }
      expect(
        builds,
        before,
        reason: 'state is preserved without rebuilding hidden pages on every switch',
      );
      expect(
        app.wholeProfileReads,
        0,
        reason: 'switching must not copy all subscription nodes',
      );
      app.changed();
      await t.pumpAndSettle();
      expect(
        builds['one'],
        greaterThan(before['one']!),
        reason:
            'real profile/connection changes still invalidate configurations',
      );
      await t.pumpWidget(const SizedBox.shrink());
      features.dispose();
      input.dispose();
      app.dispose();
    },
  );
}

class _App extends AppState {
  final _entry = ServerEntry(id: 'fixture', name: 'fixture');
  final _link = _Link();
  int wholeProfileReads = 0;
  @override
  bool get ready => true;
  @override
  Profile get profile {
    wholeProfileReads++;
    return Profile(servers: [_entry], selected: _entry.id);
  }

  @override
  ServerEntry? server(String id) => id == _entry.id ? _entry : null;
  @override
  String? get selected => _entry.id;
  @override
  List<ServerEntry> get servers => [_entry];
  @override
  Link? link(String id) => _link;
  @override
  ConnStatus status(String id) =>
      ConnStatus(ConnState.connected, addr: 'fixture:17710');
  void changed() => notifyListeners();
}

class _Link implements Link {
  @override
  AgentInfo get server =>
      AgentInfo({'version': '3.3.0', 'arch': 'amd64', 'caps': <String>[]});
  @override
  bool get isClosed => false;
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async => {
    'services': [
      for (final id in ['terminal', 'files', 'monitor'])
        {'id': id, 'enabled': true, 'available': true, 'ops': <String>[]},
    ],
  };
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Feature extends Feature {
  @override
  final String id;
  @override
  final String title;
  final Map<String, int> builds;
  Workspace? workspace;
  _Feature(this.id, this.title, this.builds);
  @override
  IconData get icon => Icons.folder;
  @override
  String get service => id;
  @override
  List<String> get ops => const [];
  @override
  SideBarView sideBar(BuildContext context, Workspace ws) {
    workspace = ws;
    return SideBarView(title: title, body: _Probe(id, builds));
  }
}

class _Probe extends StatelessWidget {
  final String id;
  final Map<String, int> builds;
  const _Probe(this.id, this.builds);
  @override
  Widget build(BuildContext context) {
    builds.update(id, (n) => n + 1, ifAbsent: () => 1);
    return Text('body $id');
  }
}
