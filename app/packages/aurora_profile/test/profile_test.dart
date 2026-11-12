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

  group('agent instance (D-101)', () {
    test('is kept in the profile; an old entry without one is the default instance', () {
      final p = Profile();
      p.servers.add(ServerEntry.create('mine', instance: 'c1a2b3c4d'));
      p.servers.add(ServerEntry.create('old'));
      final j = jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
      final servers = (j['servers'] as List).cast<Map<String, dynamic>>();
      expect(servers[0]['instance'], 'c1a2b3c4d');
      expect(servers[1].containsKey('instance'), isFalse, reason: 'the default instance writes nothing');
      final back = Profile.fromJson(j);
      expect(back.servers[0].instance, 'c1a2b3c4d');
      expect(back.servers[1].instance, '');
      // A profile written before instances existed has no key at all.
      servers[1].remove('instance');
      expect(Profile.fromJson(j).servers[1].instance, '');
    });

    test('new names are valid for the agent and differ', () {
      final names = {for (var i = 0; i < 200; i++) newInstanceName()};
      expect(names.length, 200);
      for (final n in names) {
        expect(RegExp(r'^[a-z][a-z0-9]{0,15}$').hasMatch(n), isTrue, reason: n);
      }
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

    test('small server snapshots stay defensive without visiting subscription nodes', () async {
      final s = await ProfileStore.open(path, XorSealer());
      await s.update((p) {
        p.servers.add(ServerEntry(id: 'one', name: 'before', failedUpgrades: ['3.0.1']));
        p.proxySources.add(_CountingSource());
        p.selected = 'one';
      });
      _CountingSource.copies = 0;
      expect(s.selected, 'one');
      final snapshot = s.server('one')!;
      snapshot.name = 'changed outside the store';
      snapshot.failedUpgrades.add('3.0.2');
      s.servers.single.failedUpgrades.clear();
      expect(s.server('one')!.name, 'before');
      expect(s.server('one')!.failedUpgrades, ['3.0.1']);
      expect(_CountingSource.copies, 0);
      s.get();
      expect(_CountingSource.copies, greaterThan(0), reason: 'control: full profile reads do visit the nodes');
      await s.close();
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

  group('proxy sources and the choice of a node', () {
    const url = 'https://sub.example.com/api/v1/client/subscribe?token=SUBTOKEN-9f31c0aa';
    const nodePass = 'node-password-77aa';

    Profile withProxy() {
      final p = sample();
      final src = ProxySource.create('我的机场', url: url);
      src.nodes = [
        {'name': 'HK 01', 'proto': 'trojan', 'host': 'hk.example.com', 'port': 443, 'secret': nodePass, 'tls': {'enabled': true}},
      ];
      p.proxySources.add(src);
      p.servers.single.proxy = ProxyChoice(source: src.id, key: 'trojan|hk.example.com|443|||$nodePass', name: 'HK 01');
      return p;
    }

    test('JSON round trip keeps the sources, their nodes and the choice', () {
      final p = withProxy();
      final q = Profile.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(jsonEncode(q.toJson()), jsonEncode(p.toJson()));
      expect(q.proxySources.single.url, url);
      expect(q.proxySources.single.nodes.single['secret'], nodePass);
      expect(q.servers.single.proxy!.name, 'HK 01');
      expect(q.proxySource(q.proxySources.single.id), isNotNull);
      expect(q.proxySource('nope'), isNull);
    });

    test('a profile written before proxies existed still opens', () {
      final old = jsonEncode(sample().toJson());
      final q = Profile.fromJson(jsonDecode(old) as Map<String, dynamic>);
      expect(q.proxySources, isEmpty);
      expect(q.servers.single.proxy, isNull);
    });

    test('a profile without any proxy writes none of the keys', () {
      final j = sample().toJson();
      expect(j.containsKey('proxy_sources'), isFalse);
      expect((j['servers'] as List).single.containsKey('proxy'), isFalse);
    });

    test('on disk the subscription address and the node passwords are sealed', () async {
      final store = await ProfileStore.open(path, XorSealer());
      await store.update((p) {
        final w = withProxy();
        p.servers
          ..clear()
          ..addAll(w.servers);
        p.proxySources
          ..clear()
          ..addAll(w.proxySources);
      });
      await store.close();
      final raw = latin1.decode(File(path).readAsBytesSync(), allowInvalid: true);
      for (final secret in [url, 'SUBTOKEN-9f31c0aa', nodePass, 'sub.example.com', 'hk.example.com']) {
        expect(raw, isNot(contains(secret)), reason: secret);
      }
      final again = await ProfileStore.open(path, XorSealer());
      expect(again.get().proxySources.single.url, url);
      expect(again.get().proxySources.single.nodes.single['secret'], nodePass);
      await again.close();
    });

    test('a different sealer cannot read it (D-72: bound to this machine)', () async {
      final store = await ProfileStore.open(path, XorSealer());
      await store.update((p) => p.proxySources.add(ProxySource.create('x', url: url)));
      await store.close();
      await expectLater(ProfileStore.open(path, XorSealer(0x33, 'other-machine')), throwsA(isA<ProfileUnreadable>()));
    });
  });

  group('AI settings (D-104)', () {
    test('round-trips providers, OpenCode protocols, and seals API keys on disk', () async {
      final store = await ProfileStore.open(path, XorSealer());
      const secretKey = 'sk-opencode-secret-key-998877';
      await store.update((p) {
        final prov = AiProvider.create(
          name: 'OpenCode Gateway',
          protocol: 'anthropic-messages',
          baseUrl: 'https://opencode.ai/zen/v1',
          apiKey: secretKey,
          model: 'claude-sonnet-4-5',
          useProxy: true,
        )..reasoningEffort = 'medium';
        p.ai.providers.add(prov);
        p.ai.selectedProviderId = prov.id;
        p.ai.permissionMode = 'auto';
      });
      await store.close();

      final raw = latin1.decode(File(path).readAsBytesSync(), allowInvalid: true);
      expect(raw, isNot(contains(secretKey)));

      final again = await ProfileStore.open(path, XorSealer());
      final ai = again.get().ai;
      expect(ai.permissionMode, 'auto');
      expect(ai.activeProvider, isNotNull);
      expect(ai.activeProvider!.name, 'OpenCode Gateway');
      expect(ai.activeProvider!.protocol, 'anthropic-messages');
      expect(ai.activeProvider!.apiKey, secretKey);
      expect(ai.activeProvider!.useProxy, isTrue);
      expect(ai.activeProvider!.toWireJson()['model'], 'claude-sonnet-4-5');
      await again.close();
    });
  });
}

class _CountingSource extends ProxySource {
  static int copies = 0;
  _CountingSource() : super(id: 'source', name: 'fixture', nodes: [
    {'proto': 'trojan', 'host': 'node.invalid', 'port': 443, 'secret': 'synthetic-only'},
  ]);
  @override
  Map<String, dynamic> toJson() {
    copies++;
    return super.toJson();
  }
}
