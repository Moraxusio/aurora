import 'package:aurora/features/proxy/proxy_feature.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/widgets.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('large subscriptions build visible rows only and filtering keeps working', (t) async {
    final app = _App();
    final ws = Workspace(app, 'fixture');
    final input = InputMode(touch: false);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: InputMode.scope(mode: input, child: Scaffold(body: SizedBox(width: 300, child: ProxyPanel(ws: ws)))),
    ));
    await t.pumpAndSettle();
    expect(find.byType(TreeRow), findsWidgets);
    expect(find.byType(TreeRow).evaluate().length, lessThan(50), reason: 'do not construct all 2000 node rows');
    await t.enterText(find.byType(TextField), 'node 1999');
    await t.pumpAndSettle();
    expect(find.text('node 1999'), findsWidgets);
    expect(find.byType(TreeRow), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    ws.dispose();
    app.dispose();
    input.dispose();
  });
}

class _App extends AppState {
  final _profile = Profile(servers: [ServerEntry(id: 'fixture', name: 'fixture')], proxySources: [
    ProxySource(id: 'synthetic', name: 'synthetic', nodes: [
      for (var i = 0; i < 2000; i++) {'name': 'node $i', 'proto': 'trojan', 'host': '$i.invalid', 'port': 443, 'secret': 'synthetic'},
    ]),
  ]);
  final _link = _Link();
  @override
  Profile get profile => _profile;
  @override
  ServerEntry? server(String id) => _profile.server(id);
  @override
  Link? link(String id) => _link;
}

class _Link implements Link {
  @override
  bool get isClosed => false;
  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async =>
      op == 'proxy.status' ? {'running': false} : {'services': <Object>[]};
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
