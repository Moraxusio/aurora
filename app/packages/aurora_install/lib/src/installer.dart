// The install wizard's engine (G5.6): over one SSH login, find the server's
// architecture, verify the bundled agent's signature (D-3), upload it, run
// `aurora3-agent install` as root (G3.1) and read back the direct-link
// parameters (D-4). The SSH session ends with the run; daily use is direct.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_tls/aurora_tls.dart';

import 'manifest.dart';
import 'remote.dart';

/// A signed agent build on this machine: a directory with manifest.json,
/// manifest.sig and the file the manifest names (agent/cmd/aurora3-release).
class AgentBuild {
  final String dir;
  final Manifest manifest;
  AgentBuild._(this.dir, this.manifest);

  String get path => '$dir${Platform.pathSeparator}${manifest.file}';

  /// Linux architecture from the file name (`...-linux-amd64`).
  String get arch => manifest.file.split('-').last;

  /// Verifies the signature and the file's size and SHA-256.
  static Future<AgentBuild> open(String dir, {List<Uint8List>? trusted}) async {
    final sep = Platform.pathSeparator;
    final mb = await File('$dir${sep}manifest.json').readAsBytes();
    final sig = await File('$dir${sep}manifest.sig').readAsBytes();
    final m = verifyManifest(mb, sig, trusted: trusted);
    if (m.file == 'manifest.json' || m.file == 'manifest.sig') throw ManifestException('签名清单的文件名无效');
    final f = File('$dir$sep${m.file}');
    if (!await f.exists()) throw ManifestException('缺少 ${m.file}');
    if (await f.length() != m.size) throw ManifestException('${m.file} 的大小与签名清单不符');
    if (await sha256File(f.path) != m.sha256.toLowerCase()) throw ManifestException('${m.file} 的 SHA-256 与签名清单不符');
    if (parseVersion(m.version) == null) throw ManifestException('签名清单的版本 ${m.version} 无效');
    return AgentBuild._(dir, m);
  }
}

/// Steps the wizard shows, in order.
enum InstallStep {
  connect, // SSH and the host key
  inspect, // architecture, root or sudo
  upload,
  probe, // G3.1 stages, as the agent reports them
  prepare,
  switchOver,
  confirm,
  rollback,
  read, // direct-link parameters
}

class InstallProgress {
  final InstallStep step;
  final String status; // start | ok | fail | progress
  final String message;
  final double? fraction; // upload
  InstallProgress(this.step, this.status, [this.message = '', this.fraction]);
  @override
  String toString() => '$step $status $message';
}

/// The direct-link parameters to store (D-22), as wire.DirectInfo.
class Direct {
  final int port;
  final List<String> addrs;
  final String pin;
  final String token;
  Direct(this.port, this.addrs, this.pin, this.token);

  static Direct? fromJson(Object? o) {
    if (o is! Map) return null;
    final pin = o['cert_sha256'], token = o['token'];
    if (pin is! String || token is! String || pin.length != 64 || token.isEmpty) return null;
    return Direct(o['port'] is int ? o['port'] as int : 17710,
        [for (final a in (o['addrs'] as List? ?? const [])) if (a is String) a], pin.toLowerCase(), token);
  }
}

/// Outcome of a run. [result] is the agent's (G3.1), or one of the client's
/// own: "unsupported" and "failed".
class InstallOutcome {
  final String result;
  final String message;
  final String? version;
  final String? previous;
  final String? agentId;
  final Direct? direct;
  final String? kept;
  InstallOutcome(this.result, this.message, {this.version, this.previous, this.agentId, this.direct, this.kept});

  /// [direct] can be stored: after an install, or from `direct-info`.
  bool get ok =>
      const {'installed', 'upgraded', 'up_to_date', 'direct'}.contains(result) && direct != null;
}

class InstallException implements Exception {
  final String message;
  InstallException(this.message);
  @override
  String toString() => message;
}

