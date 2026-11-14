import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/monitor/gpu_panel.dart';
import 'package:aurora/features/monitor/monitor_view.dart';
import 'package:aurora/theme/ide_theme.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gpu_fixture.dart';
import 'support/workspace_fixture.dart';

class _Link extends FileTreeLink {
  final counts = <String, int>{};
  Completer<Object?>? gpuWait, systemWait;
  Object? gpuError;
  String host;
  _Link([this.host = 'gpu-server']);
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    counts.update(op, (n) => n + 1, ifAbsent: () => 1);
    if (op == 'gpu.info') {
      if (gpuError != null) throw gpuError!;
      return gpuWait?.future ?? gpuFixture(ts: 1794650400 + counts[op]! * 2);
    }
    if (op == 'proc.list') return {'processes': <Object>[]};
    if (op == 'sys.metrics') return systemWait?.future ?? metrics;
    return super.call(op, args, timeout);
  }

  Map<String, dynamic> get metrics => {
    'host': host,
    'os': 'Ubuntu 24.04',
    'kernel': '6.8.0',
    'uptime': 7200,
    'cpu_model': 'AMD EPYC',
    'cpu_count': 8,
    'cpu': [100 + (counts['sys.metrics'] ?? 1) * 10, 0, 20, 500, 0, 0, 0, 0],
    'memory': {'MemTotal': 16 << 30, 'MemAvailable': 8 << 30},
    'load': [0.5, 0.3, 0.2],
    'disks': <Object>[],
    'gpus': gpuFixture()['gpus'],
  };
}

