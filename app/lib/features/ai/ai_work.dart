import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'ai_models.dart';
import 'ai_visuals.dart';

Map<String, dynamic> aiWorkArguments(Object? input) {
  try {
    final value = input is String ? jsonDecode(input) : input;
    return value is Map ? value.cast<String, dynamic>() : const {};
  } on Object {
    return const {};
  }
}

class AiWorkItem extends ChangeNotifier {
  final String sessionId, callId;
  String name = '', title = '', childId = '', sessionTitle = '';
  Map<String, dynamic> arguments = {}, metadata = {};
  AiWorkStatus status = AiWorkStatus.running;
  String output = '';
  int firstLine = 0, outputRevision = 0;
  bool clipped = false;
  AiWorkItem(this.sessionId, this.callId);
  String get key => '$sessionId:$callId';
  String get input => const JsonEncoder.withIndent('  ').convert(arguments);

  void update(Map<String, dynamic> event, {bool snapshot = false}) {
    if (event['tool_name'] is String) name = event['tool_name'] as String;
    if (event['session_title'] is String) {
      sessionTitle = event['session_title'] as String;
    }
    if (event['input'] != null) {
      arguments = {...arguments, ...aiWorkArguments(event['input'])};
    }
    if (event['metadata'] is Map) {
      metadata = {
        ...metadata,
        ...(event['metadata'] as Map).cast<String, dynamic>(),
      };
    }
    childId = metadata['child_session_id'] as String? ?? childId;
    title = switch (name) {
      'shell' =>
        '${arguments['description'] ?? arguments['command'] ?? 'Shell'}',
      'subagent' => '${arguments['description'] ?? '子代理'}',
      _ => '$name ${arguments['path'] ?? arguments['pattern'] ?? ''}'.trim(),
    };
    if (event['output'] is String) {
      final text = event['output'] as String;
      if (snapshot) { _mergeSnapshot(text); } else { replaceOutput(text); }
    }
  }

  void _mergeSnapshot(String text) {
    if (text.isEmpty || output.endsWith(text)) return;
    if (output.isEmpty) { replaceOutput(text); return; }
    // Active snapshots are bounded tails. Merge their overlap with the local
    // log in linear time, preserving line IDs and any earlier text still held.
    final prefix = List<int>.filled(text.length, 0);
    for (var i = 1, match = 0; i < text.length; i++) {
      while (match > 0 && text.codeUnitAt(i) != text.codeUnitAt(match)) { match = prefix[match - 1]; }
      if (text.codeUnitAt(i) == text.codeUnitAt(match)) match++;
      prefix[i] = match;
    }
    var overlap = 0;
    for (var i = (output.length - text.length).clamp(0, output.length); i < output.length; i++) {
      if (overlap == text.length) overlap = prefix[overlap - 1];
      while (overlap > 0 && output.codeUnitAt(i) != text.codeUnitAt(overlap)) { overlap = prefix[overlap - 1]; }
      if (output.codeUnitAt(i) == text.codeUnitAt(overlap)) overlap++;
    }
    if (overlap > 0) { append(text.substring(overlap)); }
    else { replaceOutput(text); }
  }

  void append(String delta) {
    output += delta;
    _boundOutput();
  }

  void replaceOutput(String text) {
    if (text == output) return;
    // An authoritative result can be a server-side excerpt rather than the
    // live log. Do not pretend its line numbers refer to the old content.
    if (!text.startsWith(output)) {
      firstLine = 0;
      outputRevision++;
    }
    output = text;
    _boundOutput();
  }

