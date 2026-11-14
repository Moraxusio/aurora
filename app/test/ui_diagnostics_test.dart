import 'package:aurora/kernel/ui_diagnostics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UI fault recording preserves the error handler and excludes error payloads', () {
    final previous = FlutterError.onError;
    var forwarded = 0;
    final written = <String>[];
    final diagnostics = UiDiagnostics();
    FlutterError.onError = (_) => forwarded++;
    diagnostics.install(sink: written.add);
    try {
      for (var i = 0; i < 40; i++) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: StateError('private-document-api-key'),
            stack: StackTrace.fromString('#0 widget.dart:$i'),
            library: 'widgets library',
          ),
        );
      }
      expect(forwarded, 40);
      expect(written.length, 40);
      expect(
        diagnostics.snapshot(),
        isNot(contains('private-document-api-key')),
      );
      expect(diagnostics.snapshot(), contains('GUI-40'));
      expect(diagnostics.snapshot(), isNot(contains('"id": "GUI-1"')));
    } finally {
      diagnostics.uninstall();
      FlutterError.onError = previous;
    }
  });
}
