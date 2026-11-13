import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/core/app_dirs.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/pdf_edit/text_raster.dart';
import 'package:olako/theme/app_spacing.dart';

class SignatureResult {
  const SignatureResult(this.bytes, this.size);

  final Uint8List bytes;
  final Size size;
}

Future<SignatureResult?> _saved() async {
  try {
    final base = await AppDirs.data();
    final image = File('$base/signature.png');
    final meta = File('$base/signature.txt');
    if (!await image.exists() || !await meta.exists()) return null;
    final parts = (await meta.readAsString()).split(',');
    if (parts.length != 2) return null;
    final w = double.tryParse(parts[0]);
    final h = double.tryParse(parts[1]);
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return SignatureResult(await image.readAsBytes(), Size(w, h));
  } on Object {
    return null;
  }
}

Future<void> _remember(SignatureResult result) async {
  try {
    final base = await AppDirs.data();
    await File('$base/signature.png').writeAsBytes(result.bytes);
    await File(
      '$base/signature.txt',
    ).writeAsString('${result.size.width},${result.size.height}');
  } on Object {
    return;
  }
}

Future<SignatureResult?> askSignature(BuildContext context) async {
  final saved = await _saved();
  if (!context.mounted) return null;
  return showDialog<SignatureResult>(
    context: context,
    builder: (_) => _SignatureDialog(saved: saved),
  );
}

class _SignatureDialog extends StatefulWidget {
  const _SignatureDialog({required this.saved});

  final SignatureResult? saved;

  @override
  State<_SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureDialogState extends State<_SignatureDialog> {
  static const double _pad = 4;
  static const List<int> _inks = <int>[0xFF111111, 0xFF1A3FA6, 0xFFB3261E];

  final List<List<Offset>> _strokes = <List<Offset>>[];
  int _ink = _inks.first;
  bool _busy = false;

  Future<void> _use() async {
    if (_strokes.isEmpty || _busy) return;
    setState(() => _busy = true);
    var bounds = Rect.fromPoints(_strokes.first.first, _strokes.first.first);
    for (final stroke in _strokes) {
      for (final p in stroke) {
        bounds = bounds.expandToInclude(Rect.fromPoints(p, p));
      }
    }
    bounds = bounds.inflate(_pad + 2);
    final shifted = <List<Offset>>[
      for (final stroke in _strokes)
        <Offset>[for (final p in stroke) p - bounds.topLeft],
    ];
    final size = Size(math.max(bounds.width, 8), math.max(bounds.height, 8));
    final bytes = await rasterStrokes(shifted, size, width: 3, color: _ink);
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _busy = false);
      return;
    }
    final result = SignatureResult(bytes, size);
    await _remember(result);
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: const Text('Signature'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 160,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppRadius.tile),
                border: Border.all(color: scheme.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) =>
                    setState(() => _strokes.add(<Offset>[e.localPosition])),
                onPointerMove: (e) {
                  if (_strokes.isEmpty) return;
                  final last = _strokes.last;
                  if ((last.last - e.localPosition).distance < 1.5) return;
                  setState(() => last.add(e.localPosition));
                },
                child: CustomPaint(
                  painter: _PadPainter(_strokes, _ink),
                  size: Size.infinite,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                for (final ink in _inks)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      end: AppSpacing.sm,
                    ),
                    child: InkResponse(
                      onTap: () => setState(() => _ink = ink),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Color(ink),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: ink == _ink
                                ? scheme.primary
                                : scheme.outlineVariant,
                            width: ink == _ink ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: _strokes.isEmpty
                      ? null
                      : () => setState(_strokes.clear),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        if (widget.saved != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(widget.saved),
            child: const Text('Use saved'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _strokes.isEmpty || _busy ? null : _use,
          child: const Text('Use'),
        ),
      ],
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes, this.ink);

  final List<List<Offset>> strokes;
  final int ink;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Color(ink)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final stroke in strokes) {
      if (stroke.length == 1) {
        canvas.drawCircle(stroke.first, 1.5, Paint()..color = Color(ink));
        continue;
      }
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (var i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => true;
}
