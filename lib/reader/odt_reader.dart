import 'dart:typed_data';

import 'package:olako/reader/doc_model.dart';
import 'package:olako/reader/ooxml_util.dart';
import 'package:olako/reader/xml_lite.dart';
import 'package:olako/reader/zip_archive.dart';

class _Fmt {
  bool? bold;
  bool? italic;
  bool? underline;
  bool? strike;
  bool? superscript;
  bool? subscript;
  int? color;
  int? background;

  _Fmt copy() => _Fmt()..merge(this);

  void merge(_Fmt o) {
    bold = o.bold ?? bold;
    italic = o.italic ?? italic;
    underline = o.underline ?? underline;
    strike = o.strike ?? strike;
    superscript = o.superscript ?? superscript;
    subscript = o.subscript ?? subscript;
    color = o.color ?? color;
    background = o.background ?? background;
  }
}

int? _hex(String? value) {
  if (value == null || !value.startsWith('#')) return null;
  return parseHexColor(value.substring(1));
}

_Fmt _readFmt(XmlElement? props) {
  final fmt = _Fmt();
  if (props == null) return fmt;
  final weight = props.attr('font-weight');
  if (weight != null) {
    final number = int.tryParse(weight);
    fmt.bold = weight == 'bold' || (number != null && number >= 600);
  }
  final style = props.attr('font-style');
  if (style != null) fmt.italic = style == 'italic' || style == 'oblique';
  final underline = props.attr('text-underline-style');
  if (underline != null) fmt.underline = underline != 'none';
  final strike = props.attr('text-line-through-style');
  if (strike != null) fmt.strike = strike != 'none';
  final position = props.attr('text-position');
  if (position != null) {
    final first = position.trim().split(' ').first;
    if (first == 'super') {
      fmt.superscript = true;
    } else if (first == 'sub') {
      fmt.subscript = true;
    } else {
      final percent = int.tryParse(first.replaceAll('%', ''));
      if (percent != null && percent > 0) fmt.superscript = true;
      if (percent != null && percent < 0) fmt.subscript = true;
    }
  }
  fmt.color = _hex(props.attr('color'));
  fmt.background = _hex(props.attr('background-color'));
  return fmt;
}

class _OdStyles {
  final Map<String, XmlElement> _byName = <String, XmlElement>{};
  final Map<String, XmlElement> _lists = <String, XmlElement>{};

  void add(XmlElement? container) {
    if (container == null) return;
    for (final s in container.childrenNamed('style')) {
      final name = s.attr('name');
      if (name != null) _byName[name] = s;
    }
    for (final l in container.childrenNamed('list-style')) {
      final name = l.attr('name');
      if (name != null) _lists[name] = l;
    }
  }

  List<XmlElement> _chain(String? name) {
    final chain = <XmlElement>[];
    var current = name == null ? null : _byName[name];
    var guard = 0;
    while (current != null && guard < 12) {
      chain.insert(0, current);
      final parent = current.attr('parent-style-name');
      current = parent == null ? null : _byName[parent];
      guard++;
    }
    return chain;
  }

  _Fmt text(String? name) {
    final fmt = _Fmt();
    for (final s in _chain(name)) {
      fmt.merge(_readFmt(s.child('text-properties')));
    }
    return fmt;
  }

  String? _paragraphAttr(String? name, String attribute) {
    for (final s in _chain(name).reversed) {
      final value = s.child('paragraph-properties')?.attr(attribute);
      if (value != null) return value;
    }
    return null;
  }

  DocAlign? align(String? name) {
    switch (_paragraphAttr(name, 'text-align')) {
      case 'center':
        return DocAlign.center;
      case 'end':
      case 'right':
        return DocAlign.end;
      case 'justify':
        return DocAlign.justify;
      case 'start':
      case 'left':
        return DocAlign.start;
    }
    return null;
  }

  bool? rtl(String? name) {
    final mode = _paragraphAttr(name, 'writing-mode');
    if (mode == null) return null;
    if (mode.startsWith('rl')) return true;
    if (mode.startsWith('lr')) return false;
    return null;
  }

  bool isNumbered(String? name, int level) {
    final list = name == null ? null : _lists[name];
    if (list == null) return false;
    for (final l in list.children) {
      if (l.attr('level') == '${level + 1}') {
        return l.local == 'list-level-style-number';
      }
    }
    return false;
  }
}