/// Runs one install over [remote]. [builds] are verified agent builds, one
/// per architecture. [sudoPassword] is used when the login is not root and
/// sudo asks for one (D-6).
class Installer {
  final Remote remote;
  final List<AgentBuild> builds;
  final String? sudoPassword;
  final String? serverName;
  final void Function(InstallProgress p)? onProgress;

  Installer(this.remote, this.builds, {this.sudoPassword, this.serverName, this.onProgress});

  void _p(InstallStep s, String status, [String msg = '', double? f]) =>
      onProgress?.call(InstallProgress(s, status, msg, f));

  /// Probes, uploads and installs. Never throws for an outcome the user must
  /// see; an [InstallOutcome] carries it.
  Future<InstallOutcome> install() async {
    _p(InstallStep.inspect, 'start');
    final _Host host;
    try {
      host = await _inspect();
    } on InstallException catch (e) {
      _p(InstallStep.inspect, 'fail', e.message);
      return InstallOutcome('unsupported', e.message);
    }
    final build = builds.where((b) => b.arch == host.arch).firstOrNull;
    if (build == null) {
      final m = '服务器的架构是 ${host.uname}，本客户端没有对应的 agent（支持 amd64、arm64，D-14）';
      _p(InstallStep.inspect, 'fail', m);
      return InstallOutcome('unsupported', m);
    }
    _p(InstallStep.inspect, 'ok', '${host.uname}，${host.root ? 'root' : 'sudo'}');

    // A private upload directory: mktemp -d is 0700 and owned by the login
    // user, so no other user can swap the binary before root runs it.
    final mk = await remote.run('mktemp -d /tmp/aurora3-upload-XXXXXXXX');
    final dir = mk.stdout.trim();
    if (mk.exitCode != 0 || !RegExp(r'^/tmp/aurora3-upload-[A-Za-z0-9]{8}$').hasMatch(dir)) {
      return InstallOutcome('failed', '无法在服务器上创建临时目录：${mk.stderr.trim()}');
    }
    try {
      final bin = '$dir/aurora3-agent';
      _p(InstallStep.upload, 'start');
      final len = build.manifest.size;
      try {
        await remote.upload(bin, File(build.path).openRead(), len, 0x1ed /* 0755 */,
            onProgress: (n) => _p(InstallStep.upload, 'progress', '', len == 0 ? 1 : n / len));
      } on Object catch (e) {
        _p(InstallStep.upload, 'fail', '$e');
        return InstallOutcome('failed', '上传失败：$e');
      }
      // The install checks the SHA-256 again against the manifest's value,
      // after root has the file (G3.1 prepare).
      _p(InstallStep.upload, 'ok');
      final args = [
        bin,
        'install',
        '--sha256',
        build.manifest.sha256.toLowerCase(),
        if (serverName != null && serverName!.isNotEmpty) ...['--name', serverName!],
        if (!host.root) ...['--user', host.user],
      ];
      final out = await _asRoot(host, args);
      return _outcome(out);
    } finally {
      await remote.run('rm -rf ${_q(dir)}');
    }
  }

  /// Reads the direct-link parameters of an installed agent (re-pairing,
  /// D-62), with no upload.
  Future<InstallOutcome> readDirect() async {
    _p(InstallStep.inspect, 'start');
    final _Host host;
    try {
      host = await _inspect();
    } on InstallException catch (e) {
      _p(InstallStep.inspect, 'fail', e.message);
      return InstallOutcome('unsupported', e.message);
    }
    _p(InstallStep.inspect, 'ok');
    final out = await _asRoot(host, ['/usr/local/bin/aurora3-agent', 'direct-info']);
    return _outcome(out);
  }

