import 'dart:math' as math;
import 'dart:typed_data';

import 'package:olako/reader/doc_model.dart';
import 'package:olako/reader/ooxml_util.dart';
import 'package:olako/reader/xml_lite.dart';
import 'package:olako/reader/zip_archive.dart';

SlideDeck readPptx(ZipArchive zip) {
  final mainPath = findMainPart(zip) ?? 'ppt/presentation.xml';
  final root = readXmlPart(zip, mainPath);
  if (root == null) {
    throw const DocumentFormatException('The presentation has no content.');
  }
  final deck = _Deck(zip, _ListStyle.parse(root.child('defaultTextStyle')));
  final rels = deck.rels(mainPath);

  final size = root.child('sldSz');
  final cx = double.tryParse(size?.attr('cx') ?? '') ?? 9144000;
  final cy = double.tryParse(size?.attr('cy') ?? '') ?? 5143500;

  final slides = <SlideData>[];
  final list = root.child('sldIdLst');
  if (list != null) {
    for (final id in list.childrenNamed('sldId')) {
      final relId = id.prefixedAttr('id');
      final rel = relId == null ? null : rels[relId];
      if (rel == null || rel.external) continue;
      final path = resolvePartPath(mainPath, rel.target);
      try {
        final slide = _SlideReader(deck, path).read();
        if (slide != null) slides.add(slide);
      } on DocumentFormatException {
        rethrow;
      } on Object {
        slides.add(
          const SlideData(
            shapes: <SlideShape>[],
            background: 0xFFFFFFFF,
            outline: <DocBlock>[],
            notes: '',
            title: '',
          ),
        );
      }
    }
  }
  if (slides.isEmpty) {
    throw const DocumentFormatException('The presentation has no slides.');
  }
  return SlideDeck(
    slides: slides,
    widthPt: cx / emuPerPoint,
    heightPt: cy / emuPerPoint,
  );
}

class _Deck {
  _Deck(this.zip, this.defaultStyle);

  final ZipArchive zip;
  final _ListStyle defaultStyle;
  final Map<String, XmlElement?> _xml = <String, XmlElement?>{};
  final Map<String, Map<String, Relationship>> _rels =
      <String, Map<String, Relationship>>{};
  final Map<String, _Theme> _themes = <String, _Theme>{};

  XmlElement? xml(String? path) {
    if (path == null) return null;
    return _xml.putIfAbsent(path, () => readXmlPart(zip, path));
  }

  Map<String, Relationship> rels(String path) =>
      _rels.putIfAbsent(path, () => readRelationships(zip, path));

  String? related(String part, String suffix) {
    for (final r in rels(part).values) {
      if (r.type.endsWith(suffix) && !r.external) {
        return resolvePartPath(part, r.target);
      }
    }
    return null;
  }

  Uint8List? bytes(String part, String? relId) {
    if (relId == null) return null;
    final rel = rels(part)[relId];
    if (rel == null || rel.external) return null;
    try {
      return zip.read(resolvePartPath(part, rel.target));
    } on DocumentFormatException {
      return null;
    }
  }

  _Theme theme(String? path) {
    if (path == null) return _Theme(const <String, int>{});
    return _themes.putIfAbsent(path, () => _Theme.parse(xml(path)));
  }
}

class _Theme {
  _Theme(this.colors);

  factory _Theme.parse(XmlElement? root) {
    final colors = <String, int>{};
    final scheme = root?.path(['themeElements', 'clrScheme']);
    if (scheme != null) {
      for (final c in scheme.children) {
        final value =
            parseHexColor(c.child('srgbClr')?.attr('val')) ??
            parseHexColor(c.child('sysClr')?.attr('lastClr'));
        if (value != null) colors[c.local] = value;
      }
    }
    return _Theme(colors);
  }

  final Map<String, int> colors;
}

class _Colors {
  _Colors(this.theme, this.clrMap);

  final _Theme theme;
  final Map<String, String> clrMap;

  static const Set<String> _kinds = <String>{
    'srgbClr',
    'schemeClr',
    'sysClr',
    'prstClr',
  };

  int? scheme(String? name) {
    if (name == null) return null;
    final mapped = clrMap[name] ?? name;
    return theme.colors[mapped];
  }

  int? resolve(XmlElement? holder) {
    if (holder == null) return null;
    XmlElement? c;
    for (final child in holder.children) {
      if (_kinds.contains(child.local)) {
        c = child;
        break;
      }
    }
    if (c == null) return null;
    int? base;
    switch (c.local) {
      case 'srgbClr':
        base = parseHexColor(c.attr('val'));
      case 'schemeClr':
        base = scheme(c.attr('val'));
      case 'sysClr':
        base =
            parseHexColor(c.attr('lastClr')) ??
            (c.attr('val') == 'window' ? 0xFFFFFFFF : 0xFF000000);
      case 'prstClr':
        base = _preset(c.attr('val'));
    }
    if (base == null) return null;
    return _modify(base, c);
  }