void main() {
  Future<void> monitor(
    WidgetTester t,
    _Link link, {
    bool visible = true,
    bool detailed = true,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1200, 1100);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: TickerMode(
            enabled: visible,
            child: MonitorTab(link: link, gpuDetails: detailed),
          ),
        ),
      ),
    );
    await t.pump();
  }

  testWidgets(
    'slow GPU never blocks system refresh and requests do not overlap',
    (t) async {
      final link = _Link()..gpuWait = Completer<Object?>();
      await monitor(t, link);
      expect(find.text('gpu-server'), findsOneWidget);
      expect(find.text('正在读取 GPU 状态…'), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      await t.pump(const Duration(seconds: 2));
      expect(link.counts['gpu.info'], 1);
      expect(link.counts['sys.metrics'], 3);
      link.systemWait = Completer<Object?>();
      await t.pump(const Duration(seconds: 2));
      await t.pump(const Duration(seconds: 2));
      expect(link.counts['sys.metrics'], 4);
      link.gpuWait!.complete(gpuFixture());
      link.systemWait!.complete(link.metrics);
      await t.pump();
      await t.pump();
      expect(find.text('GPU 0 · NVIDIA RTX A6000'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('hidden monitor pauses polling and resumes immediately', (
    t,
  ) async {
    final link = _Link();
    await monitor(t, link, visible: false);
    await t.pump(const Duration(seconds: 4));
    expect(link.counts, isEmpty);
    await monitor(t, link);
    expect(link.counts['gpu.info'], 1);
    await monitor(t, link, visible: false);
    await t.pump(const Duration(seconds: 6));
    expect(link.counts['gpu.info'], 1);
    await monitor(t, link);
    expect(link.counts['gpu.info'], 2);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'late replies from an old link cannot replace the current server',
    (t) async {
      final old = _Link('old-host')
        ..gpuWait = Completer<Object?>()
        ..systemWait = Completer<Object?>();
      await monitor(t, old);
      final fresh = _Link('new-host');
      await monitor(t, fresh);
      old.gpuWait!.complete({...gpuFixture(), 'error': 'old GPU error'});
      old.systemWait!.complete(old.metrics);
      await t.pump();
      expect(find.text('new-host'), findsOneWidget);
      expect(find.text('old-host'), findsNothing);
      expect(find.textContaining('old GPU error'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('GPU transport failure retains the last reading and recovers', (
    t,
  ) async {
    final link = _Link();
    await monitor(t, link);
    link.gpuError = TimeoutException('synthetic timeout');
    await t.pump(const Duration(seconds: 2));
    expect(find.textContaining('当前显示上次成功数据'), findsOneWidget);
    expect(find.text('GPU 0 · NVIDIA RTX A6000'), findsOneWidget);
    expect(find.text('gpu-server'), findsOneWidget);
    link.gpuError = null;
    await t.pump(const Duration(seconds: 2));
    expect(find.textContaining('当前显示上次成功数据'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'old agents use basic GPU fields without retrying unsupported operations',
    (t) async {
      final link = _Link();
      await monitor(t, link, detailed: false);
      expect(link.counts['gpu.info'], isNull);
      expect(find.textContaining('旧版 agent'), findsOneWidget);
      expect(find.text('GPU 0 · NVIDIA RTX A6000'), findsOneWidget);
      link.gpuError = OpError(codeUnsupported, 'old agent');
      await monitor(t, link);
      await t.pump(const Duration(seconds: 4));
      expect(link.counts['gpu.info'], 1);
      expect(find.textContaining('旧版 agent'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('closing a monitor during requests safely discards replies', (
    t,
  ) async {
    final link = _Link()
      ..gpuWait = Completer<Object?>()
      ..systemWait = Completer<Object?>();
    await monitor(t, link);
    await t.pumpWidget(const SizedBox());
    link.gpuWait!.complete(gpuFixture());
    link.systemWait!.complete(link.metrics);
    await t.pump();
    expect(t.takeException(), isNull);
  });

  Future<void> panel(
    WidgetTester t,
    Map<String, dynamic> data, {
    double width = 1100,
    Brightness brightness = Brightness.dark,
    Key? boundary,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 1400);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(brightness),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: GpuPanel(
                data: data,
                legacy: false,
                history: {
                  'GPU-fixture-a': [
                    for (var i = 0; i < 30; i++)
                      GpuPoint(50 + i % 8 * 4, 40 + i / 3),
                  ],
                },
              ),
            ),
          ),
        ),
      ),
    );
    await t.pump();
  }

  testWidgets(
    'multiple cards expose processes, units and unavailable metrics correctly',
    (t) async {
      await panel(t, gpuFixture());
      expect(find.text('GPU 1 · NVIDIA H100 PCIe'), findsOneWidget);
      expect(find.text('82.0 %'), findsOneWidget);
      expect(find.text('24.0 GiB / 48.0 GiB'), findsOneWidget);
      expect(find.text('风扇 —'), findsOneWidget);
      await t.tap(find.text('设备详情与进程 · 2 个'));
      await t.pumpAndSettle();
      expect(find.text('PID 4123'), findsOneWidget);
      expect(find.text('/opt/train, eval/python & worker'), findsOneWidget);
      expect(find.textContaining('软件功耗限制'), findsOneWidget);
      expect(find.textContaining('16', findRichText: true), findsWidgets);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'missing tool, no devices, stale and unavailable process states are distinct',
    (t) async {
      await panel(t, {
        'status': 'unavailable',
        'gpus': [],
        'error': '未找到 nvidia-smi',
      });
      expect(find.text('未找到 nvidia-smi'), findsOneWidget);
      expect(find.text('未检测到 NVIDIA GPU。'), findsNothing);
      await panel(t, {'status': 'empty', 'gpus': []});
      expect(find.text('未检测到 NVIDIA GPU。'), findsOneWidget);
      final data = gpuFixture()
        ..['stale'] = true
        ..['error'] = '驱动超时';
      (data['gpus'] as List).first['processes_available'] = false;
      (data['gpus'] as List).first['processes'] = <Object>[];
      await panel(t, data);
      expect(find.textContaining('当前显示上次成功数据'), findsOneWidget);
      await t.tap(find.text('设备详情与进程'));
      await t.pumpAndSettle();
      expect(find.text('驱动未提供进程数据。'), findsOneWidget);
    },
  );

  testWidgets('GPU details fit a narrow pane and preserve unknown values', (
    t,
  ) async {
    await panel(t, gpuFixture(), width: 360);
    await t.ensureVisible(find.text('设备详情与进程 · 2 个'));
    await t.tap(find.text('设备详情与进程 · 2 个'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(gpuIdentity({'uuid': '', 'bus_id': '', 'index': 1}), '1');
  });

  testWidgets(
    'large GPU process lists are built only when expanded and remain scrollable',
    (t) async {
      final data = gpuFixture();
      final gpu = (data['gpus'] as List).first as Map;
      gpu['processes'] = [
        for (var i = 0; i < 600; i++)
          {
            'pid': 10000 + i,
            'name': 'synthetic worker $i',
            'type': 'C',
            'mem_used': null,
          },
      ];
      data['gpus'] = [gpu];
      await panel(t, data);
      expect(
        find.textContaining('synthetic worker', skipOffstage: false),
        findsNothing,
      );
      await t.tap(find.text('设备详情与进程 · 600 个'));
      await t.pumpAndSettle();
      expect(find.text('synthetic worker 0'), findsOneWidget);
      expect(
        find.textContaining('synthetic worker').evaluate().length,
        lessThan(20),
      );
      final scroll = find.descendant(
        of: find.byKey(const PageStorageKey('gpu-processes-GPU-fixture-a')),
        matching: find.byType(Scrollable),
      );
      final position = t.state<ScrollableState>(scroll).position;
      position.jumpTo(position.maxScrollExtent);
      await t.pumpAndSettle();
      expect(find.text('synthetic worker 599'), findsOneWidget);
      await t.tap(find.text('设备详情与进程 · 600 个'));
      await t.pumpAndSettle();
      expect(
        find.textContaining('synthetic worker', skipOffstage: false),
        findsNothing,
      );
      expect(t.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('GPU ${brightness.name} visual', (t) async {
      final out = Platform.environment['AURORA_GPU_SHOTS'];
      if (out != null) {
        for (final (family, file) in [
          ('Microsoft YaHei UI', r'C:\Windows\Fonts\msyh.ttc'),
          (Ide.ui, r'C:\Windows\Fonts\SegUIVar.ttf'),
          ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
          (Ide.mono, r'C:\Windows\Fonts\CascadiaMono.ttf'),
          (
            'MaterialIcons',
            r'C:\dev\VPS\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
          ),
        ]) {
          final loader = FontLoader(family)
            ..addFont(
              Future.value(ByteData.sublistView(File(file).readAsBytesSync())),
            );
          await loader.load();
        }
      }
      final key = GlobalKey();
      await panel(t, gpuFixture(), brightness: brightness, boundary: key);
      await t.tap(find.text('设备详情与进程 · 2 个'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      if (out != null) {
        final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key));
        await t.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory(out).createSync(recursive: true);
          await File('$out/gpu-${brightness.name}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
