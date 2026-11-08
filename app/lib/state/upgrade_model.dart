import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora_install/aurora_install.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_tls/aurora_tls.dart' show sha256File;
import 'package:aurora_wire/aurora_wire.dart';

import 'profile_access.dart';

class UpgradeOffer {
  final AgentBuild? build;
  final String current;
  final String? reason;
  final bool direct;
  UpgradeOffer(this.current, this.build, this.reason, this.direct);
  bool get available => build != null && reason == null;
}

/// Chooses verified bundled builds, persists a receipt before committing and
/// recovers it over the next authenticated link. Merely connecting never
/// uploads a build: the UI must obtain explicit confirmation first.
class UpgradeModel {
  final ProfileAccess app;
  final List<AgentBuild> Function() builds;
  final UpgradePolicy? Function() policy;
  final Map<String, Future<void>> _running = {};
  final Map<String,Link> _watching = {};
  UpgradeModel(this.app, this.builds, this.policy);

  UpgradeOffer offer(String id, Link link) {
    final current = link.server.version;
    final raw = link.server.raw;
    final arch = raw['arch'] as String? ?? (link.server.os.endsWith(' amd64') ? 'amd64' : link.server.os.endsWith(' arm64') ? 'arm64' : '');
    final candidates = builds().where((b) => b.arch == arch).toList()
      ..sort((a,b) => compareVersions(b.manifest.version,a.manifest.version) ?? 0);
    final direct = link.server.caps.contains('agent.upgrade');
    if (candidates.isEmpty) return UpgradeOffer(current, null, '没有与此服务器架构匹配的内置 agent', direct);
    // Prefer an actually safe target, even if a higher bundled version has
    // been revoked by the same signed policy.
    final safe = candidates.where((b) => policy()?.revoked.contains(b.manifest.version) != true && (policy()?.minOK == null || compareVersions(b.manifest.version,policy()!.minOK!)! >= 0)).toList();
    final b = safe.isEmpty ? candidates.first : safe.first;
    if (parseVersion(current) == null) return UpgradeOffer(current,b,'当前是开发版本，不能自动判断升级方向',direct);
    final record = app.profile.server(id)?.upgrade;
    if (record?.state == 'interrupted') {
      return UpgradeOffer(current, b, '上次升级连接中断，结果无法确认；请先查询，或通过 SSH 兼容向导核查后再操作', direct);
    }
    if (record != null && !record.terminal) return UpgradeOffer(current,b,'有升级任务未完成，请先查询结果',direct);
    if (app.profile.server(id)?.failedUpgrades.contains(b.manifest.version) == true) return UpgradeOffer(current,b,'此目标版本曾升级失败，不会再次推送',direct);
    final p = policy();
    final why = p?.refusal(current,b.manifest.version) ?? (p == null && compareVersions(b.manifest.version,current)! <= 0 ? '已是最新版本或服务器版本更新' : null);
    return UpgradeOffer(current,b,why,direct);
  }

  Future<void> connected(String id, Link link) async {
    final r = app.profile.server(id)?.upgrade;
    if (r == null || (r.terminal && r.state != 'interrupted') || _running.containsKey(id)) return;
    if(identical(_watching[id],link))return;
    _watching[id]=link;
    final until=DateTime.now().add(const Duration(minutes:20));
    try {
      do {
        await recover(id,link);
        if(app.profile.server(id)?.upgrade?.terminal!=false)return;
        await Future<void>.delayed(const Duration(seconds:2));
      } while(!link.isClosed && identical(app.link(id),link) && DateTime.now().isBefore(until));
    } finally {if(identical(_watching[id],link))_watching.remove(id);}
  }

  Future<void> recover(String id,Link link) async {
    final r = app.profile.server(id)?.upgrade;
    if (r == null || (r.terminal && r.state != 'interrupted')) return;
    // A rollback target may be an older agent without the status operation.
    if (!link.server.caps.contains('agent.upgrade.status')) {
      if (link.server.version == r.target) {
        await record(id,state:'upgraded',message:'已重连并确认目标版本');
      } else {
        await record(id,state:'interrupted',message:'已连接旧 agent，无法查询任务；请通过 SSH 核查，不会重复推送');
      }
      return;
    }
    if (r.job == null) {
      await record(id,state:'failed',message:'提交前连接中断，没有升级任务回执；未自动重试');
      return;
    }
    try {
      final result = await link.call('agent.upgrade.status', {'id':r.job}) as Map;
      if (result['id'] != r.job || result['version'] != r.target) throw OpError(codeConflict, '升级任务回执与请求不匹配');
      final current = app.profile.server(id)?.upgrade;
      if (current == null || (current.terminal && current.state != 'interrupted') || current.job != r.job || current.target != r.target) return;
      await record(id,state:result['state'] as String,message:result['message'] as String?);
    } on OpError catch(e) {
      await record(id,state:e.code == codeNotFound ? 'failed' : r.state,message:e.code == codeNotFound ? '上传未完成或任务不存在；没有自动重复推送' : e.message,blockTarget: false);
    }
  }

