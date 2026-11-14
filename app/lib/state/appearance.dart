import 'dart:async';

import 'package:flutter/foundation.dart';

/// A small, credential-free snapshot. No profile copies or disk IO on a drag.
class AppearanceValues {
  final String theme;
  final double editorFont, terminalFont, chatFont, uiScale;
  final bool wordWrap;
  final int tabSize;
  const AppearanceValues({this.theme = 'system', this.editorFont = 13.5,
    this.terminalFont = 14, this.chatFont = 15, this.uiScale = 1,
    this.wordWrap = false, this.tabSize = 4});

  AppearanceValues patch(Map<String, Object> p) => AppearanceValues(
    theme: p['theme'] as String? ?? theme,
    editorFont: (p['editorFont'] as num?)?.toDouble() ?? editorFont,
    terminalFont: (p['terminalFont'] as num?)?.toDouble() ?? terminalFont,
    chatFont: (p['chatFont'] as num?)?.toDouble() ?? chatFont,
    uiScale: (p['uiScale'] as num?)?.toDouble() ?? uiScale,
    wordWrap: p['wordWrap'] as bool? ?? wordWrap,
    tabSize: p['tabSize'] as int? ?? tabSize,
  );
  Object get signature => (theme, editorFont, terminalFont, chatFont, uiScale, wordWrap, tabSize);
}

/// UI updates are synchronous. Persistence is debounced, serialized, and only
/// merges the fields the user changed into the latest sealed profile.
class AppearanceController extends ChangeNotifier {
  final AppearanceValues Function() read;
  final Future<void> Function(Map<String, Object>) save;
  late AppearanceValues value = read();
  final _pending = <String, Object>{};
  Timer? _timer;
  Future<bool>? _saving;
  bool _disposed = false;
  String? error;
  bool get unsaved => _pending.isNotEmpty || _saving != null;

  AppearanceController({required this.read, required this.save});

  void set(String field, Object v) {
    if (v is double && !v.isFinite) return;
    if (const ['editorFont', 'terminalFont', 'chatFont'].contains(field)) {
      v = (v as num).toDouble().clamp(9, 28);
    } else if (field == 'uiScale') {
      v = (v as num).toDouble().clamp(.8, 1.5);
    }
    final next = value.patch({field: v});
    if (next.signature == value.signature) return;
    value = next;
    _pending[field] = v;
    error = null;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 240), flush);
    notifyListeners();
  }

  void reload() {
    final next = read().patch(_pending);
    // A write already in flight must not roll the preview back.
    if (_saving != null) return;
    if (next.signature != value.signature) {
      value = next;
      notifyListeners();
    }
  }

  Future<bool> flush() {
    _timer?.cancel();
    _timer = null;
    if (_saving != null) return _saving!;
    if (_pending.isEmpty) return Future.value(true);
    final future = _drain();
    _saving = future;
    return future;
  }

  Future<bool> _drain() async {
    // Yield so _saving is installed even when a fake store throws immediately.
    await Future<void>.value();
    var ok = true;
    while (_pending.isNotEmpty && !_disposed) {
      final patch = Map<String, Object>.of(_pending);
      _pending.clear();
      try {
        await save(patch);
      } on Object {
        // Newer pointer values win over the failed, older write.
        final newer = Map<String, Object>.of(_pending);
        _pending..addAll(patch)..addAll(newer);
        error = '保存失败，当前预览仍有效。请重试。';
        ok = false;
        break;
      }
    }
    _saving = null;
    if (ok) error = null;
    if (!_disposed) notifyListeners();
    return ok;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
