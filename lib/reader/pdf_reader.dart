import 'dart:math' as math;
import 'dart:typed_data';

import 'package:olako/reader/doc_model.dart';
import 'package:olako/reader/pdf_objects.dart';
import 'package:olako/reader/pdf_tables.dart';
import 'package:olako/reader/pdf_text.dart';
import 'package:olako/reader/zip_archive.dart';

const int _maxPages = 1500;

class _Page {
  const _Page(this.dict, this.resources, this.attrs);

  final Map<String, Object?> dict;
  final Map<String, Object?>? resources;
  final Map<String, Object?> attrs;
}

const List<String> _inheritedKeys = <String>['MediaBox', 'CropBox', 'Rotate'];

Map<String, Object?> _mergeAttrs(
  Map<String, Object?> parent,
  Map<String, Object?> d,
) {
  final merged = Map<String, Object?>.of(parent);
  for (final key in _inheritedKeys) {
    final value = d[key];
    if (value != null) merged[key] = value;
  }
  return merged;
}

class _Line {
  _Line(this.text, this.x, this.y, this.size, this.end);

  String text;
  double x;
  final double y;
  double size;
  double end;
}

void _collectPages(
  PdfDocument doc,
  Object? node,
  Map<String, Object?>? inherited,
  Map<String, Object?> attrs,
  List<_Page> out,
  Set<Object> seen,
  int depth,
) {
  if (depth > 40 || out.length >= _maxPages) return;
  if (node is PdfRef && !seen.add(node.id)) return;
  final d = doc.dict(node);
  if (d == null) return;
  final resources = doc.dict(d['Resources']) ?? inherited;
  final merged = _mergeAttrs(attrs, d);
  final kids = doc.array(d['Kids']);
  if (kids != null && doc.name(d['Type']) != 'Page') {
    for (final kid in kids) {
      _collectPages(doc, kid, resources, merged, out, seen, depth + 1);
    }
    return;
  }
  out.add(_Page(d, resources, merged));
}

List<_Page> _pages(PdfDocument doc, Map<String, Object?>? trailer) {
  final out = <_Page>[];
  final catalog = doc.dict(trailer?['Root']);
  final root = catalog?['Pages'];
  if (root != null)
    _collectPages(doc, root, null, <String, Object?>{}, out, <Object>{}, 0);
  if (out.isNotEmpty) return out;
  for (final id in doc.objectIds) {
    final d = doc.dict(doc.object(id));
    if (d != null && doc.name(d['Type']) == 'Page') {
      out.add(
        _Page(d, doc.dict(d['Resources']), _mergeAttrs(<String, Object?>{}, d)),
      );
      if (out.length >= _maxPages) break;
    }
  }
  return out;
}

Uint8List? _pageContent(PdfDocument doc, _Page page) {
  final value = doc.resolve(page.dict['Contents']);
  final parts = <Uint8List>[];
  if (value is PdfStream) {
    final bytes = doc.decode(value);
    if (bytes != null) parts.add(bytes);
  } else if (value is List<Object?>) {
    for (final item in value) {
      final s = doc.stream(item);
      final bytes = s == null ? null : doc.decode(s);
      if (bytes != null) parts.add(bytes);
    }
  }
  if (parts.isEmpty) return null;
  if (parts.length == 1) return parts.first;
  final out = BytesBuilder();
  for (final part in parts) {
    out.add(part);
    out.addByte(10);
  }
  return out.takeBytes();
}

List<Object> _lines(List<Object> items) {
  final out = <Object>[];
  final group = <PdfPiece>[];

  void flush() {
    if (group.isEmpty) return;
    var ordered = true;
    for (var i = 1; i < group.length; i++) {
      if (group[i].x < group[i - 1].x) {
        ordered = false;
        break;
      }
    }
    final order = List<int>.generate(group.length, (i) => i);
    if (!ordered) {
      order.sort((a, b) {
        final c = group[a].x.compareTo(group[b].x);
        return c != 0 ? c : a.compareTo(b);
      });
    }
    _Line? line;
    for (final index in order) {
      final item = group[index];
      if (line != null && item.x >= line.end - line.size * 1.5) {
        final gap = item.x - line.end;
        if (gap > line.size * 0.12 &&
            !line.text.endsWith(' ') &&
            !item.text.startsWith(' ')) {
          line.text += ' ';
        }
        line.text += item.text;
        line.end = math.max(line.end, item.end);
        line.size = math.max(line.size, item.size);
        continue;
      }
      if (line != null) out.add(line);
      line = _Line(item.text, item.x, item.y, item.size, item.end);
    }
    if (line != null) out.add(line);
    group.clear();
  }

  for (final item in items) {
    if (item is PdfImagePiece) {
      flush();
      out.add(item);
      continue;
    }
    if (item is! PdfPiece) continue;
    if (group.isNotEmpty) {
      final first = group.first;
      final tolerance = math.max(first.size, item.size) * 0.4;
      if ((item.y - first.y).abs() > tolerance) flush();
    }
    group.add(item);
  }
  flush();
  return out;
}