  Future<void> record(String id,{required String state,String? message,String? job,bool blockTarget=true}) => app.update((p) {
    final e=p.server(id),r=p.server(id)?.upgrade;
    if (e==null||r==null) return;
    // A late "starting" reply must not roll back a terminal status already
    // recovered on a fresh link while the old upload response was in flight.
    if (r.terminal && !const {'upgraded','installed','up_to_date','rolled_back','rollback_failed','refused','failed','interrupted'}.contains(state)) return;
    r.state=state;r.message=message;if(job!=null)r.job=job;
    if (blockTarget && const {'failed','rolled_back','rollback_failed'}.contains(state) && !e.failedUpgrades.contains(r.target)) e.failedUpgrades.add(r.target);
  });

  Future<void> begin(String id,UpgradeOffer o) => app.update((p) {
    p.server(id)?.upgrade=UpgradeRecord(target:o.build!.manifest.version,previous:o.current,state:'uploading');
  });

  Future<void> directUpgrade(String id,Link link,{void Function(String,double?)? progress}) {
    if (_running.containsKey(id)) throw OpError(codeConflict,'已有升级操作');
    final work = _direct(id,link,progress);
    _running[id]=work;
    return work.whenComplete(() {
      _running.remove(id);
      final current = app.link(id);
      if (current != null) unawaited(connected(id, current));
    });
  }

  Future<void> _direct(String id,Link link,void Function(String,double?)? progress) async {
    final o=offer(id,link),p=policy();
    if(!o.available) throw ManifestException(o.reason ?? '没有升级文件');
    if(!o.direct) throw ManifestException('旧 agent 需要通过 SSH 升级');
    if(p==null) throw ManifestException('缺少签名撤回清单，不能执行直连升级');
    final b=o.build!;
    if(await File(b.path).length()!=b.manifest.size || await sha256File(b.path)!=b.manifest.sha256.toLowerCase())throw ManifestException('内置文件已变化，拒绝上传');
    await begin(id,o);
    OpStream? stream;
    try {
      final sep=Platform.pathSeparator;
      stream=await link.open('agent.upgrade',{
        'manifest':base64.encode(await File('${b.dir}${sep}manifest.json').readAsBytes()),
        'signature':await File('${b.dir}${sep}manifest.sig').readAsString(),
        'policy':base64.encode(p.bytes), 'policy_signature':p.signature,
      },Priority.bulk);
      final ready=await stream.response() as Map;
      await record(id,state:'uploading',job:ready['id'] as String);
      var sent=0;
      await for(final chunk in File(b.path).openRead()){
        for(var off=0;off<chunk.length;off+=65536){final end=(off+65536).clamp(0,chunk.length);await stream.sendData(chunk.sublist(off,end));sent+=end-off;progress?.call('上传已签名 agent',sent/b.manifest.size);}
      }
      await stream.sendEnd();await stream.close();
      await record(id,state:'waiting',message:'等待文件传输结束和 30 秒安静窗口');
      progress?.call('等待文件传输结束和 30 秒安静窗口；最长 15 分钟',null);
      final result=await stream.response().timeout(const Duration(minutes:16)) as Map;
      await record(id,state:result['state'] as String,job:result['id'] as String,message:'升级已提交；独立进程运行，断线后会重新查询');
    } on Object catch(e) {
      final r=app.profile.server(id)?.upgrade;
      // A lost response is not a failed upgrade. Keep the durable job id and
      // query after reconnect rather than uploading the same target again.
      final refused = e is OpError && e.code != codeUnavailable;
      await record(id,state:refused ? 'refused' : r?.job==null ? 'failed' : 'interrupted',message:e is OpError?e.message:'连接中断，升级结果待查询',blockTarget:false);
      stream?.reset();rethrow;
    }
  }
}
