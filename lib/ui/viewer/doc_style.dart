import 'package:flutter/material.dart' hide Text, Icon;
import 'package:olako/reader/doc_model.dart';
import 'package:olako/reader/text_direction.dart';

class TextContext {
  const TextContext({
    required this.pxPerPt,
    required this.surface,
    required this.ink,
    required this.link,
    required this.codeBackground,
    required this.textScaler,
    this.imageMaxWidth = 640,
    this.pixelRatio = 2,
    this.onLink,
  });

  final double pxPerPt;

  final Color surface;

  final Color ink;
  final Color link;
  final Color codeBackground;
  final TextScaler textScaler;
  final double imageMaxWidth;
  final double pixelRatio;
  final void Function(String link)? onLink;

  TextContext copyWith({Color? surface, Color? ink, double? imageMaxWidth}) {
    return TextContext(
      pxPerPt: pxPerPt,
      surface: surface ?? this.surface,
      ink: ink ?? this.ink,
      link: link,
      codeBackground: codeBackground,
      textScaler: textScaler,
      imageMaxWidth: imageMaxWidth ?? this.imageMaxWidth,
      pixelRatio: pixelRatio,
      onLink: onLink,
    );
  }
}

class DocStyle {
  const DocStyle({
    required this.text,
    required this.bodyPx,
    required this.muted,
    required this.rule,
    required this.accent,
    required this.docRtl,
    required this.panel,
    this.markdown = false,
    this.nested = false,
  });

  final TextContext text;

  final double bodyPx;
  final Color muted;
  final Color rule;
  final Color accent;
  final Color panel;

  final bool docRtl;
  final bool markdown;
  final bool nested;

  double get unit => bodyPx / 16;

  DocStyle withText(TextContext value) {
    return DocStyle(
      text: value,
      bodyPx: bodyPx,
      muted: muted,
      rule: rule,
      accent: accent,
      docRtl: docRtl,
      panel: panel,
      markdown: markdown,
      nested: nested,
    );
  }
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance() + 0.05;
  final lb = b.computeLuminance() + 0.05;
  return la > lb ? la / lb : lb / la;
}

Color readableOn(Color color, Color surface, Color fallback) {
  if (_contrast(color, surface) >= 3) return color;
  final hsl = HSLColor.fromColor(color);
  final mirrored = hsl.withLightness(1 - hsl.lightness).toColor();
  if (_contrast(mirrored, surface) >= 3) return mirrored;
  return fallback;
}

Color inkOn(Color background) {
  return background.computeLuminance() > 0.45
      ? const Color(0xFF1B1B1F)
      : const Color(0xFFF5F5F7);
}

String plainText(List<Inline> inlines) {
  final out = StringBuffer();
  for (final inline in inlines) {
    switch (inline) {
      case TextRun(:final text):
        out.write(text);
      case LineBreakInline():
        out.write('\n');
      case ImageInline():
        break;
    }
  }
  return out.toString();
}

bool paragraphIsRtl(ParagraphBlock p, bool fallback) {
  return p.rtl ?? firstStrongIsRtl(plainText(p.inlines)) ?? fallback;
}

bool? blocksAreRtl(List<DocBlock> blocks, [int limit = 60]) {
  var seen = 0;
  for (final block in blocks) {
    if (seen++ > limit) break;
    bool? found;
    switch (block) {
      case final ParagraphBlock p:
        found = p.rtl ?? firstStrongIsRtl(plainText(p.inlines));
      case final QuoteBlock q:
        found = blocksAreRtl(q.children, 10);
      case final GroupBlock g:
        found = blocksAreRtl(g.children, 10);
      case final TableBlock t:
        found = _tableIsRtl(t);
      case CodeBlock():
      case RuleBlock():
        break;
    }
    if (found != null) return found;
  }
  return null;
}

bool? _tableIsRtl(TableBlock table) {
  for (final row in table.rows) {
    for (final cell in row.cells) {
      final found = blocksAreRtl(cell.blocks, 6);
      if (found != null) return found;
    }
  }
  return null;
}

double slideAspect(SlideDeck deck) {
  if (deck.widthPt <= 0 || deck.heightPt <= 0) return 16 / 9;
  return deck.widthPt / deck.heightPt;
}
