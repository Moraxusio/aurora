import 'dart:async';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/foundation.dart';

import '../document_model.dart';
import '../document_recovery.dart';
import '../workspace.dart';
import 'protocol_peer.dart';
import 'text_edits.dart';
import 'workspace_edit.dart';

String languageIdForPath(String path) {
  final name = path.split('/').last.toLowerCase();
  if (name == 'dockerfile') return 'dockerfile';
  return switch (name.split('.').last) {
    'dart' => 'dart',
    'go' => 'go',
    'rs' => 'rust',
    'py' || 'pyw' => 'python',
    'js' || 'mjs' || 'cjs' => 'javascript',
    'jsx' => 'javascriptreact',
    'ts' => 'typescript',
    'tsx' => 'typescriptreact',
    'c' || 'h' => 'c',
    'cpp' || 'cc' || 'cxx' || 'hpp' => 'cpp',
    'java' => 'java',
    'cs' => 'csharp',
    'json' => 'json',
    'jsonc' => 'jsonc',
    'yaml' || 'yml' => 'yaml',
    'html' || 'htm' => 'html',
    'css' => 'css',
    'sh' || 'bash' || 'zsh' => 'shellscript',
    'md' => 'markdown',
    'xml' || 'svg' => 'xml',
    'sql' => 'sql',
    _ => 'plaintext',
  };
}

class DevelopmentScope {
  final String root, path, rootUri, workspaceUri, platform, etag;
  final Map<String, dynamic> config;
  const DevelopmentScope(
    this.root,
    this.path,
    this.rootUri,
    this.workspaceUri,
    this.platform,
    this.etag,
    this.config,
  );
  String get identity => '$root:$path';
  Map<String, Object?> get args => {'root': root, 'path': path};
  List<Map<String, dynamic>> entries(String key) => [
    for (final item in config[key] as List? ?? const [])
      if (item is Map) item.cast<String, dynamic>(),
  ];
  String documentUri(String path) {
    final base = Uri.parse(rootUri);
    return base
        .replace(
          pathSegments: [
            ...base.pathSegments.where((part) => part.isNotEmpty),
            ...path.split('/').where((part) => part.isNotEmpty),
          ],
        )
        .toString();
  }

  String? pathFromUri(String value) {
    final uri = Uri.tryParse(value), base = Uri.tryParse(rootUri);
    if (uri == null ||
        base == null ||
        uri.scheme != 'file' ||
        uri.host != base.host ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.any(
          (part) =>
              part == '..' ||
              part.contains('/') ||
              part.contains('\\') ||
              part.contains('\x00'),
        ))
      return null;
    final prefix = base.pathSegments.where((part) => part.isNotEmpty).toList();
    final parts = uri.pathSegments;
    if (parts.length < prefix.length) return null;
    for (var i = 0; i < prefix.length; i++) {
      if (platform == 'windows'
          ? parts[i].toLowerCase() != prefix[i].toLowerCase()
          : parts[i] != prefix[i])
        return null;
    }
    return WorkspacePath.normalize('/${parts.skip(prefix.length).join('/')}');
  }
}

class DevelopmentDiagnostic {
  final DocumentKey key;
  final int line, column, severity;
  final String message, source;
  final Map<String, dynamic> raw;
  DevelopmentDiagnostic(
    this.key,
    this.line,
    this.column,
    this.severity,
    this.message,
    this.source,
    this.raw,
  );
}

class LanguageReply {
  final LanguageSession session;
  final Object? result;
  final Map<DocumentKey, int> versions;
  LanguageReply(this.session, this.result, this.versions);
}

class DevelopmentModel extends ChangeNotifier {
  final Workspace ws;
  final Map<String, Future<DevelopmentScope>> _scopes = {};
  final Map<String, Future<LanguageSession>> _starting = {};
  final Map<String, LanguageSession> sessions = {};
  final Map<DocumentModel, VoidCallback> _listeners = {};
  final Map<DocumentModel, LanguageSession> _bound = {};
  final Map<DocumentModel, Future<LanguageSession?>> _ensuring = {};
  final Map<String, String> _scopeFailures = {};
  final Map<String, Map<DocumentKey, List<DevelopmentDiagnostic>>> _problems =
      {};
  final List<String> logs = [];
  final Map<String, String> failures = {};
  Link? _link;
  bool _disposed = false, _notifyQueued = false;
  int _generation = 0;
  Future<bool> Function(DocumentEditPlan plan)? reviewEdit;

