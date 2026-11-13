import 'dart:math' as math;
import 'dart:typed_data';

import 'package:olako/reader/doc_model.dart';
import 'package:olako/reader/ooxml_util.dart';
import 'package:olako/reader/xml_lite.dart';
import 'package:olako/reader/zip_archive.dart';

TextDocument readDocx(ZipArchive zip) {
  final mainPath = findMainPart(zip) ?? 'word/document.xml';
  final root = readXmlPart(zip, mainPath);
  final body = root?.child('body');
  if (root == null || body == null) {
    throw const DocumentFormatException('The Word document has no body.');
  }
  final rels = readRelationships(zip, mainPath);

  String? partOf(String suffix, String fallback) {
    for (final r in rels.values) {
      if (r.type.endsWith(suffix) && !r.external) {
        return resolvePartPath(mainPath, r.target);
      }
    }
    return zip.contains(fallback) ? fallback : null;
  }

  final styles = _Styles(
    readXmlPart(zip, partOf('/styles', 'word/styles.xml')),
  );
  final numbering = _Numbering(
    readXmlPart(zip, partOf('/numbering', 'word/numbering.xml')),
  );
  final footnotes = <String, XmlElement>{};
  final footnoteRoot = readXmlPart(
    zip,
    partOf('/footnotes', 'word/footnotes.xml'),
  );
  if (footnoteRoot != null) {
    for (final note in footnoteRoot.childrenNamed('footnote')) {
      final id = note.attr('id');
      final type = note.attr('type');
      if (id == null || (type != null && type != 'normal')) continue;
      footnotes[id] = note;
    }
  }

  final reader = _DocxReader(
    zip: zip,
    mainPath: mainPath,
    rels: rels,
    styles: styles,
    numbering: numbering,
    footnotes: footnotes,
  );
  final blocks = <DocBlock>[];
  reader.readBody(body, blocks);
  reader.appendFootnotes(blocks);
  return TextDocument(blocks: _tidy(blocks), baseSizePt: styles.baseSizePt);
}

List<DocBlock> _tidy(List<DocBlock> blocks) {
  final out = <DocBlock>[];
  var lastEmpty = true;
  for (final block in blocks) {
    final empty =
        block is ParagraphBlock && block.isEmpty && block.marker.isEmpty;
    if (empty && lastEmpty) continue;
    out.add(block);
    lastEmpty = empty;
  }
  while (out.isNotEmpty) {
    final last = out.last;
    if (last is ParagraphBlock && last.isEmpty && last.marker.isEmpty) {
      out.removeLast();
    } else {
      break;
    }
  }
  return out;
}

class _RunProps {
  bool? bold;
  bool? italic;
  bool? underline;
  bool? strike;
  bool? caps;
  bool? hidden;
  bool? mono;
  double? sizePt;
  int? color;
  int? background;
  String? vertAlign;

  _RunProps copy() => _RunProps()..merge(this);

  void merge(_RunProps o) {
    bold = o.bold ?? bold;
    italic = o.italic ?? italic;
    underline = o.underline ?? underline;
    strike = o.strike ?? strike;
    caps = o.caps ?? caps;
    hidden = o.hidden ?? hidden;
    mono = o.mono ?? mono;
    sizePt = o.sizePt ?? sizePt;
    color = o.color ?? color;
    background = o.background ?? background;
    vertAlign = o.vertAlign ?? vertAlign;
  }
}

class _ParaProps {
  DocAlign? align;
  bool? bidi;
  double? leftPt;
  int? numId;
  int? ilvl;
  int? outline;
  int? shade;

  void merge(_ParaProps o) {
    align = o.align ?? align;
    bidi = o.bidi ?? bidi;
    leftPt = o.leftPt ?? leftPt;
    numId = o.numId ?? numId;
    ilvl = o.ilvl ?? ilvl;
    outline = o.outline ?? outline;
    shade = o.shade ?? shade;
  }
}

