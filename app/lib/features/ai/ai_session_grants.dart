import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora/ui/aurora_ui.dart';

import '../../theme/ide_theme.dart';
import 'ai_visuals.dart';

Future<void> showAiSessionGrants(
  BuildContext context,
  Link link,
  String sessionId,
) => showPicker<void>(
  context,
  maxWidth: 540,
  maxHeight: 540,
  builder: (_) => _Grants(link: link, sessionId: sessionId),
);

class _Grants extends StatefulWidget {
  final Link link;
  final String sessionId;
  const _Grants({required this.link, required this.sessionId});
  @override
  State<_Grants> createState() => _GrantsState();
}

class _GrantsState extends State<_Grants> {
  List<Map> _grants = [];
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([Map? revoke, bool revokeAll = false]) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.link.call('ai.permissions', {
        'session_id': widget.sessionId,
        if (revokeAll) ...{
          'revoke': true,
          'action': '*',
          'resource': '*',
        } else if (revoke != null) ...{
          'revoke': true,
          'action': revoke['action'],
          'resource': revoke['resource'],
        },
      }) as Map;
      if (mounted)
        setState(
          () => _grants = (result['grants'] as List? ?? [])
              .whereType<Map>()
              .toList(),
        );
    } on Object catch (e) {
      if (mounted)
        setState(() => _error = e is OpError ? e.message : '无法更新会话授权，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _grantExpiry(Map grant) {
    final exp = (grant['expires_at'] as num?)?.toInt() ?? 0;
    if (exp <= 0) return '本会话有效';
    final left = exp - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) return '即将过期';
    final mins = (left / 60000).ceil();
    return mins >= 60 ? '约 ${(mins / 60).ceil()} 小时后过期' : '约 $mins 分钟后过期';
  }

  @override
  Widget build(BuildContext context) {
    final ide = Ide.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: const AiSectionHeading(
            icon: Icons.shield_outlined,
            title: '本会话授权',
            subtitle: '仅此会话记住的允许范围。撤销后，后续调用重新按权限规则判断。',
          ),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: TextStyle(color: ide.error)),
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final grant in _grants)
                ListTile(
                  title: Text(
                    '${grant['action']}  ·  ${_grantExpiry(grant)}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: SelectableText(
                    '${grant['resource']}',
                    style: const TextStyle(fontFamily: Ide.mono, fontSize: 12),
                  ),
                  trailing: TextButton(
                    onPressed: _busy ? null : () => _load(grant),
                    child: const Text('撤销'),
                  ),
                ),
              if (!_busy && _grants.isEmpty && _error == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('本会话暂无记住的授权。'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_grants.isNotEmpty)
                TextButton(
                  onPressed: _busy ? null : () => _load(null, true),
                  child: Text('全部撤销', style: TextStyle(color: ide.error)),
                ),
              if (_error != null)
                TextButton(
                  onPressed: _busy ? null : _load,
                  child: const Text('重试'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
