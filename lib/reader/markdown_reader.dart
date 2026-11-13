import 'dart:math' as math;

import 'package:olako/reader/doc_model.dart';

TextDocument readMarkdown(String source) {
  final blocks = _MarkdownParser(source).parse();
  return TextDocument(blocks: blocks, baseSizePt: 11, markdown: true);
}

class _LinkRef {
  const _LinkRef(this.url);

  final String url;
}

class _MarkdownParser {
  _MarkdownParser(String source) : _source = source;

  final String _source;
  final Map<String, _LinkRef> _refs = <String, _LinkRef>{};

  static final RegExp _atx = RegExp(
    r'^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$',
  );
  static final RegExp _rule = RegExp(r'^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$');
  static final RegExp _pageBreak = RegExp(
    r'^\s*(?:<!--\s*(?:page-?break|new-?page)\s*-->|\\(?:newpage|pagebreak|clearpage)|<div[^>]*page-break-(?:after|before)\s*:\s*always[^>]*>\s*(?:</div>)?)\s*$',
    caseSensitive: false,
  );

  static final RegExp _setext = RegExp(r'^ {0,3}(=+|-+)[ \t]*$');
  static final RegExp _fence = RegExp(
    r'^( {0,3})(`{3,}|~{3,})[ \t]*([^`]*?)[ \t]*$',
  );
  static final RegExp _quote = RegExp(r'^ {0,3}>');
  static final RegExp _listMarker = RegExp(
    r'^( {0,3})([-+*]|\d{1,9}[.)])( +|$)',
  );
  static final RegExp _tableDelimiter = RegExp(
    r'^ {0,3}\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$',
  );
  static final RegExp _refDefinition = RegExp(
    r'''^ {0,3}\[([^\]^][^\]]*)\]:[ \t]*(<[^>]*>|\S+)(?:[ \t]+(?:"[^"]*"|'[^']*'|\([^)]*\)))?[ \t]*$''',
  );
  static final RegExp _task = RegExp(r'^\[([ xX])\][ \t]+');

  List<DocBlock> parse() {
    var text = _source;
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    var lines = text
        .split('\n')
        .map((l) => l.replaceAll('\t', '    '))
        .toList();

    final out = <DocBlock>[];

    if (lines.isNotEmpty && lines.first.trim() == '---') {
      final limit = math.min(lines.length, 200);
      for (var j = 1; j < limit; j++) {
        final t = lines[j].trim();
        if (t == '---' || t == '...') {
          final body = lines.sublist(1, j).join('\n');
          if (body.contains(':')) {
            out.add(CodeBlock(text: body, language: 'yaml'));
            lines = lines.sublist(j + 1);
          }
          break;
        }
      }
    }

    lines = _collectReferences(lines);
    out.addAll(_blocks(lines, 0));
    return out;
  }

  List<String> _collectReferences(List<String> lines) {
    final kept = <String>[];
    String? fenceChar;
    var fenceLength = 0;
    for (final line in lines) {
      final f = _fence.firstMatch(line);
      if (fenceChar == null) {
        if (f != null) {
          fenceChar = f.group(2)![0];
          fenceLength = f.group(2)!.length;
        }
      } else if (f != null &&
          f.group(2)![0] == fenceChar &&
          f.group(2)!.length >= fenceLength &&
          (f.group(3) ?? '').isEmpty) {
        fenceChar = null;
      }
      if (fenceChar == null) {
        final m = _refDefinition.firstMatch(line);
        if (m != null) {
          var url = m.group(2)!;
          if (url.startsWith('<') && url.endsWith('>')) {
            url = url.substring(1, url.length - 1);
          }
          _refs.putIfAbsent(_normalizeLabel(m.group(1)!), () => _LinkRef(url));
          continue;
        }
      }
      kept.add(line);
    }
    return kept;
  }

  static String _normalizeLabel(String label) =>
      label.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  static bool _blank(String line) => line.trim().isEmpty;