  DevelopmentModel(this.ws) {
    _link = ws.link;
    ws.addListener(_workspaceChanged);
    ws.documents.addListener(_documentsChanged);
    _documentsChanged();
  }
  bool get supported => ws.link?.server.caps.contains('lsp.start') == true;
  Iterable<DevelopmentDiagnostic> get diagnostics =>
      _problems.values.expand((files) => files.values).expand((items) => items);
  LanguageSession? sessionFor(DocumentModel document) => _bound[document];
  Map<DocumentKey, int> versions() => {
    for (final doc in ws.documents.all) doc.key: doc.version,
  };

  void _notify() {
    if (_disposed || _notifyQueued) return;
    _notifyQueued = true;
    scheduleMicrotask(() {
      _notifyQueued = false;
      if (!_disposed) notifyListeners();
    });
  }

  void log(String message) {
    if (_disposed) return;
    logs.add(
      message.length > 4096 ? '${message.substring(0, 4096)}…' : message,
    );
    if (logs.length > 128) logs.removeRange(0, logs.length - 128);
    _notify();
  }

  void _workspaceChanged() {
    if (identical(_link, ws.link)) return;
    _link = ws.link;
    restart();
  }

  void restart() {
    _generation++;
    _scopes.clear();
    _starting.clear();
    _ensuring.clear();
    _scopeFailures.clear();
    _bound.clear();
    _problems.clear();
    failures.clear();
    for (final session in sessions.values.toList()) {
      session.close();
    }
    sessions.clear();
    for (final doc in _listeners.keys.toList()) {
      unawaited(ensure(doc));
    }
    _notify();
  }

  void _documentsChanged() {
    final documents = ws.documents.all.toSet();
    for (final doc in _listeners.keys.toList()) {
      if (documents.contains(doc)) continue;
      doc.removeListener(_listeners.remove(doc)!);
      final session = _bound.remove(doc);
      if (session != null)
        unawaited(session.detach(doc).catchError((Object e) => log('$e')));
      for (final problems in _problems.values) {
        problems.remove(doc.key);
      }
    }
    for (final doc in documents) {
      if (_listeners.containsKey(doc)) continue;
      var version = -1, saved = -1;
      DocumentPhase? phase;
      void changed() {
        if (_disposed ||
            (version == doc.version &&
                saved == doc.savedVersion &&
                phase == doc.phase))
          return;
        version = doc.version;
        saved = doc.savedVersion;
        phase = doc.phase;
        for (final problems in _problems.values) {
          problems.remove(doc.key);
        }
        final session = _bound[doc];
        if (!doc.languageSyncEligible && session != null) {
          _bound.remove(doc);
          unawaited(session.detach(doc).catchError((Object e) => log('$e')));
        } else if (session != null && !session.peer.closed) {
          session.queueSync(doc);
        } else {
          unawaited(ensure(doc));
        }
        _notify();
      }

      _listeners[doc] = changed;
      doc.addListener(changed);
      changed();
    }
    _notify();
  }

  WorkspacePath scopeFor(DocumentModel doc) {
    final folders =
        ws.project?.folders
            .where(
              (f) =>
                  f.root == doc.key.root &&
                  (f.path == '/' ||
                      doc.key.path == f.path ||
                      doc.key.path.startsWith('${f.path}/')),
            )
            .toList() ??
        [];
    folders.sort((a, b) => b.path.length.compareTo(a.path.length));
    return folders.isEmpty
        ? WorkspacePath(root: doc.key.root, path: '/')
        : folders.first;
  }

  Future<DevelopmentScope> configuration(
    String root,
    String path, {
    bool refresh = false,
  }) {
    final id = '$root:$path';
    if (refresh) {
      _scopes.remove(id);
      _scopeFailures.remove(id);
    }
    return _scopes.putIfAbsent(id, () async {
      final link = ws.link, generation = _generation;
      if (link == null) throw const ProtocolError('未连接');
      final reply = await link.call('devtools.config', {
        'root': root,
        'path': path,
      }) as Map;
      if (_disposed || generation != _generation || !identical(link, ws.link))
        throw const ProtocolError('连接已变化');
      return DevelopmentScope(
        root,
        path,
        reply['rootUri'] as String,
        reply['workspaceUri'] as String,
        reply['platform'] as String,
        reply['etag'] as String,
        (reply['config'] as Map).cast<String, dynamic>(),
      );
    });
  }

