import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:flutter/widgets.dart' as w show Text;
import 'package:olako/localization/localization.dart';
import 'package:olako/platform/document_service.dart';
import 'package:olako/reader/pdf_layer_loader.dart';
import 'package:olako/reader/pdf_reader.dart';
import 'package:olako/theme/app_spacing.dart';

class PdfPagesController extends ChangeNotifier {
  int _page = 0;
  int _count = 0;
  void Function(int page)? _jump;

  int get page => _page;
  int get count => _count;

  void jumpTo(int page) => _jump?.call(page);

  void _set(int page, int count) {
    if (page == _page && count == _count) return;
    _page = page;
    _count = count;
    notifyListeners();
  }
}

class _Slot extends ChangeNotifier {
  ui.Image? image;
  int width = 0;
  int requested = 0;
  bool failed = false;

  void put(ui.Image next, int pixels) {
    if (pixels < width) {
      next.dispose();
      return;
    }
    final old = image;
    image = next;
    width = pixels;
    failed = false;
    notifyListeners();
    _later(old);
  }

  void drop() {
    final old = image;
    image = null;
    width = 0;
    requested = 0;
    if (old != null) {
      notifyListeners();
      _later(old);
    }
  }

  void fail() {
    requested = 0;
    if (failed) return;
    failed = true;
    notifyListeners();
  }

  static void _later(ui.Image? old) {
    if (old == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  void dispose() {
    image?.dispose();
    image = null;
    super.dispose();
  }
}

class _PdfSession {
  _PdfSession(this.info)
    : slots = List<_Slot>.generate(info.pages.length, (_) => _Slot());

  static const int _maxActive = 2;
  static const int _budget = 150 * 1024 * 1024;

  final PdfInfo info;
  final List<_Slot> slots;
  final Map<int, List<PdfTextLine>> layers = <int, List<PdfTextLine>>{};
  final ValueNotifier<int> layerTick = ValueNotifier<int>(0);
  final Map<int, int> _wanted = <int, int>{};

  int _focus = 0;
  int _first = 0;
  int _last = 0;
  int _active = 0;
  bool _closed = false;

  int clampWidth(int wanted, int page) {
    final size = info.pages[page];
    final ratio = size.height / size.width;
    var width = math.min(4000, math.max(64, wanted));
    if (width * width * ratio > 9000000) {
      width = math.max(64, math.sqrt(9000000 / ratio).floor());
    }
    return width;
  }

  void setRange(int first, int last, int focus) {
    _first = first;
    _last = last;
    _focus = focus;
    final stale = <int>[
      for (final page in _wanted.keys)
        if (page < first - 3 || page > last + 3) page,
    ];
    for (final page in stale) {
      _wanted.remove(page);
      slots[page].requested = 0;
    }
  }

  void want(int page, int width) {
    if (_closed || page < 0 || page >= slots.length) return;
    final target = clampWidth(width, page);
    final slot = slots[page];
    if (slot.width >= target - 2 || slot.requested >= target - 2) return;
    slot.requested = target;
    _wanted[page] = target;
    _pump();
  }

  void _pump() {
    while (!_closed && _active < _maxActive && _wanted.isNotEmpty) {
      var best = -1;
      var distance = 1 << 30;
      for (final page in _wanted.keys) {
        final d = (page - _focus).abs();
        if (d < distance) {
          distance = d;
          best = page;
        }
      }
      final width = _wanted.remove(best)!;
      _active++;
      unawaited(_render(best, width));
    }
  }

  Future<void> _render(int page, int width) async {
    try {
      final bitmap = await DocumentService.pdfRender(info.id, page, width);
      if (_closed) return;
      final slot = slots[page];
      if (bitmap == null) {
        slot.fail();
        return;
      }
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        bitmap.pixels,
        bitmap.width,
        bitmap.height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final image = await completer.future;
      if (_closed) {
        image.dispose();
        return;
      }
      slot.put(image, bitmap.width);
      _evict();
    } on Object {
      if (!_closed) slots[page].fail();
    } finally {
      _active--;
      if (!_closed) _pump();
    }
  }

  void _evict() {
    var total = 0;
    final held = <int>[];
    for (var i = 0; i < slots.length; i++) {
      final image = slots[i].image;
      if (image != null) {
        total += image.width * image.height * 4;
        held.add(i);
      }
    }
    if (total <= _budget) return;
    held.sort((a, b) => (b - _focus).abs().compareTo((a - _focus).abs()));
    for (final i in held) {
      if (total <= _budget) break;
      if (i >= _first - 1 && i <= _last + 1) continue;
      final image = slots[i].image;
      if (image == null) continue;
      total -= image.width * image.height * 4;
      slots[i].drop();
    }
  }

  void addLayer(PdfLayerPage page) {
    layers[page.index] = page.lines;
    layerTick.value++;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _wanted.clear();
    unawaited(DocumentService.pdfClose(info.id));
    for (final slot in slots) {
      slot.dispose();
    }
    layerTick.dispose();
  }
}

class _Layout {
  _Layout(this.width, List<Size> sizes, this.gap)
    : heights = <double>[],
      tops = <double>[] {
    var y = 0.0;
    for (final size in sizes) {
      final height = size.width <= 0
          ? width * 1.4
          : width * size.height / size.width;
      tops.add(y);
      heights.add(height);
      y += height + gap;
    }
    total = y;
  }

  final double width;
  final double gap;
  final List<double> heights;
  final List<double> tops;
  late final double total;

  int pageAt(double y) {
    var low = 0;
    var high = tops.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (tops[mid] <= y) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }
}

const List<double> _invertMatrix = <double>[
  -1,
  0,
  0,
  0,
  255,
  0,
  -1,
  0,
  0,
  255,
  0,
  0,
  -1,
  0,
  255,
  0,
  0,
  0,
  1,
  0,
];

class PdfPagesView extends StatefulWidget {
  const PdfPagesView({
    required this.path,
    required this.initialPosition,
    required this.invert,
    required this.onProgress,
    required this.onFailed,
    required this.controller,
    this.chipVisible = true,
    this.onChipTouch,
    super.key,
  });

  final bool chipVisible;
  final VoidCallback? onChipTouch;
  final String path;
  final double initialPosition;
  final bool invert;
  final PdfPagesController controller;
  final void Function(double position, double progress) onProgress;
  final void Function(String reason) onFailed;

  @override
  State<PdfPagesView> createState() => _PdfPagesViewState();
}

class _PdfPagesViewState extends State<PdfPagesView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const double _gap = 6;
  static const double _maxScale = 6;
  static const double _doubleTapScale = 2.5;

  final TransformationController _tc = TransformationController();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  )..addListener(_tick);

