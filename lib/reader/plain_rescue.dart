import 'package:olako/reader/doc_model.dart';
import 'package:olako/reader/zip_archive.dart';

final RegExp _wordParagraph = RegExp(r'<w:p(?:\s[^>]*)?>[\s\S]*?</w:p>');
final RegExp _wordPiece = RegExp(
  r'<w:t(?:\s[^>]*)?>([\s\S]*?)</w:t>|(<w:tab\s*/>)|(<w:br(?:\s[^>]*)?/>)',
);
final RegExp _slideParagraph = RegExp(r'<a:p(?:\s[^>]*)?>[\s\S]*?</a:p>');
final RegExp _slidePiece = RegExp(
  r'<a:t(?:\s[^>]*)?>([\s\S]*?)</a:t>|(<a:br(?:\s[^>]*)?/>)',
);
final RegExp _slideName = RegExp(r'^ppt/slides/slide(\d+)\.xml$');
final RegExp _numeric = RegExp(r'&#(x[0-9a-fA-F]+|\d+);');

String _unescape(String raw) {
  if (!raw.contains('&')) return raw;
  final numbers = raw.replaceAllMapped(_numeric, (m) {
    final body = m.group(1)!;
    final code = body.startsWith('x')
        ? int.tryParse(body.substring(1), radix: 16)
        : int.tryParse(body);
    if (code == null || code <= 0 || code > 0x10FFFF) return '';
    return String.fromCharCode(code);
  });
  return numbers
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

List<String> _paragraphs(
  String xml,
  RegExp paragraph,
  RegExp piece,
  String tabMarker,
) {
  final out = <String>[];
  for (final match in paragraph.allMatches(xml)) {
    final text = StringBuffer();
    for (final part in piece.allMatches(match.group(0)!)) {
      final value = part.group(1);
      if (value != null) {
        text.write(_unescape(value));
      } else if (part.group(2) != null && tabMarker.isNotEmpty) {
        text.write(tabMarker);
      } else {
        text.write('\n');
      }
    }
    out.add(text.toString());
  }
  return out;
}

TextDocument? rescueDocx(ZipArchive zip) {
  final xml = zip.readString('word/document.xml');
  if (xml == null) return null;
  final blocks = <DocBlock>[];
  for (final line in _paragraphs(xml, _wordParagraph, _wordPiece, '    ')) {
    blocks.add(
      ParagraphBlock(
        inlines: line.isEmpty ? const <Inline>[] : <Inline>[TextRun(line)],
      ),
    );
  }
  if (!blocks.any((b) => b is ParagraphBlock && !b.isEmpty)) return null;
  return TextDocument(blocks: blocks, baseSizePt: 11);
}

SlideDeck? rescuePptx(ZipArchive zip) {
  const width = 960.0;
  const height = 540.0;
  final found = <int, String>{};
  for (final name in zip.names) {
    final match = _slideName.firstMatch(name);
    if (match != null) found[int.parse(match.group(1)!)] = name;
  }
  final order = found.keys.toList()..sort();
  final slides = <SlideData>[];
  for (final number in order) {
    final xml = zip.readString(found[number]!);
    if (xml == null) continue;
    final lines = _paragraphs(
      xml,
      _slideParagraph,
      _slidePiece,
      '',
    ).where((line) => line.trim().isNotEmpty).toList();
    final paragraphs = <SlideParagraph>[
      for (final line in lines)
        SlideParagraph(
          inlines: <Inline>[
            TextRun(line, const RunStyle(color: 0xFF1B1B1F, sizePt: 22)),
          ],
          sizePt: 22,
          spaceBeforePt: 6,
        ),
    ];
    slides.add(
      SlideData(
        shapes: <SlideShape>[
          SlideTextShape(
            x: 40,
            y: 30,
            width: width - 80,
            height: height - 60,
            paragraphs: paragraphs,
            anchor: -1,
          ),
        ],
        background: 0xFFFFFFFF,
        outline: <DocBlock>[
          for (var i = 0; i < lines.length; i++)
            ParagraphBlock(
              inlines: <Inline>[TextRun(lines[i])],
              heading: i == 0 ? 2 : 0,
            ),
        ],
        notes: '',
        title: lines.isEmpty ? '' : lines.first,
      ),
    );
  }
  if (slides.isEmpty) return null;
  return SlideDeck(slides: slides, widthPt: width, heightPt: height);
}
