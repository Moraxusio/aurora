import 'package:aurora/features/ai/ai_models.dart';
import 'package:aurora/features/ai/ai_visuals.dart';
import 'package:aurora/features/ai/ai_work.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reconnect tail snapshots preserve earlier output and stable line identities', () {
    final work = AiWorkController('root');
    addTearDown(work.dispose);
    work.event({'type':'tool.running','session_id':'root','tool_call_id':'call','tool_name':'shell'});
    work.event({'type':'tool.progress','session_id':'root','tool_call_id':'call','delta':'first\nsecond\nthird\n'});
    final item = work.items['root:call']!;
    final history = AiSession(id:'root',title:'fixture',root:'home',workdir:'/');
    final active = [{'session_id':'root','tool_call_id':'call','tool_name':'shell','output':'second\nthird\nfourth\n'}];
    work.hydrate(history, active, primary:true,running:true);
    expect(item.output, 'first\nsecond\nthird\nfourth\n');
    expect(item.outputRevision, 0);
    work.hydrate(history, active, primary:true,running:true);
    expect(item.output, 'first\nsecond\nthird\nfourth\n');
  });
  test('authoritative resync reconstructs completed work and reconciles lost completion', () {
    final work = AiWorkController('root');
    addTearDown(work.dispose);
    work.event({
      'type': 'tool.running',
      'session_id': 'root',
      'tool_call_id': 'build',
      'tool_name': 'shell',
      'input': {'command': 'build'},
    });
    work.event({
      'type': 'tool.progress',
      'session_id': 'root',
      'tool_call_id': 'build',
      'delta': 'progress',
    });
    work.event({
      'type': 'tool.running',
      'session_id': 'root',
      'tool_call_id': 'lost',
      'tool_name': 'shell',
    });
    final history = AiSession.fromJson({
      'id': 'root',
      'title': 'fixture',
      'messages': [
        {
          'id': 'call',
          'role': 'assistant',
          'parts': [
            {
              'type': 'tool-call',
              'tool_call_id': 'build',
              'name': 'shell',
              'input': {'command': 'build'},
            },
            {
              'type': 'tool-call',
              'tool_call_id': 'child',
              'name': 'subagent',
              'input': {'description': 'review'},
            },
          ],
        },
        {
          'id': 'result',
          'role': 'tool',
          'parts': [
            {
              'type': 'tool-result',
              'tool_call_id': 'build',
              'output': 'finished',
              'is_error': true,
            },
            {
              'type': 'tool-result',
              'tool_call_id': 'child',
              'output': 'reviewed',
              'metadata': {'child_session_id': 'child-session'},
            },
          ],
        },
      ],
    });
    work.hydrate(history, [], primary: true, running: false);
    expect(work.items['root:build']!.output, 'finished');
    expect(work.items['root:build']!.status, AiWorkStatus.error);
    expect(work.items['root:lost']!.status, AiWorkStatus.interrupted);
    expect(work.items['root:child']!.childId, 'child-session');
    work.openItem(work.items['root:child']!);
    expect(work.selected, 'session:child-session');
    work.hydrate(history, [], primary: true, running: false);
    expect(work.items.length, 3);
    expect(work.selected, 'session:child-session');
  });

  test(
    'same tool IDs in parent and child are isolated and logs remain bounded',
    () {
      final work = AiWorkController('root');
      addTearDown(work.dispose);
      for (final sid in ['root', 'child']) {
        work.event({
          'type': 'tool.running',
          'session_id': sid,
          'tool_call_id': 'same',
          'tool_name': 'shell',
        });
      }
      work.event({
        'type': 'tool.progress',
        'session_id': 'child',
        'tool_call_id': 'same',
        'delta': List.filled(30000, 'long log line\n').join(),
      });
      work.event({
        'type': 'tool.done',
        'session_id': 'child',
        'tool_call_id': 'same',
      });
      final child = work.items['child:same']!;
      expect(child.output.length, lessThanOrEqualTo(256 * 1024));
      expect(child.clipped, isTrue);
      expect(child.firstLine, greaterThan(0));
      expect(child.status, AiWorkStatus.completed);
      expect(work.items['root:same']!.status, AiWorkStatus.running);
      expect(work.items['root:same']!.output, isEmpty);
    },
  );
}