  static int? _preset(String? name) {
    switch (name) {
      case 'black':
        return 0xFF000000;
      case 'white':
        return 0xFFFFFFFF;
      case 'red':
        return 0xFFFF0000;
      case 'green':
        return 0xFF008000;
      case 'blue':
        return 0xFF0000FF;
      case 'yellow':
        return 0xFFFFFF00;
      case 'gray':
        return 0xFF808080;
    }
    return null;
  }

  static int _modify(int argb, XmlElement color) {
    var r = (argb >> 16) & 0xFF;
    var g = (argb >> 8) & 0xFF;
    var b = argb & 0xFF;
    var alpha = 255;
    for (final m in color.children) {
      final raw = double.tryParse(m.attr('val') ?? '');
      if (raw == null) continue;
      final v = raw / 100000;
      switch (m.local) {
        case 'lumMod':
        case 'lumOff':
        case 'satMod':
        case 'satOff':
          final hsl = _toHsl(r, g, b);
          var h = hsl[0];
          var s = hsl[1];
          var l = hsl[2];
          if (m.local == 'lumMod') l *= v;
          if (m.local == 'lumOff') l += v;
          if (m.local == 'satMod') s *= v;
          if (m.local == 'satOff') s += v;
          l = clampDouble(l, 0, 1);
          s = clampDouble(s, 0, 1);
          h = clampDouble(h, 0, 360);
          final rgb = _fromHsl(h, s, l);
          r = rgb[0];
          g = rgb[1];
          b = rgb[2];
        case 'tint':
          r = clampInt((r * v + 255 * (1 - v)).round(), 0, 255);
          g = clampInt((g * v + 255 * (1 - v)).round(), 0, 255);
          b = clampInt((b * v + 255 * (1 - v)).round(), 0, 255);
        case 'shade':
          r = clampInt((r * v).round(), 0, 255);
          g = clampInt((g * v).round(), 0, 255);
          b = clampInt((b * v).round(), 0, 255);
        case 'alpha':
          alpha = clampInt((255 * v).round(), 0, 255);
      }
    }
    return (alpha << 24) | (r << 16) | (g << 8) | b;
  }

  static List<double> _toHsl(int r, int g, int b) {
    final rf = r / 255;
    final gf = g / 255;
    final bf = b / 255;
    final maxV = math.max(rf, math.max(gf, bf));
    final minV = math.min(rf, math.min(gf, bf));
    final l = (maxV + minV) / 2;
    var h = 0.0;
    var s = 0.0;
    final d = maxV - minV;
    if (d != 0) {
      s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV);
      if (maxV == rf) {
        h = (gf - bf) / d + (gf < bf ? 6 : 0);
      } else if (maxV == gf) {
        h = (bf - rf) / d + 2;
      } else {
        h = (rf - gf) / d + 4;
      }
      h *= 60;
    }
    return <double>[h, s, l];
  }

  static List<int> _fromHsl(double h, double s, double l) {
    if (s == 0) {
      final v = (l * 255).round();
      return <int>[v, v, v];
    }
    final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final p = 2 * l - q;
    double channel(double t) {
      var x = t;
      if (x < 0) x += 1;
      if (x > 1) x -= 1;
      if (x < 1 / 6) return p + (q - p) * 6 * x;
      if (x < 1 / 2) return q;
      if (x < 2 / 3) return p + (q - p) * (2 / 3 - x) * 6;
      return p;
    }

    final hk = h / 360;
    return <int>[
      (channel(hk + 1 / 3) * 255).round(),
      (channel(hk) * 255).round(),
      (channel(hk - 1 / 3) * 255).round(),
    ];
  }
}

class _RunInfo {
  double? size;
  bool? bold;
  bool? italic;
  bool? underline;
  bool? strike;
  bool? mono;
  int? baseline;
  XmlElement? fill;

  void merge(_RunInfo o) {
    size = o.size ?? size;
    bold = o.bold ?? bold;
    italic = o.italic ?? italic;
    underline = o.underline ?? underline;
    strike = o.strike ?? strike;
    mono = o.mono ?? mono;
    baseline = o.baseline ?? baseline;
    fill = o.fill ?? fill;
  }

  static bool? _flag(String? v) {
    if (v == null) return null;
    return v == '1' || v == 'true';
  }

  static _RunInfo read(XmlElement? e) {
    final info = _RunInfo();
    if (e == null) return info;
    final sz = double.tryParse(e.attr('sz') ?? '');
    if (sz != null) info.size = sz / 100;
    info.bold = _flag(e.attr('b'));
    info.italic = _flag(e.attr('i'));
    final u = e.attr('u');
    if (u != null) info.underline = u != 'none';
    final strike = e.attr('strike');
    if (strike != null) info.strike = strike != 'noStrike';
    info.baseline = int.tryParse(e.attr('baseline') ?? '');
    info.fill = e.child('solidFill');
    final face = e.child('latin')?.attr('typeface')?.toLowerCase();
    if (face != null) {
      info.mono =
          face.contains('courier') ||
          face.contains('consolas') ||
          face.contains('mono');
    }
    return info;
  }
}

