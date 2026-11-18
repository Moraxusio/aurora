import 'dart:async';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';

import '../workspace.dart';
import '../document_model.dart';
import 'development_model.dart';
import 'protocol_peer.dart';
import 'task_model.dart';

enum DebugPhase {
  idle,
  starting,
  running,
  stopped,
  stopping,
  terminated,
  failed,
}

class DebugBreakpoint {
  final String root, path;
  int line;
  bool enabled;
  final String? condition, hitCondition, logMessage;
  bool verified = false;
  int? adapterId, actualLine;
  String? message;
  DebugBreakpoint(
    this.root,
    this.path,
    this.line, {
    this.enabled = true,
    this.condition,
    this.hitCondition,
    this.logMessage,
  });
  Map<String, Object?> toJson() => {
    'root': root,
    'path': path,
    'line': line,
    'enabled': enabled,
    'condition': condition,
    'hitCondition': hitCondition,
    'logMessage': logMessage,
  };
  factory DebugBreakpoint.fromJson(Map m) => DebugBreakpoint(
    m['root'] as String,
    m['path'] as String,
    m['line'] as int,
    enabled: m['enabled'] != false,
    condition: m['condition'] as String?,
    hitCondition: m['hitCondition'] as String?,
    logMessage: m['logMessage'] as String?,
  );
}

class DebugModel extends ChangeNotifier {
  final Workspace ws;
  final List<DebugBreakpoint> breakpoints = [];
  final List<String> watches = [];
  final Map<String, String> watchValues = {};
  final List<String> output = [];
  late final Future<void> ready = _load();
  ProtocolPeer? _peer;
  DevelopmentScope? scope;
  DebugPhase phase = DebugPhase.idle;
  String? error, reason, storageError, configurationId;
  Map<String, dynamic> capabilities = {};
  List<Map<String, dynamic>> threads = [], frames = [], scopes = [];
  int? threadId, frameId;
  int totalFrames = 0;
  int _generation = 0,
      _pauseGeneration = 0,
      _frameGeneration = 0,
      _stackRequest = 0;
  int get pauseGeneration => _pauseGeneration;
  bool _disposed = false, _notifyQueued = false;
  Object? _control;
  bool get controlling => _control != null;
  Link? _link;
  TaskRun? _prelaunch;
  Completer<void>? _initialized;
  Future<void> _breakpointTail = Future.value();
  bool breakOnExceptions = false;
  final Map<DocumentModel, VoidCallback> _documentListeners = {};
  final Map<DocumentModel, List<String>> _lineSnapshots = {};
  final Map<(String, String), Timer> _breakpointTimers = {};
  Timer? _persistTimer;
  DebugModel(this.ws) {
    _link = ws.link;
    ws.addListener(_connectionChanged);
    ws.documents.addListener(_documentsChanged);
    unawaited(ready);
  }
  bool get supported => ws.link?.server.caps.contains('dap.start') == true;
  bool get active =>
      phase == DebugPhase.starting ||
      phase == DebugPhase.running ||
      phase == DebugPhase.stopped ||
      phase == DebugPhase.stopping;
  bool get stopped => phase == DebugPhase.stopped;
  ProtocolPeer? get peer => _peer;
  void _notify() {
    if (_disposed || _notifyQueued) return;
    _notifyQueued = true;
    scheduleMicrotask(() {
      _notifyQueued = false;
      if (!_disposed) notifyListeners();
    });
  }

  void log(String text) {
    if (_disposed || text.isEmpty) return;
    output.add(text.length > 4096 ? text.substring(text.length - 4096) : text);
    if (output.length > 256) output.removeRange(0, output.length - 256);
    _notify();
  }

  Future<void> _load() async {
    try {
      final value = await ws.app.developmentStore.read(ws.serverId, 'debug');
      if (_disposed) return;
      if (value is Map) {
        for (final item in (value['breakpoints'] as List? ?? []).take(512)) {
          final point = DebugBreakpoint.fromJson(item as Map);
          if (point.line > 0) breakpoints.add(point);
        }
        watches.addAll(
          (value['watches'] as List? ?? []).whereType<String>().take(16),
        );
        breakOnExceptions = value['breakOnExceptions'] == true;
      }
    } on Object catch (e) {
      storageError = '$e';
    }
    if (!_disposed) _documentsChanged();
    _notify();
  }

