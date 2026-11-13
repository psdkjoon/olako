import 'package:flutter/material.dart';
import 'package:olako/theme/catppuccin.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({required this.size, super.key});

  final double size;

  static const double _darkMix = 0.12;
  static const double _lightMix = 0.22;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final base =
        (dark ? CatppuccinPalette.mocha : CatppuccinPalette.latte).base;
    final tile = Color.lerp(base, scheme.primary, dark ? _darkMix : _lightMix)!;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _LogoPainter(glyph: scheme.primary, tile: tile),
        ),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter({required this.glyph, required this.tile});

  final Color glyph;
  final Color tile;

  static final Path _flippers = Path()
    ..moveTo(7.68, 8.99)
    ..cubicTo(5.8, 8.8, 3.92, 9.93, 2.88, 12.56)
    ..cubicTo(2.69, 13.03, 3.16, 13.22, 3.54, 13.03)
    ..cubicTo(5.23, 12.19, 6.74, 12, 7.86, 12)
    ..close()
    ..moveTo(16.32, 8.99)
    ..cubicTo(18.2, 8.8, 20.08, 9.93, 21.12, 12.56)
    ..cubicTo(21.31, 13.03, 20.84, 13.22, 20.46, 13.03)
    ..cubicTo(18.77, 12.19, 17.26, 12, 16.14, 12)
    ..close()
    ..moveTo(8.43, 15.57)
    ..cubicTo(6.92, 15.76, 5.61, 16.89, 5.04, 18.77)
    ..cubicTo(4.95, 19.14, 5.33, 19.33, 5.61, 19.14)
    ..cubicTo(6.92, 18.39, 8.24, 18.2, 9.37, 17.83)
    ..close()
    ..moveTo(15.57, 15.57)
    ..cubicTo(17.08, 15.76, 18.39, 16.89, 18.96, 18.77)
    ..cubicTo(19.05, 19.14, 18.67, 19.33, 18.39, 19.14)
    ..cubicTo(17.08, 18.39, 15.76, 18.2, 14.63, 17.83)
    ..close();
  static final Path _body = Path()
    ..moveTo(12, 3.07)
    ..cubicTo(13.13, 3.07, 13.88, 3.82, 13.88, 4.95)
    ..cubicTo(13.88, 6.08, 13.13, 7.11, 12, 7.11)
    ..cubicTo(10.87, 7.11, 10.12, 6.08, 10.12, 4.95)
    ..cubicTo(10.12, 3.82, 10.87, 3.07, 12, 3.07)
    ..close()
    ..moveTo(11.25, 18.02)
    ..lineTo(12, 20.27)
    ..lineTo(12.75, 18.02)
    ..close();
  static final Path _shell = Path()
    ..moveTo(12, 6.74)
    ..cubicTo(15.01, 6.74, 16.89, 9.18, 16.89, 12.19)
    ..cubicTo(16.89, 15.38, 14.82, 18.2, 12, 18.2)
    ..cubicTo(9.18, 18.2, 7.11, 15.38, 7.11, 12.19)
    ..cubicTo(7.11, 9.18, 8.99, 6.74, 12, 6.74)
    ..close();
  static final Path _scutes = Path()
    ..moveTo(12, 10.03)
    ..lineTo(13.88, 11.11)
    ..lineTo(13.88, 13.27)
    ..lineTo(12, 14.35)
    ..lineTo(10.12, 13.27)
    ..lineTo(10.12, 11.11)
    ..lineTo(12, 10.03)
    ..moveTo(12, 10.03)
    ..lineTo(12, 7.68)
    ..moveTo(13.88, 11.11)
    ..lineTo(15.48, 9.74)
    ..moveTo(13.88, 13.27)
    ..lineTo(15.48, 14.73)
    ..moveTo(12, 14.35)
    ..lineTo(12, 17.26)
    ..moveTo(10.12, 13.27)
    ..lineTo(8.52, 14.73)
    ..moveTo(10.12, 11.11)
    ..lineTo(8.52, 9.74);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final glyphPaint = Paint()..color = glyph;
    final tilePaint = Paint()..color = tile;
    canvas.drawRRect(
      RRect.fromRectXY(const Rect.fromLTWH(0, 0, 24, 24), 6.16, 6.16),
      tilePaint,
    );
    canvas.drawPath(_flippers, glyphPaint);

    canvas.drawPath(_shell, tilePaint);
    canvas.drawPath(
      _shell,
      Paint()
        ..color = tile
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.32,
    );
    canvas.drawPath(_body, glyphPaint);
    canvas.drawPath(_shell, glyphPaint);
    canvas.drawPath(
      _scutes,
      Paint()
        ..color = tile
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.52
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_LogoPainter old) =>
      old.glyph != glyph || old.tile != tile;
}