bool? _toggle(XmlElement? e) {
  if (e == null) return null;
  final v = e.attr('val');
  if (v == null) return true;
  return !(v == '0' || v == 'false' || v == 'off');
}

const Map<String, int> _highlights = <String, int>{
  'yellow': 0xFFFFFF00,
  'green': 0xFF00FF00,
  'cyan': 0xFF00FFFF,
  'magenta': 0xFFFF00FF,
  'blue': 0xFF0000FF,
  'red': 0xFFFF0000,
  'darkBlue': 0xFF000080,
  'darkCyan': 0xFF008080,
  'darkGreen': 0xFF008000,
  'darkMagenta': 0xFF800080,
  'darkRed': 0xFF800000,
  'darkYellow': 0xFF808000,
  'darkGray': 0xFF808080,
  'lightGray': 0xFFC0C0C0,
};

bool _isMonoFont(String? name) {
  if (name == null) return false;
  final n = name.toLowerCase();
  return n.contains('courier') ||
      n.contains('consolas') ||
      n.contains('mono') ||
      n.contains('menlo') ||
      n.contains('lucida console');
}

_RunProps _readRunProps(XmlElement? rPr) {
  final props = _RunProps();
  if (rPr == null) return props;
  props.bold = _toggle(rPr.child('b'));
  props.italic = _toggle(rPr.child('i'));
  props.strike = _toggle(rPr.child('strike')) ?? _toggle(rPr.child('dstrike'));
  props.caps = _toggle(rPr.child('caps'));
  props.hidden = _toggle(rPr.child('vanish'));
  final u = rPr.child('u');
  if (u != null) props.underline = u.attr('val') != 'none';
  final size = double.tryParse(rPr.child('sz')?.attr('val') ?? '');
  if (size != null) props.sizePt = size / 2;
  props.color = parseHexColor(rPr.child('color')?.attr('val'));
  final highlight = rPr.child('highlight')?.attr('val');
  if (highlight != null) props.background = _highlights[highlight];
  props.background ??= parseHexColor(rPr.child('shd')?.attr('fill'));
  props.vertAlign = rPr.child('vertAlign')?.attr('val');
  final fonts = rPr.child('rFonts');
  if (fonts != null) {
    final name = fonts.attr('ascii') ?? fonts.attr('hAnsi');
    if (name != null) props.mono = _isMonoFont(name);
  }
  return props;
}

DocAlign? _readAlign(String? value) {
  switch (value) {
    case 'left':
    case 'start':
      return DocAlign.start;
    case 'right':
    case 'end':
      return DocAlign.end;
    case 'center':
      return DocAlign.center;
    case 'both':
    case 'distribute':
    case 'thaiDistribute':
      return DocAlign.justify;
  }
  return null;
}

_ParaProps _readParaProps(XmlElement? pPr) {
  final props = _ParaProps();
  if (pPr == null) return props;
  props.align = _readAlign(pPr.child('jc')?.attr('val'));
  final bidi = pPr.child('bidi');
  if (bidi != null) props.bidi = _toggle(bidi);
  final ind = pPr.child('ind');
  if (ind != null) {
    final left = double.tryParse(ind.attr('left') ?? ind.attr('start') ?? '');
    if (left != null) props.leftPt = left / 20;
  }
  final numPr = pPr.child('numPr');
  if (numPr != null) {
    props.numId = int.tryParse(numPr.child('numId')?.attr('val') ?? '');
    props.ilvl = int.tryParse(numPr.child('ilvl')?.attr('val') ?? '');
  }
  props.outline = int.tryParse(pPr.child('outlineLvl')?.attr('val') ?? '');
  props.shade = parseHexColor(pPr.child('shd')?.attr('fill'));
  return props;
}

class _StyleDef {
  _StyleDef({
    required this.id,
    required this.name,
    required this.basedOn,
    required this.para,
    required this.run,
  });

