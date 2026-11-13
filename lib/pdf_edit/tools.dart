import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/export/color_dialog.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/pdf_edit/models.dart';
import 'package:olako/pdf_edit/text_raster.dart';
import 'package:olako/theme/app_spacing.dart';

const String numberTag = 'pn';
const String markTag = 'wm';

class NumberSetup {
  const NumberSetup({
    required this.position,
    required this.format,
    required this.size,
    required this.color,
    required this.start,
    required this.selectedOnly,
  });

  final int position;
  final int format;
  final double size;
  final int color;
  final int start;
  final bool selectedOnly;
}

class WatermarkSetup {
  const WatermarkSetup({
    required this.text,
    required this.size,
    required this.color,
    required this.opacity,
    required this.diagonal,
    required this.selectedOnly,
  });

  final String text;
  final double size;
  final int color;
  final double opacity;
  final bool diagonal;
  final bool selectedOnly;
}

class CropSetup {
  const CropSetup({required this.insets, required this.selectedOnly});

  final List<double> insets;
  final bool selectedOnly;
}

String numberText(int format, int n, int total) {
  final page = 'Page'.tr;
  final of = 'of'.tr;
  final text = switch (format) {
    1 => '$n / $total',
    2 => '$page $n',
    3 => '$page $n $of $total',
    4 => '- $n -',
    _ => '$n',
  };
  return L10n.digits(text);
}

List<List<int>>? parseRanges(String text, int total) {
  final out = <List<int>>[];
  for (final raw in text.split(RegExp(r'[,;\s]+'))) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    final match = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(part);
    if (match == null) return null;
    final a = int.parse(match.group(1)!);
    final b = match.group(2) == null ? a : int.parse(match.group(2)!);
    if (a < 1 || b < a || b > total) return null;
    out.add(<int>[for (var i = a; i <= b; i++) i - 1]);
  }
  return out.isEmpty ? null : out;
}

Future<List<List<int>>?> askSplit(BuildContext context, int total) {
  return showDialog<List<List<int>>>(
    context: context,
    builder: (_) => _SplitDialog(total: total),
  );
}

class _SplitDialog extends StatefulWidget {
  const _SplitDialog({required this.total});

  final int total;

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  int _mode = 0;
  final TextEditingController _every = TextEditingController(text: '1');
  final TextEditingController _ranges = TextEditingController();
  bool _bad = false;

  @override
  void dispose() {
    _every.dispose();
    _ranges.dispose();
    super.dispose();
  }

  void _done() {
    final total = widget.total;
    List<List<int>>? plan;
    if (_mode == 0) {
      final n = int.tryParse(_every.text.trim()) ?? 0;
      if (n >= 1) {
        plan = <List<int>>[];
        for (var i = 0; i < total; i += n) {
          plan.add(<int>[for (var k = i; k < math.min(total, i + n); k++) k]);
        }
      }
    } else {
      plan = parseRanges(_ranges.text, total);
    }
    if (plan == null || (plan.length < 2 && _mode == 0)) {
      setState(() => _bad = true);
      return;
    }
    Navigator.of(context).pop(plan);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Split document'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment<int>(value: 0, label: Text('Every N pages')),
                ButtonSegment<int>(value: 1, label: Text('Ranges')),
              ],
              selected: <int>{_mode},
              onSelectionChanged: (v) => setState(() {
                _mode = v.first;
                _bad = false;
              }),
            ),
            const SizedBox(height: AppSpacing.md),
            if (_mode == 0)
              TextField(
                controller: _every,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Pages per file'.tr,
                  border: const OutlineInputBorder(),
                ),
              )
            else
              TextField(
                controller: _ranges,
                decoration: InputDecoration(
                  labelText: 'Ranges, for example 1-3, 4, 5-8'.tr,
                  border: const OutlineInputBorder(),
                ),
              ),
            if (_bad)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  'Check the numbers you entered',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _done, child: const Text('Split')),
      ],
    );
  }
}

