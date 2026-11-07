# xterm 4.0.0, patched for Aurora

Source: pub.dev package `xterm` 4.0.0 (MIT, see `LICENSE`), archive SHA-256
`168dfedca77cba33fdb6f52e2cd001e9fde216e398e89335c19b524bb22da3a2` as recorded in
`app/pubspec.lock` before vendoring. Only `lib/`, `LICENSE`, `README.md`,
`CHANGELOG.md` and `pubspec.yaml` were copied; examples and tests were left out.

## Changes

Marked "Aurora patch" in the code. Pinned by tests in `app/test/terminal_paint_test.dart`
(each fails without its patch; checked by taking the patch out).

`lib/src/ui/custom_text_edit.dart`:

1. The `TextInputConfiguration` carries `viewId: View.maybeOf(context)?.viewId`.
2. `setEditableRect` also sends the caret as the composing rect, which is what
   the Windows engine uses to place the IME candidate window.

`lib/src/ui/render.dart`, `painter.dart`, `terminal_view.dart`:

3. **Thin lines between rows.** A full-screen program that gives every cell a
   background (opencode, htop, vim) showed a thin light line across the screen
   between some rows. The original put each line's top at a whole *logical*
   pixel (`truncateToDouble`) while the line height is fractional (14 px x 1.2
   = 16.8), and painted each cell background at the nominal height, so two
   neighbouring rows could leave a gap of up to one logical pixel, through
   which the view's own background showed. Now each line's top is snapped to a
   whole *physical* pixel (the view passes `MediaQuery.devicePixelRatio`) and
   the line's background is painted down to the next line's top.
5. **The mouse wheel was reported as the wrong button.** `core/mouse/button.dart`
   gave the wheel the ids 68, 69, 70, 71 (`64 + 4` ..). A mouse report carries
   `64 + (button - 4)`: up 64, down 65, left 66, right 67 (xterm's ctlseqs,
   "Mouse Tracking"). A program that asked for the mouse (vim, htop, opencode)
   received button 68, which is not a wheel to it, so scrolling did nothing.
   Pinned by `app/test/terminal_wheel_test.dart`.
4. **The character under the cursor disappeared.** The block cursor was an
   opaque rectangle over the cell. It now draws the character again on top of
   the block, in the terminal's background colour, as other terminals do.

Flutter's Windows engine (3.47, `shell/platform/windows/text_input_plugin.cc`)
rejects `TextInput.setClient` without a view ID ("Could not set client, view ID
is null"). Without a text input client, Windows delivers typed characters
nowhere: letters, digits and IME input never reach the terminal, while keys the
view maps itself (Enter, arrows, Ctrl+letter) still work. Upstream xterm has no
release after 4.0.0 (2024-02) and its master branch has the same code.

When upstream fixes this, switch `app/pubspec.yaml` back to the hosted package
and delete this folder.
