// Headless real-client test. All state and files must live in an explicit sandbox.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora/state/local_agent.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw StateError('Pass a dedicated test sandbox directory');
  }
  final sandbox = Directory(args.single).absolute;
  await sandbox.create(recursive: true);
  final project = await Directory('${sandbox.path}\\项目 空格').create();
  final manager = LocalAgent();
  Link? link;
  HttpServer? models;
  ServerSocket? node;
  final nodeSockets = <Socket>{};
  var nodeHits = 0;
  try {
    final target = await manager.start('${sandbox.path}\\state');
    final hp = splitHostPort(target.addrs.single)!;
    link = await Link.dial(
      Endpoint(host: hp.$1, port: hp.$2, pin: target.pin, token: target.token),
    );
    if (link.server.kind != 'local' || link.server.platform != 'windows') {
      throw StateError('wrong agent kind/platform');
    }
    for (final cap in [
      'sys.metrics',
      'proc.list',
      'gpu.info',
      'proxy.set',
      'ai.network',
      'session.network',
    ]) {
      if (!link.server.caps.contains(cap)) {
        throw StateError('missing local capability: $cap');
      }
    }
    final metrics = await link.call('sys.metrics') as Map;
    if (metrics['platform'] != 'windows' ||
        (metrics['memory'] as Map)['MemTotal'] <= 0) {
      throw StateError('native metrics missing');
    }
    final processes = await link.call('proc.list', {'limit': 5}) as Map;
    if ((processes['processes'] as List).isEmpty) {
      throw StateError('process counters missing');
    }
    final folder = manager.locate(project.path);
    final file = {'root': folder.root, 'path': '${folder.path}/fixture.txt'};
    await link.call('fs.write', {
      ...file,
      'content': 'synthetic 本机内容',
      'create': true,
    });
    final read = await link.call('fs.read', file) as Map;
    if (read['content'] != 'synthetic 本机内容') {
      throw StateError('file round-trip mismatch');
    }
    models = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    models.listen((req) async {
      if (req.headers.value('authorization') != 'Bearer fixture-key') {
        req.response.statusCode = 401;
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'data': [
              {'id': 'fixture-model'},
            ],
          }),
        );
      }
      await req.response.close();
    });
    final catalog = await link.call('ai.models', {
      'provider': {
        'base_url': 'http://127.0.0.1:${models.port}/v1',
        'protocol': 'openai-chat',
        'api_key': 'fixture-key',
      },
    }) as Map;
    if ((catalog['models'] as List).single['id'] != 'fixture-model') {
      throw StateError('model discovery mismatch');
    }
    // Synthetic unencrypted VLESS node: accepts only this fixture hostname,
    // returns a model catalog locally, and never dials any external address.
    node = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    node.listen((socket) {
      nodeSockets.add(socket);
      var bytes = <int>[];
      var answered = false;
      socket.listen(
        (chunk) {
          if (answered) return;
          bytes.addAll(chunk);
          if (bytes.length < 23) return;
          if (bytes[0] != 0 ||
              bytes[17] != 0 ||
              bytes[18] != 1 ||
              bytes[21] != 2) {
            throw StateError('unexpected fixture VLESS header');
          }
          final end = 23 + bytes[22];
          if (bytes.length < end) return;
          if (ascii.decode(bytes.sublist(23, end)) !=
              'models.fixture.invalid') {
            throw StateError('fixture attempted an external target');
          }
          final request = latin1.decode(bytes.sublist(end));
          if (!request.contains('\r\n\r\n')) return;
          if (!request.contains('Bearer fixture-key')) {
            throw StateError('fixture API credential missing');
          }
          answered = true;
          nodeHits++;
          final body = jsonEncode({
            'data': [
              {'id': 'agent-fixture-model'},
            ],
          });
          socket.add([
            0,
            0,
            ...ascii.encode(
              'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body',
            ),
          ]);
          unawaited(socket.flush().then((_) => socket.close()));
        },
        onDone: () {
          nodeSockets.remove(socket);
          socket.destroy();
        },
      );
    });
    await link.call('proxy.set', {
      'node': {
        'name': 'fixture-node',
        'proto': 'vless',
        'host': '127.0.0.1',
        'port': node.port,
        'secret': '00112233-4455-6677-8899-aabbccddeeff',
        'tls': {'enabled': false},
      },
    });
    final provider = {
      'base_url': 'http://models.fixture.invalid/v1',
      'protocol': 'openai-chat',
      'api_key': 'fixture-key',
      'proxy_mode': 'agent',
    };
    Future<void> checkAgentModels() async {
      final result =
          await link!.call('ai.models', {'provider': provider}) as Map;
      if ((result['models'] as List).single['id'] != 'agent-fixture-model') {
        throw StateError('agent node was bypassed');
      }
    }

    await checkAgentModels();
    for (final mode in ['system', 'agent', 'direct']) {
      await link.call('session.create', {
        'name': mode,
        'root': folder.root,
        'path': folder.path,
        'no_profile': true,
        'proxy_mode': mode,
      });
      final existing = await link.call('session.create', {
        'name': mode,
        'proxy_mode': mode == 'direct' ? 'system' : 'direct',
      }) as Map;
      if (existing['existed'] != true || existing['proxy_mode'] != mode) {
        throw StateError('existing terminal changed its route');
      }
      final terminal = await Terminal.attach(link, mode);
      var recent = '';
      final output = terminal.output.listen((bytes) {
        recent += String.fromCharCodes(bytes);
        if (recent.contains('\x1b[6n')) {
          unawaited(terminal.write([27, 91, 49, 59, 49, 82]));
          recent = '';
        }
        if (recent.length > 2048) {
          recent = recent.substring(recent.length - 2048);
        }
      });
      final marker = '${project.path}\\terminal-$mode.txt'.replaceAll(
        "'",
        "''",
      );
      await terminal.write(
        utf8.encode(
          "[IO.File]::WriteAllText('$marker', (\$env:HTTP_PROXY + '|' + \$env:HTTPS_PROXY + '|' + \$env:ALL_PROXY + '|' + \$env:NO_PROXY)); exit\r",
        ),
      );
      if (await terminal.done.timeout(const Duration(seconds: 15)) !=
          TerminalEnd.exit) {
        throw StateError('terminal did not exit normally');
      }
      await output.cancel();
      final markerResult = await link.call('fs.read', {
        'root': folder.root,
        'path': '${folder.path}/terminal-$mode.txt',
      }) as Map;
      final actual = markerResult['content'] as String;
      if (mode == 'direct' && actual != '|||') {
        throw StateError('direct terminal inherited proxy variables');
      }
      if (mode == 'system' &&
          actual !=
              'http://127.0.0.1:18101|http://127.0.0.1:18102|socks5://127.0.0.1:18103|system.fixture') {
        throw StateError('system terminal did not inherit fixture routes');
      }
      if (mode == 'agent' &&
          (!actual.contains('aurora:') ||
              actual.contains('18101') ||
              actual.contains('18103'))) {
        throw StateError('agent terminal mixed routes');
      }
    }
    await link.call('agent.service', {'id': 'proxy', 'enabled': false});
    try {
      await checkAgentModels();
      throw StateError('disabled proxy silently fell back');
    } on OpError {
      /* expected */
    }
    try {
      await link.call('session.create', {
        'name': 'unavailable',
        'proxy_mode': 'agent',
        'no_profile': true,
      });
      throw StateError('disabled proxy started a terminal');
    } on OpError {
      /* expected */
    }
    await link.call('agent.service', {'id': 'monitor', 'enabled': false});
    final stateFile = File('${sandbox.path}\\state\\local-agent.json');
    final state = jsonDecode(await stateFile.readAsString()) as Map;
    if (state.keys.any((k) => k != 'services' && k != 'proxy')) {
      throw StateError('bootstrap identity persisted');
    }
    final proxyPort = (state['proxy'] as Map)['port'] as int;
    await link.close();
    await manager.stop();
    final restarted = await manager.start('${sandbox.path}\\state');
    if (restarted.token == target.token) {
      throw StateError('bootstrap token survived restart');
    }
    final next = splitHostPort(restarted.addrs.single)!;
    link = await Link.dial(
      Endpoint(
        host: next.$1,
        port: next.$2,
        pin: restarted.pin,
        token: restarted.token,
      ),
    );
    final services = await link.call('agent.services') as Map;
    for (final id in ['proxy', 'monitor']) {
      if ((services['services'] as List).firstWhere(
            (s) => s['id'] == id,
          )['enabled'] !=
          false) {
        throw StateError('service switch lost on restart');
      }
      await link.call('agent.service', {'id': id, 'enabled': true});
    }
    await checkAgentModels();
    if (nodeHits != 2) throw StateError('proxy did not retain its node');
    await manager.stop();
    try {
      final s = await Socket.connect(
        '127.0.0.1',
        proxyPort,
        timeout: const Duration(seconds: 1),
      );
      s.destroy();
      throw StateError('proxy listener survived agent exit');
    } on SocketException {
      /* expected */
    }
    stdout.writeln(
      'LOCAL_AGENT_SIGNED_TLS_MONITOR_PROXY_ROUTES_PERSISTENCE_CONPTY_EXIT_OK',
    );
  } finally {
    await link?.close();
    await models?.close(force: true);
    for (final s in nodeSockets.toList()) {
      s.destroy();
    }
    await node?.close();
    await manager.stop();
  }
}
