import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:flutter/widgets.dart' as w show Text;
import 'package:olako/reader/doc_model.dart';
import 'package:olako/reader/text_direction.dart';
import 'package:olako/ui/viewer/doc_style.dart';
import 'package:olako/ui/viewer/inline_text.dart';

class SlideCanvas extends StatelessWidget {
  const SlideCanvas({
    required this.slide,
    required this.widthPt,
    required this.heightPt,
    super.key,
  });

  final SlideData slide;
  final double widthPt;
  final double heightPt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = Color(slide.background);
    final ctx = TextContext(
      pxPerPt: 1,
      surface: background,
      ink: inkOn(background),
      link: scheme.primary,
      codeBackground: const Color(0x22808080),
      textScaler: TextScaler.noScaling,
      imageMaxWidth: widthPt,
    );
    return AspectRatio(
      aspectRatio: widthPt / heightPt,
      child: ClipRect(
        child: ColoredBox(
          color: background,
          child: FittedBox(
            child: SizedBox(
              width: widthPt,
              height: heightPt,
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  for (final shape in slide.shapes) _shape(shape, ctx),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _shape(SlideShape shape, TextContext ctx) {
  Widget child = switch (shape) {
    final SlideTextShape t => _textShape(t, ctx),
    final SlidePictureShape p => _picture(p),
    final SlideTableShape t => _tableShape(t, ctx),
  };
  if (shape.rotation != 0) {
    child = Transform.rotate(
      angle: shape.rotation * math.pi / 180,
      child: child,
    );
  }
  return Positioned(
    left: shape.x,
    top: shape.y,
    width: math.max(shape.width, 0.5),
    height: math.max(shape.height, 0.5),
    child: child,
  );
}

Widget _textShape(SlideTextShape t, TextContext ctx) {
  final line = t.line == null ? null : Color(t.line!);
  if (t.kind == ShapeKind.line) {
    return CustomPaint(
      painter: _LinePainter(
        color: line ?? ctx.ink,
        width: t.lineWidthPt,
        flip: t.flipH,
      ),
    );
  }
  final fill = t.fill == null ? null : Color(t.fill!);
  final surface = fill == null
      ? ctx.surface
      : Color.alphaBlend(fill, ctx.surface);
  final local = fill == null
      ? ctx
      : ctx.copyWith(surface: surface, ink: inkOn(surface));
  final Widget content;
  if (t.paragraphs.isEmpty) {
    content = const SizedBox.shrink();
  } else {
    content = Padding(
      padding: EdgeInsets.fromLTRB(
        t.insetLeft,
        t.insetTop,
        t.insetRight,
        t.insetBottom,
      ),
      child: OverflowBox(
        alignment: Alignment(0, t.anchor.toDouble()),
        minHeight: 0,
        maxHeight: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final p in t.paragraphs) slideParagraph(p, local)],
        ),
      ),
    );
  }
  if (fill == null && line == null) return content;
  return CustomPaint(
    painter: _ShapePainter(
      kind: t.kind,
      fill: fill,
      line: line,
      lineWidth: t.lineWidthPt,
    ),
    child: content,
  );
}

Widget slideParagraph(SlideParagraph p, TextContext ctx) {
  if (p.inlines.isEmpty) return SizedBox(height: p.sizePt * 1.2);
  final rtl = p.rtl ?? firstStrongIsRtl(plainText(p.inlines)) ?? false;
  final base = TextStyle(fontSize: p.sizePt, height: 1.2, color: ctx.ink);
  Widget body = InlineText(
    inlines: p.inlines,
    base: base,
    context: ctx,
    rtl: rtl,
    align: p.align,
  );
  final margin = math.max(0.0, p.marginPt);
  if (p.bullet.isNotEmpty) {
    final hang = p.indentPt < 0 ? -p.indentPt : p.sizePt * 1.1;
    body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: math.max(0.0, margin - hang)),
        SizedBox(
          width: hang,
          child: w.Text(
            p.bullet,
            style: base,
            textScaler: TextScaler.noScaling,
          ),
        ),
        Expanded(child: body),
      ],
    );
  } else if (margin > 0) {
    body = Padding(
      padding: EdgeInsetsDirectional.only(start: margin),
      child: body,
    );
  }
  return Directionality(
    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    child: Padding(
      padding: EdgeInsets.only(top: p.spaceBeforePt),
      child: body,
    ),
  );
}

