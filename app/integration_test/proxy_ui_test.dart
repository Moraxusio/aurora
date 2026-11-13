// Real-window test for the proxy feature. It is run by app/tool/proxy_ui_test.ps1:
// a real agent in WSL, a real Windows test node, a real local HTTP subscription,
// and a real Flutter Windows window. The test intentionally does not use the
// installed v3 agent (17710); it uses a throwaway agent on 17796.
import 'dart:io';

import 'package:aurora/kernel/widgets.dart' show TreeRow;
import 'package:aurora/main.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import 'helpers.dart';

const addr = String.fromEnvironment('AURORA3_PROXY_UI_ADDR');
const pin = String.fromEnvironment('AURORA3_PROXY_UI_PIN');
const token = String.fromEnvironment('AURORA3_PROXY_UI_TOKEN');
const nodePort = int.fromEnvironment('AURORA3_PROXY_UI_NODE_PORT');
const expectedVersion = String.fromEnvironment('AURORA3_PROXY_UI_VERSION');
const upgradeFixture = String.fromEnvironment('AURORA3_PROXY_UI_UPGRADE');
const oldAgent = bool.fromEnvironment('AURORA3_PROXY_UI_OLD_AGENT');

class _Provider {
  final HttpServer server;
  final String body;
  _Provider(this.server, this.body);

  static Future<_Provider> start(int port) async {
    final body = '''
proxies:
  - {name: "窗口节点", type: trojan, server: 127.0.0.1, port: $port, password: ui-node-password-5d2c91, sni: node.example, skip-cert-verify: true}
  - {name: "Reality 不支持", type: vless, server: 127.0.0.1, port: 1, uuid: b831381d-6324-4d53-ad4f-8cda48b30811, tls: true, flow: xtls-rprx-vision, reality-opts: {public-key: AAAA, short-id: bb}}
  - {name: "不可达节点", type: trojan, server: 127.0.0.1, port: 1, password: ui-dead-node-password, skip-cert-verify: true}
''';
    final s = await HttpServer.bind('127.0.0.1', 0);
    final p = _Provider(s, body);
    s.listen((r) async {
      r.response.write(body);
      await r.response.close();
    });
    return p;
  }

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/sub?token=WINDOW-TEST-KEY');

