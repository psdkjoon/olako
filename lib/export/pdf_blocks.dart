import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:olako/reader/doc_model.dart';

const int _maxImageBytes = 16 * 1024 * 1024;

List<Object?> serializeBlocks(List<DocBlock> blocks, String baseDir) {
  final writer = _Writer(baseDir);
  return writer.blocks(blocks);
}

class _Writer {
  _Writer(this.baseDir);

  final String baseDir;

  List<Object?> blocks(List<DocBlock> list) {
    return <Object?>[for (final block in list) _block(block)];
  }

  Map<String, Object?> _block(DocBlock block) {
    switch (block) {
      case final ParagraphBlock p:
        return <String, Object?>{
          't': 'p',
          'h': p.heading,
          'a': p.align.index,
          'r': p.rtl == null ? -1 : (p.rtl! ? 1 : 0),
          'll': p.listLevel,
          'm': p.marker,
          'ind': p.indentPt,
          'sb': p.spaceBeforePt,
          if (p.background != null) 'bg': p.background,
          'in': <Object?>[for (final inline in p.inlines) _inline(inline)],
        };
      case final CodeBlock c:
        return <String, Object?>{'t': 'c', 's': c.text, 'lang': c.language};
      case final QuoteBlock q:
        return <String, Object?>{'t': 'q', 'ch': blocks(q.children)};
      case final GroupBlock g:
        return <String, Object?>{
          't': 'g',
          'n': g.indentLevels,
          'ch': blocks(g.children),
        };
      case final RuleBlock r:
        return <String, Object?>{'t': 'r', 'pb': r.pageBreak};
      case final TableBlock t:
        return <String, Object?>{
          't': 'tb',
          'w': t.columnWeights,
          'rows': <Object?>[
            for (final row in t.rows)
              <String, Object?>{
                'h': row.header,
                'cells': <Object?>[
                  for (final cell in row.cells)
                    <String, Object?>{
                      'span': cell.span,
                      'a': cell.align.index,
                      if (cell.background != null) 'bg': cell.background,
                      'ch': blocks(cell.blocks),
                    },
                ],
              },
          ],
        };
    }
  }

  Map<String, Object?> _inline(Inline inline) {
    switch (inline) {
      case final TextRun run:
        final s = run.style;
        return <String, Object?>{
          'k': 't',
          's': run.text,
          if (s.bold) 'b': true,
          if (s.italic) 'i': true,
          if (s.underline) 'u': true,
          if (s.strike) 'x': true,
          if (s.code) 'c': true,
          if (s.superscript) 'sp': true,
          if (s.subscript) 'sb': true,
          if (s.color != null) 'col': s.color,
          if (s.background != null) 'bg': s.background,
          if (s.sizePt != null) 'z': s.sizePt,
          if (s.link != null) 'l': s.link,
        };
      case LineBreakInline():
        return <String, Object?>{'k': 'br'};
      case final ImageInline image:
        final bytes = image.bytes ?? _load(image.source);
        return <String, Object?>{
          'k': 'img',
          if (bytes != null) 'd': bytes,
          'w': image.widthPt ?? 0,
          'h': image.heightPt ?? 0,
          'alt': image.alt,
        };
    }
  }

  Uint8List? _load(String source) {
    if (source.isEmpty) return null;
    try {
      if (source.startsWith('data:')) {
        final comma = source.indexOf(',');
        if (comma < 0 || !source.substring(0, comma).contains('base64'))
          return null;
        return base64Decode(source.substring(comma + 1));
      }
      if (source.startsWith('http://') || source.startsWith('https://'))
        return null;
      var path = source;
      if (path.startsWith('file://')) path = Uri.parse(path).toFilePath();
      if (!path.startsWith('/')) {
        if (baseDir.isEmpty) return null;
        path = '$baseDir/${Uri.decodeFull(path)}';
      }
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() > _maxImageBytes) return null;
      return file.readAsBytesSync();
    } on Object {
      return null;
    }
  }
}
