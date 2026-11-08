import 'dart:convert';

import 'package:aurora_sub/aurora_sub.dart';
import 'package:test/test.dart';

// A subscription as providers send them: a Clash file with mixed protocols,
// names with emoji and Chinese, ports and booleans written as strings,
// proxy-groups and rules after the proxies (which the parser must ignore).
const clash = r'''
mixed-port: 7890
allow-lan: false
proxies:
  - {name: "🇭🇰 香港 01 | 2x", type: trojan, server: hk1.example.com, port: 443, password: trojan-pass-1, sni: hk1.example.com, udp: true}
  - name: "🇯🇵 东京 02"
    type: vless
    server: jp.example.com
    port: "443"
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    tls: true
    servername: cdn.example.com
    network: ws
    ws-opts:
      path: /vl?ed=2048
      headers:
        Host: ws.example.com
    skip-cert-verify: false
  - name: "VMess US"
    type: vmess
    server: us.example.com
    port: 8443
    uuid: 5b0f2f6e-6d5e-4e7a-9c7a-1d2f3a4b5c6d
    alterId: 0
    cipher: auto
    tls: true
    network: ws
    ws-opts: {path: /ray, headers: {Host: us.example.com}}
  - name: "HY2 SG"
    type: hysteria2
    server: sg.example.com
    port: 8443
    password: hy2-pass
    sni: sg.example.com
    up: "30 Mbps"
    down: 200
    obfs: salamander
    obfs-password: obfs-pass
    skip-cert-verify: true
  - name: "VLESS Reality"
    type: vless
    server: r.example.com
    port: 443
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    flow: xtls-rprx-vision
    tls: true
    reality-opts: {public-key: AAAA, short-id: bb}
  - name: "SS node"
    type: ss
    server: ss.example.com
    port: 8388
    cipher: aes-256-gcm
    password: ss-pass
  - name: "TUIC"
    type: tuic
    server: t.example.com
    port: 443
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    password: x
  - name: "gRPC vless"
    type: vless
    server: g.example.com
    port: 443
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    tls: true
    network: grpc
    grpc-opts: {grpc-service-name: svc}
  - name: broken, no server
    type: trojan
    port: 443
proxy-groups:
  - {name: Auto, type: url-test, proxies: ["🇭🇰 香港 01 | 2x"], url: "http://www.gstatic.com/generate_204", interval: 300}
rules:
  - MATCH,Auto
''';

SubNode byName(SubResult r, String name) => r.nodes.firstWhere((n) => n.name == name, orElse: () => throw StateError('no node "$name" in ${r.nodes.map((n) => n.name).toList()}'));

