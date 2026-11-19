import 'package:aurora/features/git/git_feature.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/main.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_sub/aurora_sub.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workbench_visual_test.dart' show VisualWorkbenchLink;
import 'workspace_fixture.dart';

class ToolsWorkbenchLink extends VisualWorkbenchLink {
  ToolsWorkbenchLink(super.features);
  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    switch (op) {
      case 'git.repos':
        return {'repos': [{'repo': '/project', 'name': 'Aurora'}]};
      case 'git.status':
        return {'branch': 'workbench-redesign', 'upstream': 'origin/main', 'ahead': 2, 'behind': 1, 'files': [
          {'path': 'src/workbench.dart', 'x': 'M', 'y': '.'},
          {'path': 'src/theme.dart', 'x': '.', 'y': 'M'},
          {'path': 'test/navigation_test.dart', 'x': '?', 'y': '?'},
        ]};
      case 'fs.search':
        return {'files': [
          {'path': '/project/src/main.dart', 'matches': [
            {'line': 6, 'text': 'class Aurora extends StatelessWidget {', 'ranges': [[6, 12]]},
          ]},
        ], 'total': 1};
      case 'svc.list':
        return {'units': [
          for (final (name, active, description) in const [
            ('aurora-agent', 'active', 'Aurora remote workspace'),
            ('nginx', 'active', 'Web application gateway'),
            ('redis', 'active', 'Cache service'),
            ('worker', 'failed', 'Background job worker'),
          ]) {'name': '$name.service', 'active': active, 'sub': active == 'active' ? 'running' : 'failed', 'load': 'loaded', 'description': description},
        ]};
      case 'agent.actions':
        return {'actions': {}};
      case 'net.ports':
        return {'ports': [
          {'addr': '127.0.0.1', 'port': 3000, 'process': 'node · development'},
          {'addr': '127.0.0.1', 'port': 5432, 'process': 'postgres'},
        ]};
      case 'proxy.status':
        return {'running': true, 'node': {'name': '开发网络', 'proto': 'trojan', 'verify': 'system'}, 'total': 42, 'failed': 0};
    }
    return super.call(op, args, timeout);
  }
}

/// Production tool panels with memory-only transport. Shared by the screenshot
/// regression and native engine audit; never opens user profiles or servers.
Future<void> exerciseWorkbenchTools(
  WidgetTester t, {
  required GlobalKey frame,
  required Future<void> Function(String) capture,
  Future<void> Function(Size)? resize,
}) async {
  final features = Features();
  final app = WorkspaceApp(wire: ToolsWorkbenchLink(features), profile: Profile(
    selected: 'server',
    servers: [ServerEntry(id: 'server', name: '开发服务器', selectedWorkspace: 'aurora', workspaces: [
      ProjectWorkspace(id: 'aurora', name: 'Aurora', folders: [ref('/project')]),
    ])],
    proxySources: [ProxySource(id: 'demo', name: '开发节点', nodes: [
      SubNode(proto: 'trojan', name: '开发网络', host: 'fixture.invalid', port: 443, secret: 'synthetic', tls: true).toAgent(),
    ])],
  ));
  Future<void> frames() async {
    for (var i = 0; i < 6; i++) { await t.pump(const Duration(milliseconds: 100)); }
    expect(t.takeException(), isNull);
    expect(find.byType(ErrorWidget, skipOffstage: false), findsNothing);
  }
  await t.pumpWidget(RepaintBoundary(key: frame, child: AuroraApp(app: app)));
  await frames();
  final ws = (t.state(find.byType(Shell)) as dynamic).debugWorkspace as Workspace;
  try {
    for (final theme in ['dark', 'light']) {
      app.appearance.set('theme', theme);
      await frames();
      if (theme == 'dark') await capture('tools-home-$theme');
      for (final (tip, id) in const [('搜索', 'search'), ('源代码管理', 'git'), ('系统服务', 'services'), ('端口转发', 'ports'), ('代理', 'proxy')]) {
        if (id == 'search') {
          await t.tap(find.byKey(const ValueKey('workbench-quick-open'))); await frames();
          await t.tap(find.text('文件内容')); await frames();
          await t.enterText(find.byKey(const ValueKey('workbench-search-query')), 'Aurora');
          await frames();
          if (theme == 'dark') await capture('unified-search-picker');
          await t.testTextInput.receiveAction(TextInputAction.done);
          await frames();
        } else {
          final navigation = find.byTooltip(tip);
          await t.ensureVisible(navigation); await frames();
          await t.tap(navigation); await frames();
        }
        if (id == 'git') {
          await t.enterText(find.descendant(of: find.byType(GitPanel), matching: find.byType(TextField)), '优化工作台导航与重连体验');
          await frames();
        }
        await capture('tools-$id-$theme');
      }
    }
    app.appearance.set('uiScale', 1.5); await frames();
    await capture('tools-proxy-zoom150');
    app.appearance.set('uiScale', 1.0); await frames();
    if (resize != null) {
      await resize(const Size(390, 760)); await frames();
      await capture('tools-proxy-narrow');
      await t.tap(find.byTooltip('搜索')); await frames();
      expect(find.text('Aurora'), findsWidgets);
      await capture('tools-search-narrow');
      await t.tap(find.byTooltip('源代码管理')); await frames();
      expect(find.text('优化工作台导航与重连体验'), findsOneWidget);
      await capture('tools-git-narrow');
      await resize(const Size(1440, 900)); await frames();
    }
    await ws.flushViews();
  } finally {
    await t.pumpWidget(const SizedBox()); await t.pump();
    features.dispose(); app.dispose();
  }
}