  void _boundOutput() {
    const max = 256 * 1024;
    var cut = 0;
    if (output.length > max) {
      cut = output.indexOf('\n', output.length - max);
      cut = cut < 0 ? output.length - max : cut + 1;
    }
    var end = output.length;
    for (var line = 0; line < 4096 && end > cut; line++) {
      final at = output.lastIndexOf('\n', end - 1);
      if (at < 0) { end = 0; break; }
      end = at;
      if (line == 4095 && end >= cut) cut = end + 1;
    }
    if (cut == 0) return;
    if (cut < output.length && output.codeUnitAt(cut) >= 0xdc00 && output.codeUnitAt(cut) <= 0xdfff) cut++;
    firstLine += '\n'.allMatches(output.substring(0, cut)).length;
    output = output.substring(cut);
    clipped = true;
  }

  void publish() => notifyListeners();
}

class AiWorkSession {
  final String id;
  String title, parentId;
  bool running = false, waiting = false;
  AiWorkSession(this.id, this.title, {this.parentId = ''});
}

/// One workbench's navigation and bounded output cache. Stream ownership stays
/// in the existing conversation: navigation never changes its connection ID.
class AiWorkController extends ChangeNotifier {
  String? rootId;
  String selected = 'main';
  final sessions = <String, AiWorkSession>{};
  final items = <String, AiWorkItem>{};
  final opened = <String>{'main'};
  final _dirty = <AiWorkItem>{};
  final _revisions = <String, int>{};
  Timer? _timer;
  bool _disposed = false;
  AiWorkController(this.rootId);
  int revisionFor(String id) => _revisions[id] ?? 0;

  int get runningCount =>
      items.values.where((item) => item.status == AiWorkStatus.running).length;

  void select(String target) {
    if (target.startsWith('work:') && !items.containsKey(target.substring(5))) return;
    opened.add(target);
    selected = target;
    notifyListeners();
  }

  void openSession(String id, [String title = '子代理']) {
    if (id.isEmpty) return;
    sessions.putIfAbsent(id, () => AiWorkSession(id, title));
    select(id == rootId ? 'main' : 'session:$id');
  }

  void openItem(AiWorkItem item) {
    if (item.childId.isNotEmpty) {
      openSession(item.childId, item.title);
    } else {
      select('work:${item.key}');
    }
  }

  void session(
    AiSession value, {
    required bool primary,
    required bool running,
    bool waiting = false,
  }) {
    if (primary) rootId = value.id;
    final info = sessions.putIfAbsent(
      value.id,
      () => AiWorkSession(value.id, value.title),
    );
    info.title = value.title;
    info.parentId = value.parentId;
    info.running = running;
    info.waiting = waiting;
  }

  void hydrate(
    AiSession value,
    List<dynamic> activities, {
    required bool primary,
    required bool running,
    bool waiting = false,
  }) {
    session(value, primary: primary, running: running, waiting: waiting);
    final active = <String>{};
    // Results may be in separate tool messages. Pair across the whole history.
    final calls = <String, AiPart>{}, results = <String, AiPart>{};
    for (final message in value.messages) {
      for (final part in message.parts) {
        if (part.type == 'tool-call') calls[part.toolCallId] = part;
        if (part.type == 'tool-result') results[part.toolCallId] = part;
      }
    }
    for (final entry in calls.entries) {
      final call = entry.value, result = results[entry.key];
      if (call.toolName != 'shell' && call.toolName != 'subagent') continue;
      final key = '${value.id}:${entry.key}';
      final item = items.putIfAbsent(
        key,
        () => AiWorkItem(value.id, entry.key),
      );
      item.update({
        'tool_name': call.toolName,
        'input': call.inputJson,
        'session_title': value.title,
        if (result != null) 'output': result.output,
        'metadata': result?.metadata ?? const {},
      });
      item.status = result == null
          ? AiWorkStatus.interrupted
          : result.isError
          ? AiWorkStatus.error
          : AiWorkStatus.completed;
      _discoverChild(item);
      _dirty.add(item);
    }
    for (final row in activities.whereType<Map>()) {
      final event = row.cast<String, dynamic>();
      final item = _record(event, snapshot: true);
      if (item == null) continue;
      active.add(item.key);
      item.status = AiWorkStatus.running;
      _dirty.add(item);
    }
    if (primary) {
      for (final item in items.values) {
        if (item.status == AiWorkStatus.running && !active.contains(item.key)) {
          item.status = AiWorkStatus.interrupted;
          _dirty.add(item);
        }
      }
    }
    _prune();
    _publish();
  }