  _PdfSession? _session;
  PdfLayerLoader? _loader;
  _Layout? _layout;
  Size _viewport = Size.zero;
  double _pixelRatio = 1;
  Matrix4Tween? _tween;
  Offset _tapAt = Offset.zero;
  Timer? _settleTimer;
  Timer? _saveTimer;
  int _first = 0;
  int _last = -1;
  bool _placed = false;
  double _position = 0;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _position = widget.initialPosition;
    widget.controller._jump = _jump;
    _tc.addListener(_onTransform);
    unawaited(_open());
  }

  Future<void> _open() async {
    final info = await DocumentService.pdfOpen(widget.path);
    if (!mounted) {
      if (info.error.isEmpty) unawaited(DocumentService.pdfClose(info.id));
      return;
    }
    if (info.error.isNotEmpty || info.pages.isEmpty) {
      widget.onFailed(info.error.isEmpty ? 'no pages' : info.error);
      return;
    }
    final session = _PdfSession(info);
    setState(() => _session = session);
    widget.controller._set(
      math.min(_position.floor(), info.pages.length - 1),
      info.pages.length,
    );
    final loader = PdfLayerLoader(
      widget.path,
      math.min(_position.floor(), info.pages.length - 1),
      session.addLayer,
    );
    _loader = loader;
    unawaited(loader.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _flush();
    }
  }

  @override
  void didUpdateWidget(PdfPagesView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller._jump = null;
      widget.controller._jump = _jump;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flush();
    _settleTimer?.cancel();
    _saveTimer?.cancel();
    _anim.dispose();
    _tc.removeListener(_onTransform);
    _tc.dispose();
    _loader?.close();
    _session?.close();
    widget.controller._jump = null;
    super.dispose();
  }

  void _flush() {
    if (_placed) widget.onProgress(_position, _progress);
  }

  double get _scale => _tc.value.getMaxScaleOnAxis();

  double get _top => -_tc.value.storage[13] / _scale;

  void _place(double position) {
    final layout = _layout;
    final session = _session;
    if (layout == null || session == null) return;
    final count = layout.tops.length;
    final page = math.min(count - 1, math.max(0, position.floor()));
    final fraction = math.min(1.0, math.max(0.0, position - page));
    var y = layout.tops[page] + fraction * (layout.heights[page] + layout.gap);
    y = math.min(y, math.max(0.0, layout.total - _viewport.height));
    y = math.max(0.0, y);
    _anim.stop();
    final matrix = Matrix4.identity()..setTranslationRaw(0, -y, 0);
    _placed = true;
    _tc.value = matrix;
    _onTransform();
  }

  void _jump(int page) => _place(page.toDouble());

  void _onTransform() {
    final layout = _layout;
    final session = _session;
    if (layout == null || session == null || !_placed) return;
    final top = math.max(0.0, _top);
    final bottom = top + _viewport.height / _scale;
    final first = layout.pageAt(top);
    final last = layout.pageAt(bottom);
    final center = layout.pageAt((top + bottom) / 2);
    final page = layout.pageAt(top);
    final fraction = math.min(
      1.0,
      math.max(
        0.0,
        (top - layout.tops[page]) / (layout.heights[page] + layout.gap),
      ),
    );
    _position = page + fraction;
    final count = layout.tops.length;
    _progress = ((top + _viewport.height / _scale) >= layout.total - 2)
        ? 1.0
        : math.min(1.0, math.max(0.0, _position / count));
    widget.controller._set(center, count);
    session.setRange(first, last, center);
    if (first != _first || last != _last) {
      _first = first;
      _last = last;
      setState(() {});
      _wantRange(1);
    }
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 160), _settle);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), _flush);
  }

  int get _baseWidth => math.max(300, (_viewport.width * _pixelRatio).round());

  void _wantRange(int bucket) {
    final session = _session;
    if (session == null) return;
    final count = session.slots.length;
    for (var page = _first; page <= _last; page++) {
      session.want(page, _baseWidth * bucket);
    }
    session.want(_last + 1, _baseWidth);
    session.want(_first - 1, _baseWidth);
    if (_last + 2 < count) session.want(_last + 2, _baseWidth);
  }

  void _settle() {
    if (!mounted) return;
    final bucket = math.min(4, math.max(1, (_scale - 0.05).ceil()));
    _wantRange(bucket);
  }

  void _tick() {
    final tween = _tween;
    if (tween == null) return;
    _tc.value = tween.transform(Curves.easeOutCubic.transform(_anim.value));
  }

  void _onDoubleTap() {
    final layout = _layout;
    if (layout == null) return;
    final current = _tc.value;
    final scale = _scale;
    final target = scale > 1.05 ? 1.0 : _doubleTapScale;
    final contentX = (_tapAt.dx - current.storage[12]) / scale;
    final contentY = (_tapAt.dy - current.storage[13]) / scale;
    var tx = _tapAt.dx - contentX * target;
    var ty = _tapAt.dy - contentY * target;
    final minX = -(layout.width * target - _viewport.width);
    final minY = -(layout.total * target - _viewport.height);
    tx = math.min(0.0, math.max(math.min(0.0, minX), tx));
    ty = math.min(0.0, math.max(math.min(0.0, minY), ty));
    final end = Matrix4(
      target,
      0,
      0,
      0,
      0,
      target,
      0,
      0,
      0,
      0,
      1,
      0,
      tx,
      ty,
      0,
      1,
    );
    _tween = Matrix4Tween(begin: current, end: end);
    unawaited(_anim.forward(from: 0));
  }

  Future<void> _askPage() async {
    final count = widget.controller.count;
    if (count <= 0) return;
    final field = TextEditingController();
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          controller: field,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(helperText: '1 – $count'.tr),
          onSubmitted: (value) =>
              Navigator.of(dialogContext).pop(_parseNumber(value)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_parseNumber(field.text)),
            child: const Text('Go'),
          ),
        ],
      ),
    );
    field.dispose();
    if (result != null && result >= 1 && result <= count) _jump(result - 1);
  }

  static int? _parseNumber(String text) {
    final buffer = StringBuffer();
    for (final unit in text.codeUnits) {
      if (unit >= 0x6F0 && unit <= 0x6F9) {
        buffer.writeCharCode(unit - 0x6F0 + 0x30);
      } else if (unit >= 0x660 && unit <= 0x669) {
        buffer.writeCharCode(unit - 0x660 + 0x30);
      } else {
        buffer.writeCharCode(unit);
      }
    }
    return int.tryParse(buffer.toString().trim());
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final scheme = Theme.of(context).colorScheme;
    _pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        var layout = _layout;
        if (layout == null || layout.width != size.width) {
          final keep = _placed ? _position : widget.initialPosition;
          layout = _layout = _Layout(size.width, session.info.pages, _gap);
          _viewport = size;
          _position = keep;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _viewport = size;
            _place(keep);
            setState(() {});
          });
        }
        _viewport = size;
        if (!_placed) {
          return ColoredBox(color: scheme.surfaceContainerHighest);
        }
        final tiles = <Widget>[];
        if (_last >= _first) {
          for (
            var i = math.max(0, _first - 1);
            i <= math.min(layout.tops.length - 1, _last + 1);
            i++
          ) {
            tiles.add(
              Positioned(
                key: ValueKey<int>(i),
                left: 0,
                top: layout.tops[i],
                width: layout.width,
                height: layout.heights[i],
                child: _PageTile(
                  session: session,
                  page: i,
                  invert: widget.invert,
                ),
              ),
            );
          }
        }
        final viewer = GestureDetector(
          onDoubleTapDown: (details) => _tapAt = details.localPosition,
          onDoubleTap: _onDoubleTap,
          child: InteractiveViewer(
            transformationController: _tc,
            constrained: false,
            minScale: 1,
            maxScale: _maxScale,
            boundaryMargin: EdgeInsets.zero,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: layout.width,
              height: layout.total,
              child: Stack(children: tiles),
            ),
          ),
        );
        return ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Stack(
            children: [
              Positioned.fill(child: SelectionArea(child: viewer)),
              PositionedDirectional(
                bottom: AppSpacing.md,
                end: AppSpacing.md,
                child: AnimatedOpacity(
                  opacity: widget.chipVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: IgnorePointer(
                    ignoring: !widget.chipVisible,
                    child: Listener(
                      onPointerDown: (_) => widget.onChipTouch?.call(),
                      child: _PageChip(
                        controller: widget.controller,
                        onTap: () => unawaited(_askPage()),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PageChip extends StatelessWidget {
  const _PageChip({required this.controller, required this.onTap});

  final PdfPagesController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.count <= 0) return const SizedBox.shrink();
        return Material(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Text(
                '${controller.page + 1} / ${controller.count}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PageTile extends StatelessWidget {
  const _PageTile({
    required this.session,
    required this.page,
    required this.invert,
  });

  final _PdfSession session;
  final int page;
  final bool invert;

  @override
  Widget build(BuildContext context) {
    final slot = session.slots[page];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        Widget paper = ListenableBuilder(
          listenable: slot,
          builder: (context, _) {
            final image = slot.image;
            return ColoredBox(
              color: Colors.white,
              child: image == null
                  ? Center(
                      child: slot.failed
                          ? const Text(
                              'This page could not be displayed.',
                              style: TextStyle(color: Colors.black54),
                            )
                          : const SizedBox.shrink(),
                    )
                  : RawImage(
                      image: image,
                      width: width,
                      height: height,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.medium,
                    ),
            );
          },
        );
        if (invert) {
          paper = ColorFiltered(
            colorFilter: const ColorFilter.matrix(_invertMatrix),
            child: paper,
          );
        }
        return Stack(
          children: [
            Positioned.fill(child: paper),
            Positioned.fill(
              child: ValueListenableBuilder<int>(
                valueListenable: session.layerTick,
                builder: (context, _, __) {
                  final lines = session.layers[page];
                  if (lines == null || lines.isEmpty)
                    return const SizedBox.shrink();
                  return _TextLayer(lines: lines, width: width, height: height);
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TextLayer extends StatelessWidget {
  const _TextLayer({
    required this.lines,
    required this.width,
    required this.height,
  });

  final List<PdfTextLine> lines;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        for (final line in lines)
          Positioned(
            left: line.left * width,
            top: line.top * height,
            width: math.max(2.0, line.width * width),
            height: math.max(2.0, line.height * height),
            child: Directionality(
              textDirection: line.rtl ? TextDirection.rtl : TextDirection.ltr,
              child: FittedBox(
                fit: BoxFit.fill,
                child: w.Text(
                  line.text,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: math.max(4.0, line.height * height / 1.05),
                    height: 1,
                    color: Colors.transparent,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