Widget _colorRow(BuildContext context, int color, ValueChanged<int> onChanged) {
  const palette = <int>[
    0xFF111111,
    0xFF616161,
    0xFF9E9E9E,
    0xFFE53935,
    0xFF1E88E5,
    0xFF43A047,
  ];
  final scheme = Theme.of(context).colorScheme;
  return Wrap(
    spacing: AppSpacing.sm,
    runSpacing: AppSpacing.sm,
    children: [
      for (final c in palette)
        InkResponse(
          onTap: () => onChanged(c),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: Color(c),
              shape: BoxShape.circle,
              border: Border.all(
                color: c == color ? scheme.primary : scheme.outlineVariant,
                width: c == color ? 3 : 1,
              ),
            ),
          ),
        ),
      InkResponse(
        onTap: () async {
          final picked = await pickColor(
            context,
            initial: color,
            allowNone: false,
          );
          if (picked != null) onChanged(picked | 0xFF000000);
        },
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Icon(
            Icons.palette_outlined,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  );
}

Widget _scopeSwitch(bool value, ValueChanged<bool> onChanged) {
  return SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('Only the selected pages'),
    value: value,
    onChanged: onChanged,
  );
}

Future<NumberSetup?> askNumbers(
  BuildContext context, {
  required bool hasSelection,
  required int total,
}) {
  return showDialog<NumberSetup>(
    context: context,
    builder: (_) => _NumberDialog(hasSelection: hasSelection, total: total),
  );
}

class _NumberDialog extends StatefulWidget {
  const _NumberDialog({required this.hasSelection, required this.total});

  final bool hasSelection;
  final int total;

  @override
  State<_NumberDialog> createState() => _NumberDialogState();
}

class _NumberDialogState extends State<_NumberDialog> {
  int _position = 0;
  int _format = 0;
  double _size = 12;
  int _color = 0xFF111111;
  final TextEditingController _start = TextEditingController(text: '1');
  late bool _selectedOnly = widget.hasSelection;

  static const List<String> _places = <String>[
    'Bottom center',
    'Bottom right',
    'Bottom left',
    'Top center',
    'Top right',
    'Top left',
  ];

  @override
  void dispose() {
    _start.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Page numbers'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<int>(
              initialValue: _position,
              decoration: InputDecoration(
                labelText: 'Position'.tr,
                border: const OutlineInputBorder(),
              ),
              items: [
                for (var i = 0; i < _places.length; i++)
                  DropdownMenuItem<int>(value: i, child: Text(_places[i])),
              ],
              onChanged: (v) => setState(() => _position = v ?? 0),
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<int>(
              initialValue: _format,
              decoration: InputDecoration(
                labelText: 'Format'.tr,
                border: const OutlineInputBorder(),
              ),
              items: [
                for (var i = 0; i < 5; i++)
                  DropdownMenuItem<int>(
                    value: i,
                    child: Text(numberText(i, 3, widget.total)),
                  ),
              ],
              onChanged: (v) => setState(() => _format = v ?? 0),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _start,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'First number'.tr,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                const Icon(Icons.format_size_rounded, size: 20),
                Expanded(
                  child: Slider(
                    min: 8,
                    max: 36,
                    value: _size,
                    onChanged: (v) => setState(() => _size = v),
                  ),
                ),
              ],
            ),
            _colorRow(context, _color, (c) => setState(() => _color = c)),
            if (widget.hasSelection)
              _scopeSwitch(
                _selectedOnly,
                (v) => setState(() => _selectedOnly = v),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            NumberSetup(
              position: _position,
              format: _format,
              size: _size,
              color: _color,
              start: int.tryParse(_start.text.trim()) ?? 1,
              selectedOnly: widget.hasSelection && _selectedOnly,
            ),
          ),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

Future<WatermarkSetup?> askWatermark(
  BuildContext context, {
  required bool hasSelection,
}) {
  return showDialog<WatermarkSetup>(
    context: context,
    builder: (_) => _WatermarkDialog(hasSelection: hasSelection),
  );
}

class _WatermarkDialog extends StatefulWidget {
  const _WatermarkDialog({required this.hasSelection});

  final bool hasSelection;

