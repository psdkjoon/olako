import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text, Icon;
import 'package:flutter/widgets.dart' as w show Text;
import 'package:olako/reader/doc_model.dart';
import 'package:olako/theme/app_text_style.dart';
import 'package:olako/ui/viewer/doc_style.dart';
import 'package:olako/ui/viewer/inline_text.dart';

const List<double> _headingScale = <double>[1, 2, 1.6, 1.35, 1.2, 1.1, 1];

const List<double> _markdownHeadingScale = <double>[
  1,
  2.05,
  1.6,
  1.32,
  1.15,
  1.05,
  1,
];

Widget buildDocBlock(DocBlock block, DocStyle s, {int depth = 0}) {
  switch (block) {
    case final ParagraphBlock p:
      return _paragraph(p, s);
    case final CodeBlock c:
      return _code(c, s);
    case final QuoteBlock q:
      return _quote(q, s, depth);
    case final GroupBlock g:
      return Padding(
        padding: EdgeInsetsDirectional.only(
          start: g.indentLevels * s.bodyPx * 1.4,
        ),
        child: _column(g.children, s, depth + 1),
      );
    case final RuleBlock r:
      return Padding(
        padding: EdgeInsets.symmetric(
          vertical: (r.pageBreak ? 18 : 12) * s.unit,
        ),
        child: Divider(
          height: 1,
          thickness: r.pageBreak ? 2 : 1,
          color: s.rule,
        ),
      );
    case final TableBlock t:
      return _table(t, s, depth);
  }
}

Widget _column(List<DocBlock> blocks, DocStyle s, int depth) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final block in blocks) buildDocBlock(block, s, depth: depth),
    ],
  );
}

Widget _paragraph(ParagraphBlock p, DocStyle s) {
  final u = s.unit;
  final isList = p.listLevel >= 0;
  if (p.inlines.isEmpty && !isList) {
    return SizedBox(height: s.bodyPx * (s.nested ? 0.6 : 0.9));
  }
  final rtl = paragraphIsRtl(p, s.docRtl);
  final heading = math.min(6, math.max(0, p.heading));
  final md = s.markdown;
  final size = s.bodyPx * (md ? _markdownHeadingScale : _headingScale)[heading];
  final base = TextStyle(
    fontFamily: AppTextStyle.readingFamily,
    fontFamilyFallback: AppTextStyle.fontFallback,
    fontSize: size,
    height: heading > 0 ? 1.3 : (md ? 1.68 : 1.55),
    fontWeight: heading > 0 ? FontWeight.w700 : FontWeight.w400,
    fontVariations: <FontVariation>[
      FontVariation.weight(heading > 0 ? 700 : 400),
    ],
    color: heading == 6 ? s.muted : s.text.ink,
  );

  final cell = s.nested;
  final top = cell
      ? (heading > 0 ? 2 * u : 0.0)
      : heading > 0
      ? s.bodyPx *
            (md ? (heading <= 2 ? 1.6 : 1.15) : (heading <= 2 ? 1.1 : 0.7))
      : math.min(p.spaceBeforePt * s.text.pxPerPt, 24.0 * u);
  final bottom =
      u *
      (cell
          ? 2.0
          : heading > 0
          ? (md ? 8.0 : 6.0)
          : (isList ? (md ? 5.0 : 4.0) : (md ? 14.0 : 8.0)));

  final background = p.background == null ? null : Color(p.background!);
  final surface = background == null
      ? s.text.surface
      : Color.alphaBlend(background, s.text.surface);
  final textContext = background == null
      ? s.text
      : s.text.copyWith(surface: surface, ink: inkOn(surface));

  Widget body = InlineText(
    inlines: p.inlines,
    base: background == null ? base : base.copyWith(color: inkOn(surface)),
    context: textContext,
    rtl: rtl,
    align: p.align,
  );

  if (isList) {
    final markerWidth = s.bodyPx * 1.7;
    final markerStyle = base.copyWith(
      fontSize: s.bodyPx,
      color: md ? s.accent : base.color,
    );
    body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: p.listLevel * s.bodyPx * 1.4 + 4 * u),
        SizedBox(
          width: markerWidth,
          child: Padding(
            padding: EdgeInsetsDirectional.only(end: 6 * u),
            child: w.Text(
              p.marker,
              textAlign: TextAlign.end,
              textScaler: s.text.textScaler,
              style: markerStyle,
            ),
          ),
        ),
        Expanded(child: body),
      ],
    );
  } else if (p.indentPt > 0) {
    body = Padding(
      padding: EdgeInsetsDirectional.only(
        start: math.min(p.indentPt * s.text.pxPerPt, 80 * u),
      ),
      child: body,
    );
  }

  if (background != null) {
    body = DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4 * u),
      ),
      child: Padding(padding: EdgeInsets.all(6 * u), child: body),
    );
  }

  if (md && heading >= 1 && heading <= 2) {
    body = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: s.rule, width: 1)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: 8 * u),
        child: body,
      ),
    );
  }

  Widget result = Directionality(
    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    child: Padding(
      padding: EdgeInsets.only(top: top, bottom: bottom),
      child: body,
    ),
  );
  if (heading > 0) {
    result = Semantics(header: true, child: result);
  }
  return result;
}

