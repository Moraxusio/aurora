import 'package:aurora/features/git/conflicts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const two = 'a\n<<<<<<< HEAD\nours 1\nours 2\n=======\ntheirs\n>>>>>>> feature\nb\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> feature\n';

  test('unchanged text comes back byte for byte', () {
    for (final t in [two, '', '\n', 'no conflict', 'no conflict\n', two.replaceAll('\n', '\r\n'), 'a\n<<<<<<< HEAD\nunclosed\n', '=======\n>>>>>>> x\n']) {
      expect(parseConflicts(t).join(), t, reason: t);
    }
  });

  test('two conflicts, their sides and labels', () {
    final f = parseConflicts(two);
    final c = f.conflicts;
    expect(c.length, 2);
    expect(c[0].ours, ['ours 1', 'ours 2']);
    expect(c[0].theirs, ['theirs']);
    expect(c[0].oursLabel, 'HEAD');
    expect(c[0].theirsLabel, 'feature');
    expect(c[0].hasBase, isFalse);
    expect(f.unresolved, 2);
  });

  test('diff3 style: the base is separate from ours', () {
    final f = parseConflicts('<<<<<<< ours\nmine\n||||||| base\norig\n=======\nyours\n>>>>>>> theirs\n');
    final c = f.conflicts.single;
    expect(c.ours, ['mine']);
    expect(c.base, ['orig']);
    expect(c.theirs, ['yours']);
    expect(c.hasBase, isTrue);
  });

  test('resolving one block changes only that block', () {
    final f = parseConflicts(two);
    f.conflicts[0].resolution = [...f.conflicts[0].ours, ...f.conflicts[0].theirs];
    expect(f.unresolved, 1);
    expect(f.join(), 'a\nours 1\nours 2\ntheirs\nb\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> feature\n');
    f.conflicts[1].resolution = f.conflicts[1].theirs;
    expect(f.unresolved, 0);
    expect(f.join(), 'a\nours 1\nours 2\ntheirs\nb\ny\n');
  });

  test('an empty resolution removes the block', () {
    final f = parseConflicts('a\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> t\nb\n');
    f.conflicts.single.resolution = [];
    expect(f.join(), 'a\nb\n');
  });

  test('CRLF files stay CRLF', () {
    final f = parseConflicts('a\r\n<<<<<<< HEAD\r\nx\r\n=======\r\ny\r\n>>>>>>> t\r\n');
    f.conflicts.single.resolution = f.conflicts.single.theirs;
    expect(f.join(), 'a\r\ny\r\n');
  });

  test('marker-like text that is not a full block stays text', () {
    // no end marker, a second start before the first closed, a longer marker
    for (final t in ['<<<<<<< a\nx\n=======\ny\n', '<<<<<<< a\n<<<<<<< b\nx\n=======\ny\n>>>>>>> b\n', '<<<<<<<< a\nx\n=======\ny\n>>>>>>> b\n']) {
      final f = parseConflicts(t);
      expect(f.join(), t);
    }
    expect(parseConflicts('<<<<<<< a\n<<<<<<< b\nx\n=======\ny\n>>>>>>> b\n').conflicts.length, 1);
    expect(parseConflicts('<<<<<<<< a\nx\n=======\ny\n>>>>>>> b\n').conflicts, isEmpty);
  });

  test('a file without a final newline keeps it that way', () {
    final f = parseConflicts('<<<<<<< a\nx\n=======\ny\n>>>>>>> b');
    f.conflicts.single.resolution = ['y'];
    expect(f.join(), 'y');
  });
}
