import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'add_server.dart';

Future<void> showAgentUpgrade(BuildContext context,AppState app,String id) async {
  final link=app.link(id),server=app.profile.server(id);
  if(link==null||server==null)return;
  final o=app.upgrades.offer(id,link);
  final confirmed=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
    title:Text('升级 agent：${o.current} → ${o.build?.manifest.version ?? '—'}'),
    content:Text(o.reason ?? (o.direct ? '校验内置发布签名后，经当前加密连接上传。等待文件传输结束及 30 秒安静窗口，再由独立进程切换和健康检查；失败自动回滚。终端进程保留，但连接会短暂中断。' : '当前 agent 不支持直连升级。将打开 SSH 兼容升级向导，核对原有主机指纹并使用内置签名版本；不会静默登录。')),
    actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('取消')),if(o.available)FilledButton(onPressed:()=>Navigator.pop(c,true),child:Text(o.direct?'确认升级':'打开 SSH 升级向导'))],
  ));
  if(confirmed!=true||!context.mounted)return;
  if(!o.direct){await Navigator.push(context,MaterialPageRoute(builder:(_)=>AddServerPage(app:app,existing:server)));return;}
  await showDialog<void>(context:context,barrierDismissible:false,builder:(_)=>_UpgradeProgress(app:app,id:id));
}

class _UpgradeProgress extends StatefulWidget{
  final AppState app;final String id;
  const _UpgradeProgress({required this.app,required this.id});
  @override State<_UpgradeProgress> createState()=>_UpgradeProgressState();
}
class _UpgradeProgressState extends State<_UpgradeProgress>{
  String note='正在准备升级';double? fraction;Timer? poll;bool submitted=false,checking=false;
  @override void initState(){super.initState();widget.app.addListener(changed);unawaited(start());poll=Timer.periodic(const Duration(seconds:2),(_)=>check());}
  void changed(){if(mounted)setState((){});}
  Future<void> start()async{
    final l=widget.app.link(widget.id);if(l==null)return;
    try{await widget.app.upgrades.directUpgrade(widget.id,l,progress:(n,f){if(mounted)setState((){note=n;fraction=f;});});}
    on Object catch(e){if(mounted)setState(()=>note='$e');}
    finally{if(mounted)setState(()=>submitted=true);}
  }
  Future<void> check()async{
    if(!submitted||checking)return;final l=widget.app.link(widget.id);if(l==null)return;checking=true;
    try{await widget.app.upgrades.recover(widget.id,l);}finally{checking=false;}
  }
  @override void dispose(){poll?.cancel();widget.app.removeListener(changed);super.dispose();}
  @override Widget build(BuildContext context){
    final r=widget.app.profile.server(widget.id)?.upgrade;
    return AlertDialog(title:const Text('agent 升级'),content:SizedBox(width:460,child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
      if(r?.terminal!=true)LinearProgressIndicator(value:fraction),const SizedBox(height:12),Text(note),if(r!=null)...[const SizedBox(height:8),Text('状态：${r.state}\n${r.message ?? ''}'),if(r.job!=null)SelectableText('任务：${r.job}')],
      const SizedBox(height:8),const Text('提交后关闭此窗口不会中止服务器的升级。重连或重新打开客户端时会查询任务状态。',style:TextStyle(fontSize:12)),
    ])),actions:[TextButton(onPressed:submitted?()=>Navigator.pop(context):null,child:const Text('关闭'))]);
  }
}

/// A passive connection-time version prompt: no upload until clicked and
/// explicitly confirmed. It also keeps interrupted jobs visible after restart.
class AgentUpgradeNotice extends StatelessWidget{
  final AppState app;final String id;
  const AgentUpgradeNotice({super.key,required this.app,required this.id});
  @override Widget build(BuildContext context){
    final l=app.link(id);if(l==null)return const SizedBox.shrink();
    final o=app.upgrades.offer(id,l),r=app.profile.server(id)?.upgrade;
    if(r!=null&&(!r.terminal||r.state=='interrupted')){return ListTile(dense:true,title:Text('agent 升级任务：${r.state}'),subtitle:Text(r.message??'重连后查询结果'),trailing:TextButton(onPressed:()=>app.upgrades.recover(id,l),child:const Text('查询结果')));}
    if(o.build==null||o.current==o.build!.manifest.version)return const SizedBox.shrink();
    final versionNewer=app.upgradePolicy?.revoked.contains(o.current)==true||o.available;
    if(!versionNewer)return const SizedBox.shrink();
    return ListTile(dense:true,leading:const Icon(Icons.system_update_alt),title:Text('agent ${o.current}；内置版本 ${o.build!.manifest.version}'),subtitle:Text(o.reason??(o.direct?'可通过加密直连安全升级':'旧 agent，需 SSH 兼容升级')),trailing:TextButton(onPressed:()=>showAgentUpgrade(context,app,id),child:const Text('升级 agent')));
  }
}
