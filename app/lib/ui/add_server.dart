// "Add server": SSH address and login, then the install over SSH (G5.6)
// with the host key shown for confirmation (D-2) and the four stages as
// progress. The SSH session ends when the install does (D-4).
import 'dart:async';

import 'package:aurora_install/aurora_install.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';

class AddServerPage extends StatefulWidget {
  final AppState app;

  /// Re-pair or reinstall an existing entry instead of adding one.
  final ServerEntry? existing;
  const AddServerPage({super.key, required this.app, this.existing});

  @override
  State<AddServerPage> createState() => _AddServerPageState();
}

enum _Phase { form, running, done }

class _AddServerPageState extends State<AddServerPage> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _host = TextEditingController(text: widget.existing?.ssh?.host ?? '');
  late final _port = TextEditingController(text: '${widget.existing?.ssh?.port ?? 22}');
  late final _user = TextEditingController(text: widget.existing?.ssh?.user ?? 'root');
  late final _password = TextEditingController(text: widget.existing?.ssh?.password ?? '');
  late final _key = TextEditingController(text: widget.existing?.ssh?.privateKey ?? '');
  late final _passphrase = TextEditingController(text: widget.existing?.ssh?.passphrase ?? '');
  late final _sudo = TextEditingController(text: widget.existing?.ssh?.sudoPassword ?? '');
  bool _useKey = false;
  bool _save = true;

  /// The agent instance of this client on the server (D-101). A server added
  /// here gets a new one; reinstalling an entry keeps its own, and an old
  /// entry (empty) stays on the default instance.
  late final String _instance = widget.existing != null ? widget.existing!.instance : newInstanceName();

  _Phase _phase = _Phase.form;
  final List<_StepRow> _steps = [];
  double? _upload;
  String? _error;
  InstallOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    _useKey = (widget.existing?.ssh?.privateKey ?? '').isNotEmpty;
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _user, _password, _key, _passphrase, _sudo]) {
      c.dispose();
    }
    super.dispose();
  }

  static const _labels = {
    InstallStep.connect: '登录 SSH',
    InstallStep.inspect: '检查服务器',
    InstallStep.upload: '上传 agent',
    InstallStep.probe: '探测',
    InstallStep.prepare: '准备与校验',
    InstallStep.switchOver: '切换',
    InstallStep.confirm: '确认新版本在运行',
    InstallStep.rollback: '回滚',
    InstallStep.read: '读取直连参数',
  };

  void _progress(InstallProgress p) {
    if (!mounted) return;
    setState(() {
      if (p.status == 'progress') {
        _upload = p.fraction;
        return;
      }
      final i = _steps.indexWhere((s) => s.step == p.step);
      final row = _StepRow(p.step, p.status, p.message);
      if (i < 0) {
        _steps.add(row);
      } else {
        _steps[i] = row;
      }
    });
  }

  /// D-2: an unknown host key is shown and must be confirmed; a known one
  /// must match; a changed one is refused with the old and new keys shown.
  Future<bool> _checkHostKey(String host, int port, HostKey k) async {
    final known = widget.app.profile.knownHost(host, port);
    if (known != null) {
      if (known.fingerprint == k.fingerprint) return true;
      if (!mounted) return false;
      await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
                title: const Text('服务器的主机密钥变了'),
                content: SelectableText('$host:$port 之前确认的密钥是\n${known.type} ${known.fingerprint}\n\n'
                    '现在收到的是\n${k.type} ${k.fingerprint}\n\n'
                    '可能是服务器重装了系统，也可能有人在中间冒充它。已停止登录，没有发送密码。'
                    '确认是重装后，可以在服务器详情里删除旧的记录再试。'),
                actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('知道了'))],
              ));
      return false;
    }
    if (!mounted) return false;
    final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
              title: const Text('第一次连接这台服务器'),
              content: SelectableText('请核对 $host:$port 的主机密钥指纹：\n\n${k.type}\n${k.fingerprint}\n\n'
                  '可以在服务器上运行 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 对照。'
                  '指纹一致再继续；确认后会记住它，以后自动比对。'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('指纹一致，继续')),
              ],
            ));
    if (ok == true) {
      await widget.app.update((p) => p.trustHost(host, port, k.type, k.fingerprint));
      return true;
    }
    return false;
  }

  Future<void> _run() async {
    if (!_form.currentState!.validate()) return;
    if (widget.app.builds.isEmpty) {
      setState(() => _error = widget.app.buildsError ?? '没有可用的 agent');
      return;
    }
    final host = _host.text.trim(), port = int.parse(_port.text.trim()), user = _user.text.trim();
    setState(() {
      _phase = _Phase.running;
      _steps.clear();
      _error = null;
      _upload = null;
    });
    _progress(InstallProgress(InstallStep.connect, 'start'));
    final cred = SshCredentials(
      user: user,
      password: _useKey ? null : _password.text,
      privateKey: _useKey ? _key.text : null,
      passphrase: _useKey && _passphrase.text.isNotEmpty ? _passphrase.text : null,
    );
    SshRemote remote;
    try {
      remote = await SshRemote.connect(host, port, cred, checkHostKey: (k) => _checkHostKey(host, port, k));
    } on SshException catch (e) {
      _progress(InstallProgress(InstallStep.connect, 'fail', e.message));
      setState(() {
        _phase = _Phase.form;
        _error = e.message;
      });
      return;
    }
    _progress(InstallProgress(InstallStep.connect, 'ok'));
    InstallOutcome o;
    try {
      final existing=widget.existing;
      final link=existing==null?null:widget.app.link(existing.id);
      if(existing!=null&&link!=null){final offer=widget.app.upgrades.offer(existing.id,link);if(offer.available)await widget.app.upgrades.begin(existing.id,offer);}
      final inst = Installer(remote, widget.app.builds,
          policy: widget.app.upgradePolicy,
          instance: _instance,
          sudoPassword: _sudo.text.isEmpty ? null : _sudo.text,
          serverName: _name.text.trim().isEmpty ? host : _name.text.trim(),
          onProgress: _progress);
      o = await inst.install();
      if(existing!=null&&widget.app.profile.server(existing.id)?.upgrade!=null){await widget.app.upgrades.record(existing.id,state:o.result,message:o.message,blockTarget:const {'rolled_back','rollback_failed'}.contains(o.result));}
    } on Object catch (e) {
      o = InstallOutcome('failed', '$e');
      final id=widget.existing?.id;
      if(id!=null && widget.app.profile.server(id)?.upgrade!=null) await widget.app.upgrades.record(id,state:'failed',message:o.message,blockTarget:false);
    } finally {
      await remote.close();
    }
    if (!mounted) return;
    if (o.ok) {
      // D-1: secrets are saved only when the user asked to.
      final ssh = SshLogin(
        host: host,
        port: port,
        user: user,
        password: _save && !_useKey ? _password.text : null,
        privateKey: _save && _useKey ? _key.text : null,
        passphrase: _save && _useKey && _passphrase.text.isNotEmpty ? _passphrase.text : null,
        sudoPassword: _save && _sudo.text.isNotEmpty ? _sudo.text : null,
      );
      await widget.app.saveInstalled(
          id: widget.existing?.id, name: _name.text.trim().isEmpty ? host : _name.text.trim(), ssh: ssh, o: o, instance: _instance);
    }
    setState(() {
      _outcome = o;
      _phase = o.ok ? _Phase.done : _Phase.form;
      _error = o.ok ? null : _explain(o);
    });
  }

  String _explain(InstallOutcome o) => switch (o.result) {
        'rolled_back' => '新版本没有正常启动，已恢复到安装前的状态。${o.message}',
        'rollback_failed' => '安装失败，而且回滚没有完成。服务器上保留了回滚目录 ${o.kept ?? ''}，请检查。${o.message}',
        'refused' => '服务器拒绝安装，没有做任何改动：${o.message}',
        'up_to_date' => o.message,
        _ => o.message,
      };

  @override
  Widget build(BuildContext context) {
    final title = widget.existing == null ? '添加服务器' : '重新安装或配对：${widget.existing!.name}';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(padding: const EdgeInsets.all(24), children: [
            // Installing needs the signed agent shipped with the app (D-3);
            // a development build has none next to it.
            if (widget.app.builds.isEmpty) ...[
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.warning_amber),
                  title: const Text('无法安装：缺少内置的 agent'),
                  subtitle: SelectableText(widget.app.buildsError ?? ''),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (widget.app.testKey != null) ...[
              Card(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.science_outlined),
                  title: const Text('测试模式'),
                  subtitle: Text('agent 的签名用测试密钥 ${widget.app.testKey} 校验，不是发布密钥（AURORA3_TRUST_KEY）'),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_phase != _Phase.done) _formView(),
            if (_phase == _Phase.done && _outcome != null) ..._doneView(),
            if (_steps.isNotEmpty) ...[const SizedBox(height: 24), _progressView()],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(padding: const EdgeInsets.all(16), child: SelectableText(_error!)),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  /// The finished page leads with the result and the way out; the stage list
  /// stays below for reference.
  List<Widget> _doneView() => [
        Card(
          child: ListTile(
            leading: const Icon(Icons.check_circle, color: Colors.green),
            title: Text(_outcome!.result == 'up_to_date' ? '服务器上已是最新版本，已保存直连参数' : '安装完成，版本 ${_outcome!.version ?? ''}'),
            subtitle: const Text('之后的连接都走直连，不再需要 SSH。'),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('完成')),
      ];

  Widget _formView() {
    final busy = _phase == _Phase.running;
    InputDecoration d(String l, [String? h]) => InputDecoration(labelText: l, helperText: h, border: const OutlineInputBorder());
    String? req(String? v) => v == null || v.trim().isEmpty ? '必填' : null;
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextFormField(controller: _name, enabled: !busy, decoration: d('名称', '可选，默认用地址')),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(flex: 3, child: TextFormField(controller: _host, enabled: !busy, decoration: d('SSH 地址'), validator: req)),
          const SizedBox(width: 12),
          Expanded(
              child: TextFormField(
                  controller: _port,
                  enabled: !busy,
                  decoration: d('端口'),
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    return n == null || n < 1 || n > 65535 ? '1–65535' : null;
                  })),
        ]),
        const SizedBox(height: 12),
        TextFormField(controller: _user, enabled: !busy, decoration: d('用户名'), validator: req),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: false, label: Text('密码')), ButtonSegment(value: true, label: Text('私钥'))],
          selected: {_useKey},
          onSelectionChanged: busy ? null : (s) => setState(() => _useKey = s.first),
        ),
        const SizedBox(height: 12),
        if (!_useKey)
          TextFormField(controller: _password, enabled: !busy, obscureText: true, decoration: d('密码'), validator: req)
        else ...[
          TextFormField(
              controller: _key,
              enabled: !busy,
              maxLines: 5,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
              decoration: d('私钥', '粘贴 OpenSSH 或 PEM 格式的私钥'),
              validator: req),
          const SizedBox(height: 12),
          TextFormField(controller: _passphrase, enabled: !busy, obscureText: true, decoration: d('私钥密码', '私钥没有密码就留空')),
        ],
        const SizedBox(height: 12),
        TextFormField(controller: _sudo, enabled: !busy, obscureText: true, decoration: d('sudo 密码', '用 root 登录，或 sudo 不要密码时留空')),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _save,
          onChanged: busy ? null : (v) => setState(() => _save = v ?? false),
          title: const Text('在本机加密保存这些密码'),
          subtitle: const Text('用 Windows 的 DPAPI 加密，只有当前 Windows 用户能读。不保存的话，重新安装时要再输入。'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy || widget.app.builds.isEmpty ? null : _run,
          icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download),
          label: Text(busy ? '正在安装…' : '安装并连接'),
        ),
      ]),
    );
  }

  Widget _progressView() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(children: [
          for (final s in _steps)
            ListTile(
              dense: true,
              leading: switch (s.status) {
                'ok' => const Icon(Icons.check, color: Colors.green),
                'fail' => const Icon(Icons.close, color: Colors.red),
                _ => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              },
              title: Text(_labels[s.step] ?? s.step.name),
              subtitle: s.step == InstallStep.upload && s.status == 'start' && _upload != null
                  ? LinearProgressIndicator(value: _upload)
                  : (s.message.isEmpty ? null : Text(s.message)),
            ),
        ]),
      ),
    );
  }
}

class _StepRow {
  final InstallStep step;
  final String status;
  final String message;
  _StepRow(this.step, this.status, this.message);
}
