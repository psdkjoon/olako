import 'dart:typed_data';

enum DocAlign { start, center, end, justify }

class RunStyle {
  const RunStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.code = false,
    this.superscript = false,
    this.subscript = false,
    this.color,
    this.background,
    this.sizePt,
    this.link,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool code;
  final bool superscript;
  final bool subscript;
  final int? color;
  final int? background;
  final double? sizePt;
  final String? link;

  RunStyle copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    bool? code,
    bool? superscript,
    bool? subscript,
    int? color,
    int? background,
    double? sizePt,
    String? link,
  }) {
    return RunStyle(
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      strike: strike ?? this.strike,
      code: code ?? this.code,
      superscript: superscript ?? this.superscript,
      subscript: subscript ?? this.subscript,
      color: color ?? this.color,
      background: background ?? this.background,
      sizePt: sizePt ?? this.sizePt,
      link: link ?? this.link,
    );
  }
}

sealed class Inline {
  const Inline();
}

class TextRun extends Inline {
  const TextRun(this.text, [this.style = const RunStyle()]);

  final String text;
  final RunStyle style;
}

class LineBreakInline extends Inline {
  const LineBreakInline();
}

class ImageInline extends Inline {
  const ImageInline({
    this.bytes,
    this.source = '',
    this.alt = '',
    this.widthPt,
    this.heightPt,
  });

  final Uint8List? bytes;
  final String source;
  final String alt;
  final double? widthPt;
  final double? heightPt;
}

sealed class DocBlock {
  const DocBlock();
}

class ParagraphBlock extends DocBlock {
  const ParagraphBlock({
    required this.inlines,
    this.heading = 0,
    this.align = DocAlign.start,
    this.rtl,
    this.listLevel = -1,
    this.marker = '',
    this.indentPt = 0,
    this.spaceBeforePt = 0,
    this.background,
  });

  final List<Inline> inlines;

  final int heading;
  final DocAlign align;

  final bool? rtl;

  final int listLevel;
  final String marker;
  final double indentPt;
  final double spaceBeforePt;
  final int? background;

  bool get isEmpty => inlines.isEmpty;
}

class CodeBlock extends DocBlock {
  const CodeBlock({required this.text, this.language = ''});

  final String text;
  final String language;
}

class QuoteBlock extends DocBlock {
  const QuoteBlock({required this.children});

  final List<DocBlock> children;
}

class GroupBlock extends DocBlock {
  const GroupBlock({required this.children, this.indentLevels = 1});

  final List<DocBlock> children;
  final int indentLevels;
}

class RuleBlock extends DocBlock {
  const RuleBlock({this.pageBreak = false});

  final bool pageBreak;
}

class TableCellData {
  const TableCellData({
    required this.blocks,
    this.span = 1,
    this.align = DocAlign.start,
    this.background,
  });

  final List<DocBlock> blocks;
  final int span;
  final DocAlign align;
  final int? background;
}

class TableRowData {
  const TableRowData({required this.cells, this.header = false});

  final List<TableCellData> cells;
  final bool header;
}

class TableBlock extends DocBlock {
  const TableBlock({required this.rows, this.columnWeights = const <double>[]});

  final List<TableRowData> rows;
  final List<double> columnWeights;

  int get columnCount {
    var count = columnWeights.length;
    for (final row in rows) {
      var n = 0;
      for (final cell in row.cells) {
        n += cell.span;
      }
      if (n > count) count = n;
    }
    return count;
  }
}

class SlideParagraph {
  const SlideParagraph({
    required this.inlines,
    this.align = DocAlign.start,
    this.rtl,
    this.level = 0,
    this.bullet = '',
    this.marginPt = 0,
    this.indentPt = 0,
    this.spaceBeforePt = 0,
    this.sizePt = 18,
  });

  final List<Inline> inlines;
  final DocAlign align;

  final bool? rtl;
  final int level;

  final String bullet;
  final double marginPt;

  final double indentPt;
  final double spaceBeforePt;

  final double sizePt;
}

enum ShapeKind { rect, roundRect, ellipse, line }

sealed class SlideShape {
  const SlideShape({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotation = 0,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  final double rotation;
}

class SlideTextShape extends SlideShape {
  const SlideTextShape({
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    super.rotation,
    this.paragraphs = const <SlideParagraph>[],
    this.kind = ShapeKind.rect,
    this.fill,
    this.line,
    this.lineWidthPt = 1,
    this.anchor = 0,
    this.insetLeft = 7.2,
    this.insetTop = 3.6,
    this.insetRight = 7.2,
    this.insetBottom = 3.6,
    this.title = false,
    this.flipH = false,
  });

  final List<SlideParagraph> paragraphs;
  final ShapeKind kind;
  final int? fill;
  final int? line;
  final double lineWidthPt;

  final int anchor;
  final double insetLeft;
  final double insetTop;
  final double insetRight;
  final double insetBottom;
  final bool title;
  final bool flipH;
}

class SlidePictureShape extends SlideShape {
  const SlidePictureShape({
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    super.rotation,
    required this.bytes,
    this.alt = '',
    this.cropLeft = 0,
    this.cropTop = 0,
    this.cropRight = 0,
    this.cropBottom = 0,
  });

  final Uint8List bytes;
  final String alt;

  final double cropLeft;
  final double cropTop;
  final double cropRight;
  final double cropBottom;
}

class SlideTableShape extends SlideShape {
  const SlideTableShape({
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    required this.columnWidths,
    required this.rows,
  });

  final List<double> columnWidths;
  final List<List<SlideTableCell>> rows;
}

class SlideTableCell {
  const SlideTableCell({required this.paragraphs, this.fill, this.span = 1});

  final List<SlideParagraph> paragraphs;
  final int? fill;
  final int span;
}

class SlideData {
  const SlideData({
    required this.shapes,
    required this.background,
    required this.outline,
    required this.notes,
    required this.title,
  });

  final List<SlideShape> shapes;

  final int background;

  final List<DocBlock> outline;
  final String notes;
  final String title;
}

sealed class LoadedDocument {
  const LoadedDocument();
}

class TextDocument extends LoadedDocument {
  const TextDocument({
    required this.blocks,
    required this.baseSizePt,
    this.markdown = false,
  });

  final List<DocBlock> blocks;

  final double baseSizePt;
  final bool markdown;
}

class SlideDeck extends LoadedDocument {
  const SlideDeck({
    required this.slides,
    required this.widthPt,
    required this.heightPt,
  });

  final List<SlideData> slides;
  final double widthPt;
  final double heightPt;
}

enum DocumentProblem {
  legacyFormat,
  encrypted,
  damaged,
  unsupported,
  tooLarge,
  noText,
}

class LoadOutcome {
  const LoadOutcome.ready(LoadedDocument this.document, [this.detail = ''])
    : problem = null;

  const LoadOutcome.failed(DocumentProblem this.problem, [this.detail = ''])
    : document = null;

  final LoadedDocument? document;
  final DocumentProblem? problem;
  final String detail;
}
