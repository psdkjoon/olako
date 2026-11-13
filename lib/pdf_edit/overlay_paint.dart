import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:olako/pdf_edit/models.dart';
import 'package:olako/pdf_edit/page_images.dart';

Color _tint(int argb, double opacity) {
  return Color(argb).withValues(alpha: opacity.clamp(0.0, 1.0).toDouble());
}

void paintAnnotation(Canvas canvas, Annotation item, PictureStore store) {
  if (item is InkOverlay) {
    _paintInk(canvas, item);
  } else if (item is MarkOverlay) {
    _paintMark(canvas, item);
  } else if (item is PictureOverlay) {
    _paintPicture(canvas, item, store);
  }
}

void paintAnnotations(
  Canvas canvas,
  List<Annotation> items,
  PictureStore store,
) {
  for (final item in items) {
    paintAnnotation(canvas, item, store);
  }
}

void _paintInk(Canvas canvas, InkOverlay ink) {
  if (ink.points.isEmpty) return;
  final paint = Paint()
    ..color = _tint(ink.color, ink.opacity)
    ..style = PaintingStyle.stroke
    ..strokeWidth = ink.width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  if (ink.highlight) paint.blendMode = BlendMode.multiply;
  if (ink.points.length == 1) {
    final dot = Paint()
      ..color = paint.color
      ..blendMode = paint.blendMode;
    canvas.drawCircle(ink.points.first, ink.width / 2, dot);
    return;
  }
  final path = Path()..moveTo(ink.points.first.dx, ink.points.first.dy);
  for (var i = 1; i < ink.points.length; i++) {
    path.lineTo(ink.points[i].dx, ink.points[i].dy);
  }
  canvas.drawPath(path, paint);
}

void _paintMark(Canvas canvas, MarkOverlay mark) {
  final stroke = Paint()
    ..color = _tint(mark.stroke, mark.opacity)
    ..style = PaintingStyle.stroke
    ..strokeWidth = mark.width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final fillColor = mark.fill;
  final fill = fillColor == null
      ? null
      : (Paint()
          ..color = _tint(fillColor, mark.opacity)
          ..style = PaintingStyle.fill);
  final rect = Rect.fromPoints(mark.a, mark.b);
  switch (mark.kind) {
    case MarkKind.rect:
      if (fill != null) canvas.drawRect(rect, fill);
      if (mark.width > 0) canvas.drawRect(rect, stroke);
    case MarkKind.oval:
      if (fill != null) canvas.drawOval(rect, fill);
      if (mark.width > 0) canvas.drawOval(rect, stroke);
    case MarkKind.line:
      canvas.drawLine(mark.a, mark.b, stroke);
    case MarkKind.arrow:
      final angle = math.atan2(mark.b.dy - mark.a.dy, mark.b.dx - mark.a.dx);
      final head = math.max(9.0, mark.width * 4.5);
      final end = Offset(
        mark.b.dx - math.cos(angle) * head * 0.7,
        mark.b.dy - math.sin(angle) * head * 0.7,
      );
      canvas.drawLine(mark.a, end, stroke);
      const spread = 0.45;
      final left = Offset(
        mark.b.dx - math.cos(angle - spread) * head,
        mark.b.dy - math.sin(angle - spread) * head,
      );
      final right = Offset(
        mark.b.dx - math.cos(angle + spread) * head,
        mark.b.dy - math.sin(angle + spread) * head,
      );
      final tip = Path()
        ..moveTo(mark.b.dx, mark.b.dy)
        ..lineTo(left.dx, left.dy)
        ..lineTo(right.dx, right.dy)
        ..close();
      canvas.drawPath(
        tip,
        Paint()
          ..color = stroke.color
          ..style = PaintingStyle.fill,
      );
  }
}

void _paintPicture(Canvas canvas, PictureOverlay item, PictureStore store) {
  final image = store.get(item);
  if (image == null) return;
  canvas.save();
  final center = item.rect.center;
  canvas.translate(center.dx, center.dy);
  canvas.rotate(item.rotation);
  final target = Rect.fromCenter(
    center: Offset.zero,
    width: item.rect.width,
    height: item.rect.height,
  );
  final paint = Paint()
    ..filterQuality = FilterQuality.medium
    ..color = Color.fromRGBO(
      255,
      255,
      255,
      item.opacity.clamp(0.0, 1.0).toDouble(),
    );
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    target,
    paint,
  );
  canvas.restore();
}

class PageFace extends CustomPainter {
  PageFace({
    required this.image,
    required this.page,
    required this.visible,
    required this.annotations,
    required this.store,
    this.paper = const Color(0xFFFFFFFF),
  }) : super(repaint: store);

  final ui.Image? image;
  final Size page;
  final Rect visible;
  final List<Annotation> annotations;
  final PictureStore store;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    if (visible.width <= 0 || visible.height <= 0) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / visible.width, size.height / visible.height);
    canvas.translate(-visible.left, -visible.top);
    final area = Offset.zero & page;
    canvas.drawRect(area, Paint()..color = paper);
    final picture = image;
    if (picture != null) {
      canvas.drawImageRect(
        picture,
        Rect.fromLTWH(
          0,
          0,
          picture.width.toDouble(),
          picture.height.toDouble(),
        ),
        area,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    paintAnnotations(canvas, annotations, store);
    canvas.restore();
  }

  @override
  bool shouldRepaint(PageFace old) {
    return old.image != image ||
        old.page != page ||
        old.visible != visible ||
        !identical(old.annotations, annotations) ||
        old.paper != paper;
  }
}
