import 'package:flutter/material.dart' as m;
import 'package:flutter/material.dart'
    hide TextField, FilledButton, OutlinedButton, TextButton, AlertDialog;
import 'package:flutter/services.dart';

import '../kernel/input_mode.dart';
import '../theme/workbench_tokens.dart';

enum _ButtonKind { primary, secondary, quiet, tonal }

/// Material supplies editing/IME and accessibility behaviour. Aurora owns the
/// public entry point and density; keys belong to the actual interactive node.
class TextField extends StatelessWidget {
  final Key? controlKey;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextStyle? style;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextAlign textAlign;
  final TextAlignVertical? textAlignVertical;
  final bool autofocus,
      obscureText,
      autocorrect,
      enableSuggestions,
      expands,
      readOnly;
  final bool? enabled;
  final int? maxLines, minLines, maxLength;
  final ValueChanged<String>? onChanged, onSubmitted;
  final VoidCallback? onEditingComplete;
  final TapRegionCallback? onTapOutside;
  final List<TextInputFormatter>? inputFormatters;
  final ContentInsertionConfiguration? contentInsertionConfiguration;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  // The key identifies the native editable node, including in integration tests.
  // ignore: use_key_in_widget_constructors
  const TextField({
    Key? key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.style,
    this.keyboardType,
    this.textInputAction,
    this.textAlign = TextAlign.start,
    this.textAlignVertical,
    this.autofocus = false,
    this.obscureText = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.expands = false,
    this.readOnly = false,
    this.enabled,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.onTapOutside,
    this.inputFormatters,
    this.contentInsertionConfiguration,
    this.contextMenuBuilder = _contextMenu,
  }) : controlKey = key;

  static Widget _contextMenu(BuildContext context, EditableTextState state) =>
      AdaptiveTextSelectionToolbar.editableText(editableTextState: state);

  @override
  Widget build(BuildContext context) {
    final touch = InputMode.isTouch(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: touch ? UiMetrics.touchRow : 0),
      child: m.TextField(
        key: controlKey,
        controller: controller,
        focusNode: focusNode,
        decoration: decoration,
        style: style,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textAlign: textAlign,
        textAlignVertical: textAlignVertical,
        autofocus: autofocus,
        obscureText: obscureText,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        expands: expands,
        readOnly: readOnly,
        enabled: enabled,
        maxLines: maxLines,
        minLines: minLines,
        maxLength: maxLength,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        onEditingComplete: onEditingComplete,
        onTapOutside: onTapOutside,
        inputFormatters: inputFormatters,
        contentInsertionConfiguration: contentInsertionConfiguration,
        contextMenuBuilder: contextMenuBuilder,
      ),
    );
  }
}

abstract class _Button extends StatelessWidget {
  final Key? controlKey;
  final VoidCallback? onPressed, onLongPress;
  final Widget child;
  final Widget? icon;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus, busy;
  final _ButtonKind kind;
  const _Button({
    Key? key,
    required this.onPressed,
    required this.child,
    required this.kind,
    this.onLongPress,
    this.icon,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.busy = false,
  }) : controlKey = key;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final touch = InputMode.isTouch(context);
    final height = touch ? UiMetrics.touchRow : UiMetrics.controlHeight;
    final baseline = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(48, height)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return BorderSide(
            color: kind == _ButtonKind.primary
                ? colors.onPrimary
                : colors.primary,
            width: 2,
          );
        }
        if (kind == _ButtonKind.secondary) {
          return BorderSide(color: colors.outline);
        }
        return const BorderSide(color: Colors.transparent);
      }),
    ).merge(style);
    final action = busy ? null : onPressed;
    final contents = icon == null && !busy
        ? child
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                icon!,
              const SizedBox(width: UiMetrics.labelGap),
              Flexible(child: child),
            ],
          );
    return switch (kind) {
      _ButtonKind.primary => m.FilledButton(
        key: controlKey,
        onPressed: action,
        onLongPress: busy ? null : onLongPress,
        style: baseline,
        focusNode: focusNode,
        autofocus: autofocus,
        child: contents,
      ),
      _ButtonKind.tonal => m.FilledButton.tonal(
        key: controlKey,
        onPressed: action,
        onLongPress: busy ? null : onLongPress,
        style: baseline,
        focusNode: focusNode,
        autofocus: autofocus,
        child: contents,
      ),
      _ButtonKind.secondary => m.OutlinedButton(
        key: controlKey,
        onPressed: action,
        onLongPress: busy ? null : onLongPress,
        style: baseline,
        focusNode: focusNode,
        autofocus: autofocus,
        child: contents,
      ),
      _ButtonKind.quiet => m.TextButton(
        key: controlKey,
        onPressed: action,
        onLongPress: busy ? null : onLongPress,
        style: baseline,
        focusNode: focusNode,
        autofocus: autofocus,
        child: contents,
      ),
    };
  }
}

