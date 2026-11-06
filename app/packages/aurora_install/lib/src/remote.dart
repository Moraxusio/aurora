// What the installer needs from a server, and its SSH implementation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// Output of one remote command.
class RunResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  RunResult(this.exitCode, this.stdout, this.stderr);
}

/// A logged-in shell on the server.
abstract interface class Remote {
  /// Runs [command] with `sh -c`. [stdin] is written, then closed. [onLine]
  /// receives stdout line by line as it arrives.
  Future<RunResult> run(String command, {Uint8List? stdin, void Function(String line)? onLine});

  /// Writes [data] to [path] with [mode], replacing it.
  Future<void> upload(String path, Stream<List<int>> data, int length, int mode, {void Function(int sent)? onProgress});

  Future<void> close();
}

/// Why connecting failed; the kinds need different handling.
enum SshFailure {
  /// Refused, unreachable, timed out.
  network,

  /// The host key is not the one the user confirmed before (D-2, D-62).
  hostKeyChanged,

  /// The user declined an unknown host key.
  hostKeyRejected,

  /// Wrong password or key, or no method the server accepts.
  auth,

  /// Anything else in the SSH handshake.
  protocol,
}

class SshException implements Exception {
  final SshFailure kind;
  final String message;
  SshException(this.kind, this.message);
  @override
  String toString() => message;
}

/// A host key as dartssh2 reports it.
class HostKey {
  final String type;

  /// OpenSSH-style "SHA256:base64".
  final String fingerprint;
  HostKey(this.type, this.fingerprint);
}

/// Decides about a server's host key: true to continue.
typedef HostKeyCheck = FutureOr<bool> Function(HostKey key);

/// How to log in. At least one of [password] and [privateKey] is set.
class SshCredentials {
  final String user;
  final String? password;
  final String? privateKey;
  final String? passphrase;
  SshCredentials({required this.user, this.password, this.privateKey, this.passphrase});
}

/// [Remote] over dartssh2.
class SshRemote implements Remote {
  final SSHClient _c;
  SshRemote._(this._c);

  /// Connects and logs in. [checkHostKey] decides about the host key before
  /// any credential is sent.
  static Future<SshRemote> connect(String host, int port, SshCredentials cred,
      {required HostKeyCheck checkHostKey, Duration timeout = const Duration(seconds: 15)}) async {
    SSHSocket sock;
    try {
      sock = await SSHSocket.connect(host, port, timeout: timeout);
    } on SocketException catch (e) {
      throw SshException(SshFailure.network, '无法连接 $host:$port：${e.message}');
    } on TimeoutException {
      throw SshException(SshFailure.network, '连接 $host:$port 超时');
    }
    List<SSHKeyPair>? ids;
    if (cred.privateKey != null && cred.privateKey!.isNotEmpty) {
      try {
        ids = SSHKeyPair.fromPem(cred.privateKey!, cred.passphrase);
      } on SSHKeyDecryptError {
        sock.destroy();
        throw SshException(SshFailure.auth, '私钥的密码不对');
      } on Object catch (e) {
        sock.destroy();
        throw SshException(SshFailure.auth, '无法读取私钥：$e');
      }
    }
    SshFailure? hostFailure;
    final c = SSHClient(
      sock,
      username: cred.user,
      identities: ids,
      onPasswordRequest: cred.password == null ? null : () => cred.password,
      handshakeTimeout: timeout,
      authTimeout: timeout,
      onVerifyHostKey: (type, fp) async {
        final ok = await checkHostKey(HostKey(type, utf8.decode(fp)));
        if (!ok) hostFailure ??= SshFailure.hostKeyRejected;
        return ok;
      },
    );
    try {
      await c.authenticated;
    } on SSHAuthFailError {
      c.close();
      throw SshException(SshFailure.auth, '登录失败：用户名、密码或私钥不对');
    } on Object catch (e) {
      c.close();
      if (hostFailure != null) {
        throw SshException(hostFailure!, hostFailure == SshFailure.hostKeyRejected ? '未接受服务器的主机密钥' : '$e');
      }
      if (e is SSHHostkeyError) throw SshException(SshFailure.hostKeyChanged, '服务器的主机密钥校验失败：$e');
      if (e is SSHSocketError || e is SocketException) throw SshException(SshFailure.network, '连接中断：$e');
      if (e is SSHAuthAbortError) throw SshException(SshFailure.network, '登录中断：${e.message}');
      throw SshException(SshFailure.protocol, 'SSH 握手失败：$e');
    }
    return SshRemote._(c);
  }

  @override
  Future<RunResult> run(String command, {Uint8List? stdin, void Function(String line)? onLine}) async {
    final s = await _c.execute(command);
    final out = StringBuffer(), err = BytesBuilder(copy: false);
    final outDone = Completer<void>(), errDone = Completer<void>();
    s.stdout.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      out.writeln(l);
      onLine?.call(l);
    }, onDone: outDone.complete, onError: outDone.completeError);
    s.stderr.listen(err.add, onDone: errDone.complete, onError: errDone.completeError);
    if (stdin != null) s.stdin.add(stdin);
    await s.stdin.close();
    await Future.wait([outDone.future, errDone.future]);
    await s.done;
    return RunResult(s.exitCode ?? -1, out.toString(), utf8.decode(err.takeBytes(), allowMalformed: true));
  }

  /// Streams [data] into `cat` over an exec channel rather than SFTP: every
  /// server with a shell has cat, while the SFTP subsystem can be disabled.
  /// SSH channel flow control paces the sender.
  @override
  Future<void> upload(String path, Stream<List<int>> data, int length, int mode,
      {void Function(int sent)? onProgress}) async {
    final m = mode.toRadixString(8);
    final s = await _c.execute('umask 077 && cat > ${_q(path)} && chmod $m ${_q(path)}');
    final err = BytesBuilder(copy: false);
    final outDone = s.stdout.drain<void>();
    final errDone = s.stderr.listen(err.add).asFuture<void>();
    var sent = 0;
    try {
      await for (final c in data) {
        final b = c is Uint8List ? c : Uint8List.fromList(c);
        s.stdin.add(b);
        sent += b.length;
        onProgress?.call(sent);
      }
    } finally {
      await s.stdin.close();
    }
    await Future.wait([outDone, errDone]);
    await s.done;
    if (sent != length) throw StateError('读取到 $sent 字节，应为 $length');
    if (s.exitCode != 0) {
      throw StateError('写入 $path 失败（退出码 ${s.exitCode}）：${utf8.decode(err.takeBytes(), allowMalformed: true).trim()}');
    }
  }

  @override
  Future<void> close() async => _c.close();
}

String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";