  Future<void> saveConfiguration(
    DevelopmentScope scope,
    Map<String, dynamic> config,
  ) async {
    final link = ws.link;
    if (link == null) throw const ProtocolError('未连接');
    await link.call('devtools.configure', {
      ...scope.args,
      'if_match': scope.etag,
      'config': config,
    });
    if (!identical(link, ws.link)) throw const ProtocolError('连接已变化，请重新读取配置');
    restart();
  }

  Future<LanguageSession?> ensure(DocumentModel doc) {
    if (_disposed ||
        !supported ||
        doc.isClosed ||
        !doc.languageSyncEligible ||
        doc.phase != DocumentPhase.ready) {
      return Future.value();
    }
    final bound = _bound[doc];
    if (bound != null && !bound.peer.closed) return Future.value(bound);
    final pending = _ensuring[doc];
    if (pending != null) return pending;
    late final Future<LanguageSession?> future;
    future = _ensure(doc).whenComplete(() {
      if (identical(_ensuring[doc], future)) _ensuring.remove(doc);
    });
    _ensuring[doc] = future;
    return future;
  }

  Future<LanguageSession?> _ensure(DocumentModel doc) async {
    final link = ws.link!, generation = _generation;
    final folder = scopeFor(doc);
    final scopeId = '${folder.root}:${folder.path}';
    if (_scopeFailures.containsKey(scopeId)) return null;
    String? serverId;
    bool active() =>
        !_disposed &&
        !doc.isClosed &&
        doc.languageSyncEligible &&
        identical(link, ws.link) &&
        generation == _generation;
    try {
      final scope = await configuration(folder.root, folder.path);
      if (!active()) return null;
      final language = languageIdForPath(doc.key.path);
      final config = scope
          .entries('languageServers')
          .where((c) => (c['languages'] as List? ?? []).contains(language))
          .firstOrNull;
      if (config == null) return null;
      final id = '${scope.identity}:${config['id']}';
      serverId = id;
      if (failures.containsKey(id)) return null;
      final session = await _starting.putIfAbsent(id, () async {
        final peer = await ProtocolPeer.open(
          link,
          'lsp.start',
          {...scope.args, 'id': config['id']},
          active: () =>
              !_disposed &&
              generation == _generation &&
              identical(link, ws.link),
        );
        final session = LanguageSession(
          this,
          id,
          scope,
          config,
          peer,
          link,
          generation,
        );
        try {
          await session.initialize();
          if (!session.active) throw const ProtocolError('语言服务器已过期');
          sessions[id] = session;
          failures.remove(id);
          _notify();
          return session;
        } on Object {
          peer.close();
          rethrow;
        }
      });
      if (!active() || session.peer.closed) return null;
      _bound[doc] = session;
      await session.sync(doc);
      _notify();
      return session;
    } on Object catch (e) {
      if (active()) {
        if (serverId == null) {
          _scopeFailures[scopeId] = '$e';
        } else {
          failures[serverId] = '$e';
        }
        log('${doc.key.path}: $e');
      }
      return null;
    }
  }

  Future<LanguageReply> request(
    DocumentModel doc,
    String method,
    Map<String, Object?> params,
  ) async {
    final session = _bound[doc] ?? await ensure(doc);
    if (session == null || !session.active)
      throw const ProtocolError('没有可用的语言服务器，请检查开发配置与日志');
    final snapshot = versions();
    await session.sync(doc);
    final result = await session.peer.request(method, {
      'textDocument': {'uri': session.scope.documentUri(doc.key.path)},
      ...params,
    });
    if (!session.active || snapshot[doc.key] != doc.version)
      throw const ProtocolError('文档已变化，已丢弃旧结果');
    return LanguageReply(session, result, snapshot);
  }

  Future<DocumentEditPlan> prepareEdit(
    LanguageSession session,
    Map edit,
    Map<DocumentKey, int> expected,
  ) => prepareWorkspaceEdit(
    documents: ws.documents,
    root: session.scope.root,
    pathFromUri: session.scope.pathFromUri,
    caseSensitive: session.scope.platform != 'windows',
    edit: edit,
    expected: expected,
    active: () => session.active,
    cancelled: session.peer.done,
  );

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    ws.removeListener(_workspaceChanged);
    ws.documents.removeListener(_documentsChanged);
    for (final entry in _listeners.entries) {
      entry.key.removeListener(entry.value);
    }
    _listeners.clear();
    for (final session in sessions.values) {
      session.close();
    }
    sessions.clear();
    super.dispose();
  }
}

class _SyncedDocument {
  int version, savedVersion;
  String text;
  _SyncedDocument(this.version, this.savedVersion, this.text);
}

