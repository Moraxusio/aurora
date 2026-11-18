import 'dart:async';
import 'dart:convert';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';

import '../workspace.dart';
import 'development_model.dart';
import 'protocol_peer.dart';

class TaskProblem {
  final String root, path, message, severity;
  final int line, column;
  const TaskProblem(
    this.root,
    this.path,
    this.line,
    this.column,
    this.message,
    this.severity,
  );
  Map<String, Object> toJson() => {
    'root': root,
    'path': path,
    'line': line,
    'column': column,
    'message': message,
    'severity': severity,
  };
  factory TaskProblem.fromJson(Map m) => TaskProblem(
    m['root'] as String,
    m['path'] as String,
    m['line'] as int,
    m['column'] as int,
    m['message'] as String,
    m['severity'] as String,
  );
}

class TestResult {
  final String id, name;
  String status, output;
  double elapsed;
  TestResult(
    this.id,
    this.name,
    this.status, {
    this.output = '',
    this.elapsed = 0,
  });
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'status': status,
    'output': output,
    'elapsed': elapsed,
  };
  factory TestResult.fromJson(Map m) => TestResult(
    m['id'] as String,
    m['name'] as String,
    m['status'] as String,
    output: m['output'] as String? ?? '',
    elapsed: (m['elapsed'] as num?)?.toDouble() ?? 0,
  );
}

class TaskRun {
  final String id, task, label, root, path, group;
  final DateTime started;
  DateTime? ended;
  String status = 'running', output = '';
  String? error;
  int? exitCode;
  bool outputTruncated = false;
  final List<TaskProblem> problems = [];
  final Map<String, TestResult> tests = {};
  final Completer<int?> _done = Completer<int?>();
  Future<int?> get done => _done.future;
  bool get running => status == 'running' || status == 'cancelling';
  TaskRun(
    this.id,
    this.task,
    this.label,
    this.root,
    this.path,
    this.group,
    this.started,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'task': task,
    'label': label,
    'root': root,
    'path': path,
    'group': group,
    'started': started.toIso8601String(),
    'ended': ended?.toIso8601String(),
    'status': status,
    'output': output,
    'truncated': outputTruncated,
    'error': error,
    'code': exitCode,
    'problems': problems.map((p) => p.toJson()).toList(),
    'tests': tests.values.map((t) => t.toJson()).toList(),
  };
  factory TaskRun.fromJson(Map m) {
    final r = TaskRun(
      m['id'] as String,
      m['task'] as String,
      m['label'] as String,
      m['root'] as String,
      m['path'] as String,
      m['group'] as String,
      DateTime.parse(m['started'] as String),
    );
    r.status = m['status'] as String;
    if (r.running) r.status = 'interrupted';
    r.ended = DateTime.tryParse(m['ended'] as String? ?? '');
    r.output = m['output'] as String? ?? '';
    r.outputTruncated = m['truncated'] == true;
    r.error = m['error'] as String?;
    r.exitCode = m['code'] as int?;
    for (final p in (m['problems'] as List? ?? []).take(500)) {
      r.problems.add(TaskProblem.fromJson(p as Map));
    }
    for (final t in (m['tests'] as List? ?? []).take(500)) {
      final test = TestResult.fromJson(t as Map);
      r.tests[test.id] = test;
    }
    r._done.complete(r.exitCode);
    return r;
  }
}

/// Converts compiler paths from the agent's filesystem to an Aurora document.
String? developmentPath(DevelopmentScope scope, String value, String cwdUri) {
  if (value.startsWith('file:')) return scope.pathFromUri(value);
  final path = value.replaceAll('\\', '/');
  Uri uri;
  if (RegExp(r'^[A-Za-z]:/').hasMatch(path)) {
    uri = Uri(scheme: 'file', path: '/$path');
  } else if (path.startsWith('/')) {
    uri = Uri(scheme: 'file', path: path);
  } else {
    final base = Uri.parse(cwdUri);
    uri = base
        .replace(path: '${base.path.replaceFirst(RegExp(r'/$'), '')}/')
        .resolveUri(Uri(pathSegments: path.split('/')));
  }
  return scope.pathFromUri(uri.toString());
}

/// Output adapters consume complete lines across arbitrary transport chunks.
/// Both retained text and parsed results have independent hard budgets.
class TaskOutputParser {
  final TaskRun run;
  final DevelopmentScope scope;
  final Map<String, String> _pending = {};
  final Map<String, Map> _config = {};
  final Map<String, String> _cwd = {};
  final Set<String> _agentProblems = {};
  final Set<String> _problemKeys = {};
  TaskOutputParser(this.run, this.scope);
  void started(
    String id,
    Map config,
    String cwd, {
    bool agentProblems = false,
  }) {
    _config[id] = config;
    _cwd[id] = cwd;
    if (agentProblems ||
        config['problemPattern'] is String &&
            (config['problemPattern'] as String).isNotEmpty) {
      _agentProblems.add(id);
    }
  }

