import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_profile/aurora_profile.dart';
import 'package:test/test.dart';

/// Test-only sealer: XOR with a byte, so tests of the file format run
/// everywhere. Not in lib/ on purpose (D-72: no plaintext fallback).
class XorSealer implements Sealer {
  final int k;
  final String name;
  XorSealer([this.k = 0x5a, this.name = 'xor-test']);
  @override
  String get id => name;
  @override
  Uint8List seal(Uint8List p) => Uint8List.fromList([for (final b in p) b ^ k]);
  @override
  Uint8List unseal(Uint8List s) => Uint8List.fromList([for (final b in s) b ^ k]);
}

Profile sample() {
  final p = Profile();
  final s = ServerEntry.create('lab',
      ssh: SshLogin(host: '203.0.113.10', user: 'alice', password: 'pw-秘密', sudoPassword: 'sudo-pw'));
  s.direct = DirectParams(port: 17710, addrs: ['203.0.113.10:17710'], pin: 'a' * 64, token: 'tok-1');
  s.forwards.add(ForwardSpec(port: 8888, local: 18888, label: 'jupyter'));
  s.forwards.add(ForwardSpec(host: 'db.internal', port: 5432, local: 15432));
  p.servers.add(s);
  p.selected = s.id;
  p.trustHost('203.0.113.10', 22, 'ssh-ed25519', 'SHA256:abc');
  return p;
}

