import 'package:aurora/ui/aurora_ui.dart';

/// One editor for connection, model and session effort values.
class AiReasoningField extends StatefulWidget {
  final String value, label, hint;
  final Iterable<String> suggestions;
  final ValueChanged<String> onChanged;
  const AiReasoningField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = '思考强度',
    this.hint = '留空不发送参数，也可填写 high、max、xhigh…',
    this.suggestions = const ['low', 'medium', 'high', 'max'],
  });
  @override
  State<AiReasoningField> createState() => _AiReasoningFieldState();
}

class _AiReasoningFieldState extends State<AiReasoningField> {
  late final _text = TextEditingController(text: widget.value);
  @override
  void didUpdateWidget(covariant AiReasoningField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && _text.text.trim() != widget.value) {
      _text.text = widget.value;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _set(String value) {
    _text.text = value;
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: const ValueKey('ai-effort-input'),
        controller: _text,
        maxLength: 64,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          counterText: '',
          suffixIcon: _text.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '不发送思考参数',
                  onPressed: () => _set(''),
                  icon: const Icon(Icons.clear, size: 16),
                ),
        ),
        onChanged: (v) => widget.onChanged(v.trim()),
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final value in widget.suggestions.toSet().where(
            (s) => s.isNotEmpty,
          ))
            ActionChip(
              visualDensity: VisualDensity.compact,
              label: Text(value, style: const TextStyle(fontSize: 11)),
              onPressed: () => _set(value),
            ),
        ],
      ),
    ],
  );
}