bool _isRtl(int c) =>
    (c >= 0x0590 && c <= 0x05FF) ||
    (c >= 0x0620 && c <= 0x064A) ||
    (c >= 0x064B && c <= 0x065F) ||
    c == 0x0670 ||
    (c >= 0x066E && c <= 0x06D3) ||
    (c >= 0x06D5 && c <= 0x06EF) ||
    (c >= 0x06FA && c <= 0x06FF) ||
    (c >= 0x0750 && c <= 0x077F) ||
    (c >= 0x08A0 && c <= 0x08FF) ||
    (c >= 0xFB1D && c <= 0xFDFF) ||
    (c >= 0xFE70 && c <= 0xFEFF);

bool _isDigit(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x660 && c <= 0x669) ||
    (c >= 0x6F0 && c <= 0x6F9);

bool _isLatin(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    (c >= 0xC0 && c <= 0x24F) ||
    (c >= 0x370 && c <= 0x58F);

bool _isLtr(int c) => _isDigit(c) || _isLatin(c);

const Map<int, int> _mirror = <int, int>{
  0x28: 0x29,
  0x29: 0x28,
  0x5B: 0x5D,
  0x5D: 0x5B,
  0x7B: 0x7D,
  0x7D: 0x7B,
  0x3C: 0x3E,
  0x3E: 0x3C,
  0xAB: 0xBB,
  0xBB: 0xAB,
};

List<int> _reverseLtrRuns(List<int> r) {
  final out = <int>[];
  var i = 0;
  while (i < r.length) {
    if (_isLtr(r[i])) {
      var last = i;
      var k = i;
      while (k < r.length) {
        if (_isRtl(r[k])) break;
        if (_isLtr(r[k])) last = k;
        k++;
      }
      out.addAll(r.sublist(i, last + 1).reversed);
      i = last + 1;
    } else {
      out.add(_mirror[r[i]] ?? r[i]);
      i++;
    }
  }
  return out;
}

List<int> _reverseDigitRuns(List<int> r) {
  final out = <int>[];
  var i = 0;
  while (i < r.length) {
    if (_isDigit(r[i])) {
      var last = i;
      var k = i;
      while (k < r.length) {
        final c = r[k];
        if (_isDigit(c)) {
          last = k;
        } else if (c != 0x2E &&
            c != 0x2C &&
            c != 0x2F &&
            c != 0x3A &&
            c != 0x60B &&
            c != 0x66B &&
            c != 0x66C) {
          break;
        }
        k++;
      }
      out.addAll(r.sublist(i, last + 1).reversed);
      i = last + 1;
    } else {
      out.add(_mirror[r[i]] ?? r[i]);
      i++;
    }
  }
  return out;
}

String _visualToLogical(String text) {
  final runes = <int>[];
  var rtl = 0;
  for (final u in text.runes) {
    final m = pdfArabicForms[u];
    if (m == null) {
      runes.add(u);
    } else {
      runes.addAll(m.runes.toList().reversed);
    }
  }
  for (final u in runes) {
    if (_isRtl(u)) rtl++;
  }
  if (rtl == 0) return text;
  if (rtl / runes.length >= 0.3) {
    return String.fromCharCodes(_reverseLtrRuns(runes.reversed.toList()));
  }
  final out = <int>[];
  var i = 0;
  while (i < runes.length) {
    if (_isRtl(runes[i])) {
      var last = i;
      var k = i;
      while (k < runes.length) {
        if (_isLatin(runes[k])) break;
        if (_isRtl(runes[k])) last = k;
        k++;
      }
      out.addAll(
        _reverseDigitRuns(runes.sublist(i, last + 1).reversed.toList()),
      );
      i = last + 1;
    } else {
      out.add(runes[i]);
      i++;
    }
  }
  return String.fromCharCodes(out);
}

String _clean(String text) {
  final out = StringBuffer();
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 < units.length &&
          units[i + 1] >= 0xDC00 &&
          units[i + 1] <= 0xDFFF) {
        out.writeCharCode(u);
        out.writeCharCode(units[i + 1]);
        i++;
      }
      continue;
    }
    if (u >= 0xDC00 && u <= 0xDFFF) continue;
    if (u == 0xFFFE || u == 0xFFFF || u == 0xFEFF || u == 0xFFFD) continue;
    if (u < 32 && u != 9) {
      out.writeCharCode(32);
      continue;
    }
    if (u == 9 || u == 0xA0 || u == 0x2028 || u == 0x2029) {
      out.writeCharCode(32);
      continue;
    }
    out.writeCharCode(u);
  }
  return out.toString().replaceAll(RegExp(r' {2,}'), ' ');
}