Widget _code(CodeBlock c, DocStyle s) {
  final u = s.unit;
  final style = TextStyle(
    fontFamily: 'monospace',
    fontSize: s.bodyPx * 0.86,
    height: 1.5,
    color: s.text.ink,
  );
  final language = c.language.trim();
  return Padding(
    padding: EdgeInsets.only(top: 4 * u, bottom: 14 * u),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: s.panel,
        borderRadius: BorderRadius.circular(10 * u),
        border: Border.all(color: s.rule, width: 0.6),
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (language.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(14 * u, 8 * u, 14 * u, 0),
                child: w.Text(
                  language.toUpperCase(),
                  textScaler: s.text.textScaler,
                  style: TextStyle(
                    fontSize: s.bodyPx * 0.7,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w700,
                    fontVariations: const <FontVariation>[
                      FontVariation.weight(700),
                    ],
                    color: s.muted,
                  ),
                ),
              ),
            if (s.nested)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  14 * u,
                  (language.isEmpty ? 12 : 6) * u,
                  14 * u,
                  12 * u,
                ),
                child: w.Text(
                  c.text,
                  style: style,
                  textScaler: s.text.textScaler,
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.fromLTRB(
                  14 * u,
                  (language.isEmpty ? 12 : 6) * u,
                  14 * u,
                  12 * u,
                ),
                child: w.Text(
                  c.text,
                  style: style,
                  softWrap: false,
                  textScaler: s.text.textScaler,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

Widget _quote(QuoteBlock q, DocStyle s, int depth) {
  final u = s.unit;
  final bar = math.max(2.0, 3 * u);
  final radius = BorderRadius.circular(6 * u);
  return Padding(
    padding: EdgeInsets.only(top: 2 * u, bottom: 12 * u),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: s.accent.withValues(alpha: 0.08),
        borderRadius: radius,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            PositionedDirectional(
              start: 0,
              top: 0,
              bottom: 0,
              width: bar,
              child: ColoredBox(color: s.accent),
            ),
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                bar + 14 * u,
                8 * u,
                12 * u,
                0,
              ),
              child: _column(q.children, s, depth + 1),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _table(TableBlock t, DocStyle s, int depth) {
  final columns = t.columnCount;
  if (columns == 0 || t.rows.isEmpty) return const SizedBox.shrink();
  final u = s.unit;
  final minColumn = 96 * u;

  final given = t.columnWeights;
  final weights = <double>[
    for (var i = 0; i < columns; i++)
      given.length == columns && given[i] > 0 ? given[i] : 1.0,
  ];
  var sum = 0.0;
  var needed = 0.0;
  for (final weight in weights) {
    sum += weight;
  }
  for (final weight in weights) {
    needed = math.max(needed, minColumn * sum / weight);
  }
  final rtl = blocksAreRtl(<DocBlock>[t]) ?? s.docRtl;

  if (s.nested) {
    return Padding(
      padding: EdgeInsets.only(top: 4 * u, bottom: 8 * u),
      child: Directionality(
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var r = 0; r < t.rows.length; r++)
              _tableRow(t.rows[r], weights, s, depth, r, flex: true),
          ],
        ),
      ),
    );
  }

  return Padding(
    padding: EdgeInsets.only(top: 4 * u, bottom: (s.markdown ? 16 : 8) * u),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 600.0;
        final total = math.min(
          math.max(available, needed),
          math.max(available, columns * 200.0 * u),
        );
        final widths = <double>[
          for (final weight in weights) total * weight / sum,
        ];
        final grid = Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var r = 0; r < t.rows.length; r++)
                _tableRow(t.rows[r], widths, s, depth, r),
            ],
          ),
        );
        if (total <= available + 0.5) return grid;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: total, child: grid),
        );
      },
    ),
  );
}

