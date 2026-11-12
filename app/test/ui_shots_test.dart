// Renders the window to PNG files for a look at the design (D-103). Runs only
// when AURORA_SHOTS names an output folder, and needs the Windows fonts:
//   AURORA_SHOTS=C:\build\shots flutter test test/ui_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/monitor/monitor_view.dart';
import 'package:aurora/kernel/desktop_lifecycle.dart';
import 'package:aurora/kernel/input_mode.dart';
import 'package:aurora/kernel/overview.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/window_frame.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora/ui/add_server.dart';
import 'package:aurora/ui/settings_page.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_fixture.dart';

final _out = Platform.environment['AURORA_SHOTS'];
final _shot = GlobalKey();

const _code = '''// The agent's entry point.
package main

import (
	"context"
	"log"
	"os/signal"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := run(ctx); err != nil {
		log.Fatal(err)
	}
}
''';

int _tick = 0;

/// Every feature's service on, with every operation it asks for, and
/// believable answers for each panel.
class ShotLink extends FileTreeLink {
  final Features features;
  ShotLink(this.features);

  @override
  Future<OpStream> open(String op, [Object? args, Priority priority = Priority.interactive]) async {
    throw OpError(codeUnsupported, 'stream stubbed in shots');
  }

  @override
  Future<Object?> call(String op, [Object? args, Duration timeout = const Duration(seconds: 60)]) async {
    final a = (args as Map?) ?? const {};
    switch (op) {
      case 'agent.services':
        final ops = <String, Set<String>>{};
        for (final f in features.all) {
          ops.putIfAbsent(f.service, () => {}).addAll(f.ops);
        }
        ops['systemd']!.addAll(['log.tail', 'agent.actions']);
        return {
          'services': [
            for (final e in ops.entries) {'id': e.key, 'enabled': true, 'available': true, 'ops': e.value.toList()},
          ],
        };
      case 'fs.read':
        return {'content': _code, 'etag': 'e1', 'size': _code.length};
      case 'session.list':
        return {
          'sessions': [
            {'name': 'main', 'windows': 3, 'attached': 1},
            {'name': 'build', 'windows': 1, 'attached': 0},
            {'name': 'logs', 'windows': 2, 'attached': 0},
          ],
        };
      case 'git.repos':
        return {
          'repos': [
            {'repo': '/project', 'name': 'aurora', 'top': '/fixture/home/project'},
          ],
        };
      case 'git.status':
        return {
          'branch': 'main',
          'oid': 'c118078',
          'upstream': 'origin/main',
          'ahead': 2,
          'behind': 0,
          'remotes': ['origin'],
          'stashes': 1,
          'files': [
            {'path': 'app/lib/kernel/shell.dart', 'x': 'M', 'y': '.'},
            {'path': 'app/lib/theme/ide_theme.dart', 'x': 'M', 'y': '.'},
            {'path': 'app/lib/kernel/window_frame.dart', 'x': 'A', 'y': '.'},
            {'path': 'app/lib/features/monitor/monitor_view.dart', 'x': '.', 'y': 'M'},
            {'path': 'docs/DESIGN.md', 'x': '.', 'y': 'M'},
            {'path': 'app/test/ui_shots_test.dart', 'x': '?', 'y': '?'},
          ],
        };
      case 'git.branches':
        return {
          'branches': [
            {'name': 'main', 'current': true, 'hash': 'c118078', 'upstream': 'origin/main', 'subject': 'Redesign the window', 'ahead': 2},
            {'name': 'feature/islands', 'hash': '4b2e9a1', 'subject': 'Island layout'},
            {'name': 'origin/main', 'remote': true, 'hash': 'b76c4ff', 'subject': 'Record the 3.8.0 package hashes'},
          ],
        };
      case 'git.log':
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        return {
          'commits': [
            for (final (i, s) in [
              'Redesign the window: islands layout, title bar, design tokens',
              'Record the 3.8.0 package hashes',
              'package: 3.8.0 README; ship LICENSE and NOTICE',
              'Search across files, Ctrl+P, split editor, settings',
              'Add the Apache License 2.0 (LICENSE, NOTICE)',
              'Record the 3.7.0 package hashes',
            ].indexed)
              {
                'hash': '${'c118078b76c4ffcd84ad695c5b10'.substring(i, i + 7)}000',
                'short': 'c118078b76c4ffcd84ad695c5b10'.substring(i, i + 7),
                'author': 'Aurora',
                'subject': s,
                'refs': i == 0 ? 'HEAD -> main' : (i == 2 ? 'tag: v3.8.0' : ''),
                'time': now - i * 5400 - 600,
              },
          ],
        };
      case 'git.stash':
        return {'stashes': <Object>[]};
      case 'git.tag':
        return {'tags': <Object>[]};
      case 'svc.list':
        return {
          'units': [
            for (final (n, d, act, sub) in [
              ('aurora3-agent.service', 'Aurora 3 agent', 'active', 'running'),
              ('nginx.service', 'A high performance web server', 'active', 'running'),
              ('postgresql.service', 'PostgreSQL RDBMS', 'active', 'exited'),
              ('docker.service', 'Docker Application Container Engine', 'active', 'running'),
              ('redis-server.service', 'Advanced key-value store', 'failed', 'failed'),
              ('cron.service', 'Regular background program processing daemon', 'active', 'running'),
              ('ssh.service', 'OpenBSD Secure Shell server', 'active', 'running'),
              ('certbot.service', 'Certbot', 'inactive', 'dead'),
            ])
              {'name': n, 'description': d, 'load': 'loaded', 'active': act, 'sub': sub, 'file': 'enabled'},
          ],
        };
      case 'agent.actions':
        return {'actions': <String, Object>{}};
      case 'net.ports':
        return {
          'ports': [
            {'port': 22, 'addr': '0.0.0.0', 'process': 'sshd', 'command': '/usr/sbin/sshd -D'},
            {'port': 80, 'addr': '0.0.0.0', 'process': 'nginx', 'command': 'nginx: master process'},
            {'port': 5432, 'addr': '127.0.0.1', 'process': 'postgres', 'command': 'postgres -D /var/lib/postgresql'},
            {'port': 6379, 'addr': '127.0.0.1', 'process': 'redis-server', 'command': 'redis-server 127.0.0.1:6379'},
            {'port': 8080, 'addr': '::', 'process': 'node', 'command': 'node server.js'},
          ],
        };
      case 'proxy.status':
        return {'active': false};
      case 'ai.sessions':
        return {
          'sessions': [
            {
              'id': 'ses_shot1',
              'title': '优化 Nginx 与修复 Redis 启动异常',
              'root': 'home',
              'workdir': '/project',
              'agent': 'build',
              'model': 'claude-sonnet-4-5',
              'running': false,
              'message_count': 4,
              'updated_at': DateTime.now().millisecondsSinceEpoch,
            },
          ],
        };
      case 'ai.get':
        return {
          'running': false,
          'session': {
            'id': 'ses_shot1',
            'title': '优化 Nginx 与修复 Redis 启动异常',
            'root': 'home',
            'workdir': '/project',
            'agent': 'build',
            'permission_mode': 'ask',
            'model': 'claude-sonnet-4-5',
            'protocol': 'anthropic-messages',
            'todos': [
              {'id': '1', 'content': '检查 redis-server.service 失败日志', 'status': 'completed', 'priority': 'high'},
              {'id': '2', 'content': '修复配置并重载服务验证', 'status': 'completed', 'priority': 'high'},
            ],
            'total_usage': {'input_tokens': 4820, 'output_tokens': 610, 'cache_read_tokens': 3900, 'total_tokens': 5430},
            'messages': [
              {
                'id': 'msg_u1',
                'role': 'user',
                'agent': 'build',
                'parts': [
                  {'type': 'text', 'text': '帮我检查为什么 redis-server.service 启动失败，并顺便看看项目入口代码。'},
                ],
                'created_at': DateTime.now().millisecondsSinceEpoch - 60000,
              },
              {
                'id': 'msg_a1',
                'role': 'assistant',
                'agent': 'build',
                'model': 'claude-sonnet-4-5',
                'parts': [
                  {'type': 'reasoning', 'text': '先查看 systemd 日志与项目目录结构，定位 Redis 绑定地址或目录权限问题。'},
                  {
                    'type': 'tool-call',
                    'tool_call_id': 'call_1',
                    'name': 'shell',
                    'input': {'command': 'journalctl -u redis-server.service -n 20 --no-pager'},
                  },
                  {
                    'type': 'tool-result',
                    'tool_call_id': 'call_1',
                    'name': 'shell',
                    'output': 'Could not create server TCP listening socket 127.0.0.1:6379: bind: Address already in use',
                  },
                  {
                    'type': 'text',
                    'text': '已定位原因：端口 `6379` 已被手动启动的 `redis-server` 进程占用，清理旧进程后服务恢复正常。',
                  },
                ],
                'snapshot': {
                  'start': 'a1b2c3d',
                  'end': 'e4f5g6h',
                  'files': [
                    {'file': 'config/redis.conf', 'additions': 2, 'deletions': 1, 'status': 'modified', 'patch': '@@ -12,1 +12,2 @@\n-supervised no\n+supervised systemd\n+maxmemory-policy allkeys-lru'},
                  ],
                },
                'created_at': DateTime.now().millisecondsSinceEpoch - 30000,
              },
            ],
          },
        };
      case 'sys.metrics':
        _tick++;
        final base = 1000000 + _tick * 400;
        return {
          'host': 'tokyo-dev',
          'os': 'Ubuntu 24.04.1 LTS',
          'kernel': '6.8.0-48-generic',
          'uptime': 1234567,
          'cpu_model': 'AMD EPYC 7B13',
          'cpu_count': 8,
          'cpu': [base + _tick * 90 + (_tick.isEven ? 120 : 30), 0, base ~/ 4 + _tick * 40, base * 3 + _tick * 300, 1000, 0, 0, 0],
          'memory': {'MemTotal': 16 << 30, 'MemAvailable': (6 << 30) + (_tick % 3) * (300 << 20), 'SwapTotal': 4 << 30, 'SwapFree': 3 << 30},
          'load': [0.84, 0.66, 0.52],
          'disks': [
            {'mount': '/', 'fstype': 'ext4', 'used': 61 << 30, 'total': 100 << 30},
            {'mount': '/data', 'fstype': 'xfs', 'used': 912 << 30, 'total': 1000 << 30},
            {'mount': '/boot', 'fstype': 'vfat', 'used': 120 << 20, 'total': 512 << 20},
          ],
        };
      case 'proc.list':
        return {
          'processes': [
            for (final (pid, user, cpu, rss, args) in [
              (1423, 'postgres', 38.2, 812 << 20, 'postgres: checkpointer'),
              (982, 'root', 12.5, 64 << 20, '/usr/local/bin/aurora3-agent serve'),
              (2211, 'www-data', 6.1, 48 << 20, 'nginx: worker process'),
              (3100, 'app', 4.4, 410 << 20, 'node server.js --port 8080'),
              (77, 'root', 0.8, 120 << 20, '/usr/bin/dockerd -H fd://'),
              (1, 'root', 0.0, 12 << 20, '/sbin/init'),
            ])
              {'pid': pid, 'user': user, 'cpu': cpu, 'rss': rss, 'args': args},
          ],
        };
    }
    try {
      return await super.call(op, a, timeout);
    } on OpError {
      rethrow;
    } on Object {
      throw OpError(codeNotFound, 'not in the fixture');
    }
  }
}

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    final file = File(f);
    if (file.existsSync()) l.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await l.load();
}

