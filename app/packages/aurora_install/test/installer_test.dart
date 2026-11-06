// The installer's own logic against a scripted remote: which commands it
// runs, how it reads the agent's output, and what it refuses.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_install/aurora_install.dart';
import 'package:test/test.dart';

/// Answers commands from a script and records them.
class FakeRemote implements Remote {
  final List<String> commands = [];
  final List<Uint8List?> stdins = [];
  String uname = 'Linux\nx86_64\n1000\nalice\nsudo-pass\n';
  String installOut = '';
  String installErr = '';
  int installCode = 0;
  bool uploadFails = false;
  int uploaded = -1;
  String? uploadPath;
  bool removed = false;

  @override
  Future<RunResult> run(String command, {Uint8List? stdin, void Function(String line)? onLine}) async {
    commands.add(command);
    stdins.add(stdin);
    if (command.startsWith('uname')) return RunResult(0, uname, '');
    if (command.startsWith('mktemp')) return RunResult(0, '/tmp/aurora3-upload-AbCd1234\n', '');
    if (command.startsWith('rm -rf')) {
      removed = true;
      return RunResult(0, '', '');
    }
    for (final l in const LineSplitter().convert(installOut)) {
      onLine?.call(l);
    }
    return RunResult(installCode, installOut, installErr);
  }

  @override
  Future<void> upload(String path, Stream<List<int>> data, int length, int mode, {void Function(int sent)? onProgress}) async {
    uploadPath = path;
    if (uploadFails) throw StateError('disk full');
    var n = 0;
    await for (final c in data) {
      n += c.length;
      onProgress?.call(n);
    }
    uploaded = n;
  }

  @override
  Future<void> close() async {}
}

const pin = 'aa00000000000000000000000000000000000000000000000000000000000000';
String resultLine(String result, {bool direct = true}) => jsonEncode({
      'result': result,
      'version': '3.0.1',
      'agent_id': 'id1',
      if (direct) 'direct': {'port': 17710, 'addrs': ['10.0.0.5:17710'], 'cert_sha256': pin, 'token': 'tok'},
    });

