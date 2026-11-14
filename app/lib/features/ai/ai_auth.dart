// OpenCode MIT device OAuth: tokens stay in Aurora's sealed client profile.
import 'dart:async';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import '../../kernel/overlays.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';
import 'ai_oauth_client.dart';

final _refreshes = Expando<Map<String, Future<AiProvider>>>();

/// Share refresh across workspaces on the same app, then persist before use.
Future<AiProvider> prepareAiProvider(
  AppState app,
  Link link,
  AiProvider provider, {
  AiOAuthClient Function()? localFactory,
}) async {
  final p = AiProvider.fromJson(provider.toJson());
  if (p.proxyMode.isNotEmpty && !link.server.caps.contains('ai.network')) {
    throw StateError('当前 agent 尚不支持选择代理出口，请升级 agent 或沿用旧设置');
  }
  if (!p.isSubscription) return p;
  if (p.oauth == null || p.oauth!.refresh.isEmpty) throw StateError('请先在 AI 设置中使用 OpenAI 设备码登录');
  if (!p.oauth!.needsRefresh) return p;
  final pending = _refreshes[app] ??= {};
  if (pending[p.id] case final existing?) {
    final refreshed = await existing;
    p.oauth = refreshed.oauth; // retain THIS caller's model and reasoning selection
    return p;
  }
  final job = _refreshProvider(app, link, p, localFactory);
  pending[p.id] = job;
  try {
    return await job;
  } finally {
    if (identical(pending[p.id], job)) pending.remove(p.id);
  }
}

Future<AiProvider> _refreshProvider(
  AppState app,
  Link link,
  AiProvider p,
  AiOAuthClient Function()? localFactory,
) async {
  final previous = p.oauth!;
  late final AiOAuthCredential credential;
  if (previous.transport == 'client') {
    final local = (localFactory ?? AiOAuthClient.new)();
    try {
      if (p.proxyMode == 'direct') { local.useDirect(); } else { await local.configureProxy(); }
      credential = await local.refresh(previous);
    } finally {
      local.close();
    }
  } else {
    final res = await link.call('ai.auth.refresh', {
      'refresh': previous.refresh,
      'account_id': previous.accountId,
      'use_proxy': p.usesProxy,
      if (p.proxyMode.isNotEmpty) 'proxy_mode': p.proxyMode,
    }) as Map;
    credential = AiOAuthCredential.fromJson({
      ...((res['credential'] as Map).cast<String, dynamic>()),
      'transport': 'server',
    });
  }
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

Future<AiOAuthCredential?> showAiDeviceLogin(
  BuildContext context,
  Link? link, {
  required bool useProxy,
  String proxyMode = '',
  String initialTransport = 'client',
  AiOAuthClient Function()? localFactory,
}) => showWorkbenchDialog<AiOAuthCredential>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _DeviceLogin(link: link, useProxy: useProxy, proxyMode: proxyMode, initialTransport: initialTransport, localFactory: localFactory),
);

class _DeviceLogin extends StatefulWidget {
  final Link? link;
  final bool useProxy;
  final String proxyMode;
  final String initialTransport;
  final AiOAuthClient Function()? localFactory;
  const _DeviceLogin({required this.link, required this.useProxy, required this.proxyMode, required this.initialTransport, this.localFactory});
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
  late String _transport;
  AiOAuthClient? _local;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _transport = widget.initialTransport;
    unawaited(_begin());
  }

  @override
  void dispose() {
    _finished = true;
    _timer?.cancel();
    _expiryTimer?.cancel();
    _local?.close();
    super.dispose();
  }

  void _cancel() {
    _finished = true;
    _timer?.cancel();
    _expiryTimer?.cancel();
    _local?.close();
  }

  Future<void> _begin() async {
    final generation = ++_generation;
    try {
      late final Map r;
      if (_transport == 'client') {
        final local = (widget.localFactory ?? AiOAuthClient.new)();
        _local = local;
        if (widget.proxyMode == 'direct') { local.useDirect(); } else { await local.configureProxy(); }
        r = await local.begin();
      } else {
        if (widget.link == null) throw StateError('服务器未连接，请使用本机网络');
        if (widget.proxyMode.isNotEmpty && !widget.link!.server.caps.contains('ai.network')) throw StateError('请升级 agent 后选择代理出口');
        r = await widget.link!.call('ai.auth.begin', {'use_proxy': widget.useProxy, if (widget.proxyMode.isNotEmpty) 'proxy_mode': widget.proxyMode}) as Map;
      }
      if (!mounted || _finished || generation != _generation) return;
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
      if (generation == _generation) _fail(e);
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
    final generation = _generation;
    try {
      final r = _transport == 'client'
          ? await _local!.poll(_deviceId, _code)
          : await widget.link!.call('ai.auth.poll', {
              'device_auth_id': _deviceId,
              'user_code': _code,
              'use_proxy': widget.useProxy,
              if (widget.proxyMode.isNotEmpty) 'proxy_mode': widget.proxyMode,
            }) as Map;
      if (!mounted || _finished || generation != _generation) return;
      if (r['status'] == 'authorized') {
        final c = AiOAuthCredential.fromJson({
          ...((r['credential'] as Map).cast<String, dynamic>()),
          'transport': _transport,
        });
        if (c.access.isEmpty || c.refresh.isEmpty) throw StateError('授权响应缺少登录令牌');
        _cancel();
        Navigator.pop(context, c);
      } else if (r['status'] == 'pending') {
        _schedule();
      } else {
        throw StateError('设备授权状态无效，请重新登录');
      }
    } on Object catch (e) {
      if (generation == _generation) _fail(e);
    } finally {
      if (generation == _generation) _polling = false;
    }
  }

  void _retry([String? transport]) {
    _cancel();
    setState(() {
      _transport = transport ?? _transport;
      _finished = false;
      _polling = false;
      _code = '';
      _error = null;
    });
    unawaited(_begin());
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('请自行在浏览器打开官方地址并输入下方设备码。仅在你主动发起登录时授权，切勿把设备码交给他人。'),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('ai-auth-transport-$_transport'),
                initialValue: _transport,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '授权网络出口'),
                items: const [
                  DropdownMenuItem(value: 'client', child: Text('本机网络 / 系统代理（推荐）')),
                  DropdownMenuItem(value: 'server', child: Text('服务器网络 / 服务器代理出口')),
                ],
                onChanged: (v) {
                  if (v != null && v != _transport) _retry(v);
                },
              ),
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
              Text(
                _transport == 'client'
                    ? '授权及刷新直接从本机发出，不经过服务器；模型请求仍从服务器发出。令牌加密保存在本机。'
                    : '授权及刷新经服务器出口，令牌仅加密保存在本机。获取设备码时的 403 通常需要检查出口网络，不能据此判断订阅资格。',
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (_error != null)
          FilledButton.icon(
            onPressed: () => _retry(),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重新获取设备码'),
          ),
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
