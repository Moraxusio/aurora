import 'dart:convert';
import 'dart:io';

import 'package:aurora/features/monitor/monitor_view.dart';
import 'package:aurora/features/monitor/gpu_panel.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/main.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workbench_visual_test.dart' show VisualWorkbenchLink;
import 'gpu_fixture.dart';
import 'workspace_fixture.dart';

class MonitorWorkbenchLink extends VisualWorkbenchLink {
  final counts = <String, int>{};
  Map<String, dynamic>? hardwareSnapshot;
  MonitorWorkbenchLink(super.features);

  @override
  AgentInfo get server => AgentInfo({
    'version': '3.19.0',
    'os': 'windows',
    'arch': 'amd64',
    'caps': ['gpu.info'],
  });

  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    counts.update(op, (n) => n + 1, ifAbsent: () => 1);
    if (op == 'gpu.info') {
      if (hardwareSnapshot != null) {
        return {...hardwareSnapshot!, 'ts': 1794650400 + counts[op]! * 2};
      }
      final data = gpuFixture(ts: 1794650400 + counts[op]! * 2);
      final gpu = (data['gpus'] as List).first as Map;
      gpu['processes'] = [(gpu['processes'] as List).first];
      data['gpus'] = [gpu];
      return data;
    }
    if (op == 'sys.metrics') {
      return {
        'host': 'isolated-workstation',
        'platform': 'windows',
        'os': 'Windows',
        'kernel': 'Windows 11',
        'uptime': 7200,
        'cpu_model': 'Fixture CPU',
        'cpu_count': 8,
        'cpu': [100 + counts[op]! * 10, 0, 20, 500, 0, 0, 0, 0],
        'memory': {
          'MemTotal': 16 << 30,
          'MemAvailable': 8 << 30,
          'CommitTotal': 10 << 30,
          'CommitLimit': 32 << 30,
        },
        'load': <num>[],
        'load_supported': false,
        'disks': [
          {
            'mount': 'C:\\',
            'fstype': 'NTFS',
            'used': 100 << 30,
            'total': 512 << 30,
          },
        ],
      };
    }
    if (op == 'proc.list') {
      return {
        'processes': [
          for (var i = 0; i < 30; i++)
            {
              'pid': 4000 + i,
              'user': 'fixture',
              'args': 'synthetic process $i',
              'rss': 64 << 20,
              'cpu': i / 2,
            },
        ],
      };
    }
    final result = await super.call(op, args, timeout);
    if (op == 'agent.services') {
      for (final service in (result as Map)['services'] as List) {
        if (service['id'] == 'monitor') {
          (service['ops'] as List).add('gpu.info');
        }
      }
    }
    return result;
  }
}

/// LayoutBuilder descendants of an offscreen sliver may not be mounted yet.
/// Scroll from a known endpoint before looking for their rendered text.
Future<void> revealMonitor(WidgetTester t, Finder target) async {
  final scroll = find
      .descendant(
        of: find.byType(MonitorTab),
        matching: find.byType(Scrollable),
      )
      .first;
  if (target.evaluate().isEmpty) {
    t.state<ScrollableState>(scroll).position.jumpTo(0);
    await t.pump();
    await t.scrollUntilVisible(target, 180, scrollable: scroll, maxScrolls: 40);
  }
  await t.ensureVisible(target);
  await t.pump(const Duration(milliseconds: 60));
  expect(target.hitTestable(), findsOneWidget);
}

/// The actual monitor scroll view, Navigator, scaling and workbench hosts.
Future<void> exerciseMonitor(
  WidgetTester t, {
  GlobalKey? frame,
  Future<void> Function(String)? capture,
  String theme = 'dark',
}) async {
  final features = Features();
  final link = MonitorWorkbenchLink(features);
  final app = WorkspaceApp(wire: link);
  app.appearance.set('theme', theme);
  Future<void> frames([int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 60));
    }
    expect(t.takeException(), isNull);
    expect(find.byType(ErrorWidget, skipOffstage: false), findsNothing);
  }

  await t.pumpWidget(
    RepaintBoundary(
      key: frame,
      child: AuroraApp(app: app),
    ),
  );
  await frames();
  final ws =
      (t.state(find.byType(Shell)) as dynamic).debugWorkspace as Workspace;
  try {
    ws.openTab(monitorTab(ws));
    await frames();
    final heading = find.text('设备详情与进程 · 1 个');
    await revealMonitor(t, heading);
    await frames();
    await t.tap(heading, kind: PointerDeviceKind.mouse);
    await frames();
    expect(find.text('PID 4123'), findsOneWidget);
    expect(find.text('/opt/train, eval/python & worker'), findsOneWidget);
    if (capture != null) await capture('expanded');
    for (final scale in [0.85, 1.0, 1.25, 1.5]) {
      app.appearance.set('uiScale', scale);
      await frames();
      await t.pump(const Duration(seconds: 2));
      await frames();
      await revealMonitor(t, heading);
      await frames();
      expect(find.text('PID 4123'), findsOneWidget);
      await t.tap(heading, kind: PointerDeviceKind.mouse);
      await frames();
      await t.tap(heading, kind: PointerDeviceKind.mouse);
      await frames();
      if (capture != null) await capture('zoom-${(scale * 100).round()}');
    }
    final hardware = Platform.environment['AURORA_GPU_NATIVE_FIXTURE'];
    if (hardware != null) {
      link.hardwareSnapshot =
          jsonDecode(File(hardware).readAsStringSync()) as Map<String, dynamic>;
      app.appearance.set('uiScale', 1.0);
      await t.pump(const Duration(seconds: 2));
      await frames();
      final card = (link.hardwareSnapshot!['gpus'] as List).first as Map;
      final heading = find.text(
        '设备详情与进程 · ${(card['processes'] as List).length} 个',
      );
      await revealMonitor(t, heading);
      final panel = t.widget<GpuPanel>(find.byType(GpuPanel));
      expect(
        panel.error,
        isNull,
        reason: 'hardware snapshot requests: ${link.counts}',
      );
      expect((panel.data!['gpus'] as List).first['uuid'], card['uuid']);
      await frames();
      await t.tap(heading, kind: PointerDeviceKind.mouse);
      await frames();
      expect(find.text('UUID  ${card['uuid']}'), findsOneWidget);
      if ((card['processes'] as List).isNotEmpty) {
        expect(find.text('synthetic-gpu-process.exe'), findsWidgets);
      }
      if (capture != null) await capture('hardware');
    }
  } finally {
    await app.appearance.flush();
    await ws.flushViews();
    await t.pumpWidget(const SizedBox());
    app.dispose();
    features.dispose();
  }
}
