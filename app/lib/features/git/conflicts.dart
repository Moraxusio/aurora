// Conflict markers in a work-tree file, as git writes them after a failed
// merge, rebase, cherry-pick, revert or stash apply:
//
//   <<<<<<< ours-label
//   our lines
//   ||||||| base-label        (only with merge.conflictStyle diff3 / zdiff3)
//   base lines
//   =======
//   their lines
//   >>>>>>> theirs-label
//
// The file is split into plain text and conflict blocks; each block can be
// resolved on its own, and the text is put together again with every block
// either resolved or left exactly as it was (markers included), so nothing the
// user has not decided on changes.

class Conflict {
  final List<String> ours, base, theirs;
  final String oursLabel, theirsLabel;
  final bool hasBase;

  /// The lines exactly as they are in the file, markers included.
  final List<String> raw;

  /// null: not decided; otherwise the lines that replace the block.
  List<String>? resolution;

  Conflict({required this.ours, required this.base, required this.theirs, required this.oursLabel, required this.theirsLabel, required this.hasBase, required this.raw});

  bool get resolved => resolution != null;
}

/// A piece of the file: plain lines, or a conflict.
class Piece {
  final List<String>? lines;
  final Conflict? conflict;
  Piece.text(List<String> this.lines) : conflict = null;
  Piece.conflict(Conflict this.conflict) : lines = null;
}

class ConflictFile {
  final List<Piece> pieces;

  /// The file ended with a line break (kept as it was when joining).
  final bool trailingNewline;
  final String lineBreak;
  ConflictFile(this.pieces, this.trailingNewline, this.lineBreak);

  List<Conflict> get conflicts => [for (final p in pieces) if (p.conflict != null) p.conflict!];
  int get unresolved => conflicts.where((c) => !c.resolved).length;

  /// The file's text with the decisions applied; undecided blocks unchanged.
  String join() {
    final out = <String>[];
    for (final p in pieces) {
      if (p.lines != null) {
        out.addAll(p.lines!);
      } else {
        out.addAll(p.conflict!.resolution ?? p.conflict!.raw);
      }
    }
    final s = out.join(lineBreak);
    return trailingNewline && out.isNotEmpty ? '$s$lineBreak' : s;
  }
}

bool _start(String l) => l.startsWith('<<<<<<<') && (l.length == 7 || l[7] == ' ');
bool _base(String l) => l.startsWith('|||||||') && (l.length == 7 || l[7] == ' ');
bool _mid(String l) => l == '=======';
bool _end(String l) => l.startsWith('>>>>>>>') && (l.length == 7 || l[7] == ' ');
String _label(String l) => l.length > 8 ? l.substring(8) : '';

/// Splits [text] into pieces. A block that is not closed properly (no
/// "=======" or no ">>>>>>>") is kept as plain text, not guessed at.
ConflictFile parseConflicts(String text) {
  final crlf = text.contains('\r\n');
  final br = crlf ? '\r\n' : '\n';
  final trailing = text.endsWith(br);
  final body = trailing ? text.substring(0, text.length - br.length) : text;
  // "" is no lines; "\n" is one empty line followed by a line break
  final lines = text.isEmpty ? <String>[] : body.split(br);
  final pieces = <Piece>[];
  var plain = <String>[];
  var i = 0;
  while (i < lines.length) {
    if (!_start(lines[i])) {
      plain.add(lines[i]);
      i++;
      continue;
    }
    // find the block's parts; give up (plain text) if it does not close
    final s = i;
    var b = -1, m = -1, e = -1;
    for (var j = s + 1; j < lines.length; j++) {
      final l = lines[j];
      if (_start(l)) break; // a nested or second start before this one closed
      if (b < 0 && m < 0 && _base(l)) {
        b = j;
      } else if (m < 0 && _mid(l)) {
        m = j;
      } else if (m >= 0 && _end(l)) {
        e = j;
        break;
      }
    }
    if (m < 0 || e < 0) {
      plain.add(lines[i]);
      i++;
      continue;
    }
    if (plain.isNotEmpty) {
      pieces.add(Piece.text(plain));
      plain = <String>[];
    }
    final oursEnd = b >= 0 ? b : m;
    pieces.add(Piece.conflict(Conflict(
      ours: lines.sublist(s + 1, oursEnd),
      base: b >= 0 ? lines.sublist(b + 1, m) : const [],
      theirs: lines.sublist(m + 1, e),
      oursLabel: _label(lines[s]),
      theirsLabel: _label(lines[e]),
      hasBase: b >= 0,
      raw: lines.sublist(s, e + 1),
    )));
    i = e + 1;
  }
  if (plain.isNotEmpty) pieces.add(Piece.text(plain));
  return ConflictFile(pieces, trailing, br);
}
