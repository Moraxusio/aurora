import 'dart:async';
import 'dart:convert';

import 'package:aurora/features/proxy/proxy_model.dart';
import 'package:aurora/state/profile_access.dart';
import 'package:aurora/state/upgrade_model.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_sub/aurora_sub.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryProfile implements ProfileAccess {
  @override
  Profile profile = Profile(servers:[ServerEntry(id:'s',name:'server')]);
  final Map<String,Link> links={};
  @override ServerEntry? server(String id) => profile.server(id);
  @override Link? link(String id)=>links[id];
  @override Future<void> update(FutureOr<void> Function(Profile) fn) async { await fn(profile); }
}

class FakeLink implements Link {
  @override final AgentInfo server;
  final Future<Object?> Function(String,Object?) handler;
  FakeLink(this.handler,{Map<String,dynamic>? info}):server=AgentInfo(info??{'version':'3.3.0','arch':'amd64','caps':['agent.upgrade.status']});
  @override bool get isClosed=>false;
  @override Future<Object?> call(String op,[Object? args,Duration timeout=const Duration(seconds:60)])=>handler(op,args);
  @override dynamic noSuchMethod(Invocation i)=>super.noSuchMethod(i);
}

void main(){
  test('capability check sends placeholders, real testing and selection send real credentials',()async{
    final app=MemoryProfile(), sent=<Map<String, dynamic>>[];
    final link=FakeLink((op,args)async{sent.add({'op':op,'args':args});if(op=='proxy.check')return {'reasons':['']};if(op=='proxy.test')return {'ok':true,'ms':2};return {};});
    final model=ProxyModel(app);
    final n=SubNode(proto:'hysteria2',host:'node.invalid',port:443,secret:'REAL-ACCOUNT-SECRET',obfsPassword:'REAL-OBFS-SECRET',tls:true);
    final src=ProxySource(id:'src',name:'airport',nodes:[n.toAgent()]);app.profile.proxySources.add(src);
    await model.check(link,[n]);
    expect(jsonEncode(sent.single),isNot(contains('REAL-')));
    await model.test(link,NodeRow(src,n,''));
    expect(jsonEncode(sent.last),contains('REAL-ACCOUNT-SECRET'));
    await model.choose(app.profile.servers.single,link,NodeRow(src,n,''));
    expect(jsonEncode(sent.last),contains('REAL-ACCOUNT-SECRET'));
  });

  test('an old push acknowledgement cannot clear a newer subscription generation',()async{
    final app=MemoryProfile();final n=SubNode(proto:'trojan',host:'h',port:443,secret:'old',tls:true);
    final src=ProxySource(id:'src',name:'source',url:'https://sub.invalid',nodes:[n.toAgent()]);app.profile.proxySources.add(src);
    app.profile.servers.single.proxy=ProxyChoice(source:'src',key:n.key,name:'old',pending:true,revision:1);
    final started=Completer<void>(),reply=Completer<void>();
    final link=FakeLink((op,args)async{started.complete();await reply.future;return {};});
    final model=ProxyModel(app);
    final oldPush=model.repush(app.profile.servers.single,link);
    await started.future;
    await model.refresh('src',fetch:(_)async=>'proxies:\n  - {name: newer, type: trojan, server: h, port: 443, password: newer-password}');
    expect(app.profile.servers.single.proxy!.revision,2);
    reply.complete();await oldPush;
    expect(app.profile.servers.single.proxy!.pending,true);
    expect(app.profile.servers.single.proxy!.revision,2);
  });

  test('choosing while a clear is in flight is serialized, not erased by its late reply',()async{
    final app=MemoryProfile();final n=SubNode(proto:'trojan',host:'h',port:443,secret:'pw',tls:true);
    final src=ProxySource(id:'src',name:'source',nodes:[n.toAgent()]);app.profile.proxySources.add(src);
    app.profile.servers.single.proxy=ProxyChoice(source:'src',key:n.key,name:'old');
    final started=Completer<void>(),reply=Completer<void>();final ops=<String>[];
    final link=FakeLink((op,args)async{ops.add(op);if(op=='proxy.clear'){started.complete();await reply.future;}return {};});
    final model=ProxyModel(app);
    final clear=model.clear(app.profile.servers.single,link);await started.future;
    final choose=model.choose(app.profile.servers.single,link,NodeRow(src,n,''));
    reply.complete();await Future.wait([clear,choose]);
    expect(ops,['proxy.clear','proxy.set']);
    expect(app.profile.servers.single.proxy!.key,n.key);
    expect(app.profile.servers.single.proxy!.pending,false);
  });

  test('a persisted upload receipt recovers without uploading and a late starting response cannot undo it',()async{
    final app=MemoryProfile();app.profile.servers.single.upgrade=UpgradeRecord(target:'3.3.1',previous:'3.3.0',state:'interrupted',job:'a'*24);
    final ops=<String>[];
    final link=FakeLink((op,args)async{ops.add(op);return {'id':'a'*24,'version':'3.3.1','state':'rolled_back','message':'health failed'};});
    final m=UpgradeModel(app,()=>[],()=>null);
    await m.recover('s',link);
    expect(ops,['agent.upgrade.status']);
    expect(app.profile.servers.single.upgrade!.state,'rolled_back');
    expect(app.profile.servers.single.failedUpgrades,['3.3.1']);
    await m.record('s',state:'starting');
    expect(app.profile.servers.single.upgrade!.state,'rolled_back');
  });

  test('recovery rejects a receipt for another job or version',()async{
    final app=MemoryProfile();app.profile.servers.single.upgrade=UpgradeRecord(target:'3.3.1',previous:'3.3.0',state:'interrupted',job:'a'*24);
    final link=FakeLink((op,args)async=>{'id':'b'*24,'version':'3.3.1','state':'upgraded'});
    await UpgradeModel(app,()=>[],()=>null).recover('s',link);
    expect(app.profile.servers.single.upgrade!.state,'interrupted');
    expect(app.profile.servers.single.upgrade!.message,contains('不匹配'));
  });
}
