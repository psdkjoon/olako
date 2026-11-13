import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

enum MarkKind { rect, oval, line, arrow }

Offset _mapPoint(Offset p, Rect from, Rect to) {
  final sx = from.width.abs() < 0.001 ? 1.0 : to.width / from.width;
  final sy = from.height.abs() < 0.001 ? 1.0 : to.height / from.height;
  return Offset(
    to.left + (p.dx - from.left) * sx,
    to.top + (p.dy - from.top) * sy,
  );
}

double _segmentDistance(Offset p, Offset a, Offset b) {
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared < 0.0001) return (p - a).distance;
  final t = (((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / lengthSquared).clamp(
    0.0,
    1.0,
  );
  final nearest = Offset(a.dx + dx * t, a.dy + dy * t);
  return (p - nearest).distance;
}

abstract class Annotation {
  Annotation({this.tag = ''});

  String tag;

  Annotation clone();

  Rect get bounds;

  void shift(Offset delta);

  void resize(Rect from, Rect to);

  bool hit(Offset point, double slop);

  Map<String, Object?> toJob();
}

class InkOverlay extends Annotation {
  InkOverlay({
    required this.points,
    required this.color,
    required this.width,
    this.opacity = 1,
    this.highlight = false,
    super.tag,
  });

  List<Offset> points;
  int color;
  double width;
  double opacity;
  bool highlight;

  @override
  InkOverlay clone() {
    return InkOverlay(
      points: List<Offset>.of(points),
      color: color,
      width: width,
      opacity: opacity,
      highlight: highlight,
      tag: tag,
    );
  }

  @override
  Rect get bounds {
    var rect = Rect.fromPoints(points.first, points.first);
    for (final p in points) {
      rect = rect.expandToInclude(Rect.fromPoints(p, p));
    }
    return rect.inflate(width / 2);
  }

  @override
  void shift(Offset delta) {
    points = <Offset>[for (final p in points) p + delta];
  }

  @override
  void resize(Rect from, Rect to) {
    points = <Offset>[for (final p in points) _mapPoint(p, from, to)];
  }

  @override
  bool hit(Offset point, double slop) {
    final reach = width / 2 + slop;
    if (points.length == 1) return (points.first - point).distance <= reach;
    for (var i = 0; i + 1 < points.length; i++) {
      if (_segmentDistance(point, points[i], points[i + 1]) <= reach)
        return true;
    }
    return false;
  }

  @override
  Map<String, Object?> toJob() {
    return <String, Object?>{
      't': 'ink',
      'pts': <double>[
        for (final p in points) ...<double>[p.dx, p.dy],
      ],
      'c': color,
      'sw': width,
      'a': opacity,
      if (highlight) 'm': 'mul',
    };
  }
}

class MarkOverlay extends Annotation {
  MarkOverlay({
    required this.kind,
    required this.a,
    required this.b,
    required this.stroke,
    this.fill,
    this.width = 2,
    this.opacity = 1,
    super.tag,
  });

  MarkKind kind;
  Offset a;
  Offset b;
  int stroke;
  int? fill;
  double width;
  double opacity;

  bool get linear => kind == MarkKind.line || kind == MarkKind.arrow;

  @override
  MarkOverlay clone() {
    return MarkOverlay(
      kind: kind,
      a: a,
      b: b,
      stroke: stroke,
      fill: fill,
      width: width,
      opacity: opacity,
      tag: tag,
    );
  }

  @override
  Rect get bounds => Rect.fromPoints(
    a,
    b,
  ).inflate(width / 2 + (kind == MarkKind.arrow ? 6 : 0));

  @override
  void shift(Offset delta) {
    a += delta;
    b += delta;
  }

  @override
  void resize(Rect from, Rect to) {
    a = _mapPoint(a, from, to);
    b = _mapPoint(b, from, to);
  }

  @override
  bool hit(Offset point, double slop) {
    final reach = width / 2 + slop;
    if (linear) return _segmentDistance(point, a, b) <= reach;
    final rect = Rect.fromPoints(a, b);
    if (kind == MarkKind.rect) {
      if (fill != null) return rect.inflate(reach).contains(point);
      if (!rect.inflate(reach).contains(point)) return false;
      return !rect.deflate(reach).contains(point);
    }
    final rx = math.max(rect.width / 2, 0.5);
    final ry = math.max(rect.height / 2, 0.5);
    final dx = (point.dx - rect.center.dx) / rx;
    final dy = (point.dy - rect.center.dy) / ry;
    final d = math.sqrt(dx * dx + dy * dy);
    if (fill != null) return d <= 1 + reach / math.min(rx, ry);
    return (d - 1).abs() * math.min(rx, ry) <= reach;
  }

  @override
  Map<String, Object?> toJob() {
    final rect = Rect.fromPoints(a, b);
    final map = <String, Object?>{'c': stroke, 'sw': width, 'a': opacity};
    if (fill != null) map['f'] = fill;
    switch (kind) {
      case MarkKind.rect:
      case MarkKind.oval:
        map['t'] = kind == MarkKind.rect ? 'rect' : 'oval';
        map['x'] = rect.left;
        map['y'] = rect.top;
        map['w'] = rect.width;
        map['h'] = rect.height;
      case MarkKind.line:
      case MarkKind.arrow:
        map['t'] = kind == MarkKind.line ? 'line' : 'arrow';
        map['x1'] = a.dx;
        map['y1'] = a.dy;
        map['x2'] = b.dx;
        map['y2'] = b.dy;
    }
    return map;
  }
}

class PictureOverlay extends Annotation {
  PictureOverlay({
    required this.rect,
    this.bytes,
    this.path = '',
    this.rotation = 0,
    this.opacity = 1,
    super.tag,
  });

  Uint8List? bytes;
  String path;
  Rect rect;
  double rotation;
  double opacity;

  Object get source => bytes ?? path;

  @override
  PictureOverlay clone() {
    return PictureOverlay(
      rect: rect,
      bytes: bytes,
      path: path,
      rotation: rotation,
      opacity: opacity,
      tag: tag,
    );
  }

  @override
  Rect get bounds => rect;

  @override
  void shift(Offset delta) {
    rect = rect.shift(delta);
  }

  @override
  void resize(Rect from, Rect to) {
    final topLeft = _mapPoint(rect.topLeft, from, to);
    final bottomRight = _mapPoint(rect.bottomRight, from, to);
    rect = Rect.fromPoints(topLeft, bottomRight);
  }

  @override
  bool hit(Offset point, double slop) {
    final local = unrotate(point);
    return rect.inflate(slop).contains(local);
  }

  Offset unrotate(Offset point) {
    if (rotation == 0) return point;
    final c = rect.center;
    final cos = math.cos(-rotation);
    final sin = math.sin(-rotation);
    final dx = point.dx - c.dx;
    final dy = point.dy - c.dy;
    return Offset(c.dx + dx * cos - dy * sin, c.dy + dx * sin + dy * cos);
  }

  Offset rotate(Offset point) {
    if (rotation == 0) return point;
    final c = rect.center;
    final cos = math.cos(rotation);
    final sin = math.sin(rotation);
    final dx = point.dx - c.dx;
    final dy = point.dy - c.dy;
    return Offset(c.dx + dx * cos - dy * sin, c.dy + dx * sin + dy * cos);
  }

  void dragCorner(Offset pointer, double minSide) {
    final c = rect.center;
    final cos = math.cos(rotation);
    final sin = math.sin(rotation);
    final half = Offset(-rect.width / 2, -rect.height / 2);
    final anchor = Offset(
      c.dx + half.dx * cos - half.dy * sin,
      c.dy + half.dx * sin + half.dy * cos,
    );
    final d = pointer - anchor;
    final lx = d.dx * cos + d.dy * sin;
    final ly = -d.dx * sin + d.dy * cos;
    final ratio = rect.height <= 0 ? 1.0 : rect.width / rect.height;
    var w = math.max(lx, ly * ratio);
    if (w < minSide) w = minSide;
    final h = w / ratio;
    final center = Offset(
      anchor.dx + (w / 2) * cos - (h / 2) * sin,
      anchor.dy + (w / 2) * sin + (h / 2) * cos,
    );
    rect = Rect.fromCenter(center: center, width: w, height: h);
  }

  @override
  Map<String, Object?> toJob() {
    final data = bytes;
    return <String, Object?>{
      't': 'img',
      if (data != null) 'bytes': data else 'path': path,
      'x': rect.left,
      'y': rect.top,
      'w': rect.width,
      'h': rect.height,
      'rot': rotation,
      'a': opacity,
    };
  }
}

class PdfSource {
  PdfSource({required this.path, required this.name, required this.sizes});

  final String path;
  final String name;
  final List<Size> sizes;
  int handle = 0;
}

class PageItem {
  const PageItem({
    required this.id,
    required this.source,
    required this.index,
    required this.size,
    this.turns = 0,
    this.overlays = const <Annotation>[],
    this.crop = const <double>[0, 0, 0, 0],
  });

  final String id;
  final int source;
  final int index;
  final Size size;
  final int turns;
  final List<Annotation> overlays;
  final List<double> crop;

  bool get blank => source < 0;

  bool get cropped => crop.any((v) => v > 0.5);

  Rect get visible => Rect.fromLTRB(
    crop[0],
    crop[1],
    size.width - crop[2],
    size.height - crop[3],
  );

  Size get shown {
    final v = visible;
    return turns.isOdd ? Size(v.height, v.width) : v.size;
  }

  PageItem copyWith({
    String? id,
    int? turns,
    List<Annotation>? overlays,
    List<double>? crop,
  }) {
    return PageItem(
      id: id ?? this.id,
      source: source,
      index: index,
      size: size,
      turns: turns ?? this.turns,
      overlays: overlays ?? this.overlays,
      crop: crop ?? this.crop,
    );
  }

  Map<String, Object?> toJob() {
    final map = <String, Object?>{
      's': source,
      'p': index,
      'r': (turns % 4) * 90,
    };
    if (blank) {
      map['w'] = size.width;
      map['h'] = size.height;
    }
    if (cropped) map['crop'] = crop;
    if (overlays.isNotEmpty) {
      map['ov'] = <Map<String, Object?>>[for (final o in overlays) o.toJob()];
    }
    return map;
  }
}

Map<String, Object?> buildJob({
  required String name,
  required List<PageItem> pages,
  required List<PdfSource> sources,
  String title = '',
  String author = '',
}) {
  return <String, Object?>{
    'name': name,
    'title': title,
    'author': author,
    'sources': <String>[for (final s in sources) s.path],
    'pages': <Map<String, Object?>>[for (final p in pages) p.toJob()],
  };
}

List<Annotation> cloneAll(List<Annotation> overlays) {
  return <Annotation>[for (final o in overlays) o.clone()];
}
