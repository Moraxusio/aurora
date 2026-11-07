// The add-server wizard against a real SSH server and a real install
// (agent/tools/ui-ssh.sh, started as root by app/tool/install_ui_test.ps1):
// fill in the form, confirm the host key, watch the stages, and land on a
// connected server whose terminal works. Then uninstall from the overview.
import 'dart:io';

import 'package:aurora/main.dart';
import 'package:aurora/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const addr = String.fromEnvironment('AURORA3_SSH_ADDR');
const hostKey = String.fromEnvironment('AURORA3_SSH_HOSTKEY');
const password = String.fromEnvironment('AURORA3_SSH_PASSWORD');

Future<void> pumpFor(WidgetTester t, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> waitFor(WidgetTester t, Finder f, {Duration upTo = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(upTo);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return;
  }
  throw TestFailure('not found within $upTo: $f');
}

Finder field(String label) => find.widgetWithText(TextFormField, label);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('add a server through the wizard, then uninstall', (t) async {
    expect(addr, isNotEmpty, reason: 'run through app/tool/install_ui_test.ps1');
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      final s = d.exceptionAsString();
      if (s.contains('view ID is null') || s.contains('no client is set')) return;
      prev?.call(d);
    };
    addTearDown(() => FlutterError.onError = prev);

    final dir = await Directory.systemTemp.createTemp('aurora3-ui-install-');
    addTearDown(() => dir.delete(recursive: true));
    final app = AppState();
    await app.initAt('${dir.path}\\profile.bin');
    expect(app.builds, isNotEmpty, reason: 'AURORA3_AGENT_DIR has the signed build: ${app.buildsError}');
    await t.pumpWidget(AuroraApp(app: app));

    await t.tap(find.text('添加服务器'));
    await pumpFor(t, const Duration(milliseconds: 600));
    final i = addr.lastIndexOf(':');
    await t.enterText(field('名称'), 'wsl-wizard');
    await t.enterText(field('SSH 地址'), addr.substring(0, i));
    await t.enterText(field('端口'), addr.substring(i + 1));
    await t.enterText(field('用户名'), 'root');
    await t.enterText(field('密码'), password);
    await t.tap(find.text('安装并连接'));

    // First contact: the host key is shown; it must be the server's.
    await waitFor(t, find.text('第一次连接这台服务器'));
    expect(find.textContaining(hostKey), findsOneWidget, reason: 'the dialog shows the fingerprint to compare');
    await t.tap(find.text('指纹一致，继续'));

    // The stages run, then the result.
    await waitFor(t, find.textContaining('安装完成'), upTo: const Duration(seconds: 90));
    for (final s in ['登录 SSH', '检查服务器', '上传 agent', '探测', '准备与校验', '切换', '确认新版本在运行', '读取直连参数']) {
      expect(find.text(s), findsOneWidget, reason: 'stage $s shown');
    }
    expect(find.byIcon(Icons.close), findsNothing, reason: 'no stage failed');
    await t.ensureVisible(find.text('完成'));
    await pumpFor(t, const Duration(milliseconds: 300));
    await t.tap(find.text('完成'));
    await pumpFor(t, const Duration(milliseconds: 600));

    // The new server is selected and connects directly, to the version the
    // build carried.
    await waitFor(t, find.textContaining('已连接'));
    const want = String.fromEnvironment('AURORA3_EXPECT_VERSION');
    if (want.isNotEmpty) expect(find.textContaining('agent $want'), findsOneWidget);
    expect(app.testKey, Platform.environment['AURORA3_TRUST_KEY'] == null ? isNull : isNotNull);
    final p = app.profile;
    final s = p.servers.single;
    expect(s.name, 'wsl-wizard');
    expect(s.direct!.ready, isTrue);
    expect(s.ssh!.password, password, reason: '"save the passwords" was on');
    expect(p.knownHost(addr.substring(0, i), int.parse(addr.substring(i + 1)))!.fingerprint, hostKey);

    // Its terminal works: a session can be created.
    await waitFor(t, find.text('新建会话'));
    await t.tap(find.widgetWithText(FilledButton, '新建会话'));
    await pumpFor(t, const Duration(milliseconds: 500));
    await t.tap(find.widgetWithText(FilledButton, '新建'));
    await waitFor(t, find.widgetWithText(ChoiceChip, 'main'));

    // Uninstall from the overview: the session is listed and must be
    // confirmed, then the agent is removed and the link goes away.
    await t.tap(find.descendant(of: find.byType(TabBar), matching: find.text('概览')));
    await pumpFor(t, const Duration(milliseconds: 600));
    await t.tap(find.text('卸载 agent'));
    await pumpFor(t, const Duration(milliseconds: 400));
    await t.tap(find.widgetWithText(FilledButton, '卸载'));
    await waitFor(t, find.text('还有终端会话在运行'));
    expect(find.textContaining('main'), findsWidgets);
    await t.tap(find.text('结束会话并卸载'));
    await waitFor(t, find.textContaining('已卸载'), upTo: const Duration(seconds: 60));
    expect(find.textContaining('/etc/aurora3'), findsWidgets, reason: 'config kept by a default uninstall');
  });
}