void main() {
  final fx = Platform.environment['AURORA3_RELEASE_FIXTURE'];
  final skip = fx == null || fx.isEmpty ? 'AURORA3_RELEASE_FIXTURE not set' : null;
  late AgentBuild build;
  setUpAll(() async {
    if (skip != null) return;
    final sep = Platform.pathSeparator;
    build = await AgentBuild.open('$fx${sep}good',
        trusted: [base64.decode(File('$fx${sep}trust.pub').readAsStringSync().trim())]);
  });

  test('sudo with a password: password on stdin, never in a command', () async {
    final r = FakeRemote()..installOut = '${jsonEncode({'stage': 'probe', 'status': 'ok'})}\n${resultLine('installed')}\n';
    final steps = <String>[];
    final o = await Installer(r, [build], sudoPassword: 'p@ss w0rd', serverName: "lab's",
        onProgress: (p) => steps.add('${p.step.name}:${p.status}')).install();
    expect(o.ok, isTrue);
    expect(o.direct!.pin, pin);
    expect(o.direct!.addrs, ['10.0.0.5:17710']);
    final inst = r.commands.firstWhere((c) => c.contains("'install'"));
    expect(inst, startsWith('sudo -k -S -p "" -- '));
    expect(inst, contains("'--name' 'lab'\\''s'"));
    expect(inst, contains("'--user' 'alice'"));
    expect(inst, contains("'--sha256' '${build.manifest.sha256.toLowerCase()}'"));
    for (final c in r.commands) {
      expect(c, isNot(contains('p@ss')));
    }
    expect(utf8.decode(r.stdins[r.commands.indexOf(inst)]!), 'p@ss w0rd\n');
    expect(r.uploadPath, '/tmp/aurora3-upload-AbCd1234/aurora3-agent');
    expect(r.uploaded, build.manifest.size);
    expect(r.removed, isTrue, reason: 'upload dir removed');
    expect(steps, containsAllInOrder(['inspect:ok', 'upload:start', 'upload:ok', 'probe:ok', 'read:ok']));
  }, skip: skip);

  test('root login: no sudo, no --user', () async {
    final r = FakeRemote()
      ..uname = 'Linux\naarch64\n0\nroot\nroot\n'
      ..installOut = resultLine('installed');
    // An arm64 server with only an amd64 build is refused before uploading.
    final o = await Installer(r, [build]).install();
    expect(o.result, 'unsupported');
    expect(o.message, contains('aarch64'));
    expect(r.uploadPath, isNull);
    r.uname = 'Linux\nx86_64\n0\nroot\nroot\n';
    final o2 = await Installer(r, [build]).install();
    expect(o2.ok, isTrue);
    final inst = r.commands.lastWhere((c) => c.contains("'install'"));
    expect(inst, startsWith("'/tmp/aurora3-upload-AbCd1234/aurora3-agent' 'install'"));
    expect(inst, isNot(contains('--user')));
  }, skip: skip);

  test('passwordless sudo uses sudo -n', () async {
    final r = FakeRemote()
      ..uname = 'Linux\nx86_64\n1000\nalice\nsudo-nopass\n'
      ..installOut = resultLine('upgraded');
    final o = await Installer(r, [build]).install();
    expect(o.ok, isTrue);
    expect(r.commands.firstWhere((c) => c.contains("'install'")), startsWith('sudo -n -- '));
  }, skip: skip);

  test('refusals before anything is uploaded', () async {
    for (final (uname, sudo, want) in [
      ('Darwin\narm64\n501\nme\nsudo-pass\n', 'x', 'Linux'),
      ('Linux\nx86_64\n1000\nme\nnosudo\n', 'x', 'sudo'),
      ('Linux\nx86_64\n1000\nme\nsudo-pass\n', null, 'sudo 密码'),
      ('Linux\nriscv64\n0\nroot\nroot\n', null, 'riscv64'),
    ]) {
      final r = FakeRemote()..uname = uname;
      final o = await Installer(r, [build], sudoPassword: sudo).install();
      expect(o.result, 'unsupported', reason: uname);
      expect(o.message, contains(want), reason: uname);
      expect(r.uploadPath, isNull, reason: uname);
    }
  }, skip: skip);

  test('wrong sudo password is reported as such', () async {
    final r = FakeRemote()
      ..installCode = 1
      ..installErr = 'sudo: 1 incorrect password attempt\n';
    final o = await Installer(r, [build], sudoPassword: 'bad').install();
    expect(o.result, 'failed');
    expect(o.message, 'sudo 密码不对');
    expect(r.removed, isTrue);
  }, skip: skip);

  test('rollback and refusal results come through', () async {
    for (final res in ['rolled_back', 'refused', 'rollback_failed']) {
      final r = FakeRemote()
        ..installCode = 2
        ..installOut = '${jsonEncode({'stage': 'rollback', 'status': 'ok'})}\n'
            '${jsonEncode({'result': res, 'message': 'why', 'kept': res == 'rollback_failed' ? '/var/lib/aurora3/rollback-1' : null})}\n';
      final o = await Installer(r, [build], sudoPassword: 'x').install();
      expect(o.result, res);
      expect(o.ok, isFalse);
      expect(o.message, 'why');
      if (res == 'rollback_failed') expect(o.kept, '/var/lib/aurora3/rollback-1');
    }
  }, skip: skip);

  test('no result line, upload failure', () async {
    final r = FakeRemote()
      ..installCode = 126
      ..installErr = 'Permission denied';
    var o = await Installer(r, [build], sudoPassword: 'x').install();
    expect(o.result, 'failed');
    expect(o.message, allOf(contains('126'), contains('Permission denied')));
    final u = FakeRemote()..uploadFails = true;
    o = await Installer(u, [build], sudoPassword: 'x').install();
    expect(o.result, 'failed');
    expect(o.message, contains('disk full'));
    expect(u.commands.where((c) => c.contains("'install'")), isEmpty);
    expect(u.removed, isTrue);
  }, skip: skip);

  test('a result without valid direct parameters is not ok', () async {
    final r = FakeRemote()..installOut = resultLine('installed', direct: false);
    final o = await Installer(r, [build], sudoPassword: 'x').install();
    expect(o.result, 'installed');
    expect(o.ok, isFalse);
  }, skip: skip);

  test('uninstall: sessions first, then --force, flags pass through', () async {
    final r = FakeRemote()
      ..uname = 'Linux\nx86_64\n0\nroot\nroot\n'
      ..installCode = 1
      ..installOut = jsonEncode({'result': 'sessions', 'message': 'two', 'sessions': ['main', 'build']});
    var o = await Installer(r, const []).uninstall();
    expect(o.result, 'sessions');
    expect(o.sessions, ['main', 'build']);
    expect(o.ok, isFalse);
    expect(r.commands.last, "'/usr/local/bin/aurora3-agent' 'uninstall'");
    r
      ..installCode = 0
      ..installOut = jsonEncode({'result': 'uninstalled', 'kept': ['/etc/aurora3', '/var/lib/aurora3'], 'done': ['stop-agent']});
    o = await Installer(r, const []).uninstall(force: true, purge: true);
    expect(o.ok, isTrue);
    expect(o.kept, hasLength(2));
    expect(r.commands.last, "'/usr/local/bin/aurora3-agent' 'uninstall' '--force' '--purge'");
  });

  test('uninstall with sudo, partial failure, not installed', () async {
    final r = FakeRemote()
      ..uname = 'Linux\nx86_64\n1000\nalice\nsudo-nopass\n'
      ..installCode = 4
      ..installOut = jsonEncode({'result': 'partial', 'message': 'm', 'failed': 'stop-sessions', 'done': ['stop-agent']});
    var o = await Installer(r, const []).uninstall(force: true);
    expect(o.result, 'partial');
    expect(o.failed, 'stop-sessions');
    expect(o.done, ['stop-agent']);
    expect(r.commands.last, startsWith('sudo -n -- '));
    r
      ..installCode = 127
      ..installOut = ''
      ..installErr = "sudo: /usr/local/bin/aurora3-agent: command not found";
    o = await Installer(r, const []).uninstall();
    expect(o.result, 'uninstalled');
    expect(o.message, contains('没有安装'));
  });

  test('readDirect runs direct-info as root', () async {
    final r = FakeRemote()
      ..uname = 'Linux\nx86_64\n1000\nalice\nsudo-nopass\n'
      ..installOut = resultLine('direct');
    final o = await Installer(r, const []).readDirect();
    expect(o.ok, isTrue);
    expect(r.commands.last, "sudo -n -- '/usr/local/bin/aurora3-agent' 'direct-info'");
    expect(r.uploadPath, isNull);
  });
}