  final String id;
  final String name;
  final String? basedOn;
  final _ParaProps para;
  final _RunProps run;
}

class _Styles {
  _Styles(XmlElement? root) {
    if (root == null) return;
    final defaults = root.child('docDefaults');
    final runDefault = defaults?.path(['rPrDefault', 'rPr']);
    if (runDefault != null) _defaultRun = _readRunProps(runDefault);
    final paraDefault = defaults?.path(['pPrDefault', 'pPr']);
    if (paraDefault != null) _defaultPara = _readParaProps(paraDefault);
    for (final s in root.childrenNamed('style')) {
      final id = s.attr('styleId');
      if (id == null) continue;
      final def = _StyleDef(
        id: id,
        name: s.child('name')?.attr('val') ?? id,
        basedOn: s.child('basedOn')?.attr('val'),
        para: _readParaProps(s.child('pPr')),
        run: _readRunProps(s.child('rPr')),
      );
      _styles[id] = def;
      if (s.attr('type') == 'paragraph' && s.attr('default') == '1') {
        _normalId = id;
      }
    }
  }

  final Map<String, _StyleDef> _styles = <String, _StyleDef>{};
  _RunProps _defaultRun = _RunProps();
  _ParaProps _defaultPara = _ParaProps();
  String? _normalId;

  double get baseSizePt {
    final size = runProps(_normalId).sizePt ?? _defaultRun.sizePt;
    return size ?? 11;
  }

  List<_StyleDef> _chain(String? id) {
    final chain = <_StyleDef>[];
    var current = id == null ? null : _styles[id];
    var guard = 0;
    while (current != null && guard < 20) {
      chain.insert(0, current);
      final parent = current.basedOn;
      current = parent == null ? null : _styles[parent];
      guard++;
    }
    return chain;
  }

  _RunProps runProps(String? id) {
    final props = _defaultRun.copy();
    for (final s in _chain(id)) {
      props.merge(s.run);
    }
    return props;
  }

  _RunProps charProps(String? id) {
    final props = _RunProps();
    for (final s in _chain(id)) {
      props.merge(s.run);
    }
    return props;
  }

  _ParaProps paraProps(String? id) {
    final props = _ParaProps()..merge(_defaultPara);
    for (final s in _chain(_normalId)) {
      props.merge(s.para);
    }
    for (final s in _chain(id)) {
      props.merge(s.para);
    }
    return props;
  }

  String? get normalId => _normalId;

  int headingLevel(String? id) {
    for (final s in _chain(id).reversed) {
      final name = s.name.toLowerCase();
      if (name == 'title') return 1;
      if (name.startsWith('heading ')) {
        final n = int.tryParse(name.substring(8).trim());
        if (n != null && n >= 1) return n > 6 ? 6 : n;
      }
    }
    return 0;
  }
}

class _NumLevel {
  const _NumLevel({
    required this.format,
    required this.text,
    required this.start,
  });

  final String format;
  final String text;
  final int start;
}

class _Numbering {
  _Numbering(XmlElement? root) {
    if (root == null) return;
    for (final abs in root.childrenNamed('abstractNum')) {
      final id = int.tryParse(abs.attr('abstractNumId') ?? '');
      if (id == null) continue;
      final levels = <int, _NumLevel>{};
      for (final lvl in abs.childrenNamed('lvl')) {
        final ilvl = int.tryParse(lvl.attr('ilvl') ?? '');
        if (ilvl == null) continue;
        levels[ilvl] = _NumLevel(
          format: lvl.child('numFmt')?.attr('val') ?? 'decimal',
          text: lvl.child('lvlText')?.attr('val') ?? '',
          start: int.tryParse(lvl.child('start')?.attr('val') ?? '') ?? 1,
        );
      }
      _abstracts[id] = levels;
    }
    for (final entry in root.childrenNamed('num')) {
      final id = int.tryParse(entry.attr('numId') ?? '');
      final abs = int.tryParse(entry.child('abstractNumId')?.attr('val') ?? '');
      if (id == null || abs == null) continue;
      _numToAbstract[id] = abs;
      for (final o in entry.childrenNamed('lvlOverride')) {
        final ilvl = int.tryParse(o.attr('ilvl') ?? '');
        final start = int.tryParse(o.child('startOverride')?.attr('val') ?? '');
        if (ilvl != null && start != null) {
          _overrides.putIfAbsent(id, () => <int, int>{})[ilvl] = start;
        }
      }
    }
  }