class _ParaInfo {
  String? algn;
  double? marL;
  double? indent;
  bool? rtl;
  bool? bulletNone;
  String? bulletChar;
  String? bulletFont;
  String? autoNum;
  int? autoStart;
  double? spaceBefore;
  int? lvl;

  void merge(_ParaInfo o) {
    algn = o.algn ?? algn;
    marL = o.marL ?? marL;
    indent = o.indent ?? indent;
    rtl = o.rtl ?? rtl;
    spaceBefore = o.spaceBefore ?? spaceBefore;
    lvl = o.lvl ?? lvl;
    if (o.bulletNone == true) {
      bulletNone = true;
      bulletChar = null;
      autoNum = null;
    } else if (o.bulletChar != null) {
      bulletNone = false;
      bulletChar = o.bulletChar;
      bulletFont = o.bulletFont ?? bulletFont;
      autoNum = null;
    } else if (o.autoNum != null) {
      bulletNone = false;
      autoNum = o.autoNum;
      autoStart = o.autoStart;
      bulletChar = null;
    }
  }

  static _ParaInfo read(XmlElement? e) {
    final info = _ParaInfo();
    if (e == null) return info;
    info.algn = e.attr('algn');
    final marL = double.tryParse(e.attr('marL') ?? '');
    if (marL != null) info.marL = marL / emuPerPoint;
    final indent = double.tryParse(e.attr('indent') ?? '');
    if (indent != null) info.indent = indent / emuPerPoint;
    final rtl = e.attr('rtl');
    if (rtl != null) info.rtl = rtl == '1' || rtl == 'true';
    info.lvl = int.tryParse(e.attr('lvl') ?? '');
    if (e.child('buNone') != null) info.bulletNone = true;
    final char = e.child('buChar')?.attr('char');
    if (char != null) {
      info.bulletChar = char;
      info.bulletFont = e.child('buFont')?.attr('typeface');
    }
    final auto = e.child('buAutoNum');
    if (auto != null) {
      info.autoNum = auto.attr('type') ?? 'arabicPeriod';
      info.autoStart = int.tryParse(auto.attr('startAt') ?? '');
    }
    final before = e.path(['spcBef', 'spcPts'])?.attr('val');
    final points = double.tryParse(before ?? '');
    if (points != null) info.spaceBefore = points / 100;
    return info;
  }
}

class _Level {
  final _ParaInfo para = _ParaInfo();
  final _RunInfo run = _RunInfo();

  void merge(_Level o) {
    para.merge(o.para);
    run.merge(o.run);
  }
}

class _ListStyle {
  _ListStyle();

  factory _ListStyle.withFill(XmlElement holder) {
    final style = _ListStyle();
    for (var n = 0; n < 9; n++) {
      style.levels[n] = _Level()..run.fill = holder;
    }
    return style;
  }

  factory _ListStyle.parse(XmlElement? e) {
    final style = _ListStyle();
    if (e == null) return style;
    for (var n = 1; n <= 9; n++) {
      final lvl = e.child('lvl${n}pPr');
      if (lvl == null) continue;
      final level = _Level();
      level.para.merge(_ParaInfo.read(lvl));
      level.run.merge(_RunInfo.read(lvl.child('defRPr')));
      style.levels[n - 1] = level;
    }
    return style;
  }

  final Map<int, _Level> levels = <int, _Level>{};
}

class _Xform {
  const _Xform(this.sx, this.tx, this.sy, this.ty);

  static const _Xform identity = _Xform(1, 0, 1, 0);

  final double sx;
  final double tx;
  final double sy;
  final double ty;

  _Xform group(XmlElement xfrm) {
    final off = xfrm.child('off');
    final ext = xfrm.child('ext');
    final chOff = xfrm.child('chOff');
    final chExt = xfrm.child('chExt');
    double v(XmlElement? e, String a) => double.tryParse(e?.attr(a) ?? '') ?? 0;
    final extX = v(ext, 'cx');
    final extY = v(ext, 'cy');
    final chExtX = v(chExt, 'cx');
    final chExtY = v(chExt, 'cy');
    final kx = chExtX == 0 ? 1.0 : extX / chExtX;
    final ky = chExtY == 0 ? 1.0 : extY / chExtY;
    final mx = v(off, 'x') - v(chOff, 'x') * kx;
    final my = v(off, 'y') - v(chOff, 'y') * ky;
    return _Xform(sx * kx, sx * mx + tx, sy * ky, sy * my + ty);
  }
}

class _Part {
  const _Part(this.path);

  final String path;
}

class _Placeholders {
  _Placeholders(XmlElement? tree) {
    if (tree == null) return;
    for (final sp in tree.childrenNamed('sp')) {
      final ph = sp.path(['nvSpPr', 'nvPr', 'ph']);
      if (ph == null) continue;
      final idx = ph.attr('idx');
      if (idx != null) byIdx.putIfAbsent(idx, () => sp);
      byType.putIfAbsent(_kind(ph.attr('type')), () => sp);
    }
  }

