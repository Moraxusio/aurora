import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';

import 'gpu_data.dart';

/// Immutable publications: a painter never observes a list being mutated by a
/// later poll. System and GPU have independent subscriptions and failure paths.
class SystemReading {
  final Map<String, dynamic>? data;
  final List<Map<String, dynamic>> processes;
  final List<double> cpuHistory, memoryHistory;
  final double? cpu;
  final String? error;
  const SystemReading({
    this.data,
    this.processes = const [],
    this.cpuHistory = const [],
    this.memoryHistory = const [],
    this.cpu,
    this.error,
  });
  SystemReading failed(String error) => SystemReading(
    data: data,
    processes: processes,
    cpuHistory: cpuHistory,
    memoryHistory: memoryHistory,
    cpu: cpu,
    error: error,
  );
}

class GpuReading {
  final Map<String, dynamic>? data;
  final bool legacy;
  final String? error;
  final Map<String, List<GpuPoint>> history;
  const GpuReading({
    this.data,
    this.legacy = false,
    this.error,
    this.history = const {},
  });
}

class MonitorController {
  Link _link;
  bool _details, _unsupported = false, _visible = false, _disposed = false;
  bool _systemBusy = false, _gpuBusy = false;
  int _generation = 0;
  Timer? _timer;
  List<int>? _previousCpu;
  num? _gpuTimestamp;
  final system = ValueNotifier(const SystemReading());
  final gpu = ValueNotifier(const GpuReading());

  MonitorController(Link link, {required bool gpuDetails})
    : _link = link,
      _details = gpuDetails {
    gpu.value = GpuReading(legacy: !gpuDetails);
  }

  void bind(Link link, {required bool gpuDetails}) {
    if (identical(_link, link) && _details == gpuDetails) return;
    _generation++;
    _link = link;
    _details = gpuDetails;
    _unsupported = _systemBusy = _gpuBusy = false;
    _previousCpu = null;
    _gpuTimestamp = null;
    system.value = const SystemReading();
    gpu.value = GpuReading(legacy: !gpuDetails);
    refresh();
  }

  void setVisible(bool visible) {
    if (_disposed || _visible == visible) return;
    _visible = visible;
    _timer?.cancel();
    _timer = null;
    if (!visible) {
      _previousCpu = null;
      return;
    }
    refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
  }