void main() {
  late Directory dir;
  late String path;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aurora3-profile-test-');
    path = '${dir.path}${Platform.pathSeparator}profile.bin';
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  group('profile model', () {
    test('JSON round trip keeps every field', () {
      final p = sample();
      final q = Profile.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(jsonEncode(q.toJson()), jsonEncode(p.toJson()));
      final s = q.servers.single;
      expect(s.ssh!.password, 'pw-秘密');
      expect([for (final f in s.forwards) '${f.host}:${f.port}->${f.local} ${f.label}'], ['127.0.0.1:8888->18888 jupyter', 'db.internal:5432->15432 ']);
      expect(s.ssh!.sudoPassword, 'sudo-pw');
      expect(s.ssh!.privateKey, isNull);
      expect(s.direct!.ready, isTrue);
      expect(q.knownHost('203.0.113.10', 22)!.fingerprint, 'SHA256:abc');
    });

    test('absent secrets are not written', () {
      final j = jsonEncode(SshLogin(host: 'h', user: 'u').toJson());
      expect(j, isNot(contains('password')));
      expect(j, isNot(contains('private_key')));
    });

    test('known hosts: lookup ignores case, trust replaces', () {
      final p = Profile()..trustHost('Example.ORG', 22, 'ssh-ed25519', 'SHA256:one');
      expect(p.knownHost('example.org', 22)!.fingerprint, 'SHA256:one');
      expect(p.knownHost('example.org', 2222), isNull);
      p.trustHost('example.org', 22, 'ssh-ed25519', 'SHA256:two');
      expect(p.knownHosts, hasLength(1));
      expect(p.knownHost('EXAMPLE.org', 22)!.fingerprint, 'SHA256:two');
    });

    test('direct params need token, pin and an address', () {
      expect(DirectParams(port: 1, pin: 'a' * 64, token: 't').ready, isFalse);
      expect(DirectParams(port: 1, addrs: ['h:1'], pin: 'A' * 64, token: 't').ready, isFalse);
      expect(DirectParams(port: 1, addrs: ['h:1'], pin: 'a' * 64, token: '').ready, isFalse);
      expect(DirectParams(port: 1, pin: 'a' * 64, token: 't', goodAddr: 'h:1').ready, isTrue);
    });

    test('ids are 16 hex digits and differ', () {
      final a = newId(), b = newId();
      expect(a, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(a, isNot(b));
    });
  });

  group('store', () {
    test('missing file opens empty; saved profile reopens', () async {
      final s = await ProfileStore.open(path, XorSealer());
      expect(s.get().servers, isEmpty);
      await s.update((p) {
        final x = sample();
        p.servers = x.servers;
        p.selected = x.selected;
        p.knownHosts = x.knownHosts;
      });
      await s.close();
      final again = await ProfileStore.open(path, XorSealer());
      expect(jsonEncode(again.get().toJson()), jsonEncode(s.get().toJson()));
      expect(File('$path.tmp').existsSync(), isFalse);
    });

    test('the file holds no plaintext', () async {
      final s = await ProfileStore.open(path, XorSealer());
      await s.update((p) => p.servers.addAll(sample().servers));
      final raw = File(path).readAsBytesSync();
      expect(latin1.decode(raw, allowInvalid: true), isNot(contains('tok-1')));
      expect(ascii.decode(raw.sublist(0, 8)), 'AURORA3P');
    });

    test('get() returns copies', () async {
      final s = await ProfileStore.open(path, XorSealer());
      s.get().servers.add(ServerEntry.create('x'));
      expect(s.get().servers, isEmpty);
    });

    test('a failing update changes neither memory nor file', () async {
      final s = await ProfileStore.open(path, XorSealer());
      await s.update((p) => p.selected = 'one');
      final before = File(path).readAsBytesSync();
      await expectLater(s.update((p) {
        p.selected = 'two';
        throw StateError('no');
      }), throwsStateError);
      expect(s.get().selected, 'one');
      expect(File(path).readAsBytesSync(), before);
      await s.update((p) => p.selected = 'three');
      expect(s.get().selected, 'three');
    });

    test('updates run in call order', () async {
      final s = await ProfileStore.open(path, XorSealer());
      final seen = <String>[];
      final fs = [
        for (var i = 0; i < 20; i++)
          s.update((p) async {
            await Future<void>.delayed(Duration(milliseconds: 20 - i));
            p.servers.add(ServerEntry(id: '$i', name: '$i'));
            seen.add('$i');
          }),
      ];
      await Future.wait(fs);
      expect(seen, [for (var i = 0; i < 20; i++) '$i']);
      final again = await ProfileStore.open(path, XorSealer());
      expect(again.get().servers.map((e) => e.id), seen);
    });

    test('changes stream reports saved profiles', () async {
      final s = await ProfileStore.open(path, XorSealer());
      final got = <String?>[];
      s.changes.listen((p) => got.add(p.selected));
      await s.update((p) => p.selected = 'a');
      await s.update((p) => p.selected = 'b');
      expect(got, ['a', 'b']);
    });

    test('a file sealed by another sealer is refused, not overwritten', () async {
      final s = await ProfileStore.open(path, XorSealer());
      await s.update((p) => p.selected = 'x');
      final before = File(path).readAsBytesSync();
      await expectLater(ProfileStore.open(path, XorSealer(0x5a, 'other')), throwsA(isA<ProfileUnreadable>()));
      expect(File(path).readAsBytesSync(), before);
    });

    test('damaged files are refused', () async {
      for (final bad in [
        <int>[1, 2, 3],
        utf8.encode('NOTAURORA..........'),
        [...ascii.encode('AURORA3P'), 9, 0],
        [...ascii.encode('AURORA3P'), 1, 20, 0x78],
        [...ascii.encode('AURORA3P'), 1, 8, ...ascii.encode('xor-test'), 0xff, 0xfe],
      ]) {
        File(path).writeAsBytesSync(bad);
        await expectLater(ProfileStore.open(path, XorSealer()), throwsA(isA<ProfileUnreadable>()), reason: '$bad');
      }
    });

    test('resetUnreadable moves the file aside and keeps it', () async {
      File(path).writeAsBytesSync([1, 2, 3]);
      final aside = await ProfileStore.resetUnreadable(path);
      expect(File(path).existsSync(), isFalse);
      expect(File(aside).readAsBytesSync(), [1, 2, 3]);
      final s = await ProfileStore.open(path, XorSealer());
      expect(s.get().servers, isEmpty);
    });
  });

  group('DPAPI', () {
    final skip = Platform.isWindows ? null : 'Windows only';

    test('platformSealer is DPAPI', () {
      expect(platformSealer().id, 'dpapi');
    }, skip: skip);

    test('round trip, including empty and 1 MiB', () {
      final d = DpapiSealer();
      for (final n in [0, 1, 1000, 1 << 20]) {
        final plain = Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31) & 255]);
        final sealed = d.seal(plain);
        expect(sealed.length, greaterThan(n));
        expect(d.unseal(sealed), plain, reason: '$n bytes');
      }
    }, skip: skip);

    test('sealing twice gives different blobs', () {
      final d = DpapiSealer();
      final p = Uint8List.fromList(utf8.encode('same'));
      expect(d.seal(p), isNot(d.seal(p)));
    }, skip: skip);

    test('another purpose (entropy) cannot open the blob', () {
      final sealed = DpapiSealer().seal(Uint8List.fromList(utf8.encode('secret')));
      expect(() => DpapiSealer(purpose: 'something-else').unseal(sealed), throwsA(isA<SealerException>()));
    }, skip: skip);

    test('a modified blob is refused', () {
      final d = DpapiSealer();
      final sealed = d.seal(Uint8List.fromList(utf8.encode('secret')));
      sealed[sealed.length - 5] ^= 1;
      expect(() => d.unseal(sealed), throwsA(isA<SealerException>()));
    }, skip: skip);

    test('store on DPAPI: save, reopen, tamper', () async {
      final s = await ProfileStore.open(path, DpapiSealer());
      await s.update((p) => p.servers.addAll(sample().servers));
      final again = await ProfileStore.open(path, DpapiSealer());
      expect(again.get().servers.single.ssh!.password, 'pw-秘密');
      final raw = File(path).readAsBytesSync();
      expect(latin1.decode(raw, allowInvalid: true), isNot(contains('alice')));
      raw[raw.length - 3] ^= 0x40;
      File(path).writeAsBytesSync(raw);
      await expectLater(ProfileStore.open(path, DpapiSealer()), throwsA(isA<ProfileUnreadable>()));
    }, skip: skip);
  });
}