  static int _indentOf(String line) {
    var n = 0;
    while (n < line.length && line.codeUnitAt(n) == 0x20) {
      n++;
    }
    return n;
  }

  List<DocBlock> _blocks(List<String> lines, int level) {
    final out = <DocBlock>[];
    final para = <String>[];

    void flushParagraph() {
      if (para.isEmpty) return;
      final text = para.map((l) => l.trimLeft()).join('\n');
      para.clear();
      out.add(ParagraphBlock(inlines: _inlines(text, const RunStyle())));
    }

    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (_blank(line)) {
        flushParagraph();
        i++;
        continue;
      }

      final fence = _fence.firstMatch(line);
      if (fence != null) {
        flushParagraph();
        final marker = fence.group(2)!;
        final indent = fence.group(1)!.length;
        final code = <String>[];
        var j = i + 1;
        final closing = RegExp(
          '^ {0,3}${RegExp.escape(marker[0])}{${marker.length},}[ \\t]*\$',
        );
        while (j < lines.length && !closing.hasMatch(lines[j])) {
          final l = lines[j];
          code.add(_indentOf(l) >= indent ? l.substring(indent) : l.trimLeft());
          j++;
        }
        final info = (fence.group(3) ?? '').split(RegExp(r'\s+')).first;
        out.add(CodeBlock(text: code.join('\n'), language: info));
        i = j + 1;
        continue;
      }

      final atx = _atx.firstMatch(line);
      if (atx != null) {
        flushParagraph();
        out.add(
          ParagraphBlock(
            heading: atx.group(1)!.length,
            inlines: _inlines((atx.group(2) ?? '').trim(), const RunStyle()),
          ),
        );
        i++;
        continue;
      }

      if (para.isNotEmpty) {
        final setext = _setext.firstMatch(line);
        if (setext != null) {
          final text = para.map((l) => l.trim()).join('\n');
          para.clear();
          out.add(
            ParagraphBlock(
              heading: setext.group(1)!.startsWith('=') ? 1 : 2,
              inlines: _inlines(text, const RunStyle()),
            ),
          );
          i++;
          continue;
        }
      }

      if (_pageBreak.hasMatch(line)) {
        flushParagraph();
        out.add(const RuleBlock(pageBreak: true));
        i++;
        continue;
      }

      if (_rule.hasMatch(line)) {
        flushParagraph();
        out.add(const RuleBlock());
        i++;
        continue;
      }

      if (_quote.hasMatch(line)) {
        flushParagraph();
        final inner = <String>[];
        var j = i;
        while (j < lines.length) {
          final l = lines[j];
          if (_quote.hasMatch(l)) {
            inner.add(l.replaceFirst(RegExp(r'^ {0,3}> ?'), ''));
          } else if (!_blank(l) &&
              inner.isNotEmpty &&
              !_blank(inner.last) &&
              !_startsBlock(l)) {
            inner.add(l);
          } else {
            break;
          }
          j++;
        }
        out.add(QuoteBlock(children: _blocks(inner, level)));
        i = j;
        continue;
      }

      final marker = _listMarker.firstMatch(line);
      if (marker != null && _canStartList(marker, line, para.isNotEmpty)) {
        flushParagraph();
        i = _list(lines, i, level, out);
        continue;
      }

      if (line.contains('|') && i + 1 < lines.length) {
        final table = _tryTable(lines, i);
        if (table != null) {
          flushParagraph();
          out.add(table.block);
          i = table.next;
          continue;
        }
      }

      if (para.isEmpty && _indentOf(line) >= 4) {
        final code = <String>[];
        var j = i;
        while (j < lines.length) {
          final l = lines[j];
          if (_blank(l)) {
            var k = j;
            while (k < lines.length && _blank(lines[k])) {
              k++;
            }
            if (k < lines.length && _indentOf(lines[k]) >= 4) {
              for (var b = j; b < k; b++) {
                code.add('');
              }
              j = k;
              continue;
            }
            break;
          }
          if (_indentOf(l) < 4) break;
          code.add(l.substring(4));
          j++;
        }
        out.add(CodeBlock(text: code.join('\n')));
        i = j;
        continue;
      }

      if (para.isEmpty && line.trimLeft().startsWith('<!--')) {
        var j = i;
        while (j < lines.length && !lines[j].contains('-->')) {
          j++;
        }
        i = j + 1;
        continue;
      }

      para.add(line);
      i++;
    }
    flushParagraph();
    return out;
  }

  bool _canStartList(RegExpMatch m, String line, bool inParagraph) {
    final empty = line.trim().length == m.group(2)!.length;
    if (!inParagraph) return true;
    if (empty) return false;
    final token = m.group(2)!;
    final isOrdered = RegExp(r'^\d').hasMatch(token);
    return !isOrdered ||
        int.tryParse(token.substring(0, token.length - 1)) == 1;
  }

  bool _startsBlock(String line) {
    if (_fence.hasMatch(line) || _atx.hasMatch(line) || _rule.hasMatch(line)) {
      return true;
    }
    final m = _listMarker.firstMatch(line);
    return m != null && line.trim().length > m.group(2)!.length;
  }

  int _list(List<String> lines, int start, int level, List<DocBlock> out) {
    final first = _listMarker.firstMatch(lines[start])!;
    final ordered = RegExp(r'^\d').hasMatch(first.group(2)!);
    var number = ordered
        ? int.tryParse(
                first.group(2)!.substring(0, first.group(2)!.length - 1),
              ) ??
              1
        : 0;
    var i = start;
    while (i < lines.length) {
      final line = lines[i];
      final m = _listMarker.firstMatch(line);
      if (m == null) break;
      final token = m.group(2)!;
      if (RegExp(r'^\d').hasMatch(token) != ordered) break;

      final baseIndent = m.group(1)!.length;
      final markerEnd = m.end;
      final spaces = m.group(3)!.length;
      final hasContent = line.length > markerEnd;
      final contentIndent = (!hasContent || spaces > 4)
          ? baseIndent + token.length + 1
          : baseIndent + token.length + spaces;
      final itemLines = <String>[
        if (hasContent)
          (spaces > 4
              ? line.substring(baseIndent + token.length + 1)
              : line.substring(markerEnd))
        else
          '',
      ];

      var j = i + 1;
      while (j < lines.length) {
        final l = lines[j];
        if (_blank(l)) {
          var k = j;
          while (k < lines.length && _blank(lines[k])) {
            k++;
          }
          if (k < lines.length && _indentOf(lines[k]) >= contentIndent) {
            for (var b = j; b < k; b++) {
              itemLines.add('');
            }
            j = k;
            continue;
          }
          break;
        }
        if (_indentOf(l) >= contentIndent) {
          itemLines.add(l.substring(contentIndent));
        } else if (_listMarker.hasMatch(l) || _startsBlock(l)) {
          break;
        } else if (!_blank(itemLines.last)) {
          itemLines.add(l.trimLeft());
        } else {
          break;
        }
        j++;
      }

      var marker = ordered
          ? '$number.'
          : (level == 0 ? '\u2022' : (level == 1 ? '\u25E6' : '\u25AA'));
      if (itemLines.isNotEmpty) {
        final task = _task.firstMatch(itemLines.first);
        if (task != null) {
          marker = task.group(1) == ' ' ? '\u2610' : '\u2611';
          itemLines[0] = itemLines.first.substring(task.end);
        }
      }
      _emitItem(_blocks(itemLines, level + 1), level, marker, out);
      number++;

      var k = j;
      while (k < lines.length && _blank(lines[k])) {
        k++;
      }
      if (k < lines.length) {
        final next = _listMarker.firstMatch(lines[k]);
        if (next != null &&
            RegExp(r'^\d').hasMatch(next.group(2)!) == ordered &&
            next.group(1)!.length < contentIndent) {
          i = k;
          continue;
        }
      }
      return j;
    }
    return i;
  }

  void _emitItem(
    List<DocBlock> blocks,
    int level,
    String marker,
    List<DocBlock> out,
  ) {
    var placed = false;
    for (final b in blocks) {
      if (!placed) {
        placed = true;
        if (b is ParagraphBlock && b.heading == 0 && b.listLevel < 0) {
          out.add(
            ParagraphBlock(
              inlines: b.inlines,
              listLevel: level,
              marker: marker,
            ),
          );
          continue;
        }
        out.add(
          ParagraphBlock(
            inlines: const <Inline>[],
            listLevel: level,
            marker: marker,
          ),
        );
      }
      if (b is ParagraphBlock && b.listLevel >= 0) {
        out.add(b);
      } else {
        out.add(GroupBlock(children: <DocBlock>[b], indentLevels: level + 1));
      }
    }
    if (!placed) {
      out.add(
        ParagraphBlock(
          inlines: const <Inline>[],
          listLevel: level,
          marker: marker,
        ),
      );
    }
  }

  List<String> _splitRow(String line) {
    var s = line.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|') && !s.endsWith('\\|')) s = s.substring(0, s.length - 1);
    final cells = <String>[];
    final cell = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '\\' && i + 1 < s.length && s[i + 1] == '|') {
        cell.write('|');
        i++;
      } else if (c == '|') {
        cells.add(cell.toString().trim());
        cell.clear();
      } else {
        cell.write(c);
      }
    }
    cells.add(cell.toString().trim());
    return cells;
  }

  ({TableBlock block, int next})? _tryTable(List<String> lines, int start) {
    final delimiter = lines[start + 1];
    if (!delimiter.contains('-') || !_tableDelimiter.hasMatch(delimiter)) {
      return null;
    }
    final header = _splitRow(lines[start]);
    final aligns = _splitRow(delimiter);
    if (header.length != aligns.length) return null;
    if (!lines[start].contains('|') && !delimiter.contains('|')) return null;

    DocAlign alignOf(String d) {
      final left = d.startsWith(':');
      final right = d.endsWith(':');
      if (left && right) return DocAlign.center;
      if (right) return DocAlign.end;
      return DocAlign.start;
    }

    final columns = header.length;
    TableCellData cell(String text, DocAlign align) {
      return TableCellData(
        blocks: <DocBlock>[
          ParagraphBlock(inlines: _inlines(text, const RunStyle())),
        ],
        align: align,
      );
    }

    final rows = <TableRowData>[
      TableRowData(
        header: true,
        cells: <TableCellData>[
          for (var c = 0; c < columns; c++) cell(header[c], alignOf(aligns[c])),
        ],
      ),
    ];
    var i = start + 2;
    while (i < lines.length && !_blank(lines[i]) && lines[i].contains('|')) {
      final values = _splitRow(lines[i]);
      rows.add(
        TableRowData(
          cells: <TableCellData>[
            for (var c = 0; c < columns; c++)
              cell(c < values.length ? values[c] : '', alignOf(aligns[c])),
          ],
        ),
      );
      i++;
    }
    return (
      block: TableBlock(
        rows: rows,
        columnWeights: List<double>.filled(columns, 1),
      ),
      next: i,
    );
  }

  static const String _asciiPunct = "!\"#\$%&'()*+,-./:;<=>?@[\\]^_`{|}~";
  static final RegExp _punctuation = RegExp(r'[\p{P}\p{S}]', unicode: true);
  static final RegExp _space = RegExp(r'\s');
  static final RegExp _autolink = RegExp(
    r'^<([A-Za-z][A-Za-z0-9+.\-]{1,31}:[^\s<>]*)>',
  );
  static final RegExp _emailLink = RegExp(
    r'^<([^\s@<>]+@[^\s@<>]+\.[A-Za-z]+)>',
  );
  static final RegExp _htmlTag = RegExp(
    r'^</?([A-Za-z][A-Za-z0-9-]*)(?:\s[^<>]*)?/?>',
  );
  static final RegExp _entity = RegExp(
    r'^&(#\d+|#[xX][0-9a-fA-F]+|[A-Za-z0-9]+);',
  );
  static const Map<String, String> _namedEntities = <String, String>{
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': '\u00A0',
    'copy': '\u00A9',
    'reg': '\u00AE',
    'mdash': '\u2014',
    'ndash': '\u2013',
    'hellip': '\u2026',
    'laquo': '\u00AB',
    'raquo': '\u00BB',
  };

  List<Inline> _inlines(String text, RunStyle base) {
    final tokens = _tokenize(text, base);
    _processEmphasis(tokens);
    return _assemble(tokens, base);
  }

  List<_Token> _tokenize(String s, RunStyle base) {
    final tokens = <_Token>[];
    final buffer = StringBuffer();

    void flushText() {
      if (buffer.isEmpty) return;
      tokens.add(_Token.text(buffer.toString()));
      buffer.clear();
    }

    void addNodes(List<Inline> nodes) {
      flushText();
      tokens.add(_Token.nodes(nodes));
    }

    var i = 0;
    while (i < s.length) {
      final c = s[i];
      switch (c) {
        case '\\':
          if (i + 1 < s.length && s[i + 1] == '\n') {
            addNodes(const <Inline>[LineBreakInline()]);
            i += 2;
          } else if (i + 1 < s.length && _asciiPunct.contains(s[i + 1])) {
            buffer.write(s[i + 1]);
            i += 2;
          } else {
            buffer.write(c);
            i++;
          }
        case '`':
          var n = 1;
          while (i + n < s.length && s[i + n] == '`') {
            n++;
          }
          final close = _findBacktickClose(s, i + n, n);
          if (close < 0) {
            buffer.write('`' * n);
            i += n;
          } else {
            var code = s.substring(i + n, close).replaceAll('\n', ' ');
            if (code.length > 2 &&
                code.startsWith(' ') &&
                code.endsWith(' ') &&
                code.trim().isNotEmpty) {
              code = code.substring(1, code.length - 1);
            }
            addNodes(<Inline>[TextRun(code, base.copyWith(code: true))]);
            i = close + n;
          }
        case '*':
        case '_':
        case '~':
          var n = 1;
          while (i + n < s.length && s[i + n] == c) {
            n++;
          }
          if (c == '~' && n != 2) {
            buffer.write('~' * n);
            i += n;
            break;
          }
          final prev = i == 0 ? ' ' : s[i - 1];
          final next = i + n >= s.length ? ' ' : s[i + n];
          final prevSpace = _space.hasMatch(prev);
          final nextSpace = _space.hasMatch(next);
          final prevPunct = _punctuation.hasMatch(prev);
          final nextPunct = _punctuation.hasMatch(next);
          final left = !nextSpace && (!nextPunct || prevSpace || prevPunct);
          final right = !prevSpace && (!prevPunct || nextSpace || nextPunct);
          final canOpen = c == '_' ? left && (!right || prevPunct) : left;
          final canClose = c == '_' ? right && (!left || nextPunct) : right;
          flushText();
          tokens.add(_Token.delimiter(c, n, canOpen, canClose));
          i += n;
        case '!':
        case '[':
          final isImage = c == '!';
          if (isImage && (i + 1 >= s.length || s[i + 1] != '[')) {
            buffer.write(c);
            i++;
            break;
          }
          final link = _tryLink(s, i, isImage, base);
          if (link == null) {
            buffer.write(c);
            i++;
          } else {
            addNodes(link.nodes);
            i = link.end;
          }
        case '<':
          final rest = s.substring(i);
          final auto = _autolink.firstMatch(rest);
          final email = auto == null ? _emailLink.firstMatch(rest) : null;
          if (auto != null) {
            final url = auto.group(1)!;
            addNodes(<Inline>[TextRun(url, base.copyWith(link: url))]);
            i += auto.end;
          } else if (email != null) {
            final address = email.group(1)!;
            addNodes(<Inline>[
              TextRun(address, base.copyWith(link: 'mailto:$address')),
            ]);
            i += email.end;
          } else if (rest.startsWith('<!--')) {
            final end = rest.indexOf('-->');
            i += end < 0 ? rest.length : end + 3;
          } else {
            final tag = _htmlTag.firstMatch(rest);
            if (tag == null) {
              buffer.write(c);
              i++;
            } else {
              final name = tag.group(1)!.toLowerCase();
              final whole = tag.group(0)!;
              if (name == 'br') {
                addNodes(const <Inline>[LineBreakInline()]);
              } else if (name == 'img') {
                final src = _attribute(whole, 'src');
                if (src != null) {
                  addNodes(<Inline>[
                    ImageInline(
                      source: src,
                      alt: _attribute(whole, 'alt') ?? '',
                    ),
                  ]);
                }
              }
              i += whole.length;
            }
          }
        case '&':
          final m = _entity.firstMatch(
            s.substring(i, math.min(s.length, i + 12)),
          );
          final decoded = m == null ? null : _decodeEntity(m.group(1)!);
          if (decoded == null) {
            buffer.write(c);
            i++;
          } else {
            buffer.write(decoded);
            i += m!.end;
          }
        case '\n':
          final current = buffer.toString();
          final trimmed = current.trimRight();
          final hard = current.length - trimmed.length >= 2;
          buffer
            ..clear()
            ..write(trimmed);
          if (hard) {
            addNodes(const <Inline>[LineBreakInline()]);
          } else {
            buffer.write(' ');
          }
          i++;
        case 'h':
          final isLink =
              (i == 0 || !_isWordChar(s[i - 1])) &&
              (s.startsWith('http://', i) || s.startsWith('https://', i));
          if (!isLink) {
            buffer.write(c);
            i++;
            break;
          }
          var end = i;
          while (end < s.length && !_space.hasMatch(s[end]) && s[end] != '<') {
            end++;
          }
          while (end > i && '.,;:!?*_~\'"'.contains(s[end - 1])) {
            end--;
          }
          final url = s.substring(i, end);
          if (url.endsWith(')') && !url.contains('(')) {
            end--;
          }
          final clean = s.substring(i, end);
          addNodes(<Inline>[TextRun(clean, base.copyWith(link: clean))]);
          i = end;
        default:
          buffer.write(c);
          i++;
      }
    }
    flushText();
    return tokens;
  }

  static bool _isWordChar(String c) => RegExp(r'[A-Za-z0-9]').hasMatch(c);

  static String? _decodeEntity(String body) {
    if (body.startsWith('#')) {
      final hex = body.startsWith('#x') || body.startsWith('#X');
      final n = int.tryParse(body.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
      if (n == null || n <= 0 || n > 0x10FFFF) return null;
      return String.fromCharCode(n);
    }
    return _namedEntities[body];
  }

  static String? _attribute(String tag, String name) {
    final m = RegExp(
      '$name\\s*=\\s*("([^"]*)"|\'([^\']*)\')',
      caseSensitive: false,
    ).firstMatch(tag);
    if (m == null) return null;
    return m.group(2) ?? m.group(3);
  }

  static int _findBacktickClose(String s, int from, int n) {
    var i = from;
    while (i < s.length) {
      if (s[i] != '`') {
        i++;
        continue;
      }
      var run = 0;
      while (i + run < s.length && s[i + run] == '`') {
        run++;
      }
      if (run == n) return i;
      i += run;
    }
    return -1;
  }

  ({List<Inline> nodes, int end})? _tryLink(
    String s,
    int start,
    bool image,
    RunStyle base,
  ) {
    final open = image ? start + 1 : start;
    var depth = 1;
    var k = open + 1;
    while (k < s.length) {
      final c = s[k];
      if (c == '\\') {
        k += 2;
        continue;
      }
      if (c == '`') {
        var n = 1;
        while (k + n < s.length && s[k + n] == '`') {
          n++;
        }
        final close = _findBacktickClose(s, k + n, n);
        k = close < 0 ? k + n : close + n;
        continue;
      }
      if (c == '[') depth++;
      if (c == ']') {
        depth--;
        if (depth == 0) break;
      }
      k++;
    }
    if (k >= s.length) return null;
    final label = s.substring(open + 1, k);
    final after = k + 1;
    String? url;
    var end = after;

    if (after < s.length && s[after] == '(') {
      final dest = _parseDestination(s, after + 1);
      if (dest != null) {
        url = dest.url;
        end = dest.end;
      }
    } else if (after < s.length && s[after] == '[') {
      final close = s.indexOf(']', after + 1);
      if (close > 0) {
        final raw = s.substring(after + 1, close);
        final ref = _refs[_normalizeLabel(raw.isEmpty ? label : raw)];
        if (ref != null) {
          url = ref.url;
          end = close + 1;
        }
      }
    } else {
      final ref = _refs[_normalizeLabel(label)];
      if (ref != null) url = ref.url;
    }
    if (url == null) return null;

    if (image) {
      return (
        nodes: <Inline>[ImageInline(source: url, alt: _plain(label))],
        end: end,
      );
    }
    return (nodes: _inlines(label, base.copyWith(link: url)), end: end);
  }

  ({String url, int end})? _parseDestination(String s, int from) {
    var i = from;
    while (i < s.length && (s[i] == ' ' || s[i] == '\n')) {
      i++;
    }
    final url = StringBuffer();
    if (i < s.length && s[i] == '<') {
      i++;
      while (i < s.length && s[i] != '>' && s[i] != '\n') {
        url.write(s[i]);
        i++;
      }
      if (i >= s.length || s[i] != '>') return null;
      i++;
    } else {
      var parens = 0;
      while (i < s.length) {
        final c = s[i];
        if (c == '\\' && i + 1 < s.length && _asciiPunct.contains(s[i + 1])) {
          url.write(s[i + 1]);
          i += 2;
          continue;
        }
        if (c == ' ' || c == '\n') break;
        if (c == '(') parens++;
        if (c == ')') {
          if (parens == 0) break;
          parens--;
        }
        url.write(c);
        i++;
      }
    }
    while (i < s.length && (s[i] == ' ' || s[i] == '\n')) {
      i++;
    }
    if (i < s.length && (s[i] == '"' || s[i] == "'" || s[i] == '(')) {
      final closer = s[i] == '(' ? ')' : s[i];
      final close = s.indexOf(closer, i + 1);
      if (close < 0) return null;
      i = close + 1;
      while (i < s.length && (s[i] == ' ' || s[i] == '\n')) {
        i++;
      }
    }
    if (i >= s.length || s[i] != ')') return null;
    return (url: url.toString(), end: i + 1);
  }

  static String _plain(String label) =>
      label.replaceAll(RegExp(r'[*_`~\\]'), '').replaceAll('\n', ' ').trim();

  void _processEmphasis(List<_Token> tokens) {
    final stack = <int>[];
    for (var i = 0; i < tokens.length; i++) {
      if (tokens[i].kind == _Kind.delimiter) stack.add(i);
    }
    var ci = 0;
    while (ci < stack.length) {
      final closer = tokens[stack[ci]];
      if (!closer.canClose || closer.count == 0) {
        ci++;
        continue;
      }
      var found = -1;
      for (var oi = ci - 1; oi >= 0; oi--) {
        final o = tokens[stack[oi]];
        if (o.char == closer.char &&
            o.canOpen &&
            o.count > 0 &&
            !_oddMatch(o, closer)) {
          found = oi;
          break;
        }
      }
      if (found < 0) {
        if (!closer.canOpen) {
          stack.removeAt(ci);
        } else {
          ci++;
        }
        continue;
      }
      final opener = tokens[stack[found]];
      final use = (closer.count >= 2 && opener.count >= 2) ? 2 : 1;
      for (var t = stack[found] + 1; t < stack[ci]; t++) {
        final token = tokens[t];
        if (closer.char == '~') {
          token.strike++;
        } else if (use == 2) {
          token.strong++;
        } else {
          token.em++;
        }
      }
      opener.count -= use;
      closer.count -= use;
      stack.removeRange(found + 1, ci);
      ci = found + 1;
      if (opener.count == 0) {
        stack.removeAt(found);
        ci--;
      }
      if (closer.count == 0) stack.removeAt(ci);
    }
  }

  static bool _oddMatch(_Token opener, _Token closer) {
    if (!(opener.canOpen && opener.canClose) &&
        !(closer.canOpen && closer.canClose)) {
      return false;
    }
    final sum = opener.original + closer.original;
    return sum % 3 == 0 &&
        !(opener.original % 3 == 0 && closer.original % 3 == 0);
  }

  List<Inline> _assemble(List<_Token> tokens, RunStyle base) {
    final out = <Inline>[];

    void add(Inline inline) {
      if (inline is TextRun && out.isNotEmpty) {
        final last = out.last;
        if (last is TextRun && _sameStyle(last.style, inline.style)) {
          out[out.length - 1] = TextRun(last.text + inline.text, last.style);
          return;
        }
      }
      out.add(inline);
    }

    for (final token in tokens) {
      RunStyle styled(RunStyle style) => style.copyWith(
        bold: token.strong > 0 ? true : null,
        italic: token.em > 0 ? true : null,
        strike: token.strike > 0 ? true : null,
      );
      switch (token.kind) {
        case _Kind.text:
          add(TextRun(token.text, styled(base)));
        case _Kind.delimiter:
          if (token.count > 0) {
            add(TextRun(token.char * token.count, styled(base)));
          }
        case _Kind.nodes:
          for (final node in token.inlineNodes) {
            if (node is TextRun) {
              add(TextRun(node.text, styled(node.style)));
            } else {
              add(node);
            }
          }
      }
    }
    return out;
  }

  static bool _sameStyle(RunStyle a, RunStyle b) {
    return a.bold == b.bold &&
        a.italic == b.italic &&
        a.underline == b.underline &&
        a.strike == b.strike &&
        a.code == b.code &&
        a.superscript == b.superscript &&
        a.subscript == b.subscript &&
        a.color == b.color &&
        a.background == b.background &&
        a.sizePt == b.sizePt &&
        a.link == b.link;
  }
}

enum _Kind { text, delimiter, nodes }

class _Token {
  _Token.text(this.text)
    : kind = _Kind.text,
      char = '',
      count = 0,
      original = 0,
      canOpen = false,
      canClose = false,
      inlineNodes = const <Inline>[];

  _Token.delimiter(this.char, int length, this.canOpen, this.canClose)
    : kind = _Kind.delimiter,
      text = '',
      count = length,
      original = length,
      inlineNodes = const <Inline>[];

  _Token.nodes(this.inlineNodes)
    : kind = _Kind.nodes,
      text = '',
      char = '',
      count = 0,
      original = 0,
      canOpen = false,
      canClose = false;

  final _Kind kind;
  final String text;
  final String char;
  int count;
  final int original;
  final bool canOpen;
  final bool canClose;
  final List<Inline> inlineNodes;
  int strong = 0;
  int em = 0;
  int strike = 0;
}
