// Aurora 3 client (D-70). The window is the kernel's shell (lib/kernel); the
// features (lib/features) plug into it (D-78). Windows desktop first (M1).
import 'package:flutter/material.dart';

import 'kernel/input_mode.dart';
import 'kernel/registry.dart';
import 'kernel/shell.dart';
import 'kernel/widgets.dart';
import 'kernel/desktop_lifecycle.dart';
import 'kernel/window_frame.dart';
import 'state/app_state.dart';
import 'theme/ide_theme.dart';
import 'ui/add_server.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  await app.init();
  runApp(AuroraApp(app: app));
}

class AuroraApp extends StatefulWidget {
  final AppState app;
  const AuroraApp({super.key, required this.app});
  @override
  State<AuroraApp> createState() => _AuroraAppState();
}

class _AuroraAppState extends State<AuroraApp> {
  final _features = Features();
  final _input = InputMode();

  @override
  void initState() {
    super.initState();
    DesktopLifecycle.start();
    widget.app.addListener(_onApp);
  }

  @override
  void dispose() {
    widget.app.removeListener(_onApp);
    DesktopLifecycle.stop();
    _features.dispose();
    _input.dispose();
    super.dispose();
  }

  ThemeMode get _themeMode => switch (widget.app.ready ? widget.app.profile.editor.theme : 'system') {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  late ThemeMode _theme = _themeMode;

  // The theme follows the settings page. The app notifies on every connection
  // change; only a different theme rebuilds the MaterialApp.
  void _onApp() {
    final t = _themeMode;
    if (t != _theme && mounted) setState(() => _theme = t);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // touch or pointer: decided by the last input (kernel/input_mode.dart)
      behavior: HitTestBehavior.translucent,
      onPointerDown: _input.onPointer,
      onPointerHover: _input.onPointer,
      child: MaterialApp(
        title: 'Aurora 3',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: Toast.key,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: _theme,
        builder: (context, child) => ValueListenableBuilder<bool>(valueListenable: DesktopLifecycle.visible,
          child: InputMode.scope(mode: _input, child: WindowChrome(child: child!)),
          builder: (_, visible, child) => ExcludeFocus(excluding: !visible,
            child: Offstage(offstage: !visible, child: TickerMode(enabled: visible, child: child!)))),
        home: Home(app: widget.app, features: _features),
      ),
    );
  }
}

class Home extends StatelessWidget {
  final AppState app;
  final Features features;
  const Home({super.key, required this.app, required this.features});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        if (!app.ready) return _StoreProblem(app: app);
        return Shell(app: app, features: features);
      },
    );
  }
}

class _StoreProblem extends StatelessWidget {
  final AppState app;
  const _StoreProblem({required this.app});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          const WindowDragArea(child: SizedBox(height: WindowFrame.height, width: double.infinity)),
          Expanded(child: Center(
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
          )),
        ]),
      );
}

// AddServerPage is opened by the shell; re-exported here for the tests.
typedef AddServer = AddServerPage;