  @override
  State<_WatermarkDialog> createState() => _WatermarkDialogState();
}

class _WatermarkDialogState extends State<_WatermarkDialog> {
  final TextEditingController _text = TextEditingController();
  double _size = 64;
  int _color = 0xFF9E9E9E;
  double _opacity = 0.3;
  bool _diagonal = true;
  late bool _selectedOnly = widget.hasSelection;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Watermark'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _text,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Text'.tr,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                const Icon(Icons.format_size_rounded, size: 20),
                Expanded(
                  child: Slider(
                    min: 20,
                    max: 140,
                    value: _size,
                    onChanged: (v) => setState(() => _size = v),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const Icon(Icons.opacity_rounded, size: 20),
                Expanded(
                  child: Slider(
                    min: 0.05,
                    max: 1,
                    value: _opacity,
                    onChanged: (v) => setState(() => _opacity = v),
                  ),
                ),
              ],
            ),
            _colorRow(context, _color, (c) => setState(() => _color = c)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Diagonal'),
              value: _diagonal,
              onChanged: (v) => setState(() => _diagonal = v),
            ),
            if (widget.hasSelection)
              _scopeSwitch(
                _selectedOnly,
                (v) => setState(() => _selectedOnly = v),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _text.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  WatermarkSetup(
                    text: _text.text.trim(),
                    size: _size,
                    color: _color,
                    opacity: _opacity,
                    diagonal: _diagonal,
                    selectedOnly: widget.hasSelection && _selectedOnly,
                  ),
                ),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

Future<CropSetup?> askCrop(BuildContext context, {required bool hasSelection}) {
  return showDialog<CropSetup>(
    context: context,
    builder: (_) => _CropDialog(hasSelection: hasSelection),
  );
}

class _CropDialog extends StatefulWidget {
  const _CropDialog({required this.hasSelection});

  final bool hasSelection;

  @override
  State<_CropDialog> createState() => _CropDialogState();
}

class _CropDialogState extends State<_CropDialog> {
  final List<double> _v = <double>[0, 0, 0, 0];
  late bool _selectedOnly = widget.hasSelection;