  final Map<String, XmlElement> byIdx = <String, XmlElement>{};
  final Map<String, XmlElement> byType = <String, XmlElement>{};

  static String _kind(String? type) {
    switch (type) {
      case null:
      case 'obj':
      case 'body':
      case 'subTitle':
      case 'tbl':
      case 'chart':
      case 'pic':
      case 'media':
      case 'clipArt':
      case 'dgm':
        return 'body';
      case 'ctrTitle':
      case 'title':
        return 'title';
    }
    return type;
  }

  static String kindOf(XmlElement ph) => _kind(ph.attr('type'));

  XmlElement? find(XmlElement ph, {bool useIndex = true}) {
    final idx = ph.attr('idx');
    if (useIndex && idx != null) {
      final hit = byIdx[idx];
      if (hit != null) return hit;
    }
    return byType[_kind(ph.attr('type'))];
  }
}

class _OutlineItem {
  _OutlineItem(this.y, this.x, this.blocks);

  final double y;
  final double x;
  final List<DocBlock> blocks;
}

class _SlideReader {
  _SlideReader(this.deck, this.path);

  final _Deck deck;
  final String path;

  late final _Colors _colors;
  late final _Placeholders _layoutPh;
  late final _Placeholders _masterPh;
  XmlElement? _masterStyles;

  final List<SlideShape> _shapes = <SlideShape>[];
  final List<_OutlineItem> _outline = <_OutlineItem>[];
  String _title = '';

  SlideData? read() {
    final slide = deck.xml(path);
    if (slide == null) return null;
    final layoutPath = deck.related(path, '/slideLayout');
    final layout = deck.xml(layoutPath);
    final masterPath = layoutPath == null
        ? null
        : deck.related(layoutPath, '/slideMaster');
    final master = deck.xml(masterPath);
    final themePath = masterPath == null
        ? null
        : deck.related(masterPath, '/theme');

    final clrMap = <String, String>{};
    final mapElement = master?.child('clrMap');
    if (mapElement != null) clrMap.addAll(mapElement.attributes);
    _colors = _Colors(deck.theme(themePath), clrMap);

    final layoutTree = layout?.path(['cSld', 'spTree']);
    final masterTree = master?.path(['cSld', 'spTree']);
    _layoutPh = _Placeholders(layoutTree);
    _masterPh = _Placeholders(masterTree);
    _masterStyles = master?.child('txStyles');

    final hideAll = slide.attr('showMasterSp') == '0';
    final hideMaster = hideAll || layout?.attr('showMasterSp') == '0';
    if (!hideMaster && masterTree != null && masterPath != null) {
      _readTree(
        masterTree,
        _Part(masterPath),
        _Xform.identity,
        decorative: true,
      );
    }
    if (!hideAll && layoutTree != null && layoutPath != null) {
      _readTree(
        layoutTree,
        _Part(layoutPath),
        _Xform.identity,
        decorative: true,
      );
    }
    final tree = slide.path(['cSld', 'spTree']);
    if (tree != null) {
      _readTree(tree, _Part(path), _Xform.identity, decorative: false);
    }

    final background =
        _background(slide) ??
        _background(layout) ??
        _background(master) ??
        _colors.scheme('bg1') ??
        0xFFFFFFFF;

    _outline.sort((a, b) {
      final dy = a.y.compareTo(b.y);
      return dy != 0 ? dy : a.x.compareTo(b.x);
    });
    final blocks = <DocBlock>[for (final item in _outline) ...item.blocks];

    return SlideData(
      shapes: _shapes,
      background: background,
      outline: blocks,
      notes: _notes(),
      title: _title,
    );
  }

  int? _background(XmlElement? part) {
    final bg = part?.path(['cSld', 'bg']);
    if (bg == null) return null;
    final props = bg.child('bgPr');
    if (props != null) {
      final solid = _colors.resolve(props.child('solidFill'));
      if (solid != null) return solid | 0xFF000000;
      final stop = props.path(['gradFill', 'gsLst'])?.child('gs');
      final gradient = _colors.resolve(stop);
      if (gradient != null) return gradient | 0xFF000000;
    }
    final ref = _colors.resolve(bg.child('bgRef'));
    return ref == null ? null : ref | 0xFF000000;
  }

  String _notes() {
    final notesPath = deck.related(path, '/notesSlide');
    final notes = deck.xml(notesPath);
    final tree = notes?.path(['cSld', 'spTree']);
    if (tree == null) return '';
    final lines = <String>[];
    for (final sp in tree.childrenNamed('sp')) {
      final ph = sp.path(['nvSpPr', 'nvPr', 'ph']);
      if (ph == null || ph.attr('type') != 'body') continue;
      final body = sp.child('txBody');
      if (body == null) continue;
      for (final p in body.childrenNamed('p')) {
        final text = StringBuffer();
        for (final r in p.children) {
          if (r.local == 'r' || r.local == 'fld')
            text.write(r.child('t')?.text ?? '');
          if (r.local == 'br') text.write('\n');
        }
        lines.add(text.toString());
      }
    }
    return lines.join('\n').trim();
  }

