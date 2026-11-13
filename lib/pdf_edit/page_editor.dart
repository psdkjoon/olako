import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/export/color_dialog.dart';
import 'package:olako/localization/localization.dart';
import 'package:olako/pdf_edit/models.dart';
import 'package:olako/pdf_edit/overlay_paint.dart';
import 'package:olako/pdf_edit/page_images.dart';
import 'package:olako/pdf_edit/signature_pad.dart';
import 'package:olako/pdf_edit/text_raster.dart';
import 'package:olako/platform/document_service.dart';
import 'package:olako/theme/app_spacing.dart';

enum EditTool {
  hand,
  select,
  pen,
  marker,
  text,
  rect,
  oval,
  line,
  arrow,
  eraser,
}

const List<int> _palette = <int>[
  0xFF111111,
  0xFFE53935,
  0xFFFB8C00,
  0xFFFDD835,
  0xFF43A047,
  0xFF1E88E5,
  0xFF8E24AA,
  0xFFFFFFFF,
];

enum _Drag { none, move, corner, endA, endB }

class PageEditorScreen extends StatefulWidget {
  const PageEditorScreen({
    required this.page,
    required this.source,
    required this.images,
    required this.store,
    super.key,
  });

  final PageItem page;
  final PdfSource? source;
  final PageImages images;
  final PictureStore store;

  @override
  State<PageEditorScreen> createState() => _PageEditorScreenState();
}

class _PageEditorScreenState extends State<PageEditorScreen> {
  late List<Annotation> _items = cloneAll(widget.page.overlays);
  final List<List<Annotation>> _undo = <List<Annotation>>[];
  final List<List<Annotation>> _redo = <List<Annotation>>[];
  final Map<int, Offset> _pointers = <int, Offset>{};

  EditTool _tool = EditTool.pen;
  int _color = _palette[1];
  double _width = 3;
  double _opacity = 1;
  bool _fill = false;
  double _textSize = 18;
  bool _textBold = false;

  ui.Image? _image;
  int _imageWidth = 0;
  Size _viewport = Size.zero;
  double _fit = 1;
  double _zoom = 1;
  Offset _origin = Offset.zero;
  bool _placed = false;

  Annotation? _current;
  Annotation? _selected;
  Annotation? _dragBase;
  _Drag _drag = _Drag.none;
  Offset _dragStart = Offset.zero;
  bool _moved = false;
  Offset? _tapAt;
  bool _gestureDead = false;
  bool _erased = false;
  double _lastDistance = 0;
  Offset _lastFocal = Offset.zero;
  bool _dirty = false;

  Size get _pageSize => widget.page.size;

  int get _turns => widget.page.turns % 4;

  Size get _turned {
    final s = _pageSize;
    return _turns.isOdd ? Size(s.height, s.width) : s;
  }

  double get _k => _fit * _zoom;

  @override
  void initState() {
    super.initState();
    unawaited(_loadImage(1600));
  }

  Future<void> _loadImage(int width) async {
    final source = widget.source;
    if (source == null || widget.page.blank) return;
    if (width <= _imageWidth) return;
    _imageWidth = width;
    final image = await widget.images.get(source, widget.page.index, width);
    if (!mounted || image == null) return;
    setState(() => _image = image);
  }

  void _layout(Size viewport) {
    if (viewport == _viewport && _placed) return;
    final t = _turned;
    final fit = math.max(
      0.05,
      math.min(
        (viewport.width - 24) / t.width,
        (viewport.height - 24) / t.height,
      ),
    );
    if (!_placed) {
      _fit = fit;
      _zoom = 1;
      _origin = Offset(
        (viewport.width - t.width * fit) / 2,
        (viewport.height - t.height * fit) / 2,
      );
      _placed = true;
    } else {
      final oldCenter = Offset(_viewport.width / 2, _viewport.height / 2);
      final anchor = (oldCenter - _origin) / _k;
      _fit = fit;
      _origin = Offset(viewport.width / 2, viewport.height / 2) - anchor * _k;
    }
    _viewport = viewport;
  }