final RegExp _bullet = RegExp(r'^([•●▪◦·\-–—*]|\d{1,3}[.)]|\([a-zA-Z0-9]\))\s');
final RegExp _sentenceEnd = RegExp(r'[.!?:;؟。]["”)]?$');

int _headingLevel(double size, double body, String text) {
  if (body <= 0 || text.length > 140) return 0;
  final ratio = size / body;
  if (ratio >= 1.8) return 1;
  if (ratio >= 1.45) return 2;
  if (ratio >= 1.2) return 3;
  return 0;
}

double _bodySize(List<List<Object>> pages) {
  final weights = <int, int>{};
  for (final page in pages) {
    for (final item in page) {
      if (item is _Line) {
        final key = (item.size * 2).round();
        weights[key] = (weights[key] ?? 0) + item.text.length;
      }
    }
  }
  var best = 0;
  var bestWeight = 0;
  weights.forEach((key, weight) {
    if (weight > bestWeight) {
      best = key;
      bestWeight = weight;
    }
  });
  return best / 2;
}

List<DocBlock> _blocks(List<Object> lines, double body) {
  final blocks = <DocBlock>[];
  var pageWidth = 0.0;
  for (final item in lines) {
    if (item is _Line) pageWidth = math.max(pageWidth, item.end - item.x);
  }
  StringBuffer? paragraph;
  var heading = 0;
  _Line? previous;
  var previousText = '';

  void flush() {
    final text = paragraph;
    if (text == null) return;
    blocks.add(
      ParagraphBlock(
        inlines: <Inline>[TextRun(text.toString())],
        heading: heading,
      ),
    );
    paragraph = null;
    heading = 0;
  }

  for (final item in lines) {
    if (item is PdfImagePiece) {
      flush();
      previous = null;
      blocks.add(
        ParagraphBlock(
          inlines: <Inline>[
            ImageInline(
              bytes: item.bytes,
              widthPt: item.width,
              heightPt: item.height,
            ),
          ],
        ),
      );
      continue;
    }
    if (item is! _Line) continue;
    final text = _clean(_visualToLogical(_clean(item.text).trim())).trim();
    if (text.isEmpty) continue;
    final level = _headingLevel(item.size, body, text);
    final prev = previous;
    final gap = prev == null ? double.infinity : prev.y - item.y;
    if (level > 0) {
      if (paragraph != null &&
          heading == level &&
          gap > 0 &&
          gap < item.size * 1.8) {
        paragraph!.write(' $text');
      } else {
        flush();
        paragraph = StringBuffer(text);
        heading = level;
      }
    } else {
      final continues =
          paragraph != null &&
          heading == 0 &&
          prev != null &&
          gap > 0 &&
          gap < item.size * 1.9 &&
          !_bullet.hasMatch(text) &&
          !(_sentenceEnd.hasMatch(previousText) &&
              (prev.end - prev.x) < pageWidth * 0.75) &&
          (item.x - prev.x) < item.size * 2.5;
      if (continues) {
        final current = paragraph!;
        final joined = current.toString();
        if (joined.endsWith('-') &&
            joined.length > 1 &&
            RegExp(r'^[a-zа-я]').hasMatch(text)) {
          paragraph = StringBuffer(joined.substring(0, joined.length - 1))
            ..write(text);
        } else {
          current.write(' $text');
        }
      } else {
        flush();
        paragraph = StringBuffer(text);
      }
    }
    previous = item;
    previousText = text;
  }
  flush();
  return blocks;
}

TextDocument readPdf(Uint8List bytes) {
  final doc = PdfDocument(bytes);
  final trailer = doc.trailer();
  if (trailer != null && trailer.containsKey('Encrypt')) {
    throw const DocumentFormatException('The PDF is protected by a password.');
  }
  final pages = _pages(doc, trailer);
  if (pages.isEmpty) {
    throw const DocumentFormatException('The PDF has no pages.');
  }
  final interpreter = PdfInterpreter(doc, <Object>[]);
  final perPage = <List<Object>>[];
  var pieces = 0;
  var pictures = 0;
  var empty = 0;
  var failures = 0;
  var firstError = '';
  for (final page in pages) {
    final items = <Object>[];
    interpreter.items = items;
    final content = _pageContent(doc, page);
    if (content == null) {
      empty++;
    } else {
      try {
        interpreter.run(content, page.resources, <double>[1, 0, 0, 1, 0, 0]);
      } on Object catch (e) {
        failures++;
        if (firstError.isEmpty) firstError = '$e';
      }
    }
    for (final item in items) {
      if (item is PdfPiece) pieces++;
      if (item is PdfImagePiece) pictures++;
    }
    perPage.add(_lines(items));
  }
  final body = _bodySize(perPage);
  final blocks = <DocBlock>[];
  for (final page in perPage) {
    final pageBlocks = _blocks(page, body);
    if (pageBlocks.isEmpty) continue;
    if (blocks.isNotEmpty) blocks.add(const RuleBlock(pageBreak: true));
    blocks.addAll(pageBlocks);
  }
  if (blocks.isEmpty) {
    final report = StringBuffer('The PDF has no readable text.')
      ..write('\npages ${pages.length}, without content $empty')
      ..write(', text pieces $pieces, pictures $pictures');
    if (failures > 0) {
      final shown = firstError.length > 160
          ? firstError.substring(0, 160)
          : firstError;
      report.write('\nerrors $failures: $shown');
    }
    throw DocumentFormatException(report.toString());
  }
  return TextDocument(blocks: blocks, baseSizePt: 11);
}

