import 'package:aurora/features/files/csv_parse.dart';
import 'package:aurora/features/files/file_kind.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('kindOf', () {
    test('images, pdf, video, audio by extension, case-insensitive', () {
      expect(kindOf('/a/b/photo.PNG'), FileKind.image);
      expect(kindOf('x.jpeg'), FileKind.image);
      expect(kindOf('x.webp'), FileKind.image);
      expect(kindOf('/docs/Paper.PDF'), FileKind.pdf);
      expect(kindOf('clip.mp4'), FileKind.video);
      expect(kindOf('clip.MKV'), FileKind.video);
      expect(kindOf('song.flac'), FileKind.audio);
    });
    test('text, unknown and dotfiles open as text', () {
      expect(kindOf('/etc/hosts'), FileKind.text);
      expect(kindOf('main.go'), FileKind.text);
      expect(kindOf('/home/u/.png'), FileKind.text); // a dotfile named png, not an image
      expect(kindOf('logo.svg'), FileKind.text); // SVG is XML text
      expect(kindOf('archive.tar.gz'), FileKind.text);
    });
    test('only the last path segment counts', () {
      expect(kindOf('/data.png/readme'), FileKind.text);
      expect(kindOf('/data.png/readme.md'), FileKind.text);
    });
  });

  group('previewOf', () {
    test('markdown and csv/tsv', () {
      expect(previewOf('README.md'), PreviewKind.markdown);
      expect(previewOf('a.markdown'), PreviewKind.markdown);
      expect(previewOf('t.csv'), PreviewKind.csv);
      expect(previewOf('t.TSV'), PreviewKind.csv);
      expect(previewOf('main.go'), PreviewKind.none);
    });
  });

  group('parseCsv', () {
    test('plain rows and a missing final newline', () {
      final t = parseCsv('a,b,c\n1,2,3\n4,5,6');
      expect(t.rows, [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
        ['4', '5', '6'],
      ]);
      expect(t.columns, 3);
      expect(t.truncated, isFalse);
    });
    test('quoted fields: commas, doubled quotes and line breaks', () {
      final t = parseCsv('name,note\n"Li, Ming","said ""hi"""\n"two\nlines",x\n');
      expect(t.rows[1], ['Li, Ming', 'said "hi"']);
      expect(t.rows[2], ['two\nlines', 'x']);
      expect(t.rows.length, 3);
    });
    test('CRLF, BOM and empty fields', () {
      final t = parseCsv('\uFEFFa,b\r\n,2\r\n3,\r\n');
      expect(t.rows, [
        ['a', 'b'],
        ['', '2'],
        ['3', ''],
      ]);
    });
    test('delimiter is guessed: tab and semicolon', () {
      expect(parseCsv('a\tb\n1\t2').rows[1], ['1', '2']);
      expect(parseCsv('a;b\n1;2').rows[1], ['1', '2']);
      expect(parseCsv('a,b\n1;2', delimiter: ',').rows[1], ['1;2']);
    });
    test('ragged rows widen the table; empty input has no rows', () {
      expect(parseCsv('a,b\n1,2,3').columns, 3);
      expect(parseCsv('').rows, isEmpty);
    });
    test('maxRows stops early and says so', () {
      final text = List.generate(100, (i) => '$i,x').join('\n');
      final t = parseCsv(text, maxRows: 10);
      expect(t.rows.length, 10);
      expect(t.truncated, isTrue);
      final exact = parseCsv('1,x\n2,x', maxRows: 2);
      expect(exact.rows.length, 2);
      expect(exact.truncated, isFalse);
    });
  });
}
