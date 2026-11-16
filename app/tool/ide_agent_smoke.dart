// Runs against the signed packaged Windows agent with only synthetic files.
// dart run tool/ide_agent_smoke.dart NEW_SANDBOX EXPECTED_VERSION
import 'dart:convert';
import 'dart:io';

import 'package:aurora/kernel/file_text.dart';
import 'package:aurora/state/local_agent.dart';
import 'package:aurora_wire/aurora_wire.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> rejected(Future<Object?> Function() action, String label) async {
  try {
    await action();
  } on OpError {
    stdout.writeln('PASS $label rejected');
    return;
  }
  throw StateError('$label was accepted');
}

Future<void> initializeTool(
  Link link,
  Map<String, Object?> scope,
  bool dap,
) async {
  final stream = await link.open(dap ? 'dap.start' : 'lsp.start', {
    ...scope,
    'id': 'dart',
  });
  try {
    final ready = await stream.response() as Map;
    await stream.sendData(
      utf8.encode(
        jsonEncode(
          dap
              ? {
                  'seq': 1,
                  'type': 'request',
                  'command': 'initialize',
                  'arguments': {
                    'adapterID': 'dart',
                    'linesStartAt1': true,
                    'columnsStartAt1': true,
                    'pathFormat': 'path',
                  },
                }
              : {
                  'jsonrpc': '2.0',
                  'id': 1,
                  'method': 'initialize',
                  'params': {
                    'processId': null,
                    'rootUri': ready['workspaceUri'],
                    'capabilities': <String, Object?>{},
                  },
                },
        ),
      ),
    );
    while (true) {
      final frame = await stream.read().timeout(const Duration(seconds: 60));
      require(frame != null, 'Development process ended before initialize');
      final message = jsonDecode(utf8.decode(frame!.payload)) as Map;
      require(
        message['type'] != 'error',
        'Development bridge failed: $message',
      );
      if (frame.type != typeData) continue;
      if (dap && message['request_seq'] == 1) {
        require(message['success'] == true, 'DAP initialize failed');
        break;
      }
      if (!dap && message['id'] == 1) {
        require(message['result'] is Map, 'LSP initialize failed');
        break;
      }
    }
    stdout.writeln('PASS real Dart ${dap ? 'DAP' : 'LSP'} initialize');
  } finally {
    stream.reset();
  }
}

