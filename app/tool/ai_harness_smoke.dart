// Exercises the signed, packaged local agent through the real TLS wire client.
// All files, state and model responses are synthetic and sandboxed.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/state/local_agent.dart';
import 'package:aurora_wire/aurora_wire.dart';

import '../test/support/test_pdf.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<Uint8List> download(Link link, String id) async {
  final stream = await link.open('ai.attach.download', {'id': id});
  final bytes = BytesBuilder();
  try {
    await stream.response();
    while (true) {
      final frame = await stream.read();
      if (frame == null || frame.type == typeEnd) break;
      require(frame.type == typeData, 'Unexpected attachment frame');
      bytes.add(frame.payload);
    }
    return bytes.takeBytes();
  } finally {
    stream.reset();
  }
}

Future<void> main(List<String> args) async {
  require(args.length == 1, 'Pass a new dedicated sandbox directory');
  final sandbox = Directory(args.single).absolute;
  require(!sandbox.existsSync(), 'Sandbox already exists');
  await sandbox.create(recursive: true);
  final project = await Directory('${sandbox.path}/project').create();
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJZkAAAAASUVORK5CYII=',
  );
  final pdf = buildTestPdf(pages: 1, extra: 'Harness wire fixture');
  await File('${project.path}/chart.png').writeAsBytes(png);
  await File('${project.path}/report.pdf').writeAsBytes(pdf);
  final manager = LocalAgent();
  final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  Link? link;
  OpStream? events;
  var requests = 0, answered = false;
  Object? fixtureError;
  model.listen((request) async {
    try {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      require(
        request.headers.value('user-agent') ==
                'opencode/stable/1.4.0/opencode' &&
            request.headers.value('x-opencode-client') != null,
        'Compatibility identity missing',
      );
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      final tools = body['tools'] as List? ?? const [];
      Map<String, Object?> delta = {'content': 'harness fixture complete'};
      if (tools.isNotEmpty) {
        requests++;
        require(body['reasoning_effort'] == 'max', 'Custom effort changed');
        final names = tools.map((t) => t['function']['name']).toSet();
        require(!names.contains('shell'), 'Disabled shell was declared');
        require(
          names.containsAll(['read', 'apply_patch', 'question']),
          'Harness tools missing',
        );
        Map<String, Object?> call(int index, String name, Object args) => {
          'index': index,
          'id': 'step-$requests-$index',
          'type': 'function',
          'function': {'name': name, 'arguments': jsonEncode(args)},
        };
        if (requests == 1) {
          delta = {
            'tool_calls': [
              call(0, 'read', {'path': 'chart.png'}),
              call(1, 'read', {'path': 'report.pdf'}),
              call(2, 'apply_patch', {
                'patch': '*** Begin Patch\n*** Add File: result.txt\n+verified harness\n*** End Patch',
              }),
            ],
          };
        } else {
          final serialized = jsonEncode(body);
          require(
            serialized.contains(base64Encode(png)),
            'Image bytes missing',
          );
          require(serialized.contains(base64Encode(pdf)), 'PDF bytes missing');
          if (requests == 2) {
            await File('${project.path}/chart.png')
                .writeAsString('workspace changed');
            delta = {
              'tool_calls': [
                call(0, 'question', {
                  'questions': [
                    {
                      'question': 'Finish fixture?',
                      'options': [
                        {'label': 'Continue'},
                      ],
                    },
                  ],
                }),
              ],
            };
          } else {
            require(
              requests == 3 && answered && serialized.contains('Continue'),
              'Answer not delivered',
            );
          }
        }
      }
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {'delta': delta, 'finish_reason': delta.containsKey('tool_calls') ? 'tool_calls' : 'stop'},
          ],
        })}\n\ndata: [DONE]\n\n',
      );
    } on Object catch (error) {
      fixtureError = error;
      request.response.statusCode = 500;
    } finally {
      await request.response.close();
    }
  });
  Future<Link> connect() async {
    final target = await manager.start('${sandbox.path}/state');
    final address = splitHostPort(target.addrs.single)!;
    return Link.dial(
      Endpoint(
        host: address.$1,
        port: address.$2,
        pin: target.pin,
        token: target.token,
      ),
    );
  }

  try {
    link = await connect();
    require(
      link.server.caps.toSet().containsAll(['ai.capabilities', 'ai.question']),
      'Packaged agent lacks harness capabilities',
    );
    final folder = manager.locate(project.path);
    events = await link.open('ai.stream');
    await events.response();
    final started = await link.call('ai.run', {
      'root': folder.root,
      'workdir': folder.path,
      'agent': 'build',
      'permission_mode': 'auto',
      'text': 'Run synthetic harness fixture',
      'provider': {
        'protocol': 'openai-chat',
        'model': 'fixture',
        'base_url': 'http://127.0.0.1:${model.port}/v1',
        'proxy_mode': 'direct',
        'reasoning_effort': 'max',
        'capabilities': {'shell': false},
      },
    }) as Map;
    final sid = started['session']['id'] as String;
    while (true) {
      final frame = await events.read().timeout(const Duration(seconds: 30));
      require(frame != null && frame.isJson, 'Event stream ended');
      final event = frame!.json() as Map;
      if (event['session_id'] != sid) continue;
      require(
        !jsonEncode(event).contains(base64Encode(png)),
        'Media bytes leaked into events',
      );
      require(
        event['type'] != 'session.error',
        'Agent failure: ${fixtureError ?? event['error']}',
      );
      if (event['type'] == 'question.ask') {
        final pending =
            await link.call('ai.question', {'session_id': sid}) as Map;
        require(
          pending['question']['id'] == event['question']['id'],
          'Pending question not recoverable',
        );
        answered = true;
        await link.call('ai.question', {
          'session_id': sid,
          'id': event['question']['id'],
          'answers': [
            ['Continue'],
          ],
        });
      }
      if (event['type'] == 'session.status' && event['status'] == 'idle') break;
    }
    require(
      requests == 3 && fixtureError == null,
      'Fixture sequence failed: $fixtureError',
    );
    require(
      await File('${project.path}/result.txt').readAsString() ==
          'verified harness\n',
      'Patch did not commit',
    );
    final history = await link.call('ai.get', {'id': sid}) as Map;
    require(
      !jsonEncode(history).contains(base64Encode(png)),
      'History persisted base64',
    );
    final attachments = [
      for (final message in history['session']['messages'] as List)
        for (final part in message['parts'] as List? ?? const [])
          ...part['attachments'] as List? ?? const [],
    ];
    require(attachments.length == 2, 'Tool attachment references missing');
    events.reset();
    events = null;
    await link.close();
    await manager.stop();
    link = await connect();
    await link.call('ai.get', {'id': sid});
    for (final attachment in attachments) {
      final bytes = await download(link, attachment['attachment_id'] as String);
      require(
        base64Encode(bytes) ==
            base64Encode(attachment['mime'] == 'image/png' ? png : pdf),
        'Restart did not preserve captured media',
      );
    }
    stdout.writeln('SIGNED_AGENT_TLS_HARNESS_MEDIA_PATCH_QUESTION_RESTART_OK');
  } finally {
    events?.reset();
    await link?.close();
    await manager.stop();
    await model.close(force: true);
  }
}