  AiWorkItem? _record(Map<String, dynamic> event, {bool snapshot = false}) {
    final sid = event['session_id'] as String? ?? '',
        cid = event['tool_call_id'] as String? ?? '';
    if (sid.isEmpty || cid.isEmpty) return null;
    final key = '$sid:$cid';
    final name = event['tool_name'] ?? items[key]?.name;
    if (name != 'shell' && name != 'subagent') return null;
    final item = items.putIfAbsent(key, () => AiWorkItem(sid, cid));
    item.update(event, snapshot: snapshot);
    _discoverChild(item);
    return item;
  }

  void _discoverChild(AiWorkItem item) {
    if (item.childId.isNotEmpty) {
      final info = sessions.putIfAbsent(
        item.childId,
        () => AiWorkSession(item.childId, item.title, parentId: item.sessionId),
      );
      info.running = item.status == AiWorkStatus.running;
    }
  }

  void event(Map<String, dynamic> event) {
    if (_disposed) return;
    final type = event['type'], sid = event['session_id'] as String? ?? '';
    _revisions[sid] = revisionFor(sid) + 1;
    final key = '$sid:${event['tool_call_id']}';
    if (type == 'tool.progress') {
      final item = items[key];
      if (item != null) {
        item.append(event['delta'] as String? ?? '');
        _dirty.add(item);
        _timer ??= Timer(const Duration(milliseconds: 33), _flushOutput);
      }
      return;
    }
    if (type == 'tool.running' || type == 'tool.done') {
      final item = _record(event);
      if (item != null) {
        item.status = type == 'tool.running'
            ? AiWorkStatus.running
            : event['is_error'] == true
            ? AiWorkStatus.error
            : AiWorkStatus.completed;
        _discoverChild(item);
        _dirty.add(item);
      }
    } else if (type == 'session.status' || type == 'session.error') {
      final info = sessions.putIfAbsent(
        sid,
        () => AiWorkSession(sid, event['session_title'] as String? ?? '子代理'),
      );
      info.running = type == 'session.status' && event['status'] == 'running';
      if (!info.running) {
        info.waiting = false;
        for (final item in items.values) {
          if ((item.sessionId == sid || sid == rootId) &&
              item.status == AiWorkStatus.running) {
            item.status = type == 'session.error'
                ? AiWorkStatus.error
                : AiWorkStatus.interrupted;
            _dirty.add(item);
          }
        }
      }
    } else if (type == 'permission.ask') {
      final info = sessions.putIfAbsent(
        sid,
        () => AiWorkSession(sid, event['session_title'] as String? ?? '子代理'),
      );
      info.waiting = true;
    } else if (type == 'session.title') {
      sessions[sid]?.title = event['title'] as String? ?? sessions[sid]!.title;
    } else {
      return;
    }
    if (type == 'tool.done' || type == 'tool.running') {
      sessions[sid]?.waiting = false;
    }
    _prune();
    _publish();
  }

  void _prune() {
    // Keep running and visited work. Older results remain in the transcript.
    final removable = items.values
        .where(
          (i) =>
              i.status != AiWorkStatus.running &&
              !opened.contains('work:${i.key}') &&
              !opened.contains('session:${i.childId}'),
        )
        .toList();
    for (final item in removable.take(
      (items.length - 120).clamp(0, removable.length),
    )) {
      items.remove(item.key);
      _dirty.remove(item);
      item.dispose();
    }
  }

  void _flushOutput() {
    _timer?.cancel();
    _timer = null;
    for (final item in _dirty.toList()) {
      item.publish();
    }
    _dirty.clear();
  }

  void _publish() {
    _flushOutput();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final item in items.values) {
      item.dispose();
    }
    super.dispose();
  }
}
