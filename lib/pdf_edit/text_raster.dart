import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

class RasterText {
  const RasterText(this.bytes, this.width, this.height);

  final Uint8List bytes;
  final double width;
  final double height;
}

final RegExp _rtlLetters = RegExp(r'[֐-ࣿיִ-﷿ﹰ-﻿]');

bool hasRtl(String text) => _rtlLetters.hasMatch(text);

Future<RasterText?> rasterText(
  String text, {
  required double sizePt,
  required int color,
  bool bold = false,
  bool italic = false,
  double maxWidth = 480,
  double scale = 3,
}) async {
  if (text.trim().isEmpty) return null;
  final rtl = hasRtl(text);
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: Color(color),
        fontSize: sizePt,
        height: 1.25,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      ),
    ),
    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    textAlign: TextAlign.start,
  );
  painter.layout(maxWidth: maxWidth);
  final width = painter.width + 4;
  final height = painter.height + 4;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);
  painter.paint(canvas, const Offset(2, 2));
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (width * scale).ceil(),
    (height * scale).ceil(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  painter.dispose();
  if (data == null) return null;
  return RasterText(data.buffer.asUint8List(), width, height);
}

Future<Uint8List?> rasterStrokes(
  List<List<Offset>> strokes,
  Size size, {
  required double width,
  required int color,
  double scale = 2,
}) async {
  if (strokes.isEmpty) return null;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);
  final paint = Paint()
    ..color = Color(color)
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  for (final stroke in strokes) {
    if (stroke.isEmpty) continue;
    if (stroke.length == 1) {
      canvas.drawCircle(stroke.first, width / 2, Paint()..color = Color(color));
      continue;
    }
    final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
    for (var i = 1; i < stroke.length; i++) {
      path.lineTo(stroke[i].dx, stroke[i].dy);
    }
    canvas.drawPath(path, paint);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (size.width * scale).ceil(),
    (size.height * scale).ceil(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data?.buffer.asUint8List();
}