  final Map<int, Map<int, _NumLevel>> _abstracts = <int, Map<int, _NumLevel>>{};
  final Map<int, int> _numToAbstract = <int, int>{};
  final Map<int, Map<int, int>> _overrides = <int, Map<int, int>>{};
  final Map<int, List<int>> _counters = <int, List<int>>{};

  _NumLevel? _level(int numId, int ilvl) {
    final abs = _numToAbstract[numId];
    if (abs == null) return null;
    return _abstracts[abs]?[ilvl];
  }

  int _startOf(int numId, int ilvl) {
    return _overrides[numId]?[ilvl] ?? _level(numId, ilvl)?.start ?? 1;
  }

  String next(int numId, int ilvl) {
    final level = _level(numId, ilvl);
    if (level == null) return '•';
    final level0 = math.min(8, math.max(0, ilvl));
    final counters = _counters.putIfAbsent(
      numId,
      () => List<int>.filled(9, -1),
    );
    for (var j = 0; j < level0; j++) {
      if (counters[j] < 0) counters[j] = _startOf(numId, j);
    }
    counters[level0] = counters[level0] < 0
        ? _startOf(numId, level0)
        : counters[level0] + 1;
    for (var j = level0 + 1; j < 9; j++) {
      counters[j] = -1;
    }
    if (level.format == 'none') return '';
    if (level.format == 'bullet') return _bullet(level.text);
    var text = level.text.isEmpty ? '%${level0 + 1}.' : level.text;
    for (var k = 1; k <= 9; k++) {
      if (!text.contains('%$k')) continue;
      final lv = _level(numId, k - 1);
      final value = counters[k - 1] < 0
          ? _startOf(numId, k - 1)
          : counters[k - 1];
      text = text.replaceAll('%$k', _format(value, lv?.format ?? 'decimal'));
    }
    return text;
  }

  static String _bullet(String text) {
    if (text.isEmpty) return '•';
    final c = text.codeUnitAt(0);
    if (c >= 0xF000 && c <= 0xF0FF) {
      return c == 0xF0A7 || c == 0xF0FC ? '▪' : '•';
    }
    if (text == 'o') return '◦';
    if (text == '§') return '▪';
    return text;
  }

  static String _format(int n, String format) {
    switch (format) {
      case 'decimalZero':
        return n < 10 ? '0$n' : '$n';
      case 'lowerLetter':
        return _letters(n, 0x61);
      case 'upperLetter':
        return _letters(n, 0x41);
      case 'lowerRoman':
        return _roman(n).toLowerCase();
      case 'upperRoman':
        return _roman(n);
    }
    return '$n';
  }

  static String _letters(int n, int base) {
    if (n < 1) return '$n';
    var x = n;
    var out = '';
    while (x > 0) {
      x--;
      out = String.fromCharCode(base + x % 26) + out;
      x ~/= 26;
    }
    return out;
  }

  static String _roman(int n) {
    if (n < 1 || n > 3999) return '$n';
    const values = <int>[1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const symbols = <String>[
      'M',
      'CM',
      'D',
      'CD',
      'C',
      'XC',
      'L',
      'XL',
      'X',
      'IX',
      'V',
      'IV',
      'I',
    ];
    var x = n;
    final out = StringBuffer();
    for (var i = 0; i < values.length; i++) {
      while (x >= values[i]) {
        out.write(symbols[i]);
        x -= values[i];
      }
    }
    return out.toString();
  }
}

class _DocxReader {
  _DocxReader({
    required this.zip,
    required this.mainPath,
    required this.rels,
    required this.styles,
    required this.numbering,
    required this.footnotes,
  });

