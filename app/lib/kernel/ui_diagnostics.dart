import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Bounded, local UI fault records. Never records exception messages, widget
/// dumps, document contents, network arguments or the user's configuration.
/// Existing framework/engine handlers still receive every original exception.
class UiDiagnostics {
  static final shared = UiDiagnostics();
  final List<Map<String, Object>> _faults = [];
  void Function(FlutterErrorDetails)? _previousFlutter;
  bool Function(Object, StackTrace)? _previousPlatform;
  ErrorWidgetBuilder? _previousWidget;
  void Function(String)? _sink;
  bool _installed = false;
  Future<void> _writes = Future.value();
  int _serial = 0;

  void install({void Function(String)? sink}) {
    if (_installed) return;
    _installed = true;
    _sink = sink ?? _writeLocal;
    _previousFlutter = FlutterError.onError;
    _previousPlatform = ui.PlatformDispatcher.instance.onError;
    _previousWidget = ErrorWidget.builder;
    FlutterError.onError = (details) {
      record(
        details.exception,
        details.stack ?? StackTrace.empty,
        details.library ?? 'framework',
      );
      (_previousFlutter ?? FlutterError.presentError)(details);
    };
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, 'platform');
      return _previousPlatform?.call(error, stack) ?? false;
    };
    ErrorWidget.builder = (_) => Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xff402d31),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '此区域显示失败 · GUI-$_serial\n可在命令面板中“复制界面诊断”',
            style: const TextStyle(color: Color(0xfff4dfe2), fontSize: 12),
          ),
        ),
      ),
    );
  }

  void record(Object error, StackTrace stack, String source) {
    final trace = stack.toString().split('\n').take(24).join('\n');
    final kind = error.runtimeType.toString();
    if (_faults.isNotEmpty &&
        _faults.last['type'] == kind &&
        _faults.last['stack'] == trace) {
      _faults.last['count'] = (_faults.last['count'] as int) + 1;
      return;
    }
    final fault = <String, Object>{
      'id': 'GUI-${++_serial}',
      'time': DateTime.now().toUtc().toIso8601String(),
      'type': kind,
      'source': source,
      'stack': trace,
      'count': 1,
    };
    _faults.add(fault);
    if (_faults.length > 32) _faults.removeAt(0);
    _sink?.call(jsonEncode(fault));
  }

  String snapshot() => const JsonEncoder.withIndent('  ').convert({
    'platform': Platform.operatingSystem,
    'faults': _faults,
    'scope': 'UI error types and code stacks only',
  });

  void _writeLocal(String line) {
    _writes = _writes.then((_) async {
      try {
        final root = Platform.environment['LOCALAPPDATA'];
        if (root == null || root.isEmpty) return;
        final directory = Directory('$root/Aurora3/diagnostics');
        await directory.create(recursive: true);
        final file = File('${directory.path}/gui.jsonl');
        final full = await file.exists() && await file.length() > 256 * 1024;
        await file.writeAsString(
          '$line\n',
          mode: full ? FileMode.write : FileMode.append,
          flush: true,
        );
      } on Object {
        /* A diagnostic must not introduce another UI failure. */
      }
    });
  }

  void uninstall() {
    if (!_installed) return;
    FlutterError.onError = _previousFlutter;
    ui.PlatformDispatcher.instance.onError = _previousPlatform;
    ErrorWidget.builder = _previousWidget!;
    _installed = false;
  }
}
