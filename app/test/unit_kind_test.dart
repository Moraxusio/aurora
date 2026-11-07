// How a systemd unit is classified, from the ActiveState and SubState that
// `systemctl list-units` prints.
import 'package:aurora/features/systemd/unit_kind.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active and running is running; active and exited is not', () {
    expect(unitKind('active', 'running'), UnitKind.running);
    expect(unitKind('active', 'exited'), UnitKind.exited, reason: 'a finished one-shot has nothing to stop');
    expect(unitKind('active', 'waiting'), UnitKind.running, reason: 'any other active state still has a live part');
  });

  test('failed, busy and stopped', () {
    expect(unitKind('failed', 'failed'), UnitKind.failed);
    for (final a in ['activating', 'deactivating', 'reloading']) {
      expect(unitKind(a, 'start'), UnitKind.busy, reason: a);
    }
    expect(unitKind('inactive', 'dead'), UnitKind.stopped);
    expect(unitKind('', ''), UnitKind.stopped);
  });

  test('the notes are words, not systemd jargon', () {
    expect(unitNote(UnitKind.running, 'enabled'), '开机自启');
    expect(unitNote(UnitKind.running, 'static'), '由其它单元启动');
    expect(unitNote(UnitKind.running, 'disabled'), '不自启');
    expect(unitNote(UnitKind.exited, 'enabled'), '已执行完');
    expect(unitNote(UnitKind.failed, ''), '失败');
    expect(unitNote(UnitKind.running, 'something-new'), 'something-new', reason: 'an unknown state is shown as it is');
  });
}
