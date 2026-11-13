import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_install/aurora_install.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';

/// Owns only the Windows local backend. Remote installs/credentials are unrelated.
class LocalAgent {
  Process? _process;
  Target? _target;
  Future<Target>? _starting;
  int _epoch = 0;
  List<Map<String, dynamic>> roots = [];

  Future<Target> start(String stateDir) =>
      _starting ??= _start(stateDir).whenComplete(() => _starting = null);

  Future<Target> _start(String stateDir) async {
    final epoch = _epoch;
    if (_process != null && _target != null) return _target!;
    if (!Platform.isWindows) throw StateError('本地 agent 当前仅支持 Windows');
    final dir =
        Platform.environment['AURORA3_LOCAL_AGENT_DIR'] ??
        '${File(Platform.resolvedExecutable).parent.path}\\local-agent\\windows-amd64';
    List<Uint8List>? trusted;
    final testKey = Platform.environment['AURORA3_TRUST_KEY'];
    if (testKey != null && testKey.isNotEmpty) {
      trusted = [Uint8List.fromList(base64Decode(testKey))];
    }
    final build = await AgentBuild.open(dir, trusted: trusted, product: 'aurora3-local-agent');
    if (epoch != _epoch) throw StateError('本地 agent 启动已取消');
    if (build.manifest.product != 'aurora3-local-agent' ||
        build.manifest.channel != 'stable' ||
        !build.manifest.file.endsWith('-windows-amd64.exe')) {
      throw StateError('本地 agent 的签名产品或 Windows 平台不匹配');
    }
    final process = await Process.start(
      build.path,
      [],
      mode: ProcessStartMode.normal,
    );
    if (epoch != _epoch) {
      process.kill();
      throw StateError('本地 agent 启动已取消');
    }
    _process = process;
    // Do not log child streams: the bootstrap contains a fresh authentication token.
    unawaited(process.stderr.drain<void>());
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    try {
      process.stdin.writeln(jsonEncode({'state_dir': stateDir}));
      await process.stdin.flush();
      if (!await lines.moveNext().timeout(const Duration(seconds: 20))) {
        throw StateError('本地 agent 未返回启动结果');
      }
      final ready = (jsonDecode(lines.current) as Map).cast<String, dynamic>();
      final addr = ready['addr'] as String? ?? '';
      final hp = splitHostPort(addr);
      final pin = ready['pin'] as String? ?? '';
      final token = ready['token'] as String? ?? '';
      if (ready['kind'] != 'local' ||
          ready['platform'] != 'windows' ||
          ready['version'] != build.manifest.version ||
          hp == null ||
          hp.$1 != '127.0.0.1' ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(pin) ||
          token.length < 32) {
        throw StateError('本地 agent 握手无效');
      }
      roots = [
        for (final r in ready['roots'] as List)
          (r as Map).cast<String, dynamic>(),
      ];
      _target = Target(addrs: [addr], pin: pin, token: token);
      unawaited(
        process.exitCode.then((_) {
          if (identical(_process, process)) {
            _process = null;
            _target = null;
          }
        }),
      );
      return _target!;
    } on Object {
      await stop();
      rethrow;
    } finally {
      await lines.cancel();
    }
  }

  WorkspacePath locate(String folder) {
    final path = folder.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
    final sorted = [...roots]
      ..sort(
        (a, b) => (b['path'] as String).length.compareTo(
          (a['path'] as String).length,
        ),
      );
    for (final r in sorted) {
      final base = (r['path'] as String)
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'/+$'), '');
      if (path.toLowerCase() == base.toLowerCase() ||
          path.toLowerCase().startsWith('${base.toLowerCase()}/')) {
        return WorkspacePath(
          root: r['id'] as String,
          path: path.substring(base.length),
        );
      }
    }
    throw StateError('当前仅支持本机固定磁盘上的文件夹，暂不支持 UNC/网络共享');
  }

  String nativePath(String root, String path) {
    final entry = roots.where((r) => r['id'] == root).firstOrNull;
    if (entry == null) return '$root:$path';
    final base = (entry['path'] as String).replaceFirst(RegExp(r'[/\\]+$'), '');
    final relative = WorkspacePath.normalize(path).replaceAll('/', '\\');
    return '$base$relative';
  }

  Future<void> stop() async {
    _epoch++;
    final p = _process;
    _process = null;
    _target = null;
    if (p == null) return;
    // EOF is the graceful lifetime signal, not a command-line secret. A child
    // that already exited may have broken its pipe; shutdown must still finish.
    try { await p.stdin.close(); } on Object { /* already broken */ }
    try {
      await p.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      p.kill();
    }
  }
}