class LanguageSession {
  final DevelopmentModel model;
  final String id;
  final DevelopmentScope scope;
  final Map<String, dynamic> configuration;
  final ProtocolPeer peer;
  final Link link;
  final int generation;
  final Map<DocumentModel, _SyncedDocument> _opened = {};
  final Map<DocumentModel, Timer> _timers = {};
  Map<String, dynamic> capabilities = {};
  Future<void> _syncTail = Future.value();
  LanguageSession(
    this.model,
    this.id,
    this.scope,
    this.configuration,
    this.peer,
    this.link,
    this.generation,
  ) {
    peer.onRequest = _serverRequest;
    peer.onNotification = _notification;
    peer.onTransport = (event) =>
        model.log('$id: ${event['text'] ?? event['message'] ?? event}');
    peer.onClosed = () {
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
      model._problems.remove(id);
      if (!model._disposed && generation == model._generation) {
        model.failures[id] = '语言服务器已停止，可通过“重启语言服务”重连';
        model._notify();
      }
    };
  }
  bool get active =>
      !model._disposed &&
      generation == model._generation &&
      identical(link, model.ws.link) &&
      !peer.closed;
  int get changeKind {
    final sync = capabilities['textDocumentSync'];
    return sync is int
        ? sync
        : sync is Map
        ? (sync['change'] as int? ?? 0)
        : 0;
  }

  bool get openClose {
    final sync = capabilities['textDocumentSync'];
    return sync is int ? sync != 0 : sync is Map && sync['openClose'] == true;
  }

  Future<void> initialize() async {
    final result = await peer.request('initialize', {
      'processId': null,
      'rootUri': scope.workspaceUri,
      'clientInfo': {'name': 'Aurora', 'version': '3'},
      'workspaceFolders': [
        {'uri': scope.workspaceUri, 'name': scope.path.split('/').last},
      ],
      'initializationOptions': configuration['initializationOptions'],
      'capabilities': {
        'general': {
          'positionEncodings': ['utf-16'],
        },
        'workspace': {
          'applyEdit': true,
          'workspaceEdit': {
            'documentChanges': true,
            if (link.server.caps.contains('fs.refactor')) ...{
              'resourceOperations': ['create', 'rename', 'delete'],
              'failureHandling': 'abort',
            },
          },
          'configuration': true,
          'workspaceFolders': true,
        },
        'textDocument': {
          'synchronization': {'didSave': true},
          'completion': {
            'completionItem': {'snippetSupport': true},
          },
          'hover': {
            'contentFormat': ['plaintext', 'markdown'],
          },
          'publishDiagnostics': {'versionSupport': true},
          'codeAction': {
            'codeActionLiteralSupport': {
              'codeActionKind': {
                'valueSet': ['quickfix', 'refactor', 'source'],
              },
            },
          },
        },
      },
    });
    capabilities = result is Map && result['capabilities'] is Map
        ? (result['capabilities'] as Map).cast<String, dynamic>()
        : {};
    if ((capabilities['positionEncoding'] ?? 'utf-16') != 'utf-16') {
      throw const ProtocolError('语言服务器不支持 UTF-16 文本位置');
    }
    await peer.notify('initialized', {});
    await peer.notify('workspace/didChangeConfiguration', {
      'settings': configuration['settings'] ?? {},
    });
  }

  void queueSync(DocumentModel doc) {
    _timers.remove(doc)?.cancel();
    _timers[doc] = Timer(const Duration(milliseconds: 100), () {
      _timers.remove(doc);
      unawaited(sync(doc).catchError((Object e) => model.log('$id: $e')));
    });
  }