Widget _tableRow(
  TableRowData row,
  List<double> widths,
  DocStyle s,
  int depth,
  int index, {
  bool flex = false,
}) {
  final cells = <Widget>[];
  var column = 0;
  final striped = s.markdown && index.isOdd && !row.header;
  for (final cell in row.cells) {
    final span = cell.span < 1 ? 1 : cell.span;
    var width = 0.0;
    for (var k = column; k < column + span && k < widths.length; k++) {
      width += widths[k];
    }
    column += span;
    if (width <= 0) continue;
    final child = _tableCell(cell, row.header, s, depth, striped);
    cells.add(
      flex
          ? Expanded(flex: math.max(1, (width * 100).round()), child: child)
          : SizedBox(width: width, child: child),
    );
  }
  return IntrinsicHeight(
    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells),
  );
}

Widget _tableCell(
  TableCellData cell,
  bool header,
  DocStyle s,
  int depth,
  bool striped,
) {
  final u = s.unit;
  final fill = cell.background == null ? null : Color(cell.background!);
  final surface = fill == null
      ? s.text.surface
      : Color.alphaBlend(fill, s.text.surface);
  final cellStyle = DocStyle(
    text: fill == null
        ? s.text
        : s.text.copyWith(surface: surface, ink: inkOn(surface)),
    bodyPx: s.bodyPx * 0.94,
    muted: s.muted,
    rule: s.rule,
    accent: s.accent,
    docRtl: s.docRtl,
    panel: s.panel,
    markdown: s.markdown,
    nested: true,
  );
  final blocks = <DocBlock>[
    for (final block in cell.blocks) _tidyCellBlock(block, cell.align, header),
  ];
  final color =
      fill ??
      (header ? s.panel : (striped ? s.panel.withValues(alpha: 0.4) : null));
  return DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      border: Border.all(color: s.rule, width: 0.6),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: (s.markdown ? 10 : 8) * u,
        vertical: (s.markdown ? 6 : 4) * u,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final block in blocks)
            buildDocBlock(block, cellStyle, depth: depth + 1),
        ],
      ),
    ),
  );
}

DocBlock _tidyCellBlock(DocBlock block, DocAlign align, bool header) {
  if (block is! ParagraphBlock) return block;
  final needsAlign = align != DocAlign.start && block.align == DocAlign.start;
  if (!needsAlign && !header) return block;
  return ParagraphBlock(
    inlines: header
        ? <Inline>[for (final i in block.inlines) _bold(i)]
        : block.inlines,
    heading: block.heading,
    align: needsAlign ? align : block.align,
    rtl: block.rtl,
    listLevel: block.listLevel,
    marker: block.marker,
    indentPt: block.indentPt,
    spaceBeforePt: 0,
    background: block.background,
  );
}

Inline _bold(Inline inline) {
  if (inline is TextRun) {
    return TextRun(inline.text, inline.style.copyWith(bold: true));
  }
  return inline;
}