  final ZipArchive zip;
  final String mainPath;
  final Map<String, Relationship> rels;
  final _Styles styles;
  final _Numbering numbering;
  final Map<String, XmlElement> footnotes;
  final List<String> _footnoteOrder = <String>[];

  void readBody(XmlElement parent, List<DocBlock> out) {
    for (final child in parent.children) {
      switch (child.local) {
        case 'p':
          out.addAll(_paragraph(child));
        case 'tbl':
          out.add(_table(child));
        case 'sdt':
          final content = child.child('sdtContent');
          if (content != null) readBody(content, out);
        case 'ins':
        case 'customXml':
        case 'smartTag':
          readBody(child, out);
      }
    }
  }

  void appendFootnotes(List<DocBlock> out) {
    if (_footnoteOrder.isEmpty) return;
    out
      ..add(const RuleBlock())
      ..add(const ParagraphBlock(inlines: <Inline>[]));
    for (var i = 0; i < _footnoteOrder.length; i++) {
      final note = footnotes[_footnoteOrder[i]];
      if (note == null) continue;
      final blocks = <DocBlock>[];
      readBody(note, blocks);
      var first = true;
      for (final block in blocks) {
        if (first && block is ParagraphBlock) {
          first = false;
          out.add(
            ParagraphBlock(
              inlines: block.inlines,
              rtl: block.rtl,
              align: block.align,
              listLevel: 0,
              marker: '${i + 1}.',
            ),
          );
        } else {
          out.add(block);
        }
      }
    }
  }

  List<DocBlock> _paragraph(XmlElement p) {
    final pPr = p.child('pPr');
    final styleId = pPr?.child('pStyle')?.attr('val') ?? styles.normalId;
    final props = styles.paraProps(styleId)..merge(_readParaProps(pPr));
    final baseRun = styles.runProps(styleId);

    final builder = _ParagraphBuilder(this, baseRun);
    builder.readChildren(p, null);
    builder.flush();

    var heading = styles.headingLevel(styleId);
    final outline = props.outline;
    if (heading == 0 && outline != null && outline >= 0 && outline <= 5) {
      heading = outline + 1;
    }

    var marker = '';
    var listLevel = -1;
    final numId = props.numId;
    if (numId != null && numId != 0) {
      marker = numbering.next(numId, props.ilvl ?? 0);
      listLevel = math.min(8, math.max(0, props.ilvl ?? 0));
    }

    final inlines = builder.inlines;
    if (heading > 0 && marker.isNotEmpty) {
      inlines.insert(0, TextRun('$marker '));
      marker = '';
      listLevel = -1;
    }

    final blocks = <DocBlock>[];
    final pageBreakBefore = pPr?.child('pageBreakBefore') != null;
    if (pageBreakBefore) blocks.add(const RuleBlock(pageBreak: true));

    final hasContent = inlines.any(
      (i) => i is! TextRun || i.text.trim().isNotEmpty,
    );
    if (hasContent || !builder.pageBreak) {
      final indent = props.leftPt ?? 0;
      blocks.add(
        ParagraphBlock(
          inlines: hasContent ? inlines : const <Inline>[],
          heading: heading,
          align: props.align ?? DocAlign.start,
          rtl: props.bidi == true ? true : null,
          listLevel: listLevel,
          marker: marker,
          indentPt: listLevel >= 0 ? 0 : indent.clamp(0, 80).toDouble(),
          background: props.shade,
        ),
      );
    }
    blocks.addAll(builder.extras);
    if (builder.pageBreak) blocks.add(const RuleBlock(pageBreak: true));
    return blocks;
  }

