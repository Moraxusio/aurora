import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aurora/features/ai/ai_studio_view.dart';
import 'package:aurora/features/ai/ai_transcript.dart';
import 'package:aurora/features/files/file_editor.dart';
import 'package:aurora/features/monitor/monitor_view.dart';
import 'package:aurora/features/terminal/terminal_feature.dart';
import 'package:aurora/kernel/editor_tab.dart';
import 'package:aurora/kernel/registry.dart';
import 'package:aurora/kernel/shell.dart';
import 'package:aurora/kernel/workspace.dart';
import 'package:aurora/main.dart';
import 'package:aurora_wire/aurora_wire.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:xterm/xterm.dart';

import '../test/support/monitor_workflow.dart';
import '../test/support/workspace_fixture.dart';
import '../test/ai_runtime_test.dart' show EventStream;
import 'native_window.dart';

class _ConcurrentLink extends MonitorWorkbenchLink {
  final events = EventStream();
  int aiAttaches = 0;
  _ConcurrentLink(super.features);
  @override
  Future<OpStream> open(
    String op, [
    Object? args,
    Priority priority = Priority.interactive,
  ]) {
    if (op == 'ai.stream') {
      aiAttaches++;
      return Future.value(events);
    }
    return super.open(op, args, priority);
  }

  @override
  Future<Object?> call(
    String op, [
    Object? args,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    final result = await super.call(op, args, timeout);
    if (op == 'ai.get') {
      final response = result as Map;
      response['running'] = true;
      final messages = response['session']['messages'] as List;
      messages.first['parts'][0]['text'] = List.generate(
        80,
        (i) =>
            'History paragraph $i: retain the reading anchor while the monitor, terminal and AI stream update.',
      ).join('\n\n');
    }
    return result;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'production desktop monitor and concurrent workbench frame budgets',
    (t) async {
      const output = String.fromEnvironment('AURORA_REVIEW_OUT');
      const enforce = bool.fromEnvironment(
        'AURORA_ENFORCE_BUDGET',
        defaultValue: true,
      );
      expect(output, isNotEmpty);
      final frame = GlobalKey();
      Future<void> screenshot(String name) async {
        final boundary =
            frame.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$output-$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      await exerciseMonitor(t, frame: frame, capture: screenshot);

      final features = Features();
      final link = _ConcurrentLink(features);
      final app = WorkspaceApp(wire: link);
      await t.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: AuroraApp(app: app),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 8; i++) {
          await t.pump(const Duration(milliseconds: 60));
        }
        expect(t.takeException(), isNull);
        expect(find.byType(ErrorWidget, skipOffstage: false), findsNothing);
      }

      await settle();
      final ws =
          (t.state(find.byType(Shell)) as dynamic).debugWorkspace as Workspace;
      final timings = <ui.FrameTiming>[];
      void onTimings(List<ui.FrameTiming> frames) => timings.addAll(frames);
      SchedulerBinding.instance.addTimingsCallback(onTimings);
      final samples = <Map<String, Object>>[];
      Future<void> measure(String name, Future<void> Function() task) async {
        await settle();
        timings.clear();
        final watch = Stopwatch()..start();
        await task();
        watch.stop();
        await t.pump(const Duration(milliseconds: 1200));
        final builds =
            timings.map((f) => f.buildDuration.inMicroseconds).toList()..sort();
        final rasters =
            timings.map((f) => f.rasterDuration.inMicroseconds).toList()
              ..sort();
        int p(List<int> data, double q) =>
            data.isEmpty ? 0 : data[((data.length - 1) * q).round()];
        samples.add({
          'operation': name,
          'frames': timings.length,
          'elapsed_us': watch.elapsedMicroseconds,
          'build_p95_us': p(builds, .95),
          'raster_p95_us': p(rasters, .95),
          'build_max_us': p(builds, 1),
          'raster_max_us': p(rasters, 1),
          'over_16ms': timings
              .where(
                (f) =>
                    f.buildDuration.inMicroseconds > 16667 ||
                    f.rasterDuration.inMicroseconds > 16667,
              )
              .length,
        });
        await File('$output-frames.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(samples));
        expect(t.takeException(), isNull);
      }

      try {
        for (var i = 0; i < 12; i++) {
          ws.openTab(
            fileEditorTab(
              ws,
              root: 'home',
              path: '/project/src/document-$i.dart',
            ),
          );
          await settle();
        }
        ws.activate('file:home:/project/src/document-0.dart');
        await settle();
        final doc = t.state<FileEditorState>(find.byType(FileEditor));
        final controller = t
            .widget<CodeEditor>(find.byType(CodeEditor))
            .controller;
        doc.text = 'const unsaved = true;\n';
        ws.pinTab('file:home:/project/src/document-0.dart');
        openSession(ws, 'main');
        ws.openTab(
          EditorTab(
            id: 'ai:foundation',
            title: 'GUI audit',
            icon: Icons.auto_awesome_outlined,
            builder: (_) => AiStudioView(ws: ws, initialSessionId: 'ses_1'),
          ),
        );
        ws.openTab(monitorTab(ws));
        await settle();
        final prompt = find.byKey(const ValueKey('ai-prompt-input'));
        final draft = t.widget<TextField>(prompt).controller!;
        draft.text = 'unsent foundation audit draft';
        final transcript =
            t
                    .widget<CustomScrollView>(
                      find.byKey(const ValueKey('ai-transcript')),
                    )
                    .controller!
                as AiTranscriptController;
        transcript.reveal('u');
        await settle();
        transcript.jumpTo(transcript.offset + 160);
        await settle();
        final terminal = t
            .widget<TerminalView>(find.byType(TerminalView))
            .terminal;
        final details = find.text('设备详情与进程 · 1 个');
        await revealMonitor(t, details);
        await settle();
        await t.tap(details);
        await settle();
        await measure(
          'monitor + AI stream + terminal output + sidebar drag',
          () async {
            final handle = find.byKey(const ValueKey('sidebar-resize'));
            final start = t.getCenter(handle);
            final gesture = await t.startGesture(
              start,
              kind: PointerDeviceKind.mouse,
            );
            for (var i = 0; i < 80; i++) {
              final dx = (i < 40 ? i : 80 - i).toDouble();
              link.terminalStreams.single.output(
                'synthetic output frame $i\r\n' * 20,
              );
              link.events.emit({'type': 'text.delta', 'delta': 'Chunk $i. '});
              await gesture.moveTo(start + Offset(dx, 0));
              await t.pump(const Duration(milliseconds: 16));
              expect(
                (t.getCenter(handle).dx - start.dx - dx).abs(),
                lessThan(.2),
              );
            }
            await gesture.up();
          },
        );
        await measure(
          'retained editor switching beside AI and terminal',
          () async {
            for (var i = 0; i < 48; i++) {
              ws.activate('file:home:/project/src/document-${i % 12}.dart');
              link.terminalStreams.single.output('background $i\r\n' * 8);
              link.events.emit({
                'type': 'text.delta',
                'delta': 'Background $i. ',
              });
              await t.pump(const Duration(milliseconds: 16));
            }
          },
        );
        await measure('expanded monitor scroll and refresh', () async {
          ws.activate('monitor');
          await settle();
          await revealMonitor(t, details);
          final scroll = find
              .descendant(
                of: find.byType(MonitorTab),
                matching: find.byType(Scrollable),
              )
              .first;
          final position = t.state<ScrollableState>(scroll).position;
          final detailOffset = position.pixels;
          for (var i = 0; i < 48; i++) {
            position.jumpTo(
              (detailOffset + (i.isEven ? 0 : 80)).clamp(
                position.minScrollExtent,
                position.maxScrollExtent,
              ),
            );
            await t.pump(const Duration(milliseconds: 16));
          }
        });
        final readingOffset = transcript.offset;
        final polls = link.counts['gpu.info']!;
        await measure('30s concurrent polling and streaming soak', () async {
          for (var i = 0; i < 300; i++) {
            link.terminalStreams.single.output('soak frame $i\r\n' * 4);
            link.events.emit({'type': 'text.delta', 'delta': 'Stream $i. '});
            await t.pump(const Duration(milliseconds: 100));
          }
        });
        expect(link.counts['gpu.info']! - polls, greaterThanOrEqualTo(12));
        expect(
          transcript.offset,
          closeTo(readingOffset, .5),
          reason: 'streaming must not steal the reading anchor',
        );
        await screenshot('loaded');
        final window = NativeTestWindow();
        try {
          for (final size in [
            const Size(1200, 800),
            const Size(1000, 700),
            const Size(1500, 1000),
          ]) {
            window.resize(size);
            await settle();
            expect(window.bounds.width, closeTo(size.width, 1));
            expect(window.bounds.height, closeTo(size.height, 1));
            ws.activate('monitor');
            await settle();
            await revealMonitor(t, details);
            await settle();
            expect(find.text('PID 4123'), findsOneWidget);
          }
        } finally {
          window.restore();
          await settle();
        }
        ws.activate('file:home:/project/src/document-0.dart');
        await settle();
        expect(
          t.widget<CodeEditor>(find.byType(CodeEditor)).controller,
          same(controller),
        );
        expect(doc.text, 'const unsaved = true;\n');
        expect(doc.dirty, isTrue);
        expect(
          t.widget<TerminalView>(find.byType(TerminalView)).terminal,
          same(terminal),
        );
        expect(link.terminalStreams.length, 1);
        expect(link.aiAttaches, 1);
        expect(t.widget<TextField>(prompt).controller, same(draft));
        expect(draft.text, 'unsent foundation audit draft');
        expect(
          ws.tabLayout.pinned,
          contains('file:home:/project/src/document-0.dart'),
        );
        await File('$output.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'native_engine': true,
            'production_root': true,
            'profile': const bool.fromEnvironment('dart.vm.profile'),
            'physical_size': {
              'width': t.view.physicalSize.width,
              'height': t.view.physicalSize.height,
            },
            'device_pixel_ratio': t.view.devicePixelRatio,
            'samples': samples,
            'dirty_buffer_retained': doc.dirty,
            'terminal_attaches': link.terminalStreams.length,
            'ai_attaches': link.aiAttaches,
            'ai_draft_retained': draft.text == 'unsent foundation audit draft',
            'reading_anchor_retained': true,
            'native_window_sizes': ['1200x800', '1000x700', '1500x1000'],
            'soak_gpu_polls': link.counts['gpu.info']! - polls,
          }),
        );
        if (enforce) {
          for (final sample in samples) {
            expect(sample['frames'] as int, greaterThan(10));
            expect(
              sample['build_p95_us'] as int,
              lessThan(16667),
              reason: '${sample['operation']} UI budget',
            );
            expect(
              sample['raster_p95_us'] as int,
              lessThan(16667),
              reason: '${sample['operation']} GPU budget',
            );
            expect(
              sample['build_max_us'] as int,
              lessThan(100000),
              reason: 'no 100ms UI stalls',
            );
          }
        }
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(onTimings);
        await app.appearance.flush();
        await ws.flushViews();
        await t.pumpWidget(const SizedBox());
        app.dispose();
        features.dispose();
      }
    },
  );
}
