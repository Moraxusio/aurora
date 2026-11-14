// Anchored, lazy transcript. A stable center sliver permits direct navigation
// by message ID without walking/laying out the entire history. Reflow correction
// happens inside viewport layout, before paint; no queued scroll animations.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class _ReadingAnchor {
  final String id;
  final double fraction, y;
  final RenderObject? text;
  final int? character;
  final String? content;
  const _ReadingAnchor(
    this.id,
    this.fraction,
    this.y, [
    this.text,
    this.character,
    this.content,
  ]);
}

class AiTranscriptController extends ScrollController {
  final Map<String, _AnchorBox> _mounted = {};
  final ValueNotifier<String?> currentMessage = ValueNotifier(null);
  final ValueNotifier<bool> followsLatest = ValueNotifier(true);
  _ReadingAnchor? _held;
  _ReadingAnchor? _snapshot;
  void Function(String?)? _navigate;
  bool _resetting = false, _disposed = false, _notificationQueued = false;
  int _corrections = 0;
  String? _navigationTarget;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _TranscriptPosition(
    physics: physics,
    context: context,
    owner: this,
    oldPosition: oldPosition,
  );

  void followLatest() {
    followsLatest.value = true;
    _held = null;
    _navigate?.call(null);
  }

  void reveal(String id) {
    followsLatest.value = false;
    _held = null;
    currentMessage.value = id;
    _navigate?.call(id);
  }

  @override
  void jumpTo(double value) {
    if (hasClients) followsLatest.value = value >= position.maxScrollExtent - 2;
    _held = null;
    super.jumpTo(value);
    _publishLocation();
  }

  void userScrolled() {
    if (!hasClients || _resetting) return;
    followsLatest.value = position.maxScrollExtent - offset <= 2;
    _held = null;
    _publishLocation();
  }

  void _publishLocation() {
    if (_notificationQueued || _disposed) return;
    _notificationQueued = true;
    scheduleMicrotask(() {
      _notificationQueued = false;
      if (_disposed) return;
      final anchor = _capture();
      if (anchor != null) {
        _snapshot = anchor;
        currentMessage.value = anchor.id;
      }
    });
  }

  RenderAbstractViewport? _viewport(RenderObject box) =>
      RenderAbstractViewport.maybeOf(box);
  double? _documentTop(_AnchorBox box) {
    RenderObject child = box;
    while (child.parent != null &&
        child.parent is! RenderSliverMultiBoxAdaptor) {
      child = child.parent!;
    }
    final data = child.parentData, sliver = child.parent;
    if (data is! SliverMultiBoxAdaptorParentData ||
        data.layoutOffset == null ||
        sliver is! RenderSliverMultiBoxAdaptor) {
      return null;
    }
    return sliver.constraints.growthDirection == GrowthDirection.reverse
        ? -data.layoutOffset! - box.layoutHeight
        : data.layoutOffset!;
  }