  void append(String task, String stream, String text) {
    run.output += text;
    if (run.output.length > 128 * 1024) {
      var start = run.output.length - 128 * 1024;
      if (run.output.codeUnitAt(start) >= 0xDC00 &&
          run.output.codeUnitAt(start) <= 0xDFFF)
        start++;
      run.output = run.output.substring(start);
      run.outputTruncated = true;
    }
    final key = '$task:$stream';
    final parts = '${_pending.remove(key) ?? ''}$text'.split('\n');
    for (final line in parts.take(parts.length - 1)) {
      _line(task, line.replaceFirst(RegExp(r'\r$'), ''));
    }
    _pending[key] = parts.last.length > 16 * 1024
        ? parts.last.substring(parts.last.length - 16 * 1024)
        : parts.last;
  }

  void finish() {
    for (final entry in _pending.entries) {
      _line(entry.key.substring(0, entry.key.lastIndexOf(':')), entry.value);
    }
    _pending.clear();
    for (final result in run.tests.values) {
      if (result.status == 'running') result.status = 'interrupted';
    }
  }

  TestResult? _test(String id, String name, String status) {
    if (!run.tests.containsKey(id) && run.tests.length >= 500) return null;
    return run.tests.putIfAbsent(id, () => TestResult(id, name, status));
  }

  void _line(String task, String line) {
    if (line.isEmpty) return;
    final config = _config[task] ?? {};
    if (config['testFormat'] == 'go-json') {
      try {
        final m = jsonDecode(line);
        if (m is Map) {
          final name = m['Test'], package = m['Package'] ?? '';
          if (name is String) {
            final test = _test(
              '$task:$package:$name',
              '$package · $name',
              'running',
            );
            if (test != null) {
              final action = m['Action'];
              if (action == 'pass' || action == 'fail' || action == 'skip')
                test.status = '$action';
              if (m['Elapsed'] is num)
                test.elapsed = (m['Elapsed'] as num).toDouble();
              if (m['Output'] is String) {
                test.output = '${test.output}${m['Output']}';
                if (test.output.length > 2048)
                  test.output = test.output.substring(
                    test.output.length - 2048,
                  );
              }
            }
          }
          if (m['Output'] is String)
            _problem(task, (m['Output'] as String).trimRight());
          return;
        }
      } on FormatException {
        /* Plain build failures may precede JSON output. */
      }
    } else if (config['testFormat'] == 'tap') {
      final match = RegExp(r'^\s*(not ok|ok)\s+(\d+)(?:\s+-?\s*(.*))?$')
          .firstMatch(line);
      if (match != null) {
        final detail = match.group(3) ?? '';
        final skipped = RegExp(
          r'#\s*(SKIP|TODO)\b',
          caseSensitive: false,
        ).hasMatch(detail);
        final result = _test(
          '$task:${match.group(2)}',
          detail.isEmpty ? 'Test ${match.group(2)}' : detail,
          'running',
        );
        if (result != null)
          result.status = skipped
              ? 'skip'
              : match.group(1) == 'ok'
              ? 'pass'
              : 'fail';
      }
    }
    _problem(task, line);
  }

  void _problem(String task, String line) {
    if (run.problems.length >= 500 || _agentProblems.contains(task)) return;
    final match = RegExp(r'^\s*(.+?):(\d+)(?::(\d+))?:\s*(.*)$')
        .firstMatch(line);
    if (match == null) return;
    problem(task, {
      'file': match.group(1),
      'line': int.tryParse(match.group(2) ?? ''),
      'column': int.tryParse(match.group(3) ?? '') ?? 1,
      'message': match.group(4) ?? line,
      'severity': line.toLowerCase().contains('warning') ? 'warning' : 'error',
    });
  }

  void problem(String task, Map value) {
    if (run.problems.length >= 500) return;
    final file = value['file'], number = value['line'];
    if (file is! String || number is! int) return;
    if (number <= 0 || number > 100000000) return;
    final path = developmentPath(scope, file, _cwd[task] ?? scope.workspaceUri);
    if (path == null) return;
    final column = (value['column'] as int? ?? 1).clamp(1, 1000000);
    final raw = '${value['message'] ?? ''}';
    final message = raw.length > 16384 ? raw.substring(0, 16384) : raw;
    final severity = '${value['severity'] ?? 'error'}';
    if (!_problemKeys.add('$path:$number:$column:$message')) return;
    run.problems.add(
      TaskProblem(
        scope.root,
        path,
        number,
        column.clamp(1, 1000000),
        message,
        severity,
      ),
    );
  }
}

