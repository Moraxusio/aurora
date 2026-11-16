import 'package:aurora/ui/aurora_ui.dart';
import 'package:aurora_wire/aurora_wire.dart';

class AiQuestionDialog extends StatefulWidget {
  final Map<String, dynamic> question;
  final Future<void> Function(List<List<String>> answers, bool skip) submit;
  const AiQuestionDialog({
    super.key,
    required this.question,
    required this.submit,
  });
  @override
  State<AiQuestionDialog> createState() => _AiQuestionDialogState();
}

class _AiQuestionDialogState extends State<AiQuestionDialog> {
  late final _questions = [
    for (final q in widget.question['questions'] as List? ?? const [])
      if (q is Map) q.cast<String, dynamic>(),
  ];
  late final _choices = List.generate(_questions.length, (_) => <String>{});
  late final _custom = List.generate(
    _questions.length,
    (_) => TextEditingController(),
  );
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    for (final controller in _custom) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit(bool skip) async {
    if (_busy) return;
    final answers = [
      for (var i = 0; i < _questions.length; i++)
        [
          ..._choices[i],
          if (_custom[i].text.trim().isNotEmpty) _custom[i].text.trim(),
        ],
    ];
    if (!skip && answers.any((a) => a.isEmpty)) {
      setState(() => _error = '请回答每个问题，也可以填写自己的答案。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.submit(answers, skip);
      if (mounted) Navigator.pop(context);
    } on Object catch (e) {
      if (mounted)
        setState(
          () => _error = e is OpError
              ? e.message
              : e is StateError
              ? e.message
              : '提交失败，答案已保留，可以重试。',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(12),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 540, maxHeight: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '需要你的选择',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '稍后回答',
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _questions.length; i++) ...[
                    Text(
                      '${i + 1}. ${_questions[i]['question'] ?? ''}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    for (final option
                        in _questions[i]['options'] as List? ?? const [])
                      if (option is Map)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('${option['label']}'),
                          subtitle:
                              (option['description'] as String? ?? '').isEmpty
                              ? null
                              : Text('${option['description']}'),
                          value: _choices[i].contains(option['label']),
                          onChanged: _busy
                              ? null
                              : (checked) => setState(() {
                                  if (_questions[i]['multiple'] != true) {
                                    _choices[i].clear();
                                    _custom[i].clear();
                                  }
                                  if (checked == true) {
                                    _choices[i].add('${option['label']}');
                                  } else {
                                    _choices[i].remove(option['label']);
                                  }
                                }),
                        ),
                    TextField(
                      key: ValueKey('ai-question-answer-$i'),
                      controller: _custom[i],
                      enabled: !_busy,
                      maxLength: 1000,
                      decoration: const InputDecoration(
                        labelText: '自己的答案',
                        counterText: '',
                      ),
                      onChanged: (v) {
                        if (v.isNotEmpty && _questions[i]['multiple'] != true)
                          setState(() => _choices[i].clear());
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => _submit(true),
                  child: const Text('跳过'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('ai-question-submit'),
                  onPressed: _busy ? null : () => _submit(false),
                  child: Text(_busy ? '提交中…' : '提交答案'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