void main() {
  group('capability descriptors contain no real credentials', () {
    test('password, UUID and obfuscation password are replaced', () {
      for (final proto in ['trojan','hysteria2','vless','vmess']) {
        final original = proto == 'vless' || proto == 'vmess' ? 'b831381d-6324-4d53-ad4f-8cda48b30811' : 'synthetic-provider-password';
        final n = SubNode(proto:proto,host:'node.invalid',port:443,secret:original,obfsPassword:'synthetic-obfs-password');
        final check = n.toCheck();
        final json = jsonEncode(check);
        expect(json,isNot(contains(original)));
        expect(json,isNot(contains('synthetic-obfs-password')));
        expect(check['host'],'node.invalid');
        expect(n.toAgent()['secret'],original,reason:'real dialing still needs the actual credential');
      }
    });
    test('missing/invalid credentials and too-short obfs are not disguised as valid', () {
      expect(SubNode(proto:'trojan',host:'h',port:1).toCheck().containsKey('secret'),false);
      expect(SubNode(proto:'vless',host:'h',port:1,secret:'broken').toCheck()['secret'],'invalid-uuid');
      expect(SubNode(proto:'hysteria2',host:'h',port:1,obfsPassword:'ab').toCheck()['obfs_password'],'xx');
      final n = SubNode(proto:'trojan',host:'h',port:1,secret:'密码-credential',obfsPassword:'混淆密码');
      expect(utf8.encode(n.toCheck()['secret'] as String).length, utf8.encode(n.secret).length);
      expect(utf8.encode(n.toCheck()['obfs_password'] as String).length, utf8.encode(n.obfsPassword).length);
      expect(n.toCheck()['secret_length'], utf8.encode(n.secret).length);
      expect(n.toCheck()['obfs_password_length'], utf8.encode(n.obfsPassword).length);
    });
  });
  group('Clash file', () {
    final r = parseSubscription(clash);

    test('is read as Clash, and every proxy is either a node or a stated skip', () {
      expect(r.format, 'clash');
      expect(r.nodes.length, 8);
      expect(r.skipped, hasLength(1));
      expect(r.skipped.single, contains('broken, no server'));
    });

    test('Trojan', () {
      final n = byName(r, '🇭🇰 香港 01 | 2x');
      expect(n.proto, 'trojan');
      expect([n.host, n.port, n.secret, n.sni, n.tls], ['hk1.example.com', 443, 'trojan-pass-1', 'hk1.example.com', true]);
      expect(n.unsupported, isEmpty);
      expect(n.verify, '系统根证书');
    });

    test('VLESS over WebSocket: port written as a string, Host header, servername', () {
      final n = byName(r, '🇯🇵 东京 02');
      expect([n.proto, n.port, n.transport, n.wsPath, n.wsHost, n.sni, n.tls], ['vless', 443, 'ws', '/vl?ed=2048', 'ws.example.com', 'cdn.example.com', true]);
      expect(n.secret, 'b831381d-6324-4d53-ad4f-8cda48b30811');
      expect(n.unsupported, isEmpty);
    });

    test('VMess', () {
      final n = byName(r, 'VMess US');
      expect([n.proto, n.cipher, n.transport, n.wsPath, n.wsHost], ['vmess', 'auto', 'ws', '/ray', 'us.example.com']);
      expect(n.unsupported, isEmpty);
    });

    test('Hysteria2: units, obfuscation, and a skip-cert-verify the user will see', () {
      final n = byName(r, 'HY2 SG');
      expect([n.proto, n.upMbps, n.downMbps, n.obfs, n.obfsPassword, n.insecure], ['hysteria2', 30, 200, 'salamander', 'obfs-pass', true]);
      expect(n.verify, '不校验证书');
      expect(n.unsupported, isEmpty);
    });

    test('what the agent cannot dial is kept and says why, never turned into a different protocol', () {
      expect(byName(r, 'VLESS Reality').unsupported, contains('Reality'));
      expect(byName(r, 'SS node').unsupported, contains('Shadowsocks'));
      expect(byName(r, 'TUIC').unsupported, contains('TUIC'));
      expect(byName(r, 'gRPC vless').unsupported, contains('grpc'));
    });

    test('Vision is passed on as the flow, and left for the agent to refuse', () {
      // the parser reports Reality here; the flow is still carried so the agent's own check names it too
      expect(byName(r, 'VLESS Reality').flow, 'xtls-rprx-vision');
    });
  });

  group('share links', () {
    final vmessJson = jsonEncode({'v': '2', 'ps': 'VM 香港', 'add': 'vm.example.com', 'port': '443', 'id': '5b0f2f6e-6d5e-4e7a-9c7a-1d2f3a4b5c6d', 'aid': '0', 'scy': 'auto', 'net': 'ws', 'type': 'none', 'host': 'cdn.example.com', 'path': '/ws', 'tls': 'tls', 'sni': ''});
    final lines = [
      'trojan://p%40ss@t.example.com:443?sni=t.example.com&allowInsecure=0#%F0%9F%87%AD%F0%9F%87%B0%20Trojan',
      'vless://b831381d-6324-4d53-ad4f-8cda48b30811@v.example.com:443?type=ws&security=tls&sni=v.example.com&path=%2Fvl&host=h.example.com#VL',
      'vless://b831381d-6324-4d53-ad4f-8cda48b30811@r.example.com:443?type=tcp&security=reality&pbk=AAA&sid=bb&flow=xtls-rprx-vision#RE',
      'vmess://${base64.encode(utf8.encode(vmessJson))}',
      'hysteria2://hy2pass@h.example.com:8443?sni=h.example.com&obfs=salamander&obfs-password=op&insecure=1#HY',
      'hy2://x@m.example.com:443?mport=20000-30000#HOP',
      'ss://${base64.encode(utf8.encode('aes-256-gcm:sspass'))}@s.example.com:8388#SS',
      'tuic://u:p@tu.example.com:443?congestion_control=bbr#TU',
      'not a link at all',
      'trojan://nohostport',
    ];
    final plain = lines.join('\n');

    void check(SubResult r) {
      expect(r.format, 'links');
      final by = {for (final n in r.nodes) n.name: n};
      expect(by['🇭🇰 Trojan']!.secret, 'p@ss');
      expect(by['🇭🇰 Trojan']!.unsupported, isEmpty);
      final vl = by['VL']!;
      expect([vl.transport, vl.wsPath, vl.wsHost, vl.tls], ['ws', '/vl', 'h.example.com', true]);
      expect(by['RE']!.unsupported, contains('Reality'));
      final vm = by['VM 香港']!;
      expect([vm.proto, vm.host, vm.port, vm.transport, vm.wsPath, vm.wsHost, vm.tls], ['vmess', 'vm.example.com', 443, 'ws', '/ws', 'cdn.example.com', true]);
      expect(vm.unsupported, isEmpty);
      final hy = by['HY']!;
      expect([hy.obfs, hy.obfsPassword, hy.insecure, hy.secret], ['salamander', 'op', true, 'hy2pass']);
      expect(by['HOP']!.unsupported, contains('端口跳跃'));
      expect(by['SS']!.unsupported, contains('Shadowsocks'));
      expect(by['SS']!.host, 's.example.com');
      expect(by['TU']!.unsupported, contains('TUIC'));
      expect(r.skipped, hasLength(2));
    }

    test('plain lines', () => check(parseSubscription(plain)));
    test('the whole subscription as one base64 block', () => check(parseSubscription(base64.encode(utf8.encode(plain)))));
    test('URL-safe base64 without padding, with a line break in the middle', () {
      var b = base64Url.encode(utf8.encode(plain)).replaceAll('=', '');
      b = '${b.substring(0, 40)}\n${b.substring(40)}';
      check(parseSubscription(b));
    });
    test('Clash text that is itself base64 is read as Clash', () {
      expect(parseSubscription(base64.encode(utf8.encode(clash))).format, 'clash');
    });
  });

  // Each of these is a node that would connect differently from what the
  // provider configured if the parser let it through as a plain one.
  group('nothing is quietly turned into a plain node', () {
    test('a link with another transport says so, and is not read as tcp', () {
      for (final t in ['grpc', 'h2', 'httpupgrade', 'xhttp', 'kcp', 'quic']) {
        final n = parseLink('vless://b831381d-6324-4d53-ad4f-8cda48b30811@x.example.com:443?type=$t&security=tls#x')!;
        expect(n.unsupported, contains(t), reason: t);
        expect(n.transport, isEmpty, reason: t);
      }
      final tr = parseLink('trojan://p@x.example.com:443?type=grpc&serviceName=s#x')!;
      expect(tr.unsupported, contains('grpc'));
    });

    test('a Clash transport other than tcp and ws says so', () {
      final r = parseSubscription('proxies:\n  - {name: a, type: vmess, server: x.example.com, port: 443, uuid: 5b0f2f6e-6d5e-4e7a-9c7a-1d2f3a4b5c6d, alterId: 0, cipher: auto, tls: true, network: h2}');
      expect(r.nodes.single.unsupported, contains('h2'));
    });

    test('legacy VMess (alterId not 0) is flagged in both formats', () {
      final r = parseSubscription('proxies:\n  - {name: old, type: vmess, server: x.example.com, port: 443, uuid: 5b0f2f6e-6d5e-4e7a-9c7a-1d2f3a4b5c6d, alterId: 64, cipher: auto}');
      expect(r.nodes.single.unsupported, contains('alterId'));
      final j = jsonEncode({'ps': 'old', 'add': 'x.example.com', 'port': 443, 'id': '5b0f2f6e-6d5e-4e7a-9c7a-1d2f3a4b5c6d', 'aid': 64, 'net': 'tcp'});
      expect(parseLink('vmess://${base64.encode(utf8.encode(j))}')!.unsupported, contains('alterId'));
    });

    test('a pinned certificate is carried into the node, in both formats', () {
      final pin = List.filled(32, 'ab').join();
      final colons = List.filled(32, 'AB').join(':');
      final c = parseSubscription('proxies:\n  - {name: p, type: trojan, server: x.example.com, port: 443, password: pw, fingerprint: "$colons"}');
      expect(c.nodes.single.pin, pin);
      expect(c.nodes.single.verify, '指纹校验');
      final h = parseLink('hysteria2://pw@x.example.com:443?pinSHA256=$colons#p')!;
      expect(h.pin, pin);
      expect(h.verify, '指纹校验');
    });

    test('Trojan over WebSocket is flagged in both formats: the agent only speaks Trojan on plain TLS', () {
      final r = parseSubscription('proxies:\n  - {name: t, type: trojan, server: x.example.com, port: 443, password: pw, network: ws, ws-opts: {path: /t}}');
      expect(r.nodes.single.unsupported, contains('Trojan'));
      expect(parseLink('trojan://pw@x.example.com:443?type=ws&path=%2Ft#t')!.unsupported, contains('Trojan'));
    });

    test('a node with a WebSocket early-data header is flagged: the agent does not send it', () {
      final r = parseSubscription('proxies:\n  - {name: e, type: vless, server: x.example.com, port: 443, uuid: b831381d-6324-4d53-ad4f-8cda48b30811, tls: true, network: ws, ws-opts: {path: /w, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}');
      expect(r.nodes.single.unsupported, contains('早期数据'));
    });
  });

  group('what is not a subscription', () {
    test('empty', () => expect(parseSubscription('  \n').nodes, isEmpty));
    test('an HTML page (a login wall, a blocked URL) is not read as nodes', () {
      final r = parseSubscription('<!DOCTYPE html><html><body>Please log in</body></html>');
      expect(r.nodes, isEmpty);
      expect(r.skipped.single, contains('不认识'));
    });
    test('a Clash file with no proxies', () {
      final r = parseSubscription('proxies:\nrules:\n  - MATCH,DIRECT');
      expect(r.nodes, isEmpty);
    });
    test('broken YAML does not throw', () {
      final r = parseSubscription('proxies:\n  - {name: a, type: [');
      expect(r.nodes, isEmpty);
      expect(r.skipped, isNotEmpty);
    });
  });

  group('secrets', () {
    final r = parseSubscription(clash);
    test('a message about a skipped line never repeats its password', () {
      final s = parseSubscription('trojan://SUPERSECRET@\nvless://SUPERSECRET2@:::');
      for (final m in s.skipped) {
        expect(m, isNot(contains('SUPERSECRET')));
      }
    });
    test('the list the user reads has no secret in it', () {
      for (final n in r.nodes) {
        final pub = jsonEncode(n.toPublic());
        if (n.secret.isNotEmpty) expect(pub, isNot(contains(n.secret)), reason: n.name);
        if (n.obfsPassword.isNotEmpty) expect(pub, isNot(contains(n.obfsPassword)), reason: n.name);
      }
    });
    test('what goes to the agent does carry it', () {
      expect(jsonEncode(byName(r, '🇭🇰 香港 01 | 2x').toAgent()), contains('trojan-pass-1'));
    });
  });

  group('identity across refreshes', () {
    test('a renamed node and a rotated password are the same node; a moved one is not', () {
      SubNode mk(String name, {String host = 'h.example.com', int port = 443, String secret = 's', String path = ''}) =>
          SubNode(proto: 'trojan', host: host, port: port, name: name, secret: secret, tls: true, wsPath: path);
      expect(mk('HK 01').key, mk('香港 01 | 2x').key);
      expect(mk('a').key, mk('a', secret: 'rotated').key);
      expect(mk('a').key, isNot(mk('a', host: 'other.example.com').key));
      expect(mk('a').key, isNot(mk('a', port: 8443).key));
      expect(SubNode(proto: 'vless', host: 'h', port: 443, transport: 'ws', wsPath: '/a').key, isNot(SubNode(proto: 'vless', host: 'h', port: 443, transport: 'ws', wsPath: '/b').key));
    });

    test('the key carries no secret, so it can be logged and compared without leaking one', () {
      final n = SubNode(proto: 'trojan', host: 'h.example.com', port: 443, secret: 'SECRET-PASSWORD', obfsPassword: 'OBFS-SECRET');
      expect(n.key, isNot(contains('SECRET')));
    });
  });

  group('round trip with the agent\'s JSON', () {
    test('toAgent then fromJson gives the same node', () {
      final r = parseSubscription(clash);
      for (final n in r.nodes) {
        final back = SubNode.fromJson(n.toAgent());
        expect(back.toAgent(), n.toAgent(), reason: n.name);
      }
    });
  });
}
