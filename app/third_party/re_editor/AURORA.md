# Aurora patch to re_editor 0.10.0

Upstream: https://github.com/reqable/re-editor (MIT; see LICENSE).

- `_CodeCursorBlinkController`: own and cancel the delayed mobile cursor reveal
  when blinking stops or the editor is disposed. The upstream untracked
  `Future.delayed` can notify a disposed controller after closing/recreating an
  editor. Covered by `test/document_lifecycle_test.dart` with Flutter's mobile
  test platform and immediate editor recreation.

- `CodeLineEditingController.amendCurrentEdit` merges snippet mirror changes into
  the triggering undo step. `restoringHistory` prevents undo/redo from scheduling
  another mirror edit. See `test/snippets_test.dart` and the LSP completion
  integration in `test/development_model_test.dart`.
- `CodeEditor.ghostText` paints inline AI completions without changing editable
  text, selection offsets, IME state or undo history. Keyboard acceptance and
  rejection are covered on Windows and Android by `test/ai_edits_test.dart`.

Keep these changes when updating the dependency.
