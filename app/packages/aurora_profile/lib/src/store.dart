// The sealed profile file, written atomically (as v2's client.Store).
//
// File layout: "AURORA3P", one format byte, one byte n, the sealer id (n
// ASCII bytes), then the sealer's output over the profile JSON.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'profile.dart';
import 'sealer.dart';

const List<int> _magic = [0x41, 0x55, 0x52, 0x4f, 0x52, 0x41, 0x33, 0x50]; // AURORA3P
const int _format = 1;

/// The profile file exists but cannot be read: sealed by another user, on
/// another device or by another sealer, damaged, or from a newer client. It
/// is never overwritten automatically; [ProfileStore.resetUnreadable] moves
/// it aside when the user chooses to start over.
class ProfileUnreadable implements Exception {
  final String path;
  final String message;
  ProfileUnreadable(this.path, this.message);
  @override
  String toString() => message;
}

/// The default profile path on this platform (D-71: `%LOCALAPPDATA%\Aurora3`
/// on Windows). Other platforms get theirs from the app (path_provider).
String defaultProfilePath() {
  if (Platform.isWindows) {
    final base = Platform.environment['LOCALAPPDATA'];
    if (base == null || base.isEmpty) throw StateError('LOCALAPPDATA 未设置');
    return '$base\\Aurora3\\profile.bin';
  }
  throw UnsupportedError('profile path on ${Platform.operatingSystem} comes from the app');
}

class ProfileStore {
  final String path;
  final Sealer _sealer;
  Profile _p;
  Future<void> _last = Future.value();
  final StreamController<Profile> _changes = StreamController<Profile>.broadcast(sync: true);

  ProfileStore._(this.path, this._sealer, this._p);

  /// Opens [path], or starts empty when it does not exist yet. Throws
  /// [ProfileUnreadable] when it exists but cannot be opened.
  static Future<ProfileStore> open(String path, Sealer sealer) async {
    final f = File(path);
    if (!await f.exists()) return ProfileStore._(path, sealer, Profile());
    final raw = await f.readAsBytes();
    return ProfileStore._(path, sealer, _decode(path, raw, sealer));
  }

  static Profile _decode(String path, Uint8List raw, Sealer sealer) {
    if (raw.length < _magic.length + 2) throw ProfileUnreadable(path, '配置文件已损坏（太短）');
    for (var i = 0; i < _magic.length; i++) {
      if (raw[i] != _magic[i]) throw ProfileUnreadable(path, '不是 Aurora 3 的配置文件');
    }
    final format = raw[_magic.length];
    if (format != _format) throw ProfileUnreadable(path, '配置文件来自更新版本的客户端（格式 $format）');
    final n = raw[_magic.length + 1];
    final start = _magic.length + 2;
    if (raw.length < start + n) throw ProfileUnreadable(path, '配置文件已损坏（头部不完整）');
    final id = ascii.decode(raw.sublist(start, start + n), allowInvalid: true);
    if (id != sealer.id) throw ProfileUnreadable(path, '配置文件由另一种方式加密（$id），无法用 ${sealer.id} 打开');
    Uint8List plain;
    try {
      plain = sealer.unseal(Uint8List.sublistView(raw, start + n));
    } on SealerException catch (e) {
      throw ProfileUnreadable(path, e.message);
    }
    try {
      final j = jsonDecode(utf8.decode(plain));
      if (j is! Map) throw const FormatException('not an object');
      return Profile.fromJson(j.cast<String, dynamic>());
    } on Object catch (e) {
      throw ProfileUnreadable(path, '配置文件内容无法解析：$e');
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  /// A deep copy of the current profile.
  Profile get() => _p.copy();

  /// Small defensive snapshots for UI hot paths. Reading a server name or a
  /// tab's connection state must not clone every node in every subscription.
  String? get selected => _p.selected;
  ServerEntry? server(String id) {
    final value = _p.server(id);
    return value == null ? null : ServerEntry.fromJson(value.toJson());
  }

  List<ServerEntry> get servers => [for (final s in _p.servers) ServerEntry.fromJson(s.toJson())];

  /// The profile after every successful [update].
  Stream<Profile> get changes => _changes.stream;

  /// Applies [fn] to a copy and saves it; the stored profile changes only
  /// when the file was written. Updates run one at a time, in call order.
  Future<void> update(FutureOr<void> Function(Profile p) fn) {
    final run = _last.then((_) async {
      final next = _p.copy();
      await fn(next);
      await _write(next);
      _p = next;
      _changes.add(next.copy());
    });
    _last = run.catchError((_) {});
    return run;
  }

  Future<void> _write(Profile p) async {
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(p.toJson())));
    Uint8List sealed;
    try {
      sealed = _sealer.seal(plain);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
    final id = ascii.encode(_sealer.id);
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..addByte(_format)
      ..addByte(id.length)
      ..add(id)
      ..add(sealed);
    final f = File(path);
    await f.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    final raf = await tmp.open(mode: FileMode.writeOnly);
    try {
      await raf.writeFrom(out.takeBytes());
      await raf.flush();
    } finally {
      await raf.close();
    }
    // Replaces the old file in one step (MoveFileEx with REPLACE_EXISTING on
    // Windows, rename(2) elsewhere): a crash leaves the old or the new file.
    await tmp.rename(path);
  }

  /// Moves an unreadable profile aside (`profile.bin.unreadable-TIME`) so
  /// a new one can be started. Returns the new name. Nothing is deleted.
  static Future<String> resetUnreadable(String path) async {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 14);
    final aside = '$path.unreadable-$stamp';
    await File(path).rename(aside);
    return aside;
  }

  Future<void> close() async {
    await _last;
    await _changes.close();
  }
}