  Future<void> sync(DocumentModel doc) {
    _timers.remove(doc)?.cancel();
    final work = _syncTail.then((_) async {
      if (!active ||
          doc.isClosed ||
          !doc.languageSyncEligible ||
          doc.phase != DocumentPhase.ready)
        return;
      final uri = scope.documentUri(doc.key.path);
      final version = doc.version,
          savedVersion = doc.savedVersion,
          text = doc.text;
      final previous = _opened[doc];
      if (previous == null) {
        if (openClose) {
          await peer.notify('textDocument/didOpen', {
            'textDocument': {
              'uri': uri,
              'languageId': languageIdForPath(doc.key.path),
              'version': version,
              'text': text,
            },
          });
        }
        _opened[doc] = _SyncedDocument(version, savedVersion, text);
        return;
      }
      if (previous.version != version) {
        if (changeKind != 0) {
          final lines = previous.text.split('\n');
          await peer.notify('textDocument/didChange', {
            'textDocument': {'uri': uri, 'version': version},
            'contentChanges': [
              {
                if (changeKind == 2)
                  'range': {
                    'start': {'line': 0, 'character': 0},
                    'end': {
                      'line': lines.length - 1,
                      'character': lines.last
                          .replaceFirst(RegExp(r'\r$'), '')
                          .length,
                    },
                  },
                'text': text,
              },
            ],
          });
        }
        previous.version = version;
        previous.text = text;
      }
      if (previous.savedVersion != savedVersion && savedVersion >= 0) {
        final sync = capabilities['textDocumentSync'];
        final save = sync is Map ? sync['save'] : null;
        if (save != null && save != false) {
          await peer.notify('textDocument/didSave', {
            'textDocument': {'uri': uri},
            if (save is Map && save['includeText'] == true)
              'text': doc.baseText,
          });
        }
      }
      previous.savedVersion = savedVersion;
    });
    _syncTail = work.then<void>((_) {}, onError: (Object _) {});
    return work;
  }

  Future<void> detach(DocumentModel doc) async {
    _timers.remove(doc)?.cancel();
    await _syncTail;
    if (_opened.remove(doc) != null && active && openClose) {
      await peer.notify('textDocument/didClose', {
        'textDocument': {'uri': scope.documentUri(doc.key.path)},
      });
    }
  }

  Future<Object?> _serverRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    switch (method) {
      case 'workspace/configuration':
        final settings = configuration['settings'] as Map? ?? {};
        return [
          for (final item in params['items'] as List? ?? [])
            item is Map && item['section'] is String
                ? (item['section'] as String)
                      .split('.')
                      .fold<Object?>(
                        settings,
                        (value, key) => value is Map ? value[key] : null,
                      )
                : settings,
        ];
      case 'workspace/workspaceFolders':
        return [
          {'uri': scope.workspaceUri, 'name': scope.path.split('/').last},
        ];
      case 'window/workDoneProgress/create':
        return null;
      case 'workspace/applyEdit':
        try {
          if (!active || params['edit'] is! Map || model.reviewEdit == null)
            return {'applied': false, 'failureReason': '修改预览不可用'};
          final plan = await model.prepareEdit(
            this,
            params['edit'] as Map,
            model.versions(),
          );
          if (!await model.reviewEdit!(plan))
            return {'applied': false, 'failureReason': '用户取消'};
          if (!plan.applied) plan.apply();
          return {'applied': true};
        } on Object catch (e) {
          return {'applied': false, 'failureReason': '$e'};
        }
      default:
        throw ProtocolError('不支持服务端请求：$method');
    }
  }

  void _notification(String method, Map<String, dynamic> params) {
    if (!active) return;
    if (method == 'textDocument/publishDiagnostics') {
      final path = scope.pathFromUri('${params['uri']}');
      if (path == null) return;
      final key = DocumentKey(model.ws.serverId, scope.root, path);
      final doc = model.ws.documents.find(scope.root, path);
      if (doc != null) {
        if (params['version'] is int && params['version'] != doc.version)
          return;
        if (params['version'] == null && _opened[doc]?.version != doc.version)
          return;
      }
      final problems = model._problems.putIfAbsent(id, () => {});
      final items = <DevelopmentDiagnostic>[];
      var count = problems.entries
          .where((e) => e.key != key)
          .fold(0, (sum, e) => sum + e.value.length);
      for (final raw in (params['diagnostics'] as List? ?? []).take(2000)) {
        if (count >= 2000) break;
        if (raw is! Map || raw['range'] is! Map) continue;
        final start = (raw['range'] as Map)['start'];
        if (start is! Map ||
            start['line'] is! int ||
            start['character'] is! int ||
            start['line'] < 0 ||
            start['character'] < 0)
          continue;
        count++;
        items.add(
          DevelopmentDiagnostic(
            key,
            (start['line'] as num?)?.toInt() ?? 0,
            (start['character'] as num?)?.toInt() ?? 0,
            (raw['severity'] as num?)?.toInt() ?? 1,
            '${raw['message'] ?? ''}',
            '${raw['source'] ?? configuration['id']}',
            raw.cast<String, dynamic>(),
          ),
        );
      }
      if (items.isEmpty) {
        problems.remove(key);
      } else {
        problems[key] = items;
      }
      model._notify();
    } else if (method == 'window/logMessage' ||
        method == 'window/showMessage') {
      model.log('$id: ${params['message']}');
    }
  }

  void close() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    peer.close();
  }
}
