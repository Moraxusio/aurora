import 'dart:convert';
import 'dart:typed_data';

/// Builds a small but valid PDF with [pages] pages. Each page says "Page N"
/// plus [extra] (so a search has something to find), the first page has an
/// outline entry per page. Offsets in the xref table are computed, so real
/// PDFium opens it without repairing.
Uint8List buildTestPdf({int pages = 3, String extra = 'alpha beta', bool outline = true, int padBytes = 0}) {
  final objs = <int, String>{};
  // 1 catalog, 2 pages, 3 font, then per page: page obj + content obj
  final firstPage = 4;
  final kids = [for (var i = 0; i < pages; i++) '${firstPage + i * 2} 0 R'].join(' ');
  final outlineRoot = firstPage + pages * 2;
  objs[1] = '<< /Type /Catalog /Pages 2 0 R${outline ? ' /Outlines $outlineRoot 0 R /PageMode /UseOutlines' : ''} >>';
  objs[2] = '<< /Type /Pages /Kids [$kids] /Count $pages >>';
  objs[3] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>';
  for (var i = 0; i < pages; i++) {
    final p = firstPage + i * 2, c = p + 1;
    final text = 'Page ${i + 1} $extra';
    final stream = 'BT /F1 24 Tf 72 700 Td ($text) Tj ET';
    objs[p] = '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents $c 0 R /Resources << /Font << /F1 3 0 R >> >> >>';
    objs[c] = '<< /Length ${stream.length} >>\nstream\n$stream\nendstream';
  }
  if (outline) {
    final first = outlineRoot + 1, last = outlineRoot + pages;
    objs[outlineRoot] = '<< /Type /Outlines /First $first 0 R /Last $last 0 R /Count $pages >>';
    for (var i = 0; i < pages; i++) {
      final id = outlineRoot + 1 + i;
      objs[id] = '<< /Title (Chapter ${i + 1}) /Parent $outlineRoot 0 R /Dest [${firstPage + i * 2} 0 R /Fit]'
          '${i > 0 ? ' /Prev ${id - 1} 0 R' : ''}${i < pages - 1 ? ' /Next ${id + 1} 0 R' : ''} >>';
    }
  }
  if (padBytes > 0) {
    // an unreferenced stream of spaces: makes the file big while every offset stays valid
    final padId = outline ? outlineRoot + pages + 1 : outlineRoot;
    objs[padId] = '<< /Length $padBytes >>\nstream\n${' ' * padBytes}\nendstream';
  }
  final b = BytesBuilder();
  void put(String s) => b.add(latin1.encode(s));
  put('%PDF-1.4\n');
  final offsets = <int, int>{};
  final ids = objs.keys.toList()..sort();
  for (final id in ids) {
    offsets[id] = b.length;
    put('$id 0 obj\n${objs[id]}\nendobj\n');
  }
  final xref = b.length;
  final size = ids.last + 1;
  put('xref\n0 $size\n0000000000 65535 f \n');
  for (var id = 1; id < size; id++) {
    put('${offsets[id]!.toString().padLeft(10, '0')} 00000 n \n');
  }
  put('trailer\n<< /Size $size /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return b.toBytes();
}
