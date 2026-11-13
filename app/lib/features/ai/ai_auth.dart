// OpenCode MIT device OAuth: tokens stay in Aurora's sealed client profile.
import 'dart:async';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';

final _refreshes = Expando<Map<String, Future<AiProvider>>>();

/// Share refresh across workspaces on the same app, then persist before use.
Future<AiProvider> prepareAiProvider(AppState app, Link link, AiProvider provider) async {
  final p = AiProvider.fromJson(provider.toJson());
  if (!p.isSubscription) return p;
  if (p.oauth == null || p.oauth!.refresh.isEmpty) throw StateError('请先在 AI 设置中使用 OpenAI 设备码登录');
  if (!p.oauth!.needsRefresh) return p;
  final pending = _refreshes[app] ??= {};
  if (pending[p.id] case final existing?) {
    final refreshed = await existing;
    p.oauth = refreshed.oauth; // retain THIS caller's model and reasoning selection
    return p;
  }
  final job = _refreshProvider(app, link, p);
  pending[p.id] = job;
  try {
    return await job;
  } finally {
    if (identical(pending[p.id], job)) pending.remove(p.id);
  }
}

Future<AiProvider> _refreshProvider(AppState app, Link link, AiProvider p) async {
  final previous = p.oauth!;
  final res = await link.call('ai.auth.refresh', {
    'refresh': previous.refresh,
    'account_id': previous.accountId,
    'use_proxy': p.useProxy,
  }) as Map;
  final credential = AiOAuthCredential.fromJson((res['credential'] as Map).cast<String, dynamic>());
  if (credential.access.isEmpty || credential.refresh.isEmpty || credential.needsRefresh) {
    throw StateError('OpenAI 刷新响应无效，请重新登录');
  }
  await app.update((profile) {
    final current = profile.ai.providers.where((x) => x.id == p.id).firstOrNull;
    if (current == null ||
        !current.isSubscription ||
        current.oauth?.refresh != previous.refresh ||
        current.oauth?.access != previous.access) {
      throw StateError('提供商或登录已变更，请重新发送');
    }
    current.oauth = credential;
  });
  p.oauth = credential;
  return p;
}

Future<AiOAuthCredential?> showAiDeviceLogin(BuildContext context, Link link, {required bool useProxy}) =>
    showDialog<AiOAuthCredential>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DeviceLogin(link: link, useProxy: useProxy),
    );

class _DeviceLogin extends StatefulWidget {
  final Link link;
  final bool useProxy;
  const _DeviceLogin({required this.link, required this.useProxy});
  @override
  State<_DeviceLogin> createState() => _DeviceLoginState();
}

class _DeviceLoginState extends State<_DeviceLogin> {
  Timer? _timer;
  Timer? _expiryTimer;
  bool _finished = false;
  String _code = '';
  String _deviceId = '';
  String? _error;
  int _deadline = 0;
  int _interval = 8000;
  bool _polling = false;
  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  @override
  void dispose() {
    _finished = true;
    _timer?.cancel();
    _expiryTimer?.cancel();
    super.dispose();
  }

  void _cancel() {
    _finished = true;
    _timer?.cancel();
    _expiryTimer?.cancel();
  }

  Future<void> _begin() async {
    try {
      final r = await widget.link.call('ai.auth.begin', {'use_proxy': widget.useProxy}) as Map;
      if (!mounted || _finished) return;
      _deviceId = r['device_auth_id'] as String? ?? '';
      _deadline = (r['expires_at'] as num?)?.toInt() ?? 0;
      _interval = ((r['interval_ms'] as num?)?.toInt() ?? 8000).clamp(8000, 63000);
      final code = r['user_code'] as String? ?? '';
      if (_deviceId.isEmpty || code.isEmpty || _deadline <= DateTime.now().millisecondsSinceEpoch) {
        throw StateError('设备授权响应无效，请升级 agent 后重试');
      }
      setState(() => _code = code);
      _expiryTimer = Timer(
        Duration(milliseconds: _deadline - DateTime.now().millisecondsSinceEpoch),
        () => _fail(StateError('设备码已过期，请关闭后重新登录')),
      );
      _schedule();
    } on Object catch (e) {
      _fail(e);
    }
  }

  void _schedule() {
    if (!mounted || _finished) return;
    final remaining = _deadline - DateTime.now().millisecondsSinceEpoch;
    if (remaining <= 0) {
      _fail(StateError('设备码已过期，请关闭后重新登录'));
      return;
    }
    _timer = Timer(Duration(milliseconds: remaining < _interval ? remaining : _interval), () => unawaited(_poll()));
  }

  Future<void> _poll() async {
    if (!mounted || _finished || _polling) return;
    if (DateTime.now().millisecondsSinceEpoch >= _deadline) {
      _fail(StateError('设备码已过期，请关闭后重新登录'));
      return;
    }
    _polling = true;
    try {
      final r = await widget.link.call('ai.auth.poll', {
        'device_auth_id': _deviceId,
        'user_code': _code,
        'use_proxy': widget.useProxy,
      }) as Map;
      if (!mounted || _finished) return;
      if (r['status'] == 'authorized') {
        final c = AiOAuthCredential.fromJson((r['credential'] as Map).cast<String, dynamic>());
        if (c.access.isEmpty || c.refresh.isEmpty) throw StateError('授权响应缺少登录令牌');
        _cancel();
        Navigator.pop(context, c);
      } else if (r['status'] == 'pending') {
        _schedule();
      } else {
        throw StateError('设备授权状态无效，请重新登录');
      }
    } on Object catch (e) {
      _fail(e);
    } finally {
      _polling = false;
    }
  }

  void _fail(Object e) {
    if (!mounted || _finished) return;
    _cancel();
    setState(
      () => _error = e is OpError
          ? e.message
          : e is StateError
          ? e.message
          : '授权网络请求失败，请重试',
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<AiOAuthCredential>(
    onPopInvokedWithResult: (didPop, result) {
      if (didPop) _cancel();
    },
    child: AlertDialog(
      title: const Text('OpenAI / ChatGPT 设备码登录'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请自行在浏览器打开官方地址并输入下方设备码。仅在你主动发起登录时授权，切勿把设备码交给他人。'),
            const SizedBox(height: 12),
            const SelectableText('https://auth.openai.com/codex/device'),
            TextButton.icon(
              onPressed: () => Clipboard.setData(const ClipboardData(text: 'https://auth.openai.com/codex/device')),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制官方登录地址'),
            ),
            if (_code.isNotEmpty) ...[
              SelectableText(
                _code,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 3),
              ),
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: _code)),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制设备码'),
              ),
            ],
            if (_error != null)
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
            else
              Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Flexible(child: Text(_code.isEmpty ? '正在获取设备码…' : '等待浏览器授权，最长 15 分钟…')),
                ],
              ),
            const SizedBox(height: 12),
            const Text('授权和模型请求经当前服务器出口。刷新令牌仅加密保存在客户端；服务器不保存登录。需账号启用设备码登录并具有相应模型资格。', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _cancel();
            Navigator.pop(context);
          },
          child: Text(_error == null ? '取消登录' : '关闭'),
        ),
      ],
    ),
  );
}
