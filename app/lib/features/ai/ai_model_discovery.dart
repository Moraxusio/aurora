import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/services.dart';

List<Map<String, dynamic>> parseAiModels(Object? json) {
  final Object? raw = json is List
      ? json
      : json is Map
      ? json['data'] ?? json['models']
      : null;
  if (raw is! List) {
    throw StateError('返回 JSON 中没有 data/models 列表，请检查 API 地址或手动添加模型');
  }
  final models = <String, Map<String, dynamic>>{};
  for (final row in raw) {
    final m = row is Map ? row : <String, dynamic>{};
    final id = (row is String ? row : m['id'] ?? m['name'] ?? '')
        .toString()
        .replaceFirst(RegExp(r'^models/'), '')
        .trim();
    if (id.isEmpty) continue;
    final window =
        m['context_length'] ?? m['context_window'] ?? m['max_input_tokens'];
    models[id] = {
      'id': id,
      if (window is num && window > 0) 'context_window': window.toInt(),
    };
  }
  final result = models.values.toList()
    ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
  return result;
}

/// Optional client-network discovery works before any local/remote agent exists.
/// Keys are sent only to the configured origin; redirects are never followed.
Future<List<Map<String, dynamic>>> discoverAiModels(
  AiProvider provider, {
  HttpClient? http,
}) async {
  if (provider.isSubscription) {
    return [
      for (final id in {
        provider.model,
        'gpt-6.1-sol',
        'gpt-5.2-codex',
        'gpt-5.1-codex',
        'gpt-5-codex',
      }.where((x) => x.isNotEmpty))
        {'id': id},
    ];
  }
  final base = Uri.tryParse(provider.baseUrl.trim());
  if (base == null ||
      !base.hasAuthority ||
      base.userInfo.isNotEmpty ||
      !['https', 'http'].contains(base.scheme)) {
    throw StateError('请填写有效的 HTTP(S) API Base URL');
  }
  var path = base.path
      .replaceFirst(RegExp(r'/+$'), '')
      .replaceFirst(
        RegExp(r'/(chat/completions|messages|responses|models)$'),
        '',
      );
  final endpoints = [
    base.replace(path: '$path/models'),
    if (!path.endsWith('/v1') && !path.contains('/v1/'))
      base.replace(path: '$path/v1/models'),
  ];
  final client = http ?? HttpClient();
  client.connectionTimeout = const Duration(seconds: 15);
  try {
    String? system;
    if (provider.useProxy) {
      try {
        system = await const MethodChannel('aurora3/input')
            .invokeMethod<String>('authProxy');
      } on MissingPluginException {
        /* environment proxy */
      }
    }
    client.findProxy = (uri) => !provider.useProxy
        ? 'DIRECT'
        : HttpClient.findProxyFromEnvironment(uri) != 'DIRECT'
        ? HttpClient.findProxyFromEnvironment(uri)
        : system ?? 'DIRECT';
    StateError? last;
    List<Map<String, dynamic>>? empty;
    endpointsLoop:
    for (final firstEndpoint in endpoints) {
      var endpoint = firstEndpoint;
      final all = <Map<String, dynamic>>[];
      final cursors = <String>{};
      for (var page = 0; page < 20; page++) {
        final req = await client
            .getUrl(endpoint)
            .timeout(const Duration(seconds: 20));
        req.followRedirects = false;
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (provider.apiKey.isNotEmpty) {
          if (provider.authMode == 'x-api-key' ||
              (provider.authMode.isEmpty &&
                  provider.protocol == 'anthropic-messages')) {
            req.headers.set('x-api-key', provider.apiKey);
          } else {
            req.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer ${provider.apiKey}',
            );
          }
        }
        if (provider.protocol == 'anthropic-messages') {
          req.headers.set('anthropic-version', '2023-06-01');
        }
        for (final entry in provider.headers.entries) {
          req.headers.set(entry.key, entry.value);
        }
        final res = await req.close().timeout(const Duration(seconds: 25));
        final bytes = <int>[];
        await for (final chunk in res.timeout(const Duration(seconds: 25))) {
          bytes.addAll(chunk);
          if (bytes.length > 4 * 1024 * 1024) {
            throw StateError('模型列表超过 4 MiB，请手动添加');
          }
        }
        if (res.statusCode == 401 || res.statusCode == 403) {
          throw StateError('拉取模型被拒绝（HTTP ${res.statusCode}），请检查凭证、出口和提供商权限');
        }
        if (res.statusCode < 200 || res.statusCode >= 300) {
          last = StateError('模型接口 HTTP ${res.statusCode}；可手动添加模型');
          continue endpointsLoop;
        }
        try {
          final json = jsonDecode(utf8.decode(bytes));
          final models = parseAiModels(json);
          all.addAll(models);
          if (json is Map && json['has_more'] == true) {
            final cursor = json['last_id'];
            if (cursor is! String || cursor.isEmpty || !cursors.add(cursor)) {
              throw StateError('模型列表分页游标无效或重复');
            }
            endpoint = endpoint.replace(
              queryParameters: {
                ...endpoint.queryParameters,
                'after_id': cursor,
              },
            );
            continue;
          }
          if (all.isNotEmpty) return parseAiModels(all);
          empty = models;
        } on FormatException {
          last = StateError('返回的是网页或无效 JSON，请检查 API Base URL');
        } on StateError catch (e) {
          last = e;
        }
        continue endpointsLoop;
      }
      throw StateError('模型列表超过 20 页，请手动添加模型');
    }
    if (empty != null) return empty;
    throw last ?? StateError('未能获取模型列表');
  } finally {
    client.close(force: true);
  }
}