  void _readTree(
    XmlElement tree,
    _Part part,
    _Xform xf, {
    required bool decorative,
  }) {
    for (final child in tree.children) {
      try {
        switch (child.local) {
          case 'sp':
            _shape(child, part, xf, decorative);
          case 'cxnSp':
            _connector(child, xf, decorative);
          case 'pic':
            _picture(child, part, xf, decorative);
          case 'graphicFrame':
            _frame(child, part, xf, decorative);
          case 'grpSp':
            final xfrm = child.path(['grpSpPr', 'xfrm']);
            _readTree(
              child,
              part,
              xfrm == null ? xf : xf.group(xfrm),
              decorative: decorative,
            );
          case 'AlternateContent':
            final choice = child.child('Fallback') ?? child.child('Choice');
            if (choice != null)
              _readTree(choice, part, xf, decorative: decorative);
        }
      } on DocumentFormatException {
        rethrow;
      } on Object {
        continue;
      }
    }
  }

  ({double x, double y, double w, double h, double rot, bool flipH})? _geometry(
    XmlElement? xfrm,
    _Xform xf,
  ) {
    if (xfrm == null) return null;
    final off = xfrm.child('off');
    final ext = xfrm.child('ext');
    if (off == null || ext == null) return null;
    final x = double.tryParse(off.attr('x') ?? '');
    final y = double.tryParse(off.attr('y') ?? '');
    final cx = double.tryParse(ext.attr('cx') ?? '');
    final cy = double.tryParse(ext.attr('cy') ?? '');
    if (x == null || y == null || cx == null || cy == null) return null;
    final rot = double.tryParse(xfrm.attr('rot') ?? '') ?? 0;
    return (
      x: (xf.sx * x + xf.tx) / emuPerPoint,
      y: (xf.sy * y + xf.ty) / emuPerPoint,
      w: cx * xf.sx / emuPerPoint,
      h: cy * xf.sy / emuPerPoint,
      rot: rot / 60000,
      flipH: xfrm.attr('flipH') == '1',
    );
  }

  int? _solid(XmlElement? spPr, XmlElement? styleRef) {
    if (spPr != null) {
      if (spPr.child('noFill') != null) return null;
      final solid = spPr.child('solidFill');
      if (solid != null) return _colors.resolve(solid);
      final stop = spPr.path(['gradFill', 'gsLst'])?.child('gs');
      if (stop != null) return _colors.resolve(stop);
    }
    if (styleRef != null && styleRef.attr('idx') != '0') {
      return _colors.resolve(styleRef);
    }
    return null;
  }

  ({int? color, double width}) _outlineOf(XmlElement sp) {
    final ln = sp.child('spPr')?.child('ln');
    final style = sp.child('style')?.child('lnRef');
    var width = 1.0;
    final w = double.tryParse(ln?.attr('w') ?? '');
    if (w != null) width = w / emuPerPoint;
    if (ln != null) {
      if (ln.child('noFill') != null) return (color: null, width: width);
      final solid = ln.child('solidFill');
      if (solid != null) return (color: _colors.resolve(solid), width: width);
    }
    if (style != null && style.attr('idx') != '0') {
      return (color: _colors.resolve(style), width: width);
    }
    return (color: null, width: width);
  }

  ShapeKind _kind(XmlElement spPr) {
    switch (spPr.child('prstGeom')?.attr('prst')) {
      case 'roundRect':
      case 'round1Rect':
      case 'round2SameRect':
      case 'round2DiagRect':
      case 'snipRoundRect':
        return ShapeKind.roundRect;
      case 'ellipse':
      case 'flowChartConnector':
        return ShapeKind.ellipse;
      case 'line':
      case 'straightConnector1':
        return ShapeKind.line;
    }
    return ShapeKind.rect;
  }

