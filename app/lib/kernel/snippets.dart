import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:re_editor/re_editor.dart';

class SnippetRange {
  final int group;
  int start, end;
  final List<String> choices;
  final List<int> ancestors;
  SnippetRange(
    this.group,
    this.start,
    this.end, [
    this.choices = const [],
    this.ancestors = const [],
  ]);
}

class SnippetExpansion {
  final String text;
  final List<SnippetRange> ranges;
  SnippetExpansion(this.text, this.ranges);
}

class _SnippetNode {
  final Object? key;
  final String literal;
  final List<_SnippetNode>? fallback;
  final List<String> choices;
  _SnippetNode.text(this.literal)
    : key = null,
      fallback = null,
      choices = const [];
  _SnippetNode.field(this.key, {this.fallback, this.choices = const []})
    : literal = '';
}

/// Bounded TextMate/LSP placeholders, tab stops, choices and variables. Regex
/// transformations are rejected before editing instead of inserted as syntax.
SnippetExpansion expandSnippet(String source, Map<String, String> variables) {
  if (source.length > 64 * 1024) throw StateError('补全片段超过 64 Ki 字符');
  final parser = _SnippetParser(source);
  final nodes = parser.parse();
  final definitions = <int, _SnippetNode>{};
  var largestGroup = 0;
  void discover(List<_SnippetNode> nodes) {
    for (final node in nodes) {
      if (node.key is int && (node.key as int) > largestGroup)
        largestGroup = node.key as int;
      if (node.key is int &&
          (node.fallback != null || node.choices.isNotEmpty)) {
        definitions.putIfAbsent(node.key as int, () => node);
      }
      if (node.fallback != null) discover(node.fallback!);
    }
  }

  discover(nodes);
  final result = StringBuffer(),
      ranges = <SnippetRange>[],
      values = <int, String>{};
  final resolving = <int>{};
  final ancestors = <int>[];
  var unknown = largestGroup + 1;
  void append(String text) {
    if (result.length + text.length > 256 * 1024)
      throw StateError('片段展开超过 256 Ki 字符');
    result.write(text);
  }

  void render(List<_SnippetNode> nodes, int depth) {
    if (depth > 16) throw StateError('片段嵌套过深');
    for (final node in nodes) {
      if (node.key == null) {
        append(node.literal);
        continue;
      }
      if (node.key is String) {
        final name = node.key as String, value = variables[node.key];
        if (value != null && value.isNotEmpty) {
          append(value);
        } else if (node.fallback != null) {
          render(node.fallback!, depth + 1);
        } else if (value == null) {
          final start = result.length;
          append(name);
          ranges.add(
            SnippetRange(
              unknown++,
              start,
              result.length,
              const [],
              List.of(ancestors),
            ),
          );
        }
        continue;
      }
      final group = node.key as int, start = result.length;
      final definition = definitions[group] ?? node;
      if (values.containsKey(group)) {
        append(values[group]!);
      } else {
        if (!resolving.add(group)) throw StateError('片段占位符循环引用');
        if (definition.choices.isNotEmpty) {
          append(definition.choices.first);
        } else if (definition.fallback != null) {
          ancestors.add(group);
          render(definition.fallback!, depth + 1);
          ancestors.removeLast();
        }
        resolving.remove(group);
        values[group] = result.toString().substring(start);
      }
      ranges.add(
        SnippetRange(
          group,
          start,
          result.length,
          definition.choices,
          List.of(ancestors),
        ),
      );
      if (ranges.length > 256) throw StateError('片段占位符超过 256 个');
    }
  }

  render(nodes, 0);
  if (!ranges.any((r) => r.group == 0))
    ranges.add(SnippetRange(0, result.length, result.length));
  return SnippetExpansion(result.toString(), ranges);
}