final RegExp _spaces = RegExp(r'[ \t\r\n]+');

double? _length(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^\s*([\d.]+)\s*([a-z%]*)').firstMatch(value);
  if (match == null) return null;
  final number = double.tryParse(match.group(1)!);
  if (number == null) return null;
  switch (match.group(2)) {
    case 'cm':
      return number * 28.3465;
    case 'mm':
      return number * 2.83465;
    case 'in':
      return number * 72;
    case 'px':
      return number * 0.75;
    case 'pt':
      return number;
  }
  return null;
}

class _OdtReader {
  _OdtReader(this.zip, this.styles);

  final ZipArchive zip;
  final _OdStyles styles;

  RunStyle _runStyle(_Fmt fmt, String? link) {
    return RunStyle(
      bold: fmt.bold ?? false,
      italic: fmt.italic ?? false,
      underline: fmt.underline ?? false,
      strike: fmt.strike ?? false,
      superscript: fmt.superscript ?? false,
      subscript: fmt.subscript ?? false,
      color: fmt.color,
      background: fmt.background,
      link: link,
    );
  }

  void readBlocks(XmlElement parent, List<DocBlock> out) {
    for (final e in parent.children) {
      switch (e.local) {
        case 'h':
          final level = int.tryParse(e.attr('outline-level') ?? '') ?? 1;
          out.add(
            _paragraph(e, heading: level < 1 ? 1 : (level > 6 ? 6 : level)),
          );
        case 'p':
          out.add(_paragraph(e));
        case 'list':
          _list(e, out, 0, null);
        case 'table':
          final table = _table(e);
          if (table != null) out.add(table);
        case 'section':
        case 'table-of-content':
        case 'index-body':
        case 'index-title':
        case 'alphabetical-index':
        case 'user-index':
        case 'illustration-index':
        case 'bibliography':
          readBlocks(e, out);
      }
    }
  }

  ParagraphBlock _paragraph(
    XmlElement e, {
    int heading = 0,
    int level = -1,
    String marker = '',
  }) {
    final styleName = e.attr('style-name');
    final inlines = <Inline>[];
    _inlines(e, styles.text(styleName), null, inlines);
    return ParagraphBlock(
      inlines: _trimmed(inlines),
      heading: heading,
      align: styles.align(styleName) ?? DocAlign.start,
      rtl: styles.rtl(styleName),
      listLevel: level,
      marker: marker,
    );
  }

  List<Inline> _trimmed(List<Inline> inlines) {
    if (inlines.isEmpty) return inlines;
    final out = List<Inline>.of(inlines);
    final first = out.first;
    if (first is TextRun) {
      final text = first.text.trimLeft();
      if (text.isEmpty) {
        out.removeAt(0);
      } else if (text != first.text) {
        out[0] = TextRun(text, first.style);
      }
    }
    if (out.isNotEmpty) {
      final last = out.last;
      if (last is TextRun) {
        final text = last.text.trimRight();
        if (text.isEmpty) {
          out.removeLast();
        } else if (text != last.text) {
          out[out.length - 1] = TextRun(text, last.style);
        }
      }
    }
    return out;
  }

  void _inlines(XmlElement e, _Fmt fmt, String? link, List<Inline> out) {
    for (final node in e.nodes) {
      if (node is String) {
        final text = node.replaceAll(_spaces, ' ');
        if (text.isNotEmpty) out.add(TextRun(text, _runStyle(fmt, link)));
        continue;
      }
      if (node is! XmlElement) continue;
      switch (node.local) {
        case 'span':
          final merged = fmt.copy()
            ..merge(styles.text(node.attr('style-name')));
          _inlines(node, merged, link, out);
        case 'a':
          _inlines(node, fmt, node.attr('href') ?? link, out);
        case 's':
          final count = int.tryParse(node.attr('c') ?? '') ?? 1;
          out.add(TextRun(' ' * count, _runStyle(fmt, link)));
        case 'tab':
          out.add(TextRun('    ', _runStyle(fmt, link)));
        case 'line-break':
          out.add(const LineBreakInline());
        case 'frame':
          _frame(node, out);
        case 'note':
        case 'annotation':
        case 'tracked-changes':
        case 'bookmark':
        case 'bookmark-start':
        case 'bookmark-end':
        case 'soft-page-break':
          break;
        default:
          _inlines(node, fmt, link, out);
      }
    }
  }