  void _shape(XmlElement sp, _Part part, _Xform xf, bool decorative) {
    final ph = sp.path(['nvSpPr', 'nvPr', 'ph']);
    if (ph != null && decorative) return;
    final layoutSp = ph == null ? null : _layoutPh.find(ph);
    final masterSp = ph == null ? null : _masterPh.find(ph, useIndex: false);

    final spPr = sp.child('spPr');
    final geometry = _geometry(
      spPr?.child('xfrm') ??
          layoutSp?.path(['spPr', 'xfrm']) ??
          masterSp?.path(['spPr', 'xfrm']),
      xf,
    );
    if (geometry == null) return;

    final style = sp.child('style');
    final fill = _solid(spPr, style?.child('fillRef'));
    final outline = _outlineOf(sp);

    final txBody = sp.child('txBody');
    final bodyPr = txBody?.child('bodyPr');
    final layoutBody = layoutSp?.path(['txBody', 'bodyPr']);
    final masterBody = masterSp?.path(['txBody', 'bodyPr']);
    String? bodyAttr(String name) =>
        bodyPr?.attr(name) ?? layoutBody?.attr(name) ?? masterBody?.attr(name);
    double inset(String name, double fallback) {
      final v = double.tryParse(bodyAttr(name) ?? '');
      return v == null ? fallback : v / emuPerPoint;
    }

    var scale = 1.0;
    final autofit =
        bodyPr?.child('normAutofit') ??
        layoutBody?.child('normAutofit') ??
        masterBody?.child('normAutofit');
    final fontScale = double.tryParse(autofit?.attr('fontScale') ?? '');
    if (fontScale != null) scale = fontScale / 100000;

    final chain = <_ListStyle>[deck.defaultStyle];
    final fontRef = style?.child('fontRef');
    if (fontRef != null && _colors.resolve(fontRef) != null) {
      chain.add(_ListStyle.withFill(fontRef));
    }
    var isTitle = false;
    var footer = false;
    if (ph != null) {
      final kind = _Placeholders.kindOf(ph);
      isTitle = kind == 'title';
      footer =
          kind == 'sldNum' || kind == 'dt' || kind == 'ftr' || kind == 'hdr';
      final styleName = isTitle
          ? 'titleStyle'
          : (footer ? 'otherStyle' : 'bodyStyle');
      chain.add(_ListStyle.parse(_masterStyles?.child(styleName)));
      chain.add(_ListStyle.parse(masterSp?.path(['txBody', 'lstStyle'])));
      chain.add(_ListStyle.parse(layoutSp?.path(['txBody', 'lstStyle'])));
    }
    chain.add(_ListStyle.parse(txBody?.child('lstStyle')));

    final paragraphs = txBody == null
        ? const <SlideParagraph>[]
        : _paragraphs(txBody, chain, part, scale);
    final hasText = paragraphs.any((p) => p.inlines.isNotEmpty);
    final kind = spPr == null ? ShapeKind.rect : _kind(spPr);
    if (!hasText && fill == null && outline.color == null) return;

    final anchor = bodyAttr('anchor');
    final shape = SlideTextShape(
      x: geometry.x,
      y: geometry.y,
      width: geometry.w,
      height: geometry.h,
      rotation: geometry.rot,
      paragraphs: paragraphs,
      kind: kind,
      fill: fill,
      line: outline.color,
      lineWidthPt: outline.width,
      anchor: anchor == 'ctr' ? 0 : (anchor == 'b' ? 1 : -1),
      insetLeft: inset('lIns', 7.2),
      insetTop: inset('tIns', 3.6),
      insetRight: inset('rIns', 7.2),
      insetBottom: inset('bIns', 3.6),
      title: isTitle,
      flipH: geometry.flipH,
    );
    _shapes.add(shape);

    if (!decorative && hasText && !footer) {
      final blocks = <DocBlock>[];
      if (isTitle) {
        final inlines = <Inline>[];
        for (final p in paragraphs) {
          if (inlines.isNotEmpty && p.inlines.isNotEmpty) {
            inlines.add(const TextRun(' '));
          }
          inlines.addAll(_withoutSize(p.inlines));
        }
        if (_title.isEmpty) _title = _plain(inlines);
        blocks.add(ParagraphBlock(inlines: inlines, heading: 2));
      } else {
        for (final p in paragraphs) {
          if (p.inlines.isEmpty) continue;
          blocks.add(
            ParagraphBlock(
              inlines: _withoutSize(p.inlines),
              rtl: p.rtl,
              listLevel: p.bullet.isEmpty ? -1 : p.level,
              marker: p.bullet,
            ),
          );
        }
      }
      _outline.add(_OutlineItem(geometry.y, geometry.x, blocks));
    }
  }

  static List<Inline> _withoutSize(List<Inline> inlines) {
    return <Inline>[
      for (final i in inlines)
        if (i is TextRun)
          TextRun(
            i.text,
            RunStyle(
              bold: i.style.bold,
              italic: i.style.italic,
              underline: i.style.underline,
              strike: i.style.strike,
              code: i.style.code,
              superscript: i.style.superscript,
              subscript: i.style.subscript,
              link: i.style.link,
            ),
          )
        else
          i,
    ];
  }

  static String _plain(List<Inline> inlines) {
    final out = StringBuffer();
    for (final i in inlines) {
      if (i is TextRun) out.write(i.text);
      if (i is LineBreakInline) out.write(' ');
    }
    return out.toString().trim();
  }

  void _connector(XmlElement cxn, _Xform xf, bool decorative) {
    final geometry = _geometry(cxn.path(['spPr', 'xfrm']), xf);
    if (geometry == null) return;
    final outline = _outlineOf(cxn);
    if (outline.color == null) return;
    _shapes.add(
      SlideTextShape(
        x: geometry.x,
        y: geometry.y,
        width: geometry.w,
        height: geometry.h,
        rotation: geometry.rot,
        kind: ShapeKind.line,
        line: outline.color,
        lineWidthPt: outline.width,
        flipH: geometry.flipH,
      ),
    );
  }