class TaskModel extends ChangeNotifier {
  final Workspace ws;
  final List<TaskRun> history = [];
  final Map<String, OpStream> _streams = {};
  final Set<String> _cancelled = {};
  late final Future<void> ready = _load();
  Timer? _notification;
  bool _disposed = false;
  int _sequence = 0;
  Link? _link;
  String? storageError;
  TaskModel(this.ws) {
    _link = ws.link;
    ws.addListener(_connectionChanged);
    unawaited(ready);
  }
  bool get supported => ws.link?.server.caps.contains('task.run') == true;
  Iterable<TaskRun> get active => history.where((r) => r.running);
  void _notify() {
    if (_disposed || _notification != null) return;
    _notification = Timer(const Duration(milliseconds: 50), () {
      _notification = null;
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _load() async {
    try {
      final stored = await ws.app.developmentStore.read(ws.serverId, 'tasks');
      if (_disposed) return;
      if (stored is List) {
        history.addAll(stored.take(12).map((m) => TaskRun.fromJson(m as Map)));
      }
    } on Object catch (e) {
      storageError = '$e';
    }
    _notify();
  }

  Future<void> flush() async {
    try {
      await ws.app.developmentStore.write(
        ws.serverId,
        'tasks',
        history.map((r) => r.toJson()).toList(),
      );
      storageError = null;
    } on Object catch (e) {
      storageError = '$e';
    }
    _notify();
  }

  void _connectionChanged() {
    if (identical(_link, ws.link)) return;
    _link = ws.link;
    for (final run in active.toList()) {
      cancel(run.id, interrupted: true);
    }
  }

  Future<TaskRun> start(DevelopmentScope scope, String task) async {
    await ready;
    final link = ws.link;
    if (_disposed || link == null || !supported)
      throw const ProtocolError('任务服务不可用');
    if (active.length >= 4) throw const ProtocolError('最多同时运行 4 组任务');
    if (active.any(
      (r) => r.root == scope.root && r.path == scope.path && r.task == task,
    )) {
      throw const ProtocolError('该任务正在运行');
    }
    final config = scope
        .entries('tasks')
        .where((t) => t['id'] == task)
        .firstOrNull;
    if (config == null) throw const ProtocolError('任务未配置');
    final now = DateTime.now();
    final run = TaskRun(
      '${now.microsecondsSinceEpoch}-${++_sequence}',
      task,
      config['label'] as String? ?? task,
      scope.root,
      scope.path,
      config['group'] as String? ?? '',
      now,
    );
    history.insert(0, run);
    while (history.length > 12) {
      final i = history.lastIndexWhere((r) => !r.running);
      if (i < 0) break;
      history.removeAt(i);
    }
    unawaited(flush());
    _notify();
    unawaited(_run(run, scope, link));
    return run;
  }

  Future<void> _run(TaskRun run, DevelopmentScope scope, Link link) async {
    OpStream? stream;
    final parser = TaskOutputParser(run, scope);
    bool current() =>
        !_disposed && identical(link, ws.link) && !_cancelled.contains(run.id);
    try {
      stream = await link.open('task.run', {
        ...scope.args,
        'id': run.task,
        'if_match': scope.etag,
      });
      if (!current()) return;
      _streams[run.id] = stream;
      await stream.response().timeout(const Duration(seconds: 15));
      if (!current()) return;
      var complete = false;
      while (current()) {
        final frame = await stream.read();
        if (!current()) break;
        if (frame == null || frame.type == typeEnd) break;
        if (frame.type != typeJson) throw const ProtocolError('任务返回无效帧');
        final event = jsonDecode(utf8.decode(frame.payload)) as Map;
        switch (event['type']) {
          case 'started':
            parser.started(
              '${event['task']}',
              event['configuration'] as Map,
              '${event['cwd']}',
              agentProblems: event['problemMatching'] == 'agent-re2',
            );
          case 'problem':
            if (event['problem'] is Map)
              parser.problem('${event['task']}', event['problem'] as Map);
          case 'output':
            parser.append(
              '${event['task']}',
              '${event['stream']}',
              '${event['text'] ?? ''}',
            );
          case 'error':
            run.error = '${event['message']}';
          case 'finished':
            if (event['cancelled'] == true) run.error = '任务超时或已取消';
          case 'complete':
            run.exitCode = (event['code'] as num).toInt();
            run.status = run.exitCode == 0 && run.error == null
                ? 'passed'
                : 'failed';
            complete = true;
        }
        _notify();
        if (complete) break;
      }
      if (!complete && current()) {
        run.status = 'interrupted';
        run.error ??= '任务连接在完成前关闭';
      }
    } on Object catch (e) {
      if (current()) {
        run.status = 'failed';
        run.error = '$e';
      }
    } finally {
      stream?.reset();
      _streams.remove(run.id);
      parser.finish();
      if (run.running) run.status = 'interrupted';
      run.ended = DateTime.now();
      _cancelled.remove(run.id);
      if (!run._done.isCompleted)
        run._done.complete(run.status == 'passed' ? 0 : run.exitCode ?? -1);
      await flush();
    }
  }

  void cancel(String id, {bool interrupted = false}) {
    final run = history.where((r) => r.id == id).firstOrNull;
    if (run == null || !run.running) return;
    _cancelled.add(id);
    run.status = interrupted ? 'interrupted' : 'cancelled';
    run.ended = DateTime.now();
    _streams.remove(id)?.reset();
    if (!run._done.isCompleted) run._done.complete(-1);
    unawaited(flush());
  }

  @override
  void dispose() {
    _disposed = true;
    ws.removeListener(_connectionChanged);
    _notification?.cancel();
    for (final run in active.toList()) {
      cancel(run.id, interrupted: true);
    }
    super.dispose();
  }
}
