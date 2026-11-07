// How long it takes to switch between the things in the window, measured on
// the real window against a real agent (agent/tools/ui-agent.sh):
//   - a side bar to another (terminal, files, git, systemd, forwards);
//   - an editor tab to another;
//   - the same side bar chosen again after one visit.
// For each switch: milliseconds until the screen has stopped changing, the
// frames that took longer than one 60 Hz frame (16.7 ms) to build or to
// rasterise, and how many requests went to the agent. Results are printed as
// "PERF ..." lines and written to a JSON file (--dart-define=AURORA3_PERF_OUT).
//
// What it can say depends on the build mode: `flutter test` builds a debug
// app (JIT, assertions), where everything is several times slower than the
// release build a user runs. Run it through app/tool/switch_perf.ps1, which
// builds in profile mode and reads the numbers that count.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/main.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers.dart';

const addr = String.fromEnvironment('AURORA3_UI_ADDR');
const pin = String.fromEnvironment('AURORA3_UI_PIN');
const token = String.fromEnvironment('AURORA3_UI_TOKEN');
const out = String.fromEnvironment('AURORA3_PERF_OUT');

class Sample {
  final String what;
  final int settleMs, frames, slow, worstMs, requests;
  Sample(this.what, this.settleMs, this.frames, this.slow, this.worstMs, this.requests);
  Map<String, Object> toJson() => {'what': what, 'settle_ms': settleMs, 'frames': frames, 'slow_frames': slow, 'worst_frame_ms': worstMs, 'requests': requests};
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('switching between side bars and tabs', (t) async {
    expect(addr, isNotEmpty, reason: 'run through app/tool/switch_perf.ps1');
    t.view.physicalSize = const Size(1700, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });
    final dir = await Directory.systemTemp.createTemp('aurora3-perf-');
    addTearDown(() => dir.delete(recursive: true));
    final store = await ProfileStore.open('${dir.path}\\profile.bin', DpapiSealer());
    await store.update((p) {
      final s = ServerEntry.create('wsl-perf', ssh: SshLogin(host: '127.0.0.1', user: 'root'));
      s.direct = DirectParams(port: 17791, addrs: [addr], pin: pin, token: token);
      p.servers.add(s);
      p.selected = s.id;
    });
    await store.close();
    final app = AppState();
    await app.initAt('${dir.path}\\profile.bin');
    await t.pumpWidget(AuroraApp(app: app));
    await waitFor(t, find.textContaining('127.0.0.1:17791'), upTo: const Duration(seconds: 20));
    await settle(t, upTo: const Duration(seconds: 2));

    // every frame's build and raster time, as the engine reports them
    final timings = <ui.FrameTiming>[];
    void onTimings(List<ui.FrameTiming> l) => timings.addAll(l);
    SchedulerBinding.instance.addTimingsCallback(onTimings);
    addTearDown(() => SchedulerBinding.instance.removeTimingsCallback(onTimings));

    // requests the app makes: counted at the one place every request starts
    final link = app.link(app.profile.servers.first.id)!;
    final before = Link.requestCount;

    Future<Sample> measure(String what, Future<void> Function() action, {Finder? until, String? untilText}) async {
      timings.clear();
      final r0 = Link.requestCount;
      final sw = Stopwatch()..start();
      await action();
      // wait for the screen to stop changing: two quiet frames in a row
      var quiet = 0;
      var last = await _fingerprint(t);
      final end = DateTime.now().add(const Duration(seconds: 15));
      while (quiet < 3 && DateTime.now().isBefore(end)) {
        await t.pump(const Duration(milliseconds: 16));
        final now = await _fingerprint(t);
        quiet = now == last ? quiet + 1 : 0;
        last = now;
        if (until != null && until.evaluate().isEmpty) quiet = 0;
      }
      final settleMs = sw.elapsedMilliseconds - 3 * 16;
      await t.pump(const Duration(milliseconds: 100)); // late frame timings arrive
      int ms(ui.FrameTiming f) => (f.totalSpan.inMicroseconds / 1000).round();
      final slow = timings.where((f) => ms(f) > 17).length;
      final worst = timings.isEmpty ? 0 : timings.map(ms).reduce((a, b) => a > b ? a : b);
      return Sample(what, settleMs, timings.length, slow, worst, Link.requestCount - r0);
    }

    final samples = <Sample>[];
    // First visit to each side bar, then back to it a second time.
    final bars = [
      ('terminal', '终端', '终端会话'),
      ('files', '文件', '文件'),
      ('git', '源代码管理', '源代码管理'),
      ('systemd', '系统服务', '系统服务'),
      ('net', '端口转发', '端口转发'),
    ];
    for (final round in ['first visit', 'second visit']) {
      for (final (key, tip, title) in bars) {
        if (find.text(title.toUpperCase()).evaluate().isNotEmpty) {
          // the side bar is already shown: a click would hide it; go to another first
          await click(t, find.byTooltip(bars.firstWhere((b) => b.$1 != key).$2).first);
          await settle(t, upTo: const Duration(milliseconds: 800));
        }
        samples.add(await measure('$key side bar, $round', () => click(t, find.byTooltip(tip).first)));
      }
    }
    // Editor tabs: open two files and a diff, then switch between them.
    await click(t, find.byTooltip('文件').first);
    await settle(t, upTo: const Duration(milliseconds: 800));
    if (find.text('docs').evaluate().isNotEmpty) await click(t, find.text('docs'));
    await waitFor(t, find.textContaining('readme.txt'));
    await click(t, find.textContaining('readme.txt').first);
    await settle(t, upTo: const Duration(seconds: 1));
    await click(t, find.text('proj'));
    await settle(t, upTo: const Duration(seconds: 1));
    await click(t, find.textContaining('a.txt').first);
    await settle(t, upTo: const Duration(seconds: 1));
    final tabs = ['readme.txt', 'a.txt'];
    for (var i = 0; i < 4; i++) {
      final name = tabs[i % 2];
      samples.add(await measure('editor tab $name', () => click(t, find.descendant(of: find.byType(ListView), matching: find.textContaining(name)).first)));
    }

    // print and save
    for (final s in samples) {
      // ignore: avoid_print
      print('PERF ${s.what.padRight(34)} settle ${s.settleMs.toString().padLeft(5)} ms   frames ${s.frames.toString().padLeft(3)}   slow(>17ms) ${s.slow.toString().padLeft(3)}   worst ${s.worstMs.toString().padLeft(4)} ms   requests ${s.requests}');
    }
    // ignore: avoid_print
    print('PERF total requests during the run: ${Link.requestCount - before}');
    if (out.isNotEmpty) {
      await File(out).writeAsString(const JsonEncoder.withIndent('  ').convert({
        'mode': const bool.fromEnvironment('dart.vm.product') ? 'release' : (const bool.fromEnvironment('dart.vm.profile') ? 'profile' : 'debug'),
        'samples': [for (final s in samples) s.toJson()],
      }));
    }
    // the link must still be the same one: no reconnect happened during the measurement
    expect(identical(link, app.link(app.profile.servers.first.id)), isTrue);
  });
}

/// A cheap fingerprint of what is on screen: the number of widgets and the
/// text of the first few Text widgets, enough to tell that nothing changed.
Future<String> _fingerprint(WidgetTester t) async {
  final texts = find.byType(Text).evaluate().take(60).map((e) => (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText() ?? '').join('|');
  return '${t.binding.rootElement?.debugDescribeChildren().length}/${find.byType(Widget).evaluate().length}/$texts';
}
