// End-to-end install over SSH, for agent/tools/install-e2e.sh: connects to
// aurora3-sshpeer, checks the host key, verifies and uploads the signed
// build, installs as root (or with sudo), then dials the agent directly.
//   e2e ADDR HOSTKEY_SHA256 USER PASSWORD BUILD_DIR TRUST_PUB_B64 [SUDO_PASSWORD]
// Prints one JSON line per step and a final {"result":...}.
import 'dart:convert';
import 'dart:io';

import 'package:aurora_install/aurora_install.dart';
import 'package:aurora_wire/aurora_wire.dart';

void out(Map<String, Object?> m) => stdout.writeln(jsonEncode(m));

Future<void> main(List<String> a) async {
  final i = a[0].lastIndexOf(':');
  final host = a[0].substring(0, i), port = int.parse(a[0].substring(i + 1));
  final want = a[1], user = a[2], password = a[3], dir = a[4];
  final trust = [base64.decode(a[5].trim())];
  final sudo = a.length > 6 ? a[6] : null;

  final build = await AgentBuild.open(dir, trusted: trust);
  out({'build': build.manifest.version, 'arch': build.arch});

  // A wrong expected key must stop the login before any credential is sent.
  try {
    final r = await SshRemote.connect(host, port, SshCredentials(user: user, password: password),
        checkHostKey: (k) => k.fingerprint == 'SHA256:wrong');
    await r.close();
    out({'result': 'fail', 'message': 'a host key that does not match was accepted'});
    exit(1);
  } on SshException catch (e) {
    out({'host_key_check': e.kind.name});
  }
  try {
    final r = await SshRemote.connect(host, port, SshCredentials(user: user, password: 'wrong'),
        checkHostKey: (k) => k.fingerprint == want);
    await r.close();
    out({'result': 'fail', 'message': 'a wrong password logged in'});
    exit(1);
  } on SshException catch (e) {
    out({'wrong_password': e.kind.name});
  }

  String? seen;
  final remote = await SshRemote.connect(host, port, SshCredentials(user: user, password: password), checkHostKey: (k) {
    seen = '${k.type} ${k.fingerprint}';
    return k.fingerprint == want;
  });
  out({'host_key': seen});
  final inst = Installer(remote, [build], sudoPassword: sudo, serverName: 'e2e', onProgress: (p) {
    if (p.status != 'progress') out({'step': p.step.name, 'status': p.status, if (p.message.isNotEmpty) 'message': p.message});
  });
  final o = await inst.install();
  if (!o.ok) {
    out({'result': o.result, 'message': o.message});
    await remote.close();
    exit(2);
  }
  final again = await inst.readDirect();
  await remote.close();

  final d = o.direct!;
  final link = await Link.dial(Endpoint(host: '127.0.0.1', port: d.port, pin: d.pin, token: d.token));
  final info = await link.call('agent.info') as Map;
  await link.close();
  out({
    'result': o.result,
    'version': o.version,
    'agent_id': o.agentId,
    'direct_info_same': again.ok && again.direct!.pin == d.pin && again.direct!.token == d.token,
    'dialed_version': (info['agent'] as Map)['version'],
    'addrs': d.addrs.length,
  });
}
