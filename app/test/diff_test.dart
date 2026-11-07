// The diff code that has no agent behind it: parsing `git diff` output, and
// the line diff used for "what did this commit change in this file".
import 'package:aurora/features/git/diff_view.dart';
import 'package:aurora/features/git/text_diff.dart';
import 'package:flutter_test/flutter_test.dart';

String show(List<DiffLine> l) => l.map((x) => switch (x.kind) {
      DiffLineKind.add => '+${x.text}',
      DiffLineKind.del => '-${x.text}',
      DiffLineKind.hunk => x.text,
      DiffLineKind.meta => '#${x.text}',
      DiffLineKind.context => ' ${x.text}',
    }).join('\n');

void main() {
  group('parseDiff', () {
    const sample = 'diff --git a/a.txt b/a.txt\n'
        'index 1111111..2222222 100644\n'
        '--- a/a.txt\n'
        '+++ b/a.txt\n'
        '@@ -1,4 +1,5 @@ func main\n'
        ' one\n'
        '-two\n'
        '+TWO\n'
        '+two and a half\n'
        ' three\n'
        ' four\n'
        '@@ -20,2 +21,2 @@\n'
        '-x\n'
        '+y\n'
        ' z\n'
        '\\ No newline at end of file\n';

    test('numbers both sides and keeps headers as meta', () {
      final l = parseDiff(sample);
      expect(l.where((x) => x.kind == DiffLineKind.meta).length, 5); // 4 header lines + "no newline"
      expect(l.where((x) => x.kind == DiffLineKind.hunk).length, 2);
      final two = l.firstWhere((x) => x.text == 'two');
      expect((two.kind, two.oldNo, two.newNo), (DiffLineKind.del, 2, null));
      final upper = l.firstWhere((x) => x.text == 'TWO');
      expect((upper.kind, upper.oldNo, upper.newNo), (DiffLineKind.add, null, 2));
      final three = l.firstWhere((x) => x.text == 'three');
      expect((three.kind, three.oldNo, three.newNo), (DiffLineKind.context, 3, 4));
      // the second hunk restarts the numbers from its header
      final y = l.firstWhere((x) => x.text == 'y');
      expect(y.newNo, 21);
      final x = l.firstWhere((e) => e.text == 'x' && e.kind == DiffLineKind.del);
      expect(x.oldNo, 20);
    });

    test('an empty diff has no lines', () => expect(parseDiff(''), isEmpty));

    test('a blank context line (a single space in the patch) stays a line', () {
      final l = parseDiff('@@ -1,3 +1,3 @@\n a\n \n-b\n+c\n');
      expect(show(l), '@@ -1,3 +1,3 @@\n a\n \n-b\n+c');
    });
  });

  group('diffTexts', () {
    test('equal texts give nothing', () => expect(diffTexts('a\nb\n', 'a\nb\n'), isEmpty));

    test('one changed line with context on both sides', () {
      final l = diffTexts('1\n2\n3\n4\n5\n6\n7\n8\n9\n', '1\n2\n3\n4\nFIVE\n6\n7\n8\n9\n');
      expect(show(l), '@@ -2,7 +2,7 @@\n 2\n 3\n 4\n-5\n+FIVE\n 6\n 7\n 8');
      final five = l.firstWhere((x) => x.text == 'FIVE');
      expect((five.oldNo, five.newNo), (null, 5));
    });

    test('an added file is all additions, a deleted file all deletions', () {
      expect(show(diffTexts('', 'x\ny\n')), '@@ -0,0 +1,2 @@\n+x\n+y');
      expect(show(diffTexts('x\ny\n', '')), '@@ -1,2 +0,0 @@\n-x\n-y');
    });

    test('changes far apart become two hunks; close ones merge into one', () {
      final base = [for (var i = 1; i <= 30; i++) 'l$i'];
      final far = [...base]..[1] = 'A'..[27] = 'B';
      expect(diffTexts(base.join('\n'), far.join('\n')).where((x) => x.kind == DiffLineKind.hunk).length, 2);
      final near = [...base]..[1] = 'A'..[5] = 'B';
      expect(diffTexts(base.join('\n'), near.join('\n')).where((x) => x.kind == DiffLineKind.hunk).length, 1);
    });

    test('the diff reproduces the new text when applied to the old', () {
      const a = 'alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\n';
      const b = 'alpha\nBETA\ngamma\ngamma2\ndelta\nzeta\neta\niota\n';
      final l = diffTexts(a, b, context: 100);
      final rebuilt = [for (final x in l) if (x.kind == DiffLineKind.context || x.kind == DiffLineKind.add) x.text].join('\n');
      expect('$rebuilt\n', b);
      final original = [for (final x in l) if (x.kind == DiffLineKind.context || x.kind == DiffLineKind.del) x.text].join('\n');
      expect('$original\n', a);
    });

    test('a very large change falls back to replace instead of hanging', () {
      final a = List.generate(3000, (i) => 'a$i').join('\n');
      final b = List.generate(3000, (i) => 'b$i').join('\n');
      final sw = Stopwatch()..start();
      final l = diffTexts(a, b);
      expect(sw.elapsedMilliseconds, lessThan(3000));
      expect(l.where((x) => x.kind == DiffLineKind.del).length, 3000);
      expect(l.where((x) => x.kind == DiffLineKind.add).length, 3000);
    });

    test('Chinese text and a missing final newline', () {
      expect(show(diffTexts('你好\n世界', '你好\n世界！')), '@@ -1,2 +1,2 @@\n 你好\n-世界\n+世界！');
    });
  });

  group('withoutFileHeader', () {
    test('drops the four file header lines, keeps the ones that carry information', () {
      final l = withoutFileHeader(parseDiff('diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0000000..e69de29\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+x\n'));
      expect(show(l), '#new file mode 100644\n@@ -0,0 +1 @@\n+x');
    });

    test('a binary change keeps its notice', () {
      final l = withoutFileHeader(parseDiff('diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n'));
      expect(show(l), '#Binary files a/i.png and b/i.png differ');
    });
  });
}