void main() {
  setUpAll(() async {
    if (_out == null) return;
    const w = r'C:\Windows\Fonts\';
    await _font(Ide.ui, ['${w}SegUIVar.ttf']);
    await _font('Segoe UI', ['${w}segoeui.ttf', '${w}segoeuib.ttf', '${w}seguisb.ttf']);
    await _font('Microsoft YaHei UI', ['${w}msyh.ttc', '${w}msyhbd.ttc']);
    await _font('Cascadia Mono', ['${w}CascadiaMono.ttf']);
    await _font('MaterialIcons', [r'C:\dev\VPS\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf']);
    Directory(_out!).createSync(recursive: true);
    DesktopLifecycle.frameless.value = true;
  });

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> snap(WidgetTester t, String name) async {
    await settle(t);
    final b = t.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
    await t.runAsync(() async {
      final img = await b.toImage(pixelRatio: t.view.devicePixelRatio);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<(Features, WorkspaceApp, InputMode)> open(WidgetTester t, Size size, Brightness b, {bool touch = false, bool servers = true}) async {
    t.view.devicePixelRatio = 1.5;
    t.view.physicalSize = size * 1.5;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final features = Features();
    final app = WorkspaceApp(wire: ShotLink(features));
    if (servers) {
      app.data.servers.single.name = 'tokyo-dev';
      app.data.servers.single.selectedWorkspace = 'a';
    } else {
      app.data.servers.clear();
    }
    final input = InputMode(touch: touch);
    await t.pumpWidget(RepaintBoundary(
      key: _shot,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(b),
        builder: (_, child) => InputMode.scope(mode: input, child: WindowChrome(child: child!)),
        home: Shell(app: app, features: features),
      ),
    ));
    await t.runAsync(() => precacheImage(const AssetImage('assets/branding/aurora3-256.png'), t.element(find.byType(Shell))));
    await settle(t);
    return (features, app, input);
  }

  Future<void> close(WidgetTester t, (Features, WorkspaceApp, InputMode) s) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 3));
    s.$1.dispose();
    s.$3.dispose();
    s.$2.dispose();
  }

  Workspace ws(WidgetTester t) => (t.state(find.byType(Shell)) as dynamic).debugWorkspace as Workspace;

  Future<void> rail(WidgetTester t, Features f, String id) async {
    await t.tap(find.byTooltip(f.byId(id)!.title).first);
    await settle(t);
  }

  Future<void> tapText(WidgetTester t, String s) async {
    final f = find.text(s);
    if (f.evaluate().isEmpty) return;
    await t.tap(f.first);
    await settle(t);
  }

  for (final b in Brightness.values) {
    final tag = b == Brightness.dark ? 'dark' : 'light';
    testWidgets('wide $tag', (t) async {
      final s = await open(t, const Size(1440, 900), b);
      await snap(t, '$tag-01-welcome');
      await rail(t, s.$1, 'files');
      for (final name in ['src', 'main.dart', 'README.md']) {
        await tapText(t, name);
      }
      await snap(t, '$tag-02-editor');
      await t.tap(find.byTooltip('命令面板（Ctrl+Shift+P）').first);
      await snap(t, '$tag-03-palette');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      await t.tap(find.byTooltip('切换服务器').first);
      await snap(t, '$tag-04-servers');
      await t.tapAt(const Offset(900, 600));
      await settle(t);
      for (final id in ['terminal', 'search', 'git', 'ai', 'systemd', 'net', 'proxy']) {
        await rail(t, s.$1, id);
        await snap(t, '$tag-10-$id');
      }
      await rail(t, s.$1, 'ai');
      await t.tap(find.byKey(const ValueKey('ai-session-ses_shot1')).first);
      await settle(t);
      await snap(t, '$tag-15-ai-studio');
      final w = ws(t);
      w.openTab(monitorTab(w));
      await settle(t);
      await t.pump(const Duration(seconds: 2));
      await snap(t, '$tag-20-monitor');
      await t.pump(const Duration(seconds: 2));
      await t.pump(const Duration(seconds: 2));
      await snap(t, '$tag-21-monitor-later');
      w.openTab(overviewTab(w, s.$1));
      await snap(t, '$tag-22-overview');
      w.openTab(settingsTab(w.app));
      await snap(t, '$tag-23-settings');
      await close(t, s);
    }, skip: _out == null);
  }

  testWidgets('medium dark', (t) async {
    final s = await open(t, const Size(820, 700), Brightness.dark);
    await snap(t, 'dark-30-medium');
    await rail(t, s.$1, 'files');
    await snap(t, 'dark-31-medium-drawer');
    await close(t, s);
  }, skip: _out == null);

  testWidgets('phone dark', (t) async {
    final s = await open(t, const Size(400, 820), Brightness.dark, touch: true);
    await snap(t, 'dark-40-phone');
    await close(t, s);
  }, skip: _out == null);

  testWidgets('no server', (t) async {
    final s = await open(t, const Size(1200, 760), Brightness.dark, servers: false);
    await snap(t, 'dark-50-empty');
    await t.tap(find.text('添加服务器'));
    await settle(t);
    await t.pump(const Duration(milliseconds: 400));
    await snap(t, 'dark-51-add-server');
    expect(find.byType(AddServerPage), findsOneWidget);
    await close(t, s);
  }, skip: _out == null);
}