  double _top(_AnchorBox box) => -offset + (_documentTop(box) ?? 0);
  Rect? _caret(RenderObject text, int offset) {
    if (!text.attached) return null;
    if (text is RenderEditable) {
      return text
              .getEndpointsForSelection(TextSelection.collapsed(offset: offset))
              .first
              .point &
          const Size(1, 1);
    }
    if (text is RenderParagraph) {
      return text.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) &
          const Size(1, 1);
    }
    return null;
  }

  _ReadingAnchor? _capture() {
    if (!hasClients || !position.hasContentDimensions) return null;
    final entries =
        _mounted.entries
            .where(
              (entry) =>
                  entry.value.attached &&
                  entry.value.hasSize &&
                  _documentTop(entry.value) != null,
            )
            .toList()
          ..sort((a, b) => _top(a.value).compareTo(_top(b.value)));
    for (final entry in entries) {
      final box = entry.value, viewport = _viewport(entry.value);
      if (!box.attached || !box.hasSize || viewport == null) continue;
      final top = _top(box), height = box.layoutHeight;
      if (top + height <= 20 || top >= position.viewportDimension) continue;
      final point = math.max(24.0, top);
      // Prefer the actual text character under the reading line, not a ratio
      // of a long answer. Markdown/SelectableText wrapping can then change
      // height without changing the paragraph/line the user is reading.
      _ReadingAnchor? textAnchor;
      void visit(RenderObject node) {
        if (textAnchor != null) return;
        if (node is RenderBox &&
            node.hasSize &&
            (node is RenderEditable || node is RenderParagraph)) {
          final y =
              top +
              MatrixUtils.transformPoint(
                node.getTransformTo(box),
                Offset.zero,
              ).dy;
          if (y <= point && y + node.size.height > point) {
            final local = Offset(4, point - y);
            final character = node is RenderEditable
                ? node.getPositionForPoint(node.localToGlobal(local)).offset
                : (node as RenderParagraph).getPositionForOffset(local).offset;
            final rect = _caret(node, character);
            if (rect != null) {
              textAnchor = _ReadingAnchor(
                entry.key,
                height <= 0 ? 0 : ((point - top) / height).clamp(0, 1),
                y + rect.top,
                node,
                character,
                node is RenderEditable
                    ? node.text?.toPlainText()
                    : (node as RenderParagraph).text.toPlainText(),
              );
            }
          }
        }
        node.visitChildren(visit);
      }

      visit(box);
      if (textAnchor != null) return textAnchor;
      return _ReadingAnchor(
        entry.key,
        height <= 0 ? 0 : ((point - top) / height).clamp(0, 1),
        point,
      );
    }
    return null;
  }

  @visibleForTesting
  (String, RenderObject?, int?, double)? get debugReadingAnchor {
    final anchor = _capture();
    return anchor == null
        ? null
        : (anchor.id, anchor.text, anchor.character, anchor.y);
  }

  void _beforeLayout() {
    _corrections = 0;
    if (!_resetting && !followsLatest.value) _held = _snapshot ?? _held;
  }

  double? _desired(ScrollMetrics metrics) {
    if (_resetting) {
      _resetting = false;
      _held = null;
      if (followsLatest.value) return metrics.maxScrollExtent;
      final box = _mounted[_navigationTarget];
      if (box != null && box.hasSize) {
        return _documentTop(box) ?? 0;
      }
      return 0;
    }
    if (followsLatest.value) return metrics.maxScrollExtent;
    final held = _held;
    if (held == null) return null;
    final box = _mounted[held.id];
    if (box == null || !box.attached || !box.hasSize) return null;
    final documentTop = _documentTop(box);
    if (documentTop == null) return null;
    RenderObject? currentText = held.text?.attached == true ? held.text : null;
    if (currentText == null && held.content != null) {
      void visit(RenderObject node) {
        if (currentText != null) return;
        final content = node is RenderEditable
            ? node.text?.toPlainText()
            : node is RenderParagraph
            ? node.text.toPlainText()
            : null;
        if (content == held.content) currentText = node;
        node.visitChildren(visit);
      }

      visit(box);
    }
    if (currentText case final text?) {
      final caret = _caret(text, held.character!);
      if (caret != null &&
          RenderAbstractViewport.maybeOf(text) == _viewport(box)) {
        final y = MatrixUtils.transformPoint(
          text.getTransformTo(box),
          caret.topLeft,
        ).dy;
        return documentTop + y - held.y;
      }
    }
    return documentTop + box.layoutHeight * held.fraction - held.y;
  }

  @override
  void dispose() {
    _disposed = true;
    currentMessage.dispose();
    followsLatest.dispose();
    super.dispose();
  }
}

class _TranscriptPosition extends ScrollPositionWithSingleContext {
  final AiTranscriptController owner;
  _TranscriptPosition({
    required super.physics,
    required super.context,
    required this.owner,
    super.oldPosition,
  });
  void prepareNavigation() {
    goIdle();
    owner._corrections = 0;
    correctPixels(0);
    // Cached message widgets can make an identical-origin rebuild layout-free.
    // Invalidate the viewport explicitly; correction still finishes in layout.
    notifyListeners();
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final accepted = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    // An explicit jump (or a same-height text reflow) can require correction
    // even when min/max/viewport dimensions did not change. The framework only
    // invokes correctForNewDimensions when metrics change; handle the remaining
    // case in this same viewport layout, never with a later jump/animation.
    if (!accepted) return false;
    final anchored = _correctPosition(this);
    if (anchored) owner._corrections = 0;
    return anchored;
  }

  bool _correctPosition(ScrollMetrics metrics) {
    final desired = owner
        ._desired(metrics)
        ?.clamp(metrics.minScrollExtent, metrics.maxScrollExtent);
    if (desired != null &&
        (desired - pixels).abs() > .25 &&
        owner._corrections++ < 4) {
      correctPixels(desired);
      return false;
    }
    return true;
  }

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    return _correctPosition(newPosition) &&
        super.correctForNewDimensions(oldPosition, newPosition);
  }
}

