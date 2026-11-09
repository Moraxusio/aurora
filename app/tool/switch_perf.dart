// CMD-compatible host for a real Windows PROFILE run. All server state is a
// throwaway normal-user WSL agent; never install, stop or upgrade a real one.
//   dart run tool/switch_perf.dart OUT.json [TARGET.dart]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty) throw ArgumentError('OUT.json is required');
  final app = Directory.current;
  final repo = app.parent;
  final tempBase = '${Platform.environment['LOCALAPPDATA']}\\Temp\\aurora3';
  final work = await Directory(tempBase).createTemp('switch-profile-');
  const go = r'go';
  const flutter = r'flutter';
  final binary = '${work.path}\\agent';
  Process? peer;
  int result = 1;
  try {
    final build = await Process.run(
      go,
      [
        'build',
        '-trimpath',
        '-ldflags',
        '-s -w -X main.Version=3.3.0',
        '-o',
        binary,
        './cmd/aurora3-agent',
      ],
      workingDirectory: '${repo.path}\\agent',
      environment: {
        'GOTOOLCHAIN': 'local',
        'GOPROXY': 'off',
        'CGO_ENABLED': '0',
        'GOOS': 'linux',
        'GOARCH': 'amd64',
      },
    );
    if (build.exitCode != 0) {
      throw StateError('agent build failed: ${build.stderr}');
    }
    String wsl(String path) =>
        '/mnt/${path[0].toLowerCase()}${path.substring(2).replaceAll('\\', '/')}';
    peer = await Process.start('wsl', [
      '-d',
      'Ubuntu-24.04',
      '--',
      'bash',
      wsl('${repo.path}\\agent\\tools\\ui-agent.sh'),
      wsl(binary),
    ]);
    peer.stderr.transform(utf8.decoder).listen(stderr.write);
    final lines = peer.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    final ep = jsonDecode(
      await lines.first.timeout(const Duration(seconds: 30)),
    ) as Map;
    final environment = Map<String, String>.from(Platform.environment)
      ..['AURORA3_INSTANCE_SCOPE'] = 'integration-$pid'
      ..remove('AURORA3_AGENT_DIR')
      ..remove('AURORA3_TRUST_KEY');
    final test = await Process.start(
      flutter,
      [
        'drive',
        '--profile',
        '-d',
        'windows',
        '--driver=test_driver/perf_driver.dart',
        '--target=${args.length > 1 ? args[1] : 'integration_test/switch_perf_test.dart'}',
        '--dart-define=AURORA3_UI_ADDR=${ep['addr']}',
        '--dart-define=AURORA3_UI_PIN=${ep['pin']}',
        '--dart-define=AURORA3_UI_TOKEN=${ep['token']}',
        '--dart-define=AURORA3_PERF_OUT=${File(args[0]).absolute.path}',
        '--dart-define=AURORA3_UI_SENDKEYS=${app.path}\\tool\\sendkeys.ps1',
      ],
      workingDirectory: app.path,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: true,
    );
    await Future.wait([
      stdout.addStream(test.stdout),
      stderr.addStream(test.stderr),
    ]);
    result = await test.exitCode;
  } finally {
    if (peer != null) {
      await peer.stdin.close();
      await peer.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          peer!.kill();
          return -1;
        },
      );
    }
    await work.delete(recursive: true);
  }
  exitCode = result;
}
