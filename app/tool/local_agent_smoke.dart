// Headless real-client test. All state and files must live in an explicit sandbox.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:aurora/state/local_agent.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) throw StateError('Pass a dedicated test sandbox directory');
  final sandbox = Directory(args.single).absolute;
  await sandbox.create(recursive: true);
  final project = await Directory('${sandbox.path}\\项目 空格').create();
  final manager = LocalAgent();
  Link? link;
  HttpServer? models;
  try {
    final target = await manager.start('${sandbox.path}\\state');
    final hp = splitHostPort(target.addrs.single)!;
    link = await Link.dial(Endpoint(host: hp.$1, port: hp.$2, pin: target.pin, token: target.token));
    if (link.server.kind != 'local' || link.server.platform != 'windows') throw StateError('wrong agent kind/platform');
    final folder = manager.locate(project.path);
    final file = {'root': folder.root, 'path': '${folder.path}/fixture.txt'};
    await link.call('fs.write', {...file, 'content': 'synthetic 本机内容', 'create': true});
    final read = await link.call('fs.read', file) as Map;
    if (read['content'] != 'synthetic 本机内容') throw StateError('file round-trip mismatch');
    models = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    models.listen((req) async {
      if (req.headers.value('authorization') != 'Bearer fixture-key') { req.response.statusCode = 401; }
      else { req.response.headers.contentType = ContentType.json; req.response.write(jsonEncode({'data': [{'id': 'fixture-model'}]})); }
      await req.response.close();
    });
    final catalog = await link.call('ai.models', {'provider': {'base_url': 'http://127.0.0.1:${models.port}/v1', 'protocol': 'openai-chat', 'api_key': 'fixture-key'}}) as Map;
    if ((catalog['models'] as List).single['id'] != 'fixture-model') throw StateError('model discovery mismatch');
    await link.call('session.create', {'name':'fixture','root':folder.root,'path':folder.path,'no_profile':true});
    final terminal = await Terminal.attach(link, 'fixture');
    var recent = '';
    final output = terminal.output.listen((bytes) {
      recent += String.fromCharCodes(bytes);
      if (recent.contains('\x1b[6n')) { unawaited(terminal.write([27,91,49,59,49,82])); recent = ''; }
      if (recent.length > 2048) recent = recent.substring(recent.length - 2048);
    });
    final marker = '${project.path}\\terminal.txt'.replaceAll("'", "''");
    await terminal.write(utf8.encode("[IO.File]::WriteAllText('$marker', 'terminal-fixture'); exit\r"));
    if (await terminal.done.timeout(const Duration(seconds: 15)) != TerminalEnd.exit) throw StateError('terminal did not exit normally');
    await output.cancel();
    final markerResult = await link.call('fs.read', {'root':folder.root,'path':'${folder.path}/terminal.txt'}) as Map;
    if (markerResult['content'] != 'terminal-fixture') throw StateError('ConPTY command was not executed');
    await manager.stop();
    stdout.writeln('LOCAL_AGENT_SIGNED_CLIENT_TLS_FILES_MODELS_CONPTY_EXIT_OK');
  } finally {
    await link?.close();
    await models?.close(force: true);
    await manager.stop();
  }
}