  void _clampOrigin() {
    final t = _turned;
    final w = t.width * _k;
    final h = t.height * _k;
    const keep = 80.0;
    final loX = math.min(keep - w, _viewport.width - keep);
    final hiX = math.max(keep - w, _viewport.width - keep);
    final loY = math.min(keep - h, _viewport.height - keep);
    final hiY = math.max(keep - h, _viewport.height - keep);
    _origin = Offset(
      _origin.dx.clamp(loX, hiX).toDouble(),
      _origin.dy.clamp(loY, hiY).toDouble(),
    );
  }

  Offset _toPage(Offset screen) {
    final u = (screen - _origin) / _k;
    final s = _pageSize;
    switch (_turns) {
      case 1:
        return Offset(u.dy, s.height - u.dx);
      case 2:
        return Offset(s.width - u.dx, s.height - u.dy);
      case 3:
        return Offset(s.width - u.dy, u.dx);
      default:
        return u;
    }
  }

  void _zoomAt(Offset focal, double ratio) {
    final next = (_zoom * ratio).clamp(1.0, 12.0).toDouble();
    final r = next / _zoom;
    _origin = focal - (focal - _origin) * r;
    _zoom = next;
    _clampOrigin();
    if (_zoom > 2.2) unawaited(_loadImage(2800));
  }

  void _push() {
    _undo.add(cloneAll(_items));
    if (_undo.length > 60) _undo.removeAt(0);
    _redo.clear();
    _dirty = true;
  }

  void _undoStep() {
    if (_undo.isEmpty) return;
    _redo.add(cloneAll(_items));
    setState(() {
      _items = _undo.removeLast();
      _selected = null;
    });
  }

  void _redoStep() {
    if (_redo.isEmpty) return;
    _undo.add(cloneAll(_items));
    setState(() {
      _items = _redo.removeLast();
      _selected = null;
    });
  }

  double get _slop => 14 / _k;

  Annotation? _topAt(Offset p) {
    for (var i = _items.length - 1; i >= 0; i--) {
      if (_items[i].hit(p, _slop)) return _items[i];
    }
    return null;
  }

  List<Offset> _corners(Annotation item) {
    if (item is PictureOverlay) {
      final r = item.rect;
      return <Offset>[
        item.rotate(r.topLeft),
        item.rotate(r.topRight),
        item.rotate(r.bottomRight),
        item.rotate(r.bottomLeft),
      ];
    }
    final b = item.bounds;
    return <Offset>[b.topLeft, b.topRight, b.bottomRight, b.bottomLeft];
  }

  Offset _cornerHandle(Annotation item) => _corners(item)[2];

