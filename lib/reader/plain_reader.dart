import 'dart:math' as math;

import 'package:olako/reader/doc_model.dart';

String _normalize(String source) {
  var text = source;
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

bool _looksWrapped(List<String> lines) {
  if (lines.length < 3) return false;
  for (var i = 0; i < lines.length - 1; i++) {
    final line = lines[i];
    if (line.length < 40 || line.length > 110) return false;
    if (line.startsWith(' ')) return false;
  }
  return true;
}

TextDocument readPlainText(String source) {
  final text = _normalize(source).replaceAll('\t', '    ');
  final blocks = <DocBlock>[];
  final current = <String>[];

  void flush() {
    if (current.isEmpty) return;
    final inlines = <Inline>[];
    if (_looksWrapped(current)) {
      inlines.add(TextRun(current.map((l) => l.trim()).join(' ')));
    } else {
      for (var i = 0; i < current.length; i++) {
        if (i > 0) inlines.add(const LineBreakInline());
        inlines.add(TextRun(current[i]));
      }
    }
    blocks.add(ParagraphBlock(inlines: inlines));
    current.clear();
  }

  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) {
      flush();
      continue;
    }
    current.add(line);
    if (current.length >= 40) flush();
  }
  flush();
  return TextDocument(blocks: blocks, baseSizePt: 11);
}

final RegExp _number = RegExp(r'^[-+]?[\d.,]+%?$');

List<DocBlock> buildTableBlocks(List<List<String>> rows, {bool header = true}) {
  if (rows.isEmpty) return const <DocBlock>[];
  var columns = 0;
  for (final row in rows) {
    columns = math.max(columns, row.length);
  }
  if (columns == 0) return const <DocBlock>[];
  final weights = List<double>.filled(columns, 6);
  final sample = math.min(rows.length, 200);
  for (var r = 0; r < sample; r++) {
    final row = rows[r];
    for (var c = 0; c < row.length; c++) {
      final length = row[c].length.toDouble();
      weights[c] = math.max(weights[c], math.min(length, 40.0));
    }
  }
  final blocks = <DocBlock>[];
  const chunk = 50;
  for (var start = 0; start < rows.length; start += chunk) {
    final end = math.min(rows.length, start + chunk);
    final out = <TableRowData>[];
    for (var r = start; r < end; r++) {
      final cells = <TableCellData>[];
      for (final value in rows[r]) {
        final plain = value.trim();
        cells.add(
          TableCellData(
            blocks: <DocBlock>[
              ParagraphBlock(
                inlines: plain.isEmpty
                    ? const <Inline>[]
                    : <Inline>[TextRun(plain)],
              ),
            ],
            align: _number.hasMatch(plain) ? DocAlign.end : DocAlign.start,
          ),
        );
      }
      while (cells.length < columns) {
        cells.add(
          const TableCellData(
            blocks: <DocBlock>[ParagraphBlock(inlines: <Inline>[])],
          ),
        );
      }
      out.add(TableRowData(cells: cells, header: header && r == 0));
    }
    blocks.add(TableBlock(rows: out, columnWeights: weights));
  }
  return blocks;
}

List<List<String>> parseDelimited(String text, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var started = false;
  final length = text.length;
  var i = 0;
  while (i < length) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < length && text[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        quoted = false;
        i++;
        continue;
      }
      field.write(c);
      i++;
      continue;
    }
    if (c == '"' && field.isEmpty) {
      quoted = true;
      started = true;
      i++;
    } else if (c == delimiter) {
      row.add(field.toString());
      field.clear();
      started = true;
      i++;
    } else if (c == '\n') {
      if (started || field.isNotEmpty || row.isNotEmpty) {
        row.add(field.toString());
        rows.add(row);
      }
      row = <String>[];
      field.clear();
      started = false;
      i++;
    } else {
      field.write(c);
      started = true;
      i++;
    }
  }
  if (started || field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

String _detectDelimiter(String text) {
  final newline = text.indexOf('\n');
  final first = newline < 0 ? text : text.substring(0, newline);
  var best = ',';
  var bestCount = 0;
  for (final candidate in const <String>[',', ';', '\t', '|']) {
    final count = candidate.allMatches(first).length;
    if (count > bestCount) {
      best = candidate;
      bestCount = count;
    }
  }
  return best;
}

TextDocument readDelimited(String source) {
  final text = _normalize(source);
  final rows = parseDelimited(text, _detectDelimiter(text));
  return TextDocument(blocks: buildTableBlocks(rows), baseSizePt: 11);
}