  void _frame(XmlElement frame, List<Inline> out) {
    final width = _length(frame.attr('width'));
    final height = _length(frame.attr('height'));
    final alt = frame.child('desc')?.text ?? frame.child('title')?.text ?? '';
    for (final image in frame.descendants('image')) {
      var href = image.attr('href');
      if (href == null) continue;
      if (href.startsWith('./')) href = href.substring(2);
      Uint8List? bytes;
      try {
        bytes = zip.read(href);
      } on DocumentFormatException {
        bytes = null;
      }
      if (bytes == null) continue;
      out.add(
        ImageInline(bytes: bytes, alt: alt, widthPt: width, heightPt: height),
      );
    }
  }

  void _list(
    XmlElement list,
    List<DocBlock> out,
    int level,
    String? inherited,
  ) {
    final styleName = list.attr('style-name') ?? inherited;
    final numbered = styles.isNumbered(styleName, level);
    const bullets = <String>['•', '◦', '▪'];
    var counter = 0;
    for (final item in list.children) {
      if (item.local != 'list-item' && item.local != 'list-header') continue;
      final marked = item.local == 'list-item';
      if (marked) counter++;
      var first = true;
      for (final child in item.children) {
        if (child.local == 'p' || child.local == 'h') {
          final marker = first && marked
              ? (numbered ? '$counter.' : bullets[level % 3])
              : '';
          first = false;
          out.add(_paragraph(child, level: level, marker: marker));
        } else if (child.local == 'list') {
          _list(child, out, level + 1, styleName);
        }
      }
    }
  }

  TableBlock? _table(XmlElement table) {
    final rows = <TableRowData>[];

    void walk(XmlElement parent, bool header) {
      for (final c in parent.children) {
        switch (c.local) {
          case 'table-header-rows':
            walk(c, true);
          case 'table-row-group':
          case 'table-rows':
            walk(c, header);
          case 'table-row':
            final cells = <TableCellData>[];
            for (final cell in c.children) {
              if (cell.local != 'table-cell') continue;
              final blocks = <DocBlock>[];
              readBlocks(cell, blocks);
              final repeat =
                  int.tryParse(cell.attr('number-columns-repeated') ?? '') ?? 1;
              if (blocks.isEmpty && repeat > 1) continue;
              final span =
                  int.tryParse(cell.attr('number-columns-spanned') ?? '') ?? 1;
              cells.add(
                TableCellData(
                  blocks: blocks.isEmpty
                      ? const <DocBlock>[ParagraphBlock(inlines: <Inline>[])]
                      : blocks,
                  span: span < 1 ? 1 : span,
                ),
              );
            }
            if (cells.isNotEmpty)
              rows.add(TableRowData(cells: cells, header: header));
        }
      }
    }

    walk(table, false);
    if (rows.isEmpty) return null;
    return TableBlock(rows: rows);
  }
}

double _defaultSize(XmlElement? styles) {
  for (final d
      in styles?.childrenNamed('default-style') ??
          const Iterable<XmlElement>.empty()) {
    if (d.attr('family') != 'paragraph') continue;
    final size = _length(d.child('text-properties')?.attr('font-size'));
    if (size != null && size > 4) return size;
  }
  return 12;
}

TextDocument readOdt(ZipArchive zip) {
  final content = readXmlPart(zip, 'content.xml');
  final body = content?.child('body')?.child('text');
  if (content == null || body == null) {
    throw const DocumentFormatException('The document has no text.');
  }
  final styleRoot = readXmlPart(zip, 'styles.xml');
  final styles = _OdStyles()
    ..add(styleRoot?.child('styles'))
    ..add(styleRoot?.child('automatic-styles'))
    ..add(content.child('automatic-styles'));
  final blocks = <DocBlock>[];
  _OdtReader(zip, styles).readBlocks(body, blocks);

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
  return TextDocument(
    blocks: out,
    baseSizePt: _defaultSize(styleRoot?.child('styles')),
  );
}