  void _picture(XmlElement pic, _Part part, _Xform xf, bool decorative) {
    final geometry = _geometry(pic.path(['spPr', 'xfrm']), xf);
    if (geometry == null) return;
    final blip = pic.path(['blipFill', 'blip']);
    final bytes = deck.bytes(part.path, blip?.prefixedAttr('embed'));
    if (bytes == null) return;
    final crop = pic.path(['blipFill', 'srcRect']);
    double cut(String side) =>
        (double.tryParse(crop?.attr(side) ?? '') ?? 0) / 100000;
    final alt = pic.path(['nvPicPr', 'cNvPr'])?.attr('descr') ?? '';
    _shapes.add(
      SlidePictureShape(
        x: geometry.x,
        y: geometry.y,
        width: geometry.w,
        height: geometry.h,
        rotation: geometry.rot,
        bytes: bytes,
        alt: alt,
        cropLeft: cut('l'),
        cropTop: cut('t'),
        cropRight: cut('r'),
        cropBottom: cut('b'),
      ),
    );
    if (!decorative) {
      _outline.add(
        _OutlineItem(geometry.y, geometry.x, <DocBlock>[
          ParagraphBlock(
            inlines: <Inline>[ImageInline(bytes: bytes, alt: alt)],
          ),
        ]),
      );
    }
  }

  void _frame(XmlElement frame, _Part part, _Xform xf, bool decorative) {
    final table = frame.path(['graphic', 'graphicData', 'tbl']);
    if (table == null) return;
    final geometry = _geometry(frame.child('xfrm'), xf);
    if (geometry == null) return;

    final widths = <double>[
      for (final g
          in table.child('tblGrid')?.childrenNamed('gridCol') ??
              const <XmlElement>[])
        (double.tryParse(g.attr('w') ?? '') ?? 1000000) / emuPerPoint * xf.sx,
    ];
    if (widths.isEmpty) return;

    final props = table.child('tblPr');
    final headerRow = props?.attr('firstRow') == '1';
    final banded = props?.attr('bandRow') == '1';
    final accent = _colors.scheme('accent1') ?? 0xFF4472C4;
    final chain = <_ListStyle>[deck.defaultStyle];

    final rows = <List<SlideTableCell>>[];
    final outlineRows = <TableRowData>[];
    var rowIndex = 0;
    for (final tr in table.childrenNamed('tr')) {
      final cells = <SlideTableCell>[];
      final outlineCells = <TableCellData>[];
      for (final tc in tr.childrenNamed('tc')) {
        if (tc.attr('hMerge') == '1' || tc.attr('vMerge') == '1') continue;
        final span = int.tryParse(tc.attr('gridSpan') ?? '') ?? 1;
        final tcPr = tc.child('tcPr');
        int? fill = _colors.resolve(tcPr?.child('solidFill'));
        final isHeader = headerRow && rowIndex == 0;
        var textChain = chain;
        if (fill == null) {
          if (isHeader) {
            fill = accent;
            textChain = <_ListStyle>[deck.defaultStyle, _whiteText()];
          } else if (banded && rowIndex.isOdd) {
            fill = (accent & 0x00FFFFFF) | 0x33000000;
          }
        }
        final body = tc.child('txBody');
        final paragraphs = body == null
            ? const <SlideParagraph>[]
            : _paragraphs(body, textChain, part, 1);
        cells.add(
          SlideTableCell(
            paragraphs: paragraphs,
            fill: fill,
            span: span < 1 ? 1 : span,
          ),
        );
        outlineCells.add(
          TableCellData(
            blocks: <DocBlock>[
              ParagraphBlock(
                inlines: <Inline>[
                  for (final p in paragraphs) ..._withoutSize(p.inlines),
                ],
              ),
            ],
            span: span < 1 ? 1 : span,
          ),
        );
      }
      if (cells.isNotEmpty) {
        rows.add(cells);
        outlineRows.add(
          TableRowData(cells: outlineCells, header: headerRow && rowIndex == 0),
        );
      }
      rowIndex++;
    }
    if (rows.isEmpty) return;

    _shapes.add(
      SlideTableShape(
        x: geometry.x,
        y: geometry.y,
        width: geometry.w,
        height: geometry.h,
        columnWidths: widths,
        rows: rows,
      ),
    );
    if (!decorative) {
      _outline.add(
        _OutlineItem(geometry.y, geometry.x, <DocBlock>[
          TableBlock(
            rows: outlineRows,
            columnWeights: List<double>.filled(widths.length, 1),
          ),
        ]),
      );
    }
  }

  _ListStyle _whiteText() {
    final style = _ListStyle();
    for (var n = 0; n < 9; n++) {
      final level = _Level();
      level.run.bold = true;
      level.run.fill = _whiteFill;
      style.levels[n] = level;
    }
    return style;
  }

  static final XmlElement _whiteFill = _buildWhite();

  static XmlElement _buildWhite() {
    final holder = XmlElement('a:solidFill', <String, String>{});
    holder.children.add(
      XmlElement('a:srgbClr', <String, String>{'val': 'FFFFFF'}),
    );
    return holder;
  }