class PdfTextLine {
  const PdfTextLine(
    this.text,
    this.left,
    this.top,
    this.width,
    this.height,
    this.rtl,
  );

  final String text;
  final double left;
  final double top;
  final double width;
  final double height;
  final bool rtl;
}

class PdfLayerPage {
  const PdfLayerPage(this.index, this.lines);

  final int index;
  final List<PdfTextLine> lines;
}

List<double>? _boxOf(PdfDocument doc, Object? value) {
  final array = doc.array(value);
  if (array == null || array.length < 4) return null;
  final numbers = <double>[];
  for (var i = 0; i < 4; i++) {
    final n = doc.number(array[i]);
    if (n == null) return null;
    numbers.add(n.toDouble());
  }
  final left = math.min(numbers[0], numbers[2]);
  final right = math.max(numbers[0], numbers[2]);
  final bottom = math.min(numbers[1], numbers[3]);
  final top = math.max(numbers[1], numbers[3]);
  if (right - left < 1 || top - bottom < 1) return null;
  return <double>[left, bottom, right, top];
}

List<PdfTextLine> _layerLines(PdfDocument doc, _Page page, List<Object> items) {
  final rotate = doc.number(doc.resolve(page.attrs['Rotate']))?.toInt() ?? 0;
  if (rotate % 360 != 0) return const <PdfTextLine>[];
  final box =
      _boxOf(doc, page.attrs['CropBox']) ??
      _boxOf(doc, page.attrs['MediaBox']) ??
      <double>[0, 0, 612, 792];
  final width = box[2] - box[0];
  final height = box[3] - box[1];
  final out = <PdfTextLine>[];
  for (final item in _lines(items)) {
    if (item is! _Line) continue;
    final text = _clean(_visualToLogical(_clean(item.text).trim())).trim();
    if (text.isEmpty) continue;
    final size = item.size.clamp(1.0, 400.0).toDouble();
    final left = (item.x - box[0]) / width;
    final lineWidth = (item.end - item.x) / width;
    final top = (box[3] - (item.y + size * 0.85)) / height;
    final lineHeight = size * 1.05 / height;
    if (lineWidth <= 0 ||
        left > 1 ||
        top > 1 ||
        left + lineWidth < 0 ||
        top + lineHeight < 0) {
      continue;
    }
    var rtl = 0;
    var other = 0;
    for (final rune in text.runes) {
      if (_isRtl(rune)) {
        rtl++;
      } else if (_isLatin(rune)) {
        other++;
      }
    }
    out.add(PdfTextLine(text, left, top, lineWidth, lineHeight, rtl > other));
  }
  return out;
}

int pdfPageCount(Uint8List bytes) {
  final doc = PdfDocument(bytes);
  return _pages(doc, doc.trailer()).length;
}

void extractPdfLayer(
  Uint8List bytes,
  int first,
  void Function(PdfLayerPage page) emit,
) {
  final doc = PdfDocument(bytes);
  final trailer = doc.trailer();
  if (trailer != null && trailer.containsKey('Encrypt')) return;
  final pages = _pages(doc, trailer);
  if (pages.isEmpty) return;
  final interpreter = PdfInterpreter(doc, <Object>[]);
  final start = first.clamp(0, pages.length - 1);
  for (var step = 0; step < pages.length; step++) {
    final index = (start + step) % pages.length;
    final page = pages[index];
    final items = <Object>[];
    interpreter.items = items;
    final content = _pageContent(doc, page);
    if (content != null) {
      try {
        interpreter.run(content, page.resources, <double>[1, 0, 0, 1, 0, 0]);
      } on Object {
        items.clear();
      }
    }
    emit(PdfLayerPage(index, _layerLines(doc, page, items)));
  }
}