Widget _picture(SlidePictureShape p) {
  final keepW = math.max(0.05, 1 - p.cropLeft - p.cropRight);
  final keepH = math.max(0.05, 1 - p.cropTop - p.cropBottom);
  final decode = math.min(2000, math.max(64, (p.width * 2 / keepW).round()));
  final image = Image.memory(
    p.bytes,
    fit: BoxFit.fill,
    gaplessPlayback: true,
    cacheWidth: decode,
    semanticLabel: p.alt.isEmpty ? null : p.alt,
    errorBuilder: (_, _, _) => const SizedBox.shrink(),
  );
  final cropped =
      p.cropLeft > 0 || p.cropTop > 0 || p.cropRight > 0 || p.cropBottom > 0;
  if (!cropped) return image;
  return ClipRect(
    child: OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: 0,
      minHeight: 0,
      maxWidth: double.infinity,
      maxHeight: double.infinity,
      child: Transform.translate(
        offset: Offset(
          -p.cropLeft / keepW * p.width,
          -p.cropTop / keepH * p.height,
        ),
        child: SizedBox(
          width: p.width / keepW,
          height: p.height / keepH,
          child: image,
        ),
      ),
    ),
  );
}

Widget _tableShape(SlideTableShape t, TextContext ctx) {
  final border = ctx.ink.withValues(alpha: 0.35);
  final rows = <Widget>[];
  for (final row in t.rows) {
    final cells = <Widget>[];
    var index = 0;
    for (final cell in row) {
      final span = cell.span < 1 ? 1 : cell.span;
      var width = 0.0;
      for (var k = index; k < index + span && k < t.columnWidths.length; k++) {
        width += t.columnWidths[k];
      }
      index += span;
      if (width <= 0) continue;
      final fill = cell.fill == null ? null : Color(cell.fill!);
      final surface = fill == null
          ? ctx.surface
          : Color.alphaBlend(fill, ctx.surface);
      final local = fill == null
          ? ctx
          : ctx.copyWith(surface: surface, ink: inkOn(surface));
      cells.add(
        SizedBox(
          width: width,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: border, width: 0.75),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final p in cell.paragraphs) slideParagraph(p, local),
                ],
              ),
            ),
          ),
        ),
      );
    }
    rows.add(
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: cells,
        ),
      ),
    );
  }
  return OverflowBox(
    alignment: Alignment.topLeft,
    minHeight: 0,
    maxHeight: double.infinity,
    child: Column(mainAxisSize: MainAxisSize.min, children: rows),
  );
}

class _ShapePainter extends CustomPainter {
  const _ShapePainter({
    required this.kind,
    required this.fill,
    required this.line,
    required this.lineWidth,
  });

  final ShapeKind kind;
  final Color? fill;
  final Color? line;
  final double lineWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = math.min(size.width, size.height) * 0.16;

    void draw(Paint paint) {
      switch (kind) {
        case ShapeKind.ellipse:
          canvas.drawOval(rect, paint);
        case ShapeKind.roundRect:
          canvas.drawRRect(RRect.fromRectXY(rect, radius, radius), paint);
        case ShapeKind.rect:
        case ShapeKind.line:
          canvas.drawRect(rect, paint);
      }
    }

    final fillColor = fill;
    if (fillColor != null) draw(Paint()..color = fillColor);
    final lineColor = line;
    if (lineColor != null) {
      draw(
        Paint()
          ..color = lineColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(lineWidth, 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_ShapePainter old) =>
      old.kind != kind ||
      old.fill != fill ||
      old.line != line ||
      old.lineWidth != lineWidth;
}

class _LinePainter extends CustomPainter {
  const _LinePainter({
    required this.color,
    required this.width,
    required this.flip,
  });

  final Color color;
  final double width;
  final bool flip;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.max(width, 0.5)
      ..strokeCap = StrokeCap.round;
    if (flip) {
      canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
    } else {
      canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.color != color || old.width != width || old.flip != flip;
}
