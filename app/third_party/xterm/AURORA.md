# xterm 4.0.0, patched for Aurora

Source: pub.dev package `xterm` 4.0.0 (MIT, see `LICENSE`), archive SHA-256
`168dfedca77cba33fdb6f52e2cd001e9fde216e398e89335c19b524bb22da3a2` as recorded in
`app/pubspec.lock` before vendoring. Only `lib/`, `LICENSE`, `README.md`,
`CHANGELOG.md` and `pubspec.yaml` were copied; examples and tests were left out.

## Changes

All in `lib/src/ui/custom_text_edit.dart`, marked "Aurora patch":

1. The `TextInputConfiguration` carries `viewId: View.maybeOf(context)?.viewId`.
2. `setEditableRect` also sends the caret as the composing rect, which is what
   the Windows engine uses to place the IME candidate window.

Flutter's Windows engine (3.47, `shell/platform/windows/text_input_plugin.cc`)
rejects `TextInput.setClient` without a view ID ("Could not set client, view ID
is null"). Without a text input client, Windows delivers typed characters
nowhere: letters, digits and IME input never reach the terminal, while keys the
view maps itself (Enter, arrows, Ctrl+letter) still work. Upstream xterm has no
release after 4.0.0 (2024-02) and its master branch has the same code.

When upstream fixes this, switch `app/pubspec.yaml` back to the hosted package
and delete this folder.
