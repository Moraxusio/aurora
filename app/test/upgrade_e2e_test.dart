// Dart -> Go upgrade protocol integration. The testpeer uses the real
// authenticated entry, signed manifest/policy verification and upload stream;
// its Launch hook only writes an "upgraded" receipt, so this is not a real
// systemd install (that is covered separately by the authorized WSL test).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurora/state/profile_access.dart';
import 'package:aurora/state/upgrade_model.dart';
import 'package:aurora_install/aurora_install.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

class _Profile implements ProfileAccess {
  @override
  final Profile profile = Profile();
  final Map<String, Link> links = {};

  @override
  Link? link(String id) => links[id];

  @override
  Future<void> update(FutureOr<void> Function(Profile) change) async {
    await change(profile);
  }
}

void main() {
  final bin = Platform.environment['AURORA3_TESTPEER'];
  final fixture = Platform.environment['AURORA3_UPGRADE_FIXTURE'];
  final skip = bin == null || bin.isEmpty || fixture == null || fixture.isEmpty
      ? 'AURORA3_TESTPEER and AURORA3_UPGRADE_FIXTURE are not set'
      : null;

  late Process peer;
  late Link link;
  late _Profile access;
  late UpgradeModel model;

  setUp(() async {
    if (skip != null) return;
    final sep = Platform.pathSeparator;
    final pub = base64.decode(File('$fixture${sep}trust.pub').readAsStringSync().trim());
    final build = await AgentBuild.open('$fixture${sep}3.3.1', trusted: [Uint8List.fromList(pub)]);
    final policy = UpgradePolicy.verify(
      await File('$fixture${sep}normal.json').readAsBytes(),
      await File('$fixture${sep}normal.sig').readAsString(),
      trusted: [Uint8List.fromList(pub)],
    );

    peer = await Process.start(bin!, ['-upgrade-fixture', fixture!]);
    final line = await peer.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
    final ep = (jsonDecode(line) as Map).cast<String, dynamic>();
    final addr = ep['addr'] as String;
    final split = addr.lastIndexOf(':');
    link = await Link.dial(Endpoint(
      host: addr.substring(0, split),
      port: int.parse(addr.substring(split + 1)),
      pin: ep['pin'] as String,
      token: ep['token'] as String,
    ));
    access = _Profile();
    final server = ServerEntry(id: 'peer', name: 'testpeer');
    access.profile.servers.add(server);
    access.links[server.id] = link;
    model = UpgradeModel(access, () => [build], () => policy);
  });

  tearDown(() async {
    if (skip != null) return;
    await link.close();
    peer.stdin.close();
    await peer.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      peer.kill();
      return -1;
    });
  });

  test('verified build uploads over the real wire and receipt is recovered', () async {
    final offer = model.offer('peer', link);
    expect(offer.available, isTrue, reason: offer.reason);
    expect(offer.direct, isTrue);

    await model.directUpgrade('peer', link);
    final receipt = access.profile.server('peer')!.upgrade!;
    expect(receipt.job, matches(RegExp(r'^[0-9a-f]{24}$')));
    expect(receipt.state, anyOf('starting', 'upgraded'));

    // The testpeer's worker fixture completes immediately. Querying through a
    // fresh model exercises the same reconnect/status path used after a real
    // client disconnect.
    final recovered = UpgradeModel(access, () => const [], () => null);
    await recovered.recover('peer', link);
    expect(access.profile.server('peer')!.upgrade!.state, 'upgraded');
    expect(access.profile.server('peer')!.failedUpgrades, isEmpty);
  }, skip: skip);
}