class _SnippetParser {
  final String source;
  int at = 0, count = 0;
  _SnippetParser(this.source);
  List<_SnippetNode> parse({bool nested = false, int depth = 0}) {
    if (depth > 16) throw StateError('片段嵌套过深');
    final nodes = <_SnippetNode>[], text = StringBuffer();
    void flush() {
      if (text.isNotEmpty) {
        nodes.add(_SnippetNode.text(text.toString()));
        text.clear();
      }
    }

    while (at < source.length) {
      final c = source[at++];
      if (c == '}' && nested) {
        flush();
        return nodes;
      }
      if (c == r'\') {
        if (at < source.length && r'\$}'.contains(source[at])) {
          text.write(source[at++]);
        } else {
          text.write(c);
        }
        continue;
      }
      if (c != r'$') {
        text.write(c);
        continue;
      }
      final braced = at < source.length && source[at] == '{';
      if (braced) at++;
      final start = at;
      bool word(int c) =>
          c == 95 ||
          c >= 48 && c <= 57 ||
          c >= 65 && c <= 90 ||
          c >= 97 && c <= 122;
      final numeric =
          at < source.length &&
          source.codeUnitAt(at) >= 48 &&
          source.codeUnitAt(at) <= 57;
      while (at < source.length &&
          (numeric
              ? source.codeUnitAt(at) >= 48 && source.codeUnitAt(at) <= 57
              : word(source.codeUnitAt(at)))) {
        at++;
      }
      if (start == at) {
        if (braced) throw StateError('片段占位符格式无效');
        text.write(r'$');
        continue;
      }
      final name = source.substring(start, at);
      final Object key = int.tryParse(name) ?? name;
      if (++count > 256) throw StateError('片段占位符超过 256 个');
      flush();
      if (!braced) {
        nodes.add(_SnippetNode.field(key));
        continue;
      }
      if (at == source.length) throw StateError('片段缺少结束括号');
      switch (source[at++]) {
        case '}':
          nodes.add(_SnippetNode.field(key));
        case ':':
          nodes.add(
            _SnippetNode.field(
              key,
              fallback: parse(nested: true, depth: depth + 1),
            ),
          );
        case '|':
          if (key is! int) throw StateError('片段选择项需要编号');
          final choices = <String>[], choice = StringBuffer();
          var closed = false;
          while (at < source.length) {
            final c = source[at++];
            if (c == r'\' &&
                at < source.length &&
                r'\,|'.contains(source[at])) {
              choice.write(source[at++]);
            } else if (c == ',') {
              choices.add(choice.toString());
              choice.clear();
            } else if (c == '|' && at < source.length && source[at] == '}') {
              at++;
              choices.add(choice.toString());
              closed = true;
              break;
            } else {
              choice.write(c);
            }
          }
          if (!closed) throw StateError('片段选择项未结束');
          nodes.add(_SnippetNode.field(key, choices: choices));
        case '/':
          throw StateError('此片段包含暂未支持的正则转换');
        default:
          throw StateError('片段占位符格式无效');
      }
    }
    if (nested) throw StateError('片段缺少结束括号');
    flush();
    return nodes;
  }
}

int _offset(String text, int line, int column) {
  var start = 0, index = 0;
  for (final match in RegExp(r'\r\n|\r|\n').allMatches(text)) {
    if (index >= line) break;
    start = match.end;
    index++;
  }
  if (index < line) return text.length;
  return (start + column).clamp(0, text.length);
}

/// A snippet is tied to one document controller and its text version, not to a
/// tab widget. Cursor-only notifications never materialize the document text.
class SnippetSession extends ChangeNotifier {
  final CodeLineEditingController controller;
  final int Function() version;
  final VoidCallback onClosed;
  final List<SnippetRange> ranges;
  String _text;
  int _version, _group;
  bool _closed = false, _updating = false, _queued = false;
  SnippetSession(
    this.controller,
    SnippetExpansion expansion,
    int start, {
    required this.version,
    required this.onClosed,
  }) : ranges = [
         for (final r in expansion.ranges)
           SnippetRange(
             r.group,
             r.start + start,
             r.end + start,
             r.choices,
             r.ancestors,
           ),
       ],
       _text = controller.text,
       _version = version(),
       _group = -1 {
    controller.addListener(_changed);
  }
  bool get active => !_closed;
  SnippetRange? get current =>
      ranges.where((r) => r.group == _group).firstOrNull;
  List<int> get _groups => ranges.map((r) => r.group).toSet().toList()
    ..sort(
      (a, b) => a == b
          ? 0
          : a == 0
          ? 1
          : b == 0
          ? -1
          : a.compareTo(b),
    );

  CodeLineSelection _selection(int start, int end) {
    (int, int) position(int offset) {
      final prefix = _text.substring(0, offset),
          lines = prefix.split(RegExp(r'\r\n|\r|\n'));
      return (lines.length - 1, lines.last.length);
    }

    int visible(int line) {
      var mapped = controller.lineIndex2Index(line);
      for (var i = 0; mapped.chunkIndex >= 0 && i < 256; i++) {
        controller.expandChunk(mapped.index);
        mapped = controller.lineIndex2Index(line);
      }
      return mapped.index;
    }

    final a = position(start), b = position(end);
    visible(a.$1);
    visible(b.$1);
    return CodeLineSelection(
      baseIndex: visible(a.$1),
      baseOffset: a.$2,
      extentIndex: visible(b.$1),
      extentOffset: b.$2,
    );
  }