Future<void> main(List<String> args) async {
  require(args.length == 2, 'Pass a new sandbox and expected agent version');
  require(
    Platform.environment['AURORA3_TRUST_KEY']?.isNotEmpty != true,
    'Use the production public key',
  );
  final sandbox = Directory(args[0]).absolute;
  require(!await sandbox.exists(), 'Sandbox already exists');
  final project = await Directory('${sandbox.path}/项目 空格')
      .create(recursive: true);
  final manager = LocalAgent();
  Link? connection;
  try {
    final target = await manager.start('${sandbox.path}/state');
    final hp = splitHostPort(target.addrs.single)!;
    final link = connection = await Link.dial(
      Endpoint(host: hp.$1, port: hp.$2, pin: target.pin, token: target.token),
    );
    require(link.server.version == args[1], 'Wrong packaged agent version');
    for (final cap in [
      'fs.text',
      'fs.commit',
      'fs.refactor',
      'fs.replace.preview',
      'devtools.configure',
      'task.run',
      'lsp.start',
      'dap.start',
      'ai.extensions',
      'ai.mcp.probe',
      'ai.propose',
    ]) {
      require(link.server.caps.contains(cap), 'Missing capability: $cap');
    }
    stdout.writeln('PASS signed agent ${link.server.version} IDE capabilities');
    final folder = manager.locate(project.path);
    final scope = <String, Object?>{'root': folder.root, 'path': folder.path};
    String path(String name) => '${folder.path}/$name';
    FileTextOperation operation() => FileTextOperation(active: () => true);
    final created = await operation().commit(link, [
      FileTextChange(
        root: folder.root,
        path: path('utf16.txt'),
        etag: null,
        text: '中文 alpha\n',
        encoding: 'utf-16le-bom',
      ),
      FileTextChange(
        root: folder.root,
        path: path('utf8.txt'),
        etag: null,
        text: 'first alpha\n',
      ),
    ]);
    final bytes = await File('${project.path}/utf16.txt').readAsBytes();
    require(bytes[0] == 255 && bytes[1] == 254, 'UTF-16 BOM missing');
    final text = await operation().read(link, folder.root, path('utf16.txt'));
    require(text['content'] == '中文 alpha\n', 'UTF-16 decoding mismatch');
    final preview = await operation().replace(link, 'unsaved alpha\n', {
      'query': 'alpha',
      'replacement': 'beta',
      'case': true,
    });
    require(
      preview['content'] == 'unsaved beta\n' && preview['replacements'] == 1,
      'Unsaved replacement preview mismatch',
    );
    stdout.writeln('PASS encoded batch create/read and unsaved replacement');

    await File('${project.path}/utf8.txt').writeAsString('external change\n');
    await rejected(
      () => operation().commit(link, [
        FileTextChange(
          root: folder.root,
          path: path('utf16.txt'),
          etag: created[0]['etag'] as String,
          text: 'must not land',
        ),
        FileTextChange(
          root: folder.root,
          path: path('utf8.txt'),
          etag: created[1]['etag'] as String,
          text: 'must not land',
        ),
      ]),
      'stale multi-file transaction',
    );
    final unchanged = await operation().read(
      link,
      folder.root,
      path('utf16.txt'),
    );
    require(unchanged['content'] == '中文 alpha\n', 'Partial commit occurred');
    require(
      await File('${project.path}/utf8.txt').readAsString() ==
          'external change\n',
      'External change was overwritten',
    );
    final external = await operation().read(
      link,
      folder.root,
      path('utf8.txt'),
    );
    await operation().commit(link, [
      FileTextChange(
        root: folder.root,
        path: path('utf16.txt'),
        etag: unchanged['etag'] as String,
        text: '中文 beta\n',
        encoding: 'utf-16le-bom',
      ),
      FileTextChange(
        root: folder.root,
        path: path('utf8.txt'),
        etag: external['etag'] as String,
        text: 'second beta\n',
      ),
    ]);
    require(
      (await operation().read(
                link,
                folder.root,
                path('utf16.txt'),
              ))['content'] ==
              '中文 beta\n' &&
          await File('${project.path}/utf8.txt').readAsString() ==
              'second beta\n',
      'Versioned batch update mismatch',
    );
    stdout.writeln('PASS atomic conflict and versioned batch update');

    await File('${project.path}/task.dart').writeAsString(
      "void main() { print('fixture.dart:2:3: warning fixture'); }\n",
    );
    final initial = await link.call('devtools.config', scope) as Map;
    final config = {
      'version': 1,
      'languageServers': [
        {
          'id': 'dart',
          'command': [
            Platform.resolvedExecutable,
            'language-server',
            '--protocol=lsp',
          ],
          'languages': ['dart'],
        },
      ],
      'debug': [
        {
          'id': 'dart',
          'command': [Platform.resolvedExecutable, 'debug_adapter'],
          'request': 'launch',
        },
      ],
      'tasks': [
        {
          'id': 'fixture',
          'command': [Platform.resolvedExecutable, 'task.dart'],
          'timeoutSeconds': 30,
        },
      ],
    };
    final saved = await link.call('devtools.configure', {
      ...scope,
      'if_match': initial['etag'],
      'config': config,
    }) as Map;
    await rejected(
      () => link.call('devtools.configure', {
        ...scope,
        'if_match': initial['etag'],
        'config': config,
      }),
      'stale development configuration',
    );
    final versionedScope = {...scope, 'if_match': saved['etag']};
    final task = await link.open('task.run', {
      ...versionedScope,
      'id': 'fixture',
    });
    var output = '', complete = false, problem = false;
    try {
      await task.response();
      while (true) {
        final frame = await task.read().timeout(const Duration(seconds: 45));
        if (frame == null || frame.type == typeEnd) break;
        final event = jsonDecode(utf8.decode(frame.payload)) as Map;
        if (event['type'] == 'output') output += event['text'] as String;
        if (event['type'] == 'problem') {
          final p = event['problem'] as Map;
          problem =
              p['file'] == 'fixture.dart' &&
              p['line'] == 2 &&
              p['column'] == 3 &&
              p['severity'] == 'warning';
        }
        if (event['type'] == 'complete') complete = event['code'] == 0;
      }
    } finally {
      task.reset();
    }
    require(
      complete && problem && output.contains('warning fixture'),
      'Task result mismatch',
    );
    stdout.writeln('PASS task output, problem location and exit code');
    await initializeTool(link, versionedScope, false);
    await initializeTool(link, versionedScope, true);

    await File('${project.path}/instructions.md')
        .writeAsString('Synthetic IDE smoke instructions.');
    final skill = File('${project.path}/.aurora/skills/fixture/SKILL.md');
    await skill.parent.create(recursive: true);
    await skill.writeAsString(
      '---\ndescription: Synthetic fixture skill\n---\nFixture only.\n',
    );
    final aiScope = {'root': folder.root, 'workdir': folder.path};
    final extensions = await link.call('ai.extensions', aiScope) as Map;
    final aiConfig = Map<String, dynamic>.from(extensions['config'] as Map);
    aiConfig['instructions'] = ['instructions.md'];
    aiConfig['budget'] = {
      'steps': 3,
      'seconds': 30,
      'tokens': 2048,
      'outputBytes': 4096,
    };
    final updated = await link.call('ai.extensions', {
      ...aiScope,
      'config': aiConfig,
      'if_match': extensions['etag'],
    }) as Map;
    require(
      (updated['instructions'] as List).any(
            (item) => item['text'] == 'Synthetic IDE smoke instructions.',
          ) &&
          (updated['skills'] as List).any((item) => item['name'] == 'fixture'),
      'AI instruction/skill discovery failed',
    );
    await rejected(
      () => link.call('ai.extensions', {
        ...aiScope,
        'config': aiConfig,
        'if_match': extensions['etag'],
      }),
      'stale AI configuration',
    );
    final reread = await link.call('ai.extensions', aiScope) as Map;
    require(
      (reread['config']['budget'] as Map)['steps'] == 3 &&
          reread['etag'] == updated['etag'],
      'AI configuration did not persist',
    );
    stdout.writeln('PASS AI instructions, skills and budget persistence');
    stdout.writeln(
      'IDE_SIGNED_AGENT_TEXT_TRANSACTION_TASK_LSP_DAP_EXTENSIONS_OK',
    );
  } finally {
    await connection?.close();
    await manager.stop();
  }
}