class FilledButton extends _Button {
  static final styleFrom = m.FilledButton.styleFrom;
  const FilledButton({
    super.key,
    required super.onPressed,
    required super.child,
    super.onLongPress,
    super.style,
    super.focusNode,
    super.autofocus,
    super.busy,
  }) : super(kind: _ButtonKind.primary);
  const FilledButton.icon({
    super.key,
    required super.onPressed,
    required Widget label,
    super.icon,
    super.onLongPress,
    super.style,
    super.focusNode,
    super.autofocus,
    super.busy,
  }) : super(child: label, kind: _ButtonKind.primary);
  const FilledButton.tonal({
    super.key,
    required super.onPressed,
    required super.child,
    super.style,
    super.focusNode,
    super.autofocus,
    super.busy,
  }) : super(kind: _ButtonKind.tonal);
  const FilledButton.tonalIcon({
    super.key,
    required super.onPressed,
    required Widget label,
    super.icon,
    super.style,
    super.focusNode,
    super.autofocus,
    super.busy,
  }) : super(child: label, kind: _ButtonKind.tonal);
}

class OutlinedButton extends _Button {
  static final styleFrom = m.OutlinedButton.styleFrom;
  const OutlinedButton({
    super.key,
    required super.onPressed,
    required super.child,
    super.onLongPress,
    super.style,
    super.focusNode,
    super.autofocus,
    super.busy,
  }) : super(kind: _ButtonKind.secondary);
  const OutlinedButton.icon({
    super.key,
    required super.onPressed,
    required Widget label,
    super.icon,
    super.onLongPress,
    super.style,
    super.focusNode,
    super.autofocus,
    super.busy,
  }) : super(child: label, kind: _ButtonKind.secondary);
}

class TextButton extends _Button {
  static final styleFrom = m.TextButton.styleFrom;
  const TextButton({
    super.key,
    required super.onPressed,
    required super.child,
    super.onLongPress,
    super.style,
    super.focusNode,
    super.autofocus,
    super.busy,
  }) : super(kind: _ButtonKind.quiet);
  const TextButton.icon({
    super.key,
    required super.onPressed,
    required Widget label,
    super.icon,
    super.onLongPress,
    super.style,
    super.focusNode,
    super.autofocus,
    super.busy,
  }) : super(child: label, kind: _ButtonKind.quiet);
}

class AlertDialog extends StatelessWidget {
  final Key? controlKey;
  final Widget? title, content;
  final List<Widget>? actions;
  // Forward the caller's key to the native dialog and its semantics.
  // ignore: use_key_in_widget_constructors
  const AlertDialog({Key? key, this.title, this.content, this.actions})
    : controlKey = key;
  @override
  Widget build(BuildContext context) => m.AlertDialog(
    key: controlKey,
    title: title,
    content: content,
    actions: actions,
    scrollable: true,
    insetPadding: const EdgeInsets.all(UiMetrics.dialogInset),
  );
}