  static const List<String> _names = <String>['Left', 'Top', 'Right', 'Bottom'];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Crop pages'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < 4; i++)
              Row(
                children: [
                  SizedBox(width: 64, child: Text(_names[i])),
                  Expanded(
                    child: Slider(
                      min: 0,
                      max: 45,
                      divisions: 45,
                      value: _v[i],
                      onChanged: (x) => setState(() => _v[i] = x),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      L10n.digits('${_v[i].round()}%'),
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            if (widget.hasSelection)
              _scopeSwitch(
                _selectedOnly,
                (v) => setState(() => _selectedOnly = v),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            CropSetup(
              insets: const <double>[0, 0, 0, 0],
              selectedOnly: widget.hasSelection && _selectedOnly,
            ),
          ),
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            CropSetup(
              insets: List<double>.of(_v),
              selectedOnly: widget.hasSelection && _selectedOnly,
            ),
          ),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

Future<(String, String)?> askInfo(
  BuildContext context,
  String title,
  String author,
) {
  return showDialog<(String, String)>(
    context: context,
    builder: (_) => _InfoDialog(title: title, author: author),
  );
}

class _InfoDialog extends StatefulWidget {
  const _InfoDialog({required this.title, required this.author});

  final String title;
  final String author;

  @override
  State<_InfoDialog> createState() => _InfoDialogState();
}

class _InfoDialogState extends State<_InfoDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.title,
  );
  late final TextEditingController _author = TextEditingController(
    text: widget.author,
  );

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Document info'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              decoration: InputDecoration(
                labelText: 'Title'.tr,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _author,
              decoration: InputDecoration(
                labelText: 'Author'.tr,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop((_title.text.trim(), _author.text.trim())),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

Offset fromTurned(Offset u, Size visible, int turns) {
  switch (turns % 4) {
    case 1:
      return Offset(u.dy, visible.height - u.dx);
    case 2:
      return Offset(visible.width - u.dx, visible.height - u.dy);
    case 3:
      return Offset(visible.width - u.dy, u.dx);
    default:
      return u;
  }
}

List<double> insetsToOriginal(List<double> turnedInsets, int turns) {
  final l = turnedInsets[0];
  final t = turnedInsets[1];
  final r = turnedInsets[2];
  final b = turnedInsets[3];
  switch (turns % 4) {
    case 1:
      return <double>[t, r, b, l];
    case 2:
      return <double>[r, b, l, t];
    case 3:
      return <double>[b, l, t, r];
    default:
      return <double>[l, t, r, b];
  }
}

List<PageItem> applyCrop(
  List<PageItem> pages,
  Set<String>? only,
  List<double> percent,
) {
  return <PageItem>[
    for (final page in pages)
      if (only != null && !only.contains(page.id))
        page
      else
        page.copyWith(crop: _cropFor(page, percent)),
  ];
}

List<double> _cropFor(PageItem page, List<double> percent) {
  if (percent.every((v) => v <= 0)) return const <double>[0, 0, 0, 0];
  final turned = page.turns.isOdd
      ? Size(page.size.height, page.size.width)
      : page.size;
  final insets = <double>[
    turned.width * percent[0] / 100,
    turned.height * percent[1] / 100,
    turned.width * percent[2] / 100,
    turned.height * percent[3] / 100,
  ];
  return insetsToOriginal(insets, page.turns);
}

Future<List<PageItem>> applyNumbers(
  List<PageItem> pages,
  Set<String>? only,
  NumberSetup setup,
) async {
  final out = <PageItem>[];
  var counter = setup.start;
  final total = pages.length;
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    final targeted = only == null || only.contains(page.id);
    final kept = <Annotation>[
      for (final a in page.overlays)
        if (!(targeted && a.tag == numberTag)) a,
    ];
    if (!targeted) {
      out.add(page.copyWith(overlays: kept));
      continue;
    }
    final shown = page.shown;
    final raster = await rasterText(
      numberText(setup.format, counter, total + setup.start - 1),
      sizePt: setup.size,
      color: setup.color,
      maxWidth: shown.width,
    );
    counter++;
    if (raster == null) {
      out.add(page.copyWith(overlays: kept));
      continue;
    }
    const margin = 24.0;
    final column = setup.position % 3;
    final top = setup.position >= 3;
    final cx = switch (column) {
      0 => shown.width / 2,
      1 => shown.width - margin - raster.width / 2,
      _ => margin + raster.width / 2,
    };
    final cy = top
        ? margin + raster.height / 2
        : shown.height - margin - raster.height / 2;
    final centre =
        fromTurned(Offset(cx, cy), shown, page.turns) + page.visible.topLeft;
    final item = PictureOverlay(
      rect: Rect.fromCenter(
        center: centre,
        width: raster.width,
        height: raster.height,
      ),
      bytes: raster.bytes,
      rotation: -page.turns * math.pi / 2,
      tag: numberTag,
    );
    out.add(page.copyWith(overlays: <Annotation>[...kept, item]));
  }
  return out;
}

Future<List<PageItem>> applyWatermark(
  List<PageItem> pages,
  Set<String>? only,
  WatermarkSetup setup,
) async {
  final out = <PageItem>[];
  final raster = await rasterText(
    setup.text,
    sizePt: setup.size,
    color: setup.color,
    bold: true,
    maxWidth: 4000,
  );
  for (final page in pages) {
    final targeted = only == null || only.contains(page.id);
    final kept = <Annotation>[
      for (final a in page.overlays)
        if (!(targeted && a.tag == markTag)) a,
    ];
    if (!targeted || raster == null) {
      out.add(page.copyWith(overlays: kept));
      continue;
    }
    final shown = page.shown;
    var width = raster.width;
    var height = raster.height;
    final angle = setup.diagonal ? -math.pi / 4 : 0.0;
    final cosA = math.cos(angle).abs();
    final sinA = math.sin(angle).abs();
    final spanX = width * cosA + height * sinA;
    final spanY = width * sinA + height * cosA;
    final fit = math.min(
      1.0,
      math.min(shown.width * 0.92 / spanX, shown.height * 0.92 / spanY),
    );
    width *= fit;
    height *= fit;
    final centre =
        fromTurned(
          Offset(shown.width / 2, shown.height / 2),
          shown,
          page.turns,
        ) +
        page.visible.topLeft;
    final item = PictureOverlay(
      rect: Rect.fromCenter(center: centre, width: width, height: height),
      bytes: raster.bytes,
      rotation: angle - page.turns * math.pi / 2,
      opacity: setup.opacity,
      tag: markTag,
    );
    out.add(page.copyWith(overlays: <Annotation>[...kept, item]));
  }
  return out;
}

List<PageItem> removeTagged(
  List<PageItem> pages,
  Set<String>? only,
  String tag,
) {
  return <PageItem>[
    for (final page in pages)
      if (only != null && !only.contains(page.id))
        page
      else
        page.copyWith(
          overlays: <Annotation>[
            for (final a in page.overlays)
              if (a.tag != tag) a,
          ],
        ),
  ];
}
