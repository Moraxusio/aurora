// A line diff of two texts, for the one case the agent has no patch for: what a
// commit changed in one file. The client reads the file at <hash>^ and at
// <hash> (git.show) and compares them here. It is a longest-common-subsequence
// diff over lines, with the common head and tail trimmed first, and context
// lines around each change in the usual unified form.
import 'diff_view.dart';

/// Lines of [oldText] and [newText] as a unified diff with [context] lines
/// around each change. Two equal texts give no lines.
List<DiffLine> diffTexts(String oldText, String newText, {int context = 3}) {
  List<String> split(String s) {
    if (s.isEmpty) return [];
    final l = s.split('\n');
    if (l.last.isEmpty) l.removeLast();
    return l;
  }

  final a = split(oldText), b = split(newText);
  // common head and tail
  var head = 0;
  while (head < a.length && head < b.length && a[head] == b[head]) {
    head++;
  }
  var tail = 0;
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
    tail++;
  }
  final ma = a.sublist(head, a.length - tail), mb = b.sublist(head, b.length - tail);
  if (ma.isEmpty && mb.isEmpty) return [];

  // The middle: LCS table, or a plain replace when it would be too large.
  final ops = <(int, String)>[]; // 0 same, 1 add, 2 del
  if (ma.length * mb.length > 4000000) {
    for (final x in ma) {
      ops.add((2, x));
    }
    for (final x in mb) {
      ops.add((1, x));
    }
  } else {
    final n = ma.length, m = mb.length;
    final t = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        t[i][j] = ma[i] == mb[j] ? t[i + 1][j + 1] + 1 : (t[i + 1][j] >= t[i][j + 1] ? t[i + 1][j] : t[i][j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < n && j < m) {
      if (ma[i] == mb[j]) {
        ops.add((0, ma[i]));
        i++;
        j++;
      } else if (t[i + 1][j] >= t[i][j + 1]) {
        ops.add((2, ma[i++]));
      } else {
        ops.add((1, mb[j++]));
      }
    }
    while (i < n) {
      ops.add((2, ma[i++]));
    }
    while (j < m) {
      ops.add((1, mb[j++]));
    }
  }

  // the whole file as numbered ops
  final all = <(int, String, int?, int?)>[]; // kind, text, oldNo, newNo
  var o = 1, nn = 1;
  for (var k = 0; k < head; k++) {
    all.add((0, a[k], o++, nn++));
  }
  for (final op in ops) {
    switch (op.$1) {
      case 0:
        all.add((0, op.$2, o++, nn++));
      case 1:
        all.add((1, op.$2, null, nn++));
      default:
        all.add((2, op.$2, o++, null));
    }
  }
  for (var k = 0; k < tail; k++) {
    all.add((0, a[a.length - tail + k], o++, nn++));
  }

  // hunks: every change with `context` lines each side, merged when they touch
  final out = <DiffLine>[];
  var k = 0;
  while (k < all.length) {
    if (all[k].$1 == 0) {
      k++;
      continue;
    }
    final start = (k - context).clamp(0, all.length);
    var end = k;
    while (end < all.length) {
      if (all[end].$1 != 0) {
        end++;
        continue;
      }
      var run = 0;
      while (end + run < all.length && all[end + run].$1 == 0) {
        run++;
      }
      if (end + run >= all.length || run > context * 2) {
        end = (end + context).clamp(0, all.length);
        break;
      }
      end += run;
    }
    final slice = all.sublist(start, end);
    final oldStart = slice.firstWhere((e) => e.$3 != null, orElse: () => (0, '', 0, 0)).$3 ?? 0;
    final newStart = slice.firstWhere((e) => e.$4 != null, orElse: () => (0, '', 0, 0)).$4 ?? 0;
    final oldLen = slice.where((e) => e.$3 != null).length, newLen = slice.where((e) => e.$4 != null).length;
    out.add(DiffLine(DiffLineKind.hunk, '@@ -$oldStart,$oldLen +$newStart,$newLen @@'));
    for (final e in slice) {
      out.add(DiffLine(switch (e.$1) { 1 => DiffLineKind.add, 2 => DiffLineKind.del, _ => DiffLineKind.context }, e.$2, oldNo: e.$3, newNo: e.$4));
    }
    k = end;
  }
  return out;
}
