import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/core/safely.dart';
import 'package:olako/platform/system_service.dart';
import 'package:olako/reader/doc_model.dart';
import 'package:olako/ui/viewer/block_widgets.dart';
import 'package:olako/ui/viewer/doc_style.dart';

void openDocumentLink(String link) {
  final lower = link.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('mailto:') ||
      lower.startsWith('tel:')) {
    unawaited(_open(link));
  }
}

Future<void> _open(String link) async {
  await safely(() => SystemService.openUrl(link));
}

class DocumentView extends StatefulWidget {
  const DocumentView({
    required this.blocks,
    required this.baseSizePt,
    required this.readerScale,
    required this.initialPosition,
    required this.onProgress,
    this.markdown = false,
    super.key,
  });

  final List<DocBlock> blocks;
  final double baseSizePt;

  final int readerScale;
  final double initialPosition;
  final bool markdown;

  final void Function(double position, double progress) onProgress;

  @override
  State<DocumentView> createState() => _DocumentViewState();
}

class _DocumentViewState extends State<DocumentView> {
  static const double _columnWidth = 760;
  static const int _eagerLimit = 400;

  final ScrollController _controller = ScrollController();
  int _restoreRuns = 0;
  bool _dragged = false;
  final ValueNotifier<double> _fraction = ValueNotifier<double>(0);
  late bool _docRtl = _detectDirection();

  bool _detectDirection() =>
      blocksAreRtl(widget.blocks) ??
      Directionality.of(context) == TextDirection.rtl;

  void _track() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    final max = position.maxScrollExtent;
    final value = max <= 0
        ? 0.0
        : math.min(1.0, math.max(0.0, position.pixels / max));
    if ((value - _fraction.value).abs() > 0.0005) _fraction.value = value;
  }

  double _fractionNow() {
    if (!_controller.hasClients) return _fraction.value;
    final position = _controller.position;
    if (!position.hasContentDimensions) return _fraction.value;
    final max = position.maxScrollExtent;
    return max <= 0 ? 0.0 : math.min(1.0, math.max(0.0, position.pixels / max));
  }

  void _report() {
    final value = _fractionNow();
    widget.onProgress(value, value);
  }

  void _restore() {
    if (!mounted || _dragged) return;
    if (!_controller.hasClients || !_controller.position.hasContentDimensions) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
      return;
    }
    final position = _controller.position;
    final target = math.min(
      position.maxScrollExtent,
      math.max(0.0, widget.initialPosition * position.maxScrollExtent),
    );
    if ((position.pixels - target).abs() > 1) _controller.jumpTo(target);
    _track();
    _restoreRuns++;
    if (_restoreRuns < 4) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_track);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialPosition > 0) {
        _restore();
      } else {
        _track();
      }
    });
  }

  @override
  void didUpdateWidget(DocumentView old) {
    super.didUpdateWidget(old);
    if (!identical(old.blocks, widget.blocks)) _docRtl = _detectDirection();
  }

  @override
  void dispose() {
    if (_controller.hasClients) _report();
    _controller.dispose();
    _fraction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bodyPx = 16.0 * widget.readerScale / 100;
    final base = widget.baseSizePt > 0 ? widget.baseSizePt : 11.0;
    final media = MediaQuery.of(context);
    final style = DocStyle(
      text: TextContext(
        pxPerPt: bodyPx / base,
        surface: scheme.surface,
        ink: scheme.onSurface,
        link: scheme.primary,
        codeBackground: scheme.surfaceContainerHighest,
        textScaler: media.textScaler,
        pixelRatio: media.devicePixelRatio,
        onLink: openDocumentLink,
      ),
      bodyPx: bodyPx,
      muted: scheme.onSurfaceVariant,
      rule: scheme.outlineVariant,
      accent: scheme.primary,
      panel: scheme.surfaceContainerHighest,
      docRtl: _docRtl,
      markdown: widget.markdown,
    );
    final eager = widget.blocks.length <= _eagerLimit;

    return LayoutBuilder(
      builder: (context, constraints) {
        final column = _columnWidth * widget.readerScale / 100;
        final side = math.max(16.0, (constraints.maxWidth - column) / 2);
        final inner = math.max(120.0, constraints.maxWidth - side * 2);
        final sized = style.withText(style.text.copyWith(imageMaxWidth: inner));
        final padding = EdgeInsets.fromLTRB(side, 16, side, 80);
        final Widget content;
        if (eager) {
          content = SingleChildScrollView(
            controller: _controller,
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final block in widget.blocks) buildDocBlock(block, sized),
              ],
            ),
          );
        } else {
          content = ListView.builder(
            controller: _controller,
            padding: padding,
            itemCount: widget.blocks.length,
            itemBuilder: (context, index) =>
                buildDocBlock(widget.blocks[index], sized),
          );
        }
        return Stack(
          children: [
            NotificationListener<Notification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification &&
                    notification.dragDetails != null) {
                  _dragged = true;
                } else if (notification is ScrollEndNotification) {
                  if (_controller.hasClients) _report();
                } else if (notification is ScrollMetricsNotification) {
                  _track();
                }
                return false;
              },
              child: SelectionArea(
                child: Directionality(
                  textDirection: _docRtl
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  child: content,
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 3,
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _ProgressPainter(
                      progress: _fraction,
                      color: scheme.primary,
                      track: scheme.outlineVariant.withValues(alpha: 0.35),
                      rtl: _docRtl,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter({
    required this.progress,
    required this.color,
    required this.track,
    required this.rtl,
  }) : super(repaint: progress);

  final ValueNotifier<double> progress;
  final Color color;
  final Color track;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = track);
    final width = size.width * progress.value;
    if (width <= 0) return;
    final left = rtl ? size.width - width : 0.0;
    canvas.drawRect(
      Rect.fromLTWH(left, 0, width, size.height),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.color != color || old.track != track || old.rtl != rtl;
}