  void refresh() {
    if (_disposed || !_visible || _link.isClosed) return;
    unawaited(_readSystem());
    if (_details && !_unsupported) unawaited(_readGpu());
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  static List<double> _append(List<double> history, double value) =>
      List.unmodifiable([...history.skip(history.length >= 60 ? 1 : 0), value]);
  static int _busy(List<int> cpu) =>
      cpu.fold(0, (a, b) => a + b) - cpu[3] - (cpu.length > 4 ? cpu[4] : 0);

  Future<void> _readSystem() async {
    if (_systemBusy) return;
    _systemBusy = true;
    final generation = _generation, link = _link;
    try {
      final values = await Future.wait([
        link.call('sys.metrics', null, const Duration(seconds: 8)),
        link.call('proc.list', {'limit': 30}, const Duration(seconds: 8)),
      ]);
      if (!_current(generation)) return;
      final m = _systemData(values[0]);
      final processes = List<Map<String, dynamic>>.unmodifiable([
        for (final p in _maps(_map(values[1])['processes']))
          Map<String, dynamic>.unmodifiable({
            ...p,
            'cpu': _optionalNumber(p['cpu']),
            'rss': _optionalNumber(p['rss']),
          }),
      ]);
      final cpu = [for (final n in m['cpu'] as List<num>) n.toInt()];
      final previous = _previousCpu, old = system.value;
      var usage = old.cpu;
      var history = old.cpuHistory, memory = old.memoryHistory;
      if (previous != null &&
          previous.length == cpu.length &&
          cpu.length >= 4) {
        final total =
            cpu.fold<int>(0, (a, b) => a + b) -
            previous.fold<int>(0, (a, b) => a + b);
        usage = total <= 0
            ? 0
            : (100 * (_busy(cpu) - _busy(previous)) / total).clamp(0, 100);
        history = _append(history, usage);
      }
      _previousCpu = _visible ? cpu : null;
      final mem = m['memory'] as Map;
      final total = _number(mem['MemTotal']);
      if (total > 0) {
        memory = _append(
          memory,
          (100 * (total - _number(mem['MemAvailable'])) / total).clamp(0, 100),
        );
      }
      system.value = SystemReading(
        data: m,
        processes: processes,
        cpu: usage,
        cpuHistory: history,
        memoryHistory: memory,
      );
      if (!_details || _unsupported) _publishLegacy();
    } catch (error) {
      if (_current(generation)) {
        system.value = system.value.failed(_message(error, '监控'));
      }
    } finally {
      if (_current(generation)) _systemBusy = false;
    }
  }

  Future<void> _readGpu() async {
    if (_gpuBusy) return;
    _gpuBusy = true;
    final generation = _generation;
    try {
      final data = _gpuData(
        await _link.call('gpu.info', null, const Duration(seconds: 8)),
      );
      if (!_current(generation)) return;
      final ts = data['ts'] as num?;
      var history = gpu.value.history;
      if (data['status'] == 'ok' &&
          data['stale'] != true &&
          ts != null &&
          ts != _gpuTimestamp) {
        history = {
          for (final g in data['gpus'] as List<Map<String, dynamic>>)
            gpuIdentity(g): List.unmodifiable([
              ...(history[gpuIdentity(g)] ?? const <GpuPoint>[]).skip(
                (history[gpuIdentity(g)]?.length ?? 0) >= 60 ? 1 : 0,
              ),
              GpuPoint.fromMap(g),
            ]),
        };
        _gpuTimestamp = ts;
      }
      gpu.value = GpuReading(data: data, history: Map.unmodifiable(history));
    } catch (error) {
      if (!_current(generation)) return;
      if (error is OpError &&
          (error.code == codeNotFound || error.code == codeUnsupported)) {
        _unsupported = true;
        _publishLegacy();
      } else {
        gpu.value = GpuReading(
          data: gpu.value.data,
          history: gpu.value.history,
          error: _message(error, 'GPU'),
        );
      }
    } finally {
      if (_current(generation)) _gpuBusy = false;
    }
  }

  void _publishLegacy() {
    final m = system.value.data;
    try {
      gpu.value = GpuReading(
        legacy: true,
        data: m == null
            ? null
            : _gpuData({
                'gpus': m['gpus'] ?? const [],
                'error': m['gpu_error'] ?? '',
                'ts': m['gpu_ts'],
                'stale': m['gpu_stale'] ?? false,
              }),
      );
    } catch (error) {
      gpu.value = GpuReading(
        legacy: true,
        data: gpu.value.data,
        history: gpu.value.history,
        error: _message(error, 'GPU'),
      );
    }
  }

  static String _message(Object error, String name) => error is OpError
      ? error.message
      : error is FormatException
      ? '$name 数据格式不正确，等待下一次刷新'
      : '$name 刷新失败：$error';
  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('expected object');
    }
    return Map<String, dynamic>.from(value);
  }

  static List<Map<String, dynamic>> _maps(Object? value) {
    if (value == null) return const [];
    if (value is! List) throw const FormatException('expected array');
    return List.unmodifiable(value.map(_map));
  }

  static double _number(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : 0;
  static double? _optionalNumber(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : null;

  static Object? _freeze(Object? value) => switch (value) {
    Map value => Map<String, dynamic>.unmodifiable({
      for (final e in _map(value).entries) e.key: _freeze(e.value),
    }),
    List value => List<Object?>.unmodifiable(value.map(_freeze)),
    _ => value,
  };
  static Map<String, dynamic> _systemData(Object? value) {
    final m = _map(value);
    for (final key in ['cpu', 'load']) {
      final v = m[key];
      if (v is! List || v.any((n) => n is! num || !n.isFinite)) {
        throw const FormatException('expected finite counters');
      }
      m[key] = List<num>.unmodifiable(v);
    }
    m['memory'] = Map<String, dynamic>.unmodifiable({
      for (final e in _map(m['memory']).entries) e.key: _number(e.value),
    });
    m['uptime'] = _number(m['uptime']);
    m['cpu_count'] = _number(m['cpu_count']);
    m['disks'] = List<Map<String, dynamic>>.unmodifiable([
      for (final d in _maps(m['disks']))
        Map<String, dynamic>.unmodifiable({
          ...d,
          'used': _number(d['used']),
          'total': _number(d['total']),
        }),
    ]);
    m['gpus'] = _freeze(m['gpus']);
    return Map.unmodifiable(m);
  }

  static Map<String, dynamic> _gpuData(Object? value) {
    final m = _map(value);
    final cards = _maps(m['gpus']);
    for (final g in cards) {
      g['processes'] = List<Map<String, dynamic>>.unmodifiable([
        for (final p in _maps(g['processes']))
          Map<String, dynamic>.unmodifiable(p),
      ]);
      final reasons = g['clock_reasons'];
      if (reasons != null && reasons is! List) {
        throw const FormatException('expected clock reasons');
      }
      g['clock_reasons'] = List<String>.unmodifiable([
        for (final reason in reasons as List? ?? const []) '$reason',
      ]);
    }
    m['gpus'] = List<Map<String, dynamic>>.unmodifiable([
      for (final g in cards) Map<String, dynamic>.unmodifiable(g),
    ]);
    m['error'] = m['error'] is String ? m['error'] : '';
    final ts = m['ts'];
    m['ts'] = ts is num && ts.isFinite && ts > 0 && ts < 8640000000000
        ? ts
        : null;
    return Map.unmodifiable(m);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    system.dispose();
    gpu.dispose();
  }
}
