import 'dart:async';

import 'package:aurora/features/monitor/monitor_controller.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gpu_fixture.dart';
import 'support/workspace_fixture.dart';

class _MonitorLink extends FileTreeLink {
  final requests = <String, int>{};
  Completer<Object?>? systemWait, gpuWait;
  Object? gpuData, legacyData, gpuError;
  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    requests.update(op, (n) => n + 1, ifAbsent: () => 1);
    if (op == 'gpu.info') {
      if (gpuError != null) throw gpuError!;
      return gpuWait?.future ?? gpuData ?? gpuFixture(ts: requests[op]!);
    }
    if (op == 'proc.list') return {'processes': []};
    return systemWait?.future ??
        {
          'host': 'fixture',
          'cpu': [10 * requests[op]!, 0, 10, 50],
          'load': <num>[],
          'memory': {'MemTotal': 1024, 'MemAvailable': 512},
          'disks': [],
          'gpus': legacyData,
        };
  }
}

void main() {
  testWidgets(
    'malformed legacy GPU data cannot fail system polling or escape unsupported fallback',
    (t) async {
      final link = _MonitorLink()..legacyData = [false];
      final monitor = MonitorController(link, gpuDetails: true)
        ..setVisible(true);
      await t.pump();
      expect(monitor.system.value.error, isNull);
      link.gpuError = OpError(codeUnsupported, 'fixture');
      monitor.refresh();
      await t.pump();
      expect(monitor.system.value.error, isNull);
      expect(monitor.gpu.value.error, contains('数据格式'));
      final requests = link.requests['gpu.info'];
      link.legacyData = gpuFixture()['gpus'];
      monitor.refresh();
      await t.pump();
      expect(monitor.gpu.value.legacy, isTrue);
      expect(monitor.gpu.value.error, isNull);
      expect(link.requests['gpu.info'], requests);
      monitor.dispose();
    },
  );

  testWidgets(
    'sustained polling bounds history and publishes detached snapshots',
    (t) async {
      final source = gpuFixture();
      final link = _MonitorLink()..gpuData = source;
      final monitor = MonitorController(link, gpuDetails: true)
        ..setVisible(true);
      await t.pump();
      final first = monitor.gpu.value.data!;
      (source['gpus'] as List).first['processes'].clear();
      expect(
        ((first['gpus'] as List).first['processes'] as List),
        hasLength(2),
      );
      for (var i = 0; i < 120; i++) {
        link.gpuData = gpuFixture(ts: 1794650400 + i * 2);
        await t.pump(const Duration(seconds: 2));
      }
      expect(monitor.system.value.cpuHistory, hasLength(60));
      expect(monitor.system.value.memoryHistory, hasLength(60));
      expect(
        monitor.gpu.value.history.values.every((h) => h.length == 60),
        isTrue,
      );
      expect(monitor.system.value.error, isNull);
      expect(monitor.gpu.value.error, isNull);
      monitor.dispose();
    },
  );

  testWidgets(
    'independent publications, immutable history and no overlapping polls',
    (t) async {
      final link = _MonitorLink()..gpuWait = Completer();
      final monitor = MonitorController(link, gpuDetails: true);
      var systems = 0, gpus = 0;
      monitor.system.addListener(() => systems++);
      monitor.gpu.addListener(() => gpus++);
      monitor.setVisible(true);
      await t.pump();
      expect(systems, 1);
      expect(gpus, 0);
      await t.pump(const Duration(seconds: 6));
      expect(link.requests['gpu.info'], 1);
      expect(systems, greaterThan(1));
      final history = monitor.system.value.cpuHistory.toList();
      final previous = monitor.system.value;
      link.gpuWait!.complete(gpuFixture());
      await t.pump();
      expect(gpus, 1);
      monitor.refresh();
      await t.pump();
      expect(previous.cpuHistory, history);
      monitor.dispose();
    },
  );

  testWidgets('bad GPU payload stays a local data error and recovers', (
    t,
  ) async {
    final link = _MonitorLink();
    final monitor = MonitorController(link, gpuDetails: true)..setVisible(true);
    await t.pump();
    final good = monitor.gpu.value.data;
    link.gpuData = {
      'gpus': [false],
    };
    monitor.refresh();
    await t.pump();
    expect(monitor.gpu.value.data, same(good));
    expect(monitor.gpu.value.error, contains('数据格式'));
    expect(monitor.system.value.error, isNull);
    link.gpuData = gpuFixture();
    monitor.refresh();
    await t.pump();
    expect(monitor.gpu.value.error, isNull);
    monitor.dispose();
  });

  testWidgets(
    'hidden and disposed monitors cannot start work; old generations cannot publish',
    (t) async {
      final old = _MonitorLink()
        ..gpuWait = Completer()
        ..systemWait = Completer();
      final monitor = MonitorController(old, gpuDetails: true);
      await t.pump(const Duration(seconds: 4));
      expect(old.requests, isEmpty);
      monitor.setVisible(true);
      final fresh = _MonitorLink();
      monitor.bind(fresh, gpuDetails: true);
      await t.pump();
      final good = monitor.gpu.value.data;
      old.gpuWait!.complete({'gpus': [], 'error': 'obsolete'});
      old.systemWait!.complete({'bad': true});
      await t.pump();
      expect(monitor.gpu.value.data, same(good));
      expect(monitor.system.value.error, isNull);
      monitor.setVisible(false);
      final count = fresh.requests['gpu.info'];
      await t.pump(const Duration(seconds: 10));
      monitor.refresh();
      await t.pump();
      expect(fresh.requests['gpu.info'], count);
      monitor.dispose();
      monitor.refresh();
    },
  );
}