class AiTranscript extends StatefulWidget {
  final AiTranscriptController controller;
  final List<String> ids;
  final Widget Function(BuildContext context, int index) itemBuilder;
  const AiTranscript({
    super.key,
    required this.controller,
    required this.ids,
    required this.itemBuilder,
  });
  @override
  State<AiTranscript> createState() => _AiTranscriptState();
}

class _AiTranscriptState extends State<AiTranscript> {
  final _center = GlobalKey();
  final Map<String, GlobalKey> _keys = {};
  String? _origin;
  String? get _latestOrigin => widget.ids.isEmpty
      ? null
      : widget.ids[math.max(0, widget.ids.length - 4)];
  @override
  void initState() {
    super.initState();
    _origin = _latestOrigin;
    widget.controller._navigate = _navigate;
  }

  @override
  void didUpdateWidget(AiTranscript old) {
    super.didUpdateWidget(old);
    _keys.removeWhere((id, _) => !widget.ids.contains(id));
    if (!widget.ids.contains(_origin) ||
        (widget.controller.followsLatest.value &&
            (widget.ids.indexOf(_origin ?? '') < widget.ids.length - 32 ||
                widget.ids.indexOf(_origin ?? '') >
                    math.max(0, widget.ids.length - 4)))) {
      _origin = _latestOrigin;
      widget.controller._resetting = true;
    }
  }

  void _navigate(String? id) {
    if (!mounted || (id != null && !widget.ids.contains(id))) return;
    widget.controller._resetting = true;
    widget.controller._navigationTarget = id;
    if (widget.controller.hasClients) {
      (widget.controller.position as _TranscriptPosition).prepareNavigation();
    }
    setState(() => _origin = id ?? _latestOrigin);
  }

  @override
  void dispose() {
    widget.controller._navigate = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final at = widget.ids.indexOf(_origin ?? '');
    final center = at < 0 ? 0 : at;
    Widget item(int index) => _AnchorItem(
      key: _keys.putIfAbsent(widget.ids[index], GlobalKey.new),
      id: widget.ids[index],
      controller: widget.controller,
      child: widget.itemBuilder(context, index),
    );
    return _TranscriptFrame(
      controller: widget.controller,
      child: NotificationListener<ScrollNotification>(
        onNotification: (event) {
          if (event.depth == 0 &&
              (event is UserScrollNotification ||
                  event is ScrollUpdateNotification &&
                      event.dragDetails != null)) {
            widget.controller.userScrolled();
          }
          widget.controller._publishLocation();
          return false;
        },
        child: CustomScrollView(
          key: const ValueKey('ai-transcript'),
          controller: widget.controller,
          center: _center,
          anchor: 0,
          physics: const ClampingScrollPhysics(),
          scrollCacheExtent: const ScrollCacheExtent.pixels(300),
          slivers: [
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => item(center - i - 1),
                childCount: center,
                findChildIndexCallback: (key) {
                  final index = widget.ids.indexWhere((id) => _keys[id] == key);
                  return index >= 0 && index < center
                      ? center - index - 1
                      : null;
                },
              ),
            ),
            SliverList(
              key: _center,
              delegate: SliverChildBuilderDelegate(
                (_, i) => item(center + i),
                childCount: widget.ids.length - center,
                findChildIndexCallback: (key) {
                  final index = widget.ids.indexWhere((id) => _keys[id] == key);
                  return index >= center ? index - center : null;
                },
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 20)),
          ],
        ),
      ),
    );
  }
}

class _AnchorItem extends SingleChildRenderObjectWidget {
  final String id;
  final AiTranscriptController controller;
  const _AnchorItem({
    super.key,
    required this.id,
    required this.controller,
    required super.child,
  });
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _AnchorBox(id, controller);
}

class _AnchorBox extends RenderProxyBox {
  final String id;
  final AiTranscriptController controller;
  _AnchorBox(this.id, this.controller);
  double layoutHeight = 0;
  @override
  void performLayout() {
    super.performLayout();
    layoutHeight = size.height;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    controller._mounted[id] = this;
  }

  @override
  void detach() {
    if (identical(controller._mounted[id], this)) {
      controller._mounted.remove(id);
    }
    super.detach();
  }
}

class _TranscriptFrame extends SingleChildRenderObjectWidget {
  final AiTranscriptController controller;
  const _TranscriptFrame({required this.controller, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _FrameBox(controller);
}

class _FrameBox extends RenderProxyBox {
  final AiTranscriptController controller;
  _FrameBox(this.controller);
  @override
  void performLayout() {
    controller._beforeLayout();
    super.performLayout();
    controller._publishLocation();
  }
}