  Future<void> close() => server.close(force: true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('代理页添加订阅、显示节点、选用节点，并在终端对话框显示走代理', (t) async {
    expect(addr, isNotEmpty, reason: 'run through app/tool/proxy_ui_test.ps1');
    expect(nodePort, greaterThan(0), reason: 'the Windows test node did not start');
    t.view.physicalSize = const Size(1700, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });

    final provider = await _Provider.start(nodePort);
    addTearDown(provider.close);
    final dir = await Directory.systemTemp.createTemp('aurora3-proxy-ui-');
    addTearDown(() => dir.delete(recursive: true));

    final store = await ProfileStore.open('${dir.path}\\profile.bin', DpapiSealer());
    await store.update((p) {
      final s = ServerEntry.create('proxy-ui');
      s.direct = DirectParams(port: 17796, addrs: [addr], pin: pin, token: token);
      p.servers.add(s);
      p.selected = s.id;
    });
    await store.close();
    final app = AppState();
    await app.initAt('${dir.path}\\profile.bin');
    await t.pumpWidget(AuroraApp(app: app));

    await waitFor(t, find.textContaining('127.0.0.1:17796'), upTo: const Duration(seconds: 20));
    expect(app.link(app.profile.servers.single.id)!.server.version, expectedVersion);

    // Connecting only shows a passive version notice. The upload dialog is
    // opened by an explicit click; old agents show the SSH compatibility path
    // instead of silently attempting a direct upgrade.
    if (upgradeFixture.isNotEmpty) {
      final notice = find.widgetWithText(TextButton, '升级 agent');
      await waitFor(t, notice, upTo: const Duration(seconds: 15));
      await click(t, notice);
      if (oldAgent) {
        expect(find.text('打开 SSH 升级向导'), findsOneWidget);
        await click(t, find.text('打开 SSH 升级向导'));
        await waitFor(t, find.textContaining('重新安装或配对'), upTo: const Duration(seconds: 10));
        expect(find.byType(BackButton), findsOneWidget);
        await t.tap(find.byType(BackButton));
        await t.pumpAndSettle();
        // 3.2.0 deliberately has no proxy service. This branch is only the
        // version notice/SSH fallback assertion; the current-agent branch
        // below covers the proxy UI and close confirmation.
        return;
      } else {
        expect(find.text('确认升级'), findsOneWidget);
        expect(find.textContaining('30 秒安静窗口'), findsOneWidget);
        await click(t, find.text('取消'));
      }
    }
    await activity(t, '代理', title: '代理');
    await waitFor(t, find.byTooltip('添加订阅或节点…'));
    await click(t, find.byTooltip('添加订阅或节点…'));
    await t.pumpAndSettle();
    expect(find.text('添加代理来源'), findsOneWidget);

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await t.enterText(fields.at(0), '窗口订阅');
    await t.enterText(fields.at(1), provider.url.toString());
    await t.tap(find.widgetWithText(FilledButton, '添加'));
    await t.pumpAndSettle();

    await waitFor(t, find.text('窗口节点'), upTo: const Duration(seconds: 15));
    expect(find.text('Reality 不支持'), findsOneWidget);
    expect(find.textContaining('Reality'), findsWidgets);
    final blocked = t.widget<TreeRow>(find.byWidgetPredicate((w) => w is TreeRow && w.label == 'Reality 不支持'));
    expect(blocked.onTap, isNull, reason: 'unsupported nodes cannot be selected');

    // A model-only timing test does not prove the number reaches the screen.
    // The row must display it, and retain it when another action rebuilds it.
    final nodeRow = find.byWidgetPredicate((w) => w is TreeRow && w.label == '窗口节点');
    await click(t, find.descendant(of: nodeRow, matching: find.byTooltip('测速')));
    await waitUntil(t, () => RegExp(r'^\d+ ms$').hasMatch(t.widget<TreeRow>(nodeRow).detail ?? ''), 'the node timing is displayed');

    await click(t, find.descendant(of: nodeRow, matching: find.byTooltip('用这个节点')));
    await t.pumpAndSettle();
    expect(find.text('这个节点不校验服务器证书'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, '仍然使用'));
    await t.pumpAndSettle();

    // proxy.status has returned through the real wire and the panel now shows
    // the selected node, rather than only a locally selected radio row.
    await waitFor(t, find.textContaining('窗口节点'), upTo: const Duration(seconds: 15));
    expect(find.byTooltip('不再使用代理节点'), findsOneWidget);

    expect(t.widget<TreeRow>(nodeRow).detail, matches(r'^\d+ ms$'), reason: 'choosing a node does not lose the timing');

    // The bulk action uses a separate path from the row's own timing button.
    // Include a refused connection so its failure must also survive a rebuild.
    final deadRow = find.byWidgetPredicate((w) => w is TreeRow && w.label == '不可达节点');
    await click(t, find.byTooltip('从这台服务器测速'));
    await waitUntil(t, () => t.widget<TreeRow>(deadRow).detail == '失败', 'the batch timing failure is displayed');
    await waitFor(t, find.byTooltip('从这台服务器测速'));
    expect(t.widget<TreeRow>(nodeRow).detail, matches(r'^\d+ ms$'));

    // Create the session through the dialog, not a direct session.create call.
    await terminalPanel(t);
    await waitFor(t, find.text('新建会话'));
    await click(t, find.widgetWithText(OutlinedButton, '新建会话'));
    await t.pumpAndSettle();
    expect(find.text('这个会话走代理'), findsOneWidget);
    expect(find.textContaining('窗口节点'), findsWidgets);
    expect(t.widget<CheckboxListTile>(find.byKey(const ValueKey('session-proxy'))).value, isFalse);
    await click(t, find.byKey(const ValueKey('session-proxy')));
    expect(t.widget<CheckboxListTile>(find.byKey(const ValueKey('session-proxy'))).value, isTrue);
    await click(t, find.widgetWithText(FilledButton, '创建'));
    await waitFor(t, find.byType(TerminalView));
    final terminal = t.widget<TerminalView>(find.byType(TerminalView)).terminal;
    String screen() => [for (var i = 0; i < terminal.buffer.lines.length; i++) terminal.buffer.lines[i].toString()].join('\n');
    await waitUntil(t, () => screen().contains(r'$'), 'the real shell is ready');
    // Feed terminal input, without using the desktop keyboard. The marker is
    // split in the command so its echoed input cannot satisfy the assertion.
    terminal.onOutput!(r'''case "$HTTP_PROXY" in http://aurora:*@127.0.0.1:*) echo UI-PROXY-"ENABLED";; *) echo UI-PROXY-"MISSING";; esac''' '\r');
    await waitUntil(t, () => screen().contains('UI-PROXY-ENABLED'), 'the session created by the checked dialog has proxy variables');
    expect(screen(), isNot(contains('UI-PROXY-MISSING')));

    // The entry operation reports the known proxy session and the legacy
    // session created by ui-agent.sh without a marker. Cancel must leave the
    // switch on; only the second explicit confirmation turns it off.
    if (!oldAgent) {
      await openOverview(t);
      final proxySwitch = find.byKey(const ValueKey('service-switch-proxy'));
      await waitFor(t, proxySwitch, upTo: const Duration(seconds: 10));
      expect(t.widget<Switch>(proxySwitch).value, isTrue);
      await click(t, proxySwitch);
      await waitFor(t, find.text('关闭代理服务？'));
      expect(find.textContaining('将影响 1 个代理会话'), findsOneWidget);
      expect(find.textContaining('另有 1 个旧会话的代理状态未知'), findsOneWidget);
      await click(t, find.text('取消'));
      expect(t.widget<Switch>(proxySwitch).value, isTrue);
      await click(t, proxySwitch);
      await waitFor(t, find.text('关闭代理服务？'));
      await click(t, find.text('关闭'));
      await waitUntil(t, () => !t.widget<Switch>(proxySwitch).value, 'proxy switch turns off after confirmation');
    }
  });
}
