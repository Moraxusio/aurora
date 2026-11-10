// A small CSV/TSV reader for the table preview (RFC 4180: quoted fields,
// doubled quotes, line breaks inside quotes). The preview shows at most
// [maxRows] rows so a 500 MB export cannot freeze the UI; the editor tab only
// ever holds files under the 512 KB online-edit limit anyway, so this is a
// second line of defence.
class CsvTable {
  final List<List<String>> rows;
  final int columns;
  final bool truncated;
  CsvTable(this.rows, this.columns, this.truncated);
}

CsvTable parseCsv(String text, {String? delimiter, int maxRows = 5000}) {
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final d = delimiter ?? _guessDelimiter(text);
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var truncated = false;
  var i = 0;
  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    rows.add(row);
    row = <String>[];
  }

  while (i < text.length) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"' && field.isEmpty) {
      inQuotes = true;
    } else if (c == d) {
      endField();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      endRow();
      if (rows.length >= maxRows) {
        truncated = i + 1 < text.length;
        break;
      }
    } else {
      field.write(c);
    }
    i++;
  }
  // the last line without a trailing break
  if (!truncated && (field.isNotEmpty || row.isNotEmpty)) endRow();
  var cols = 0;
  for (final r in rows) {
    if (r.length > cols) cols = r.length;
  }
  return CsvTable(rows, cols, truncated);
}

/// Tab, semicolon or comma, by which one the first line has most of.
String _guessDelimiter(String text) {
  final nl = text.indexOf('\n');
  final first = nl < 0 ? text : text.substring(0, nl);
  var best = ',';
  var bestN = -1;
  for (final d in const [',', '\t', ';']) {
    final n = d.allMatches(first).length;
    if (n > bestN) {
      best = d;
      bestN = n;
    }
  }
  return best;
}