  List<SlideParagraph> _paragraphs(
    XmlElement txBody,
    List<_ListStyle> chain,
    _Part part,
    double scale,
  ) {
    const defaultSize = 18.0;
    final counters = List<int>.filled(10, 0);
    final out = <SlideParagraph>[];
    final rels = deck.rels(part.path);
    final defaultColor = _colors.scheme('tx1') ?? 0xFF000000;

    for (final p in txBody.childrenNamed('p')) {
      final own = _ParaInfo.read(p.child('pPr'));
      final level = math.min(8, math.max(0, own.lvl ?? 0));
      final resolved = _Level();
      for (final style in chain) {
        final lv = style.levels[level];
        if (lv != null) resolved.merge(lv);
      }
      resolved.para.merge(own);

      final inlines = <Inline>[];
      double? firstSize;
      for (final child in p.children) {
        if (child.local == 'br') {
          inlines.add(const LineBreakInline());
          continue;
        }
        if (child.local != 'r' && child.local != 'fld') continue;
        final text = child.child('t')?.text ?? '';
        if (text.isEmpty) continue;
        final rPr = child.child('rPr');
        final info = _RunInfo()
          ..merge(resolved.run)
          ..merge(_RunInfo.read(rPr));
        final relId = rPr?.child('hlinkClick')?.prefixedAttr('id');
        final rel = relId == null ? null : rels[relId];
        final link = rel != null && rel.external ? rel.target : null;
        final size = (info.size ?? defaultSize) * scale;
        firstSize ??= size;
        final baseline = info.baseline ?? 0;
        inlines.add(
          TextRun(
            text,
            RunStyle(
              bold: info.bold ?? false,
              italic: info.italic ?? false,
              underline: info.underline ?? false,
              strike: info.strike ?? false,
              code: info.mono ?? false,
              superscript: baseline > 0,
              subscript: baseline < 0,
              color: _colors.resolve(info.fill) ?? defaultColor,
              sizePt: size,
              link: link,
            ),
          ),
        );
      }

      final endSize = _RunInfo.read(p.child('endParaRPr')).size;
      final paragraphSize =
          firstSize ?? (endSize ?? resolved.run.size ?? defaultSize) * scale;

      var bullet = '';
      final paraInfo = resolved.para;
      if (inlines.isNotEmpty && paraInfo.bulletNone != true) {
        if (paraInfo.autoNum != null) {
          counters[level] = counters[level] == 0
              ? (paraInfo.autoStart ?? 1)
              : counters[level] + 1;
          bullet = _autoNumber(counters[level], paraInfo.autoNum!);
        } else if (paraInfo.bulletChar != null) {
          bullet = _bulletChar(paraInfo.bulletChar!, paraInfo.bulletFont);
          counters[level] = 0;
        }
      } else {
        counters[level] = 0;
      }
      for (var d = level + 1; d < counters.length; d++) {
        counters[d] = 0;
      }

      final rtl = paraInfo.rtl;
      final algn = paraInfo.algn;
      final DocAlign align;
      switch (algn) {
        case 'ctr':
          align = DocAlign.center;
        case 'r':
          align = rtl == true ? DocAlign.start : DocAlign.end;
        case 'just':
        case 'justLow':
        case 'dist':
          align = DocAlign.justify;
        default:
          align = rtl == true ? DocAlign.end : DocAlign.start;
      }

      out.add(
        SlideParagraph(
          inlines: inlines,
          align: align,
          rtl: rtl,
          level: level,
          bullet: bullet,
          marginPt: paraInfo.marL ?? 0,
          indentPt: paraInfo.indent ?? 0,
          spaceBeforePt: (paraInfo.spaceBefore ?? 0) * scale,
          sizePt: paragraphSize,
        ),
      );
    }
    return out;
  }

  static String _bulletChar(String char, String? font) {
    if (char.isEmpty) return '•';
    final c = char.codeUnitAt(0);
    if (c >= 0xF000 && c <= 0xF0FF) return '•';
    final face = font?.toLowerCase() ?? '';
    if (face.contains('wingdings')) return '▪';
    if (face.contains('symbol')) return '•';
    return char;
  }

  static String _autoNumber(int n, String type) {
    switch (type) {
      case 'arabicParenR':
        return '$n)';
      case 'arabicParenBoth':
        return '($n)';
      case 'arabicPlain':
        return '$n';
      case 'alphaLcPeriod':
        return '${formatLetters(n, 0x61)}.';
      case 'alphaUcPeriod':
        return '${formatLetters(n, 0x41)}.';
      case 'alphaLcParenR':
        return '${formatLetters(n, 0x61)})';
      case 'alphaUcParenR':
        return '${formatLetters(n, 0x41)})';
      case 'romanLcPeriod':
        return '${formatRoman(n).toLowerCase()}.';
      case 'romanUcPeriod':
        return '${formatRoman(n)}.';
    }
    return '$n.';
  }
}
