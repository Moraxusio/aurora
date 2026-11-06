// Aurora 3 client (D-70): the server list on the left, the selected server
// on the right. Windows desktop first (M1).
import 'package:flutter/material.dart';

import 'state/app_state.dart';
import 'ui/add_server.dart';
import 'ui/server_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  await app.init();
  runApp(AuroraApp(app: app));
}

class AuroraApp extends StatelessWidget {
  final AppState app;
  const AuroraApp({super.key, required this.app});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Aurora',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF3B82F6), useMaterial3: true, fontFamily: 'Microsoft YaHei UI'),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF3B82F6), brightness: Brightness.dark, useMaterial3: true, fontFamily: 'Microsoft YaHei UI'),
        home: Home(app: app),
      );
}

class Home extends StatelessWidget {
  final AppState app;
  const Home({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        if (!app.ready) return _StoreProblem(app: app);
        final p = app.profile;
        final sel = p.selected;
        return Scaffold(
          body: Row(children: [
            SizedBox(
              width: 260,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Column(children: [
                  ListTile(title: Text('Aurora', style: Theme.of(context).textTheme.titleLarge)),
                  Expanded(
                    child: ListView(children: [
                      for (final s in p.servers)
                        ListTile(
                          selected: s.id == sel,
                          leading: _dot(app.status(s.id).state.name),
                          title: Text(s.name),
                          subtitle: Text(s.ssh?.host ?? ''),
                          onTap: () => app.select(s.id),
                        ),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton.icon(
                      onPressed: () async {
                        await Navigator.push(context, MaterialPageRoute(builder: (_) => AddServerPage(app: app)));
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('添加服务器'),
                    ),
                  ),
                ]),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: sel == null || p.server(sel) == null
                  ? const Center(child: Text('添加一台服务器开始使用'))
                  : ServerPage(key: ValueKey(sel), app: app, id: sel),
            ),
          ]),
        );
      },
    );
  }

  static Widget _dot(String state) => Icon(
        state == 'connected' ? Icons.circle : Icons.circle_outlined,
        size: 12,
        color: switch (state) { 'connected' => Colors.green, 'failed' => Colors.red, 'waiting' => Colors.orange, _ => null },
      );
}

class _StoreProblem extends StatelessWidget {
  final AppState app;
  const _StoreProblem({required this.app});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('无法打开本机保存的服务器列表', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  SelectableText(app.storeError ?? ''),
                  if (app.storeUnreadable) ...[
                    const SizedBox(height: 12),
                    const Text('文件可能属于另一个 Windows 用户或另一台电脑。可以把它移到一边、从空列表开始；原文件不会被删除。'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () async {
                        final aside = await app.resetProfile();
                        if (context.mounted && aside != null) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('原文件已移到 $aside')));
                        }
                      },
                      child: const Text('移到一边，从空列表开始'),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        ),
      );
}