  void selectFirst() => advance();
  void advance({bool backward = false}) {
    if (_closed ||
        controller.composing.isValid && !controller.composing.isCollapsed)
      return;
    _mirror();
    if (_closed) return;
    final groups = _groups, index = groups.indexOf(_group);
    final next = backward ? index - 1 : index + 1;
    if (next < 0) return;
    if (next >= groups.length) {
      close();
      return;
    }
    _group = groups[next];
    final range = current!;
    _updating = true;
    controller.selection = _selection(range.start, range.end);
    _updating = false;
    if (_group == 0) {
      close();
    } else {
      notifyListeners();
    }
  }

  void choose(String value) {
    final range = current;
    if (_closed || range == null || !range.choices.contains(value)) return;
    controller.replaceSelection(value, _selection(range.start, range.end));
  }

  void _shift(SnippetRange changed, int from, int to, int length) {
    final delta = length - (to - from);
    ranges.removeWhere(
      (r) =>
          !identical(r, changed) &&
          r.start >= from &&
          r.end <= to &&
          r.ancestors.contains(changed.group),
    );
    for (final r in ranges) {
      if (identical(r, changed)) {
        r.end += delta;
      } else if (changed.ancestors.contains(r.group) &&
          r.start <= from &&
          r.end >= to) {
        r.end += delta;
      } else if (r.start >= to) {
        r.start += delta;
        r.end += delta;
      } else if (r.start <= from && r.end >= to) {
        r.end += delta;
      }
    }
  }

  void _changed() {
    if (_closed || _updating) return;
    if (controller.restoringHistory) {
      close();
      return;
    }
    final range = current;
    if (range == null) return;
    final selection = controller.unfoldLineSelection;
    if (_version == version()) {
      if (_offset(_text, selection.startIndex, selection.startOffset) <
              range.start ||
          _offset(_text, selection.endIndex, selection.endOffset) > range.end)
        close();
      else if (controller.composing.isCollapsed ||
          !controller.composing.isValid)
        _queueMirror();
      return;
    }
    final next = controller.text;
    var head = 0, tail = 0;
    while (head < range.end &&
        head < _text.length &&
        head < next.length &&
        _text.codeUnitAt(head) == next.codeUnitAt(head)) {
      head++;
    }
    while (tail < _text.length - head &&
        tail < next.length - head &&
        _text.codeUnitAt(_text.length - tail - 1) ==
            next.codeUnitAt(next.length - tail - 1)) {
      tail++;
    }
    final end = _text.length - tail;
    if (head < range.start || end > range.end) {
      close();
      return;
    }
    _shift(range, head, end, next.length - head - tail);
    _text = next;
    _version = version();
    if (!controller.composing.isValid || controller.composing.isCollapsed)
      _queueMirror();
  }

  void _queueMirror() {
    if (_queued || _closed) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (!_closed) _mirror();
    });
  }

  void _mirror() {
    final primary = current;
    if (_closed ||
        primary == null ||
        controller.composing.isValid && !controller.composing.isCollapsed)
      return;
    final selection = controller.unfoldLineSelection;
    var caret = _offset(_text, selection.extentIndex, selection.extentOffset);
    var anchor = _offset(_text, selection.baseIndex, selection.baseOffset);
    var changed = false;
    _updating = true;
    try {
      controller.amendCurrentEdit(() {
        for (final group in [_group, ...primary.ancestors.reversed]) {
          final origin = ranges.firstWhere((r) => r.group == group);
          final value = _text.substring(origin.start, origin.end);
          final mirrors =
              ranges
                  .where((r) => r.group == group && !identical(r, origin))
                  .toList()
                ..sort((a, b) => b.start.compareTo(a.start));
          for (final mirror in mirrors) {
            if (_text.substring(mirror.start, mirror.end) == value) continue;
            final from = mirror.start, to = mirror.end;
            controller.replaceSelection(value, _selection(from, to));
            final delta = value.length - (to - from);
            if (to < caret || to == caret && from < primary.start)
              caret += delta;
            if (to < anchor || to == anchor && from < primary.start)
              anchor += delta;
            _shift(mirror, from, to, value.length);
            _text = controller.text;
            _version = version();
            changed = true;
          }
        }
        if (changed) controller.selection = _selection(anchor, caret);
      });
    } finally {
      _updating = false;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    controller.removeListener(_changed);
    onClosed();
  }
}
