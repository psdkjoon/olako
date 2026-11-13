import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/localization/localization.dart';
import 'package:olako/theme/app_spacing.dart';

Future<int?> pickColor(
  BuildContext context, {
  required int initial,
  required bool allowNone,
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => _ColorDialog(initial: initial, allowNone: allowNone),
  );
}

class _ColorDialog extends StatefulWidget {
  const _ColorDialog({required this.initial, required this.allowNone});

  final int initial;
  final bool allowNone;

  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  static const List<int> _palette = <int>[
    0xFF000000,
    0xFF1B1B1F,
    0xFF444444,
    0xFF666A70,
    0xFF9AA0A6,
    0xFFC9CCD1,
    0xFFE9ECEF,
    0xFFFFFFFF,
    0xFFD32F2F,
    0xFFE64A19,
    0xFFF9A825,
    0xFF388E3C,
    0xFF00796B,
    0xFF1A5FB4,
    0xFF512DA8,
    0xFFC2185B,
    0xFF1E1E2E,
    0xFFFDF6E3,
  ];

  late HSVColor _hsv;
  late final TextEditingController _hex;

  static String _hexOf(Color color) => (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();

  @override
  void initState() {
    super.initState();
    final start = Color(widget.initial == 0 ? 0xFF000000 : widget.initial);
    _hsv = HSVColor.fromColor(start);
    _hex = TextEditingController(text: _hexOf(start));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _apply(HSVColor next) {
    setState(() => _hsv = next);
    _hex.text = _hexOf(next.toColor());
  }

  void _typed(String text) {
    final cleaned = text.replaceAll('#', '').trim();
    if (cleaned.length != 6) return;
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed == null) return;
    setState(() => _hsv = HSVColor.fromColor(Color(0xFF000000 | parsed)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _hsv.toColor();
    return AlertDialog(
      title: const Text('Choose a color'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppSpacing.sm,
          children: [
            Container(
              height: 44,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(AppRadius.tile),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
            ),
            Wrap(
              spacing: AppSpacing.xxs * 2,
              runSpacing: AppSpacing.xxs * 2,
              children: [
                for (final value in _palette)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _apply(HSVColor.fromColor(Color(value))),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Color(value),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            Slider(
              value: _hsv.hue,
              max: 360,
              onChanged: (v) => _apply(_hsv.withHue(v)),
            ),
            Slider(
              value: _hsv.saturation,
              onChanged: (v) => _apply(_hsv.withSaturation(v)),
            ),
            Slider(
              value: _hsv.value,
              onChanged: (v) => _apply(_hsv.withValue(v)),
            ),
            TextField(
              controller: _hex,
              onChanged: _typed,
              maxLength: 7,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                prefixText: '#',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.allowNone)
          TextButton(
            onPressed: () => Navigator.of(context).pop(0),
            child: const Text('None'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(color.toARGB32()),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