  TableBlock _table(XmlElement tbl) {
    final weights = <double>[];
    final grid = tbl.child('tblGrid');
    if (grid != null) {
      for (final col in grid.childrenNamed('gridCol')) {
        weights.add(double.tryParse(col.attr('w') ?? '') ?? 1000);
      }
    }
    final rows = <TableRowData>[];
    for (final tr in tbl.childrenNamed('tr')) {
      final header = tr.path(['trPr', 'tblHeader']) != null;
      final cells = <TableCellData>[];
      for (final tc in tr.childrenNamed('tc')) {
        final tcPr = tc.child('tcPr');
        final span =
            int.tryParse(tcPr?.child('gridSpan')?.attr('val') ?? '') ?? 1;
        final merge = tcPr?.child('vMerge');
        final continued = merge != null && merge.attr('val') != 'restart';
        final blocks = <DocBlock>[];
        if (!continued) readBody(tc, blocks);
        cells.add(
          TableCellData(
            blocks: _tidy(blocks),
            span: span < 1 ? 1 : span,
            background: parseHexColor(tcPr?.child('shd')?.attr('fill')),
          ),
        );
      }
      if (cells.isNotEmpty)
        rows.add(TableRowData(cells: cells, header: header));
    }
    return TableBlock(rows: rows, columnWeights: weights);
  }

  Uint8List? _image(String? relId) {
    if (relId == null) return null;
    final rel = rels[relId];
    if (rel == null || rel.external) return null;
    try {
      return zip.read(resolvePartPath(mainPath, rel.target));
    } on DocumentFormatException {
      return null;
    }
  }

  int _noteNumber(String id) {
    var index = _footnoteOrder.indexOf(id);
    if (index < 0) {
      _footnoteOrder.add(id);
      index = _footnoteOrder.length - 1;
    }
    return index + 1;
  }
}

class _ParagraphBuilder {
  _ParagraphBuilder(this._reader, this._base);

  final _DocxReader _reader;
  final _RunProps _base;

  final List<Inline> inlines = <Inline>[];
  final List<DocBlock> extras = <DocBlock>[];
  bool pageBreak = false;

  final StringBuffer _text = StringBuffer();
  RunStyle _textStyle = const RunStyle();

  StringBuffer? _instruction;
  String? _fieldLink;

  void flush() {
    if (_text.isEmpty) return;
    inlines.add(TextRun(_text.toString(), _textStyle));
    _text.clear();
  }

  void _write(String text, RunStyle style) {
    if (text.isEmpty) return;
    if (_text.isNotEmpty &&
        (_textStyle.bold != style.bold ||
            _textStyle.italic != style.italic ||
            _textStyle.underline != style.underline ||
            _textStyle.strike != style.strike ||
            _textStyle.code != style.code ||
            _textStyle.superscript != style.superscript ||
            _textStyle.subscript != style.subscript ||
            _textStyle.color != style.color ||
            _textStyle.background != style.background ||
            _textStyle.sizePt != style.sizePt ||
            _textStyle.link != style.link)) {
      flush();
    }
    _textStyle = style;
    _text.write(text);
  }

  void readChildren(XmlElement parent, String? link) {
    for (final child in parent.children) {
      switch (child.local) {
        case 'r':
          _run(child, link);
        case 'hyperlink':
          final id = child.prefixedAttr('id');
          final rel = id == null ? null : _reader.rels[id];
          final target = rel != null && rel.external ? rel.target : null;
          readChildren(child, target ?? link);
        case 'sdt':
          final content = child.child('sdtContent');
          if (content != null) readChildren(content, link);
        case 'ins':
        case 'smartTag':
        case 'fldSimple':
        case 'customXml':
        case 'bdo':
        case 'dir':
          readChildren(child, link);
        case 'AlternateContent':
          final choice = child.child('Choice') ?? child.child('Fallback');
          if (choice != null) readChildren(choice, link);
      }
    }
  }