  Future<_Host> _inspect() async {
    // One round trip: kernel, machine, uid, user, and whether sudo works
    // without a password.
    final r = await remote.run(r'uname -s; uname -m; id -u; id -un; '
        r'if [ "$(id -u)" = 0 ]; then echo root; elif command -v sudo >/dev/null 2>&1; then '
        r'sudo -n true >/dev/null 2>&1 && echo sudo-nopass || echo sudo-pass; else echo nosudo; fi');
    final l = const LineSplitter().convert(r.stdout).map((s) => s.trim()).toList();
    if (r.exitCode != 0 || l.length < 5) throw InstallException('无法读取服务器信息：${r.stderr.trim()}');
    if (l[0] != 'Linux') throw InstallException('服务器的系统是 ${l[0]}，只支持 Linux');
    final arch = switch (l[1]) { 'x86_64' || 'amd64' => 'amd64', 'aarch64' || 'arm64' => 'arm64', _ => '' };
    final mode = l[4];
    if (mode == 'nosudo') throw InstallException('登录用户 ${l[3]} 不是 root，服务器也没有 sudo');
    if (mode == 'sudo-pass' && (sudoPassword == null || sudoPassword!.isEmpty)) {
      throw InstallException('sudo 需要密码，请填写 sudo 密码');
    }
    return _Host(l[1], arch, l[3], mode == 'root', mode == 'sudo-pass');
  }

  /// Runs argv as root and turns its JSON lines into progress.
  Future<RunResult> _asRoot(_Host host, List<String> argv) {
    final cmd = argv.map(_q).join(' ');
    String full;
    Uint8List? stdin;
    if (host.root) {
      full = cmd;
    } else if (!host.sudoNeedsPassword) {
      full = 'sudo -n -- $cmd';
    } else {
      // The password goes through stdin, never the command line. -k forgets
      // a cached ticket so a wrong password fails now instead of later.
      full = 'sudo -k -S -p "" -- $cmd';
      stdin = Uint8List.fromList(utf8.encode('${sudoPassword!}\n'));
    }
    return remote.run(full, stdin: stdin, onLine: _onAgentLine);
  }

  static const _stages = {
    'probe': InstallStep.probe,
    'prepare': InstallStep.prepare,
    'switch': InstallStep.switchOver,
    'confirm': InstallStep.confirm,
    'rollback': InstallStep.rollback,
  };

  void _onAgentLine(String line) {
    if (!line.startsWith('{')) return;
    try {
      final m = jsonDecode(line);
      if (m is Map && m['stage'] is String) {
        final s = _stages[m['stage']];
        if (s != null) _p(s, m['status'] as String? ?? '', m['message'] as String? ?? '');
      }
    } on FormatException {
      // not one of ours
    }
  }

  InstallOutcome _outcome(RunResult r) {
    Map? last;
    for (final l in const LineSplitter().convert(r.stdout).reversed) {
      if (!l.startsWith('{')) continue;
      try {
        final m = jsonDecode(l);
        if (m is Map && m['result'] is String) {
          last = m;
          break;
        }
      } on FormatException {
        continue;
      }
    }
    if (last == null) {
      final err = r.stderr.trim();
      if (err.contains('incorrect password') || err.contains('密码不正确') || err.contains('Sorry, try again')) {
        return InstallOutcome('failed', 'sudo 密码不对');
      }
      return InstallOutcome('failed', '安装程序没有给出结果（退出码 ${r.exitCode}）${err.isEmpty ? '' : '：$err'}');
    }
    final res = last['result'] as String;
    final direct = Direct.fromJson(last['direct']);
    _p(InstallStep.read, direct != null ? 'ok' : 'fail');
    return InstallOutcome(res, last['message'] as String? ?? '',
        version: last['version'] as String?,
        previous: last['previous'] as String?,
        agentId: last['agent_id'] as String?,
        direct: direct,
        kept: last['kept'] as String?);
  }
}

class _Host {
  final String uname, arch, user;
  final bool root, sudoNeedsPassword;
  _Host(this.uname, this.arch, this.user, this.root, this.sudoNeedsPassword);
}

/// Single-quotes [s] for sh.
String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";
