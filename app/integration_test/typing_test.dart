// Typing into a bare terminal view, with no agent and no network: what xterm
// hands to Terminal.onOutput for keys sent through the real Windows input
// path (app/tool/sendkeys.ps1). If a character is lost here, it is lost before
// the connection; if not, the loss is further along.
//   flutter test integration_test/typing_test.dart -d windows
//     --dart-define=AURORA3_UI_SENDKEYS=<path to sendkeys.ps1>
//     --dart-define=AURORA3_TYPING_LINES=60 --dart-define=AURORA3_TYPING_GAP_MS=15
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalView, TerminalViewState;

import 'helpers.dart';

const lines = int.fromEnvironment('AURORA3_TYPING_LINES', defaultValue: 40);
const gap = int.fromEnvironment('AURORA3_TYPING_GAP_MS', defaultValue: 15);

String shown(String s) => s.runes.map((r) => r == 13 ? r'\r' : String.fromCharCode(r)).join();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every typed character reaches Terminal.onOutput', (t) async {
    t.view.physicalSize = const Size(900, 600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });
    final term = Terminal(maxLines: 1000);
    final got = StringBuffer();
    term.onOutput = got.write;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: TerminalView(term, autofocus: true))));
    final state = t.state<TerminalViewState>(find.byType(TerminalView));
    for (var i = 0; i < 50 && !state.hasInputConnection; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(state.hasInputConnection, isTrue, reason: 'the view has a text input connection');

    final bad = <String>[];
    for (var i = 0; i < lines; i++) {
      got.clear();
      final want = 'echo TYPED$i-中文-\$(((6+$i)*7))';
      await typeKeys(t, '$want\n', gapMs: gap);
      for (var k = 0; k < 10; k++) {
        await t.pump(const Duration(milliseconds: 50)); // let the last events through
      }
      final have = got.toString();
      if (have != '$want\r') bad.add('line $i\n  want: ${shown('$want\r')}\n  got:  ${shown(have)}');
    }
    expect(bad, isEmpty, reason: '${bad.length} of $lines lines differ (gap $gap ms):\n${bad.join('\n')}');
  });
}