  void _run(XmlElement r, String? link) {
    final props = _base.copy();
    final rStyle = r.child('rPr')?.child('rStyle')?.attr('val');
    if (rStyle != null) props.merge(_reader.styles.charProps(rStyle));
    props.merge(_readRunProps(r.child('rPr')));
    _runContent(r, props, _style(props, link ?? _fieldLink));
  }

  void _runContent(XmlElement container, _RunProps props, RunStyle style) {
    final hidden = props.hidden == true;
    for (final c in container.children) {
      switch (c.local) {
        case 't':
          if (!hidden) _write(_cased(c.text, props), style);
        case 'tab':
          if (!hidden) _write('    ', style);
        case 'noBreakHyphen':
          if (!hidden) _write('-', style);
        case 'br':
        case 'cr':
          if (c.attr('type') == 'page') {
            pageBreak = true;
          } else {
            flush();
            inlines.add(const LineBreakInline());
          }
        case 'footnoteReference':
          final id = c.attr('id');
          if (id != null && _reader.footnotes.containsKey(id)) {
            final n = _reader._noteNumber(id);
            _write('$n', style.copyWith(superscript: true));
          }
        case 'fldChar':
          _fieldChar(c.attr('fldCharType'));
        case 'instrText':
          _instruction?.write(c.text);
        case 'drawing':
          _drawing(c);
        case 'pict':
          _picture(c);
        case 'AlternateContent':
          final choice = c.child('Choice') ?? c.child('Fallback');
          if (choice != null) _runContent(choice, props, style);
      }
    }
  }

  static String _cased(String text, _RunProps props) =>
      props.caps == true ? text.toUpperCase() : text;

  RunStyle _style(_RunProps props, String? link) {
    final size = props.sizePt;
    return RunStyle(
      bold: props.bold ?? false,
      italic: props.italic ?? false,
      underline: props.underline ?? false,
      strike: props.strike ?? false,
      code: props.mono ?? false,
      superscript: props.vertAlign == 'superscript',
      subscript: props.vertAlign == 'subscript',
      color: props.color,
      background: props.background,
      sizePt: size,
      link: link,
    );
  }

  void _fieldChar(String? type) {
    switch (type) {
      case 'begin':
        _instruction = StringBuffer();
        _fieldLink = null;
      case 'separate':
        final text = _instruction?.toString().trim() ?? '';
        _instruction = null;
        if (text.toUpperCase().startsWith('HYPERLINK')) {
          final match = RegExp('"([^"]+)"').firstMatch(text);
          final url = match?.group(1);
          if (url != null && url.contains(':')) _fieldLink = url;
        }
      case 'end':
        _instruction = null;
        _fieldLink = null;
    }
  }

  void _drawing(XmlElement drawing) {
    flush();
    final extent = drawing.descendants('extent').firstOrNull;
    final cx = double.tryParse(extent?.attr('cx') ?? '');
    final cy = double.tryParse(extent?.attr('cy') ?? '');
    final alt = drawing.descendants('docPr').firstOrNull?.attr('descr') ?? '';
    for (final blip in drawing.descendants('blip')) {
      final bytes = _reader._image(blip.prefixedAttr('embed'));
      if (bytes == null) continue;
      inlines.add(
        ImageInline(
          bytes: bytes,
          alt: alt,
          widthPt: cx == null ? null : cx / emuPerPoint,
          heightPt: cy == null ? null : cy / emuPerPoint,
        ),
      );
    }
    for (final box in drawing.descendants('txbxContent')) {
      _reader.readBody(box, extras);
    }
  }

  void _picture(XmlElement pict) {
    flush();
    for (final image in pict.descendants('imagedata')) {
      final bytes = _reader._image(image.prefixedAttr('id'));
      if (bytes == null) continue;
      inlines.add(ImageInline(bytes: bytes, alt: image.attr('title') ?? ''));
    }
    for (final box in pict.descendants('txbxContent')) {
      _reader.readBody(box, extras);
    }
  }
}
