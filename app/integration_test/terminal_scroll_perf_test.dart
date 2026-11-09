import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/main.dart';
import 'package:aurora/state/app_state.dart';
import 'package:aurora_profile/aurora_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import 'helpers.dart';
import 'native_wheel.dart';
import 'terminal_mouse_fixture.dart';

const addr = String.fromEnvironment('AURORA3_UI_ADDR');
const pin = String.fromEnvironment('AURORA3_UI_PIN');
const token = String.fromEnvironment('AURORA3_UI_TOKEN');
const out = String.fromEnvironment('AURORA3_PERF_OUT');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Windows wheel reaches a live full-screen tmux program during redraws and switches',
    (t) async {
      // LiveTest normally drops device pointer input (only synthetic test
      // gestures propagate). This test intentionally covers the Windows path.
      final propagate = t.binding.shouldPropagateDevicePointerEvents;
      t.binding.shouldPropagateDevicePointerEvents = true;
      addTearDown(
        () => t.binding.shouldPropagateDevicePointerEvents = propagate,
      );
      final dir = await Directory.systemTemp.createTemp(
        'aurora3-native-wheel-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final app = AppState();
      await app.initAt('${dir.path}\\profile.bin');
      await app.update((p) {
        final server = ServerEntry(
          id: 'fixture',
          name: 'fixture',
          direct: DirectParams(
            port: 17791,
            addrs: [addr],
            pin: pin,
            token: token,
          ),
        );
        p.servers.add(server);
        p.selected = server.id;
        p.proxySources.add(
          ProxySource(
            id: 'synthetic',
            name: 'synthetic',
            nodes: [
              for (var i = 0; i < 2000; i++)
                {
                  'name': '$i',
                  'proto': 'trojan',
                  'host': 'node-$i.invalid',
                  'port': 443,
                  'secret': 'synthetic',
                },
            ],
          ),
        );
      });
      await t.pumpWidget(AuroraApp(app: app));
      await waitFor(t, find.textContaining('127.0.0.1:17791'));
      final link = app.link('fixture')!;
      await activity(t, '文件', title: '文件');
      await waitFor(t, find.text('docs'));
      await click(t, find.text('docs'));
      await waitFor(t, find.textContaining('readme.txt'));
      await click(t, find.textContaining('readme.txt').first);
      await waitFor(t, find.byType(FileEditor));
      final ws = t.widget<FileEditor>(find.byType(FileEditor)).ws;
      await link.call('fs.write', {
        'root': 'home',
        'path': '/mouse_fixture.py',
        'content': terminalMouseFixture,
        'create': true,
      });
      await link.call('session.create', {'name': 'wheel-fixture'});
      openSession(ws, 'wheel-fixture');
      await waitFor(t, find.byType(TerminalView));
      final terminal = t
          .widget<TerminalView>(find.byType(TerminalView))
          .terminal;
      String screen() => [
        for (var i = 0; i < terminal.buffer.lines.length; i++)
          terminal.buffer.lines[i].toString(),
      ].join('\n');
      await waitUntil(t, () => screen().contains(r'$'), 'shell prompt');
      void start() => terminal.onOutput!(
        'python3 -u /tmp/aurora3-ui-agent/home/mouse_fixture.py /tmp/aurora3-ui-agent/home/mouse_status.json\r',
      );
      start();
      await waitUntil(
        t,
        () => screen().contains('WHEEL up='),
        'full-screen mouse fixture',
      );
      final native = NativeWheel()..focus();
      await t.pump(const Duration(milliseconds: 300));

      Future<Map> status() async {
        final r = await link.call('fs.read', {
          'root': 'home',
          'path': '/mouse_status.json',
        }) as Map;
        return jsonDecode(r['content'] as String) as Map;
      }

      final timings = <ui.FrameTiming>[];
      void onTiming(List<ui.FrameTiming> value) => timings.addAll(value);
      SchedulerBinding.instance.addTimingsCallback(onTiming);
      addTearDown(
        () => SchedulerBinding.instance.removeTimingsCallback(onTiming),
      );
      final samples = <Map<String, Object>>[];
      Future<void> notches(String name, bool up, {int count = 12}) async {
        native.focus();
        await t.pump(const Duration(milliseconds: 300));
        final before = await status();
        timings.clear();
        for (var i = 0; i < count; i++) {
          final at =
              t.getTopLeft(find.byType(TerminalView)) + const Offset(100, 100);
          native.send(at, t.view.devicePixelRatio, up: up);
          await t.pump(const Duration(milliseconds: 25));
        }
        await t.pump(const Duration(milliseconds: 250));
        final after = await status();
        final sent =
            (after[up ? 'up' : 'down'] as int) -
            (before[up ? 'up' : 'down'] as int);
        final wrong =
            (after[up ? 'down' : 'up'] as int) -
            (before[up ? 'down' : 'up'] as int);
        expect(
          sent,
          greaterThanOrEqualTo(count),
          reason: '$name: native wheel reports arrived inside tmux',
        );
        expect(
          sent,
          lessThanOrEqualTo(count * 10),
          reason: '$name: no replay of lifetime scroll counters',
        );
        expect(wrong, 0, reason: '$name: no wrong-direction events');
        int maximum(Iterable<int> values) =>
            values.fold(0, (a, b) => a > b ? a : b);
        final sample = <String, Object>{
          'what': name,
          'native_notches': count,
          'received_reports': sent,
          'build_worst_us': maximum(
            timings.map((f) => f.buildDuration.inMicroseconds),
          ),
          'raster_worst_us': maximum(
            timings.map((f) => f.rasterDuration.inMicroseconds),
          ),
          'slow_frames': timings
              .where(
                (f) =>
                    f.buildDuration.inMicroseconds > 16667 ||
                    f.rasterDuration.inMicroseconds > 16667,
              )
              .length,
        };
        samples.add(sample);
        // ignore: avoid_print
        print('WHEEL-PERF $sample');
      }

      await notches('first program, down', false);
      await notches('first program, up', true);
      terminal.onOutput!('q');
      // tmux itself keeps the outer terminal in alternate mode even when its
      // foreground program is a shell; observe the program's exit marker.
      await waitUntil(
        t,
        () => screen().contains('MOUSE-FIXTURE-EXIT'),
        'first program exits',
      );
      start();
      await waitUntil(
        t,
        () => terminal.isUsingAltBuffer && screen().contains('WHEEL up='),
        'second program enters',
      );
      await notches('second program, down', false);
      final switching = <int>[];
      for (var i = 0; i < 10; i++) {
        timings.clear();
        ws.activate('file:home:/docs/readme.txt');
        await t.pump(const Duration(milliseconds: 20));
        ws.activate('term:wheel-fixture');
        await t.pump(const Duration(milliseconds: 50));
        switching.addAll(timings.map((f) => f.buildDuration.inMicroseconds));
      }
      await notches('after ten tab switches, up', true);
      await click(
        t,
        find.byTooltip('文件').first,
      ); // hide the side bar and change terminal geometry
      await t.pump(const Duration(milliseconds: 150));
      await notches('after sidebar resize, down', false);
      terminal.onOutput!('q');
      await waitUntil(
        t,
        () => screen().contains('MOUSE-FIXTURE-EXIT'),
        'fixture cleanup',
      );
      if (out.isNotEmpty) {
        await File(out).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'mode': const bool.fromEnvironment('dart.vm.profile')
                ? 'profile'
                : 'debug',
            'samples': samples,
            'tab_build_times_us': switching,
          }),
        );
      }
      await link.call('session.kill', {'name': 'wheel-fixture'});
      await app.disconnect('fixture');
      await t.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );
}