  void _documentsChanged() {
    final current = ws.documents.all.toSet();
    for (final doc in _documentListeners.keys.toList()) {
      if (!current.contains(doc)) {
        doc.removeListener(_documentListeners.remove(doc)!);
        _lineSnapshots.remove(doc);
      }
    }
    for (final doc in current) {
      if (_documentListeners.containsKey(doc)) continue;
      void changed() => _moveBreakpoints(doc);
      _documentListeners[doc] = changed;
      doc.addListener(changed);
      _moveBreakpoints(doc);
    }
  }

  void _moveBreakpoints(DocumentModel doc) {
    if (_disposed || doc.isClosed || doc.phase != DocumentPhase.ready) return;
    final points = breakpoints
        .where((b) => b.root == doc.key.root && b.path == doc.key.path)
        .toList();
    if (points.isEmpty) {
      _lineSnapshots.remove(doc);
      return;
    }
    final next = doc.lineSnapshot, before = _lineSnapshots[doc];
    _lineSnapshots[doc] = next;
    if (before == null || listEquals(before, next)) return;
    var head = 0, tail = 0;
    while (head < before.length &&
        head < next.length &&
        before[head] == next[head]) {
      head++;
    }
    while (tail < before.length - head &&
        tail < next.length - head &&
        before[before.length - tail - 1] == next[next.length - tail - 1]) {
      tail++;
    }
    final delta = next.length - before.length;
    // Retain unique unchanged anchors inside a multi-edit refactoring as well
    // as the common prefix/suffix of ordinary typing, paste and undo.
    final anchors = <String, int>{};
    for (var i = head; i < next.length - tail; i++) {
      anchors.update(next[i], (_) => -1, ifAbsent: () => i);
    }
    var moved = false;
    for (final point in points) {
      final old = point.line - 1;
      var line = old;
      if (old >= before.length - tail) {
        line += delta;
      } else if (old >= head) {
        final anchor = old < before.length ? anchors[before[old]] : null;
        final last = next.length - tail - 1;
        line = anchor != null && anchor >= 0
            ? anchor
            : last < head
            ? head
            : old.clamp(head, last);
      }
      line = line.clamp(0, next.length - 1);
      if (line + 1 == point.line) continue;
      point.line = line + 1;
      point.actualLine = null;
      point.verified = false;
      moved = true;
    }
    if (!moved) return;
    final file = (doc.key.root, doc.key.path);
    _breakpointTimers.remove(file)?.cancel();
    _breakpointTimers[file] = Timer(const Duration(milliseconds: 200), () {
      _breakpointTimers.remove(file);
      unawaited(
        _syncFile(file.$1, file.$2).catchError((Object e) => log('$e')),
      );
    });
    _persistTimer?.cancel();
    _persistTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(flush()),
    );
    _notify();
  }

  Future<void> flush() async {
    _persistTimer?.cancel();
    try {
      await ws.app.developmentStore.write(ws.serverId, 'debug', {
        'breakpoints': breakpoints.map((b) => b.toJson()).toList(),
        'watches': watches,
        'breakOnExceptions': breakOnExceptions,
      });
      storageError = null;
    } on Object catch (e) {
      storageError = '$e';
    }
    _notify();
  }

  Future<void> toggleBreakpoint(String root, String path, int line) async {
    await ready;
    if (_disposed || line <= 0) return;
    final existing = breakpoints
        .where((b) => b.root == root && b.path == path && b.line == line)
        .firstOrNull;
    if (existing == null) {
      if (breakpoints.length >= 512) throw const ProtocolError('断点超过 512 个预算');
      breakpoints.add(DebugBreakpoint(root, path, line));
    } else {
      breakpoints.remove(existing);
    }
    final doc = ws.documents.find(root, path);
    if (doc != null) {
      if (doc.phase == DocumentPhase.ready)
        _lineSnapshots[doc] = doc.lineSnapshot;
      _documentsChanged();
    }
    _notify();
    await flush();
    await _syncFile(root, path);
  }

  Future<void> updateBreakpoint(
    DebugBreakpoint point, {
    bool? enabled,
    String? condition,
    String? hitCondition,
    String? logMessage,
  }) async {
    if ([
      condition,
      hitCondition,
      logMessage,
    ].any((v) => (v?.length ?? 0) > 4096)) {
      throw const ProtocolError('断点表达式超过 4096 字符');
    }
    final i = breakpoints.indexOf(point);
    if (i < 0) return;
    breakpoints[i] = DebugBreakpoint(
      point.root,
      point.path,
      point.line,
      enabled: enabled ?? point.enabled,
      condition: condition ?? point.condition,
      hitCondition: hitCondition ?? point.hitCondition,
      logMessage: logMessage ?? point.logMessage,
    );
    _notify();
    await flush();
    await _syncFile(point.root, point.path);
  }

  Future<void> addWatch(String expression) async {
    await ready;
    expression = expression.trim();
    if (expression.isEmpty ||
        expression.length > 1024 ||
        watches.contains(expression))
      return;
    if (watches.length >= 16) throw const ProtocolError('监视表达式超过 16 个预算');
    watches.add(expression);
    await flush();
    if (stopped) await _refreshWatches();
  }

  Future<void> removeWatch(String expression) async {
    watches.remove(expression);
    watchValues.remove(expression);
    await flush();
  }

  Future<void> setBreakOnExceptions(bool value) async {
    breakOnExceptions = value;
    await flush();
    if (_peer != null) await _syncExceptions(_peer!);
  }

  void _connectionChanged() {
    if (identical(_link, ws.link)) return;
    _link = ws.link;
    if (active) {
      error = '连接已变化，调试已停止';
      _end(DebugPhase.terminated);
    }
  }

  void _clearPause() {
    _pauseGeneration++;
    _frameGeneration++;
    threadId = null;
    frameId = null;
    threads = [];
    frames = [];
    scopes = [];
    watchValues.clear();
  }

  void _end(DebugPhase next) {
    _generation++;
    _control = null;
    final peer = _peer;
    _peer = null;
    phase = next;
    _clearPause();
    _initialized?.completeIfPending();
    if (_prelaunch?.running == true) ws.tasks.cancel(_prelaunch!.id);
    _prelaunch = null;
    peer?.close();
    for (final point in breakpoints) {
      point.verified = false;
      point.adapterId = null;
    }
    _notify();
  }

  Future<void> start(DevelopmentScope selectedScope, String id) async {
    await ready;
    if (_disposed || active) throw const ProtocolError('已有调试会话正在运行');
    final link = ws.link;
    if (link == null || !supported) throw const ProtocolError('调试服务不可用');
    final config = selectedScope
        .entries('debug')
        .where((c) => c['id'] == id)
        .firstOrNull;
    if (config == null) throw const ProtocolError('调试配置不存在');
    final generation = ++_generation;
    bool current() =>
        !_disposed && generation == _generation && identical(link, ws.link);
    phase = DebugPhase.starting;
    scope = selectedScope;
    configurationId = id;
    error = null;
    reason = null;
    output.clear();
    _clearPause();
    _notify();
    try {
      final task = config['preLaunchTask'];
      if (task is String && task.isNotEmpty) {
        final prelaunch = await ws.tasks.start(selectedScope, task);
        if (!current()) {
          ws.tasks.cancel(prelaunch.id);
          return;
        }
        _prelaunch = prelaunch;
        final code = await prelaunch.done;
        if (!current()) return;
        _prelaunch = null;
        if (code != 0) throw const ProtocolError('调试前置任务失败，已停止启动');
      }
      final peer = await ProtocolPeer.open(
        link,
        'dap.start',
        {...selectedScope.args, 'id': id, 'if_match': selectedScope.etag},
        active: current,
        dap: true,
      );
      if (!current()) {
        peer.close();
        return;
      }
      _peer = peer;
      _initialized = Completer<void>();
      final initialized = _initialized!;
      peer.onNotification = (event, body) {
        if (current()) _event(event, body);
      };
      peer.onTransport = (event) =>
          log('${event['text'] ?? event['message'] ?? event}');
      peer.onClosed = () {
        if (current()) {
          error ??= phase == DebugPhase.stopping ? null : '调试适配器连接已关闭';
          _end(DebugPhase.terminated);
        }
      };
      final response = await peer.request('initialize', {
        'clientID': 'aurora',
        'clientName': 'Aurora',
        'adapterID': id,
        'pathFormat': 'path',
        'linesStartAt1': true,
        'columnsStartAt1': true,
        'supportsVariableType': true,
        'supportsVariablePaging': true,
        'supportsRunInTerminalRequest': false,
        'supportsStartDebuggingRequest': false,
      });
      if (!current()) return;
      capabilities = response is Map ? response.cast<String, dynamic>() : {};
      final args = _expand(
        config['arguments'] ?? {},
        selectedScope,
      ) as Map<String, Object?>;
      // Adapters may wait for configurationDone before replying to launch.
      final launch = peer.request(
        config['request'] as String? ?? 'launch',
        args,
        const Duration(seconds: 60),
      );
      Object? launchError;
      final launchDone = launch.then<void>(
        (_) {},
        onError: (Object e) {
          launchError = e;
          initialized.completeIfPending();
        },
      );
      await initialized.future.timeout(const Duration(seconds: 20));
      if (launchError != null) throw launchError!;
      if (!current()) return;
      final files = <(String, String)>{
        for (final b in breakpoints) (b.root, b.path),
      };
      for (final file in files) {
        await _syncFile(file.$1, file.$2);
        if (!current()) return;
      }
      await _syncExceptions(peer);
      if (capabilities['supportsConfigurationDoneRequest'] == true) {
        await peer.request('configurationDone');
      }
      await launchDone;
      if (launchError != null) throw launchError!;
      if (!current()) return;
      if (phase == DebugPhase.starting) phase = DebugPhase.running;
      _notify();
    } on Object catch (e) {
      if (current()) {
        error = '$e';
        _end(DebugPhase.failed);
      }
    }
  }

  Object? _expand(Object? value, DevelopmentScope scope) {
    if (value is String) {
      final native = Uri.parse(scope.workspaceUri)
          .toFilePath(windows: scope.platform == 'windows');
      return value.replaceAll(r'${workspaceFolder}', native);
    }
    if (value is List) return value.map((v) => _expand(v, scope)).toList();
    if (value is Map)
      return <String, Object?>{
        for (final e in value.entries) '${e.key}': _expand(e.value, scope),
      };
    return value;
  }

  Future<void> _syncExceptions(ProtocolPeer peer) async {
    final filters = (capabilities['exceptionBreakpointFilters'] as List? ?? [])
        .whereType<Map>();
    if (filters.isEmpty) return;
    await peer.request('setExceptionBreakpoints', {
      'filters': [
        for (final filter in filters)
          if (breakOnExceptions || filter['default'] == true) filter['filter'],
      ],
    });
  }

  Future<void> _syncFile(String root, String path) {
    final peer = _peer, currentScope = scope, generation = _generation;
    if (peer == null || currentScope == null || currentScope.root != root)
      return Future.value();
    final work = _breakpointTail.then((_) async {
      if (_disposed || generation != _generation || peer.closed) return;
      final points = breakpoints
          .where((b) => b.root == root && b.path == path && b.enabled)
          .toList();
      final supported = points
          .where(
            (b) =>
                ((b.condition ?? '').isEmpty ||
                    capabilities['supportsConditionalBreakpoints'] == true) &&
                ((b.hitCondition ?? '').isEmpty ||
                    capabilities['supportsHitConditionalBreakpoints'] ==
                        true) &&
                ((b.logMessage ?? '').isEmpty ||
                    capabilities['supportsLogPoints'] == true),
          )
          .toList();
      for (final point in points) {
        point.verified = false;
        point.message = supported.contains(point) ? null : '适配器不支持此条件或日志断点';
      }
      final response = await peer.request('setBreakpoints', {
        'source': {
          'path': Uri.parse(currentScope.documentUri(path))
              .toFilePath(windows: currentScope.platform == 'windows'),
        },
        'breakpoints': [
          for (final point in supported)
            {
              'line': point.line,
              if ((point.condition ?? '').isNotEmpty)
                'condition': point.condition,
              if ((point.hitCondition ?? '').isNotEmpty)
                'hitCondition': point.hitCondition,
              if ((point.logMessage ?? '').isNotEmpty)
                'logMessage': point.logMessage,
            },
        ],
        'sourceModified': ws.documents.find(root, path)?.dirty == true,
      });
      if (_disposed || generation != _generation) return;
      final returned = response is Map
          ? response['breakpoints'] as List? ?? []
          : [];
      for (var i = 0; i < supported.length && i < returned.length; i++) {
        final value = returned[i];
        if (value is Map) _updateBreakpoint(supported[i], value);
      }
      _notify();
    });
    _breakpointTail = work.then<void>(
      (_) {},
      onError: (Object e) {
        log('$e');
      },
    );
    return work;
  }

  void _updateBreakpoint(DebugBreakpoint point, Map value) {
    point.verified = value['verified'] == true;
    point.adapterId = value['id'] as int?;
    point.actualLine = value['line'] as int?;
    point.message = value['message'] as String?;
  }

  void _event(String event, Map<String, dynamic> body) {
    switch (event) {
      case 'initialized':
        _initialized?.completeIfPending();
      case 'stopped':
        _clearPause();
        phase = DebugPhase.stopped;
        reason = '${body['description'] ?? body['reason'] ?? '已暂停'}';
        threadId = body['threadId'] as int?;
        unawaited(refreshStack().catchError((Object e) => log('$e')));
      case 'continued':
        phase = DebugPhase.running;
        _clearPause();
      case 'terminated':
        _end(DebugPhase.terminated);
      case 'exited':
        log('调试目标退出：${body['exitCode']}');
      case 'output':
        log('${body['output'] ?? ''}');
      case 'breakpoint':
        final value = body['breakpoint'];
        if (value is Map && value['id'] is int) {
          for (final point in breakpoints.where(
            (b) => b.adapterId == value['id'],
          )) {
            _updateBreakpoint(point, value);
          }
        }
      case 'capabilities':
        if (body['capabilities'] is Map)
          capabilities.addAll(
            (body['capabilities'] as Map).cast<String, dynamic>(),
          );
      case 'invalidated':
        if (stopped)
          unawaited(refreshStack().catchError((Object e) => log('$e')));
    }
    _notify();
  }

  bool _samePause(int generation, int pause) =>
      !_disposed &&
      generation == _generation &&
      pause == _pauseGeneration &&
      stopped;
  Future<void> refreshStack({int? selectThread, bool more = false}) async {
    final peer = _peer, generation = _generation, pause = _pauseGeneration;
    if (peer == null || !stopped) return;
    final request = ++_stackRequest;
    if (!more) {
      final reply = await peer.request('threads');
      if (!_samePause(generation, pause) || request != _stackRequest) return;
      threads = _maps(reply, 'threads', 128);
      threadId =
          selectThread ?? threadId ?? (threads.firstOrNull?['id'] as int?);
      frames = [];
      scopes = [];
      frameId = null;
      _frameGeneration++;
    }
    final thread = threadId;
    if (thread == null) {
      _notify();
      return;
    }
    final frameGeneration = _frameGeneration;
    final reply = await peer.request('stackTrace', {
      'threadId': thread,
      'startFrame': more ? frames.length : 0,
      'levels': 100,
    });
    if (!_samePause(generation, pause) ||
        request != _stackRequest ||
        thread != threadId ||
        frameGeneration != _frameGeneration)
      return;
    frames = [
      ...frames,
      ..._maps(reply, 'stackFrames', 100),
    ].take(1000).toList();
    totalFrames = reply is Map
        ? reply['totalFrames'] as int? ?? frames.length
        : frames.length;
    _notify();
    if (!more && frames.isNotEmpty)
      await selectFrame(frames.first['id'] as int);
  }

  Future<void> selectFrame(int id) async {
    final peer = _peer, generation = _generation, pause = _pauseGeneration;
    if (peer == null || !stopped || !frames.any((f) => f['id'] == id)) return;
    final selection = ++_frameGeneration;
    frameId = id;
    scopes = [];
    watchValues.clear();
    _notify();
    final response = await peer.request('scopes', {'frameId': id});
    if (!_samePause(generation, pause) || selection != _frameGeneration) return;
    scopes = _maps(response, 'scopes', 64);
    _notify();
    await _refreshWatches();
  }

  Future<List<Map<String, dynamic>>> variables(
    int reference, {
    int start = 0,
  }) async {
    final peer = _peer,
        generation = _generation,
        pause = _pauseGeneration,
        selection = _frameGeneration;
    if (peer == null || !stopped || reference <= 0) return [];
    final response = await peer.request('variables', {
      'variablesReference': reference,
      'start': start,
      'count': 100,
    });
    if (!_samePause(generation, pause) || selection != _frameGeneration)
      return [];
    return _maps(response, 'variables', 100);
  }

  Future<String> evaluate(String expression, {String context = 'repl'}) async {
    final peer = _peer,
        generation = _generation,
        pause = _pauseGeneration,
        selection = _frameGeneration;
    if (peer == null || !stopped) throw const ProtocolError('请先暂停调试目标');
    if (expression.length > 4096) throw const ProtocolError('表达式过长');
    final response = await peer.request('evaluate', {
      'expression': expression,
      'context': context,
      if (frameId != null) 'frameId': frameId,
    });
    if (!_samePause(generation, pause) || selection != _frameGeneration)
      throw const ProtocolError('调试栈已变化');
    return response is Map ? '${response['result'] ?? ''}' : '';
  }

  Future<void> _refreshWatches() async {
    final generation = _generation,
        pause = _pauseGeneration,
        selection = _frameGeneration;
    for (final expression in watches.toList()) {
      String result;
      try {
        result = await evaluate(expression, context: 'watch');
      } on Object catch (e) {
        result = '$e';
      }
      if (!_samePause(generation, pause) || selection != _frameGeneration)
        return;
      if (watches.contains(expression)) watchValues[expression] = result;
      _notify();
    }
  }

  Future<void> control(String command) async {
    final peer = _peer, generation = _generation, pause = _pauseGeneration;
    if (peer == null || controlling) return;
    final operation = _control = Object();
    _notify();
    try {
      if (command == 'pause') {
        if (phase != DebugPhase.running) return;
        final reply = await peer.request('threads');
        if (generation != _generation || phase != DebugPhase.running) return;
        final available = _maps(reply, 'threads', 128);
        final id = available.firstOrNull?['id'];
        if (id != null) await peer.request('pause', {'threadId': id});
        return;
      }
      if (!stopped || threadId == null) return;
      await peer.request(command, {'threadId': threadId});
      if (_samePause(generation, pause)) {
        phase = DebugPhase.running;
        _clearPause();
      }
    } finally {
      if (identical(_control, operation)) _control = null;
      _notify();
    }
  }

  Future<void> stop() async {
    if (!active || phase == DebugPhase.stopping) return;
    phase = DebugPhase.stopping;
    _notify();
    final peer = _peer, generation = _generation;
    if (peer == null) {
      _end(DebugPhase.terminated);
      return;
    }
    try {
      await peer.request('disconnect', {
        'restart': false,
        'terminateDebuggee': true,
      }, const Duration(seconds: 3));
    } on Object {
      /* Stream closure is the final cancellation boundary. */
    }
    if (generation == _generation) _end(DebugPhase.terminated);
  }

  String? pathForFrame(Map frame) {
    final source = frame['source'];
    if (scope == null || source is! Map || source['path'] is! String)
      return null;
    return developmentPath(
      scope!,
      source['path'] as String,
      scope!.workspaceUri,
    );
  }

  Future<String> readSource(Map frame) async {
    final peer = _peer, generation = _generation, source = frame['source'];
    if (peer == null || peer.closed || source is! Map)
      throw const ProtocolError('当前栈帧没有可读取的源文件');
    final response = await peer.request('source', {
      'source': source,
      'sourceReference': source['sourceReference'] as int? ?? 0,
    });
    if (_disposed || generation != _generation)
      throw const ProtocolError('调试会话已变化');
    if (response is! Map || response['content'] is! String)
      throw const ProtocolError('适配器没有返回源文件内容');
    final text = response['content'] as String;
    if (text.length > 512 * 1024)
      throw const ProtocolError('调试源文件超过 512 Ki 字符阅读预算');
    return text;
  }

  static List<Map<String, dynamic>> _maps(
    Object? value,
    String key,
    int limit,
  ) => [
    if (value is Map)
      for (final item in (value[key] as List? ?? []).take(limit))
        if (item is Map) item.cast<String, dynamic>(),
  ];
  @override
  void dispose() {
    _disposed = true;
    ws.removeListener(_connectionChanged);
    ws.documents.removeListener(_documentsChanged);
    for (final entry in _documentListeners.entries) {
      entry.key.removeListener(entry.value);
    }
    _documentListeners.clear();
    _lineSnapshots.clear();
    for (final timer in _breakpointTimers.values) {
      timer.cancel();
    }
    _breakpointTimers.clear();
    _persistTimer?.cancel();
    unawaited(flush());
    _end(DebugPhase.terminated);
    super.dispose();
  }
}

extension on Completer<void> {
  void completeIfPending() {
    if (!isCompleted) complete();
  }
}
