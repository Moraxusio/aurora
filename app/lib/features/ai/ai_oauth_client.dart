// OpenCode MIT openai.ts headless flow, executed on the CLIENT's network.
// No browser cookies, existing credentials or account files are read.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/services.dart';

class AiOAuthClient {
  final Uri issuer;
  final HttpClient _http;
  bool _closed = false;
  static const clientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
  AiOAuthClient({Uri? testIssuer, HttpClient? http})
    : issuer = testIssuer ?? Uri.parse('https://auth.openai.com'),
      _http = http ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 20);
    _http.userAgent = 'opencode/stable/1.4.0/opencode';
  }
  Future<void> configureProxy() async {
    // Explicit environment proxies take precedence. Otherwise use the OS proxy
    // for this fixed issuer (no proxy credentials or browser state are read).
    final env = HttpClient.findProxyFromEnvironment(issuer);
    String? system;
    if (env == 'DIRECT') {
      try {
        system = await const MethodChannel('aurora3/input').invokeMethod<String>('authProxy');
      } on MissingPluginException {
        /* non-native tests/platforms use environment */
      } on PlatformException {
        /* direct network remains available */
      }
    }
    _http.findProxy = (_) => env != 'DIRECT'
        ? env
        : system?.isNotEmpty == true
        ? system!
        : 'DIRECT';
  }

  void useDirect() { _http.findProxy = (_) => 'DIRECT'; }

  void close() {
    _closed = true;
    _http.close(force: true);
  }

  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, String> body, {
    bool form = false,
    bool pending = false,
  }) async {
    if (_closed) throw StateError('登录已取消');
    try {
      final req = await _http.postUrl(issuer.resolve(path)).timeout(const Duration(seconds: 25));
      req.followRedirects = false;
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.contentType = ContentType('application', form ? 'x-www-form-urlencoded' : 'json', charset: 'utf-8');
      req.write(form ? Uri(queryParameters: body).query : jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 35));
      var size = 0;
      final chunks = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 35))) {
        size += chunk.length;
        if (size > 1024 * 1024) throw StateError('OpenAI 授权响应过大，请检查网络代理');
        chunks.addAll(chunk);
      }
      final html = res.headers.contentType?.mimeType == 'text/html' || res.headers.value('cf-mitigated') == 'challenge';
      if (pending && (res.statusCode == 403 || res.statusCode == 404) && !html) return {'status': 'pending'};
      if (res.statusCode != 200) {
        final phase = path.endsWith('usercode')
            ? '获取设备码'
            : path == '/oauth/token'
            ? '交换/刷新令牌'
            : '查询设备授权';
        if (res.statusCode == 403) {
          throw StateError('$phase被 OpenAI 拒绝（HTTP 403${html ? '，网页安全验证' : ''}）。请切换本机网络/代理或授权出口后重试；这不等于订阅无效。');
        }
        if (res.statusCode == 429) throw StateError('$phase请求过于频繁（HTTP 429），请稍后重试');
        throw StateError('$phase失败（HTTP ${res.statusCode}），请重试；授权已过期时重新获取设备码');
      }
      final decoded = jsonDecode(utf8.decode(chunks));
      if (decoded is! Map) throw const FormatException();
      return decoded.cast<String, dynamic>();
    } on StateError {
      rethrow;
    } on FormatException {
      throw StateError('OpenAI 未返回有效 JSON，可能是代理错误页或网页验证');
    } on Object {
      throw StateError(_closed ? '登录已取消' : '本机无法连接 OpenAI 授权服务，请检查本机网络/系统代理，或选择服务器网络');
    }
  }

  Future<Map<String, dynamic>> begin() async {
    final r = await _request('/api/accounts/deviceauth/usercode', {'client_id': clientId});
    final interval = (int.tryParse('${r['interval']}') ?? 5).clamp(5, 60);
    if (r['device_auth_id'] is! String || r['user_code'] is! String) throw StateError('OpenAI 未返回完整设备码');
    return {...r, 'interval_ms': interval * 1000 + 3000, 'expires_at': DateTime.now().millisecondsSinceEpoch + 900000};
  }

  Future<Map<String, dynamic>> poll(String device, String code) async {
    final r = await _request('/api/accounts/deviceauth/token', {
      'device_auth_id': device,
      'user_code': code,
    }, pending: true);
    if (r['status'] == 'pending') return r;
    if (r['authorization_code'] is! String || r['code_verifier'] is! String) {
      throw StateError('OpenAI 授权响应不完整，请重新获取设备码');
    }
    final c = await _exchange({
      'grant_type': 'authorization_code',
      'code': r['authorization_code'] as String,
      'code_verifier': r['code_verifier'] as String,
      'redirect_uri': issuer.resolve('/deviceauth/callback').toString(),
    });
    return {'status': 'authorized', 'credential': c.toJson()};
  }

  Future<AiOAuthCredential> refresh(AiOAuthCredential previous) =>
      _exchange({'grant_type': 'refresh_token', 'refresh_token': previous.refresh}, previous: previous);
  Future<AiOAuthCredential> _exchange(Map<String, String> form, {AiOAuthCredential? previous}) async {
    final r = await _request('/oauth/token', {'client_id': clientId, ...form}, form: true);
    final access = r['access_token'] as String? ?? '';
    final refresh = r['refresh_token'] as String? ?? previous?.refresh ?? '';
    if (access.isEmpty || refresh.isEmpty) throw StateError('OpenAI 未返回完整令牌，请重新登录');
    return AiOAuthCredential(
      access: access,
      refresh: refresh,
      expires: DateTime.now().millisecondsSinceEpoch + ((r['expires_in'] as num?)?.toInt() ?? 3600) * 1000,
      accountId: _account(r['id_token']) ?? _account(access) ?? previous?.accountId ?? '',
      transport: 'client',
    );
  }

  String? _account(Object? token) {
    // Unverified JWT claims are only used for routing, never authentication.
    try {
      final parts = (token as String).split('.');
      final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
      if (j['chatgpt_account_id'] is String) return j['chatgpt_account_id'] as String;
      final auth = j['https://api.openai.com/auth'];
      if (auth is Map && auth['chatgpt_account_id'] is String) return auth['chatgpt_account_id'] as String;
      final orgs = j['organizations'];
      if (orgs is List && orgs.isNotEmpty && orgs.first is Map) return (orgs.first as Map)['id'] as String?;
    } on Object {
      /* absent/malformed routing hint */
    }
    return null;
  }
}