  _Drag _handleAt(Annotation item, Offset p) {
    final reach = 20 / _k;
    if (item is MarkOverlay && item.linear) {
      if ((item.a - p).distance <= reach) return _Drag.endA;
      if ((item.b - p).distance <= reach) return _Drag.endB;
    } else if ((_cornerHandle(item) - p).distance <= reach) {
      return _Drag.corner;
    }
    return _Drag.none;
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2) {
      _cancelStroke();
      _gestureDead = true;
      final points = _pointers.values.toList();
      _lastDistance = (points[0] - points[1]).distance;
      _lastFocal = (points[0] + points[1]) / 2;
      return;
    }
    if (_pointers.length > 2) return;
    _gestureDead = false;
    _erased = false;
    _moved = false;
    final p = _toPage(e.localPosition);
    _dragStart = p;
    _tapAt = e.localPosition;
    switch (_tool) {
      case EditTool.hand:
        break;
      case EditTool.pen:
      case EditTool.marker:
        final marker = _tool == EditTool.marker;
        setState(() {
          _current = InkOverlay(
            points: <Offset>[p],
            color: _color,
            width: marker ? math.max(_width * 3, 10) : _width,
            opacity: marker ? math.min(_opacity, 0.4) : _opacity,
            highlight: marker,
          );
        });
      case EditTool.rect:
      case EditTool.oval:
      case EditTool.line:
      case EditTool.arrow:
        final kind = switch (_tool) {
          EditTool.rect => MarkKind.rect,
          EditTool.oval => MarkKind.oval,
          EditTool.line => MarkKind.line,
          _ => MarkKind.arrow,
        };
        setState(() {
          _current = MarkOverlay(
            kind: kind,
            a: p,
            b: p,
            stroke: _color,
            fill: _fill && (kind == MarkKind.rect || kind == MarkKind.oval)
                ? _color
                : null,
            width: _width,
            opacity: _opacity,
          );
        });
      case EditTool.eraser:
        _erase(p);
      case EditTool.select:
        _beginSelect(p);
      case EditTool.text:
        break;
    }
  }

  void _beginSelect(Offset p) {
    final chosen = _selected;
    if (chosen != null) {
      final handle = _handleAt(chosen, p);
      if (handle != _Drag.none) {
        _dragPushed = false;
        setState(() {
          _drag = handle;
          _dragBase = chosen.clone();
        });
        return;
      }
    }
    final hit = _topAt(p);
    _dragPushed = false;
    setState(() {
      _selected = hit;
      _drag = hit == null ? _Drag.none : _Drag.move;
      _dragBase = hit?.clone();
    });
  }

  void _erase(Offset p) {
    final hit = _topAt(p);
    if (hit == null) return;
    if (!_erased) {
      _push();
      _erased = true;
    }
    setState(() => _items.remove(hit));
  }

  void _cancelStroke() {
    if (_current != null || _drag != _Drag.none) {
      final base = _dragBase;
      final item = _selected;
      if (_drag != _Drag.none && base != null && item != null) {
        final index = _items.indexOf(item);
        if (index >= 0 && _moved) {
          _items[index] = base;
          _selected = base;
        }
      }
      setState(() {
        _current = null;
        _drag = _Drag.none;
        _dragBase = null;
      });
    }
  }

  void _move(PointerMoveEvent e) {
    final before = _pointers[e.pointer];
    if (before == null) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length >= 2) {
      final points = _pointers.values.take(2).toList();
      final distance = (points[0] - points[1]).distance;
      final focal = (points[0] + points[1]) / 2;
      setState(() {
        if (_lastDistance > 8) _zoomAt(focal, distance / _lastDistance);
        _origin += focal - _lastFocal;
        _clampOrigin();
      });
      _lastDistance = distance;
      _lastFocal = focal;
      return;
    }
    if (_gestureDead) return;
    final screen = e.localPosition;
    final p = _toPage(screen);
    final tap = _tapAt;
    if (tap != null && (tap - screen).distance > 6) _moved = true;
    switch (_tool) {
      case EditTool.hand:
        setState(() {
          _origin += e.delta;
          _clampOrigin();
        });
      case EditTool.pen:
      case EditTool.marker:
        final ink = _current;
        if (ink is InkOverlay) {
          if ((ink.points.last - p).distance * _k < 2) return;
          setState(() => ink.points.add(p));
        }
      case EditTool.rect:
      case EditTool.oval:
      case EditTool.line:
      case EditTool.arrow:
        final mark = _current;
        if (mark is MarkOverlay) {
          setState(() => mark.b = p);
        }
      case EditTool.eraser:
        _erase(p);
      case EditTool.select:
        _dragSelected(p);
      case EditTool.text:
        break;
    }
  }

  void _dragSelected(Offset p) {
    final base = _dragBase;
    final item = _selected;
    if (base == null || item == null || _drag == _Drag.none || !_moved) return;
    final index = _items.indexOf(item);
    if (index < 0) return;
    if (!_dragPushed) {
      _push();
      _dragPushed = true;
    }
    final next = base.clone();
    switch (_drag) {
      case _Drag.move:
        next.shift(p - _dragStart);
      case _Drag.corner:
        if (next is PictureOverlay) {
          next.dragCorner(p, 12);
        } else {
          final from = next.bounds;
          final to = Rect.fromLTRB(
            from.left,
            from.top,
            math.max(p.dx, from.left + 6),
            math.max(p.dy, from.top + 6),
          );
          next.resize(from, to);
        }
      case _Drag.endA:
        if (next is MarkOverlay) next.a = p;
      case _Drag.endB:
        if (next is MarkOverlay) next.b = p;
      case _Drag.none:
        break;
    }
    next.tag = base.tag;
    setState(() {
      _items[index] = next;
      _selected = next;
    });
  }

  bool _dragPushed = false;

  void _up(PointerEvent e) {
    final wasTwo = _pointers.length >= 2;
    _pointers.remove(e.pointer);
    if (wasTwo) {
      if (_pointers.length == 1) {
        _gestureDead = true;
      }
      return;
    }
    if (_gestureDead) {
      _gestureDead = false;
      return;
    }
    if (e is PointerCancelEvent) {
      _cancelStroke();
      return;
    }
    final current = _current;
    if (current != null) {
      var keep = true;
      if (current is MarkOverlay) {
        keep = (current.a - current.b).distance * _k > 4;
      }
      if (keep) {
        _push();
        setState(() {
          _items.add(current);
          _current = null;
        });
      } else {
        setState(() => _current = null);
      }
    }
    if (_drag != _Drag.none) {
      setState(() {
        _drag = _Drag.none;
        _dragBase = null;
      });
      _dragPushed = false;
    }
    if (_tool == EditTool.text && !_moved) {
      final at = _tapAt;
      if (at != null) unawaited(_askText(_toPage(at)));
    }
    _tapAt = null;
  }

  void _signal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      final ratio = math.exp(-e.scrollDelta.dy / 300);
      setState(() => _zoomAt(e.localPosition, ratio));
    }
  }

  Future<void> _askText(Offset at) async {
    final result = await showDialog<_TextAnswer>(
      context: context,
      builder: (_) =>
          _TextDialog(color: _color, size: _textSize, bold: _textBold),
    );
    if (result == null || !mounted) return;
    _textSize = result.size;
    _textBold = result.bold;
    final raster = await rasterText(
      result.text,
      sizePt: result.size,
      color: result.color,
      bold: result.bold,
      maxWidth: math.max(80, _pageSize.width * 0.8),
    );
    if (raster == null || !mounted) return;
    final rect = Rect.fromLTWH(
      (at.dx - raster.width / 2)
          .clamp(0.0, math.max(0.0, _pageSize.width - raster.width))
          .toDouble(),
      (at.dy - raster.height / 2)
          .clamp(0.0, math.max(0.0, _pageSize.height - raster.height))
          .toDouble(),
      raster.width,
      raster.height,
    );
    _push();
    final item = PictureOverlay(rect: rect, bytes: raster.bytes);
    setState(() {
      _items.add(item);
      _selected = item;
      _tool = EditTool.select;
    });
  }

  Future<void> _addImage() async {
    final path = await DocumentService.pick();
    if (path == null || !mounted) return;
    Size? size;
    try {
      final bytes = await File(path).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      size = Size(descriptor.width.toDouble(), descriptor.height.toDouble());
      descriptor.dispose();
      buffer.dispose();
    } on Object {
      size = null;
    }
    if (!mounted) return;
    if (size == null || size.width <= 0 || size.height <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Couldn't open this image")));
      return;
    }
    _place(PictureOverlay(rect: Rect.zero, path: path), size, 0.45);
  }

  Future<void> _addSignature() async {
    final result = await askSignature(context);
    if (result == null || !mounted) return;
    _place(
      PictureOverlay(rect: Rect.zero, bytes: result.bytes),
      result.size,
      0.3,
    );
  }

  void _place(PictureOverlay item, Size natural, double share) {
    final page = _pageSize;
    var w = page.width * share;
    var h = w * natural.height / natural.width;
    if (h > page.height * 0.6) {
      h = page.height * 0.6;
      w = h * natural.width / natural.height;
    }
    final center = _toPage(Offset(_viewport.width / 2, _viewport.height / 2));
    final cx = center.dx
        .clamp(w / 2, math.max(w / 2, page.width - w / 2))
        .toDouble();
    final cy = center.dy
        .clamp(h / 2, math.max(h / 2, page.height - h / 2))
        .toDouble();
    item.rect = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
    _push();
    setState(() {
      _items.add(item);
      _selected = item;
      _tool = EditTool.select;
    });
  }

  void _deleteSelected() {
    final item = _selected;
    if (item == null) return;
    _push();
    setState(() {
      _items.remove(item);
      _selected = null;
    });
  }

  void _duplicateSelected() {
    final item = _selected;
    if (item == null) return;
    _push();
    final copy = item.clone()..shift(const Offset(14, 14));
    setState(() {
      _items.add(copy);
      _selected = copy;
    });
  }

  void _turnSelected() {
    final item = _selected;
    if (item is! PictureOverlay) return;
    _push();
    setState(() => item.rotation += math.pi / 12);
  }

  void _setColor(int color) {
    setState(() => _color = color);
    final item = _selected;
    if (_tool != EditTool.select || item == null) return;
    if (item is InkOverlay) {
      _push();
      setState(() => item.color = color);
    } else if (item is MarkOverlay) {
      _push();
      setState(() {
        item.stroke = color;
        if (item.fill != null) item.fill = color;
      });
    }
  }

  void _setWidth(double width) {
    setState(() => _width = width);
    final item = _selected;
    if (_tool != EditTool.select || item == null) return;
    if (item is InkOverlay) {
      setState(() => item.width = item.highlight ? width * 3 : width);
    } else if (item is MarkOverlay) {
      setState(() => item.width = width);
    }
  }

  Future<void> _customColor() async {
    final picked = await pickColor(context, initial: _color, allowNone: false);
    if (picked == null) return;
    _setColor(picked | 0xFF000000);
  }

  void _chooseTool(EditTool tool) {
    setState(() {
      _tool = tool;
      if (tool != EditTool.select) _selected = null;
      if (tool == EditTool.marker) {
        _color = _palette[3];
        _opacity = 0.4;
      } else if (tool == EditTool.pen && _opacity < 1) {
        _opacity = 1;
      }
    });
  }

  Future<void> _leave() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final navigator = Navigator.of(context);
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Keep these changes?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('stay'),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('discard'),
            child: const Text("Don't save"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'discard') {
      navigator.pop();
    } else if (choice == 'save') {
      navigator.pop(_items);
    }
  }

  IconData _iconOf(EditTool tool) {
    return switch (tool) {
      EditTool.hand => Icons.pan_tool_alt_outlined,
      EditTool.select => Icons.near_me_outlined,
      EditTool.pen => Icons.edit_rounded,
      EditTool.marker => Icons.border_color_rounded,
      EditTool.text => Icons.text_fields_rounded,
      EditTool.rect => Icons.crop_square_rounded,
      EditTool.oval => Icons.circle_outlined,
      EditTool.line => Icons.horizontal_rule_rounded,
      EditTool.arrow => Icons.north_east_rounded,
      EditTool.eraser => Icons.cleaning_services_outlined,
    };
  }

  String _labelOf(EditTool tool) {
    return switch (tool) {
      EditTool.hand => 'Move view',
      EditTool.select => 'Select',
      EditTool.pen => 'Pen',
      EditTool.marker => 'Highlighter',
      EditTool.text => 'Text',
      EditTool.rect => 'Rectangle',
      EditTool.oval => 'Ellipse',
      EditTool.line => 'Line',
      EditTool.arrow => 'Arrow',
      EditTool.eraser => 'Eraser',
    };
  }

  Widget _toolButton(EditTool tool) {
    final selected = _tool == tool;
    return IconButton(
      tooltip: _labelOf(tool).tr,
      isSelected: selected,
      style: selected
          ? IconButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
            )
          : null,
      icon: Icon(_iconOf(tool)),
      onPressed: () => _chooseTool(tool),
    );
  }

  Widget _swatches() {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        children: [
          for (final c in _palette)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
              child: InkResponse(
                onTap: () => _setColor(c),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c == _color
                          ? scheme.primary
                          : scheme.outlineVariant,
                      width: c == _color ? 3 : 1,
                    ),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
            child: InkResponse(
              onTap: _customColor,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Icon(
                  Icons.palette_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool get _usesStroke =>
      _tool == EditTool.pen ||
      _tool == EditTool.marker ||
      _tool == EditTool.rect ||
      _tool == EditTool.oval ||
      _tool == EditTool.line ||
      _tool == EditTool.arrow ||
      (_tool == EditTool.select &&
          (_selected is InkOverlay || _selected is MarkOverlay));

  bool get _canFill => _tool == EditTool.rect || _tool == EditTool.oval;

  Widget _options() {
    final theme = Theme.of(context);
    final selected = _selected;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_tool != EditTool.hand &&
            _tool != EditTool.eraser &&
            (_tool != EditTool.select ||
                selected is InkOverlay ||
                selected is MarkOverlay))
          _swatches(),
        if (_usesStroke)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                const Icon(Icons.line_weight_rounded, size: 20),
                Expanded(
                  child: Slider(
                    min: 1,
                    max: 16,
                    value: _width.clamp(1.0, 16.0).toDouble(),
                    onChanged: _setWidth,
                  ),
                ),
                if (_canFill)
                  FilterChip(
                    label: const Text('Fill'),
                    selected: _fill,
                    onSelected: (v) => setState(() => _fill = v),
                  ),
              ],
            ),
          ),
        if (_tool == EditTool.select && selected != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Duplicate'.tr,
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: _duplicateSelected,
                ),
                if (selected is PictureOverlay)
                  IconButton(
                    tooltip: 'Rotate'.tr,
                    icon: const Icon(Icons.rotate_right_rounded),
                    onPressed: _turnSelected,
                  ),
                IconButton(
                  tooltip: 'Delete'.tr,
                  color: theme.colorScheme.error,
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: _deleteSelected,
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    final source = widget.source;
    if (source != null && !widget.page.blank) {
      for (final w in <int>[1600, 2800]) {
        widget.images.release(source, widget.page.index, w);
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit page'),
          leading: IconButton(
            tooltip: 'Back'.tr,
            icon: const Icon(Icons.close_rounded),
            onPressed: () => unawaited(_leave()),
          ),
          actions: [
            IconButton(
              tooltip: 'Undo'.tr,
              icon: const Icon(Icons.undo_rounded),
              onPressed: _undo.isEmpty ? null : _undoStep,
            ),
            IconButton(
              tooltip: 'Redo'.tr,
              icon: const Icon(Icons.redo_rounded),
              onPressed: _redo.isEmpty ? null : _redoStep,
            ),
            IconButton(
              tooltip: 'Done'.tr,
              icon: const Icon(Icons.check_rounded),
              onPressed: () => Navigator.of(context).pop(_items),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _layout(constraints.biggest);
                    return ClipRect(
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: _down,
                        onPointerMove: _move,
                        onPointerUp: _up,
                        onPointerCancel: _up,
                        onPointerSignal: _signal,
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: _EditorPainter(
                            image: _image,
                            page: _pageSize,
                            turns: _turns,
                            origin: _origin,
                            scale: _k,
                            items: _items,
                            current: _current,
                            selected: _tool == EditTool.select
                                ? _selected
                                : null,
                            store: widget.store,
                            accent: scheme.primary,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Material(
              color: scheme.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _options(),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                      ),
                      child: Row(
                        children: [
                          for (final tool in EditTool.values) _toolButton(tool),
                          IconButton(
                            tooltip: 'Image'.tr,
                            icon: const Icon(Icons.image_outlined),
                            onPressed: () => unawaited(_addImage()),
                          ),
                          IconButton(
                            tooltip: 'Signature'.tr,
                            icon: const Icon(Icons.draw_outlined),
                            onPressed: () => unawaited(_addSignature()),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditorPainter extends CustomPainter {
  _EditorPainter({
    required this.image,
    required this.page,
    required this.turns,
    required this.origin,
    required this.scale,
    required this.items,
    required this.current,
    required this.selected,
    required this.store,
    required this.accent,
  }) : super(repaint: store);

  final ui.Image? image;
  final Size page;
  final int turns;
  final Offset origin;
  final double scale;
  final List<Annotation> items;
  final Annotation? current;
  final Annotation? selected;
  final PictureStore store;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale);
    final turned = turns.isOdd ? Size(page.height, page.width) : page;
    canvas.drawRect(
      (Offset.zero & turned).inflate(1 / scale),
      Paint()..color = const Color(0x33000000),
    );
    switch (turns) {
      case 1:
        canvas.translate(page.height, 0);
        canvas.rotate(math.pi / 2);
      case 2:
        canvas.translate(page.width, page.height);
        canvas.rotate(math.pi);
      case 3:
        canvas.translate(0, page.width);
        canvas.rotate(math.pi * 3 / 2);
    }
    final area = Offset.zero & page;
    canvas.save();
    canvas.clipRect(area);
    canvas.drawRect(area, Paint()..color = const Color(0xFFFFFFFF));
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
    paintAnnotations(canvas, items, store);
    final live = current;
    if (live != null) paintAnnotation(canvas, live, store);
    canvas.restore();
    final chosen = selected;
    if (chosen != null) _paintSelection(canvas, chosen);
    canvas.restore();
  }

  void _paintSelection(Canvas canvas, Annotation item) {
    final line = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / scale;
    final handle = Paint()..color = accent;
    final white = Paint()..color = const Color(0xFFFFFFFF);
    final r = 7 / scale;
    if (item is MarkOverlay && item.linear) {
      for (final p in <Offset>[item.a, item.b]) {
        canvas.drawCircle(p, r + 1.5 / scale, white);
        canvas.drawCircle(p, r, handle);
      }
      return;
    }
    final Path outline;
    final Offset corner;
    if (item is PictureOverlay) {
      final pts = <Offset>[
        item.rotate(item.rect.topLeft),
        item.rotate(item.rect.topRight),
        item.rotate(item.rect.bottomRight),
        item.rotate(item.rect.bottomLeft),
      ];
      outline = Path()..addPolygon(pts, true);
      corner = pts[2];
    } else {
      final b = item.bounds.inflate(3 / scale);
      outline = Path()..addRect(b);
      corner = b.bottomRight;
    }
    canvas.drawPath(outline, line);
    canvas.drawCircle(corner, r + 1.5 / scale, white);
    canvas.drawCircle(corner, r, handle);
  }

  @override
  bool shouldRepaint(_EditorPainter old) => true;
}

class _TextAnswer {
  const _TextAnswer(this.text, this.size, this.bold, this.color);

  final String text;
  final double size;
  final bool bold;
  final int color;
}

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.color,
    required this.size,
    required this.bold,
  });

  final int color;
  final double size;
  final bool bold;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final TextEditingController _controller = TextEditingController();
  late double _size = widget.size;
  late bool _bold = widget.bold;
  late int _color = widget.color;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Add text'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              style: TextStyle(
                color: Color(_color),
                fontSize: math.min(_size, 32),
                fontWeight: _bold ? FontWeight.w700 : FontWeight.w400,
              ),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                filled: _color == 0xFFFFFFFF,
                fillColor: Colors.black87,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                const Icon(Icons.format_size_rounded, size: 20),
                Expanded(
                  child: Slider(
                    min: 8,
                    max: 72,
                    value: _size.clamp(8.0, 72.0).toDouble(),
                    onChanged: (v) => setState(() => _size = v),
                  ),
                ),
                IconButton.filledTonal(
                  isSelected: _bold,
                  tooltip: 'Bold'.tr,
                  icon: const Icon(Icons.format_bold_rounded),
                  onPressed: () => setState(() => _bold = !_bold),
                ),
              ],
            ),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                for (final c in _palette)
                  InkResponse(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == _color
                              ? scheme.primary
                              : scheme.outlineVariant,
                          width: c == _color ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
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
          onPressed: () {
            final text = _controller.text.trimRight();
            if (text.isEmpty) return;
            Navigator.of(context).pop(_TextAnswer(text, _size, _bold, _color));
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
