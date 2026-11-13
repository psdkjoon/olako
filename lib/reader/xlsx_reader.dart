import 'package:olako/reader/doc_model.dart';
import 'package:olako/reader/ooxml_util.dart';
import 'package:olako/reader/plain_reader.dart';
import 'package:olako/reader/xml_lite.dart';
import 'package:olako/reader/zip_archive.dart';

const int _maxRows = 10000;
const int _maxColumns = 200;

String _partOf(
  Map<String, Relationship> rels,
  String mainPath,
  String suffix,
  String fallback,
) {
  for (final r in rels.values) {
    if (r.type.endsWith(suffix) && !r.external) {
      return resolvePartPath(mainPath, r.target);
    }
  }
  return fallback;
}

String _textOf(XmlElement? e) {
  if (e == null) return '';
  final out = StringBuffer();
  for (final part in e.children) {
    if (part.local == 't') {
      out.write(part.text);
    } else if (part.local == 'r') {
      out.write(part.child('t')?.text ?? '');
    }
  }
  return out.toString();
}

List<String> _sharedStrings(XmlElement? root) {
  if (root == null) return const <String>[];
  return <String>[for (final si in root.childrenNamed('si')) _textOf(si)];
}

Set<int> _dateStyles(XmlElement? styles) {
  final result = <int>{};
  if (styles == null) return result;
  final custom = <int, String>{};
  for (final f
      in styles.child('numFmts')?.childrenNamed('numFmt') ??
          const Iterable<XmlElement>.empty()) {
    final id = int.tryParse(f.attr('numFmtId') ?? '');
    final code = f.attr('formatCode');
    if (id != null && code != null) custom[id] = code;
  }
  final formats =
      styles.child('cellXfs')?.childrenNamed('xf') ??
      const Iterable<XmlElement>.empty();
  var index = 0;
  for (final xf in formats) {
    final id = int.tryParse(xf.attr('numFmtId') ?? '') ?? 0;
    final code = custom[id];
    final builtin =
        (id >= 14 && id <= 22) ||
        (id >= 27 && id <= 36) ||
        (id >= 45 && id <= 47) ||
        (id >= 50 && id <= 58);
    if (builtin || (code != null && _isDateFormat(code))) result.add(index);
    index++;
  }
  return result;
}

bool _isDateFormat(String code) {
  final stripped = code
      .replaceAll(RegExp(r'"[^"]*"'), '')
      .replaceAll(RegExp(r'\[[^\]]*\]'), '')
      .replaceAll(RegExp(r'\\.'), '');
  return RegExp('[dmyhs]', caseSensitive: false).hasMatch(stripped);
}

String _two(int n) => n < 10 ? '0$n' : '$n';

String _date(double serial) {
  final whole = serial.floor();
  final seconds = ((serial - whole) * 86400).round();
  final moment = DateTime.utc(
    1899,
    12,
    30,
  ).add(Duration(days: whole, seconds: seconds));
  final day = '${moment.year}-${_two(moment.month)}-${_two(moment.day)}';
  if (serial - whole < 0.00001) return day;
  return '$day ${_two(moment.hour)}:${_two(moment.minute)}';
}

String _number(String raw) {
  final value = double.tryParse(raw);
  if (value == null) return raw;
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  return double.parse(value.toStringAsPrecision(12)).toString();
}

int _column(String ref) {
  var n = 0;
  for (var i = 0; i < ref.length; i++) {
    final c = ref.codeUnitAt(i);
    if (c >= 65 && c <= 90) {
      n = n * 26 + (c - 64);
    } else if (c >= 97 && c <= 122) {
      n = n * 26 + (c - 96);
    } else {
      break;
    }
  }
  return n - 1;
}

List<List<String>> _rows(
  XmlElement sheet,
  List<String> shared,
  Set<int> dates,
) {
  final rows = <List<String>>[];
  final data = sheet.child('sheetData');
  if (data == null) return rows;
  for (final row in data.childrenNamed('row')) {
    if (rows.length >= _maxRows) break;
    final cells = <String>[];
    var next = 0;
    for (final c in row.childrenNamed('c')) {
      var index = next;
      final ref = c.attr('r');
      if (ref != null) {
        final parsed = _column(ref);
        if (parsed >= 0) index = parsed;
      }
      if (index >= _maxColumns) continue;
      while (cells.length <= index) {
        cells.add('');
      }
      final type = c.attr('t');
      final raw = c.child('v')?.text ?? '';
      String value;
      switch (type) {
        case 's':
          final at = int.tryParse(raw.trim());
          value = at == null || at < 0 || at >= shared.length ? '' : shared[at];
        case 'inlineStr':
          value = _textOf(c.child('is'));
        case 'b':
          value = raw.trim() == '1' ? 'TRUE' : 'FALSE';
        case 'str':
        case 'e':
          value = raw;
        default:
          final style = int.tryParse(c.attr('s') ?? '');
          final number = double.tryParse(raw);
          if (number != null &&
              number >= 0 &&
              number < 2958466 &&
              style != null &&
              dates.contains(style)) {
            value = _date(number);
          } else {
            value = raw.isEmpty ? '' : _number(raw.trim());
          }
      }
      cells[index] = value;
      next = index + 1;
    }
    rows.add(cells);
  }
  while (rows.isNotEmpty && rows.last.every((v) => v.isEmpty)) {
    rows.removeLast();
  }
  return rows;
}

TextDocument readXlsx(ZipArchive zip) {
  final mainPath = findMainPart(zip) ?? 'xl/workbook.xml';
  final workbook = readXmlPart(zip, mainPath);
  if (workbook == null) {
    throw const DocumentFormatException('The workbook has no content.');
  }
  final rels = readRelationships(zip, mainPath);
  final shared = _sharedStrings(
    readXmlPart(
      zip,
      _partOf(rels, mainPath, '/sharedStrings', 'xl/sharedStrings.xml'),
    ),
  );
  final dates = _dateStyles(
    readXmlPart(zip, _partOf(rels, mainPath, '/styles', 'xl/styles.xml')),
  );
  final blocks = <DocBlock>[];
  final sheets =
      workbook.child('sheets')?.childrenNamed('sheet') ??
      const Iterable<XmlElement>.empty();
  for (final sheet in sheets) {
    final relId = sheet.prefixedAttr('id') ?? sheet.attr('id');
    final rel = relId == null ? null : rels[relId];
    if (rel == null || rel.external) continue;
    final root = readXmlPart(zip, resolvePartPath(mainPath, rel.target));
    if (root == null) continue;
    final rows = _rows(root, shared, dates);
    if (rows.isEmpty) continue;
    blocks.add(
      ParagraphBlock(
        heading: 2,
        inlines: <Inline>[TextRun(sheet.attr('name') ?? 'Sheet')],
      ),
    );
    blocks.addAll(buildTableBlocks(rows));
  }
  if (blocks.isEmpty) {
    throw const DocumentFormatException('The workbook has no cells.');
  }
  return TextDocument(blocks: blocks, baseSizePt: 11);
}
